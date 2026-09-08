/* ============================================================================
 * x0_writes.S — x0 stays zero however it is written.
 *
 * Every instruction format that has a destination register is pointed at x0
 * with a result that is emphatically not zero. x0 must read zero afterwards,
 * and — the part that a naive "mask the write" implementation gets wrong — a
 * following instruction must not receive the discarded value through the
 * forwarding path either.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START

    la      x1, scratch
    li      x2, 0x12345678
    sw      x2, 0(x1)

    /* ---- 1,2: OP-IMM and OP -------------------------------------------- */
    addi    x0, x0, 1234
    CHECK_EQ x0, 0, 1
    add     x0, x2, x2
    CHECK_EQ x0, 0, 2

    /* ---- 3,4: the shift and logical forms ------------------------------- */
    slli    x0, x2, 4
    CHECK_EQ x0, 0, 3
    xori    x0, x2, -1
    CHECK_EQ x0, 0, 4

    /* ---- 5,6: LUI and AUIPC --------------------------------------------- */
    lui     x0, 0xFFFFF
    CHECK_EQ x0, 0, 5
    auipc   x0, 0xFFFFF
    CHECK_EQ x0, 0, 6

    /* ---- 7,8: loads of every width -------------------------------------- */
    lw      x0, 0(x1)
    CHECK_EQ x0, 0, 7
    lb      x0, 0(x1)
    CHECK_EQ x0, 0, 8
    lh      x0, 0(x1)
    CHECK_EQ x0, 0, 9
    lbu     x0, 2(x1)
    CHECK_EQ x0, 0, 10
    lhu     x0, 2(x1)
    CHECK_EQ x0, 0, 11

    /* ---- 12,13: JAL and JALR link into x0 ------------------------------- */
    jal     x0, x0_jal_dest
    CHECK_UNREACHABLE 12
x0_jal_dest:
    CHECK_EQ x0, 0, 13

    la      x3, x0_jalr_dest
    jalr    x0, 0(x3)
    CHECK_UNREACHABLE 14
x0_jalr_dest:
    CHECK_EQ x0, 0, 15

    /* ---- 16: the discarded value must not reach the forwarding path ----- */
    /* If x0 were forwarded, x4 would pick up 0x2468ACF0 instead of zero. */
    add     x0, x2, x2
    add     x4, x0, x0
    CHECK_EQ x4, 0, 16

    /* ---- 17: the same, through a load ----------------------------------- */
    lw      x0, 0(x1)
    add     x5, x0, x0
    CHECK_EQ x5, 0, 17

    /* ---- 18: x0 as a branch operand right after a write attempt --------- */
    addi    x0, x0, 99
    beq     x0, x0, 1f
    CHECK_UNREACHABLE 18
1:  li      x6, 99
    bne     x0, x6, 2f
    CHECK_UNREACHABLE 19
2:

    /* ---- 20: x0 as a store's data operand after a write attempt --------- */
    li      x7, -1
    sw      x7, 4(x1)
    add     x0, x2, x2
    sw      x0, 4(x1)
    lw      x8, 4(x1)
    CHECK_EQ x8, 0, 20

    /* ---- 21: x0 as a store's address base ------------------------------- */
    /* Address 0 is the reset vector, in read-only-by-convention ROM, so this
       only checks that x0 reads zero as a base: the store target address is
       formed but the value stored is checked nowhere. Use a load instead. */
    lw      x9, 0(x0)               /* reads the instruction at address 0 */
    CHECK_NE x9, 0, 21              /* _start is not an all-zero word */

    TEST_PASS

    TEST_DATA_SECTION
scratch:
    .word   0, 0, 0, 0
