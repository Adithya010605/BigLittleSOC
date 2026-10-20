// mc_dirty_sharing.c — modified data moving between caches and memory.
//
// 1. Hart 0 (P-core) writes a 24 KB array: more than its 16 KB L1, so most
//    of it is written back by evictions, and the rest stays modified.
// 2. Every hart checks the whole array (flushes of the still-modified lines
//    on snooped BusRd, refills of the written-back ones from memory), then
//    rewrites its own quarter.
// 3. Every hart checks the whole array again, seeing the others' writes:
//    lines written by P-cores come from their L1s, lines written by E-cores
//    from memory.
#include "soc.h"

#define WORDS (24 * 1024 / 4)

static uint32_t array[WORDS] __attribute__((aligned(32)));

static uint32_t first(int i) { return (uint32_t)i * 0x9E3779B9u + 0x1234u; }
static uint32_t second(int i) { return (uint32_t)i ^ 0xC0DE0000u; }

int main(int h) {
  if (h == 0)
    for (int i = 0; i < WORDS; ++i) array[i] = first(i);
  mc_barrier(h);
  for (int i = 0; i < WORDS; ++i)
    if (array[i] != first(i)) return 1;
  mc_barrier(h);
  const int lo = h * (WORDS / NHARTS);
  const int hi = (h + 1 == NHARTS) ? WORDS : lo + WORDS / NHARTS;
  for (int i = lo; i < hi; ++i) array[i] = second(i);
  mc_barrier(h);
  for (int i = 0; i < WORDS; ++i)
    if (array[i] != second(i)) return 2;
  return 0;
}
