// ============================================================================
// support.c — the runtime the upstream Dhrystone sources expect.
//
//   printf                  Dhrystone's report. Discarded: its own timing
//                           lines assume HZ-based wall-clock time, and the
//                           values it prints are checked directly by
//                           bench_dhrystone.c instead. (debug_printf, which
//                           prints the rest, is defined upstream in
//                           dhrystone.c as an empty function.)
//   strcpy / strcmp         used inside the benchmark loop, so they are part
//                           of what is measured; written plainly, a byte at a
//                           time, as a freestanding libc would.
//   setStats                snapshots mcycle, minstret and the event counters
//                           at the start and end of the timed region.
// ============================================================================
#include <stddef.h>
#include <stdint.h>

#include "bench_stats.h"
#include "util.h"

bench_stats_t g_bench_begin, g_bench_end;

static void snapshot(bench_stats_t *s) {
  s->cycles = read_csr(mcycle);
  s->instret = read_csr(minstret);
  s->stalls = read_csr(mhpmcounter3);
  s->branches = read_csr(mhpmcounter4);
  s->taken = read_csr(mhpmcounter5);
  s->mem = read_csr(mhpmcounter6);
#ifdef BENCH_P_CORE
  s->mispredicts = read_csr(mhpmcounter7);
  s->md_busy = read_csr(mhpmcounter8);
  s->interlock = read_csr(mhpmcounter9);
#else
  s->mispredicts = 0;
  s->md_busy = 0;
  s->interlock = 0;
#endif
}

void setStats(int enable) { snapshot(enable ? &g_bench_begin : &g_bench_end); }

int printf(const char *fmt, ...) {
  (void)fmt;
  return 0;
}

char *strcpy(char *d, const char *s) {
  char *r = d;
  while ((*d++ = *s++) != '\0') {
  }
  return r;
}

int strcmp(const char *a, const char *b) {
  while (*a != '\0' && *a == *b) {
    ++a;
    ++b;
  }
  return (int)(unsigned char)*a - (int)(unsigned char)*b;
}
