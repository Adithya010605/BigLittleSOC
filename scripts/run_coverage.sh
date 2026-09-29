#!/usr/bin/env bash
# Coverage build + report. Runs the directed asm suite and the C tests under a
# --coverage build, merges the .dat files and reports line/toggle percentages
# for the core's RTL: rtl/common and rtl/e_core for the E-core; rtl/common,
# rtl/p_core and the shared trap unit for the P-core.
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
# shellcheck source=scripts/core_config.sh
. "$ROOT/scripts/core_config.sh"
OUT="$CORE_OUT/coverage"
SIM="${CORE_SIM}_cov"
if [ "$CORE" = p_core ]; then
  COV_DIRS="rtl/common,rtl/p_core+rtl/e_core/e_core_trap.sv"
else
  COV_DIRS="rtl/common,rtl/e_core"
fi
mkdir -p "$OUT"
rm -f "$OUT"/*.dat

"$ROOT/scripts/build_core.sh" --coverage || exit 1
[ -x "$SIM" ] || { echo "==> coverage: coverage simulator not built yet"; exit 0; }

# The randomised programs matter here more than anything else: they are what
# drives the arithmetic datapath through operand values the directed tests
# never produce, and toggle coverage on a 32-bit datapath is otherwise
# dominated by bits that only a wide value range exercises. A capped number of
# them keeps the replay to a sensible runtime.
RANDOM_CAP=${COVERAGE_RANDOM_CAP:-120}
shopt -s nullglob
RAND_ELFS=("$CORE_OUT/random"/*.elf)
if [ ${#RAND_ELFS[@]} -gt "$RANDOM_CAP" ]; then
  RAND_ELFS=("${RAND_ELFS[@]:0:$RANDOM_CAP}")
fi
ELFS=("$CORE_OUT/asm"/*.elf "$CORE_OUT/sw"/*.elf "$CORE_OUT/riscv-tests"/*.elf "${RAND_ELFS[@]}")
if [ ${#ELFS[@]} -eq 0 ]; then
  echo "==> coverage: no test ELFs built yet — run 'make asm-tests sw-tests riscv-tests' first"
  exit 0
fi

echo "==> coverage: replaying ${#ELFS[@]} programs"
n=0
for elf in "${ELFS[@]}"; do
  n=$((n+1))
  # Alternate the latency configuration so the back-pressure paths -- the
  # skid buffer, the wrong-path discard, the multi-cycle memory handshake --
  # are covered too. At zero wait states several of them never activate.
  if [ $((n % 3)) -eq 0 ]; then w="random:$n"; else w=0; fi
  "$SIM" --elf "$elf" --waits="$w" --max-cycles=20000000 \
         --coverage-out="$OUT/cov_$n.dat" > /dev/null 2>&1 || true
done

if ! command -v verilator_coverage >/dev/null 2>&1; then
  echo "verilator_coverage not found" >&2; exit 1
fi
verilator_coverage --write "$OUT/merged.dat" "$OUT"/cov_*.dat > /dev/null
verilator_coverage --annotate "$OUT/annotated" --annotate-all --annotate-min 1 \
                   "$OUT/merged.dat" > "$OUT/report.txt" 2>&1

"$ROOT/scripts/cov_summary.py" "$OUT/merged.dat" "$COV_DIRS" | tee "$OUT/summary.txt"
