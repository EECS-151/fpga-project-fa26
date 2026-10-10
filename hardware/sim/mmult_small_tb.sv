`timescale 1ns/1ns
`include "mem_path.vh"

// A small version of the mmult test for debugging and unofficial CPI reporting

module mmult_small_tb();
  reg clk, rst;
  parameter CPU_CLOCK_PERIOD = 20;
  parameter CPU_CLOCK_FREQ   = 1_000_000_000 / CPU_CLOCK_PERIOD;

  localparam TIMEOUT_CYCLE = 1_000_000;
  localparam BAUD_RATE       = 10_000_000;
  localparam BAUD_PERIOD     = 1_000_000_000 / BAUD_RATE; // 8680.55 ns

  initial clk = 0;
  always #(CPU_CLOCK_PERIOD/2) clk = ~clk;

  reg bp_enable = 1'b0;
  wire serial_out;

  cpu # (
    .CPU_CLOCK_FREQ(CPU_CLOCK_FREQ),
    .RESET_PC(32'h1000_0000),
    .BAUD_RATE(BAUD_RATE)
  ) cpu (
    .clk(clk),
    .rst(rst),
    .system_clk(clk),
    .serial_in(1'b1), // input
    .serial_out(serial_out),     // output
    .errors()
  );

  reg [31:0] cycle;
  always @(posedge clk) begin
    if (rst === 1)
      cycle <= 0;
    else
      cycle <= cycle + 1;
  end

  reg [9:0] char_out;
  integer j;

  reg [7:0] msg_out [156:0];
  integer char_i = 0;

  integer i;

  // Host off-chip UART <-- FPGA on-chip UART (transmitter)
  // The host (testbench) expects to receive a character from the CPU via the serial line
  task fpga_to_host;
    begin
      // Wait until serial_out is LOW (start of transaction)
      wait (serial_out === 1'b0);

      for (j = 0; j < 10; j = j + 1) begin
        // sample output half-way through the baud period to avoid tricky edge cases
        #(BAUD_PERIOD / 2);
        char_out[j] = serial_out;
        #(BAUD_PERIOD / 2);
      end

      msg_out[char_i][7:0] = char_out[8:1];
      char_i = char_i + 1;
    end
  endtask

  reg [255:0] MIF_FILE;
  string output_string;
  initial begin

    $readmemh("../../software/bios/bios.hex", `BIOS_PATH.mem, 0, 4095);
    $readmemh("../../software/small/mmult/mmult.hex", `IMEM_PATH.mem, 0, 16384-1);
    $readmemh("../../software/small/mmult/mmult.hex", `DMEM_PATH.mem, 0, 16384-1);

    `ifndef IVERILOG
      $vcdpluson;
    `endif
    `ifdef IVERILOG
      $dumpfile("mmult_small.fst");
      $dumpvars(0, c_tests_tb);
    `endif

    rst = 1;

    // Hold reset for a while
    repeat (10) @(posedge clk);

    @(negedge clk);
    rst = 0;

    // Delay for some time
    repeat (1000) @(posedge clk);

    fork 

      begin
        $display("[TEST] This test multiplies a 4x4 identity matrix (A) by a 4x4 matrix (B) where B[i, j] = j. The result is stored in S");
        $display("[TEST] Expecting result of 00000018");
        repeat (156) fpga_to_host();
      end

      begin
        repeat (TIMEOUT_CYCLE) @(posedge clk);
        $display("[TEST] WARNING: Timeout while waiting for BIOS to finish\n");
      end

    join_any

    $display("[TEST] BIOS output...\n");

    output_string = "";
    for (i = 0; i < 156; i = i + 1) begin
      output_string = {output_string, $sformatf("%s", msg_out[i][7:0])};
    end
    $display("%s", output_string);

    $display("\n[TEST] Memory dump:\n");

    for (i = 0; i < 4; i = i + 1) begin
      for (j = 0; j < 4; j = j + 1) begin
        $display("A: %d, %d: %x", i, j, `DMEM_PATH.mem[527 + i * 4 + j]);
      end
    end
    $display("");
    for (i = 0; i < 4; i = i + 1) begin
      for (j = 0; j < 4; j = j + 1) begin
        $display("B: %d, %d: %x", i, j, `DMEM_PATH.mem[559 + i * 4 + j]);
      end
    end
    $display("");
    for (i = 0; i < 4; i = i + 1) begin
      for (j = 0; j < 4; j = j + 1) begin
        $display("S: %d, %d: %x", i, j, `DMEM_PATH.mem[543 + i * 4 + j]);
      end
    end

    $finish();
  end

endmodule
