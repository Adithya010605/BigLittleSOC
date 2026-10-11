// mc_sleep.c — sleep, wake-on-interrupt and clock gating.
//
//   hart 1  enables its software interrupt, goes to sleep, and is woken by
//           hart 0 raising that interrupt: it takes the interrupt (the
//           handler runs on the woken core) and carries on. Its own mcycle
//           barely moves while it sleeps -- its clock is stopped -- although
//           thousands of system cycles pass.
//   hart 2  sleeps with interrupts off and is woken by a write to PWR_WAKE.
//   hart 3  arms its own timer, sleeps with mie.MTIE set but mstatus.MIE
//           clear: the timer wakes it, and it continues without trapping.
//
// Hart 0 watches each sleeper through the PMU: CORE_STATE shows it asleep,
// halted and clock-gated, its GATED counter grows while its RUN counter
// stands still, and after the wake it is running again.
//
// Needs 2 P-cores + 2 E-cores; on any other configuration it passes
// trivially.
#include "pmu.h"
#include "soc.h"

#define IRQ_BASE 0x11000000u
#define IRQ_REG(h, off) (*(volatile uint32_t*)(uintptr_t)(IRQ_BASE + 0x100u * (h) + (off)))

static volatile uint32_t asleep[NHARTS], awake[NHARTS], irq_taken[NHARTS];
static volatile uint32_t slept_cycles[NHARTS];

static inline uint32_t mcycle(void) {
  uint32_t v;
  __asm__ volatile("csrr %0, mcycle" : "=r"(v));
  return v;
}

__attribute__((interrupt("machine"), aligned(4))) static void handler(void) {
  const uint32_t h = pmu_hartid();
  IRQ_REG(h, 0x8) = 0;   // drop the software interrupt
  irq_taken[h]++;
}

// Asleep, halted, clock stopped; and the gated counter moves while the run
// counter does not.
static int check_asleep(int c) {
  pmu_wait_core(c, CS_ACTIVE | CS_SLEEP | CS_HALTED | CS_CLK_EN, CS_ACTIVE | CS_SLEEP | CS_HALTED);
  const uint32_t run0 = PWR_RUN(c), gated0 = PWR_GATED(c);
  for (volatile int i = 0; i < 300; ++i) {
  }
  if ((PWR_CORE_STATE(c) & CS_SLEEP) == 0) return 1;
  if (PWR_RUN(c) != run0) return 2;
  if (PWR_GATED(c) - gated0 < 600) return 3;
  return 0;
}

static int hart0(void) {
  int r;
  // hart 1: woken by its software interrupt
  while (!asleep[1]) {
  }
  if ((r = check_asleep(1)) != 0) return 0x10 + r;
  IRQ_REG(1, 0x8) = 1;
  while (!awake[1]) {
  }
  if (irq_taken[1] != 1) return 0x20;
  if ((PWR_CORE_STATE(1) & (CS_ACTIVE | CS_SLEEP)) != CS_ACTIVE) return 0x21;

  // hart 2: woken by PWR_WAKE
  while (!asleep[2]) {
  }
  if ((r = check_asleep(2)) != 0) return 0x30 + r;
  PWR_WAKE = 1u << 2;
  while (!awake[2]) {
  }
  if (irq_taken[2] != 0) return 0x40;

  // hart 3 wakes itself with its timer
  while (!awake[3]) {
  }
  if (irq_taken[3] != 0) return 0x50;
  return 0;
}

static int hart1(void) {
  __asm__ volatile("csrw mtvec, %0" ::"r"(handler));
  __asm__ volatile("csrs mie, %0" ::"r"(1u << 3));       // MSIE
  __asm__ volatile("csrs mstatus, %0" ::"r"(1u << 3));   // MIE
  const uint32_t c0 = mcycle();
  asleep[1] = 1;
  PWR_SLEEP = 1u << 1;
  while (irq_taken[1] == 0) {
  }
  const uint32_t c1 = mcycle();
  __asm__ volatile("csrc mstatus, %0" ::"r"(1u << 3));
  slept_cycles[1] = c1 - c0;
  // hart 0 spent hundreds of system cycles watching this core asleep
  if (c1 - c0 > 400) return 1;
  awake[1] = 1;
  return 0;
}

static int hart2(void) {
  asleep[2] = 1;
  PWR_SLEEP = 1u << 2;
  // Execution may run on for a few instructions before the halt: wait for
  // the PMU to report the wake rather than assuming where it stopped.
  while (PWR_CORE_STATE(2) & CS_SLEEP) {
  }
  awake[2] = 1;
  return 0;
}

static int hart3(void) {
  __asm__ volatile("csrs mie, %0" ::"r"(1u << 7));   // MTIE, but MIE stays clear
  IRQ_REG(3, 0x0) = 3000;                             // timer fires in 3000 cycles
  asleep[3] = 1;
  PWR_SLEEP = 1u << 3;
  while (PWR_CORE_STATE(3) & CS_SLEEP) {
  }
  uint32_t mip;
  __asm__ volatile("csrr %0, mip" : "=r"(mip));
  if (!(mip & (1u << 7))) return 1;                   // woke because the timer is pending
  IRQ_REG(3, 0x4) = 0;                                // clear it
  awake[3] = 1;
  return 0;
}

int main(int h) {
#if NHARTS != 4 || NUM_P != 2
  (void)h;
  return 0;
#else
  switch (h) {
    case 0: return hart0();
    case 1: return hart1();
    case 2: return hart2();
    default: return hart3();
  }
#endif
}
