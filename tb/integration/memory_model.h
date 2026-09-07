// ============================================================================
// memory_model.h — unified memory, UART and simulation-exit model.
//
// Implements the E-Core's memory map and both of its valid/ready ports.
//
//   0x0000_0000 .. 0x0002_FFFF   unified ROM/SRAM (192 KiB), instr + data
//   0x1000_0000                  UART transmit data   (write)
//   0x1000_0004                  UART status          (read; bit 0 = busy)
//   0x1100_0000                  IRQ controller       (see below)
//   <tohost>                     simulation exit mailbox, address resolved
//                                from the ELF symbol table, not hard-coded
//
// Anything outside the map raises the corresponding port's error input, which
// is what lets the core's access-fault exceptions be tested.
//
// ---------------------------------------------------------------------------
// PROTOCOL
// ---------------------------------------------------------------------------
// Ibex-style two-phase handshake, per port:
//
//   * The core asserts `req` with a stable address (and, for the data port,
//     we/be/wdata) and holds them until it sees `gnt`.
//   * `gnt` marks the cycle in which the request is accepted.
//   * `rvalid` marks the cycle in which `rdata` (and `err`) are valid. It may
//     be in the SAME cycle as `gnt` or any number of cycles later. `rvalid` is
//     asserted for writes as well as reads, acknowledging completion.
//
// The model supports a same-cycle response because that is what a cache hit
// looks like, and the whole point of using this protocol now is that the core
// drops behind a cache later without change.
//
// One transaction per port is outstanding at a time, which matches an in-order
// core with a single load/store unit. A new request is not granted while a
// response is still pending.
//
// The model's response is a pure function of the port's own state and the
// core's request signals; it never depends combinationally on anything the
// core derives from the response. That is what makes a single settle-then-
// respond evaluation per cycle sufficient, and it is a design rule the core
// must honour: `req` must not depend combinationally on `gnt`.
// ============================================================================
#ifndef MEMORY_MODEL_H
#define MEMORY_MODEL_H

#include <cstdint>
#include <string>
#include <vector>

#include "elf_loader.h"

// ---------------------------------------------------------------------------
// Wait-state configuration, parsed from --waits=
//   "0"              zero wait states: gnt and rvalid in the request cycle
//   "N"              N cycles to grant, then N more to respond
//   "random:SEED"    each transaction independently draws both delays
// ---------------------------------------------------------------------------
struct WaitConfig {
  enum Mode { kFixed, kRandom };
  Mode mode = kFixed;
  uint32_t fixed = 0;
  uint32_t max_random = 7;
  uint64_t seed = 1;

  // Returns false and fills `error` if the string is malformed.
  static bool Parse(const std::string& spec, WaitConfig* out, std::string* error);
  std::string Describe() const;
};

// ---------------------------------------------------------------------------
struct MemRequest {
  bool req = false;
  uint32_t addr = 0;
  bool we = false;
  uint8_t be = 0xF;
  uint32_t wdata = 0;
};

struct MemResponse {
  bool gnt = false;
  bool rvalid = false;
  uint32_t rdata = 0;
  bool err = false;
};

// ---------------------------------------------------------------------------
class MemoryModel {
 public:
  static constexpr uint32_t kRamBase = 0x00000000u;
  static constexpr uint32_t kRamSize = 0x00030000u;   // 192 KiB
  static constexpr uint32_t kUartBase = 0x10000000u;
  static constexpr uint32_t kUartData = kUartBase + 0x0u;
  static constexpr uint32_t kUartStatus = kUartBase + 0x4u;

  // Minimal interrupt controller, enough to drive the three interrupt pins
  // from a test program. A real CLINT arrives with the SoC in a later phase;
  // this exists so the taken-interrupt path can be tested now.
  //
  //   +0x0  W  arm the timer: assert irq_timer_i after N more cycles
  //         R  1 while the timer interrupt is asserted
  //   +0x4  W  clear the timer interrupt
  //   +0x8  W  bit 0 drives irq_software_i
  //   +0xC  W  bit 0 drives irq_external_i
  static constexpr uint32_t kIrqBase = 0x11000000u;
  static constexpr uint32_t kIrqTimerArm = kIrqBase + 0x0u;
  static constexpr uint32_t kIrqTimerClear = kIrqBase + 0x4u;
  static constexpr uint32_t kIrqSoftware = kIrqBase + 0x8u;
  static constexpr uint32_t kIrqExternal = kIrqBase + 0xCu;

  MemoryModel();

  // Loads an ELF image and resolves `tohost`. Returns false on failure.
  bool LoadElf(const ElfImage& elf, std::string* error);

  void SetWaits(const WaitConfig& cfg);

  // Per-cycle interface. Call order within one simulated cycle:
  //   1. settle the core's outputs
  //   2. EvaluateInstr / EvaluateData  -> drive the core's response inputs
  //   3. settle the core again, then clock it
  //   4. TickInstr / TickData          -> advance the model's own state
  MemResponse EvaluateInstr(const MemRequest& q) const;
  MemResponse EvaluateData(const MemRequest& q) const;
  void TickInstr(const MemRequest& q);
  void TickData(const MemRequest& q);

  // Backdoor access, for the golden ISS and for test setup.
  uint32_t ReadWordBackdoor(uint32_t addr) const;
  void WriteWordBackdoor(uint32_t addr, uint32_t value);
  bool InRam(uint32_t addr) const {
    return addr < kRamBase + kRamSize;   // kRamBase is 0
  }

  // Simulation exit, signalled by a store to `tohost`.
  bool exited() const { return exited_; }
  uint32_t exit_code() const { return exit_code_; }
  uint32_t tohost_raw() const { return tohost_raw_; }
  bool tohost_known() const { return tohost_known_; }
  uint32_t tohost_addr() const { return tohost_addr_; }

  // UART capture.
  const std::string& uart_output() const { return uart_out_; }

  // Interrupt pins, sampled by the harness each cycle.
  bool irq_timer() const { return irq_timer_; }
  bool irq_software() const { return irq_software_; }
  bool irq_external() const { return irq_external_; }
  // Advances the timer countdown. Called once per simulated cycle.
  void TickTimer();

  // Counters, for the results report.
  uint64_t instr_fetches() const { return instr_fetches_; }
  uint64_t data_reads() const { return data_reads_; }
  uint64_t data_writes() const { return data_writes_; }

 private:
  enum Phase { kIdle, kAwaitRvalid };

  struct Port {
    Phase phase = kIdle;
    int gnt_wait = 0;
    int rv_wait = 0;
    uint32_t held_rdata = 0;
    bool held_err = false;
    uint64_t rng = 1;
  };

  // The read half of an access, with no side effects at all, so that the
  // combinational Evaluate pass can be called any number of times per cycle.
  void ReadFor(const MemRequest& q, uint32_t* rdata, bool* err) const;

  // The state-changing half: applies stores, updates counters, drives the
  // UART and detects the tohost write. Called exactly once per transaction,
  // from Tick, in the cycle the request is granted.
  void CommitAccess(const MemRequest& q, bool is_instr);

  MemResponse Evaluate(const Port& p, const MemRequest& q) const;
  void Tick(Port* p, const MemRequest& q, bool is_instr);

  void DrawDelays(Port* p);
  uint32_t NextRandom(Port* p) const;

  std::vector<uint32_t> mem_;      // kRamSize/4 words
  WaitConfig waits_;

  Port iport_;
  Port dport_;

  bool tohost_known_ = false;
  uint32_t tohost_addr_ = 0;
  bool exited_ = false;
  uint32_t exit_code_ = 0;
  uint32_t tohost_raw_ = 0;

  std::string uart_out_;

  bool irq_timer_ = false;
  bool irq_software_ = false;
  bool irq_external_ = false;
  int64_t timer_countdown_ = -1;   // -1 = disarmed

  uint64_t instr_fetches_ = 0;
  uint64_t data_reads_ = 0;
  uint64_t data_writes_ = 0;
};

#endif  // MEMORY_MODEL_H
