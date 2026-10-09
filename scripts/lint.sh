#!/usr/bin/env bash
# Verilator lint of both cores.
#
# The bar is: --lint-only -Wall, zero warnings, no -Wno-fatal escape hatch and
# no waiver of any kind. Each core is linted as its own design, with its top
# module forced so that unconnected top-level ports are checked, and with every
# file it uses -- including the shared package, which is what makes
# UNUSEDPARAM meaningful: an unused package constant is invisible to a
# per-file lint. The P-core is additionally linted with RVFI enabled, since
# that elaboration reads signals the default one does not.
#
# The SoC (both cores, the coherent L1 data caches, the snooping bus) is
# linted as a design of its own, in the 2P+2E configuration and in the two
# one-core configurations the cached regressions use, so every generate
# branch is elaborated.
#
#   lint.sh            both cores and the SoC
#   CORE=p_core lint.sh   one core
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
VERILATOR=${VERILATOR:-verilator}

if [ -n "${CORE:-}" ]; then CORES=("$CORE"); LINT_SOC=0; else CORES=(e_core p_core); LINT_SOC=1; fi

rc=0
for c in "${CORES[@]}"; do
  CORE=$c
  # shellcheck source=scripts/core_config.sh
  . "$ROOT/scripts/core_config.sh"
  mapfile -t FILES < <(core_rtl_files)
  for rvfi in 0 1; do
    echo "==> lint: $CORE_TOP (RVFI=$rvfi), ${#FILES[@]} file(s)"
    if "$VERILATOR" --lint-only -Wall "${CORE_INC[@]}" \
         --top-module "$CORE_TOP" -GRVFI=$rvfi "${FILES[@]}"; then
      echo "    lint clean (0 warnings)"
    else
      echo "    LINT FAILED"
      rc=1
    fi
  done
done
if [ "$LINT_SOC" = 1 ]; then
  CORE=e_core
  # shellcheck source=scripts/core_config.sh
  . "$ROOT/scripts/core_config.sh"
  mapfile -t FILES < <(soc_rtl_files)
  for cfg in "2 2 0" "2 2 1" "1 0 1" "0 1 1"; do
    read -r np ne rvfi <<< "$cfg"
    echo "==> lint: soc_top (${np}P+${ne}E, RVFI=$rvfi), ${#FILES[@]} file(s)"
    if "$VERILATOR" --lint-only -Wall "${CORE_INC[@]}" --top-module soc_top \
         -GNUM_P="$np" -GNUM_E="$ne" -GRVFI="$rvfi" "${FILES[@]}"; then
      echo "    lint clean (0 warnings)"
    else
      echo "    LINT FAILED"
      rc=1
    fi
  done
fi
exit $rc
