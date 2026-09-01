#!/usr/bin/env bash
# Central regression driver. Dispatched from the Makefile so every target
# shares one place for build rules, result tables and exit codes.
#
#   run_tests.sh unit        - build+run tb/unit/*
#   run_tests.sh build-core  - build the integration simulator
#   run_tests.sh asm         - tb/asm/*.S
#   run_tests.sh sw          - sw/tests/*.c
#   run_tests.sh riscv       - rv32ui-p compliance suite
#   run_tests.sh random      - lockstep random programs
#   run_tests.sh coverage    - coverage build + report
#   run_tests.sh wave <name> - one test with --trace
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
mkdir -p "$BUILD"

MODE=${1:-}
shift || true

case "$MODE" in
  unit)       exec "$ROOT/scripts/run_unit.sh" "$@" ;;
  build-core) exec "$ROOT/scripts/build_core.sh" "$@" ;;
  asm)        exec "$ROOT/scripts/run_asm.sh" "$@" ;;
  sw)         exec "$ROOT/scripts/run_sw.sh" "$@" ;;
  riscv)      exec "$ROOT/scripts/build_riscv_tests.sh" "$@" ;;
  random)     exec "$ROOT/scripts/run_random.sh" "$@" ;;
  coverage)   exec "$ROOT/scripts/run_coverage.sh" "$@" ;;
  wave)       exec "$ROOT/scripts/run_wave.sh" "$@" ;;
  *)
    echo "run_tests.sh: unknown mode '${MODE}'" >&2
    echo "expected one of: unit build-core asm sw riscv random coverage wave" >&2
    exit 2 ;;
esac
