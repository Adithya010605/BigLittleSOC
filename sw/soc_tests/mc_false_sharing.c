// mc_false_sharing.c — every hart writes its own part of shared lines.
//
// word_line: hart h increments word h of one 32-byte line.
// byte_line: hart h increments byte h of another, so stores from different
//            harts merge inside a single word.
// No hart ever reads another hart's data until the end, so the program is
// race-free, but the lines bounce between the caches on every store. A lost
// byte merge, a stale copy written back over a newer one, or a flush that
// misses a word all show up as a wrong final count.
#include "soc.h"

#define ITERS 300

static volatile uint32_t word_line[8] __attribute__((aligned(32)));
static volatile uint8_t byte_line[32] __attribute__((aligned(32)));
static volatile uint16_t half_line[16] __attribute__((aligned(32)));

int main(int h) {
  for (int i = 0; i < ITERS; ++i) {
    word_line[h] = word_line[h] + 1;
    byte_line[h] = (uint8_t)(byte_line[h] + 1);
    half_line[h + 4] = (uint16_t)(half_line[h + 4] + 3);
  }
  mc_barrier(h);
  if (h == 0) {
    for (int i = 0; i < NHARTS; ++i) {
      if (word_line[i] != ITERS) return 1;
      if (byte_line[i] != (uint8_t)ITERS) return 2;
      if (half_line[i + 4] != (uint16_t)(3 * ITERS)) return 3;
    }
    for (int i = NHARTS; i < 8; ++i)
      if (word_line[i] != 0) return 4;          // neighbours untouched
    for (int i = NHARTS; i < 32; ++i)
      if (byte_line[i] != 0) return 5;
  }
  return 0;
}
