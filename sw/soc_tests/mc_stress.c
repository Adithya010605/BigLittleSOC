// mc_stress.c — racing loads and stores, checked by the testbench.
//
// Every hart issues pseudo-random byte, halfword and word loads and stores
// over a small shared region: 4 sets x 4 tags x 8 words, where the tags are
// one cache-way size (8 KB) apart, so lines collide in every cache and
// evictions race snoops constantly. The accesses race freely; there is no
// right answer the program itself could check. The testbench's coherence
// checker is the oracle: it verifies every load against the coherent value.
//
// Each hart also owns one word per line that only it writes, and checks that
// it always reads back its own last write -- program order on one hart.
//
// SEED (from the build) varies the access pattern.
#include "soc.h"

#ifndef SEED
#define SEED 1
#endif
#define OPS 3000
#define WAY_BYTES 8192
#define SETS 4
#define TAGS 4    // powers of two: no software divide on the E-cores

// Aligned to a way, so (tag, set) maps to the same set in every cache.
static uint32_t mc_stress_region[(TAGS * WAY_BYTES) / 4] __attribute__((aligned(WAY_BYTES)));

static volatile uint32_t* addr_of(int tag, int set, int word) {
  return (volatile uint32_t*)((uintptr_t)mc_stress_region + (uintptr_t)tag * WAY_BYTES +
                              (uintptr_t)set * 32u + (uintptr_t)word * 4u);
}

int main(int h) {
  uint32_t s = 0x9E3779B9u * (uint32_t)(SEED * 31 + h + 1);
  uint32_t mine[TAGS][SETS] = {{0}};
  for (int i = 0; i < OPS; ++i) {
    const uint32_t r = mc_rand(&s);
    const int tag = (int)(r & (TAGS - 1));
    const int set = (int)((r >> 4) & (SETS - 1));
    const int kind = (int)((r >> 8) & 7);
    if (kind == 0) {
      // own word (word 4 + h): write, then read back
      const uint32_t v = mc_rand(&s);
      *addr_of(tag, set, 4 + h) = v;
      mine[tag][set] = v;
      if (*addr_of(tag, set, 4 + h) != v) return 1;
    } else if (kind == 1) {
      if (*addr_of(tag, set, 4 + h) != mine[tag][set]) return 2;
    } else {
      // shared words 0..3: random size and direction
      const int word = (int)((r >> 12) & 3);
      volatile uint8_t* b = (volatile uint8_t*)addr_of(tag, set, word);
      const uint32_t v = mc_rand(&s);
      switch ((r >> 16) & 7) {
        case 0: *addr_of(tag, set, word) = v; break;
        case 1: *(volatile uint16_t*)(b + 2 * ((r >> 20) & 1)) = (uint16_t)v; break;
        case 2: b[(r >> 20) & 3] = (uint8_t)v; break;
        case 3: (void)*(volatile uint16_t*)(b + 2 * ((r >> 20) & 1)); break;
        case 4: (void)b[(r >> 20) & 3]; break;
        default: (void)*addr_of(tag, set, word); break;
      }
    }
  }
  return 0;
}
