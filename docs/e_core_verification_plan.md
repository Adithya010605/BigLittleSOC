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

| `csr_basic` | CSRRW/S/C and the three immediate forms; CSRRS with rs1=x0 does not write; read-only enforcement, and the legality of a *non-writing* access to a read-only CSR; unimplemented address traps; mcycle/minstret monotonicity; mcountinhibit; counter writability; mstatus.MPP hardwired to machine mode; mtvec mode bits forced to zero | 29 | pass |
| `trap_exceptions` | ECALL, EBREAK, illegal (`0x00000000`, `0xFFFFFFFF`, MUL, DIV), misaligned LW/LH/SW/SH, load and store access faults, instruction access fault via a jump into unmapped memory, instruction-address-misaligned via JALR — each checked for cause, `mtval` **and** `mepc`; a faulting store leaves memory unchanged; byte accesses never fault; execution resumes correctly through MRET | 34 | pass |
| `irq_timer` | interrupt suppressed while `mstatus.MIE` is clear but visible in `mip`; taken as soon as MIE is set; cause encoding for timer/software/external; MIE cleared on entry and restored by MRET; taken mid-loop with the loop result unaffected; masked by `mie` | 10 | pass |
| `illegal_encodings` | every reserved encoding inside an otherwise-valid opcode: LOAD/STORE/BRANCH/JALR/MISC-MEM/SYSTEM reserved funct3, malformed privileged instructions, reserved funct7 on the shift-immediates and on register-register ops, the M extension, reserved major opcodes (OP-FP, AMO), compressed encodings — each must trap with cause 2 and `mtval` equal to the instruction word; FENCE and FENCE.I must **not** trap | 73 | pass |
| `csr_perf` | all four `mhpmcounter`s and their high halves readable and writable; branch, taken-branch, memory and stall counting semantics; `mepc`/`mcause`/`mtval`/`mscratch`/`mtvec`/`mie`/`mcountinhibit`/`mcycleh`/`minstreth` driven with all-zeros and all-ones | 24 | pass |

### 2.3 Compliance (`make riscv-tests`)

_(populated M6)_

### 2.3.1 Compliance results

`make riscv-tests` — **40 passed, 0 failed, 2 skipped.** The full table and the
justification for the two exclusions (`fence_i`, `ma_data`) are in
[`e_core_results.md`](e_core_results.md) section 2.

### 2.4 Randomised lockstep (`make random`)

`scripts/gen_random_prog.py` emits constrained-random RV32I_Zicsr programs and
the harness runs them against `tb/integration/golden_iss.cpp`, comparing PC,
instruction, `pc_next`, destination register and value, and memory address,
byte mask and write data at every retirement.

**Result: 600 programs (200 x 3 seed groups), each run at zero AND randomised
wait states — 1,200 runs, all passing.**

The generator is written to produce programs that are *interesting to a
pipeline* rather than merely legal:

- a six-register hot pool, so read-after-write hazards at distance 1 are
  constant rather than occasional;
- loads and stores at every alignment inside a confined scratch area;
- forward branches and jumps with short displacements;
- counted backward loops;
- occasional CSR accesses and ECALLs, which exercise trap entry and MRET.

**Termination is structural, not hoped for.** Every conditional branch and jump
targets a label forward of itself, so control can only move down the program;
the one backward-branch construct is a counted loop whose counter register is
reserved and decremented by the generator itself, so no random instruction can
touch it. A program therefore cannot loop forever regardless of the values it
computes, which matters because the cycle budget would otherwise turn a
generator bug into a mysterious timeout.

**Two classes of state are deliberately excluded from comparison**, because an
architectural model cannot predict them:

| Excluded | Why | How divergence is prevented |
|---|---|---|
| `mcycle`, `minstret`, `mhpmcounter3..6`, `mip` | count microarchitectural or external events | The ISS *adopts* the RTL's value on such a read rather than merely skipping the check. Skipping alone is not enough: the reference would keep its own differing value and diverge on the next instruction that used it. |
| Interrupts | asynchronous, so the arrival cycle is not architectural | The generator emits no interrupt-driven code; `irq_timer.S` is verified by directed checks instead. |

The lockstep checker also runs against the whole directed suite and all five C
programs, including 473,764 instructions of `fib`.

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

Measured by `make coverage`, which replays 177 programs — the directed
assembly suite, the C programs, the compliance suite and 120 randomised
programs — under a `--coverage` build, alternating between zero and randomised
wait states so the back-pressure paths are exercised too.

| Scope | Kind | Hit | Total | % |
|---|---|---:|---:|---:|
| `rtl/common` | line | 154 | 154 | **100.00%** |
| `rtl/common` | toggle | 4,060 | 5,002 | 81.17% |
| `rtl/e_core` | line | 38 | 38 | **100.00%** |
| `rtl/e_core` | toggle | 7,490 | 9,068 | 82.60% |

### 3.1 Line coverage: 100%, and what it took to get there

Every line of the design is reachable by a program, so the gate is set at
100% rather than 95%: anything less is a real hole. Closing the last gaps
required two changes, and the distinction between them is the useful part.

**A genuine gap.** `e_core_trap.sv`'s instruction-access-fault arm had never
been executed. Load and store access faults were tested; fetching from
unmapped memory was not. `trap_exceptions.S` now jumps into unmapped memory
and checks cause 1, `mtval` and `mepc`. The handler cannot step over the
faulting instruction the way it does for every other exception — `mepc` points
at the unmapped address, so returning would fault forever — and instead
redirects `mepc` to a recovery label.

**A tool artifact, fixed rather than excused.** Eight lines inside the
decoder's `AluFromFunct3` function reported zero hits, while the *expression*
coverage points on the very same lines recorded 2.2 million. The line points
inside an inlined `automatic` function are simply never incremented. Rather
than write a justification for eight lines that provably execute on every
arithmetic instruction, the function was restructured into combinational
logic, which removes the artifact and reads no worse.

There are now **no uncovered lines to justify**.

### 3.2 Toggle coverage: 82%, and why the remainder is unreachable

Toggle coverage counts every *bit* of every signal in both directions. A large,
precisely identifiable share of the points in this design cannot be reached by
any program:

| Signals | Unhit bits | Why unreachable |
|---|---:|---|
| `mie`, `mip` and their fan-out (`csr_unit.sv:49,50,70,75,85`, `e_core_top.sv:126`, `e_core_trap.sv:64,65`) | ~510 | These are 32-bit registers in which only bits 3, 7 and 11 are implemented. The other 29 bits are hardwired to zero by the WARL masking and can never toggle. |
| `mhpm_q` / `mhpm_d` (`csr_unit.sv:81,82`) | 222 | Four 64-bit counters. Their upper halves would need on the order of 2^32 counted events to toggle. |
| `rvfi_order_q` (`e_core_top.sv:62,388`) | 182 | A 64-bit retirement counter, same argument. |
| `pc_d`, `fetch_addr_d`, `ifid_pc_d`, `skid_pc_d`, `idex_pc_next` | ~400 | Every address lives inside a 192 KiB memory, so address bits 18 and above are permanently zero. |

That is roughly 1,300 of the 2,520 unhit points, all of them structurally
unreachable. Raising the raw figure would mean widening the memory map or
running for billions of cycles — neither of which tests anything.

`scripts/cov_summary.py` prints this breakdown automatically, worst signal
first, so the number is justified from data rather than asserted. The gate is
therefore set at 100% for line coverage and a floor of 80% for toggle, with the
shortfall accounted for above.

## 4. Mutation testing

See section 2.5. **23 mutations: 16 killed, 7 documented equivalents, 0
unexpected.**

## 5. Known limitations

| Limitation | Consequence | Rationale |
|---|---|---|
| Misaligned accesses trap; no hardware fixup | `ma_data` from the compliance suite cannot pass | Specification section 2.4. Covered instead by `mem_align.S` and the misaligned cases in `trap_exceptions.S`. |
| No instruction cache | `fence_i` cannot distinguish a correct implementation from a broken one | `FENCE.I` decodes as an architectural NOP; the decoder's handling is checked in `tb_decoder`. |
| No M extension | `MUL`/`DIV`/`REM` trap; C code links libgcc for `__divsi3` and friends | Specification section 2.1. Asserted by `illegal_encodings.S`. |
| Loads and stores are not interruptible | An interrupt is deferred to the next non-memory instruction | A memory access commits at the bus on grant, so taking an interrupt there would re-execute it after MRET. See the M5 lab notebook entry. |
| Toggle coverage 82% | See section 3.2 | Structurally unreachable bits. |
| Lockstep excludes cycle-dependent CSRs and interrupts | See section 2.4 | Not architecturally predictable. Covered by directed tests. |

## 4. Known limitations

_(populated as they are discovered; the `fence_i` exclusion from the compliance
suite is recorded here at M6)_
