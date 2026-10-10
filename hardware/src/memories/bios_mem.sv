module bios_mem (
    input wire logic clk,
    input wire logic ena,
    input wire logic [11:0] addra,
    output logic [31:0] douta,
    input wire logic enb,
    input wire logic [11:0] addrb,
    output logic [31:0] doutb
);
    parameter DEPTH = 4096;
    logic [31:0] mem [4096-1:0];
    always_ff @(posedge clk) begin
        if (ena) begin
            douta <= mem[addra];
        end
    end

    always_ff @(posedge clk) begin
        if (enb) begin
            doutb <= mem[addrb];
        end
    end

    `define STRINGIFY_BIOS(x) `"x/../software/bios/bios.hex`"
    `ifdef SYNTHESIS
        initial begin
            $readmemh(`STRINGIFY_BIOS(`ABS_TOP), mem);
        end
    `endif
endmodule
