// ============================================================================
// perf.h — reading the E-Core's performance counters from C.
//
// The counter set and its semantics are fixed by rtl/common/csr_unit.sv:
//   mcycle          every cycle since reset, unless inhibited
//   minstret        retired instructions; never a flushed or bubbled one
//   mhpmcounter3    cycles in which S2 held a valid instruction back
//   mhpmcounter4    retired conditional branches (jumps are not counted)
//   mhpmcounter5    retired conditional branches whose condition was true
//   mhpmcounter6    retired loads and stores
// ============================================================================
#ifndef PERF_H
#define PERF_H

#include <stdint.h>

#define CSR_READ(name)                                     \
  ({                                                       \
    uint32_t _v;                                           \
    __asm__ volatile("csrr %0, " #name : "=r"(_v));        \
    _v;                                                    \
  })

typedef struct {
  uint32_t cycles;
  uint32_t instret;
  uint32_t stalls;
  uint32_t branches;
  uint32_t branches_taken;
  uint32_t mem_ops;
} perf_t;

static inline void perf_read(perf_t *p) {
  p->cycles = CSR_READ(mcycle);
  p->instret = CSR_READ(minstret);
  p->stalls = CSR_READ(mhpmcounter3);
  p->branches = CSR_READ(mhpmcounter4);
  p->branches_taken = CSR_READ(mhpmcounter5);
  p->mem_ops = CSR_READ(mhpmcounter6);
}

// Difference between two samples, so the measured window excludes startup.
static inline void perf_delta(const perf_t *a, const perf_t *b, perf_t *d) {
  d->cycles = b->cycles - a->cycles;
  d->instret = b->instret - a->instret;
  d->stalls = b->stalls - a->stalls;
  d->branches = b->branches - a->branches;
  d->branches_taken = b->branches_taken - a->branches_taken;
  d->mem_ops = b->mem_ops - a->mem_ops;
}

#endif  // PERF_H
