#!/usr/bin/env bash
# Build the integration-level Verilator simulator (tb/integration/tb_e_core.cpp
# driving rtl/e_core/e_core_top.sv). Produces build/e_core_sim.
#
#   build_core.sh [--trace] [--coverage]
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
VERILATOR=${VERILATOR:-verilator}

TRACE=0; COV=0; SUFFIX=""
for a in "$@"; do
  case "$a" in
    --trace)    TRACE=1; SUFFIX="_trace" ;;
    --coverage) COV=1;   SUFFIX="_cov" ;;
    *) echo "build_core.sh: unknown option $a" >&2; exit 2 ;;
  esac
done

TOP="$ROOT/rtl/e_core/e_core_top.sv"
if [ ! -f "$TOP" ]; then
  echo "==> e_core: rtl/e_core/e_core_top.sv not present yet"
  exit 0
fi

# The package must be compiled first: every other file references its types,
# and `ls` would sort the names rather than preserve this order.
shopt -s nullglob
PKG="$ROOT/rtl/common/e_core_pkg.sv"
RTL=("$PKG")
for f in "$ROOT"/rtl/common/*.sv "$ROOT"/rtl/e_core/*.sv; do
  [ "$f" = "$PKG" ] && continue
  RTL+=("$f")
done
TBSRC=("$ROOT"/tb/integration/*.cpp)
if [ ${#TBSRC[@]} -eq 0 ]; then
  echo "==> e_core: no integration testbench sources yet"
  exit 0
fi

OBJDIR="$BUILD/obj_core$SUFFIX"
BIN="e_core_sim$SUFFIX"
EXTRA=()
[ $TRACE -eq 1 ] && EXTRA+=(--trace --trace-structs --trace-depth 8)
[ $COV   -eq 1 ] && EXTRA+=(--coverage)

mkdir -p "$BUILD"
echo "==> building $BIN"
"$VERILATOR" --cc --exe --build -j 0 -Wall \
  -I"$ROOT/rtl/common" -I"$ROOT/rtl/e_core" \
  --Mdir "$OBJDIR" --top-module e_core_top \
  --x-assign unique --x-initial unique \
  -GRVFI=1 \
  -CFLAGS "-std=c++17 -O2 -Wall -I$ROOT/tb/integration" \
  "${EXTRA[@]}" \
  -o "$BUILD/$BIN" \
  "${RTL[@]}" "${TBSRC[@]}" > "$BUILD/build_core$SUFFIX.log" 2>&1 || {
    echo "   BUILD FAILED — see $BUILD/build_core$SUFFIX.log"
    tail -40 "$BUILD/build_core$SUFFIX.log" | sed 's/^/     /'
    exit 1
  }
echo "   -> $BUILD/$BIN"
