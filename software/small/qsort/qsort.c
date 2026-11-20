#include "types.h"
#include "benchmark.h"
#include "ascii.h"
#include "uart.h"

// Sorts PASSES arrays of N pseudo-random signed integers with quicksort, finishing short ranges
// with insertion sort. Which way its comparisons go depends on the data, so its branches are hard
// to predict.
// Result: a checksum of the sorted arrays (0 if one isn't sorted).

#define N 256
#define PASSES 4
#define CUTOFF 16           // ranges this short are insertion sorted

static int32_t a[N];
static uint32_t seed;

static uint32_t xorshift32() {
    uint32_t x = seed;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return seed = x;
}

static void insertion_sort(int32_t lo, int32_t hi) {
    for (int32_t i = lo + 1; i <= hi; i++) {
        int32_t v = a[i];
        int32_t j = i - 1;
        while (j >= lo && a[j] > v) {
            a[j + 1] = a[j];
            j--;
        }
        a[j + 1] = v;
    }
}

// Sorts a[lo..hi]
static void quicksort(int32_t lo, int32_t hi) {
    while (hi - lo > CUTOFF) {
        // Hoare partition around the middle element: a[lo..j] <= pivot <= a[j+1..hi]
        int32_t pivot = a[lo + ((hi - lo) >> 1)];
        int32_t i = lo - 1, j = hi + 1;
        for (;;) {
            do i++; while (a[i] < pivot);
            do j--; while (a[j] > pivot);
            if (i >= j)
                break;
            int32_t t = a[i];
            a[i] = a[j];
            a[j] = t;
        }
        // recurse into the smaller side and loop on the larger, which bounds the stack depth
        if (j - lo < hi - j) {
            quicksort(lo, j);
            lo = j + 1;
        } else {
            quicksort(j + 1, hi);
            hi = j;
        }
    }
    insertion_sort(lo, hi);
}

uint32_t sort() {
    uint32_t sum = 0;
    for (int32_t pass = 0; pass < PASSES; pass++) {
        for (int32_t i = 0; i < N; i++)
            a[i] = (int32_t) xorshift32();
        quicksort(0, N - 1);
        for (int32_t i = 0; i < N; i++) {
            if (i > 0 && a[i - 1] > a[i])
                return 0;
            sum = ((sum << 5) | (sum >> 27)) ^ (uint32_t) a[i];
        }
    }
    return sum;
}

typedef void (*entry_t)(void);

int main(int argc, char**argv) {
    seed = 0x151;
    run_and_time(&sort);
    // go back to the bios - using this function causes a jr to the addr,
    // the compiler "jals" otherwise and then cannot set PC[31:28]
    uint32_t bios = ascii_hex_to_uint32("40000000");
    entry_t start = (entry_t) (bios);
    start();
    return 0;
}
