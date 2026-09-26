#!/usr/bin/env bash
# Build and run every unit testbench.
#
# Convention: tb/unit/tb_<module>.cpp is the harness for rtl/common/<module>.sv,
# and tb/unit/p_core/tb_<module>.cpp the harness for rtl/p_core/<module>.sv.
# Each harness is Verilated with --top-module <module>, linked, and run; a zero
# exit status means pass. The shared package is always compiled in, and the
# P-core package too for a P-core module.
#
# A harness may override the convention with directive lines of its own, which
# is how one module is checked under a second set of parameters:
#   // UNIT-TOP: <module>          the module under test, if not tb_<module>
#   // UNIT-VFLAGS: <flags>        extra Verilator flags, e.g. -GRV32M=1
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
VERILATOR=${VERILATOR:-verilator}
RTL_PKG=${RTL_PKG:-$ROOT/rtl/common/e_core_pkg.sv}
P_PKG="$ROOT/rtl/p_core/p_core_pkg.sv"

UNIT_DIR="$ROOT/tb/unit"
OUT="$BUILD/unit"
mkdir -p "$OUT"

shopt -s nullglob
HARNESSES=("$UNIT_DIR"/tb_*.cpp "$UNIT_DIR"/p_core/tb_*.cpp)
if [ ${#HARNESSES[@]} -eq 0 ]; then
  echo "==> unit: no unit testbenches present yet"
  exit 0
fi

pass=0; fail=0; failed_names=()
printf "==> unit tests\n"
for cpp in "${HARNESSES[@]}"; do
  base=$(basename "$cpp" .cpp)      # tb_alu
  name=${base#tb_}                  # alu, decoder_rv32m, ...
  mod=$(grep -m1 -oP '^// UNIT-TOP:\s*\K\S+' "$cpp" || true)
  [ -z "$mod" ] && mod=$name
  read -r -a vflags <<< "$(grep -m1 -oP '^// UNIT-VFLAGS:\s*\K.*' "$cpp" || true)"

  pkgs=("$RTL_PKG")
  if [ -f "$ROOT/rtl/common/$mod.sv" ]; then
    rtl="$ROOT/rtl/common/$mod.sv"
  elif [ -f "$ROOT/rtl/p_core/$mod.sv" ]; then
    rtl="$ROOT/rtl/p_core/$mod.sv"
    pkgs+=("$P_PKG")
  else
    printf "  %-24s %s\n" "$name" "SKIP (no rtl for module $mod)"
    continue
  fi

  objdir="$OUT/obj_$name"
  log="$OUT/$name.log"
  # -Wno-UNUSEDPARAM: a single module legitimately consumes only part of the
  # shared package. The whole-design lint gate is 'make lint' (scripts/lint.sh),
  # which compiles every file together and allows no waivers at all.
  if ! "$VERILATOR" --cc --exe --build -j 0 -Wall -Wno-UNUSEDPARAM \
        -I"$ROOT/rtl/common" -I"$ROOT/rtl/p_core" \
        --Mdir "$objdir" --top-module "$mod" "${vflags[@]}" \
        -CFLAGS "-std=c++17 -O2 -Wall -I$ROOT/tb/unit" \
        -o "$OUT/$name" \
        "${pkgs[@]}" "$rtl" "$cpp" > "$log" 2>&1; then
    printf "  %-24s \033[31mBUILD FAIL\033[0m  (see %s)\n" "$name" "$log"
    tail -25 "$log" | sed 's/^/      /'
    fail=$((fail+1)); failed_names+=("$name:build"); continue
  fi

  if "$OUT/$name" >> "$log" 2>&1; then
    n=$(grep -c '^\[PASS\]' "$log" || true)
    printf "  %-24s \033[32mPASS\033[0m  (%s checks)\n" "$name" "${n:-0}"
    pass=$((pass+1))
  else
    printf "  %-24s \033[31mFAIL\033[0m  (see %s)\n" "$name" "$log"
    grep -E '^\[FAIL\]|Assertion|ERROR' "$log" | head -20 | sed 's/^/      /'
    fail=$((fail+1)); failed_names+=("$name")
  fi
done

echo "    unit: $pass passed, $fail failed"
if [ $fail -gt 0 ]; then
  echo "    failing: ${failed_names[*]}"
  exit 1
fi
exit 0
