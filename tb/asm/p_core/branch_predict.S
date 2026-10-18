/* ============================================================================
 * branch_predict.S — control flow under dynamic prediction.
 *
 * Two things are checked. First, CORRECTNESS in every situation that makes a
 * predictor wrong: cold entries, direction changes, a JALR whose target
 * changes each time, BTB aliases, a taken branch whose target is its own
 * fall-through, and nested loops. The program must compute the same answer
 * whatever was predicted.
 *
 * Second, the predictor actually PREDICTS, measured with mhpmcounter7
 * (instructions retired that redirected fetch from EX). The counts are
 * architectural functions of the program and the predictor's rules, not of
 * memory latency, so the exact values hold at every wait-state setting:
 *
 *   * a 5-iteration counted loop mispredicts exactly twice: once on the
 *     first, cold, taken branch and once at the exit;
 *   * run again, the trained loop mispredicts exactly once, at the exit;
 *   * a 9-taken / 1-not-taken loop run 20 times mispredicts exactly 21
 *     times: one cold miss, then one per exit -- the 2-bit counter's
 *     hysteresis keeps each re-entry predicted taken.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START

    /* ---- 1: counted loop, cold then trained ----------------------------- */
    csrw    mhpmcounter7, x0
    li      x5, 5
    li      x6, 0
1:  addi    x6, x6, 3
    addi    x5, x5, -1
    bne     x5, x0, 1b
    csrr    x7, mhpmcounter7
    CHECK_EQ x6, 15, 1
    CHECK_EQ x7, 2, 2

    /* ---- 3: a fresh copy of the loop, run three times by an outer loop.
       The inner loop is cold on the first pass only; after that its 2-bit
       counter sits at weakly-taken between passes, so each later pass
       mispredicts only at its exit. */
    li      x20, 0                  /* pass counter */
    csrw    mhpmcounter7, x0
2:  li      x5, 5
    li      x6, 0
3:  addi    x6, x6, 3
    addi    x5, x5, -1
    bne     x5, x0, 3b
    addi    x20, x20, 1
    li      x21, 3
    bne     x20, x21, 2b            /* three passes over the inner loop */
    csrr    x7, mhpmcounter7
    CHECK_EQ x6, 15, 3
    /* inner: 2 (cold) + 1 + 1; outer: 1 (cold taken) + 1 (exit) = 6 */
    CHECK_EQ x7, 6, 4

    /* ---- 5: 9-taken / 1-not-taken, 20 times ----------------------------- */
    li      x8, 20                  /* outer count */
    li      x9, 0                   /* total inner iterations */
    csrw    mhpmcounter7, x0
4:  li      x10, 10
5:  addi    x9, x9, 1
    addi    x10, x10, -1
    bne     x10, x0, 5b             /* taken 9 times, then falls through */
    addi    x8, x8, -1
    bne     x8, x0, 4b              /* taken 19 times, then falls through */
    csrr    x11, mhpmcounter7
    CHECK_EQ x9, 200, 5
    /* inner: 1 cold + 20 exits = 21; outer: 1 cold + 1 exit = 2 */
    CHECK_EQ x11, 23, 6

    /* ---- 7: alternating direction --------------------------------------- */
    li      x12, 16
    li      x13, 0                  /* taken count  */
    li      x14, 0                  /* fall count   */
6:  andi    x15, x12, 1
    bne     x15, x0, 7f
    addi    x14, x14, 1
    j       8f
7:  addi    x13, x13, 1
8:  addi    x12, x12, -1
    bne     x12, x0, 6b
    CHECK_EQ x13, 8, 7
    CHECK_EQ x14, 8, 8

    /* ---- 9: a subroutine called from two alternating sites ------------- */
    /* The return JALR's target alternates, so the BTB -- which remembers the
       last target -- is wrong every time after the first. */
    li      x16, 6
    li      x17, 0
9:  jal     x1, sub_add1
    jal     x1, sub_add1
    addi    x16, x16, -1
    bne     x16, x0, 9b
    CHECK_EQ x17, 12, 9

    /* ---- 10: a taken branch whose target is its own fall-through ------- */
    li      x18, 0
    beq     x0, x0, 10f
10: addi    x18, x18, 1
    CHECK_EQ x18, 1, 10

    /* ---- 11: two branches aliasing in the BTB (same pc[7:2]) ----------- */
    /* alias_a and alias_b are exactly 256 bytes apart, so their taken
       branches share a BTB index with different tags: each call finds the
       other's entry, misses, and evicts it. */
    li      x19, 8
    li      x22, 0
11: jal     x1, alias_a
    jal     x1, alias_b
    addi    x19, x19, -1
    bne     x19, x0, 11b
    CHECK_EQ x22, 8 * 5, 11

    /* ---- 12: the BTB tag is compared ------------------------------------ */
    /* alias_c's first instruction (an addi) shares alias_a's BTB index. With
       the tag compared it never hits alias_a's branch entry, so after the
       first pass nothing in this loop mispredicts but the loop exit. Were
       the tag ignored, the addi would hit, be predicted as a branch, and
       invalidate alias_a's entry every pass.
         pass 1: jal a, beq in a, ret a, jal c, ret c, loop bne  (all cold) = 6
         exit:   loop bne                                                 = 1 */
    li      x19, 4
    li      x22, 0
    csrw    mhpmcounter7, x0
12: jal     x1, alias_a
    jal     x1, alias_c
    addi    x19, x19, -1
    bne     x19, x0, 12b
    csrr    x23, mhpmcounter7
    CHECK_EQ x22, 4 * 3, 12
    CHECK_EQ x23, 7, 13

    TEST_PASS

sub_add1:
    addi    x17, x17, 1
    ret

    .align 8
alias_a:
    beq     x0, x0, 1f              /* always taken */
    addi    x22, x22, 100           /* never executed */
1:  addi    x22, x22, 2
    ret
    .align 8
alias_b:
    beq     x0, x0, 1f              /* always taken */
    addi    x22, x22, 100           /* never executed */
1:  addi    x22, x22, 3
    ret
    .align 8
alias_c:
    addi    x22, x22, 1             /* same BTB index as alias_a's beq */
    ret
