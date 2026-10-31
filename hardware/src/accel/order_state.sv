`default_nettype none
// order_state: our bid and ask orders at the exchange, kept in line with quote_mgr's targets
// Per side, one request in flight, NEW/CANCEL only (a change is cancel-then-new):
//   IDLE -> NEW -> PEND_NEW -> ACK -> LIVE      (REJECT -> IDLE)
//   LIVE -> CANCEL -> PEND_CXL -> CANCEL_ACK/REJECT -> IDLE
//   LIVE -> fully filled, or canceled by the exchange -> IDLE
// Order id = {pid, side, generation}. Each NEW bumps the generation, and a report only moves a
// side's state when its generation matches. Fills always update inventory and cash.
module order_state (
    input  wire logic               clk,
    input  wire logic               rst,
    input  wire logic [4:0]         pid,
    input  wire logic               clear,                  // session start
    input  wire logic               rate_window_reset,      // a heartbeat: reset orders_sent_this_heartbeat

    // a private report, from the message accel_ctrl holds
    input  wire logic               report_start,
    input  wire logic [3:0]         report_type,            // 8 ACK, 9 REJECT, A FILL, B CANCEL_ACK
    input  wire logic [23:0]        report_order_id,        // {pid[23:19], side[18:16], generation[15:0]}
    input  wire logic [7:0]         report_qty,             // FILL qty, or ACK leaves

    input  wire logic               update_orders_start,
    input  wire logic               cancel_all_start,
    input  wire logic [13:0]        tgt_bid_px,
    input  wire logic [7:0]         tgt_bid_sz,
    input  wire logic [13:0]        tgt_ask_px,
    input  wire logic [7:0]         tgt_ask_sz,
    input  wire logic [7:0]         position_limit,
    input  wire logic [7:0]         max_msgs_per_heartbeat, // NEW budget per heartbeat; 0 = none

    output logic               done,
    output logic               generation_wrap,        // a side ran out of generations: halt
    output logic               cancel_all_sent,
    output logic signed [15:0] inventory,              // + long
    output logic signed [39:0] cash,                   // ticks x shares

    // our orders, per side ([0] bid, [1] ask)
    output logic [2:0]         our_order_state  [2],   // 0 IDLE, 1 PEND_NEW, 2 LIVE, 4 PEND_CXL
    output logic [13:0]        live_px          [2],
    output logic [15:0]        live_leaves      [2],

    output logic               enqueue_valid,          // to msg_egress
    output logic [63:0]        enqueue_msg,
    output logic               idle                    // no report or order update in progress
);
    localparam logic [2:0] ORDER_IDLE = 3'd0, ORDER_PEND_NEW = 3'd1, ORDER_LIVE = 3'd2, ORDER_PEND_CXL = 3'd4;
    localparam logic [3:0] TYPE_ACK = 4'h8, TYPE_REJECT = 4'h9, TYPE_FILL = 4'hA, TYPE_CANCEL_ACK = 4'hB;
    localparam logic [3:0] TYPE_NEW = 4'hC, TYPE_CANCEL = 4'hD, TYPE_CANCEL_ALL = 4'hF;
    localparam logic [1:0] ACTION_NONE = 2'd0, ACTION_NEW = 2'd1, ACTION_CANCEL = 2'd2;
    localparam logic [15:0] GENERATION_MAX = 16'hFFFF;

    typedef enum logic [2:0] {IDLE, APPLY_REPORT, UPDATE_CASH, EMIT_BID, EMIT_ASK} step_t;
    step_t step;
    assign idle = step == IDLE && !enqueue_valid;

    // per side: the generation of the latest NEW and of the live order, and the pending NEW's price
    logic [15:0] latest_generation [2];
    logic [15:0] live_generation   [2];
    logic [13:0] pending_px        [2];
    logic [15:0] orders_sent_this_heartbeat;            // NEWs sent in this heartbeat's window

    // the report being applied
    logic [3:0] applied_report_type;
    logic       report_is_ours, report_side, report_matches_live, report_matches_latest;
    logic [7:0] fill_qty, ack_leaves;

    // the decision: what to send on each side
    logic [1:0] action [2];
    logic       generation_exhausted [2];
    logic       msg_is_last [2];

    // ---- fill value = qty * px: a 3-stage DSP multiply, started in APPLY_REPORT
    logic        fill_value_start;
    logic [13:0] fill_value_px;
    logic [7:0]  fill_value_qty;
    assign fill_value_start = (step == APPLY_REPORT) && report_is_ours && (applied_report_type == TYPE_FILL);
    assign fill_value_px    = report_matches_live   ? live_px[report_side]      // our own price: the live order's,
                            : report_matches_latest ? pending_px[report_side]   // or the pending one's
                            :                         live_px[report_side];
    assign fill_value_qty   = fill_qty;
    logic [13:0] multiplier_px;  logic [7:0] multiplier_qty;  logic [21:0] multiplier_product, fill_value;
    logic [2:0]  fill_value_pending;
    always_ff @(posedge clk) begin
        multiplier_px      <= fill_value_px;
        multiplier_qty     <= fill_value_qty;
        multiplier_product <= multiplier_px * multiplier_qty;
        fill_value         <= multiplier_product;
        fill_value_pending <= rst ? 3'd0 : {fill_value_pending[1:0], fill_value_start};
    end
    wire fill_value_ready = fill_value_pending[2];

    function automatic logic [63:0] order_msg(input logic [3:0] msg_type, input logic side, input logic eoe,
                                              input logic [23:0] order_id, input logic [13:0] px, input logic [7:0] qty);
        logic [63:0] msg = '0;
        msg[63:60] = msg_type;
        msg[57]    = eoe;
        msg[56]    = side;
        if (msg_type != TYPE_CANCEL_ALL) msg[47:24] = order_id;
        if (msg_type == TYPE_NEW) begin msg[23:8] = {2'b0, px}; msg[7:0] = qty; end
        return msg;
    endfunction

    // ---- the decision (IDLE + update_orders_start): what to send on each side, both at once, bid first
    logic [1:0]  decide_action [2];
    logic        decide_exhausted [2];
    always_comb begin
        logic [15:0] budget;
        logic        unlimited;
        unlimited = (max_msgs_per_heartbeat == 8'd0);
        budget    = (16'(max_msgs_per_heartbeat) > orders_sent_this_heartbeat)
                  ? 16'(max_msgs_per_heartbeat) - orders_sent_this_heartbeat : 16'd0;
        for (int side = 0; side < 2; side++) begin
            logic signed [17:0] position_after;       // the position this order could take us to
            logic [13:0] target_px;
            logic [7:0]  target_qty;
            target_px  = side == 0 ? tgt_bid_px : tgt_ask_px;
            target_qty = side == 0 ? tgt_bid_sz : tgt_ask_sz;
            position_after = (side == 0 ? 18'(inventory) : -18'(inventory)) + 18'(target_qty);
            decide_action[side]    = ACTION_NONE;
            decide_exhausted[side] = 1'b0;
            if (side == 1 && decide_exhausted[0]) begin
                // a generation wrap on the bid stops the ask
            end else if (our_order_state[side] == ORDER_IDLE) begin
                if (target_qty != 8'd0 && position_after <= 18'(position_limit) && (unlimited || budget != 16'd0)) begin
                    if (latest_generation[side] >= GENERATION_MAX) decide_exhausted[side] = 1'b1;
                    else begin
                        decide_action[side] = ACTION_NEW;
                        if (!unlimited) budget = budget - 16'd1;
                    end
                end
            end else if (our_order_state[side] == ORDER_LIVE) begin
                if (target_qty == 8'd0 || target_px != live_px[side] || 16'(target_qty) != live_leaves[side])
                    decide_action[side] = ACTION_CANCEL;
            end
        end
    end

    always_ff @(posedge clk) begin
        done             <= 1'b0;
        enqueue_valid    <= 1'b0;
        if (rst) begin
            step <= IDLE; inventory <= '0; cash <= '0; cancel_all_sent <= 1'b0; generation_wrap <= 1'b0;
            orders_sent_this_heartbeat <= '0;
            for (int s = 0; s < 2; s++) begin
                our_order_state[s] <= ORDER_IDLE; latest_generation[s] <= '0; live_generation[s] <= '0;
                live_px[s] <= '0; live_leaves[s] <= '0; pending_px[s] <= '0;
            end
        end else begin
            if (rate_window_reset) orders_sent_this_heartbeat <= '0;
            if (clear) begin
                for (int s = 0; s < 2; s++) begin
                    our_order_state[s] <= ORDER_IDLE; latest_generation[s] <= '0; live_generation[s] <= '0;
                    live_px[s] <= '0; live_leaves[s] <= '0; pending_px[s] <= '0;
                end
                inventory <= '0; cash <= '0; cancel_all_sent <= 1'b0; orders_sent_this_heartbeat <= '0;
                step <= IDLE;
            end else begin
                case (step)
                    IDLE: begin
                        if (report_start) begin                                  // decode the report
                            logic [4:0]  id_pid;
                            logic [2:0]  id_side;
                            logic [15:0] id_generation;
                            logic        ours;
                            {id_pid, id_side, id_generation} = report_order_id;
                            ours = (id_pid == pid) && (id_side <= 3'd1);
                            applied_report_type <= report_type;
                            report_is_ours      <= ours;
                            if (ours) begin
                                report_side           <= id_side[0];
                                report_matches_live   <= id_generation == live_generation[id_side[0]];
                                report_matches_latest <= id_generation == latest_generation[id_side[0]];
                            end
                            if (report_type == TYPE_FILL)     fill_qty   <= report_qty;
                            else if (report_type == TYPE_ACK) ack_leaves <= report_qty;
                            step <= APPLY_REPORT;
                        end else if (update_orders_start) begin
                            logic wrapped;
                            wrapped = decide_exhausted[0] || decide_exhausted[1];
                            for (int s = 0; s < 2; s++) begin
                                action[s]               <= decide_action[s];
                                generation_exhausted[s] <= decide_exhausted[s];
                            end
                            // EOE on the event's final message; after a wrap a CANCEL_ALL follows instead
                            msg_is_last[0] <= decide_action[0] != ACTION_NONE && decide_action[1] == ACTION_NONE && !wrapped;
                            msg_is_last[1] <= decide_action[1] != ACTION_NONE && !wrapped;
                            generation_wrap <= 1'b0;
                            step <= EMIT_BID;
                        end else if (cancel_all_start) begin
                            enqueue_msg     <= order_msg(TYPE_CANCEL_ALL, 1'b0, 1'b1, '0, '0, '0);
                            enqueue_valid   <= 1'b1;
                            cancel_all_sent <= 1'b1;
                            done            <= 1'b1;
                        end
                    end

                    APPLY_REPORT: begin
                        logic side;
                        side = report_side;
                        if (!report_is_ours) begin
                            done <= 1'b1; step <= IDLE;
                        end else if (applied_report_type == TYPE_FILL) begin
                            logic [15:0] leaves;
                            inventory <= side == 1'b0 ? inventory + 16'(fill_qty) : inventory - 16'(fill_qty);
                            // fill_value_* feed the multiplier this cycle (see above)
                            if ((our_order_state[side] == ORDER_LIVE || our_order_state[side] == ORDER_PEND_CXL) && report_matches_live) begin
                                leaves = (live_leaves[side] > 16'(fill_qty)) ? live_leaves[side] - 16'(fill_qty) : 16'd0;
                                live_leaves[side] <= leaves;
                                if (our_order_state[side] == ORDER_LIVE && leaves == 16'd0) our_order_state[side] <= ORDER_IDLE;
                            end
                            step <= UPDATE_CASH;
                        end else begin
                            case (applied_report_type)
                                TYPE_ACK: if (our_order_state[side] == ORDER_PEND_NEW && report_matches_latest) begin
                                    if (ack_leaves != 8'd0) begin
                                        our_order_state[side]     <= ORDER_LIVE;
                                        live_generation[side] <= latest_generation[side];
                                        live_px[side]         <= pending_px[side];
                                        live_leaves[side]     <= 16'(ack_leaves);
                                    end else begin
                                        our_order_state[side] <= ORDER_IDLE;
                                    end
                                end
                                TYPE_REJECT: begin
                                    if (our_order_state[side] == ORDER_PEND_NEW && report_matches_latest) begin
                                        our_order_state[side] <= ORDER_IDLE;
                                    end else if (our_order_state[side] == ORDER_PEND_CXL && report_matches_live) begin
                                        our_order_state[side] <= ORDER_IDLE; live_leaves[side] <= '0;   // it was already gone
                                    end
                                end
                                TYPE_CANCEL_ACK: if ((our_order_state[side] == ORDER_LIVE || our_order_state[side] == ORDER_PEND_CXL)
                                                     && report_matches_live) begin
                                    our_order_state[side] <= ORDER_IDLE; live_leaves[side] <= '0;
                                end
                                default: ;
                            endcase
                            done <= 1'b1; step <= IDLE;
                        end
                    end

                    UPDATE_CASH: if (fill_value_ready) begin
                        cash <= report_side == 1'b0 ? cash - 40'(fill_value) : cash + 40'(fill_value);
                        done <= 1'b1; step <= IDLE;
                    end

                    EMIT_BID, EMIT_ASK: begin
                        logic       side;
                        logic [13:0] target_px;
                        logic [7:0]  target_qty;
                        side       = (step == EMIT_ASK);
                        target_px  = side ? tgt_ask_px : tgt_bid_px;
                        target_qty = side ? tgt_ask_sz : tgt_bid_sz;
                        if (action[side] == ACTION_NEW) begin
                            logic [15:0] generation;
                            generation = latest_generation[side] + 16'd1;
                            latest_generation[side] <= generation;
                            our_order_state[side]       <= ORDER_PEND_NEW;
                            pending_px[side]        <= target_px;
                            enqueue_msg <= order_msg(TYPE_NEW, side, msg_is_last[side], {pid, 2'b00, side, generation},
                                                     target_px, target_qty);
                            enqueue_valid <= 1'b1;
                            orders_sent_this_heartbeat <= orders_sent_this_heartbeat + 16'd1;
                        end else if (action[side] == ACTION_CANCEL) begin
                            our_order_state[side] <= ORDER_PEND_CXL;
                            enqueue_msg <= order_msg(TYPE_CANCEL, side, msg_is_last[side],
                                                     {pid, 2'b00, side, live_generation[side]}, '0, '0);
                            enqueue_valid <= 1'b1;
                        end
                        if (step == EMIT_BID) step <= EMIT_ASK;
                        else begin
                            generation_wrap <= generation_exhausted[0] || generation_exhausted[1];
                            done <= 1'b1; step <= IDLE;
                        end
                    end

                    default: step <= IDLE;
                endcase
            end
        end
    end
endmodule
