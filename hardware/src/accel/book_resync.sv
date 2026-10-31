`default_nettype none
// book_resync: on a CPU RESYNC, refill the delta log with the whole book (accel_ctrl holds off
// messages until `done`). A full log stalls the walk instead of dropping entries. The log gets:
//   RESYNC_BEGIN          {1, kind 4, 0}          the CPU clears its book
//   one entry per level   {0, side, px, qty}      bids best first, then asks best first
//   RESYNC_END            {1, kind 5, hb_count}   then log_overflow is cleared
module book_resync (
    input  wire logic         clk,
    input  wire logic         rst,
    input  wire logic         start,                   // from accel_ctrl
    output logic         done,                    // 1-cycle pulse
    input  wire logic [15:0]  heartbeat_count,

    // the book, per side (book_side's outside read ports; the side is idle during a resync)
    input  wire logic [255:0] bid_word_nonempty,
    input  wire logic [255:0] ask_word_nonempty,
    output logic [13:0]  read_key,                // to both sides: {word, 0}, then a level's key
    input  wire logic [63:0]  bid_occupancy_read_data,
    input  wire logic [63:0]  ask_occupancy_read_data,
    output logic         bid_qty_read_start,
    output logic         ask_qty_read_start,
    input  wire logic         bid_qty_read_done,
    input  wire logic [15:0]  bid_qty_read_data,
    input  wire logic         ask_qty_read_done,
    input  wire logic [15:0]  ask_qty_read_data,

    // the delta log
    input  wire logic         log_full,
    output logic         log_write_valid,
    output logic [31:0]  log_write_data,
    output logic         log_overflow_clear
);
    localparam logic [2:0] LOG_RESYNC_BEGIN = 3'd4, LOG_RESYNC_END = 3'd5;

    typedef enum logic [3:0] {
        IDLE, PUSH_BEGIN, SIDE_BEGIN, FIND_WORD_START, FIND_WORD_WAIT, FIND_BIT_START, FIND_BIT_WAIT,
        READ_QTY, WAIT_QTY, PUSH_LEVEL, NEXT_SIDE, PUSH_END
    } state_t;
    state_t state;

    logic         side;                           // 0 bid, 1 ask
    logic [255:0] words_left;                     // this side's non-empty words not walked yet
    logic [7:0]   word_idx;                       // the word being walked...
    logic [63:0]  bits_left;                      // ...and its levels not emitted yet
    logic [13:0]  level_key;                      // the level being emitted (bid: px, ask: ~px)
    logic [15:0]  level_qty;

    wire [13:0] level_px = side ? ~level_key : level_key;

    // ---- the find-first trees
    logic       word_valid, word_found, bit_valid, bit_found;
    logic [7:0] word_index;
    logic [5:0] bit_index;
    ffs256 find_word (.clk, .start(state == FIND_WORD_START), .vec(words_left),
                      .valid(word_valid), .found(word_found), .index(word_index), .second_found(), .second_index());
    ffs64  find_bit  (.clk, .start(state == FIND_BIT_START), .vec(bits_left),
                      .valid(bit_valid), .found(bit_found), .index(bit_index), .second_found(), .second_index());

    // ---- book reads
    // the word the find just picked (its occupancy is read in FIND_WORD_WAIT, when the index
    // arrives), or in READ_QTY the level whose quantity read starts
    assign read_key = (state == READ_QTY) ? level_key : {word_index, 6'd0};
    wire [63:0] occupancy_read_data = side ? ask_occupancy_read_data : bid_occupancy_read_data;
    assign bid_qty_read_start = (state == READ_QTY) && !side;
    assign ask_qty_read_start = (state == READ_QTY) &&  side;
    wire        qty_read_done = side ? ask_qty_read_done : bid_qty_read_done;
    wire [15:0] qty_read_data = side ? ask_qty_read_data : bid_qty_read_data;

    always_ff @(posedge clk) begin
        done <= 1'b0; log_write_valid <= 1'b0; log_overflow_clear <= 1'b0;
        if (rst) begin
            state <= IDLE; side <= 1'b0;
        end else begin
            unique case (state)
                IDLE: if (start) state <= PUSH_BEGIN;

                PUSH_BEGIN: if (!log_full) begin
                    log_write_valid <= 1'b1; log_write_data <= {1'b1, LOG_RESYNC_BEGIN, 28'd0};
                    side  <= 1'b0;
                    state <= SIDE_BEGIN;
                end

                SIDE_BEGIN: begin
                    words_left <= side ? ask_word_nonempty : bid_word_nonempty;
                    state      <= FIND_WORD_START;
                end

                FIND_WORD_START: state <= FIND_WORD_WAIT;          // the find starts this cycle

                FIND_WORD_WAIT: if (word_valid) begin
                    if (!word_found) state <= NEXT_SIDE;           // this side is done
                    else begin
                        word_idx  <= word_index;
                        bits_left <= occupancy_read_data;
                        state     <= FIND_BIT_START;
                    end
                end

                FIND_BIT_START: state <= FIND_BIT_WAIT;            // the find starts this cycle

                FIND_BIT_WAIT: if (bit_valid) begin
                    if (!bit_found) begin                          // this word is done
                        words_left[word_idx] <= 1'b0;
                        state <= FIND_WORD_START;
                    end else begin
                        level_key            <= {word_idx, bit_index};
                        bits_left[bit_index] <= 1'b0;
                        state <= READ_QTY;
                    end
                end

                READ_QTY: state <= WAIT_QTY;                       // the read starts this cycle

                WAIT_QTY: if (qty_read_done) begin
                    level_qty <= qty_read_data;
                    state     <= PUSH_LEVEL;
                end

                PUSH_LEVEL: if (!log_full) begin                   // a book delta: "px on side holds qty"
                    log_write_valid <= 1'b1; log_write_data <= {1'b0, side, level_px, level_qty};
                    state <= FIND_BIT_START;
                end

                NEXT_SIDE: if (!side) begin side <= 1'b1; state <= SIDE_BEGIN; end
                           else state <= PUSH_END;

                PUSH_END: if (!log_full) begin
                    log_write_valid    <= 1'b1; log_write_data <= {1'b1, LOG_RESYNC_END, 12'd0, heartbeat_count};
                    log_overflow_clear <= 1'b1;
                    done               <= 1'b1;
                    state              <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule
