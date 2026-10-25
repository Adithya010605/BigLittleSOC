#!/usr/bin/env bash
# Clock sweep for one tile: the full ORFS flow (synthesis to GDS) once per
# clock period, each in its own FLOW_VARIANT (sweep_<period>), one after
# another (a run peaks at about 8 GB, and this machine has 15 GB).
#
#   scripts/pd_sweep.sh [block] [periods...]
#   scripts/pd_sweep.sh e_tile 1300 1350 1400 1450 1500
#
# A period whose run already finished (6_report.json exists) is skipped, so an
# interrupted sweep picks up where it stopped. Then summarise with
#   python3 scripts/pd_sweep_report.py <block>
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BLOCK=${1:-e_tile}
shift || true
PERIODS=("$@")
[[ ${#PERIODS[@]} -gt 0 ]] || PERIODS=(1300 1350 1400 1450 1500)
NUM_CORES=${NUM_CORES:-12}

CONFIG=/workspace/pd/asap7/soc_top/$BLOCK/config.mk
NICK=soc_top_$BLOCK
LOGS=$ROOT/pd/orfs/sweep_logs/$BLOCK
mkdir -p "$LOGS"

for p in "${PERIODS[@]}"; do
  variant=sweep_$p
  if [[ -f $ROOT/pd/orfs/logs/asap7/$NICK/$variant/6_report.json ]]; then
    echo "[$(date +%T)] $BLOCK $p ps: already done, skipped"
    continue
  fi
  echo "[$(date +%T)] $BLOCK $p ps: started (log: ${LOGS#$ROOT/}/$variant.log)"
  # CLK_PERIOD_PS sets the SDC's clock; ABC_CLOCK_PERIOD_IN_PS gives synthesis
  # the same target (ORFS otherwise reads the SDC's first `set clk_period`).
  if "$ROOT/scripts/orfs_shell.sh" env CLK_PERIOD_PS="$p" \
       make -C /OpenROAD-flow-scripts/flow DESIGN_CONFIG="$CONFIG" \
            FLOW_VARIANT="$variant" ABC_CLOCK_PERIOD_IN_PS="$p" \
            NUM_CORES="$NUM_CORES" </dev/null >"$LOGS/$variant.log" 2>&1; then
    echo "[$(date +%T)] $BLOCK $p ps: finished"
  else
    echo "[$(date +%T)] $BLOCK $p ps: FAILED (see the log); continuing"
  fi
done
echo "[$(date +%T)] sweep done"
