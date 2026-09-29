// ============================================================================
// tb_p_core_div.cpp — unit testbench for rtl/p_core/p_core_div.sv
//
// Reference: host division, with the two cases the ISA defines explicitly
// (divide by zero, and INT_MIN / -1 overflow) written out from the manual's
// table rather than left to the host, where they are undefined behaviour.
//
// Coverage:
//   * both special cases for all four operations, over many dividends
//   * the operand corners, all pairings, all four operations
//   * every combination of operand signs for DIV / REM
//   * divisors that are powers of two and dividends just either side of a
//     multiple of the divisor, where a restoring step decides wrongly first
//   * 150,000 random operations (corner-biased)
//   * TIMING: the result appears in exactly the 33rd cycle
//   * HOLD, CAPTURE and KILL, as for the multiplier
// ============================================================================
#include "Vp_core_div.h"
#include "tb_common.h"

#include <cinttypes>

namespace {

Vp_core_div* g = nullptr;

void Tick() {
  g->clk_i = 0;
  g->eval();
  g->clk_i = 1;
  g->eval();
}

// op = md_op[1:0] within the divide group: 0 DIV, 1 DIVU, 2 REM, 3 REMU.
uint32_t Ref(uint32_t op, uint32_t a, uint32_t b) {
  const int32_t sa = static_cast<int32_t>(a);
  const int32_t sb = static_cast<int32_t>(b);
  switch (op) {
    case 0:  // DIV
      if (b == 0) return 0xFFFFFFFFu;
      if (a == 0x80000000u && b == 0xFFFFFFFFu) return 0x80000000u;
      return static_cast<uint32_t>(sa / sb);
    case 1:  // DIVU
      if (b == 0) return 0xFFFFFFFFu;
      return a / b;
    case 2:  // REM
      if (b == 0) return a;
      if (a == 0x80000000u && b == 0xFFFFFFFFu) return 0u;
      return static_cast<uint32_t>(sa % sb);
    default:  // REMU
      if (b == 0) return a;
      return a % b;
  }
}

const char* kName[4] = {"DIV", "DIVU", "REM", "REMU"};
constexpr int kLatency = 32;   // done_o rises in cycle 32 (0-based): 33 cycles

int Run(uint32_t op, uint32_t a, uint32_t b, int hold, bool scramble,
        tb::Rng* rng, uint32_t* result) {
  g->kill_i = 0;
  g->ack_i = 0;
  g->start_i = 1;
  g->op_i = op;
  for (int cyc = 0; cyc < 40; ++cyc) {
    g->a_i = (cyc > 0 && scramble) ? rng->U32() : a;
    g->b_i = (cyc > 0 && scramble) ? rng->U32() : b;
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
  tb::Fail("divide never completed");
  return -1;
}

void CheckOne(uint32_t op, uint32_t a, uint32_t b, tb::Rng* rng, int hold = 0,
              bool scramble = false) {
  uint32_t r = 0;
  const int cyc = Run(op, a, b, hold, scramble, rng, &r);
  char w[128];
  std::snprintf(w, sizeof(w), "%s 0x%08" PRIx32 " / 0x%08" PRIx32, kName[op], a, b);
  tb::CheckEq<uint32_t>(w, r, Ref(op, a, b));
  tb::CheckEq<int>("result in the 33rd cycle", cyc, kLatency);
}

}  // namespace

int main(int argc, char** argv) {
  const uint64_t seed = (argc > 1) ? std::strtoull(argv[1], nullptr, 0) : 0xD1Du;
  std::printf("tb_p_core_div: seed=0x%" PRIx64 "\n", seed);
  tb::Rng rng(seed);

  Vp_core_div dut;
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

  // ---------------- the ISA's special cases ----------------
  const uint32_t dividends[] = {0u, 1u, 7u, 0xFFFFFFFFu, 0x80000000u,
                                0x7FFFFFFFu, 0x12345678u, 0xDEADBEEFu};
  for (uint32_t op = 0; op < 4; ++op) {
    for (uint32_t a : dividends) CheckOne(op, a, 0u, &rng);   // divide by zero
    CheckOne(op, 0x80000000u, 0xFFFFFFFFu, &rng);             // overflow
  }
  tb::Group("divide by zero and INT_MIN / -1, all four operations");

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

  // ---------------- sign combinations ----------------
  for (uint32_t op = 0; op < 4; ++op) {
    for (int sa = 0; sa < 2; ++sa) {
      for (int sb = 0; sb < 2; ++sb) {
        for (int k = 0; k < 300; ++k) {
          uint32_t a = rng.U32() & 0x7FFFFFFFu;
          uint32_t b = (rng.U32() >> (rng.U32() % 31)) & 0x7FFFFFFFu;
          if (sa) a |= 0x80000000u;
          if (sb) b |= 0x80000000u;
          CheckOne(op, a, b, &rng);
        }
      }
    }
  }
  tb::Group("every operand sign combination");

  // ---------------- near multiples ----------------
  for (int k = 0; k < 3000; ++k) {
    const uint32_t b = (rng.U32() >> (rng.U32() % 32)) | 1u;
    const uint32_t q = rng.U32() >> (rng.U32() % 32);
    const uint32_t m = q * b;
    for (int d = -1; d <= 1; ++d) {
      CheckOne(rng.U32() & 3u, m + static_cast<uint32_t>(d), b, &rng);
    }
    CheckOne(rng.U32() & 3u, rng.U32(), 1u << (rng.U32() % 32), &rng);
  }
  tb::Group("dividends either side of a multiple; power-of-two divisors");

  // ---------------- random ----------------
  for (int i = 0; i < 150000; ++i) {
    // A random divisor is almost always large, giving a tiny quotient; shift
    // it down half the time so small divisors are exercised as heavily.
    uint32_t b = rng.Corner32();
    if (rng.U32() & 1u) b >>= rng.U32() % 32;
    CheckOne(rng.U32() & 3u, rng.Corner32(), b, &rng);
  }
  tb::Group("150000 random operations");

  // ---------------- hold and capture ----------------
  for (int i = 0; i < 1000; ++i) {
    CheckOne(rng.U32() & 3u, rng.Corner32(), rng.Corner32() >> (rng.U32() % 32),
             &rng, static_cast<int>(rng.U32() % 6), /*scramble=*/true);
  }
  tb::Group("result held until acknowledged; operands captured at start");

  // ---------------- kill ----------------
  for (int kill_at : {0, 1, 2, 5, 16, 31, 32, 33, 35}) {
    for (int k = 0; k < 40; ++k) {
      dut.start_i = 1;
      dut.op_i = rng.U32() & 3u;
      dut.a_i = rng.U32();
      dut.b_i = rng.U32() | 1u;
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
      CheckOne(rng.U32() & 3u, rng.Corner32(), rng.Corner32(), &rng);
    }
  }
  tb::Group("kill at every phase, including after completion");

  return tb::Report("p_core_div");
}
