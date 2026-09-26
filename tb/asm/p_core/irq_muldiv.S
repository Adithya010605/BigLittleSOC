/* ============================================================================
 * irq_muldiv.S — interrupts landing at every point of a multiply / divide.
 *
 * An interrupt is taken at MEM, on the instruction there, and flushes
 * everything younger -- including a multiply or divide part-way through its
 * iterations in EX. The abandoned operation must leave no trace, and must
 * restart from scratch when the handler returns. (This is the sense in which
 * the divider is "interruptible": an interrupt never waits for it.)
 *
 * The same five-instruction sequence runs 64 times, each time with the timer
 * armed to fire three cycles later than the last, so the interrupt lands at
 * successive points through the sequence: in the iterations of each divide,
 * during the multiplies, and between them. Every result is checked every
 * time, and the handler must have run exactly once per pass.
 *
 * The handler does a multiply and a divide of its own, with operands unlike
 * anything in the main sequence, and the main loop checks what it got. If an
 * abandoned operation were not truly abandoned -- the unit still busy, or a
 * finished result still held -- the handler's own operation is the one that
 * would pick up the stale result.
 * ============================================================================
 */
#include "test_macros.h"

#define IRQ_TIMER_ARM 0x11000000
#define IRQ_TIMER_CLR 0x11000004
#define MIE_MTIE      (1 << 7)
#define MSTATUS_MIE   (1 << 3)

    TEST_START

    la      t0, handler
    csrw    mtvec, t0
    la      x1, state
    sw      x0, 0(x1)               /* interrupts taken */
    li      x2, MIE_MTIE
    csrw    mie, x2
    li      x2, MSTATUS_MIE
    csrs    mstatus, x2

    li      x15, 1000000
    li      x16, 7
    li      x17, 12345
    li      x18, 6789
    li      x19, 13
    li      x26, 0x80000000
    li      x3, IRQ_TIMER_ARM
    li      x4, 1                   /* delay, cycles */
    li      x5, 0                   /* passes completed */

pass:
    sw      x4, 0(x3)               /* arm: fire after x4 cycles */
    divu    x21, x15, x16           /* 142857      */
    mul     x22, x17, x18           /* 83810205    */
    rem     x23, x15, x19           /* 1           */
    div     x24, x15, x19           /* 76923       */
    mulh    x25, x26, x26           /* 0x40000000  */
    li      x6, 142857
    bne     x21, x6, fail
    li      x6, 83810205
    bne     x22, x6, fail
    li      x6, 1
    bne     x23, x6, fail
    li      x6, 76923
    bne     x24, x6, fail
    li      x6, 0x40000000
    bne     x25, x6, fail

    /* wait for this pass's interrupt, in case it has not fired yet */
    addi    x5, x5, 1
1:  lw      x7, 0(x1)
    bne     x7, x5, 1b

    /* the handler's own results: count^2 and count/count */
    lw      x9, 4(x1)
    mul     x10, x5, x5
    bne     x9, x10, fail_handler
    lw      x9, 8(x1)
    li      x10, 1
    bne     x9, x10, fail_handler

    addi    x4, x4, 3
    li      x8, 64
    bne     x5, x8, pass

    lw      x7, 0(x1)
    CHECK_EQ x7, 64, 2              /* exactly one interrupt per pass */
    TEST_PASS

fail:
    /* check 1 failed; x5 holds the pass it failed on */
    TEST_FAIL 1
fail_handler:
    TEST_FAIL 3

/* Clears the timer and counts. mepc is not advanced: the interrupted
   instruction has not executed. Preserves everything but x30. */
    .align 4
handler:
    csrw    mscratch, x31
    la      x31, state
    lw      x30, 0(x31)
    addi    x30, x30, 1
    sw      x30, 0(x31)
    mul     x30, x30, x30           /* count^2 */
    sw      x30, 4(x31)
    lw      x30, 0(x31)
    divu    x30, x30, x30           /* count / count = 1 */
    sw      x30, 8(x31)
    li      x30, IRQ_TIMER_CLR
    sw      x0, 0(x30)
    csrr    x31, mscratch
    mret

    TEST_DATA_SECTION
state:
    .word   0, 0, 0
