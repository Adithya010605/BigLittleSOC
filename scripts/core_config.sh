# Per-core configuration, sourced by every regression script.
#
# CORE selects the core under test:
#   e_core  (default)  RV32I_Zicsr, 3-stage           rtl/e_core
#   p_core             RV32IM_Zicsr, 5-stage, BHT/BTB  rtl/p_core
#
# Everything that differs between the two lives here: the top module, the RTL
# file list, the ISA the test programs are compiled for, the name of the
# simulator binary and where build products go. The E-core keeps the paths it
# has always used (build/e_core_sim, build/asm, ...), so nothing that already
# refers to them moves; the P-core's products live under build/p_core/.

CORE=${CORE:-e_core}
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}

case "$CORE" in
  e_core)
    CORE_TOP=e_core_top
    CORE_ARCH=rv32i_zicsr
    CORE_CFLAGS=""
    CORE_OUT="$BUILD"
    CORE_ASM_DEFS=""
    ;;
  p_core)
    CORE_TOP=p_core_top
    # Zifencei: FENCE.I flushes and refetches (see p_core_mem_stage.sv).
    CORE_ARCH=rv32im_zicsr_zifencei
    CORE_CFLAGS="-DCORE_P"
    CORE_OUT="$BUILD/p_core"
    # Lets a shared directed test leave out the checks that only hold on a
    # core without the M extension (that MUL traps, for instance).
    CORE_ASM_DEFS="-DCORE_HAS_M"
    ;;
  *)
    echo "core_config.sh: unknown CORE '$CORE' (expected e_core or p_core)" >&2
    exit 2 ;;
esac

CORE_SIM="$BUILD/${CORE}_sim"
CORE_INC=(-I"$ROOT/rtl/common" -I"$ROOT/rtl/e_core" -I"$ROOT/rtl/p_core")

# Ordered RTL file list for the core under test, rooted at $1 (default
# $ROOT/rtl, overridden by the mutation script to point at a mutated copy).
# Packages come first, because every other file refers to their types.
core_rtl_files() {
  local rtl=${1:-$ROOT/rtl}
  local f
  echo "$rtl/common/e_core_pkg.sv"
  [ "$CORE" = p_core ] && echo "$rtl/p_core/p_core_pkg.sv"
  for f in "$rtl"/common/*.sv; do
    [ "$f" = "$rtl/common/e_core_pkg.sv" ] || echo "$f"
  done
  if [ "$CORE" = p_core ]; then
    for f in "$rtl"/p_core/*.sv; do
      [ "$f" = "$rtl/p_core/p_core_pkg.sv" ] || echo "$f"
    done
    # The trap unit is shared with the E-core, unchanged.
    echo "$rtl/e_core/e_core_trap.sv"
  else
    for f in "$rtl"/e_core/*.sv; do echo "$f"; done
  fi
}

# The test programs are compiled for the core's ISA: with the M extension the
# C compiler emits hardware multiply and divide instead of libgcc calls.
RVARCH=$CORE_ARCH
RVCFLAGS="-march=$RVARCH -mabi=${RVABI:-ilp32} -mcmodel=medany -nostdlib -nostartfiles -ffreestanding -fno-builtin -O2 -g -Wall -Wextra -fno-common -fomit-frame-pointer"
export CORE RVARCH RVCFLAGS
