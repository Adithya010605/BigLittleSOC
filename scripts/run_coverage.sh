#!/usr/bin/env bash
# Coverage build + report. Runs the directed asm suite and the C tests under a
# --coverage build, merges the .dat files and reports line/toggle percentages
# for rtl/common and rtl/e_core.
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
OUT="$BUILD/coverage"
SIM="$BUILD/e_core_sim_cov"
mkdir -p "$OUT"
rm -f "$OUT"/*.dat

"$ROOT/scripts/build_core.sh" --coverage || exit 1
[ -x "$SIM" ] || { echo "==> coverage: coverage simulator not built yet"; exit 0; }

shopt -s nullglob
ELFS=("$BUILD/asm"/*.elf "$BUILD/sw"/*.elf "$BUILD/riscv-tests"/*.elf)
if [ ${#ELFS[@]} -eq 0 ]; then
  echo "==> coverage: no test ELFs built yet — run 'make asm-tests sw-tests riscv-tests' first"
  exit 0
fi

echo "==> coverage: replaying ${#ELFS[@]} programs"
n=0
for elf in "${ELFS[@]}"; do
  n=$((n+1))
  "$SIM" --elf "$elf" --waits=0 --max-cycles=20000000 \
         --coverage-out="$OUT/cov_$n.dat" > /dev/null 2>&1 || true
done

if ! command -v verilator_coverage >/dev/null 2>&1; then
  echo "verilator_coverage not found" >&2; exit 1
fi
verilator_coverage --write "$OUT/merged.dat" "$OUT"/cov_*.dat > /dev/null
verilator_coverage --annotate "$OUT/annotated" --annotate-all --annotate-min 1 \
                   "$OUT/merged.dat" > "$OUT/report.txt" 2>&1

"$ROOT/scripts/cov_summary.py" "$OUT/merged.dat" | tee "$OUT/summary.txt"
