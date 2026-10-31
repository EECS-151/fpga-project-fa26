`default_nettype none
// accel_system: accel_core on the Ethernet interface's byte port, as zu3top instantiates it.
module accel_system #(
    parameter int HARD_POSITION_LIMIT = 10,
    parameter int MAX_ORDER_QTY       = 10,
    parameter int QMAX                = 10
) (
    input  wire logic                     clk,            // the accelerator's clock
    input  wire logic                     rst,
    input  wire logic [4:0]               pid,
    input  wire logic                     kill,

    // the Ethernet interface's byte port
    input  wire logic [7:0]               rx_data,
    input  wire logic                     rx_valid,
    input  wire logic                     rx_last,
    output logic                     rx_ready,
    output logic [7:0]               tx_data,
    output logic                     tx_valid,
    input  wire logic                     tx_ready,
    output logic                     tx_end,

    // the CPU's memory-mapped port, on cpu_clk
    input  wire logic                     cpu_clk,
    input  wire logic                     cpu_rst,
    input  wire logic [9:0]               cpu_addr,
    input  wire logic [31:0]              cpu_wdata,
    input  wire logic                     cpu_we,
    input  wire logic                     cpu_re,
    output logic [31:0]              cpu_rdata
);
    accel_core #(
        .BUS_BYTES(1), .HARD_POSITION_LIMIT(HARD_POSITION_LIMIT), .MAX_ORDER_QTY(MAX_ORDER_QTY), .QMAX(QMAX)
    ) core (
        .clk, .rst, .pid, .kill,
        .rx_tdata(rx_data), .rx_tvalid(rx_valid), .rx_tlast(rx_last), .rx_tready(rx_ready),
        .tx_tdata(tx_data), .tx_tvalid(tx_valid), .tx_tready(tx_ready), .tx_end,
        .cpu_clk, .cpu_rst, .cpu_addr, .cpu_wdata, .cpu_we, .cpu_re, .cpu_rdata);
endmodule
