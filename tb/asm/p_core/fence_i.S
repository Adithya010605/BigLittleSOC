/* ============================================================================
 * fence_i.S — self-modifying code and FENCE.I.
 *
 * The P-core fetches several instructions ahead of the store that could
 * modify them: by the time a store is in MEM, the next instructions are
 * already in EX, ID and IF. FENCE.I is therefore implemented as a flush and
 * refetch when it retires, and this test is written so that WITHOUT that
 * refetch the stale instruction would execute:
 *
 *   * IN-LINE: the patched instruction is the one immediately after the
 *     FENCE.I, so it is certainly already in the pipeline when the store is
 *     performed. The same site is patched on three passes of a loop with
 *     three different values, so the stale word is always one that has
 *     actually executed before, not merely never-fetched memory.
 *   * OUT-OF-LINE: a subroutine that has already run (and whose return the
 *     BTB has learned) is patched and called again.
 *
 * The rv32ui fence_i compliance test adds a third shape: patch, FENCE.I,
 * then jump to code the fetch stage never reached.
 *
 * The memory model is one unified RAM, so code can be written with ordinary
 * stores.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START

    la      x2, templates
    lw      x3, 0(x2)               /* addi x10, x10, 1   */
    lw      x4, 4(x2)               /* addi x10, x10, 10  */
    lw      x5, 8(x2)               /* addi x10, x10, 100 */

    /* ---- 1..3: in-line, three passes ------------------------------------ */
    la      x7, inline_site
    li      x11, 0                  /* pass */
pass:
    /* pick this pass's replacement word and the value it must produce */
    mv      x13, x3
    li      x12, 1
    li      x14, 1
    beq     x11, x14, 1f
    li      x14, 2
    beq     x11, x14, 2f
    j       3f
1:  mv      x13, x4
    li      x12, 10
    j       3f
2:  mv      x13, x5
    li      x12, 100
3:
    li      x10, 0
    sw      x13, 0(x7)
    fence.i
inline_site:
    addi    x10, x10, 2000          /* as assembled; patched every pass */
    bne     x10, x12, fail_inline
    addi    x11, x11, 1
    li      x14, 3
    bne     x11, x14, pass
    CHECK_EQ x11, 3, 4              /* all three passes ran */

    /* ---- 5, 6: out-of-line ---------------------------------------------- */
    li      x10, 0
    jal     x6, smc_block           /* as assembled: +1000 */
    CHECK_EQ x10, 1000, 5
    la      x8, smc_block
    sw      x4, 0(x8)               /* now +10 */
    fence.i
    li      x10, 0
    jal     x6, smc_block
    CHECK_EQ x10, 10, 6

    /* ---- 7: a stale BTB entry is invalidated ---------------------------- */
    /* stale_site starts as a jump, which the BTB learns. It is then patched
       into an addi. The first time the addi is fetched the BTB still predicts
       the jump -- a mispredict, which must also invalidate the entry -- and
       never again. Mispredicts in the four-pass loop:
         pass 1: jal to stale_site (cold), the addi (stale entry),
                 jal to stale_ret (cold), loop bne (cold)          = 4
         pass 4: loop bne exit                                    = 1
       = 5. Without the invalidation the addi would mispredict on all four
       passes, giving 8. */
    jal     x0, stale_site          /* train: stale_site -> stale_target */
stale_back:
    la      x8, stale_site
    sw      x3, 0(x8)               /* now "addi x10, x10, 1" */
    fence.i
    li      x10, 0
    li      x20, 4
    csrw    mhpmcounter7, x0
    nop
    nop
stale_loop:
    jal     x0, stale_site
stale_ret:
    addi    x20, x20, -1
    bne     x20, x0, stale_loop
    csrr    x21, mhpmcounter7
    CHECK_EQ x10, 4, 7
    CHECK_EQ x21, 5, 8

    TEST_PASS

fail_inline:
    /* x11 says which pass saw the stale instruction */
    addi    x11, x11, 1
    li      x31, 1
    slli    x11, x11, 1
    or      x31, x31, x11
    la      x30, tohost
    sw      x31, 0(x30)
1:  j       1b

smc_block:
    addi    x10, x10, 1000
    jalr    x0, 0(x6)

/* Before patching: a jump to stale_target, which returns to stale_back.
   After patching: an addi, followed by a jump back into the loop. */
stale_site:
    jal     x0, stale_target
    jal     x0, stale_ret
stale_target:
    jal     x0, stale_back

    .section .rodata
    .align 4
/* Instruction words the test patches in, assembled rather than hand-encoded. */
templates:
    addi    x10, x10, 1
    addi    x10, x10, 10
    addi    x10, x10, 100
