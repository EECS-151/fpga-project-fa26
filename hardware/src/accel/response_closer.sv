`default_nettype none
// response_closer: pulses tx_end, closing a frame's response, once the frame's last beat is in
// and the accelerator is quiescent.
module response_closer (
    input  wire logic clk,
    input  wire logic rst,
    input  wire logic rx_done,                               // the frame's last beat was accepted
    input  wire logic core_quiescent,
    output logic tx_end                                 // one cycle: the response is complete
);
    logic draining;                                     // the frame is in; its work isn't done yet

    always_ff @(posedge clk) begin
        tx_end <= 1'b0;
        if (rst) begin
            draining <= 1'b0;
        end else if (rx_done) begin
            draining <= 1'b1;
        end else if (draining && core_quiescent) begin
            draining <= 1'b0;
            tx_end   <= 1'b1;
        end
    end
endmodule
