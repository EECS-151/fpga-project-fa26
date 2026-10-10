`timescale 1ns/1ns

`include "../src/riscv_core/opcode.vh"
`include "mem_path.vh"

module csr_counter_tb();
  reg clk, rst;
  parameter CPU_CLOCK_PERIOD = 20;
  parameter CPU_CLOCK_FREQ   = 1_000_000_000 / CPU_CLOCK_PERIOD;

  initial clk = 0;
  always #(CPU_CLOCK_PERIOD/2) clk = ~clk;

  localparam MCYCLE     = 12'h800; 
  localparam MINSTRET   = 12'h802; 
  localparam TOHOST     = 12'h51E;

  cpu # (
    .CPU_CLOCK_FREQ(CPU_CLOCK_FREQ),
    .RESET_PC(32'h1000_0000)
  ) cpu (
    .clk(clk), .rst(rst), .system_clk(clk),
    .serial_in(1'b1), .serial_out(), .errors()
  );

  reg [31:0] cycle;
  reg done;
  reg [31:0]  current_test_id = 0;
  reg [255:0] current_test_type;
  reg [31:0]  current_output;
  reg [31:0]  current_result;
  reg all_tests_passed = 0;
  wire [31:0] timeout_cycle = 500; 

  reg [31:0] captured_mcycle;
  reg [31:0] captured_minstret;

  task reset_memories;
    integer i;
    begin
      for (i = 0; i < `RF_PATH.DEPTH; i = i + 1)   `RF_PATH.mem[i] = 0;
      for (i = 0; i < `DMEM_PATH.DEPTH; i = i + 1) `DMEM_PATH.mem[i] = 0;
      for (i = 0; i < `IMEM_PATH.DEPTH; i = i + 1) `IMEM_PATH.mem[i] = 0;
    end
  endtask

  task reset_cpu;
    begin
      @(negedge clk); rst = 1;
      @(negedge clk); rst = 0;
      repeat (5) @(posedge clk);
      captured_mcycle = 0;
    end
  endtask

  task check_tohost;
    input [31:0] expected_val;
    input [255:0] test_type;
    begin
      done = 0;
      current_test_id = current_test_id + 1;
      current_test_type = test_type;
      current_result = expected_val;
      
      // Blocks until the TOHOST CSR matches the expected register value
      while (`CSR_PATH !== expected_val) begin
        current_output = `CSR_PATH;
        @(posedge clk);
      end
      
      cycle = 0;
      done = 1;
      $display("[%0d] Test %s passed! (TOHOST: 0x%h)", current_test_id, test_type, expected_val);
    end
  endtask

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

      captured_minstret = `RF_PATH.mem[8];
      captured_mcycle   = `RF_PATH.mem[7];

      cycle = 0;
      done = 1;
      $display("[%0d] Test %s passed! (Result: %0d)", current_test_id, test_type, result);
    end
  endtask

  task write_finish_sequence;
    input [14:0] addr;
    begin
      // Stores current counters in x8/x7 then signals completion via TOHOST
      `IMEM_PATH.mem[addr + 0] = {MINSTRET, 5'd0, 3'b010, 5'd8, `OPC_CSR};
      `IMEM_PATH.mem[addr + 1] = {MCYCLE,   5'd0, 3'b010, 5'd7, `OPC_CSR};
      `IMEM_PATH.mem[addr + 2] = {TOHOST,   5'd1, 3'b101, 5'd0, `OPC_CSR};
    end
  endtask

  initial begin
    `ifndef IVERILOG
        $vcdpluson;
        $vcdplusmemon;
    `endif
    `ifdef IVERILOG
        $dumpfile("csr_verification_tb.fst");
        $dumpvars(0, csr_counter_tb);
    `endif

    while (all_tests_passed === 0) begin
      @(posedge clk);
      if (cycle === timeout_cycle) begin
        $display("[Failed] Timeout at [%0d] %s, expected_result = %0d, last_val = %0d",
                current_test_id, current_test_type, current_result, current_output);
        $finish();
      end
    end
  end

  always @(posedge clk) begin
    if (done === 0) cycle <= cycle + 1;
    else            cycle <= 0;
  end

  integer i;
  reg [14:0] INST_ADDR;
  reg [31:0] test3_start_mcycle;

  initial begin
    #0 rst = 0;

    // Test 1: 10 NOPs
    reset_memories();
    INST_ADDR = 14'h0000;
    for (i = 0; i < 10; i = i + 1) begin
      `IMEM_PATH.mem[INST_ADDR + i] = {12'd0, 5'd0, 3'b000, 5'd0, `OPC_ARI_ITYPE};
    end
    write_finish_sequence(14'h000A);
    reset_cpu();
    check_result_rf(5'd8, 32'd10, "CSR MINSTRET (10 NOPs)");

    // Test 2: For Loop
    reset_memories();
    INST_ADDR = 14'h0000;
    `IMEM_PATH.mem[0] = {12'd10, 5'd0, 3'b000, 5'd10, `OPC_ARI_ITYPE}; 
    `IMEM_PATH.mem[1] = {12'hfff, 5'd10, 3'b000, 5'd10, `OPC_ARI_ITYPE}; 
    `IMEM_PATH.mem[2] = {1'b1, 6'b111111, 5'd0, 5'd10, 3'b001, 4'b1110, 1'b1, `OPC_BRANCH}; 
    write_finish_sequence(14'h0003);
    reset_cpu();
    check_result_rf(5'd8, 32'd21, "CSR MINSTRET (10-iter Loop)");

    // Test 3: MCYCLE Activity
    reset_memories();
    INST_ADDR = 14'h0000;
    for (i = 0; i < 30; i = i + 1) begin
      `IMEM_PATH.mem[INST_ADDR + i] = {12'd0, 5'd0, 3'b000, 5'd0, `OPC_ARI_ITYPE};
    end
    write_finish_sequence(14'h01E);
    reset_cpu();
    test3_start_mcycle = captured_mcycle; 
    check_result_rf(5'd8, 32'd30, "MCYCLE Active Run");

    if (captured_mcycle == 0) begin
      $display("[Failed] MCYCLE is stuck at 0!");
      $finish();
    end else begin
      $display("    MCYCLE Sanity: Start=%0d, End=%0d, Delta=%0d", 
               test3_start_mcycle, captured_mcycle, (captured_mcycle - test3_start_mcycle));
    end

    // Test 4: TOHOST Functional Data Write
    reset_memories();
    INST_ADDR = 14'h0000;
    // Load x5 with 0x7A then write x5 to TOHOST CSR
    `IMEM_PATH.mem[0] = {12'h07A, 5'd0, 3'b000, 5'd5, `OPC_ARI_ITYPE}; 
    `IMEM_PATH.mem[1] = {TOHOST, 5'd5, 3'b001, 5'd0, `OPC_CSR}; 
    reset_cpu();
    check_tohost(32'h0000_007A, "TOHOST Register Write");

    all_tests_passed = 1'b1;
    repeat (10) @(posedge clk);
    $display("\n***************************************");
    $display("CSR Counter & TOHOST Tests Passed!");
    $display("***************************************");
    $finish();
  end

endmodule
