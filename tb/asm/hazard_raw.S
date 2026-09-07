/* ============================================================================
 * hazard_raw.S — read-after-write hazards resolved by S3 -> S2 forwarding.
 *
 * Every check here would still pass on a machine with no forwarding at all IF
 * that machine stalled instead, so the point is not only the results but the
 * dependency distances: each block places the consumer at distance 1 from its
 * producer, which is the only distance the forwarding path covers. Distance-2
 * and distance-3 cases are included as controls, since those are served by the
 * register file (write-first) rather than by the forward muxes.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START

    /* ---- 1: back-to-back RAW through rs1 -------------------------------- */
    li      x1, 100
    li      x2, 7
    add     x3, x1, x2          /* produces x3 = 107 */
    add     x4, x3, x2          /* consumes x3 at distance 1, via rs1 */
    CHECK_EQ x4, 114, 1

    /* ---- 2: back-to-back RAW through rs2 -------------------------------- */
    li      x5, 1000
    add     x6, x5, x2          /* x6 = 1007 */
    add     x7, x2, x6          /* consumes x6 at distance 1, via rs2 */
    CHECK_EQ x7, 1014, 2

    /* ---- 3: both operands from the same producer ------------------------ */
    li      x8, 21
    add     x9, x8, x8          /* x9 = 42 */
    add     x10, x9, x9         /* both operands forwarded from one result */
    CHECK_EQ x10, 84, 3

    /* ---- 4: a chain of five dependent instructions ---------------------- */
    li      x11, 1
    addi    x11, x11, 1         /* 2 */
    addi    x11, x11, 1         /* 3 */
    addi    x11, x11, 1         /* 4 */
    addi    x11, x11, 1         /* 5 */
    addi    x11, x11, 1         /* 6 */
    CHECK_EQ x11, 6, 4

    /* ---- 5: distance 2, served by the register file, not forwarding ----- */
    li      x12, 50
    add     x13, x12, x2        /* x13 = 57 */
    nop
    add     x14, x13, x2
    CHECK_EQ x14, 64, 5

    /* ---- 6: distance 3 -------------------------------------------------- */
    li      x15, 60
    add     x16, x15, x2        /* x16 = 67 */
    nop
    nop
    add     x17, x16, x2
    CHECK_EQ x17, 74, 6

    /* ---- 7: forwarding a LUI result (op_a is the constant zero) --------- */
    lui     x18, 0x12345
    addi    x19, x18, 0x678     /* consumes the LUI result at distance 1 */
    CHECK_EQ x19, 0x12345678, 7

    /* ---- 8: forwarding an AUIPC result (op_a is the PC) ----------------- */
auipc_site:
    auipc   x20, 0
    addi    x21, x20, 0         /* consumes the AUIPC result at distance 1 */
    la      x22, auipc_site
    CHECK_EQ_REG x21, x22, 8

    /* ---- 9: forwarding a JAL link value (writeback source is PC+4) ------ */
    jal     x23, jal_landing
jal_return:
    nop
jal_landing:
    addi    x24, x23, 0         /* consumes the link value at distance 1 */
    la      x25, jal_return
    CHECK_EQ_REG x24, x25, 9

    /* ---- 10: forwarding into a store's data operand (rs2) --------------- */
    la      x26, scratch
    li      x27, 3
    add     x28, x27, x27       /* x28 = 6 */
    sw      x28, 0(x26)         /* rs2 forwarded at distance 1 */
    lw      x29, 0(x26)
    CHECK_EQ x29, 6, 10

    /* ---- 11: forwarding into a store's ADDRESS operand (rs1) ------------ */
    la      x1, scratch
    addi    x2, x1, 4           /* address produced at distance 1 */
    li      x3, 0x5A5A5A5A
    sw      x3, 0(x2)
    lw      x4, 4(x1)
    CHECK_EQ x4, 0x5A5A5A5A, 11

    /* ---- 12: forwarding into a load's address operand -------------------- */
    la      x5, scratch
    addi    x6, x5, 4           /* address produced at distance 1 */
    lw      x7, 0(x6)
    CHECK_EQ x7, 0x5A5A5A5A, 12

    /* ---- 13: a producer whose rd is x0 must NOT be forwarded ------------- */
    /* x0 stays zero, so the consumer must read zero and not the ALU result. */
    li      x8, 0x1234
    add     x0, x8, x8          /* attempts to write 0x2468 to x0 */
    add     x9, x0, x0          /* must read zero on both operands */
    CHECK_EQ x9, 0, 13

    TEST_PASS

    TEST_DATA_SECTION
scratch:
    .word   0, 0, 0, 0
