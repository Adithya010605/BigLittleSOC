#!/usr/bin/env bash
# Verilator lint over every RTL file that currently exists.
#
# The bar is: --lint-only -Wall, zero warnings, no -Wno-fatal escape hatch.
# When e_core_top.sv exists it is forced as the top module so that unconnected
# top-level ports are checked properly; before then the available modules are
# linted as-is, which is what makes the bar meaningful at every milestone
# rather than only at the end.
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
VERILATOR=${VERILATOR:-verilator}

PKG="$ROOT/rtl/common/e_core_pkg.sv"
shopt -s nullglob
COMMON=("$ROOT"/rtl/common/*.sv)
CORE=("$ROOT"/rtl/e_core/*.sv)

FILES=()
[ -f "$PKG" ] && FILES+=("$PKG")
for f in "${COMMON[@]}" "${CORE[@]}"; do
  [ "$f" = "$PKG" ] && continue
  FILES+=("$f")
done

if [ ${#FILES[@]} -eq 0 ]; then
  echo "==> lint: no RTL yet — nothing to lint"
  exit 0
fi

# With e_core_top present there is a single unambiguous top and no waiver of
# any kind is used. Before it exists, rtl/ is a library of independent modules,
# so Verilator legitimately reports MULTITOP; that one warning is suppressed
# rather than splitting the lint per file, because a combined pass is what
# makes UNUSEDPARAM meaningful across the shared package -- an unused package
# constant is invisible to a per-file lint.
TOPARG=()
if [ -f "$ROOT/rtl/e_core/e_core_top.sv" ]; then
  TOPARG=(--top-module e_core_top)
else
  TOPARG=(-Wno-MULTITOP)
fi

echo "==> lint: ${#FILES[@]} file(s)"
if "$VERILATOR" --lint-only -Wall \
     -I"$ROOT/rtl/common" -I"$ROOT/rtl/e_core" \
     "${TOPARG[@]}" "${FILES[@]}"; then
  echo "    lint clean (0 warnings)"
  exit 0
else
  echo "    LINT FAILED"
  exit 1
fi
