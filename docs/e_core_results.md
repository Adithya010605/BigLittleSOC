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

_(CPI, instruction mix and stall breakdown for hello / fib / bubble_sort /
memcpy_test, at M7)_

## 4. Area estimate

_(Yosys output at M8; plan target is < 5K LUTs)_
