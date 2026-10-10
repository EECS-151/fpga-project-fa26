module zu3top #(
    parameter int BAUD_RATE = 115_200,
    // Warning: CPU_CLOCK_FREQ must match the PLL parameters!
    parameter int CPU_CLOCK_FREQ = 100_000_000,
    // PLL Parameters: sets the CPU clock = 100Mhz * (12 / 1) / 12 = 100 MHz
    parameter int CPU_CLK_CLKFBOUT_MULT = 12,
    parameter int CPU_CLK_DIVCLK_DIVIDE = 1,
    parameter int CPU_CLK_CLKOUT_DIVIDE  = 12,
    
    /* verilator lint_off REALCVT */
    // Sample the button signal every 500us
    parameter int B_SAMPLE_CNT_MAX = int'(0.0005 * CPU_CLOCK_FREQ),
    // The button is considered 'pressed' after 100ms of continuous pressing
    parameter int B_PULSE_CNT_MAX = int'(0.100 / 0.0005),
    /* lint_on */
    // The PC the RISC-V CPU should start at after reset
    parameter logic [31:0] RESET_PC = 32'h4000_0000
) (
    input wire logic        CLK_100_P,
    input wire logic        CLK_100_N,
    input wire logic [3:0]  BUTTONS,
    input wire logic [7:0]  SWITCHES,
    output logic [7:0]  LEDS,
    input wire logic        FPGA_SERIAL_RX,
    output logic        FPGA_SERIAL_TX,


    output logic        eth_reset_n,
    input wire logic        eth_ref_clk,
    input wire logic        eth_crs_dv,
    input wire logic        eth_rxd0,
    input wire logic        eth_rxd1,
    output logic        eth_tx_en,
    output logic        eth_txd0,
    output logic        eth_txd1
);

    // The board's 100 MHz clock, buffered by the Ethernet interface (it owns the IBUFDS)
    logic CLK_100MHZ;

    // Clocks and PLL lock status
    logic cpu_clk, cpu_clk_locked;

    // Buttons after the button_parser
    logic [3:0] buttons_pressed;

    // Switches after the synchronizer
    logic [7:0] switches_sync;

    // Reset the CPU and all components on the cpu_clk if the reset button is
    // pushed or whenever the CPU clock PLL isn't locked
    logic cpu_reset;
    assign cpu_reset = buttons_pressed[0] || !cpu_clk_locked;

    // Use IOBs to drive/sense the UART serial lines
    logic cpu_tx, cpu_rx;
    (* IOB = "true" *) logic fpga_serial_tx_iob;
    (* IOB = "true" *) logic fpga_serial_rx_iob;
    assign FPGA_SERIAL_TX = fpga_serial_tx_iob;
    assign cpu_rx = fpga_serial_rx_iob;

    always_ff @(posedge CLK_100MHZ) begin
        fpga_serial_tx_iob <= cpu_tx;
        fpga_serial_rx_iob <= FPGA_SERIAL_RX;
    end

    clocks #(
        .CPU_CLK_CLKFBOUT_MULT(CPU_CLK_CLKFBOUT_MULT),
        .CPU_CLK_DIVCLK_DIVIDE(CPU_CLK_DIVCLK_DIVIDE),
        .CPU_CLK_CLKOUT_DIVIDE(CPU_CLK_CLKOUT_DIVIDE)
    ) clk_gen (
        .clk_100mhz(CLK_100MHZ),
        .cpu_clk(cpu_clk),
        .cpu_clk_locked(cpu_clk_locked)
    );

    button_parser #(
        .WIDTH(4),
        .SAMPLE_CNT_MAX(B_SAMPLE_CNT_MAX),
        .PULSE_CNT_MAX(B_PULSE_CNT_MAX)
    ) bp (
        .clk(cpu_clk),
        .in(BUTTONS),
        .out(buttons_pressed)
    );

    synchronizer #(
        .WIDTH(8)
    ) switch_synchronizer (
        .clk(cpu_clk),
        .async_signal(SWITCHES),
        .sync_signal(switches_sync)
    );

    // Ethernet: the provided interface (PHY, MAC, framing, EtherType filter, addressing), with
    // its byte streams on cpu_clk for the CPU's MMIO. Provided: do not modify.
    // SWITCHES[7:3] is the board id: the last octet of the board's MAC address.
    logic [7:0] cpu_eth_rx_data, cpu_eth_tx_data;
    logic       cpu_eth_rx_valid, cpu_eth_rx_last, cpu_eth_rx_ready;
    logic       cpu_eth_tx_valid, cpu_eth_tx_ready, cpu_eth_tx_end, cpu_eth_link_up;

    eth_seal eth (
        .CLK_100_P(CLK_100_P),
        .CLK_100_N(CLK_100_N),
        .eth_reset_n(eth_reset_n),
        .eth_ref_clk(eth_ref_clk),
        .eth_crs_dv(eth_crs_dv),
        .eth_rxd0(eth_rxd0),
        .eth_rxd1(eth_rxd1),
        .eth_tx_en(eth_tx_en),
        .eth_txd0(eth_txd0),
        .eth_txd1(eth_txd1),
        .board_id(SWITCHES[7:3]),
        .clk_100(CLK_100MHZ),
        .clk(cpu_clk),
        .rst(cpu_reset),
        .rx_data(cpu_eth_rx_data),
        .rx_valid(cpu_eth_rx_valid),
        .rx_last(cpu_eth_rx_last),
        .rx_ready(cpu_eth_rx_ready),
        .tx_data(cpu_eth_tx_data),
        .tx_valid(cpu_eth_tx_valid),
        .tx_ready(cpu_eth_tx_ready),
        .tx_end(cpu_eth_tx_end),
        .link_up(cpu_eth_link_up)
    );

    logic [2:0] cpu_error_vector;
    cpu #(
        .CPU_CLOCK_FREQ(CPU_CLOCK_FREQ),
        .SYSTEM_CLOCK_FREQ(100_000_000),
        .RESET_PC(RESET_PC),
        .BAUD_RATE(BAUD_RATE)
    ) cpu_inst (
        .clk(cpu_clk),
        .rst(cpu_reset),
        .system_clk(CLK_100MHZ),
        .bp_enable(switches_sync[0]),
        .serial_out(cpu_tx),
        .serial_in(cpu_rx),
        .eth_rx_data(cpu_eth_rx_data),
        .eth_rx_valid(cpu_eth_rx_valid),
        .eth_rx_last(cpu_eth_rx_last),
        .eth_rx_ready(cpu_eth_rx_ready),
        .eth_tx_data(cpu_eth_tx_data),
        .eth_tx_valid(cpu_eth_tx_valid),
        .eth_tx_ready(cpu_eth_tx_ready),
        .eth_tx_end(cpu_eth_tx_end),
        .eth_link_up(cpu_eth_link_up),
        .errors(cpu_error_vector)
    );

    logic [2:0] error_vector;
    always_ff @(posedge cpu_clk) begin
        if (cpu_reset)
            error_vector <= 3'b0;
        else
            error_vector <= error_vector | cpu_error_vector;
    end

    assign LEDS = {4'd0, cpu_eth_link_up, error_vector[2:0]};
endmodule
