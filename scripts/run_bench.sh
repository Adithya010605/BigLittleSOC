#!/usr/bin/env bash
# The E-core / P-core performance comparison.
#
# Runs every C test program on both cores (each built for its own ISA:
# RV32I for the E-core, RV32IM for the P-core, by 'make sw-tests') and
# compares cycles, retired instructions and CPI. Everything is reported from
# the cores' own counters, at zero wait states, and written as a markdown
# table to build/bench/comparison.md.
#
#   run_bench.sh           both cores
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
OUT="$BUILD/bench"
mkdir -p "$OUT"

declare -A R   # R[core.kind.program] = value

for core in e_core p_core; do
  CORE=$core
  # shellcheck source=scripts/core_config.sh
  . "$ROOT/scripts/core_config.sh"
  "$ROOT/scripts/build_core.sh" || exit 1

  # The C test programs, already built by 'make sw-tests' for this core.
  for src in "$ROOT"/sw/tests/*.c; do
    n=$(basename "$src" .c)
    elf="$CORE_OUT/sw/$n.elf"
    if [ ! -f "$elf" ]; then
      echo "==> bench ($core): $n not built; run 'make CORE=$core sw-tests' first"
      exit 1
    fi
    l=$("$CORE_SIM" --elf "$elf" --waits=0 --max-cycles=20000000 2>/dev/null | tail -1)
    case "$l" in
      *PASS*) ;;
      *) echo "==> bench ($core): $n FAILED: $l"; exit 1 ;;
    esac
    R[$core.cyc.$n]=$(grep -oP 'cycles=\K[0-9]+' <<<"$l")
    R[$core.ins.$n]=$(grep -oP 'instret=\K[0-9]+' <<<"$l")
  done
  echo "==> bench ($core): all C programs passed"
done

ratio() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b>0) printf "%.2f", a/b; else printf "-" }'; }
cpi()   { awk -v c="$1" -v i="$2" 'BEGIN{ if (i>0) printf "%.3f", c/i; else printf "-" }'; }

{
  echo "## E-core vs P-core: C programs, whole-program cycles, zero wait states"
  echo
  echo "| Program | E-core cycles | E-core instret | E-core CPI | P-core cycles | P-core instret | P-core CPI | Speed-up |"
  echo "|---|---:|---:|---:|---:|---:|---:|---:|"
  ec=0; ei=0; pc=0; pi=0
  for src in "$ROOT"/sw/tests/*.c; do
    n=$(basename "$src" .c)
    e=${R[e_core.cyc.$n]}; eI=${R[e_core.ins.$n]}
    p=${R[p_core.cyc.$n]}; pI=${R[p_core.ins.$n]}
    ec=$((ec + e)); ei=$((ei + eI)); pc=$((pc + p)); pi=$((pi + pI))
    echo "| $n | $e | $eI | $(cpi "$e" "$eI") | $p | $pI | $(cpi "$p" "$pI") | $(ratio "$e" "$p")x |"
  done
  echo "| **total** | **$ec** | **$ei** | **$(cpi "$ec" "$ei")** | **$pc** | **$pi** | **$(cpi "$pc" "$pi")** | **$(ratio "$ec" "$pc")x** |"
  echo
  echo "Speed-up = E-core cycles / P-core cycles (above 1.00x: the P-core is faster)."
} > "$OUT/comparison.md"

echo
cat "$OUT/comparison.md"
exit 0
