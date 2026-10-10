`ifdef SYNTHESIS

module uart #(
    parameter int CLOCK_FREQ = 125_000_000,
    parameter int SYSTEM_CLOCK_FREQ = 100_000_000,
    parameter int BAUD_RATE = 115_200
) (
    input wire logic        clk,
    input wire logic        system_clk,
    input wire logic        reset,

    input wire logic  [7:0] data_in,
    input wire logic        data_in_valid,
    output logic        data_in_ready,

    output logic  [7:0] data_out,
    output logic        data_out_valid,
    input wire logic        data_out_ready,

    input wire logic        serial_in,
    output logic        serial_out
);
    logic serial_in_reg, serial_out_reg;
    logic serial_out_tx;
    assign serial_out = serial_out_reg;

    always_ff @ (posedge system_clk) begin
        if (reset) begin
            serial_out_reg <= 1'b1;
            serial_in_reg  <= 1'b1;
        end else begin
            serial_out_reg <= serial_out_tx;
            serial_in_reg  <= serial_in;
        end
    end

    logic tx_fifo_full, tx_fifo_empty, tx_fifo_rd_en, tx_wr_rst_busy, tx_rd_rst_busy;
    logic [7:0] tx_fifo_data_out;
    xpm_fifo_async #(
        .READ_DATA_WIDTH(8),
        .WRITE_DATA_WIDTH(8),
        .FIFO_WRITE_DEPTH(16),
        .FIFO_READ_LATENCY(0),
        .READ_MODE("fwft")
    ) tx_fifo (
        .rst(reset),
        .wr_clk(clk),
        .wr_rst_busy(tx_wr_rst_busy),
        .wr_en(data_in_valid),
        .din(data_in),
        .full(tx_fifo_full),
        .rd_clk(system_clk),
        .rd_rst_busy(tx_rd_rst_busy),
        .rd_en(tx_fifo_rd_en),
        .dout(tx_fifo_data_out),
        .empty(tx_fifo_empty)
    );
    assign data_in_ready = !tx_fifo_full && !tx_wr_rst_busy;

    uart_transmitter #(
        .CLOCK_FREQ(SYSTEM_CLOCK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) uatransmit (
        .clk(system_clk),
        .reset(reset),
        .data_in(tx_fifo_data_out),
        .data_in_valid(!tx_fifo_empty && !tx_rd_rst_busy),
        .data_in_ready(tx_fifo_rd_en),
        .serial_out(serial_out_tx)
    );

    logic rx_fifo_full, rx_fifo_empty, rx_fifo_wr_en, rx_wr_rst_busy, rx_rd_rst_busy;
    logic [7:0] rx_fifo_data_out;

    uart_receiver #(
        .CLOCK_FREQ(SYSTEM_CLOCK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) uareceive (
        .clk(system_clk),
        .reset(reset),
        .data_out(rx_fifo_data_out),
        .data_out_valid(rx_fifo_wr_en),
        .data_out_ready(!rx_fifo_full && !rx_wr_rst_busy),
        .serial_in(serial_in_reg)
    );

    xpm_fifo_async #(
        .READ_DATA_WIDTH(8),
        .WRITE_DATA_WIDTH(8),
        .FIFO_WRITE_DEPTH(16),
        .FIFO_READ_LATENCY(0),
        .READ_MODE("fwft")
    ) rx_fifo (
        .rst(reset),
        .wr_clk(system_clk),
        .wr_rst_busy(rx_wr_rst_busy),
        .wr_en(rx_fifo_wr_en),
        .din(rx_fifo_data_out),
        .full(rx_fifo_full),
        .rd_clk(clk),
        .rd_rst_busy(rx_rd_rst_busy),
        .rd_en(data_out_ready),
        .dout(data_out),
        .empty(rx_fifo_empty)
    );
    assign data_out_valid = !rx_fifo_empty && !rx_rd_rst_busy;

endmodule

`else // SIMULATION

module uart #(
    parameter CLOCK_FREQ = 100_000_000,
    parameter BAUD_RATE  = 115_200
) (
    input wire logic        clk,
    input wire logic        system_clk,
    input wire logic        reset,

    input wire logic  [7:0] data_in,
    input wire logic        data_in_valid,
    output logic        data_in_ready,

    output logic  [7:0] data_out,
    output logic        data_out_valid,
    input wire logic        data_out_ready,

    input wire logic        serial_in,
    output logic        serial_out
);
    logic serial_in_reg, serial_out_reg;
    logic serial_out_tx;
    assign serial_out = serial_out_reg;

    always_ff @ (posedge clk) begin
        serial_out_reg <= reset ? 1'b1 : serial_out_tx;
        serial_in_reg  <= reset ? 1'b1 : serial_in;
    end

    uart_transmitter #(
        .CLOCK_FREQ(CLOCK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) uatransmit (
        .clk(clk),
        .reset(reset),
        .data_in(data_in),
        .data_in_valid(data_in_valid),
        .data_in_ready(data_in_ready),
        .serial_out(serial_out_tx)
    );

    uart_receiver #(
        .CLOCK_FREQ(CLOCK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) uareceive (
        .clk(clk),
        .reset(reset),
        .data_out(data_out),
        .data_out_valid(data_out_valid),
        .data_out_ready(data_out_ready),
        .serial_in(serial_in_reg)
    );

endmodule

`endif
