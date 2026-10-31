`default_nettype none
// book_side_tb: random updates to both sides, each checked against a reference book. the best two
// levels, the occupancy bit and the quantity read are checked. The occupancy read must be combinational,
// a quantity read must take read_key on qty_read_start's cycle only, and clear must take effect at
// once; done and qty_read_done may take any number of cycles.
//   make sim/book_side_tb.fsdb
module book_side_tb;
    bit finished_bid, finished_ask;
    int errors_bid, errors_ask;

    book_side_tb_side #(.SIDE(0)) bid (.finished(finished_bid), .errors(errors_bid));
    book_side_tb_side #(.SIDE(1)) ask (.finished(finished_ask), .errors(errors_ask));

    initial begin
        string fsdb_file;
        if (!$value$plusargs("fsdbfile+%s", fsdb_file)) begin
            fsdb_file = "default.fsdb";
        end
        $fsdbDumpfile(fsdb_file);
        $fsdbDumpvars(0, book_side_tb);
        wait (finished_bid && finished_ask);
        if (errors_bid == 0 && errors_ask == 0) $display("PASS"); else $display("FAILED");
        $finish;
    end
endmodule

module book_side_tb_side #(
    parameter int SIDE = 0,
    parameter int N    = 60000
) (
    output bit finished,
    output int errors
);
    localparam int MAX_ERRORS = 20;               // stop this side after this many
    localparam int TIMEOUT    = 20000;            // cycles to wait for done (> a scan of every key)

    logic clk = 0, rst = 1, clear = 0, start = 0;
    logic [13:0] level_px;  logic [15:0] level_qty;
    logic done, best_valid, second_valid;  logic [13:0] best_px, second_px;  logic [15:0] best_qty;
    logic [255:0] word_nonempty;
    logic [13:0]  read_key = '0;
    logic [63:0]  occupancy_read_data;
    logic         qty_read_start = 0, qty_read_done;
    logic [15:0]  qty_read_data;

    book_side #(.SIDE(SIDE)) dut (
        .clk, .rst, .clear, .start, .level_px, .level_qty,
        .done, .best_valid, .best_px, .best_qty, .second_valid, .second_px,
        .word_nonempty, .read_key, .occupancy_read_data,
        .qty_read_start, .qty_read_done, .qty_read_data);
    always #5 clk = ~clk;

    // reference: px -> qty
    int unsigned ref_q [int];
    int n_top_removes = 0, n_other = 0, n_outside_reads = 0, n_second_removes = 0;

    function automatic int key_of(int px); return SIDE == 0 ? px : (~px) & 14'h3fff; endfunction
    function automatic int px_of(int key); return SIDE == 0 ? key : (~key) & 14'h3fff; endfunction

    // the reference's two highest keys (-1 if absent)
    task automatic top_two(output int best_key, output int second_key);
        best_key = -1; second_key = -1;
        foreach (ref_q[p]) begin
            int k = key_of(p);
            if (k > best_key) begin second_key = best_key; best_key = k; end
            else if (k > second_key) second_key = k;
        end
    endtask

    task automatic check(string what);
        int best_key, second_key;
        top_two(best_key, second_key);
        if (second_key < 0) begin
            if (second_valid !== 1'b0) begin errors++; $display("FAIL %s: expected no second level, got px=%0d", what, second_px); end
        end else if (second_valid !== 1'b1 || second_px !== px_of(second_key)) begin
            errors++; $display("FAIL %s: second exp px=%0d got v=%b px=%0d", what, px_of(second_key), second_valid, second_px);
        end
        if (best_key < 0) begin
            if (best_valid !== 1'b0) begin errors++; $display("FAIL %s: expected empty, got px=%0d", what, best_px); end
        end else begin
            int bpx = SIDE == 0 ? best_key : (~best_key) & 14'h3fff;
            if (best_valid !== 1'b1 || best_px !== bpx[13:0] || best_qty !== ref_q[bpx][15:0]) begin
                errors++;
                $display("FAIL %s: exp px=%0d qty=%0d  got v=%b px=%0d qty=%0d", what, bpx, ref_q[bpx], best_valid, best_px, best_qty);
            end
        end
    endtask

    // the outside read ports, while the side is idle
    task automatic check_outside_reads(int px);
        int key = key_of(px), waited = 1;
        bit present = ref_q.exists(px);
        @(negedge clk) read_key = key[13:0];
        #1 if (occupancy_read_data[key & 63] !== present || word_nonempty[key >> 6] !== (occupancy_read_data != 0)) begin
            errors++; $display("FAIL occupancy read px=%0d: bit %b, expected %b", px, occupancy_read_data[key & 63], present);
        end
        if (present) begin
            @(negedge clk) begin qty_read_start = 1; read_key = key[13:0]; end
            @(negedge clk) begin qty_read_start = 0; read_key = 14'($urandom); end   // held for the start only
            while (qty_read_done !== 1'b1 && waited < TIMEOUT) begin @(negedge clk); waited++; end
            if (qty_read_done !== 1'b1) begin
                errors++; $display("FAIL qty read px=%0d: no qty_read_done within %0d cycles", px, TIMEOUT);
            end else if (qty_read_data !== ref_q[px][15:0]) begin
                errors++; $display("FAIL qty read px=%0d: got %0d, expected %0d", px, qty_read_data, ref_q[px]);
            end
            n_outside_reads++;
        end
    endtask

    task automatic update(int px, int qty);
        bit top_removed;                          // removes the best or second level
        int lat = 0;
        int best_key, second_key;
        top_two(best_key, second_key);
        top_removed = (qty == 0) && ref_q.exists(px) && (key_of(px) == best_key || key_of(px) == second_key);
        if (qty == 0) ref_q.delete(px); else ref_q[px] = qty;

        // drive and sample on negedge so the DUT sees clean inputs at posedge
        @(negedge clk); start = 1; level_px = px[13:0]; level_qty = qty[15:0];
        @(negedge clk); start = 0;
        lat = 1;
        while (lat < TIMEOUT && done !== 1'b1) begin @(negedge clk); lat++; end
        if (done !== 1'b1) begin errors++; $display("FAIL: no done within %0d cycles (px=%0d qty=%0d)", TIMEOUT, px, qty); end
        else begin
            if (top_removed) n_top_removes++; else n_other++;
            check($sformatf("upd px=%0d qty=%0d", px, qty));
            check_outside_reads(px);
        end
    endtask

    task automatic do_clear();
        @(negedge clk); clear = 1;
        @(negedge clk); clear = 0;
        ref_q.delete();
        @(negedge clk);
        check("clear");
    endtask

    function automatic int pick_existing();
        int n = $urandom_range(ref_q.size() - 1), i = 0, r = 0;
        foreach (ref_q[p]) begin if (i == n) r = p; i++; end
        return r;
    endfunction

    initial begin
        errors = 0;
        repeat (4) @(posedge clk);
        @(negedge clk) rst = 0;
        repeat (2) @(negedge clk);
        check("post-reset");

        for (int i = 0; i < N && errors < MAX_ERRORS; i++) begin
            int u, px, qty;
            u = $urandom_range(999);       // not an initialiser: in this static block that runs once
            if (u < 10) do_clear();
            else begin
                int bk, sk;
                top_two(bk, sk);
                if (bk >= 0 && u < 250) begin                            // remove best
                    update(px_of(bk), 0);
                end else if (sk >= 0 && u < 450) begin                   // remove the second level
                    n_second_removes++;
                    update(px_of(sk), 0);
                end else if (ref_q.size() != 0 && u < 550) begin         // remove random existing
                    update(pick_existing(), 0);
                end else if (u < 600) begin                              // remove absent
                    px = $urandom_range(16383);
                    if (!ref_q.exists(px)) update(px, 0);
                end else begin                                           // add / modify, clustered (often at the top)
                    int centers[5];
                    int anywhere, at_top, pick, offset;
                    anywhere = $urandom_range(16383);
                    at_top   = bk >= 0 ? px_of(bk) : 8000;
                    pick     = $urandom_range(4);
                    offset   = $urandom_range(140);
                    centers  = '{anywhere, 8000, 0, 16383, at_top};
                    px = centers[pick] + offset - 70;
                    px = px < 0 ? 0 : (px > 16383 ? 16383 : px);
                    qty = $urandom_range(1, 65535);
                    update(px, qty);
                end
            end
        end
        $display("SIDE=%0d: %0d updates, %0d removing the best or second level (%0d the second), %0d outside qty reads; errors=%0d%s",
                 SIDE, n_top_removes + n_other, n_top_removes, n_second_removes, n_outside_reads, errors,
                 errors >= MAX_ERRORS ? " (stopped early)" : "");
        finished = 1;
    end
endmodule
