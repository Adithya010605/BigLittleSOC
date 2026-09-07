#!/usr/bin/env bash
# Randomised lockstep regression: generate constrained-random RV32I programs,
# run them on the RTL and on the golden ISS, and compare retirement streams.
#
#   run_random.sh [n_programs] [n_seeds]
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
SIM="$BUILD/e_core_sim"
OUT="$BUILD/random"
PYTHON=${PYTHON:-python3}
mkdir -p "$OUT"

NPROG=${1:-${RANDOM_NPROG:-200}}
NSEED=${2:-${RANDOM_NSEED:-3}}

RVCC=${RVCC:-riscv64-unknown-elf-gcc}
RVCFLAGS=${RVCFLAGS:--march=rv32i_zicsr -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding}
LDS="$ROOT/sw/common/linker.ld"
GEN="$ROOT/scripts/gen_random_prog.py"

[ -f "$GEN" ] || { echo "==> random: generator not present yet"; exit 0; }
"$ROOT/scripts/build_core.sh" || exit 1
if [ ! -x "$SIM" ]; then echo "==> random: simulator not built yet"; exit 0; fi
command -v "$RVCC" >/dev/null 2>&1 || { echo "==> random: no RISC-V compiler ($RVCC)"; exit 1; }

pass=0; fail=0; failed=()
printf "==> randomised lockstep: %d programs x %d seeds x {0, random} waits\n" "$NPROG" "$NSEED"
for seed_base in $(seq 1 "$NSEED"); do
  for i in $(seq 1 "$NPROG"); do
    seed=$(( seed_base * 100000 + i ))
    name="rnd_${seed}"
    asm="$OUT/$name.S"
    elf="$OUT/$name.elf"
    "$PYTHON" "$GEN" --seed "$seed" --out "$asm" || { fail=$((fail+1)); failed+=("$name:gen"); continue; }
    if ! "$RVCC" $RVCFLAGS -T "$LDS" -o "$elf" "$asm" > "$OUT/$name.build.log" 2>&1; then
      printf "  %-14s \033[31mASM FAIL\033[0m\n" "$name"
      head -15 "$OUT/$name.build.log" | sed 's/^/      /'
      fail=$((fail+1)); failed+=("$name:asm"); continue
    fi
    ok=1
    for waits in "0" "random:$seed"; do
      log="$OUT/$name.w${waits//:/_}.log"
      if ! "$SIM" --elf "$elf" --waits="$waits" --lockstep --max-cycles=2000000 \
           > "$log" 2>&1; then
        printf "  %-14s \033[31mLOCKSTEP FAIL\033[0m (waits=%s)\n" "$name" "$waits"
        tail -40 "$log" | sed 's/^/      /'
        ok=0; break
      fi
    done
    if [ $ok -eq 1 ]; then
      pass=$((pass+1))
      rm -f "$OUT/$name."*.log "$OUT/$name.build.log"
    else
      fail=$((fail+1)); failed+=("$name")
      [ ${#failed[@]} -ge 5 ] && { echo "    too many failures, stopping early"; break 3; }
    fi
  done
  printf "  seed group %d done (%d passed so far)\n" "$seed_base" "$pass"
done

echo "    random: $pass passed, $fail failed"
[ $fail -gt 0 ] && { echo "    failing: ${failed[*]}"; exit 1; }
exit 0
