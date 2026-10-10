#define RECV_CTRL (*((volatile unsigned int*)0x80000014) & 0x01)
#define RECV_DATA (*((volatile unsigned int*)0x80000000) & 0xFF)

#define TRAN_CTRL (*((volatile unsigned int*)0x80000014) & 0x20)
#define TRAN_DATA (*((volatile unsigned int*)0x80000000))

int main(void)
{
    for ( ; ; )
    {
        while (!RECV_CTRL) ;
        char byte = RECV_DATA;
        while ((TRAN_CTRL != 0x20)) ;
        TRAN_DATA = byte;
    }

    return 0;
}
