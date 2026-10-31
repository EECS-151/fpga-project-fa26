`default_nettype none
// msg_egress: a 4-entry queue of our order messages -> the outbound stream, each stamped with
// out_seq as it is queued. `room` (3 free entries) fits one event's worst case: bid, ask and
// CANCEL_ALL.
module msg_egress #(
    parameter int BUS_BYTES = 8                        // 1, 2, 4 or 8
) (
    input  wire logic                     clk,
    input  wire logic                     rst,
    input  wire logic                     clear,            // session start: out_seq back to 0
    input  wire logic                     enqueue_valid,
    input  wire logic [63:0]              enqueue_msg,      // seq field left 0
    output logic                     room,
    output logic [8*BUS_BYTES-1:0]   tx_tdata,
    output logic                     tx_tvalid,
    output logic                     tx_tlast,
    input  wire logic                     tx_tready,
    output logic                     idle              // nothing queued or going out (response_closer)
);
    localparam int BEAT_BITS = 8 * BUS_BYTES;
    localparam int BEATS_PER_MSG = 8 / BUS_BYTES;
    localparam int QUEUE_DEPTH = 4;

    logic [63:0] queue_msg        [QUEUE_DEPTH];
    logic        queue_ends_frame [QUEUE_DEPTH];     // the message carries EOE
    logic [1:0]  queue_head, queue_tail;
    logic [2:0]  queue_count;
    logic [7:0]  out_seq;
    logic        serializing;                        // a message is going out
    logic [63:0] serializer_msg;
    logic        serializer_ends_frame;
    logic [2:0]  beat_idx;                           // its next beat

    assign room = queue_count <= 3'(QUEUE_DEPTH - 3);
    assign idle = queue_count == 3'd0 && !serializing && !tx_tvalid;

    function automatic logic [BEAT_BITS-1:0] beat_of(input logic [63:0] msg, input int idx);
        return msg[63 - BEAT_BITS * idx -: BEAT_BITS];
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            queue_head <= '0; queue_tail <= '0; queue_count <= '0; out_seq <= '0;
            serializing <= 1'b0; beat_idx <= '0;
            tx_tdata <= '0; tx_tvalid <= 1'b0; tx_tlast <= 1'b0;
        end else begin
            logic [2:0]  count;
            logic        serializing_next;
            logic [3:0]  beat_idx_next;             // one bit wider: it can reach BEATS_PER_MSG
            logic [7:0]  seq;
            logic [63:0] stamped;
            logic        handshake;
            count            = queue_count;
            serializing_next = serializing;
            beat_idx_next    = {1'b0, beat_idx};
            handshake        = tx_tvalid && tx_tready;

            if (clear) out_seq <= '0;
            // enqueue, stamping out_seq
            if (enqueue_valid) begin
                seq     = clear ? 8'd0 : out_seq;
                stamped = enqueue_msg | {8'd0, seq, 48'd0};
                queue_msg[queue_tail]        <= stamped;
                queue_ends_frame[queue_tail] <= stamped[57];
                queue_tail <= queue_tail + 2'd1;
                out_seq    <= seq + 8'd1;
                count       = count + 3'd1;
            end

            // serializer
            if (handshake) begin
                beat_idx_next = beat_idx_next + 4'd1;
                if (beat_idx_next == 4'(BEATS_PER_MSG)) begin serializing_next = 1'b0; beat_idx_next = '0; end
            end
            if (!serializing_next && queue_count > 3'd0) begin              // start the next message
                serializer_msg        <= queue_msg[queue_head];
                serializer_ends_frame <= queue_ends_frame[queue_head];
                queue_head            <= queue_head + 2'd1;
                count                  = count - 3'd1;
                serializing_next       = 1'b1;
                beat_idx_next          = '0;
                tx_tdata  <= beat_of(queue_msg[queue_head], 0);
                tx_tlast  <= (BEATS_PER_MSG == 1) && queue_ends_frame[queue_head];
                tx_tvalid <= 1'b1;
            end else if (serializing_next) begin                             // its next beat
                if (handshake || !tx_tvalid) begin
                    tx_tdata  <= beat_of(serializer_msg, int'(beat_idx_next));
                    tx_tlast  <= (beat_idx_next == 4'(BEATS_PER_MSG - 1)) && serializer_ends_frame;
                    tx_tvalid <= 1'b1;
                end
            end else begin
                tx_tvalid <= 1'b0;
            end
            serializing <= serializing_next;
            beat_idx    <= beat_idx_next[2:0];
            queue_count <= count;
        end
    end
endmodule
