/* ===========================================================================
 * linker.ld — bare-metal layout for E-Core test programs.
 *
 * Memory map (matches tb/integration/memory_model.h and the project plan):
 *
 *   0x0000_0000 .. 0x0000_FFFF   code + read-only data   (64 KiB)
 *   0x0001_0000 .. 0x0002_FFFF   data, bss, heap, stack  (128 KiB)
 *   0x0002_FFF0                  initial stack pointer (16-byte aligned)
 *   0x1000_0000                  UART, outside all loadable sections
 *
 * The reset vector is 0x0000_0000, so _start must be the first thing in
 * .text. That is enforced by giving it its own input section, .text.init,
 * which start.S places it in.
 * ===========================================================================
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
  RAM (rwx) : ORIGIN = 0x00010000, LENGTH = 128K
}

_stack_top = ORIGIN(RAM) + LENGTH(RAM) - 16;   /* 0x0002_FFF0 */

SECTIONS
{
  .text ORIGIN(ROM) :
  {
    KEEP(*(.text.init))        /* _start, must be at the reset vector */
    *(.text .text.*)
    . = ALIGN(4);
  } > ROM

  .rodata :
  {
    *(.rodata .rodata.*)
    *(.srodata .srodata.*)
    . = ALIGN(4);
  } > ROM

  /* The exit mailbox. Kept in its own section so the testbench can find it
     by symbol and so it is never confused with ordinary program data. */
  .tohost ORIGIN(RAM) :
  {
    . = ALIGN(8);
    PROVIDE(tohost = .);
    . += 8;
    PROVIDE(fromhost = .);
    . += 8;
    . = ALIGN(8);
  } > RAM

  .data :
  {
    __data_start = .;
    *(.data .data.*)
    /* gp-relative small data. __global_pointer$ sits 0x800 into the small
       data area so the +-2 KiB gp-relative range covers all of .sdata/.sbss. */
    . = ALIGN(8);
    PROVIDE(__global_pointer$ = . + 0x800);
    *(.sdata .sdata.*)
    . = ALIGN(4);
    __data_end = .;
  } > RAM

  .bss (NOLOAD) :
  {
    . = ALIGN(4);
    __bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM

  _end = .;
  PROVIDE(__heap_start = _end);

  /* Nothing below here is loaded into the simulated memory. */
  /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame) *(.riscv.attributes) }
}
