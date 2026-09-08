// memcpy_test.c — byte-lane and alignment stress through the LSU.
//
// Every source/destination alignment combination is exercised, which is what
// makes this a load/store unit test rather than a library test: a byte enable
// or a lane-select error shows up as a specific offset failing while the rest
// pass.
#include <stddef.h>
#include <stdint.h>

#include "uart.h"

extern void *memcpy(void *dst, const void *src, size_t n);
extern void *memset(void *dst, int c, size_t n);
extern int memcmp(const void *a, const void *b, size_t n);

#define BUF 64

static uint8_t src[BUF + 8];
static uint8_t dst[BUF + 8];

int main(void) {
  // Distinct, non-repeating contents so a lane swap cannot go unnoticed.
  for (int i = 0; i < BUF + 8; ++i) {
    src[i] = (uint8_t)(i * 7 + 3);
  }

  for (int soff = 0; soff < 4; ++soff) {
    for (int doff = 0; doff < 4; ++doff) {
      for (int len = 0; len <= 33; ++len) {
        memset(dst, 0xA5, sizeof(dst));
        memcpy(dst + doff, src + soff, (size_t)len);

        if (memcmp(dst + doff, src + soff, (size_t)len) != 0) {
          uart_puts("memcpy: content mismatch at soff=");
          uart_put_dec(soff);
          uart_puts(" doff=");
          uart_put_dec(doff);
          uart_puts(" len=");
          uart_put_dec(len);
          uart_putc('\n');
          return 1;
        }
        // The bytes just outside the copied range must be untouched, which is
        // what catches a byte enable that is too wide.
        if (doff > 0 && dst[doff - 1] != 0xA5) {
          uart_puts("memcpy: underrun\n");
          return 2;
        }
        if (dst[doff + len] != 0xA5) {
          uart_puts("memcpy: overrun\n");
          return 3;
        }
      }
    }
  }

  uart_puts("memcpy_test: 4x4x34 alignment/length combinations OK\n");
  return 0;
}
