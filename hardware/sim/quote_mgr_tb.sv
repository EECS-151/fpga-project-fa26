`default_nettype none
// quote_mgr_tb: directed scenarios checked at done against expected outputs: targets, book_ok,
// reference mid and reservation price.
//   make sim/quote_mgr_tb.fsdb
module quote_mgr_tb;
  logic clk = 0, rst = 1, start = 0, clear = 0, targets_clear = 0;
  always #5 clk = ~clk;
  logic bid_best_valid, ask_best_valid; logic [13:0] bid_best_px, ask_best_px; logic [15:0] bid_best_qty, ask_best_qty;
  logic bid_second_valid, ask_second_valid; logic [13:0] bid_second_px, ask_second_px;
  logic signed [15:0] inventory;
  logic [2:0] bid_order_state, ask_order_state; logic [13:0] bid_live_px, ask_live_px;
  logic [15:0] bid_live_leaves, ask_live_leaves;
  logic [4:0] bank_row; logic signed [23:0] bank_skew_q8; logic [7:0] bank_size_bid, bank_size_ask;
  logic [13:0] tgt_bid_px, tgt_ask_px; logic [7:0] tgt_bid_sz, tgt_ask_sz; logic book_ok, done;
  logic [22:0] reference_mid_q8; logic [21:0] reservation_price_q8;
  logic [7:0] SIZE_BID [21]; logic [7:0] SIZE_ASK [21];
  initial begin
    SIZE_BID[0] = 8'd3; SIZE_BID[1] = 8'd3; SIZE_BID[2] = 8'd3; SIZE_BID[3] = 8'd3; SIZE_BID[4] = 8'd3; SIZE_BID[5] = 8'd3; SIZE_BID[6] = 8'd3; SIZE_BID[7] = 8'd3; SIZE_BID[8] = 8'd2; SIZE_BID[9] = 8'd1; SIZE_BID[10] = 8'd3; SIZE_BID[11] = 8'd1; SIZE_BID[12] = 8'd1; SIZE_BID[13] = 8'd0; SIZE_BID[14] = 8'd0; SIZE_BID[15] = 8'd0; SIZE_BID[16] = 8'd0; SIZE_BID[17] = 8'd0; SIZE_BID[18] = 8'd0; SIZE_BID[19] = 8'd0; SIZE_BID[20] = 8'd0;
    SIZE_ASK[0] = 8'd0; SIZE_ASK[1] = 8'd0; SIZE_ASK[2] = 8'd0; SIZE_ASK[3] = 8'd0; SIZE_ASK[4] = 8'd0; SIZE_ASK[5] = 8'd0; SIZE_ASK[6] = 8'd0; SIZE_ASK[7] = 8'd0; SIZE_ASK[8] = 8'd1; SIZE_ASK[9] = 8'd1; SIZE_ASK[10] = 8'd3; SIZE_ASK[11] = 8'd1; SIZE_ASK[12] = 8'd2; SIZE_ASK[13] = 8'd3; SIZE_ASK[14] = 8'd3; SIZE_ASK[15] = 8'd3; SIZE_ASK[16] = 8'd3; SIZE_ASK[17] = 8'd3; SIZE_ASK[18] = 8'd3; SIZE_ASK[19] = 8'd3; SIZE_ASK[20] = 8'd3;
  end
  // the walkthrough bank: skew = q * 479, h = 1263 (Q8)
  assign bank_skew_q8 = 24'(($signed({1'b0, bank_row}) - 6'sd10) * 479);
  assign bank_size_bid = SIZE_BID[bank_row]; assign bank_size_ask = SIZE_ASK[bank_row];
  quote_mgr dut (.clk, .rst, .start, .clear, .targets_clear,
    .bid_best_valid, .bid_best_px, .bid_best_qty, .bid_second_valid, .bid_second_px,
    .ask_best_valid, .ask_best_px, .ask_best_qty, .ask_second_valid, .ask_second_px,
    .bid_order_state, .bid_live_px, .bid_live_leaves, .ask_order_state, .ask_live_px, .ask_live_leaves,
    .inventory, .bank_row, .bank_skew_q8, .bank_size_bid, .bank_size_ask,
    .bank_half_spread_bid_q8(24'sd1263), .bank_half_spread_ask_q8(24'sd1263),
    .tgt_bid_px, .tgt_bid_sz, .tgt_ask_px, .tgt_ask_sz, .book_ok, .reference_mid_q8, .reservation_price_q8, .done);
  localparam int TIMEOUT = 1000;   // cycles to wait for done
  int fails = 0, cycles, mid, r;
  task automatic run(string name, int ebpx, int ebsz, int eapx, int easz, int eok, int emid, int er);
    @(negedge clk) start = 1; @(negedge clk) start = 0; cycles = 1;
    while (done !== 1'b1 && cycles < TIMEOUT) begin @(negedge clk); cycles++; end
    if (done !== 1'b1) begin
      $display("FAIL %s: no done within %0d cycles", name, TIMEOUT);
      fails++;
      return;
    end
    mid = book_ok ? int'(reference_mid_q8) : 0; r = book_ok ? int'(reservation_price_q8) : 0;
    if (tgt_bid_px !== ebpx || tgt_bid_sz !== ebsz || tgt_ask_px !== eapx || tgt_ask_sz !== easz
        || book_ok !== eok || mid !== emid || r !== er) begin
      $display("FAIL %s: got %0d x %0d / %0d x %0d ok %0d mid %0d r %0d; want %0d x %0d / %0d x %0d ok %0d mid %0d r %0d",
               name, tgt_bid_px, tgt_bid_sz, tgt_ask_px, tgt_ask_sz, book_ok, mid, r, ebpx, ebsz, eapx, easz, eok, emid, er);
      fails++;
    end else $display("pass %s: %0d x %0d / %0d x %0d, mid %0d/256, %0d cycles", name, tgt_bid_px, tgt_bid_sz, tgt_ask_px, tgt_ask_sz, mid, cycles);
  endtask
  initial begin
    string fsdb_file;
    if (!$value$plusargs("fsdbfile+%s", fsdb_file)) begin
      fsdb_file = "default.fsdb";
    end
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, quote_mgr_tb);
    repeat (2) @(negedge clk); rst = 0;
    // doc example 1
    bid_best_px = 5000; bid_best_valid = 1; bid_best_qty = 10; bid_second_px = 0; bid_second_valid = 0;
    ask_best_px = 5003; ask_best_valid = 1; ask_best_qty = 10; ask_second_px = 0; ask_second_valid = 0; inventory = 2;
    bid_order_state = 0; bid_live_px = 0; bid_live_leaves = 0; ask_order_state = 0; ask_live_px = 0; ask_live_leaves = 0;
    run("doc example 1", 4992, 1, 5003, 2, 1, 1280384, 1279426);
    // our bid is the whole best level
    bid_best_px = 5003; bid_best_valid = 1; bid_best_qty = 2; bid_second_px = 5000; bid_second_valid = 1;
    ask_best_px = 5010; ask_best_valid = 1; ask_best_qty = 10; ask_second_px = 0; ask_second_valid = 0; inventory = -2;
    bid_order_state = 2; bid_live_px = 5003; bid_live_leaves = 2; ask_order_state = 0; ask_live_px = 0; ask_live_leaves = 0;
    run("our bid is the whole best level", 5003, 2, 5014, 1, 1, 1281280, 1282238);
    // someone joined our bid
    bid_best_px = 5003; bid_best_valid = 1; bid_best_qty = 7; bid_second_px = 5000; bid_second_valid = 1;
    ask_best_px = 5010; ask_best_valid = 1; ask_best_qty = 10; ask_second_px = 0; ask_second_valid = 0; inventory = -2;
    bid_order_state = 2; bid_live_px = 5003; bid_live_leaves = 2; ask_order_state = 0; ask_live_px = 0; ask_live_leaves = 0;
    run("someone joined our bid", 5005, 2, 5016, 1, 1, 1281664, 1282622);
    // only our bid on its side
    bid_best_px = 5003; bid_best_valid = 1; bid_best_qty = 2; bid_second_px = 0; bid_second_valid = 0;
    ask_best_px = 5010; ask_best_valid = 1; ask_best_qty = 10; ask_second_px = 0; ask_second_valid = 0; inventory = -2;
    bid_order_state = 2; bid_live_px = 5003; bid_live_leaves = 2; ask_order_state = 0; ask_live_px = 0; ask_live_leaves = 0;
    run("only our bid on its side", 0, 0, 0, 0, 0, 0, 0);
    // only our bid on its side, ask ours too
    bid_best_px = 5003; bid_best_valid = 1; bid_best_qty = 2; bid_second_px = 0; bid_second_valid = 0;
    ask_best_px = 5006; ask_best_valid = 1; ask_best_qty = 1; ask_second_px = 5200; ask_second_valid = 1; inventory = 0;
    bid_order_state = 2; bid_live_px = 5003; bid_live_leaves = 2; ask_order_state = 2; ask_live_px = 5006; ask_live_leaves = 1;
    run("only our bid on its side, ask ours too", 0, 0, 0, 0, 0, 0, 0);
    // both best levels ours, clamp
    bid_best_px = 5003; bid_best_valid = 1; bid_best_qty = 2; bid_second_px = 4900; bid_second_valid = 1;
    ask_best_px = 5006; ask_best_valid = 1; ask_best_qty = 1; ask_second_px = 5200; ask_second_valid = 1; inventory = 0;
    bid_order_state = 2; bid_live_px = 5003; bid_live_leaves = 2; ask_order_state = 2; ask_live_px = 5006; ask_live_leaves = 1;
    run("both best levels ours, clamp", 5005, 3, 5055, 3, 1, 1292800, 1292800);
    // our ask PEND_CXL is the whole level
    bid_best_px = 5000; bid_best_valid = 1; bid_best_qty = 10; bid_second_px = 0; bid_second_valid = 0;
    ask_best_px = 5006; ask_best_valid = 1; ask_best_qty = 2; ask_second_px = 5008; ask_second_valid = 1; inventory = 1;
    bid_order_state = 0; bid_live_px = 0; bid_live_leaves = 0; ask_order_state = 4; ask_live_px = 5006; ask_live_leaves = 2;
    run("our ask PEND_CXL is the whole level", 4997, 1, 5008, 1, 1, 1281024, 1280545);
    // bid PEND_NEW is not in the book
    bid_best_px = 5003; bid_best_valid = 1; bid_best_qty = 2; bid_second_px = 5000; bid_second_valid = 1;
    ask_best_px = 5010; ask_best_valid = 1; ask_best_qty = 10; ask_second_px = 0; ask_second_valid = 0; inventory = -2;
    bid_order_state = 1; bid_live_px = 0; bid_live_leaves = 0; ask_order_state = 0; ask_live_px = 0; ask_live_leaves = 0;
    run("bid PEND_NEW is not in the book", 5005, 2, 5016, 1, 1, 1281664, 1282622);
    // level smaller than our leaves
    bid_best_px = 5003; bid_best_valid = 1; bid_best_qty = 1; bid_second_px = 5000; bid_second_valid = 1;
    ask_best_px = 5010; ask_best_valid = 1; ask_best_qty = 10; ask_second_px = 0; ask_second_valid = 0; inventory = -2;
    bid_order_state = 2; bid_live_px = 5003; bid_live_leaves = 2; ask_order_state = 0; ask_live_px = 0; ask_live_leaves = 0;
    run("level smaller than our leaves", 5003, 2, 5014, 1, 1, 1281280, 1282238);
    // one-sided book
    bid_best_px = 5000; bid_best_valid = 1; bid_best_qty = 10; bid_second_px = 0; bid_second_valid = 0;
    ask_best_px = 0; ask_best_valid = 0; ask_best_qty = 0; ask_second_px = 0; ask_second_valid = 0; inventory = 0;
    bid_order_state = 0; bid_live_px = 0; bid_live_leaves = 0; ask_order_state = 0; ask_live_px = 0; ask_live_leaves = 0;
    run("one-sided book", 0, 0, 0, 0, 0, 0, 0);
    // our ask alone at top, far next level
    bid_best_px = 5000; bid_best_valid = 1; bid_best_qty = 10; bid_second_px = 0; bid_second_valid = 0;
    ask_best_px = 5001; ask_best_valid = 1; ask_best_qty = 3; ask_second_px = 9000; ask_second_valid = 1; inventory = 3;
    bid_order_state = 0; bid_live_px = 0; bid_live_leaves = 0; ask_order_state = 2; ask_live_px = 5001; ask_live_leaves = 3;
    run("our ask alone at top, far next level", 0, 0, 7000, 3, 1, 1792000, 1790563);
    // our bid live below the best
    bid_best_px = 5003; bid_best_valid = 1; bid_best_qty = 4; bid_second_px = 5000; bid_second_valid = 1;
    ask_best_px = 5010; ask_best_valid = 1; ask_best_qty = 10; ask_second_px = 0; ask_second_valid = 0; inventory = 0;
    bid_order_state = 2; bid_live_px = 5000; bid_live_leaves = 10; ask_order_state = 0; ask_live_px = 0; ask_live_leaves = 0;
    run("our bid live below the best", 5001, 3, 5012, 3, 1, 1281664, 1281664);
    if (fails == 0) $display("PASS (12 scenarios)"); else $display("FAILED (%0d)", fails);
    $finish;
  end
endmodule
