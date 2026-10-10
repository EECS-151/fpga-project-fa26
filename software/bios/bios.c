#include "ascii.h"
#include "uart.h"
#include "string.h"
#include "memory_map.h"

int8_t* read_n(int8_t*b, uint32_t n) {
    for (uint32_t i = 0; i < n;  i++) {
        b[i] =  uread_int8_noecho();
    }
    b[n] = '\0';
    return b;
}

int8_t* read_token(int8_t* b, uint32_t n, int8_t* ds) {
    uint32_t i = 0;
    while (i < n) {
        int8_t ch = uread_int8();
        if (ch == '\x08') { // backspace character
            if (i == 0)
                uwrite_int8('\x20'); // space
            else {
                b[i] = '\0'; // null current idx in buffer
                i = i - 1;
                uwrite_int8s("\x20\x08"); // space + backspace
            }
        } else {
            for (uint32_t j = 0; ds[j] != '\0'; j++) {
                if (ch == ds[j]) {
                    b[i] = '\0';
                    return b;
                }
            }
            b[i] = ch;
            i = i + 1;
        }
    }
    b[n - 1] = '\0';
    return b;
}

void store(uint32_t address, uint32_t length) {
    for (uint32_t i = 0; i*4 < length; i++) {
        int8_t buffer[9];
        int8_t* ascii_instruction = read_n(buffer,8);
        volatile uint32_t* p = (volatile uint32_t*)(address+i*4);
        *p = ascii_hex_to_uint32(ascii_instruction);
    }
}

void store_opt(register uint32_t address, register uint32_t length) {
    volatile uint8_t* const ctrl = (volatile uint8_t*)0x80000014;
    volatile uint8_t* const data = (volatile uint8_t*)0x80000000;
    for (register uint32_t i = 0; i < length; i += 4) {
        uint32_t p = address + i;
        uint32_t tmp;
        asm volatile(
            "1:\n\t"
            "lbu %[t], 0(%[c])\n\t"
            "andi %[t], %[t], 1\n\t"
            "beqz %[t], 1b\n\t"
            "lbu %[t], 0(%[d])\n\t"
            "sb %[t], 0(%[p])\n\t"
            "addi %[p], %[p], 1\n\t"
            "2:\n\t"
            "lbu %[t], 0(%[c])\n\t"
            "andi %[t], %[t], 1\n\t"
            "beqz %[t], 2b\n\t"
            "lbu %[t], 0(%[d])\n\t"
            "sb %[t], 0(%[p])\n\t"
            "addi %[p], %[p], 1\n\t"
            "3:\n\t"
            "lbu %[t], 0(%[c])\n\t"
            "andi %[t], %[t], 1\n\t"
            "beqz %[t], 3b\n\t"
            "lbu %[t], 0(%[d])\n\t"
            "sb %[t], 0(%[p])\n\t"
            "addi %[p], %[p], 1\n\t"
            "4:\n\t"
            "lbu %[t], 0(%[c])\n\t"
            "andi %[t], %[t], 1\n\t"
            "beqz %[t], 4b\n\t"
            "lbu %[t], 0(%[d])\n\t"
            "sb %[t], 0(%[p])\n\t"
            : [t] "=&r"(tmp), [p] "+r"(p)
            : [c] "r"(ctrl), [d] "r"(data)
            : "memory");
    }
}

void dump(uint32_t start_address, uint32_t length) {
    uwrite_int8s("\r\n");
    uwrite_int8s("Dumping memory...\r\n");
    uwrite_int8s("Memory dump:\r\n");
    for (uint32_t addr = start_address; addr < start_address + length; addr += 4) {
        volatile uint32_t* p = (volatile uint32_t*)(addr);
        int8_t buffer[9];
        uint32_to_ascii_hex(addr, buffer, 9);
        uwrite_int8s(buffer);
        uwrite_int8s(":");
        uint32_to_ascii_hex(*p, buffer, 9);
        uwrite_int8s(buffer);
        uwrite_int8s("\r\n");
    }
}


#define BUFFER_LEN 128

typedef void (*entry_t)(void);

int main(void) {
    uwrite_int8s("\r\n");

    while (1) {
        uwrite_int8s("151> ");

        int8_t buffer[BUFFER_LEN];
        int8_t* input = read_token(buffer, BUFFER_LEN, " \x0d");

        if (strcmp(input, "file") == 0) {
            uint32_t address = ascii_hex_to_uint32(read_token(buffer, BUFFER_LEN, " \x0d"));
            uint32_t file_length = ascii_dec_to_uint32(read_token(buffer, BUFFER_LEN, " \x0d"));
            store(address, file_length);
        } else if (strcmp(input, "opt_file") == 0) {
            uint32_t address = ascii_hex_to_uint32(read_token(buffer, BUFFER_LEN, " \x0d"));
            uint32_t file_length = ascii_dec_to_uint32(read_token(buffer, BUFFER_LEN, " \x0d"));
            store_opt(address, file_length);
        } else if (strcmp(input, "dump") == 0) {
            uint32_t address = ascii_hex_to_uint32(read_token(buffer, BUFFER_LEN, " \x0d"));
            uint32_t length = ascii_dec_to_uint32(read_token(buffer, BUFFER_LEN, " \x0d"));
            dump(address, length);
        } else if (strcmp(input, "jal") == 0) {
            uint32_t address = ascii_hex_to_uint32(read_token(buffer, BUFFER_LEN, " \x0d"));

            entry_t start = (entry_t)(address);
            start();
        } else if (strcmp(input, "lw") == 0) {
            uint32_t address = ascii_hex_to_uint32(read_token(buffer, BUFFER_LEN, " \x0d"));
            volatile uint32_t* p = (volatile uint32_t*)(address);

            uwrite_int8s(uint32_to_ascii_hex(address, buffer, BUFFER_LEN));
            uwrite_int8s(":");
            uwrite_int8s(uint32_to_ascii_hex(*p, buffer, BUFFER_LEN));
            uwrite_int8s("\r\n");
        } else if (strcmp(input, "lhu") == 0) {
            uint32_t address = ascii_hex_to_uint32(read_token(buffer, BUFFER_LEN, " \x0d"));
            volatile uint16_t* p = (volatile uint16_t*)(address);

            uwrite_int8s(uint32_to_ascii_hex(address, buffer, BUFFER_LEN));
            uwrite_int8s(":");
            uwrite_int8s(uint16_to_ascii_hex(*p, buffer, BUFFER_LEN));
            uwrite_int8s("\r\n");
        } else if (strcmp(input, "lbu") == 0) {
            uint32_t address = ascii_hex_to_uint32(read_token(buffer, BUFFER_LEN, " \x0d"));
            volatile uint8_t* p = (volatile uint8_t*)(address);

            uwrite_int8s(uint32_to_ascii_hex(address, buffer, BUFFER_LEN));
            uwrite_int8s(":");
            uwrite_int8s(uint8_to_ascii_hex(*p, buffer, BUFFER_LEN));
            uwrite_int8s("\r\n");
        } else if (strcmp(input, "sw") == 0) {
            uint32_t word = ascii_hex_to_uint32(read_token(buffer, BUFFER_LEN, " \x0d"));
            uint32_t address = ascii_hex_to_uint32(read_token(buffer, BUFFER_LEN, " \x0d"));

            volatile uint32_t* p = (volatile uint32_t*)(address);
            *p = word;
        } else if (strcmp(input, "sh") == 0) {
            uint16_t half = ascii_hex_to_uint16(read_token(buffer, BUFFER_LEN, " \x0d"));
            uint32_t address = ascii_hex_to_uint32(read_token(buffer, BUFFER_LEN, " \x0d"));

            volatile uint16_t* p = (volatile uint16_t*)(address);
            *p = half;
        } else if (strcmp(input, "sb") == 0) {
            uint8_t byte = ascii_hex_to_uint8(read_token(buffer, BUFFER_LEN, " \x0d"));
            uint32_t address = ascii_hex_to_uint32(read_token(buffer, BUFFER_LEN, " \x0d"));

            volatile uint8_t* p = (volatile uint8_t*)(address);
            *p = byte;
        } else {
            uwrite_int8s("\n\rUnrecognized token: ");
            uwrite_int8s(input);
            uwrite_int8s("\n\r");
        }
    }

    return 0;
}
