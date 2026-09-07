/* ===========================================================================
 * riscv_tests.ld — link script for the upstream riscv-tests compliance suite.
 *
 * The upstream env/p/link.ld places the image at 0x8000_0000, which is where a
 * Spike-like machine keeps its RAM. This core's memory map puts its unified
 * ROM/SRAM at 0x0000_0000 (see tb/integration/memory_model.h), so the tests
 * are re-linked here at the reset vector instead. Nothing else differs: the
 * section order, the .tohost section and the ENTRY symbol are the same, so the
 * upstream env/p/riscv_test.h macros work unchanged.
 *
 * The 4 KiB alignment between sections is inherited from upstream. It is not
 * required by anything here, but keeping it means the only difference from the
 * original script is the base address.
 * ===========================================================================
 */

OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  . = 0x00000000;
  .text.init : { *(.text.init) }

  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }

  . = ALIGN(0x1000);
  .text : { *(.text) *(.text.*) }

  . = ALIGN(0x1000);
  .data : { *(.data) *(.data.*) *(.rodata) *(.rodata.*) *(.sdata) *(.sdata.*) }
  .bss  : { *(.bss) *(.bss.*) *(.sbss) *(.sbss.*) *(COMMON) }

  _end = .;

  /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame) *(.riscv.attributes) }
}
