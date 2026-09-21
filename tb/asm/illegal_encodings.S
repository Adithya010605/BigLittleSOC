/* ============================================================================
 * illegal_encodings.S — every reserved encoding inside an otherwise-valid
 * opcode must raise illegal-instruction with mtval = the instruction word.
 *
 * The decoder rejects these through per-opcode `default` arms that no other
 * test reaches: a program built by an assembler never emits them, and the
 * random generator only emits legal instructions. They are written here as
 * raw .word directives.
 * ============================================================================
 */
#include "test_macros.h"

    TEST_START

    la      t0, handler
    csrw    mtvec, t0
    la      x1, saved

/* Checks that the word at `insn` traps with cause 2 and mtval == the word. */
.macro EXPECT_ILLEGAL insn, code
    li      x5, \insn
    sw      x5, 12(x1)              /* remember what we are about to execute */
    .word   \insn
    lw      x6, 0(x1)               /* mcause */
    li      x7, 2
    CHECK_EQ_REG x6, x7, \code
    lw      x8, 4(x1)               /* mtval  */
    lw      x9, 12(x1)
    CHECK_EQ_REG x8, x9, (\code + 1)
.endm

    /* ---- LOAD with reserved funct3 (011, 110, 111) ---------------------- */
    EXPECT_ILLEGAL 0x0000B003, 1    /* funct3 = 011 */
    EXPECT_ILLEGAL 0x0000E003, 3    /* funct3 = 110 */
    EXPECT_ILLEGAL 0x0000F003, 5    /* funct3 = 111 */

    /* ---- STORE with reserved funct3 (011..111) -------------------------- */
    EXPECT_ILLEGAL 0x0000B023, 7    /* funct3 = 011 */
    EXPECT_ILLEGAL 0x0000C023, 9    /* funct3 = 100 */
    EXPECT_ILLEGAL 0x0000D023, 11   /* funct3 = 101 */
    EXPECT_ILLEGAL 0x0000E023, 13   /* funct3 = 110 */
    EXPECT_ILLEGAL 0x0000F023, 15   /* funct3 = 111 */

    /* ---- BRANCH with reserved funct3 (010, 011) ------------------------- */
    EXPECT_ILLEGAL 0x00002063, 17
    EXPECT_ILLEGAL 0x00003063, 19

    /* ---- JALR with funct3 != 0 ------------------------------------------ */
    EXPECT_ILLEGAL 0x00001067, 21
    EXPECT_ILLEGAL 0x00007067, 23

    /* ---- MISC-MEM with a funct3 that is neither FENCE nor FENCE.I ------- */
    EXPECT_ILLEGAL 0x0000200F, 25
    EXPECT_ILLEGAL 0x0000700F, 27

    /* ---- SYSTEM funct3 = 100 is reserved -------------------------------- */
    EXPECT_ILLEGAL 0x00004073, 29

    /* ---- SYSTEM funct3 = 0 but not a defined privileged instruction ----- */
    EXPECT_ILLEGAL 0x00200073, 31   /* ECALL-shaped, wrong imm */
    EXPECT_ILLEGAL 0x30300073, 33   /* MRET-shaped, wrong imm */
    EXPECT_ILLEGAL 0x10600073, 35   /* WFI-shaped, wrong imm */
    EXPECT_ILLEGAL 0x00001073, 37   /* CSRRW x0, 0, x0 -> CSR 0 unimplemented */

    /* ---- shift-immediate with a reserved funct7 ------------------------- */
    EXPECT_ILLEGAL 0x40001013, 39   /* slli with funct7 = 0100000 */
    EXPECT_ILLEGAL 0x02001013, 41   /* slli with funct7 = 0000001 */
    EXPECT_ILLEGAL 0x02005013, 43   /* srli with funct7 = 0000001 */
    EXPECT_ILLEGAL 0x60005013, 45   /* srli with funct7 = 0110000 */

    /* ---- register-register with a reserved funct7 ----------------------- */
    EXPECT_ILLEGAL 0x40001033, 47   /* sll with funct7 = 0100000 */
    EXPECT_ILLEGAL 0x40004033, 49   /* xor with funct7 = 0100000 */
    EXPECT_ILLEGAL 0x02000033, 51   /* mul  */
    EXPECT_ILLEGAL 0x02004033, 53   /* div  */
    EXPECT_ILLEGAL 0x0200C033, 55   /* divu */
    EXPECT_ILLEGAL 0x02007033, 57   /* remu */

    /* ---- reserved major opcodes ----------------------------------------- */
    EXPECT_ILLEGAL 0x0000007B, 59
    EXPECT_ILLEGAL 0x0000005B, 61
    EXPECT_ILLEGAL 0x00000053, 63   /* OP-FP: no floating point here */
    EXPECT_ILLEGAL 0x0000002F, 65   /* AMO: no atomics here */

    /* ---- 16-bit (compressed) encodings ---------------------------------- */
    EXPECT_ILLEGAL 0x00000000, 67   /* also the canonical all-zero word */
    EXPECT_ILLEGAL 0xFFFFFFFD, 69
    EXPECT_ILLEGAL 0xDEADBEEE, 71

    /* ---- FENCE and FENCE.I must NOT trap -------------------------------- */
    lw      x10, 8(x1)              /* trap count before */
    fence
    /* FENCE.I emitted as a raw word: naming it would require zifencei in the
       -march string, and this core's target ISA is deliberately rv32i_zicsr.
       The decoder accepts the encoding as a NOP either way, which is exactly
       what this check is asserting. */
    .word   0x0000100F
    lw      x11, 8(x1)              /* trap count after  */
    CHECK_EQ_REG x11, x10, 73

    TEST_PASS

/* saved[0]=mcause saved[1]=mtval saved[2]=count saved[3]=expected word */
    .align 4
handler:
    csrw    mscratch, x31
    la      x31, saved
    csrr    x30, mcause
    sw      x30, 0(x31)
    csrr    x30, mtval
    sw      x30, 4(x31)
    lw      x30, 8(x31)
    addi    x30, x30, 1
    sw      x30, 8(x31)
    csrr    x30, mepc
    addi    x30, x30, 4
    csrw    mepc, x30
    csrr    x31, mscratch
    mret

    TEST_DATA_SECTION
saved:
    .word   0, 0, 0, 0
