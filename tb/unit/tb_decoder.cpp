// ============================================================================
// tb_decoder.cpp — unit testbench for rtl/common/decoder.sv
//
// Coverage:
//   * every legal RV32I_Zicsr encoding, built programmatically, checked field
//     by field against a reference decoder written independently from the RTL
//     (transcribed from the ISA manual's opcode tables, not from decoder.sv)
//   * the reserved encodings that MUST trap: M-extension opcodes, reserved
//     funct3 values inside valid opcodes, bad funct7 on the shift-immediates,
//     malformed privileged instructions, compressed encodings, 0x00000000 and
//     0xFFFFFFFF
//   * the Zicsr read/write side-effect rules, which decide whether a CSR
//     access to a read-only register is legal
//   * a sweep of 2,000,000 random 32-bit words: anything the reference model
//     does not recognise must assert illegal_instr_o, and every instruction it
//     does recognise must produce a matching control bundle
//   * the safety property that an illegal instruction asserts NO enable of any
//     kind -- no register write, no memory request, no control transfer, no
//     CSR access, no privileged action
// ============================================================================
#include "Vdecoder.h"
#include "tb_common.h"

#include <cinttypes>
#include <cstring>
#include <vector>

// ---- encodings mirrored from rtl/common/e_core_pkg.sv ----
enum : uint8_t {
  ALU_SUB = 0x0, ALU_SLL = 0x1, ALU_SLT = 0x2, ALU_SLTU = 0x3, ALU_XOR = 0x4,
  ALU_SRL = 0x5, ALU_OR = 0x6, ALU_AND = 0x7, ALU_SRA = 0x8, ALU_ADD = 0xF,
};
enum : uint8_t { OP_A_RS1 = 0, OP_A_PC = 1, OP_A_ZERO = 2 };
enum : uint8_t { OP_B_RS2 = 0, OP_B_IMM = 1 };
enum : uint8_t { IMM_I = 0, IMM_S = 1, IMM_B = 2, IMM_U = 3, IMM_J = 4, IMM_Z = 5 };
enum : uint8_t { WB_ALU = 0, WB_MEM = 1, WB_PC4 = 2, WB_CSR = 3 };
enum : uint8_t { SZ_BYTE = 0, SZ_HALF = 1, SZ_WORD = 2 };
enum : uint8_t { CSR_OP_RW = 0, CSR_OP_RS = 1, CSR_OP_RC = 2 };

// ---------------------------------------------------------------------------
// Reference control bundle
// ---------------------------------------------------------------------------
struct Ctrl {
  uint8_t rs1_addr = 0, rs2_addr = 0, rd_addr = 0;
  bool rs1_used = false, rs2_used = false;
  uint8_t imm_sel = IMM_I;
  uint8_t alu_op = ALU_ADD;
  uint8_t op_a_sel = OP_A_RS1;
  uint8_t op_b_sel = OP_B_IMM;
  bool rf_we = false;
  uint8_t wb_sel = WB_ALU;
  bool mem_req = false, mem_we = false;
  uint8_t mem_size = SZ_WORD;
  bool mem_signed = false;
  bool is_branch = false, is_jump = false, is_jalr = false;
  bool csr_en = false, csr_use_imm = false, csr_read = false, csr_write = false;
  uint8_t csr_op = CSR_OP_RW;
  bool ecall = false, ebreak = false, mret = false, wfi = false, fence = false;
  bool illegal = false;
};

static inline uint32_t Field(uint32_t v, int hi, int lo) {
  return (v >> lo) & ((1u << (hi - lo + 1)) - 1u);
}

// Reference decoder. Written from the ISA manual's tables: opcode first, then
// funct3, then funct7. Deliberately structured differently from decoder.sv so
// the two do not share a transcription error.
static Ctrl RefDecode(uint32_t insn) {
  Ctrl c;
  const uint32_t opcode = Field(insn, 6, 0);
  const uint32_t funct3 = Field(insn, 14, 12);
  const uint32_t funct7 = Field(insn, 31, 25);
  c.rs1_addr = static_cast<uint8_t>(Field(insn, 19, 15));
  c.rs2_addr = static_cast<uint8_t>(Field(insn, 24, 20));
  c.rd_addr = static_cast<uint8_t>(Field(insn, 11, 7));

  auto illegal = [&]() {
    Ctrl bad;
    bad.rs1_addr = c.rs1_addr;
    bad.rs2_addr = c.rs2_addr;
    bad.rd_addr = c.rd_addr;
    bad.illegal = true;
    return bad;
  };

  if (Field(insn, 1, 0) != 3u) return illegal();   // compressed encoding

  // ALU operation shared by OP and OP-IMM.
  auto alu_from = [&](bool alt) -> uint8_t {
    switch (funct3) {
      case 0: return alt ? ALU_SUB : ALU_ADD;
      case 1: return ALU_SLL;
      case 2: return ALU_SLT;
      case 3: return ALU_SLTU;
      case 4: return ALU_XOR;
      case 5: return alt ? ALU_SRA : ALU_SRL;
      case 6: return ALU_OR;
      default: return ALU_AND;
    }
  };

  switch (opcode) {
    case 0x37:  // LUI
      c.imm_sel = IMM_U; c.op_a_sel = OP_A_ZERO; c.op_b_sel = OP_B_IMM;
      c.alu_op = ALU_ADD; c.rf_we = true; c.wb_sel = WB_ALU;
      return c;

    case 0x17:  // AUIPC
      c.imm_sel = IMM_U; c.op_a_sel = OP_A_PC; c.op_b_sel = OP_B_IMM;
      c.alu_op = ALU_ADD; c.rf_we = true; c.wb_sel = WB_ALU;
      return c;

    case 0x6F:  // JAL
      c.imm_sel = IMM_J; c.rf_we = true; c.wb_sel = WB_PC4; c.is_jump = true;
      return c;

    case 0x67:  // JALR
      if (funct3 != 0) return illegal();
      c.imm_sel = IMM_I; c.rs1_used = true; c.rf_we = true;
      c.wb_sel = WB_PC4; c.is_jump = true; c.is_jalr = true;
      return c;

    case 0x63:  // BRANCH
      if (funct3 == 2 || funct3 == 3) return illegal();
      c.imm_sel = IMM_B; c.rs1_used = true; c.rs2_used = true;
      c.is_branch = true;
      return c;

    case 0x03:  // LOAD
      if (funct3 == 3 || funct3 == 6 || funct3 == 7) return illegal();
      c.imm_sel = IMM_I; c.rs1_used = true; c.op_a_sel = OP_A_RS1;
      c.op_b_sel = OP_B_IMM; c.alu_op = ALU_ADD; c.rf_we = true;
      c.wb_sel = WB_MEM; c.mem_req = true; c.mem_we = false;
      c.mem_size = static_cast<uint8_t>(funct3 & 3u);
      c.mem_signed = ((funct3 >> 2) & 1u) == 0u;
      return c;

    case 0x23:  // STORE
      if (funct3 > 2) return illegal();
      c.imm_sel = IMM_S; c.rs1_used = true; c.rs2_used = true;
      c.op_a_sel = OP_A_RS1; c.op_b_sel = OP_B_IMM; c.alu_op = ALU_ADD;
      c.mem_req = true; c.mem_we = true;
      c.mem_size = static_cast<uint8_t>(funct3 & 3u);
      return c;

    case 0x13: {  // OP-IMM
      const bool alt = (funct7 == 0x20u);
      if (funct3 == 1 && funct7 != 0x00u) return illegal();           // SLLI
      if (funct3 == 5 && funct7 != 0x00u && funct7 != 0x20u) return illegal();
      c.imm_sel = IMM_I; c.rs1_used = true; c.op_a_sel = OP_A_RS1;
      c.op_b_sel = OP_B_IMM; c.rf_we = true; c.wb_sel = WB_ALU;
      // `alt` only selects SUB/SRA for the shift encodings; for the non-shift
      // OP-IMM forms instr[31:25] is part of the immediate, never a selector.
      c.alu_op = alu_from(alt && funct3 == 5);
      return c;
    }

    case 0x33: {  // OP
      if (funct7 == 0x20u) {
        if (funct3 != 0 && funct3 != 5) return illegal();
      } else if (funct7 != 0x00u) {
        return illegal();                     // includes the M extension
      }
      c.rs1_used = true; c.rs2_used = true; c.op_a_sel = OP_A_RS1;
      c.op_b_sel = OP_B_RS2; c.rf_we = true; c.wb_sel = WB_ALU;
      c.alu_op = alu_from(funct7 == 0x20u);
      return c;
    }

    case 0x0F:  // MISC-MEM
      if (funct3 != 0 && funct3 != 1) return illegal();
      c.fence = true;
      return c;

    case 0x73:  // SYSTEM
      if (funct3 == 0) {
        if (insn == 0x00000073u) { c.ecall = true; return c; }
        if (insn == 0x00100073u) { c.ebreak = true; return c; }
        if (insn == 0x30200073u) { c.mret = true; return c; }
        if (insn == 0x10500073u) { c.wfi = true; return c; }
        return illegal();
      }
      if (funct3 == 4) return illegal();
      c.csr_en = true; c.rf_we = true; c.wb_sel = WB_CSR; c.imm_sel = IMM_Z;
      c.csr_use_imm = ((funct3 >> 2) & 1u) != 0u;
      c.rs1_used = !c.csr_use_imm;
      switch (funct3 & 3u) {
        case 1: c.csr_op = CSR_OP_RW; break;
        case 2: c.csr_op = CSR_OP_RS; break;
        default: c.csr_op = CSR_OP_RC; break;
      }
      if ((funct3 & 3u) == 1u) {              // CSRRW / CSRRWI
        c.csr_write = true;
        c.csr_read = (c.rd_addr != 0);
      } else {                                 // CSRRS/C and immediate forms
        c.csr_read = true;
        c.csr_write = (c.rs1_addr != 0);
      }
      return c;

    default:
      return illegal();
  }
}

// ---------------------------------------------------------------------------
static Vdecoder* g_dut = nullptr;

static void CheckInsn(uint32_t insn, const char* tag) {
  g_dut->instr_i = insn;
  g_dut->eval();
  const Ctrl r = RefDecode(insn);

  char w[192];
  auto eq = [&](const char* field, uint64_t got, uint64_t exp) {
    std::snprintf(w, sizeof(w), "%s 0x%08" PRIx32 " %s", tag, insn, field);
    tb::CheckEq<uint64_t>(w, got, exp);
  };

  eq("illegal", g_dut->illegal_instr_o, r.illegal ? 1u : 0u);

  // Register addresses and the CSR address are pure field extractions and are
  // valid regardless of legality.
  eq("rs1_addr", g_dut->rs1_addr_o, r.rs1_addr);
  eq("rs2_addr", g_dut->rs2_addr_o, r.rs2_addr);
  eq("rd_addr", g_dut->rd_addr_o, r.rd_addr);
  eq("csr_addr", g_dut->csr_addr_o, Field(insn, 31, 20));
  eq("br_op", g_dut->br_op_o, Field(insn, 14, 12));

  // Enables must be correct for BOTH legal and illegal instructions: for an
  // illegal one they must all be zero, which is the property that stops a
  // trapping instruction from also committing a side effect.
  eq("rs1_used", g_dut->rs1_used_o, r.rs1_used ? 1u : 0u);
  eq("rs2_used", g_dut->rs2_used_o, r.rs2_used ? 1u : 0u);
  eq("rf_we", g_dut->rf_we_o, r.rf_we ? 1u : 0u);
  eq("mem_req", g_dut->mem_req_o, r.mem_req ? 1u : 0u);
  eq("mem_we", g_dut->mem_we_o, r.mem_we ? 1u : 0u);
  eq("is_branch", g_dut->is_branch_o, r.is_branch ? 1u : 0u);
  eq("is_jump", g_dut->is_jump_o, r.is_jump ? 1u : 0u);
  eq("is_jalr", g_dut->is_jalr_o, r.is_jalr ? 1u : 0u);
  eq("csr_en", g_dut->csr_en_o, r.csr_en ? 1u : 0u);
  eq("csr_read", g_dut->csr_read_o, r.csr_read ? 1u : 0u);
  eq("csr_write", g_dut->csr_write_o, r.csr_write ? 1u : 0u);
  eq("ecall", g_dut->ecall_o, r.ecall ? 1u : 0u);
  eq("ebreak", g_dut->ebreak_o, r.ebreak ? 1u : 0u);
  eq("mret", g_dut->mret_o, r.mret ? 1u : 0u);
  eq("wfi", g_dut->wfi_o, r.wfi ? 1u : 0u);
  eq("fence", g_dut->fence_o, r.fence ? 1u : 0u);

  // The datapath selects only carry meaning for a legal instruction; an
  // illegal one traps before they are used.
  if (!r.illegal) {
    eq("imm_sel", g_dut->imm_sel_o, r.imm_sel);
    eq("alu_op", g_dut->alu_op_o, r.alu_op);
    eq("op_a_sel", g_dut->op_a_sel_o, r.op_a_sel);
    eq("op_b_sel", g_dut->op_b_sel_o, r.op_b_sel);
    eq("wb_sel", g_dut->wb_sel_o, r.wb_sel);
    if (r.mem_req) {
      eq("mem_size", g_dut->mem_size_o, r.mem_size);
      eq("mem_signed", g_dut->mem_signed_o, r.mem_signed ? 1u : 0u);
    }
    if (r.csr_en) {
      eq("csr_op", g_dut->csr_op_o, r.csr_op);
      eq("csr_use_imm", g_dut->csr_use_imm_o, r.csr_use_imm ? 1u : 0u);
    }
  }
}

// ---- instruction builders ----
static uint32_t R(uint32_t f7, uint32_t rs2, uint32_t rs1, uint32_t f3,
                  uint32_t rd, uint32_t op) {
  return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
}
static uint32_t I(uint32_t imm, uint32_t rs1, uint32_t f3, uint32_t rd,
                  uint32_t op) {
  return ((imm & 0xFFFu) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
}
static uint32_t S(uint32_t imm, uint32_t rs2, uint32_t rs1, uint32_t f3,
                  uint32_t op) {
  return (((imm >> 5) & 0x7Fu) << 25) | (rs2 << 20) | (rs1 << 15) |
         (f3 << 12) | ((imm & 0x1Fu) << 7) | op;
}
static uint32_t U(uint32_t imm, uint32_t rd, uint32_t op) {
  return (imm & 0xFFFFF000u) | (rd << 7) | op;
}

int main(int argc, char** argv) {
  const uint64_t seed = (argc > 1) ? std::strtoull(argv[1], nullptr, 0) : 0xDEC0u;
  std::printf("tb_decoder: seed=0x%" PRIx64 "\n", seed);

  Vdecoder dut;
  g_dut = &dut;

  // ---------------- legal: U and J types ----------------
  for (uint32_t rd = 0; rd < 32; rd += 7) {
    CheckInsn(U(0xABCDE000u, rd, 0x37), "LUI");
    CheckInsn(U(0x80000000u, rd, 0x17), "AUIPC");
    CheckInsn((0xFFFFF000u & 0xFFFFF000u) | (rd << 7) | 0x6Fu, "JAL");
    CheckInsn(I(0x123u, 5, 0, rd, 0x67), "JALR");
  }
  tb::Group("LUI / AUIPC / JAL / JALR");

  // ---------------- legal: branches ----------------
  for (uint32_t f3 : {0u, 1u, 4u, 5u, 6u, 7u}) {
    CheckInsn(R(0x00, 3, 2, f3, 0x08, 0x63), "BRANCH");
  }
  tb::Group("all six branch conditions");

  // ---------------- legal: loads and stores ----------------
  for (uint32_t f3 : {0u, 1u, 2u, 4u, 5u}) {
    CheckInsn(I(0x010u, 6, f3, 7, 0x03), "LOAD");
  }
  for (uint32_t f3 : {0u, 1u, 2u}) {
    CheckInsn(S(0x020u, 9, 8, f3, 0x23), "STORE");
  }
  tb::Group("all load and store widths");

  // ---------------- legal: OP-IMM ----------------
  for (uint32_t f3 : {0u, 2u, 3u, 4u, 6u, 7u}) {
    CheckInsn(I(0x7FFu, 1, f3, 2, 0x13), "OP-IMM");
    CheckInsn(I(0x800u, 1, f3, 2, 0x13), "OP-IMM neg");
  }
  for (uint32_t sh = 0; sh < 32; ++sh) {
    CheckInsn(R(0x00, sh, 1, 1, 2, 0x13), "SLLI");
    CheckInsn(R(0x00, sh, 1, 5, 2, 0x13), "SRLI");
    CheckInsn(R(0x20, sh, 1, 5, 2, 0x13), "SRAI");
  }
  tb::Group("all OP-IMM forms including the three shift-immediates");

  // ---------------- legal: OP ----------------
  for (uint32_t f3 = 0; f3 < 8; ++f3) {
    CheckInsn(R(0x00, 3, 2, f3, 1, 0x33), "OP");
  }
  CheckInsn(R(0x20, 3, 2, 0, 1, 0x33), "SUB");
  CheckInsn(R(0x20, 3, 2, 5, 1, 0x33), "SRA");
  tb::Group("all OP forms including SUB and SRA");

  // ---------------- legal: FENCE, FENCE.I ----------------
  CheckInsn(0x0FF0000Fu, "FENCE");
  CheckInsn(0x0000100Fu, "FENCE.I");
  tb::Group("FENCE and FENCE.I decode as NOP, not as a trap");

  // ---------------- legal: privileged ----------------
  CheckInsn(0x00000073u, "ECALL");
  CheckInsn(0x00100073u, "EBREAK");
  CheckInsn(0x30200073u, "MRET");
  CheckInsn(0x10500073u, "WFI");
  tb::Group("ECALL / EBREAK / MRET / WFI");

  // ---------------- legal: Zicsr, with the side-effect rules ----------------
  for (uint32_t f3 : {1u, 2u, 3u, 5u, 6u, 7u}) {
    for (uint32_t rs1 : {0u, 1u, 31u}) {
      for (uint32_t rd : {0u, 1u, 31u}) {
        CheckInsn(I(0x305u, rs1, f3, rd, 0x73), "CSR");
      }
    }
  }
  tb::Group("Zicsr read/write side-effect rules over rs1 and rd = x0");

  // ---------------- illegal: the M extension ----------------
  for (uint32_t f3 = 0; f3 < 8; ++f3) {
    CheckInsn(R(0x01, 3, 2, f3, 1, 0x33), "M-ext");
  }
  tb::Group("MUL/MULH/DIV/REM raise illegal-instruction");

  // ---------------- illegal: reserved funct3 in valid opcodes ----------------
  CheckInsn(R(0x00, 3, 2, 2, 8, 0x63), "BRANCH f3=2");
  CheckInsn(R(0x00, 3, 2, 3, 8, 0x63), "BRANCH f3=3");
  CheckInsn(I(0x010u, 6, 3, 7, 0x03), "LOAD f3=3");
  CheckInsn(I(0x010u, 6, 6, 7, 0x03), "LOAD f3=6");
  CheckInsn(I(0x010u, 6, 7, 7, 0x03), "LOAD f3=7");
  for (uint32_t f3 : {3u, 4u, 5u, 6u, 7u}) {
    CheckInsn(S(0x020u, 9, 8, f3, 0x23), "STORE bad f3");
  }
  CheckInsn(I(0x000u, 6, 1, 7, 0x67), "JALR f3!=0");
  CheckInsn(I(0x000u, 6, 2, 7, 0x0F), "MISC-MEM f3=2");
  CheckInsn(I(0x000u, 6, 4, 7, 0x73), "SYSTEM f3=4");
  tb::Group("reserved funct3 values trap");

  // ---------------- illegal: bad funct7 on shift-immediates ----------------
  CheckInsn(R(0x01, 4, 1, 1, 2, 0x13), "SLLI bad f7");
  CheckInsn(R(0x20, 4, 1, 1, 2, 0x13), "SLLI f7=0x20");
  CheckInsn(R(0x01, 4, 1, 5, 2, 0x13), "SRLI bad f7");
  CheckInsn(R(0x10, 4, 1, 5, 2, 0x13), "SRxI f7=0x10");
  // ...but the non-shift OP-IMM forms accept any instr[31:25] as immediate.
  CheckInsn(R(0x20, 4, 1, 0, 2, 0x13), "ADDI with f7-looking imm");
  CheckInsn(R(0x01, 4, 1, 7, 2, 0x13), "ANDI with f7-looking imm");
  tb::Group("shift-immediate funct7 checked, other OP-IMM immediates not");

  // ---------------- illegal: malformed privileged instructions ----------------
  CheckInsn(0x00200073u, "SYSTEM f3=0 bad");
  CheckInsn(0x30100073u, "MRET-like bad");
  CheckInsn(0x00001073u & ~0x7000u, "SYSTEM f3=0 rs1!=0");
  CheckInsn(0x10500074u, "WFI wrong opcode");
  tb::Group("malformed privileged encodings trap");

  // ---------------- illegal: the classic bad words ----------------
  CheckInsn(0x00000000u, "all zeros");
  CheckInsn(0xFFFFFFFFu, "all ones");
  for (uint32_t low = 0; low < 3; ++low) {
    CheckInsn(0xDEADBEE0u | low, "compressed encoding");
  }
  tb::Group("0x00000000, 0xFFFFFFFF and compressed encodings trap");

  // ---------------- random sweep ----------------
  tb::Rng rng(seed);
  const int kRandom = 2000000;
  int legal_seen = 0;
  for (int i = 0; i < kRandom; ++i) {
    uint32_t insn = rng.U32();
    // Bias half the vectors towards well-formed 32-bit encodings so the sweep
    // spends real effort on the legal space, not only on the trap path.
    if (i & 1) insn |= 3u;
    CheckInsn(insn, "rand");
    if (!RefDecode(insn).illegal) ++legal_seen;
  }
  std::printf("  random sweep: %d of %d words were legal instructions\n",
              legal_seen, kRandom);
  tb::Check(legal_seen > kRandom / 100,
            "random sweep produced too few legal instructions to be meaningful");
  tb::Group("2000000 random instruction words");

  return tb::Report("decoder");
}
