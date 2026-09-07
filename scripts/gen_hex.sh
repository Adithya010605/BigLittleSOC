#!/usr/bin/env bash
# ELF -> flat .bin -> Verilator-loadable .hex (one 32-bit word per line,
# little-endian, ascending address) plus a .sym symbol table so the
# testbench can resolve `tohost`, `_start`, etc.
#
#   gen_hex.sh <input.elf> <output-basename>
# produces <output-basename>.bin, .hex, .sym, .dis
set -euo pipefail

ELF=${1:?usage: gen_hex.sh <elf> <out-basename>}
OUT=${2:?usage: gen_hex.sh <elf> <out-basename>}

. "$(dirname "$0")/toolchain.sh"
OBJCOPY=$RVOBJCOPY
OBJDUMP=$RVOBJDUMP
NM=$RVNM

# Flat image: every allocatable, loadable section from the lowest LMA up.
"$OBJCOPY" -O binary --gap-fill 0 "$ELF" "$OUT.bin"

# 32-bit little-endian words, one per line, no address prefix.
python3 - "$OUT.bin" "$OUT.hex" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
if len(data) % 4:
    data += b'\x00' * (4 - len(data) % 4)
with open(dst, 'w') as f:
    for i in range(0, len(data), 4):
        f.write('%08x\n' % int.from_bytes(data[i:i+4], 'little'))
PY

# Symbol table: "<hex addr> <type> <name>" — the TB greps this for tohost.
"$NM" "$ELF" > "$OUT.sym"

# Disassembly is not needed by the TB but makes failures readable.
"$OBJDUMP" -d -M no-aliases,numeric "$ELF" > "$OUT.dis" 2>/dev/null || \
  "$OBJDUMP" -d "$ELF" > "$OUT.dis"
