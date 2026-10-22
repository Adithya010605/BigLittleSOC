// UNIT-TOP: coherent_mem
// UNIT-RTL: rtl/power/clock_gate.sv rtl/cache/cache_pkg.sv rtl/cache/sram_sp.sv rtl/cache/l1_dcache.sv rtl/cache/l1_pair.sv rtl/cache/l2_cache.sv rtl/coherence/snoop_bus.sv rtl/coherence/coherent_mem.sv
// ============================================================================
// tb_coherent_mem.cpp — the cache hierarchy, full-size geometry.
//
// Two P-cores and two E-cores. Data caches: write-back L1s (16 KB, 2-way:
// ports 0, 1 = "P0", "P1") and write-through L1s (8 KB, direct-mapped: ports
// 2, 3 = "E0", "E1"). Instruction caches: ports 4..7 ("IP0", "IP1", "IE0",
// "IE1"). All on the snooping bus, with the shared inclusive L2 (64 KB,
// 4-way) and its snoop filter behind it.
//
// Part 1 walks the protocol through every transition of the plan's MSI table
// (RISC-V_SoC_Project_Plan.md §2.2), checking after each access the exact bus
// transaction it caused and the state of the line in every cache:
//
//   I -> S  read miss, BusRd                         basic_walk
//   I -> M  write miss, BusRdX                       basic_walk, c2c_transfer
//   S -> M  write hit on S, BusUpgr                  basic_walk
//   S -> I  snooped BusRdX / BusUpgr / write-through basic_walk
//   M -> S  snooped BusRd: flush into the L2         basic_walk
//   M -> I  snooped BusRdX: line forwarded c2c       c2c_transfer
//   M -> I  snooped write-through: flush + merge     basic_walk
//   M -> I  eviction: writeback into the L2          eviction
//
// plus the two races a request waiting for the bus can lose:
//
//   * an upgrade whose S copy is invalidated first becomes a BusRdX
//     (upgrade_race, upgrade_vs_write_through)
//   * a modified victim that a snoop flushes first needs no writeback
//     (writeback_race)
//
// and uncached accesses and access errors. Then the L2 and the instruction
// caches:
//
//   * L2 miss then hit, and the sharer bits after each access   l2_basics
//   * stale sharer bits after silent evictions are harmless     snoop_filter
//   * an L2 eviction invalidates the victim's L1 copies, taking
//     a modified one, and writes it back (inclusion)            l2_back_invalidate
//   * a dirty L2 victim no L1 holds is written back             l2_dirty_victim
//   * a store invalidates the line in every instruction cache,
//     and the next fetch gets the new code                      icache_coherence
//
// Part 2 is randomised traffic from all eight ports at once over a pool of
// lines that collide in every cache, at several memory latency settings, with
// every load and fetch, every copy, the L2 and memory checked every cycle (see
// coh_harness.h).
// ============================================================================
#include "coh_harness.h"


using coh::Harness;
using coh::BusTxn;

namespace {

constexpr int P0 = 0, P1 = 1, E0 = 2, E1 = 3;
constexpr int IP0 = 4, IE0 = 6;                  // instruction ports
constexpr uint32_t kWay = 256 * 32;     // L1: same set every 8 KB
constexpr uint32_t kL2Way = 512 * 32;   // L2: same set every 16 KB

struct Exp {
  int master;
  int cmd;
  uint32_t addr;
  bool shared;
  bool dirty;
};

void ExpectBus(Harness& h, const std::vector<Exp>& exp, const std::string& what) {
  const std::vector<BusTxn> got = h.TakeBus();
  bool ok = got.size() == exp.size();
  for (size_t i = 0; ok && i < exp.size(); ++i) {
    ok = got[i].master == exp[i].master && got[i].cmd == exp[i].cmd &&
         got[i].addr == exp[i].addr && got[i].shared == exp[i].shared &&
         got[i].dirty == exp[i].dirty;
  }
  if (!ok) {
    std::string d = what + ": bus transactions differ\n         expected:";
    for (const Exp& e : exp) {
      BusTxn t;
      t.master = e.master; t.cmd = e.cmd; t.addr = e.addr; t.shared = e.shared; t.dirty = e.dirty;
      d += "\n           " + t.Str();
    }
    d += "\n         got:";
    for (const BusTxn& t : got) d += "\n           " + t.Str();
    tb::Check(false, d);
  } else {
    ++tb::g_checks;
  }
}

void ExpectStates(Harness& h, uint32_t addr, std::vector<int> exp, const std::string& what) {
  for (int p = 0; p < coh::kN; ++p) {
    const int st = h.StateOf(p, addr);
    char b[160];
    std::snprintf(b, sizeof(b), "%s: cache %d state of %08x", what.c_str(), p, addr);
    if (st != exp[p]) {
      std::snprintf(b, sizeof(b), "%s: cache %d holds %08x in %s, expected %s", what.c_str(), p,
                    addr, coh::MsiName(st), coh::MsiName(exp[p]));
      tb::Check(false, b);
    } else {
      ++tb::g_checks;
    }
  }
}

using namespace coh;   // RD, RDX, ..., I, S, M

// ---------------------------------------------------------------------------
void BasicWalk() {
  Harness h(1);
  const uint32_t X = 0x00010000u;

  h.Load(P0, X);
  ExpectBus(h, {{P0, RD, X, false, false}}, "P0 read miss");
  ExpectStates(h, X, {S, I, I, I}, "P0 read miss");

  h.Load(P1, X);
  ExpectBus(h, {{P1, RD, X, true, false}}, "P1 read miss, P0 shares");
  ExpectStates(h, X, {S, S, I, I}, "P1 read miss");

  h.Load(P0, X + 4);
  ExpectBus(h, {}, "P0 read hit");

  h.Store(P0, X, 0x11111111u);
  ExpectBus(h, {{P0, UPGR, X, true, false}}, "P0 write hit on S");
  ExpectStates(h, X, {M, I, I, I}, "P0 upgrade");

  h.Store(P0, X + 8, 0x22222222u);
  ExpectBus(h, {}, "P0 write hit on M");

  h.Load(P1, X);
  ExpectBus(h, {{P1, RD, X, true, true}}, "P1 read, P0 flushes");
  ExpectStates(h, X, {S, S, I, I}, "M -> S on snooped BusRd");
  tb::CheckEq<uint32_t>("the flush reached the L2", h.L2Word(X + 8), 0x22222222u);
  tb::Check(h.L2Of(X).dirty, "the L2 copy is dirty after the flush");

  h.Load(E0, X);
  ExpectBus(h, {{E0, RD, X, true, false}}, "E0 read miss");
  ExpectStates(h, X, {S, S, S, I}, "E0 read miss");

  h.Store(E0, X + 12, 0x33333333u);
  ExpectBus(h, {{E0, WR, X, true, false}}, "E0 write-through");
  ExpectStates(h, X, {I, I, S, I}, "write-through invalidates the others, keeps its own");
  tb::CheckEq<uint32_t>("write-through reached the L2", h.L2Word(X + 12), 0x33333333u);
  tb::CheckEq<uint32_t>("E0 reads its own write", h.Load(E0, X + 12), 0x33333333u);
  ExpectBus(h, {}, "E0 read hit after its write");

  h.Store(P1, X + 16, 0x44444444u);
  ExpectBus(h, {{P1, RDX, X, true, false}}, "P1 write miss");
  ExpectStates(h, X, {I, M, I, I}, "S -> I on snooped BusRdX");

  h.Store(E1, X + 20, 0x55555555u, 0x3);
  ExpectBus(h, {{E1, WR, X, true, true}}, "E1 write-through, P1 holds M");
  ExpectStates(h, X, {I, I, I, I}, "M -> I on snooped write-through, no allocate");
  tb::CheckEq<uint32_t>("P1's modified word reached the L2", h.L2Word(X + 16), 0x44444444u);
  tb::CheckEq<uint32_t>("E1's halfword merged on top", h.L2Word(X + 20) & 0xFFFFu, 0x5555u);

  h.Load(P0, X + 20);
  ExpectBus(h, {{P0, RD, X, false, false}}, "P0 read after everyone lost the line");
  tb::Group("basic MSI walk: I->S, S->M, M->S, S->I, M->I, write-through");
}

// ---------------------------------------------------------------------------
void CacheToCache() {
  Harness h(2);
  const uint32_t Y = 0x00010040u;
  h.Store(P0, Y, 0xCAFEF00Du);
  ExpectBus(h, {{P0, RDX, Y, false, false}}, "P0 write miss");
  ExpectStates(h, Y, {M, I, I, I}, "I -> M");

  const uint64_t mem_before = h.mem_accesses();
  h.Store(P1, Y + 4, 0x0BADBEEFu);
  ExpectBus(h, {{P1, RDX, Y, true, true}}, "P1 write miss, P0 holds M");
  ExpectStates(h, Y, {I, M, I, I}, "ownership moves P0 -> P1");
  tb::CheckEq<uint64_t>("cache-to-cache transfer touched neither L2 miss path nor memory",
                        h.mem_accesses() - mem_before, 0);
  tb::Check(h.RamWord(Y) != 0xCAFEF00Du, "memory is legitimately stale while P1 owns the line");
  tb::CheckEq<uint32_t>("P1 sees P0's write", h.Load(P1, Y), 0xCAFEF00Du);
  tb::Group("M -> I by BusRdX: cache-to-cache transfer, no memory access");
}

// ---------------------------------------------------------------------------
void Eviction() {
  Harness h(3);
  const uint32_t A = 0x00010000u, B = A + kWay, C = A + 2 * kWay;   // one set
  h.Store(P0, A, 0xAAAAAAAAu);
  h.Store(P0, B, 0xBBBBBBBBu);
  h.Load(P0, A);   // B is now least recently used
  h.TakeBus();
  h.Load(P0, C);
  ExpectBus(h, {{P0, WB, B, false, false}, {P0, RD, C, false, false}},
            "P0 miss on a full set: write back the LRU modified way, then fill");
  ExpectStates(h, A, {M, I, I, I}, "most recently used way kept");
  ExpectStates(h, B, {I, I, I, I}, "LRU way evicted");
  ExpectStates(h, C, {S, I, I, I}, "new line filled");
  tb::CheckEq<uint32_t>("writeback reached the L2", h.L2Word(B), 0xBBBBBBBBu);

  // A clean victim leaves silently. Touch A first so that C is the LRU way.
  h.Load(P0, A);
  h.TakeBus();
  h.Load(P0, B);
  ExpectBus(h, {{P0, RD, B, false, false}}, "clean victim C evicted without a writeback");

  // Direct-mapped write-through cache: evictions are always silent.
  h.Load(E0, A);
  ExpectBus(h, {{E0, RD, A, true, true}}, "E0 reads A, P0 flushes");
  h.Load(E0, B);
  ExpectBus(h, {{E0, RD, B, true, false}}, "E0 conflict miss replaces A silently");
  ExpectStates(h, A, {S, I, I, I}, "E0 lost A");
  ExpectStates(h, B, {S, I, S, I}, "E0 holds B");
  tb::Group("eviction: LRU choice, writeback of M, silent drop of S");

  // An invalid way is filled before any valid one is evicted, even when the
  // LRU bit points at the valid one. (Correctness does not depend on this;
  // the hit rate does, so it is checked here directly.)
  Harness g(30);
  const uint32_t D = 0x00010020u, F = D + kWay, G = D + 2 * kWay;   // one set
  g.Load(P0, D);
  g.Load(P0, F);
  g.Load(P0, D);            // LRU now points at F's way
  g.Store(P1, D, 1);        // P0's copy of D invalidated: D's way is empty
  ExpectStates(g, D, {I, M, I, I}, "D taken by P1");
  g.Load(P0, G);
  ExpectStates(g, F, {S, I, I, I}, "fill used the invalid way, not the LRU one");
  ExpectStates(g, G, {S, I, I, I}, "G filled");
  tb::Group("replacement prefers an invalid way over the LRU way");
}

// ---------------------------------------------------------------------------
void Uncached() {
  Harness h(4);
  const uint32_t r = coh::kMmioBase;
  tb::CheckEq<uint32_t>("uncached read", h.Load(P0, r + 8), 0x10000002u);
  ExpectBus(h, {{P0, UNC_RD, r + 8, false, false}}, "uncached read");
  h.Store(E0, r + 8, 0x000000AAu, 0x1);
  ExpectBus(h, {{E0, UNC_WR, r + 8, false, false}}, "uncached byte write");
  tb::CheckEq<uint32_t>("uncached read-back", h.Load(P1, r + 8), 0x100000AAu);
  h.Load(P1, 0x00040000u);
  tb::Check(h.LastErr(P1), "unmapped load returns an error");
  h.Store(E1, 0x20000000u, 1);
  tb::Check(h.LastErr(E1), "unmapped store returns an error");
  h.Load(P0, r + 8);
  tb::Check(!h.LastErr(P0), "error does not stick");
  tb::Group("uncached accesses and access errors");
}

// ---------------------------------------------------------------------------
// Both P-caches hold Z in S and both store to it in the same cycle. One
// upgrade wins; the other's S copy is invalidated while it waits, so it must
// turn into a BusRdX and take the winner's modified line.
void UpgradeRace() {
  Harness h(5);
  const uint32_t Z = 0x00010080u;
  h.Load(P0, Z);
  h.Load(P1, Z);
  h.TakeBus();
  h.Issue(P0, Access{Z, true, 0xF, 0x01010101u});
  h.Issue(P1, Access{Z + 4, true, 0xF, 0x02020202u});
  h.Drain();
  const std::vector<BusTxn> t = h.TakeBus();
  if (tb::Check(t.size() == 2, "upgrade race: two transactions")) {
    const int first = t[0].master, second = t[1].master;
    tb::Check(t[0].cmd == UPGR && t[0].shared && !t[0].dirty, "winner upgrades: " + t[0].Str());
    tb::Check(t[1].cmd == RDX && t[1].shared && t[1].dirty,
              "loser's upgrade became a BusRdX that took the winner's line: " + t[1].Str());
    std::vector<int> st = {I, I, I, I};
    st[second] = M;
    ExpectStates(h, Z, st, "upgrade race final");
    (void)first;
  }
  tb::CheckEq<uint32_t>("both stores survive (word 0)", h.Load(E0, Z), 0x01010101u);
  tb::CheckEq<uint32_t>("both stores survive (word 1)", h.Load(E0, Z + 4), 0x02020202u);
  tb::Group("race: lost upgrade becomes BusRdX");
}

// P0 upgrades a line E0 is writing through, in the same cycle, and the
// write-through wins (round-robin points at E0).
void UpgradeVsWriteThrough() {
  Harness h(6);
  const uint32_t Z = 0x000100C0u;
  h.Load(P0, Z);
  h.Load(E0, Z);
  h.Load(P1, 0x00011000u);   // last grant to P1: E0 is next in round-robin order
  h.TakeBus();
  h.Issue(P0, Access{Z, true, 0xF, 0x0F0F0F0Fu});
  h.Issue(E0, Access{Z, true, 0x1, 0x000000EEu});
  h.Drain();
  ExpectBus(h, {{E0, WR, Z, true, false}, {P0, RDX, Z, true, false}},
            "write-through wins; P0's invalidated upgrade becomes BusRdX");
  ExpectStates(h, Z, {M, I, I, I}, "P0 owns, E0's copy invalidated");
  tb::CheckEq<uint32_t>("P0's store is the last one", h.Load(E1, Z), 0x0F0F0F0Fu);
  tb::Group("race: upgrade loses to a write-through");
}

// P0's modified LRU victim A is read (and then, in a second round, written)
// by P1 in the same cycle P0 misses on another line of the set. P1 wins the
// bus; the snoop flushes A out of P0, and P0 must notice that the writeback
// it was about to do is no longer needed.
void WritebackRace() {
  for (int round = 0; round < 2; ++round) {
    const bool p1_writes = round == 1;
    Harness h(7 + round);
    const uint32_t A = 0x00010000u, B = A + kWay, C = A + 2 * kWay;
    h.Store(P0, A, 0xA0A0A0A0u);
    h.Store(P0, B, 0xB0B0B0B0u);   // A is LRU; last grant P0, so P1 is next
    h.TakeBus();
    h.Issue(P1, Access{A + 4, p1_writes, 0xF, 0x11112222u});
    h.Issue(P0, Access{C, false, 0xF, 0});
    h.Drain();
    ExpectBus(h,
              {{P1, p1_writes ? RDX : RD, A, true, true}, {P0, RD, C, false, false}},
              p1_writes ? "writeback race (P1 writes): flushed victim needs no BusWB"
                        : "writeback race (P1 reads): flushed victim needs no BusWB");
    ExpectStates(h, A, {I, p1_writes ? M : S, I, I}, "victim gone from P0");
    ExpectStates(h, C, {S, I, I, I}, "P0 filled the new line");
    tb::CheckEq<uint32_t>("P0's write to A survived", h.Load(E0, A), 0xA0A0A0A0u);
    if (p1_writes) tb::CheckEq<uint32_t>("P1's write to A", h.Load(E0, A + 4), 0x11112222u);
  }
  tb::Group("race: snoop flushes a victim waiting to be written back");
}


// ---------------------------------------------------------------------------
// The L2: misses go to memory, hits do not, and the sharer bits follow every
// access exactly.
void L2Basics() {
  Harness h(40);
  const uint32_t X = 0x00010100u;
  const uint32_t orig = h.RamWord(X);
  uint64_t mem = h.mem_accesses();
  h.Load(P0, X);
  tb::CheckEq<uint64_t>("L2 miss reads memory once", h.mem_accesses() - mem, 1);
  coh::L2Line l = h.L2Of(X);
  tb::Check(l.present && !l.dirty, "line installed clean in the L2");
  tb::CheckEq<uint32_t>("sharers after P0 read", l.sharers, 1u << P0);

  mem = h.mem_accesses();
  h.Load(P1, X);
  tb::CheckEq<uint64_t>("L2 hit does not touch memory", h.mem_accesses() - mem, 0);
  tb::CheckEq<uint32_t>("sharers after P1 read", h.L2Of(X).sharers, (1u << P0) | (1u << P1));

  h.Store(P0, X, 0x0DDBA11u);
  tb::CheckEq<uint32_t>("sharers after P0 upgrade", h.L2Of(X).sharers, 1u << P0);
  tb::Check(!h.L2Of(X).dirty, "the L2 is not written while P0 owns the line");

  h.Load(E0, X);
  l = h.L2Of(X);
  tb::CheckEq<uint32_t>("sharers after E0 read", l.sharers, (1u << P0) | (1u << E0));
  tb::Check(l.dirty, "P0's flush made the L2 copy dirty");
  tb::CheckEq<uint32_t>("the L2 holds P0's write", h.L2Word(X), 0x0DDBA11u);
  tb::CheckEq<uint32_t>("memory is untouched: the L2 is write-back", h.RamWord(X), orig);
  tb::Group("L2: miss fills from memory, hit stays in the L2, sharer bits exact");
}

// An E-cache drops a clean line silently, so its sharer bit goes stale. The
// next writer snoops it anyway (finding nothing) and the bit is cleared.
void SnoopFilter() {
  Harness h(41);
  const uint32_t A = 0x00010140u, B = A + kWay;   // one E-cache set
  h.Load(E0, A);
  h.Load(E0, B);                                   // A dropped silently
  ExpectStates(h, A, {I, I, I, I}, "E0 dropped A");
  tb::CheckEq<uint32_t>("E0's stale sharer bit for A", h.L2Of(A).sharers, 1u << E0);
  h.TakeBus();
  h.Store(P0, A, 7);
  ExpectBus(h, {{P0, RDX, A, false, false}}, "the snoop of the stale sharer finds nothing");
  tb::CheckEq<uint32_t>("stale bit cleared by the ownership change", h.L2Of(A).sharers, 1u << P0);
  tb::Group("snoop filter: stale sharer bits cost a snoop, never correctness");
}

// Five lines in one L2 set (four ways). The fifth fill evicts the pseudo-LRU
// way, A, which P0 holds modified: the L2 must back-invalidate P0's copy,
// take its data, and write it to memory, so that inclusion holds and nothing
// is lost.
void L2BackInvalidate() {
  Harness h(42);
  const uint32_t A = 0x00010000u;
  const uint32_t B = A + kL2Way, C = A + 2 * kL2Way, D = A + 3 * kL2Way, E = A + 4 * kL2Way;
  h.Store(P0, A, 0xA11CE000u);      // A modified in P0
  h.Load(P0, B);
  h.Load(P1, C);
  h.Load(E0, D);                    // L2 set full: A, B, C, D; A least recent
  h.TakeBus();
  const uint64_t binv = h.l2_events(coh::L2_BACKINV), wb = h.l2_events(coh::L2_WRITEBACK);
  h.Load(E1, E);
  ExpectBus(h, {{E1, RD, E, false, false}}, "one transaction for E1's read, eviction inside it");
  tb::CheckEq<uint64_t>("one back-invalidation", h.l2_events(coh::L2_BACKINV) - binv, 1);
  tb::CheckEq<uint64_t>("one writeback to memory", h.l2_events(coh::L2_WRITEBACK) - wb, 1);
  ExpectStates(h, A, {I, I, I, I}, "P0's modified copy of A back-invalidated");
  tb::Check(!h.L2Of(A).present, "A evicted from the L2");
  tb::CheckEq<uint32_t>("P0's modified data reached memory", h.RamWord(A), 0xA11CE000u);
  ExpectStates(h, B, {S, I, I, I}, "B untouched");
  tb::CheckEq<uint32_t>("A still reads P0's value", h.Load(P1, A), 0xA11CE000u);
  tb::Group("inclusion: L2 eviction back-invalidates L1 copies, takes modified data");
}

// A write-through store allocates in the L2 (dirty) but not in any L1. When
// that line is evicted from the L2 it has no sharers, only a writeback.
void L2DirtyVictim() {
  Harness h(43);
  const uint32_t F = 0x00010020u;
  h.Store(E0, F, 0xF00DFACEu);      // L2 miss: filled, merged, dirty, no sharers
  coh::L2Line l = h.L2Of(F);
  tb::Check(l.present && l.dirty && l.sharers == 0, "write-through allocated dirty in the L2 only");
  for (int k = 1; k <= 3; ++k) h.Load(P1, F + k * kL2Way);
  const uint64_t binv = h.l2_events(coh::L2_BACKINV), wb = h.l2_events(coh::L2_WRITEBACK);
  h.Load(E1, F + 4 * kL2Way);       // evicts F
  tb::CheckEq<uint64_t>("no L1 copies to invalidate", h.l2_events(coh::L2_BACKINV) - binv, 0);
  tb::CheckEq<uint64_t>("the dirty victim was written back", h.l2_events(coh::L2_WRITEBACK) - wb, 1);
  tb::CheckEq<uint32_t>("memory has E0's write", h.RamWord(F), 0xF00DFACEu);
  tb::Group("L2: dirty victim without L1 copies written back");
}

// Instruction fetch is coherent with every core's stores.
void IcacheCoherence() {
  Harness h(44);
  const uint32_t X = 0x00010200u;
  h.Load(IP0, X);
  tb::CheckEq<int>("IP0 holds the code line", h.StateOf(IP0, X), S);
  tb::Check((h.L2Of(X).sharers >> IP0) & 1u, "instruction cache tracked by the snoop filter");
  h.TakeBus();
  h.Store(P0, X, 0x00100073u);      // the core overwrites its own code
  ExpectBus(h, {{P0, RDX, X, true, false}}, "the store takes ownership from the I-cache");
  tb::CheckEq<int>("the store invalidated IP0's copy", h.StateOf(IP0, X), I);
  tb::CheckEq<uint32_t>("the next fetch gets the new code", h.Load(IP0, X), 0x00100073u);
  ExpectBus(h, {{IP0, RD, X, true, true}}, "the fetch takes the line from P0's data cache");

  // An E-core's write-through store invalidates another core's code too.
  h.Load(IE0, X + 4);
  h.TakeBus();
  h.Store(E1, X + 4, 0x12345678u);
  tb::CheckEq<int>("write-through invalidated IE0's copy", h.StateOf(IE0, X), I);
  tb::CheckEq<uint32_t>("IE0 fetches the new word", h.Load(IE0, X + 4), 0x12345678u);
  tb::Group("instruction caches: coherent with every core's stores (FENCE.I-safe)");
}

// Power management: a flush writes back what its caches own and leaves them
// empty; the other cores then read the data from the L2.
void FlushCaches() {
  Harness h(45);
  const uint32_t A = 0x00011000u, B = A + 0x40, C = A + 0x80;
  h.Store(P0, A, 0x0A0A0A0Au);      // M in P0
  h.Store(P0, B, 0x0B0B0B0Bu);      // M in P0
  h.Load(P0, C);                    // S in P0
  h.Load(IP0, C + 4);               // S in P0's instruction cache
  h.TakeBus();
  h.Flush(P0);
  ExpectBus(h, {{P0, WB, A, false, false}, {P0, WB, B, false, false}},
            "flush writes back exactly the modified lines");
  for (uint32_t x : {A, B, C}) ExpectStates(h, x, {I, I, I, I}, "after P0's flush");
  tb::CheckEq<int>("instruction cache flushed too", h.StateOf(IP0, C), I);
  tb::Check(h.L2Of(A).dirty && h.L2Of(A).sharers == 0, "flushed line dirty in the L2, no sharers");
  tb::CheckEq<uint32_t>("E0 reads P0's flushed data", h.Load(E0, A), 0x0A0A0A0Au);
  tb::CheckEq<uint32_t>("P0 refills after the flush", h.Load(P0, B), 0x0B0B0B0Bu);

  // A write-through cache has nothing to write back.
  h.Load(E1, A);
  h.TakeBus();
  h.Flush(E1);
  ExpectBus(h, {}, "a write-through flush is silent");
  tb::CheckEq<int>("E1 flushed", h.StateOf(E1, A), I);
  tb::Group("flush: modified lines written back, every line invalidated");
}

// A core whose clock runs at 1/4 sees each response at its own clock edge,
// with the data the access performed with.
void SlowCore() {
  Harness h(46);
  h.SetCoreSpeed(P0, 4);
  h.SetCoreSpeed(E0, 0);
  const uint32_t A = 0x00012000u;
  h.Store(P1, A, 0x11111111u);
  tb::CheckEq<uint32_t>("slow P0 loads P1's data", h.Load(P0, A), 0x11111111u);
  h.Store(P0, A, 0x22222222u);
  tb::CheckEq<uint32_t>("random-speed E0 loads it", h.Load(E0, A), 0x22222222u);
  h.Store(E0, A + 4, 0x33333333u);
  tb::CheckEq<uint32_t>("P1 sees E0's store", h.Load(P1, A + 4), 0x33333333u);
  tb::Check(h.held() > 0, "some response was held for a paused core");
  tb::Group("slow cores: responses held until the core's clock edge");
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  std::printf("tb_coherent_mem: %d P-cores + %d E-cores, I+D L1s, inclusive L2\n", COH_NUM_WB, COH_NUM_WT);

  BasicWalk();
  CacheToCache();
  Eviction();
  Uncached();
  UpgradeRace();
  UpgradeVsWriteThrough();
  WritebackRace();
  L2Basics();
  SnoopFilter();
  L2BackInvalidate();
  L2DirtyVictim();
  IcacheCoherence();
  FlushCaches();
  SlowCore();

  // 4 sets x 5 tags: more lines per set than any cache has ways, in every
  // cache, so evictions and writebacks race with snoops constantly.
  const std::vector<uint32_t> pool = coh::ConflictPool(0x00010000u, 4, 5, kWay);
  coh::RandomRun("random, zero latency", 11, false, 0, 300000, pool, 70);
  coh::RandomRun("random, 2-cycle memory", 12, false, 2, 300000, pool, 70);
  coh::RandomRun("random, 0-7 cycle memory", 13, true, 7, 400000, pool, 70);
  // Light traffic: ports mostly idle, so hits and short transactions
  // interleave differently from the saturated runs above.
  coh::RandomRun("random, light traffic", 14, true, 3, 200000, pool, 15);
  // Power management: cores at 1/2, 1/4 and random speed, and caches
  // flushed in the middle of the traffic.
  coh::RandomRun("random, slow cores", 15, true, 3, 300000, pool, 70, {2, 1, 4, 0});
  coh::RandomRun("random, flushes", 16, true, 3, 400000, pool, 70, {1, 0, 1, 2}, 40);

  return tb::Report("coherent_mem");
}
