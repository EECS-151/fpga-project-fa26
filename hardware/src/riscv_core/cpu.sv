module cpu #(
    parameter SYSTEM_CLOCK_FREQ = 100_000_000,
    parameter CPU_CLOCK_FREQ = 50_000_000,
    parameter RESET_PC = 32'h4000_0000,
    parameter BAUD_RATE = 115200
) (
    input wire logic clk,
    input wire logic rst,
    input wire logic system_clk,
    input wire logic bp_enable,
    input wire logic serial_in,
    output logic serial_out,

    // Ethernet interface (on clk): ready/valid byte streams, like the UART's
    input wire logic [7:0] eth_rx_data,   // head byte of the current inbound frame
    input wire logic eth_rx_valid,
    input wire logic eth_rx_last,         // eth_rx_data is the frame's last byte
    output logic eth_rx_ready,        // pop the head byte
    output logic [7:0] eth_tx_data,   // next byte of the response frame
    output logic eth_tx_valid,
    input wire logic eth_tx_ready,
    output logic eth_tx_end,          // one-cycle pulse: the response frame is complete
    input wire logic eth_link_up,
    output logic [2:0] errors
);
    // BIOS Memory
    // Synchronous read: read takes one cycle
    // Synchronous write: write takes one cycle
    logic [11:0] bios_addra, bios_addrb;
    logic [31:0] bios_douta, bios_doutb;
    logic bios_ena, bios_enb;
    bios_mem bios_mem (
      .clk(clk),
      .ena(bios_ena),
      .addra(bios_addra),
      .douta(bios_douta),
      .enb(bios_enb),
      .addrb(bios_addrb),
      .doutb(bios_doutb)
    );

    // Data Memory
    // Synchronous read: read takes one cycle
    // Synchronous write: write takes one cycle
    // Write-byte-enable: select which of the four bytes to write
    logic [13:0] dmem_addr;
    logic [31:0] dmem_din, dmem_dout;
    logic [3:0] dmem_we;
    logic dmem_en;
    dmem dmem (
      .clk(clk),
      .en(dmem_en),
      .we(dmem_we),
      .addr(dmem_addr),
      .din(dmem_din),
      .dout(dmem_dout)
    );

    // Instruction Memory
    // Synchronous read: read takes one cycle
    // Synchronous write: write takes one cycle
    // Write-byte-enable: select which of the four bytes to write
    logic [31:0] imem_dina, imem_doutb;
    logic [13:0] imem_addra, imem_addrb;
    logic [3:0] imem_wea;
    logic imem_ena;
    imem imem (
      .clk(clk),
      .ena(imem_ena),
      .wea(imem_wea),
      .addra(imem_addra),
      .dina(imem_dina),
      .addrb(imem_addrb),
      .doutb(imem_doutb)
    );

    // Register file
    // Asynchronous read: read data is available in the same cycle
    // Synchronous write: write takes one cycle
    logic we;
    logic [4:0] ra1, ra2, wa;
    logic [31:0] wd;
    logic [31:0] rd1, rd2;
    reg_file rf (
        .clk(clk),
        .we(we),
        .ra1(ra1), .ra2(ra2), .wa(wa),
        .wd(wd),
        .rd1(rd1), .rd2(rd2)
    );

    // On-chip UART
    //// UART Receiver
    logic [7:0] uart_rx_data_out;
    logic uart_rx_data_out_valid;
    logic uart_rx_data_out_ready;
    //// UART Transmitter
    logic [7:0] uart_tx_data_in;
    logic uart_tx_data_in_valid;
    logic uart_tx_data_in_ready;
    uart #(
        .CLOCK_FREQ(CPU_CLOCK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) on_chip_uart (
        .clk(clk),
        .reset(rst),
        .system_clk(system_clk),

        .serial_in(serial_in),
        .data_out(uart_rx_data_out),
        .data_out_valid(uart_rx_data_out_valid),
        .data_out_ready(uart_rx_data_out_ready),

        .serial_out(serial_out),
        .data_in(uart_tx_data_in),
        .data_in_valid(uart_tx_data_in_valid),
        .data_in_ready(uart_tx_data_in_ready)
    );

    // On-chip Ethernet: the eth_* ports above. Memory-mapped I/O (addr[31:28] = 4'b1000):
    //   0x8000_0020  ETH_STATUS   R  {28'b0, eth_link_up, eth_tx_ready, eth_rx_last, eth_rx_valid}
    //   0x8000_0024  ETH_RX_DATA  R  {24'b0, eth_rx_data}; the load pops the byte (eth_rx_ready)
    //   0x8000_0028  ETH_TX_DATA  W  sends wdata[7:0] (eth_tx_valid)
    //   0x8000_002C  ETH_TX_END   W  closes the response frame (eth_tx_end); the data is ignored
    // As with the UART, software checks ETH_STATUS before each pop or push, so a pop is only
    // issued when eth_rx_valid is high and a push only when eth_tx_ready is high.
    // TODO: decode these addresses with the rest of your MMIO, and remove the tie-offs below
    assign eth_rx_ready = 1'b0;
    assign eth_tx_data  = 8'd0;
    assign eth_tx_valid = 1'b0;
    assign eth_tx_end   = 1'b0;

    logic [31:0] tohost_csr = 0;

    // Illegal instruction / trap aggregation (stub: tie low until core reports faults)
    assign errors[0] = uart_rx_overflow; // input buffer overflowed
    // Optional TODO: errors[1] is raised when PC is invalid (ie. not in IMEM or BIOS)
    assign errors[1] = 1'b0;
    // Optional TODO: errors[2] is raised when a memory access is invalid (ie. outside of IMEM, DMEM, BIOS, MMIO etc.)
    assign errors[2] = 1'b0;

    // TODO: Your code to implement a fully functioning RISC-V core
    // Add as many modules as you want
    // Feel free to move the memory modules around
endmodule
