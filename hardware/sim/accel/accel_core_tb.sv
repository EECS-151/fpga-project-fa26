`default_nettype none
// accel_core_tb: accel_core against the expected vectors (sim/accel/vectors), with the testbench
// as both exchange and CPU. Run it with sim/accel/run_accel_core.sh (make accel-core-tests). Each
// sim/accel/vectors/<case> holds stimulus.txt, the expected tx.txt and log.txt, and records.txt
// (per-event results, for debugging).
//   RX   stimulus frames, each after the previous response closes, with random gaps (+rx_gap=<%>)
//   TX   random back-pressure (+tx_stall=<%>); each response's orders must match tx.txt
//   CPU  on cpu_clk (+cpu_period=<ns>, default 10; clk is 10). Pops the delta log at a random
//        pace (+pop=<%>) and checks it against log.txt; does the stimulus's commits and RESYNCs
// VIA_SYSTEM=1 tests accel_system on the Ethernet seal's model instead (no rx_gap or tx_stall),
// and also checks each response's END.
module accel_core_tb;
    parameter int BUS_BYTES           = 8;
    parameter int HARD_POSITION_LIMIT = 10;
    parameter int MAX_ORDER_QTY       = 10;
    parameter bit VIA_SYSTEM          = 0;
    localparam int BEAT_BITS = 8 * BUS_BYTES;

    localparam logic [9:0] ADDR_COMMIT = 10'h004, ADDR_LOG_DATA = 10'h010, ADDR_RESYNC = 10'h01C,
                           ADDR_BANK = 10'h100, ADDR_SESSION_HEARTBEATS = 10'h038;

    logic clk = 0, rst = 1, kill = 0;
    always #5 clk = ~clk;
    logic cpu_clk = 0, cpu_rst = 1;
    realtime cpu_half_period = 5ns;
    initial begin
        real cpu_period;
        if ($value$plusargs("cpu_period=%f", cpu_period)) cpu_half_period = cpu_period * 0.5ns;
        forever #(cpu_half_period) cpu_clk = ~cpu_clk;
    end
    always @(posedge cpu_clk) cpu_rst <= rst;
    logic [BEAT_BITS-1:0] rx_tdata = '0;  logic rx_tvalid = 0, rx_tlast = 0, rx_tready;
    logic [BEAT_BITS-1:0] tx_tdata;       logic tx_tvalid, tx_tready = 1, tx_end;
    logic [9:0]  cpu_addr = '0;  logic [31:0] cpu_wdata = '0;  logic cpu_we = 0, cpu_re = 0;
    logic [31:0] cpu_rdata;
    logic dut_quiescent;                             // the core has nothing left to do or send

    string vectors;
    int rx_gap = 25, tx_stall = 25, pop = 50;
    int errors = 0, max_errors = 10;
    bit quiet_each_frame = 0;

    // ---------------- reading the vector files
    function automatic void split(string line, ref string words[$]);
        string word = "";
        words.delete();
        for (int i = 0; i < line.len(); i++) begin
            if (line[i] == " " || line[i] == "\n" || line[i] == "\r") begin
                if (word.len() != 0) words.push_back(word);
                word = "";
            end else word = {word, line.substr(i, i)};
        end
        if (word.len() != 0) words.push_back(word);
    endfunction

    function automatic logic [63:0] hex(string word);
        logic [63:0] value;
        void'($sscanf(word, "%h", value));
        return value;
    endfunction

    function automatic void bytes_of(string word, ref byte unsigned bytes[$]);
        bytes.delete();
        for (int i = 0; i + 1 < word.len(); i += 2) bytes.push_back(8'(hex(word.substr(i, i + 1))));
    endfunction

    function automatic int open_vectors(string file);
        int fd = $fopen({vectors, "/", file}, "r");
        if (fd == 0) $fatal(1, "can't open %s/%s", vectors, file);
        return fd;
    endfunction

    string       expected_tx[$];                   // tx.txt frames, as hex
    int          expected_rx_seq[$];               // per RX frame sent: 0 after a SESSION_START frame
    int          frames_queued = 0, ends_received = 0, next_rx_seq = 0;
    logic [31:0] expected_log[$];                  // log.txt entries
    task automatic load(string file, ref string lines[$]);
        int fd = open_vectors(file);
        string line;
        while ($fgets(line, fd) != 0) lines.push_back(line);
        $fclose(fd);
    endtask

    task automatic fail(string message);
        errors++;
        if (errors <= max_errors) $display("FAIL at %0t: %s", $time, message);
    endtask

    // ---------------- responses: the orders, closed by tx_end
    byte unsigned rx_queue[$][$];
    bit rx_busy = 0;
    int tx_frames = 0;
    function automatic string hex_of(ref byte unsigned bytes[$], input int from, input int to);
        string h = "";
        for (int i = from; i < to; i++) h = {h, $sformatf("%02x", bytes[i])};
        return h;
    endfunction
    task automatic check_response(ref byte unsigned orders[$]);
        int n_msgs = orders.size() / 8, start = 0;
        if (orders.size() % 8 != 0) fail($sformatf("response %0d is not whole messages: %s", ends_received, hex_of(orders, 0, orders.size())));
        for (int m = 0; m < n_msgs; m++) begin                 // the orders, one frame per EOE
            if (orders[8 * m][1] || m == n_msgs - 1) begin
                string words[$];
                if (expected_tx.size() == 0) fail("an extra TX frame");
                else begin
                    split(expected_tx.pop_front(), words);
                    if (hex_of(orders, 8 * start, 8 * (m + 1)) != words[1])
                        fail($sformatf("TX frame %0d: got %s, expected %s", tx_frames, hex_of(orders, 8 * start, 8 * (m + 1)), words[1]));
                end
                tx_frames++;
                start = m + 1;
            end
        end
        ends_received++;
    endtask

    if (VIA_SYSTEM) begin : g_system
        logic [7:0] rx_data, tx_data;
        logic       rx_valid, rx_last, rx_ready, tx_valid, tx_ready, link_up;
        eth_seal eth (
            .CLK_100_P(1'b0), .CLK_100_N(1'b1), .eth_reset_n(), .eth_ref_clk(1'b0), .eth_crs_dv(1'b0),
            .eth_rxd0(1'b0), .eth_rxd1(1'b0), .eth_tx_en(), .eth_txd0(), .eth_txd1(), .board_id(5'd3), .clk_100(),
            .clk, .rst, .rx_data, .rx_valid, .rx_last, .rx_ready, .tx_data, .tx_valid, .tx_ready, .tx_end, .link_up);
        accel_system #(.HARD_POSITION_LIMIT(HARD_POSITION_LIMIT), .MAX_ORDER_QTY(MAX_ORDER_QTY)) dut (
            .clk, .rst, .pid(5'd3), .kill, .rx_data, .rx_valid, .rx_last, .rx_ready,
            .tx_data, .tx_valid, .tx_ready, .tx_end, .cpu_clk, .cpu_rst, .cpu_addr, .cpu_wdata, .cpu_we, .cpu_re, .cpu_rdata);
        assign dut_quiescent = dut.core.core_quiescent;

        // RX: one frame at a time into the model, which offers it once the last response is closed
        initial begin
            forever begin
                @(negedge clk);
                if (rx_queue.size() != 0) begin
                    byte unsigned frame[$];
                    logic [7:0] payload[$];
                    frame = rx_queue.pop_front();
                    rx_busy = 1;
                    payload = {};                                     // (static: clear it each frame)
                    foreach (frame[i]) payload.push_back(frame[i]);
                    eth.send_frame(payload);
                    do @(negedge clk); while (eth.inbound.size() != 0 || eth.offering);   // all of it popped
                    rx_busy = 0;
                end
            end
        end

        // TX: each response from the model is the orders, the seal's END and the trailer
        initial begin
            forever begin
                logic [7:0] r[$];
                byte unsigned orders[$];
                logic [63:0] seal_end;
                int n;
                eth.get_response(r);
                n = r.size();
                orders = {};                                          // (static: clear it each response)
                if (n < 16 || n % 8 != 0) begin
                    fail($sformatf("response %0d: %0d bytes", ends_received, n));
                    continue;
                end
                for (int i = 0; i < n - 16; i++) orders.push_back(r[i]);
                for (int k = 0; k < 8; k++) seal_end = {seal_end[55:0], r[n - 16 + k]};
                if (seal_end[63:56] != 8'h72) fail($sformatf("END %016h: bad type/flags", seal_end));
                if (int'(seal_end[47:40]) != orders.size() / 8)
                    fail($sformatf("END %016h counts %0d orders, the response has %0d", seal_end, seal_end[47:40], orders.size() / 8));
                if (expected_rx_seq.size() == 0) fail($sformatf("END %016h answers no RX frame", seal_end));
                else begin
                    int seq;
                    seq = expected_rx_seq.pop_front();
                    if (int'(seal_end[55:48]) != seq) fail($sformatf("END %016h: rx_seq %0d, expected %0d", seal_end, seal_end[55:48], seq));
                end
                if (seal_end[34]) fail($sformatf("END %016h: SATURATED", seal_end));
                if (seal_end[35] && (orders.size() == 0 || orders[0] >> 4 != 4'hF))
                    fail($sformatf("END %016h: UNSOLICITED without a CANCEL_ALL first", seal_end));
                if (seal_end[31:16] > seal_end[15:0]) fail($sformatf("END %016h: tag > busy", seal_end));
                if (r[n - 8] != 8'h62 || r[n - 7] != seal_end[55:48]) fail($sformatf("response %0d: trailer %02h %02h", ends_received, r[n - 8], r[n - 7]));
                check_response(orders);
            end
        end
    end else begin : g_core
        accel_core #(.BUS_BYTES(BUS_BYTES), .HARD_POSITION_LIMIT(HARD_POSITION_LIMIT), .MAX_ORDER_QTY(MAX_ORDER_QTY)) dut (
            .clk, .rst, .pid(5'd3), .kill, .rx_tdata, .rx_tvalid, .rx_tlast, .rx_tready,
            .tx_tdata, .tx_tvalid, .tx_tready, .tx_end, .cpu_clk, .cpu_rst, .cpu_addr, .cpu_wdata, .cpu_we, .cpu_re, .cpu_rdata);
        assign dut_quiescent = dut.core_quiescent;

        // RX: frames with random gaps, each once the last response is closed (the seal's lockstep);
        // a handshake happens at the posedge after a negedge where rx_tvalid && rx_tready
        int frames_sent = 0;
        initial begin
            forever begin
                @(negedge clk);
                if (rx_queue.size() != 0 && ends_received == frames_sent) begin
                    byte unsigned frame[$];
                    int beats;
                    frame = rx_queue.pop_front();
                    rx_busy = 1;
                    beats = frame.size() / BUS_BYTES;
                    for (int b = 0; b < beats; b++) begin
                        while ($urandom_range(99) < rx_gap) begin rx_tvalid = 0; @(negedge clk); end
                        for (int k = 0; k < BUS_BYTES; k++) rx_tdata[BEAT_BITS - 1 - 8 * k -: 8] = frame[b * BUS_BYTES + k];
                        rx_tvalid = 1; rx_tlast = (b == beats - 1);
                        while (!rx_tready) @(negedge clk);
                        @(negedge clk);                                   // the handshake happened
                    end
                    rx_tvalid = 0; rx_tlast = 0; rx_busy = 0;
                    frames_sent++;
                end
            end
        end

        // TX: random back-pressure; a beat accepted with tx_end (or before) belongs to the response
        byte unsigned tx_bytes[$];
        initial begin
            forever begin
                @(negedge clk);
                tx_tready = $urandom_range(99) >= tx_stall;
                if (tx_tvalid && tx_tready)                               // the handshake at the next posedge
                    for (int k = 0; k < BUS_BYTES; k++) tx_bytes.push_back(tx_tdata[BEAT_BITS - 1 - 8 * k -: 8]);
                if (tx_end) begin
                    check_response(tx_bytes);
                    tx_bytes.delete();
                end
            end
        end
    end

    // ---------------- the CPU's MMIO port (cpu_clk): the stimulus's operations first, else pop the log
    typedef struct { bit write; logic [9:0] addr; logic [31:0] data; } mmio_op_t;
    mmio_op_t mmio_ops[$];
    int mmio_ops_done = 0;
    logic [31:0] mmio_read_data;
    int log_popped = 0;
    bit read_in_flight = 0, read_is_pop = 0;
    // As a CPU program would, read SESSION_HEARTBEATS right after popping a session entry: it must
    // already show that session's total
    bit session_check_due = 0, read_is_session_check = 0;
    logic [15:0] session_total;
    initial begin
        forever begin
            @(negedge cpu_clk);
            if (read_in_flight) begin                                 // cpu_rdata is valid now
                read_in_flight = 0;
                if (read_is_pop) begin
                    if (cpu_rdata != 32'd0) begin                     // 0 = empty (no entry is ever 0)
                        logic [31:0] expected;
                        if (expected_log.size() == 0) fail($sformatf("an extra log entry %08h", cpu_rdata));
                        else begin
                            expected = expected_log.pop_front();
                            if (cpu_rdata != expected) fail($sformatf("log entry %0d: got %08h, expected %08h", log_popped, cpu_rdata, expected));
                        end
                        log_popped++;
                        if (cpu_rdata[31] && cpu_rdata[30:28] == 3'd2) begin
                            session_check_due = 1; session_total = cpu_rdata[15:0];
                        end
                    end
                end else if (read_is_session_check) begin
                    read_is_session_check = 0;
                    if (cpu_rdata[15:0] != session_total)
                        fail($sformatf("SESSION_HEARTBEATS total = %0d right after the session entry, expected %0d",
                                       cpu_rdata[15:0], session_total));
                end else begin
                    mmio_read_data = cpu_rdata;
                    mmio_ops_done++;
                end
            end
            cpu_we = 0; cpu_re = 0;
            if (session_check_due) begin
                session_check_due = 0;
                cpu_addr = ADDR_SESSION_HEARTBEATS; cpu_re = 1; read_in_flight = 1; read_is_pop = 0;
                read_is_session_check = 1;
            end else if (mmio_ops.size() != 0) begin
                mmio_op_t op;
                op = mmio_ops.pop_front();
                cpu_addr = op.addr; cpu_wdata = op.data;
                if (op.write) begin cpu_we = 1; mmio_ops_done++; end
                else begin cpu_re = 1; read_in_flight = 1; read_is_pop = 0; end
            end else if ($urandom_range(99) < pop) begin
                cpu_addr = ADDR_LOG_DATA; cpu_re = 1; read_in_flight = 1; read_is_pop = 1;
            end
        end
    end

    task automatic mmio(bit write, logic [9:0] addr, logic [31:0] data = '0);
        int target;
        mmio_ops.push_back('{write, addr, data});
        target = mmio_ops_done + mmio_ops.size();
        while (mmio_ops_done < target) @(negedge cpu_clk);
    endtask

    // ---------------- the stimulus
    task automatic wait_quiet();                       // every frame answered, and the core idle
        int limit = 0;
        do begin @(negedge clk); limit++; end
        while ((rx_busy || rx_queue.size() != 0 || ends_received < frames_queued || !dut_quiescent) && limit < 1000000);
        if (limit >= 1000000) $fatal(1, "timeout waiting for %0d responses (got %0d)", frames_queued, ends_received);
        repeat (4) @(negedge clk);
    endtask

    initial begin
        int stimulus_fd, params_fd, hard, maxq, quiet;
        string line;
        string words[$];
        if (!$value$plusargs("vectors=%s", vectors)) $fatal(1, "+vectors=<dir> is required");
`ifdef WAVES                                            // WAVES=1 in run_accel_core.sh
        begin
            string fsdb_file;
            if (!$value$plusargs("fsdbfile+%s", fsdb_file)) fsdb_file = "accel_core_tb.fsdb";
            $fsdbDumpfile(fsdb_file);
            $fsdbDumpvars(0, accel_core_tb);
        end
`endif
        void'($value$plusargs("rx_gap=%d", rx_gap));
        void'($value$plusargs("tx_stall=%d", tx_stall));
        void'($value$plusargs("pop=%d", pop));
        params_fd = open_vectors("params.txt");
        void'($fscanf(params_fd, "%d %d %d", hard, maxq, quiet));
        if (hard != HARD_POSITION_LIMIT || maxq != MAX_ORDER_QTY) $fatal(1, "built for limits %0d/%0d, the vectors need %0d/%0d",
                                                                         HARD_POSITION_LIMIT, MAX_ORDER_QTY, hard, maxq);
        quiet_each_frame = quiet != 0;
        stimulus_fd = open_vectors("stimulus.txt");
        load("tx.txt", expected_tx);
        begin
            string log_lines[$];
            load("log.txt", log_lines);
            foreach (log_lines[i]) expected_log.push_back(32'(hex(log_lines[i])));
        end

        repeat (4) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);
        while ($fgets(line, stimulus_fd) != 0) begin
            split(line, words);
            if (words.size() == 0) continue;
            case (words[0])
                "F": begin
                    byte unsigned frame[$];
                    if (quiet_each_frame) wait_quiet();
                    bytes_of(words[2], frame);
                    for (int m = 0; 8 * m < frame.size() && frame[8 * m] >> 4 != 4'h0; m++)
                        if (frame[8 * m] >> 4 == 4'h1) next_rx_seq = 0;     // SESSION_START
                    expected_rx_seq.push_back(next_rx_seq);
                    next_rx_seq = (next_rx_seq + 1) % 256;
                    rx_queue.push_back(frame);
                    frames_queued++;
                end
                "K": begin
                    wait_quiet();
                    @(negedge clk) kill = 1;
                    @(negedge clk) kill = 0;
                end
                "C": begin                                        // the CPU's bank commit
                    wait_quiet();
                    for (int i = 0; i < 65; i++) mmio(1, ADDR_BANK + 10'(4 * i), 32'(hex(words[2 + i])));
                    mmio(1, ADDR_COMMIT, 32'(hex(words[1])));
                end
                "R": begin
                    int limit = 0;
                    wait_quiet();
                    mmio(1, ADDR_RESYNC, 32'd1);
                    do begin mmio(0, ADDR_RESYNC); limit++; end while (mmio_read_data[0] && limit < 100000);
                    if (limit >= 100000) fail("RESYNC never finished");
                end
                default: $fatal(1, "bad stimulus line: %s", line);
            endcase
        end
        wait_quiet();
        begin                                                     // drain: the log popped, the frames sent
            int limit = 0;
            while ((expected_log.size() != 0 || expected_tx.size() != 0 || ends_received < frames_queued) && limit < 200000) begin
                @(negedge clk); limit++;
            end
        end
        repeat (200) @(negedge clk);
        if (expected_tx.size() != 0) fail($sformatf("%0d TX frames missing after %0d", expected_tx.size(), tx_frames));
        if (ends_received != frames_queued) fail($sformatf("%0d responses for %0d RX frames", ends_received, frames_queued));
        if (expected_log.size() != 0) fail($sformatf("%0d log entries missing after %0d", expected_log.size(), log_popped));
        $display("%s BUS_BYTES=%0d: %0d RX frames, %0d TX frames in %0d responses, %0d log entries; errors=%0d",
                 vectors, BUS_BYTES, frames_queued, tx_frames, ends_received, log_popped, errors);
        if (errors == 0) $display("PASS"); else $display("FAILED");
        $finish;
    end
endmodule
