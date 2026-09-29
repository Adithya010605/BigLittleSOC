// ============================================================================
// bench_dhrystone.c — runs Dhrystone 2.1 and turns it into a test.
//
// The upstream main() is compiled as dhrystone_main() (-Dmain=dhrystone_main
// on that file only) and called from here. Upstream only PRINTS the values its
// variables should end with; this driver CHECKS them, so a core that
// miscomputes Dhrystone fails rather than reporting a plausible speed.
//
// Output, over the UART:
//   the timed region's cycle and instruction counts and the derived CPI and
//   DMIPS/MHz, plus every event counter, all measured by the core's own CSRs.
//
// DMIPS/MHz = runs per second at 1 MHz / 1757
//           = runs * 1e6 / cycles / 1757
// computed here in fixed point (x1000) since neither core has an FPU.
// ============================================================================
#include <stdint.h>

#include "bench_stats.h"
#include "uart.h"

// dhrystone.h's NUMBER_OF_RUNS, restated for the checks and the arithmetic.
#define RUNS 500

int dhrystone_main(int argc, char **argv);

// Globals defined by the upstream sources. Their types there are the
// benchmark's own typedefs; these declarations match their sizes.
extern int Int_Glob;
extern int Bool_Glob;
extern char Ch_1_Glob, Ch_2_Glob;
extern int Arr_1_Glob[50];
extern int Arr_2_Glob[50][50];

static void put_kv(const char *k, uint32_t v) {
  uart_puts(k);
  uart_put_dec((int32_t)v);
  uart_putc('\n');
}

// v / 1000 with three decimals.
static void put_milli(const char *k, uint32_t v) {
  uart_puts(k);
  uart_put_dec((int32_t)(v / 1000u));
  uart_putc('.');
  const uint32_t f = v % 1000u;
  if (f < 100u) uart_putc('0');
  if (f < 10u) uart_putc('0');
  uart_put_dec((int32_t)f);
  uart_putc('\n');
}

int main(void) {
  dhrystone_main(0, 0);

  // Dhrystone's own "should be" values (dhrystone_main.c).
  if (Int_Glob != 5) return 10;
  if (Bool_Glob != 1) return 11;
  if (Ch_1_Glob != 'A') return 12;
  if (Ch_2_Glob != 'B') return 13;
  if (Arr_1_Glob[8] != 7) return 14;
  if (Arr_2_Glob[8][7] != RUNS + 10) return 15;

  const uint32_t cyc = g_bench_end.cycles - g_bench_begin.cycles;
  const uint32_t ins = g_bench_end.instret - g_bench_begin.instret;
  if (cyc == 0 || ins == 0) return 16;

  uart_puts("dhrystone: ");
  uart_put_dec(RUNS);
  uart_puts(" runs, final values verified\n");
  put_kv("cycles=", cyc);
  put_kv("instret=", ins);
  put_kv("stalls=", g_bench_end.stalls - g_bench_begin.stalls);
  put_kv("branches=", g_bench_end.branches - g_bench_begin.branches);
  put_kv("taken=", g_bench_end.taken - g_bench_begin.taken);
  put_kv("mem=", g_bench_end.mem - g_bench_begin.mem);
  put_kv("mispredicts=", g_bench_end.mispredicts - g_bench_begin.mispredicts);
  put_kv("md_busy=", g_bench_end.md_busy - g_bench_begin.md_busy);
  put_kv("interlock=", g_bench_end.interlock - g_bench_begin.interlock);
  put_milli("CPI=", (uint32_t)(((uint64_t)cyc * 1000u) / ins));
  put_milli("cycles_per_run=", (uint32_t)(((uint64_t)cyc * 1000u) / RUNS));
  // runs * 1e6 / cycles / 1757, times 1000.
  put_milli("DMIPS_per_MHz=",
            (uint32_t)(((uint64_t)RUNS * 1000000u * 1000u) / ((uint64_t)cyc * 1757u)));
  return 0;
}
