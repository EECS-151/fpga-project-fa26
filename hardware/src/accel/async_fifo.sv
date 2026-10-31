`default_nettype none
// async_fifo: dual-clock FIFO (block RAM, gray pointers) with a first-word fall-through read
// side. Each side's status lags the other side by a few clocks. With EXTERNAL_RD_LIMIT the reader
// sees the write pointer through rd_limit instead of a synchronizer.
module async_fifo #(
    parameter int WIDTH             = 32,
    parameter int DEPTH_LOG2        = 10,
    parameter bit EXTERNAL_RD_LIMIT = 0
) (
    input  wire logic                  wr_clk,
    input  wire logic                  wr_rst,
    input  wire logic                  wr_en,             // ignored when full
    input  wire logic [WIDTH-1:0]      wr_data,
    output logic                  wr_full,
    output logic                  wr_empty,
    output logic [DEPTH_LOG2:0]   wr_count,          // entries written (wraps), for EXTERNAL_RD_LIMIT

    input  wire logic                  rd_clk,
    input  wire logic                  rd_rst,
    input  wire logic                  rd_pop,            // ignored when !rd_valid
    output logic                  rd_valid,
    output logic [WIDTH-1:0]      rd_data,
    output logic [DEPTH_LOG2:0]   rd_count,          // entries not yet popped
    input  wire logic [DEPTH_LOG2:0]   rd_limit           // with EXTERNAL_RD_LIMIT: wr_count, as the reader may see it
);
    localparam int N = DEPTH_LOG2;

    function automatic logic [N:0] bin2gray(input logic [N:0] b);
        return b ^ (b >> 1);
    endfunction
    function automatic logic [N:0] gray2bin(input logic [N:0] g);
        logic [N:0] b;
        b[N] = g[N];
        for (int i = N - 1; i >= 0; i--) b[i] = b[i + 1] ^ g[i];
        return b;
    endfunction

    (* ram_style = "block" *) logic [WIDTH-1:0] mem [2**N];

    logic [N:0] wr_ptr, wr_gray;                     // write side
    logic [N:0] fetch_ptr, pop_ptr, pop_gray;        // read side: fetch_ptr addresses the RAM,
                                                     // pop_ptr counts entries the reader took

    // ---- write side
    (* ASYNC_REG = "TRUE" *) logic [N:0] pop_gray_s1, pop_gray_s2;
    assign wr_full  = wr_gray == {~pop_gray_s2[N:N-1], pop_gray_s2[N-2:0]};
    assign wr_empty = wr_gray == pop_gray_s2;
    assign wr_count = wr_ptr;

    always_ff @(posedge wr_clk) begin
        if (wr_en && !wr_full) mem[wr_ptr[N-1:0]] <= wr_data;
    end
    always_ff @(posedge wr_clk) begin
        if (wr_rst) begin
            wr_ptr <= '0; wr_gray <= '0; pop_gray_s1 <= '0; pop_gray_s2 <= '0;
        end else begin
            if (wr_en && !wr_full) begin
                wr_ptr  <= wr_ptr + 1'b1;
                wr_gray <= bin2gray(wr_ptr + 1'b1);
            end
            pop_gray_s1 <= pop_gray;
            pop_gray_s2 <= pop_gray_s1;
        end
    end

    // ---- read side
    (* ASYNC_REG = "TRUE" *) logic [N:0] wr_gray_s1, wr_gray_s2;
    logic [N:0] wr_seen;                             // the write pointer, as the read side sees it
    logic ram_empty, pop, fetch;
    assign wr_seen   = EXTERNAL_RD_LIMIT ? rd_limit : gray2bin(wr_gray_s2);
    assign ram_empty = fetch_ptr == wr_seen;
    assign pop       = rd_pop && rd_valid;
    assign fetch     = !ram_empty && (!rd_valid || pop);
    assign rd_count  = wr_seen - pop_ptr;

    always_ff @(posedge rd_clk) begin
        if (fetch) rd_data <= mem[fetch_ptr[N-1:0]];
    end
    always_ff @(posedge rd_clk) begin
        if (rd_rst) begin
            fetch_ptr <= '0; pop_ptr <= '0; pop_gray <= '0; rd_valid <= 1'b0;
            wr_gray_s1 <= '0; wr_gray_s2 <= '0;
        end else begin
            if (fetch) fetch_ptr <= fetch_ptr + 1'b1;
            if (pop) begin
                pop_ptr  <= pop_ptr + 1'b1;
                pop_gray <= bin2gray(pop_ptr + 1'b1);
            end
            if (fetch)    rd_valid <= 1'b1;
            else if (pop) rd_valid <= 1'b0;
            wr_gray_s1 <= wr_gray;
            wr_gray_s2 <= wr_gray_s1;
        end
    end
endmodule
