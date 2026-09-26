// bench_stats.h — hardware-counter snapshot shared by support.c and the
// benchmark driver.
#ifndef BENCH_STATS_H
#define BENCH_STATS_H

#include <stdint.h>

typedef struct {
  uint32_t cycles, instret, stalls, branches, taken, mem;
  uint32_t mispredicts, md_busy, interlock;   // P-core only; zero on the E-core
} bench_stats_t;

extern bench_stats_t g_bench_begin, g_bench_end;

#endif  // BENCH_STATS_H
