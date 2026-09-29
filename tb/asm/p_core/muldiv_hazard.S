/* ============================================================================
 * muldiv_hazard.S — multiplies and divides inside dependency chains.
 *
 * A multiply occupies EX for 4 cycles and a divide for 33, so every
 * forwarding and interlock path meets them in a shape an ordinary ALU op
 * never produces: the consumer waits in ID for many cycles, the producer's
 * result appears only when the unit finishes, and the operands must be right
 * in the very first cycle the unit starts. Each check below pairs a result
 * with the distance at which it is consumed.
 *
 * Every test in this directory runs at 0, 2 and random wait states, which is
 * what makes the multiply sit finished in EX behind a stalled MEM -- the
 * result-hold path -- as well as run straight through.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START
    la      x1, scratch

    /* ---- 1: MUL result used by the very next instruction (EX->EX) ------- */
    li      x6, 7
    li      x7, 9
    mul     x5, x6, x7
    add     x8, x5, x5
    CHECK_EQ x8, 126, 1

    /* ---- 2: ...and one instruction later (MEM->EX) ---------------------- */
    mul     x5, x6, x7
    nop
    add     x8, x5, x0
    CHECK_EQ x8, 63, 2

    /* ---- 3: a branch on a DIV result, immediately ----------------------- */
    li      x6, 100
    li      x7, 7
    div     x5, x6, x7              /* 14 */
    li      x9, 14
    beq     x5, x9, 3f
    TEST_FAIL 3
3:
    /* ---- 4: a load feeding a MUL (load-use interlock into the unit) ----- */
    li      x10, 1234
    sw      x10, 0(x1)
    lw      x11, 0(x1)
    mul     x12, x11, x11           /* 1522756 */
    CHECK_EQ x12, 1522756, 4

    /* ---- 5: dependent divides back to back ------------------------------ */
    li      x13, 1000000
    li      x14, 10
    divu    x15, x13, x14           /* 100000 */
    divu    x16, x15, x14           /* 10000  */
    remu    x17, x16, x14           /* 0      */
    divu    x18, x16, x14           /* 1000   */
    CHECK_EQ x15, 100000, 5
    CHECK_EQ x16, 10000, 6
    CHECK_EQ x17, 0, 7
    CHECK_EQ x18, 1000, 8

    /* ---- 9: storing a MUL result directly (store data from the unit) ---- */
    li      x6, -3
    li      x7, 5
    mul     x5, x6, x7
    sw      x5, 4(x1)
    lw      x19, 4(x1)
    CHECK_EQ x19, -15, 9

    /* ---- 10: a MUL chain, each consuming the last ------------------------ */
    li      x5, 3
    mul     x5, x5, x5              /* 9     */
    mul     x5, x5, x5              /* 81    */
    mul     x5, x5, x5              /* 6561  */
    mulhu   x20, x5, x5             /* 0     */
    mul     x5, x5, x5              /* 43046721 */
    CHECK_EQ x5, 43046721, 10
    CHECK_EQ x20, 0, 11

    /* ---- 12: DIV operands from EX->EX and MEM->EX forwarding at once ---- */
    li      x21, 81
    li      x22, 9
    addi    x21, x21, 19            /* 100, reaches the div from WB  */
    addi    x22, x22, -4            /* 5,   reaches the div from MEM */
    div     x23, x21, x22
    CHECK_EQ x23, 20, 12

    /* ---- 13: a MUL result as a JALR target ------------------------------ */
    la      x24, 13f
    li      x25, 1
    mul     x26, x24, x25
jalr_site:
    jalr    x27, 0(x26)
    TEST_FAIL 13
13:
    /* the link is the jalr's own pc + 4 */
    la      x28, jalr_site
    addi    x28, x28, 4
    CHECK_EQ_REG x27, x28, 22

    /* ---- 14: an older write reaching an operand held across a store ---- */
    /* The add is in EX while the second store waits on memory in MEM and the
       addi leaves WB: the forwarded operand must survive in EX (operand
       refresh). The first store stalls MEM long enough for fetch to pack
       addi, store and add in behind it; with fast fetch and slow data (the
       0/d3 latency configuration) that makes the case certain. */
    li      x6, 0
    sw      x0, 12(x1)
    addi    x6, x6, 21
    sw      x0, 8(x1)
    add     x7, x6, x6
    CHECK_EQ x7, 42, 14
    sw      x0, 12(x1)
    addi    x6, x6, 1
    sw      x0, 8(x1)
    mul     x7, x6, x6
    CHECK_EQ x7, 484, 15

    /* ---- 16: an instruction behind a divide waits, then sees its result - */
    li      x6, -100
    li      x7, 3
    rem     x8, x6, x7              /* -1 */
    addi    x9, x8, 1               /* 0  */
    sub     x10, x0, x8             /* 1  */
    CHECK_EQ x8, -1, 16
    CHECK_EQ x9, 0, 17
    CHECK_EQ x10, 1, 18

    /* ---- 19: a MUL writing x0 does not forward a value ------------------ */
    li      x6, 5
    mul     x0, x6, x6
    add     x7, x0, x0
    CHECK_EQ x7, 0, 19

    /* ---- 20: a DIV after a mispredicted branch still starts cleanly ---- */
    li      x6, 50
    li      x7, 5
    li      x11, 0
    beq     x0, x0, 20f             /* cold: mispredicted, ID/IF flushed */
    div     x11, x6, x7             /* wrong path: must not complete */
20: div     x12, x6, x7
    CHECK_EQ x11, 0, 20
    CHECK_EQ x12, 10, 21

    TEST_PASS

    TEST_DATA_SECTION
scratch:
    .fill 16, 4, 0
