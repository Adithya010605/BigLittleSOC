#!/usr/bin/env bash
# Benchmarks, and the E-core / P-core comparison.
#
# Builds Dhrystone 2.1 from the unmodified riscv-tests sources for each core
# (RV32I for the E-core, RV32IM for the P-core), runs it, and checks its final
# values; then collects the C test programs' cycle counts from both cores.
# Everything is reported from the cores' own counters, at zero wait states,
# and written as a markdown table to build/bench/comparison.md.
#
#   run_bench.sh           both cores
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
THIRD=${THIRD:-$ROOT/third_party}
OUT="$BUILD/bench"
mkdir -p "$OUT"

# shellcheck source=scripts/toolchain.sh
. "$ROOT/scripts/toolchain.sh"

DHRY_UP="$THIRD/riscv-tests/benchmarks/dhrystone"
DHRY_LOCAL="$ROOT/sw/bench/dhrystone"
LDS="$ROOT/sw/common/linker.ld"
COMMON_SRC=("$ROOT/sw/common/start.S" "$ROOT/sw/common/crt0.c" "$ROOT/sw/common/uart.c")

[ -f "$DHRY_UP/dhrystone.c" ] || { echo "==> bench: riscv-tests not checked out (make riscv-tests-fetch)"; exit 1; }

declare -A R   # R[core.key] = value
rc=0

for core in e_core p_core; do
  CORE=$core
  # shellcheck source=scripts/core_config.sh
  . "$ROOT/scripts/core_config.sh"
  "$ROOT/scripts/build_core.sh" || exit 1

  od="$OUT/$core"
  mkdir -p "$od"
  defs=()
  [ "$core" = p_core ] && defs+=(-DBENCH_P_CORE)
  # Upstream code is K&R-era C, which C23 (GCC's default since 15) rejects.
  # It alone is compiled as gnu89, its native dialect, and with -w: its
  # warnings are not ours to fix.
  ok=1
  "$RVCC" $RVCFLAGS -std=gnu89 -w -Dmain=dhrystone_main -I"$DHRY_LOCAL" -I"$DHRY_UP" \
      -c "$DHRY_UP/dhrystone_main.c" -o "$od/dhrystone_main.o" > "$od/build.log" 2>&1 || ok=0
  "$RVCC" $RVCFLAGS -std=gnu89 -w -I"$DHRY_LOCAL" -I"$DHRY_UP" \
      -c "$DHRY_UP/dhrystone.c" -o "$od/dhrystone.o" >> "$od/build.log" 2>&1 || ok=0
  "$RVCC" $RVCFLAGS "${defs[@]}" -I"$DHRY_LOCAL" -I"$ROOT/sw/common" -T "$LDS" \
      -o "$od/dhrystone.elf" "$DHRY_LOCAL/bench_dhrystone.c" "$DHRY_LOCAL/support.c" \
      "$od/dhrystone_main.o" "$od/dhrystone.o" "${COMMON_SRC[@]}" ${RVLIBS:--lgcc} \
      >> "$od/build.log" 2>&1 || ok=0
  if [ $ok -eq 0 ]; then
    echo "==> bench ($core): Dhrystone BUILD FAILED"; sed 's/^/     /' "$od/build.log" | head -30
    exit 1
  fi

  log="$od/dhrystone.log"
  if ! "$CORE_SIM" --elf "$od/dhrystone.elf" --waits=0 --max-cycles=50000000 \
       --uart-out="$od/dhrystone.uart" > "$log" 2>&1; then
    echo "==> bench ($core): Dhrystone FAILED"; tail -30 "$log" | sed 's/^/     /'
    rc=1; continue
  fi
  echo "==> bench ($core): Dhrystone passed, final values verified"
  sed 's/^/     /' "$od/dhrystone.uart"
  for k in cycles instret stalls branches taken mispredicts md_busy interlock CPI DMIPS_per_MHz cycles_per_run; do
    R[$core.$k]=$(grep -oP "^$k=\K\S+" "$od/dhrystone.uart")
  done

  # The C test programs, already built by 'make sw-tests' for this core.
  for src in "$ROOT"/sw/tests/*.c; do
    n=$(basename "$src" .c)
    elf="$CORE_OUT/sw/$n.elf"
    [ -f "$elf" ] || continue
    l=$("$CORE_SIM" --elf "$elf" --waits=0 --max-cycles=20000000 2>/dev/null | tail -1)
    R[$core.sw.$n]=$(grep -oP 'cycles=\K[0-9]+' <<<"$l")
    R[$core.swi.$n]=$(grep -oP 'instret=\K[0-9]+' <<<"$l")
  done
done
[ $rc -ne 0 ] && exit $rc

ratio() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b>0) printf "%.2f", a/b; else printf "-" }'; }

{
  echo "## Dhrystone 2.1, 500 runs, zero wait states"
  echo
  echo "| Metric | E-core (RV32I, 3-stage) | P-core (RV32IM, 5-stage) |"
  echo "|---|---|---|"
  for k in cycles instret CPI cycles_per_run DMIPS_per_MHz stalls branches taken mispredicts md_busy interlock; do
    echo "| $k | ${R[e_core.$k]} | ${R[p_core.$k]} |"
  done
  echo
  echo "Speed-up (E-core cycles / P-core cycles): **$(ratio "${R[e_core.cycles]}" "${R[p_core.cycles]}")x**"
  echo
  echo "## C test programs, whole-program cycles, zero wait states"
  echo
  echo "| Program | E-core cycles | E-core instret | P-core cycles | P-core instret | Speed-up |"
  echo "|---|---|---|---|---|---|"
  for src in "$ROOT"/sw/tests/*.c; do
    n=$(basename "$src" .c)
    [ -n "${R[e_core.sw.$n]:-}" ] && [ -n "${R[p_core.sw.$n]:-}" ] || continue
    echo "| $n | ${R[e_core.sw.$n]} | ${R[e_core.swi.$n]} | ${R[p_core.sw.$n]} | ${R[p_core.swi.$n]} | $(ratio "${R[e_core.sw.$n]}" "${R[p_core.sw.$n]}")x |"
  done
} > "$OUT/comparison.md"

echo
cat "$OUT/comparison.md"
exit 0
