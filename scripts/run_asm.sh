#!/usr/bin/env bash
# Assemble, link and run every directed assembly test in tb/asm/.
# Each test is self-checking: it stores 1 to `tohost` on pass, or (code<<1)|1
# with code != 0 on failure. The simulator turns that into an exit status.
#
# Every test is run at 0 wait states and at randomised wait states.
#
# The tests in tb/asm/ run on both cores; those in tb/asm/<core>/ only on that
# one. A shared test that checks something only one core's ISA allows (that
# MUL traps, say) wraps it in #ifndef CORE_HAS_M.
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}

# shellcheck source=scripts/toolchain.sh
. "$ROOT/scripts/toolchain.sh"
# shellcheck source=scripts/core_config.sh
. "$ROOT/scripts/core_config.sh"
SIM="$CORE_SIM"
OUT="$CORE_OUT/asm"
mkdir -p "$OUT"

LDS="$ROOT/sw/common/linker.ld"

shopt -s nullglob
TESTS=("$ROOT"/tb/asm/*.S "$ROOT"/tb/asm/"$CORE"/*.S)
if [ ${#TESTS[@]} -eq 0 ]; then echo "==> asm: no tests present yet"; exit 0; fi

"$ROOT/scripts/build_core.sh" || exit 1
if [ ! -x "$SIM" ]; then echo "==> asm: simulator not built yet"; exit 0; fi
command -v "$RVCC" >/dev/null 2>&1 || { echo "==> asm: no RISC-V compiler ($RVCC)"; exit 1; }

pass=0; fail=0; failed=()
printf "==> directed assembly tests (%s)\n" "$CORE"
for src in "${TESTS[@]}"; do
  name=$(basename "$src" .S)
  elf="$OUT/$name.elf"
  if ! "$RVCC" $RVCFLAGS $CORE_ASM_DEFS -I"$ROOT/tb/asm" -T "$LDS" -o "$elf" "$src" ${RVLIBS:--lgcc} \
        > "$OUT/$name.build.log" 2>&1; then
    printf "  %-28s \033[31mASM FAIL\033[0m\n" "$name"
    sed 's/^/      /' "$OUT/$name.build.log" | head -15
    fail=$((fail+1)); failed+=("$name:asm"); continue
  fi
  "$ROOT/scripts/gen_hex.sh" "$elf" "$OUT/$name" >/dev/null 2>&1

  # Every directed test runs at zero, fixed and randomised latency. Several
  # defects are invisible at zero wait states because the situation they break
  # never arises -- a mishandled wrong-path fetch, a stall term that ignores
  # ex_ready, a skid buffer that drops an instruction -- so the fixed and
  # random configurations are part of the pass criterion, not an extra.
  ok=1
  # The last configuration is fast fetch with slow data ("0/d3"), which packs
  # instructions tightly behind a stalled load or store -- the case that
  # needs the P-core's operand refresh and result hold.
  for waits in "0" "2" "random:1" "random:7" "0/d3"; do
    dflag=()
    w=$waits
    if [[ "$waits" == */d* ]]; then w=${waits%%/d*}; dflag=(--dwaits="${waits##*/d}"); fi
    log="$OUT/$name.w${waits//[:\/]/_}.log"
    if ! "$SIM" --elf "$elf" --waits="$w" "${dflag[@]}" --max-cycles=1000000 > "$log" 2>&1; then
      printf "  %-28s \033[31mFAIL\033[0m (waits=%s)\n" "$name" "$waits"
      tail -30 "$log" | sed 's/^/      /'
      ok=0; break
    fi
  done
  if [ $ok -eq 1 ]; then
    cyc=$(grep -oP 'cycles=\K[0-9]+' "$OUT/$name.w0.log" | tail -1)
    ins=$(grep -oP 'instret=\K[0-9]+' "$OUT/$name.w0.log" | tail -1)
    printf "  %-28s \033[32mPASS\033[0m  cycles=%-8s instret=%-8s\n" "$name" "${cyc:-?}" "${ins:-?}"
    pass=$((pass+1))
  else
    fail=$((fail+1)); failed+=("$name")
  fi
done

echo "    asm: $pass passed, $fail failed"
[ $fail -gt 0 ] && { echo "    failing: ${failed[*]}"; exit 1; }
exit 0
