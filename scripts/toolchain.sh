# Shared toolchain discovery, sourced by the regression scripts.
#
# The Makefile exports RISCV_PREFIX and friends, but the scripts are also meant
# to be runnable by hand while debugging. This fills in the same values using
# the same preference order when the environment does not already carry them.

if [ -z "${RISCV_PREFIX:-}" ]; then
  for _p in riscv32-unknown-elf- riscv64-unknown-elf- \
            riscv32-elf- riscv64-elf- riscv64-linux-gnu-; do
    if command -v "${_p}gcc" >/dev/null 2>&1; then RISCV_PREFIX="$_p"; break; fi
  done
  unset _p
fi

RVCC=${RVCC:-${RISCV_PREFIX:-}gcc}
RVOBJCOPY=${RVOBJCOPY:-${RISCV_PREFIX:-}objcopy}
RVOBJDUMP=${RVOBJDUMP:-${RISCV_PREFIX:-}objdump}
RVNM=${RVNM:-${RISCV_PREFIX:-}nm}

RVARCH=${RVARCH:-rv32i_zicsr}
RVABI=${RVABI:-ilp32}
RVCFLAGS=${RVCFLAGS:--march=$RVARCH -mabi=$RVABI -mcmodel=medany -nostdlib -nostartfiles -ffreestanding -fno-builtin -O2 -g -Wall -Wextra -fno-common -fomit-frame-pointer}
RVLIBS=${RVLIBS:--lgcc}

export RISCV_PREFIX RVCC RVOBJCOPY RVOBJDUMP RVNM RVARCH RVABI RVCFLAGS RVLIBS
