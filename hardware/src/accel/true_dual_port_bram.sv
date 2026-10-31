`default_nettype none
// True dual-port BRAM, READ_FIRST on both ports.
// OUT_REG=1 adds the BRAM output register (RAMB DOUT_REG): read latency 2.
module true_dual_port_bram #(
    parameter int DATA_WIDTH = 16,
    parameter int DEPTH      = 16384,
    parameter int ADDR_WIDTH = $clog2(DEPTH),
    parameter bit OUT_REG    = 1'b1
) (
    // Port A
    input  wire logic                  clka,
    input  wire logic                  ena,
    input  wire logic                  wea,
    input  wire logic [ADDR_WIDTH-1:0] addra,
    input  wire logic [DATA_WIDTH-1:0] dia,
    output logic [DATA_WIDTH-1:0] doa,

    // Port B
    input  wire logic                  clkb,
    input  wire logic                  enb,
    input  wire logic                  web,
    input  wire logic [ADDR_WIDTH-1:0] addrb,
    input  wire logic [DATA_WIDTH-1:0] dib,
    output logic [DATA_WIDTH-1:0] dob
);
    localparam int RAM_DEPTH = 1 << ADDR_WIDTH;

    /* verilator lint_off MULTIDRIVEN */
    (* ram_style = "block" *) logic [DATA_WIDTH-1:0] ram [RAM_DEPTH];
    /* verilator lint_on MULTIDRIVEN */

    logic [DATA_WIDTH-1:0] doa_r, dob_r;

    // Plain always (not always_ff): both ports may write ram, which always_ff forbids.
    always @(posedge clka) begin
        if (ena) begin
            if (wea) ram[addra] <= dia;
            doa_r <= ram[addra];
        end
    end

    always @(posedge clkb) begin
        if (enb) begin
            if (web) ram[addrb] <= dib;
            dob_r <= ram[addrb];
        end
    end

    if (OUT_REG) begin : g_oreg
        always_ff @(posedge clka) doa <= doa_r;
        always_ff @(posedge clkb) dob <= dob_r;
    end else begin : g_noreg
        assign doa = doa_r;
        assign dob = dob_r;
    end
endmodule
