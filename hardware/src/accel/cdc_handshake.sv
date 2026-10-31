`default_nettype none
// cdc_handshake: carry a word across clock domains (two-phase req/ack). src_busy is high from a
// send until it is acknowledged, and sends while busy are ignored. ~3 dst + 3 src clocks each.
module cdc_handshake #(
    parameter int WIDTH = 32
) (
    input  wire logic             src_clk,
    input  wire logic             src_rst,
    input  wire logic             src_send,
    input  wire logic [WIDTH-1:0] src_data,
    output logic             src_busy,

    input  wire logic             dst_clk,
    input  wire logic             dst_rst,
    output logic             dst_valid,          // one cycle: dst_data was just updated
    output logic [WIDTH-1:0] dst_data            // holds the last word received
);
    logic [WIDTH-1:0] hold;
    logic             req, ack;
    (* ASYNC_REG = "TRUE" *) logic ack_s1, ack_s2;
    (* ASYNC_REG = "TRUE" *) logic req_s1, req_s2;

    // ---- source
    assign src_busy = req != ack_s2;
    always_ff @(posedge src_clk) begin
        if (src_rst) begin
            req <= 1'b0; ack_s1 <= 1'b0; ack_s2 <= 1'b0; hold <= '0;
        end else begin
            if (src_send && !src_busy) begin
                hold <= src_data;
                req  <= ~req;
            end
            ack_s1 <= ack;
            ack_s2 <= ack_s1;
        end
    end

    // ---- destination: ack is the last req value taken
    always_ff @(posedge dst_clk) begin
        if (dst_rst) begin
            req_s1 <= 1'b0; req_s2 <= 1'b0; ack <= 1'b0; dst_valid <= 1'b0; dst_data <= '0;
        end else begin
            req_s1    <= req;
            req_s2    <= req_s1;
            dst_valid <= req_s2 != ack;
            if (req_s2 != ack) begin
                dst_data <= hold;
                ack      <= req_s2;
            end
        end
    end
endmodule
