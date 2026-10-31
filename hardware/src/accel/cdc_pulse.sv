`default_nettype none
// cdc_pulse: carry a one-cycle pulse into another clock domain (toggle, then 2-flop sync)
// Pulses closer together than about 3 destination clocks can merge
module cdc_pulse (
    input  wire logic src_clk,
    input  wire logic src_rst,
    input  wire logic src_pulse,
    input  wire logic dst_clk,
    input  wire logic dst_rst,
    output logic dst_pulse
);
    logic toggle, dst_s3;
    (* ASYNC_REG = "TRUE" *) logic dst_s1, dst_s2;

    always_ff @(posedge src_clk) begin
        if (src_rst)        toggle <= 1'b0;
        else if (src_pulse) toggle <= ~toggle;
    end

    always_ff @(posedge dst_clk) begin
        if (dst_rst) begin
            dst_s1 <= 1'b0; dst_s2 <= 1'b0; dst_s3 <= 1'b0;
        end else begin
            dst_s1 <= toggle;
            dst_s2 <= dst_s1;
            dst_s3 <= dst_s2;
        end
    end
    assign dst_pulse = dst_s2 != dst_s3;
endmodule
