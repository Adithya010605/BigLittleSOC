#!/usr/bin/env bash
# Build and run the multi-core programs in sw/soc_tests/ on the big.LITTLE
# SoC (rtl/soc/soc_top.sv): SOC_NUM_P P-cores + SOC_NUM_E E-cores (default
# 2 + 2), every hart running the same image.
#
# Each program is self-checking (start_mc.S collects every hart's result),
# and the harness checks coherence on every load regardless (tb/soc/tb_soc.cpp).
# An .expected file next to a program is compared with its UART output.
# mc_stress*.c is built once per seed in SOC_STRESS_SEEDS, and once more
# with the clusters' clocks divided (DVFS).
#
# Every program runs at five latency settings -- zero, fixed, two random
# streams, and "fast fetch, slow data" (the single-core scripts' setting;
# here simply another SRAM latency) -- and once more with the interconnect's
# two traffic ports loading the SRAM with checked background traffic
# (random:3+t40: 40% of idle cycles start a traffic transaction).
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
# shellcheck source=scripts/toolchain.sh
. "$ROOT/scripts/toolchain.sh"

NP=${SOC_NUM_P:-2}
NE=${SOC_NUM_E:-2}
NH=$((NP + NE))
NAME="soc_${NP}p${NE}e_sim"
SIM="$BUILD/$NAME"
OUT="$BUILD/soc_${NP}p${NE}e"
SEEDS=${SOC_STRESS_SEEDS:-"1 2 3 4"}
WAITS_LIST=${SOC_WAITS:-"0 2 random:1 random:7 0/d3 random:3+t40"}
mkdir -p "$OUT"

"$ROOT/scripts/build_soc.sh" "$NP" "$NE" "$NAME" || exit 1
command -v "$RVCC" >/dev/null 2>&1 || { echo "==> soc: no RISC-V compiler ($RVCC)"; exit 1; }

# One image for every hart, so it must run on the smallest core: RV32I.
ARCH=rv32i_zicsr
CFLAGS="-march=$ARCH -mabi=ilp32 -mcmodel=medany -nostdlib -nostartfiles -ffreestanding \
        -fno-builtin -O2 -g -Wall -Wextra -fno-common -fomit-frame-pointer \
        -DNHARTS=$NH -DNUM_P=$NP -I$ROOT/sw/common"
COMMON=("$ROOT"/sw/common/start_mc.S "$ROOT"/sw/common/soc.c "$ROOT"/sw/common/crt0.c
        "$ROOT"/sw/common/uart.c)
LDS="$ROOT/sw/common/linker.ld"

# name|source|extra flags
JOBS=()
shopt -s nullglob
for src in "$ROOT"/sw/soc_tests/*.c; do
  base=$(basename "$src" .c)
  if [[ "$base" == mc_stress* ]]; then
    for s in $SEEDS; do JOBS+=("${base}_s$s|$src|-DSEED=$s"); done
    # and once with the P cluster at 1/2 speed, the E cluster at 1/4
    JOBS+=("${base}_dvfs|$src|-DSEED=5 -DSTRESS_DVFS=0x9")
  else
    JOBS+=("$base|$src|")
  fi
done

pass=0; fail=0; failed=()
printf "==> multi-core programs (%d P + %d E)\n" "$NP" "$NE"
for job in "${JOBS[@]}"; do
  IFS='|' read -r name src extra <<< "$job"
  base=$(basename "$src" .c)
  elf="$OUT/$name.elf"
  # A program may have an assembly part beside it: <name>.S.
  srcs=("$src")
  [ -f "${src%.c}.S" ] && srcs+=("${src%.c}.S")
  # shellcheck disable=SC2086
  if ! "$RVCC" $CFLAGS $extra -T "$LDS" -Wl,--build-id=none -o "$elf" "${srcs[@]}" "${COMMON[@]}" -lgcc \
        > "$OUT/$name.build.log" 2>&1; then
    printf "  %-26s \033[31mCC FAIL\033[0m\n" "$name"
    sed 's/^/      /' "$OUT/$name.build.log" | head -20
    fail=$((fail+1)); failed+=("$name:cc"); continue
  fi
  ok=1; first_log=""
  for waits in $WAITS_LIST; do
    dflag=(); w=$waits
    if [[ "$w" == *+t* ]]; then dflag+=(--traffic="${w##*+t}"); w=${w%%+t*}; fi
    if [[ "$w" == */d* ]]; then dflag+=(--dwaits="${w##*/d}"); w=${w%%/d*}; fi
    log="$OUT/$name.w${waits//[:\/+]/_}.log"
    [ -z "$first_log" ] && first_log=$log
    if ! "$SIM" --elf "$elf" --waits="$w" "${dflag[@]}" --max-cycles=${SOC_MAX_CYCLES:-8000000} \
         --stats --uart-out="$OUT/$name.uart" > "$log" 2>&1; then
      printf "  %-26s \033[31mFAIL\033[0m (waits=%s)\n" "$name" "$waits"
      grep -E 'COHERENCE|PROGRAM FAILED|TIMEOUT|HALTED|Assertion|%Error' "$log" | head -5 | sed 's/^/      /'
      ok=0; break
    fi
    exp="$ROOT/sw/soc_tests/$base.expected"
    if [ -f "$exp" ] && ! diff -u "$exp" "$OUT/$name.uart" > "$OUT/$name.diff" 2>&1; then
      printf "  %-26s \033[31mUART MISMATCH\033[0m (waits=%s)\n" "$name" "$waits"
      head -20 "$OUT/$name.diff" | sed 's/^/      /'
      ok=0; break
    fi
  done
  if [ $ok -eq 1 ]; then
    l0=$first_log
    cyc=$(grep -oP 'cycles=\K[0-9]+' "$l0" | tail -1)
    bus=$(grep -oP '^  bus: \K.*' "$l0" | tail -1)
    lds=$(grep -oP 'loads_checked=\K[0-9]+' "$l0" | tail -1)
    printf "  %-26s \033[32mPASS\033[0m  cycles=%-8s loads checked=%-7s %s\n" "$name" "${cyc:-?}" "${lds:-?}" "$bus"
    pass=$((pass+1))
  else
    fail=$((fail+1)); failed+=("$name")
  fi
done

echo "    soc: $pass passed, $fail failed"
[ $fail -gt 0 ] && { echo "    failing: ${failed[*]}"; exit 1; }
exit 0
