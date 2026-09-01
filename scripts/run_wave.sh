#!/usr/bin/env bash
# Rerun a single test with waveform tracing enabled.
#   run_wave.sh <name>
# <name> is looked up in build/asm, build/sw, build/riscv-tests and build/random.
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
NAME=${1:?usage: run_wave.sh <test-name>}
SIM="$BUILD/e_core_sim_trace"

"$ROOT/scripts/build_core.sh" --trace || exit 1
[ -x "$SIM" ] || { echo "tracing simulator not built"; exit 1; }

ELF=""
for d in asm sw riscv-tests random; do
  for cand in "$BUILD/$d/$NAME.elf" "$BUILD/$d/rv32ui-p-$NAME.elf"; do
    [ -f "$cand" ] && { ELF="$cand"; break 2; }
  done
done
if [ -z "$ELF" ]; then
  echo "no ELF found for '$NAME'. Build the suite first (make asm-tests / sw-tests / riscv-tests)." >&2
  exit 1
fi

VCD="$BUILD/$NAME.vcd"
echo "==> tracing $ELF -> $VCD"
"$SIM" --elf "$ELF" --waits="${WAITS:-0}" --trace="$VCD" \
       --log="$BUILD/$NAME.trace.log" --max-cycles="${MAX_CYCLES:-1000000}"
rc=$?
echo "   VCD:   $VCD"
echo "   trace: $BUILD/$NAME.trace.log"
echo "   view:  gtkwave $VCD"
exit $rc
