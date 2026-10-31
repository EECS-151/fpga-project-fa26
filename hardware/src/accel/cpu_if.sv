`default_nettype none
// cpu_if: the CPU's side of the accelerator: parameter bank, delta log, read-back registers and
// RESYNC. The CPU port runs on cpu_clk. COMMIT/RESYNC and the read-back registers cross with
// cdc_handshake (so registers read a few cycles late), the delta log with async_fifo.
//   bank       the CPU writes the 65-word shadow bank (skew[21], h_bid, h_ask, size_bid[21],
//              size_ask[21]), then COMMITs the heartbeat it was computed for. A COMMIT for the
//              latest heartbeat is copied to the active bank; any other counts as stale. A
//              heartbeat with no COMMIT since the previous one counts as missed.
//   delta log  1024 entries, pushed by accel_ctrl or book_resync, popped by reading LOG_DATA.
//              A push into a full log is dropped and sets the overflow flag.
//
// Register map (byte offsets, one 32-bit word each; cpu_rdata is valid one cycle after cpu_re)
//   0x000 STATUS            [1:0] session state, [2] halted, [5:3] halt reason, [6] active bank
//                           valid, [7] log overflow, [8] resync busy, [31:16] active epoch
//   0x004 COMMIT            W: [15:0] the epoch the shadow bank was computed at
//   0x008 MISSED_COMMITS    0x00C STALE_COMMITS
//   0x010 LOG_DATA          R: pops one entry (0 when empty)
//   0x014 LOG_COUNT         0x018 LOG_OVERFLOW
//   0x01C RESYNC            W 1: refill the log from the current book; R: [0] busy
//   0x020 BEST_BID          [13:0] px, [29:14] qty, [31] valid (all 0 when empty)   0x024 BEST_ASK (same)
//   0x028 INVENTORY         signed      0x02C CASH_LO [31:0]           0x030 CASH_HI [39:32], signed
//   0x034 SESSION_LIMITS    [7:0] position limit, [15:8] max order qty, [23:16] NEW budget per heartbeat
//   0x038 SESSION_HEARTBEATS [15:0] total, [31:16] remaining        0x03C HEARTBEAT_COUNT
//   0x100..0x200 the shadow bank, word i at 0x100 + 4*i (write only)
module cpu_if #(
    parameter int QMAX = 10
) (
    input  wire logic               clk,
    input  wire logic               rst,
    input  wire logic               clear,                      // session start

    // delta-log push (accel_ctrl, or book_resync while trading is paused)
    input  wire logic               log_push_valid,
    input  wire logic [31:0]        log_push_data,
    output logic               log_full,
    input  wire logic               log_overflow_clear,         // book_resync finished

    // from accel_ctrl
    input  wire logic               heartbeat_pulse,
    input  wire logic [15:0]        heartbeat_count,
    input  wire logic [1:0]         session_state,
    input  wire logic               halted,
    input  wire logic [2:0]         halt_reason,
    input  wire logic [15:0]        total_heartbeats,
    input  wire logic [15:0]        heartbeats_remaining,
    input  wire logic [7:0]         position_limit,
    input  wire logic [7:0]         max_order_qty,
    input  wire logic [7:0]         max_msgs_per_heartbeat,
    output logic               resync_request,             // to accel_ctrl
    input  wire logic               resync_busy,

    // the book, for the BEST_* registers
    input  wire logic               bid_best_valid,
    input  wire logic [13:0]        bid_best_px,
    input  wire logic [15:0]        bid_best_qty,
    input  wire logic               ask_best_valid,
    input  wire logic [13:0]        ask_best_px,
    input  wire logic [15:0]        ask_best_qty,
    // order_state, for readback
    input  wire logic signed [15:0] inventory,
    input  wire logic signed [39:0] cash,

    // the active bank, to quote_mgr (combinational read at bank_row)
    input  wire logic [4:0]         bank_row,
    output logic signed [23:0] bank_skew_q8,
    output logic [7:0]         bank_size_bid,
    output logic [7:0]         bank_size_ask,
    output logic signed [23:0] bank_half_spread_bid_q8,
    output logic signed [23:0] bank_half_spread_ask_q8,

    // the CPU's memory-mapped port, on cpu_clk
    input  wire logic               cpu_clk,
    input  wire logic               cpu_rst,
    input  wire logic [9:0]         cpu_addr,                   // byte offset, word aligned
    input  wire logic [31:0]        cpu_wdata,
    input  wire logic               cpu_we,
    input  wire logic               cpu_re,
    output logic [31:0]        cpu_rdata
);
    localparam int NQ = 2 * QMAX + 1;                          // 21 table rows
    localparam int BANK_WORDS = 3 * NQ + 2;                    // 65
    localparam int WORD_HALF_SPREAD_BID = NQ, WORD_HALF_SPREAD_ASK = NQ + 1;
    localparam int WORD_SIZE_BID = NQ + 2, WORD_SIZE_ASK = 2 * NQ + 2;
    localparam int LOG_DEPTH_LOG2 = 10;                        // 1024 entries

    // ---- parameter bank: shadow on cpu_clk, active on clk
    logic signed [23:0] shadow_bank [BANK_WORDS];              // sizes use the low 8 bits
    logic signed [23:0] active_skew_q8 [NQ];
    logic signed [23:0] active_half_spread_bid_q8, active_half_spread_ask_q8;
    logic [7:0]         active_size_bid [NQ];
    logic [7:0]         active_size_ask [NQ];
    logic               active_valid;                          // the active bank has been loaded
    logic [15:0]        active_epoch;                          // the epoch it was computed at
    logic [15:0]        last_marker;                           // the latest heartbeat
    logic               marker_committed;                      // the latest marker's bank is in
    logic [15:0]        stale_commits, missed_commits;

    assign bank_skew_q8            = active_skew_q8[bank_row];
    assign bank_size_bid           = active_size_bid[bank_row];
    assign bank_size_ask           = active_size_ask[bank_row];
    assign bank_half_spread_bid_q8 = active_half_spread_bid_q8;
    assign bank_half_spread_ask_q8 = active_half_spread_ask_q8;

    // ---- the CPU-to-accelerator command channel: {commit, resync, epoch}
    typedef struct packed {
        logic        commit;
        logic        resync;
        logic [15:0] epoch;
    } command_t;

    logic     command_send, command_busy, command_valid;
    command_t command_out, command_in;
    wire      commit_write = command_valid && command_in.commit;   // the CPU's COMMIT, on clk
    wire      resync_write = command_valid && command_in.resync;
    logic [7:0] resyncs_applied;                                   // echoed to the CPU in the snapshot

    cdc_handshake #(.WIDTH($bits(command_t))) command_cdc (
        .src_clk(cpu_clk), .src_rst(cpu_rst), .src_send(command_send), .src_data(command_out), .src_busy(command_busy),
        .dst_clk(clk), .dst_rst(rst), .dst_valid(command_valid), .dst_data(command_in));

    // ---- delta log
    logic        log_head_valid, log_pop;
    logic [31:0] log_head;
    logic [10:0] log_count, log_written, log_visible;
    logic        log_overflow;                                 // sticky until a RESYNC finishes

    async_fifo #(.WIDTH(32), .DEPTH_LOG2(LOG_DEPTH_LOG2), .EXTERNAL_RD_LIMIT(1)) log_fifo (
        .wr_clk(clk), .wr_rst(rst), .wr_en(log_push_valid), .wr_data(log_push_data),
        .wr_full(log_full), .wr_empty(), .wr_count(log_written),
        .rd_clk(cpu_clk), .rd_rst(cpu_rst), .rd_pop(log_pop), .rd_valid(log_head_valid), .rd_data(log_head),
        .rd_count(log_count), .rd_limit(log_visible));

    function automatic logic [15:0] add_saturating_16(input logic [15:0] a, input logic [15:0] b);
        logic [16:0] sum = {1'b0, a} + {1'b0, b};
        return sum[16] ? 16'hFFFF : sum[15:0];
    endfunction

    // shadow -> active, tagged with `epoch`
    task automatic swap_bank(input logic [15:0] epoch);
        for (int i = 0; i < NQ; i++) begin
            active_skew_q8[i]  <= shadow_bank[i];
            active_size_bid[i] <= shadow_bank[WORD_SIZE_BID + i][7:0];
            active_size_ask[i] <= shadow_bank[WORD_SIZE_ASK + i][7:0];
        end
        active_half_spread_bid_q8 <= shadow_bank[WORD_HALF_SPREAD_BID];
        active_half_spread_ask_q8 <= shadow_bank[WORD_HALF_SPREAD_ASK];
        active_valid     <= 1'b1;
        active_epoch     <= epoch;
        marker_committed <= 1'b1;
    endtask

    // =============================================================================================
    // Accelerator side (clk): the CPU's writes arrive as commands
    // =============================================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            log_overflow <= 1'b0;
            active_valid <= 1'b0; active_epoch <= '0; marker_committed <= 1'b0;
            last_marker <= '0; stale_commits <= '0; missed_commits <= '0; resync_request <= 1'b0;
            resyncs_applied <= '0;
            for (int i = 0; i < NQ; i++) begin active_skew_q8[i] <= '0; active_size_bid[i] <= '0; active_size_ask[i] <= '0; end
            active_half_spread_bid_q8 <= '0; active_half_spread_ask_q8 <= '0;
        end else begin
            // ---- the delta log: a push into a full FIFO is dropped
            if (log_push_valid && log_full) log_overflow <= 1'b1;
            if (log_overflow_clear)         log_overflow <= 1'b0;

            // ---- RESYNC: the request waits until accel_ctrl grants it
            if (resync_write) resync_request <= 1'b1;
            else if (resync_busy) resync_request <= 1'b0;
            if (resync_write) resyncs_applied <= resyncs_applied + 8'd1;

            if (clear) begin
                for (int i = 0; i < NQ; i++) begin active_skew_q8[i] <= '0; active_size_bid[i] <= '0; active_size_ask[i] <= '0; end
                active_half_spread_bid_q8 <= '0; active_half_spread_ask_q8 <= '0;
                active_valid <= 1'b0; active_epoch <= '0;
                last_marker <= '0; stale_commits <= '0; missed_commits <= '0; marker_committed <= 1'b0;
                if (commit_write && command_in.epoch == 16'd0) swap_bank(16'd0);   // a commit in the clear's cycle: marker 0
            end else begin
                // ---- the heartbeat moves the marker (a miss if nothing came since the last one),
                //      then a COMMIT tagged with the marker swaps at once
                logic [15:0] marker;
                logic        committed;
                marker    = last_marker;
                committed = marker_committed;
                if (heartbeat_pulse) begin
                    if (!committed) missed_commits <= add_saturating_16(missed_commits, 16'd1);
                    marker      = heartbeat_count;
                    committed   = 1'b0;
                    last_marker <= heartbeat_count;
                end
                if (commit_write) begin
                    if (command_in.epoch == marker) begin
                        swap_bank(marker);
                        committed = 1'b1;
                    end else begin
                        stale_commits <= add_saturating_16(stale_commits, 16'd1);
                    end
                end
                marker_committed <= committed;
            end
        end
    end

    // ---- the read-back snapshot, sent to cpu_clk continuously
    typedef struct packed {
        logic [10:0] log_written;                                  // the log entries this snapshot covers
        logic [7:0]  resyncs_applied;
        logic [15:0] active_epoch;
        logic        resync_busy;                                  // request pending or walk running
        logic        log_overflow;
        logic        active_valid;
        logic [2:0]  halt_reason;
        logic        halted;
        logic [1:0]  session_state;
        logic [15:0] missed_commits;
        logic [15:0] stale_commits;
        logic [31:0] best_bid;
        logic [31:0] best_ask;
        logic [15:0] inventory;
        logic [39:0] cash;
        logic [7:0]  max_msgs_per_heartbeat;
        logic [7:0]  max_order_qty;
        logic [7:0]  position_limit;
        logic [15:0] heartbeats_remaining;
        logic [15:0] total_heartbeats;
        logic [15:0] heartbeat_count;
    } readback_t;

    readback_t snapshot, mirror;
    always_comb begin
        snapshot = '{log_written: log_written, resyncs_applied: resyncs_applied, active_epoch: active_epoch,
                     resync_busy: resync_request || resync_busy, log_overflow: log_overflow, active_valid: active_valid,
                     halt_reason: halt_reason, halted: halted, session_state: session_state,
                     missed_commits: missed_commits, stale_commits: stale_commits,
                     // px and qty are 0 for an empty side (book_side leaves them unset)
                     best_bid: bid_best_valid ? {1'b1, 1'b0, bid_best_qty, bid_best_px} : 32'd0,
                     best_ask: ask_best_valid ? {1'b1, 1'b0, ask_best_qty, ask_best_px} : 32'd0,
                     inventory: inventory, cash: cash,
                     max_msgs_per_heartbeat: max_msgs_per_heartbeat, max_order_qty: max_order_qty,
                     position_limit: position_limit,
                     heartbeats_remaining: heartbeats_remaining, total_heartbeats: total_heartbeats,
                     heartbeat_count: heartbeat_count};
    end

    cdc_handshake #(.WIDTH($bits(readback_t))) readback_cdc (
        .src_clk(clk), .src_rst(rst), .src_send(1'b1), .src_data(snapshot), .src_busy(),
        .dst_clk(cpu_clk), .dst_rst(cpu_rst), .dst_valid(), .dst_data(mirror));
    assign log_visible = mirror.log_written;

    // =============================================================================================
    // CPU side (cpu_clk)
    // =============================================================================================
    wire        commit_access  = cpu_we && cpu_addr == 10'h004;
    wire        resync_access  = cpu_we && cpu_addr == 10'h01C && cpu_wdata[0];
    wire        bank_write     = cpu_we && cpu_addr >= 10'h100 && cpu_addr < 10'(10'h100 + 4 * BANK_WORDS);
    wire [6:0]  bank_word      = 7'((cpu_addr - 10'h100) >> 2);
    assign      log_pop        = cpu_re && cpu_addr == 10'h010;

    // ---- commands: the latest COMMIT and any RESYNC wait here until the channel is free
    logic        commit_waiting, resync_waiting;
    logic [15:0] epoch_waiting;
    logic [7:0]  resyncs_sent;
    logic        resync_busy_cpu;
    assign command_send = (commit_waiting || resync_waiting) && !command_busy;
    assign command_out  = '{commit: commit_waiting, resync: resync_waiting, epoch: epoch_waiting};
    // busy from the write until the snapshot shows the RESYNC taken, then as the accelerator says
    assign resync_busy_cpu = resync_waiting || resyncs_sent != mirror.resyncs_applied || mirror.resync_busy;

    always_ff @(posedge cpu_clk) begin
        if (cpu_rst) begin
            commit_waiting <= 1'b0; resync_waiting <= 1'b0; epoch_waiting <= '0; resyncs_sent <= '0;
            for (int i = 0; i < BANK_WORDS; i++) shadow_bank[i] <= '0;
        end else begin
            if (command_send) begin
                commit_waiting <= 1'b0;
                resync_waiting <= 1'b0;
                if (resync_waiting) resyncs_sent <= resyncs_sent + 8'd1;
            end
            if (commit_access) begin
                commit_waiting <= 1'b1;
                epoch_waiting  <= cpu_wdata[15:0];
            end
            if (resync_access) resync_waiting <= 1'b1;

            // ---- the CPU writes the shadow bank
            if (bank_write) begin
                if (int'(bank_word) < WORD_SIZE_BID) shadow_bank[bank_word] <= 24'(cpu_wdata);          // Q8 fields
                else                                 shadow_bank[bank_word] <= {16'd0, cpu_wdata[7:0]}; // sizes
            end
        end
    end

    // ---- register reads: one cycle after cpu_re (LOG_DATA pops)
    always_ff @(posedge cpu_clk) begin
        if (cpu_re) begin
            unique case (cpu_addr)
                10'h000: cpu_rdata <= {mirror.active_epoch, 7'd0, resync_busy_cpu, mirror.log_overflow,
                                       mirror.active_valid, mirror.halt_reason, mirror.halted, mirror.session_state};
                10'h008: cpu_rdata <= 32'(mirror.missed_commits);
                10'h00C: cpu_rdata <= 32'(mirror.stale_commits);
                10'h010: cpu_rdata <= log_head_valid ? log_head : 32'd0;
                10'h014: cpu_rdata <= 32'(log_count);
                10'h018: cpu_rdata <= 32'(mirror.log_overflow);
                10'h01C: cpu_rdata <= 32'(resync_busy_cpu);
                10'h020: cpu_rdata <= mirror.best_bid;
                10'h024: cpu_rdata <= mirror.best_ask;
                10'h028: cpu_rdata <= 32'($signed(mirror.inventory));                     // sign-extended
                10'h02C: cpu_rdata <= mirror.cash[31:0];
                10'h030: cpu_rdata <= {{24{mirror.cash[39]}}, mirror.cash[39:32]};
                10'h034: cpu_rdata <= {8'd0, mirror.max_msgs_per_heartbeat, mirror.max_order_qty, mirror.position_limit};
                10'h038: cpu_rdata <= {mirror.heartbeats_remaining, mirror.total_heartbeats};
                10'h03C: cpu_rdata <= 32'(mirror.heartbeat_count);
                default: cpu_rdata <= 32'd0;
            endcase
        end
    end
endmodule
