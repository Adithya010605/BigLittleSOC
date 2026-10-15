// ============================================================================
// tb_core.cpp — Verilator harness for either core.
//
// Drives rtl/e_core/e_core_top.sv or rtl/p_core/p_core_top.sv against
// tb/integration/memory_model.*, loading a program from an ELF file and
// terminating on the `tohost` store. Both cores have the same ports, so the
// harness is the same; building with -DCORE_P selects the P-core, and with it
// the golden ISS configuration (RV32IM, seven event counters) that matches.
//
// Usage:
//   e_core_sim | p_core_sim --elf=PROG.elf [options]
//     --waits=0 | --waits=N | --waits=random[:SEED]
//                          memory latency model (default 0)
//     --dwaits=SPEC        override the data port's latency alone, same
//                          syntax (e.g. --waits=0 --dwaits=3: fast fetch,
//                          slow data)
//     --max-cycles=N       timeout, default 1,000,000
//     --trace=FILE.vcd     waveform dump (only in a --trace build)
//     --log=FILE           per-instruction retirement trace
//     --uart-out=FILE      capture UART output to a file as well as stdout
//     --coverage-out=FILE  write coverage data (only in a --coverage build)
//     --lockstep           compare against the golden ISS every retirement
//     --halt-every=N[:SEED] halt the core through its debug port about every
//                          N cycles (see HALT MODE below)
//     --quiet              suppress the per-run summary line
//
// Exit status: 0 if the program signalled success through tohost, non-zero
// otherwise. Every failure path prints the PC, the instruction word, its
// disassembly, and the last 20 retired instructions.
//
// ---------------------------------------------------------------------------
// CYCLE ORDERING
// ---------------------------------------------------------------------------
// Each simulated cycle runs as:
//   1. clk low, eval  -> the core's request outputs settle from current state
//   2. the memory model evaluates those requests purely and drives gnt /
//      rvalid / rdata / err; eval again so the core sees them
//   3. sample RVFI: this is the retirement that happens in THIS cycle
//   4. clk high, eval -> the registers take their new values
//   5. the memory model advances its own state, using the request captured
//      in step 2
//
// A single settle pass in step 2 is sufficient because the model's response is
// a pure function of its own state and the request, and the core never derives
// `req` combinationally from `gnt`. Both halves of that contract are stated in
// memory_model.h and in the RTL header.
//
// ---------------------------------------------------------------------------
// HALT MODE (--halt-every)
// ---------------------------------------------------------------------------
// The halt/debug port is what the PMU uses to migrate a context between
// cores (rtl/power/pmu.sv). In halt mode the harness plays the PMU: at random
// intervals it requests a halt and waits for halted_o, then
//
//   * reads x1..x31, the pc and the CSRs that travel with a context through
//     the debug port and, under --lockstep, compares them with the golden
//     ISS's architectural state at that point;
//   * writes a random register, the pc and two CSRs with random values, reads
//     each back, writes the original back and reads that back too;
//   * stays halted a few cycles more, then releases the core.
//
// Now and then it withdraws the request before the core has halted, which
// must simply let the core carry on. Since every write is undone, the
// program runs exactly as it would have without the halts -- its own checks,
// and the lockstep comparison, prove that the halts were invisible.
// ============================================================================

#ifdef CORE_P
#include "Vp_core_top.h"
using CoreTop = Vp_core_top;
#define SIM_NAME "p_core_sim"
constexpr bool kIssRv32m = true;
constexpr int kIssNumHpm = 7;
#else
#include "Ve_core_top.h"
using CoreTop = Ve_core_top;
#define SIM_NAME "e_core_sim"
constexpr bool kIssRv32m = false;
constexpr int kIssNumHpm = 4;
#endif
#include "verilated.h"

#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

#include "disasm.h"
#include "elf_loader.h"
#include "golden_iss.h"
#include "memory_model.h"

namespace {

// ---------------------------------------------------------------------------
struct Options {
  std::string elf_path;
  std::string waits = "0";
  std::string dwaits;
  std::string trace_path;
  std::string log_path;
  std::string uart_path;
  std::string coverage_path;
  uint64_t max_cycles = 1000000;
  bool lockstep = false;
  bool quiet = false;
  uint64_t halt_every = 0;     // 0: never
  uint64_t halt_seed = 1;
};

bool StartsWith(const char* s, const char* prefix, const char** rest) {
  const size_t n = std::strlen(prefix);
  if (std::strncmp(s, prefix, n) == 0) {
    *rest = s + n;
    return true;
  }
  return false;
}

bool ParseArgs(int argc, char** argv, Options* o, std::string* error) {
  for (int i = 1; i < argc; ++i) {
    const char* a = argv[i];
    const char* v = nullptr;
    if (StartsWith(a, "--elf=", &v)) {
      o->elf_path = v;
    } else if (std::strcmp(a, "--elf") == 0 && i + 1 < argc) {
      o->elf_path = argv[++i];
    } else if (StartsWith(a, "--waits=", &v)) {
      o->waits = v;
    } else if (StartsWith(a, "--dwaits=", &v)) {
      o->dwaits = v;
    } else if (StartsWith(a, "--max-cycles=", &v)) {
      o->max_cycles = std::strtoull(v, nullptr, 0);
    } else if (StartsWith(a, "--trace=", &v)) {
      o->trace_path = v;
    } else if (std::strcmp(a, "--trace") == 0) {
      o->trace_path = "trace.vcd";
    } else if (StartsWith(a, "--log=", &v)) {
      o->log_path = v;
    } else if (StartsWith(a, "--uart-out=", &v)) {
      o->uart_path = v;
    } else if (StartsWith(a, "--coverage-out=", &v)) {
      o->coverage_path = v;
    } else if (std::strcmp(a, "--lockstep") == 0) {
      o->lockstep = true;
    } else if (StartsWith(a, "--halt-every=", &v)) {
      char* end = nullptr;
      o->halt_every = std::strtoull(v, &end, 0);
      if (end != nullptr && *end == ':') o->halt_seed = std::strtoull(end + 1, nullptr, 0);
      if (o->halt_every == 0) {
        *error = "--halt-every needs a positive interval";
        return false;
      }
    } else if (std::strcmp(a, "--quiet") == 0) {
      o->quiet = true;
    } else {
      *error = std::string("unknown option: ") + a;
      return false;
    }
  }
  if (o->elf_path.empty()) {
    *error = "no --elf given";
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// One retired instruction, kept in a short ring so that a failure can show how
// the machine got there rather than only where it stopped.
// ---------------------------------------------------------------------------
struct Retirement {
  uint64_t cycle = 0;
  uint64_t order = 0;
  uint32_t pc = 0;
  uint32_t insn = 0;
  uint32_t pc_next = 0;
  uint8_t rd = 0;
  uint32_t rd_value = 0;
  uint32_t mem_addr = 0;
  uint8_t mem_rmask = 0;
  uint8_t mem_wmask = 0;
  uint32_t mem_rdata = 0;
  uint32_t mem_wdata = 0;
  bool trap = false;    // this instruction took a trap instead of retiring
  bool intr = false;    // ...and the trap was an interrupt
  bool halt = false;    // the core stopped: nothing further will execute
};

std::string FormatRetirement(const Retirement& r, const ElfImage& elf) {
  char buf[512];
  std::string extra;
  if (r.rd != 0) {
    char b[64];
    std::snprintf(b, sizeof(b), " x%u<-0x%08x", r.rd, r.rd_value);
    extra += b;
  }
  if (r.mem_rmask != 0) {
    char b[80];
    std::snprintf(b, sizeof(b), " [0x%08x]->0x%08x", r.mem_addr, r.mem_rdata);
    extra += b;
  }
  if (r.mem_wmask != 0) {
    char b[96];
    std::snprintf(b, sizeof(b), " [0x%08x]<-0x%08x be=%x", r.mem_addr,
                  r.mem_wdata, r.mem_wmask);
    extra += b;
  }
  if (r.intr) {
    extra += "  <INTERRUPT>";
  } else if (r.trap) {
    extra += "  <TRAP>";
  }
  if (r.halt) extra += "  <HALT>";

  const std::string sym = elf.SymbolAt(r.pc);
  std::snprintf(buf, sizeof(buf), "%8llu %6llu  0x%08x  %08x  %-28s %-24s%s",
                static_cast<unsigned long long>(r.cycle),
                static_cast<unsigned long long>(r.order), r.pc, r.insn,
                Disassemble(r.insn, r.pc).c_str(), sym.c_str(), extra.c_str());
  return std::string(buf);
}

// ---------------------------------------------------------------------------
// Halt mode: the harness drives the core's halt and debug ports.
// ---------------------------------------------------------------------------
class HaltDriver {
 public:
  HaltDriver(uint64_t every, uint64_t seed) : every_(every), rng_(seed * 0x9E3779B97F4A7C15ull + 1) {
    countdown_ = Draw(every_);
  }

  // Called once per cycle after the core's outputs have settled and before
  // the clock edge: drives halt_req and the debug ports for this cycle.
  // Returns an error message, or "" .
  std::string Cycle(CoreTop* top, const GoldenIss* iss) {
    // Every debug write lasts exactly one cycle.
    top->dbg_rf_we_i = 0;
    top->dbg_csr_we_i = 0;
    top->dbg_pc_we_i = 0;
    switch (phase_) {
      case RUN:
        if (countdown_-- == 0) {
          phase_ = WAIT;
          top->halt_req_i = 1;
          waited_ = 0;
          abort_at_ = (Next() % 8 == 0) ? static_cast<int>(Next() % 4) : -1;
          ++requests_;
        }
        break;
      case WAIT:
        if (abort_at_ >= 0 && waited_ == static_cast<uint64_t>(abort_at_) && !top->halted_o) {
          Release(top);
          ++withdrawn_;
          break;
        }
        if (top->halted_o) {
          phase_ = HALTED;
          ++halts_;
          std::string e = Inspect(top, iss);
          if (!e.empty()) return e;
          Plan(top);
        } else if (++waited_ > 5000) {
          return "the core did not halt within 5000 cycles of the request";
        }
        break;
      case HALTED: {
        if (!top->halted_o) return "the core left the halted state while halt_req was high";
        if (ops_.empty()) {
          Release(top);
          break;
        }
        const Op op = ops_.front();
        ops_.pop_front();
        std::string e = Do(top, op);
        if (!e.empty()) return e;
        break;
      }
    }
    return "";
  }

  uint64_t halts() const { return halts_; }
  uint64_t requests() const { return requests_; }
  uint64_t withdrawn() const { return withdrawn_; }

 private:
  enum Phase { RUN, WAIT, HALTED };
  enum Kind { RF_WRITE, RF_CHECK, CSR_WRITE, CSR_CHECK, PC_WRITE, PC_CHECK, IDLE };
  struct Op {
    Kind kind;
    uint32_t addr;
    uint32_t value;
  };

  static constexpr uint32_t kCsrs[7] = {0x300, 0x304, 0x305, 0x340, 0x341, 0x342, 0x343};

  uint64_t Next() {
    rng_ ^= rng_ << 13;
    rng_ ^= rng_ >> 7;
    rng_ ^= rng_ << 17;
    return rng_;
  }
  uint64_t Draw(uint64_t mean) { return mean / 2 + Next() % (mean + 1); }

  void Release(CoreTop* top) {
    top->halt_req_i = 0;
    phase_ = RUN;
    countdown_ = Draw(every_);
  }

  static uint32_t ReadRf(CoreTop* top, int r) {
    top->dbg_rf_addr_i = static_cast<uint8_t>(r);
    top->eval();
    return top->dbg_rf_rdata_o;
  }
  static uint32_t ReadCsr(CoreTop* top, uint32_t a) {
    top->dbg_csr_addr_i = static_cast<uint16_t>(a);
    top->eval();
    return top->dbg_csr_rdata_o;
  }

  static std::string Mismatch(const char* what, uint32_t a, uint32_t got, uint32_t exp) {
    char b[160];
    std::snprintf(b, sizeof(b), "halted state: %s 0x%x reads 0x%08x, expected 0x%08x", what, a,
                  got, exp);
    return b;
  }

  // The architectural state, read through the debug port, against the ISS.
  std::string Inspect(CoreTop* top, const GoldenIss* iss) {
    for (int r = 1; r < 32; ++r) saved_x_[r] = ReadRf(top, r);
    saved_pc_ = top->dbg_pc_o;
    for (int k = 0; k < 7; ++k) saved_csr_[k] = ReadCsr(top, kCsrs[k]);
    if (iss == nullptr) return "";
    for (int r = 1; r < 32; ++r)
      if (saved_x_[r] != iss->reg(r)) return Mismatch("x", static_cast<uint32_t>(r), saved_x_[r], iss->reg(r));
    if (saved_pc_ != iss->pc()) return Mismatch("pc", 0, saved_pc_, iss->pc());
    for (int k = 0; k < 7; ++k)
      if (saved_csr_[k] != iss->csr(kCsrs[k])) return Mismatch("csr", kCsrs[k], saved_csr_[k], iss->csr(kCsrs[k]));
    return "";
  }

  // Write, read back, restore, read back: one register, the pc, two CSRs.
  void Plan(CoreTop* top) {
    (void)top;
    ops_.clear();
    const uint32_t r = 1 + static_cast<uint32_t>(Next() % 31);
    const uint32_t v = static_cast<uint32_t>(Next());
    ops_.push_back({RF_WRITE, r, v});
    ops_.push_back({RF_CHECK, r, v});
    ops_.push_back({RF_WRITE, r, saved_x_[r]});
    ops_.push_back({RF_CHECK, r, saved_x_[r]});
    const uint32_t pc = static_cast<uint32_t>(Next()) & ~3u;
    ops_.push_back({PC_WRITE, 0, pc});
    ops_.push_back({PC_CHECK, 0, pc});
    ops_.push_back({PC_WRITE, 0, saved_pc_});
    ops_.push_back({PC_CHECK, 0, saved_pc_});
    // mscratch and mtval hold any value
    for (int k : {3, 6}) {
      const uint32_t cv = static_cast<uint32_t>(Next());
      ops_.push_back({CSR_WRITE, kCsrs[k], cv});
      ops_.push_back({CSR_CHECK, kCsrs[k], cv});
      ops_.push_back({CSR_WRITE, kCsrs[k], saved_csr_[k]});
      ops_.push_back({CSR_CHECK, kCsrs[k], saved_csr_[k]});
    }
    for (uint64_t i = Next() % 6; i > 0; --i) ops_.push_back({IDLE, 0, 0});
  }

  std::string Do(CoreTop* top, const Op& op) {
    switch (op.kind) {
      case RF_WRITE:
        top->dbg_rf_addr_i = static_cast<uint8_t>(op.addr);
        top->dbg_wdata_i = op.value;
        top->dbg_rf_we_i = 1;
        break;
      case RF_CHECK: {
        const uint32_t got = ReadRf(top, static_cast<int>(op.addr));
        if (got != op.value) return Mismatch("written x", op.addr, got, op.value);
        break;
      }
      case CSR_WRITE:
        top->dbg_csr_addr_i = static_cast<uint16_t>(op.addr);
        top->dbg_wdata_i = op.value;
        top->dbg_csr_we_i = 1;
        break;
      case CSR_CHECK: {
        const uint32_t got = ReadCsr(top, op.addr);
        if (got != op.value) return Mismatch("written csr", op.addr, got, op.value);
        break;
      }
      case PC_WRITE:
        top->dbg_wdata_i = op.value;
        top->dbg_pc_we_i = 1;
        break;
      case PC_CHECK:
        if (top->dbg_pc_o != op.value) return Mismatch("written pc", 0, top->dbg_pc_o, op.value);
        break;
      case IDLE:
        break;
    }
    top->eval();
    return "";
  }

  uint64_t every_;
  uint64_t rng_;
  uint64_t countdown_ = 0;
  Phase phase_ = RUN;
  uint64_t waited_ = 0;
  int abort_at_ = -1;
  std::deque<Op> ops_;
  uint32_t saved_x_[32] = {};
  uint32_t saved_pc_ = 0;
  uint32_t saved_csr_[7] = {};
  uint64_t halts_ = 0, requests_ = 0, withdrawn_ = 0;
};

}  // namespace

// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  Options opt;
  std::string err;
  if (!ParseArgs(argc, argv, &opt, &err)) {
    std::fprintf(stderr, SIM_NAME ": %s\n", err.c_str());
    std::fprintf(stderr, "usage: " SIM_NAME " --elf=PROG.elf [--waits=...] "
                         "[--max-cycles=N] [--trace=F] [--log=F]\n");
    return 2;
  }

  ElfImage elf;
  if (!elf.Load(opt.elf_path, &err)) {
    std::fprintf(stderr, SIM_NAME ": %s\n", err.c_str());
    return 2;
  }

  WaitConfig wcfg;
  if (!WaitConfig::Parse(opt.waits, &wcfg, &err)) {
    std::fprintf(stderr, SIM_NAME ": %s\n", err.c_str());
    return 2;
  }

  MemoryModel mem;
  mem.SetWaits(wcfg);
  if (!opt.dwaits.empty()) {
    WaitConfig dcfg;
    if (!WaitConfig::Parse(opt.dwaits, &dcfg, &err)) {
      std::fprintf(stderr, SIM_NAME ": %s\n", err.c_str());
      return 2;
    }
    mem.SetDataWaits(dcfg);
    // Reported as "<fetch>/data=<data>" wherever the latency is printed.
    wcfg.label_suffix = "/data=" + dcfg.Describe();
  }
  if (!mem.LoadElf(elf, &err)) {
    std::fprintf(stderr, SIM_NAME ": %s\n", err.c_str());
    return 2;
  }

  auto* top = new CoreTop;

#if VM_TRACE
  VerilatedVcdC* vcd = nullptr;
  if (!opt.trace_path.empty()) {
    Verilated::traceEverOn(true);
    vcd = new VerilatedVcdC;
    top->trace(vcd, 8);
    vcd->open(opt.trace_path.c_str());
  }
#else
  if (!opt.trace_path.empty()) {
    std::fprintf(stderr,
                 SIM_NAME ": --trace given but this binary was built without "
                 "tracing; use 'make wave TEST=<name>'\n");
    return 2;
  }
#endif

  std::FILE* logf = nullptr;
  if (!opt.log_path.empty()) {
    logf = std::fopen(opt.log_path.c_str(), "w");
    if (logf == nullptr) {
      std::fprintf(stderr, SIM_NAME ": cannot write %s\n", opt.log_path.c_str());
      return 2;
    }
    std::fprintf(logf, "%8s %6s  %-10s  %-8s  %-28s %-24s%s\n", "cycle",
                 "order", "pc", "insn", "disassembly", "symbol", " effects");
  }

  // Golden-ISS lockstep. The reference runs one instruction per RTL
  // retirement (or trap) and the architectural effects are compared field by
  // field. Cycle-dependent state is not compared: mcycle, minstret and the
  // performance counters measure microarchitectural events that an
  // architectural model cannot predict.
  GoldenIss iss;
  iss.Configure(kIssRv32m, kIssNumHpm);
  if (opt.lockstep) {
    if (!iss.Load(elf, &err)) {
      std::fprintf(stderr, SIM_NAME ": %s\n", err.c_str());
      return 2;
    }
  }
  int lockstep_errors = 0;

  std::deque<Retirement> history;
  const size_t kHistory = 50;
  uint64_t cycle = 0;
  uint64_t retired = 0;
  uint64_t trapped = 0;
  bool timeout = false;
  bool halted = false;
  Retirement halt_rec;
  HaltDriver halter(opt.halt_every, opt.halt_seed);
  std::string halt_error;

  // ---- reset ----
  top->rst_ni = 0;
  top->instr_gnt_i = 0;
  top->instr_rvalid_i = 0;
  top->instr_rdata_i = 0;
  top->instr_err_i = 0;
  top->data_gnt_i = 0;
  top->data_rvalid_i = 0;
  top->data_rdata_i = 0;
  top->data_err_i = 0;
  top->irq_timer_i = 0;
  top->irq_software_i = 0;
  top->irq_external_i = 0;
  top->hart_id_i = 0;
  top->halt_req_i = 0;
  top->dbg_rf_addr_i = 0;
  top->dbg_rf_we_i = 0;
  top->dbg_csr_addr_i = 0;
  top->dbg_csr_we_i = 0;
  top->dbg_pc_we_i = 0;
  top->dbg_wdata_i = 0;
  top->clk_i = 0;
  for (int i = 0; i < 5; ++i) {
    top->clk_i = 0;
    top->eval();
    top->clk_i = 1;
    top->eval();
  }
  top->rst_ni = 1;

  // ---- main loop ----
  while (!mem.exited() && !halted && halt_error.empty()) {
    if (cycle >= opt.max_cycles) {
      timeout = true;
      break;
    }

    // 1. settle the core's outputs for this cycle; in halt mode, drive the
    //    halt and debug ports (the ISS is at the same architectural point:
    //    every retirement so far has been stepped)
    top->clk_i = 0;
    top->eval();
    if (opt.halt_every != 0) {
      halt_error = halter.Cycle(top, opt.lockstep && lockstep_errors == 0 ? &iss : nullptr);
      top->eval();
    }

    // 2. the memory model responds
    MemRequest iq;
    iq.req = top->instr_req_o != 0;
    iq.addr = top->instr_addr_o;
    iq.we = false;
    iq.be = 0xF;
    iq.wdata = 0;

    MemRequest dq;
    dq.req = top->data_req_o != 0;
    dq.addr = top->data_addr_o;
    dq.we = top->data_we_o != 0;
    dq.be = static_cast<uint8_t>(top->data_be_o);
    dq.wdata = top->data_wdata_o;

    top->irq_timer_i = mem.irq_timer() ? 1 : 0;
    top->irq_software_i = mem.irq_software() ? 1 : 0;
    top->irq_external_i = mem.irq_external() ? 1 : 0;

    const MemResponse ir = mem.EvaluateInstr(iq);
    const MemResponse dr = mem.EvaluateData(dq);

    top->instr_gnt_i = ir.gnt;
    top->instr_rvalid_i = ir.rvalid;
    top->instr_rdata_i = ir.rdata;
    top->instr_err_i = ir.err;
    top->data_gnt_i = dr.gnt;
    top->data_rvalid_i = dr.rvalid;
    top->data_rdata_i = dr.rdata;
    top->data_err_i = dr.err;
    top->eval();

    // 3. sample retirement
    if (top->rvfi_valid_o) {
      Retirement r;
      r.cycle = cycle;
      r.order = top->rvfi_order_o;
      r.pc = top->rvfi_pc_rdata_o;
      r.insn = top->rvfi_insn_o;
      r.pc_next = top->rvfi_pc_wdata_o;
      r.rd = static_cast<uint8_t>(top->rvfi_rd_addr_o);
      r.rd_value = top->rvfi_rd_wdata_o;
      r.mem_addr = top->rvfi_mem_addr_o;
      r.mem_rmask = static_cast<uint8_t>(top->rvfi_mem_rmask_o);
      r.mem_wmask = static_cast<uint8_t>(top->rvfi_mem_wmask_o);
      r.mem_rdata = top->rvfi_mem_rdata_o;
      r.mem_wdata = top->rvfi_mem_wdata_o;
      r.trap = top->rvfi_trap_o != 0;
      r.intr = top->rvfi_intr_o != 0;
      r.halt = top->rvfi_halt_o != 0;

      if (logf != nullptr) {
        std::fprintf(logf, "%s\n", FormatRetirement(r, elf).c_str());
      }
      history.push_back(r);
      if (history.size() > kHistory) history.pop_front();

      // A trap is ordinary execution, not a failure: the instruction does not
      // retire, control moves to mtvec, and the program continues. Only
      // rvfi_halt means the core has genuinely stopped.
      if (r.trap) {
        ++trapped;
      } else {
        ++retired;
      }
      if (r.halt) {
        halted = true;
        halt_rec = r;
      }

      if (opt.lockstep && lockstep_errors == 0) {
        const IssStep e = iss.Step();
        auto mismatch = [&](const char* field, uint64_t got, uint64_t exp) {
          if (got == exp) return;
          if (lockstep_errors++ > 0) return;
          std::fprintf(stderr,
                       "\n" SIM_NAME ": LOCKSTEP MISMATCH on %s\n"
                       "  order      : %llu\n"
                       "  RTL  pc    : 0x%08x  insn 0x%08x  %s\n"
                       "  ISS  pc    : 0x%08x  insn 0x%08x  %s\n"
                       "  %-10s : RTL 0x%llx  ISS 0x%llx\n",
                       field, static_cast<unsigned long long>(r.order), r.pc,
                       r.insn, Disassemble(r.insn, r.pc).c_str(), e.pc, e.insn,
                       Disassemble(e.insn, e.pc).c_str(), field,
                       static_cast<unsigned long long>(got),
                       static_cast<unsigned long long>(exp));
        };
        mismatch("pc", r.pc, e.pc);
        mismatch("insn", r.insn, e.insn);
        mismatch("trap", r.trap ? 1u : 0u, e.trap ? 1u : 0u);
        if (!r.trap && !e.trap) {
          mismatch("pc_next", r.pc_next, e.pc_next);
          mismatch("rd_addr", r.rd, e.rd);
          if (e.rd != 0) {
            if (e.rd_unpredictable) {
              iss.AdoptReg(e.rd, r.rd_value);
            } else {
              mismatch("rd_value", r.rd_value, e.rd_value);
            }
          }
          mismatch("mem_wmask", r.mem_wmask, e.mem_wmask);
          if (e.mem_wmask != 0) {
            mismatch("mem_addr", r.mem_addr, e.mem_addr);
            // Only the enabled lanes carry meaning; the rest are don't-care.
            uint32_t mask = 0;
            for (int l = 0; l < 4; ++l) {
              if (e.mem_wmask & (1u << l)) mask |= 0xFFu << (8 * l);
            }
            mismatch("mem_wdata", r.mem_wdata & mask, e.mem_wdata & mask);
          }
          mismatch("mem_rmask", r.mem_rmask, e.mem_rmask);
        }
      }
    }

#if VM_TRACE
    if (vcd != nullptr) vcd->dump(static_cast<uint64_t>(cycle) * 2);
#endif

    // 4. clock edge
    top->clk_i = 1;
    top->eval();
#if VM_TRACE
    if (vcd != nullptr) vcd->dump(static_cast<uint64_t>(cycle) * 2 + 1);
#endif

    // 5. the memory model advances, using the request captured in step 2
    mem.TickInstr(iq);
    mem.TickData(dq);
    mem.TickTimer();

    ++cycle;
  }

  top->final();

#if VM_TRACE
  if (vcd != nullptr) {
    vcd->close();
    delete vcd;
  }
#endif
#if VM_COVERAGE
  if (!opt.coverage_path.empty()) {
    Verilated::threadContextp()->coveragep()->write(opt.coverage_path.c_str());
  }
#endif
  if (logf != nullptr) std::fclose(logf);

  // ---- UART output ----
  const std::string& uart = mem.uart_output();
  if (!uart.empty()) {
    std::fwrite(uart.data(), 1, uart.size(), stdout);
    if (uart.back() != '\n') std::fputc('\n', stdout);
  }
  if (!opt.uart_path.empty()) {
    std::FILE* uf = std::fopen(opt.uart_path.c_str(), "w");
    if (uf != nullptr) {
      std::fwrite(uart.data(), 1, uart.size(), uf);
      std::fclose(uf);
    }
  }

  // ---- verdict ----
  auto dump_history = [&](const char* why) {
    std::fprintf(stderr, "\n=== %s ===\n", why);
    std::fprintf(stderr, "program : %s\n", opt.elf_path.c_str());
    std::fprintf(stderr, "waits   : %s\n", wcfg.Describe().c_str());
    std::fprintf(stderr, "cycles  : %llu, retired: %llu, traps: %llu\n",
                 static_cast<unsigned long long>(cycle),
                 static_cast<unsigned long long>(retired),
                 static_cast<unsigned long long>(trapped));
    std::fprintf(stderr, "\nlast %zu retired instructions (most recent last):\n",
                 history.size());
    std::fprintf(stderr, "%8s %6s  %-10s  %-8s  %-28s %-24s%s\n", "cycle",
                 "order", "pc", "insn", "disassembly", "symbol", " effects");
    for (const Retirement& r : history) {
      std::fprintf(stderr, "%s\n", FormatRetirement(r, elf).c_str());
    }
    std::fprintf(stderr, "\n");
  };

  int rc = 0;
  if (!halt_error.empty()) {
    std::fprintf(stderr, "\n" SIM_NAME ": HALT MODE: %s\n", halt_error.c_str());
    dump_history("HALT MODE FAILURE");
    rc = 5;
  } else if (opt.halt_every != 0 && halter.halts() == 0 && cycle > 4 * opt.halt_every) {
    std::fprintf(stderr, "\n" SIM_NAME ": HALT MODE: the core never halted\n");
    rc = 5;
  } else if (lockstep_errors > 0) {
    dump_history("LOCKSTEP MISMATCH");
    rc = 5;
  } else if (halted) {
    std::fprintf(stderr,
                 "\n" SIM_NAME ": CORE HALTED at pc=0x%08x insn=0x%08x (%s)\n",
                 halt_rec.pc, halt_rec.insn,
                 Disassemble(halt_rec.insn, halt_rec.pc).c_str());
    dump_history("CORE HALTED");
    rc = 3;
  } else if (timeout) {
    std::fprintf(stderr, "\n" SIM_NAME ": TIMEOUT after %llu cycles\n",
                 static_cast<unsigned long long>(cycle));
    dump_history("TIMEOUT");
    rc = 4;
  } else if (mem.tohost_raw() != 1u) {
    // riscv-tests convention: a RAW tohost value of 1 means the program
    // passed; a failing check n is written as (n<<1)|1, so the check number is
    // the raw value shifted right by one. Comparing the shifted value against
    // 1 would call check 0 a pass and check 1 a failure, which is why the
    // comparison is against the raw word.
    std::fprintf(stderr,
                 "\n" SIM_NAME ": PROGRAM FAILED, tohost=%u (raw 0x%08x)\n",
                 mem.exit_code(), mem.tohost_raw());
    std::fprintf(stderr,
                 "  The riscv-tests convention encodes a failing check n as "
                 "(n<<1)|1, so the number above\n"
                 "  names the check that failed.\n");
    dump_history("PROGRAM FAILED");
    rc = 1;
  }

  if (!opt.quiet) {
    char halts[96] = "";
    if (opt.halt_every != 0)
      std::snprintf(halts, sizeof(halts), " halts=%llu/%llu",
                    static_cast<unsigned long long>(halter.halts()),
                    static_cast<unsigned long long>(halter.requests()));
    std::printf(SIM_NAME ": %s  cycles=%llu instret=%llu traps=%llu waits=%s%s%s%s\n",
                rc == 0 ? "PASS" : "FAIL",
                static_cast<unsigned long long>(cycle),
                static_cast<unsigned long long>(retired),
                static_cast<unsigned long long>(trapped),
                wcfg.Describe().c_str(),
                opt.lockstep ? " lockstep=on" : "", halts,
                rc == 0 ? "" : "  <-- see stderr");
  }

  delete top;
  return rc;
}
