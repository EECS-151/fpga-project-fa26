#include "eth.h"

// Ethernet loopback: send every inbound frame's payload back as the response. The hardware pads
// the response to whole 8-byte messages and appends an END and a trailer. Pair with host/eth_loopback_test.
int main(void)
{
    for ( ; ; )
    {
        unsigned char byte;
        int last;
        do {
            last = eth_rx_byte(&byte);
            eth_tx_byte(byte);
        } while (!last);
        eth_tx_end();
    }

    return 0;
}
