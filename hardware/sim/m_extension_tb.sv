`timescale 1ns/1ns

`include "../src/riscv_core/opcode.vh"
`include "mem_path.vh"

// Testbench for RV32M: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU.
// Structure matches cpu_tb.v: program IMEM/RF, reset_cpu, check_result_rf after multicycle ops complete.
// Divider IP has multi-cycle latency; timeout must be large enough for worst-case divide.

module m_extension_tb;

  logic clk, rst;
  localparam int CPU_CLOCK_PERIOD = 20;
  localparam int CPU_CLOCK_FREQ   = 1_000_000_000 / CPU_CLOCK_PERIOD;

  initial clk = '0;
  always #(CPU_CLOCK_PERIOD/2) clk = ~clk;

  logic bp_enable = 1'b0;

  // Use IMEM space (pc[30]==0) so tests loaded at INST_ADDR run from IMem like isa_tb
  cpu # (
    .CPU_CLOCK_FREQ(CPU_CLOCK_FREQ),
    .RESET_PC(32'h1000_0000)
  ) cpu (
    .clk(clk),
    .system_clk(clk),
    .rst(rst),
    .bp_enable(bp_enable),
    .serial_in(1'b1),
    .serial_out(),
    .errors()
  );

  // Divider can take many cycles; MUL is also multicycle in this core
  logic [31:0] timeout_cycle = 32'd100000;

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
  logic done;
  logic [31:0]  current_test_id = '0;
  logic [255:0] current_test_type;
  logic [31:0]  current_result;
  logic [31:0]  current_output;
  logic all_tests_passed = 1'b0;

  initial begin
    while (all_tests_passed === 1'b0) begin
      @(posedge clk);
      if (cycle === timeout_cycle) begin
        $display("[Failed] Timeout at [%d] test %s, expected = %h",
                 current_test_id, current_test_type, current_result);
        $finish();
      end
    end
  end

  always @(posedge clk) begin
    if (!done)
      cycle <= cycle + 1;
    else
      cycle <= '0;
  end

  task automatic check_result_rf(
    input wire logic [4:0]   rf_wa,
    input wire logic [31:0]  result,
    input wire logic [255:0] test_type
  );
    done = 1'b0;
    current_test_id   = current_test_id + 1;
    current_test_type = test_type;
    current_result   = result;
    while (`RF_PATH.mem[rf_wa] !== result) begin
      current_output = `RF_PATH.mem[rf_wa];
      @(posedge clk);
    end
    cycle = '0;
    done  = 1'b1;
    $display("[%d] Test %s passed! (rd = %h)", current_test_id, test_type, result);
  endtask

  logic [4:0]  RS1, RS2, RD;
  logic [14:0] INST_ADDR;

  initial begin
    string fsdb_file;
    if (!$value$plusargs("fsdbfile+%s", fsdb_file)) begin
      fsdb_file = "default.fsdb";
    end
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, m_extension_tb);

    rst = 1'b0;
    rst = 1'b1;
    repeat (10) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    INST_ADDR = 15'h0000;

    // ---------- MUL: signed low 32 of product ----------
    // 7 * 6 = 42
    reset();
    RS1 = 1; RS2 = 2; RD = 3;
    `RF_PATH.mem[RS1] = 32'd7;
    `RF_PATH.mem[RS2] = 32'd6;
    `IMEM_PATH.mem[INST_ADDR] = {`FNC7_MUL, RS2, RS1, `FNC_MUL, RD, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(RD, 32'd42, "MUL 7*6");

    // ---------- MULH: high 32 of signed * signed ----------
    // 0x10000 * 0x10000 = 0x0000_0001_0000_0000 -> MULH = 1
    reset();
    RS1 = 1; RS2 = 2; RD = 4;
    `RF_PATH.mem[RS1] = 32'h0001_0000;
    `RF_PATH.mem[RS2] = 32'h0001_0000;
    `IMEM_PATH.mem[INST_ADDR] = {`FNC7_MUL, RS2, RS1, `FNC_MULH, RD, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(RD, 32'd1, "MULH 0x10000*0x10000");

    // ---------- MULHU: high 32 of unsigned * unsigned ----------
    // 0x8000_0000 * 0x8000_0000 = 0x4000_0000_0000_0000 -> MULHU = 0x4000_0000
    reset();
    RS1 = 1; RS2 = 2; RD = 5;
    `RF_PATH.mem[RS1] = 32'h8000_0000;
    `RF_PATH.mem[RS2] = 32'h8000_0000;
    `IMEM_PATH.mem[INST_ADDR] = {`FNC7_MUL, RS2, RS1, `FNC_MULHU, RD, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(RD, 32'h4000_0000, "MULHU 0x80000000^2 high");

    // ---------- MULHSU: high 32 of signed * unsigned ----------
    // -1 * 1 = -1 -> 64-bit 0xffff_ffff_ffff_ffff -> MULHSU high = 0xffff_ffff
    reset();
    RS1 = 1; RS2 = 2; RD = 6;
    `RF_PATH.mem[RS1] = 32'hffff_ffff; // -1
    `RF_PATH.mem[RS2] = 32'd1;
    `IMEM_PATH.mem[INST_ADDR] = {`FNC7_MUL, RS2, RS1, `FNC_MULHSU, RD, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(RD, 32'hffff_ffff, "MULHSU -1 * 1 high");

    // ---------- DIV: signed quotient ----------
    // 20 / 10 = 2
    reset();
    RS1 = 1; RS2 = 2; RD = 7;
    `RF_PATH.mem[RS1] = 32'd20;
    `RF_PATH.mem[RS2] = 32'd10;
    `IMEM_PATH.mem[INST_ADDR] = {`FNC7_MUL, RS2, RS1, `FNC_DIV, RD, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(RD, 32'd2, "DIV 20/10");

    // -20 / 10 = -2
    reset();
    `RF_PATH.mem[RS1] = -32'sd20;
    `RF_PATH.mem[RS2] = 32'd10;
    `IMEM_PATH.mem[INST_ADDR] = {`FNC7_MUL, RS2, RS1, `FNC_DIV, RD, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(RD, -32'sd2, "DIV -20/10");

    // ---------- DIVU: unsigned quotient ----------
    // 50 / 7 = 7
    reset();
    `RF_PATH.mem[RS1] = 32'd50;
    `RF_PATH.mem[RS2] = 32'd7;
    `IMEM_PATH.mem[INST_ADDR] = {`FNC7_MUL, RS2, RS1, `FNC_DIVU, RD, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(RD, 32'd7, "DIVU 50/7");

    // ---------- REM: signed remainder (sign follows dividend) ----------
    // -20 % 7 = -6  (RISC-V: remainder has same sign as dividend)
    reset();
    `RF_PATH.mem[RS1] = -32'sd20;
    `RF_PATH.mem[RS2] = 32'd7;
    `IMEM_PATH.mem[INST_ADDR] = {`FNC7_MUL, RS2, RS1, `FNC_REM, RD, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(RD, -32'sd6, "REM -20%7");

    // ---------- REMU: unsigned remainder ----------
    // 50 % 7 = 1
    reset();
    `RF_PATH.mem[RS1] = 32'd50;
    `RF_PATH.mem[RS2] = 32'd7;
    `IMEM_PATH.mem[INST_ADDR] = {`FNC7_MUL, RS2, RS1, `FNC_REMU, RD, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(RD, 32'd1, "REMU 50%7");

    // ---------- DIV/REM divide-by-zero behavior ----------
    // RISC-V spec:
    // - DIV / DIVU with divisor = 0    -> quotient = -1 (all ones)
    // - REM / REMU with divisor = 0    -> remainder = dividend

    // DIV by zero:  123 / 0 -> -1
    reset();
    RS1 = 1; RS2 = 2; RD = 7;
    `RF_PATH.mem[RS1] = 32'd123;
    `RF_PATH.mem[RS2] = 32'd0;
    `IMEM_PATH.mem[INST_ADDR] = {`FNC7_MUL, RS2, RS1, `FNC_DIV, RD, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(RD, 32'hffff_ffff, "DIV 123/0 -> -1");

    // DIVU by zero: 123 / 0 -> 0xffffffff
    reset();
    `RF_PATH.mem[RS1] = 32'd123;
    `RF_PATH.mem[RS2] = 32'd0;
    `IMEM_PATH.mem[INST_ADDR] = {`FNC7_MUL, RS2, RS1, `FNC_DIVU, RD, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(RD, 32'hffff_ffff, "DIVU 123/0 -> 0xffffffff");

    // REM by zero:  123 % 0 -> 123
    reset();
    `RF_PATH.mem[RS1] = 32'd123;
    `RF_PATH.mem[RS2] = 32'd0;
    `IMEM_PATH.mem[INST_ADDR] = {`FNC7_MUL, RS2, RS1, `FNC_REM, RD, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(RD, 32'd123, "REM 123%0 -> 123");

    // REMU by zero: 123 % 0 -> 123
    reset();
    `RF_PATH.mem[RS1] = 32'd123;
    `RF_PATH.mem[RS2] = 32'd0;
    `IMEM_PATH.mem[INST_ADDR] = {`FNC7_MUL, RS2, RS1, `FNC_REMU, RD, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(RD, 32'd123, "REMU 123%0 -> 123");

    // ---------- Hazard 1: back-to-back DIV and REM sharing rd ----------
    // x1 = 100, x2 = 7
    // DIV  x3,x1,x2  => 14
    // REM  x3,x1,x2  => 2  (same rd, WAW on x3 in pipe)
    reset();
    RS1 = 1; RS2 = 2;
    `RF_PATH.mem[1] = 32'd100;
    `RF_PATH.mem[2] = 32'd7;
    `IMEM_PATH.mem[INST_ADDR + 0] = {`FNC7_MUL, RS2, RS1, `FNC_DIV, 5'd3, `OPC_ARI_RTYPE};
    `IMEM_PATH.mem[INST_ADDR + 1] = {`FNC7_MUL, RS2, RS1, `FNC_REM, 5'd3, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(5'd3, 32'd14, "Hazard1 DIV 100/7");
    check_result_rf(5'd3, 32'd2,  "Hazard1 REM 100%7");

    // ---------- Hazard 2: MIX of MUL and DIV with RAW on same source regs ----------
    // x5 = 6, x6 = 7:
    // MUL  x7,x5,x6   => 42
    // DIV  x8,x7,x5   => 7    (x7 result used as dividend)
    // REMU x9,x7,x6   => 0
    reset();
    `RF_PATH.mem[5] = 32'd6;
    `RF_PATH.mem[6] = 32'd7;
    `IMEM_PATH.mem[INST_ADDR + 0] = {`FNC7_MUL, 5'd6, 5'd5, `FNC_MUL,  5'd7, `OPC_ARI_RTYPE};
    `IMEM_PATH.mem[INST_ADDR + 1] = {`FNC7_MUL, 5'd5, 5'd7, `FNC_DIV,  5'd8, `OPC_ARI_RTYPE};
    `IMEM_PATH.mem[INST_ADDR + 2] = {`FNC7_MUL, 5'd6, 5'd7, `FNC_REMU, 5'd9, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(5'd7, 32'd42, "Hazard2 MUL 6*7");
    check_result_rf(5'd8, 32'd7,  "Hazard2 DIV 42/6");
    check_result_rf(5'd9, 32'd0,  "Hazard2 REMU 42%7");

    // ---------- Hazard 3: three different M ops, no RAW between them ----------
    // Independent streams should not stall each other:
    // x10,x11: MUL; x12,x13: DIV; x14,x15: REM
    reset();
    `RF_PATH.mem[10] = 32'd3;
    `RF_PATH.mem[11] = 32'd5;
    `RF_PATH.mem[12] = 32'd40;
    `RF_PATH.mem[13] = 32'd8;
    `RF_PATH.mem[14] = 32'd55;
    `RF_PATH.mem[15] = 32'd9;
    `IMEM_PATH.mem[INST_ADDR + 0] = {`FNC7_MUL, 5'd11, 5'd10, `FNC_MUL, 5'd16, `OPC_ARI_RTYPE}; // 3*5=15
    `IMEM_PATH.mem[INST_ADDR + 1] = {`FNC7_MUL, 5'd13, 5'd12, `FNC_DIVU,5'd17, `OPC_ARI_RTYPE}; // 40/8=5
    `IMEM_PATH.mem[INST_ADDR + 2] = {`FNC7_MUL, 5'd15, 5'd14, `FNC_REM, 5'd18, `OPC_ARI_RTYPE}; // 55%9=1
    reset_cpu();
    check_result_rf(5'd16, 32'd15, "Hazard3 MUL 3*5");
    check_result_rf(5'd17, 32'd5,  "Hazard3 DIVU 40/8");
    check_result_rf(5'd18, 32'd1,  "Hazard3 REM 55%9");

    // ---------- Hazard 4: DIV, unrelated ADD, then MUL using DIV result ----------
    // x1 = 30, x2 = 5, x5 = 3, x6 = 4, x8 = 2
    // DIV x3,x1,x2 => 6
    // ADD x4,x5,x6 => 7 (unrelated to DIV result)
    // MUL x7,x3,x8 => 12 (uses DIV result in x3)
    reset();
    `RF_PATH.mem[1] = 32'd30;
    `RF_PATH.mem[2] = 32'd5;
    `RF_PATH.mem[5] = 32'd3;
    `RF_PATH.mem[6] = 32'd4;
    `RF_PATH.mem[8] = 32'd2;
    // reuse INST_ADDR window; instructions are self-contained for this test
    `IMEM_PATH.mem[INST_ADDR + 0] = {`FNC7_MUL, 5'd2, 5'd1, `FNC_DIV,    5'd3, `OPC_ARI_RTYPE};
    `IMEM_PATH.mem[INST_ADDR + 1] = {`FNC7_0,   5'd6, 5'd5, `FNC_ADD_SUB,5'd4, `OPC_ARI_RTYPE};
    `IMEM_PATH.mem[INST_ADDR + 2] = {`FNC7_MUL, 5'd8, 5'd3, `FNC_MUL,    5'd7, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(5'd3, 32'd6,  "Hazard4 DIV 30/5");
    check_result_rf(5'd4, 32'd7,  "Hazard4 ADD 3+4");
    check_result_rf(5'd7, 32'd12, "Hazard4 MUL 6*2");

    // Existing basic DIV hazard: DIV then ADD using rd (must stall until divide completes)
    reset();
    RS1 = 1; RS2 = 2;
    `RF_PATH.mem[1] = 32'd100;
    `RF_PATH.mem[2] = 32'd10;
    `IMEM_PATH.mem[INST_ADDR + 0] = {`FNC7_MUL, 5'd2, 5'd1, `FNC_DIV, 5'd3, `OPC_ARI_RTYPE};
    `IMEM_PATH.mem[INST_ADDR + 1] = {`FNC7_0,   5'd1, 5'd3, `FNC_ADD_SUB, 5'd4, `OPC_ARI_RTYPE};
    reset_cpu();
    check_result_rf(5'd3, 32'd10,  "DIV hazard part1");
    check_result_rf(5'd4, 32'd110, "DIV hazard ADD after");

    // DIVU then MUL, back-to-back test
    reset();
    `RF_PATH.mem[20] = 32'd50;
    `RF_PATH.mem[21] = 32'd10;
    `RF_PATH.mem[22] = 32'd7;
    `IMEM_PATH.mem[INST_ADDR + 0] = {`FNC7_MUL, 5'd21, 5'd20, `FNC_DIVU, 5'd23, `OPC_ARI_RTYPE}; // DIVU x23, x20, x21 = 50/10=5
    `IMEM_PATH.mem[INST_ADDR + 1] = {`FNC7_MUL, 5'd22, 5'd23, `FNC_MUL, 5'd24, `OPC_ARI_RTYPE};  // MUL x24, x23, x22 = 5*7=35
    reset_cpu();
    check_result_rf(5'd23, 32'd5,  "DIVU followed by MUL -- DIVU 50/10");
    check_result_rf(5'd24, 32'd35, "DIVU followed by MUL -- MUL result");

    // ---------- Jump before DIV: JAL skips the DIV, DIV must not execute ----------
    // 0: JAL x5, +8   -> skip inst 1, land at inst 2; x5 = PC+4
    // 1: DIV x10, x1, x2  (would be 100/10=10) — must be skipped
    // 2: addi x6, x0, 1   (landing: x6=1)
    // Expect: x6=1 (we landed), x10=0 (DIV rd unchanged)
    reset();
    `RF_PATH.mem[1] = 32'd100;
    `RF_PATH.mem[2] = 32'd10;
    `IMEM_PATH.mem[INST_ADDR + 0] = {1'b0, 10'd4, 1'b0, 8'd0, 5'd5, `OPC_JAL};                    // JAL x5, +8
    `IMEM_PATH.mem[INST_ADDR + 1] = {`FNC7_MUL, 5'd2, 5'd1, `FNC_DIV, 5'd10, `OPC_ARI_RTYPE};       // DIV x10,x1,x2 (skipped)
    `IMEM_PATH.mem[INST_ADDR + 2] = {12'd1, 5'd0, `FNC_ADD_SUB, 5'd6, `OPC_ARI_ITYPE};             // addi x6, x0, 1
    reset_cpu();
    check_result_rf(5'd6, 32'd1, "Jump before DIV: landed at skip target");
    check_result_rf(5'd10, 32'd0, "Jump before DIV: DIV skipped (rd unchanged)");

    // ---------- Jump after DIV: DIV completes, then JAL is taken ----------
    // 0: DIV x10, x1, x2   => 20/10 = 2
    // 1: JAL x5, +12       => skip to inst 4; x5 = PC+4
    // 2: addi x6, x0, 0    (fall-through would set x6=0)
    // 3: addi x0, x0, 0    (nop)
    // 4: addi x6, x0, 1    (jump target: x6=1)
    // Expect: x10=2 (DIV result), x6=1 (jump was taken)
    reset();
    `RF_PATH.mem[1] = 32'd20;
    `RF_PATH.mem[2] = 32'd10;
    `IMEM_PATH.mem[INST_ADDR + 0] = {`FNC7_MUL, 5'd2, 5'd1, `FNC_DIV, 5'd10, `OPC_ARI_RTYPE};       // DIV x10,x1,x2
    `IMEM_PATH.mem[INST_ADDR + 1] = {1'b0, 10'd6, 1'b0, 8'd0, 5'd5, `OPC_JAL};                    // JAL x5, +12
    `IMEM_PATH.mem[INST_ADDR + 2] = {12'd0, 5'd0, `FNC_ADD_SUB, 5'd6, `OPC_ARI_ITYPE};             // addi x6, x0, 0
    `IMEM_PATH.mem[INST_ADDR + 3] = {12'd0, 5'd0, `FNC_ADD_SUB, 5'd0, `OPC_ARI_ITYPE};             // nop
    `IMEM_PATH.mem[INST_ADDR + 4] = {12'd1, 5'd0, `FNC_ADD_SUB, 5'd6, `OPC_ARI_ITYPE};             // addi x6, x0, 1
    reset_cpu();
    check_result_rf(5'd10, 32'd2, "Jump after DIV: DIV 20/10 completed");
    check_result_rf(5'd6, 32'd1, "Jump after DIV: JAL taken (landed at target)");

    all_tests_passed = 1'b1;
    repeat (50) @(posedge clk);
    $display("All M-extension tests passed!");
    $finish();
  end

endmodule
