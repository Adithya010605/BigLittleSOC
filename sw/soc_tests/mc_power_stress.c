// mc_power_stress.c — E-cores storing into lines the P cluster's flush is
// writing back.
//
// Each round:
//   1. harts 0 and 1 (P-cores) each fill 16 lines of a shared region, so
//      the lines are modified in their L1s, and go to sleep;
//   2. hart 2 switches the P cluster off, and harts 2 and 3 (E-cores)
//      immediately start storing their own word (6 and 7) of every line,
//      over and over, last line first, while the P L1s' flush walks the same
//      lines first line first: the two sweeps meet head-on. A line the
//      E-cores take while its writeback waits for the bus must not be written
//      back afterwards, or the E-core's word is lost;
//   3. once the cluster is off, hart 2 wakes harts 0 and 1 (switching it on
//      again) and every hart checks every word it owns, and the P harts also
//      the E harts' last values.
//
// The region sits in the L1s' first sets, where the flush starts, so the
// sweeps meet within the first few dozen cycles of it. The testbench checks
// every load, the L2 and memory against the coherent values throughout.
//
// Needs 2 P-cores + 2 E-cores; on any other configuration it passes
// trivially.
#include "pmu.h"
#include "soc.h"

#define LINES 32
#define ROUNDS 6
#define WAY_BYTES 8192   // the E-cores' L1 way; the P-cores' is 8 KB too

static uint32_t region[LINES][8] __attribute__((aligned(WAY_BYTES)));
static volatile uint32_t asleep_round[2];
static volatile uint32_t e_last[2][LINES];
static volatile uint32_t e_done[2];
static volatile uint32_t woken_round;

static volatile uint32_t* word(int line, int w) { return (volatile uint32_t*)&region[line][w]; }

static uint32_t p_val(int h, int line, int w, int r) {
  return 0x50000000u ^ ((uint32_t)h << 20) ^ ((uint32_t)line << 8) ^ ((uint32_t)w << 4) ^ (uint32_t)r;
}

static int p_hart(int h, int r) {
  // 1. fill own 16 lines (words 0..5), then sleep
  for (int l = 16 * h; l < 16 * h + 16; ++l)
    for (int w = 0; w < 6; ++w) *word(l, w) = p_val(h, l, w, r);
  asleep_round[h] = (uint32_t)r;
  PWR_SLEEP = 1u << h;
  while (woken_round != (uint32_t)r) {
  }
  // 3. check own words and the E harts' last values
  for (int l = 16 * h; l < 16 * h + 16; ++l) {
    for (int w = 0; w < 6; ++w)
      if (*word(l, w) != p_val(h, l, w, r)) return 1;
    if (*word(l, 6) != e_last[0][l] || *word(l, 7) != e_last[1][l]) return 2;
  }
  return 0;
}

static int e_hart(int h, int r) {
  const int k = h - 2;            // 0: word 6, 1: word 7
  if (h == 2) {
    for (int c = 0; c < 2; ++c) {
      while (asleep_round[c] != (uint32_t)r) {
      }
      pmu_wait_core(c, CS_SLEEP | CS_HALTED, CS_SLEEP | CS_HALTED);
    }
    PWR_PD_CTRL = 1u;             // P cluster off: its flush starts now
  } else {
    while ((PWR_PD_STATUS & ((1u << 4) | 1u)) == 0) {   // flushing (or already off)
    }
  }
  // 2. sweep the lines, storing word 6 / 7, until the cluster is off
  const uint32_t base = 0xE0000000u ^ ((uint32_t)h << 24) ^ ((uint32_t)r << 16);
  uint32_t n = 0;
  do {
    const uint32_t vn = base ^ (n << 6);
    for (int l = LINES - 1; l >= 0; --l) *word(l, 6 + k) = vn ^ (uint32_t)l;
    ++n;
  } while ((PWR_PD_STATUS & 1u) == 0);
  for (int l = 0; l < LINES; ++l) e_last[k][l] = base ^ ((n - 1) << 6) ^ (uint32_t)l;
  if (PWR_PD_STATUS & (1u << 8)) return 1;   // the request was refused
  for (int l = 0; l < LINES; ++l)
    if (*word(l, 6 + k) != e_last[k][l]) return 2;
  e_done[k] = (uint32_t)r;
  if (h == 2) {
    while (e_done[1] != (uint32_t)r) {
    }
    PWR_PD_CTRL = 0u;
    PWR_WAKE = 0x3u;              // wakes harts 0, 1: the cluster comes back on
    while (PWR_PD_STATUS & 1u) {
    }
    woken_round = (uint32_t)r;
  }
  return 0;
}

int main(int h) {
#if NHARTS != 4 || NUM_P != 2
  (void)h;
  return 0;
#else
  for (int r = 1; r <= ROUNDS; ++r) {
    mc_barrier(h);
    const int res = (h < 2) ? p_hart(h, r) : e_hart(h, r);
    if (res != 0) return 0x10 * r + res;
  }
  return 0;
#endif
}
