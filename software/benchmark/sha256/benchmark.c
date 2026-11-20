#include "benchmark.h"
#include "ascii.h"
#include "uart.h"
#include "memory_map.h"

#define BUF_LEN 128

void run_and_time(uint32_t (*f)()) {
    uint32_t result, time, instructions, br_insts, bp_correct;
    int8_t buffer[BUF_LEN];
    reset_counters();
    result = (*f)();
    time = read_cycle_counter();
    instructions = read_instret_counter();
    uwrite_int8s("Result: ");
    uwrite_int8s(uint32_to_ascii_hex(result, buffer, BUF_LEN));
    uwrite_int8s("\r\nCycle Count: ");
    uwrite_int8s(uint32_to_ascii_hex(time, buffer, BUF_LEN));
    uwrite_int8s("\r\nInstruction Count: ");
    uwrite_int8s(uint32_to_ascii_hex(instructions, buffer, BUF_LEN));
    uwrite_int8s("\r\n");
}
