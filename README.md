# RISC-V SoC — E-Core, P-Core and the coherent big.LITTLE SoC

The two CPU cores of the big.LITTLE / UMA SoC described in
`RISC-V_SoC_Project_Plan.md`, and the SoC built from them, written in
SystemVerilog-2012 and verified with Verilator: Phases 0–2, the cache
hierarchy with MSI coherence, the QoS system interconnect, and task migration
with power management.

* **E-core** — 3-stage, RV32I_Zicsr, static not-taken, small.
* **P-core** — 5-stage, RV32IM_Zicsr_Zifencei, BHT + BTB branch prediction,
  Booth multiplier and restoring divider.
* **SoC** — 2 P-cores + 2 E-cores, each with private L1 instruction and data
  caches (P: 16 KB 2-way, write-back MSI; E: 8 KB direct-mapped,
  write-through), kept coherent by MSI snooping, a shared inclusive 64 KB L2
  with a snoop filter, and a QoS crossbar to an RTL SRAM, UART, interrupt
  controller and system-control block. See
  [`docs/memory_system.md`](docs/memory_system.md).
* **PMU** — task migration between the clusters (software-requested, or
  automatic on IPC or a power budget; 84 cycles), per-hart sleep with
  wake-on-interrupt, per-core clock gating, a per-cluster clock divider
  (DVFS stub) and per-cluster power domains with L1 flush. See
  [`docs/power_migration.md`](docs/power_migration.md).

Both cores have identical external interfaces (two valid/ready memory ports,
three interrupt pins, RVFI), share the ALU, register file, immediate generator,
LSU, decoder, CSR file and trap unit, and run under the same testbench and
golden ISS. `CORE=e_core` (default) or `CORE=p_core` selects the core for any
per-core target; `CACHED=1` runs that core behind the whole memory system.

## The SoC at a glance

| Property | Value |
|---|---|
| Harts | 0–1 start on the P-cores, 2–3 on the E-cores (`mhartid`), one image for all; harts migrate between cores |
| P-core L1I / L1D | 16 KB, 2-way, 32 B lines, LRU; L1D write-back / write-allocate, MSI |
| E-core L1I / L1D | 8 KB, direct-mapped, 32 B lines; L1D write-through / no-write-allocate |
| Instruction fetch | coherent with every core's stores (`FENCE.I` works behind the caches) |
| L2 | 64 KB, 4-way, pseudo-LRU, write-back, inclusive; a sharer bit per L1 per line is the snoop filter; back-invalidation on eviction |
| Coherence | MSI on an atomic snooping bus: BusRd, BusRdX (cache-to-cache), BusUpgr, write-through, writeback |
| Interconnect | 4 × 6 crossbar, simplified AXI4-Lite, strict priority + round-robin + anti-starvation (16 cycles), QoS registers |
| Slaves | SRAM 192 KB (1-cycle), UART, per-hart interrupt controller, system control (QoS, performance counters), PMU (power, migration) |
| Migration | 39 items (x1–x31, pc, 7 CSRs) through the cores' halt/debug ports, 84 cycles; triggers: software, IPC monitor with hysteresis, P-core power budget |
| Power | clock gating per core and per core's L1s, sleep / wake-on-interrupt, 1/1–1/2–1/4 divider per cluster, cluster power-off with L1 flush |
| Memory model | sequentially consistent (each access performed at acknowledgement) |
| Verification | every load checked against the coherent value in every SoC run, at every core speed; halted state checked against the golden ISS at random halts; 50/50 SoC mutations detected |

## P-core at a glance

| Property | Value |
|---|---|
| ISA | RV32I + M + Zicsr + Zifencei, machine mode only |
| Pipeline | 5 stages: `IF` → `ID` → `EX` → `MEM` → `WB` |
| Branch prediction | 256-entry 2-bit BHT + 64-entry BTB; resolved in EX; 0-cycle correctly-predicted taken branch, 2-cycle mispredict |
| Forwarding | EX→EX, MEM→EX, MEM→MEM (store data); 1-cycle load-use interlock, none for load→store data |
| Multiply / divide | radix-4 Booth 4 cycles / restoring 33 cycles, abandoned on interrupt |
| Traps | precise, at MEM; FENCE.I flushes and refetches |
| Counters | the E-core's four plus mispredicts, MUL/DIV busy cycles, interlock cycles |

Full details: [`docs/p_core_microarchitecture.md`](docs/p_core_microarchitecture.md),
[`docs/p_core_verification_plan.md`](docs/p_core_verification_plan.md),
[`docs/p_core_results.md`](docs/p_core_results.md).

## E-core at a glance

| Property | Value |
|---|---|
| ISA | RV32I + Zicsr, machine mode only (`rv32i_zicsr` / `ilp32`) |
| Pipeline | 3 stages: `IF` → `ID/RF` → `EX/MEM/WB` |
| Branch handling | Resolved in ID, static not-taken, 1-cycle penalty |
| Hazards | Full EX→ID forwarding; 1-cycle stall for load-use and CSR-use |
| Memory interface | Two independent valid/ready ports (Ibex-style), arbitrary latency |
| Traps | All RV32I machine-mode exceptions + timer/software/external interrupts |
| Area | **2,273 LUTs**, 968 FFs, register file in distributed RAM (Xilinx 7-series) |

Full details: [`docs/e_core_microarchitecture.md`](docs/e_core_microarchitecture.md).

## Status

### SoC

| Gate | Result |
|---|---|
| Unit: coherence (`tb_coherent_mem`, `_small`, `_wb4`) | every MSI transition, both waiting-request races, L2 inclusion and back-invalidation, snoop filter, instruction-cache coherence, flush, slow cores; random traffic on all 8 ports, also with cores at 1/2, 1/4 and random speed and flushes mid-traffic |
| Unit: interconnect (`tb_qos_xbar`) | every grant against a reference arbiter (priority, round-robin, anti-starvation, no dead cycles), routing, data, decode errors; 3.5M checks |
| Each core behind the whole system (`make cached-tests`) | directed (incl. `fence_i`), `riscv-tests`, C programs, 600 × 2 random lockstep: all pass, same as the bare cores |
| Multi-core programs (`make soc-tests`) | 20 programs × 6 settings (5 SRAM latencies + checked background traffic), including migration, sleep/wake, DVFS, power domains and automatic migration |
| Halt/debug port (both cores, `--halt-every`) | directed suites, half the random lockstep programs and a quarter of the coverage replay run with random halts: halted state = golden ISS, debug writes read back; 100% line coverage kept |
| Mutation (`make soc-mutation`) | 50 / 50 detected: caches, coherence, L2, interconnect, peripherals, slow-core hold and flush, PMU and migration |


### P-core

See `docs/p_core_verification_plan.md` and `docs/p_core_results.md` for the
full figures. In summary: lint clean in both RVFI elaborations; 5 new unit
benches (≈54M checks); 20 directed tests at 5 latency configurations;
`rv32ui-p` + `rv32um-p` + `fence_i` at zero and random latency; 600 randomised
RV32IM lockstep programs; mutation testing with no unexplained survivors;
100% line coverage; 1.11× faster than the E-core per clock over the C
programs (`make bench`).

### E-core

| Gate | Result |
|---|---|
| `verilator --lint-only -Wall` | 0 warnings, no waivers |
| Unit tests (6 modules) | 45.7M checks, all passing |
| Directed assembly (13 tests) | 300 checks, each run at 4 memory latencies |
| `rv32ui-p` compliance | 40 passed, 0 failed, 2 documented skips |
| Randomised lockstep vs golden ISS | 600 programs x {0, random} waits = 1,200 runs |
| Mutation testing | 23 mutations: 16 killed, 7 documented equivalents |
| Line coverage | **100%** on `rtl/common` and `rtl/e_core` |
| Toggle coverage | 82% — shortfall itemised in the verification plan |
| C benchmarks | hello, fib, bubble_sort, memcpy_test, perf_counters |
| CPI (bubble sort, 0 wait states) | 1.24 |

## Prerequisites

| Tool | Version | Needed for |
|---|---|---|
| Verilator | **5.x** (hard requirement) | all simulation and lint |
| g++ / clang++ | C++17 | testbench harnesses |
| RISC-V cross compiler | any of `riscv32-unknown-elf-`, `riscv64-unknown-elf-`, `riscv32-elf-`, `riscv64-elf-`, `riscv64-linux-gnu-` | assembling and compiling test programs |
| GNU make, python3, git | — | build system, generators |
| yosys | 0.3x+ | `make synth` only |
| sv2v | any | `make synth` only — fetched automatically into `build/tools/` if absent, no root needed |
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

`make test` runs lint and the unit tests, then each core's gate (directed
assembly → compliance → C programs → randomised lockstep → mutation testing →
coverage), E-core then P-core, then the E-core/P-core comparison (`make bench`). It is the gate;
it must be green with zero warnings. `make e-test` / `make p-test` run one
core's gate.

The randomised and mutation stages dominate the runtime. For a quicker pass:

```sh
make lint unit asm-tests riscv-tests sw-tests
RANDOM_NPROG=20 RANDOM_NSEED=1 make random
make CORE=p_core asm-tests riscv-tests sw-tests
```

## SoC targets

```sh
make soc            # build the 2P+2E SoC simulator (build/soc_2p2e_sim)
make soc-tests      # multi-core programs on it
make cached-tests   # every core suite again, behind the whole memory system
make soc-mutation   # mutation testing of caches, coherence, interconnect, peripherals, PMU
make soc-test       # all three: the SoC's gate (part of `make test`)
```

`build/soc_2p2e_sim --elf=PROG.elf --stats` runs any multi-core program and
prints per-cache hit/miss counts, L2 and bus statistics and interconnect
contention; `--waits=random:SEED` slows the SRAM, `--traffic=PCT` adds checked
background traffic on the interconnect.

## Individual targets

| Target | What it does |
|---|---|
| `make tools` | report toolchain state |
| `make lint` | `verilator --lint-only -Wall` over all of `rtl/` |
| `make unit` | build + run every unit testbench in `tb/unit/` |
| `make e_core` / `make p_core` | build that core's Verilator simulator |
| `make asm-tests` | run the directed assembly tests in `tb/asm/` |
| `make sw-tests` | compile and run the C programs in `sw/tests/` |
| `make riscv-tests` | run the rv32ui-p compliance suite |
| `make random` | randomised lockstep against the golden ISS |
| `make mutation` | verify the tests can actually detect broken RTL |
| `make coverage` | coverage build + line/toggle report |
| `make bench` | C programs on both cores + E/P comparison table |
| `make synth` | Yosys area estimate, both cores |
| `make e-test` / `make p-test` | one core's full gate |
| `make wave TEST=<name>` | rerun one test with tracing → `build/<name>.vcd` |
| `make clean` | remove build products |

## Repository layout

```
rtl/common/     ALU, regfile, immediate generator, decoder, CSR unit, LSU, shared package
rtl/e_core/     E-core pipeline stages, hazard unit, trap unit, top level
rtl/p_core/     P-core pipeline stages, predictor, multiplier, divider, hazard unit, top
rtl/cache/      L1 cache (write-back MSI / write-through / instruction), L2 arrays, package
rtl/coherence/  snooping bus + L2 controller; L1s + bus + L2 as one coherent memory system
rtl/interconnect/ QoS crossbar
rtl/periph/     SRAM controller, UART, interrupt controller, system control
rtl/soc/        the 2P+2E big.LITTLE SoC top level
tb/unit/        one C++ Verilator harness per common/ module (p_core/: per P-core
                module; coherence/: the coherent memory system; interconnect/:
                the crossbar)
tb/integration/ core harness, memory model, ELF loader, golden ISS
tb/soc/         SoC harness: program loader, coherence checker, traffic masters
tb/asm/         hand-written self-checking assembly tests (p_core/: P-core only)
sw/common/      startup code (start_mc.S: multi-core), linker scripts, UART driver
sw/tests/       C benchmark programs
sw/soc_tests/   multi-core C programs for the SoC
scripts/        build and regression drivers
syn/            Yosys synthesis script
docs/           microarchitecture, verification plan, results, lab notebook
```

## Documentation

**Start here:** [`docs/E_CORE_REFERENCE.md`](docs/E_CORE_REFERENCE.md) — the
complete technical reference in one file: architecture, the full instruction
set with encodings, CSR map, trap model, memory interface, performance, area
and verification.

- [`docs/e_core_microarchitecture.md`](docs/e_core_microarchitecture.md) — datapath, hazard and stall tables, trap priority, CSR map, design justifications
- [`docs/e_core_verification_plan.md`](docs/e_core_verification_plan.md) — test matrix, coverage numbers, known limitations
- [`docs/e_core_results.md`](docs/e_core_results.md) — compliance pass table, CPI, stall breakdown, area estimate
- [`docs/memory_system.md`](docs/memory_system.md) — caches, MSI coherence, L2 and snoop filter, QoS interconnect, peripherals: design, verification, mutation table and results
- [`docs/lab_notebook.md`](docs/lab_notebook.md) — design decisions and debugging log, one entry per session, with the root cause of every bug found

## Notable design decisions

Each is argued in full in the microarchitecture document; the short version:

- **Branches resolve in ID, not EX.** A dedicated comparator and target adder
  cost one adder each but halve the taken-branch penalty to a single cycle.
- **The register file is deliberately not reset.** That is what lets it infer
  as distributed RAM rather than 1,024 flip-flops, and synthesis confirms it
  (12 RAM32M primitives).
- **The IF stage has a one-entry skid buffer.** Without it, refusing to fetch
  until IF/ID is empty caps throughput at 0.5 IPC even with a zero-latency
  memory.
- **The fetch address is a separate register from the PC**, so a branch
  redirect cannot change the address of a request the memory has already
  accepted.
- **Loads and stores are not interruptible**, because a memory access commits
  at the bus on grant; taking an interrupt there would re-execute it after
  `MRET`.
- **The memory ports permit a same-cycle response**, because that is what a
  cache hit looks like and the point of the protocol is that the core drops
  behind a cache later without change.
