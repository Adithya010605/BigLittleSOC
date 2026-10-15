// mc_hello.c — every hart reports in, in hart order.
//
// A turn variable passes from hart to hart: hart h waits until turn == h,
// prints, and hands the turn on. Each hand-off moves the line holding `turn`
// from one L1 to the next, through P-core (write-back) and E-core
// (write-through) caches alike, so the output appearing in order at all is
// the first evidence that the caches agree on what `turn` holds.
#include "soc.h"
#include "uart.h"

static volatile uint32_t turn;

int main(int h) {
  while (turn != (uint32_t)h) {
  }
  uart_puts("hart ");
  uart_put_dec(h);
  uart_puts(mc_is_pcore(h) ? ": P-core (RV32IM, 5-stage, write-back L1)\n"
                           : ": E-core (RV32I, 3-stage, write-through L1)\n");
  turn = (uint32_t)h + 1;
  if (h == 0) {
    while (turn != NHARTS) {
    }
    uart_puts("all harts up\n");
  }
  return 0;
}
