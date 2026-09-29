# P-Core Results

All figures from `make test` (log: `docs/logs/make_test_2026-09-26.log`, clean
build, 9m37s) and `make synth`, 2026-09-26, Verilator 5.052, Yosys, GCC 15.2
(`riscv64-elf`).

## 1. Exit criteria (plan, Phase 2)

| Criterion | Result |
|---|---|
| passes rv32ui | **41/41** run pass (incl. `fence_i`); `ma_data` skipped by spec |
| passes rv32um | **8/8** |
| runs Dhrystone with measurable IPC | **yes**, results verified; CPI 1.181 (IPC 0.847), 0.919 DMIPS/MHz |

## 2. Regression summary

| Gate | E-core | P-core |
|---|---|---|
| lint `-Wall`, both RVFI elaborations | 0 warnings | 0 warnings |
| unit benches (shared + own) | pass | pass (P-core units: 3.08M checks; decoder RV32M: 50.7M) |
| directed asm × 5 latency configs | 13/13 | 20/20 |
| compliance, zero + random latency | 40 pass, 2 skip | 49 pass, 1 skip |
| C programs | 6/6 | 6/6 |
| random lockstep vs golden ISS | 600 × 2 | 600 × 2 (RV32IM + JALR/trap constructs) |
| mutation | 16 killed, 7 equiv | 30 killed, 2 equiv, 0 unexplained |
| line coverage | 100% / 100% | 100% (common) / 100% (p_core + trap) |
| toggle coverage | 81.3% / 82.6% | 82.0% / 83.2% |

## 3. Performance comparison (zero wait states, same clock)

## Dhrystone 2.1, 500 runs, zero wait states

| Metric | E-core (RV32I, 3-stage) | P-core (RV32IM, 5-stage) |
|---|---|---|
| cycles | 337537 | 309584 |
| instret | 277029 | 262032 |
| CPI | 1.218 | 1.181 |
| cycles_per_run | 675.074 | 619.168 |
| DMIPS_per_MHz | 0.843 | 0.919 |
| stalls | 13006 | 29500 |
| branches | 48501 | 43501 |
| taken | 30000 | 29000 |
| mispredicts | 0 | 9026 |
| md_busy | 0 | 17500 |
| interlock | 0 | 12000 |

Speed-up (E-core cycles / P-core cycles): **1.09x**

## C test programs, whole-program cycles, zero wait states

| Program | E-core cycles | E-core instret | P-core cycles | P-core instret | Speed-up |
|---|---|---|---|---|---|
| add_demo | 4915 | 3703 | 3893 | 2944 | 1.26x |
| bubble_sort | 12523 | 10075 | 7113 | 5819 | 1.76x |
| fib | 511036 | 473764 | 500623 | 470300 | 1.02x |
| hello | 675 | 487 | 631 | 487 | 1.07x |
| memcpy_test | 298242 | 235936 | 240549 | 235936 | 1.24x |
| perf_counters | 14999 | 11726 | 7767 | 5598 | 1.93x |

Reading the numbers:

* **Dhrystone, 1.09×.** The P-core executes 5% fewer instructions (hardware
  multiply/divide instead of libgcc) and has a lower CPI, but the E-core is a
  strong baseline per clock: it resolves branches in ID for a 1-cycle
  penalty, where the P-core pays 2 cycles per mispredict. Dhrystone mispredicts
  18 times per run (returns ≈44%, BTB conflicts on JALs ≈28%, branches ≈28%).
* **Multiply/divide-heavy code, up to 1.93×** (`perf_counters`, `bubble_sort`):
  the win of the M extension.
* **`memcpy_test`, 1.24× with identical instruction counts**: the no-stall
  load→store path and predicted loop branches.
* **Clock frequency is not measured** (no place-and-route tool; see the
  verification plan §4). A 5-stage pipeline's usual main benefit is a higher
  Fmax; that is the open question for FPGA bring-up in Phase 8.

## 4. Area (Yosys `synth_xilinx`, 7-series, estimate)

| Resource | E-core | P-core |
|---|---:|---:|
| LUTs (LUT1–6) | 2,249 | 5,273 |
| flip-flops | 968 | 1,907 |
| CARRY4 | 152 | 383 |
| MUXF7 / MUXF8 | 143 / 49 | 992 / 278 |
| RAM32M (register file) | 12 | 12 |
| RAM64M (BHT + BTB) | 0 | 23 |

The P-core is 2.3× the E-core in LUTs. The plan's "< 5K LUTs" target is the
E-core's; the plan sets no P-core target, but the P-core at 5.3K LUTs fits
comfortably in any Artix-7 part. Its extra state is the four pipeline
registers, the multiplier's and divider's 64-/32-bit iteration registers,
three more 64-bit counters and the BTB valid bits; the predictor tables infer
as distributed RAM as intended. (The E-core's figure differs slightly from the
earlier 2,273 because sv2v is now run with `SYNTHESIS` defined; see the lab
notebook.)

## 5. Suggested next steps

1. FPGA place and route of both cores to measure Fmax — the one missing number
   in the E/P comparison.
2. A small return-address stack (the largest mispredict source) and a
   2-way BTB, if the plan is extended beyond its BHT + BTB specification.
3. Phase 3: L1 caches behind the existing valid/ready ports.
