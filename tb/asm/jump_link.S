/* ============================================================================
 * jump_link.S — JAL and JALR: link values, target formation, LSB clearing.
 *
 * The link value is PC+4 of the JUMP, not of the target, and JALR must clear
 * bit 0 of the computed address while leaving bit 1 alone. Both are easy to
 * get subtly wrong and neither shows up as a crash: control still flows, just
 * to the wrong place or with a wrong return address.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START

    /* ---- 1: JAL links the address of the following instruction ---------- */
    jal     x1, j1
j1_ret:
    CHECK_UNREACHABLE 1
j1:
    la      x2, j1_ret
    CHECK_EQ_REG x1, x2, 2

    /* ---- 3: JAL with a backwards displacement --------------------------- */
    li      x3, 0
    j       forward_first
back_target:
    addi    x3, x3, 1
    j       after_back
forward_first:
    jal     x4, back_target
    CHECK_UNREACHABLE 3
after_back:
    CHECK_EQ x3, 1, 4
    /* x4 must hold the address just after the jal at forward_first */
    la      x5, forward_first
    addi    x5, x5, 4
    CHECK_EQ_REG x4, x5, 5

    /* ---- 6: JALR to a register-held address, link checked --------------- */
    la      x6, jalr_dest
    jalr    x7, 0(x6)
jalr_ret:
    CHECK_UNREACHABLE 6
jalr_dest:
    la      x8, jalr_ret
    CHECK_EQ_REG x7, x8, 7

    /* ---- 8: JALR clears bit 0 of the computed target -------------------- */
    /* Base deliberately carries a set bit 0; the hardware must mask it. */
    la      x9, jalr_odd_dest
    ori     x10, x9, 1          /* base with bit 0 set */
    jalr    x11, 0(x10)
    CHECK_UNREACHABLE 8
jalr_odd_dest:

    /* ---- 9: the +imm form also has its bit 0 cleared -------------------- */
    la      x12, jalr_imm_dest
    addi    x12, x12, -3        /* target = (x12 + 3) with LSB set -> cleared */
    jalr    x13, 3(x12)
    CHECK_UNREACHABLE 9
jalr_imm_dest:

    /* ---- 10: JALR with a negative immediate ----------------------------- */
    la      x14, jalr_neg_dest
    addi    x14, x14, 64
    jalr    x15, -64(x14)
    CHECK_UNREACHABLE 10
jalr_neg_dest:

    /* ---- 11: JALR where rd and rs1 are the SAME register ---------------- */
    /* The target must be computed from the OLD value of the register, before
       the link value overwrites it. */
    la      x16, jalr_same_dest
    jalr    x16, 0(x16)
    CHECK_UNREACHABLE 11
jalr_same_dest:
    la      x17, jalr_same_dest
    /* x16 now holds the link address, which is 4 bytes past the jalr */
    CHECK_NE x16, 0, 12

    /* ---- 13: a call/return sequence ------------------------------------- */
    li      x18, 0
    jal     x1, leaf_fn
    CHECK_EQ x18, 5, 13
    jal     x1, leaf_fn
    CHECK_EQ x18, 10, 14

    /* ---- 15: jump landing directly on a load-use hazard ------------------ */
    /* The instruction at the branch target is a load, and the one after it
       consumes the result: the stall must work on a freshly redirected PC. */
    la      x19, scratch
    li      x20, 0x2468ACE0
    sw      x20, 0(x19)
    jal     x21, hazard_landing
    CHECK_UNREACHABLE 15
hazard_landing:
    lw      x22, 0(x19)
    add     x23, x22, x0
    CHECK_EQ x23, 0x2468ACE0, 16

    /* ---- 17: jump landing directly on a taken branch --------------------- */
    jal     x24, branch_landing
    CHECK_UNREACHABLE 17
branch_landing:
    beq     x0, x0, branch_landing2
    CHECK_UNREACHABLE 18
branch_landing2:

    TEST_PASS

leaf_fn:
    addi    x18, x18, 5
    jalr    x0, 0(x1)           /* the canonical `ret` */

    TEST_DATA_SECTION
scratch:
    .word   0, 0, 0, 0
