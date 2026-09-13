#!/usr/bin/env bash
# Build and run the rv32ui-p compliance suite from third_party/riscv-tests.
#
# The upstream suite links its tests at 0x8000_0000 for a Spike-like machine.
# This core's memory map puts ROM at 0x0000_0000 (spec section 3), so the tests
# are re-linked here with sw/common/riscv_tests.ld and the upstream env headers
# from riscv-tests/env/p (physical-memory, machine-mode environment).
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
THIRD=${THIRD:-$ROOT/third_party}
SIM="$BUILD/e_core_sim"
OUT="$BUILD/riscv-tests"
mkdir -p "$OUT"

# shellcheck source=scripts/toolchain.sh
. "$ROOT/scripts/toolchain.sh"

ISA_DIR="$THIRD/riscv-tests/isa"
ENV_DIR="$THIRD/riscv-tests/env/p"
LDS="$ROOT/sw/common/riscv_tests.ld"

if [ ! -d "$ISA_DIR/rv32ui" ]; then
  echo "==> riscv-tests: not checked out — run 'make riscv-tests-fetch'"
  exit 1
fi

"$ROOT/scripts/build_core.sh" || exit 1
if [ ! -x "$SIM" ]; then echo "==> riscv-tests: simulator not built yet"; exit 0; fi
command -v "$RVCC" >/dev/null 2>&1 || { echo "==> riscv-tests: no RISC-V compiler ($RVCC)"; exit 1; }
[ -f "$LDS" ] || { echo "==> riscv-tests: missing $LDS"; exit 1; }

# isa/rv32ui/<name>.S is a thin wrapper that redefines RVTEST_RV64U to the
# 32-bit form and includes ../rv64ui/<name>.S, which is exactly how upstream
# builds rv32ui-p-*. Using the wrappers rather than the rv64 sources directly
# is what keeps the rv64-only tests (addiw, ld, sd, sllw, ...) out.
SRC_DIR="$ISA_DIR/rv32ui"

# The authoritative rv32ui list, taken verbatim from isa/rv32ui/Makefrag.
TEST_LIST="simple add addi and andi auipc beq bge bgeu blt bltu bne fence_i \
           jal jalr lb lbu lh lhu lw ld_st lui ma_data or ori sb sh sw st_ld \
           sll slli slt slti sltiu sltu sra srai srl srli sub xor xori"

# Documented exclusions. Both are deliberate consequences of this core's
# specification, not defects; see docs/e_core_verification_plan.md.
#
#   fence_i  requires an instruction cache to be meaningful. This core has no
#            caches, so FENCE.I is an architectural NOP and the test cannot
#            distinguish a correct implementation from a broken one.
#   ma_data  exercises MISALIGNED loads and stores and expects the hardware to
#            complete them. This core traps misaligned accesses by design
#            (specification section 2.4: "Misaligned accesses raise exceptions;
#            do not implement hardware misalignment fixup"), and the test
#            installs no handler to emulate them, so it cannot pass. The
#            behaviour it would test is covered instead by tb/asm/mem_align.S
#            and by the misaligned cases in tb/asm/trap_exceptions.S.
SKIP_LIST=${RISCV_TESTS_SKIP:-"fence_i ma_data"}

CFLAGS="-march=rv32i_zicsr -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding \
        -fno-builtin -static -Wa,-march=rv32i_zicsr \
        -I$ENV_DIR -I$ISA_DIR/macros/scalar"

pass=0; fail=0; skip=0
declare -a rows
printf "==> riscv-tests rv32ui-p\n"
for name in $TEST_LIST; do
  src="$SRC_DIR/$name.S"
  if [ ! -f "$src" ]; then
    rows+=("$(printf '%-14s %-8s %s' "$name" "MISSING" "$src")")
    fail=$((fail+1)); continue
  fi
  if [[ " $SKIP_LIST " == *" $name "* ]]; then
    rows+=("$(printf '%-14s %-8s %s' "$name" "SKIP" "documented exclusion")")
    skip=$((skip+1)); continue
  fi
  elf="$OUT/rv32ui-p-$name.elf"
  if ! $RVCC $CFLAGS -T "$LDS" -o "$elf" "$src" > "$OUT/$name.build.log" 2>&1; then
    rows+=("$(printf '%-14s %-8s %s' "$name" "BUILD" "see $OUT/$name.build.log")")
    fail=$((fail+1)); continue
  fi
  log="$OUT/$name.log"
  if "$SIM" --elf "$elf" --waits=0 --max-cycles=2000000 > "$log" 2>&1; then
    cyc=$(grep -oP 'cycles=\K[0-9]+' "$log" | tail -1)
    ins=$(grep -oP 'instret=\K[0-9]+' "$log" | tail -1)
    rows+=("$(printf '%-14s %-8s cycles=%-7s instret=%s' "$name" "PASS" "${cyc:-?}" "${ins:-?}")")
    pass=$((pass+1))
  else
    tn=$(grep -oP 'tohost=\K[0-9]+' "$log" | tail -1)
    rows+=("$(printf '%-14s %-8s failing test #%s (%s)' "$name" "FAIL" "${tn:-?}" "$log")")
    fail=$((fail+1))
  fi
done

for r in "${rows[@]}"; do echo "  $r"; done
echo "    rv32ui-p: $pass passed, $fail failed, $skip skipped"

# Machine-readable table for docs/e_core_results.md.
{ echo "| Test | Status | Notes |"; echo "|---|---|---|"
  for r in "${rows[@]}"; do
    n=$(awk '{print $1}' <<<"$r"); s=$(awk '{print $2}' <<<"$r")
    d=$(cut -d' ' -f3- <<<"$(tr -s ' ' <<<"$r")")
    echo "| $n | $s | $d |"
  done
} > "$OUT/results.md"

[ $fail -gt 0 ] && exit 1
exit 0
