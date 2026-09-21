#!/usr/bin/env bash
# Build and run every unit testbench.
#
# Convention: tb/unit/tb_<module>.cpp is the harness for rtl/common/<module>.sv.
# Each harness is Verilated with --top-module <module>, linked, and run; a zero
# exit status means pass. The package file is always compiled in.
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
VERILATOR=${VERILATOR:-verilator}
RTL_PKG=${RTL_PKG:-$ROOT/rtl/common/e_core_pkg.sv}

UNIT_DIR="$ROOT/tb/unit"
OUT="$BUILD/unit"
mkdir -p "$OUT"

shopt -s nullglob
HARNESSES=("$UNIT_DIR"/tb_*.cpp)
if [ ${#HARNESSES[@]} -eq 0 ]; then
  echo "==> unit: no unit testbenches present yet"
  exit 0
fi

pass=0; fail=0; failed_names=()
printf "==> unit tests\n"
for cpp in "${HARNESSES[@]}"; do
  base=$(basename "$cpp" .cpp)      # tb_alu
  mod=${base#tb_}                   # alu
  rtl="$ROOT/rtl/common/$mod.sv"
  if [ ! -f "$rtl" ]; then
    printf "  %-14s %s\n" "$mod" "SKIP (no rtl/common/$mod.sv)"
    continue
  fi

  objdir="$OUT/obj_$mod"
  log="$OUT/$mod.log"
  # -Wno-UNUSEDPARAM: a single module legitimately consumes only part of the
  # shared package. The whole-design lint gate is 'make lint' (scripts/lint.sh),
  # which compiles every file together and allows no waivers at all.
  if ! "$VERILATOR" --cc --exe --build -j 0 -Wall -Wno-UNUSEDPARAM \
        -I"$ROOT/rtl/common" \
        --Mdir "$objdir" --top-module "$mod" \
        -CFLAGS "-std=c++17 -O2 -Wall -I$ROOT/tb/unit" \
        -o "$OUT/$mod" \
        "$RTL_PKG" "$rtl" "$cpp" > "$log" 2>&1; then
    printf "  %-14s \033[31mBUILD FAIL\033[0m  (see %s)\n" "$mod" "$log"
    tail -25 "$log" | sed 's/^/      /'
    fail=$((fail+1)); failed_names+=("$mod:build"); continue
  fi

  if "$OUT/$mod" >> "$log" 2>&1; then
    n=$(grep -c '^\[PASS\]' "$log" || true)
    printf "  %-14s \033[32mPASS\033[0m  (%s checks)\n" "$mod" "${n:-0}"
    pass=$((pass+1))
  else
    printf "  %-14s \033[31mFAIL\033[0m  (see %s)\n" "$mod" "$log"
    grep -E '^\[FAIL\]|Assertion|ERROR' "$log" | head -20 | sed 's/^/      /'
    fail=$((fail+1)); failed_names+=("$mod")
  fi
done

echo "    unit: $pass passed, $fail failed"
if [ $fail -gt 0 ]; then
  echo "    failing: ${failed_names[*]}"
  exit 1
fi
exit 0
