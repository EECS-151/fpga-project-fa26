`timescale 1ns/1ns
`include "../src/riscv_core/opcode.vh"
`include "mem_path.vh"

module zephyr_tb;

  logic clk, rst, system_clk;
  localparam int CPU_CLOCK_PERIOD = 10;
  localparam int CPU_CLOCK_FREQ   = 1_000_000_000 / CPU_CLOCK_PERIOD;
  localparam int BAUD_RATE        = 10_000_000;
  localparam int BAUD_PERIOD      = 1_000_000_000 / BAUD_RATE; // 8680.55 ns

  localparam int TIMEOUT_CYCLE = 500_000;

  initial clk = '0;
  always #(CPU_CLOCK_PERIOD/2) clk = ~clk;

  initial system_clk = '0;
  always #(5) system_clk = ~system_clk;

  logic bp_enable = 1'b0;

  logic serial_in;
  logic serial_out;

  cpu # (
    .CPU_CLOCK_FREQ(CPU_CLOCK_FREQ),
    .SYSTEM_CLOCK_FREQ(100_000_000),
    .RESET_PC(32'h1000_0000),
    .BAUD_RATE(BAUD_RATE),
    .BIOS_MIF_HEX("../../software/bios/bios.hex")
  ) cpu (
    .clk(clk),
    .system_clk(system_clk),
    .rst(rst),
    .bp_enable(bp_enable),
    .serial_in(serial_in),   // input
    .serial_out(serial_out),  // output
    .errors()
  );

  logic [31:0] cycle;
  always_ff @(posedge system_clk) begin
    if (rst)
      cycle <= '0;
    else
      cycle <= cycle + 1;
  end

  // Output buffer: collect up to 1000 characters from FPGA serial output
  logic [7:0] out_buf [0:999];
  int         buf_idx;
  logic [7:0] byte_val;

  // Continuously collect UART bytes from serial_out into out_buf
  initial begin
    buf_idx = 0;
    forever begin
      wait (serial_out === 1'b0);  // start bit
      #(BAUD_PERIOD + BAUD_PERIOD/2);  // middle of first data bit (LSB)
      byte_val[0] = serial_out;
      #(BAUD_PERIOD);
      byte_val[1] = serial_out;
      #(BAUD_PERIOD);
      byte_val[2] = serial_out;
      #(BAUD_PERIOD);
      byte_val[3] = serial_out;
      #(BAUD_PERIOD);
      byte_val[4] = serial_out;
      #(BAUD_PERIOD);
      byte_val[5] = serial_out;
      #(BAUD_PERIOD);
      byte_val[6] = serial_out;
      #(BAUD_PERIOD);
      byte_val[7] = serial_out;
      #(BAUD_PERIOD);              // consume stop bit
      if (buf_idx < 1000) begin
        out_buf[buf_idx] = byte_val;
        buf_idx = buf_idx + 1;
      end
    end
  end

  initial begin
    string fsdb_file;
    if (!$value$plusargs("fsdbfile+%s", fsdb_file)) begin
      fsdb_file = "default.fsdb";
    end
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, zephyr_tb);

    $readmemh("../../software/bios/bios.hex", `BIOS_PATH.mem, 0, 16384);
    $readmemh("../../software/rtos/build/zephyr/zephyr.hex", `IMEM_PATH.mem, 0, 65535);
    $readmemh("../../software/rtos/build/zephyr/zephyr.hex", `DMEM_PATH.mem, 0, 65535);

    rst = 1'b1;
    serial_in = 1'b1;

    // Hold reset for a while
    repeat (10) @(posedge system_clk);

    @(negedge system_clk);
    rst = 1'b0;

    // Run until timeout; serial output is collected in out_buf
    repeat (10) @(posedge system_clk);
  end

  // Simple UART transmitter on serial_in to send commands into Zephyr shell.
  // Uses same BAUD_RATE/BAUD_PERIOD as the on-chip UART.
  task automatic host_to_fpga(input wire logic [7:0] char_in);
    serial_in = 1'b0;
    #(BAUD_PERIOD);
    // Data bits (payload)
    for (int i = 0; i < 8; i++) begin
      serial_in = char_in[i];
      #(BAUD_PERIOD);
    end
    // Stop bit
    serial_in = 1'b1;
    #(BAUD_PERIOD);

    $display("[time %t, sim. cycle %d] [Host (tb) --> FPGA_SERIAL_RX] Sent char 8'h%h",
             $time, cycle, char_in);
    repeat (1000) @(posedge clk);
  endtask


  // After boot and shell startup, send "hwinfo" followed by Enter over UART.
  initial begin
    // Wait a while for Zephyr banner and shell prompt to appear.
    // This is a coarse delay; adjust if needed.
    repeat (60000) @(posedge system_clk);

    host_to_fpga("h");
    host_to_fpga("w");
    host_to_fpga("i");
    host_to_fpga("n");
    host_to_fpga("f");
    host_to_fpga("o");
    // Send CRLF as Enter
    host_to_fpga(8'd13);
    host_to_fpga(8'd10);

    $display("Sent hwinfo command");
  end

  initial begin
    repeat (TIMEOUT_CYCLE) @(posedge system_clk);
    $display("Timeout! Characters received (%0d):", buf_idx);
    for (int i = 0; i < buf_idx; i++)
      $write("%c", out_buf[i]);
    $display("");
    $display("Hex codes:");
    for (int i = 0; i < buf_idx; i++)
      $write(" %02h", out_buf[i]);
    $display("");
    $fatal();
  end

endmodule
