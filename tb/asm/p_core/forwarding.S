/* ============================================================================
 * forwarding.S — every operand path of the five-stage pipeline.
 *
 *   EX -> EX     producer one ahead (in MEM when the consumer is in EX)
 *   MEM -> EX    producer two ahead (in WB)
 *   regfile      producer three ahead, written in WB the cycle ID reads
 *   MEM -> MEM   store data from a load / CSR read one ahead
 *   interlock    load or CSR read one ahead of any other use
 *
 * Plus the priority rule (the youngest producer wins), x0, and the load /
 * store combinations where the interlock must or must not apply. Each check
 * gives the distance and the path in its comment.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START
    la      x1, scratch

    /* ---- 1: the youngest producer wins (MEM beats WB) ------------------- */
    li      x5, 0
    addi    x5, x0, 1
    addi    x5, x0, 2
    add     x6, x5, x0
    CHECK_EQ x6, 2, 1

    /* ---- 2: distance 2, MEM -> EX --------------------------------------- */
    addi    x5, x0, 3
    nop
    add     x6, x5, x0
    CHECK_EQ x6, 3, 2

    /* ---- 3: distance 3, register file write-first ---------------------- */
    addi    x5, x0, 4
    nop
    nop
    add     x6, x5, x0
    CHECK_EQ x6, 4, 3

    /* ---- 4: both operands, from different stages ------------------------ */
    addi    x7, x0, 10
    addi    x8, x0, 32
    sub     x9, x8, x7              /* x8 from MEM, x7 from WB */
    CHECK_EQ x9, 22, 4

    /* ---- 5: load -> store data, distance 1 (MEM -> MEM, no stall) ------- */
    li      x10, 0x11223344
    sw      x10, 0(x1)
    lw      x11, 0(x1)
    sw      x11, 4(x1)
    lw      x12, 4(x1)
    CHECK_EQ x12, 0x11223344, 5

    /* ---- 6: sign-extended byte load -> word store, distance 1 ---------- */
    li      x10, 0x000000F0
    sw      x10, 8(x1)
    lb      x11, 8(x1)
    sw      x11, 12(x1)
    lw      x12, 12(x1)
    CHECK_EQ x12, 0xFFFFFFF0, 6

    /* ---- 7: word load -> byte and halfword stores, distance 1 ---------- */
    li      x10, 0xA1B2C3D4
    sw      x10, 16(x1)
    sw      x0, 20(x1)
    lw      x11, 16(x1)
    sb      x11, 21(x1)
    lw      x13, 16(x1)
    sh      x13, 22(x1)
    lw      x12, 20(x1)
    CHECK_EQ x12, 0xC3D4D400, 7

    /* ---- 8: CSR read -> store data, distance 1 (MEM -> MEM) ------------ */
    li      x10, 0x5A5A1234
    csrw    mscratch, x10
    csrr    x11, mscratch
    sw      x11, 24(x1)
    lw      x12, 24(x1)
    CHECK_EQ x12, 0x5A5A1234, 8

    /* ---- 9: load -> store ADDRESS, distance 1: must interlock ---------- */
    la      x10, scratch + 28
    sw      x10, 32(x1)
    li      x14, 0x0BADF00D
    lw      x11, 32(x1)
    sw      x14, 0(x11)
    lw      x12, 28(x1)
    CHECK_EQ x12, 0x0BADF00D, 9

    /* ---- 10: load -> store data, distance 2 (MEM -> EX) ----------------- */
    li      x10, 0x600DCAFE
    sw      x10, 36(x1)
    lw      x11, 36(x1)
    nop
    sw      x11, 40(x1)
    lw      x12, 40(x1)
    CHECK_EQ x12, 0x600DCAFE, 10

    /* ---- 11: load -> ALU, distance 1: interlock, then MEM -> EX -------- */
    li      x10, 77
    sw      x10, 44(x1)
    lw      x11, 44(x1)
    addi    x12, x11, 1
    CHECK_EQ x12, 78, 11

    /* ---- 12: load -> load address (pointer chase), distance 1 ---------- */
    la      x10, scratch + 48
    sw      x10, 52(x1)
    li      x13, 999
    sw      x13, 48(x1)
    lw      x11, 52(x1)
    lw      x12, 0(x11)
    CHECK_EQ x12, 999, 12

    /* ---- 13: load -> branch comparison, distance 1 ---------------------- */
    li      x10, 5
    sw      x10, 56(x1)
    lw      x11, 56(x1)
    beq     x11, x10, 13f
    TEST_FAIL 13
13:
    /* ---- 14: load -> JALR base, distance 1 ------------------------------ */
    la      x10, 14f
    sw      x10, 60(x1)
    lw      x11, 60(x1)
    jalr    x0, 0(x11)
    TEST_FAIL 14
14:
    /* ---- 15: CSR read -> ALU, distance 1: interlock --------------------- */
    li      x10, 40
    csrw    mscratch, x10
    csrr    x11, mscratch
    addi    x12, x11, 2
    CHECK_EQ x12, 42, 15

    /* ---- 16: a load whose rd is x0 forwards nothing -------------------- */
    li      x10, 0x12345678
    sw      x10, 64(x1)
    lw      x0, 64(x1)
    add     x12, x0, x0
    CHECK_EQ x12, 0, 16
    /* ...and nothing into the MEM -> MEM store path either */
    lw      x0, 64(x1)
    sw      x0, 68(x1)
    lw      x12, 68(x1)
    CHECK_EQ x12, 0, 17

    /* ---- 18: an ALU write to x0 forwards nothing ----------------------- */
    addi    x0, x0, 5
    add     x12, x0, x0
    CHECK_EQ x12, 0, 18

    /* ---- 19: store data where the younger ALU write supersedes a load --- */
    /* lw writes x11, then addi overwrites x11; the store must take the addi's
       value (EX->EX), not the load's from WB (MEM->MEM). */
    li      x10, 111
    sw      x10, 72(x1)
    lw      x11, 72(x1)
    addi    x11, x0, 222
    sw      x11, 76(x1)
    lw      x12, 76(x1)
    CHECK_EQ x12, 222, 19

    /* ---- 20: two loads in a row to the same rd, then a store of it ----- */
    li      x10, 1
    sw      x10, 80(x1)
    li      x10, 2
    sw      x10, 84(x1)
    lw      x11, 80(x1)
    lw      x11, 84(x1)
    sw      x11, 88(x1)
    lw      x12, 88(x1)
    CHECK_EQ x12, 2, 20

    /* ---- 21: JAL link value forwarded at distance 1 --------------------- */
    jal     x13, 21f
21: la      x14, 21b
    CHECK_EQ_REG x13, x14, 21

    TEST_PASS

    TEST_DATA_SECTION
scratch:
    .fill 32, 4, 0
