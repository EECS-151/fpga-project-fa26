`timescale 1ns/10ps

// eth_seal, simulation model: the Ethernet interface as the CPU sees it, without any Ethernet.
// Same name and ports as the module the FPGA build uses, so zu3top doesn't change.
//
// The testbench plays the exchange with two tasks:
//   send_frame(payload)     queue an inbound frame (its payload bytes)
//   get_response(payload)   wait for the next response frame and return its payload
//
// The CPU sees what it sees on the board:
//   - a frame is offered only once the previous response has been closed (one at a time);
//     rx_valid/rx_data/rx_last show its head byte and rx_ready pops it
//   - tx_ready is high except for a few cycles while a TX_END is being handled; a byte written
//     while tx_ready is low is lost (with a warning)
//   - tx_end closes the response: it is padded with zeros to whole 8-byte messages, then an END
//     message and an 8-byte trailer are appended:
//       END     = {0x72, seq, n_orders, status, tag[15:0], busy[15:0]}
//       trailer = {0x62, seq, 6 more bytes (zero in simulation)}
//     tag and busy are in 2.5 ns ticks, from the frame being offered to the last whole message
//     written (0 if none) and to TX_END. status b2: saturated (or more than 7 messages);
//     b3: bytes were written before the frame was offered. seq counts responses, mod 256, and
//     restarts at 0 for a frame holding a SESSION_START (message type 0x1).
module eth_seal (
    // board pins (unused in the model)
    input  wire logic       CLK_100_P,
    input  wire logic       CLK_100_N,
    output logic            eth_reset_n,
    input  wire logic       eth_ref_clk,
    input  wire logic       eth_crs_dv,
    input  wire logic       eth_rxd0,
    input  wire logic       eth_rxd1,
    output logic            eth_tx_en,
    output logic            eth_txd0,
    output logic            eth_txd1,
    input  wire logic [4:0] board_id,

    output logic            clk_100,

    // the CPU side
    input  wire logic       clk,
    input  wire logic       rst,
    output logic [7:0]      rx_data,
    output logic            rx_valid,
    output logic            rx_last,
    input  wire logic       rx_ready,
    input  wire logic [7:0] tx_data,
    input  wire logic       tx_valid,
    output logic            tx_ready,
    input  wire logic       tx_end,
    output logic            link_up
);
    localparam realtime TICK = 2.5ns;                    // the END's tag/busy unit
    localparam int END_BUSY_CYCLES = 3;                  // tx_ready low after a TX_END

    assign clk_100     = CLK_100_P;
    assign eth_reset_n = 1'b1;
    assign eth_tx_en   = 1'b0;
    assign eth_txd0    = 1'b0;
    assign eth_txd1    = 1'b0;

    // ---- the testbench's side ----
    typedef logic [7:0] byte_q_t [$];
    byte_q_t inbound [$];                                // frames waiting to be offered
    byte_q_t responses [$];                              // closed responses

    task automatic send_frame(input logic [7:0] payload [$]);
        if (payload.size() == 0) $error("eth (sim): send_frame with an empty payload");
        else inbound.push_back(payload);
    endtask

    task automatic get_response(output logic [7:0] payload [$]);
        wait (responses.size() != 0);
        payload = responses.pop_front();
    endtask

    // ---- state ----
    logic [7:0] cur [$];                                 // the frame being offered
    logic [7:0] resp [$];                                // the response being written
    bit         offering;                                // cur is at the port
    bit         in_window;                               // a frame was offered since the last TX_END
    bit         early;                                   // bytes written before the frame was offered
    bit         has_last;
    bit         session_start;
    bit         end_waiting;                             // a TX_END arrived before any frame
    bit         stamp_offer;                             // the frame shows at the port from the next edge
    int         end_busy;                                // cycles tx_ready stays low
    int         byte_cnt;
    logic [7:0] rx_seq;
    realtime    t_avail, t_last;

    // the CPU-side outputs are registered (updated after each edge, like a FIFO's)
    initial begin rx_valid = 0; rx_data = '0; rx_last = 0; tx_ready = 0; link_up = 0; end

    function automatic logic [15:0] ticks(input realtime from, input realtime to, output bit sat);
        longint t;
        t = longint'($floor((to - from) / TICK));
        sat = t > 16'hFFFF;
        return sat ? 16'hFFFF : 16'(t);
    endfunction

    task automatic close_response(input realtime t_end);
        logic [7:0] seq, status;
        logic [15:0] tag, busy;
        bit tag_sat, busy_sat;
        int n_orders;
        while (resp.size() % 8 != 0) resp.push_back(8'h00);
        n_orders = resp.size() / 8;
        tag  = has_last ? ticks(t_avail, t_last, tag_sat) : 16'd0;
        if (!has_last) tag_sat = 0;
        busy = ticks(t_avail, t_end, busy_sat);
        seq  = session_start ? 8'd0 : rx_seq;
        status = {4'd0, early, (n_orders > 7) || tag_sat || busy_sat, 2'b00};
        resp.push_back(8'h72); resp.push_back(seq); resp.push_back(8'(n_orders)); resp.push_back(status);
        resp.push_back(tag[15:8]); resp.push_back(tag[7:0]); resp.push_back(busy[15:8]); resp.push_back(busy[7:0]);
        resp.push_back(8'h62); resp.push_back(seq);
        repeat (6) resp.push_back(8'h00);
        responses.push_back(resp);
        resp = {};
        rx_seq = seq + 8'd1;
        session_start = 0; in_window = 0; early = 0; has_last = 0; byte_cnt = 0;
    endtask

    always @(posedge clk) begin
        if (rst) begin
            cur = {}; resp = {}; offering = 0; in_window = 0; early = 0; has_last = 0;
            session_start = 0; end_waiting = 0; stamp_offer = 0; end_busy = 0; byte_cnt = 0; rx_seq = '0;
        end else begin
            // the first edge the CPU can see the new frame: the latency count starts there
            if (stamp_offer) begin t_avail = $realtime; stamp_offer = 0; end

            // the CPU pops a byte; the frame is gone once its last byte is popped
            if (rx_valid && rx_ready) begin
                void'(cur.pop_front());
                if (cur.size() == 0) offering = 0;
            end

            // the CPU writes a byte
            if (tx_valid) begin
                if (!tx_ready) $warning("eth (sim): byte %h written while tx_ready was low: lost", tx_data);
                else begin
                    resp.push_back(tx_data);
                    byte_cnt++;
                    if (!in_window) early = 1;
                    else if (byte_cnt % 8 == 0) begin t_last = $realtime; has_last = 1; end
                end
            end

            if (end_busy != 0) end_busy--;

            // TX_END closes the response (or waits for a frame, if none was offered yet)
            if (tx_end && end_busy == 0) begin
                end_busy = END_BUSY_CYCLES;
                if (in_window) close_response($realtime);
                else begin
                    $warning("eth (sim): TX_END before any frame was offered: it closes the next frame's response");
                    end_waiting = 1;
                end
            end

            // offer the next frame once the previous response is closed
            if (!offering && !in_window && end_busy == 0 && inbound.size() != 0) begin
                cur = inbound.pop_front();
                for (int i = 0; i < cur.size(); i += 8)
                    if (cur[i][7:4] == 4'h1) session_start = 1;
                offering = 1; in_window = 1; stamp_offer = 1; t_avail = $realtime;
                if (end_waiting) begin end_waiting = 0; stamp_offer = 0; close_response($realtime); end
            end
        end
        rx_valid <= !rst && offering && cur.size() != 0;
        rx_data  <= (!rst && offering && cur.size() != 0) ? cur[0] : 8'h00;
        rx_last  <= !rst && offering && cur.size() == 1;
        tx_ready <= !rst && end_busy == 0;
        link_up  <= !rst;
    end
endmodule
