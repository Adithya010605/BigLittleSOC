// mc_dvfs.c — per-cluster clock dividers (the DVFS stub).
//
// For each setting of PWR_DVFS, every hart times the same compute loop twice
// over: in its own core's clock cycles (mcycle, which only counts when the
// core's clock runs) and in system cycles (the PMU's RUN + GATED counters of
// core 0, which together count every cycle). The ratio must be the
// cluster's divider: 1, 2 or 4.
//
// Between measurements the harts share a lock-protected counter at the
// current speeds, so the caches have to hold responses for paused cores in
// the middle of real coherence traffic (the testbench checks every access).
//
// Needs 2 P-cores + 2 E-cores; on any other configuration it passes
// trivially.
#include "pmu.h"
#include "soc.h"

#define LOOP 600
#define LOCKED_INCS 40

static mc_bakery_t lock;
static volatile uint32_t shared_count;
static volatile uint32_t ratio_x8[NHARTS][4];

static inline uint32_t mcycle(void) {
  uint32_t v;
  __asm__ volatile("csrr %0, mcycle" : "=r"(v));
  return v;
}

static inline uint32_t systime(void) { return PWR_RUN(0) + PWR_GATED(0); }

// Divider codes per phase: P cluster, E cluster.
static const uint32_t kCode[4][2] = {
    {DVFS_1_2, DVFS_1_4}, {DVFS_1_4, DVFS_1_1}, {DVFS_1_1, DVFS_1_2}, {DVFS_1_1, DVFS_1_1}};

static uint32_t divider(uint32_t code) { return code == 0 ? 1 : (code == 1 ? 2 : 4); }

int main(int h) {
#if NHARTS != 4 || NUM_P != 2
  (void)h;
  return 0;
#else
  for (int phase = 0; phase < 4; ++phase) {
    mc_barrier(h);
    if (h == 0) PWR_DVFS = DVFS(kCode[phase][0], kCode[phase][1]);
    mc_barrier(h);
    if (h == 0 && PWR_DVFS != DVFS(kCode[phase][0], kCode[phase][1])) return 1;

    // timing
    const uint32_t s0 = systime();
    const uint32_t c0 = mcycle();
    uint32_t x = (uint32_t)h;
    for (int i = 0; i < LOOP; ++i) {
      x ^= x << 3;
      x += (uint32_t)i;
      __asm__ volatile("" : "+r"(x));
    }
    const uint32_t c1 = mcycle();
    const uint32_t s1 = systime();
    const uint32_t sys = s1 - s0, cyc = c1 - c0;
    const uint32_t d = divider(kCode[phase][mc_is_pcore(h) ? 0 : 1]);
    // sys / cyc must be d, within +-1/2
    ratio_x8[h][phase] = (sys << 3) / cyc;
    if (2 * sys < (2 * d - 1) * cyc || 2 * sys > (2 * d + 1) * cyc) return 0x10 + phase;

    // shared work at these speeds
    for (int i = 0; i < LOCKED_INCS; ++i) {
      mc_lock(&lock, h);
      shared_count = shared_count + 1;
      mc_unlock(&lock, h);
    }
  }
  mc_barrier(h);
  if (shared_count != 4u * NHARTS * LOCKED_INCS) return 2;
  return 0;
#endif
}
