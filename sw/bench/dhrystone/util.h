// ============================================================================
// util.h — stand-in for riscv-tests' benchmarks/common/util.h.
//
// The upstream Dhrystone sources (third_party/riscv-tests/benchmarks/
// dhrystone) are compiled unmodified; this header is found first on the
// include path and supplies the two things they take from util.h:
//   read_csr(name)   used by dhrystone.h's Start_Timer / Stop_Timer
//   setStats(on)     brackets the timed region
// setStats is implemented in support.c, where it snapshots the hardware
// counters so the measurement comes from the core itself.
// ============================================================================
#ifndef BENCH_UTIL_H
#define BENCH_UTIL_H

#include <stdint.h>

#define read_csr(reg)                                   \
  ({                                                    \
    unsigned long _v;                                   \
    __asm__ volatile("csrr %0, " #reg : "=r"(_v));      \
    _v;                                                 \
  })

void setStats(int enable);

#endif  // BENCH_UTIL_H
