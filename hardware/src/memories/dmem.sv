module dmem (
  input wire logic clk,
  input wire logic en,
  input wire logic [3:0] we,
  input wire logic [14:0] addr,
  input wire logic [31:0] din,
  output logic [31:0] dout
);
  parameter DEPTH = 32768;

  // See page 133 of the Vivado Synthesis Guide for the template
  // https://www.xilinx.com/support/documentation/sw_manuals/xilinx2016_4/ug901-vivado-synthesis.pdf

  logic [31:0] mem [DEPTH-1:0];
  integer i;
  always @(posedge clk) begin
    if (en) begin
      for(i=0; i<4; i=i+1) begin
        if (we[i]) begin
          mem[addr][i*8 +: 8] <= din[i*8 +: 8];
        end
      end
      dout <= mem[addr];
    end
  end
endmodule
