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
  top->clk_i = 0;
  for (int i = 0; i < 5; ++i) {
    top->clk_i = 0;
    top->eval();
    top->clk_i = 1;
    top->eval();
  }
  top->rst_ni = 1;

  // ---- main loop ----
  while (!mem.exited() && !halted) {
    if (cycle >= opt.max_cycles) {
      timeout = true;
      break;
    }

    // 1. settle the core's outputs for this cycle
    top->clk_i = 0;
    top->eval();

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
  if (lockstep_errors > 0) {
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
    std::printf(SIM_NAME ": %s  cycles=%llu instret=%llu traps=%llu waits=%s%s%s\n",
                rc == 0 ? "PASS" : "FAIL",
                static_cast<unsigned long long>(cycle),
                static_cast<unsigned long long>(retired),
                static_cast<unsigned long long>(trapped),
                wcfg.Describe().c_str(),
                opt.lockstep ? " lockstep=on" : "",
                rc == 0 ? "" : "  <-- see stderr");
  }

  delete top;
  return rc;
}
