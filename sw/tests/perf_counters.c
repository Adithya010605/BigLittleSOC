// perf_counters.c — measures a representative workload with the core's own
// performance counters and prints the result.
//
// These numbers are the Phase 2 baseline for the P-core comparison, so the
// measurement window deliberately excludes startup: two samples are taken and
// subtracted, and every figure comes from the hardware counters rather than
// from the testbench.
#include "perf.h"
#include "uart.h"

#define N 24

static int data[N];

static void fill(int *a, int n) {
  // A fixed pseudo-random sequence, so the measurement is repeatable.
  uint32_t s = 12345u;
  for (int i = 0; i < n; ++i) {
    s = s * 1103515245u + 12345u;
    a[i] = (int)(s >> 16) % 200 - 100;
  }
}

static void bubble_sort(int *a, int n) {
  for (int i = 0; i < n - 1; ++i) {
    for (int j = 0; j < n - 1 - i; ++j) {
      if (a[j] > a[j + 1]) {
        const int t = a[j];
        a[j] = a[j + 1];
        a[j + 1] = t;
      }
    }
  }
}

static void print_pair(const char *name, uint32_t v) {
  uart_puts(name);
  uart_put_dec((int)v);
  uart_putc('\n');
}

// Prints x/y to two decimal places without any floating point, since this
// core has no FPU and libgcc's soft-float would dominate the measurement.
static void print_ratio(const char *name, uint32_t num, uint32_t den) {
  uart_puts(name);
  if (den == 0) {
    uart_puts("n/a\n");
    return;
  }
  const uint32_t scaled = (num * 100u) / den;
  uart_put_dec((int)(scaled / 100u));
  uart_putc('.');
  const uint32_t frac = scaled % 100u;
  if (frac < 10) uart_putc('0');
  uart_put_dec((int)frac);
  uart_putc('\n');
}

int main(void) {
  perf_t before, after, d;

  fill(data, N);

  perf_read(&before);
  bubble_sort(data, N);
  perf_read(&after);
  perf_delta(&before, &after, &d);

  for (int i = 0; i < N - 1; ++i) {
    if (data[i] > data[i + 1]) {
      uart_puts("perf_counters: workload did not sort correctly\n");
      return 1;
    }
  }

  uart_puts("perf_counters: bubble sort, N=24\n");
  print_pair("  cycles          = ", d.cycles);
  print_pair("  instret         = ", d.instret);
  print_pair("  stall cycles    = ", d.stalls);
  print_pair("  branches        = ", d.branches);
  print_pair("  branches taken  = ", d.branches_taken);
  print_pair("  loads+stores    = ", d.mem_ops);
  print_ratio("  CPI             = ", d.cycles, d.instret);
  print_ratio("  stalls/instr    = ", d.stalls, d.instret);
  print_ratio("  branch rate %   = ", d.branches * 100u, d.instret);
  print_ratio("  taken rate %    = ", d.branches_taken * 100u, d.branches);
  print_ratio("  memory rate %   = ", d.mem_ops * 100u, d.instret);

  // Invariants that must hold whatever the workload, so this stays a test and
  // not merely a report.
  if (d.instret == 0) return 2;
  if (d.cycles < d.instret) return 3;          // CPI cannot be below 1
  if (d.branches_taken > d.branches) return 4;  // taken is a subset
  if (d.stalls > d.cycles) return 5;
  return 0;
}
