/* ============================================================================
 * start.S — reset entry for E-Core bare-metal test programs.
 *
 * Runs at the reset vector 0x0000_0000 and establishes everything C code
 * assumes: a stack, a global pointer, a zeroed .bss and a trap vector. It then
 * calls main() and turns the return value into a simulation exit through the
 * `tohost` mailbox.
 *
 * tohost protocol (the riscv-tests convention, which the testbench follows):
 *   bit 0 set  => the program has finished
 *   bits 31:1  => exit code, so a stored value of 1 means "passed"
 * A non-zero exit code n is therefore written as (n << 1) | 1.
 *
 * NOTE ON COMMENT STYLE: .S files are run through the C preprocessor, so a
 * line whose first non-blank character is '#' followed by a directive name is
 * taken as a preprocessor directive, not a comment. C-style comments are used
 * throughout to make that class of mistake impossible.
 * ============================================================================
 */

    .section .text.init, "ax"
    .globl _start
    .type  _start, @function

_start:
    /* Establish gp before anything uses gp-relative addressing.
       .option norelax stops the assembler relaxing this very sequence into a
       gp-relative form, which would depend on gp already being set. */
.option push
.option norelax
    la      gp, __global_pointer$
.option pop

    la      sp, _stack_top

    /* Point mtvec at the default handler. Direct mode, so the low two bits
       must be zero. A program wanting its own handler overwrites mtvec. */
    la      t0, default_trap_handler
    csrw    mtvec, t0

    /* Clear .bss. */
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    /* Zero the integer register file, leaving the machine in a defined
       architectural state before main(). A program that reads an
       uninitialised register then behaves identically in the RTL and in the
       golden ISS instead of diverging on reset noise. gp and sp are set
       above and must not be clobbered. */
    li      x1,  0
    li      x4,  0
    li      x5,  0
    li      x6,  0
    li      x7,  0
    li      x8,  0
    li      x9,  0
    li      x10, 0
    li      x11, 0
    li      x12, 0
    li      x13, 0
    li      x14, 0
    li      x15, 0
    li      x16, 0
    li      x17, 0
    li      x18, 0
    li      x19, 0
    li      x20, 0
    li      x21, 0
    li      x22, 0
    li      x23, 0
    li      x24, 0
    li      x25, 0
    li      x26, 0
    li      x27, 0
    li      x28, 0
    li      x29, 0
    li      x30, 0
    li      x31, 0

    /* Run the program. */
    li      a0, 0                   /* argc */
    li      a1, 0                   /* argv */
    call    main

    /* main() returning 0 means success, which tohost encodes as 1. */
    slli    a0, a0, 1
    ori     a0, a0, 1
    j       _exit_with_a0

    .globl _exit_with_a0
    .type  _exit_with_a0, @function
_exit_with_a0:
    la      t0, tohost
    sw      a0, 0(t0)
    sw      zero, 4(t0)
    /* The testbench stops the simulation on that store; the loop below only
       matters if this image is ever run on real hardware. */
1:  wfi
    j       1b

/* ---------------------------------------------------------------------------
 * default_trap_handler
 *
 * Programs that do not install their own handler land here. There is no sane
 * way to continue from an unexpected trap in a test program, so it reports a
 * distinctive failure code (0x7E) rather than looping silently, leaving mcause
 * in a1 for the log.
 * ---------------------------------------------------------------------------
 */
    .globl default_trap_handler
    .type  default_trap_handler, @function
    .align 4
default_trap_handler:
    csrr    a1, mcause
    li      a0, (0x7E << 1) | 1
    j       _exit_with_a0
