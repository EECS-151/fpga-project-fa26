// Commented out: this testbench exercises the timer interrupt (mtime, mtimecmp, mie, mstatus), which aren't part of this checkpoint.
/*
`timescale 1ns/1ns

`include "../src/riscv_core/opcode.vh"
`include "mem_path.vh"

// Timer interrupt test: handler is placed before RESET_PC so we never execute it except via trap.
// RESET_PC = 0x1000_000C (first main instruction). Handler at 0x1000_0008 (indices 0,1,2).
// Test order: x1=0x11, x3=mcause (handler), then x2=0x22 (overwrite after mret).

module timer_interrupt_tb;

  logic clk, rst;
  localparam int CPU_CLOCK_PERIOD = 20;
  localparam int CPU_CLOCK_FREQ   = 1_000_000_000 / CPU_CLOCK_PERIOD;

  initial clk = '0;
  always #(CPU_CLOCK_PERIOD/2) clk = ~clk;
  logic bp_enable = 1'b0;

  // Start at instruction 3 so we never run the handler (indices 0,1,2) except via mtvec
  localparam RESET_PC = 32'h1000_0100;

  cpu # (
    .CPU_CLOCK_FREQ(CPU_CLOCK_FREQ),
    .RESET_PC(RESET_PC)
  ) cpu (
    .clk(clk),
    .system_clk(clk),
    .rst(rst),
    .bp_enable(bp_enable),
    .serial_in(1'b1),
    .serial_out()
  );

  task automatic reset;
    for (int i = 0; i < `RF_PATH.DEPTH; i++)
      `RF_PATH.mem[i] = '0;
    for (int i = 0; i < `DMEM_PATH.DEPTH; i++)
      `DMEM_PATH.mem[i] = '0;
    for (int i = 0; i < `IMEM_PATH.DEPTH; i++)
      `IMEM_PATH.mem[i] = '0;
  endtask

  task automatic reset_cpu;
    @(negedge clk);
    rst = 1;
    @(negedge clk);
    rst = 0;
  endtask

  logic [31:0] cycle;
  logic [14:0] INST_ADDR;

  initial begin
    `ifndef IVERILOG
      $vcdpluson;
    `endif
    `ifdef IVERILOG
      $dumpfile("timer_interrupt_tb.fst");
      $dumpvars(0, timer_interrupt_tb);
    `endif

    #0;
    rst = 1'b0;
    repeat (10) @(posedge clk);
    @(negedge clk);
    rst = 1'b1;
    @(negedge clk);
    rst = 1'b0;

    reset();
    INST_ADDR = 14'h0000;

    // 0x1000_0000 (0): write to unused reg; 0x1000_0004 (1): jal to 0x1000_0000 (timeout if mret doesn't work)
    `IMEM_PATH.mem[INST_ADDR + 0] = {12'h0DE, 5'd0, 3'b000, 5'd6, `OPC_ARI_ITYPE};   // addi x6, x0, 0xDE  (unused reg)
    `IMEM_PATH.mem[INST_ADDR + 1] = 32'hFFEFF06F;                                    // jal x0, 0x10000000  (jump to 00 from 04)
    // Handler at 0x1000_0008 (mtvec) — only reached via trap
    `IMEM_PATH.mem[INST_ADDR + 2] = {12'h342, 5'd0, 3'b010, 5'd3, `OPC_CSR};         // csrrs x3, mcause, x0
    `IMEM_PATH.mem[INST_ADDR + 3] = {12'h011, 5'd0, 3'b000, 5'd1, `OPC_ARI_ITYPE};   // addi x1, x0, 0x11
    `IMEM_PATH.mem[INST_ADDR + 4] = {12'h099, 5'd0, 3'b000, 5'd2, `OPC_ARI_ITYPE};   // addi x2, x0, 0x99
    `IMEM_PATH.mem[INST_ADDR + 5] = {12'hFFF, 5'd0, 3'b000, 5'd8, `OPC_ARI_ITYPE};   // addi x8, x0, 0xFFFFFF
    `IMEM_PATH.mem[INST_ADDR + 6] = {7'b0, 5'd8, 5'd11, `FNC_SW, 5'b0, `OPC_STORE};  // sw x8, 0(x11)  mtimecmp[31:0]
    `IMEM_PATH.mem[INST_ADDR + 7] = 32'h30200073;      // mret
    `IMEM_PATH.mem[INST_ADDR + 8] = 32'h0BFEFF06F;     // jal x0, 0x10000000  (timeout if mret didn't work; x6 gets 0xDE)

    // Main program starts at 64 (RESET_PC = 0x1000_0100)
    // Setup: enable timer interrupts (mstatus.MIE=1, mie.MTIE=1)
    `IMEM_PATH.mem[INST_ADDR + 64] = {12'h300, 5'd8, 3'b110, 5'd0, `OPC_CSR};                // csrrsi x0, mstatus, 8  (mstatus[3]=MIE=1)
    `IMEM_PATH.mem[INST_ADDR + 65] = {12'd128, 5'd0, 3'b000, 5'd4, `OPC_ARI_ITYPE};          // addi x4, x0, 128  (1<<7 for MTIE)
    `IMEM_PATH.mem[INST_ADDR + 66] = {12'h304, 5'd4, 3'b010, 5'd0, `OPC_CSR};                // csrrs x0, mie, x4  (set mie[7]=MTIE)
    `IMEM_PATH.mem[INST_ADDR + 67] = {20'h10000, 5'd5, `OPC_LUI};                            // lui x5, 0x10000
    `IMEM_PATH.mem[INST_ADDR + 68] = {12'd8, 5'd5, 3'b000, 5'd5, `OPC_ARI_ITYPE};            // addi x5, x5, 8  -> 0x10000008
    `IMEM_PATH.mem[INST_ADDR + 69] = {12'h305, 5'd5, 3'b001, 5'd0, `OPC_CSR};                // csrrw x0, mtvec, x5
    // mtimecmp = mtime + 2 (CLINT: mtime @ 0x0200BFF8, mtimecmp @ 0x02004000)
    // 0x0200BFF8: lower 12 bits are 0xFF8 (> 0x7FF), so lui 0x0200C then addi with 12'hFF8 (-8).
    `IMEM_PATH.mem[INST_ADDR + 70] = {20'h0200C, 5'd7, `OPC_LUI};                            // lui x7, 0x0200C  -> 0x0200C000
    `IMEM_PATH.mem[INST_ADDR + 71] = {12'hFF8, 5'd7, 3'b000, 5'd7, `OPC_ARI_ITYPE};          // addi x7, x7, -8  -> x7 = 0x0200BFF8
    `IMEM_PATH.mem[INST_ADDR + 75] = {20'h02004, 5'd11, `OPC_LUI};                           // lui x11, 0x02004  -> x11=0x02004000
    `IMEM_PATH.mem[INST_ADDR + 76] = {12'd0, 5'd7, 3'b010, 5'd8, `OPC_LOAD};                 // lw x8, 0(x7)   mtime[31:0]
    `IMEM_PATH.mem[INST_ADDR + 77] = {12'd4, 5'd7, 3'b010, 5'd9, `OPC_LOAD};                 // lw x9, 4(x7)   mtime[63:32]
    `IMEM_PATH.mem[INST_ADDR + 78] = {12'd2, 5'd8, 3'b000, 5'd8, `OPC_ARI_ITYPE};            // addi x8, x8, 2
    `IMEM_PATH.mem[INST_ADDR + 79] = {7'b0, 5'd8, 5'd11, `FNC_SW, 5'b0, `OPC_STORE};         // sw x8, 0(x11)  mtimecmp[31:0]
    `IMEM_PATH.mem[INST_ADDR + 80] = {7'b0, 5'd9, 5'd11, `FNC_SW, 5'd4, `OPC_STORE};         // sw x9, 4(x11)  mtimecmp[63:32]
    `IMEM_PATH.mem[INST_ADDR + 81] = {12'd1, 5'd0, 3'b000, 5'd0, `OPC_ARI_ITYPE};            // addi x0, x0, 1  (nop)
    `IMEM_PATH.mem[INST_ADDR + 82] = {12'd1, 5'd0, 3'b000, 5'd0, `OPC_ARI_ITYPE};            // addi x0, x0, 1  (nop)
    `IMEM_PATH.mem[INST_ADDR + 83] = {12'h022, 5'd0, 3'b000, 5'd2, `OPC_ARI_ITYPE};          // addi x2, x0, 0x22  (overwrite after mret)

    reset_cpu();
    cycle = '0;

    // Test 1: x1 becomes 0x11
    while (`RF_PATH.mem[1] !== 32'h11) begin
      @(posedge clk);
      cycle = cycle + 1;
      if (cycle > 120) begin
        $display("[Failed] Timer interrupt test: x1 did not become 0x11 (x1=%h)", `RF_PATH.mem[1]);
        $finish();
      end
    end
    $display("  x1 = 0x11 - Interrupt handler executed");

    // Test 2: x3 = 0x80000007 (mcause read in handler)
    while (`RF_PATH.mem[3] !== 32'h80000007) begin
      @(posedge clk);
      cycle = cycle + 1;
      if (cycle > 180) begin
        $display("[Failed] Timer interrupt test: x3 did not become 0x80000007 (mcause) (x3=%h)", `RF_PATH.mem[3]);
        $finish();
      end
    end
    $display("  x3 = 0x80000007 (mcause) - Correct mcause read in handler");

    // Test 3: x2 becomes 0x22 (overwrite after mret)
    while (`RF_PATH.mem[2] !== 32'h22) begin
      @(posedge clk);
      cycle = cycle + 1;
      if (cycle > 220) begin
        $display("[Failed] Timer interrupt test: x2 did not become 0x22 (x2=%h)", `RF_PATH.mem[2]);
        if (`RF_PATH.mem[6] === 32'hDE) begin
          $display("[Failed] Timer interrupt test: mret did not work (fell through to timeout loop, x6=0xDE)");
          $finish();
        end
        $finish();
      end
    end
    $display("  x2 = 0x22 - mret worked");

    $display("Timer interrupt test passed! (x1=0x11, x3=0x80000007, x2=0x22)");
    repeat (20) @(posedge clk);
    $finish();
  end

endmodule
*/
