/* ============================================================================
 * branch_hazard.S — branches whose operands come from the instruction
 * immediately before them.
 *
 * This is the case that makes resolving branches in S2 delicate. The
 * comparator sits in S2, one stage ahead of where results are produced, so a
 * branch at distance 1 from its producer must read the forwarded S3 value.
 * If the forward muxes fed only the ALU operands and not the comparator, every
 * check here would compare stale register contents — and would still take
 * *some* branch, so the tests are written so that the stale value would send
 * control the wrong way rather than merely producing a wrong number.
 *
 * The load cases are the mirror image: a load's result cannot be forwarded, so
 * a branch at distance 1 from a load must stall until the value is committed.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START

    la      x1, scratch
    li      x2, 42
    sw      x2, 0(x1)
    li      x3, 7
    sw      x3, 4(x1)
    li      x4, -1
    sw      x4, 8(x1)

    /* ---- 1: branch on an ALU result produced one instruction earlier ---- */
    /* x5 starts holding a value that would send the branch the wrong way. */
    li      x5, 999
    addi    x5, x0, 5           /* producer: x5 becomes 5 */
    li      x6, 5
    beq     x5, x6, 1f          /* stale 999 would fall through */
    CHECK_UNREACHABLE 1
1:

    /* ---- 2: the producer feeds rs2 of the branch ------------------------ */
    li      x7, 999
    addi    x7, x0, 11
    li      x8, 11
    beq     x8, x7, 2f
    CHECK_UNREACHABLE 2
2:

    /* ---- 3: both branch operands produced at distance 1 and 2 ----------- */
    addi    x9, x0, 33
    addi    x10, x0, 33
    beq     x9, x10, 3f
    CHECK_UNREACHABLE 3
3:

    /* ---- 4: a NOT-taken branch on a forwarded value --------------------- */
    /* Here the stale value would make the branch TAKEN, so a missing forward
       shows up as control going the wrong way. */
    li      x11, 5
    addi    x11, x0, 6          /* now 6, so the branch must fall through */
    li      x12, 5
    beq     x11, x12, 4f
    j       5f
4:  CHECK_UNREACHABLE 4
5:

    /* ---- 5: signed comparison on a forwarded negative result ------------ */
    li      x13, 100
    sub     x13, x0, x2         /* x13 = -42, produced at distance 1 */
    blt     x13, x0, 6f
    CHECK_UNREACHABLE 5
6:

    /* ---- 6: unsigned comparison on the same forwarded value ------------- */
    sub     x14, x0, x2         /* x14 = 0xFFFFFFD6 */
    bltu    x0, x14, 7f         /* unsigned: 0 < 0xFFFFFFD6 -> taken */
    CHECK_UNREACHABLE 6
7:

    /* ---- 7: branch depending on the immediately preceding LOAD ---------- */
    /* Must stall: the load result cannot be forwarded into the comparator. */
    li      x15, 999
    lw      x15, 0(x1)          /* x15 = 42 */
    li      x16, 42
    beq     x15, x16, 8f
    CHECK_UNREACHABLE 7
8:

    /* ---- 8: load feeding rs2 of a branch at distance 1 ------------------ */
    li      x17, 999
    lw      x17, 4(x1)          /* x17 = 7 */
    li      x18, 7
    beq     x18, x17, 9f
    CHECK_UNREACHABLE 8
9:

    /* ---- 9: a NOT-taken branch depending on a load ---------------------- */
    li      x19, 7
    lw      x19, 0(x1)          /* becomes 42, so must NOT branch */
    li      x20, 7
    beq     x19, x20, 10f
    j       11f
10: CHECK_UNREACHABLE 9
11:

    /* ---- 10: load of a negative value feeding a signed branch ----------- */
    lw      x21, 8(x1)          /* -1 */
    blt     x21, x0, 12f
    CHECK_UNREACHABLE 10
12:

    /* ---- 11: JALR whose base register is produced at distance 1 --------- */
    /* The JALR target adder also lives in S2 and needs the same forwarding. */
    la      x22, jalr_target_a
    addi    x23, x22, 0         /* base produced at distance 1 */
    jalr    x24, 0(x23)
    CHECK_UNREACHABLE 11
jalr_target_a:

    /* ---- 12: JALR whose base register comes from a load ----------------- */
    la      x25, ptr_cell
    la      x26, jalr_target_b
    sw      x26, 0(x25)
    lw      x27, 0(x25)         /* base comes from a load: must stall */
    jalr    x28, 0(x27)
    CHECK_UNREACHABLE 12
jalr_target_b:

    /* ---- 13: branch immediately after a store (no dependency, no stall) - */
    li      x29, 77
    sw      x29, 12(x1)
    beq     x29, x29, 13f
    CHECK_UNREACHABLE 13
13: lw      x1, 12(x1)
    CHECK_EQ x1, 77, 14

    TEST_PASS

    TEST_DATA_SECTION
scratch:
    .word   0, 0, 0, 0
ptr_cell:
    .word   0
