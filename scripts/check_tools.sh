#!/usr/bin/env bash
# Toolchain presence / version check for the E-Core project (Milestone M0).
# Exits non-zero if a hard requirement is missing.
set -u

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
fail=0
warn=0

say_ok()   { printf "  %s[ ok ]%s %-28s %s\n" "$GRN" "$RST" "$1" "$2"; }
say_warn() { printf "  %s[warn]%s %-28s %s\n" "$YEL" "$RST" "$1" "$2"; warn=$((warn+1)); }
say_bad()  { printf "  %s[FAIL]%s %-28s %s\n" "$RED" "$RST" "$1" "$2"; fail=$((fail+1)); }

echo "=== E-Core toolchain check ==="

# ---- Verilator (hard requirement, v5.x) ----
if command -v verilator >/dev/null 2>&1; then
    vver=$(verilator --version | awk '{print $2}')
    vmaj=${vver%%.*}
    if [ "${vmaj:-0}" -ge 5 ] 2>/dev/null; then
        say_ok "verilator" "$vver"
    else
        say_bad "verilator" "$vver (need >= 5.0)"
    fi
else
    say_bad "verilator" "not found  -> pacman -S verilator | apt install verilator"
fi

# ---- C++ host compiler (hard requirement) ----
if command -v g++ >/dev/null 2>&1; then
    say_ok "g++" "$(g++ -dumpversion)"
elif command -v clang++ >/dev/null 2>&1; then
    say_ok "clang++" "$(clang++ -dumpversion)"
else
    say_bad "g++/clang++" "not found"
fi

# ---- make / python3 / git (hard) ----
for t in make python3 git; do
    if command -v $t >/dev/null 2>&1; then
        say_ok "$t" "$($t --version 2>&1 | head -1)"
    else
        say_bad "$t" "not found"
    fi
done

# ---- RISC-V cross compiler (hard) ----
# Preference order matches the Makefile's own detection.
RISCV_PREFIX=""
for p in riscv32-unknown-elf- riscv64-unknown-elf- riscv32-elf- riscv64-elf- riscv64-linux-gnu-; do
    if command -v "${p}gcc" >/dev/null 2>&1; then RISCV_PREFIX="$p"; break; fi
done
if [ -n "$RISCV_PREFIX" ]; then
    # Confirm it can actually emit rv32i_zicsr / ilp32 objects.
    tmp=$(mktemp -d)
    echo 'int _start(void){return 0;}' > "$tmp/t.c"
    if "${RISCV_PREFIX}gcc" -march=rv32i_zicsr -mabi=ilp32 -nostdlib -ffreestanding \
         -c "$tmp/t.c" -o "$tmp/t.o" >"$tmp/err" 2>&1; then
        say_ok "riscv cc (${RISCV_PREFIX}gcc)" "emits rv32i_zicsr/ilp32"
    else
        say_bad "riscv cc (${RISCV_PREFIX}gcc)" "cannot emit rv32i_zicsr/ilp32: $(head -1 "$tmp/err")"
    fi
    rm -rf "$tmp"
else
    say_bad "riscv cross compiler" "none of riscv{32,64}-{unknown-,}elf-gcc / riscv64-linux-gnu-gcc found"
fi

# ---- Soft requirements ----
if command -v yosys >/dev/null 2>&1; then
    say_ok "yosys" "$(yosys --version | head -1)"
else
    say_warn "yosys" "not found (only 'make synth' needs it)"
fi
if command -v gtkwave >/dev/null 2>&1; then
    say_ok "gtkwave" "$(gtkwave --version 2>&1 | head -1)"
else
    say_warn "gtkwave" "not found (only waveform viewing needs it)"
fi

# ---- riscv-tests checkout ----
here=$(cd "$(dirname "$0")/.." && pwd)
if [ -d "$here/third_party/riscv-tests/isa" ]; then
    say_ok "third_party/riscv-tests" "present"
else
    say_warn "third_party/riscv-tests" "missing -> make riscv-tests-fetch"
fi

echo
if [ "$fail" -gt 0 ]; then
    echo "${RED}$fail hard requirement(s) missing.${RST}  See docs/README.md 'Prerequisites'."
    exit 1
fi
[ "$warn" -gt 0 ] && echo "${YEL}$warn optional tool(s) missing.${RST}"
echo "${GRN}Toolchain OK.${RST}"
exit 0
