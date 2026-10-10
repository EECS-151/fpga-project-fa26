// Simple behavioral model of Xilinx div_gen_3 for Icarus Verilog.
// This is NOT cycle-accurate; it is only to let Icarus elaborate and run
// the RISC-V divider/ISA tests without the encrypted Xilinx netlist.

`ifdef IVERILOG

module div_gen_sim #(
    parameter int WIDTH = 32,
    parameter int DIV_LATENCY = 30
) (
    input wire logic        aclk,
    input wire logic        aresetn,
    // Divisor AXI-Stream
    input wire logic        s_axis_divisor_tvalid,
    output logic        s_axis_divisor_tready,
    input wire logic [((WIDTH+7)/8)*8-1:0] s_axis_divisor_tdata,
    // Dividend AXI-Stream
    input wire logic        s_axis_dividend_tvalid,
    output logic        s_axis_dividend_tready,
    input wire logic [((WIDTH+7)/8)*8-1:0] s_axis_dividend_tdata,
    // Result AXI-Stream
    output logic        m_axis_dout_tvalid,
    output logic [2*((WIDTH+7)/8)*8-1:0] m_axis_dout_tdata,
    output logic [0:0]  m_axis_dout_tuser
);

  // Round up to nearest byte for operand width; quotient+remainder = 2*BITS.
  localparam int BITS      = ((WIDTH + 7) / 8) * 8;
  localparam int CNT_WIDTH = $clog2(DIV_LATENCY + 1);

  logic        busy;
  logic [CNT_WIDTH-1:0] cnt;

  logic signed [WIDTH-1:0] dividend_s;
  logic signed [WIDTH-1:0] divisor_s;

  assign s_axis_divisor_tready  = !busy;
  assign s_axis_dividend_tready = !busy;

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      m_axis_dout_tvalid <= 1'b0;
      m_axis_dout_tdata  <= '0;
      m_axis_dout_tuser  <= 1'b0;
      busy               <= 1'b0;
      cnt                <= '0;
    end else begin
      // Default: no new valid result this cycle
      m_axis_dout_tvalid <= 1'b0;
      m_axis_dout_tuser  <= 1'b0;

      if (!busy) begin
        // Accept a new transaction when not busy.
        if (s_axis_divisor_tvalid && s_axis_dividend_tvalid) begin
          dividend_s <= s_axis_dividend_tdata[WIDTH-1:0];
          divisor_s  <= s_axis_divisor_tdata[WIDTH-1:0];
          busy       <= 1'b1;
          cnt        <= DIV_LATENCY[CNT_WIDTH-1:0];
        end
      end else begin
        // Busy: count down latency and produce result when counter expires.
        if (cnt != 0) begin
          cnt <= cnt - 1'b1;
        end else begin
          // Time to produce result
          if (divisor_s == 0) begin
            // Signal divide-by-zero via tuser[0], clear data
            m_axis_dout_tuser[0] <= 1'b1;
            m_axis_dout_tdata    <= {2*BITS{1'b0}};
          end else begin
            // remainder in [BITS-1:0], quotient in [2*BITS-1:BITS]; result is WIDTH bits, zero-pad to BITS
            m_axis_dout_tdata[BITS-1:0]      <= (BITS > WIDTH) ? {{(BITS-WIDTH){1'b0}}, dividend_s % divisor_s} : dividend_s % divisor_s;
            m_axis_dout_tdata[2*BITS-1:BITS] <= (BITS > WIDTH) ? {{(BITS-WIDTH){1'b0}}, dividend_s / divisor_s} : dividend_s / divisor_s;
            m_axis_dout_tuser[0]             <= 1'b0;
          end
          m_axis_dout_tvalid <= 1'b1;
          busy               <= 1'b0;
        end
      end
    end
  end

endmodule

`endif

