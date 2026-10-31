`default_nettype none
// accel_core: decision accelerator top level
//   RX -> msg_ingress -> accel_ctrl -+-> book_side x2 (bid, ask)
//                                    +-> quote_mgr -> order_state -> msg_egress -> TX
//                                    +-> cpu_if (bank, delta log, registers) <-> CPU (cpu_clk)
module accel_core #(
    parameter int BUS_BYTES           = 8,           // stream width in bytes: 1, 2, 4 or 8 (1 on the board)
    parameter int HARD_POSITION_LIMIT = 10,
    parameter int MAX_ORDER_QTY       = 10,
    parameter int QMAX                = 10
) (
    input  wire logic                     clk,
    input  wire logic                     rst,
    input  wire logic [4:0]               pid,            // our participant id (board switches)
    input  wire logic                     kill,           // local kill pulse: halt trading

    // RX / TX: the Ethernet interface's byte port on the board
    input  wire logic [8*BUS_BYTES-1:0]   rx_tdata,
    input  wire logic                     rx_tvalid,
    input  wire logic                     rx_tlast,
    output logic                     rx_tready,
    output logic [8*BUS_BYTES-1:0]   tx_tdata,
    output logic                     tx_tvalid,
    input  wire logic                     tx_tready,
    output logic                     tx_end,         // one cycle: the response is complete

    // the CPU's memory-mapped port (cpu_if's register map), on the CPU's clock
    input  wire logic                     cpu_clk,
    input  wire logic                     cpu_rst,
    input  wire logic [9:0]               cpu_addr,
    input  wire logic [31:0]              cpu_wdata,
    input  wire logic                     cpu_we,
    input  wire logic                     cpu_re,
    output logic [31:0]              cpu_rdata
);
    // ---------------- nets

    // msg_ingress -> accel_ctrl
    logic [63:0] msg_data;   logic [1:0] msg_class;
    logic        msg_valid, msg_ready;

    // accel_ctrl
    logic        clear, targets_clear;
    logic [1:0]  book_update_start, book_update_done;
    logic [13:0] book_level_px;   logic [15:0] book_level_qty;
    logic        quote_start, quote_done;
    logic        report_start, update_orders_start, cancel_all_start, rate_window_reset;
    logic [3:0]  report_type;   logic [23:0] report_order_id;   logic [7:0] report_qty;
    logic [7:0]  position_limit, max_order_qty, max_msgs_per_heartbeat;
    logic        ctrl_log_write_valid;   logic [31:0] ctrl_log_write_data;
    logic        heartbeat_pulse;   logic [15:0] heartbeat_count;
    logic [1:0]  session_state;   logic halted;   logic [2:0] halt_reason;
    logic [15:0] total_heartbeats, heartbeats_remaining;
    logic        resync_request, resync_start, resync_busy, resync_done;

    // book_side x2: index 0 = bid, 1 = ask
    logic        best_valid [2];   logic [13:0] best_px [2];   logic [15:0] best_qty [2];
    logic        second_valid [2]; logic [13:0] second_px [2];
    logic [255:0] word_nonempty [2];
    logic [63:0] occupancy_read_data [2];
    logic        qty_read_start [2], qty_read_done [2];   logic [13:0] book_read_key;
    logic [15:0] qty_read_data [2];

    // quote_mgr
    logic [4:0]  bank_row;
    logic signed [23:0] bank_skew_q8, bank_half_spread_bid_q8, bank_half_spread_ask_q8;
    logic [7:0]  bank_size_bid, bank_size_ask;
    logic [13:0] tgt_bid_px, tgt_ask_px;   logic [7:0] tgt_bid_sz, tgt_ask_sz;

    // order_state
    logic        order_state_done, generation_wrap, cancel_all_sent;
    logic signed [15:0] inventory;   logic signed [39:0] cash;
    logic [2:0]  our_order_state [2];
    logic [13:0] live_px [2];   logic [15:0] live_leaves [2];
    logic        enqueue_valid;   logic [63:0] enqueue_msg;

    // msg_egress
    logic        egress_room;

    // response_closer
    logic        ingress_idle, ctrl_idle, order_state_idle, egress_idle, core_quiescent;

    // book_resync
    logic        resync_log_write_valid, log_overflow_clear;   logic [31:0] resync_log_write_data;

    // cpu_if
    logic        log_push_valid, log_full;
    logic [31:0] log_push_data;

    // ---------------- blocks ---------------- // 
    response_closer closer (.clk, .rst, .rx_done(rx_tvalid && rx_tready && rx_tlast), .core_quiescent, .tx_end);

    // nothing left to do or send for the frames received so far
    assign core_quiescent = ingress_idle && ctrl_idle && order_state_idle && egress_idle
                            && !resync_request && !resync_busy;

    msg_ingress #(.BUS_BYTES(BUS_BYTES)) ingress (
        .clk, .rst, .pid, .rx_tdata, .rx_tvalid, .rx_tlast, .rx_tready,
        .msg_data, .msg_class, .msg_valid, .msg_ready, .idle(ingress_idle));

    accel_ctrl #(.HARD_POSITION_LIMIT(HARD_POSITION_LIMIT), .MAX_ORDER_QTY(MAX_ORDER_QTY)) ctrl (
        .clk, .rst, .kill, .msg_data, .msg_class, .msg_valid, .msg_ready,
        .clear, .targets_clear,
        .book_update_start, .book_level_px, .book_level_qty, .book_update_done,
        .quote_start, .quote_done,
        .report_start, .report_type, .report_order_id, .report_qty, .update_orders_start, .cancel_all_start,
        .rate_window_reset, .position_limit, .max_order_qty, .max_msgs_per_heartbeat,
        .order_state_done, .generation_wrap, .cancel_all_sent, .egress_room,
        .log_write_valid(ctrl_log_write_valid), .log_write_data(ctrl_log_write_data),
        .heartbeat_pulse, .heartbeat_count, .resync_request,
        .resync_start, .resync_busy, .resync_done,
        .session_state, .halted, .halt_reason, .total_heartbeats, .heartbeats_remaining,
        .idle(ctrl_idle));

    for (genvar s = 0; s < 2; s++) begin : books
        book_side #(.SIDE(s)) book (
            .clk, .rst, .clear, .start(book_update_start[s]), .level_px(book_level_px), .level_qty(book_level_qty),
            .done(book_update_done[s]), .best_valid(best_valid[s]), .best_px(best_px[s]), .best_qty(best_qty[s]),
            .second_valid(second_valid[s]), .second_px(second_px[s]),
            .word_nonempty(word_nonempty[s]),
            .read_key(book_read_key), .occupancy_read_data(occupancy_read_data[s]),
            .qty_read_start(qty_read_start[s]), .qty_read_done(qty_read_done[s]),
            .qty_read_data(qty_read_data[s]));
    end

    quote_mgr #(.QMAX(QMAX)) quotes (
        .clk, .rst, .start(quote_start), .clear, .targets_clear,
        .bid_best_valid(best_valid[0]), .bid_best_px(best_px[0]), .bid_best_qty(best_qty[0]),
        .bid_second_valid(second_valid[0]), .bid_second_px(second_px[0]),
        .ask_best_valid(best_valid[1]), .ask_best_px(best_px[1]), .ask_best_qty(best_qty[1]),
        .ask_second_valid(second_valid[1]), .ask_second_px(second_px[1]),
        .bid_order_state(our_order_state[0]), .bid_live_px(live_px[0]), .bid_live_leaves(live_leaves[0]),
        .ask_order_state(our_order_state[1]), .ask_live_px(live_px[1]), .ask_live_leaves(live_leaves[1]),
        .inventory, .bank_row, .bank_skew_q8, .bank_size_bid, .bank_size_ask,
        .bank_half_spread_bid_q8, .bank_half_spread_ask_q8,
        .tgt_bid_px, .tgt_bid_sz, .tgt_ask_px, .tgt_ask_sz,
        .book_ok(), .reference_mid_q8(), .reservation_price_q8(), .done(quote_done));

    order_state orders (
        .clk, .rst, .pid, .clear, .rate_window_reset,
        .report_start, .report_type, .report_order_id, .report_qty,
        .update_orders_start, .cancel_all_start, .tgt_bid_px, .tgt_bid_sz, .tgt_ask_px, .tgt_ask_sz,
        .position_limit, .max_msgs_per_heartbeat,
        .done(order_state_done), .generation_wrap, .cancel_all_sent, .inventory, .cash,
        .our_order_state, .live_px, .live_leaves, .enqueue_valid, .enqueue_msg, .idle(order_state_idle));

    msg_egress #(.BUS_BYTES(BUS_BYTES)) egress (
        .clk, .rst, .clear, .enqueue_valid, .enqueue_msg, .room(egress_room),
        .tx_tdata, .tx_tvalid, .tx_tlast(), .tx_tready,
        .idle(egress_idle));

    // the delta log's one push port: book_resync while it runs, else accel_ctrl
    assign log_push_valid = resync_busy ? resync_log_write_valid : ctrl_log_write_valid;
    assign log_push_data  = resync_busy ? resync_log_write_data  : ctrl_log_write_data;

    cpu_if #(.QMAX(QMAX)) cpu (
        .clk, .rst, .clear, .log_push_valid, .log_push_data, .log_full, .log_overflow_clear,
        .heartbeat_pulse, .heartbeat_count,
        .session_state, .halted, .halt_reason, .total_heartbeats, .heartbeats_remaining,
        .position_limit, .max_order_qty, .max_msgs_per_heartbeat, .resync_request, .resync_busy,
        .bid_best_valid(best_valid[0]), .bid_best_px(best_px[0]), .bid_best_qty(best_qty[0]),
        .ask_best_valid(best_valid[1]), .ask_best_px(best_px[1]), .ask_best_qty(best_qty[1]),
        .inventory, .cash,
        .bank_row, .bank_skew_q8, .bank_size_bid, .bank_size_ask, .bank_half_spread_bid_q8, .bank_half_spread_ask_q8,
        .cpu_clk, .cpu_rst, .cpu_addr, .cpu_wdata, .cpu_we, .cpu_re, .cpu_rdata);

    book_resync resync (
        .clk, .rst, .start(resync_start), .done(resync_done), .heartbeat_count,
        .bid_word_nonempty(word_nonempty[0]), .ask_word_nonempty(word_nonempty[1]),
        .read_key(book_read_key),
        .bid_occupancy_read_data(occupancy_read_data[0]), .ask_occupancy_read_data(occupancy_read_data[1]),
        .bid_qty_read_start(qty_read_start[0]), .ask_qty_read_start(qty_read_start[1]),
        .bid_qty_read_done(qty_read_done[0]), .bid_qty_read_data(qty_read_data[0]),
        .ask_qty_read_done(qty_read_done[1]), .ask_qty_read_data(qty_read_data[1]),
        .log_full, .log_write_valid(resync_log_write_valid), .log_write_data(resync_log_write_data),
        .log_overflow_clear);

endmodule
