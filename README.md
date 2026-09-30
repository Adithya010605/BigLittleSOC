# BigLittleSOC

A RISC-V big.LITTLE / Unified-Memory SoC, built from scratch in SystemVerilog and
verified with Verilator.

This repository currently contains **Phase 0 and Phase 1 of the project: the
E-Core** — a complete, compliance-passing, 100%-line-covered RV32I_Zicsr
processor — together with the full multi-phase plan for the SoC that gets built
around it.

> **Phase 2, the P-Core, is done and lives on the
> [`docs/p-core-presentation`](https://github.com/Adithya010605/BigLittleSOC/tree/docs/p-core-presentation) branch**,
> not on `main` yet. See [§1.1](#11-phase-2-the-p-core-on-branch-docsp-core-presentation)
> for what it is and how it compares with the E-Core.

The design target is a heterogeneous SoC in the shape of real Apple-Silicon-class
parts: a small efficiency core and a wide performance core sharing one coherent
memory fabric, with an ML accelerator and DMA hanging off the same unified
memory, and a task-migration controller moving work between the cores.

---

## Table of contents

1. [Where the project stands](#1-where-the-project-stands)
2. [The E-Core at a glance](#2-the-e-core-at-a-glance)
3. [Repository layout](#3-repository-layout)
4. [Prerequisites](#4-prerequisites)
5. [Quick start](#5-quick-start)
6. [How to run everything](#6-how-to-run-everything)
7. [How the verification is put together](#7-how-the-verification-is-put-together)
8. [Results](#8-results)
9. [Programming model and memory map](#9-programming-model-and-memory-map)
10. [Design decisions worth knowing](#10-design-decisions-worth-knowing)
11. [Documentation index](#11-documentation-index)
12. [Presentation](#12-presentation)
13. [Working on this as a team](#13-working-on-this-as-a-team)
14. [Roadmap](#14-roadmap)
15. [Troubleshooting](#15-troubleshooting)

---

## 1. Where the project stands

The full plan lives in [`RISC-V_SoC_Project_Plan.md`](RISC-V_SoC_Project_Plan.md).
The short version of the build order, and where we are in it:

| Phase | Deliverable | Status |
|---|---|---|
| 0 | Repo skeleton, build system, toolchain checks | **Done** |
| 1 | **E-Core** — RV32I + Zicsr, 3-stage, machine mode | **Done, verified, synthesised** |
| 2 | **P-Core** — RV32IM, 5-stage, branch prediction | **Done, verified, synthesised** — on branch `docs/p-core-presentation` |
| 3 | UMA interconnect fabric (QoS NoC) | Not started |
| 4 | Cache hierarchy + coherence | Not started |
| 5 | ML accelerator + DMA | Not started |
| 6 | Task migration controller + power management | Not started |
| 7 | Integration, system verification, FPGA bring-up | Not started |

Everything in `rtl/`, `tb/`, `sw/`, `scripts/` and `syn/` on `main` is the
E-Core. **The P-Core source is on the `docs/p-core-presentation` branch** (see
§1.1). The caches, interconnect and accelerator are not written yet; that is
the next chunk of work, and it is what the plan document is for.

The E-Core is not a toy: it passes the official `rv32ui-p` compliance suite,
runs 1,200 randomised programs in lockstep against a golden instruction-set
simulator, survives mutation testing, hits 100% line coverage, and synthesises
to 2,273 LUTs. The numbers in section 8 are all reproducible with `make test`.

### 1.1 Phase 2: the P-Core (on branch `docs/p-core-presentation`)

The P-Core is the "big" core of the big.LITTLE pair. Its code is **not on
`main` yet**; it is on the `docs/p-core-presentation` branch:

```sh
git fetch origin
git checkout docs/p-core-presentation
make CORE=p_core p-test     # the P-Core's full gate
make test                   # both cores' gates + the E/P benchmark comparison
```

On that branch, `rtl/p_core/` holds the P-Core RTL, `tb/asm/p_core/` and
`tb/unit/p_core/` its tests, and `docs/p_core_*.md` its microarchitecture,
verification plan and results. `docs/p_core_panel_presentation.md` has every
feature, every result and the full E-Core/P-Core comparison. Every regression
script takes `CORE=e_core|p_core`.

**P-Core at a glance**

| Property | Value |
|---|---|
| ISA | RV32I + M + Zicsr + Zifencei, machine mode |
| Pipeline | 5 stages: `IF` → `ID` → `EX` → `MEM` → `WB` |
| Branch prediction | 256-entry 2-bit BHT + 64-entry direct-mapped BTB; resolved in EX, 2-cycle mispredict penalty |
| Forwarding | EX→EX, MEM→EX, MEM→MEM (a load followed by a store of the loaded value does not stall) |
| Multiply / divide | radix-4 Booth, 4 cycles / restoring, 33 cycles, interruptible |
| Traps | precise, committed at MEM; the E-Core's trap unit is reused unchanged |
| Performance counters | `mcycle`, `minstret` + 7 `mhpmcounter`s (adds mispredicts, MUL/DIV busy, interlock) |
| Interface | **identical to the E-Core's**, so the two drop into the same SoC slot |

**E-Core vs P-Core, same metrics.** Both cores were built and measured in one
`make test` run (2026-09-26) with the same testbench, golden ISS, compiler and
counter definitions, at zero wait states and the same clock. Speed-up = E-Core
cycles ÷ P-Core cycles.

| Metric | E-Core | P-Core | P vs E |
|---|---:|---:|---|
| ISA | RV32I | RV32IM + real `FENCE.I` | |
| Pipeline | 3-stage | 5-stage | |
| Branches | static not-taken, 1-cycle penalty on every taken branch or jump | predicted; 0 cycles if right, 2 if wrong | |
| **C programs, all six, total cycles** | 842,390 | **760,576** | **1.11×** |
| C programs, total instructions retired | 735,691 | 721,084 | −2.0% (hardware MUL/DIV) |
| C programs, total CPI | 1.145 | **1.055** | −7.9% |
| `perf_counters` (MUL/DIV-heavy) | 14,999 | 7,767 | **1.93×** |
| `bubble_sort` | 12,523 | 7,113 | 1.76× |
| `memcpy_test` (same instruction count) | 298,242 (CPI 1.264) | 240,549 (CPI **1.020**) | 1.24× |
| `fib` (recursion) | 511,036 | 500,623 | 1.02× |
| Short one-pass code (40 `rv32ui` tests) | **16,426** | 18,005 | **0.91×** (E-Core faster) |
| LUTs (Xilinx 7-series, Yosys) | **2,249**¹ | 5,273 | 2.3× larger |
| Flip-flops | **968** | 1,907 | 2.0× larger |
| Work per LUT (speed-up ÷ area) | **1.00** | 0.47 | E-Core 2.1× more area-efficient |
| Compliance | `rv32ui` 40 pass, 2 skip | `rv32ui` 41 pass + `rv32um` 8/8, 1 skip | |
| Directed tests (× 5 latency configs) | 13 | 20 | |
| Randomised lockstep vs golden ISS | 1,200 runs | 1,200 runs (with RV32M) | |
| Mutation testing | 23: 16 killed, 7 equivalent | 32: 30 killed, 2 equivalent | 0 unexplained on both |
| Line coverage | 100% | 100% | |
| Toggle coverage (core RTL) | 82.6% | 83.2% | |
| Fmax | not measured | not measured | needs place and route |

¹ 2,249 rather than the 2,273 in §8: the synthesis flow now defines
`SYNTHESIS`, which drops simulation-only code. Same RTL.

**Reading the comparison**

- On real, loop-heavy programs the P-Core does more work per clock: 1.11×
  over the C programs, and up to 1.93× on multiply/divide code. The gain comes from two places: fewer instructions (hardware MUL/DIV
  instead of libgcc) and lower CPI (predicted branches, and loads feeding
  stores without a stall).
- On short code that runs once, the E-Core is about 9% faster per clock. The
  predictor has not learnt anything yet, and a wrong guess costs 2 cycles
  against the E-Core's 1.
- The P-Core is 1.11× faster but costs 2.3× the LUTs, so the E-Core does
  about 2.1× more work per LUT. That is the big.LITTLE trade-off: a small core for light
  work, a bigger core for heavy work.
- A 5-stage pipeline's main expected gain is a higher clock frequency. That is
  not measured yet for either core (no place-and-route tool); it is the open
  question for FPGA bring-up.

To reproduce the program comparison on the branch:

```sh
make sw-tests && make CORE=p_core sw-tests   # build and run the C programs on both cores
make bench                                   # prints the E-Core vs P-Core table (~5 s)
```

There is no return-address stack yet, so a function called from several
places mispredicts its return; that is why recursive `fib` gains only 1.02×,
and a return-address stack is the obvious next improvement.

---

## 2. The E-Core at a glance

| Property | Value |
|---|---|
| ISA | RV32I + Zicsr, machine mode only (`rv32i_zicsr` / `ilp32`) |
| Pipeline | 3 stages: `IF` → `ID/RF` → `EX/MEM/WB` |
| Branch handling | Resolved in ID, static not-taken, 1-cycle penalty |
| Hazards | Full EX→ID forwarding; 1-cycle stall on load-use and CSR-use |
| Memory interface | Two independent valid/ready ports (Ibex-style), arbitrary latency |
| Traps | All RV32I machine-mode exceptions + timer / software / external interrupts |
| Performance counters | `mcycle`, `minstret`, plus 4 custom `mhpmcounter`s |
| Area | **2,273 LUTs**, 968 FFs, register file in distributed RAM (Xilinx 7-series) |
| Language | SystemVerilog-2012, synthesizable, zero lint warnings |

```
        ┌──────────┐      ┌──────────────┐      ┌────────────────────┐
        │    IF    │─────▶│    ID / RF   │─────▶│   EX / MEM / WB    │
        │  PC      │      │  decoder     │      │  ALU               │
        │  I-fetch │      │  regfile rd  │      │  LSU (D-mem)       │
        │  skid    │      │  imm gen     │      │  CSR unit          │
        │  buffer  │      │  branch res. │      │  writeback mux     │
        └──────────┘      └──────────────┘      └────────────────────┘
              ▲                   ▲                       │
              │                   └───── forward EX→ID ───┤
              └──────── redirect on branch/jump/trap ──────┘
```

Two independent memory ports (instruction and data) each use a
`valid` / `ready` / `rvalid` handshake with no fixed latency, so the core can be
dropped behind a cache in Phase 4 without touching the pipeline.

---

## 3. Repository layout

```
BigLittleSOC/
├── README.md                        this file
├── RISC-V_SoC_Project_Plan.md       the full multi-phase SoC plan
├── Makefile                         every build and test entry point
│
├── rtl/
│   ├── common/                      ALU, regfile, imm gen, decoder, CSR unit, LSU, shared package
│   └── e_core/                      pipeline stages, hazard unit, trap unit, top level
│
├── tb/
│   ├── unit/                        one C++ Verilator harness per rtl/common module
│   ├── integration/                 core harness, memory model, ELF loader, golden ISS, disassembler
│   └── asm/                         hand-written self-checking assembly tests
│
├── sw/
│   ├── common/                      startup code (crt0, start.S), linker scripts, UART driver
│   └── tests/                       C benchmark programs + expected output
│
├── scripts/                         build and regression drivers called by the Makefile
├── syn/                             Yosys synthesis script
├── docs/                            microarchitecture, verification plan, results, lab notebook
└── presentation/                    slide decks + the script that generates them
```

Two directories are created on demand and are **not** in git:

- `build/` — every build product, log, waveform and report. Safe to delete.
- `third_party/riscv-tests/` — the official RISC-V test suite, fetched by
  `make riscv-tests-fetch`.

---

## 4. Prerequisites

| Tool | Version | Needed for |
|---|---|---|
| Verilator | **5.x** (hard requirement) | all simulation and lint |
| g++ / clang++ | C++17 | testbench harnesses |
| RISC-V cross compiler | any of `riscv32-unknown-elf-`, `riscv64-unknown-elf-`, `riscv32-elf-`, `riscv64-elf-`, `riscv64-linux-gnu-` | assembling and compiling test programs |
| GNU make, python3, git | — | build system, generators |
| yosys | 0.3x+ | `make synth` only |
| sv2v | any | `make synth` only — fetched automatically into `build/tools/` if absent, no root needed |
| gtkwave | — | viewing `make wave` output only |
| python-pptx | — | regenerating the slide deck only |

Verilator 4.x will **not** work; the testbenches use 5.x APIs.

**Arch:**

```sh
sudo pacman -S verilator gtkwave yosys riscv64-elf-gcc riscv64-elf-newlib \
               riscv64-elf-binutils base-devel python
```

**Debian / Ubuntu:**

```sh
sudo apt install verilator gtkwave yosys gcc-riscv64-unknown-elf \
                 build-essential python3
```

Check what the build system found:

```sh
make tools
```

The Makefile auto-detects the cross compiler and sets `RISCV_PREFIX`. If your
toolchain lives somewhere unusual, override it:

```sh
make RISCV_PREFIX=/opt/riscv/bin/riscv32-unknown-elf- test
```

---

## 5. Quick start

From a clean clone:

```sh
git clone git@github.com:Adithya010605/BigLittleSOC.git
cd BigLittleSOC

make riscv-tests-fetch      # pull third_party/riscv-tests (once)
make tools                  # confirm the toolchain is complete
make test                   # the full acceptance gate
```

`make test` is the gate. It runs, in order:

```
lint → unit → asm-tests → riscv-tests → sw-tests → random → mutation → coverage
```

and must finish green with zero warnings. The randomised and mutation stages
dominate the runtime — expect tens of minutes on a laptop.

**For a fast sanity pass** (a couple of minutes) while you are developing:

```sh
make lint unit asm-tests riscv-tests sw-tests
RANDOM_NPROG=20 RANDOM_NSEED=1 make random
```

`make help` lists every target with a one-line description.

---

## 6. How to run everything

### Targets

| Target | What it does |
|---|---|
| `make help` | list all targets |
| `make tools` | report toolchain state and detected cross compiler |
| `make lint` | `verilator --lint-only -Wall` over all of `rtl/` — must be silent |
| `make unit` | build + run every unit testbench in `tb/unit/` |
| `make e_core` | build the Verilator integration simulator only |
| `make asm-tests` | run the directed assembly tests in `tb/asm/`, at 4 memory latencies each |
| `make sw-tests` | compile and run the C programs in `sw/tests/`, diff against `.expected` |
| `make riscv-tests` | run the official `rv32ui-p` compliance suite |
| `make random` | randomised lockstep against the golden ISS |
| `make mutation` | inject faults into the RTL, prove the tests catch them |
| `make coverage` | coverage build + line/toggle report |
| `make synth` | Yosys area estimate (fetches `sv2v` if needed) |
| `make wave TEST=<name>` | rerun one test with tracing → `build/<name>.vcd` |
| `make riscv-tests-fetch` | clone `third_party/riscv-tests` |
| `make clean` | remove `build/` |
| `make test` | **the acceptance gate** — everything above that matters |

### Knobs

These are environment variables; pass them on the `make` line.

| Variable | Default | Effect |
|---|---|---|
| `RISCV_PREFIX` | auto-detected | cross-compiler prefix |
| `VERILATOR` / `YOSYS` / `PYTHON` | `verilator` / `yosys` / `python3` | tool binaries |
| `RANDOM_NPROG` | `200` | random programs generated for lockstep |
| `RANDOM_NSEED` | `3` | seeds per program (200 x 3 x {0, random} waits = 1,200 runs) |
| `RISCV_TESTS_SKIP` | `fence_i ma_data` | compliance tests excluded by design (see §8) |
| `COVERAGE_RANDOM_CAP` | `120` | cap on random programs during the coverage run |
| `WAITS` | `0` | wait-state profile for `make wave` |
| `MAX_CYCLES` | `1000000` | simulation timeout guard for `make wave` |

The directed assembly tests always run at all four latency profiles
(`0`, `2`, `random:1`, `random:7`); that list is fixed in `scripts/run_asm.sh`,
not an environment knob.

### Looking at waveforms

```sh
make wave TEST=hazard_load_use
gtkwave build/hazard_load_use.vcd
```

`TEST` accepts the basename of anything in `tb/asm/` or `sw/tests/`.

### Regenerating the slide deck

```sh
pip install python-pptx
python3 presentation/generate_a1_ppt.py                 # writes next to the script
python3 presentation/generate_a1_ppt.py /path/out.pptx  # or wherever you want it
```

---

## 7. How the verification is put together

There are six independent layers, deliberately so — each one catches a class of
bug the others structurally cannot.

1. **Lint.** `verilator --lint-only -Wall` across all RTL, zero warnings, no
   waivers. Catches width mismatches, inferred latches, unused signals.

2. **Unit tests** (`tb/unit/`). One C++ Verilator harness per module in
   `rtl/common/`: ALU, regfile, immediate generator, decoder, CSR unit, LSU.
   These are exhaustive or near-exhaustive — 45.7 million checks in total —
   because these blocks are small enough to brute-force their input space.

   > Note: `make unit` prints a small number per module (`alu PASS (7 checks)`).
   > That is the count of *test groups*, not individual checks. The real tally is
   > in `build/unit/<module>.log` on the `---- module: N checks ----` line —
   > 45,440,523 of the 45.7M are `tb_decoder` alone, which sweeps 2M random
   > words plus every legal encoding field-by-field.

3. **Directed assembly** (`tb/asm/`). Thirteen hand-written, self-checking
   programs aimed at specific pipeline behaviour: RAW hazards, load-use
   interlocks, branch hazards, jump-and-link, misaligned access traps, illegal
   encodings, writes to `x0`, CSR access, performance counters, timer
   interrupts, exception entry and `MRET`. Each is run at four memory latency
   profiles, so back-pressure is exercised on every path.

4. **Compliance** (`third_party/riscv-tests`). The official `rv32ui-p` suite,
   re-linked at `0x0000_0000`. This is the external check that the core is
   actually RV32I and not merely self-consistent.

5. **Randomised lockstep** (`scripts/gen_random_prog.py` + the golden ISS in
   `tb/integration/golden_iss.cpp`). 600 randomly generated programs are run on
   both the RTL and an independently written C++ instruction-set simulator, and
   every retired instruction's architectural state is compared. Run at zero and
   at random wait states = 1,200 runs. This is what finds the bugs the directed
   tests were never shaped to look for.

6. **Mutation testing** (`scripts/mutation_test.sh`). Deliberately breaks the
   RTL 23 different ways and checks the test suite notices. 16 mutations are
   killed; the other 7 are documented equivalent mutants — changes that provably
   cannot alter behaviour. This is the test that tests the tests.

Coverage is measured on top of all of it: **100% line coverage** on both
`rtl/common` and `rtl/e_core`, and 82% toggle coverage, with every unhit toggle
itemised and justified in the verification plan.

---

## 8. Results

All numbers from `make test` and `make synth`; the methodology is in
[`docs/e_core_results.md`](docs/e_core_results.md).

### Acceptance gate

| Gate | Result |
|---|---|
| `verilator --lint-only -Wall` | 0 warnings, no waivers |
| Unit tests (6 modules) | 45.7M checks, all passing |
| Directed assembly (13 tests) | 300 checks, each run at 4 memory latencies |
| `rv32ui-p` compliance | **40 passed, 0 failed**, 2 documented skips |
| Randomised lockstep vs golden ISS | 600 programs × {0, random} waits = 1,200 runs |
| Mutation testing | 23 mutations: 16 killed, 7 documented equivalents |
| Line coverage | **100%** on `rtl/common` and `rtl/e_core` |
| Toggle coverage | 82% — shortfall itemised in the verification plan |

**The two skipped compliance tests are specification, not defects:**

- `fence_i` — needs an instruction cache to be meaningful. This core has none,
  so `FENCE.I` is an architectural NOP and the test cannot tell a correct
  implementation from a broken one. Decoder handling of `FENCE`/`FENCE.I` is
  checked in `tb_decoder` instead.
- `ma_data` — expects hardware fixup of misaligned accesses. This core traps
  them by design, and the test installs no handler. Covered instead by
  `tb/asm/mem_align.S` and the misaligned cases in `tb/asm/trap_exceptions.S`,
  which check `mcause`, `mtval`, `mepc`, and that a faulting store leaves memory
  untouched.

### Performance

Zero wait states, cycles and instructions read from the core's own `mcycle` and
`minstret`, including startup code.

| Program | Cycles | Retired | CPI | What it stresses |
|---|---:|---:|---:|---|
| `hello` | 675 | 487 | 1.386 | boot path, UART store/poll loop |
| `bubble_sort` | 12,523 | 10,075 | **1.243** | load-use interlocks and branches |
| `memcpy_test` | 298,242 | 235,936 | 1.264 | every alignment through the LSU |
| `fib` | 511,036 | 473,764 | 1.079 | recursion, stack traffic, deep dependence chains |
| `perf_counters` | 14,999 | 11,726 | 1.279 | the counter workload below |

Where the overhead goes, measured on a 24-element bubble sort with the core's own
counters (CPI 1.39 over that window):

| Contribution | Cycles/instruction |
|---|---:|
| Taken-branch flushes (400 taken / 1,783 retired) | 0.22 |
| Stall cycles (load-use, CSR-use, memory back-pressure) | 0.15 |
| Pipeline fill after reset | remainder |
| **Total over ideal 1.0** | **0.39** |

That profile — 32% branches, 70% of them taken, one flush each — is exactly what
a static-not-taken machine looks like, and **it is the number the Phase 2 P-core's
branch predictor has to beat.**

### Area (Xilinx 7-series, `synth_xilinx -family xc7 -flatten`)

| Resource | Count |
|---|---:|
| **LUTs (LUT1–LUT6)** | **2,273** |
| Flip-flops (FDCE) | 968 |
| Distributed RAM (RAM32M) | 12 |
| Carry chains (CARRY4) | 146 |
| Wide muxes (MUXF7 / MUXF8) | 147 / 58 |

2,273 LUTs against the plan's < 5K target, with 55% headroom. The 12 RAM32M
primitives are the register file inferring as distributed RAM — the payoff from
deliberately not resetting it. Of the 968 flops, 384 bits are the 64-bit
performance counters; that is a deliberate cost, because those counters are what
make the Phase 2 comparison measurable.

This is an area estimate with no timing constraint and no place-and-route, so it
is not a frequency result.

---

## 9. Programming model and memory map

**ISA:** RV32I + Zicsr, machine mode only. No M extension — multiply and divide
are done in software by libgcc. No compressed instructions. Misaligned loads and
stores trap rather than being fixed up in hardware.

**Memory map** as modelled by the testbench (`tb/integration/memory_model.cpp`):

| Range | Contents |
|---|---|
| `0x0000_0000` – `0x0000_FFFF` | Code and read-only data (64 KiB) |
| `0x0001_0000` – `0x0002_FFFF` | Data, BSS, heap, stack (128 KiB) |
| `0x0002_FFF0` | Initial stack pointer |
| `0x1000_0000` | UART transmit data (write) |
| `0x1000_0004` | UART status (read; bit 0 = busy) |
| `0x1100_0000` – `0x1100_000C` | Interrupt controller (testbench only) |
| anything else | Unmapped — raises an access fault |

Reset vector is `0x0000_0000`. Interrupt causes: machine software 3, machine
timer 7, machine external 11.

**Writing a new test program.** Drop a `.c` file in `sw/tests/` with a matching
`.expected` file holding its UART output, and `make sw-tests` picks it up. For
assembly, drop a `.S` in `tb/asm/` using the self-checking macros in
`tb/asm/test_macros.h`, and `make asm-tests` picks it up. Neither needs a
Makefile edit.

Full instruction encodings, the CSR map, trap priority and the top-level port
list are in [`docs/E_CORE_REFERENCE.md`](docs/E_CORE_REFERENCE.md).

---

## 10. Design decisions worth knowing

Each is argued in full in the microarchitecture document. The short versions,
because they are the ones that will surprise you when reading the RTL:

- **Branches resolve in ID, not EX.** A dedicated comparator and target adder
  cost one adder each but halve the taken-branch penalty to a single cycle.

- **The register file is deliberately not reset.** That is what lets it infer as
  distributed RAM rather than 1,024 flip-flops, and synthesis confirms it
  (12 RAM32M primitives). Do not "fix" this.

- **The IF stage has a one-entry skid buffer.** Without it, refusing to fetch
  until IF/ID is empty caps throughput at 0.5 IPC even with a zero-latency
  memory.

- **The fetch address is a separate register from the PC**, so a branch redirect
  cannot change the address of a request the memory has already accepted.

- **Loads and stores are not interruptible**, because a memory access commits at
  the bus on grant; taking an interrupt there would re-execute it after `MRET`.

- **The memory ports permit a same-cycle response**, because that is what a cache
  hit looks like — the whole point of the protocol is that the core drops behind
  a cache in Phase 4 without change.

---

## 11. Documentation index

**Start here:** [`docs/E_CORE_REFERENCE.md`](docs/E_CORE_REFERENCE.md) — the
complete technical reference in one file (1,086 lines): architecture, the full
instruction set with encodings, CSR map, trap model, memory interface,
performance, area, verification, and the top-level port list.

Then, by topic:

| Document | What is in it |
|---|---|
| [`RISC-V_SoC_Project_Plan.md`](RISC-V_SoC_Project_Plan.md) | the whole SoC: both project variants, the unified build argument, phase-by-phase roadmap, timeline, reference papers, toolchain setup, verification strategy, deliverables checklist, risk analysis |
| [`docs/e_core_microarchitecture.md`](docs/e_core_microarchitecture.md) | datapath, hazard and stall tables, trap priority, CSR map, design justifications |
| [`docs/e_core_verification_plan.md`](docs/e_core_verification_plan.md) | test matrix, coverage numbers, known limitations |
| [`docs/e_core_results.md`](docs/e_core_results.md) | compliance pass table, CPI, stall breakdown, area estimate, methodology |
| [`docs/lab_notebook.md`](docs/lab_notebook.md) | design decisions and debugging log, one entry per session, with the root cause of every bug found |

The P-Core's documents (`docs/p_core_microarchitecture.md`,
`docs/p_core_verification_plan.md`, `docs/p_core_results.md`,
`docs/p_core_panel_presentation.md`) are on the `docs/p-core-presentation`
branch; see §1.1.

---

## 12. Presentation

`presentation/` holds the project slide decks and the script that builds them:

| File | What it is |
|---|---|
| `Project_A1_bigLITTLE_SoC_Presentation.pptx` | the full project deck |
| `Project_A1_Minimal_Format_Presentation.pptx` | minimal-format version |
| `generate_a1_ppt.py` | regenerates the minimal deck from code (`python-pptx`) |

Editing the generator rather than the `.pptx` keeps the deck reproducible and
diffable. See §6 for how to run it.

---

## 13. Working on this as a team

**Branching.** `main` stays green. Work on a branch named for the phase or the
thing you are building — `phase2/p-core-pipeline`, `fix/lsu-halfword-store` —
and open a PR.

**The rule for merging:** `make test` passes with zero warnings. Not "passes
except for", not "passes locally with one flake". The gate exists so that when
something breaks in Phase 4, you know it broke in Phase 4.

**Adding RTL.** New modules go in `rtl/common/` if they are shared, `rtl/<block>/`
if they belong to one block. Every new `rtl/common/` module gets a unit testbench
in `tb/unit/` before it gets integrated — that is why the unit layer catches what
it does.

**Adding tests.** See §9 — assembly and C tests are picked up automatically from
their directories, so adding coverage never means touching the Makefile.

**Keep the lab notebook current.** `docs/lab_notebook.md` gets one entry per
working session: what you tried, what broke, what the root cause turned out to
be. It is the most useful document in the repo for whoever debugs this next, and
that person is usually you in three weeks.

**Don't commit `build/`.** It is gitignored; if you find yourself fighting it,
you are probably running make from the wrong directory.

---

## 14. Roadmap

**Phase 2, the P-Core, is complete** on the `docs/p-core-presentation` branch
(§1.1), and merging it into `main` is the next step. It reused the E-Core's
core-agnostic verification infrastructure (golden ISS, random generator,
mutation harness, memory model) and its memory-port protocol, and it is
measured against the E-Core's baseline in the comparison table in §1.1.

Next, Phase 3 builds the interconnect that both cores plug into, and the
project starts being a SoC rather than a processor. Full detail, including the
timeline and risk analysis, in
[`RISC-V_SoC_Project_Plan.md`](RISC-V_SoC_Project_Plan.md).

---

## 15. Troubleshooting

**`make tools` reports no cross compiler.** Install one of the prefixes listed
in §4, or pass `RISCV_PREFIX=` explicitly. A `riscv64-*` toolchain is fine — the
Makefile builds for `rv32i_zicsr`/`ilp32` regardless.

**Verilator errors about unknown flags or missing headers.** You are on
Verilator 4.x. Upgrade to 5.x; there is no workaround.

**`make riscv-tests` finds nothing.** Run `make riscv-tests-fetch` first — the
suite is an external checkout, not vendored.

**`make synth` fails to parse the RTL.** Yosys's Verilog front end cannot handle
enums and packed structs in port lists, which this design uses throughout. The
flow lowers the sources with `sv2v` first; `scripts/synth_estimate.sh` fetches
the static binary into `build/tools/` automatically and needs no root. If your
network blocks that, install `sv2v` yourself and put it on `PATH`.

**A test passes at 0 wait states and fails at 7.** That is a back-pressure bug
and it is a real one — the memory port protocol allows arbitrary latency.
`make wave TEST=<name>` and look at the `valid`/`ready` handshake.

**Everything is suddenly failing after a pull.** `make clean` first. The build
directory caches Verilator-generated C++, and a package change can leave it stale.
