`default_nettype none
// accel_ctrl: takes one message at a time (msg_ready is high only in IDLE)
// and finishes its work before taking the next. Public messages in a session are also logged.
//   SESSION_START   latch the session parameters and clear every block
//   HEARTBEAT       advance the heartbeat counters; the first opens the market, the last closes
//                   it; quote if open
//   BOOK_UPDATE     update book_side; quote on EOE
//   TRADE           log only
//   private report  order_state applies it; quote on EOE
// A malformed message, sequence gap, kill or generation wrap halts. sends a CANCEL_ALL
// A RESYNC request from the CPU pauses trading between events while book_resync runs
module accel_ctrl #(
    parameter int HARD_POSITION_LIMIT = 10,           // effective limit = min(this, the session's)
    parameter int MAX_ORDER_QTY       = 10
) (
    input  wire logic        clk,
    input  wire logic        rst,
    input  wire logic        kill,                         // local kill pulse

    // from msg_ingress
    input  wire logic [63:0] msg_data,
    input  wire logic [1:0]  msg_class,                    // 0 public, 1 our private report, 2 foreign, 3 malformed
    input  wire logic        msg_valid,
    output logic        msg_ready,

    // to every block that holds session state
    output logic        clear,                        // session start
    output logic        targets_clear,                // market close: quote_mgr zeroes its targets

    // book_side x2
    output logic [1:0]  book_update_start,
    output logic [13:0] book_level_px,
    output logic [15:0] book_level_qty,
    input  wire logic [1:0]  book_update_done,

    // quote_mgr
    output logic        quote_start,
    input  wire logic        quote_done,

    // order_state
    output logic        report_start,
    output logic [3:0]  report_type,
    output logic [23:0] report_order_id,
    output logic [7:0]  report_qty,
    output logic        update_orders_start,
    output logic        cancel_all_start,
    output logic        rate_window_reset,
    output logic [7:0]  position_limit,
    output logic [7:0]  max_order_qty,
    output logic [7:0]  max_msgs_per_heartbeat,
    input  wire logic        order_state_done,
    input  wire logic        generation_wrap,
    input  wire logic        cancel_all_sent,

    input  wire logic        egress_room,                  // msg_egress can take one event's messages

    // cpu_if
    output logic        log_write_valid,
    output logic [31:0] log_write_data,
    output logic        heartbeat_pulse,
    output logic [15:0] heartbeat_count,
    input  wire logic        resync_request,               // the CPU wrote RESYNC

    // book_resync
    output logic        resync_start,
    output logic        resync_busy,
    input  wire logic        resync_done,

    // session state (cpu_if readback)
    output logic [1:0]  session_state,                // 0 no session, 1 pre-open, 2 open, 3 closed
    output logic        halted,
    output logic [2:0]  halt_reason,
    output logic [15:0] total_heartbeats,
    output logic [15:0] heartbeats_remaining,

    output logic        idle                          // between events, nothing pending (response_closer)
);
    localparam logic [1:0] CLASS_PUBLIC = 2'd0, CLASS_FOREIGN = 2'd2, CLASS_MALFORMED = 2'd3;
    localparam logic [1:0] SESSION_IDLE = 2'd0, SESSION_PREOPEN = 2'd1, SESSION_OPEN = 2'd2, SESSION_CLOSED = 2'd3;
    localparam logic [2:0] HALT_NONE = 3'd0, HALT_GAP_PUBLIC = 3'd1, HALT_GAP_PRIVATE = 3'd2, HALT_BAD_MSG = 3'd3,
                           HALT_KILL = 3'd4, HALT_GENERATION_WRAP = 3'd6;
    localparam logic [3:0] TYPE_SESSION_START = 4'h1, TYPE_HEARTBEAT = 4'h2, TYPE_BOOK_UPDATE = 4'h3, TYPE_TRADE = 4'h4;

    typedef enum logic [3:0] {
        IDLE                        = 4'd0,
        CHECK_MSG                   = 4'd1,   // classify, sequence check, session transitions, start a block
        LOG_SESSION                 = 4'd2,   // session start: log the session entry after the clear
        WAIT_BOOK                   = 4'd3,
        WAIT_REPORT                 = 4'd4,
        WAIT_BANK_SWAP              = 4'd5,   // cpu_if swaps the bank this cycle; log close if it ended
        DECIDE_QUOTE                = 4'd6,   // halted -> CANCEL_ALL; quote requested and open -> quote
        WAIT_QUOTE                  = 4'd7,
        WAIT_ROOM_FOR_UPDATE_ORDERS = 4'd8,   // egress has room for the event's messages -> order_state
        WAIT_UPDATE_ORDERS          = 4'd9,   // order_state sends NEW/CANCEL to match the targets
        WAIT_ROOM_FOR_CANCEL_ALL    = 4'd10,
        WAIT_CANCEL_ALL             = 4'd11,
        END_EVENT                   = 4'd12,
        RESYNC                      = 4'd13   // trading paused while book_resync runs
    } phase_t;
    phase_t phase;

    logic [63:0] held_msg;
    logic [1:0]  held_msg_class;
    logic        kill_pending;
    logic        have_session;
    logic [7:0]  expected_public_seq, expected_private_seq;
    logic        close_log_pending;
    logic        quote_requested;

    assign idle = phase == IDLE && !kill_pending && !log_write_valid;

    // fields of the held message (all messages put them in the same place)
    wire [3:0]  held_type  = held_msg[63:60];
    wire        held_eoe   = held_msg[57];
    wire        held_side  = held_msg[56];
    wire [7:0]  held_seq   = held_msg[55:48];
    assign book_level_px   = held_msg[45:32];        // BOOK_UPDATE (ingress checked it is 1..16383)
    assign book_level_qty  = held_msg[31:16];
    assign report_type     = held_msg[63:60];
    assign report_order_id = held_msg[47:24];
    assign report_qty      = held_msg[23:16];
    wire [15:0] trade_qty = held_msg[31:16];          // TRADE (its side is held_side)

    // delta-log entries
    function automatic logic [31:0] log_book(input logic side, input logic [13:0] px, input logic [15:0] qty);
        return {1'b0, side, px, qty};
    endfunction
    function automatic logic [31:0] log_other(input logic [2:0] kind, input logic [27:0] payload);
        return {1'b1, kind, payload};
    endfunction
    localparam logic [2:0] LOG_MARKER = 3'd0, LOG_TRADE = 3'd1, LOG_SESSION_KIND = 3'd2, LOG_CLOSE = 3'd3;

    task automatic halt(input logic [2:0] reason);
        if (!halted) begin halted <= 1'b1; halt_reason <= reason; end
    endtask

    task automatic begin_event(input phase_t next_phase);
        quote_requested <= 1'b0;
        msg_ready       <= 1'b0;
        phase           <= next_phase;
    endtask

    always_ff @(posedge clk) begin
        // one-cycle pulses
        book_update_start <= '0; report_start <= 1'b0; update_orders_start <= 1'b0; cancel_all_start <= 1'b0;
        rate_window_reset <= 1'b0; quote_start <= 1'b0; clear <= 1'b0; targets_clear <= 1'b0;
        heartbeat_pulse <= 1'b0; log_write_valid <= 1'b0; resync_start <= 1'b0;

        if (rst) begin
            phase <= IDLE; msg_ready <= 1'b1; kill_pending <= 1'b0;
            have_session <= 1'b0; session_state <= SESSION_IDLE; halted <= 1'b0; halt_reason <= HALT_NONE;
            expected_public_seq <= '0; expected_private_seq <= '0;
            total_heartbeats <= '0; heartbeats_remaining <= '0; heartbeat_count <= '0;
            position_limit <= '0; max_order_qty <= '0; max_msgs_per_heartbeat <= '0; close_log_pending <= 1'b0;
            quote_requested <= 1'b0; log_write_data <= '0; resync_busy <= 1'b0;
        end else begin
            if (kill) kill_pending <= 1'b1;

            unique case (phase)
                IDLE: begin
                    if (msg_valid && msg_ready) begin                              // take the message
                        held_msg       <= msg_data;
                        held_msg_class <= msg_class;
                        begin_event(CHECK_MSG);
                    end else if (kill_pending) begin                                // a kill pseudo-event
                        kill_pending <= 1'b0;
                        if (have_session) halt(HALT_KILL);
                        begin_event(DECIDE_QUOTE);
                    end else if (resync_request && !kill) begin
                        resync_start <= 1'b1;
                        resync_busy  <= 1'b1;
                        msg_ready    <= 1'b0;
                        phase        <= RESYNC;
                    end
                end

                CHECK_MSG: begin
                    phase <= DECIDE_QUOTE;
                    if (held_msg_class == CLASS_MALFORMED) begin
                        if (have_session) halt(HALT_BAD_MSG);                     // before a session: ignored
                    end else if (held_msg_class == CLASS_FOREIGN || (!have_session && held_type != TYPE_SESSION_START)) begin
                        // another participant's report, or no session yet: ignored
                    end else if (held_type == TYPE_SESSION_START) begin
                        have_session  <= 1'b1;
                        session_state <= SESSION_PREOPEN;
                        halted        <= 1'b0;
                        halt_reason   <= HALT_NONE;
                        total_heartbeats     <= held_msg[47:32];               // 16 bits, as on the wire
                        heartbeats_remaining <= held_msg[47:32];
                        heartbeat_count      <= '0;
                        position_limit <= (held_msg[31:24] < 8'(HARD_POSITION_LIMIT)) ? held_msg[31:24] : 8'(HARD_POSITION_LIMIT);
                        max_order_qty  <= (held_msg[23:16] < 8'(MAX_ORDER_QTY))       ? held_msg[23:16] : 8'(MAX_ORDER_QTY);
                        max_msgs_per_heartbeat <= held_msg[15:8];
                        expected_public_seq    <= held_seq + 8'd1;
                        expected_private_seq   <= '0;
                        close_log_pending      <= 1'b0;
                        clear <= 1'b1;
                        phase <= LOG_SESSION;
                    end else begin
                        logic gap;                                         // a gap halts; the content is still applied
                        if (held_msg_class == CLASS_PUBLIC) begin
                            gap = held_seq != expected_public_seq;
                            if (gap) halt(HALT_GAP_PUBLIC);
                            expected_public_seq <= held_seq + 8'd1;
                        end else begin
                            gap = held_seq != expected_private_seq;
                            if (gap) halt(HALT_GAP_PRIVATE);
                            expected_private_seq <= held_seq + 8'd1;
                        end

                        if (held_type == TYPE_HEARTBEAT) begin
                            logic [15:0] hb;
                            logic [15:0] remaining;
                            hb        = held_msg[47:32];
                            remaining = (total_heartbeats > hb) ? total_heartbeats - hb : 16'd0;
                            heartbeat_count      <= hb;
                            heartbeats_remaining <= remaining;
                            rate_window_reset    <= 1'b1;
                            heartbeat_pulse      <= 1'b1;
                            log_write_valid <= 1'b1; log_write_data <= log_other(LOG_MARKER, 28'(hb));
                            if (remaining == 16'd0) begin                  // the horizon is exhausted: close
                                close_log_pending <= session_state != SESSION_CLOSED;
                                session_state     <= SESSION_CLOSED;
                                targets_clear     <= 1'b1;
                                quote_requested   <= 1'b0;
                            end else begin
                                if (session_state == SESSION_PREOPEN) session_state <= SESSION_OPEN;  // opens
                                quote_requested <= session_state == SESSION_PREOPEN || session_state == SESSION_OPEN;
                            end
                            phase <= WAIT_BANK_SWAP;
                        end else if (held_type == TYPE_BOOK_UPDATE) begin
                            book_update_start[held_side] <= 1'b1;
                            log_write_valid <= 1'b1; log_write_data <= log_book(held_side, book_level_px, book_level_qty);
                            quote_requested <= held_eoe;
                            phase <= WAIT_BOOK;
                        end else if (held_type == TYPE_TRADE) begin
                            log_write_valid <= 1'b1; log_write_data <= log_other(LOG_TRADE, {11'd0, held_side, trade_qty});
                        end else begin                                     // a private report
                            report_start    <= 1'b1;
                            quote_requested <= held_eoe;
                            phase <= WAIT_REPORT;
                        end
                    end
                end

                LOG_SESSION: begin                                         // the clear took effect this edge
                    log_write_valid <= 1'b1; log_write_data <= log_other(LOG_SESSION_KIND, 28'(total_heartbeats));
                    phase <= DECIDE_QUOTE;
                end

                WAIT_BOOK: if (book_update_done[held_side]) phase <= DECIDE_QUOTE;

                WAIT_REPORT: if (order_state_done) phase <= DECIDE_QUOTE;

                WAIT_BANK_SWAP: begin                                      // cpu_if swaps the bank this edge
                    if (close_log_pending) begin
                        log_write_valid <= 1'b1; log_write_data <= log_other(LOG_CLOSE, '0);
                        close_log_pending <= 1'b0;
                    end
                    phase <= DECIDE_QUOTE;
                end

                DECIDE_QUOTE: begin
                    logic active;
                    active = session_state == SESSION_PREOPEN || session_state == SESSION_OPEN;
                    if (halted) phase <= (active && !cancel_all_sent) ? WAIT_ROOM_FOR_CANCEL_ALL : END_EVENT;
                    else if (quote_requested && session_state == SESSION_OPEN) begin
                        quote_start <= 1'b1;
                        phase       <= WAIT_QUOTE;
                    end else phase <= END_EVENT;
                end

                WAIT_QUOTE: if (quote_done) phase <= WAIT_ROOM_FOR_UPDATE_ORDERS;

                WAIT_ROOM_FOR_UPDATE_ORDERS: if (egress_room) begin
                    update_orders_start <= 1'b1;
                    phase <= WAIT_UPDATE_ORDERS;
                end

                WAIT_UPDATE_ORDERS: if (order_state_done) begin
                    if (generation_wrap) begin
                        halt(HALT_GENERATION_WRAP);
                        phase <= !cancel_all_sent ? WAIT_ROOM_FOR_CANCEL_ALL : END_EVENT;
                    end else phase <= END_EVENT;
                end

                WAIT_ROOM_FOR_CANCEL_ALL: if (egress_room) begin
                    cancel_all_start <= 1'b1;
                    phase <= WAIT_CANCEL_ALL;
                end

                WAIT_CANCEL_ALL: if (order_state_done) phase <= END_EVENT;

                END_EVENT: begin
                    msg_ready <= 1'b1;
                    phase     <= IDLE;
                end

                RESYNC: if (resync_done) begin
                    resync_busy <= 1'b0;
                    msg_ready   <= 1'b1;
                    phase       <= IDLE;
                end

                default: phase <= IDLE;
            endcase
        end
    end
endmodule
