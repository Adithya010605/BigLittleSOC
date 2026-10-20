// ============================================================================
// soc.h — helpers for multi-core programs on the SoC (sw/soc_tests/).
//
// Every hart runs the same image; start_mc.S calls main(hartid). Harts
// 0 .. NUM_P-1 are P-cores, NUM_P .. NHARTS-1 are E-cores. Both are set on
// the command line by scripts/run_soc.sh.
//
// There are no atomic instructions in either core, so everything here is
// built from plain loads and stores with a single writer per location, which
// is correct on this system because it is sequentially consistent: each core
// performs one memory access at a time, in program order, and the L1 caches
// make every access take effect in the cycle the core sees it complete.
// ============================================================================
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#ifndef NHARTS
#error "NHARTS must be defined"
#endif
#ifndef NUM_P
#error "NUM_P must be defined"
#endif

static inline int mc_is_pcore(int h) { return h < NUM_P; }

// Each hart's result, published by start_mc.S when its main returns:
// (ret << 1) | 1, or 0 while it is still running.
extern volatile uint32_t mc_result[NHARTS];

// Stops the compiler from caching, merging or reordering memory accesses
// across this point. The hardware needs no fence (see above).
#define mc_compiler_barrier() __asm__ volatile("" ::: "memory")

// Barrier: hart h publishes how many barriers it has reached, then waits
// until every hart has reached at least as many. Counters only grow, so no
// reset phase is needed.
extern volatile uint32_t mc_barrier_count[NHARTS];
static inline void mc_barrier(int h) {
  const uint32_t mine = mc_barrier_count[h] + 1;
  mc_barrier_count[h] = mine;
  for (int i = 0; i < NHARTS; ++i) {
    while (mc_barrier_count[i] < mine) {
    }
  }
}

// Lamport's bakery lock: mutual exclusion for NHARTS harts from plain loads
// and stores.
typedef struct {
  volatile uint32_t choosing[NHARTS];
  volatile uint32_t number[NHARTS];
} mc_bakery_t;

static inline void mc_lock(mc_bakery_t* b, int h) {
  b->choosing[h] = 1;
  uint32_t max = 0;
  for (int i = 0; i < NHARTS; ++i) {
    const uint32_t n = b->number[i];
    if (n > max) max = n;
  }
  b->number[h] = max + 1;
  b->choosing[h] = 0;
  for (int j = 0; j < NHARTS; ++j) {
    if (j == h) continue;
    while (b->choosing[j]) {
    }
    for (;;) {
      const uint32_t nj = b->number[j];
      const uint32_t nh = b->number[h];
      if (nj == 0 || nj > nh || (nj == nh && j > h)) break;
    }
  }
}

static inline void mc_unlock(mc_bakery_t* b, int h) { b->number[h] = 0; }

// A small per-hart pseudo-random generator (xorshift32).
static inline uint32_t mc_rand(uint32_t* s) {
  uint32_t x = *s;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  *s = x;
  return x;
}

#endif  // SOC_H
