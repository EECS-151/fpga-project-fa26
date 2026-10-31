`timescale 1ns/10ps
`default_nettype none
`include "mem_path.vh"

// The CPU and the accelerator (accel_system, connected as in zu3top) on unrelated clocks:
// software/accel_mmio/start.s reaches the accelerator through its MMIO window (0x8001_0000) and
// leaves its results in registers, checked at each step. The testbench sends the accelerator one
// frame (a SESSION_START and two TRADEs, which only need the provided blocks) for the program to
// find in the delta log. The accel_* ports are checked too: each of the program's accesses must
// reach the accelerator exactly once, in order, with the right offset and data, and no other
// access may. A LOG_DATA read pops the log, so a read issued twice (held through a stall) or on
// a path not taken (a flushed load) loses an entry.
//   make -C ../software/accel_mmio && make sim/accel_mmio_tb.fsdb
//   +cpu_period=<ns> (default 10), +accel_period=<ns> (default 7.3)
module accel_mmio_tb;
  localparam int StepTimeout = 20_000;            // CPU cycles per step

  logic    clk = 1'b0, accel_clk = 1'b0, rst = 1'b1, accel_rst = 1'b1;
  realtime cpu_half_period = 5ns, accel_half_period = 3.65ns;
  initial begin
    real period;
    if ($value$plusargs("cpu_period=%f", period))   cpu_half_period   = period * 0.5ns;
    if ($value$plusargs("accel_period=%f", period)) accel_half_period = period * 0.5ns;
  end
  always #(cpu_half_period)   clk       = ~clk;
  always #(accel_half_period) accel_clk = ~accel_clk;
  always @(posedge accel_clk) accel_rst <= rst;

  logic [9:0]  accel_addr;
  logic [31:0] accel_wdata, accel_rdata;
  logic        accel_we, accel_re;
  logic [7:0]  rx_data = 8'd0;                    // the Ethernet interface's byte port, on accel_clk
  logic        rx_valid = 1'b0, rx_last = 1'b0, rx_ready;

  cpu #(
    .CPU_CLOCK_FREQ(100_000_000)
  ) cpu (
    .clk(clk),
    .rst(rst),
    .system_clk(clk),
    .serial_in(1'b1),
    .serial_out(),
    .eth_rx_data(8'd0),
    .eth_rx_valid(1'b0),
    .eth_rx_last(1'b0),
    .eth_rx_ready(),
    .eth_tx_data(),
    .eth_tx_valid(),
    .eth_tx_ready(1'b0),
    .eth_tx_end(),
    .eth_link_up(1'b0),
    .accel_addr(accel_addr),
    .accel_wdata(accel_wdata),
    .accel_we(accel_we),
    .accel_re(accel_re),
    .accel_rdata(accel_rdata),
    .errors()
  );

  accel_system accel (
    .clk(accel_clk),
    .rst(accel_rst),
    .pid(5'd3),
    .kill(1'b0),
    .rx_data(rx_data),
    .rx_valid(rx_valid),
    .rx_last(rx_last),
    .rx_ready(rx_ready),
    .tx_data(),
    .tx_valid(),
    .tx_ready(1'b1),
    .tx_end(),
    .cpu_clk(clk),
    .cpu_rst(rst),
    .cpu_addr(accel_addr),
    .cpu_wdata(accel_wdata),
    .cpu_we(accel_we),
    .cpu_re(accel_re),
    .cpu_rdata(accel_rdata)
  );

  // The frame, one 8-byte message each, sent first byte first:
  //   SESSION_START seq 0: 600 heartbeats, position limit 7, max order qty 5, 42 NEWs per heartbeat
  //   TRADE seq 1: side 0, px 100, qty 0x123        TRADE seq 2: side 1, px 200, qty 0x45
  localparam logic [63:0] Frame [3] = '{64'h1200_0258_0705_2A00, 64'h4001_0064_0123_0000, 64'h4102_00C8_0045_0000};

  task automatic send_frame();
    @(negedge accel_clk);
    foreach (Frame[m]) begin
      for (int b = 0; b < 8; b++) begin
        rx_data = Frame[m][63 - 8 * b -: 8];
        rx_valid = 1'b1;
        rx_last = m == $size(Frame) - 1 && b == 7;
        while (!rx_ready) @(negedge accel_clk);
        @(negedge accel_clk);                     // the handshake happened
      end
    end
    rx_valid = 1'b0;
    rx_last = 1'b0;
  endtask

  int errors = 0;
  task automatic fail(input string message);
    $display("FAIL - %s", message);
    errors++;
  endtask

  // ---- the accelerator accesses start.s makes, in order; a `poll` read repeats one or more times
  typedef struct { bit write; logic [9:0] addr; logic [31:0] data; bit poll; } access_t;
  access_t expected[$];

  function automatic void expect_read(input logic [9:0] addr, input bit poll = 1'b0);
    expected.push_back('{1'b0, addr, 'x, poll});
  endfunction
  function automatic void expect_write(input logic [9:0] addr, input logic [31:0] data);
    expected.push_back('{1'b1, addr, data, 1'b0});
  endfunction
  function automatic string describe(input bit write, input logic [9:0] addr, input logic [31:0] data);
    return write ? $sformatf("write 0x%03h <- %h", addr, data) : $sformatf("read 0x%03h", addr);
  endfunction

  initial begin
    expect_read(10'h010); expect_read(10'h014); expect_read(10'h000);                     // 1
    expect_read(10'h014, 1'b1); repeat (4) expect_read(10'h010);                          // 2
    expect_read(10'h038); expect_read(10'h034); expect_read(10'h000);
    for (int i = 0; i < 65; i++) expect_write(10'h100 + 10'(4 * i), 32'hA5C3_0000 + 32'(i));  // 3
    expect_write(10'h004, 32'd0); expect_read(10'h000, 1'b1);
    expect_write(10'h004, 32'd7); expect_read(10'h00C, 1'b1);                             // 4
    expect_read(10'h000); expect_read(10'h008);
    expect_read(10'h000); expect_read(10'h000);                                           // 5
  end

  // the accelerator samples accel_* at each rising clk, as this does; the first problem stops it
  int  accesses = 0, polls = 0;
  bit  checking = 1'b1;
  always @(posedge clk) begin
    if (!rst && checking) begin
      if ($isunknown({accel_we, accel_re})) begin
        fail($sformatf("accel_we = %b, accel_re = %b (not checking the accesses after this)", accel_we, accel_re));
        checking = 1'b0;
      end else if (accel_we && accel_re) begin
        fail($sformatf("accel_we and accel_re both high, addr 0x%03h (not checking the accesses after this)", accel_addr));
        checking = 1'b0;
      end else if (accel_we || accel_re) begin
        // a poll that has run ends at the first other access
        if (expected.size() != 0 && expected[0].poll && polls != 0 && !(accel_re && accel_addr === expected[0].addr)) begin
          void'(expected.pop_front());
          polls = 0;
        end
        if (expected.size() == 0 || accel_we != expected[0].write || accel_addr !== expected[0].addr
            || (accel_we && accel_wdata !== expected[0].data)) begin
          fail($sformatf("accelerator access %0d is %s, expected %s (not checking the accesses after this)", accesses,
                         describe(accel_we, accel_addr, accel_wdata),
                         expected.size() == 0 ? "none" : describe(expected[0].write, expected[0].addr, expected[0].data)));
          checking = 1'b0;
        end else if (expected[0].poll) polls++;
        else void'(expected.pop_front());
        accesses++;
      end
    end
  end

  task automatic check_reg(input logic [4:0] r, input logic [31:0] value, input string what);
    if (`RF_PATH.mem[r] !== value) fail($sformatf("%s: x%0d = %h, expected %h", what, r, `RF_PATH.mem[r], value));
    else $display("PASS - %s: x%0d = %h", what, r, value);
  endtask

  task automatic wait_for_step(input logic [31:0] step);
    int cycles = 0;
    while (`RF_PATH.mem[20] !== step && cycles < StepTimeout) begin @(posedge clk); cycles++; end
    if (cycles >= StepTimeout) begin
      fail($sformatf("timeout waiting for step %0d (x20 = %h; %0d accelerator accesses so far, next expected: %s)",
                     step, `RF_PATH.mem[20], accesses,
                     expected.size() == 0 ? "none" : describe(expected[0].write, expected[0].addr, expected[0].data)));
      $display("%0d ACCEL MMIO TESTS FAILED", errors);
      $finish();
    end
  endtask

  initial begin
    string fsdb_file;
    int fd;
    if (!$value$plusargs("fsdbfile+%s", fsdb_file)) begin
      fsdb_file = "default.fsdb";
    end
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, accel_mmio_tb);

    fd = $fopen("../../software/accel_mmio/accel_mmio.hex", "r");
    if (fd == 0) $fatal(1, "no software/accel_mmio/accel_mmio.hex: build it with make -C ../software/accel_mmio");
    $fclose(fd);
    $readmemh("../../software/accel_mmio/accel_mmio.hex", `BIOS_PATH.mem, 0, 4095);

    repeat (10) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    wait_for_step(1);
    check_reg(1,  32'h0000_0000, "LOG_DATA, the log empty");
    check_reg(2,  32'h0000_0000, "LOG_COUNT, the log empty");
    check_reg(3,  32'h0000_0000, "STATUS after reset");
    send_frame();
    wait_for_step(2);
    check_reg(4,  32'h0000_0003, "LOG_COUNT after the frame");
    check_reg(5,  32'hA000_0258, "LOG_DATA: the session, 600 heartbeats");
    check_reg(6,  32'h9000_0123, "LOG_DATA right after: TRADE side 0 qty 0x123");
    check_reg(7,  32'h3000_037B, "both LOG_DATA loads used right away (x5 + x6)");
    check_reg(8,  32'h9001_0045, "LOG_DATA: TRADE side 1 qty 0x45");
    check_reg(9,  32'h0000_0000, "LOG_DATA, the log empty again");
    check_reg(14, 32'hFFFF_FFFF, "the load after j never ran");
    check_reg(10, 32'h0258_0258, "SESSION_HEARTBEATS");
    check_reg(11, 32'h002A_0507, "SESSION_LIMITS");
    check_reg(12, 32'h0000_0001, "STATUS: pre-open");
    wait_for_step(3);
    check_reg(13, 32'h0000_0041, "STATUS after COMMIT epoch 0: the bank active, epoch 0");
    wait_for_step(4);
    check_reg(15, 32'h0000_0001, "STALE_COMMITS after COMMIT epoch 7");
    check_reg(16, 32'h0000_0041, "STATUS after the stale COMMIT: still epoch 0");
    check_reg(17, 32'h0000_0000, "MISSED_COMMITS");
    wait_for_step(5);
    check_reg(18, 32'h0000_0041, "STATUS");
    check_reg(19, 32'h1357_9BDF, "DMEM right after an accelerator load");
    check_reg(21, 32'h0000_0041, "STATUS right after a DMEM load");
    check_reg(22, 32'h0000_0000, "ETH_STATUS right after an accelerator load");

    repeat (100) @(posedge clk);                  // nothing else may reach the accelerator
    if (checking && expected.size() != 0 && !(expected.size() == 1 && expected[0].poll && polls != 0))
      fail($sformatf("%0d accelerator accesses missing, the first: %s", expected.size(),
                     describe(expected[0].write, expected[0].addr, expected[0].data)));
    $display("%0d accelerator accesses checked", accesses);

    if (errors == 0) $display("ALL ACCEL MMIO TESTS PASSED!");
    else             $display("%0d ACCEL MMIO TESTS FAILED", errors);
    $finish();
  end
endmodule
