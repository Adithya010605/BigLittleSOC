/* ============================================================================
 * branch_basic.S — branch conditions, direction and target forms.
 *
 * Branches resolve in S2 against a dedicated comparator, so every condition is
 * checked in BOTH directions: a comparator that always returned "taken" would
 * pass a one-sided test. The signed and unsigned conditions are checked with
 * operands that distinguish them (-1 versus 1), which is where a shared
 * comparator most often goes wrong.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START

    li      x1, -1
    li      x2, 1
    li      x3, 5
    li      x4, 5

    /* ---- 1,2: beq ------------------------------------------------------- */
    beq     x3, x4, 1f
    CHECK_UNREACHABLE 1             /* equal must branch */
1:  beq     x3, x2, 2f
    j       3f
2:  CHECK_UNREACHABLE 2             /* unequal must not branch */
3:

    /* ---- 3,4: bne ------------------------------------------------------- */
    bne     x3, x2, 4f
    CHECK_UNREACHABLE 3             /* unequal must branch */
4:  bne     x3, x4, 5f
    j       6f
5:  CHECK_UNREACHABLE 4             /* equal must not branch */
6:

    /* ---- 5,6: blt is SIGNED --------------------------------------------- */
    blt     x1, x2, 7f              /* -1 < 1 signed -> taken */
    CHECK_UNREACHABLE 5
7:  blt     x2, x1, 8f              /* 1 < -1 signed -> not taken */
    j       9f
8:  CHECK_UNREACHABLE 6
9:

    /* ---- 7,8: bltu is UNSIGNED ------------------------------------------ */
    bltu    x2, x1, 10f             /* 1 < 0xFFFFFFFF unsigned -> taken */
    CHECK_UNREACHABLE 7
10: bltu    x1, x2, 11f             /* 0xFFFFFFFF < 1 unsigned -> not taken */
    j       12f
11: CHECK_UNREACHABLE 8
12:

    /* ---- 9,10: bge is SIGNED -------------------------------------------- */
    bge     x2, x1, 13f             /* 1 >= -1 signed -> taken */
    CHECK_UNREACHABLE 9
13: bge     x1, x2, 14f             /* -1 >= 1 signed -> not taken */
    j       15f
14: CHECK_UNREACHABLE 10
15:

    /* ---- 11,12: bgeu is UNSIGNED ---------------------------------------- */
    bgeu    x1, x2, 16f             /* 0xFFFFFFFF >= 1 unsigned -> taken */
    CHECK_UNREACHABLE 11
16: bgeu    x2, x1, 17f             /* 1 >= 0xFFFFFFFF unsigned -> not taken */
    j       18f
17: CHECK_UNREACHABLE 12
18:

    /* ---- 13: bge and bgeu with equal operands must be taken ------------- */
    bge     x3, x4, 19f
    CHECK_UNREACHABLE 13
19: bgeu    x3, x4, 20f
    CHECK_UNREACHABLE 14
20:

    /* ---- 15: signed boundary, INT_MIN vs INT_MAX ------------------------ */
    li      x5, 0x80000000          /* INT32_MIN */
    li      x6, 0x7FFFFFFF          /* INT32_MAX */
    blt     x5, x6, 21f             /* signed: MIN < MAX -> taken */
    CHECK_UNREACHABLE 15
21: bltu    x6, x5, 22f             /* unsigned: 2^31-1 < 2^31 -> taken */
    CHECK_UNREACHABLE 16
22:

    /* ---- 17: back-to-back branches, both taken -------------------------- */
    beq     x3, x4, 23f
    CHECK_UNREACHABLE 17
23: beq     x3, x4, 24f
    CHECK_UNREACHABLE 18
24: beq     x3, x4, 25f
    CHECK_UNREACHABLE 19
25:

    /* ---- 20: back-to-back branches, alternating taken / not taken ------- */
    li      x7, 0
    beq     x3, x2, 26f             /* not taken */
    addi    x7, x7, 1
26: beq     x3, x4, 27f             /* taken */
    addi    x7, x7, 16
27: beq     x3, x2, 28f             /* not taken */
    addi    x7, x7, 1
28: CHECK_EQ x7, 2, 20

    /* ---- 21: a not-taken branch whose target is itself ------------------ */
    /* The degenerate target exercises the redirect path's address without
       creating an infinite loop, because the condition is false. */
29: bne     x3, x4, 29b
    li      x8, 0xC0DE
    CHECK_EQ x8, 0xC0DE, 21

    /* ---- 22: backwards branch used as a counted loop -------------------- */
    li      x9, 10
    li      x10, 0
30: addi    x10, x10, 3
    addi    x9, x9, -1
    bne     x9, x0, 30b
    CHECK_EQ x10, 30, 22
    CHECK_EQ x9, 0, 23

    /* ---- 24: nested loops, exercising repeated redirects ---------------- */
    li      x11, 4                  /* outer */
    li      x12, 0                  /* accumulator */
31: li      x13, 3                  /* inner */
32: addi    x12, x12, 1
    addi    x13, x13, -1
    bne     x13, x0, 32b
    addi    x11, x11, -1
    bne     x11, x0, 31b
    CHECK_EQ x12, 12, 24

    /* ---- 25: a long forward branch (large positive displacement) -------- */
    beq     x3, x4, far_target
    CHECK_UNREACHABLE 25
    .space  1024, 0                 /* pad the displacement out */
far_target:
    li      x14, 0xFA20
    CHECK_EQ x14, 0xFA20, 26

    TEST_PASS
