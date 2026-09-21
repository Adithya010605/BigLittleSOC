/* ============================================================================
 * csr_basic.S — Zicsr read/write/set/clear semantics and the counters.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START

    /* install a handler that records mcause and skips the faulting insn */
    la      t0, handler
    csrw    mtvec, t0
    la      x1, trap_count
    sw      x0, 0(x1)

    /* ---- 1,2: CSRRW round trip through mscratch ------------------------- */
    li      x2, 0xDEADBEEF
    csrw    mscratch, x2
    csrr    x3, mscratch
    CHECK_EQ_REG x3, x2, 1

    li      x4, 0x12345678
    csrrw   x5, mscratch, x4        /* x5 gets the OLD value */
    CHECK_EQ_REG x5, x2, 2
    csrr    x6, mscratch
    CHECK_EQ_REG x6, x4, 3

    /* ---- 4: CSRRS sets bits and returns the old value ------------------- */
    li      x7, 0x0F0F0000
    csrw    mscratch, x7
    li      x8, 0x00000F0F
    csrrs   x9, mscratch, x8
    CHECK_EQ_REG x9, x7, 4
    csrr    x10, mscratch
    CHECK_EQ x10, 0x0F0F0F0F, 5

    /* ---- 6: CSRRC clears bits ------------------------------------------- */
    li      x11, 0x00000F0F
    csrrc   x12, mscratch, x11
    CHECK_EQ x12, 0x0F0F0F0F, 6
    csrr    x13, mscratch
    CHECK_EQ x13, 0x0F0F0000, 7

    /* ---- 8: CSRRS with rs1 = x0 must NOT write -------------------------- */
    li      x14, 0xAAAA5555
    csrw    mscratch, x14
    csrrs   x15, mscratch, x0
    CHECK_EQ_REG x15, x14, 8
    csrr    x16, mscratch
    CHECK_EQ_REG x16, x14, 9         /* unchanged */

    /* ---- 10: the immediate forms use the 5-bit uimm, zero-extended ------ */
    csrwi   mscratch, 31
    csrr    x17, mscratch
    CHECK_EQ x17, 31, 10             /* 31, not -1: zero-extended */

    csrwi   mscratch, 0
    csrrsi  x18, mscratch, 5
    CHECK_EQ x18, 0, 11
    csrr    x19, mscratch
    CHECK_EQ x19, 5, 12

    csrrci  x20, mscratch, 1
    CHECK_EQ x20, 5, 13
    csrr    x21, mscratch
    CHECK_EQ x21, 4, 14

    /* ---- 15: read-only CSRs -------------------------------------------- */
    csrr    x22, mhartid
    CHECK_EQ x22, 0, 15
    csrr    x23, misa
    CHECK_EQ x23, 0x40000100, 16     /* RV32I */
    csrr    x24, mvendorid
    CHECK_EQ x24, 0, 17

    /* ---- 18: writing a read-only CSR must raise illegal-instruction ----- */
    li      x25, 1
    csrw    misa, x25                /* traps; the handler skips it */
    lw      x26, 0(x1)
    CHECK_EQ x26, 1, 18              /* exactly one trap so far */
    li      x27, 2
    CHECK_EQ_REG x28, x27, 19        /* handler recorded mcause = 2 */

    /* ---- 20: CSRRS with rs1 = x0 on a read-only CSR is LEGAL ------------ */
    csrrs   x29, misa, x0            /* no write, so no trap */
    lw      x26, 0(x1)
    CHECK_EQ x26, 1, 20              /* still exactly one trap */

    /* ---- 21: an unimplemented CSR raises illegal-instruction ------------ */
    csrr    x30, 0x7C0
    lw      x26, 0(x1)
    CHECK_EQ x26, 2, 21

    /* ---- 22: mcycle advances monotonically ------------------------------ */
    csrr    x2, mcycle
    csrr    x3, mcycle
    bltu    x2, x3, 1f
    TEST_FAIL 22
1:

    /* ---- 23: minstret advances, and by less than mcycle over the same
                window, since CPI is at least 1 --------------------------- */
    csrr    x4, minstret
    csrr    x5, mcycle
    nop
    nop
    nop
    nop
    csrr    x6, minstret
    csrr    x7, mcycle
    sub     x8, x6, x4               /* instructions retired */
    sub     x9, x7, x5               /* cycles elapsed */
    bltu    x0, x8, 2f
    TEST_FAIL 23                     /* minstret must have advanced */
2:  bgeu    x9, x8, 3f
    TEST_FAIL 24                     /* cycles must be >= instructions */
3:

    /* ---- 25: mcountinhibit stops minstret ------------------------------- */
    li      x10, 0x4                 /* IR bit */
    csrw    mcountinhibit, x10
    csrr    x11, minstret
    nop
    nop
    nop
    csrr    x12, minstret
    CHECK_EQ_REG x12, x11, 25        /* frozen */
    csrw    mcountinhibit, x0        /* re-enable */
    csrr    x13, minstret
    nop
    csrr    x14, minstret
    bltu    x13, x14, 4f
    TEST_FAIL 26
4:

    /* ---- 27: counters are writable -------------------------------------- */
    li      x15, 0x1000
    csrw    mcycle, x15
    csrr    x16, mcycle
    bgeu    x16, x15, 5f
    TEST_FAIL 27
5:

    /* ---- 28: mstatus.MPP is hardwired to machine mode -------------------- */
    csrw    mstatus, x0              /* try to clear everything */
    csrr    x17, mstatus
    li      x18, 0x1800
    and     x19, x17, x18
    CHECK_EQ_REG x19, x18, 28        /* MPP still 2'b11 */

    /* ---- 29: mtvec forces the mode bits to zero (direct mode only) ------ */
    la      x20, handler
    ori     x21, x20, 3
    csrw    mtvec, x21
    csrr    x22, mtvec
    CHECK_EQ_REG x22, x20, 29

    TEST_PASS

/* ---------------------------------------------------------------------------
 * Handler: record mcause in x28, bump the trap counter, skip the faulting
 * instruction and return.
 * ---------------------------------------------------------------------------
 */
    .align 4
handler:
    csrr    x28, mcause
    la      x31, trap_count
    lw      x30, 0(x31)
    addi    x30, x30, 1
    sw      x30, 0(x31)
    csrr    x31, mepc
    addi    x31, x31, 4
    csrw    mepc, x31
    mret

    TEST_DATA_SECTION
trap_count:
    .word   0
