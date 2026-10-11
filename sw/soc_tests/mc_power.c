// mc_power.c — cluster power domains: flush, off, and on again.
//
//   1. Harts 2 and 3 finish; hart 0 parks them and switches the E cluster
//      off. Its L1s are flushed and their clocks stopped (PD_STATUS,
//      CORE_STATE).
//   2. Harts 0 and 1 dirty buffers in their P-cores' L1s, then move to the
//      E-cores: migrating into a switched-off cluster switches it on.
//   3. Hart 0, now on an E-core, switches the P cluster off. Its L1s hold
//      the modified buffers, so the flush must write them back: both harts
//      then read them back from the L2. A request to switch off the cluster
//      they are running on is refused.
//   4. Both harts move back to the P-cores (switching the P cluster on) and
//      check their buffers once more.
//
// The testbench checks every load against the coherent value and the L2 and
// memory against the reference throughout, so a modified line lost by a
// flush is caught even before the program reads it.
//
// Needs 2 P-cores + 2 E-cores; on any other configuration it passes
// trivially.
#include "pmu.h"
#include "soc.h"

#define WORDS 512    // 2 KB per hart: 64 lines, all modified in the P-core's L1

static volatile uint32_t buf[2][WORDS];
static volatile uint32_t step[2];          // per hart: progress
static volatile uint32_t p_off_done;

#define PD_OFF(k)      (1u << (k))
#define PD_FLUSHING(k) (1u << (4 + (k)))
#define PD_REFUSED     (1u << 10)

static uint32_t pattern(int h, int i, uint32_t round) {
  return 0xC0DE0000u ^ ((uint32_t)h << 24) ^ ((uint32_t)i * 0x9E37u) ^ (round << 20);
}

static int check_buf(int h, uint32_t round) {
  for (int i = 0; i < WORDS; ++i)
    if (buf[h][i] != pattern(h, i, round)) return 1;
  return 0;
}

static int hart0(void) {
  // 1. E cluster off
  while (mc_result[2] == 0 || mc_result[3] == 0) {
  }
  PWR_PARK = (1u << 2) | (1u << 3);
  for (int c = 2; c < 4; ++c)
    pmu_wait_core(c, CS_ACTIVE | CS_HALTED | CS_CLK_EN, CS_HALTED);
  PWR_PD_CTRL = PD_OFF(1);
  while ((PWR_PD_STATUS & PD_OFF(1)) == 0) {
  }
  if (PWR_PD_STATUS & (PD_REFUSED | PD_FLUSHING(1))) return 1;
  for (int c = 2; c < 4; ++c)
    if (PWR_CORE_STATE(c) & (CS_L1_CLK | CS_CLK_EN)) return 2;
  const uint32_t g0 = PWR_GATED(2);
  for (volatile int i = 0; i < 50; ++i) {
  }
  if (PWR_GATED(2) == g0) return 3;

  // 2. dirty the buffer, move to E-core 2 (switching the E cluster on)
  for (int i = 0; i < WORDS; ++i) buf[0][i] = pattern(0, i, 1);
  step[0] = 1;
  while (step[1] < 1) {
  }
  if (pmu_migrate(0, MIG_PARTNER) != 0) return 4;
  if (pmu_on_pcore() || (PWR_PD_STATUS & PD_OFF(1))) return 5;
  while (pmu_core_of(1) != 3) {   // hart 1 moves itself...
  }
  while (MIG_STATUS & 1u) {        // ...and the move must be complete: a power
  }                                // request during a migration is refused

  // 3. P cluster off: both P-cores are parked now. Its L1s hold modified
  //    buffers; the flush writes them back.
  PWR_PD_CTRL = PD_OFF(0);
  while ((PWR_PD_STATUS & PD_OFF(0)) == 0) {
    if (PWR_PD_STATUS & PD_REFUSED) return 6;
  }
  for (int c = 0; c < 2; ++c)
    if (PWR_CORE_STATE(c) & (CS_L1_CLK | CS_CLK_EN)) return 7;
  if (check_buf(0, 1)) return 8;
  // switching off the cluster this hart runs on is refused
  PWR_PD_CTRL = PD_OFF(0) | PD_OFF(1);
  while (PWR_PD_CTRL & PD_OFF(1)) {
  }
  if (!(PWR_PD_STATUS & PD_REFUSED) || !(PWR_PD_STATUS & PD_OFF(0))) return 9;
  for (int i = 0; i < WORDS; ++i) buf[0][i] = pattern(0, i, 2);   // now in E-core 2's write-through L1
  p_off_done = 1;

  // 4. back to P-core 0: the P cluster comes back on
  while (step[1] < 2) {
  }
  if (pmu_migrate(0, MIG_PARTNER) != 0) return 10;
  if (!pmu_on_pcore() || (PWR_PD_STATUS & PD_OFF(0))) return 11;
  if (check_buf(0, 2)) return 12;
  while (step[1] < 3) {
  }
  if (PWR_PD_STATUS & (PD_OFF(0) | PD_OFF(1) | PD_FLUSHING(0) | PD_FLUSHING(1))) return 13;
  return 0;
}

static int hart1(void) {
  while (step[0] < 1) {
  }
  for (int i = 0; i < WORDS; ++i) buf[1][i] = pattern(1, i, 1);
  step[1] = 1;
  while (pmu_core_of(0) != 2) {   // after hart 0, so one request at a time
  }
  if (pmu_migrate(1, MIG_PARTNER) != 0) return 1;
  if (pmu_on_pcore()) return 2;
  while (!p_off_done) {
  }
  if (check_buf(1, 1)) return 3;   // written back by the P cluster's flush
  for (int i = 0; i < WORDS; ++i) buf[1][i] = pattern(1, i, 2);
  step[1] = 2;
  while (pmu_core_of(0) != 0) {
  }
  if (pmu_migrate(1, MIG_PARTNER) != 0) return 4;
  if (!pmu_on_pcore()) return 5;
  if (check_buf(1, 2)) return 6;
  step[1] = 3;
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
