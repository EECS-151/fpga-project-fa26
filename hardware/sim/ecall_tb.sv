// Commented out: this testbench exercises traps (ecall, mtvec, mepc, mcause, mret), which aren't part of this checkpoint.
/*
`timescale 1ns/1ns

`include "../src/riscv_core/opcode.vh"
`include "mem_path.vh"

// Ecall test: handler at 0x1000_0008 (mtvec). Main at 0x1000_0100 does ecall; handler reads mcause (11), sets x1/x2, mret.
// Test order: x1=0x11, x3=mcause (11), x2=0x22 after mret. Timeout jump after mret; x6 check to pinpoint mret failure.

module ecall_tb;
  logic clk, rst;
  parameter int CPU_CLOCK_PERIOD = 20;
  parameter int CPU_CLOCK_FREQ   = 1_000_000_000 / CPU_CLOCK_PERIOD;

  initial clk = 0;
  always #(CPU_CLOCK_PERIOD/2) clk = ~clk;
  logic bp_enable = 1'b0;

  localparam logic [31:0] RESET_PC = 32'h1000_0100;

  cpu #(
    .CPU_CLOCK_FREQ(CPU_CLOCK_FREQ),
    .RESET_PC(RESET_PC)
  ) cpu (
    .clk(clk),
    .system_clk(clk),
    .rst(rst),
    .bp_enable(bp_enable),
    .serial_in(1'b1),
    .serial_out(),
    .errors()
  );

  task reset;
    for (int i = 0; i < `RF_PATH.DEPTH; i++)
      `RF_PATH.mem[i] = 0;
    for (int i = 0; i < `DMEM_PATH.DEPTH; i++)
      `DMEM_PATH.mem[i] = 0;
    for (int i = 0; i < `IMEM_PATH.DEPTH; i++)
      `IMEM_PATH.mem[i] = 0;
  endtask

  task reset_cpu;
    @(negedge clk);
    rst = 1;
    @(negedge clk);
    rst = 0;
  endtask

  logic [31:0] cycle;
  logic [14:0] INST_ADDR;

  initial begin
    string fsdb_file;
    if (!$value$plusargs("fsdbfile+%s", fsdb_file)) begin
      fsdb_file = "default.fsdb";
    end
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, ecall_tb);

    #0;
    rst = 0;
    repeat (10) @(posedge clk);
    @(negedge clk);
    rst = 1;
    @(negedge clk);
    rst = 0;

    reset();
    INST_ADDR = 14'h0000;

    // 0x1000_0000 (0): write to unused reg; 0x1000_0004 (1): jal to 0x1000_0000 (timeout if mret doesn't work)
    `IMEM_PATH.mem[INST_ADDR + 0] = {12'h0DE, 5'd0, 3'b000, 5'd6, `OPC_ARI_ITYPE};   // addi x6, x0, 0xDE
    `IMEM_PATH.mem[INST_ADDR + 1] = 32'hFFEFF06F;     // jal x0, 0x10000000
    // Handler at 0x1000_0008 (mtvec) — reached on ecall; add 4 to mepc so mret returns past the ecall
    `IMEM_PATH.mem[INST_ADDR + 2] = {12'h341, 5'd0, 3'b010, 5'd4, `OPC_CSR};          // csrrs x4, mepc, x0
    `IMEM_PATH.mem[INST_ADDR + 3] = {12'd4, 5'd4, 3'b000, 5'd4, `OPC_ARI_ITYPE};      // addi x4, x4, 4
    `IMEM_PATH.mem[INST_ADDR + 4] = {12'h341, 5'd4, 3'b001, 5'd0, `OPC_CSR};          // csrrw x0, mepc, x4
    `IMEM_PATH.mem[INST_ADDR + 5] = {12'h342, 5'd0, 3'b010, 5'd3, `OPC_CSR};          // csrrs x3, mcause, x0
    `IMEM_PATH.mem[INST_ADDR + 6] = {12'h011, 5'd0, 3'b000, 5'd1, `OPC_ARI_ITYPE};   // addi x1, x0, 0x11
    `IMEM_PATH.mem[INST_ADDR + 7] = {12'h099, 5'd0, 3'b000, 5'd2, `OPC_ARI_ITYPE};   // addi x2, x0, 0x99
    `IMEM_PATH.mem[INST_ADDR + 8] = 32'h30200073;      // mret
    `IMEM_PATH.mem[INST_ADDR + 9] = 32'hFDDFF06F;     // jal x0, 0x10000000  (from 0x10000024, offset -36; timeout if mret didn't work)

    // Main program starts at 64 (RESET_PC = 0x1000_0100)
    `IMEM_PATH.mem[INST_ADDR + 64]  = {20'h10000, 5'd5, `OPC_LUI};                       // lui x5, 0x10000
    `IMEM_PATH.mem[INST_ADDR + 65]  = {12'd8, 5'd5, 3'b000, 5'd5, `OPC_ARI_ITYPE};       // addi x5, x5, 8  -> 0x10000008
    `IMEM_PATH.mem[INST_ADDR + 66]  = {12'h305, 5'd5, 3'b001, 5'd0, `OPC_CSR};           // csrrw x0, mtvec, x5
    `IMEM_PATH.mem[INST_ADDR + 67]  = {12'd1, 5'd0, 3'b000, 5'd0, `OPC_ARI_ITYPE};       // addi x0, x0, 1  (nop)
    `IMEM_PATH.mem[INST_ADDR + 68]  = {12'd1, 5'd0, 3'b000, 5'd0, `OPC_ARI_ITYPE};       // addi x0, x0, 1  (nop)
    `IMEM_PATH.mem[INST_ADDR + 69]  = {12'd1, 5'd0, 3'b000, 5'd0, `OPC_ARI_ITYPE};       // addi x0, x0, 1  (nop)
    `IMEM_PATH.mem[INST_ADDR + 70]  = 32'h00000073;     // ecall
    `IMEM_PATH.mem[INST_ADDR + 71]  = {12'h022, 5'd0, 3'b000, 5'd2, `OPC_ARI_ITYPE};     // addi x2, x0, 0x22  (overwrite after mret)

    reset_cpu();
    cycle = 0;

    // Test 1: x1 becomes 0x11 (handler ran)
    while (`RF_PATH.mem[1] !== 32'h11) begin
      @(posedge clk);
      cycle = cycle + 1;
      if (cycle > 120) begin
        $display("[Failed] Ecall test: x1 did not become 0x11 (x1=%h)", `RF_PATH.mem[1]);
        $finish();
      end
    end
    $display("  x1 = 0x11 - Exception handler executed");

    // Test 2: x3 = 11 (mcause for ecall from M-mode)
    while (`RF_PATH.mem[3] !== 32'd11) begin
      @(posedge clk);
      cycle = cycle + 1;
      if (cycle > 180) begin
        $display("[Failed] Ecall test: x3 did not become 11 (mcause) (x3=%h)", `RF_PATH.mem[3]);
        $finish();
      end
    end
    $display("  x3 = 11 (mcause) - Correct mcause read in handler");

    // Test 3: x2 becomes 0x22 (overwrite after mret)
    while (`RF_PATH.mem[2] !== 32'h22) begin
      @(posedge clk);
      cycle = cycle + 1;
      if (cycle > 220) begin
        $display("[Failed] Ecall test: x2 did not become 0x22 (x2=%h)", `RF_PATH.mem[2]);
        if (`RF_PATH.mem[6] === 32'hDE) begin
          $display("[Failed] Ecall test: mret did not work (fell through to timeout loop, x6=0xDE)");
        end
        $finish();
      end
    end
    $display("  x2 = 0x22 - mret worked");

    // Test 4: x6 never set (if mret didn't work we jump to 0x10000000 and x6 becomes 0xDE)
    if (`RF_PATH.mem[6] === 32'hDE) begin
      $display("[Failed] Ecall test: mret did not work (fell through to timeout loop, x6=0xDE)");
      $finish();
    end
    $display("  x6 != 0xDE (mret worked)");

    $display("Ecall test passed! (x1=0x11, x3=11, x2=0x22)");
    repeat (20) @(posedge clk);
    $finish();
  end

endmodule
*/
