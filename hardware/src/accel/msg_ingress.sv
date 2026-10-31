`default_nettype none
// msg_ingress: the inbound stream -> classified 8-byte messages. A PAD type (0) at a message
// boundary skips the rest of the frame; a tlast mid-message drops the fragment.
module msg_ingress #(
    parameter int BUS_BYTES = 8                        // 1, 2, 4 or 8
) (
    input  wire logic                     clk,
    input  wire logic                     rst,
    input  wire logic [4:0]               pid,              // our participant id
    input  wire logic [8*BUS_BYTES-1:0]   rx_tdata,
    input  wire logic                     rx_tvalid,
    input  wire logic                     rx_tlast,
    output logic                     rx_tready,
    output logic [63:0]              msg_data,
    output logic [1:0]               msg_class,        // 0 public, 1 our private report, 2 foreign, 3 malformed
    output logic                     msg_valid,
    input  wire logic                     msg_ready,        // accel_ctrl takes the message this cycle
    output logic                     idle              // nothing collected or held (response_closer)
);
    localparam int BEAT_BITS = 8 * BUS_BYTES;
    localparam int BEATS_PER_MSG = 8 / BUS_BYTES;
    localparam logic [1:0] CLASS_PUBLIC = 2'd0, CLASS_OURS = 2'd1, CLASS_FOREIGN = 2'd2, CLASS_MALFORMED = 2'd3;
    localparam logic [3:0] TYPE_PAD = 4'h0, TYPE_BOOK_UPDATE = 4'h3, TYPE_TRADE = 4'h4;

    logic [BEAT_BITS-1:0] beat_buffer [BEATS_PER_MSG];
    logic [2:0]           beat_idx;                   // next beat of the message being collected
    logic                 skipping_padding;
    logic                 beat_buffer_full;

    assign idle = !msg_valid && !beat_buffer_full && beat_idx == 3'd0 && !skipping_padding;

    // the collected beats, beat 0 in the top byte(s)
    logic [63:0] packed_msg;
    always_comb begin
        packed_msg = '0;
        for (int i = 0; i < BEATS_PER_MSG; i++)
            packed_msg[63 - BEAT_BITS * i -: BEAT_BITS] = beat_buffer[i];
    end

    function automatic logic [1:0] classify(input logic [63:0] msg, input logic [4:0] our_pid);
        logic [3:0]  msg_type = msg[63:60];
        logic [15:0] px       = msg[47:32];
        if (msg_type inside {4'h1, 4'h2, 4'h3, 4'h4}) begin              // public feed
            if ((msg_type == TYPE_BOOK_UPDATE || msg_type == TYPE_TRADE) && !(px >= 16'd1 && px <= 16'd16383))
                return CLASS_MALFORMED;                                   // price out of range
            return CLASS_PUBLIC;
        end
        if (msg_type inside {4'h8, 4'h9, 4'hA, 4'hB})                    // a private report: whose?
            return (msg[47:43] == our_pid) ? CLASS_OURS : CLASS_FOREIGN;  // the order id's pid bits
        return CLASS_MALFORMED;                                           // unassigned or order-entry type
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_tready <= 1'b1; beat_idx <= '0; skipping_padding <= 1'b0; beat_buffer_full <= 1'b0;
            msg_valid <= 1'b0;
        end else begin
            logic load, full_next;
            if (msg_valid && msg_ready) msg_valid <= 1'b0;              // consumed

            // decode, only into an empty output register
            load      = beat_buffer_full && !msg_valid;
            full_next = beat_buffer_full && !load;
            if (load) begin
                msg_data         <= packed_msg;
                msg_class        <= classify(packed_msg, pid);
                msg_valid        <= 1'b1;
                beat_buffer_full <= 1'b0;
            end

            // collect beats
            if (rx_tvalid && rx_tready) begin
                if (skipping_padding) begin
                    if (rx_tlast) skipping_padding <= 1'b0;
                end else if (beat_idx == 3'd0 && rx_tdata[BEAT_BITS-1 -: 4] == TYPE_PAD) begin
                    if (!rx_tlast) skipping_padding <= 1'b1;             // the rest of the frame is padding
                end else begin
                    beat_buffer[beat_idx] <= rx_tdata;
                    if (beat_idx == 3'(BEATS_PER_MSG - 1)) begin         // a whole message
                        beat_buffer_full     <= 1'b1;
                        full_next             = 1'b1;
                        beat_idx             <= '0;
                    end else if (rx_tlast) begin                          // a fragment: drop it
                        beat_idx <= '0;
                    end else begin
                        beat_idx <= beat_idx + 3'd1;
                    end
                end
            end
            rx_tready <= !full_next;
        end
    end
endmodule
