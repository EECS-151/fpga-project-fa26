`default_nettype none
// quote_mgr: our bid and ask targets (price, size) from the book, our position and the CPU's parameter bank.
module quote_mgr #(
    parameter int QMAX = 10                        // table rows: q = -QMAX .. +QMAX
) (
    input  wire logic               clk,
    input  wire logic               rst,
    input  wire logic               start,              // from accel_ctrl (quote_start), 1-cycle pulse
    input  wire logic               clear,              // session start: zero the targets
    input  wire logic               targets_clear,      // market close: zero the targets

    // the book (int ticks): each side's best level and the price of the level below it
    input  wire logic               bid_best_valid,
    input  wire logic        [13:0] bid_best_px,
    input  wire logic        [15:0] bid_best_qty,
    input  wire logic               bid_second_valid,
    input  wire logic        [13:0] bid_second_px,
    input  wire logic               ask_best_valid,
    input  wire logic        [13:0] ask_best_px,
    input  wire logic        [15:0] ask_best_qty,
    input  wire logic               ask_second_valid,
    input  wire logic        [13:0] ask_second_px,

    // our resting orders and position from order_state
    input  wire logic        [2:0]  bid_order_state,
    input  wire logic        [13:0] bid_live_px,
    input  wire logic        [15:0] bid_live_leaves,
    input  wire logic        [2:0]  ask_order_state,
    input  wire logic        [13:0] ask_live_px,
    input  wire logic        [15:0] ask_live_leaves,
    input  wire logic signed [15:0] inventory,

    // the CPU's active parameter bank: row out, that row's values back (combinational read)
    output logic        [4:0]  bank_row,               // 0 .. 2*QMAX = 20
    input  wire logic signed [23:0] bank_skew_q8,           // skew[row]
    input  wire logic        [7:0]  bank_size_bid,          // size_bid[row] (shares)
    input  wire logic        [7:0]  bank_size_ask,          // size_ask[row]
    input  wire logic signed [23:0] bank_half_spread_bid_q8,
    input  wire logic signed [23:0] bank_half_spread_ask_q8,

    // targets, to order_state
    output logic        [13:0] tgt_bid_px,             // 0 when tgt_bid_sz == 0
    output logic        [7:0]  tgt_bid_sz,
    output logic        [13:0] tgt_ask_px,
    output logic        [7:0]  tgt_ask_sz,
    
    // intermediate results
    output logic               book_ok,                // the book, full and reference, was usable
    output logic        [22:0] reference_mid_q8,
    output logic        [21:0] reservation_price_q8,
    output logic               done
);
    localparam logic signed [25:0] RESERVATION_MIN_Q8 = 26'sd256;       // 1.0 tick
    localparam logic signed [25:0] RESERVATION_MAX_Q8 = 26'sd4194048;   // 16383.0 ticks
    localparam logic        [2:0]  ORDER_LIVE = 3'd2, ORDER_PEND_CXL = 3'd4;  // order_state encodings

    // TODO: your implementation here
endmodule
