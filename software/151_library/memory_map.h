#include "types.h"

#define csr_tohost(csr_val) { \
    asm volatile ("csrw 0x51e,%[v]" :: [v]"r"(csr_val)); \
}


// Reset mcycle and minstret (low and high words)
static inline void reset_counters(void) {
    asm volatile("csrwi 0x802, 0\n\t"  // minstret (low) = 0
                 "csrwi 0xB82, 0"      // minstreth (high) = 0
                 ::: "memory");
    asm volatile("csrwi 0x800, 0\n\t"  // mcycle (low) = 0
                 "csrwi 0xB80, 0"      // mcycleh (high) = 0
                 ::: "memory");
}

// Read instruction-retired counter (instret/h)
static inline uint32_t read_instret_counter(void) {
    uint32_t value;
    asm volatile("csrr %0, 0x802" : "=r"(value));
    return value;
}

// Read high word of instruction-retired counter (instreth)
static inline uint32_t read_instret_counter_high(void) {
    uint32_t value;
    asm volatile("csrr %0, 0xB82" : "=r"(value));
    return value;
}

// Read cycle counter (cycle)
static inline uint32_t read_cycle_counter(void) {
    uint32_t value;
    asm volatile("csrr %0, 0x800" : "=r"(value));
    return value;
}

// Read high word of cycle counter (cycleh)
static inline uint32_t read_cycle_counter_high(void) {
    uint32_t value;
    asm volatile("csrr %0, 0xB80" : "=r"(value));
    return value;
}
