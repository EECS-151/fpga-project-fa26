/*
Credit to Isaac Tsang, Sp25 FPGA student for writing this testbench under the guidance of Prashanth Ganesh, Sp25 FPGA TA 

This is a simple testbench which checks whether your cpu jumps properly from your BIOS to IMEM and back
*/

`timescale 1ns/1ns

`include "../src/riscv_core/opcode.vh"
`include "mem_path.vh"

module bios_imem_tb();
  reg clk, rst;
  parameter CPU_CLOCK_PERIOD = 20;
  parameter CPU_CLOCK_FREQ   = 1_000_000_000 / CPU_CLOCK_PERIOD;

  initial clk = 0;
  always #(CPU_CLOCK_PERIOD/2) clk = ~clk;
  wire [31:0] csr;
  reg bp_enable = 1'b0;

  // Init PC with 32'h1000_0000 -- address space of IMem
  // When PC is in IMem's address space, IMem is read-only
  // DMem can be R/W as long as the addr bits [31:28] is 4'b00x1
  cpu # (
    .CPU_CLOCK_FREQ(CPU_CLOCK_FREQ),
    .RESET_PC(32'h4000_0000)
  ) cpu (
    .clk(clk),
    .rst(rst),
    .system_clk(clk),
    .serial_in(1'b1),
    .serial_out(),
    .errors()
  );

  wire [31:0] timeout_cycle = 10;

  // Reset IMem, DMem, and RegFile before running new test
  task reset;
    integer i;
    begin
      for (i = 0; i < `RF_PATH.DEPTH; i = i + 1) begin
        `RF_PATH.mem[i] = 0;
      end
      for (i = 0; i < `DMEM_PATH.DEPTH; i = i + 1) begin
        `DMEM_PATH.mem[i] = 0;
      end
      for (i = 0; i < `IMEM_PATH.DEPTH; i = i + 1) begin
        `IMEM_PATH.mem[i] = 0;
      end
    end
  endtask

  task reset_cpu;
    @(negedge clk);
    rst = 1;
    @(negedge clk);
    rst = 0;
  endtask

  task init_rf;
    integer i;
    begin
      for (i = 1; i < `RF_PATH.DEPTH; i = i + 1) begin
        `RF_PATH.mem[i] = 100 * i + 1;
      end
    end
  endtask

  reg [31:0] cycle;
  reg done;
  reg [31:0]  current_test_id = 0;
  reg [255:0] current_test_type;
  reg [31:0]  current_output;
  reg [31:0]  current_result;
  reg all_tests_passed = 0;


  // Check for timeout
  // If a test does not return correct value in a given timeout cycle,
  // we terminate the testbench
  initial begin
    while (all_tests_passed === 0) begin
      @(posedge clk);
      if (cycle === timeout_cycle) begin
        $display("[Failed] Timeout at [%d] test %s, expected_result = %h, got = %h",
                current_test_id, current_test_type, current_result, current_output);
        $finish();
      end
    end
  end

  always @(posedge clk) begin
    if (done === 0)
      cycle <= cycle + 1;
    else
      cycle <= 0;
  end

  // Check result of RegFile
  // If the write_back (destination) register has correct value (matches "result"), test passed
  // This is used to test instructions that update RegFile
  task check_result_rf;
    input [31:0]  rf_wa;
    input [31:0]  result;
    input [255:0] test_type;
    begin
      done = 0;
      current_test_id   = current_test_id + 1;
      current_test_type = test_type;
      current_result    = result;
      while (`RF_PATH.mem[rf_wa] !== result) begin
        current_output = `RF_PATH.mem[rf_wa];
        @(posedge clk);
      end
      cycle = 0;
      done = 1;
      $display("[%d] Test %s passed!", current_test_id, test_type);
    end
  endtask

  // Check result of DMem
  // If the memory location of DMem has correct value (matches "result"), test passed
  // This is used to test store instructions
  task check_result_dmem;
    input [31:0]  addr;
    input [31:0]  result;
    input [255:0] test_type;
    begin
      done = 0;
      current_test_id   = current_test_id + 1;
      current_test_type = test_type;
      current_result    = result;
      while (`DMEM_PATH.mem[addr] !== result) begin
        current_output = `DMEM_PATH.mem[addr];
        @(posedge clk);
      end
      cycle = 0;
      done = 1;
      $display("[%d] Test %s passed!", current_test_id, test_type);
    end
  endtask

  integer i;

  reg [31:0] num_cycles = 0;
  reg [31:0] num_insts  = 0;
  reg [4:0]  RD, RS1, RS2;
  reg [31:0] RD1, RD2;
  reg [4:0]  SHAMT;
  reg [31:0] IMM, IMM0, IMM1, IMM2, IMM3;
  reg [14:0] INST_ADDR;
  reg [14:0] DATA_ADDR;
  reg [14:0] DATA_ADDR0, DATA_ADDR1, DATA_ADDR2, DATA_ADDR3;
  reg [14:0] DATA_ADDR4, DATA_ADDR5, DATA_ADDR6, DATA_ADDR7;
  reg [14:0] DATA_ADDR8, DATA_ADDR9;

  reg [31:0] JUMP_ADDR;

  reg [31:0]  BR_TAKEN_OP1  [5:0];
  reg [31:0]  BR_TAKEN_OP2  [5:0];
  reg [31:0]  BR_NTAKEN_OP1 [5:0];
  reg [31:0]  BR_NTAKEN_OP2 [5:0];
  reg [2:0]   BR_TYPE       [5:0];
  reg [255:0] BR_NAME_TK1   [5:0];
  reg [255:0] BR_NAME_TK2   [5:0];
  reg [255:0] BR_NAME_NTK   [5:0];

  initial begin
    `ifndef IVERILOG
        $vcdpluson;
    `endif
    `ifdef IVERILOG
        $dumpfile("cpu_tb.fst");
        $dumpvars(0, cpu_tb);
    `endif

    #0;
    rst = 0;

    // Reset the CPU
    rst = 1;
    // Hold reset for a while
    repeat (10) @(posedge clk);

    @(negedge clk);
    rst = 0;

    // Test R-Type Insts --------------------------------------------------
    // - ADD, SUB, SLL, SLT, SLTU, XOR, OR, AND, SRL, SRA
    // - SLLI, SRLI, SRAI
    reset();

    // We can also use $random to generate random values for testing
    RS1 = 1; RD1 = -100;
    RS2 = 2; RD2 =  200;
    RD  = 3;
    `RF_PATH.mem[RS1] = RD1;
    `RF_PATH.mem[RS2] = RD2;
    SHAMT           = 5'd20;
    INST_ADDR       = 14'h0000;

    // Test I-type 
    reset_cpu();
    reset();
    `BIOS_PATH.mem[INST_ADDR + 0] = 32'h100002b7; // lui
    `BIOS_PATH.mem[INST_ADDR + 1] = 32'h00028567; //jalr x0, 0(x5)
    `IMEM_PATH.mem[INST_ADDR + 0] = 32'h00a00293; // li x5, 10
    `IMEM_PATH.mem[INST_ADDR + 1] = 32'h00050067; // li x6, 11
    //`IMEM_PATH.mem[INST_ADDR + 1] = 32'h00b00313; // li x6, 11


    check_result_rf(5'd5, 32'h0000000a, "imem to bios test");


    // ... what else?
    all_tests_passed = 1'b1;

    repeat (100) @(posedge clk);
    $display("All tests passed!");
    $finish();
  end

endmodule