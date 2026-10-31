`default_nettype none
// ffs_tb: ffs256 and ffs64 on random vectors, from empty to full, against a reference loop.
// Results are checked when valid arrives (any cycle after start), with vec held until then.
//   make sim/ffs_tb.fsdb
module ffs_tb;
    localparam int N       = 20000;             // vectors per tree
    localparam int TIMEOUT = 1000;              // cycles to wait for valid

    logic clk = 0;
    always #5 clk = ~clk;

    logic         start256 = 0, valid256, found256, second_found256;
    logic [255:0] vec256 = '0;
    logic [7:0]   index256, second_index256;
    logic         start64 = 0, valid64, found64, second_found64;
    logic [63:0]  vec64 = '0;
    logic [5:0]   index64, second_index64;

    ffs256 dut256 (.clk, .start(start256), .vec(vec256), .valid(valid256), .found(found256),
                   .index(index256), .second_found(second_found256), .second_index(second_index256));
    ffs64  dut64  (.clk, .start(start64), .vec(vec64), .valid(valid64), .found(found64),
                   .index(index64), .second_found(second_found64), .second_index(second_index64));

    int errors = 0, tree_errors, max_errors = 20;  // tree_errors: this tree's, which stop it at max_errors

    // a random W-bit vector, mostly sparse (where the second-highest bit gets interesting)
    function automatic logic [255:0] random_vec(int W);
        logic [255:0] v = '0;
        int kind = $urandom_range(9);
        if (kind == 0)      v = '0;
        else if (kind == 1) v[$urandom_range(W - 1)] = 1'b1;
        else if (kind <= 4) begin v[$urandom_range(W - 1)] = 1'b1; v[$urandom_range(W - 1)] = 1'b1; end
        else if (kind <= 7) repeat ($urandom_range(3, 8)) v[$urandom_range(W - 1)] = 1'b1;
        else if (kind == 8) for (int i = 0; i < 256; i += 32) v[i +: 32] = $urandom;
        else                v = '1;
        return v & ((256'd1 << W) - 1);
    endfunction

    // the reference: highest and second-highest set bit, -1 if absent
    function automatic void top_two(logic [255:0] v, int W, output int first, output int second);
        first = -1; second = -1;
        for (int i = W - 1; i >= 0; i--)
            if (v[i]) begin
                if (first < 0) first = i;
                else if (second < 0) second = i;
            end
    endfunction

    task automatic report(string tree, logic [255:0] v, bit timed_out, int first, int second,
                          logic found, logic [7:0] index, logic second_found, logic [7:0] second_index);
        errors++; tree_errors++;
        if (tree_errors > max_errors) return;
        if (timed_out) $display("FAIL %s vec=%h: no valid within %0d cycles of start", tree, v, TIMEOUT);
        else $display("FAIL %s vec=%h: got found=%b index=%0d second_found=%b second_index=%0d; exp highest %0d, second %0d (-1 = none)",
                      tree, v, found, index, second_found, second_index, first, second);
    endtask

    task automatic check256(logic [255:0] v);
        int first, second, lat;
        top_two(v, 256, first, second);
        @(negedge clk) begin vec256 = v; start256 = 1; end
        @(negedge clk) start256 = 0;
        lat = 1;
        while (valid256 !== 1'b1 && lat < TIMEOUT) begin @(negedge clk); lat++; end
        if (valid256 !== 1'b1
            || found256 !== (first >= 0) || (first >= 0 && index256 !== first[7:0])
            || second_found256 !== (second >= 0) || (second >= 0 && second_index256 !== second[7:0]))
            report("ffs256", v, valid256 !== 1'b1, first, second, found256, index256, second_found256, second_index256);
    endtask

    task automatic check64(logic [63:0] v);
        int first, second, lat;
        top_two(256'(v), 64, first, second);
        @(negedge clk) begin vec64 = v; start64 = 1; end
        @(negedge clk) start64 = 0;
        lat = 1;
        while (valid64 !== 1'b1 && lat < TIMEOUT) begin @(negedge clk); lat++; end
        if (valid64 !== 1'b1
            || found64 !== (first >= 0) || (first >= 0 && index64 !== first[5:0])
            || second_found64 !== (second >= 0) || (second >= 0 && second_index64 !== second[5:0]))
            report("ffs64", 256'(v), valid64 !== 1'b1, first, second, found64, index64, second_found64, second_index64);
    endtask

    initial begin
        string fsdb_file;
        if (!$value$plusargs("fsdbfile+%s", fsdb_file)) begin
            fsdb_file = "default.fsdb";
        end
        $fsdbDumpfile(fsdb_file);
        $fsdbDumpvars(0, ffs_tb);

        repeat (2) @(negedge clk);
        tree_errors = 0;
        for (int i = 0; i < N && tree_errors < max_errors; i++) check256(random_vec(256));
        $display("ffs256: errors=%0d%s", tree_errors, tree_errors >= max_errors ? " (stopped early)" : "");
        tree_errors = 0;
        for (int i = 0; i < N && tree_errors < max_errors; i++) check64(64'(random_vec(64)));
        $display("ffs64:  errors=%0d%s", tree_errors, tree_errors >= max_errors ? " (stopped early)" : "");
        if (errors == 0) $display("PASS"); else $display("FAILED");
        $finish;
    end
endmodule
