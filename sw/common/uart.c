// ============================================================================
// uart.c — polled UART output.
//
// The transmitter is byte-at-a-time and the status register's bit 0 reports
// "busy". Polling it (rather than writing blind) is what exercises the load
// path against a memory-mapped peripheral, and it is the behaviour a real
// UART would need, so the test programs are not silently relying on an
// infinitely fast device.
// ============================================================================
#include "uart.h"

static inline void mmio_write32(uint32_t addr, uint32_t val) {
  *(volatile uint32_t *)addr = val;
}

static inline uint32_t mmio_read32(uint32_t addr) {
  return *(volatile uint32_t *)addr;
}

void uart_putc(char c) {
  while (mmio_read32(UART_STATUS) & 1u) {
    // transmitter busy
  }
  mmio_write32(UART_DATA, (uint32_t)(unsigned char)c);
}

void uart_puts(const char *s) {
  while (*s) {
    uart_putc(*s++);
  }
}

void uart_put_hex(uint32_t v) {
  static const char kDigits[] = "0123456789abcdef";
  for (int shift = 28; shift >= 0; shift -= 4) {
    uart_putc(kDigits[(v >> shift) & 0xFu]);
  }
}

void uart_put_dec(int32_t v) {
  char buf[12];
  int n = 0;

  if (v == 0) {
    uart_putc('0');
    return;
  }
  // Negate into a uint32_t so INT32_MIN does not overflow.
  uint32_t mag;
  if (v < 0) {
    uart_putc('-');
    mag = (uint32_t)0 - (uint32_t)v;
  } else {
    mag = (uint32_t)v;
  }
  while (mag != 0u) {
    buf[n++] = (char)('0' + (mag % 10u));
    mag /= 10u;
  }
  while (n-- > 0) {
    uart_putc(buf[n]);
  }
}
