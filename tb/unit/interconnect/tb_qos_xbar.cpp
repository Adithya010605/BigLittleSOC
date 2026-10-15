// UNIT-TOP: qos_xbar
// UNIT-RTL: rtl/cache/cache_pkg.sv rtl/interconnect/qos_xbar.sv
// UNIT-VFLAGS: -GNM=4 -GNS=3 -GSLV_BASE=96'h000020000000100000000000 -GSLV_LIMIT=96'h000021000000200000001000
// ============================================================================
// tb_qos_xbar.cpp — unit testbench for rtl/interconnect/qos_xbar.sv
//
// Four masters, three slaves:  S0 [0x0000, 0x1000)  S1 [0x1000, 0x2000)
// S2 [0x2000, 0x2100); everything else is a decode error.
//
// The slaves are C++ models with random back-pressure (req_ready) and
// random response latency. Every cycle the harness checks, against a
// reference model of the arbitration rules (plan §3.1):
//
//   ROUTING      each request reaches the slave its address decodes to,
//                unchanged, exactly once; unmapped addresses get a decode
//                error and reach no slave
//   DATA         each response carries what its slave returned for that
//                request (reads see every earlier write, in slave order)
//   GRANT RULES  for every slave, in every cycle:
//                - a grant goes only to a master requesting that slave
//                - a slave that is free (idle, or answering this cycle)
//                  with a request waiting grants someone: no dead cycles
//                - if any waiting master has waited >= starve_limit, the
//                  grant goes to one of those (anti-starvation)
//                - otherwise to a master of the highest priority waiting
//                - and among those, round-robin from the last grant
//   PARALLELISM  different slaves are granted in the same cycle
//   LIVENESS     no request waits more than a bound
//
// Directed scenarios then measure the arbitration outcome itself: strict
// priority starves lower levels when anti-starvation is effectively off;
// with the plan's limit of 16 every master is served within the bound;
// equal priorities are served in exact rotation.
// ============================================================================
#include "Vqos_xbar.h"
#include "tb_common.h"

#include <cstdio>
#include <deque>
#include <map>
#include <string>
#include <vector>

#include "../../integration/vl_bits.h"

namespace {

constexpr int kNM = 4;
constexpr int kNS = 3;
const uint32_t kBase[kNS] = {0x0000, 0x1000, 0x2000};
const uint32_t kLimit[kNS] = {0x1000, 0x2000, 0x2100};

int Decode(uint32_t a) {
  for (int j = 0; j < kNS; ++j)
    if (a >= kBase[j] && a < kLimit[j]) return j;
  return kNS;   // decode error
}

struct Req {
  uint32_t addr = 0;
  bool write = false;
  uint32_t wdata[8] = {};
  uint32_t strb = 0;
};

struct Rsp {
  uint32_t rdata[8] = {};
  bool err = false;
};

class Harness {
 public:
  explicit Harness(uint64_t seed) : rng_(seed) {
    top_ = new Vqos_xbar;
    for (int j = 0; j < kNS; ++j) mem_[j].assign(0x1000 / 4, 0);
    top_->rst_ni = 0;
    top_->clk_i = 0;
    top_->m_req_valid_i = 0;
    top_->m_rsp_ready_i = 0;
    top_->s_req_ready_i = 0;
    top_->s_rsp_valid_i = 0;
    top_->starve_limit_i = 16;
    top_->qos_prio_i = 0;
    for (int i = 0; i < 3; ++i) {
      top_->clk_i = 0; top_->eval();
      top_->clk_i = 1; top_->eval();
    }
    top_->rst_ni = 1;
  }
  ~Harness() { delete top_; }

  // ---- knobs ----
  void SetPrio(int m, int p) { prio_[m] = p; }
  void SetStarve(int l) { starve_ = l; }
  void SetSlave(int ready_pct, int max_latency) { ready_pct_ = ready_pct; max_lat_ = max_latency; }
  void SetRspReadyPct(int pct) { rsp_ready_pct_ = pct; }

  bool Idle(int m) const { return !mst_[m].active; }
  void Issue(int m, const Req& r) {
    Master& x = mst_[m];
    x.active = true;
    x.granted = false;
    x.req = r;
    x.wait = 0;
    x.start = cycle_;
  }
  void Cycle();

  uint64_t cycle() const { return cycle_; }
  uint64_t grants(int m) const { return grants_[m]; }
  uint64_t max_wait(int m) const { return max_wait_[m]; }
  uint64_t completed() const { return completed_; }
  uint64_t parallel() const { return parallel_; }
  uint64_t decerr() const { return decerr_; }
  const std::vector<int>& grant_log(int s) const { return glog_[s]; }

 private:
  struct Master {
    bool active = false;
    bool granted = false;   // request accepted, response pending
    Req req;
    Rsp expect;             // what the slave returned for it
    bool expect_known = false;
    int wait = 0;           // cycles waited while requesting (mirror of the RTL)
    uint64_t start = 0;
  };
  struct Slave {
    bool busy = false;      // a transaction granted to it, not yet answered
    int owner = -1;
    bool accepted = false;  // the slave has taken the request
    int lat = 0;            // cycles until it answers
    Rsp rsp;
    int rr = 0;
  };

  void Drive();
  void Check();
  void Respond(int j);

  Vqos_xbar* top_;
  tb::Rng rng_;
  uint64_t cycle_ = 0;
  Master mst_[kNM];
  Slave slv_[kNS];
  std::vector<uint32_t> mem_[kNS];
  int prio_[kNM] = {};
  int starve_ = 16;
  int ready_pct_ = 70;
  int max_lat_ = 3;
  int rsp_ready_pct_ = 80;
  // per-cycle slave behaviour, chosen in Drive
  bool s_ready_[kNS] = {};
  bool s_rsp_[kNS] = {};
  bool m_rspr_[kNM] = {};
  uint64_t grants_[kNM] = {};
  uint64_t max_wait_[kNM] = {};
  uint64_t completed_ = 0, parallel_ = 0, decerr_ = 0;
  std::vector<int> glog_[kNS];
};

void Harness::Drive() {
  for (int m = 0; m < kNM; ++m) {
    const Master& x = mst_[m];
    vlb::Set(top_->m_req_valid_i, m, 1, x.active && !x.granted);
    vlb::Set(top_->m_req_addr_i, 32 * m, 32, x.req.addr);
    vlb::Set(top_->m_req_write_i, m, 1, x.req.write);
    for (int w = 0; w < 8; ++w) vlb::Set(top_->m_req_wdata_i, 256 * m + 32 * w, 32, x.req.wdata[w]);
    vlb::Set(top_->m_req_wstrb_i, 32 * m, 32, x.req.strb);
    vlb::Set(top_->qos_prio_i, 2 * m, 2, prio_[m]);
    m_rspr_[m] = static_cast<int>(rng_.Next() % 100) < rsp_ready_pct_;
    vlb::Set(top_->m_rsp_ready_i, m, 1, m_rspr_[m]);
  }
  top_->starve_limit_i = starve_;
  for (int j = 0; j < kNS; ++j) {
    Slave& s = slv_[j];
    s_ready_[j] = !s.accepted && static_cast<int>(rng_.Next() % 100) < ready_pct_;
    s_rsp_[j] = s.accepted && s.lat == 0;
    vlb::Set(top_->s_req_ready_i, j, 1, s_ready_[j]);
    vlb::Set(top_->s_rsp_valid_i, j, 1, s_rsp_[j]);
    for (int w = 0; w < 8; ++w) vlb::Set(top_->s_rsp_rdata_i, 256 * j + 32 * w, 32, s.rsp.rdata[w]);
    vlb::Set(top_->s_rsp_err_i, j, 1, s.rsp.err);
  }
}

void Harness::Check() {
  // ---- responses to masters ----
  for (int m = 0; m < kNM; ++m) {
    Master& x = mst_[m];
    if (!vlb::Bit(top_->m_rsp_valid_o, m)) continue;
    if (!tb::Check(x.active && x.granted && x.expect_known,
                   "response to master " + std::to_string(m) + " with nothing outstanding"))
      continue;
    if (!m_rspr_[m]) continue;   // held until accepted
    bool same = vlb::Bit(top_->m_rsp_err_o, m) == x.expect.err;
    for (int w = 0; w < 8 && same && !x.req.write; ++w)
      same = static_cast<uint32_t>(vlb::Get(top_->m_rsp_rdata_o, 256 * m + 32 * w, 32)) == x.expect.rdata[w];
    char b[128];
    std::snprintf(b, sizeof(b), "DATA: master %d response for %08x", m, x.req.addr);
    tb::Check(same, b);
    x.active = false;
    x.granted = false;
    x.expect_known = false;
    ++completed_;
  }

  // ---- slaves accepting requests (routing) ----
  for (int j = 0; j < kNS; ++j) {
    Slave& s = slv_[j];
    if (!vlb::Bit(top_->s_req_valid_o, j)) continue;
    if (!tb::Check(s.busy && !s.accepted, "slave request with no grant outstanding")) continue;
    if (!s_ready_[j]) continue;
    Master& x = mst_[s.owner];
    const uint32_t addr = static_cast<uint32_t>(vlb::Get(top_->s_req_addr_o, 32 * j, 32));
    bool same = addr == x.req.addr && vlb::Bit(top_->s_req_write_o, j) == x.req.write &&
                static_cast<uint32_t>(vlb::Get(top_->s_req_wstrb_o, 32 * j, 32)) == x.req.strb;
    for (int w = 0; w < 8 && same; ++w)
      same = static_cast<uint32_t>(vlb::Get(top_->s_req_wdata_o, 256 * j + 32 * w, 32)) == x.req.wdata[w];
    tb::Check(same, "ROUTING: slave " + std::to_string(j) + " got a request that is not its owner's");
    // The slave performs the access now and answers later.
    const uint32_t line = (addr - kBase[j]) / 4 & ~7u;
    for (int w = 0; w < 8; ++w) {
      uint32_t& v = mem_[j][(line + w) % mem_[j].size()];
      s.rsp.rdata[w] = v;
      if (x.req.write) {
        for (int bb = 0; bb < 4; ++bb)
          if ((x.req.strb >> (4 * w + bb)) & 1u) {
            const uint32_t mask = 0xFFu << (8 * bb);
            v = (v & ~mask) | (x.req.wdata[w] & mask);
          }
      }
    }
    s.rsp.err = (addr & 0xFE0u) == 0xFE0u;   // slaves fault one corner of their window
    x.expect = s.rsp;
    x.expect_known = true;
    s.accepted = true;
    s.lat = static_cast<int>(rng_.Next() % static_cast<uint64_t>(max_lat_ + 1));
  }

  // ---- grants, against the reference arbiter ----
  int granted_slaves = 0;
  for (int j = 0; j <= kNS; ++j) {
    std::vector<int> cand;
    for (int m = 0; m < kNM; ++m)
      if (mst_[m].active && !mst_[m].granted && Decode(mst_[m].req.addr) == j) cand.push_back(m);
    std::vector<int> got;
    for (int m : cand)
      if (vlb::Bit(top_->m_req_ready_o, m)) got.push_back(m);
    if (j == kNS) {
      // decode error: every requester is accepted at once
      tb::Check(got.size() == cand.size(), "decode-error requests not all accepted");
      for (int m : got) {
        mst_[m].granted = true;
        mst_[m].expect = Rsp{};
        mst_[m].expect.err = true;
        mst_[m].expect_known = true;
        ++decerr_;
      }
      continue;
    }
    Slave& s = slv_[j];
    const bool free = !s.busy || s_rsp_[j];
    if (!free) {
      tb::Check(got.empty(), "GRANT: busy slave " + std::to_string(j) + " granted again");
      continue;
    }
    if (cand.empty()) continue;
    if (!tb::Check(got.size() == 1, "GRANT: free slave " + std::to_string(j) + " with " +
                                        std::to_string(cand.size()) + " waiting granted " +
                                        std::to_string(got.size())))
      continue;
    // Reference choice.
    std::vector<int> pool;
    for (int m : cand)
      if (mst_[m].wait >= starve_) pool.push_back(m);
    if (pool.empty()) {
      int best = -1;
      for (int m : cand) best = std::max(best, prio_[m]);
      for (int m : cand)
        if (prio_[m] == best) pool.push_back(m);
    }
    int expect = -1;
    for (int k = 0; k < kNM && expect < 0; ++k) {
      const int c = (s.rr + k) % kNM;
      for (int m : pool)
        if (m == c) expect = m;
    }
    char b[160];
    std::snprintf(b, sizeof(b), "GRANT: slave %d granted master %d, rules say %d (cycle %llu)", j,
                  got[0], expect, static_cast<unsigned long long>(cycle_));
    tb::Check(got[0] == expect, b);
    const int g = got[0];
    ++granted_slaves;
    ++grants_[g];
    glog_[j].push_back(g);
    max_wait_[g] = std::max<uint64_t>(max_wait_[g], cycle_ - mst_[g].start);
    mst_[g].granted = true;
    s.rr = (g + 1) % kNM;
    // The slave's previous transaction (if answering now) completes; the new
    // one takes its place.
    s.busy = true;
    s.owner = g;
    s.accepted = false;
  }
  if (granted_slaves > 1) ++parallel_;

  // ---- slaves answering, and the waiting-time mirror ----
  for (int j = 0; j < kNS; ++j) {
    Slave& s = slv_[j];
    if (s_rsp_[j]) {
      // A grant this same cycle has already replaced the owner; a slave
      // answering with no new grant becomes idle.
      if (s.accepted) {
        s.busy = false;
        s.accepted = false;
      }
    } else if (s.accepted && s.lat > 0) {
      --s.lat;
    }
  }
  for (int m = 0; m < kNM; ++m) {
    Master& x = mst_[m];
    if (x.active && !x.granted) {
      if (x.wait < 255) ++x.wait;
      tb::Check(cycle_ - x.start < 4000, "LIVENESS: master " + std::to_string(m) + " starved");
    } else {
      x.wait = 0;
    }
  }
}

void Harness::Cycle() {
  Drive();
  top_->clk_i = 0;
  top_->eval();
  Check();
  top_->clk_i = 1;
  top_->eval();
  ++cycle_;
}

Req RandomReq(tb::Rng& r, bool allow_unmapped) {
  Req q;
  const uint64_t x = r.Next();
  const int k = static_cast<int>(x % 100);
  if (allow_unmapped && k < 3) q.addr = 0x8000 + static_cast<uint32_t>(x >> 20) % 0x1000;
  else if (k < 50) q.addr = static_cast<uint32_t>(x >> 8) % 0x1000;              // S0
  else if (k < 85) q.addr = 0x1000 + static_cast<uint32_t>(x >> 8) % 0x1000;     // S1
  else q.addr = 0x2000 + static_cast<uint32_t>(x >> 8) % 0x100;                  // S2
  q.addr &= ~31u;
  if ((x >> 40) % 16 == 0 && q.addr < 0x2000) q.addr |= 0xFE0u;   // a slave-error corner
  q.write = (x >> 33) & 1;
  for (int w = 0; w < 8; ++w) q.wdata[w] = static_cast<uint32_t>(r.Next());
  q.strb = q.write ? static_cast<uint32_t>(r.Next()) : 0;
  return q;
}

// ---------------------------------------------------------------------------
void Random(const char* name, uint64_t seed, int issue_pct, int ready_pct, int lat, int starve,
            bool shuffle_prio) {
  Harness h(seed);
  tb::Rng r(seed * 7 + 1);
  h.SetSlave(ready_pct, lat);
  h.SetStarve(starve);
  for (int m = 0; m < kNM; ++m) h.SetPrio(m, static_cast<int>(r.Next() % 4));
  for (int c = 0; c < 150000; ++c) {
    if (shuffle_prio && c % 997 == 0)
      for (int m = 0; m < kNM; ++m) h.SetPrio(m, static_cast<int>(r.Next() % 4));
    for (int m = 0; m < kNM; ++m)
      if (h.Idle(m) && static_cast<int>(r.Next() % 100) < issue_pct) h.Issue(m, RandomReq(r, true));
    h.Cycle();
  }
  std::printf("    %-34s %7llu txns, %5llu decode errors, %6llu parallel-grant cycles, max wait",
              name, static_cast<unsigned long long>(h.completed()),
              static_cast<unsigned long long>(h.decerr()), static_cast<unsigned long long>(h.parallel()));
  for (int m = 0; m < kNM; ++m) std::printf(" %llu", static_cast<unsigned long long>(h.max_wait(m)));
  std::printf("\n");
  tb::Check(h.parallel() > 0 && h.decerr() > 0, std::string(name) + ": parallel grants and decode errors exercised");
  tb::Group(name);
}

// All four masters keep slave 0 busy. (A master has one transaction
// outstanding, so one master alone leaves gaps between its transactions;
// two masters at the top level keep that level always waiting.)
void Saturate(Harness& h, int cycles) {
  tb::Rng r(99);
  for (int c = 0; c < cycles; ++c) {
    for (int m = 0; m < kNM; ++m) {
      if (!h.Idle(m)) continue;
      Req q = RandomReq(r, false);
      q.addr = (static_cast<uint32_t>(r.Next()) % 0x1000) & ~31u;   // S0 only
      q.addr &= 0xF00u;                                               // never the faulting corner
      h.Issue(m, q);
    }
    h.Cycle();
  }
}

const int kSatPrio[kNM] = {3, 3, 1, 0};

void StrictPriority() {
  Harness h(5);
  h.SetSlave(100, 0);
  h.SetRspReadyPct(100);
  for (int m = 0; m < kNM; ++m) h.SetPrio(m, kSatPrio[m]);
  h.SetStarve(255);                  // not reached in 200 cycles: off
  Saturate(h, 200);
  tb::Check(h.grants(0) > 30 && h.grants(1) > 30, "the two top-priority masters share the slave");
  tb::CheckEq<uint64_t>("priority 1 starved under strict priority", h.grants(2), 0);
  tb::CheckEq<uint64_t>("priority 0 starved under strict priority", h.grants(3), 0);
  tb::Group("strict priority: the highest QoS level wins every arbitration");
}

void AntiStarvation() {
  Harness h(6);
  h.SetSlave(100, 0);
  h.SetRspReadyPct(100);
  for (int m = 0; m < kNM; ++m) h.SetPrio(m, kSatPrio[m]);
  h.SetStarve(16);                   // the plan's figure
  Saturate(h, 4000);
  for (int m = 0; m < kNM; ++m) {
    tb::Check(h.grants(m) > 0, "master " + std::to_string(m) + " served");
    // Waited at most the limit, plus the transactions of starving masters
    // ahead of it, plus the one in progress.
    tb::Check(h.max_wait(m) <= 16 + 3 * 4 + 4,
              "master " + std::to_string(m) + " waited " + std::to_string(h.max_wait(m)) + " cycles");
  }
  tb::Check(h.grants(0) > h.grants(3), "priority still shapes the share");
  std::printf("    anti-starvation (limit 16): grants %llu %llu %llu %llu, max wait %llu %llu %llu %llu\n",
              static_cast<unsigned long long>(h.grants(0)), static_cast<unsigned long long>(h.grants(1)),
              static_cast<unsigned long long>(h.grants(2)), static_cast<unsigned long long>(h.grants(3)),
              static_cast<unsigned long long>(h.max_wait(0)), static_cast<unsigned long long>(h.max_wait(1)),
              static_cast<unsigned long long>(h.max_wait(2)), static_cast<unsigned long long>(h.max_wait(3)));
  tb::Group("anti-starvation: every master served within the limit");
}

void RoundRobin() {
  Harness h(7);
  h.SetSlave(100, 0);
  h.SetRspReadyPct(100);
  for (int m = 0; m < kNM; ++m) h.SetPrio(m, 2);
  h.SetStarve(255);
  Saturate(h, 400);
  const std::vector<int>& g = h.grant_log(0);
  bool rotates = g.size() > 40;
  for (size_t i = 4; i < g.size() && rotates; ++i) rotates = g[i] == (g[i - 1] + 1) % kNM;
  tb::Check(rotates, "equal priorities are served in exact rotation");
  tb::Group("round-robin within a priority level");
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  std::printf("tb_qos_xbar: %d masters x %d slaves\n", kNM, kNS);
  StrictPriority();
  AntiStarvation();
  RoundRobin();
  Random("random, fast slaves", 11, 60, 90, 1, 16, false);
  Random("random, slow slaves, back-pressure", 12, 70, 40, 6, 16, true);
  Random("random, light traffic", 13, 10, 80, 3, 8, true);
  Random("random, starvation limit 1", 14, 80, 60, 2, 1, true);
  return tb::Report("qos_xbar");
}
