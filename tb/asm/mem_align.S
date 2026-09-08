/* ============================================================================
 * mem_align.S — every load and store width at every legal alignment.
 *
 * The LSU decides byte enables, store-lane placement and load extension. This
 * test drives all of it through the real memory port rather than in isolation,
 * so a byte-enable that is right in the unit test but mis-wired at the top
 * level is still caught.
 *
 * Only naturally-aligned accesses appear here. Misaligned accesses must raise
 * an exception, which needs trap entry; they are covered by the M5 tests.
 *
 * The stores are checked by reading the surrounding word back, which proves
 * both that the intended bytes changed and that the neighbouring bytes did
 * not — a byte enable stuck at 4'b1111 would pass a naive read-back of the
 * same width.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START

    la      x1, scratch

    /* ---- 1..4: SB at each of the four byte offsets ---------------------- */
    li      x2, -1
    sw      x2, 0(x1)               /* fill with 0xFFFFFFFF */
    li      x3, 0x11
    sb      x3, 0(x1)
    lw      x4, 0(x1)
    CHECK_EQ x4, 0xFFFFFF11, 1      /* only lane 0 changed */

    sw      x2, 0(x1)
    li      x3, 0x22
    sb      x3, 1(x1)
    lw      x4, 0(x1)
    CHECK_EQ x4, 0xFFFF22FF, 2

    sw      x2, 0(x1)
    li      x3, 0x33
    sb      x3, 2(x1)
    lw      x4, 0(x1)
    CHECK_EQ x4, 0xFF33FFFF, 3

    sw      x2, 0(x1)
    li      x3, 0x44
    sb      x3, 3(x1)
    lw      x4, 0(x1)
    CHECK_EQ x4, 0x44FFFFFF, 4

    /* ---- 5..12: LB and LBU at each offset, sign extension --------------- */
    li      x5, 0x807F8070
    sw      x5, 0(x1)
    lb      x6, 0(x1)
    CHECK_EQ x6, 0x70, 5            /* 0x70 positive */
    lbu     x6, 0(x1)
    CHECK_EQ x6, 0x70, 6
    lb      x6, 1(x1)
    CHECK_EQ x6, 0xFFFFFF80, 7      /* 0x80 sign-extends */
    lbu     x6, 1(x1)
    CHECK_EQ x6, 0x80, 8
    lb      x6, 2(x1)
    CHECK_EQ x6, 0x7F, 9
    lbu     x6, 2(x1)
    CHECK_EQ x6, 0x7F, 10
    lb      x6, 3(x1)
    CHECK_EQ x6, 0xFFFFFF80, 11
    lbu     x6, 3(x1)
    CHECK_EQ x6, 0x80, 12

    /* ---- 13..16: SH at both aligned halfword offsets -------------------- */
    sw      x2, 0(x1)
    li      x7, 0xABCD
    sh      x7, 0(x1)
    lw      x8, 0(x1)
    CHECK_EQ x8, 0xFFFFABCD, 13

    sw      x2, 0(x1)
    sh      x7, 2(x1)
    lw      x8, 0(x1)
    CHECK_EQ x8, 0xABCDFFFF, 14

    /* the upper bits of the source register must be discarded */
    sw      x0, 0(x1)
    li      x9, 0x1234ABCD
    sh      x9, 0(x1)
    lw      x8, 0(x1)
    CHECK_EQ x8, 0x0000ABCD, 15

    sb      x9, 2(x1)
    lw      x8, 0(x1)
    CHECK_EQ x8, 0x00CDABCD, 16

    /* ---- 17..22: LH and LHU, sign extension ----------------------------- */
    li      x10, 0x80007FFF
    sw      x10, 0(x1)
    lh      x11, 0(x1)
    CHECK_EQ x11, 0x7FFF, 17
    lhu     x11, 0(x1)
    CHECK_EQ x11, 0x7FFF, 18
    lh      x11, 2(x1)
    CHECK_EQ x11, 0xFFFF8000, 19    /* 0x8000 sign-extends */
    lhu     x11, 2(x1)
    CHECK_EQ x11, 0x8000, 20

    li      x10, 0x7FFF8000
    sw      x10, 0(x1)
    lh      x11, 0(x1)
    CHECK_EQ x11, 0xFFFF8000, 21
    lh      x11, 2(x1)
    CHECK_EQ x11, 0x7FFF, 22

    /* ---- 23..25: SW and LW ---------------------------------------------- */
    li      x12, 0xDEADBEEF
    sw      x12, 0(x1)
    lw      x13, 0(x1)
    CHECK_EQ_REG x13, x12, 23

    sw      x0, 4(x1)
    lw      x13, 4(x1)
    CHECK_EQ x13, 0, 24

    /* a store must not disturb the neighbouring words */
    li      x14, 0x11111111
    li      x15, 0x22222222
    li      x16, 0x33333333
    sw      x14, 0(x1)
    sw      x15, 4(x1)
    sw      x16, 8(x1)
    sb      x0, 4(x1)               /* clear one byte of the middle word */
    lw      x17, 0(x1)
    CHECK_EQ_REG x17, x14, 25
    lw      x17, 4(x1)
    CHECK_EQ x17, 0x22222200, 26
    lw      x17, 8(x1)
    CHECK_EQ_REG x17, x16, 27

    /* ---- 28: negative and positive offsets from a mid-array base -------- */
    addi    x18, x1, 8
    lw      x19, -8(x18)
    CHECK_EQ_REG x19, x14, 28
    lw      x19, 0(x18)
    CHECK_EQ_REG x19, x16, 29

    /* ---- 30: byte-wise fill then word read, checking lane ordering ------ */
    li      x20, 0xAA
    sb      x20, 16(x1)
    li      x20, 0xBB
    sb      x20, 17(x1)
    li      x20, 0xCC
    sb      x20, 18(x1)
    li      x20, 0xDD
    sb      x20, 19(x1)
    lw      x21, 16(x1)
    CHECK_EQ x21, 0xDDCCBBAA, 30    /* little-endian lane order */

    /* ---- 31: halfword-wise fill then word read -------------------------- */
    li      x22, 0x1122
    sh      x22, 20(x1)
    li      x22, 0x3344
    sh      x22, 22(x1)
    lw      x23, 20(x1)
    CHECK_EQ x23, 0x33441122, 31

    TEST_PASS

    TEST_DATA_SECTION
scratch:
    .word   0, 0, 0, 0, 0, 0, 0, 0
