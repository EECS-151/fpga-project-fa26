#ifndef UART_H_
#define UART_H_

#include "types.h"

#define URECV_CTRL (*((volatile uint32_t*)0x80000014) & 0x01)
#define URECV_DATA (*((volatile uint32_t*)0x80000000) & 0xff)

#define UTRAN_CTRL (*((volatile uint32_t*)0x80000014) & 0x20)
#define UTRAN_DATA (*((volatile uint32_t*)0x80000000))

void uwrite_int8(int8_t c);

void uwrite_int8s(const int8_t* s);

int8_t uread_int8(void);

int8_t uread_int8_noecho(void);

#endif
