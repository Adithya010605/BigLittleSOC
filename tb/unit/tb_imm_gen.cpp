// ============================================================================
// tb_imm_gen.cpp — unit testbench for rtl/common/imm_gen.sv
//
// Coverage:
//   * all six formats (I/S/B/U/J/Z) against an independently-written C++ model
//   * sign extension at the boundary: immediate MSB set and clear
//   * the implicit zero LSB of the B and J formats
//   * the extremes of each field (most negative, most positive, zero)
//   * 50k random 32-bit instruction words per format
//
// The DUT port is instr[31:7], so the harness shifts the 32-bit instruction
// word right by 7 before driving it. The reference model works on the full
// 32-bit word, so the two never share an indexing mistake.
// ============================================================================
#include "Vimm_gen.h"
#include "tb_common.h"

#include <cinttypes>

// Must match imm_sel_e in rtl/common/e_core_pkg.sv.
enum ImmSel : uint8_t {
  IMM_I = 0,
  IMM_S = 1,
  IMM_B = 2,
  IMM_U = 3,
  IMM_J = 4,
  IMM_Z = 5,
};

// Extract bits [hi:lo] of v as an unsigned value.
static inline uint32_t Bits(uint32_t v, int hi, int lo) {
  return (v >> lo) & ((hi - lo) == 31 ? 0xFFFFFFFFu
                                      : ((1u << (hi - lo + 1)) - 1u));
}

// Sign-extend the low `bits` bits of v.
static inline uint32_t SignExtend(uint32_t v, int bits) {
  const uint32_t m = 1u << (bits - 1);
  return (v ^ m) - m;
}

// Reference model, transcribed from the RISC-V spec's immediate tables.
static uint32_t RefImm(ImmSel sel, uint32_t insn) {
  switch (sel) {
    case IMM_I:
      return SignExtend(Bits(insn, 31, 20), 12);
    case IMM_S:
      return SignExtend((Bits(insn, 31, 25) << 5) | Bits(insn, 11, 7), 12);
    case IMM_B:
      return SignExtend((Bits(insn, 31, 31) << 12) | (Bits(insn, 7, 7) << 11) |
                            (Bits(insn, 30, 25) << 5) |
                            (Bits(insn, 11, 8) << 1),
                        13);
    case IMM_U:
      return insn & 0xFFFFF000u;
    case IMM_J:
      return SignExtend((Bits(insn, 31, 31) << 20) |
                            (Bits(insn, 19, 12) << 12) |
                            (Bits(insn, 20, 20) << 11) |
                            (Bits(insn, 30, 21) << 1),
                        21);
    case IMM_Z:
      return Bits(insn, 19, 15);
  }
  return 0u;
}

static const struct { ImmSel sel; const char* name; } kFormats[] = {
    {IMM_I, "I"}, {IMM_S, "S"}, {IMM_B, "B"},
    {IMM_U, "U"}, {IMM_J, "J"}, {IMM_Z, "Z"},
};

static Vimm_gen* g_dut = nullptr;

static uint32_t Apply(ImmSel sel, const char* name, uint32_t insn) {
  g_dut->instr_i = insn >> 7;   // port is instr[31:7]
  g_dut->imm_sel_i = static_cast<uint8_t>(sel);
  g_dut->eval();
  char what[96];
  std::snprintf(what, sizeof(what), "IMM_%s(0x%08" PRIx32 ")", name, insn);
  tb::CheckEq<uint32_t>(what, g_dut->imm_o, RefImm(sel, insn));
  return g_dut->imm_o;
}

int main(int argc, char** argv) {
  const uint64_t seed = (argc > 1) ? std::strtoull(argv[1], nullptr, 0) : 0x11660u;
  std::printf("tb_imm_gen: seed=0x%" PRIx64 "\n", seed);

  Vimm_gen dut;
  g_dut = &dut;

  // ---------------- directed: sign extension boundary ----------------
  // instr[31] is the sign bit of every sign-extended format.
  Apply(IMM_I, "I", 0x80000000u);  // most negative I immediate
  Apply(IMM_I, "I", 0x7FF00000u);  // most positive I immediate (+2047)
  Apply(IMM_I, "I", 0x00000000u);  // zero
  Apply(IMM_I, "I", 0xFFF00000u);  // -1

  Apply(IMM_S, "S", 0xFE000F80u);  // sign bit set, both halves all ones
  Apply(IMM_S, "S", 0x7E000F80u);  // sign bit clear
  Apply(IMM_S, "S", 0x00000F80u);  // only the low field set
  Apply(IMM_S, "S", 0xFE000000u);  // only the high field set
  tb::Group("I and S sign extension boundaries");

  // ---------------- directed: B format and its implicit zero LSB ----------
  for (uint32_t insn : {0x80000000u, 0x7E000F80u, 0xFE000F80u, 0x00000080u,
                        0x40000000u, 0x00000F00u}) {
    const uint32_t imm = Apply(IMM_B, "B", insn);
    tb::CheckEq<uint32_t>("B immediate bit 0 is zero", imm & 1u, 0u);
  }
  tb::Group("B format, implicit zero LSB");

  // ---------------- directed: J format and its implicit zero LSB ----------
  for (uint32_t insn : {0x80000000u, 0x7FFFF000u, 0xFFFFF000u, 0x00100000u,
                        0x000FF000u, 0x7FE00000u}) {
    const uint32_t imm = Apply(IMM_J, "J", insn);
    tb::CheckEq<uint32_t>("J immediate bit 0 is zero", imm & 1u, 0u);
  }
  tb::Group("J format, implicit zero LSB");

  // ---------------- directed: U format ----------------
  Apply(IMM_U, "U", 0xFFFFF000u);
  Apply(IMM_U, "U", 0x80000000u);
  Apply(IMM_U, "U", 0x00001000u);
  Apply(IMM_U, "U", 0xFFFFFFFFu);   // low 12 bits must be discarded
  tb::Group("U format");

  // ---------------- directed: Z (CSR uimm) is zero-extended ----------------
  // The key property is that it must NOT sign-extend: uimm=31 gives 31, not -1.
  Apply(IMM_Z, "Z", 0x000F8000u);   // uimm field all ones -> 31
  Apply(IMM_Z, "Z", 0xFFFFFFFFu);   // everything set, still only 5 bits
  Apply(IMM_Z, "Z", 0x00008000u);   // uimm = 1
  Apply(IMM_Z, "Z", 0x00000000u);   // uimm = 0
  tb::Group("Z format is zero-extended, not sign-extended");

  // ---------------- exhaustive single-bit sweeps ----------------
  // One instruction bit at a time, every format. This catches a swapped or
  // dropped bit in any field, which random vectors can mask.
  for (int b = 7; b < 32; ++b) {
    const uint32_t insn = 1u << b;
    for (const auto& f : kFormats) Apply(f.sel, f.name, insn);
  }
  tb::Group("single-bit sweep across instr[31:7]");

  // ---------------- randomised ----------------
  tb::Rng rng(seed);
  const int kIters = 50000;
  for (int i = 0; i < kIters; ++i) {
    const uint32_t insn = rng.U32();
    const auto& f = kFormats[rng.U32() % 6];
    Apply(f.sel, f.name, insn);
  }
  tb::Group("50000 random instruction words");

  return tb::Report("imm_gen");
}
