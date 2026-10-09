// ============================================================================
// tb_soc.cpp — Verilator harness for rtl/soc/soc_top.sv.
//
// Runs one ELF image on every hart of the cluster (NUM_P P-cores and NUM_E
// E-cores, fixed at build time by -DSOC_NUM_P / -DSOC_NUM_E) behind the
// coherent cache hierarchy (L1 I and D per core, shared inclusive L2) and the
// QoS interconnect, with the SRAM, UART, interrupt controller and system
// control all in RTL. The testbench owns three interconnect masters: the
// debug port, which loads the program into the SRAM while the CPUs are held
// in reset, and two traffic ports, which can load the interconnect with
// checked background traffic (--traffic).
//
// Built with one core it accepts every option tb_core.cpp accepts and prints
// the same summary line, so the single-core regressions (directed tests,
// compliance, C programs, randomised lockstep) run unchanged with the cache
// in front of the core. With several cores it runs the multi-core programs
// in sw/soc_tests/.
//
// Usage:
//   soc_sim --elf=PROG.elf [options]
//     --waits=SPEC         latency of every port (as tb_core: 0 | N | random[:SEED])
//     --dwaits=SPEC        latency of the memory port alone
//     --max-cycles=N       timeout, default 1,000,000
//     --trace=FILE.vcd     waveform dump (trace build only)
//     --log=FILE           retirement trace of every hart
//     --uart-out=FILE      capture UART output to a file as well
//     --lockstep           golden-ISS lockstep (single-core builds only)
//     --probe-all          check the coherence invariants of every line ever
//                          touched, every cycle (slow; for debugging)
//     --stats              print per-hart and per-cache statistics
//     --quiet              suppress the summary line
//
// ---------------------------------------------------------------------------
// COHERENCE CHECKING
// ---------------------------------------------------------------------------
// Always on. The harness keeps a reference copy of RAM and watches every
// core's data port (the dmon_* outputs). The L1 caches answer each access in
// exactly the cycle it takes effect (gnt and rvalid together), so:
//
//   * every load from RAM must return the reference's current word;
//   * every store to RAM updates the reference in the cycle it is answered.
//
// A stale copy anywhere in the system therefore surfaces as a wrong load on
// the core that reads it, with the cycle, hart and address. In addition, the
// lines touched in each cycle (and one more, in rotation, from everything
// touched so far) are probed in every L1 and the L2 for the invariants: at
// most one modified copy and then no other copy; every valid copy equal to
// the reference; every L1 copy also in the L2 with its sharer bit set; the
// L2's data current when no L1 owns the line; memory current when the L2 copy
// is clean.
//
// Exit: a store of a non-zero word to `tohost` by any hart ends the run, with
// the riscv-tests encoding (1 = pass, (n<<1)|1 = failed check n). Exit status
// as tb_core (0 pass, 1 program failed, 3 halted, 4 timeout, 5 lockstep
// mismatch), plus 6 for a coherence violation.
// ============================================================================

#include "Vsoc_top.h"
#include "verilated.h"

#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <set>
#include <string>
#include <vector>

#include "disasm.h"
#include "elf_loader.h"
#include "golden_iss.h"
#include "memory_model.h"   // WaitConfig
#include "vl_bits.h"

#ifndef SOC_NUM_P
#define SOC_NUM_P 2
#endif
#ifndef SOC_NUM_E
#define SOC_NUM_E 2
#endif

namespace {

constexpr int kNumP = SOC_NUM_P;
constexpr int kN = SOC_NUM_P + SOC_NUM_E;
constexpr int kNL1 = 2 * kN;   // data caches 0..kN-1, instruction caches kN..
constexpr int kLineBits = 256;
const char* const kSimName = "soc_sim";

const char* CoreKind(int h) { return h < kNumP ? "P" : "E"; }

constexpr uint32_t kRamSize = 0x00030000u;
inline bool InRam(uint32_t a) { return a < kRamSize; }

// Background traffic region: 4 KB per traffic port, above every program's
// data and below the harts' stacks.
constexpr uint32_t kTrafficBase = 0x00028000u;
constexpr uint32_t kTrafficBytes = 0x1000u;

struct Options {
  std::string elf_path;
  std::string waits = "0";
  std::string dwaits;
  std::string trace_path;
  std::string log_path;
  std::string uart_path;
  uint64_t max_cycles = 1000000;
  int traffic = 0;
  bool lockstep = false;
  bool probe_all = false;
  bool stats = false;
  bool quiet = false;
};

bool Arg(const char* a, const char* prefix, const char** rest) {
  const size_t n = std::strlen(prefix);
  if (std::strncmp(a, prefix, n) != 0) return false;
  *rest = a + n;
  return true;
}

bool ParseArgs(int argc, char** argv, Options* o, std::string* err) {
  for (int i = 1; i < argc; ++i) {
    const char* a = argv[i];
    const char* v = nullptr;
    if (Arg(a, "--elf=", &v)) o->elf_path = v;
    else if (std::strcmp(a, "--elf") == 0 && i + 1 < argc) o->elf_path = argv[++i];
    else if (Arg(a, "--waits=", &v)) o->waits = v;
    else if (Arg(a, "--dwaits=", &v)) o->dwaits = v;
    else if (Arg(a, "--max-cycles=", &v)) o->max_cycles = std::strtoull(v, nullptr, 0);
    else if (Arg(a, "--trace=", &v)) o->trace_path = v;
    else if (Arg(a, "--log=", &v)) o->log_path = v;
    else if (Arg(a, "--uart-out=", &v)) o->uart_path = v;
    else if (Arg(a, "--traffic=", &v)) o->traffic = std::atoi(v);
    else if (std::strcmp(a, "--lockstep") == 0) o->lockstep = true;
    else if (std::strcmp(a, "--probe-all") == 0) o->probe_all = true;
    else if (std::strcmp(a, "--stats") == 0) o->stats = true;
    else if (std::strcmp(a, "--quiet") == 0) o->quiet = true;
    else {
      *err = std::string("unknown option: ") + a;
      return false;
    }
  }
  if (o->elf_path.empty()) {
    *err = "no --elf given";
    return false;
  }
  if (o->lockstep && kN != 1) {
    *err = "--lockstep needs a single-core build";
    return false;
  }
  return true;
}

struct Retirement {
  uint64_t cycle = 0;
  uint64_t order = 0;
  uint32_t pc = 0, insn = 0, pc_next = 0;
  uint8_t rd = 0;
  uint32_t rd_value = 0;
  uint32_t mem_addr = 0;
  uint8_t mem_rmask = 0, mem_wmask = 0;
  uint32_t mem_rdata = 0, mem_wdata = 0;
  bool trap = false, intr = false, halt = false;
};

std::string Format(int hart, const Retirement& r, const ElfImage& elf) {
  std::string extra;
  char b[128];
  if (r.rd != 0) {
    std::snprintf(b, sizeof(b), " x%u<-0x%08x", r.rd, r.rd_value);
    extra += b;
  }
  if (r.mem_rmask != 0) {
    std::snprintf(b, sizeof(b), " [0x%08x]->0x%08x", r.mem_addr, r.mem_rdata);
    extra += b;
  }
  if (r.mem_wmask != 0) {
    std::snprintf(b, sizeof(b), " [0x%08x]<-0x%08x be=%x", r.mem_addr, r.mem_wdata, r.mem_wmask);
    extra += b;
  }
  if (r.intr) extra += "  <INTERRUPT>";
  else if (r.trap) extra += "  <TRAP>";
  if (r.halt) extra += "  <HALT>";
  char line[512];
  std::snprintf(line, sizeof(line), "%8llu  h%d%s %6llu  0x%08x  %08x  %-28s %-24s%s",
                static_cast<unsigned long long>(r.cycle), hart, CoreKind(hart),
                static_cast<unsigned long long>(r.order), r.pc, r.insn,
                Disassemble(r.insn, r.pc).c_str(), elf.SymbolAt(r.pc).c_str(), extra.c_str());
  return line;
}

// ---------------------------------------------------------------------------
// The program image, as the debug port loads it.
// ---------------------------------------------------------------------------
struct Image {
  std::vector<uint8_t> bytes = std::vector<uint8_t>(kRamSize, 0);
  std::vector<uint32_t> lines;   // lines holding loadable bytes, ascending
  uint32_t tohost = 0;
  uint32_t end = 0;              // first byte past every segment (incl. .bss)
  uint32_t Word(uint32_t a) const {
    return uint32_t(bytes[a]) | (uint32_t(bytes[a + 1]) << 8) | (uint32_t(bytes[a + 2]) << 16) |
           (uint32_t(bytes[a + 3]) << 24);
  }
};

bool BuildImage(const ElfImage& elf, Image* img, std::string* err) {
  std::set<uint32_t> lines;
  for (const ElfSegment& seg : elf.segments()) {
    if (seg.paddr + seg.memsz > kRamSize) {
      *err = "a segment runs past the end of RAM";
      return false;
    }
    for (size_t i = 0; i < seg.data.size(); ++i) {
      img->bytes[seg.paddr + i] = seg.data[i];
      lines.insert((seg.paddr + static_cast<uint32_t>(i)) & ~31u);
    }
    img->end = std::max(img->end, seg.paddr + seg.memsz);
  }
  img->lines.assign(lines.begin(), lines.end());
  if (!elf.Symbol("tohost", &img->tohost)) {
    *err = "the ELF has no `tohost` symbol";
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// A testbench master on the interconnect: one transaction at a time.
// ---------------------------------------------------------------------------
struct TbMaster {
  int port = 0;            // tbm_* index: 0 debug, 1 traffic A, 2 traffic B
  bool active = false;
  bool accepted = false;
  uint32_t addr = 0;
  bool write = false;
  uint32_t wdata[8] = {};
  uint32_t strb = 0;
  uint64_t start = 0;

  void Start(uint32_t a, bool w, const uint32_t* line, uint32_t s, uint64_t now) {
    active = true;
    accepted = false;
    addr = a;
    write = w;
    for (int i = 0; i < 8; ++i) wdata[i] = line ? line[i] : 0;
    strb = s;
    start = now;
  }
  void Drive(Vsoc_top* top) const {
    vlb::Set(top->tbm_req_valid_i, port, 1, active && !accepted);
    vlb::Set(top->tbm_req_addr_i, 32 * port, 32, addr);
    vlb::Set(top->tbm_req_write_i, port, 1, write);
    for (int i = 0; i < 8; ++i) vlb::Set(top->tbm_req_wdata_i, 256 * port + 32 * i, 32, wdata[i]);
    vlb::Set(top->tbm_req_wstrb_i, 32 * port, 32, strb);
    vlb::Set(top->tbm_rsp_ready_i, port, 1, 1);
  }
  // After the design has settled: true when the response arrives this cycle.
  bool Sample(Vsoc_top* top, uint32_t* rdata, bool* err) {
    if (!active) return false;
    if (accepted && vlb::Bit(top->tbm_rsp_valid_o, port)) {
      for (int i = 0; i < 8; ++i)
        rdata[i] = static_cast<uint32_t>(vlb::Get(top->tbm_rsp_rdata_o, 256 * port + 32 * i, 32));
      *err = vlb::Bit(top->tbm_rsp_err_o, port);
      active = false;
      return true;
    }
    if (!accepted && vlb::Bit(top->tbm_req_ready_o, port)) accepted = true;
    return false;
  }
};

// SRAM latency injection: the SRAM is held off for a drawn number of cycles
// (fixed N, or random 0..7) before each cycle in which it may work.
struct StallGen {
  WaitConfig cfg;
  uint64_t rng = 1;
  int left = 0;
  void Init(const WaitConfig& c) {
    cfg = c;
    rng = c.seed * 2862933555777941757ULL + 3037000493ULL;
    left = Draw();
  }
  int Draw() {
    if (cfg.mode != WaitConfig::kRandom) return static_cast<int>(cfg.fixed);
    rng ^= rng >> 12;
    rng ^= rng << 25;
    rng ^= rng >> 27;
    return static_cast<int>(((rng * 0x2545F4914F6CDD1DULL) >> 33) % (cfg.max_random + 1));
  }
  bool Next() {
    if (left == 0) {
      left = Draw();
      return false;
    }
    --left;
    return true;
  }
};

// ---------------------------------------------------------------------------
// Reference memory and the per-cycle coherence checks.
// ---------------------------------------------------------------------------
class CoherenceChecker {
 public:
  explicit CoherenceChecker(const Image& img) : ref_(kRamSize / 4) {
    for (uint32_t a = 0; a < kRamSize; a += 4) ref_[a / 4] = img.Word(a);
  }

  uint32_t Word(uint32_t a) const { return ref_[(a & ~3u) / 4]; }
  void Store(uint32_t a, uint32_t wdata, uint8_t be) {
    uint32_t& w = ref_[(a & ~3u) / 4];
    for (int b = 0; b < 4; ++b)
      if (be & (1u << b)) w = (w & ~(0xFFu << (8 * b))) | (wdata & (0xFFu << (8 * b)));
  }
  void Touch(uint32_t a) {
    if (a < kRamSize && touched_.insert(a & ~31u).second) order_.push_back(a & ~31u);
  }

  // Probes one line in every L1 and the L2; returns an empty string or a
  // diagnosis.
  std::string ProbeLine(Vsoc_top* top, uint32_t line, uint64_t cycle) {
    const bool busy = top->mon_busy_o != 0;
    if (busy && ((top->mon_addr_o & ~31u) == line ||
                 (top->mon_vvalid_o && (top->mon_vaddr_o & ~31u) == line)))
      return "";   // the transaction in flight is between states on this line
    top->dbg_addr_i = line;
    top->eval();
    ++probes_;
    const bool l2_present = top->dbg_l2_present_o != 0;
    const bool l2_dirty = top->dbg_l2_dirty_o != 0;
    const uint64_t sharers = vlb::Get(top->dbg_l2_sharers_o, 0, kNL1);
    int n_m = 0, n_s = 0;
    char b[256];
    auto cache_name = [](int c) {
      char n[32];
      std::snprintf(n, sizeof(n), "hart %d's %s", c % kN, c < kN ? "L1D" : "L1I");
      return std::string(n);
    };
    for (int c = 0; c < kNL1; ++c) {
      const int st = static_cast<int>(vlb::Get(top->dbg_state_o, 2 * c, 2));
      if (st == 2) ++n_m;
      if (st == 1) ++n_s;
      if (st == 2 && !(c < kNumP)) {
        std::snprintf(b, sizeof(b), "cycle %llu: %s holds %08x in M",
                      static_cast<unsigned long long>(cycle), cache_name(c).c_str(), line);
        return b;
      }
      if (st == 1 || st == 2) {
        for (int w = 0; w < 8; ++w) {
          const uint32_t got = static_cast<uint32_t>(vlb::Get(top->dbg_data_o, kLineBits * c + 32 * w, 32));
          if (got != Word(line + 4 * w)) {
            std::snprintf(b, sizeof(b),
                          "cycle %llu: %s holds a stale %s copy of %08x: word %d is %08x, "
                          "should be %08x",
                          static_cast<unsigned long long>(cycle), cache_name(c).c_str(),
                          st == 2 ? "M" : "S", line, w, got, Word(line + 4 * w));
            return b;
          }
        }
        if (!l2_present || !((sharers >> c) & 1u)) {
          std::snprintf(b, sizeof(b), "cycle %llu: %s holds %08x but the L2 %s",
                        static_cast<unsigned long long>(cycle), cache_name(c).c_str(), line,
                        l2_present ? "has its sharer bit clear" : "does not (inclusion broken)");
          return b;
        }
      }
    }
    if (n_m > 1 || (n_m == 1 && n_s > 0)) {
      std::snprintf(b, sizeof(b), "cycle %llu: line %08x has %d M and %d S copies (SWMR broken)",
                    static_cast<unsigned long long>(cycle), line, n_m, n_s);
      return b;
    }
    if (l2_present && n_m == 0) {
      for (int w = 0; w < 8; ++w) {
        const uint32_t got = static_cast<uint32_t>(vlb::Get(top->dbg_l2_data_o, 32 * w, 32));
        if (got != Word(line + 4 * w)) {
          std::snprintf(b, sizeof(b),
                        "cycle %llu: the L2 holds a stale copy of %08x (word %d %08x, should "
                        "be %08x) and no L1 owns it",
                        static_cast<unsigned long long>(cycle), line, w, got, Word(line + 4 * w));
          return b;
        }
      }
    }
    if (!(l2_present && l2_dirty) && n_m == 0) {
      for (int w = 0; w < 8; ++w) {
        const uint32_t m = static_cast<uint32_t>(vlb::Get(top->dbg_sram_line_o, 32 * w, 32));
        if (m != Word(line + 4 * w)) {
          std::snprintf(b, sizeof(b),
                        "cycle %llu: line %08x is stale in the SRAM (word %d %08x, should be "
                        "%08x) and dirty nowhere",
                        static_cast<unsigned long long>(cycle), line, w, m, Word(line + 4 * w));
          return b;
        }
      }
    }
    return "";
  }

  // The next line of the rotating sweep over everything touched so far.
  bool NextSweep(uint32_t* line) {
    if (order_.empty()) return false;
    *line = order_[sweep_++ % order_.size()];
    return true;
  }
  const std::vector<uint32_t>& all_lines() const { return order_; }
  uint64_t probes() const { return probes_; }
  uint64_t loads_checked = 0;

 private:
  std::vector<uint32_t> ref_;
  std::set<uint32_t> touched_;
  std::vector<uint32_t> order_;
  size_t sweep_ = 0;
  uint64_t probes_ = 0;
};

const char* const kEvNames[8] = {"ld_hit", "ld_miss", "st_hit", "st_miss",
                                 "writeback", "snp_inv", "snp_flush", "uncached"};
const char* const kCmdNames[8] = {"RD", "RDX", "UPGR", "WR", "WB", "UNC_RD", "UNC_WR", "?"};

}  // namespace

// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  Options opt;
  std::string err;
  if (!ParseArgs(argc, argv, &opt, &err)) {
    std::fprintf(stderr, "%s: %s\n", kSimName, err.c_str());
    return 2;
  }
  ElfImage elf;
  if (!elf.Load(opt.elf_path, &err)) {
    std::fprintf(stderr, "%s: %s\n", kSimName, err.c_str());
    return 2;
  }
  WaitConfig wcfg;
  if (!WaitConfig::Parse(opt.waits, &wcfg, &err)) {
    std::fprintf(stderr, "%s: %s\n", kSimName, err.c_str());
    return 2;
  }
  StallGen stall;
  stall.Init(wcfg);
  if (!opt.dwaits.empty()) {
    WaitConfig dcfg;
    if (!WaitConfig::Parse(opt.dwaits, &dcfg, &err)) {
      std::fprintf(stderr, "%s: %s\n", kSimName, err.c_str());
      return 2;
    }
    stall.Init(dcfg);
    wcfg.label_suffix = "/data=" + dcfg.Describe();
  }
  Image img;
  if (!BuildImage(elf, &img, &err)) {
    std::fprintf(stderr, "%s: %s\n", kSimName, err.c_str());
    return 2;
  }
  const uint32_t tohost = img.tohost & ~3u;
  if (opt.traffic > 0 && img.end > kTrafficBase) {
    std::fprintf(stderr, "%s: the program reaches 0x%08x, over the traffic region; --traffic ignored\n",
                 kSimName, img.end);
    opt.traffic = 0;
  }

  auto* top = new Vsoc_top;
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
    std::fprintf(stderr, "%s: --trace needs a trace build\n", kSimName);
    return 2;
  }
#endif

  std::FILE* logf = nullptr;
  if (!opt.log_path.empty()) {
    logf = std::fopen(opt.log_path.c_str(), "w");
    if (logf == nullptr) {
      std::fprintf(stderr, "%s: cannot write %s\n", kSimName, opt.log_path.c_str());
      return 2;
    }
  }

  GoldenIss iss;
  iss.Configure(kNumP == 1, kNumP == 1 ? 7 : 4);
  if (opt.lockstep && !iss.Load(elf, &err)) {
    std::fprintf(stderr, "%s: %s\n", kSimName, err.c_str());
    return 2;
  }
  int lockstep_errors = 0;

  CoherenceChecker coh(img);
  std::string coh_error;

  std::vector<std::deque<Retirement>> history(kN);
  std::vector<uint64_t> retired(kN, 0), trapped(kN, 0);
  uint64_t events[kNL1][8] = {};
  uint64_t l2ev[4] = {};
  uint64_t txns[8] = {};
  uint64_t fab_grants[4] = {}, fab_waits[4] = {};
  std::string uart;
  TbMaster tbm[3];
  for (int k = 0; k < 3; ++k) tbm[k].port = k;
  // Traffic ports' shadow of their own regions (the only writers there).
  std::vector<uint32_t> traffic_ref(2 * kTrafficBytes / 4, 0);
  uint64_t traffic_rng = 0x5EED0000ULL + wcfg.seed;
  uint64_t traffic_done[2] = {}, traffic_checked = 0;
  std::string traffic_error;
  uint64_t cycle = 0;
  bool exited = false, halted = false, timeout = false;
  uint32_t tohost_raw = 0;
  int exit_hart = -1, halt_hart = -1;

  // ---- reset ----
  top->rst_ni = 0;
  top->cpu_rst_ni = 0;
  top->clk_i = 0;
  top->mem_stall_i = 0;
  top->dbg_addr_i = 0;
  for (int k = 0; k < 3; ++k) tbm[k].Drive(top);
  for (int i = 0; i < 5; ++i) {
    top->clk_i = 0;
    top->eval();
    top->clk_i = 1;
    top->eval();
  }
  top->rst_ni = 1;

  // ---- load the program through the debug port, CPUs still in reset ----
  uint64_t load_cycles = 0;
  for (uint32_t line : img.lines) {
    uint32_t data[8];
    for (int w = 0; w < 8; ++w) data[w] = img.Word(line + 4 * w);
    tbm[0].Start(line, true, data, 0xFFFFFFFFu, load_cycles);
    bool done = false;
    while (!done) {
      tbm[0].Drive(top);
      top->clk_i = 0;
      top->eval();
      uint32_t rdata[8];
      bool lerr = false;
      done = tbm[0].Sample(top, rdata, &lerr);
      if (done && lerr) {
        std::fprintf(stderr, "%s: loading line 0x%08x failed\n", kSimName, line);
        return 2;
      }
      top->clk_i = 1;
      top->eval();
      if (++load_cycles > 10000000) {
        std::fprintf(stderr, "%s: the loader hung\n", kSimName);
        return 2;
      }
    }
  }
  tbm[0].Drive(top);
  top->cpu_rst_ni = 1;

  // ---- main loop ----
  while (!exited && !halted && lockstep_errors == 0 && coh_error.empty()) {
    if (cycle >= opt.max_cycles) {
      timeout = true;
      break;
    }

    // 1. settle the design's outputs
    top->clk_i = 0;
    top->eval();

    // 2. the testbench's inputs for this cycle: SRAM latency and the
    //    traffic ports (which only ever start a transaction between cycles,
    //    in step 5)
    top->mem_stall_i = stall.Next();
    for (int k = 0; k < 3; ++k) tbm[k].Drive(top);
    top->eval();

    if (top->uart_tx_valid_o) uart.push_back(static_cast<char>(top->uart_tx_byte_o));
    for (int m = 0; m < 4; ++m) {
      if ((top->fab_grant_o >> m) & 1u) ++fab_grants[m];
      if ((top->fab_wait_o >> m) & 1u) ++fab_waits[m];
    }
    for (int k = 1; k < 3; ++k) {
      uint32_t rdata[8];
      bool terr = false;
      if (!tbm[k].Sample(top, rdata, &terr)) continue;
      ++traffic_done[k - 1];
      if (terr && traffic_error.empty()) traffic_error = "traffic access returned an error";
      if (!tbm[k].write) {
        const uint32_t base = (tbm[k].addr - kTrafficBase) / 4;
        for (int w = 0; w < 8 && traffic_error.empty(); ++w) {
          ++traffic_checked;
          if (rdata[w] != traffic_ref[base + w]) {
            char b[160];
            std::snprintf(b, sizeof(b), "cycle %llu: traffic port %c read %08x from %08x, wrote %08x",
                          static_cast<unsigned long long>(cycle), 'A' + k - 1, rdata[w],
                          tbm[k].addr + 4 * w, traffic_ref[base + w]);
            traffic_error = b;
          }
        }
      }
    }
    if (!traffic_error.empty() && coh_error.empty()) coh_error = traffic_error;

    // 3a. data ports: collect this cycle's completed accesses
    struct Acc { int h; uint32_t addr; bool we; uint8_t be; uint32_t wdata, rdata; bool err; };
    Acc acc[kN];
    int nacc = 0;
    std::vector<uint32_t> probe_lines;
    for (int h = 0; h < kN; ++h) {
      const bool gnt = vlb::Bit(top->dmon_gnt_o, h);
      const bool rvalid = vlb::Bit(top->dmon_rvalid_o, h);
      if (gnt != rvalid && coh_error.empty()) {
        char b[128];
        std::snprintf(b, sizeof(b), "cycle %llu: hart %d's L1 answered gnt=%d rvalid=%d",
                      static_cast<unsigned long long>(cycle), h, gnt, rvalid);
        coh_error = b;
      }
      if (!gnt) continue;
      Acc& a = acc[nacc++];
      a.h = h;
      a.addr = static_cast<uint32_t>(vlb::Get(top->dmon_addr_o, 32 * h, 32));
      a.we = vlb::Bit(top->dmon_we_o, h);
      a.be = static_cast<uint8_t>(vlb::Get(top->dmon_be_o, 4 * h, 4));
      a.wdata = static_cast<uint32_t>(vlb::Get(top->dmon_wdata_o, 32 * h, 32));
      a.rdata = static_cast<uint32_t>(vlb::Get(top->dmon_rdata_o, 32 * h, 32));
      a.err = vlb::Bit(top->dmon_err_o, h);
      if (InRam(a.addr)) {
        coh.Touch(a.addr);
        probe_lines.push_back(a.addr & ~31u);
      }
    }
    if (top->mon_done_o) {
      ++txns[top->mon_cmd_o & 7];
      if (InRam(top->mon_addr_o)) probe_lines.push_back(top->mon_addr_o & ~31u);
    }
    for (int c = 0; c < kNL1; ++c) {
      const uint64_t ev = vlb::Get(top->events_o, 8 * c, 8);
      for (int e = 0; e < 8; ++e)
        if ((ev >> e) & 1u) ++events[c][e];
    }
    for (int e = 0; e < 4; ++e)
      if ((top->l2_events_o >> e) & 1u) ++l2ev[e];

    // 3b. MSI invariants, against the reference as it stands before this
    //     cycle's stores (what the cache arrays hold until the clock edge)
    if (coh_error.empty()) {
      uint32_t sweep;
      if (coh.NextSweep(&sweep)) probe_lines.push_back(sweep);
      const std::vector<uint32_t>& lines = opt.probe_all ? coh.all_lines() : probe_lines;
      for (uint32_t line : lines) {
        coh_error = coh.ProbeLine(top, line, cycle);
        if (!coh_error.empty()) break;
      }
    }

    // 3c. load values, then this cycle's stores
    for (int i = 0; i < nacc && coh_error.empty(); ++i) {
      const Acc& a = acc[i];
      if (!a.we && !a.err && InRam(a.addr)) {
        ++coh.loads_checked;
        if (a.rdata != coh.Word(a.addr)) {
          char b[200];
          std::snprintf(b, sizeof(b),
                        "cycle %llu: hart %d (%s-core) loaded %08x from %08x; the coherent "
                        "value is %08x",
                        static_cast<unsigned long long>(cycle), a.h, CoreKind(a.h), a.rdata,
                        a.addr & ~3u, coh.Word(a.addr));
          coh_error = b;
        }
      }
      if (a.err && InRam(a.addr)) coh_error = "access error from RAM";
    }
    for (int i = 0; i < nacc; ++i) {
      const Acc& a = acc[i];
      if (!a.we || a.err || !InRam(a.addr)) continue;
      coh.Store(a.addr, a.wdata, a.be);
      if ((a.addr & ~3u) == tohost && coh.Word(tohost) != 0 && !exited) {
        exited = true;
        tohost_raw = coh.Word(tohost);
        exit_hart = a.h;
      }
    }

    // 3d. retirements
    for (int h = 0; h < kN; ++h) {
      if (!vlb::Bit(top->rvfi_valid_o, h)) continue;
      Retirement r;
      r.cycle = cycle;
      r.order = vlb::Get(top->rvfi_order_o, 64 * h, 64);
      r.pc = static_cast<uint32_t>(vlb::Get(top->rvfi_pc_rdata_o, 32 * h, 32));
      r.insn = static_cast<uint32_t>(vlb::Get(top->rvfi_insn_o, 32 * h, 32));
      r.pc_next = static_cast<uint32_t>(vlb::Get(top->rvfi_pc_wdata_o, 32 * h, 32));
      r.rd = static_cast<uint8_t>(vlb::Get(top->rvfi_rd_addr_o, 5 * h, 5));
      r.rd_value = static_cast<uint32_t>(vlb::Get(top->rvfi_rd_wdata_o, 32 * h, 32));
      r.mem_addr = static_cast<uint32_t>(vlb::Get(top->rvfi_mem_addr_o, 32 * h, 32));
      r.mem_rmask = static_cast<uint8_t>(vlb::Get(top->rvfi_mem_rmask_o, 4 * h, 4));
      r.mem_wmask = static_cast<uint8_t>(vlb::Get(top->rvfi_mem_wmask_o, 4 * h, 4));
      r.mem_rdata = static_cast<uint32_t>(vlb::Get(top->rvfi_mem_rdata_o, 32 * h, 32));
      r.mem_wdata = static_cast<uint32_t>(vlb::Get(top->rvfi_mem_wdata_o, 32 * h, 32));
      r.trap = vlb::Bit(top->rvfi_trap_o, h);
      r.intr = vlb::Bit(top->rvfi_intr_o, h);
      r.halt = vlb::Bit(top->rvfi_halt_o, h);
      if (logf) std::fprintf(logf, "%s\n", Format(h, r, elf).c_str());
      history[h].push_back(r);
      if (history[h].size() > 30) history[h].pop_front();
      if (r.trap) ++trapped[h]; else ++retired[h];
      if (r.halt) {
        halted = true;
        halt_hart = h;
      }

      if (opt.lockstep && lockstep_errors == 0) {
        const IssStep e = iss.Step();
        auto mismatch = [&](const char* field, uint64_t got, uint64_t exp) {
          if (got == exp || lockstep_errors++ > 0) return;
          std::fprintf(stderr,
                       "\n%s: LOCKSTEP MISMATCH on %s\n"
                       "  RTL  pc 0x%08x insn 0x%08x  %s\n"
                       "  ISS  pc 0x%08x insn 0x%08x  %s\n"
                       "  %-10s : RTL 0x%llx  ISS 0x%llx\n",
                       kSimName, field, r.pc, r.insn, Disassemble(r.insn, r.pc).c_str(), e.pc,
                       e.insn, Disassemble(e.insn, e.pc).c_str(), field,
                       static_cast<unsigned long long>(got), static_cast<unsigned long long>(exp));
        };
        mismatch("pc", r.pc, e.pc);
        mismatch("insn", r.insn, e.insn);
        mismatch("trap", r.trap, e.trap);
        if (!r.trap && !e.trap) {
          mismatch("pc_next", r.pc_next, e.pc_next);
          mismatch("rd_addr", r.rd, e.rd);
          if (e.rd != 0) {
            if (e.rd_unpredictable) iss.AdoptReg(e.rd, r.rd_value);
            else mismatch("rd_value", r.rd_value, e.rd_value);
          }
          mismatch("mem_wmask", r.mem_wmask, e.mem_wmask);
          if (e.mem_wmask != 0) {
            mismatch("mem_addr", r.mem_addr, e.mem_addr);
            uint32_t m = 0;
            for (int l = 0; l < 4; ++l)
              if (e.mem_wmask & (1u << l)) m |= 0xFFu << (8 * l);
            mismatch("mem_wdata", r.mem_wdata & m, e.mem_wdata & m);
          }
          mismatch("mem_rmask", r.mem_rmask, e.mem_rmask);
        }
      }
    }

#if VM_TRACE
    if (vcd) vcd->dump(cycle * 2);
#endif
    // 4. clock edge
    top->clk_i = 1;
    top->eval();
#if VM_TRACE
    if (vcd) vcd->dump(cycle * 2 + 1);
#endif
    // 5. traffic ports start new transactions for the next cycle
    if (opt.traffic > 0) {
      for (int k = 1; k < 3; ++k) {
        if (tbm[k].active) continue;
        traffic_rng ^= traffic_rng << 13;
        traffic_rng ^= traffic_rng >> 7;
        traffic_rng ^= traffic_rng << 17;
        if (static_cast<int>(traffic_rng % 100) >= opt.traffic) continue;
        const uint32_t off = static_cast<uint32_t>((traffic_rng >> 8) % (kTrafficBytes / 32)) * 32;
        const uint32_t addr = kTrafficBase + (k - 1) * kTrafficBytes + off;
        const bool write = ((traffic_rng >> 20) & 1) != 0;
        uint32_t data[8];
        const uint32_t strb = write ? static_cast<uint32_t>(traffic_rng >> 24) | 1u : 0u;
        const uint32_t base = (addr - kTrafficBase) / 4;
        for (int w = 0; w < 8; ++w) {
          data[w] = static_cast<uint32_t>(traffic_rng * (w + 1) ^ cycle);
          if (!write) continue;
          for (int b = 0; b < 4; ++b) {
            if ((strb >> (4 * w + b)) & 1u) {
              const uint32_t mask = 0xFFu << (8 * b);
              traffic_ref[base + w] = (traffic_ref[base + w] & ~mask) | (data[w] & mask);
            }
          }
        }
        tbm[k].Start(addr, write, data, strb, cycle);
      }
    }
    ++cycle;
  }

  top->final();
#if VM_TRACE
  if (vcd) {
    vcd->close();
    delete vcd;
  }
#endif
  if (logf) std::fclose(logf);

  if (!uart.empty()) {
    std::fwrite(uart.data(), 1, uart.size(), stdout);
    if (uart.back() != '\n') std::fputc('\n', stdout);
  }
  if (!opt.uart_path.empty()) {
    if (std::FILE* uf = std::fopen(opt.uart_path.c_str(), "w")) {
      std::fwrite(uart.data(), 1, uart.size(), uf);
      std::fclose(uf);
    }
  }

  uint64_t total_retired = 0, total_trapped = 0;
  for (int h = 0; h < kN; ++h) {
    total_retired += retired[h];
    total_trapped += trapped[h];
  }

  auto dump = [&](const char* why) {
    std::fprintf(stderr, "\n=== %s ===\nprogram : %s\nwaits   : %s\ncycles  : %llu\n", why,
                 opt.elf_path.c_str(), wcfg.Describe().c_str(),
                 static_cast<unsigned long long>(cycle));
    for (int h = 0; h < kN; ++h) {
      std::fprintf(stderr, "\nhart %d (%s-core): retired %llu, traps %llu; last %zu:\n", h,
                   CoreKind(h), static_cast<unsigned long long>(retired[h]),
                   static_cast<unsigned long long>(trapped[h]), history[h].size());
      for (const Retirement& r : history[h]) std::fprintf(stderr, "%s\n", Format(h, r, elf).c_str());
    }
    std::fprintf(stderr, "\n");
  };

  int rc = 0;
  if (!coh_error.empty()) {
    std::fprintf(stderr, "\n%s: COHERENCE VIOLATION: %s\n", kSimName, coh_error.c_str());
    dump("COHERENCE VIOLATION");
    rc = 6;
  } else if (lockstep_errors > 0) {
    dump("LOCKSTEP MISMATCH");
    rc = 5;
  } else if (halted) {
    std::fprintf(stderr, "\n%s: hart %d HALTED\n", kSimName, halt_hart);
    dump("CORE HALTED");
    rc = 3;
  } else if (timeout) {
    std::fprintf(stderr, "\n%s: TIMEOUT after %llu cycles\n", kSimName,
                 static_cast<unsigned long long>(cycle));
    dump("TIMEOUT");
    rc = 4;
  } else if (tohost_raw != 1u) {
    std::fprintf(stderr, "\n%s: PROGRAM FAILED on hart %d, tohost=%u (raw 0x%08x)\n", kSimName,
                 exit_hart, tohost_raw >> 1, tohost_raw);
    dump("PROGRAM FAILED");
    rc = 1;
  }

  if (opt.stats) {
    std::printf("%s stats (%d P + %d E):\n", kSimName, kNumP, kN - kNumP);
    for (int h = 0; h < kN; ++h) {
      std::printf("  hart %d (%s): instret=%llu\n", h, CoreKind(h),
                  static_cast<unsigned long long>(retired[h]));
      for (int side = 0; side < 2; ++side) {
        const int c = side * kN + h;
        std::printf("    %s:", side == 0 ? "L1D" : "L1I");
        for (int e = 0; e < 8; ++e) {
          if (side == 1 && (e == 2 || e == 3 || e == 4)) continue;   // no stores
          std::printf(" %s=%llu", kEvNames[e], static_cast<unsigned long long>(events[c][e]));
        }
        std::printf("\n");
      }
    }
    std::printf("  L2: hit=%llu miss=%llu writeback=%llu back_invalidate=%llu\n",
                static_cast<unsigned long long>(l2ev[0]), static_cast<unsigned long long>(l2ev[1]),
                static_cast<unsigned long long>(l2ev[2]), static_cast<unsigned long long>(l2ev[3]));
    std::printf("  bus:");
    for (int c = 0; c < 7; ++c)
      std::printf(" %s=%llu", kCmdNames[c], static_cast<unsigned long long>(txns[c]));
    std::printf("\n  interconnect (grants / wait cycles): cpu %llu/%llu  debug %llu/%llu  "
                "A %llu/%llu  B %llu/%llu\n",
                static_cast<unsigned long long>(fab_grants[0]), static_cast<unsigned long long>(fab_waits[0]),
                static_cast<unsigned long long>(fab_grants[1]), static_cast<unsigned long long>(fab_waits[1]),
                static_cast<unsigned long long>(fab_grants[2]), static_cast<unsigned long long>(fab_waits[2]),
                static_cast<unsigned long long>(fab_grants[3]), static_cast<unsigned long long>(fab_waits[3]));
    std::printf("  loader: %zu lines in %llu cycles; traffic: A %llu, B %llu transactions, %llu words checked\n",
                img.lines.size(), static_cast<unsigned long long>(load_cycles),
                static_cast<unsigned long long>(traffic_done[0]),
                static_cast<unsigned long long>(traffic_done[1]),
                static_cast<unsigned long long>(traffic_checked));
    std::printf("  coherence: loads_checked=%llu line_probes=%llu lines_touched=%zu\n",
                static_cast<unsigned long long>(coh.loads_checked),
                static_cast<unsigned long long>(coh.probes()), coh.all_lines().size());
  }
  if (!opt.quiet) {
    std::printf("%s: %s  cycles=%llu instret=%llu traps=%llu waits=%s%s%s\n", kSimName,
                rc == 0 ? "PASS" : "FAIL", static_cast<unsigned long long>(cycle),
                static_cast<unsigned long long>(total_retired),
                static_cast<unsigned long long>(total_trapped), wcfg.Describe().c_str(),
                opt.lockstep ? " lockstep=on" : "", rc == 0 ? "" : "  <-- see stderr");
  }
  delete top;
  return rc;
}
