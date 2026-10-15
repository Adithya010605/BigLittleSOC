// ============================================================================
// coh_harness.h — test harness for rtl/coherence/coherent_mem.sv
//
// Drives every core port of the coherent memory system -- each core's data
// port and its instruction port -- with requests that obey the cores'
// protocol (hold until gnt), backs the L2's memory port with a memory model
// of configurable latency, and checks, every cycle:
//
//   1. ATOMICITY   gnt and rvalid rise together on every port. The caches
//                  promise this; the checks below depend on it.
//   2. VALUES      every load and every instruction fetch returns the word
//                  the reference memory holds. The reference applies each
//                  store in the cycle the issuing port is answered, which (by
//                  1) is the cycle the store takes effect. This is the
//                  coherence oracle: any stale copy, in any L1 or in the L2,
//                  shows up as a wrong load.
//   3. SWMR        for every line touched so far: at most one L1 holds it M,
//                  and then no other L1 holds it at all. Write-through data
//                  caches and instruction caches never hold M.
//   4. COPIES      every valid L1 copy (S or M) holds exactly the reference
//                  data.
//   5. INCLUSION   every line held by an L1 is held by the L2, with that L1's
//                  sharer bit set (the snoop filter never misses a holder).
//   6. L2 DATA     a line the L2 holds and no L1 holds M has the reference
//                  data in the L2.
//   7. MEMORY      a line the L2 does not hold dirty, and no L1 holds M, is
//                  the same in memory as in the reference. This is what
//                  catches a lost writeback anywhere in the hierarchy.
//   8. LIVENESS    no request waits longer than a bound.
//
// Checks 3-7 read the caches through the design's debug probe, one line at a
// time, between settling the cycle and the clock edge, and skip the line (and
// the L2 victim) of the transaction in flight, which is legitimately between
// states.
//
// Ports are numbered like the L1s: 0 .. kN-1 the cores' data ports, kN ..
// 2*kN-1 their instruction ports (loads only).
// ============================================================================
#ifndef COH_HARNESS_H
#define COH_HARNESS_H

#include "Vcoherent_mem.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <set>
#include <string>
#include <vector>

#include "../../integration/vl_bits.h"
#include "tb_common.h"

#ifndef COH_NUM_WB
#define COH_NUM_WB 2
#endif
#ifndef COH_NUM_WT
#define COH_NUM_WT 2
#endif
#ifndef COH_WB_SETS
#define COH_WB_SETS 256
#endif
#ifndef COH_WT_SETS
#define COH_WT_SETS 256
#endif
#ifndef COH_L2_SETS
#define COH_L2_SETS 512
#endif

namespace coh {

constexpr int kN = COH_NUM_WB + COH_NUM_WT;   // cores
constexpr int kNL1 = 2 * kN;                   // L1 caches = ports
constexpr int kLineBytes = 32;
constexpr int kLineBits = 256;
constexpr uint32_t kRamSize = 0x00030000u;
// A small register file standing in for MMIO, reached by uncached accesses.
constexpr uint32_t kMmioBase = 0x10000000u;
constexpr uint32_t kMmioWords = 64;

enum Cmd { RD = 0, RDX = 1, UPGR = 2, WR = 3, WB = 4, UNC_RD = 5, UNC_WR = 6 };
enum Msi { I = 0, S = 1, M = 2 };
enum L2Ev { L2_HIT = 0, L2_MISS = 1, L2_WRITEBACK = 2, L2_BACKINV = 3 };

inline const char* CmdName(int c) {
  static const char* kNames[] = {"RD", "RDX", "UPGR", "WR", "WB", "UNC_RD", "UNC_WR", "?"};
  return kNames[(c >= 0 && c < 7) ? c : 7];
}
inline const char* MsiName(int s) {
  static const char* kNames[] = {"I", "S", "M", "?"};
  return kNames[(s >= 0 && s < 3) ? s : 3];
}
inline bool IsInstr(int p) { return p >= kN; }
// Only the P-cores' data caches may own a line.
inline bool MayOwn(int p) { return p < COH_NUM_WB; }
inline uint32_t LineOf(uint32_t a) { return a & ~uint32_t(kLineBytes - 1); }

struct BusTxn {
  int master = 0;
  int cmd = 0;
  uint32_t addr = 0;
  bool shared = false;
  bool dirty = false;
  uint64_t cycle = 0;

  std::string Str() const {
    char b[96];
    std::snprintf(b, sizeof(b), "L1 %d %-6s %08x%s%s", master, CmdName(cmd), addr,
                  shared ? " shared" : "", dirty ? " dirty" : "");
    return b;
  }
};

struct Access {
  uint32_t addr = 0;
  bool we = false;
  uint8_t be = 0xF;
  uint32_t wdata = 0;
};

struct L2Line {
  bool present = false;
  bool dirty = false;
  uint32_t sharers = 0;
};

class Harness {
 public:
  explicit Harness(uint64_t seed) : rng_(seed), ram_(kRamSize, 0), ref_(kRamSize, 0) {
    top_ = new Vcoherent_mem;
    // Memory starts with a recognisable, address-dependent pattern so that a
    // load returning the wrong line is never accidentally right.
    for (uint32_t a = 0; a < kRamSize; a += 4) {
      const uint32_t v = a * 0x9E3779B1u ^ 0xA5A5A5A5u;
      for (int b = 0; b < 4; ++b) {
        ram_[a + b] = static_cast<uint8_t>(v >> (8 * b));
        ref_[a + b] = ram_[a + b];
      }
    }
    for (uint32_t i = 0; i < kMmioWords; ++i) mmio_[i] = mmio_ref_[i] = 0x10000000u + i;
    if (const char* t = std::getenv("COH_TRACE")) trace_until_ = std::strtoull(t, nullptr, 0);
    Reset();
  }
  ~Harness() {
    top_->final();
    delete top_;
  }

  Vcoherent_mem* top() { return top_; }
  uint64_t cycle() const { return cycle_; }

  // ---- configuration ----
  void SetMemLatency(bool random, int value) {
    lat_random_ = random;
    lat_value_ = value;
    mem_wait_ = DrawLatency();
  }
  void SetProbe(bool on) { probe_ = on; }
  void SetLivenessBound(uint64_t c) { liveness_bound_ = c; }
  // Prints every bus transaction and port completion up to `until` cycles
  // (COH_TRACE=<cycles> in the environment sets it for every harness).
  void SetTrace(uint64_t until) { trace_until_ = until; }

  // ---- issuing ----
  bool Busy(int p) const { return port_[p].busy; }
  bool AnyBusy() const {
    for (int p = 0; p < kNL1; ++p)
      if (port_[p].busy) return true;
    return false;
  }
  void Issue(int p, const Access& a) {
    Port& pt = port_[p];
    pt.busy = true;
    pt.acc = a;
    if (IsInstr(p)) {
      pt.acc.we = false;
      pt.acc.be = 0xF;
    }
    pt.start = cycle_;
    if (a.addr < kRamSize) touched_.insert(LineOf(a.addr));
  }

  // ---- running ----
  void Cycle();
  bool Drain(uint64_t max_cycles = 20000) {
    const uint64_t end = cycle_ + max_cycles;
    while (AnyBusy() && cycle_ < end) Cycle();
    return tb::Check(!AnyBusy(), "drain: a port never completed");
  }
  void Idle(int cycles) {
    for (int i = 0; i < cycles; ++i) Cycle();
  }

  // Blocking helpers for directed tests: one access on one port.
  uint32_t Load(int p, uint32_t addr) {
    Issue(p, Access{addr, false, 0xF, 0});
    Drain();
    return port_[p].last_rdata;
  }
  void Store(int p, uint32_t addr, uint32_t data, uint8_t be = 0xF) {
    Issue(p, Access{addr, true, be, data});
    Drain();
  }
  bool LastErr(int p) const { return port_[p].last_err; }

  // Bus transactions completed since the last call.
  std::vector<BusTxn> TakeBus() {
    std::vector<BusTxn> r(bus_log_.begin(), bus_log_.end());
    bus_log_.clear();
    return r;
  }

  // Probes (settle the model; call between cycles only).
  int StateOf(int p, uint32_t addr) {
    top_->dbg_addr_i = addr;
    top_->eval();
    return static_cast<int>(vlb::Get(top_->dbg_state_o, 2 * p, 2));
  }
  L2Line L2Of(uint32_t addr) {
    top_->dbg_addr_i = addr;
    top_->eval();
    return L2Line{top_->dbg_l2_present_o != 0, top_->dbg_l2_dirty_o != 0,
                  static_cast<uint32_t>(vlb::Get(top_->dbg_l2_sharers_o, 0, kNL1))};
  }
  uint32_t L2Word(uint32_t addr) {
    top_->dbg_addr_i = LineOf(addr);
    top_->eval();
    return static_cast<uint32_t>(vlb::Get(top_->dbg_l2_data_o, 32 * ((addr >> 2) & 7), 32));
  }

  uint32_t RefWord(uint32_t addr) const { return Word(ref_, addr & ~3u); }
  uint32_t RamWord(uint32_t addr) const { return Word(ram_, addr & ~3u); }
  uint64_t mem_accesses() const { return mem_accesses_; }

  // ---- statistics ----
  uint64_t events(int p, int ev) const { return events_[p][ev]; }
  uint64_t l2_events(int ev) const { return l2_events_[ev]; }
  uint64_t txn_count(int cmd) const { return txn_count_[cmd]; }
  uint64_t completed() const { return completed_; }
  uint64_t max_latency() const { return max_latency_; }

  // Randomised traffic on every port over a pool of lines.
  void Randomise(uint64_t cycles, const std::vector<uint32_t>& pool, int issue_pct);

 private:
  // The memory request as it stood in the cycle being simulated. Captured
  // before the clock edge: after it, the bus already shows its next state.
  struct MemReq {
    bool req = false;
    bool we = false;
    bool uncached = false;
    uint32_t addr = 0;
    uint32_t wdata[8] = {};
    uint32_t be = 0;
  };

  struct Port {
    bool busy = false;
    Access acc;
    uint64_t start = 0;
    uint32_t last_rdata = 0;
    bool last_err = false;
  };

  static uint32_t Word(const std::vector<uint8_t>& m, uint32_t a) {
    return uint32_t(m[a]) | (uint32_t(m[a + 1]) << 8) | (uint32_t(m[a + 2]) << 16) |
           (uint32_t(m[a + 3]) << 24);
  }

  int DrawLatency() {
    if (!lat_random_) return lat_value_;
    return static_cast<int>(rng_.Next() % static_cast<uint64_t>(lat_value_ + 1));
  }

  void Reset() {
    top_->rst_ni = 0;
    top_->clk_i = 0;
    top_->core_req_i = 0;
    top_->instr_req_i = 0;
    top_->mem_rvalid_i = 0;
    top_->mem_err_i = 0;
    top_->dbg_addr_i = 0;
    for (int i = 0; i < 4; ++i) {
      top_->clk_i = 0;
      top_->eval();
      top_->clk_i = 1;
      top_->eval();
    }
    top_->rst_ni = 1;
    top_->clk_i = 0;
    top_->eval();
  }

  void DriveRequests();
  void MemEvaluate();
  MemReq CaptureMem() const;
  void MemTick(const MemReq& q);
  void Sample();
  void ProbeChecks();
  void Report(const char* fmt, uint32_t line, int a = 0, int b = 0);

  Vcoherent_mem* top_ = nullptr;
  tb::Rng rng_;
  uint64_t cycle_ = 0;

  std::vector<uint8_t> ram_;   // the memory behind the L2
  std::vector<uint8_t> ref_;   // the reference: what memory should hold
  uint32_t mmio_[kMmioWords];
  uint32_t mmio_ref_[kMmioWords];

  Port port_[kNL1];
  std::set<uint32_t> touched_;
  std::deque<BusTxn> bus_log_;

  bool lat_random_ = false;
  int lat_value_ = 0;
  int mem_wait_ = 0;
  uint64_t mem_accesses_ = 0;

  bool probe_ = true;
  uint64_t liveness_bound_ = 5000;
  uint64_t trace_until_ = 0;

  uint64_t events_[kNL1][8] = {};
  uint64_t l2_events_[4] = {};
  uint64_t txn_count_[8] = {};
  uint64_t completed_ = 0;
  uint64_t max_latency_ = 0;
  int failures_reported_ = 0;
};

// ---------------------------------------------------------------------------
inline void Harness::DriveRequests() {
  for (int p = 0; p < kN; ++p) {
    const Port& d = port_[p];
    vlb::Set(top_->core_req_i, p, 1, d.busy ? 1 : 0);
    vlb::Set(top_->core_addr_i, 32 * p, 32, d.acc.addr);
    vlb::Set(top_->core_we_i, p, 1, d.acc.we ? 1 : 0);
    vlb::Set(top_->core_be_i, 4 * p, 4, d.acc.be);
    vlb::Set(top_->core_wdata_i, 32 * p, 32, d.acc.wdata);
    const Port& i = port_[kN + p];
    vlb::Set(top_->instr_req_i, p, 1, i.busy ? 1 : 0);
    vlb::Set(top_->instr_addr_i, 32 * p, 32, i.acc.addr);
  }
}

inline void Harness::MemEvaluate() {
  top_->mem_rvalid_i = 0;
  top_->mem_err_i = 0;
  if (!top_->mem_req_o || mem_wait_ != 0) return;
  top_->mem_rvalid_i = 1;
  const uint32_t addr = top_->mem_addr_o;
  if (top_->mem_uncached_o) {
    const uint32_t slot = (addr >> 2) & 7u;
    uint32_t v = 0;
    if (addr >= kMmioBase && addr < kMmioBase + 4 * kMmioWords) {
      v = mmio_[(addr - kMmioBase) >> 2];
    } else {
      top_->mem_err_i = 1;
    }
    for (int w = 0; w < 8; ++w) vlb::Set(top_->mem_rdata_i, 32 * w, 32, w == int(slot) ? v : 0);
    return;
  }
  if (addr + kLineBytes > kRamSize) {
    top_->mem_err_i = 1;
    return;
  }
  for (int w = 0; w < 8; ++w) vlb::Set(top_->mem_rdata_i, 32 * w, 32, Word(ram_, addr + 4 * w));
}

inline Harness::MemReq Harness::CaptureMem() const {
  MemReq q;
  q.req = top_->mem_req_o != 0;
  q.we = top_->mem_we_o != 0;
  q.uncached = top_->mem_uncached_o != 0;
  q.addr = top_->mem_addr_o;
  for (int w = 0; w < 8; ++w) q.wdata[w] = static_cast<uint32_t>(vlb::Get(top_->mem_wdata_o, 32 * w, 32));
  q.be = static_cast<uint32_t>(vlb::Get(top_->mem_be_o, 0, 32));
  return q;
}

inline void Harness::MemTick(const MemReq& q) {
  if (!q.req) return;
  if (mem_wait_ > 0) {
    --mem_wait_;
    return;
  }
  ++mem_accesses_;
  if (q.we) {
    if (q.uncached) {
      if (q.addr >= kMmioBase && q.addr < kMmioBase + 4 * kMmioWords) {
        const uint32_t slot = (q.addr >> 2) & 7u;
        const uint32_t w = q.wdata[slot];
        const uint32_t be = (q.be >> (4 * slot)) & 0xFu;
        uint32_t& r = mmio_[(q.addr - kMmioBase) >> 2];
        for (int b = 0; b < 4; ++b)
          if (be & (1u << b)) r = (r & ~(0xFFu << (8 * b))) | (w & (0xFFu << (8 * b)));
      }
    } else if (q.addr + kLineBytes <= kRamSize) {
      for (int b = 0; b < kLineBytes; ++b) {
        if ((q.be >> b) & 1u)
          ram_[q.addr + b] = static_cast<uint8_t>(q.wdata[b / 4] >> (8 * (b % 4)));
      }
    }
  }
  mem_wait_ = DrawLatency();
}

inline void Harness::Report(const char* fmt, uint32_t line, int a, int b) {
  if (failures_reported_++ >= 10) {
    ++tb::g_failures;
    return;
  }
  char msg[200];
  char head[48];
  std::snprintf(head, sizeof(head), "cycle %llu: ", static_cast<unsigned long long>(cycle_));
  std::snprintf(msg, sizeof(msg), fmt, line, a, b);
  tb::Check(false, std::string(head) + msg);
}

// Everything observable in this cycle, after the design has settled and
// before the clock edge.
inline void Harness::Sample() {
  if (top_->mon_done_o) {
    BusTxn t;
    t.master = static_cast<int>(top_->mon_master_o);
    t.cmd = static_cast<int>(top_->mon_cmd_o);
    t.addr = top_->mon_addr_o;
    if (t.cmd <= WB) t.addr = LineOf(t.addr);
    t.shared = top_->mon_shared_o != 0;
    t.dirty = top_->mon_dirty_o != 0;
    t.cycle = cycle_;
    bus_log_.push_back(t);
    if (bus_log_.size() > 4096) bus_log_.pop_front();
    if (cycle_ < trace_until_)
      std::printf("  %6llu  bus  %s\n", static_cast<unsigned long long>(cycle_), t.Str().c_str());
    ++txn_count_[t.cmd & 7];
  }
  for (int p = 0; p < kNL1; ++p) {
    const uint64_t ev = vlb::Get(top_->events_o, 8 * p, 8);
    for (int e = 0; e < 8; ++e)
      if ((ev >> e) & 1u) ++events_[p][e];
  }
  for (int e = 0; e < 4; ++e)
    if ((top_->l2_events_o >> e) & 1u) ++l2_events_[e];

  // Probe-based invariants use the reference as it stands BEFORE this
  // cycle's stores, which is what the cache arrays hold until the edge.
  if (probe_) ProbeChecks();

  // Port responses. Loads are checked against the reference first, then this
  // cycle's stores are applied, so the order within a cycle never matters
  // (two ports cannot complete conflicting accesses to one line in the same
  // cycle: one of them would need the bus).
  struct Done { int p; Access a; uint32_t rdata; bool err; };
  std::vector<Done> done;
  for (int p = 0; p < kNL1; ++p) {
    Port& pt = port_[p];
    const int c = IsInstr(p) ? p - kN : p;
    const bool gnt = IsInstr(p) ? vlb::Bit(top_->instr_gnt_o, c) : vlb::Bit(top_->core_gnt_o, c);
    const bool rvalid =
        IsInstr(p) ? vlb::Bit(top_->instr_rvalid_o, c) : vlb::Bit(top_->core_rvalid_o, c);
    if (!pt.busy) {
      tb::Check(!gnt && !rvalid, "port answered with no request outstanding");
      continue;
    }
    if (!tb::Check(gnt == rvalid, "gnt and rvalid not simultaneous (port " +
                                      std::to_string(p) + ")"))
      continue;
    if (!gnt) {
      if (cycle_ - pt.start > liveness_bound_) {
        tb::Check(false, "LIVENESS: port " + std::to_string(p) + " waited more than " +
                             std::to_string(liveness_bound_) + " cycles");
        pt.start = cycle_;   // report once per bound
      }
      continue;
    }
    const uint32_t rdata = static_cast<uint32_t>(
        IsInstr(p) ? vlb::Get(top_->instr_rdata_o, 32 * c, 32) : vlb::Get(top_->core_rdata_o, 32 * c, 32));
    const bool err = IsInstr(p) ? vlb::Bit(top_->instr_err_o, c) : vlb::Bit(top_->core_err_o, c);
    done.push_back({p, pt.acc, rdata, err});
  }

  for (const Done& d : done) {
    const uint32_t a = d.a.addr & ~3u;
    const bool ram = a < kRamSize;
    const bool mmio = a >= kMmioBase && a < kMmioBase + 4 * kMmioWords;
    tb::Check(d.err == (!ram && !mmio),
              "error response mismatch at " + std::to_string(a) + " port " + std::to_string(d.p));
    if (!d.a.we && !d.err && (ram || mmio)) {
      const uint32_t exp = ram ? Word(ref_, a) : mmio_ref_[(a - kMmioBase) >> 2];
      if (d.rdata != exp && failures_reported_++ < 10) {
        char b[200];
        std::snprintf(b, sizeof(b),
                      "VALUE: cycle %llu port %d %s %08x got %08x expected %08x",
                      static_cast<unsigned long long>(cycle_), d.p,
                      IsInstr(d.p) ? "fetch" : "load", a, d.rdata, exp);
        tb::Check(false, b);
      } else {
        ++tb::g_checks;
      }
    }
  }
  for (const Done& d : done) {
    const uint32_t a = d.a.addr & ~3u;
    Port& pt = port_[d.p];
    if (cycle_ < trace_until_)
      std::printf("  %6llu  port %d %s %08x be=%x %s %08x%s\n",
                  static_cast<unsigned long long>(cycle_), d.p,
                  d.a.we ? "st" : (IsInstr(d.p) ? "if" : "ld"), a, d.a.be,
                  d.a.we ? "<-" : "->", d.a.we ? d.a.wdata : d.rdata, d.err ? " ERR" : "");
    const bool mapped = a < kRamSize || (a >= kMmioBase && a < kMmioBase + 4 * kMmioWords);
    if (d.a.we && !d.err && mapped) {
      if (a < kRamSize) {
        for (int b = 0; b < 4; ++b)
          if (d.a.be & (1u << b)) ref_[a + b] = static_cast<uint8_t>(d.a.wdata >> (8 * b));
      } else {
        uint32_t& r = mmio_ref_[(a - kMmioBase) >> 2];
        for (int b = 0; b < 4; ++b)
          if (d.a.be & (1u << b))
            r = (r & ~(0xFFu << (8 * b))) | (d.a.wdata & (0xFFu << (8 * b)));
      }
    }
    pt.last_rdata = d.rdata;
    pt.last_err = d.err;
    pt.busy = false;
    ++completed_;
    max_latency_ = std::max<uint64_t>(max_latency_, cycle_ - pt.start);
  }
}

inline void Harness::ProbeChecks() {
  const bool busy = top_->mon_busy_o != 0;
  const uint32_t inflight = LineOf(top_->mon_addr_o);
  const bool vbusy = busy && top_->mon_vvalid_o;
  const uint32_t vinflight = LineOf(top_->mon_vaddr_o);
  for (uint32_t line : touched_) {
    if ((busy && inflight == line) || (vbusy && vinflight == line)) continue;
    top_->dbg_addr_i = line;
    top_->eval();
    const bool l2_present = top_->dbg_l2_present_o != 0;
    const bool l2_dirty = top_->dbg_l2_dirty_o != 0;
    const uint64_t sharers = vlb::Get(top_->dbg_l2_sharers_o, 0, kNL1);
    int n_m = 0, n_s = 0;
    for (int p = 0; p < kNL1; ++p) {
      const int st = static_cast<int>(vlb::Get(top_->dbg_state_o, 2 * p, 2));
      if (st == M) ++n_m;
      if (st == S) ++n_s;
      if (st == M && !MayOwn(p)) Report("SWMR: line %08x is M in non-owning L1 %d", line, p);
      if (st == S || st == M) {
        for (int w = 0; w < 8; ++w) {
          const uint32_t got = static_cast<uint32_t>(
              vlb::Get(top_->dbg_data_o, kLineBits * p + 32 * w, 32));
          if (got != Word(ref_, line + 4 * w)) {
            Report("COPY: line %08x is stale in L1 %d (word %d)", line, p, w);
            break;
          }
        }
        if (!l2_present) Report("INCLUSION: line %08x is in L1 %d but not in the L2", line, p);
        else if (!((sharers >> p) & 1u))
          Report("FILTER: line %08x is in L1 %d but its sharer bit is clear", line, p);
      }
    }
    if (n_m > 1 || (n_m == 1 && n_s > 0)) Report("SWMR: line %08x has %d M and %d S copies", line, n_m, n_s);
    if (l2_present && n_m == 0) {
      for (int w = 0; w < 8; ++w) {
        if (static_cast<uint32_t>(vlb::Get(top_->dbg_l2_data_o, 32 * w, 32)) !=
            Word(ref_, line + 4 * w)) {
          Report("L2 DATA: line %08x is stale in the L2 (word %d) with no L1 owner", line, w);
          break;
        }
      }
    }
    if (!(l2_present && l2_dirty) && n_m == 0) {
      for (int w = 0; w < 8; ++w) {
        if (Word(ram_, line + 4 * w) != Word(ref_, line + 4 * w)) {
          Report("MEMORY: line %08x is stale in memory (word %d), not dirty anywhere", line, w);
          break;
        }
      }
    }
    tb::g_checks += 1;
  }
}

inline void Harness::Cycle() {
  DriveRequests();
  top_->clk_i = 0;
  top_->eval();
  MemEvaluate();
  top_->eval();
  Sample();
  const MemReq mq = CaptureMem();
  top_->clk_i = 1;
  top_->eval();
  MemTick(mq);
  ++cycle_;
}

inline void Harness::Randomise(uint64_t cycles, const std::vector<uint32_t>& pool,
                               int issue_pct) {
  const uint64_t end = cycle_ + cycles;
  while (cycle_ < end) {
    for (int p = 0; p < kNL1; ++p) {
      if (port_[p].busy || static_cast<int>(rng_.Next() % 100) >= issue_pct) continue;
      Access a;
      const uint64_t r = rng_.Next();
      const int kind = static_cast<int>(r % 1000);
      if (kind < 15) {
        // uncached register
        a.addr = kMmioBase + 4 * static_cast<uint32_t>((r >> 10) % kMmioWords);
      } else if (kind < 20) {
        // unmapped: must return an error
        a.addr = (r & 1) ? 0x00040000u + (static_cast<uint32_t>(r >> 12) & 0xFFFCu)
                         : 0x20000000u;
      } else {
        const uint32_t line = pool[(r >> 10) % pool.size()];
        // Bias towards word 0 so that ports collide on the same word, not
        // only on the same line.
        const uint32_t slot = ((r >> 20) & 1) ? 0 : static_cast<uint32_t>((r >> 21) & 7);
        a.addr = line + 4 * slot;
      }
      a.we = ((r >> 30) & 1) != 0;
      switch ((r >> 31) & 3) {
        case 0:
        case 1: a.be = 0xF; break;
        case 2: a.be = static_cast<uint8_t>(((r >> 33) & 1) ? 0xC : 0x3); break;
        default: a.be = static_cast<uint8_t>(1u << ((r >> 34) & 3)); break;
      }
      a.wdata = static_cast<uint32_t>(rng_.Next());
      Issue(p, a);   // instruction ports turn this into a fetch
    }
    Cycle();
  }
  Drain();
}

// A pool of lines that collide in every cache: `sets` consecutive sets,
// `tags` different tags per set, `stride` = one way's size in bytes.
inline std::vector<uint32_t> ConflictPool(uint32_t base, int sets, int tags, uint32_t stride) {
  std::vector<uint32_t> pool;
  for (int t = 0; t < tags; ++t)
    for (int s = 0; s < sets; ++s) pool.push_back(base + t * stride + s * kLineBytes);
  return pool;
}

// One randomised run: prints a summary line and records a check group.
inline void RandomRun(const char* name, uint64_t seed, bool lat_random, int lat,
                      uint64_t cycles, const std::vector<uint32_t>& pool, int issue_pct) {
  Harness h(seed);
  h.SetMemLatency(lat_random, lat);
  h.Randomise(cycles, pool, issue_pct);
  std::printf("    %-30s %7llu accesses, max wait %3llu | bus:", name,
              static_cast<unsigned long long>(h.completed()),
              static_cast<unsigned long long>(h.max_latency()));
  for (int c = 0; c < 7; ++c)
    std::printf(" %s=%llu", CmdName(c), static_cast<unsigned long long>(h.txn_count(c)));
  std::printf(" | L2: hit=%llu miss=%llu wb=%llu binv=%llu\n",
              static_cast<unsigned long long>(h.l2_events(L2_HIT)),
              static_cast<unsigned long long>(h.l2_events(L2_MISS)),
              static_cast<unsigned long long>(h.l2_events(L2_WRITEBACK)),
              static_cast<unsigned long long>(h.l2_events(L2_BACKINV)));
  // Each kind of transaction the configuration can produce must actually
  // have been produced, or the run proved less than it claims.
  bool ok = h.txn_count(RD) > 0 && h.txn_count(UNC_RD) > 0 && h.txn_count(UNC_WR) > 0 &&
            h.l2_events(L2_HIT) > 0 && h.l2_events(L2_MISS) > 0;
  if (COH_NUM_WB > 0) ok = ok && h.txn_count(RDX) > 0 && h.txn_count(UPGR) > 0 && h.txn_count(WB) > 0;
  if (COH_NUM_WT > 0) ok = ok && h.txn_count(WR) > 0;
  tb::Check(ok, std::string(name) + ": not every transaction type was exercised");
  tb::Group(name);
}

}  // namespace coh

#endif  // COH_HARNESS_H
