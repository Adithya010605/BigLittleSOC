/* ============================================================================
 * test_macros.h — self-checking harness for the directed assembly tests.
 *
 * Each test in tb/asm/ is a standalone program: it provides its own _start,
 * links against sw/common/linker.ld, and reports its verdict by storing to the
 * `tohost` mailbox that the linker script provides.
 *
 * Result encoding (the riscv-tests convention, shared with sw/common/start.S):
 *   store 1            -> passed
 *   store (n << 1) | 1 -> failed check number n
 * Every check carries a unique number, so a failure names the exact assertion
 * rather than only the test.
 *
 * ---------------------------------------------------------------------------
 * RESERVED REGISTERS
 * ---------------------------------------------------------------------------
 * The comparison macros need a scratch register to materialise the expected
 * immediate in. x31 (t6) is reserved for that purpose and MUST NOT hold a live
 * value across a check, nor be the register under test.
 *
 * That rule is enforced, not merely documented: passing x31 (or t6) as the
 * register under test would make the check compare the scratch against itself
 * and pass unconditionally, so the macros reject it with .error at assembly
 * time. A silently vacuous check is far worse than a build failure -- this
 * exact mistake, with t0, is what let an early version of m2_basic.S report
 * success for two checks that were never actually performed.
 *
 * TEST_PASS and TEST_FAIL additionally clobber x30, but both terminate the
 * program, so nothing can observe it.
 *
 * As with sw/common/start.S, comments are C-style: .S files run through the C
 * preprocessor, where a line beginning '#' followed by a directive name would
 * be taken as a preprocessor directive rather than a comment.
 * ============================================================================
 */
#ifndef TEST_MACROS_H
#define TEST_MACROS_H

/* Rejects the reserved scratch register being used as the register under
   test, which would turn the check into a tautology. */
.macro _CHECK_NOT_SCRATCH reg
  .ifc "\reg","x31"
    .error "test_macros.h: x31 is the macro scratch register and cannot be checked"
  .endif
  .ifc "\reg","t6"
    .error "test_macros.h: t6 (x31) is the macro scratch register and cannot be checked"
  .endif
.endm

/* Begin a test: place _start at the reset vector and set up a stack. */
.macro TEST_START
    .section .text.init, "ax"
    .globl _start
_start:
    la      sp, _stack_top
.endm

/* Report success and stop. */
.macro TEST_PASS
    li      x31, 1
    la      x30, tohost
    sw      x31, 0(x30)
9001:  j    9001b
.endm

/* Report failure of check \code and stop. */
.macro TEST_FAIL code
    li      x31, ((\code) << 1) | 1
    la      x30, tohost
    sw      x31, 0(x30)
9002:  j    9002b
.endm

/* Fail unless \reg holds the immediate \val. */
.macro CHECK_EQ reg, val, code
    _CHECK_NOT_SCRATCH \reg
    li      x31, \val
    beq     \reg, x31, 8001f
    TEST_FAIL \code
8001:
.endm

/* Fail unless \rega equals \regb. Neither may be the scratch register. */
.macro CHECK_EQ_REG rega, regb, code
    _CHECK_NOT_SCRATCH \rega
    _CHECK_NOT_SCRATCH \regb
    beq     \rega, \regb, 8002f
    TEST_FAIL \code
8002:
.endm

/* Fail unless \reg differs from the immediate \val. */
.macro CHECK_NE reg, val, code
    _CHECK_NOT_SCRATCH \reg
    li      x31, \val
    bne     \reg, x31, 8003f
    TEST_FAIL \code
8003:
.endm

/* Fail unconditionally if control reaches here. */
.macro CHECK_UNREACHABLE code
    TEST_FAIL \code
.endm

/* A word-aligned scratch area in RAM for load/store tests. */
.macro TEST_DATA_SECTION
    .section .data
    .align 4
.endm

#endif /* TEST_MACROS_H */
