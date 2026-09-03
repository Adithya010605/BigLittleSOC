// ============================================================================
// tb_lsu.cpp — unit testbench for rtl/common/lsu.sv
//
// Coverage:
//   * EXHAUSTIVE over {size} x {addr[1:0]} x {signed, unsigned}: byte enables,
//     store-data placement, load extraction and extension, misalignment
//   * sign extension boundary for LB/LH (0x7F/0x80, 0x7FFF/0x8000) versus the
//     zero extension of LBU/LHU
//   * that a store places its bytes in exactly the lanes be_o enables, checked
//     by reconstructing the memory word the way a real memory would
//   * randomised traffic against a C++ model
// ============================================================================
#include "Vlsu.h"
#include "tb_common.h"

#include <cinttypes>

// Must match mem_size_e in rtl/common/e_core_pkg.sv.
enum MemSize : uint8_t { SZ_BYTE = 0, SZ_HALF = 1, SZ_WORD = 2 };

static const char* SizeName(MemSize s) {
  switch (s) {
    case SZ_BYTE: return "B";
    case SZ_HALF: return "H";
    default: return "W";
  }
}

// ---------------------------------------------------------------------------
// Reference model
// ---------------------------------------------------------------------------
static uint8_t RefBe(MemSize size, uint8_t lsb) {
  switch (size) {
    case SZ_BYTE: return static_cast<uint8_t>(0x1u << lsb);
    case SZ_HALF: return (lsb & 2u) ? 0xCu : 0x3u;
    default: return 0xFu;
  }
}

static uint32_t RefWdata(MemSize size, uint32_t v) {
  switch (size) {
    case SZ_BYTE: {
      const uint32_t b = v & 0xFFu;
      return b | (b << 8) | (b << 16) | (b << 24);
    }
    case SZ_HALF: {
      const uint32_t h = v & 0xFFFFu;
      return h | (h << 16);
    }
    default: return v;
  }
}

static uint32_t RefRdata(MemSize size, bool sign, uint8_t lsb, uint32_t rd) {
  switch (size) {
    case SZ_BYTE: {
      const uint32_t b = (rd >> (8u * lsb)) & 0xFFu;
      return sign ? static_cast<uint32_t>(static_cast<int8_t>(b)) : b;
    }
    case SZ_HALF: {
      const uint32_t h = (rd >> ((lsb & 2u) ? 16u : 0u)) & 0xFFFFu;
      return sign ? static_cast<uint32_t>(static_cast<int16_t>(h)) : h;
    }
    default: return rd;
  }
}

static bool RefMisaligned(MemSize size, uint8_t lsb) {
  switch (size) {
    case SZ_BYTE: return false;
    case SZ_HALF: return (lsb & 1u) != 0u;
    default: return lsb != 0u;
  }
}

static Vlsu* g_dut = nullptr;

static void Apply(MemSize size, bool sign, uint8_t lsb, uint32_t wdata,
                  uint32_t rdata) {
  g_dut->size_i = static_cast<uint8_t>(size);
  g_dut->sign_i = sign ? 1 : 0;
  g_dut->addr_lsb_i = lsb;
  g_dut->wdata_i = wdata;
  g_dut->rdata_i = rdata;
  g_dut->eval();

  char what[160];
  std::snprintf(what, sizeof(what), "%s%s lsb=%u wd=0x%08" PRIx32
                " rd=0x%08" PRIx32 " be", SizeName(size), sign ? "" : "U", lsb,
                wdata, rdata);
  tb::CheckEq<uint32_t>(what, g_dut->be_o, RefBe(size, lsb));

  std::snprintf(what, sizeof(what), "%s lsb=%u wd=0x%08" PRIx32 " aligned",
                SizeName(size), lsb, wdata);
  tb::CheckEq<uint32_t>(what, g_dut->wdata_aligned_o, RefWdata(size, wdata));

  std::snprintf(what, sizeof(what), "%s%s lsb=%u rd=0x%08" PRIx32 " ext",
                SizeName(size), sign ? "" : "U", lsb, rdata);
  tb::CheckEq<uint32_t>(what, g_dut->rdata_ext_o,
                        RefRdata(size, sign, lsb, rdata));

  std::snprintf(what, sizeof(what), "%s lsb=%u misaligned", SizeName(size), lsb);
  tb::CheckEq<uint32_t>(what, g_dut->misaligned_o,
                        RefMisaligned(size, lsb) ? 1u : 0u);

  // A store must land exactly in the enabled lanes. Reconstruct the word a
  // real memory would end up holding and confirm the addressed bytes of the
  // original value are there and nothing else moved.
  if (!RefMisaligned(size, lsb)) {
    const uint8_t be = RefBe(size, lsb);
    const uint32_t old_word = 0xA5A5A5A5u;
    uint32_t mem = old_word;
    for (int lane = 0; lane < 4; ++lane) {
      if (be & (1u << lane)) {
        const uint32_t byte = (g_dut->wdata_aligned_o >> (8 * lane)) & 0xFFu;
        mem = (mem & ~(0xFFu << (8 * lane))) | (byte << (8 * lane));
      }
    }
    uint32_t expect_mem = old_word;
    const int nbytes = (size == SZ_BYTE) ? 1 : (size == SZ_HALF) ? 2 : 4;
    for (int k = 0; k < nbytes; ++k) {
      const int lane = lsb + k;
      const uint32_t byte = (wdata >> (8 * k)) & 0xFFu;
      expect_mem = (expect_mem & ~(0xFFu << (8 * lane))) | (byte << (8 * lane));
    }
    std::snprintf(what, sizeof(what), "%s store lsb=%u lands in memory",
                  SizeName(size), lsb);
    tb::CheckEq<uint32_t>(what, mem, expect_mem);
  }
}

int main(int argc, char** argv) {
  const uint64_t seed = (argc > 1) ? std::strtoull(argv[1], nullptr, 0) : 0x15Fu;
  std::printf("tb_lsu: seed=0x%" PRIx64 "\n", seed);

  Vlsu dut;
  g_dut = &dut;

  const MemSize kSizes[] = {SZ_BYTE, SZ_HALF, SZ_WORD};

  // ---------------- exhaustive size x offset x signedness ----------------
  // These are the values that expose a lane-selection or extension bug: each
  // byte is distinct, and the sign bits of every lane differ.
  const uint32_t kPatterns[] = {0x00000000u, 0xFFFFFFFFu, 0x12345678u,
                                0x807F8070u, 0x8000FF7Fu, 0xDEADBEEFu};
  for (MemSize size : kSizes) {
    for (uint8_t lsb = 0; lsb < 4; ++lsb) {
      for (bool sign : {false, true}) {
        for (uint32_t p : kPatterns) {
          Apply(size, sign, lsb, p, p);
          Apply(size, sign, lsb, ~p, p);
        }
      }
    }
  }
  tb::Group("exhaustive size x offset x signedness");

  // ---------------- sign extension boundaries ----------------
  // LB of 0x7F stays positive; LB of 0x80 becomes 0xFFFFFF80. LBU never sign
  // extends. Same story one size up for LH/LHU.
  for (uint8_t lsb = 0; lsb < 4; ++lsb) {
    const uint32_t pos = 0x7Fu << (8 * lsb);
    const uint32_t neg = 0x80u << (8 * lsb);
    Apply(SZ_BYTE, true, lsb, 0, pos);
    Apply(SZ_BYTE, true, lsb, 0, neg);
    Apply(SZ_BYTE, false, lsb, 0, neg);
  }
  for (uint8_t lsb : {0, 2}) {
    const uint32_t pos = 0x7FFFu << (8 * lsb);
    const uint32_t neg = 0x8000u << (8 * lsb);
    Apply(SZ_HALF, true, lsb, 0, pos);
    Apply(SZ_HALF, true, lsb, 0, neg);
    Apply(SZ_HALF, false, lsb, 0, neg);
  }
  tb::Group("LB/LH sign extension vs LBU/LHU zero extension");

  // ---------------- misalignment detection ----------------
  // Word: only offset 0 is legal. Half: only offsets 0 and 2. Byte: all legal.
  for (uint8_t lsb = 0; lsb < 4; ++lsb) {
    Apply(SZ_WORD, true, lsb, 0x11223344u, 0x55667788u);
    Apply(SZ_HALF, true, lsb, 0x11223344u, 0x55667788u);
    Apply(SZ_BYTE, true, lsb, 0x11223344u, 0x55667788u);
  }
  tb::Group("misalignment detection for every size and offset");

  // ---------------- randomised ----------------
  tb::Rng rng(seed);
  const int kIters = 30000;
  for (int i = 0; i < kIters; ++i) {
    Apply(kSizes[rng.U32() % 3], (rng.U32() & 1u) != 0u,
          static_cast<uint8_t>(rng.U32() & 3u), rng.Corner32(), rng.Corner32());
  }
  tb::Group("30000 random accesses");

  return tb::Report("lsu");
}
