module imem (
  input wire logic clk,
  input wire logic ena,
  input wire logic [3:0] wea,
  input wire logic [14:0] addra,
  input wire logic [31:0] dina,
  input wire logic [14:0] addrb,
  output logic [31:0] doutb
);
  parameter DEPTH = 32768;

  // See page 133 of the Vivado Synthesis Guide for the template
  // https://www.xilinx.com/support/documentation/sw_manuals/xilinx2016_4/ug901-vivado-synthesis.pdf

  logic [31:0] mem [DEPTH-1:0];
  integer i;
  always @(posedge clk) begin
    if (ena) begin
      for(i=0; i<4; i=i+1) begin
        if (wea[i]) begin
          mem[addra][i*8 +: 8] <= dina[i*8 +: 8];
        end
      end
    end
  end

  always_ff @(posedge clk) begin
      doutb <= mem[addrb];
  end
endmodule
