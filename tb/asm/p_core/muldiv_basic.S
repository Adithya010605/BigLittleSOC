/* ============================================================================
 * muldiv_basic.S — every M-extension instruction, with the operand values the
 * ISA special-cases and the ones that break multipliers and dividers.
 *
 * P-core only. Expected values were computed by an independent model (Python
 * integer arithmetic) when this file was written; they are literal constants
 * here, so nothing in the test depends on the hardware being tested.
 *
 * Also checked: rd = x0 discards the result; rd == rs1 == rs2 works; a result
 * written to one register does not disturb the operand registers.
 * ============================================================================
 */
#include "test_macros.h"

/* rd <- op(a, b), then check rd. a and b go through x5/x6 so every case
   uses the same operand registers and the result lands in x7. */
.macro MD op, a, b, expect, code
    li      x5, \a
    li      x6, \b
    \op     x7, x5, x6
    CHECK_EQ x7, \expect, \code
.endm

    TEST_START

    /* ---- mul ---- */
    MD mul, 0x00000007, 0x00000006, 0x0000002a, 1
    MD mul, 0xfffffff9, 0x00000006, 0xffffffd6, 2
    MD mul, 0x80000000, 0xffffffff, 0x80000000, 3
    MD mul, 0x12345678, 0x9abcdef0, 0x242d2080, 4
    MD mul, 0xffffffff, 0xffffffff, 0x00000001, 5
    MD mul, 0x00000000, 0x7fffffff, 0x00000000, 6
    MD mul, 0x00010000, 0x00010000, 0x00000000, 7

    /* ---- mulh ---- */
    MD mulh, 0x00000007, 0x00000006, 0x00000000, 8
    MD mulh, 0xfffffff9, 0x00000006, 0xffffffff, 9
    MD mulh, 0x80000000, 0x80000000, 0x40000000, 10
    MD mulh, 0x80000000, 0x7fffffff, 0xc0000000, 11
    MD mulh, 0xffffffff, 0xffffffff, 0x00000000, 12
    MD mulh, 0x12345678, 0x9abcdef0, 0xf8cc93d6, 13
    MD mulh, 0xffffffff, 0x00000001, 0xffffffff, 14

    /* ---- mulhsu ---- */
    MD mulhsu, 0xffffffff, 0xffffffff, 0xffffffff, 15
    MD mulhsu, 0x80000000, 0xffffffff, 0x80000000, 16
    MD mulhsu, 0x7fffffff, 0xffffffff, 0x7ffffffe, 17
    MD mulhsu, 0xffffffff, 0x00000001, 0xffffffff, 18
    MD mulhsu, 0x12345678, 0x9abcdef0, 0x0b00ea4e, 19
    MD mulhsu, 0xfffffffe, 0x80000000, 0xffffffff, 20

    /* ---- mulhu ---- */
    MD mulhu, 0xffffffff, 0xffffffff, 0xfffffffe, 21
    MD mulhu, 0x80000000, 0x80000000, 0x40000000, 22
    MD mulhu, 0x12345678, 0x9abcdef0, 0x0b00ea4e, 23
    MD mulhu, 0xffffffff, 0x00000001, 0x00000000, 24
    MD mulhu, 0x00010000, 0x00010000, 0x00000001, 25
    MD mulhu, 0x00000002, 0x80000000, 0x00000001, 26

    /* ---- div ---- */
    MD div, 0x00000014, 0x00000006, 0x00000003, 27
    MD div, 0xffffffec, 0x00000006, 0xfffffffd, 28
    MD div, 0x00000014, 0xfffffffa, 0xfffffffd, 29
    MD div, 0xffffffec, 0xfffffffa, 0x00000003, 30
    MD div, 0x80000000, 0xffffffff, 0x80000000, 31
    MD div, 0x00000005, 0x00000000, 0xffffffff, 32
    MD div, 0xfffffffb, 0x00000000, 0xffffffff, 33
    MD div, 0x00000000, 0x00000000, 0xffffffff, 34
    MD div, 0x80000000, 0x00000001, 0x80000000, 35
    MD div, 0x00000001, 0xffffffff, 0xffffffff, 36

    /* ---- divu ---- */
    MD divu, 0x00000014, 0x00000006, 0x00000003, 37
    MD divu, 0xffffffff, 0x00000001, 0xffffffff, 38
    MD divu, 0xffffffff, 0x00000002, 0x7fffffff, 39
    MD divu, 0x00000005, 0x00000000, 0xffffffff, 40
    MD divu, 0x80000000, 0xffffffff, 0x00000000, 41
    MD divu, 0xffffffff, 0xffffffff, 0x00000001, 42

    /* ---- rem ---- */
    MD rem, 0x00000014, 0x00000006, 0x00000002, 43
    MD rem, 0xffffffec, 0x00000006, 0xfffffffe, 44
    MD rem, 0x00000014, 0xfffffffa, 0x00000002, 45
    MD rem, 0xffffffec, 0xfffffffa, 0xfffffffe, 46
    MD rem, 0x80000000, 0xffffffff, 0x00000000, 47
    MD rem, 0x00000005, 0x00000000, 0x00000005, 48
    MD rem, 0xfffffffb, 0x00000000, 0xfffffffb, 49
    MD rem, 0x80000000, 0x00000003, 0xfffffffe, 50

    /* ---- remu ---- */
    MD remu, 0x00000014, 0x00000006, 0x00000002, 51
    MD remu, 0xffffffff, 0x00000007, 0x00000003, 52
    MD remu, 0x00000005, 0x00000000, 0x00000005, 53
    MD remu, 0x80000000, 0xffffffff, 0x80000000, 54
    MD remu, 0xffffffff, 0xffffffff, 0x00000000, 55
    MD remu, 0x12345678, 0x00000100, 0x00000078, 56

    /* ---- rd = x0: the result is discarded ---- */
    li      x5, 12345
    li      x6, 678
    mul     x0, x5, x6
    div     x0, x5, x6
    CHECK_EQ x0, 0, 57
    /* the operand registers are untouched */
    CHECK_EQ x5, 12345, 58
    CHECK_EQ x6, 678, 59

    /* ---- rd == rs1 == rs2 ---- */
    li      x8, 0x0000ffff
    mul     x8, x8, x8
    CHECK_EQ x8, 0xfffe0001, 60
    li      x9, 0x87654321
    mulhu   x9, x9, x9
    CHECK_EQ x9, 0x479bf4da, 61
    li      x10, 0x80000000
    div     x10, x10, x10
    CHECK_EQ x10, 1, 62
    li      x11, -7
    rem     x11, x11, x11
    CHECK_EQ x11, 0, 63

    TEST_PASS
