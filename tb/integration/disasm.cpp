#include "disasm.h"

#include <cstdarg>
#include <cstdio>

namespace {

const char* kRegNames[32] = {
    "zero", "ra", "sp", "gp", "tp",  "t0",  "t1", "t2",
    "s0",   "s1", "a0", "a1", "a2",  "a3",  "a4", "a5",
    "a6",   "a7", "s2", "s3", "s4",  "s5",  "s6", "s7",
    "s8",   "s9", "s10", "s11", "t3", "t4", "t5", "t6"};

inline uint32_t Bits(uint32_t v, int hi, int lo) {
  return (v >> lo) & ((hi - lo == 31) ? 0xFFFFFFFFu : ((1u << (hi - lo + 1)) - 1u));
}
inline int32_t SignExtend(uint32_t v, int bits) {
  const uint32_t m = 1u << (bits - 1);
  return static_cast<int32_t>((v ^ m) - m);
}

std::string Fmt(const char* f, ...) {
  char buf[160];
  va_list ap;
  va_start(ap, f);
  vsnprintf(buf, sizeof(buf), f, ap);
  va_end(ap);
  return std::string(buf);
}

const char* CsrName(uint32_t a) {
  switch (a) {
    case 0x300: return "mstatus";
    case 0x301: return "misa";
    case 0x304: return "mie";
    case 0x305: return "mtvec";
    case 0x320: return "mcountinhibit";
    case 0x340: return "mscratch";
    case 0x341: return "mepc";
    case 0x342: return "mcause";
    case 0x343: return "mtval";
    case 0x344: return "mip";
    case 0xB00: return "mcycle";
    case 0xB02: return "minstret";
    case 0xB03: return "mhpmcounter3";
    case 0xB04: return "mhpmcounter4";
    case 0xB05: return "mhpmcounter5";
    case 0xB06: return "mhpmcounter6";
    case 0xB80: return "mcycleh";
    case 0xB82: return "minstreth";
    case 0xF11: return "mvendorid";
    case 0xF12: return "marchid";
    case 0xF13: return "mimpid";
    case 0xF14: return "mhartid";
    default: return nullptr;
  }
}

}  // namespace

std::string Disassemble(uint32_t insn, uint32_t pc) {
  const uint32_t op = Bits(insn, 6, 0);
  const uint32_t rd = Bits(insn, 11, 7);
  const uint32_t f3 = Bits(insn, 14, 12);
  const uint32_t rs1 = Bits(insn, 19, 15);
  const uint32_t rs2 = Bits(insn, 24, 20);
  const uint32_t f7 = Bits(insn, 31, 25);
  const char* xd = kRegNames[rd];
  const char* x1 = kRegNames[rs1];
  const char* x2 = kRegNames[rs2];

  if ((insn & 3u) != 3u) return Fmt(".2byte 0x%04x", insn & 0xFFFFu);

  switch (op) {
    case 0x37: return Fmt("lui    %s, 0x%x", xd, Bits(insn, 31, 12));
    case 0x17: return Fmt("auipc  %s, 0x%x", xd, Bits(insn, 31, 12));
    case 0x6F: {
      const int32_t imm = SignExtend((Bits(insn, 31, 31) << 20) |
                                         (Bits(insn, 19, 12) << 12) |
                                         (Bits(insn, 20, 20) << 11) |
                                         (Bits(insn, 30, 21) << 1),
                                     21);
      return Fmt("jal    %s, 0x%08x", xd, pc + static_cast<uint32_t>(imm));
    }
    case 0x67:
      return Fmt("jalr   %s, %d(%s)", xd, SignExtend(Bits(insn, 31, 20), 12), x1);
    case 0x63: {
      static const char* n[8] = {"beq", "bne", "?", "?", "blt", "bge", "bltu", "bgeu"};
      const int32_t imm = SignExtend((Bits(insn, 31, 31) << 12) |
                                         (Bits(insn, 7, 7) << 11) |
                                         (Bits(insn, 30, 25) << 5) |
                                         (Bits(insn, 11, 8) << 1),
                                     13);
      return Fmt("%-6s %s, %s, 0x%08x", n[f3], x1, x2,
                 pc + static_cast<uint32_t>(imm));
    }
    case 0x03: {
      static const char* n[8] = {"lb", "lh", "lw", "?", "lbu", "lhu", "?", "?"};
      return Fmt("%-6s %s, %d(%s)", n[f3], xd,
                 SignExtend(Bits(insn, 31, 20), 12), x1);
    }
    case 0x23: {
      static const char* n[8] = {"sb", "sh", "sw", "?", "?", "?", "?", "?"};
      const int32_t imm =
          SignExtend((Bits(insn, 31, 25) << 5) | Bits(insn, 11, 7), 12);
      return Fmt("%-6s %s, %d(%s)", n[f3], x2, imm, x1);
    }
    case 0x13: {
      static const char* n[8] = {"addi", "slli", "slti", "sltiu",
                                 "xori", "srli", "ori",  "andi"};
      if (f3 == 1) return Fmt("slli   %s, %s, %u", xd, x1, rs2);
      if (f3 == 5)
        return Fmt("%-6s %s, %s, %u", (f7 == 0x20) ? "srai" : "srli", xd, x1, rs2);
      return Fmt("%-6s %s, %s, %d", n[f3], xd, x1,
                 SignExtend(Bits(insn, 31, 20), 12));
    }
    case 0x33: {
      static const char* n[8] = {"add", "sll", "slt", "sltu",
                                 "xor", "srl", "or",  "and"};
      const char* name = n[f3];
      if (f7 == 0x20 && f3 == 0) name = "sub";
      if (f7 == 0x20 && f3 == 5) name = "sra";
      if (f7 == 0x01) {
        static const char* m[8] = {"mul", "mulh", "mulhsu", "mulhu",
                                   "div", "divu", "rem",    "remu"};
        return Fmt("%-6s %s, %s, %s   <M-ext: illegal on this core>", m[f3], xd,
                   x1, x2);
      }
      return Fmt("%-6s %s, %s, %s", name, xd, x1, x2);
    }
    case 0x0F:
      return (f3 == 1) ? std::string("fence.i") : std::string("fence");
    case 0x73: {
      if (insn == 0x00000073u) return "ecall";
      if (insn == 0x00100073u) return "ebreak";
      if (insn == 0x30200073u) return "mret";
      if (insn == 0x10500073u) return "wfi";
      static const char* n[8] = {"?",      "csrrw",  "csrrs",  "csrrc",
                                 "?",      "csrrwi", "csrrsi", "csrrci"};
      const uint32_t csr = Bits(insn, 31, 20);
      const char* cn = CsrName(csr);
      char csrbuf[24];
      if (cn == nullptr) {
        std::snprintf(csrbuf, sizeof(csrbuf), "0x%03x", csr);
        cn = csrbuf;
      }
      if (f3 >= 5) return Fmt("%-6s %s, %s, %u", n[f3], xd, cn, rs1);
      if (f3 >= 1) return Fmt("%-6s %s, %s, %s", n[f3], xd, cn, x1);
      return Fmt("system 0x%08x", insn);
    }
    default:
      return Fmt(".word  0x%08x", insn);
  }
}
