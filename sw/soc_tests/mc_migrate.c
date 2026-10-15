// mc_migrate.c — software-requested task migration, P -> E -> P.
//
// Harts 2 and 3 (the E-cores) finish at once and hart 0 parks them, leaving
// both E-cores free. Then:
//
//   1. hart 0 dirties a buffer in its P-core's L1, and moves itself to its
//      E-core partner from inside mig_selftest_to_e (mc_migrate.S), which
//      checks every register and travelling CSR across the move;
//   2. on the E-core: misa has no M, mhartid still reads 0, the PMU's
//      registers agree (CORE_OF_CTX, COUNT, LAST_ROUTE, LAST_LATENCY within
//      the plan's 100-cycle budget), the buffer reads back -- coherently,
//      out of the P-core's L1 -- the hart's stack and globals work, and its
//      software interrupt (the interrupt controller's hart-0 line) now
//      reaches it on the E-core;
//   3. it moves back (mig_selftest_to_p) and finds the M extension again;
//   4. hart 1, which has been computing all along, moves to its own E-core
//      partner and back through the C helper, its computation continuing
//      across both moves;
//   5. requests the PMU must refuse (destination busy, no such hart) are
//      refused and change nothing.
//
// Needs 2 P-cores + 2 E-cores; on any other configuration it passes
// trivially.
#include "pmu.h"
#include "soc.h"

int mig_selftest_to_e(uint32_t ctrl);
int mig_selftest_to_p(uint32_t ctrl);

#define BUF_WORDS 256

static volatile uint32_t buf[BUF_WORDS];
static volatile uint32_t go_hart1, hart1_done;
static volatile uint32_t hart1_sum;
static volatile uint32_t irq_core[NHARTS], irq_count;

#define IRQ_SW(h) (*(volatile uint32_t*)(uintptr_t)(0x11000008u + 0x100u * (h)))

__attribute__((interrupt("machine"), aligned(4))) static void handler(void) {
  IRQ_SW(pmu_hartid()) = 0;
  irq_core[irq_count & (NHARTS - 1)] = pmu_on_pcore();
  irq_count++;
}

// Raises this hart's own software interrupt and waits for the handler.
static int self_interrupt(void) {
  uint32_t old_mtvec;
  const uint32_t n = irq_count;
  __asm__ volatile("csrr %0, mtvec" : "=r"(old_mtvec));
  __asm__ volatile("csrw mtvec, %0" ::"r"(handler));
  __asm__ volatile("csrs mie, %0" ::"r"(1u << 3));
  __asm__ volatile("csrs mstatus, %0" ::"r"(1u << 3));
  IRQ_SW(pmu_hartid()) = 1;
  for (int i = 0; i < 10000 && irq_count == n; ++i) {
  }
  __asm__ volatile("csrc mstatus, %0" ::"r"(1u << 3));
  __asm__ volatile("csrc mie, %0" ::"r"(1u << 3));
  __asm__ volatile("csrw mtvec, %0" ::"r"(old_mtvec));
  return irq_count == n + 1 ? 0 : 1;
}

static uint32_t work(uint32_t x, int n) {
  for (int i = 0; i < n; ++i) x = x * 1664525u + 1013904223u;   // RV32I: mul by shifts
  return x;
}

static int hart0(void) {
  // Park the E-cores' harts once they have published their results.
  while (mc_result[2] == 0 || mc_result[3] == 0) {
  }
  PWR_PARK = (1u << 2) | (1u << 3);
  for (int c = 2; c < 4; ++c)
    pmu_wait_core(c, CS_ACTIVE | CS_SLEEP | CS_HALTED | CS_CLK_EN, CS_HALTED);
  if (pmu_core_of(2) != -1 || pmu_core_of(3) != -1) return 1;
  if (PWR_ID != 0x504D5531u || MIG_ID != 0x4D494731u) return 2;

  for (int i = 0; i < BUF_WORDS; ++i) buf[i] = 0xB0000000u + (uint32_t)i * 7u;

  // 1-2. P0 -> E-core 2
  if (!pmu_on_pcore()) return 3;
  const int r1 = mig_selftest_to_e(MIG_GO(0, MIG_PARTNER));
  if (r1 != 0) return 0x10 + r1;
  if (pmu_on_pcore() || pmu_hartid() != 0) return 4;
  if (pmu_core_of(0) != 2) return 5;
  if (MIG_COUNT != 1) return 6;
  if ((MIG_LAST_ROUTE & 0xFFFu) != 0x020u) return 7;   // hart 0, core 0 -> core 2
  if (MIG_LAST_LATENCY == 0 || MIG_LAST_LATENCY > 100) return 8;
  if ((PWR_CORE_STATE(0) & (CS_ACTIVE | CS_HALTED | CS_CLK_EN)) != CS_HALTED) return 9;
  if (CS_HART(PWR_CORE_STATE(2)) != 0) return 10;
  for (int i = 0; i < BUF_WORDS; ++i)
    if (buf[i] != 0xB0000000u + (uint32_t)i * 7u) return 11;
  for (int i = 0; i < BUF_WORDS; ++i) buf[i] ^= 0xFFFFu;
  if (self_interrupt() != 0 || irq_core[0] != 0) return 20;   // taken, on the E-core

  // 3. back to P-core 0
  const int r2 = mig_selftest_to_p(MIG_GO(0, MIG_PARTNER));
  if (r2 != 0) return 0x40 + r2;
  if (!pmu_on_pcore() || pmu_core_of(0) != 0 || MIG_COUNT != 2) return 12;
  for (int i = 0; i < BUF_WORDS; ++i)
    if (buf[i] != ((0xB0000000u + (uint32_t)i * 7u) ^ 0xFFFFu)) return 13;

  // 4. hart 1's turn
  go_hart1 = 1;
  while (!hart1_done) {
  }
  if (hart1_done != 1) return 14;
  if (MIG_COUNT != 4) return 15;

  // 5. refused requests: E-core 3 is free but hart 1 is running on core 1
  //    (destination busy); hart 7 does not exist.
  const uint32_t n = MIG_COUNT;
  if (pmu_migrate(0, 1) != 1) return 16;
  if (pmu_migrate(7, MIG_PARTNER) != 1) return 17;
  if (pmu_migrate(0, 0) != 1) return 18;                  // onto itself
  if (MIG_COUNT != n || pmu_core_of(0) != 0 || pmu_core_of(1) != 1) return 19;
  return 0;
}

static int hart1(void) {
  uint32_t x = work(1, 200);
  while (!go_hart1) x = work(x, 3);
  if (!pmu_on_pcore()) return 1;
  const uint32_t check = work(x, 500);
  // Moves while computing: the request returns once the move is done.
  if (pmu_migrate(1, MIG_PARTNER) != 0) return 2;
  if (pmu_on_pcore() || pmu_core_of(1) != 3 || pmu_hartid() != 1) return 3;
  x = work(x, 250);
  if (pmu_migrate(1, MIG_PARTNER) != 0) return 4;
  if (!pmu_on_pcore() || pmu_core_of(1) != 1) return 5;
  x = work(x, 250);
  if (x != check) return 6;
  hart1_sum = x;
  hart1_done = 1;
  return 0;
}

int main(int h) {
#if NHARTS != 4 || NUM_P != 2
  (void)h;
  return 0;
#else
  if (h == 0) return hart0();
  if (h == 1) return hart1();
  return 0;   // harts 2, 3: parked by hart 0
#endif
}
