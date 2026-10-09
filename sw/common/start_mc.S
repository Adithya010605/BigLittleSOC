/* ============================================================================
 * start_mc.S — reset entry for multi-core programs on the SoC.
 *
 * Every hart starts here at the reset vector, running the same image. Each
 * reads its hart number from mhartid and:
 *
 *   1. takes its own stack: _stack_top - hartid * MC_STACK_BYTES;
 *   2. hart 0 clears .bss and then releases the others, which wait on
 *      mc_boot_release (in .data, so clearing .bss cannot touch it);
 *   3. calls  int main(int hartid);
 *   4. publishes the result in mc_result[hartid] as (ret << 1) | 1.
 *
 * Hart 0 then waits until every hart has published, and ends the simulation
 * through tohost with the first failing hart's code (or 1 if all passed).
 * The other harts park in a loop. A trap on any hart ends the run at once,
 * from default_trap_handler, with code 0x7E.
 *
 * NHARTS must be defined on the command line (scripts/run_soc.sh does).
 * There are no atomic instructions: the release flag and the result slots
 * each have a single writer, which is all coherent memory needs.
 *
 * Comments are C-style; see start.S for why.
 * ============================================================================
 */

#ifndef NHARTS
#error "NHARTS must be defined"
#endif

#define MC_STACK_BYTES 4096
#define MC_RELEASE     0x600DB007

    .section .text.init, "ax"
    .globl _start
    .type  _start, @function
_start:
.option push
.option norelax
    la      gp, __global_pointer$
.option pop

    csrr    s0, mhartid             /* s0 = hartid, kept across main */

    la      sp, _stack_top
    li      t1, MC_STACK_BYTES
    mv      t2, s0
1:  beqz    t2, 2f                  /* sp -= hartid * MC_STACK_BYTES, without */
    sub     sp, sp, t1              /* a multiply: E-cores have no M          */
    addi    t2, t2, -1
    j       1b
2:
    la      t0, default_trap_handler
    csrw    mtvec, t0

    bnez    s0, 5f

    /* hart 0: clear .bss, then release the others */
    la      t0, __bss_start
    la      t1, __bss_end
3:  bgeu    t0, t1, 4f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       3b
4:  la      t0, mc_boot_release
    li      t1, MC_RELEASE
    sw      t1, 0(t0)
    j       7f

    /* other harts: wait for the release */
5:  la      t0, mc_boot_release
    li      t1, MC_RELEASE
6:  lw      t2, 0(t0)
    bne     t2, t1, 6b

7:  mv      a0, s0
    call    main

    /* publish (ret << 1) | 1 in mc_result[hartid] */
    slli    a0, a0, 1
    ori     a0, a0, 1
    la      t0, mc_result
    slli    t1, s0, 2
    add     t0, t0, t1
    sw      a0, 0(t0)

    bnez    s0, 9f

    /* hart 0: wait for every hart, keep the first failure */
    li      a0, 1
    la      t0, mc_result
    li      t1, 0
    li      t2, NHARTS
8:  lw      t3, 0(t0)
    beqz    t3, 8b                  /* not yet published */
    li      t4, 1
    beq     t3, t4, 10f
    bne     a0, t4, 10f             /* already holding a failure */
    mv      a0, t3
10: addi    t0, t0, 4
    addi    t1, t1, 1
    bne     t1, t2, 8b
    j       _exit_with_a0

9:  j       9b                      /* park */

    .globl _exit_with_a0
    .type  _exit_with_a0, @function
_exit_with_a0:
    la      t0, tohost
    sw      a0, 0(t0)
    sw      zero, 4(t0)
11: j       11b

    .globl default_trap_handler
    .type  default_trap_handler, @function
    .align 4
default_trap_handler:
    csrr    a1, mcause
    csrr    a2, mhartid
    li      a0, (0x7E << 1) | 1
    j       _exit_with_a0

    .section .data
    .align 2
    .globl mc_boot_release
mc_boot_release:
    .word   0
    .globl mc_result
mc_result:
    .rept   NHARTS
    .word   0
    .endr
