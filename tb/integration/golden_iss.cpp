#include "golden_iss.h"

#include <cstdio>
#include <cstring>

namespace {

inline uint32_t Bits(uint32_t v, int hi, int lo) {
  return (v >> lo) & ((hi - lo == 31) ? 0xFFFFFFFFu : ((1u << (hi - lo + 1)) - 1u));
}
inline int32_t Sext(uint32_t v, int bits) {
  const uint32_t m = 1u << (bits - 1);
  return static_cast<int32_t>((v ^ m) - m);
}

// Cause codes, matching rtl/common/e_core_pkg.sv.
constexpr uint32_t kExcInstrMisaligned = 0;
constexpr uint32_t kExcIllegal = 2;
constexpr uint32_t kExcBreakpoint = 3;
constexpr uint32_t kExcLoadMisaligned = 4;
constexpr uint32_t kExcLoadAccess = 5;
constexpr uint32_t kExcStoreMisaligned = 6;
constexpr uint32_t kExcStoreAccess = 7;
constexpr uint32_t kExcEcallM = 11;

}  // namespace

bool GoldenIss::Load(const ElfImage& elf, std::string* error) {
  mem_.assign(kRamSize / 4, 0u);
  for (const ElfSegment& seg : elf.segments()) {
    if (seg.paddr + seg.memsz > kRamSize) {
      *error = "golden ISS: segment runs past the end of memory";
      return false;
    }
    for (size_t i = 0; i < seg.data.size(); ++i) {
      const uint32_t a = seg.paddr + static_cast<uint32_t>(i);
      uint32_t& w = mem_[a >> 2];
      const int sh = 8 * static_cast<int>(a & 3u);
      w = (w & ~(0xFFu << sh)) | (static_cast<uint32_t>(seg.data[i]) << sh);
    }
    for (uint32_t i = static_cast<uint32_t>(seg.data.size()); i < seg.memsz; ++i) {
      const uint32_t a = seg.paddr + i;
      mem_[a >> 2] &= ~(0xFFu << (8 * static_cast<int>(a & 3u)));
    }
  }
  if (!elf.Symbol("tohost", &tohost_addr_)) {
    *error = "golden ISS: the ELF has no `tohost` symbol";
    return false;
  }
  tohost_known_ = true;
  pc_ = elf.entry();
  std::memset(x_, 0, sizeof(x_));
  return true;
}

uint32_t GoldenIss::Load32(uint32_t addr, bool* err) const {
  const uint32_t a = addr & ~3u;
  *err = false;
  if (a < kRamSize) return mem_[a >> 2];
  if (a == kUartData || a == kUartStatus) return 0u;
  *err = true;
  return 0u;
}

void GoldenIss::Store32(uint32_t addr, uint32_t value, uint8_t be, bool* err) {
  const uint32_t a = addr & ~3u;
  *err = false;

  if (a == kUartData) {
    for (int lane = 0; lane < 4; ++lane) {
      if (be & (1u << lane)) {
        uart_out_.push_back(static_cast<char>((value >> (8 * lane)) & 0xFFu));
        break;
      }
    }
    return;
  }
  if (a == kUartStatus) return;
  if (a >= kRamSize) {
    *err = true;
    return;
  }

  uint32_t w = mem_[a >> 2];
  for (int lane = 0; lane < 4; ++lane) {
    if (be & (1u << lane)) {
      w = (w & ~(0xFFu << (8 * lane))) |
          (((value >> (8 * lane)) & 0xFFu) << (8 * lane));
    }
  }
  mem_[a >> 2] = w;

  if (tohost_known_ && a == (tohost_addr_ & ~3u) && w != 0u) {
    tohost_raw_ = w;
    exited_ = true;
  }
}

// True for an implemented event counter, either half: mhpmcounter3 .. and
// mhpmcounter3h .., num_hpm_ of each.
bool GoldenIss::IsHpm(uint32_t addr) const {
  const uint32_t n = static_cast<uint32_t>(num_hpm_);
  return (addr >= 0xB03u && addr < 0xB03u + n) ||
         (addr >= 0xB83u && addr < 0xB83u + n);
}

// The M extension, written directly from the ISA manual's definitions using
// 64-bit host arithmetic -- deliberately nothing like the RTL's Booth
// multiplier or restoring divider, so the two cannot share a mistake.
uint32_t GoldenIss::MulDiv(uint32_t f3, uint32_t a, uint32_t b) {
  const int64_t sa = static_cast<int32_t>(a);
  const int64_t sb = static_cast<int32_t>(b);
  const uint64_t ua = a;
  const uint64_t ub = b;
  switch (f3) {
    case 0:  // MUL
      return static_cast<uint32_t>(ua * ub);
    case 1:  // MULH
      return static_cast<uint32_t>(static_cast<uint64_t>(sa * sb) >> 32);
    case 2:  // MULHSU
      return static_cast<uint32_t>(static_cast<uint64_t>(sa * static_cast<int64_t>(ub)) >> 32);
    case 3:  // MULHU
      return static_cast<uint32_t>((ua * ub) >> 32);
    case 4:  // DIV
      if (b == 0) return 0xFFFFFFFFu;
      if (a == 0x80000000u && b == 0xFFFFFFFFu) return 0x80000000u;
      return static_cast<uint32_t>(static_cast<int32_t>(sa / sb));
    case 5:  // DIVU
      if (b == 0) return 0xFFFFFFFFu;
      return a / b;
    case 6:  // REM
      if (b == 0) return a;
      if (a == 0x80000000u && b == 0xFFFFFFFFu) return 0u;
      return static_cast<uint32_t>(static_cast<int32_t>(sa % sb));
    default:  // REMU
      if (b == 0) return a;
      return a % b;
  }
}

uint32_t GoldenIss::CsrRead(uint32_t addr, bool* illegal) const {
  *illegal = false;
  if (IsHpm(addr)) return 0u;   // event counters: not predictable
  switch (addr) {
    case 0x300: return (mstatus_mie_ << 3) | (mstatus_mpie_ << 7) | 0x1800u;
    case 0x301: return rv32m_ ? 0x40001100u : 0x40000100u;   // misa
    case 0x304: return mie_;
    case 0x305: return mtvec_;
    case 0x320: return 0u;            // mcountinhibit
    case 0x340: return mscratch_;
    case 0x341: return mepc_;
    case 0x342: return mcause_;
    case 0x343: return mtval_;
    case 0x344: return 0u;            // mip: no interrupts in lockstep runs
    case 0xB00: return static_cast<uint32_t>(mcycle_);
    case 0xB02: return static_cast<uint32_t>(minstret_);
    case 0xB80: case 0xB82:
      return 0u;
    case 0xF11: case 0xF12: case 0xF13: case 0xF14: return 0u;
    default:
      *illegal = true;
      return 0u;
  }
}

void GoldenIss::CsrWrite(uint32_t addr, uint32_t value, bool* illegal) {
  *illegal = false;
  if (IsHpm(addr)) return;
  switch (addr) {
    case 0x300:
      mstatus_mie_ = (value >> 3) & 1u;
      mstatus_mpie_ = (value >> 7) & 1u;
      break;
    case 0x304: mie_ = value & 0x888u; break;
    case 0x305: mtvec_ = value & ~3u; break;
    case 0x320: break;
    case 0x340: mscratch_ = value; break;
    case 0x341: mepc_ = value & ~1u; break;
    case 0x342: mcause_ = value; break;
    case 0x343: mtval_ = value; break;
    case 0xB00: mcycle_ = (mcycle_ & 0xFFFFFFFF00000000ull) | value; break;
    case 0xB02: minstret_ = (minstret_ & 0xFFFFFFFF00000000ull) | value; break;
    case 0xB80: case 0xB82:
      break;
    // Read-only: 0x301 misa, 0x344 mip, 0xF1x identification.
    case 0x301: case 0x344:
    case 0xF11: case 0xF12: case 0xF13: case 0xF14:
      *illegal = true;
      break;
    default:
      *illegal = true;
      break;
  }
}

void GoldenIss::EnterTrap(uint32_t cause, uint32_t tval, uint32_t epc) {
  mepc_ = epc & ~1u;
  mcause_ = cause;
  mtval_ = tval;
  mstatus_mpie_ = mstatus_mie_;
  mstatus_mie_ = 0;
  pc_ = mtvec_;
}

IssStep GoldenIss::Step() {
  IssStep s;
  s.pc = pc_;
  ++mcycle_;

  bool err = false;
  const uint32_t insn = Load32(pc_, &err);
  s.insn = insn;

  auto trap = [&](uint32_t cause, uint32_t tval) {
    s.trap = true;
    s.cause = cause;
    EnterTrap(cause, tval, s.pc);
    s.pc_next = pc_;
  };

  if (err) {
    trap(1u, pc_);   // instruction access fault
    return s;
  }

  const uint32_t opcode = Bits(insn, 6, 0);
  const uint32_t rd = Bits(insn, 11, 7);
  const uint32_t f3 = Bits(insn, 14, 12);
  const uint32_t rs1 = Bits(insn, 19, 15);
  const uint32_t rs2 = Bits(insn, 24, 20);
  const uint32_t f7 = Bits(insn, 31, 25);
  const uint32_t a = reg(static_cast<int>(rs1));
  const uint32_t b = reg(static_cast<int>(rs2));

  uint32_t next_pc = pc_ + 4;
  bool writes_rd = false;
  uint32_t rd_val = 0;

  auto alu = [&](uint32_t lhs, uint32_t rhs, bool alt) -> uint32_t {
    switch (f3) {
      case 0: return alt ? (lhs - rhs) : (lhs + rhs);
      case 1: return lhs << (rhs & 31u);
      case 2: return (static_cast<int32_t>(lhs) < static_cast<int32_t>(rhs)) ? 1u : 0u;
      case 3: return (lhs < rhs) ? 1u : 0u;
      case 4: return lhs ^ rhs;
      case 5: return alt ? static_cast<uint32_t>(static_cast<int32_t>(lhs) >> (rhs & 31u))
                         : (lhs >> (rhs & 31u));
      case 6: return lhs | rhs;
      default: return lhs & rhs;
    }
  };

  if ((insn & 3u) != 3u) {
    trap(kExcIllegal, insn);
    return s;
  }

  switch (opcode) {
    case 0x37:  // LUI
      rd_val = insn & 0xFFFFF000u; writes_rd = true; break;
    case 0x17:  // AUIPC
      rd_val = pc_ + (insn & 0xFFFFF000u); writes_rd = true; break;

    case 0x6F: {  // JAL
      const int32_t imm = Sext((Bits(insn, 31, 31) << 20) |
                                   (Bits(insn, 19, 12) << 12) |
                                   (Bits(insn, 20, 20) << 11) |
                                   (Bits(insn, 30, 21) << 1), 21);
      const uint32_t target = pc_ + static_cast<uint32_t>(imm);
      if (target & 3u) { trap(kExcInstrMisaligned, target); return s; }
      rd_val = pc_ + 4; writes_rd = true; next_pc = target;
      break;
    }
    case 0x67: {  // JALR
      if (f3 != 0) { trap(kExcIllegal, insn); return s; }
      const uint32_t target = (a + static_cast<uint32_t>(Sext(Bits(insn, 31, 20), 12))) & ~1u;
      if (target & 3u) { trap(kExcInstrMisaligned, target); return s; }
      rd_val = pc_ + 4; writes_rd = true; next_pc = target;
      break;
    }

    case 0x63: {  // BRANCH
      if (f3 == 2 || f3 == 3) { trap(kExcIllegal, insn); return s; }
      bool taken = false;
      switch (f3) {
        case 0: taken = (a == b); break;
        case 1: taken = (a != b); break;
        case 4: taken = static_cast<int32_t>(a) < static_cast<int32_t>(b); break;
        case 5: taken = static_cast<int32_t>(a) >= static_cast<int32_t>(b); break;
        case 6: taken = a < b; break;
        default: taken = a >= b; break;
      }
      if (taken) {
        const int32_t imm = Sext((Bits(insn, 31, 31) << 12) |
                                     (Bits(insn, 7, 7) << 11) |
                                     (Bits(insn, 30, 25) << 5) |
                                     (Bits(insn, 11, 8) << 1), 13);
        const uint32_t target = pc_ + static_cast<uint32_t>(imm);
        if (target & 3u) { trap(kExcInstrMisaligned, target); return s; }
        next_pc = target;
      }
      break;
    }

    case 0x03: {  // LOAD
      if (f3 == 3 || f3 == 6 || f3 == 7) { trap(kExcIllegal, insn); return s; }
      const uint32_t addr = a + static_cast<uint32_t>(Sext(Bits(insn, 31, 20), 12));
      const int size = (f3 & 3u);
      const bool misaligned = (size == 2 && (addr & 3u)) || (size == 1 && (addr & 1u));
      if (misaligned) { trap(kExcLoadMisaligned, addr); return s; }
      bool lerr = false;
      const uint32_t w = Load32(addr, &lerr);
      if (lerr) { trap(kExcLoadAccess, addr); return s; }
      const uint8_t be = (size == 0) ? static_cast<uint8_t>(1u << (addr & 3u))
                       : (size == 1) ? ((addr & 2u) ? 0xCu : 0x3u)
                                     : 0xFu;
      uint32_t v;
      if (size == 0) {
        const uint32_t byte = (w >> (8 * (addr & 3u))) & 0xFFu;
        v = (f3 & 4u) ? byte : static_cast<uint32_t>(static_cast<int8_t>(byte));
      } else if (size == 1) {
        const uint32_t half = (w >> ((addr & 2u) ? 16u : 0u)) & 0xFFFFu;
        v = (f3 & 4u) ? half : static_cast<uint32_t>(static_cast<int16_t>(half));
      } else {
        v = w;
      }
      rd_val = v; writes_rd = true;
      s.mem_addr = addr & ~3u;
      s.mem_rmask = be;
      break;
    }

    case 0x23: {  // STORE
      if (f3 > 2) { trap(kExcIllegal, insn); return s; }
      const uint32_t imm = static_cast<uint32_t>(
          Sext((Bits(insn, 31, 25) << 5) | Bits(insn, 11, 7), 12));
      const uint32_t addr = a + imm;
      const int size = (f3 & 3u);
      const bool misaligned = (size == 2 && (addr & 3u)) || (size == 1 && (addr & 1u));
      if (misaligned) { trap(kExcStoreMisaligned, addr); return s; }
      const uint8_t be = (size == 0) ? static_cast<uint8_t>(1u << (addr & 3u))
                       : (size == 1) ? ((addr & 2u) ? 0xCu : 0x3u)
                                     : 0xFu;
      // The core replicates sub-word store data across the word, so the
      // reference does too: the comparison covers the bus value, not just the
      // resulting memory contents.
      const uint32_t wdata = (size == 0) ? (b & 0xFFu) * 0x01010101u
                           : (size == 1) ? (b & 0xFFFFu) * 0x00010001u
                                         : b;
      bool serr = false;
      Store32(addr, wdata, be, &serr);
      if (serr) { trap(kExcStoreAccess, addr); return s; }
      s.mem_addr = addr & ~3u;
      s.mem_wmask = be;
      s.mem_wdata = wdata;
      break;
    }

    case 0x13: {  // OP-IMM
      const uint32_t imm = static_cast<uint32_t>(Sext(Bits(insn, 31, 20), 12));
      if (f3 == 1 && f7 != 0) { trap(kExcIllegal, insn); return s; }
      if (f3 == 5 && f7 != 0 && f7 != 0x20u) { trap(kExcIllegal, insn); return s; }
      // instr[31:25] selects SRAI only; for every other OP-IMM encoding it is
      // part of the immediate.
      rd_val = alu(a, (f3 == 1 || f3 == 5) ? rs2 : imm, f3 == 5 && f7 == 0x20u);
      writes_rd = true;
      break;
    }

    case 0x33: {  // OP
      if (rv32m_ && f7 == 0x01u) {   // M extension
        rd_val = MulDiv(f3, a, b);
        writes_rd = true;
        break;
      }
      if (f7 == 0x20u) {
        if (f3 != 0 && f3 != 5) { trap(kExcIllegal, insn); return s; }
      } else if (f7 != 0) {
        trap(kExcIllegal, insn);   // includes the M extension
        return s;
      }
      rd_val = alu(a, b, f7 == 0x20u);
      writes_rd = true;
      break;
    }

    case 0x0F:  // MISC-MEM: FENCE / FENCE.I are NOPs
      if (f3 != 0 && f3 != 1) { trap(kExcIllegal, insn); return s; }
      break;

    case 0x73: {  // SYSTEM
      if (f3 == 0) {
        if (insn == 0x00000073u) { trap(kExcEcallM, 0); return s; }
        if (insn == 0x00100073u) { trap(kExcBreakpoint, pc_); return s; }
        if (insn == 0x30200073u) {   // MRET
          mstatus_mie_ = mstatus_mpie_;
          mstatus_mpie_ = 1;
          next_pc = mepc_;
          break;
        }
        if (insn == 0x10500073u) break;   // WFI: a NOP here
        trap(kExcIllegal, insn);
        return s;
      }
      if (f3 == 4) { trap(kExcIllegal, insn); return s; }

      const uint32_t csr = Bits(insn, 31, 20);
      const bool use_imm = (f3 & 4u) != 0u;
      const uint32_t operand = use_imm ? rs1 : a;
      const uint32_t op = f3 & 3u;
      const bool does_write = (op == 1) ? true : (use_imm ? (rs1 != 0) : (rs1 != 0));

      bool bad = false;
      const uint32_t old = CsrRead(csr, &bad);
      if (bad) { trap(kExcIllegal, insn); return s; }

      if (does_write) {
        uint32_t nv;
        if (op == 1) nv = operand;
        else if (op == 2) nv = old | operand;
        else nv = old & ~operand;
        bool werr = false;
        CsrWrite(csr, nv, &werr);
        if (werr) { trap(kExcIllegal, insn); return s; }
      }
      rd_val = old;
      writes_rd = true;
      // mcycle, minstret, the performance counters and mip all report
      // microarchitectural or external state that this model does not track.
      switch (csr) {
        case 0xB00: case 0xB02: case 0xB80: case 0xB82:
        case 0x344:
          s.rd_unpredictable = true;
          break;
        default:
          if (IsHpm(csr)) s.rd_unpredictable = true;
          break;
      }
      break;
    }

    default:
      trap(kExcIllegal, insn);
      return s;
  }

  if (writes_rd && rd != 0) {
    x_[rd] = rd_val;
    s.rd = static_cast<uint8_t>(rd);
    s.rd_value = rd_val;
  }
  pc_ = next_pc;
  s.pc_next = next_pc;
  ++minstret_;
  return s;
}
