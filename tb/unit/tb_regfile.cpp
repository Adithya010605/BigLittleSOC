// ============================================================================
// tb_regfile.cpp — unit testbench for rtl/common/regfile.sv
//
// Coverage:
//   * x0 always reads zero on both ports and is never written
//   * every architectural register can be written and read back
//   * the two read ports are independent (different addresses, same cycle)
//   * WRITE-FIRST bypass: reading the register being written in the same
//     cycle returns the NEW value, on either port, on both ports at once,
//     and NOT for a register that merely aliases the write address partially
//   * a write with we_i deasserted changes nothing
//   * randomised read/write traffic against a C++ shadow model
// ============================================================================
#include "Vregfile.h"
#include "tb_common.h"

#include <cinttypes>
#include <cstring>

static Vregfile* g_dut = nullptr;

// One clock edge. Verilator needs an eval() on each half-cycle for the
// always_ff to see the posedge.
static void Tick() {
  g_dut->clk_i = 0;
  g_dut->eval();
  g_dut->clk_i = 1;
  g_dut->eval();
}

// Drives the read addresses and settles combinational logic without clocking.
static void SetReads(uint8_t a, uint8_t b) {
  g_dut->raddr_a_i = a;
  g_dut->raddr_b_i = b;
  g_dut->eval();
}

static void SetWrite(bool we, uint8_t addr, uint32_t data) {
  g_dut->we_i = we ? 1 : 0;
  g_dut->waddr_i = addr;
  g_dut->wdata_i = data;
  g_dut->eval();
}

// Writes a register and leaves the write port idle afterwards.
static void Write(uint8_t addr, uint32_t data) {
  SetWrite(true, addr, data);
  Tick();
  SetWrite(false, 0, 0);
}

int main(int argc, char** argv) {
  const uint64_t seed = (argc > 1) ? std::strtoull(argv[1], nullptr, 0) : 0x5EEDu;
  std::printf("tb_regfile: seed=0x%" PRIx64 "\n", seed);

  Vregfile dut;
  g_dut = &dut;
  dut.clk_i = 0;
  SetWrite(false, 0, 0);
  SetReads(0, 0);

  // C++ shadow model of architectural state.
  uint32_t ref[32];
  std::memset(ref, 0, sizeof(ref));

  // ---------------- x0 semantics ----------------
  SetReads(0, 0);
  tb::CheckEq<uint32_t>("x0 port A reads 0", dut.rdata_a_o, 0u);
  tb::CheckEq<uint32_t>("x0 port B reads 0", dut.rdata_b_o, 0u);

  // Attempt to write x0 with a very visible pattern, then confirm it is
  // still zero -- both on the bypass path (same cycle) and from storage.
  SetWrite(true, 0, 0xDEADBEEFu);
  SetReads(0, 0);
  tb::CheckEq<uint32_t>("x0 bypass suppressed A", dut.rdata_a_o, 0u);
  tb::CheckEq<uint32_t>("x0 bypass suppressed B", dut.rdata_b_o, 0u);
  Tick();
  SetWrite(false, 0, 0);
  SetReads(0, 0);
  tb::CheckEq<uint32_t>("x0 still 0 after write attempt", dut.rdata_a_o, 0u);
  tb::Group("x0 reads zero and is never written");

  // ---------------- write/read every register ----------------
  for (uint8_t r = 1; r < 32; ++r) {
    const uint32_t val = 0x1000'0000u + (static_cast<uint32_t>(r) * 0x01010101u);
    Write(r, val);
    ref[r] = val;
  }
  for (uint8_t r = 1; r < 32; ++r) {
    SetReads(r, r);
    char what[64];
    std::snprintf(what, sizeof(what), "x%u readback A", r);
    tb::CheckEq<uint32_t>(what, dut.rdata_a_o, ref[r]);
    std::snprintf(what, sizeof(what), "x%u readback B", r);
    tb::CheckEq<uint32_t>(what, dut.rdata_b_o, ref[r]);
  }
  tb::Group("write and read back all 31 writable registers");

  // ---------------- read ports are independent ----------------
  for (uint8_t a = 1; a < 32; ++a) {
    const uint8_t b = static_cast<uint8_t>(((a + 7) % 31) + 1);
    SetReads(a, b);
    char what[64];
    std::snprintf(what, sizeof(what), "independent A(x%u)", a);
    tb::CheckEq<uint32_t>(what, dut.rdata_a_o, ref[a]);
    std::snprintf(what, sizeof(what), "independent B(x%u)", b);
    tb::CheckEq<uint32_t>(what, dut.rdata_b_o, ref[b]);
  }
  tb::Group("read ports independent");

  // ---------------- write-first bypass ----------------
  // Port A only.
  SetWrite(true, 5, 0xCAFEBABEu);
  SetReads(5, 6);
  tb::CheckEq<uint32_t>("bypass A gets new value", dut.rdata_a_o, 0xCAFEBABEu);
  tb::CheckEq<uint32_t>("bypass A leaves B alone", dut.rdata_b_o, ref[6]);

  // Port B only.
  SetReads(6, 5);
  tb::CheckEq<uint32_t>("bypass B gets new value", dut.rdata_b_o, 0xCAFEBABEu);
  tb::CheckEq<uint32_t>("bypass B leaves A alone", dut.rdata_a_o, ref[6]);

  // Both ports read the register being written.
  SetReads(5, 5);
  tb::CheckEq<uint32_t>("bypass both A", dut.rdata_a_o, 0xCAFEBABEu);
  tb::CheckEq<uint32_t>("bypass both B", dut.rdata_b_o, 0xCAFEBABEu);

  // Neither port matches: no bypass, storage value stands.
  SetReads(7, 8);
  tb::CheckEq<uint32_t>("no bypass A", dut.rdata_a_o, ref[7]);
  tb::CheckEq<uint32_t>("no bypass B", dut.rdata_b_o, ref[8]);

  // Commit and confirm the bypassed value really landed in storage.
  Tick();
  SetWrite(false, 0, 0);
  ref[5] = 0xCAFEBABEu;
  SetReads(5, 5);
  tb::CheckEq<uint32_t>("bypassed write committed", dut.rdata_a_o, ref[5]);
  tb::Group("write-first bypass on both ports");

  // ---------------- we_i deasserted must not write ----------------
  SetWrite(false, 9, 0x00000000u);
  SetReads(9, 9);
  tb::CheckEq<uint32_t>("no bypass when we_i low", dut.rdata_a_o, ref[9]);
  Tick();
  SetReads(9, 9);
  tb::CheckEq<uint32_t>("no write when we_i low", dut.rdata_a_o, ref[9]);
  tb::Group("write enable respected");

  // ---------------- randomised traffic ----------------
  tb::Rng rng(seed);
  const int kIters = 20000;
  for (int i = 0; i < kIters; ++i) {
    const bool we = (rng.U32() & 3u) != 0u;         // write ~75% of cycles
    const uint8_t wa = static_cast<uint8_t>(rng.U32() & 31u);
    const uint32_t wd = rng.Corner32();
    const uint8_t ra = static_cast<uint8_t>(rng.U32() & 31u);
    const uint8_t rb = static_cast<uint8_t>(rng.U32() & 31u);

    SetWrite(we, wa, wd);
    SetReads(ra, rb);

    // Expected values under write-first semantics, with x0 forced to zero.
    auto expect = [&](uint8_t r) -> uint32_t {
      if (r == 0) return 0u;
      if (we && wa == r && wa != 0) return wd;
      return ref[r];
    };
    char what[96];
    std::snprintf(what, sizeof(what), "rand[%d] A x%u (we=%d wa=x%u)", i, ra,
                  we ? 1 : 0, wa);
    tb::CheckEq<uint32_t>(what, dut.rdata_a_o, expect(ra));
    std::snprintf(what, sizeof(what), "rand[%d] B x%u (we=%d wa=x%u)", i, rb,
                  we ? 1 : 0, wa);
    tb::CheckEq<uint32_t>(what, dut.rdata_b_o, expect(rb));

    Tick();
    if (we && wa != 0) ref[wa] = wd;
  }
  tb::Group("20000 randomised read/write cycles");

  return tb::Report("regfile");
}
