# E-Core Results

**Status:** skeleton written at M0. All numbers below are produced by the build
system and are filled in at M6 (compliance), M7 (benchmarks) and M8 (area).
These figures are the baseline for the P-core comparison in Phase 2, so the
methodology section is written before the numbers.

## 1. Methodology

- **Cycle counts** come from the core's own `mcycle` CSR, read by the testbench
  at simulation exit, not from testbench-side cycle counting. `mcountinhibit` is
  zero throughout, so `mcycle` counts every cycle from reset deassertion.
- **Instruction counts** come from `minstret`, which increments only on retired
  instructions — never on flushed instructions or stall bubbles.
- **CPI** is `mcycle / minstret` over the whole program including startup code.
- **Stall breakdown** comes from the custom performance counters
  `mhpmcounter3..6` (stall cycles, branch instructions, taken branches,
  load/store count); their exact counting semantics are defined in
  `docs/e_core_microarchitecture.md` section 6.
- All benchmark numbers are taken at **zero wait states** so that they measure
  the core rather than the memory model. Wait-state runs exist to prove
  correctness under back-pressure, not to produce performance figures.
- **Area** is reported by Yosys from `syn/e_core_synth.ys`: a generic cell count
  and, where the Xilinx cell library is available, a 7-series LUT/FF count.

## 2. rv32ui-p compliance results

The full `rv32ui-p` suite from `third_party/riscv-tests`, re-linked at
`0x0000_0000` with `sw/common/riscv_tests.ld` (the only change from the
upstream `env/p/link.ld` is the base address). Run at zero wait states.

**40 passed, 0 failed, 2 skipped.**

| Test | Status | Notes |
|---|---|---|
| simple | PASS | cycles=102 instret=77 |
| add | PASS | cycles=542 instret=501 |
| addi | PASS | cycles=310 instret=278 |
| and | PASS | cycles=562 instret=521 |
| andi | PASS | cycles=266 instret=234 |
| auipc | PASS | cycles=122 instret=94 |
| beq | PASS | cycles=379 instret=327 |
| bge | PASS | cycles=406 instret=345 |
| bgeu | PASS | cycles=431 instret=370 |
| blt | PASS | cycles=379 instret=327 |
| bltu | PASS | cycles=404 instret=352 |
| bne | PASS | cycles=381 instret=327 |
| fence_i | SKIP | documented exclusion |
| jal | PASS | cycles=119 instret=91 |
| jalr | PASS | cycles=189 instret=151 |
| lb | PASS | cycles=323 instret=289 |
| lbu | PASS | cycles=323 instret=289 |
| lh | PASS | cycles=339 instret=305 |
| lhu | PASS | cycles=348 instret=314 |
| lw | PASS | cycles=353 instret=319 |
| ld_st | PASS | cycles=1169 instret=999 |
| lui | PASS | cycles=127 instret=101 |
| ma_data | SKIP | documented exclusion |
| or | PASS | cycles=565 instret=524 |
| ori | PASS | cycles=273 instret=241 |
| sb | PASS | cycles=536 instret=490 |
| sh | PASS | cycles=589 instret=543 |
| sw | PASS | cycles=596 instret=550 |
| st_ld | PASS | cycles=545 instret=519 |
| sll | PASS | cycles=570 instret=529 |
| slli | PASS | cycles=309 instret=277 |
| slt | PASS | cycles=536 instret=495 |
| slti | PASS | cycles=305 instret=273 |
| sltiu | PASS | cycles=305 instret=273 |
| sltu | PASS | cycles=536 instret=495 |
| sra | PASS | cycles=589 instret=548 |
| srai | PASS | cycles=324 instret=292 |
| srl | PASS | cycles=583 instret=542 |
| srli | PASS | cycles=318 instret=286 |
| sub | PASS | cycles=534 instret=493 |
| xor | PASS | cycles=564 instret=523 |
| xori | PASS | cycles=275 instret=243 |


### Skipped tests, and why

Both exclusions follow from this core's specification rather than from a
defect, and both cover behaviour that is tested elsewhere.

| Test | Reason |
|---|---|
| `fence_i` | Requires an instruction cache to be meaningful. This core has none, so `FENCE.I` is an architectural NOP and the test cannot distinguish a correct implementation from a broken one. The decoder's handling of both `FENCE` and `FENCE.I` — accepted as NOPs, never trapped — is checked in `tb_decoder`. |
| `ma_data` | Exercises misaligned loads and stores and expects the hardware to complete them. This core traps misaligned accesses by design (specification section 2.4: *"Misaligned accesses raise exceptions; do not implement hardware misalignment fixup"*), and the test installs no handler to emulate them, so it cannot pass. The behaviour is covered instead by `tb/asm/mem_align.S` (every width at every legal alignment) and by the misaligned LW/LH/SW/SH cases in `tb/asm/trap_exceptions.S`, which check cause, `mtval` and `mepc` and that a faulting store leaves memory unchanged. |

## 3. Benchmark results

All figures at zero wait states. Cycles and retired instructions are read from
the core's own `mcycle` and `minstret`, sampled by the testbench at simulation
exit, so they include the startup code in `sw/common/start.S`.

| Program | Cycles | Retired | CPI | What it stresses |
|---|---:|---:|---:|---|
| `hello` | 675 | 487 | 1.386 | boot path, UART store/poll loop |
| `bubble_sort` | 12,523 | 10,075 | 1.243 | load-use interlocks and branches, the plan's named hazard exercise |
| `memcpy_test` | 298,242 | 235,936 | 1.264 | every source/destination alignment through the LSU |
| `fib` | 511,036 | 473,764 | 1.079 | recursion: call/return, stack traffic, deep dependence chains |
| `perf_counters` | 14,999 | 11,726 | 1.279 | the counter workload below |

`fib` has the lowest CPI because recursive Fibonacci is dominated by
straight-line arithmetic and calls, which sustain close to 1 IPC. `hello` has
the highest because it is short enough that the startup code and the fetch
pipeline fill dominate.

### 3.1 Instruction mix and stall breakdown

Measured by `sw/tests/perf_counters.c` over a 24-element bubble sort, using the
core's own performance counters. The measurement window is bracketed by two
counter samples, so startup is excluded.

| Counter | CSR | Value |
|---|---|---:|
| Cycles | `mcycle` | 2,481 |
| Instructions retired | `minstret` | 1,783 |
| Stall cycles | `mhpmcounter3` | 276 |
| Branches retired | `mhpmcounter4` | 575 |
| Branches taken | `mhpmcounter5` | 400 |
| Loads and stores | `mhpmcounter6` | 812 |

Derived:

| Metric | Value | Note |
|---|---:|---|
| CPI | 1.39 | |
| Stall cycles per instruction | 0.15 | S2 held back: load-use and CSR-use interlocks, plus memory back-pressure |
| Branch instructions | 32.2% of retired | conditional branches only; jumps are not counted |
| Branch taken rate | 69.6% | each taken branch costs a 1-cycle flush |
| Loads and stores | 45.5% of retired | |

**Where the 0.39 cycles of overhead per instruction go.** Taken branches
contribute `400 / 1783 = 0.22` cycles per instruction, since each costs exactly
one flushed cycle. Stalls contribute `276 / 1783 = 0.15`. Together that is
0.37, which accounts for essentially all of the 0.39 gap between the measured
CPI and the ideal 1.0; the small remainder is the pipeline fill after reset.

This is the expected profile for a static-not-taken machine on a
branch-dominated workload, and it is the specific number the P-core's branch
predictor has to beat in Phase 2.

### 3.2 Counter semantics

Defined in `rtl/common/csr_unit.sv` and asserted by `tb/asm/csr_perf.S`:

| Counter | Increments on |
|---|---|
| `mcycle` | every cycle, unless `mcountinhibit.CY` |
| `minstret` | an instruction retiring; never a flushed instruction or a stall bubble; unless `mcountinhibit.IR` |
| `mhpmcounter3` | a cycle in which S2 held a valid instruction back |
| `mhpmcounter4` | a retired conditional branch (jumps excluded) |
| `mhpmcounter5` | a retired conditional branch whose condition was true |
| `mhpmcounter6` | a retired load or store |

`mhpmcounter3` measures *blocked work*, not idle time: if S2 has nothing to
hold back — because the instruction fetch has not returned yet — no stall is
counted. That distinction matters when comparing across memory latencies, and
it is why `csr_perf.S` asserts the counter over a loop rather than over a
single load-use pair.

## 4. Area estimate

Produced by `make synth`. Yosys's built-in Verilog front end cannot parse
enumerated or packed-struct types in port lists, which this design uses
throughout, so the sources are first lowered to Verilog-2005 with `sv2v` — a
purely syntactic transformation. `scripts/synth_estimate.sh` fetches the `sv2v`
static binary into `build/tools/` if it is not already on PATH; it needs no
root.

### 4.1 Xilinx 7-series (`synth_xilinx -family xc7 -flatten`)

| Resource | Count |
|---|---:|
| **LUTs (LUT1–LUT6)** | **2,273** |
| Flip-flops (FDCE) | 968 |
| Distributed RAM (RAM32M) | 12 |
| Carry chains (CARRY4) | 146 |
| Wide muxes (MUXF7 / MUXF8) | 147 / 58 |

**2,273 LUTs against the plan's < 5K target**, with 55% headroom.

**The register file inferred as distributed RAM, which was the point.** Twelve
RAM32M primitives hold the 32 x 32-bit array. Had it been reset — the
conventional thing to do — it would have become 1,024 flip-flops instead, more
than doubling the flop count and consuming LUT-RAM headroom the design does not
otherwise need. This is the single design decision the plan's section 4.8 warns
about, and the number confirms it went the right way.

**Where the 968 flip-flops go.** The counters dominate: `mcycle` and `minstret`
are 64-bit and the four `mhpmcounter`s are 64-bit each, which is 384 bits — a
little under 40% of all state in the core — before any pipeline register is
counted. That is a deliberate cost: those counters are what make the Phase 2
P-core comparison measurable. Narrowing them to 32 bits would save roughly 192
flops if area ever became tight.

### 4.2 Generic (technology-independent)

The generic pass reports 392 cells at the top level plus five submodules, with
the flip-flop counts split across the stage modules. Full output is in
`build/synth/generic_stat.txt`; it is included because cell counts are
comparable across Yosys versions in a way that the Xilinx numbers are not.

### 4.3 Methodology notes

- The estimate is of `e_core_top` alone with `RVFI = 0`, which is the
  synthesis configuration; with `RVFI = 1` the trace port is driven and the
  logic is retained.
- No timing constraint is applied and no place-and-route is run, so this is an
  area estimate, not a frequency result. Reproducing it requires only
  `make synth`.
