// ============================================================================
// tb_p_core_bpu.cpp — unit testbench for rtl/p_core/p_core_bpu.sv
//
// Reference: a behavioural model of the predictor written from the rules in
// the RTL header (and docs/p_core_microarchitecture.md), as plain arrays.
//
// Coverage:
//   * reset: nothing is predicted taken, whatever the lookup address
//   * random training and lookup over a small pc pool (so entries are hit,
//     replaced and aliased constantly), compared with the model every cycle:
//     taken, target, BTB hit and the BHT counter read out
//   * lookup and training of the same entry in the same cycle: the lookup
//     sees the old contents (the write lands at the clock edge)
//   * BTB aliasing: two pcs sharing an index evict each other, and a
//     different tag never hits
//   * 2-bit hysteresis: a loop branch taken 9 times then not taken once
//     mispredicts once per loop exit in steady state -- the plan's
//     "branch prediction accuracy test: loop with known pattern"
//   * stale-entry invalidation: an entry that hits for a non-control
//     instruction is removed
// ============================================================================
#include "Vp_core_bpu.h"
#include "tb_common.h"

#include <cinttypes>
#include <vector>

namespace {

Vp_core_bpu* g = nullptr;

void Tick() {
  g->clk_i = 0;
  g->eval();
  g->clk_i = 1;
  g->eval();
}

struct Model {
  uint8_t bht[256];
  bool valid[64];
  uint32_t tag[64];
  uint32_t target[64];
  bool jump[64];

  void Reset() {
    for (auto& c : bht) c = 1;   // weakly not-taken (simulation initial value)
    for (int i = 0; i < 64; ++i) {
      valid[i] = false;
      tag[i] = 0;
      target[i] = 0;
      jump[i] = false;
    }
  }
  static int BhtIdx(uint32_t pc) { return (pc >> 2) & 0xFF; }
  static int BtbIdx(uint32_t pc) { return (pc >> 2) & 0x3F; }
  static uint32_t Tag(uint32_t pc) { return pc >> 8; }

  bool Hit(uint32_t pc) const {
    return valid[BtbIdx(pc)] && tag[BtbIdx(pc)] == Tag(pc);
  }
  bool Taken(uint32_t pc) const {
    return Hit(pc) && (jump[BtbIdx(pc)] || (bht[BhtIdx(pc)] & 2u));
  }
  uint32_t Target(uint32_t pc) const { return target[BtbIdx(pc)] & ~3u; }

  void Update(uint32_t pc, bool br, bool jmp, bool taken, uint32_t tgt,
              uint8_t ctr, bool hit) {
    if (br) {
      uint8_t n = ctr;
      if (taken) {
        n = (ctr == 3) ? 3 : ctr + 1;
      } else {
        n = (ctr == 0) ? 0 : ctr - 1;
      }
      bht[BhtIdx(pc)] = n;
    }
    const int i = BtbIdx(pc);
    if (jmp || (br && (taken || hit))) {
      valid[i] = true;
      tag[i] = Tag(pc);
      target[i] = tgt & ~3u;
      jump[i] = jmp;
    } else if (!jmp && !br && hit) {
      valid[i] = false;
    }
  }
};

void Idle() {
  g->upd_en_i = 0;
  g->upd_pc_i = 0;
  g->upd_is_branch_i = 0;
  g->upd_is_jump_i = 0;
  g->upd_taken_i = 0;
  g->upd_target_i = 0;
  g->upd_bht_i = 0;
  g->upd_btb_hit_i = 0;
}

void CompareLookup(const Model& m, uint32_t pc, const char* tag) {
  g->lookup_pc_i = pc;
  g->eval();
  char w[96];
  std::snprintf(w, sizeof(w), "%s pc=0x%08" PRIx32 " btb_hit", tag, pc);
  tb::CheckEq<uint32_t>(w, g->pred_btb_hit_o, m.Hit(pc) ? 1u : 0u);
  std::snprintf(w, sizeof(w), "%s pc=0x%08" PRIx32 " taken", tag, pc);
  tb::CheckEq<uint32_t>(w, g->pred_taken_o, m.Taken(pc) ? 1u : 0u);
  std::snprintf(w, sizeof(w), "%s pc=0x%08" PRIx32 " bht", tag, pc);
  tb::CheckEq<uint32_t>(w, g->pred_bht_o, m.bht[Model::BhtIdx(pc)]);
  if (m.Hit(pc)) {
    std::snprintf(w, sizeof(w), "%s pc=0x%08" PRIx32 " target", tag, pc);
    tb::CheckEq<uint32_t>(w, g->pred_target_o, m.Target(pc));
  }
}

// Presents one training event for a cycle and applies it to the model.
void Train(Model* m, uint32_t pc, bool br, bool jmp, bool taken, uint32_t tgt,
           uint8_t ctr, bool hit) {
  g->upd_en_i = 1;
  g->upd_pc_i = pc;
  g->upd_is_branch_i = br;
  g->upd_is_jump_i = jmp;
  g->upd_taken_i = taken;
  g->upd_target_i = tgt;
  g->upd_bht_i = ctr;
  g->upd_btb_hit_i = hit;
  g->eval();
  Tick();
  Idle();
  g->eval();
  m->Update(pc, br, jmp, taken, tgt, ctr, hit);
}

}  // namespace

int main(int argc, char** argv) {
  const uint64_t seed = (argc > 1) ? std::strtoull(argv[1], nullptr, 0) : 0xB70u;
  std::printf("tb_p_core_bpu: seed=0x%" PRIx64 "\n", seed);
  tb::Rng rng(seed);

  Vp_core_bpu dut;
  g = &dut;
  Model m;
  m.Reset();

  dut.clk_i = 0;
  dut.rst_ni = 0;
  dut.lookup_pc_i = 0;
  Idle();
  for (int i = 0; i < 3; ++i) Tick();
  dut.rst_ni = 1;
  Tick();

  // ---------------- reset ----------------
  for (int i = 0; i < 2000; ++i) {
    const uint32_t pc = rng.U32() & ~3u;
    dut.lookup_pc_i = pc;
    dut.eval();
    tb::Check(!dut.pred_taken_o && !dut.pred_btb_hit_o,
              "a cold predictor must predict nothing");
  }
  tb::Group("nothing predicted after reset");

  // ---------------- random, against the model ----------------
  // A pool of pcs designed to collide: several share each BTB index with
  // different tags, and several share a BHT index but not a BTB index.
  std::vector<uint32_t> pool;
  for (int i = 0; i < 24; ++i) {
    const uint32_t base = (rng.U32() & 0x0003FFFCu);
    pool.push_back(base);
    pool.push_back(base ^ 0x00000100u);   // same BTB index, different tag
    pool.push_back(base ^ 0x00010000u);   // same BTB and BHT index, other tag
  }
  for (int cyc = 0; cyc < 400000; ++cyc) {
    const uint32_t lpc = pool[rng.U32() % pool.size()];
    dut.lookup_pc_i = lpc;
    // Train as EX would: with the counter and hit bit read for that pc.
    const bool do_upd = (rng.U32() % 4) != 0;
    const uint32_t upc = pool[rng.U32() % pool.size()];
    const uint32_t kind = rng.U32() % 8;
    const bool br = kind < 5;
    const bool jmp = kind == 5 || kind == 6;
    const bool taken = jmp || (br && (rng.U32() & 1u));
    const uint32_t tgt = rng.U32() & ~3u;
    const uint8_t ctr = m.bht[Model::BhtIdx(upc)];
    const bool hit = m.Hit(upc);

    dut.upd_en_i = do_upd;
    dut.upd_pc_i = upc;
    dut.upd_is_branch_i = br;
    dut.upd_is_jump_i = jmp;
    dut.upd_taken_i = taken;
    dut.upd_target_i = tgt;
    dut.upd_bht_i = ctr;
    dut.upd_btb_hit_i = hit;
    // The lookup must reflect the state BEFORE this cycle's training, even
    // when both address the same entry.
    CompareLookup(m, lpc, "random");
    Tick();
    if (do_upd) m.Update(upc, br, jmp, taken, tgt, ctr, hit);
  }
  Idle();
  tb::Group("400000 cycles of random training and lookup vs the model");

  // ---------------- aliasing ----------------
  m.Reset();
  dut.rst_ni = 0; Tick(); dut.rst_ni = 1; Tick();
  // BHT contents survive reset (they are RAM), so resynchronise the model by
  // reading every counter back through the lookup port.
  for (uint32_t i = 0; i < 256; ++i) {
    dut.lookup_pc_i = i << 2;
    dut.eval();
    m.bht[i] = static_cast<uint8_t>(dut.pred_bht_o);
  }
  {
    const uint32_t a = 0x00001040u, b = 0x00005040u;   // same index, other tag
    Train(&m, a, false, true, true, 0x2000u, m.bht[Model::BhtIdx(a)], m.Hit(a));
    CompareLookup(m, a, "alias a");
    CompareLookup(m, b, "alias b");
    tb::Check(dut.pred_btb_hit_o == 0, "a different tag must not hit");
    Train(&m, b, false, true, true, 0x3000u, m.bht[Model::BhtIdx(b)], m.Hit(b));
    CompareLookup(m, a, "alias a after b");
    CompareLookup(m, b, "alias b after b");
    tb::Check(!m.Hit(a), "model: b must have evicted a");
  }
  tb::Group("BTB aliasing: eviction and tag mismatch");

  // ---------------- loop accuracy ----------------
  // A branch taken 9 times and then not taken, repeated 100 times, driven
  // exactly as the pipeline drives the predictor.
  {
    const uint32_t pc = 0x00000A00u, tgt = 0x000009E0u;
    int miss = 0, total = 0;
    for (int run = 0; run < 100; ++run) {
      for (int it = 0; it < 10; ++it) {
        const bool actual = it < 9;
        dut.lookup_pc_i = pc;
        dut.eval();
        const bool pred = dut.pred_taken_o != 0;
        const uint8_t ctr = static_cast<uint8_t>(dut.pred_bht_o);
        const bool hit = dut.pred_btb_hit_o != 0;
        if (pred != actual) ++miss;
        ++total;
        Train(&m, pc, true, false, actual, tgt, ctr, hit);
      }
    }
    std::printf("  loop 9T/1N x100: %d mispredicts in %d branches\n", miss, total);
    // Cold start costs the first two (no BTB entry, then weakly not-taken);
    // after that exactly one per loop exit, the 2-bit counter's hysteresis
    // keeping the re-entry predicted taken.
    tb::CheckEq<int>("loop mispredicts", miss, 100 + 1);
  }
  tb::Group("2-bit hysteresis: one mispredict per loop exit");

  // ---------------- stale entry ----------------
  {
    const uint32_t pc = 0x00000C80u;
    Train(&m, pc, false, true, true, 0x100u, m.bht[Model::BhtIdx(pc)], m.Hit(pc));
    CompareLookup(m, pc, "stale before");
    tb::Check(dut.pred_btb_hit_o && dut.pred_taken_o, "jump entry installed");
    // The same pc now resolves as an ordinary instruction.
    Train(&m, pc, false, false, false, 0, m.bht[Model::BhtIdx(pc)], true);
    CompareLookup(m, pc, "stale after");
    tb::Check(!dut.pred_btb_hit_o, "a stale entry must be invalidated");
  }
  tb::Group("stale BTB entry invalidated by a non-control instruction");

  return tb::Report("p_core_bpu");
}
