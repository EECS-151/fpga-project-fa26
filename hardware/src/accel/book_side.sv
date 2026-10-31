`default_nettype none
// book_side: one side of the order book (SIDE 0 = bid, 1 = ask)
// tracks every level's quantity and the best two levels
module book_side #(
    parameter int SIDE = 0
) (
    input  wire logic         clk,
    input  wire logic         rst,                 // power-up reset
    input  wire logic         clear,               // session clear: 1 cycle, drops any start
    input  wire logic         start,               // 1-cycle pulse; level_* held until done
    input  wire logic [13:0]  level_px,
    input  wire logic [15:0]  level_qty,           // the level's new absolute quantity; 0 = remove it
    output logic         done,                // 1-cycle pulse; best_* and second_* settled
    output logic         best_valid,
    output logic [13:0]  best_px,
    output logic [15:0]  best_qty,
    output logic         second_valid,        // the side has a second level
    output logic [13:0]  second_px,

    // outside readers, while idle
    output logic [255:0] word_nonempty,       // the occupancy summary
    input  wire logic [13:0]  read_key,            // a key: {word, bit}; px on the bid side, ~px on the ask
    output logic [63:0]  occupancy_read_data, // word read_key[13:6], combinational; 0 for a word marked empty
    input  wire logic         qty_read_start,      // 1-cycle pulse: read the quantity at read_key (sampled now)
    output logic         qty_read_done,       // 1 or more cycles later
    output logic [15:0]  qty_read_data
);
    // ---- qty BRAM: 16K x 16 indexed by key. Read latency 2 (OUT_REG=1). Read before write
    logic        qty_ram_ena, qty_ram_wea, qty_ram_enb;
    logic [13:0] qty_ram_addra, qty_ram_addrb;
    logic [15:0] qty_ram_dia, qty_ram_dob;

    true_dual_port_bram #(.DATA_WIDTH(16), .DEPTH(16384), .OUT_REG(1'b1)) qty_ram (
        .clka(clk), .ena(qty_ram_ena), .wea(qty_ram_wea), .addra(qty_ram_addra), .dia(qty_ram_dia), .doa(),
        .clkb(clk), .enb(qty_ram_enb), .web(1'b0),        .addrb(qty_ram_addrb), .dib('0),
        .dob(qty_ram_dob)
    );

    // TODO: your implementation here
endmodule


