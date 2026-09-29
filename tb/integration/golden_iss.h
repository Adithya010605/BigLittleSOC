// ============================================================================
// golden_iss.h — architectural RV32I_Zicsr / RV32IM_Zicsr interpreter.
//
// A straightforward instruction-at-a-time reference model: register file,
// memory, machine-mode CSRs and trap semantics, with no pipeline, no stalls
// and no notion of cycles. That independence is the point — it shares no
// structure with the RTL, so a microarchitectural mistake cannot appear
// identically in both.
//
// It keeps its OWN copy of memory, initialised from the same ELF, rather than
// sharing the testbench's. Sharing would let an RTL store corrupt the
// reference before the comparison happened, which is exactly the class of bug
// lockstep is meant to catch.
//
// The same model serves both cores. Configure() selects the ISA and the size
// of the event-counter block to match the core under test: the E-core is
// RV32I with four counters, the P-core RV32IM with seven. With the M extension
// off, every M encoding traps as illegal, exactly as the E-core must.
//
// Cycle-dependent CSRs (mcycle, minstret and the performance counters) are
// modelled but deliberately excluded from comparison: they count
// microarchitectural events that an architectural model has no way to predict.
// The random program generator does not read them.
// ============================================================================
#ifndef GOLDEN_ISS_H
#define GOLDEN_ISS_H

#include <cstdint>
#include <string>
#include <vector>

#include "elf_loader.h"

// The architectural effects of one instruction, in the same shape as the RVFI
// trace port so the two can be compared field by field.
struct IssStep {
  uint32_t pc = 0;
  uint32_t insn = 0;
  uint32_t pc_next = 0;
  uint8_t rd = 0;            // 0 when no register is written
  uint32_t rd_value = 0;
  uint32_t mem_addr = 0;
  uint8_t mem_rmask = 0;
  uint8_t mem_wmask = 0;
  uint32_t mem_wdata = 0;
  bool trap = false;         // took a trap instead of retiring
  uint32_t cause = 0;
  // Set when the destination value cannot be predicted architecturally: a
  // read of mcycle, minstret, a performance counter or mip. The lockstep
  // checker skips rd_value for these rather than pretending the reference can
  // know how many cycles the pipeline took.
  bool rd_unpredictable = false;
};

class GoldenIss {
 public:
  static constexpr uint32_t kRamSize = 0x00030000u;
  static constexpr uint32_t kUartData = 0x10000000u;
  static constexpr uint32_t kUartStatus = 0x10000004u;

  // Selects the ISA (M extension on or off) and how many mhpmcounters exist.
  // Call before Load(); the default is the E-core's configuration.
  void Configure(bool rv32m, int num_hpm) {
    rv32m_ = rv32m;
    num_hpm_ = num_hpm;
  }

  bool Load(const ElfImage& elf, std::string* error);

  // Executes one instruction and reports its architectural effects.
  IssStep Step();

  uint32_t pc() const { return pc_; }
  uint32_t reg(int i) const { return (i == 0) ? 0u : x_[i]; }

  // Adopts a value the reference cannot predict (a read of mcycle, minstret,
  // a performance counter or mip). Skipping the comparison alone is not
  // enough: the reference would keep its own differing value and diverge on
  // the next instruction that used it. Taking the RTL's value keeps the two
  // machines in step while still comparing everything that IS architectural.
  void AdoptReg(int i, uint32_t v) {
    if (i != 0) x_[i] = v;
  }
  bool exited() const { return exited_; }
  uint32_t tohost_raw() const { return tohost_raw_; }
  const std::string& uart_output() const { return uart_out_; }
  const std::string& fault() const { return fault_; }

 private:
  uint32_t Load32(uint32_t addr, bool* err) const;
  void Store32(uint32_t addr, uint32_t value, uint8_t be, bool* err);
  uint32_t CsrRead(uint32_t addr, bool* illegal) const;
  void CsrWrite(uint32_t addr, uint32_t value, bool* illegal);
  void EnterTrap(uint32_t cause, uint32_t tval, uint32_t epc);
  bool IsHpm(uint32_t addr) const;
  static uint32_t MulDiv(uint32_t f3, uint32_t a, uint32_t b);

  bool rv32m_ = false;
  int num_hpm_ = 4;

  std::vector<uint32_t> mem_;
  uint32_t x_[32] = {0};
  uint32_t pc_ = 0;

  // Machine-mode CSRs that a program can observe deterministically.
  uint32_t mstatus_mie_ = 0, mstatus_mpie_ = 0;
  uint32_t mtvec_ = 0, mscratch_ = 0, mepc_ = 0, mcause_ = 0, mtval_ = 0;
  uint32_t mie_ = 0;
  uint64_t mcycle_ = 0, minstret_ = 0;

  bool tohost_known_ = false;
  uint32_t tohost_addr_ = 0;
  bool exited_ = false;
  uint32_t tohost_raw_ = 0;
  std::string uart_out_;
  std::string fault_;
};

#endif  // GOLDEN_ISS_H
