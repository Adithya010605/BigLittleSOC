// ============================================================================
// tb_common.h — shared scaffolding for the unit testbenches.
//
// Every unit testbench is a plain C++ program that drives a Verilated module
// and compares against a reference model written in the same file. A test
// reports through Check()/CheckEq() and finishes with Report(), whose exit
// status the regression driver interprets.
//
// Output convention, consumed by scripts/run_unit.sh:
//   [PASS] <name>       one line per passing check group
//   [FAIL] <detail>     one line per failing check
// ============================================================================
#ifndef TB_COMMON_H
#define TB_COMMON_H

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

namespace tb {

inline int g_checks = 0;
inline int g_failures = 0;
inline int g_fail_print_budget = 25;

// Deterministic PRNG so a failing random vector can always be reproduced from
// the seed printed in the header. xorshift64* — small, fast, good enough.
class Rng {
 public:
  explicit Rng(uint64_t seed) : s_(seed ? seed : 0x9E3779B97F4A7C15ULL) {}
  uint64_t Next() {
    s_ ^= s_ >> 12;
    s_ ^= s_ << 25;
    s_ ^= s_ >> 27;
    return s_ * 0x2545F4914F6CDD1DULL;
  }
  uint32_t U32() { return static_cast<uint32_t>(Next() >> 32); }
  // Value biased towards interesting corners: all-zeros, all-ones, sign bit,
  // small magnitudes, single bits — uniform random alone almost never
  // produces the cases that actually break arithmetic hardware.
  uint32_t Corner32() {
    switch (U32() % 8) {
      case 0: return 0u;
      case 1: return 0xFFFFFFFFu;
      case 2: return 0x80000000u;
      case 3: return 0x7FFFFFFFu;
      case 4: return U32() % 8;
      case 5: return 0u - (U32() % 8);
      case 6: return 1u << (U32() % 32);
      default: return U32();
    }
  }
 private:
  uint64_t s_;
};

inline void Fail(const std::string& detail) {
  ++g_failures;
  if (g_fail_print_budget > 0) {
    --g_fail_print_budget;
    std::printf("[FAIL] %s\n", detail.c_str());
  } else if (g_fail_print_budget == 0) {
    --g_fail_print_budget;
    std::printf("[FAIL] ... further failures suppressed\n");
  }
}

inline bool Check(bool cond, const std::string& detail) {
  ++g_checks;
  if (!cond) {
    Fail(detail);
    return false;
  }
  return true;
}

template <typename T>
inline bool CheckEq(const std::string& what, T got, T expected) {
  ++g_checks;
  if (got != expected) {
    char buf[256];
    std::snprintf(buf, sizeof(buf), "%s: got 0x%llx expected 0x%llx",
                  what.c_str(), static_cast<unsigned long long>(got),
                  static_cast<unsigned long long>(expected));
    Fail(buf);
    return false;
  }
  return true;
}

// Marks a named group of checks as complete. Prints one [PASS] line so the
// regression driver can report how many groups a module exercised.
inline void Group(const char* name) {
  std::printf("[PASS] %s\n", name);
}

inline int Report(const char* module_name) {
  std::printf("---- %s: %d checks, %d failures ----\n", module_name, g_checks,
              g_failures);
  if (g_failures != 0) {
    std::printf("RESULT: FAIL\n");
    return 1;
  }
  std::printf("RESULT: PASS\n");
  return 0;
}

}  // namespace tb

#endif  // TB_COMMON_H
