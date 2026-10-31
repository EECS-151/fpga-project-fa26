`default_nettype none
module clocks #(
    parameter int CLK_PERIOD = 10, // period of the primary clock into the FPGA
    // Sets the CPU clock = 100Mhz * 34 / 4 / 17 = 50 MHz
    parameter int CPU_CLK_CLKFBOUT_MULT = 34,
    parameter int CPU_CLK_DIVCLK_DIVIDE = 4,
    parameter int CPU_CLK_CLKOUT_DIVIDE = 17,
    // Checkpoint 3: generate the accelerator clock (in MHz: a multiple of 5, from 50 to 350)
    parameter bit HAS_ACCEL = 1'b0,
    parameter int ACCEL_CLOCK_MHZ = 100
) (
    input wire logic clk_100mhz,
    output logic cpu_clk,
    output logic cpu_clk_locked,
    output logic accel_clk,         // without HAS_ACCEL: 0, never locked
    output logic accel_clk_locked
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

    if (HAS_ACCEL) begin : g_accel
        // This MMCM generates the accel_clk from the 100 MHz clock, on its own:
        //   accel_clk = 100 MHz / 5 * M / O, with O = 4 * ceil(200 / ACCEL_CLOCK_MHZ) and
        //   M = ACCEL_CLOCK_MHZ * O / 20, which keeps the VCO (100 MHz / 5 * M) in 800..1600 MHz
        localparam int ACCEL_CLK_DIVCLK_DIVIDE = 5;
        localparam int ACCEL_CLK_CLKOUT_DIVIDE = 4 * ((200 + ACCEL_CLOCK_MHZ - 1) / ACCEL_CLOCK_MHZ);
        localparam int ACCEL_CLK_CLKFBOUT_MULT = ACCEL_CLOCK_MHZ * ACCEL_CLK_CLKOUT_DIVIDE / 20;

        if (ACCEL_CLOCK_MHZ % 5 != 0 || ACCEL_CLOCK_MHZ < 50 || ACCEL_CLOCK_MHZ > 350) begin : g_bad_accel_clock
            $error("ACCEL_CLOCK_MHZ = %0d: it must be a multiple of 5, from 50 to 350", ACCEL_CLOCK_MHZ);
        end

        logic accel_clk_int, accel_clk_fb;

        BUFG accel_clk_buf    (.I(accel_clk_int),     .O(accel_clk));

        MMCME4_BASE #(
            .BANDWIDTH            ("OPTIMIZED"),
            .STARTUP_WAIT         ("FALSE"),
            .DIVCLK_DIVIDE        (ACCEL_CLK_DIVCLK_DIVIDE),
            .CLKFBOUT_MULT_F      (ACCEL_CLK_CLKFBOUT_MULT),
            .CLKFBOUT_PHASE       (0.000),
            .CLKOUT0_DIVIDE_F     (ACCEL_CLK_CLKOUT_DIVIDE),
            .CLKOUT0_PHASE        (0.000),
            .CLKOUT0_DUTY_CYCLE   (0.500),
            .CLKIN1_PERIOD        (CLK_PERIOD)
        ) mmcm_accel_inst (
            .CLKFBOUT            (accel_clk_fb),
            .CLKFBOUTB           (),
            .CLKOUT0             (accel_clk_int),
            .CLKOUT0B            (),
            .CLKOUT1             (),
            .CLKOUT1B            (),
            .CLKOUT2             (),
            .CLKOUT2B            (),
            .CLKOUT3             (),
            .CLKOUT3B            (),
            .CLKOUT4             (),
            .CLKOUT5             (),
            .CLKOUT6             (),
            .CLKFBIN             (accel_clk_fb),       // internal feedback
            .CLKIN1              (clk_100mhz),
            .LOCKED              (accel_clk_locked),
            .PWRDWN              (1'b0),
            .RST                 (1'b0)
        );
    end else begin : g_no_accel
        assign accel_clk        = 1'b0;
        assign accel_clk_locked = 1'b0;
    end

endmodule
