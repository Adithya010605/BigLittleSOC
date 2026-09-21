/* ============================================================================
 * hazard_load_use.S — load-use interlocks.
 *
 * A load's data is not available while it sits in S3, so it cannot be
 * forwarded: the pipeline must stall the dependent instruction instead. These
 * checks pair each stalling case with the same computation separated by a NOP,
 * so a machine that failed to stall would produce a visible difference between
 * the two rather than being wrong in both.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START

    la      x1, scratch
    li      x2, 0x11112222
    sw      x2, 0(x1)
    li      x3, 0x33334444
    sw      x3, 4(x1)
    li      x4, 0x55556666
    sw      x4, 8(x1)

    /* ---- 1: lw immediately followed by a use of its rd (must stall) ----- */
    lw      x5, 0(x1)
    add     x6, x5, x0
    CHECK_EQ x6, 0x11112222, 1

    /* ---- 2: the same computation with a NOP between (no stall needed) --- */
    lw      x7, 0(x1)
    nop
    add     x8, x7, x0
    CHECK_EQ x8, 0x11112222, 2

    /* ---- 3: load-use through rs2 ---------------------------------------- */
    lw      x9, 4(x1)
    add     x10, x0, x9
    CHECK_EQ x10, 0x33334444, 3

    /* ---- 4: both operands come from the same load ----------------------- */
    li      x11, 7
    sw      x11, 12(x1)
    lw      x12, 12(x1)
    add     x13, x12, x12
    CHECK_EQ x13, 14, 4

    /* ---- 5: load feeding a store's data operand ------------------------- */
    lw      x14, 8(x1)
    sw      x14, 16(x1)
    lw      x15, 16(x1)
    CHECK_EQ x15, 0x55556666, 5

    /* ---- 6: load feeding the next load's address operand ---------------- */
    la      x16, ptr_cell
    la      x17, scratch
    sw      x17, 0(x16)
    lw      x18, 0(x16)         /* x18 = &scratch */
    lw      x19, 0(x18)         /* address comes straight from the load */
    CHECK_EQ x19, 0x11112222, 6

    /* ---- 7: two loads back to back, second independent ------------------ */
    lw      x20, 0(x1)
    lw      x21, 4(x1)
    CHECK_EQ x20, 0x11112222, 7
    CHECK_EQ x21, 0x33334444, 8

    /* ---- 9: load whose rd is x0 must not stall anything, and x0 stays 0 -- */
    lw      x0, 0(x1)
    add     x22, x0, x0
    CHECK_EQ x22, 0, 9

    /* ---- 10: a chain of dependent loads through a linked structure ------ */
    la      x23, node_a
    lw      x24, 0(x23)         /* -> node_b */
    lw      x25, 0(x24)         /* -> node_c */
    lw      x26, 0(x25)         /* -> value  */
    CHECK_EQ x26, 0xABCD, 10

    /* ---- 11: store immediately followed by a load of the same address --- */
    li      x27, 0x0F0F0F0F
    sw      x27, 20(x1)
    lw      x28, 20(x1)
    CHECK_EQ x28, 0x0F0F0F0F, 11

    TEST_PASS

    TEST_DATA_SECTION
scratch:
    .word   0, 0, 0, 0, 0, 0, 0, 0
ptr_cell:
    .word   0
node_a:
    .word   node_b
node_b:
    .word   node_c
node_c:
    .word   0xABCD
