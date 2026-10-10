module reg_file (
    input wire logic clk,
    input wire logic we,
    input wire logic [4:0] ra1, ra2, wa,
    input wire logic [31:0] wd,
    output logic [31:0] rd1, rd2
);
    parameter DEPTH = 32;
    logic [31:0] mem [0:31];
    assign rd1 = 32'd0;
    assign rd2 = 32'd0;
endmodule
