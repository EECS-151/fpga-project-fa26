module clocks #(
    parameter int CLK_PERIOD = 10, // period of the primary clock into the FPGA
    // Sets the CPU clock = 100Mhz * 34 / 4 / 17 = 50 MHz
    parameter int CPU_CLK_CLKFBOUT_MULT = 34,
    parameter int CPU_CLK_DIVCLK_DIVIDE = 4,
    parameter int CPU_CLK_CLKOUT_DIVIDE = 17
) (
    input wire logic clk_100mhz,
    output logic cpu_clk,
    output logic cpu_clk_locked
);

    logic cpu_clk_int, cpu_clk_g;
    logic cpu_clk_pll_fb_out, cpu_clk_pll_fb_in;

    assign cpu_clk = cpu_clk_g;

    BUFG cpu_clk_buf      (.I(cpu_clk_int),       .O(cpu_clk_g));
    BUFG cpu_clk_f_buf    (.I(cpu_clk_pll_fb_out),.O(cpu_clk_pll_fb_in));

    // This PLL generates the cpu_clk from the 100 Mhz clock
    PLLE2_ADV #(
        .BANDWIDTH            ("OPTIMIZED"),
        .COMPENSATION         ("BUF_IN"),  // Not "ZHOLD"
        .STARTUP_WAIT         ("FALSE"),
        .DIVCLK_DIVIDE        (CPU_CLK_DIVCLK_DIVIDE),
        .CLKFBOUT_MULT        (CPU_CLK_CLKFBOUT_MULT),
        .CLKFBOUT_PHASE       (0.000),
        .CLKOUT0_DIVIDE       (CPU_CLK_CLKOUT_DIVIDE),
        .CLKOUT0_PHASE        (0.000),
        .CLKOUT0_DUTY_CYCLE   (0.500),
        .CLKIN1_PERIOD        (CLK_PERIOD)
    ) plle2_cpu_inst (
        .CLKFBOUT            (cpu_clk_pll_fb_out),
        .CLKOUT0             (cpu_clk_int),
        .CLKOUT1             (),
        .CLKOUT2             (),
        .CLKOUT3             (),
        .CLKOUT4             (),
        .CLKOUT5             (),
        // Input clock control
        .CLKFBIN             (cpu_clk_pll_fb_in),
        .CLKIN1              (clk_100mhz),
        .CLKIN2              (1'b0),
        // Tied to always select the primary input clock
        .CLKINSEL            (1'b1),
        // Other control and status signals
        .LOCKED              (cpu_clk_locked),
        .PWRDWN              (1'b0),
        .RST                 (1'b0),
        .DCLK                (1'b0),
        .DEN                 (1'b0),
        .DI                  (16'd0),
        .DWE                 (1'b0),
        .DADDR               (7'd0),
        .DO                  (),
        .DRDY                ()
    );
    
endmodule
