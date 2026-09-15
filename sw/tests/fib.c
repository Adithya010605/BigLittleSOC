// fib.c — iterative and recursive Fibonacci.
//
// The recursive version is the interesting one: it exercises the call/return
// path, stack traffic and the load-use interlock far more heavily than any
// hand-written assembly test does.
#include "uart.h"

static unsigned fib_iter(unsigned n) {
  unsigned a = 0, b = 1;
  for (unsigned i = 0; i < n; ++i) {
    const unsigned t = a + b;
    a = b;
    b = t;
  }
  return a;
}

static unsigned fib_rec(unsigned n) {
  if (n < 2) return n;
  return fib_rec(n - 1) + fib_rec(n - 2);
}

int main(void) {
  uart_puts("fib iterative: ");
  for (unsigned i = 0; i <= 15; ++i) {
    uart_put_dec((int)fib_iter(i));
    uart_putc(i == 15 ? '\n' : ' ');
  }

  uart_puts("fib recursive: ");
  for (unsigned i = 0; i <= 15; ++i) {
    uart_put_dec((int)fib_rec(i));
    uart_putc(i == 15 ? '\n' : ' ');
  }

  // The two must agree, which is the actual check: the printed output is for
  // a human, the return code is for the regression.
  for (unsigned i = 0; i <= 20; ++i) {
    if (fib_iter(i) != fib_rec(i)) return 1;
  }
  uart_puts("fib: iterative and recursive agree up to n=20\n");
  return 0;
}
