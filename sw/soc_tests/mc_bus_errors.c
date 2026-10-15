// mc_bus_errors.c — the address map's edges, from software.
//
// Hart 0 installs its own trap handler and touches the first address past
// every slave's window, holes inside the peripherals' windows, a hart's
// interrupt block that does not exist, and unmapped space. Every one must
// trap with an access fault (load: cause 5, store: cause 7) and come back.
// Valid registers next to them must not trap. This is the interconnect's
// address decoder and the peripherals' register decode seen end to end; a
// decoder whose window is one byte too large turns a fault here into a
// silent access.
#include "soc.h"

static volatile uint32_t last_cause;
static volatile uint32_t traps;

// Records the cause and skips the faulting instruction (no compressed
// instructions on these cores, so every instruction is 4 bytes).
__attribute__((interrupt("machine"), aligned(4))) static void handler(void) {
  uint32_t cause, epc;
  __asm__ volatile("csrr %0, mcause" : "=r"(cause));
  __asm__ volatile("csrr %0, mepc" : "=r"(epc));
  last_cause = cause;
  traps = traps + 1;
  __asm__ volatile("csrw mepc, %0" ::"r"(epc + 4));
}

static int faults_load(uint32_t addr) {
  const uint32_t before = traps;
  (void)*(volatile uint32_t*)addr;
  return traps == before + 1 && last_cause == 5;
}

static int faults_store(uint32_t addr) {
  const uint32_t before = traps;
  *(volatile uint32_t*)addr = 0;
  return traps == before + 1 && last_cause == 7;
}

static int clean_load(uint32_t addr) {
  const uint32_t before = traps;
  (void)*(volatile uint32_t*)addr;
  return traps == before;
}

static const uint32_t kFault[] = {
    0x00030000u,                 // first byte past the SRAM
    0x10000100u,                 // past the UART's window
    0x10000008u,                 // a hole in the UART's window
    0x11010000u,                 // past the interrupt controller's window
    0x11000000u + 0x100u * NHARTS,   // a hart that does not exist
    0x11000010u,                 // a hole in hart 0's block
    0x12001000u,                 // past the system-control window
    0x12000FF0u,                 // a hole in the system-control window
    0x20000000u,                 // unmapped
    0xFFFFFFF0u,                 // the top of the address space
};

static const uint32_t kClean[] = {0x0002FFFCu, 0x10000004u, 0x11000000u,
                                  0x11000000u + 0x100u * (NHARTS - 1), 0x12000000u};

int main(int h) {
  int rc = 0;
  if (h == 0) {
    uint32_t old;
    __asm__ volatile("csrr %0, mtvec" : "=r"(old));
    __asm__ volatile("csrw mtvec, %0" ::"r"((uint32_t)handler));
    for (unsigned i = 0; i < sizeof(kFault) / sizeof(kFault[0]) && rc == 0; ++i) {
      if (!faults_load(kFault[i])) rc = 1 + 2 * (int)i;
      else if (!faults_store(kFault[i])) rc = 2 + 2 * (int)i;
    }
    for (unsigned i = 0; i < sizeof(kClean) / sizeof(kClean[0]) && rc == 0; ++i)
      if (!clean_load(kClean[i])) rc = 40 + (int)i;
    __asm__ volatile("csrw mtvec, %0" ::"r"(old));
  }
  mc_barrier(h);
  return rc;
}
