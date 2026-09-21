#!/usr/bin/env bash
# Yosys area estimate for the E-Core.
#
# Yosys's built-in Verilog front end cannot parse enumerated or packed-struct
# types in port lists. This design uses both throughout -- they are what makes
# the decoder's control bundle and the ALU's operator readable -- so the
# sources are first lowered to Verilog-2005 with sv2v, which is a purely
# syntactic transformation and does not change behaviour.
#
# sv2v is not packaged for every distribution, so if it is not on PATH this
# script fetches the upstream static binary into build/tools/. That needs no
# root and nothing outside the build directory.
set -euo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
YOSYS=${YOSYS:-yosys}
SV2V_VERSION=${SV2V_VERSION:-v0.0.13}

if ! command -v "$YOSYS" >/dev/null 2>&1; then
  echo "yosys not found -- install it to run 'make synth'." >&2
  echo "  Arch:   sudo pacman -S yosys" >&2
  echo "  Debian: sudo apt install yosys" >&2
  exit 1
fi

# ---- locate or fetch sv2v ----
SV2V=${SV2V:-}
if [ -z "$SV2V" ]; then
  if command -v sv2v >/dev/null 2>&1; then
    SV2V=$(command -v sv2v)
  elif [ -x "$BUILD/tools/sv2v-Linux/sv2v" ]; then
    SV2V="$BUILD/tools/sv2v-Linux/sv2v"
  else
    echo "==> sv2v not found; fetching the static binary into build/tools/"
    mkdir -p "$BUILD/tools"
    url="https://github.com/zachjs/sv2v/releases/download/${SV2V_VERSION}/sv2v-Linux.zip"
    if ! curl -fsSL -o "$BUILD/tools/sv2v.zip" "$url"; then
      echo "could not download sv2v from $url" >&2
      echo "install it manually and re-run, or set SV2V=/path/to/sv2v" >&2
      exit 1
    fi
    ( cd "$BUILD/tools" && unzip -oq sv2v.zip )
    chmod +x "$BUILD/tools/sv2v-Linux/sv2v"
    SV2V="$BUILD/tools/sv2v-Linux/sv2v"
  fi
fi
echo "==> sv2v: $("$SV2V" --version)"

mkdir -p "$BUILD/synth"

# The package must come first: everything else refers to its types.
RTL=("$ROOT/rtl/common/e_core_pkg.sv")
for f in "$ROOT"/rtl/common/*.sv "$ROOT"/rtl/e_core/*.sv; do
  [ "$f" = "$ROOT/rtl/common/e_core_pkg.sv" ] && continue
  RTL+=("$f")
done

echo "==> lowering ${#RTL[@]} SystemVerilog files to Verilog-2005"
"$SV2V" --write="$BUILD/synth/e_core_flat.v" "${RTL[@]}"

echo "==> yosys"
cd "$ROOT"
"$YOSYS" -q -l "$BUILD/synth/yosys.log" "$ROOT/syn/e_core_synth.ys"

echo
echo "=================== generic cell estimate ==================="
cat "$BUILD/synth/generic_stat.txt"
echo
echo "============== Xilinx 7-series LUT estimate ================="
cat "$BUILD/synth/xilinx_stat.txt"
