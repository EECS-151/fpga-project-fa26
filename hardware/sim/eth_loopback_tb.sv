`timescale 1ns/10ps
`include "mem_path.vh"

// Runs software/eth_loopback on the CPU, connected to the Ethernet interface's simulation model
// (sim_models/eth_seal_sim.sv). The testbench plays the exchange: it sends inbound frames and
// collects the response frames, then checks that each response is the echoed payload,
// zero-padded to whole 8-byte messages and followed by an END message and an 8-byte trailer.
module eth_loopback_tb();
  parameter CPU_CLOCK_PERIOD = 10;               // 100 MHz
  parameter CPU_CLOCK_FREQ   = 1_000_000_000 / CPU_CLOCK_PERIOD;

  localparam NUM_FRAMES    = 4;
  localparam TIMEOUT_CYCLE = 200_000;

  reg clk = 0, rst;
  always #(CPU_CLOCK_PERIOD/2) clk = ~clk;

  // CPU <-> Ethernet interface
  wire [7:0] eth_rx_data, eth_tx_data;
  wire       eth_rx_valid, eth_rx_last, eth_rx_ready;
  wire       eth_tx_valid, eth_tx_ready, eth_tx_end, eth_link_up;

  eth_seal eth (
    .CLK_100_P(1'b0), .CLK_100_N(1'b1), .eth_reset_n(), .eth_ref_clk(1'b0), .eth_crs_dv(1'b0),
    .eth_rxd0(1'b0), .eth_rxd1(1'b0), .eth_tx_en(), .eth_txd0(), .eth_txd1(), .board_id(5'd0), .clk_100(),
    .clk(clk), .rst(rst),
    .rx_data(eth_rx_data), .rx_valid(eth_rx_valid), .rx_last(eth_rx_last), .rx_ready(eth_rx_ready),
    .tx_data(eth_tx_data), .tx_valid(eth_tx_valid), .tx_ready(eth_tx_ready), .tx_end(eth_tx_end),
    .link_up(eth_link_up)
  );

  cpu # (
    .CPU_CLOCK_FREQ(CPU_CLOCK_FREQ),
    .RESET_PC(32'h1000_0000)
  ) cpu (
    .clk(clk),
    .rst(rst),
    .system_clk(clk),
    .serial_in(1'b1),
    .serial_out(),
    .eth_rx_data(eth_rx_data), .eth_rx_valid(eth_rx_valid), .eth_rx_last(eth_rx_last), .eth_rx_ready(eth_rx_ready),
    .eth_tx_data(eth_tx_data), .eth_tx_valid(eth_tx_valid), .eth_tx_ready(eth_tx_ready), .eth_tx_end(eth_tx_end),
    .eth_link_up(eth_link_up),
    .errors()
  );

  // ---- inbound frames ----
  // 0: 46 bytes (not a whole number of messages: exercises the padding)
  // 1: a SESSION_START (type 0x1) first message: the END sequence number restarts at 0
  // 2, 3: plain frames
  localparam int FRAME_LEN [NUM_FRAMES] = '{46, 16, 24, 8};
  localparam int EXP_SEQ   [NUM_FRAMES] = '{0, 0, 1, 2};    // after the SESSION_START: 0, 1, 2
  logic [7:0] frames [NUM_FRAMES][$];

  initial begin
    for (int f = 0; f < NUM_FRAMES; f++)
      for (int i = 0; i < FRAME_LEN[f]; i++)
        frames[f].push_back(8'((f * 37 + i * 11 + 3) & 8'h0F));   // type nibble 0: not a SESSION_START
    frames[1][0] = 8'h10;                                          // SESSION_START header
  end

  // ---- checks ----
  integer num_errors = 0;

  task automatic check_response(input int fr, input logic [7:0] r [$]);
    int padded, tag, busy;
    padded = (FRAME_LEN[fr] + 7) / 8 * 8;
    if (r.size() != padded + 16) begin
      $display("FAIL frame %0d: response is %0d bytes, expected %0d (echo %0d + pad + END + trailer)",
               fr, r.size(), padded + 16, FRAME_LEN[fr]);
      num_errors++;
      return;
    end
    for (int k = 0; k < padded; k++)
      if (r[k] !== (k < FRAME_LEN[fr] ? frames[fr][k] : 8'h00)) begin
        $display("FAIL frame %0d byte %0d: got %h, expected %h", fr, k, r[k], k < FRAME_LEN[fr] ? frames[fr][k] : 8'h00);
        num_errors++;
      end
    // END = {0x72, seq, n_orders, status, tag[15:0], busy[15:0]} (2.5 ns ticks); trailer = {0x62, seq, ...}
    tag  = {r[padded + 4], r[padded + 5]};
    busy = {r[padded + 6], r[padded + 7]};
    $display("frame %0d: END seq=%0d n_orders=%0d status=%h tag=%0d busy=%0d (2.5 ns ticks)", fr,
             r[padded + 1], r[padded + 2], r[padded + 3], tag, busy);
    if (r[padded] !== 8'h72)            begin $display("FAIL frame %0d: END header %h, expected 72", fr, r[padded]); num_errors++; end
    if (r[padded + 1] !== EXP_SEQ[fr])  begin $display("FAIL frame %0d: END seq %0d, expected %0d", fr, r[padded + 1], EXP_SEQ[fr]); num_errors++; end
    if (r[padded + 2] !== padded / 8)   begin $display("FAIL frame %0d: END n_orders %0d, expected %0d", fr, r[padded + 2], padded / 8); num_errors++; end
    if (r[padded + 3] !== 8'h00)        begin $display("FAIL frame %0d: END status %h, expected 00", fr, r[padded + 3]); num_errors++; end
    if (tag == 0 || busy < tag)         begin $display("FAIL frame %0d: tag %0d / busy %0d", fr, tag, busy); num_errors++; end
    if (r[padded + 8] !== 8'h62 || r[padded + 9] !== EXP_SEQ[fr]) begin
      $display("FAIL frame %0d: trailer header %h seq %0d", fr, r[padded + 8], r[padded + 9]);
      num_errors++;
    end
  endtask

  initial begin
    logic [7:0] r [$];
    string fsdb_file;
    if (!$value$plusargs("fsdbfile+%s", fsdb_file)) begin
      fsdb_file = "default.fsdb";
    end
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, eth_loopback_tb);

    $readmemh("../../software/eth_loopback/eth_loopback.hex", `IMEM_PATH.mem, 0, 16384-1);
    $readmemh("../../software/eth_loopback/eth_loopback.hex", `DMEM_PATH.mem, 0, 16384-1);

    rst = 1;
    repeat (20) @(posedge clk);
    @(negedge clk); rst = 0;

    // All frames are queued at once: the interface offers them one at a time, each only after
    // the previous response is closed, and every frame gets exactly one response.
    for (int f = 0; f < NUM_FRAMES; f++) begin
      eth.send_frame(frames[f]);
      $display("[time %t] [exchange --> FPGA] queued frame %0d (%0d bytes)", $time, f, FRAME_LEN[f]);
    end
    for (int f = 0; f < NUM_FRAMES; f++) begin
      eth.get_response(r);
      $display("[time %t] [FPGA --> exchange] got response %0d (%0d bytes)", $time, f, r.size());
      check_response(f, r);
    end
    repeat (2000) @(posedge clk);
    if (eth.responses.size() != 0) begin $display("FAIL: %0d extra responses", eth.responses.size()); num_errors++; end

    if (num_errors > 0) $display("Test failed: %0d errors", num_errors);
    else                $display("Test passed!");
    $finish();
  end

  initial begin
    repeat (TIMEOUT_CYCLE) @(posedge clk);
    $display("Timeout!");
    $fatal();
  end
endmodule
