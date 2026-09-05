#!/usr/bin/env bash
# Assemble, link and run every directed assembly test in tb/asm/.
# Each test is self-checking: it stores 1 to `tohost` on pass, or (code<<1)|1
# with code != 0 on failure. The simulator turns that into an exit status.
#
# Every test is run at 0 wait states and at randomised wait states.
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
SIM="$BUILD/e_core_sim"
OUT="$BUILD/asm"
mkdir -p "$OUT"

# shellcheck source=scripts/toolchain.sh
. "$ROOT/scripts/toolchain.sh"

LDS="$ROOT/sw/common/linker.ld"

shopt -s nullglob
TESTS=("$ROOT"/tb/asm/*.S)
if [ ${#TESTS[@]} -eq 0 ]; then echo "==> asm: no tests present yet"; exit 0; fi

"$ROOT/scripts/build_core.sh" || exit 1
if [ ! -x "$SIM" ]; then echo "==> asm: simulator not built yet"; exit 0; fi
command -v "$RVCC" >/dev/null 2>&1 || { echo "==> asm: no RISC-V compiler ($RVCC)"; exit 1; }

pass=0; fail=0; failed=()
printf "==> directed assembly tests\n"
for src in "${TESTS[@]}"; do
  name=$(basename "$src" .S)
  elf="$OUT/$name.elf"
  if ! "$RVCC" $RVCFLAGS -I"$ROOT/tb/asm" -T "$LDS" -o "$elf" "$src" ${RVLIBS:--lgcc} \
        > "$OUT/$name.build.log" 2>&1; then
    printf "  %-28s \033[31mASM FAIL\033[0m\n" "$name"
    sed 's/^/      /' "$OUT/$name.build.log" | head -15
    fail=$((fail+1)); failed+=("$name:asm"); continue
  fi
  "$ROOT/scripts/gen_hex.sh" "$elf" "$OUT/$name" >/dev/null 2>&1

  ok=1
  for waits in "0" "random:1"; do
    log="$OUT/$name.w${waits//:/_}.log"
    if ! "$SIM" --elf "$elf" --waits="$waits" --max-cycles=1000000 > "$log" 2>&1; then
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
