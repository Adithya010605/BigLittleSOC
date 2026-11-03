#!/usr/bin/env bash
# Final tile runs: the full ORFS flow (synthesis to GDS) at the chip clock in
# the tiles' constraint.sdc, then the abstract the top level places (LEF
# outline/pins, .lib timing model). One tile after another: the P-tile's
# routing peaks at about 13 GB on this 15 GB machine.
#
#   scripts/pd_final.sh [blocks...]        default: e_tile p_tile
#
# Each run goes to FLOW_VARIANT=$VARIANT (default final_1500) under pd/orfs/.
# The macro views are copied to pd/macros/<block>/ (committed): <block>.lef,
# <block>.lib and <block>.gds.gz.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VARIANT=${VARIANT:-final_1500}
BLOCKS=("$@")
[[ ${#BLOCKS[@]} -gt 0 ]] || BLOCKS=(e_tile p_tile)
LOGS=$ROOT/pd/orfs/sweep_logs

for b in "${BLOCKS[@]}"; do
  cores=12
  [[ $b == p_tile ]] && cores=6
  config=/workspace/pd/asap7/soc_top/$b/config.mk
  res=$ROOT/pd/orfs/results/asap7/soc_top_$b/$VARIANT
  mkdir -p "$LOGS/$b"
  echo "[$(date +%T)] $b: flow started (log: pd/orfs/sweep_logs/$b/$VARIANT.log)"
  "$ROOT/scripts/orfs_shell.sh" \
    make -C /OpenROAD-flow-scripts/flow DESIGN_CONFIG="$config" \
         FLOW_VARIANT="$VARIANT" NUM_CORES="$cores" \
         </dev/null >"$LOGS/$b/$VARIANT.log" 2>&1
  echo "[$(date +%T)] $b: abstract"
  "$ROOT/scripts/orfs_shell.sh" \
    make -C /OpenROAD-flow-scripts/flow DESIGN_CONFIG="$config" \
         FLOW_VARIANT="$VARIANT" generate_abstract \
         </dev/null >"$LOGS/$b/${VARIANT}_abstract.log" 2>&1

  out=$ROOT/pd/macros/$b
  mkdir -p "$out"
  cp "$res/$b.lef" "$out/$b.lef"
  cp "$res/${b}_typ.lib" "$out/$b.lib"
  gzip -9 -c "$res/6_final.gds" >"$out/$b.gds.gz"
  echo "[$(date +%T)] $b: done, macro in pd/macros/$b/"
done
