// ============================================================================
// uart.h — minimal polled UART driver for E-Core test programs.
// ============================================================================
#ifndef UART_H
#define UART_H

#include <stdint.h>

// Memory-mapped UART. Matches tb/integration/memory_model.h.
#define UART_BASE   0x10000000u
#define UART_DATA   (UART_BASE + 0x0u)   // write: transmit a byte
#define UART_STATUS (UART_BASE + 0x4u)   // read: bit 0 set => transmitter busy

void uart_putc(char c);
void uart_puts(const char *s);
void uart_put_hex(uint32_t v);       // eight hex digits, no prefix
void uart_put_dec(int32_t v);        // signed decimal

#endif  // UART_H
