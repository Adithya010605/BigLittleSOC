// ============================================================================
// tb_alu.cpp — unit testbench for rtl/common/alu.sv
//
// Coverage:
//   * every operation against a C++ reference model
//   * directed corner cases: shift by 0 and by 31, SRA sign propagation,
//     SLT vs SLTU with negative operands, add/sub wraparound at the 32-bit
//     boundary, x - x, INT_MIN edges
//   * 10k biased-random vectors across all ten operations
//   * the comparison outputs (cmp_eq/cmp_lt/cmp_ltu), which the ID stage's
//     branch comparator relies on
// ============================================================================
#include "Valu.h"
#include "tb_common.h"

#include <cinttypes>
#include <vector>

// Must match the alu_op_e encoding in rtl/common/e_core_pkg.sv.
enum AluOp : uint8_t {
  ALU_SUB  = 0x0,
  ALU_SLL  = 0x1,
  ALU_SLT  = 0x2,
  ALU_SLTU = 0x3,
  ALU_XOR  = 0x4,
  ALU_SRL  = 0x5,
  ALU_OR   = 0x6,
  ALU_AND  = 0x7,
  ALU_SRA  = 0x8,
  ALU_ADD  = 0xF,
};

static const struct { AluOp op; const char* name; } kOps[] = {
    {ALU_ADD, "ADD"},   {ALU_SUB, "SUB"},   {ALU_SLL, "SLL"},
    {ALU_SLT, "SLT"},   {ALU_SLTU, "SLTU"}, {ALU_XOR, "XOR"},
    {ALU_SRL, "SRL"},   {ALU_OR, "OR"},     {ALU_AND, "AND"},
    {ALU_SRA, "SRA"},
};

// ---------------------------------------------------------------------------
// Reference model. Written directly from the RV32I spec, deliberately in the
// most obvious form possible so it does not share bugs with the RTL.
// ---------------------------------------------------------------------------
static uint32_t RefAlu(AluOp op, uint32_t a, uint32_t b) {
  const uint32_t shamt = b & 31u;
  switch (op) {
    case ALU_ADD:  return a + b;
    case ALU_SUB:  return a - b;
    case ALU_SLL:  return a << shamt;
    case ALU_SRL:  return a >> shamt;
    case ALU_SRA:  return static_cast<uint32_t>(static_cast<int32_t>(a) >> shamt);
    case ALU_XOR:  return a ^ b;
    case ALU_OR:   return a | b;
    case ALU_AND:  return a & b;
    case ALU_SLT:
      return (static_cast<int32_t>(a) < static_cast<int32_t>(b)) ? 1u : 0u;
    case ALU_SLTU: return (a < b) ? 1u : 0u;
  }
  return 0u;
}

static Valu* g_dut = nullptr;

// Applies one vector and checks result plus all three comparison outputs.
static void Apply(AluOp op, const char* opname, uint32_t a, uint32_t b) {
  g_dut->operator_i  = static_cast<uint8_t>(op);
  g_dut->operand_a_i = a;
  g_dut->operand_b_i = b;
  g_dut->eval();

  char what[128];
  std::snprintf(what, sizeof(what), "%s(0x%08" PRIx32 ", 0x%08" PRIx32 ")",
                opname, a, b);
  tb::CheckEq<uint32_t>(what, g_dut->result_o, RefAlu(op, a, b));

  // The comparison outputs are only architecturally meaningful when the ALU is
  // driven as a subtraction, which is exactly how the ID branch comparator
  // uses them.
  if (op == ALU_SUB || op == ALU_SLT || op == ALU_SLTU) {
    char c[160];
    std::snprintf(c, sizeof(c), "%s cmp_eq", what);
    tb::CheckEq<uint32_t>(c, g_dut->cmp_eq_o, (a == b) ? 1u : 0u);
    std::snprintf(c, sizeof(c), "%s cmp_lt", what);
    tb::CheckEq<uint32_t>(
        c, g_dut->cmp_lt_o,
        (static_cast<int32_t>(a) < static_cast<int32_t>(b)) ? 1u : 0u);
    std::snprintf(c, sizeof(c), "%s cmp_ltu", what);
    tb::CheckEq<uint32_t>(c, g_dut->cmp_ltu_o, (a < b) ? 1u : 0u);
  }
}

// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
  const uint64_t seed = (argc > 1) ? std::strtoull(argv[1], nullptr, 0) : 0xA1Cu;
  std::printf("tb_alu: seed=0x%" PRIx64 "\n", seed);

  Valu dut;
  g_dut = &dut;

  // ---------------- directed: arithmetic wraparound ----------------
  const uint32_t kMin = 0x80000000u;  // INT32_MIN
  const uint32_t kMax = 0x7FFFFFFFu;  // INT32_MAX
  Apply(ALU_ADD, "ADD", kMax, 1u);            // wraps to INT32_MIN
  Apply(ALU_ADD, "ADD", 0xFFFFFFFFu, 1u);     // wraps to 0
  Apply(ALU_ADD, "ADD", kMin, kMin);          // wraps to 0
  Apply(ALU_SUB, "SUB", 0u, 1u);              // borrows to 0xFFFFFFFF
  Apply(ALU_SUB, "SUB", kMin, 1u);            // wraps to INT32_MAX
  Apply(ALU_SUB, "SUB", 12345u, 12345u);      // x - x == 0, exercises cmp_eq
  Apply(ALU_SUB, "SUB", kMin, kMin);
  tb::Group("arithmetic wraparound");

  // ---------------- directed: shifts by 0 and 31 ----------------
  for (uint32_t val : {0x00000001u, 0x80000000u, 0xDEADBEEFu, 0xFFFFFFFFu}) {
    for (uint32_t sh : {0u, 1u, 31u}) {
      Apply(ALU_SLL, "SLL", val, sh);
      Apply(ALU_SRL, "SRL", val, sh);
      Apply(ALU_SRA, "SRA", val, sh);
    }
  }
  // Shift amount must use only b[4:0]; the upper bits are ignored by RV32I.
  // If the RTL wired the full operand into the shifter these would break.
  Apply(ALU_SLL, "SLL", 0x00000001u, 32u);   // == shift by 0
  Apply(ALU_SLL, "SLL", 0x00000001u, 33u);   // == shift by 1
  Apply(ALU_SRL, "SRL", 0x80000000u, 0xFFFFFFE1u);  // == shift by 1
  Apply(ALU_SRA, "SRA", 0x80000000u, 0xFFFFFFFFu);  // == shift by 31
  tb::Group("shift amount masking, shift by 0 and 31");

  // ---------------- directed: SRA sign propagation ----------------
  Apply(ALU_SRA, "SRA", 0x80000000u, 31u);   // -> 0xFFFFFFFF
  Apply(ALU_SRA, "SRA", 0xFFFFFFFFu, 31u);   // -> 0xFFFFFFFF
  Apply(ALU_SRA, "SRA", 0x7FFFFFFFu, 31u);   // -> 0x00000000
  Apply(ALU_SRA, "SRA", 0xC0000000u, 4u);    // -> 0xFC000000
  Apply(ALU_SRL, "SRL", 0x80000000u, 31u);   // -> 0x00000001 (no sign fill)
  tb::Group("SRA sign propagation vs SRL");

  // ---------------- directed: SLT vs SLTU with negative operands ----------
  // These four cases are where a naive shared comparator gets it wrong.
  Apply(ALU_SLT,  "SLT",  0xFFFFFFFFu, 0x00000001u);  // -1 <  1  -> 1
  Apply(ALU_SLTU, "SLTU", 0xFFFFFFFFu, 0x00000001u);  // huge > 1 -> 0
  Apply(ALU_SLT,  "SLT",  0x00000001u, 0xFFFFFFFFu);  //  1 > -1  -> 0
  Apply(ALU_SLTU, "SLTU", 0x00000001u, 0xFFFFFFFFu);  //  1 < huge-> 1
  Apply(ALU_SLT,  "SLT",  kMin, kMax);                // INT_MIN < INT_MAX -> 1
  Apply(ALU_SLTU, "SLTU", kMin, kMax);                // 2^31 > 2^31-1     -> 0
  Apply(ALU_SLT,  "SLT",  kMin, kMin);                // equal -> 0
  Apply(ALU_SLTU, "SLTU", kMin, kMin);                // equal -> 0
  Apply(ALU_SLT,  "SLT",  0xFFFFFFFEu, 0xFFFFFFFFu);  // -2 < -1 -> 1
  Apply(ALU_SLTU, "SLTU", 0xFFFFFFFEu, 0xFFFFFFFFu);  // also 1 here
  tb::Group("SLT vs SLTU with negative operands");

  // ---------------- directed: logical identities ----------------
  Apply(ALU_XOR, "XOR", 0xAAAAAAAAu, 0x55555555u);
  Apply(ALU_XOR, "XOR", 0xDEADBEEFu, 0xDEADBEEFu);
  Apply(ALU_OR,  "OR",  0xAAAAAAAAu, 0x55555555u);
  Apply(ALU_AND, "AND", 0xAAAAAAAAu, 0x55555555u);
  Apply(ALU_AND, "AND", 0xFFFFFFFFu, 0xDEADBEEFu);
  Apply(ALU_OR,  "OR",  0x00000000u, 0xDEADBEEFu);
  tb::Group("logical operations");

  // ---------------- exhaustive shift amounts ----------------
  for (uint32_t sh = 0; sh < 32; ++sh) {
    Apply(ALU_SLL, "SLL", 0xDEADBEEFu, sh);
    Apply(ALU_SRL, "SRL", 0xDEADBEEFu, sh);
    Apply(ALU_SRA, "SRA", 0xDEADBEEFu, sh);
    Apply(ALU_SRA, "SRA", 0x12345678u, sh);
  }
  tb::Group("all 32 shift amounts");

  // ---------------- 10k biased-random vectors ----------------
  tb::Rng rng(seed);
  const int kRandom = 10000;
  for (int i = 0; i < kRandom; ++i) {
    const auto& e = kOps[rng.U32() % (sizeof(kOps) / sizeof(kOps[0]))];
    Apply(e.op, e.name, rng.Corner32(), rng.Corner32());
  }
  tb::Group("10000 random vectors");

  return tb::Report("alu");
}
