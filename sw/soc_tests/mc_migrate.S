/* ============================================================================
 * mc_migrate.S — a migration seen from inside the migrating hart.
 *
 *   int mig_selftest_to_e(uint32_t ctrl);   P-core -> E-core
 *   int mig_selftest_to_p(uint32_t ctrl);   E-core -> P-core
 *
 * Loads a distinct signature into every register but t0 and a0, writes
 * ctrl (still in a0) to MIG_CTRL through t0 -- a request to move the calling
 * hart -- and spins on misa with t0 alone until the hart is running on the
 * other kind of core. Every register is therefore set before the request can
 * halt the hart. Then it checks that every register still holds its
 * signature (a0: ctrl), and that the CSRs that travel with a context
 * (mstatus, mie, mtvec, mscratch, mepc, mcause, mtval) read what they read
 * before the request. Only t0, which the spin loop rewrites, is not checked.
 *
 * Returns 0, the number of the first register that changed (1..31), or
 * 0x100 + n for the n-th CSR in the list above.
 *
 * Interrupts stay disabled (mstatus.MIE = 0) throughout: sp, gp and tp hold
 * signatures while the hart spins.
 *
 * Comments are C-style; see sw/common/start.S for why.
 * ============================================================================
 */

#define MIG_CTRL_ADDR 0x50000004
#define SIG(n)        (0xA5000000 + (n) * 0x00010203)

/* gp holds a signature too: no gp-relative addressing. */
    .option norelax

    .section .bss
    .align 2
mig_saved_sp:   .space 4 * 16       /* per hart */

    .section .text

/* Frame: ra, gp, tp, s0-s11 (15 words), the 7 CSRs' expected values, a0. */
#define FRAME   96
#define CSR0    60
#define ARG0    88

/* \dst = &mig_saved_sp[mhartid], using \tmp */
.macro SAVED_SP_SLOT dst, tmp
    csrr    \tmp, mhartid
    slli    \tmp, \tmp, 2
    la      \dst, mig_saved_sp
    add     \dst, \dst, \tmp
.endm

.macro SAVE_AND_SET_CSRS
    addi    sp, sp, -FRAME
    sw      ra, 0(sp)
    sw      gp, 4(sp)
    sw      tp, 8(sp)
    sw      s0, 12(sp)
    sw      s1, 16(sp)
    sw      s2, 20(sp)
    sw      s3, 24(sp)
    sw      s4, 28(sp)
    sw      s5, 32(sp)
    sw      s6, 36(sp)
    sw      s7, 40(sp)
    sw      s8, 44(sp)
    sw      s9, 48(sp)
    sw      s10, 52(sp)
    sw      s11, 56(sp)
    SAVED_SP_SLOT t0, t1
    sw      sp, 0(t0)

    /* Give the travelling CSRs recognisable values (each is WARL, so the
     * expected value is whatever reads back). mstatus: MIE stays 0, MPIE 1. */
    li      t1, 0x00000080
    csrs    mstatus, t1
    li      t1, 0x00000008
    csrc    mstatus, t1
    li      t1, 0x00000888          /* MSIE | MTIE | MEIE (MIE is off) */
    csrw    mie, t1
    li      t1, 0x13579BDF
    csrw    mscratch, t1
    li      t1, 0x00002468
    csrw    mepc, t1
    li      t1, 0x8000000B
    csrw    mcause, t1
    li      t1, 0xFEDCBA98
    csrw    mtval, t1
    csrr    t1, mstatus
    sw      t1, CSR0+0(sp)
    csrr    t1, mie
    sw      t1, CSR0+4(sp)
    csrr    t1, mtvec
    sw      t1, CSR0+8(sp)
    csrr    t1, mscratch
    sw      t1, CSR0+12(sp)
    csrr    t1, mepc
    sw      t1, CSR0+16(sp)
    csrr    t1, mcause
    sw      t1, CSR0+20(sp)
    csrr    t1, mtval
    sw      t1, CSR0+24(sp)
    sw      a0, ARG0(sp)

    /* signatures in x1..x31, except t0 (x5) and a0 (x10) */
    .irp n, 1,2,3,4,6,7,8,9,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      x\n, SIG(\n)
    .endr

    /* the request */
    li      t0, MIG_CTRL_ADDR
    sw      a0, 0(t0)
.endm

.macro CHECK_AND_RETURN
    .irp n, 1,2,3,4,6,7,8,9,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      t0, SIG(\n)
    beq     x\n, t0, 1f
    li      t0, \n
    j       mig_fail
1:
    .endr

    SAVED_SP_SLOT t0, t1
    lw      sp, 0(t0)
    li      t0, 10
    lw      t2, ARG0(sp)
    bne     a0, t2, mig_fail_csr
    li      t0, 0x101
    csrr    t1, mstatus
    lw      t2, CSR0+0(sp)
    bne     t1, t2, mig_fail_csr
    li      t0, 0x102
    csrr    t1, mie
    lw      t2, CSR0+4(sp)
    bne     t1, t2, mig_fail_csr
    li      t0, 0x103
    csrr    t1, mtvec
    lw      t2, CSR0+8(sp)
    bne     t1, t2, mig_fail_csr
    li      t0, 0x104
    csrr    t1, mscratch
    lw      t2, CSR0+12(sp)
    bne     t1, t2, mig_fail_csr
    li      t0, 0x105
    csrr    t1, mepc
    lw      t2, CSR0+16(sp)
    bne     t1, t2, mig_fail_csr
    li      t0, 0x106
    csrr    t1, mcause
    lw      t2, CSR0+20(sp)
    bne     t1, t2, mig_fail_csr
    li      t0, 0x107
    csrr    t1, mtval
    lw      t2, CSR0+24(sp)
    bne     t1, t2, mig_fail_csr
    li      t0, 0
    j       mig_return
.endm

    .globl mig_selftest_to_e
    .type  mig_selftest_to_e, @function
mig_selftest_to_e:
    SAVE_AND_SET_CSRS
2:  csrr    t0, misa                /* wait until misa has no M */
    srli    t0, t0, 12
    andi    t0, t0, 1
    bnez    t0, 2b
    CHECK_AND_RETURN

    .globl mig_selftest_to_p
    .type  mig_selftest_to_p, @function
mig_selftest_to_p:
    SAVE_AND_SET_CSRS
2:  csrr    t0, misa                /* wait until misa has M */
    srli    t0, t0, 12
    andi    t0, t0, 1
    beqz    t0, 2b
    CHECK_AND_RETURN

/* t0 = result. Restores the caller's registers and returns it. */
mig_fail:
    SAVED_SP_SLOT t1, t2
    lw      sp, 0(t1)
mig_fail_csr:
mig_return:
    mv      a0, t0
    lw      ra, 0(sp)
    lw      gp, 4(sp)
    lw      tp, 8(sp)
    lw      s0, 12(sp)
    lw      s1, 16(sp)
    lw      s2, 20(sp)
    lw      s3, 24(sp)
    lw      s4, 28(sp)
    lw      s5, 32(sp)
    lw      s6, 36(sp)
    lw      s7, 40(sp)
    lw      s8, 44(sp)
    lw      s9, 48(sp)
    lw      s10, 52(sp)
    lw      s11, 56(sp)
    addi    sp, sp, FRAME
    ret
