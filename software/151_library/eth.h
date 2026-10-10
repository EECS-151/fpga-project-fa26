#ifndef ETH_H_
#define ETH_H_

// Plain C types only, so this works with both types.h and <stdint.h>.

// Ethernet MMIO. Each inbound frame's payload arrives as a stream of bytes; the CPU answers it
// with exactly one response frame of 8-byte messages, closed by a write to ETH_TX_END. The
// hardware then pads the response to whole messages, appends an END message and an 8-byte
// trailer, and sends the frame. The next inbound frame becomes visible only after that.
// END reports the latency in fixed 2.5 ns ticks, whatever the CPU's clock: tag from the frame
// becoming available to the last whole message written (0 if none), busy to ETH_TX_END.
// Work done after ETH_TX_END and before reading the next frame is not counted for this frame.
#define ETH_STATUS  (*((volatile unsigned int*)0x80000020))
#define ETH_RX_DATA (*((volatile unsigned int*)0x80000024))
#define ETH_TX_DATA (*((volatile unsigned int*)0x80000028))
#define ETH_TX_END  (*((volatile unsigned int*)0x8000002C))

#define ETH_RX_VALID 0x01   // ETH_RX_DATA holds a byte
#define ETH_RX_LAST  0x02   // ...and it is the last byte of the frame
#define ETH_TX_READY 0x04   // ETH_TX_DATA can take a byte
#define ETH_LINK_UP  0x08   // the shell has heard from the exchange

// Wait for the next inbound byte and pop it. Returns nonzero if it ended the frame.
static inline int eth_rx_byte(unsigned char* b)
{
    unsigned int status;
    while (!((status = ETH_STATUS) & ETH_RX_VALID)) ;
    *b = ETH_RX_DATA;
    return status & ETH_RX_LAST;
}

// Wait for room and send one byte of the response.
static inline void eth_tx_byte(unsigned char b)
{
    while (!(ETH_STATUS & ETH_TX_READY)) ;
    ETH_TX_DATA = b;
}

// Send one 8-byte message.
static inline void eth_tx_msg(const unsigned char* m)
{
    for (int i = 0; i < 8; i++) eth_tx_byte(m[i]);
}

// Close the response frame: the hardware pads it to whole messages and appends the END.
static inline void eth_tx_end(void)
{
    ETH_TX_END = 1;
}

#endif
