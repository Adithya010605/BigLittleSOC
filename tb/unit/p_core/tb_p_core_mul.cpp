// ============================================================================
// tb_p_core_mul.cpp — unit testbench for rtl/p_core/p_core_mul.sv
//
// Reference: 64-bit host arithmetic straight from the ISA manual's definition
// of each operation, sharing nothing with the RTL's Booth recoding.
//
// Coverage:
//   * the operand corners that break multipliers: 0, 1, -1, INT_MIN, INT_MAX,
//     single bits, for all four operations and every pairing
//   * every combination of the two operands' sign bits for MULH / MULHSU /
//     MULHU, which is where a signed/unsigned slip shows up
//   * 400,000 random operand pairs (corner-biased)
//   * TIMING: the result appears in exactly the 4th cycle of the operation
//   * HOLD: if the result is not acknowledged it stays on result_o, with
//     done_o high, for as long as it takes
//   * CAPTURE: changing a_i / b_i after the first cycle does not affect the
//     result (EX refreshes its operands underneath a running multiply)
//   * KILL: abandoning an operation at every possible cycle leaves the unit
//     ready to start the next one cleanly
//   * back-to-back operations with no idle cycle between them
// ============================================================================
#include "Vp_core_mul.h"
#include "tb_common.h"

#include <cinttypes>

namespace {

Vp_core_mul* g = nullptr;

void Tick() {
  g->clk_i = 0;
  g->eval();
  g->clk_i = 1;
  g->eval();
}

uint32_t Ref(uint32_t op, uint32_t a, uint32_t b) {
  const int64_t sa = static_cast<int32_t>(a);
  const int64_t sb = static_cast<int32_t>(b);
  const uint64_t ua = a, ub = b;
  switch (op) {
    case 0: return static_cast<uint32_t>(ua * ub);                                   // MUL
    case 1: return static_cast<uint32_t>(static_cast<uint64_t>(sa * sb) >> 32);      // MULH
    case 2: return static_cast<uint32_t>(
                static_cast<uint64_t>(sa * static_cast<int64_t>(ub)) >> 32);         // MULHSU
    default: return static_cast<uint32_t>((ua * ub) >> 32);                          // MULHU
  }
}

const char* kName[4] = {"MUL", "MULH", "MULHSU", "MULHU"};

// Runs one operation. `hold` is how many extra cycles the result waits before
// being acknowledged; `scramble` changes the operand inputs after the first
// cycle. Returns the cycle (0-based) in which done_o first rose.
int Run(uint32_t op, uint32_t a, uint32_t b, int hold, bool scramble,
        tb::Rng* rng, uint32_t* result) {
  g->kill_i = 0;
  g->ack_i = 0;
  g->start_i = 1;
  g->op_i = op;
  for (int cyc = 0; cyc < 12; ++cyc) {
    g->a_i = (cyc > 0 && scramble) ? rng->U32() : a;
    g->b_i = (cyc > 0 && scramble) ? rng->U32() : b;
    g->ack_i = 0;
    g->eval();
    if (g->done_o) {
      *result = g->result_o;
      for (int h = 0; h < hold; ++h) {
        Tick();
        g->a_i = rng->U32();
        g->b_i = rng->U32();
        g->eval();
        tb::Check(g->done_o, "done_o dropped while the result was unacknowledged");
        tb::CheckEq<uint32_t>("held result stable", g->result_o, *result);
      }
      g->ack_i = 1;
      g->eval();
      Tick();
      g->ack_i = 0;
      g->start_i = 0;
      g->eval();
      tb::Check(!g->done_o, "done_o still high after the result was acknowledged");
      return cyc;
    }
    Tick();
  }
  tb::Fail("multiply never completed");
  return -1;
}

void CheckOne(uint32_t op, uint32_t a, uint32_t b, tb::Rng* rng, int hold = 0,
              bool scramble = false) {
  uint32_t r = 0;
  const int cyc = Run(op, a, b, hold, scramble, rng, &r);
  char w[128];
  std::snprintf(w, sizeof(w), "%s 0x%08" PRIx32 " * 0x%08" PRIx32, kName[op], a, b);
  tb::CheckEq<uint32_t>(w, r, Ref(op, a, b));
  tb::CheckEq<int>("result in the 4th cycle", cyc, 3);
}

}  // namespace

int main(int argc, char** argv) {
  const uint64_t seed = (argc > 1) ? std::strtoull(argv[1], nullptr, 0) : 0x3171u;
  std::printf("tb_p_core_mul: seed=0x%" PRIx64 "\n", seed);
  tb::Rng rng(seed);

  Vp_core_mul dut;
  g = &dut;
  dut.clk_i = 0;
  dut.rst_ni = 0;
  dut.start_i = 0;
  dut.kill_i = 0;
  dut.ack_i = 0;
  dut.op_i = 0;
  dut.a_i = 0;
  dut.b_i = 0;
  for (int i = 0; i < 3; ++i) Tick();
  dut.rst_ni = 1;
  Tick();

  // ---------------- corners ----------------
  const uint32_t corners[] = {0u, 1u, 2u, 3u, 0xFFFFFFFFu, 0xFFFFFFFEu,
                              0x80000000u, 0x80000001u, 0x7FFFFFFFu,
                              0x55555555u, 0xAAAAAAAAu, 0x0000FFFFu,
                              0xFFFF0000u, 0x00010000u, 0x12345678u};
  for (uint32_t op = 0; op < 4; ++op) {
    for (uint32_t a : corners) {
      for (uint32_t b : corners) CheckOne(op, a, b, &rng);
    }
  }
  tb::Group("operand corners, all four operations");

  // ---------------- sign-bit combinations ----------------
  for (uint32_t op = 0; op < 4; ++op) {
    for (int sa = 0; sa < 2; ++sa) {
      for (int sb = 0; sb < 2; ++sb) {
        for (int k = 0; k < 500; ++k) {
          uint32_t a = rng.U32() & 0x7FFFFFFFu;
          uint32_t b = rng.U32() & 0x7FFFFFFFu;
          if (sa) a |= 0x80000000u;
          if (sb) b |= 0x80000000u;
          CheckOne(op, a, b, &rng);
        }
      }
    }
  }
  tb::Group("every operand sign combination, all four operations");

  // ---------------- single bits ----------------
  for (uint32_t op = 0; op < 4; ++op) {
    for (int i = 0; i < 32; ++i) {
      for (int j = 0; j < 32; j += 3) CheckOne(op, 1u << i, 1u << j, &rng);
    }
  }
  tb::Group("single-bit operands (every Booth digit position)");

  // ---------------- random ----------------
  for (int i = 0; i < 400000; ++i) {
    CheckOne(rng.U32() & 3u, rng.Corner32(), rng.Corner32(), &rng);
  }
  tb::Group("400000 random operations");

  // ---------------- hold and capture ----------------
  for (int i = 0; i < 2000; ++i) {
    CheckOne(rng.U32() & 3u, rng.Corner32(), rng.Corner32(), &rng,
             static_cast<int>(rng.U32() % 6), /*scramble=*/true);
  }
  tb::Group("result held until acknowledged; operands captured at start");

  // ---------------- kill at every cycle ----------------
  for (int kill_at = 0; kill_at <= 6; ++kill_at) {
    for (int k = 0; k < 200; ++k) {
      dut.start_i = 1;
      dut.op_i = rng.U32() & 3u;
      dut.a_i = rng.U32();
      dut.b_i = rng.U32();
      dut.ack_i = 0;
      for (int c = 0; c < kill_at; ++c) {
        dut.kill_i = 0;
        dut.eval();
        Tick();
      }
      dut.kill_i = 1;
      dut.eval();
      Tick();
      dut.kill_i = 0;
      dut.start_i = 0;
      dut.eval();
      tb::Check(!dut.done_o, "done_o high after a kill");
      // The unit must now run a fresh operation correctly.
      CheckOne(rng.U32() & 3u, rng.Corner32(), rng.Corner32(), &rng);
    }
  }
  tb::Group("kill in every cycle, including after completion");

  // ---------------- back to back ----------------
  // Acknowledge and present the next operation in the same cycle, as EX does
  // when two multiplies are adjacent.
  {
    uint32_t op = 0, a = 0, b = 0;
    dut.kill_i = 0;
    dut.start_i = 1;
    int cyc = 0;
    int ops = 0;
    op = rng.U32() & 3u; a = rng.Corner32(); b = rng.Corner32();
    while (ops < 5000) {
      dut.op_i = op; dut.a_i = a; dut.b_i = b;
      dut.ack_i = 0;
      dut.eval();
      if (dut.done_o) {
        char w[96];
        std::snprintf(w, sizeof(w), "back-to-back %s", kName[op]);
        tb::CheckEq<uint32_t>(w, dut.result_o, Ref(op, a, b));
        tb::CheckEq<int>("back-to-back latency", cyc, 3);
        dut.ack_i = 1;
        dut.eval();
        Tick();
        ++ops;
        cyc = 0;
        op = rng.U32() & 3u; a = rng.Corner32(); b = rng.Corner32();
        continue;
      }
      Tick();
      ++cyc;
    }
    dut.start_i = 0;
    dut.ack_i = 0;
  }
  tb::Group("5000 back-to-back operations with no idle cycle");

  return tb::Report("p_core_mul");
}
