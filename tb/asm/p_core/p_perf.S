/* ============================================================================
 * p_perf.S — the P-core's three additional event counters.
 *
 *   mhpmcounter7  instructions retired that redirected fetch from EX
 *   mhpmcounter8  cycles EX waited on the multiplier or divider
 *   mhpmcounter9  cycles the load-use / CSR-use interlock held ID
 *
 * mhpmcounter8 is exact at every memory latency: it counts cycles a multiply
 * or divide spends in EX before its result exists, which is 3 for a multiply
 * (4 cycles in EX) and 32 for a divide (33), independent of memory.
 * mhpmcounter9 is exactly zero for a load feeding only a store's data (that
 * pair needs no interlock) and at least one for a load feeding an ALU op.
 * mhpmcounter7 counts exactly one for a cold taken branch and zero for a
 * not-taken one.
 *
 * NOPs separate each counter write from the instruction measured: a counter
 * write and an event in the same cycle resolve in favour of the write, so the
 * event would otherwise be lost. Nothing that could interlock is placed next
 * to the csrr that reads a counter.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START
    la      x1, scratch
    li      x6, 1000
    li      x7, 7

    /* ---- 1: one multiply = 3 busy cycles -------------------------------- */
    csrw    mhpmcounter8, x0
    nop
    nop
    mul     x5, x6, x7
    csrr    x8, mhpmcounter8
    CHECK_EQ x8, 3, 1

    /* ---- 2: one divide = 32 busy cycles --------------------------------- */
    csrw    mhpmcounter8, x0
    nop
    nop
    div     x5, x6, x7
    csrr    x8, mhpmcounter8
    CHECK_EQ x8, 32, 2
    CHECK_EQ x5, 142, 3

    /* ---- 4: two back-to-back divides = 64 ------------------------------- */
    csrw    mhpmcounter8, x0
    nop
    nop
    div     x5, x6, x7
    remu    x9, x6, x7
    csrr    x8, mhpmcounter8
    CHECK_EQ x8, 64, 4

    /* ---- 5, 6: behind a store, so the result may have to be HELD in EX
       while MEM waits on memory. Held cycles are not busy cycles, so the
       counts do not change; a unit that dropped its result and recomputed
       it would count more. ---------------------------------------------- */
    csrw    mhpmcounter8, x0
    nop
    nop
    sw      x0, 8(x1)
    mul     x5, x6, x7
    csrr    x8, mhpmcounter8
    CHECK_EQ x8, 3, 14
    CHECK_EQ x5, 7000, 15
    csrw    mhpmcounter8, x0
    nop
    nop
    sw      x0, 8(x1)
    divu    x5, x6, x7
    csrr    x8, mhpmcounter8
    CHECK_EQ x8, 32, 16
    CHECK_EQ x5, 142, 17

    /* ---- 5: ALU work does not count ------------------------------------- */
    csrw    mhpmcounter8, x0
    nop
    nop
    add     x5, x6, x7
    sub     x5, x6, x7
    csrr    x8, mhpmcounter8
    CHECK_EQ x8, 0, 5

    /* ---- 6: load -> store data needs no interlock ---------------------- */
    sw      x6, 0(x1)
    csrw    mhpmcounter9, x0
    nop
    nop
    lw      x10, 0(x1)
    sw      x10, 4(x1)
    nop
    nop
    csrr    x11, mhpmcounter9
    CHECK_EQ x11, 0, 6

    /* ---- 7: load -> ALU interlocks at least once ------------------------ */
    /* With slow instruction fetch the addi could reach ID only after the load
       had finished, needing no interlock at all. The divide in front holds
       both in the fetch buffers for 33 cycles, so they then move as a pair
       and the interlock must fire whatever the memory latency. */
    csrw    mhpmcounter9, x0
    nop
    nop
    div     x13, x6, x7
    lw      x10, 0(x1)
    addi    x12, x10, 1
    nop
    nop
    csrr    x11, mhpmcounter9
    CHECK_NE x11, 0, 7
    CHECK_EQ x12, 1001, 8

    /* ---- 9: a cold taken branch mispredicts once ------------------------ */
    csrw    mhpmcounter7, x0
    nop
    nop
    beq     x0, x0, 9f
    nop
9:  csrr    x13, mhpmcounter7
    CHECK_EQ x13, 1, 9

    /* ---- 10: a cold not-taken branch does not --------------------------- */
    csrw    mhpmcounter7, x0
    nop
    nop
    bne     x0, x0, 10f
    nop
10: csrr    x13, mhpmcounter7
    CHECK_EQ x13, 0, 10

    /* ---- 11: mhpmcounter10 does not exist: the access traps ------------- */
    la      x14, handler
    csrw    mtvec, x14
    li      x15, 0
    csrr    x16, 0xB0A              /* illegal: handler sets x15 = mcause */
    CHECK_EQ x15, 2, 11
    li      x15, 0
    csrr    x16, 0xB8A
    CHECK_EQ x15, 2, 12
    /* ...while mhpmcounter9h, the last one that does, is fine */
    li      x15, 0
    csrr    x16, mhpmcounter9h
    CHECK_EQ x15, 0, 13

    TEST_PASS

    .align 4
handler:
    csrr    x15, mcause
    csrr    x17, mepc
    addi    x17, x17, 4
    csrw    mepc, x17
    mret

    TEST_DATA_SECTION
scratch:
    .fill 4, 4, 0
