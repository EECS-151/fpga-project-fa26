`default_nettype none
module zu3top #(
    parameter int BAUD_RATE = 115_200,
    // Warning: CPU_CLOCK_FREQ must match the PLL parameters!
    parameter int CPU_CLOCK_FREQ = 100_000_000,
    // PLL Parameters: sets the CPU clock = 100Mhz * (12 / 1) / 12 = 100 MHz
    parameter int CPU_CLK_CLKFBOUT_MULT = 12,
    parameter int CPU_CLK_DIVCLK_DIVIDE = 1,
    parameter int CPU_CLK_CLKOUT_DIVIDE  = 12,

    // Checkpoint 3 accelerator: HAS_ACCEL = 1'b1 adds it on its own clock, and moves the
    // Ethernet interface from the CPU to it; the CPU reaches it through its MMIO window
    // (0x8001_0000). Makefile reads this line to pick the constraints
    parameter bit HAS_ACCEL = 1'b0,
    // The accelerator clock in MHz, on its own MMCM: a multiple of 5, from 50 to 350
    parameter int ACCEL_CLOCK_MHZ = 100,

    // Sample the button signal every 500us
    parameter int B_SAMPLE_CNT_MAX = int'(0.0005 * CPU_CLOCK_FREQ),
    // The button is considered 'pressed' after 100ms of continuous pressing
    parameter int B_PULSE_CNT_MAX = int'(0.100 / 0.0005),

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

    // Clocks and PLL/MMCM lock status (accel_clk only with HAS_ACCEL)
    logic cpu_clk, cpu_clk_locked, accel_clk, accel_clk_locked;

    // Buttons after the button_parser
    logic [3:0] buttons_pressed;

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
        .CPU_CLK_CLKOUT_DIVIDE(CPU_CLK_CLKOUT_DIVIDE),
        .HAS_ACCEL(HAS_ACCEL),
        .ACCEL_CLOCK_MHZ(ACCEL_CLOCK_MHZ)
    ) clk_gen (
        .clk_100mhz(CLK_100MHZ),
        .cpu_clk(cpu_clk),
        .cpu_clk_locked(cpu_clk_locked),
        .accel_clk(accel_clk),
        .accel_clk_locked(accel_clk_locked)
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

    // Ethernet: the provided interface (PHY, MAC, framing, EtherType filter, addressing). Its byte
    // streams run on eth_clk: cpu_clk for the CPU's MMIO, or with HAS_ACCEL accel_clk for the
    // accelerator, which takes one inbound frame at a time and closes each response with tx_end.
    // Do not modify.
    logic       eth_clk, eth_rst;
    logic [7:0] eth_rx_data, eth_tx_data;
    logic       eth_rx_valid, eth_rx_last, eth_rx_ready;
    logic       eth_tx_valid, eth_tx_ready, eth_tx_end, eth_link_up;

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
        .clk(eth_clk),
        .rst(eth_rst),
        .rx_data(eth_rx_data),
        .rx_valid(eth_rx_valid),
        .rx_last(eth_rx_last),
        .rx_ready(eth_rx_ready),
        .tx_data(eth_tx_data),
        .tx_valid(eth_tx_valid),
        .tx_ready(eth_tx_ready),
        .tx_end(eth_tx_end),
        .link_up(eth_link_up)
    );

    logic [2:0] cpu_error_vector;
    logic       response_closed;   // LEDS[4]: the accelerator has closed a response (sticky until reset)

    if (!HAS_ACCEL) begin : g_no_accel
        // Checkpoint 2: Ethernet on the CPU's MMIO
        assign eth_clk = cpu_clk;
        assign eth_rst = cpu_reset;
        assign response_closed = 1'b0;

        cpu #(
            .CPU_CLOCK_FREQ(CPU_CLOCK_FREQ),
            .SYSTEM_CLOCK_FREQ(100_000_000),
            .RESET_PC(RESET_PC),
            .BAUD_RATE(BAUD_RATE)
        ) cpu_inst (
            .clk(cpu_clk),
            .rst(cpu_reset),
            .system_clk(CLK_100MHZ),
            .serial_out(cpu_tx),
            .serial_in(cpu_rx),
            .eth_rx_data(eth_rx_data),
            .eth_rx_valid(eth_rx_valid),
            .eth_rx_last(eth_rx_last),
            .eth_rx_ready(eth_rx_ready),
            .eth_tx_data(eth_tx_data),
            .eth_tx_valid(eth_tx_valid),
            .eth_tx_ready(eth_tx_ready),
            .eth_tx_end(eth_tx_end),
            .eth_link_up(eth_link_up),
            .errors(cpu_error_vector)
        );
    end else begin : g_accel
        // Checkpoint 3: Ethernet on the accelerator; the CPU reaches the accelerator through its
        // MMIO window, and its own Ethernet port is idle
        logic [9:0]  accel_addr;
        logic [31:0] accel_wdata, accel_rdata;
        logic        accel_we, accel_re;

        cpu #(
            .CPU_CLOCK_FREQ(CPU_CLOCK_FREQ),
            .SYSTEM_CLOCK_FREQ(100_000_000),
            .RESET_PC(RESET_PC),
            .BAUD_RATE(BAUD_RATE)
        ) cpu_inst (
            .clk(cpu_clk),
            .rst(cpu_reset),
            .system_clk(CLK_100MHZ),
            .serial_out(cpu_tx),
            .serial_in(cpu_rx),
            .eth_rx_data(8'd0),
            .eth_rx_valid(1'b0),
            .eth_rx_last(1'b0),
            .eth_rx_ready(),
            .eth_tx_data(),
            .eth_tx_valid(),
            .eth_tx_ready(1'b0),
            .eth_tx_end(),
            .eth_link_up(1'b0),
            .accel_addr(accel_addr),
            .accel_wdata(accel_wdata),
            .accel_we(accel_we),
            .accel_re(accel_re),
            .accel_rdata(accel_rdata),
            .errors(cpu_error_vector)
        );

        // The accelerator's reset: cpu_reset stretched to 8 cpu_clk cycles (a button press lasts
        // one), plus accel_clk not yet locked, synchronized into accel_clk
        logic       accel_reset_req, accel_reset;
        logic [2:0] accel_reset_count;
        always_ff @(posedge cpu_clk) begin
            if (cpu_reset) begin
                accel_reset_req   <= 1'b1;
                accel_reset_count <= 3'd7;
            end else if (accel_reset_count != 3'd0) begin
                accel_reset_count <= accel_reset_count - 3'd1;
            end else begin
                accel_reset_req   <= 1'b0;
            end
        end
        synchronizer #(.WIDTH(1)) accel_reset_synchronizer (
            .clk(accel_clk),
            .async_signal(accel_reset_req || !cpu_clk_locked || !accel_clk_locked),
            .sync_signal(accel_reset)
        );
        assign eth_clk = accel_clk;
        assign eth_rst = accel_reset;

        // Switches:
        //   SWITCHES[7:3]  board id: the accelerator's participant id, and the last octet of the
        //                  board's MAC address (02:00:00:00:00:{000, id}), latched at configuration
        //   SWITCHES[2:0]  unused
        logic [4:0] accel_pid;
        synchronizer #(.WIDTH(5)) pid_synchronizer (
            .clk(accel_clk),
            .async_signal(SWITCHES[7:3]),
            .sync_signal(accel_pid)
        );

        // BUTTONS[1]: local kill
        logic accel_kill;
        cdc_pulse kill_cdc (
            .src_clk(cpu_clk),
            .src_rst(cpu_reset),
            .src_pulse(buttons_pressed[1]),
            .dst_clk(accel_clk),
            .dst_rst(accel_reset),
            .dst_pulse(accel_kill)
        );

        accel_system accel (
            .clk(accel_clk),
            .rst(accel_reset),
            .pid(accel_pid),
            .kill(accel_kill),
            .rx_data(eth_rx_data),
            .rx_valid(eth_rx_valid),
            .rx_last(eth_rx_last),
            .rx_ready(eth_rx_ready),
            .tx_data(eth_tx_data),
            .tx_valid(eth_tx_valid),
            .tx_ready(eth_tx_ready),
            .tx_end(eth_tx_end),
            .cpu_clk(cpu_clk),
            .cpu_rst(cpu_reset),
            .cpu_addr(accel_addr),
            .cpu_wdata(accel_wdata),
            .cpu_we(accel_we),
            .cpu_re(accel_re),
            .cpu_rdata(accel_rdata)
        );

        always_ff @(posedge accel_clk) begin
            if (accel_reset)     response_closed <= 1'b0;
            else if (eth_tx_end) response_closed <= 1'b1;
        end
    end

    logic [2:0] error_vector;
    always_ff @(posedge cpu_clk) begin
        if (cpu_reset)
            error_vector <= 3'b0;
        else
            error_vector <= error_vector | cpu_error_vector;
    end

    // LEDS[3]: the Ethernet link is up (the exchange has been heard from)
    assign LEDS = {3'd0, response_closed, eth_link_up, error_vector[2:0]};
endmodule
