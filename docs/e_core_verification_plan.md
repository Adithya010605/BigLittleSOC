# E-Core Verification Plan

**Status:** skeleton written at M0. The test matrix is populated as tests are
written (M1–M7); coverage numbers and uncovered-line justifications are final at
M8.

## 1. Verification strategy

Four levels, mirroring section 9.1 of the project plan:

1. **Unit** — one C++ Verilator harness per module in `rtl/common/`, each
   combining directed corner cases with randomised vectors checked against a
   C++ reference model.
2. **Directed integration** — hand-written self-checking assembly in `tb/asm/`,
   targeting specific hazard, branch, trap and CSR behaviours.
3. **Compliance** — the upstream `rv32ui-p` suite from `riscv-tests`.
4. **Randomised lockstep** — constrained-random programs run simultaneously on
   the RTL and a C++ architectural ISS, compared instruction by instruction at
   retirement.

Every integration-level test runs at both zero wait states and randomised wait
states, so memory back-pressure is exercised continuously rather than in a
single dedicated test.

## 2. Test matrix

### 2.1 Unit level (`make unit`)

Every harness pairs directed corner cases with randomised vectors checked
against a reference model written from the ISA specification rather than from
the RTL, so that a transcription error cannot appear identically in both.

| Test | Module | Features covered | Checks | Status |
|---|---|---|---:|---|
| `tb_alu` | `alu.sv` | all 10 operations; add/sub wraparound at the 32-bit boundary; shift by 0, 1 and 31; shift-amount masking to `b[4:0]`; SRA sign propagation vs SRL; SLT vs SLTU across sign boundaries; `cmp_eq`/`cmp_lt`/`cmp_ltu` outputs; 10k biased-random vectors | 19,091 | pass |
| `tb_regfile` | `regfile.sv` | x0 reads zero on both ports and is never written; write/readback of all 31 writable registers; read-port independence; write-first bypass on port A, port B, and both at once; bypassed value commits to storage; write enable respected; 20k random read/write cycles against a shadow model | 40,140 | pass |
| `tb_imm_gen` | `imm_gen.sv` | all six formats (I/S/B/U/J/Z); sign-extension boundaries; implicit zero LSB of B and J; Z is zero-extended not sign-extended; single-bit sweep across `instr[31:7]`; 50k random instruction words | 50,190 | pass |
| `tb_lsu` | `lsu.sv` | exhaustive {size} x {offset} x {signedness}: byte enables, store-data placement, load extraction and extension, misalignment; LB/LH sign extension vs LBU/LHU zero extension; stores reconstructed through the byte enables the way a real memory would; 30k random accesses | 138,934 | pass |
| `tb_decoder` | `decoder.sv` | every legal RV32I_Zicsr encoding field-by-field; M-extension opcodes trap; reserved funct3 values trap; shift-immediate funct7 checked while other OP-IMM immediates are not; malformed privileged encodings trap; `0x00000000`, `0xFFFFFFFF` and compressed encodings trap; Zicsr read/write side-effect rules over rs1/rd = x0; 2M random words, of which 13.0% were legal | 45,440,523 | pass |

**Safety property asserted for all 2M random decoder words:** an instruction
that asserts `illegal_instr_o` asserts no enable of any kind — no register
write, no memory request, no control transfer, no CSR access, no privileged
action. This is what prevents a trapping instruction from also committing a
side effect.

### 2.2 Directed integration (`make asm-tests`)

Self-checking assembly, one uniquely-numbered check per assertion so a failure
names the exact check. Every test runs at zero wait states and at randomised
wait states.

| Test | Features covered | Checks | Status |
|---|---|---:|---|
| `m2_basic` | addi (immediate extremes, sign extension); add/sub with 32-bit wraparound; and/or; sw/lw round trip with positive and negative offsets and store isolation; beq taken and not taken; backwards-branch loop; jal link register; x0 stays zero when written by jal | 24 | pass |
| `hazard_raw` | RAW forwarding at distance 1 through rs1, through rs2, and with both operands from one producer; five-deep dependent chain; distance-2 and distance-3 controls served by the register file; forwarding a LUI, an AUIPC and a JAL link value; forwarding into a store's data and address operands and into a load's address; a producer writing x0 must not be forwarded | 13 | pass |
| `hazard_load_use` | load-use at distance 1 through rs1 and rs2, each paired with the same computation separated by a NOP; both operands from one load; load feeding a store's data; load feeding the next load's address; back-to-back independent loads; load with rd = x0; three-deep pointer chase; store followed immediately by a load of the same address | 11 | pass |
| `branch_basic` | all six conditions in both directions; signed vs unsigned discrimination with -1 against 1 and INT_MIN against INT_MAX; bge/bgeu with equal operands; back-to-back taken branches; alternating taken/not-taken; a not-taken branch targeting itself; backwards-branch loop; nested loops; a long forward displacement | 26 | pass |
| `branch_hazard` | branches whose comparator operands are produced one instruction earlier, written so a stale value sends control the WRONG WAY rather than merely producing a wrong number; taken and not-taken variants; signed and unsigned on forwarded values; branches depending on the immediately preceding load; JALR whose base comes from an ALU result and from a load | 14 | pass |
| `jump_link` | JAL link value and backwards displacement; JALR link value; JALR bit-0 clearing from the base, from the immediate, and with a negative immediate; JALR where rd and rs1 are the same register; call/return; a jump landing directly on a load-use hazard and on a taken branch | 18 | pass |
| `mem_align` | SB at all four offsets and LB/LBU at all four with sign extension; SH at both aligned offsets with source truncation; LH/LHU sign extension; SW/LW; stores checked by reading the surrounding word so a byte enable stuck at 4'b1111 is caught; byte-wise and halfword-wise fills checked for little-endian lane order | 31 | pass |
| `x0_writes` | x0 as destination of OP-IMM, OP, shift, logical, LUI, AUIPC, all five load widths, JAL and JALR; the discarded value must not reach the forwarding path; x0 as a branch operand and as store data after a write attempt | 21 | pass |

**Every directed test runs at four latency configurations** — `0`, `2`,
`random:1` and `random:7` — and all four must pass. This is part of the pass
criterion rather than an extra, because several defect classes are invisible at
zero wait states: a mishandled wrong-path fetch, a stall term that ignores
`ex_ready`, a skid buffer that drops an instruction. Mutation testing confirms
this directly (§2.5): five mutations are killed only by the fixed or randomised
configurations.

**Harness safeguard.** The comparison macros reserve x31 as scratch and reject
it as the register under test with an assembler `.error`. An early version used
`t0` as scratch without that guard, which made two checks compare the scratch
register against itself and pass unconditionally; see the M2 lab notebook
entry.

_(hazard, branch, trap, CSR and interrupt tests added at M3–M5)_

### 2.3 Compliance (`make riscv-tests`)

_(populated M6)_

### 2.4 Randomised lockstep (`make random`)

_(populated M7)_

### 2.5 Mutation testing (`make mutation`)

A passing regression proves nothing on its own: the design may be correct, or
the tests may simply not exercise what is broken. `scripts/mutation_test.sh`
answers that directly by injecting a specific, realistic RTL defect, rebuilding
the core, and running the whole directed suite at three latency configurations
to see whether anything notices.

Every mutation is a plausible mistake this microarchitecture invites — a
forgotten forward, a value forwarded before it is ready, a dropped x0 write
mask, a lost JALR LSB clear, a mishandled wrong-path fetch — not a random
character swap.

Each mutation is declared `kill` (must be detected) or `equiv` (an equivalent
mutant that no test can possibly detect, with a written justification). The
script fails if a `kill` mutation survives **or** if an `equiv` mutation is
killed, since the latter means the justification is wrong.

**Result at M4: 23 mutations — 16 killed, 7 equivalent, 0 unexpected.**

The seven equivalent mutants all arise because a behaviour is implemented by
two independent mechanisms, so disabling one leaves the other covering it:

| Equivalent mutant | Masked by | Proof that the behaviour *is* tested |
|---|---|---|
| `no_fwd_rs1`, `no_fwd_rs2` | the write-first register file, which is qualified by the same `rf_we_o` and carries the same `rf_wdata` | `no_fwd_no_bypass_all` removes both and is killed by all 8 tests |
| `no_regfile_bypass` | the explicit S3→S2 forward muxes | as above |
| `no_load_use_stall` (clears `ex_result_late`) | un-gates the forward muxes, so load data is then forwarded explicitly | `no_stall_no_bypass` is killed |
| `no_stall_term` (clears `data_hazard_stall` alone) | the register file bypass; the forward muxes still exclude loads | `no_stall_no_bypass` removes both and is killed |
| `no_x0_write_mask` | the read-zero mux on both read ports | `x0_fully_writable` removes both and is killed by 7 tests |
| `x0_reads_storage` | the x0 write mask | as above |

This is the rigorous form of the result: "it survived" is separated from "we do
not test it", and each survivor is paired with a combined mutation that is the
actual evidence the behaviour is covered.

## 3. Coverage

Target: ≥ 95% line and toggle coverage on `rtl/common/` and `rtl/e_core/`,
measured by `make coverage`.

_(numbers and per-line justifications added at M8)_

## 4. Known limitations

_(populated as they are discovered; the `fence_i` exclusion from the compliance
suite is recorded here at M6)_
