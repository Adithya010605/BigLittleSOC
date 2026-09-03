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

_(populated M3–M5)_

### 2.3 Compliance (`make riscv-tests`)

_(populated M6)_

### 2.4 Randomised lockstep (`make random`)

_(populated M7)_

## 3. Coverage

Target: ≥ 95% line and toggle coverage on `rtl/common/` and `rtl/e_core/`,
measured by `make coverage`.

_(numbers and per-line justifications added at M8)_

## 4. Known limitations

_(populated as they are discovered; the `fence_i` exclusion from the compliance
suite is recorded here at M6)_
