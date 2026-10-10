module uart_transmitter #(
    parameter CLOCK_FREQ = 125_000_000,
    parameter BAUD_RATE = 115_200)
(
    input wire logic clk,
    input wire logic reset,

    input wire logic [7:0] data_in,
    input wire logic data_in_valid,
    output logic data_in_ready,

    output logic serial_out
);
    // See diagram in the lab guide
    localparam  SYMBOL_EDGE_TIME    =   CLOCK_FREQ / BAUD_RATE;
    localparam  CLOCK_COUNTER_WIDTH =   $clog2(SYMBOL_EDGE_TIME);

    // Remove these assignments when implementing this module
    assign serial_out = 1'b0;
    assign data_in_ready = 1'b0;
endmodule
