module fifo #(
    parameter WIDTH = 8,
    parameter DEPTH = 32,
    parameter POINTER_WIDTH = $clog2(DEPTH)
) (
    input wire logic clk, rst,

    // Write side
    input wire logic wr_en,
    input wire logic [WIDTH-1:0] din,
    output logic full,

    // Read side
    input wire logic rd_en,
    output logic [WIDTH-1:0] dout,
    output logic empty
);
    assign full = 1'b1;
    assign empty = 1'b0;
    assign dout = 0;
endmodule
