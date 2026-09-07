// hello.c — boot test: does the core come up, run C, and reach the UART?
#include "uart.h"

int main(void) {
  uart_puts("Hello from the E-Core!\n");
  uart_puts("RV32I_Zicsr, 3-stage, machine mode.\n");
  return 0;
}
