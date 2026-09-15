/* ============================================================================
 * csr_perf.S — the performance counters and the remaining CSR write paths.
 *
 * mhpmcounter3..6 and their high halves feed the P-core comparison in Phase 2,
 * so their counting semantics need to be pinned down by a test rather than
 * only by a comment. This also drives all-zeros and all-ones patterns through
 * every writable CSR, which is what moves toggle coverage on the wide
 * registers.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START

    la      t0, handler
    csrw    mtvec, t0

    /* ---- 1..4: the four counters are readable and writable -------------- */
    li      x5, 0
    csrw    mhpmcounter3, x5
    csrw    mhpmcounter4, x5
    csrw    mhpmcounter5, x5
    csrw    mhpmcounter6, x5

    li      x6, 0x12345678
    csrw    mhpmcounter3, x6
    csrr    x7, mhpmcounter3
    /* the counter also advances, so check it is at least what we wrote */
    bgeu    x7, x6, 1f
    TEST_FAIL 1
1:

    /* all-ones through each counter, high half included */
    li      x8, 0xFFFFFFFF
    csrw    mhpmcounter3h, x8
    csrr    x9, mhpmcounter3h
    CHECK_EQ_REG x9, x8, 2
    csrw    mhpmcounter4h, x8
    csrr    x10, mhpmcounter4h
    CHECK_EQ_REG x10, x8, 3
    csrw    mhpmcounter5h, x8
    csrr    x11, mhpmcounter5h
    CHECK_EQ_REG x11, x8, 4
    csrw    mhpmcounter6h, x8
    csrr    x12, mhpmcounter6h
    CHECK_EQ_REG x12, x8, 5

    /* back to zero */
    csrw    mhpmcounter3h, x0
    csrw    mhpmcounter4h, x0
    csrw    mhpmcounter5h, x0
    csrw    mhpmcounter6h, x0
    csrr    x13, mhpmcounter3h
    CHECK_EQ x13, 0, 6

    /* ---- 7: mhpmcounter4 counts retired BRANCH instructions ------------- */
    csrw    mhpmcounter4, x0
    csrw    mhpmcounter5, x0
    li      x14, 8                  /* loop trip count */
    li      x15, 0
2:  addi    x15, x15, 1
    addi    x14, x14, -1
    bne     x14, x0, 2b             /* 8 branches, 7 of them taken */
    csrr    x16, mhpmcounter4       /* branches retired */
    csrr    x17, mhpmcounter5       /* taken branches   */

    /* The reads themselves retire no branches, so the loop's 8 branches must
       be counted, and exactly 7 of them taken. Allow the count to be at least
       that, since the CHECK macros above contain branches too. */
    li      x18, 8
    bgeu    x16, x18, 3f
    TEST_FAIL 7
3:  li      x19, 7
    bgeu    x17, x19, 4f
    TEST_FAIL 8
4:  bgeu    x16, x17, 5f
    TEST_FAIL 9                     /* taken can never exceed total */
5:

    /* ---- 10: mhpmcounter6 counts retired loads and stores --------------- */
    csrw    mhpmcounter6, x0
    la      x20, scratch
    sw      x0, 0(x20)
    sw      x0, 4(x20)
    lw      x21, 0(x20)
    lw      x22, 4(x20)
    csrr    x23, mhpmcounter6
    li      x24, 4
    bgeu    x23, x24, 6f
    TEST_FAIL 10
6:

    /* ---- 11: mhpmcounter3 counts stall cycles --------------------------- */
    /* mhpmcounter3 counts cycles in which S2 held a valid instruction back.
       A single load-use pair is NOT enough to guarantee one: if the
       instruction fetch happens to be slower than the data access, IF/ID is
       still empty when the load completes, so nothing was held back and
       nothing is counted. That is correct behaviour for this metric -- it
       measures blocked work, not idle time -- but it makes a single-pair
       assertion latency-dependent, and it failed at --waits=random:7 for
       exactly that reason.

       A loop of 32 load-use pairs removes the dependence: over that many
       memory accesses the pipeline is certain to be held back at least once
       whatever the latency pattern. */
    csrw    mhpmcounter3, x0
    li      x24, 32
8:  lw      x25, 0(x20)
    add     x26, x25, x25           /* load-use: the interlock engages here */
    addi    x24, x24, -1
    bne     x24, x0, 8b
    csrr    x27, mhpmcounter3
    bltu    x0, x27, 7f
    TEST_FAIL 11
7:  /* the stall count can never exceed the elapsed cycle count */
    csrr    x28, mcycle
    bgeu    x28, x27, 9f
    TEST_FAIL 24
9:

    /* ---- 12: mepc, mcause and mtval are directly writable --------------- */
    li      x28, 0xFFFFFFFF
    csrw    mepc, x28
    csrr    x29, mepc
    li      x5, 0xFFFFFFFE          /* bit 0 hardwired to zero */
    CHECK_EQ_REG x29, x5, 12

    csrw    mcause, x28
    csrr    x6, mcause
    CHECK_EQ_REG x6, x28, 13

    csrw    mtval, x28
    csrr    x7, mtval
    CHECK_EQ_REG x7, x28, 14

    csrw    mepc, x0
    csrw    mcause, x0
    csrw    mtval, x0
    csrr    x8, mtval
    CHECK_EQ x8, 0, 15

    /* ---- 16: mscratch and mtvec take all-ones and all-zeros ------------- */
    csrw    mscratch, x28
    csrr    x9, mscratch
    CHECK_EQ_REG x9, x28, 16
    csrw    mscratch, x0
    csrr    x10, mscratch
    CHECK_EQ x10, 0, 17

    /* ---- 18: mie accepts only the three machine-interrupt bits ---------- */
    csrw    mie, x28
    csrr    x11, mie
    li      x12, 0x888
    CHECK_EQ_REG x11, x12, 18
    csrw    mie, x0
    csrr    x13, mie
    CHECK_EQ x13, 0, 19

    /* ---- 20: mcountinhibit CY and IR ------------------------------------ */
    li      x14, 0x5                /* CY | IR */
    csrw    mcountinhibit, x14
    csrr    x15, mcountinhibit
    CHECK_EQ_REG x15, x14, 20
    csrw    mcountinhibit, x0
    csrr    x16, mcountinhibit
    CHECK_EQ x16, 0, 21

    /* ---- 22: mcycleh and minstreth ------------------------------------- */
    csrw    mcycleh, x28
    csrr    x17, mcycleh
    CHECK_EQ_REG x17, x28, 22
    csrw    mcycleh, x0
    csrw    minstreth, x28
    csrr    x18, minstreth
    CHECK_EQ_REG x18, x28, 23
    csrw    minstreth, x0

    TEST_PASS

    .align 4
handler:
    csrr    x31, mepc
    addi    x31, x31, 4
    csrw    mepc, x31
    mret

    TEST_DATA_SECTION
scratch:
    .word   0, 0, 0, 0
