# RISC-V SoC — E-Core

A 3-stage pipelined **RV32I_Zicsr** machine-mode RISC-V core, written in
SystemVerilog-2012 and verified with Verilator. This is Phase 0 + Phase 1 of the
larger big.LITTLE / UMA SoC described in `RISC-V_SoC_Project_Plan.md`; the P-core,
caches, interconnect and accelerator are **not** part of this tree yet.

## What it is

| Property | Value |
|---|---|
| ISA | RV32I + Zicsr, machine mode only (`rv32i_zicsr` / `ilp32`) |
| Pipeline | 3 stages: `IF` → `ID/RF` → `EX/MEM/WB` |
| Branch handling | Resolved in ID, static not-taken, 1-cycle penalty |
| Hazards | Full EX→ID forwarding; 1-cycle stall for load-use and CSR-use |
| Memory interface | Two independent valid/ready ports (Ibex-style), arbitrary latency |
| Traps | All RV32I machine-mode exceptions + timer/software/external interrupts |
| Area target | < 5K LUTs (Xilinx 7-series, see `docs/e_core_results.md`) |

Full details: [`docs/e_core_microarchitecture.md`](docs/e_core_microarchitecture.md).

## Prerequisites

| Tool | Version | Needed for |
|---|---|---|
| Verilator | **5.x** (hard requirement) | all simulation and lint |
| g++ / clang++ | C++17 | testbench harnesses |
| RISC-V cross compiler | any of `riscv32-unknown-elf-`, `riscv64-unknown-elf-`, `riscv32-elf-`, `riscv64-elf-`, `riscv64-linux-gnu-` | assembling and compiling test programs |
| GNU make, python3, git | — | build system, generators |
| yosys | 0.3x+ | `make synth` only |
| gtkwave | — | viewing `make wave` output only |

Install on Arch:

```sh
sudo pacman -S verilator gtkwave yosys riscv64-elf-gcc riscv64-elf-newlib \
               riscv64-elf-binutils base-devel python
```

Install on Debian/Ubuntu:

```sh
sudo apt install verilator gtkwave yosys gcc-riscv64-unknown-elf \
                 build-essential python3
```

Verify with:

```sh
make tools
```

The Makefile auto-detects the cross compiler and sets `RISCV_PREFIX`. Override it
explicitly if you have a toolchain elsewhere:

```sh
make RISCV_PREFIX=/opt/riscv/bin/riscv32-unknown-elf- test
```

## Building and running from a clean clone

```sh
git clone <this repo> && cd risc-v-soc
make riscv-tests-fetch      # pulls third_party/riscv-tests
make tools                  # confirm the toolchain
make test                   # the full acceptance gate
```

`make test` runs, in order: lint → unit tests → directed assembly tests →
rv32ui-p compliance suite → C programs → randomised lockstep → coverage. It is
the gate; it must be green with zero warnings.

## Individual targets

| Target | What it does |
|---|---|
| `make tools` | report toolchain state |
| `make lint` | `verilator --lint-only -Wall` over all of `rtl/` |
| `make unit` | build + run every unit testbench in `tb/unit/` |
| `make e_core` | build the Verilator integration simulator |
| `make asm-tests` | run the directed assembly tests in `tb/asm/` |
| `make sw-tests` | compile and run the C programs in `sw/tests/` |
| `make riscv-tests` | run the rv32ui-p compliance suite |
| `make random` | randomised lockstep against the golden ISS |
| `make coverage` | coverage build + line/toggle report |
| `make synth` | Yosys area estimate |
| `make wave TEST=<name>` | rerun one test with tracing → `build/<name>.vcd` |
| `make clean` | remove build products |

## Repository layout

```
rtl/common/     ALU, regfile, immediate generator, decoder, CSR unit, LSU, shared package
rtl/e_core/     pipeline stages, hazard unit, trap unit, top level
tb/unit/        one C++ Verilator harness per common/ module
tb/integration/ core harness, memory model, ELF loader, golden ISS
tb/asm/         hand-written self-checking assembly tests
sw/common/      startup code, linker scripts, UART driver
sw/tests/       C benchmark programs
scripts/        build and regression drivers
syn/            Yosys synthesis script
docs/           microarchitecture, verification plan, results, lab notebook
```

## Documentation

- [`docs/e_core_microarchitecture.md`](docs/e_core_microarchitecture.md) — datapath, hazard and stall tables, trap priority, CSR map, design justifications
- [`docs/e_core_verification_plan.md`](docs/e_core_verification_plan.md) — test matrix, coverage numbers, known limitations
- [`docs/e_core_results.md`](docs/e_core_results.md) — compliance pass table, CPI, stall breakdown, area estimate
- [`docs/lab_notebook.md`](docs/lab_notebook.md) — design decisions and debugging log
