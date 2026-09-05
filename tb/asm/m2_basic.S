/* ============================================================================
 * m2_basic.S — milestone M2 exit test.
 *
 * Exercises the instruction set named in the M2 exit criteria — addi, add,
 * sub, and, or, lw, sw, beq, jal — on the single-cycle datapath, checking
 * architectural results rather than merely running to completion.
 *
 * Deliberately avoids anything the M2 core cannot execute (Zicsr, ECALL,
 * EBREAK, MRET, WFI, illegal encodings, misaligned accesses); those are
 * covered by the M5 tests once trap entry exists.
 *
 * Check numbering is unique per check so a failure names the exact assertion.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START

    /* ---- 1..4: addi, including sign extension and the immediate extremes -*/
    li      x1, 0
    addi    x2, x1, 100
    CHECK_EQ x2, 100, 1

    addi    x3, x2, -100
    CHECK_EQ x3, 0, 2

    addi    x4, x0, -2048           /* most negative I immediate */
    CHECK_EQ x4, -2048, 3

    addi    x5, x0, 2047            /* most positive I immediate */
    CHECK_EQ x5, 2047, 4

    /* ---- 5..8: add and sub, including wraparound ------------------------ */
    li      x6, 0x12345678
    li      x7, 0x11111111
    add     x8, x6, x7
    CHECK_EQ x8, 0x23456789, 5

    sub     x9, x8, x7
    CHECK_EQ_REG x9, x6, 6

    li      x10, 0x7FFFFFFF
    addi    x11, x10, 1             /* wraps to INT32_MIN */
    CHECK_EQ x11, 0x80000000, 7

    li      x13, 2047
    sub     x12, x0, x13            /* 0 - 2047 */
    CHECK_EQ x12, -2047, 8

    /* ---- 9..12: and, or -------------------------------------------------- */
    li      x14, 0xAAAAAAAA
    li      x15, 0x55555555
    and     x16, x14, x15
    CHECK_EQ x16, 0, 9

    or      x17, x14, x15
    CHECK_EQ x17, 0xFFFFFFFF, 10

    and     x18, x14, x14
    CHECK_EQ_REG x18, x14, 11

    or      x19, x0, x15
    CHECK_EQ_REG x19, x15, 12

    /* ---- 13..17: sw / lw round trip through RAM -------------------------- */
    la      x19, scratch
    li      x20, 0xDEADBEEF
    sw      x20, 0(x19)
    lw      x21, 0(x19)
    CHECK_EQ_REG x21, x20, 13

    li      x22, 0x0BADF00D
    sw      x22, 4(x19)
    lw      x23, 4(x19)
    CHECK_EQ_REG x23, x22, 14

    /* the first word must be untouched by the second store */
    lw      x24, 0(x19)
    CHECK_EQ_REG x24, x20, 15

    /* negative offset addressing */
    addi    x25, x19, 8
    lw      x26, -8(x25)
    CHECK_EQ_REG x26, x20, 16

    /* store zero, read back zero */
    sw      x0, 0(x19)
    lw      x27, 0(x19)
    CHECK_EQ x27, 0, 17

    /* ---- 18..20: beq, taken and not taken -------------------------------- */
    li      x22, 5
    li      x23, 5
    beq     x22, x23, 1f
    CHECK_UNREACHABLE 18            /* equal operands must branch */
1:
    li      x24, 6
    beq     x22, x24, 2f            /* unequal operands must not branch */
    j       3f
2:
    CHECK_UNREACHABLE 19
3:
    /* backwards branch, used as a loop: count 4 down to 0 */
    li      x28, 4
    li      x29, 0
4:  addi    x29, x29, 1
    addi    x28, x28, -1
    beq     x28, x0, 5f
    j       4b
5:  CHECK_EQ x29, 4, 20

    /* ---- 21..23: jal link register and control flow ---------------------- */
    jal     x1, target_a
after_a_expected:                   /* jal must link exactly this address */
    CHECK_UNREACHABLE 21            /* target_a must not return here */

after_a:
    la      x6, after_a_expected
    CHECK_EQ_REG x1, x6, 22

    /* jal with x0 as the link register must discard the return address:
       x0 stays zero however hard the instruction tries to write it */
    jal     x0, target_b
    CHECK_UNREACHABLE 23

target_b:
    CHECK_EQ x0, 0, 24
    TEST_PASS

target_a:
    /* x1 now holds the return address; continue at after_a rather than
       returning, so the CHECK_UNREACHABLE above stays unreached */
    j       after_a

    /* ---- scratch data ---------------------------------------------------- */
    TEST_DATA_SECTION
scratch:
    .word   0, 0, 0, 0
