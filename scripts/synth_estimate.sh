#!/usr/bin/env bash
# Yosys area estimate for the E-Core. Writes build/synth/e_core_area.txt.
set -euo pipefail
ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
YOSYS=${YOSYS:-yosys}

if ! command -v "$YOSYS" >/dev/null 2>&1; then
  echo "yosys not found — install it to run 'make synth'." >&2
  echo "  Arch:   sudo pacman -S yosys" >&2
  echo "  Debian: sudo apt install yosys" >&2
  exit 1
fi

mkdir -p "$BUILD/synth"
cd "$ROOT"
"$YOSYS" -q -l "$BUILD/synth/yosys.log" "$ROOT/syn/e_core_synth.ys"
echo "--- area summary ---"
sed -n '/Printing statistics/,$p' "$BUILD/synth/yosys.log" | tail -60 \
  | tee "$BUILD/synth/e_core_area.txt"
