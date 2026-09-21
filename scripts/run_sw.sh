#!/usr/bin/env bash
# Compile and run every C program in sw/tests/ against the core, checking
# both the exit code (via tohost) and the expected UART output where an
# .expected file exists alongside the source.
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
SIM="$BUILD/e_core_sim"
OUT="$BUILD/sw"
mkdir -p "$OUT"

# shellcheck source=scripts/toolchain.sh
. "$ROOT/scripts/toolchain.sh"

LDS="$ROOT/sw/common/linker.ld"
COMMON_SRC=("$ROOT"/sw/common/start.S "$ROOT"/sw/common/crt0.c "$ROOT"/sw/common/uart.c)

shopt -s nullglob
TESTS=("$ROOT"/sw/tests/*.c)
if [ ${#TESTS[@]} -eq 0 ]; then echo "==> sw: no C tests present yet"; exit 0; fi

"$ROOT/scripts/build_core.sh" || exit 1
if [ ! -x "$SIM" ]; then echo "==> sw: simulator not built yet"; exit 0; fi
command -v "$RVCC" >/dev/null 2>&1 || { echo "==> sw: no RISC-V compiler ($RVCC)"; exit 1; }

pass=0; fail=0; failed=()
printf "==> C software tests\n"
for src in "${TESTS[@]}"; do
  name=$(basename "$src" .c)
  elf="$OUT/$name.elf"
  if ! "$RVCC" $RVCFLAGS -I"$ROOT/sw/common" -T "$LDS" -o "$elf" \
        "$src" "${COMMON_SRC[@]}" ${RVLIBS:--lgcc} > "$OUT/$name.build.log" 2>&1; then
    printf "  %-20s \033[31mCC FAIL\033[0m\n" "$name"
    sed 's/^/      /' "$OUT/$name.build.log" | head -20
    fail=$((fail+1)); failed+=("$name:cc"); continue
  fi
  "$ROOT/scripts/gen_hex.sh" "$elf" "$OUT/$name" >/dev/null 2>&1

  log="$OUT/$name.log"
  if ! "$SIM" --elf "$elf" --waits=0 --max-cycles=20000000 \
       --uart-out="$OUT/$name.uart" > "$log" 2>&1; then
    printf "  %-20s \033[31mFAIL\033[0m\n" "$name"
    tail -30 "$log" | sed 's/^/      /'
    fail=$((fail+1)); failed+=("$name"); continue
  fi

  exp="$ROOT/sw/tests/$name.expected"
  if [ -f "$exp" ] && ! diff -u "$exp" "$OUT/$name.uart" > "$OUT/$name.diff" 2>&1; then
    printf "  %-20s \033[31mUART MISMATCH\033[0m\n" "$name"
    head -30 "$OUT/$name.diff" | sed 's/^/      /'
    fail=$((fail+1)); failed+=("$name:uart"); continue
  fi

  cyc=$(grep -oP 'cycles=\K[0-9]+' "$log" | tail -1)
  ins=$(grep -oP 'instret=\K[0-9]+' "$log" | tail -1)
  cpi=$(awk -v c="${cyc:-0}" -v i="${ins:-1}" 'BEGIN{if(i>0)printf "%.3f", c/i; else printf "-"}')
  printf "  %-20s \033[32mPASS\033[0m  cycles=%-9s instret=%-9s CPI=%s\n" "$name" "${cyc:-?}" "${ins:-?}" "$cpi"
  pass=$((pass+1))
done

echo "    sw: $pass passed, $fail failed"
[ $fail -gt 0 ] && { echo "    failing: ${failed[*]}"; exit 1; }
exit 0
