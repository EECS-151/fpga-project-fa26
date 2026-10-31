`default_nettype none
// ffs256 / ffs64: find the highest and second-highest set bits of `vec`.
module ffs256 (
    input  wire logic         clk,
    input  wire logic         start,
    input  wire logic [255:0] vec,
    output logic         valid,
    output logic         found,
    output logic [7:0]   index,
    output logic         second_found,
    output logic [7:0]   second_index
);
    // TODO: your implementation here
endmodule

module ffs64 (
    input  wire logic        clk,
    input  wire logic        start,
    input  wire logic [63:0] vec,
    output logic        valid,
    output logic        found,
    output logic [5:0]  index,
    output logic        second_found,
    output logic [5:0]  second_index
);
    // TODO: your implementation here
endmodule
