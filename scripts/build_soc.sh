#!/usr/bin/env bash
# Build a Verilator simulator of rtl/soc/soc_top.sv driven by
# tb/soc/tb_soc.cpp.
#
#   build_soc.sh NUM_P NUM_E NAME [--trace] [--coverage]
#
# produces build/NAME. NUM_P P-cores (harts 0..NUM_P-1) and NUM_E E-cores
# follow them. The SoC is always built with RVFI on (the harness reads every
# core's retirement trace) and with --assert, so the cores' and the coherence
# system's simulation assertions stop the run.
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
VERILATOR=${VERILATOR:-verilator}
# shellcheck source=scripts/core_config.sh
. "$ROOT/scripts/core_config.sh"

if [ $# -lt 3 ]; then echo "usage: build_soc.sh NUM_P NUM_E NAME [--trace] [--coverage]" >&2; exit 2; fi
NP=$1; NE=$2; NAME=$3; shift 3
SUFFIX=""
# SOC_VFLAGS: extra Verilator flags. The mutation script passes -Wno-fatal,
# because a mutation often leaves a signal unused, which -Wall rejects.
read -r -a EXTRA <<< "${SOC_VFLAGS:-}"
for a in "$@"; do
  case "$a" in
    --trace)    SUFFIX="_trace"; EXTRA+=(--trace --trace-structs --trace-depth 8) ;;
    --coverage) SUFFIX="_cov";   EXTRA+=(--coverage) ;;
    *) echo "build_soc.sh: unknown option $a" >&2; exit 2 ;;
  esac
done

# SOC_RTL_ROOT lets the mutation script build from a mutated copy of rtl/.
mapfile -t RTL < <(soc_rtl_files "${SOC_RTL_ROOT:-$ROOT/rtl}")
TBSRC=("$ROOT"/tb/integration/elf_loader.cpp "$ROOT"/tb/integration/golden_iss.cpp
       "$ROOT"/tb/integration/disasm.cpp "$ROOT"/tb/integration/memory_model.cpp
       "$ROOT"/tb/soc/*.cpp)
OBJDIR="$BUILD/obj_${NAME}${SUFFIX}"
BIN="$BUILD/${NAME}${SUFFIX}"
LOG="$BUILD/build_${NAME}${SUFFIX}.log"

# Skip the (slow) Verilator run when nothing it depends on has changed.
if [ -x "$BIN" ] && [ -z "$(find "${RTL[@]}" "${TBSRC[@]}" "$ROOT"/tb/soc/*.h "$ROOT"/tb/integration/*.h \
                              "$0" -newer "$BIN" 2>/dev/null | head -1)" ]; then
  echo "==> $NAME${SUFFIX} up to date"
  exit 0
fi

mkdir -p "$BUILD"
echo "==> building ${NAME}${SUFFIX} (${NP} P-core(s) + ${NE} E-core(s))"
"$VERILATOR" --cc --exe --build -j 0 -Wall --assert \
  "${CORE_INC[@]}" \
  --Mdir "$OBJDIR" --top-module soc_top \
  --x-assign unique --x-initial unique \
  -GNUM_P="$NP" -GNUM_E="$NE" -GRVFI=1 \
  -CFLAGS "-std=c++17 -O2 -Wall -I$ROOT/tb/integration -I$ROOT/tb/soc -DSOC_NUM_P=$NP -DSOC_NUM_E=$NE" \
  "${EXTRA[@]}" \
  -o "$BIN" \
  "${RTL[@]}" "${TBSRC[@]}" > "$LOG" 2>&1 || {
    echo "   BUILD FAILED — see $LOG"
    tail -40 "$LOG" | sed 's/^/     /'
    exit 1
  }
echo "   -> $BIN"
