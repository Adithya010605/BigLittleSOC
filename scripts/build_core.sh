#!/usr/bin/env bash
# Build the integration-level Verilator simulator for the core selected by
# CORE (see core_config.sh): tb/integration/tb_core.cpp driving e_core_top or
# p_core_top. Produces build/<core>_sim.
#
#   build_core.sh [--trace] [--coverage]
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
VERILATOR=${VERILATOR:-verilator}
# shellcheck source=scripts/core_config.sh
. "$ROOT/scripts/core_config.sh"

TRACE=0; COV=0; SUFFIX=""
for a in "$@"; do
  case "$a" in
    --trace)    TRACE=1; SUFFIX="_trace" ;;
    --coverage) COV=1;   SUFFIX="_cov" ;;
    *) echo "build_core.sh: unknown option $a" >&2; exit 2 ;;
  esac
done

mapfile -t RTL < <(core_rtl_files)
shopt -s nullglob
TBSRC=("$ROOT"/tb/integration/*.cpp)

# The E-core keeps its historical object-directory names.
if [ "$CORE" = e_core ]; then OBJDIR="$BUILD/obj_core$SUFFIX"; else OBJDIR="$BUILD/obj_${CORE}$SUFFIX"; fi
BIN="${CORE}_sim$SUFFIX"
LOG="$BUILD/build_${CORE}$SUFFIX.log"
EXTRA=()
[ $TRACE -eq 1 ] && EXTRA+=(--trace --trace-structs --trace-depth 8)
[ $COV   -eq 1 ] && EXTRA+=(--coverage)
# The P-core carries simulation assertions (p_core_top.sv); --assert makes a
# failing one stop the run.
[ "$CORE" = p_core ] && EXTRA+=(--assert)

mkdir -p "$BUILD"
echo "==> building $BIN"
"$VERILATOR" --cc --exe --build -j 0 -Wall \
  "${CORE_INC[@]}" \
  --Mdir "$OBJDIR" --top-module "$CORE_TOP" \
  --x-assign unique --x-initial unique \
  -GRVFI=1 \
  -CFLAGS "-std=c++17 -O2 -Wall -I$ROOT/tb/integration $CORE_CFLAGS" \
  "${EXTRA[@]}" \
  -o "$BUILD/$BIN" \
  "${RTL[@]}" "${TBSRC[@]}" > "$LOG" 2>&1 || {
    echo "   BUILD FAILED — see $LOG"
    tail -40 "$LOG" | sed 's/^/     /'
    exit 1
  }
echo "   -> $BUILD/$BIN"
