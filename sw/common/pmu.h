// ============================================================================
// pmu.h — the power-management and task-migration registers (rtl/power/
// pmu.sv; register map in docs/power_migration.md), for sw/soc_tests/.
//
// Words are 32-bit and every register is uncached (the windows are above the
// cacheable limit), so a plain volatile access reaches the PMU directly.
//
// Harts ("contexts") are numbered as mhartid reads them; cores are physical:
// 0 .. NUM_P-1 P-cores, NUM_P .. N-1 E-cores. At reset core c runs hart c.
// ============================================================================
#ifndef PMU_H
#define PMU_H

#include <stdint.h>

#define PMU_REG(a) (*(volatile uint32_t*)(uintptr_t)(a))

// ---- power window ----
#define PWR_BASE          0x40000000u
#define PWR_ID            PMU_REG(PWR_BASE + 0x00)   // "PMU1"
#define PWR_SLEEP         PMU_REG(PWR_BASE + 0x04)   // W: harts (mask) to sleep
#define PWR_WAKE          PMU_REG(PWR_BASE + 0x08)   // W: harts (mask) to wake
#define PWR_PARK          PMU_REG(PWR_BASE + 0x0C)   // W: harts (mask) to stop for good
#define PWR_DVFS          PMU_REG(PWR_BASE + 0x10)   // [1:0] P, [3:2] E: 0 1/1, 1 1/2, 2 1/4
#define PWR_PD_CTRL       PMU_REG(PWR_BASE + 0x14)   // bit k: cluster k (0 P, 1 E) off
#define PWR_PD_STATUS     PMU_REG(PWR_BASE + 0x18)   // [1:0] off, [5:4] flushing, [10] refused
#define PWR_CORE_STATE(c) PMU_REG(PWR_BASE + 0x20 + 4u * (c))
#define PWR_RUN(c)        PMU_REG(PWR_BASE + 0x80 + 8u * (c))   // cycles clocked
#define PWR_GATED(c)      PMU_REG(PWR_BASE + 0x84 + 8u * (c))   // cycles gated

// CORE_STATE fields
#define CS_ACTIVE   (1u << 0)
#define CS_SLEEP    (1u << 1)
#define CS_HALTED   (1u << 2)
#define CS_CLK_EN   (1u << 3)
#define CS_L1_CLK   (1u << 4)
#define CS_HART(v)  (((v) >> 8) & 0xFu)

#define DVFS_1_1 0u
#define DVFS_1_2 1u
#define DVFS_1_4 2u
#define DVFS(p, e) ((p) | ((e) << 2))

// ---- migration window ----
#define MIG_BASE          0x50000000u
#define MIG_ID            PMU_REG(MIG_BASE + 0x00)   // "MIG1"
#define MIG_CTRL          PMU_REG(MIG_BASE + 0x04)   // W: [3:0] hart, [7:4] core (0xF partner), [31] go
#define MIG_STATUS        PMU_REG(MIG_BASE + 0x08)   // [0] busy, [1] last request refused, [10:8] state
#define MIG_COUNT         PMU_REG(MIG_BASE + 0x0C)
#define MIG_LAST_LATENCY  PMU_REG(MIG_BASE + 0x10)   // cycles, halt request to release
#define MIG_LAST_ROUTE    PMU_REG(MIG_BASE + 0x14)   // [3:0] src, [7:4] dst, [11:8] hart
#define MIG_AUTO          PMU_REG(MIG_BASE + 0x20)   // bit 0: monitors may migrate
#define MIG_WINDOW        PMU_REG(MIG_BASE + 0x24)   // IPC window, cycles
#define MIG_LOW           PMU_REG(MIG_BASE + 0x28)   // P-core: below this many retired per window...
#define MIG_HIGH          PMU_REG(MIG_BASE + 0x2C)   // E-core: above this many...
#define MIG_HYST          PMU_REG(MIG_BASE + 0x30)   // ...for this many windows in a row
#define MIG_BUDGET        PMU_REG(MIG_BASE + 0x34)   // most P-cores allowed to run
#define MIG_CTX_OF_CORE(c) PMU_REG(MIG_BASE + 0x40 + 4u * (c))   // [31] active, [3:0] hart
#define MIG_CORE_OF_CTX(h) PMU_REG(MIG_BASE + 0x60 + 4u * (h))   // [31] running, [3:0] core
#define MIG_LAST_IPC(c)   PMU_REG(MIG_BASE + 0x80 + 4u * (c))
#define MIG_BUF(k)        PMU_REG(MIG_BASE + 0x100 + 4u * (k))

#define MIG_PARTNER 0xFu
#define MIG_GO(h, dst) ((1u << 31) | ((uint32_t)(dst) << 4) | (uint32_t)(h))

// The core a hart runs on, or -1 if it is parked. (A migrating hart shows
// its destination from the transfer step on, while its state is still being
// restored: wait for MIG_STATUS to go idle before relying on the move being
// complete.)
static inline int pmu_core_of(int h) {
  const uint32_t v = MIG_CORE_OF_CTX(h);
  return (v >> 31) ? (int)(v & 0xFu) : -1;
}

// Is the calling hart on a P-core? The cores differ in misa's M bit.
static inline int pmu_on_pcore(void) {
  uint32_t misa;
  __asm__ volatile("csrr %0, misa" : "=r"(misa));
  return (misa >> 12) & 1u;
}

static inline uint32_t pmu_hartid(void) {
  uint32_t h;
  __asm__ volatile("csrr %0, mhartid" : "=r"(h));
  return h;
}

// Asks for hart h to move to core dst (or MIG_PARTNER) and waits until it has
// (a hart may move itself: it is halted somewhere after the request and
// resumes on the destination). Returns 0, or 1 if the PMU refused.
static inline int pmu_migrate(int h, uint32_t dst) {
  while (MIG_STATUS & 1u) {
  }
  const uint32_t before = MIG_COUNT;
  MIG_CTRL = MIG_GO(h, dst);
  for (;;) {
    const uint32_t st = MIG_STATUS;
    if (st & 2u) return 1;
    if (!(st & 1u) && MIG_COUNT != before) return 0;
  }
}

// Waits until core c's state, masked, equals want.
static inline void pmu_wait_core(int c, uint32_t mask, uint32_t want) {
  while ((PWR_CORE_STATE(c) & mask) != want) {
  }
}

#endif  // PMU_H
