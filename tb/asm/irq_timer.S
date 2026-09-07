/* ============================================================================
 * irq_timer.S — machine interrupts: taken mid-loop, handled, resumed.
 *
 * The testbench's interrupt controller lives at 0x1100_0000:
 *   +0x0  W  assert irq_timer_i after N more cycles;  R  1 while asserted
 *   +0x4  W  clear the timer interrupt
 *   +0x8  W  bit 0 drives irq_software_i
 *   +0xC  W  bit 0 drives irq_external_i
 *
 * The timer pin stays asserted until the handler clears it, exactly as real
 * hardware behaves, so a handler that forgets to clear it hangs rather than
 * taking one spurious trap and continuing.
 * ============================================================================
 */
#include "test_macros.h"

#define IRQ_BASE      0x11000000
#define IRQ_TIMER_ARM 0x11000000
#define IRQ_TIMER_CLR 0x11000004
#define IRQ_SOFT      0x11000008
#define IRQ_EXT       0x1100000C

#define MIE_MSIE  (1 << 3)
#define MIE_MTIE  (1 << 7)
#define MIE_MEIE  (1 << 11)
#define MSTATUS_MIE (1 << 3)

    TEST_START

    la      t0, handler
    csrw    mtvec, t0
    la      x1, state
    sw      x0, 0(x1)               /* irq_count  */
    sw      x0, 4(x1)               /* last cause */
    sw      x0, 8(x1)               /* last mepc  */

    /* ---- 1: with MIE clear, a pending interrupt must NOT be taken ------- */
    li      x2, MIE_MTIE
    csrw    mie, x2                 /* timer enabled in mie... */
    csrw    mstatus, x0             /* ...but globally disabled */
    li      x3, IRQ_TIMER_ARM
    li      x4, 5
    sw      x4, 0(x3)               /* fire in 5 cycles */

    li      x5, 200                 /* spin well past the firing point */
1:  addi    x5, x5, -1
    bne     x5, x0, 1b

    lw      x6, 0(x1)
    CHECK_EQ x6, 0, 1               /* no interrupt taken */

    /* mip must nevertheless show it pending */
    csrr    x7, mip
    li      x8, MIE_MTIE
    and     x9, x7, x8
    CHECK_EQ_REG x9, x8, 2

    /* ---- 3: enabling MIE takes the already-pending interrupt ------------ */
    li      x10, MSTATUS_MIE
    csrs    mstatus, x10
    nop
    nop
    nop
    nop
    lw      x11, 0(x1)
    CHECK_EQ x11, 1, 3

    /* cause must be the timer interrupt: bit 31 set, code 7 */
    lw      x12, 4(x1)
    li      x13, 0x80000007
    CHECK_EQ_REG x12, x13, 4

    /* ---- 5: MIE is cleared on entry and restored by MRET ---------------- */
    csrr    x14, mstatus
    andi    x15, x14, MSTATUS_MIE
    CHECK_EQ x15, MSTATUS_MIE, 5    /* MRET put MIE back */

    /* ---- 6: an interrupt taken in the middle of a loop resumes correctly */
    li      x16, IRQ_TIMER_ARM
    li      x17, 30
    sw      x17, 0(x16)             /* fire partway through the loop below */

    li      x18, 100                /* iterations */
    li      x19, 0                  /* accumulator */
2:  addi    x19, x19, 7
    addi    x18, x18, -1
    bne     x18, x0, 2b

    /* The loop must produce exactly 700 whatever the interrupt did to it. */
    CHECK_EQ x19, 700, 6
    lw      x20, 0(x1)
    CHECK_EQ x20, 2, 7              /* the second interrupt was taken */

    /* ---- 8: software interrupt, cause 3 --------------------------------- */
    li      x21, MIE_MSIE
    csrw    mie, x21
    li      x22, IRQ_SOFT
    li      x23, 1
    sw      x23, 0(x22)
    nop
    nop
    nop
    nop
    lw      x24, 4(x1)
    li      x25, 0x80000003
    CHECK_EQ_REG x24, x25, 8

    /* ---- 9: external interrupt, cause 11 -------------------------------- */
    li      x26, MIE_MEIE
    csrw    mie, x26
    li      x27, IRQ_EXT
    li      x28, 1
    sw      x28, 0(x27)
    nop
    nop
    nop
    nop
    lw      x29, 4(x1)
    li      x30, 0x8000000B
    CHECK_EQ_REG x29, x30, 9

    /* ---- 10: with the source masked in mie, nothing is taken ------------ */
    csrw    mie, x0
    lw      x2, 0(x1)               /* count before */
    li      x3, IRQ_SOFT
    li      x4, 1
    sw      x4, 0(x3)
    li      x5, 50
3:  addi    x5, x5, -1
    bne     x5, x0, 3b
    lw      x6, 0(x1)
    CHECK_EQ_REG x6, x2, 10         /* count unchanged */

    TEST_PASS

/* ---------------------------------------------------------------------------
 * Handler: clear the interrupt source, record cause and mepc, bump the count.
 *
 * mepc is NOT advanced: an interrupt is taken instead of the instruction at
 * mepc, which has not executed and must run on return. Advancing it here --
 * the right thing for ECALL and EBREAK -- would silently skip an instruction,
 * and the loop check above is what would catch that.
 * ---------------------------------------------------------------------------
 */
    .align 4
handler:
    csrw    mscratch, x31
    la      x31, state

    csrr    x30, mcause
    sw      x30, 4(x31)
    csrr    x30, mepc
    sw      x30, 8(x31)
    lw      x30, 0(x31)
    addi    x30, x30, 1
    sw      x30, 0(x31)

    li      x30, IRQ_TIMER_CLR
    sw      x0, 0(x30)
    li      x30, IRQ_SOFT
    sw      x0, 0(x30)
    li      x30, IRQ_EXT
    sw      x0, 0(x30)

    csrr    x31, mscratch
    mret

    TEST_DATA_SECTION
state:
    .word   0, 0, 0, 0
