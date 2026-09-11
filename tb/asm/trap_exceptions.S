/* ============================================================================
 * trap_exceptions.S — every synchronous exception: cause, mtval, mepc, and
 * resumption through MRET.
 *
 * The handler records mcause, mtval and mepc into memory and then skips the
 * faulting instruction, so the main flow can check all three after each trap
 * rather than only that "a trap happened".
 * ============================================================================
 */
#include "test_macros.h"

/* saved[0]=mcause saved[1]=mtval saved[2]=mepc saved[3]=count */
#define SAVED_CAUSE 0
#define SAVED_TVAL  4
#define SAVED_EPC   8
#define SAVED_COUNT 12

    TEST_START

    la      t0, handler
    csrw    mtvec, t0

    /* ---- 1..3: ECALL, cause 11, mtval 0 --------------------------------- */
    la      x1, ecall_site
ecall_site:
    ecall
    la      x2, saved
    lw      x3, SAVED_CAUSE(x2)
    CHECK_EQ x3, 11, 1
    lw      x4, SAVED_TVAL(x2)
    CHECK_EQ x4, 0, 2
    lw      x5, SAVED_EPC(x2)
    CHECK_EQ_REG x5, x1, 3

    /* ---- 4..6: EBREAK, cause 3, mtval = pc ------------------------------ */
    la      x6, ebreak_site
ebreak_site:
    ebreak
    lw      x7, SAVED_CAUSE(x2)
    CHECK_EQ x7, 3, 4
    lw      x8, SAVED_TVAL(x2)
    CHECK_EQ_REG x8, x6, 5
    lw      x9, SAVED_EPC(x2)
    CHECK_EQ_REG x9, x6, 6

    /* ---- 7..9: illegal instruction, cause 2, mtval = the insn word ------ */
    la      x10, zero_site
zero_site:
    .word   0x00000000
    lw      x11, SAVED_CAUSE(x2)
    CHECK_EQ x11, 2, 7
    lw      x12, SAVED_TVAL(x2)
    CHECK_EQ x12, 0x00000000, 8
    lw      x13, SAVED_EPC(x2)
    CHECK_EQ_REG x13, x10, 9

    /* all ones */
    .word   0xFFFFFFFF
    lw      x14, SAVED_TVAL(x2)
    CHECK_EQ x14, 0xFFFFFFFF, 10

    /* MUL: the M extension is not implemented and must trap */
    .word   0x02C58633              /* mul x12, x11, x12 */
    lw      x15, SAVED_CAUSE(x2)
    CHECK_EQ x15, 2, 11
    lw      x16, SAVED_TVAL(x2)
    CHECK_EQ x16, 0x02C58633, 12

    /* DIV */
    .word   0x02C5C633              /* div x12, x11, x12 */
    lw      x17, SAVED_CAUSE(x2)
    CHECK_EQ x17, 2, 13

    /* ---- 14..16: misaligned LW, cause 4, mtval = the address ------------ */
    la      x18, scratch
    addi    x19, x18, 1             /* deliberately unaligned */
    la      x20, lw_site
lw_site:
    lw      x21, 0(x19)
    lw      x22, SAVED_CAUSE(x2)
    CHECK_EQ x22, 4, 14
    lw      x23, SAVED_TVAL(x2)
    CHECK_EQ_REG x23, x19, 15
    lw      x24, SAVED_EPC(x2)
    CHECK_EQ_REG x24, x20, 16

    /* ---- 17,18: misaligned LH, cause 4 ---------------------------------- */
    addi    x25, x18, 1
    lh      x26, 0(x25)
    lw      x27, SAVED_CAUSE(x2)
    CHECK_EQ x27, 4, 17
    lw      x28, SAVED_TVAL(x2)
    CHECK_EQ_REG x28, x25, 18

    /* ---- 19,20: misaligned SW, cause 6 ---------------------------------- */
    addi    x29, x18, 2
    sw      x0, 0(x29)
    lw      x3, SAVED_CAUSE(x2)
    CHECK_EQ x3, 6, 19
    lw      x4, SAVED_TVAL(x2)
    CHECK_EQ_REG x4, x29, 20

    /* ---- 21: misaligned SH, cause 6 ------------------------------------- */
    addi    x5, x18, 3
    sh      x0, 0(x5)
    lw      x6, SAVED_CAUSE(x2)
    CHECK_EQ x6, 6, 21

    /* ---- 22: a misaligned store must NOT modify memory ------------------ */
    li      x7, -1
    sw      x7, 0(x18)              /* aligned, fills the word */
    li      x8, 0
    addi    x9, x18, 1
    sw      x8, 0(x9)               /* misaligned: traps, changes nothing */
    lw      x10, 0(x18)
    CHECK_EQ x10, 0xFFFFFFFF, 22

    /* ---- 23: aligned accesses still work after all those traps ---------- */
    li      x11, 0x5A5A1234
    sw      x11, 0(x18)
    lw      x12, 0(x18)
    CHECK_EQ_REG x12, x11, 23

    /* ---- 24: byte accesses are never misaligned ------------------------- */
    /* Compared against the count captured immediately before, rather than
       against a hard-coded total, so the check stays valid when traps are
       added above it. */
    lw      x30, SAVED_COUNT(x2)    /* before */
    addi    x13, x18, 1
    lb      x14, 0(x13)             /* odd address: legal for a byte load */
    lh      x14, 0(x18)             /* even address: legal for a halfword */
    lw      x15, SAVED_COUNT(x2)    /* after */
    CHECK_EQ_REG x15, x30, 24

    /* ---- 25: load access fault from an unmapped address, cause 5 -------- */
    li      x17, 0x40000000         /* outside every mapped region */
    lw      x18, 0(x17)
    lw      x19, SAVED_CAUSE(x2)
    CHECK_EQ x19, 5, 25
    lw      x20, SAVED_TVAL(x2)
    CHECK_EQ_REG x20, x17, 26

    /* ---- 27: store access fault, cause 7 -------------------------------- */
    li      x21, 0x40000000
    sw      x0, 0(x21)
    lw      x22, SAVED_CAUSE(x2)
    CHECK_EQ x22, 7, 27

    /* ---- 28: instruction address misaligned, cause 0 --------------------- */
    /* JALR to an address with bit 1 set: bit 0 is cleared by the hardware,
       bit 1 is not, so the target is 2-byte aligned and must trap. */
    la      x23, misaligned_target
    addi    x23, x23, 2
    la      x24, jalr_site
jalr_site:
    jalr    x25, 0(x23)
    lw      x26, SAVED_CAUSE(x2)
    CHECK_EQ x26, 0, 28
    lw      x27, SAVED_TVAL(x2)
    CHECK_EQ_REG x27, x23, 29
    lw      x28, SAVED_EPC(x2)
    CHECK_EQ_REG x28, x24, 30

    TEST_PASS

misaligned_target:
    nop
    nop

/* ---------------------------------------------------------------------------
 * Handler: record mcause/mtval/mepc, bump the count, resume at mepc+4.
 *
 * Every exception raised here is on a 4-byte instruction, so skipping by 4 is
 * the correct resumption for all of them.
 * ---------------------------------------------------------------------------
 */
    .align 4
handler:
    csrw    mscratch, x31           /* free one register without touching RAM */
    la      x31, saved
    csrr    x30, mcause
    sw      x30, SAVED_CAUSE(x31)
    csrr    x30, mtval
    sw      x30, SAVED_TVAL(x31)
    csrr    x30, mepc
    sw      x30, SAVED_EPC(x31)
    lw      x30, SAVED_COUNT(x31)
    addi    x30, x30, 1
    sw      x30, SAVED_COUNT(x31)
    csrr    x30, mepc
    addi    x30, x30, 4
    csrw    mepc, x30
    csrr    x31, mscratch
    mret

    TEST_DATA_SECTION
saved:
    .word   0, 0, 0, 0
scratch:
    .word   0, 0, 0, 0
