// mc_l2_thrash.c — a working set larger than the L2.
//
// Every hart writes its own 20 KB slice of an 80 KB array (more than the
// 64 KB L2 holds), then checks the next hart's slice, for three rounds with
// fresh values. The L2 overflows constantly: lines are evicted while L1s still
// hold them (back-invalidation), modified P-core lines must be taken out of
// the L1 on the way (the newest data is there, not in the L2), and dirty L2
// victims must reach memory before the line is fetched again. Any of those
// steps lost shows up as a wrong value here, and as a wrong load in the
// testbench's coherence checker before that.
#include "soc.h"

#define SLICE_WORDS (20 * 1024 / 4)
#define ROUNDS 3

static uint32_t big[NHARTS][SLICE_WORDS] __attribute__((aligned(32)));

static uint32_t val(int h, int i, int round) {
  return ((uint32_t)h << 24) ^ ((uint32_t)i * 2654435761u) ^ ((uint32_t)round * 0x9E3779B9u);
}

int main(int h) {
  const int other = (h + 1 == NHARTS) ? 0 : h + 1;
  for (int round = 0; round < ROUNDS; ++round) {
    for (int i = 0; i < SLICE_WORDS; ++i) big[h][i] = val(h, i, round);
    mc_barrier(h);
    for (int i = 0; i < SLICE_WORDS; ++i)
      if (big[other][i] != val(other, i, round)) return 1 + round;
    mc_barrier(h);
  }
  return 0;
}
