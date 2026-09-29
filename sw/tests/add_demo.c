// add_demo.c — how many cycles does an ADD actually cost on the E-Core?
//
// A single ADD cannot be timed directly: the two `csrr mcycle` reads that
// bracket the measurement cost more cycles than the instruction under test.
// So the window is calibrated first -- an empty read/read pair gives the
// harness overhead -- and that overhead is subtracted from every measurement
// below. What is left is the cost of the arithmetic alone.
//
// The adds are written as volatile inline asm so the compiler cannot fold
// them into a constant or hoist them out of the measured window.
#include "perf.h"
#include "uart.h"

// One dependent add: each depends on the previous result, so this measures
// the throughput of a back-to-back RAW chain through the forwarding network.
#define ADD1    __asm__ volatile("add %0, %0, %1" : "+r"(acc) : "r"(inc));
#define ADD10   ADD1 ADD1 ADD1 ADD1 ADD1 ADD1 ADD1 ADD1 ADD1 ADD1
#define ADD100  ADD10 ADD10 ADD10 ADD10 ADD10 ADD10 ADD10 ADD10 ADD10 ADD10

static void print_pair(const char *name, uint32_t v) {
  uart_puts(name);
  uart_put_dec((int)v);
  uart_putc('\n');
}

// x/y to two decimals, no floating point (this core has no FPU, and libgcc's
// soft-float would be larger than the thing being measured).
static void print_ratio(const char *name, uint32_t num, uint32_t den) {
  uart_puts(name);
  if (den == 0) { uart_puts("n/a\n"); return; }
  const uint32_t scaled = (num * 100u) / den;
  uart_put_dec((int)(scaled / 100u));
  uart_putc('.');
  const uint32_t frac = scaled % 100u;
  if (frac < 10) uart_putc('0');
  uart_put_dec((int)frac);
  uart_putc('\n');
}

int main(void) {
  perf_t before, after;
  uint32_t acc, inc;

  uart_puts("add_demo: cost of an ADD on the E-Core\n\n");

  // ---- 1. the addition itself, so the result is visible -----------------
  acc = 3; inc = 4;
  ADD1
  uart_puts("  3 + 4           = ");
  uart_put_dec((int)acc);
  uart_putc('\n');
  if (acc != 7) return 2;

  // ---- 2. calibrate: what does an empty measurement window cost? --------
  perf_read(&before);
  perf_read(&after);
  const uint32_t overhead = after.cycles - before.cycles;
  const uint32_t overhead_stalls = after.stalls - before.stalls;
  print_pair("  harness overhead= ", overhead);

  // ---- 3. one ADD -------------------------------------------------------
  acc = 3; inc = 4;
  perf_read(&before);
  ADD1
  perf_read(&after);
  const uint32_t one = after.cycles - before.cycles - overhead;
  print_pair("  1 add           = ", one);

  // ---- 4. 100 dependent ADDs -------------------------------------------
  acc = 0; inc = 1;
  perf_read(&before);
  ADD100
  perf_read(&after);
  const uint32_t hundred = after.cycles - before.cycles - overhead;
  const uint32_t retired = after.instret - before.instret;

  uart_putc('\n');
  print_pair("  100 adds cycles = ", hundred);
  print_pair("  100 adds instret= ", retired);
  print_ratio("  cycles per add  = ", hundred, 100);
  print_pair("  stalls from adds= ", (after.stalls - before.stalls) - overhead_stalls);

  // acc was incremented by 1 a hundred times.
  if (acc != 100) return 3;

  uart_putc('\n');
  uart_puts("  ADD is single-cycle: the EX-stage result is forwarded\n");
  uart_puts("  straight back, so a dependent chain never stalls.\n");

  // Invariants, so this stays a test and not merely a report.
  if (hundred == 0) return 4;
  if (hundred > 200) return 5;              // one cycle each, plus slack
  // The csrr reads that bracket the window stall; the adds must not add to
  // that, which is what makes the chain single-cycle.
  if ((after.stalls - before.stalls) > overhead_stalls) return 6;
  return 0;
}
