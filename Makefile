# ============================================================================
#  RISC-V SoC — Phase 0/1: E-Core (RV32I_Zicsr, 3-stage, machine mode)
#  Top-level build & regression Makefile.
#
#  Primary targets:
#    make tools        - report toolchain state
#    make lint         - Verilator lint over all of rtl/  (zero-warning gate)
#    make unit         - build + run every unit testbench
#    make e_core       - build the Verilator core simulator
#    make asm-tests    - build + run tb/asm/*.S
#    make sw-tests     - build + run sw/tests/*.c
#    make riscv-tests  - build + run the rv32ui-p compliance suite
#    make random       - randomised lockstep vs the golden ISS
#    make coverage     - coverage build + report
#    make synth        - Yosys area estimate
#    make test         - everything except synth (ACCEPTANCE GATE)
#    make wave TEST=x  - rerun one test with tracing -> build/x.vcd
#    make clean
# ============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

ROOT      := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
RTL_DIR   := $(ROOT)/rtl
TB_DIR    := $(ROOT)/tb
SW_DIR    := $(ROOT)/sw
SCRIPTS   := $(ROOT)/scripts
BUILD     := $(ROOT)/build
THIRD     := $(ROOT)/third_party

# ---------------------------------------------------------------------------
# Toolchain discovery
# ---------------------------------------------------------------------------
VERILATOR ?= verilator
YOSYS     ?= yosys
PYTHON    ?= python3

# RISC-V cross compiler. Preference order:
#   1. riscv32-unknown-elf-  (native rv32, ideal)
#   2. riscv64-unknown-elf-  (rv64 default, driven with -march=rv32i_zicsr -mabi=ilp32)
#   3. riscv32-elf-          (Arch/Fedora naming)
#   4. riscv64-elf-
#   5. riscv64-linux-gnu-    (multilib Linux cross; fine for -nostdlib freestanding)
# Override on the command line with:  make RISCV_PREFIX=/opt/riscv/bin/riscv32-unknown-elf-
RISCV_PREFIX ?= $(shell for p in riscv32-unknown-elf- riscv64-unknown-elf- \
                                 riscv32-elf- riscv64-elf- riscv64-linux-gnu-; do \
                          if command -v $${p}gcc >/dev/null 2>&1; then echo $$p; break; fi; \
                        done)

RVCC      := $(RISCV_PREFIX)gcc
RVOBJCOPY := $(RISCV_PREFIX)objcopy
RVOBJDUMP := $(RISCV_PREFIX)objdump
RVNM      := $(RISCV_PREFIX)nm

# Target ISA / ABI, per spec section 2.1.
RVARCH := rv32i_zicsr
RVABI  := ilp32

RVCFLAGS  := -march=$(RVARCH) -mabi=$(RVABI) -mcmodel=medany \
             -nostdlib -nostartfiles -ffreestanding -fno-builtin \
             -O2 -g -Wall -Wextra -fno-common -fomit-frame-pointer
RVLDFLAGS := -Wl,--build-id=none -T $(SW_DIR)/common/linker.ld

# libgcc supplies the software integer divide and modulo routines
# (__udivsi3, __umodsi3, __divsi3, __modsi3). This core has no M extension by
# design, so GCC lowers every '/' and '%' in C to a call into libgcc; linking
# it is what makes "multiply and divide are done in software" actually work.
# It must come last on the link line, after all objects.
RVLIBS := -lgcc

# ---------------------------------------------------------------------------
# RTL file lists
# ---------------------------------------------------------------------------
RTL_PKG    := $(RTL_DIR)/common/e_core_pkg.sv
RTL_COMMON := $(RTL_DIR)/common/alu.sv \
              $(RTL_DIR)/common/regfile.sv \
              $(RTL_DIR)/common/imm_gen.sv \
              $(RTL_DIR)/common/decoder.sv \
              $(RTL_DIR)/common/csr_unit.sv \
              $(RTL_DIR)/common/lsu.sv
RTL_CORE   := $(RTL_DIR)/e_core/e_core_if_stage.sv \
              $(RTL_DIR)/e_core/e_core_id_stage.sv \
              $(RTL_DIR)/e_core/e_core_ex_stage.sv \
              $(RTL_DIR)/e_core/e_core_hazard.sv \
              $(RTL_DIR)/e_core/e_core_trap.sv \
              $(RTL_DIR)/e_core/e_core_top.sv
RTL_ALL    := $(RTL_PKG) $(RTL_COMMON) $(RTL_CORE)

VINC := -I$(RTL_DIR)/common -I$(RTL_DIR)/e_core

# Zero-warning bar (spec 2.8): -Wall, no -Wno-fatal escape hatch.
VLINT_FLAGS := --lint-only -Wall --timing $(VINC)

# Common Verilator build flags for simulation binaries.
VSIM_FLAGS := --cc --exe --build -j 0 -Wall $(VINC) \
              -CFLAGS "-std=c++17 -O2 -Wall -I$(TB_DIR)/integration" \
              --x-assign unique --x-initial unique

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------
.PHONY: help
help:
	@echo "E-Core build system.  Targets:"
	@grep -E '^[a-z][a-z0-9_-]*:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# tools / lint
# ---------------------------------------------------------------------------
.PHONY: tools
tools: ## Report toolchain state
	@$(SCRIPTS)/check_tools.sh

.PHONY: lint
lint: ## Verilator lint over all RTL (must be warning-free)
	@$(SCRIPTS)/lint.sh

# ---------------------------------------------------------------------------
# riscv-tests checkout
# ---------------------------------------------------------------------------
.PHONY: riscv-tests-fetch
riscv-tests-fetch: ## Clone third_party/riscv-tests if absent
	@if [ ! -d $(THIRD)/riscv-tests/isa ]; then \
	  git clone --recursive --depth 1 \
	    https://github.com/riscv-software-src/riscv-tests $(THIRD)/riscv-tests; \
	else echo "riscv-tests already present"; fi

# ---------------------------------------------------------------------------
# Simulation / test targets.
# Implementations land in later milestones; each is wired to a script so the
# Makefile surface stays stable from M0 onward.
# ---------------------------------------------------------------------------
$(BUILD):
	@mkdir -p $(BUILD)

.PHONY: unit
unit: | $(BUILD) ## Build and run every unit testbench
	@$(SCRIPTS)/run_tests.sh unit

.PHONY: e_core
e_core: | $(BUILD) ## Build the Verilator E-Core simulator
	@$(SCRIPTS)/run_tests.sh build-core

.PHONY: asm-tests
asm-tests: | $(BUILD) ## Run tb/asm/*.S directed tests
	@$(SCRIPTS)/run_tests.sh asm

.PHONY: sw-tests
sw-tests: | $(BUILD) ## Run sw/tests/*.c programs
	@$(SCRIPTS)/run_tests.sh sw

.PHONY: riscv-tests
riscv-tests: | $(BUILD) ## Run the rv32ui-p compliance suite
	@$(SCRIPTS)/run_tests.sh riscv

.PHONY: random
random: | $(BUILD) ## Randomised lockstep against the golden ISS
	@$(SCRIPTS)/run_tests.sh random

.PHONY: coverage
coverage: | $(BUILD) ## Coverage build + report
	@$(SCRIPTS)/run_tests.sh coverage

.PHONY: synth
synth: | $(BUILD) ## Yosys area estimate
	@$(SCRIPTS)/synth_estimate.sh

.PHONY: wave
wave: | $(BUILD) ## Rerun one test with tracing: make wave TEST=<name>
	@if [ -z "$(TEST)" ]; then echo "usage: make wave TEST=<name>"; exit 1; fi
	@$(SCRIPTS)/run_tests.sh wave $(TEST)

.PHONY: test
test: lint unit asm-tests riscv-tests sw-tests random coverage ## ACCEPTANCE GATE
	@echo
	@echo "================================================"
	@echo "  All E-Core regressions passed."
	@echo "================================================"

.PHONY: clean
clean: ## Remove build products
	rm -rf $(BUILD) obj_dir
	find $(ROOT) -name '*.o' -o -name '*.d' | xargs -r rm -f

# Export discovered settings to the shell scripts.
export ROOT RTL_DIR TB_DIR SW_DIR SCRIPTS BUILD THIRD
export VERILATOR YOSYS PYTHON
export RISCV_PREFIX RVCC RVOBJCOPY RVOBJDUMP RVNM
export RVARCH RVABI RVCFLAGS RVLDFLAGS RVLIBS
export RTL_PKG RTL_COMMON RTL_CORE RTL_ALL VINC VSIM_FLAGS
