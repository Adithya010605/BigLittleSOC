// mc_auto.c — migrations the PMU decides on its own.
//
// Harts 2 and 3 finish and are parked, so both E-cores are free.
//
//   1. IPC monitor. WINDOW = 512 cycles, HYST = 2 windows, LOW = 256
//      instructions. Hart 0 computes (high IPC) and must stay put; hart 1
//      spins on uncached PMU reads (low IPC) and must be moved to its E-core
//      partner. There it computes, and once it sets HIGH = 128 its IPC is
//      high enough to bring it back to its P-core.
//   2. Power budget. With BUDGET = 1 and both P-cores busy, the PMU moves one
//      P-core context (the lowest-numbered: hart 0) to its E-core partner.
//
// Every move lands somewhere in the middle of the harts' C code; the harts
// keep running checksums across all of them and verify them at the end.
//
// Needs 2 P-cores + 2 E-cores; on any other configuration it passes
// trivially.
#include "pmu.h"
#include "soc.h"

static volatile uint32_t go1, hart1_moved_back, phase2_go, phase2_done;

static uint32_t step(uint32_t x) { return x * 1664525u + 1013904223u; }

// n batches of 16 steps
static uint32_t work(uint32_t x, uint32_t n) {
  for (uint32_t b = 0; b < n; ++b)
    for (int i = 0; i < 16; ++i) x = step(x);
  return x;
}

static int hart0(void) {
  while (mc_result[2] == 0 || mc_result[3] == 0) {
  }
  PWR_PARK = (1u << 2) | (1u << 3);
  for (int c = 2; c < 4; ++c)
    pmu_wait_core(c, CS_ACTIVE | CS_HALTED | CS_CLK_EN, CS_HALTED);

  // 1. IPC
  MIG_WINDOW = 512;
  MIG_HYST = 2;
  MIG_LOW = 256;
  MIG_HIGH = 0xFFFFFFFFu;
  MIG_AUTO = 1;
  go1 = 1;
  uint32_t x = 1, n = 0;
  while (!hart1_moved_back) {
    x = work(x, 1);
    ++n;
  }
  MIG_AUTO = 0;
  if (!pmu_on_pcore() || pmu_core_of(0) != 0) return 1;   // hart 0 never moved
  if (MIG_COUNT != 2) return 2;
  if ((MIG_LAST_ROUTE & 0xFFFu) != 0x113u) return 3;      // hart 1: core 3 -> core 1
  if (MIG_LAST_IPC(0) < 256) return 4;
  if (x != work(1, n)) return 5;

  // 2. budget: one P-core may run
  MIG_LOW = 0;
  MIG_HIGH = 0xFFFFFFFFu;
  MIG_BUDGET = 1;
  phase2_go = 1;
  MIG_AUTO = 1;
  x = 7;
  n = 0;
  while (pmu_on_pcore()) {
    x = work(x, 1);
    ++n;
  }
  MIG_AUTO = 0;
  if (pmu_core_of(0) != 2 || pmu_core_of(1) != 1) return 6;
  if (MIG_COUNT != 3 || (MIG_LAST_ROUTE & 0xFFFu) != 0x020u) return 7;
  if (x != work(7, n)) return 8;
  MIG_BUDGET = 2;
  if (pmu_migrate(0, MIG_PARTNER) != 0 || !pmu_on_pcore()) return 9;
  phase2_done = 1;
  return 0;
}

static int hart1(void) {
  while (!go1) {
  }
  // low IPC: one uncached read per iteration, until the PMU moves us
  uint32_t spins = 0;
  while (pmu_on_pcore()) {
    (void)PWR_ID;
    ++spins;
  }
  if (pmu_core_of(1) != 3 || pmu_hartid() != 1) return 1;
  // high IPC on the E-core: compute until moved back
  MIG_HIGH = 128;
  uint32_t x = spins, n = 0;
  while (!pmu_on_pcore()) {
    x = work(x, 1);
    ++n;
  }
  if (pmu_core_of(1) != 1) return 2;
  if (x != work(spins, n)) return 3;
  hart1_moved_back = 1;

  // phase 2: keep computing on the P-core while hart 0 is moved
  while (!phase2_go) {
  }
  x = 3;
  n = 0;
  while (!phase2_done) {
    x = work(x, 1);
    ++n;
  }
  if (!pmu_on_pcore() || x != work(3, n)) return 4;
  return 0;
}

int main(int h) {
#if NHARTS != 4 || NUM_P != 2
  (void)h;
  return 0;
#else
  if (h == 0) return hart0();
  if (h == 1) return hart1();
  return 0;
#endif
}
