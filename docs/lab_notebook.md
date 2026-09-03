# E-Core Lab Notebook

Running log of design decisions, bugs, root causes and fixes. One entry per
working/debugging session, newest last.

---

## 2026-09-07 — M0: environment and repo skeleton

### Toolchain survey

Machine: Arch Linux, kernel 7.2.3.

| Tool | Found | Notes |
|---|---|---|
| Verilator | 5.050 (2026-07-01) | meets the v5.x hard requirement |
| g++ | 16.2.1 | C++17 fine |
| gtkwave | 3.3.128 | ok |
| make | GNU Make 4.4.1 | ok |
| python3 | 3.14.7 | ok |
| git | 2.55.0 | ok |
| RISC-V cross compiler | **absent** | none of `riscv{32,64}-{unknown-,}elf-gcc` or `riscv64-linux-gnu-gcc` present |
| yosys | **absent** | needed only by `make synth` |

Both missing packages need root, and this environment has no passwordless sudo,
so installation is handed to the user. Candidate Arch packages found in `extra`:
`riscv64-elf-gcc` + `riscv64-elf-newlib` + `riscv64-elf-binutils` (bare-metal),
`riscv64-linux-gnu-gcc` (multilib, works freestanding), and `yosys`.

### Decision: cross-compiler detection order

`riscv32-unknown-elf-` → `riscv64-unknown-elf-` → `riscv32-elf-` →
`riscv64-elf-` → `riscv64-linux-gnu-`, first match wins, overridable with
`make RISCV_PREFIX=...`.

Rationale: a native rv32 toolchain is preferred because it needs no multilib and
its default `-march`/`-mabi` already match. The rv64 bare-metal toolchains work
provided every compile carries `-march=rv32i_zicsr -mabi=ilp32`, which the
Makefile always supplies, so nothing depends on the compiler's defaults. The
`riscv64-linux-gnu-` variant is last because it targets Linux; it is only usable
here because every test program is built `-nostdlib -nostartfiles -ffreestanding`
and never touches libc or the dynamic loader. `scripts/check_tools.sh` does not
trust the name — it actually compiles a one-line file with the target flags and
fails if the object cannot be produced.

### Decision: one dispatch script per regression, not Makefile recipes

`make <target>` delegates to `scripts/run_tests.sh <mode>`, which execs a
per-mode script. The Makefile therefore has a stable surface from M0 onward
while the implementations fill in at M1–M8, and the same scripts can be run by
hand while debugging without re-deriving Verilator command lines. Each script
degrades gracefully when its inputs do not exist yet (prints "not present yet",
exits 0) so `make test` is meaningful at every milestone rather than only at the
end.

### Decision: `--x-assign unique --x-initial unique` on simulation builds

Randomising X-state instead of Verilator's default zero-fill means an
uninitialised pipeline register or a missing reset shows up as a lockstep
mismatch rather than silently behaving. This is cheap insurance against the
classic "works in simulation, breaks in synthesis" class of bug, and it costs
nothing since every architectural register in this core is explicitly reset.

### Decision: lint bar has no escape hatch

`VLINT_FLAGS` is `--lint-only -Wall --timing` with no `-Wno-fatal`. The spec
allows developing with `-Wno-fatal` and removing it afterwards; leaving it out
entirely from the start avoids accumulating warnings that then have to be paid
down in a batch at M8.

### Open at end of M0

- RISC-V cross compiler and yosys must be installed by the user before M2's
  program-driven tests and M8's area estimate can run. M1 (unit tests) is
  unblocked — it needs only Verilator and g++.

---

## 2026-09-07 — M1: common modules and their unit testbenches

Toolchain gap from M0 closed: `riscv64-elf-gcc` 15.2.0 and yosys 0.66 installed.
Verified that the compiler genuinely produces rv32 output rather than merely
accepting the flags — `-print-multi-lib` lists `rv32i/ilp32`, a test link
produces an ELF32 RISC-V image, and `csrr` assembles, confirming Zicsr support.
Dropped the explicit `-Wl,-melf32lriscv` from `RVLDFLAGS`: `-march`/`-mabi`
already select the right emulation, and hard-coding it would break a
`riscv32-unknown-elf-` toolchain that a different machine might have.

Modules written this session: `e_core_pkg`, `alu`, `regfile`, `imm_gen`,
`decoder`, `lsu`, each with a C++ Verilator testbench.

### Bug found: ADDI decoded as SUB when the immediate looked like funct7

**Symptom.** The decoder's 2M-word random sweep failed on words such as
`0x41c48493`, reporting `alu_op: got 0x0 (ALU_SUB) expected 0xf (ALU_ADD)`.

**Root cause.** The OP and OP-IMM arms shared one line:

```systemverilog
alu_op_o = AluFromFunct3(funct3, funct7_is_alt);
```

`funct7_is_alt` means `instr[31:25] == 7'b0100000`, which selects SUB in place
of ADD and SRA in place of SRL. That is correct for OPCODE_OP, where
`instr[31:25]` really is a funct7 field. It is wrong for OPCODE_OP_IMM: there,
`instr[31:25]` is the top seven bits of the 12-bit immediate for every encoding
except the three shift-immediates. `0x41c48493` is `addi x9, x9, -996`, and
-996 is `0xFFFFFC1C`, whose bits 11:5 are exactly `0100000`. So the decoder
turned an add into a subtract for every ADDI/SLTI/SLTIU/XORI/ORI/ANDI whose
immediate falls in `[-2048, -1985]` — a 64-value window out of 4096, which is
why it needed a random sweep to surface rather than a directed test.

**Fix.** Gate the selector on the funct3 that actually has a shift encoding:

```systemverilog
alu_op_o = AluFromFunct3(funct3, funct7_is_alt && (funct3 == F3_SRL_SRA));
```

SLLI does not need the gate because a non-zero funct7 on SLLI is already
rejected as illegal.

**Why the test caught it and a directed test would not have.** The reference
decoder in `tb_decoder.cpp` was transcribed from the ISA manual's opcode
tables, structured opcode-first rather than mirroring the RTL's shared helper
function. Because the two were written from different sources, they did not
share the assumption. Had the reference simply mirrored `decoder.sv`, both
would have been wrong together. This is the argument for writing the reference
model from the specification rather than from the design.

### Decision: no reset on the register file array

`regfile.sv` writes `mem[]` from an `always_ff @(posedge clk_i)` with no reset
term, and the module has no `rst_ni` port at all. Resetting 1024 flip-flops
would prevent inference as distributed RAM (LUTRAM on Xilinx), and the plan's
own section 4.8 names exactly that as the most likely cause of blowing the
< 5K LUT budget. Determinism in simulation comes instead from a zero-fill
`initial` block guarded by `` `ifndef SYNTHESIS ``, which the coding standard
explicitly permits for memory initialisation. Synthesis therefore sees a
reset-free, RAM-inferable array while simulation sees deterministic zeros, so
lockstep against the golden ISS is meaningful from the first instruction.

### Decision: write-first bypass is explicit, not inferred

The S3→S2 same-cycle read of a register being written is served by an explicit
combinational mux around the array rather than by relying on a memory's
read-during-write behaviour. Read-during-write semantics differ between
simulation, FPGA block RAM and ASIC compilers; making the bypass explicit means
one behaviour everywhere and one that a unit test can actually target.
`tb_regfile.cpp` checks it on port A alone, port B alone, both ports at once,
and confirms the bypassed value really commits to storage on the next edge.

### Decision: ALU_ADD encoded as 4'b1111 so `default` is live

Enumerations are sized to a power of two, so a `unique case` over ten ALU
operations leaves a `default` arm that no legal input can reach — dead code
that permanently caps line coverage. Giving `ALU_ADD` the all-ones encoding
puts the most common operation on that arm, so it is exercised by ordinary
adds. The same trick is used in `lsu.sv`, where `SZ_WORD` sits on `default`.
This costs nothing in area (the encoding is arbitrary) and removes an
unjustifiable coverage hole from the M8 report before it exists.

### Decision: ALU shares one adder and one shifter

ADD, SUB, SLT and SLTU are computed from a single 33-bit adder: SUB/SLT/SLTU
drive it as `a + ~b + 1`, and the comparison results are read out of that same
subtraction (carry-out gives unsigned less-than; the sign bit, corrected when
the operand signs differ, gives signed less-than). SLL, SRL and SRA share one
33-bit right-shift barrel shifter, with left shifts performed by bit-reversing
in and out. The comparison results are exported as ports (`cmp_eq_o`,
`cmp_lt_o`, `cmp_ltu_o`) so that the ID stage's branch comparator can be built
from this same module at M3 rather than instantiating a second comparator.

### Decision: decoder exposes individual ports, not a packed struct

Verilator flattens a packed struct on a module port into an opaque vector, so a
testbench has to reproduce the bit layout by hand and silently breaks whenever
a field is added. The decoder therefore exposes ~25 individual named ports and
the ID stage packs them into `ctrl_t` for the pipeline register. The wiring is
more verbose exactly once, at the ID stage, and in exchange `tb_decoder.cpp`
reads each control signal by name.

### Decision: illegal instructions are squashed in one place

Rather than each decode arm clearing its own enables on the error paths, a
single block at the end of the decoder's `always_comb` forces every enable
(`rf_we`, `mem_req`, `mem_we`, `is_branch`, `is_jump`, `csr_*`, `ecall`,
`ebreak`, `mret`, `wfi`, `fence`, `rs1_used`, `rs2_used`) to zero whenever
`illegal_instr_o` is set. A future decode addition cannot forget to do it, and
the testbench asserts the property directly for every one of the 2M random
words: an illegal instruction asserts no enable of any kind.

### Decision: package grows with its consumers

Linting the package standalone reported UNUSEDPARAM for every constant no
module had consumed yet. Rather than waive the warning, the CSR address map,
the mstatus/mie/mip field positions and the exception-cause enumeration were
removed from `e_core_pkg.sv` and will be added at M5 together with
`csr_unit.sv` and `e_core_trap.sv`. `F7_MULDIV` was deleted outright: the
decoder rejects the M extension through the "funct7 must be 0000000 or 0100000"
rule, so naming the value would have been redundant logic as well as an unused
parameter. The zero-warning bar now holds at every milestone rather than only
at the end.

### Note on the lint gate before a top module exists

`scripts/lint.sh` runs one combined Verilator pass over every RTL file. Until
`e_core_top.sv` exists there is no unique top, so Verilator reports MULTITOP;
that single warning is suppressed in that case only. The alternative — linting
each file separately — was rejected because UNUSEDPARAM on a shared package is
invisible to a per-file lint, and catching unused package constants is
precisely what found `F7_MULDIV`. Once `e_core_top.sv` lands the waiver
disappears on its own.

### M1 results

| Module | Checks | Result |
|---|---:|---|
| alu | 19,091 | pass |
| regfile | 40,140 | pass |
| imm_gen | 50,190 | pass |
| lsu | 138,934 | pass |
| decoder | 45,440,523 | pass |

`scripts/lint.sh`: clean, 0 warnings, `-Wall`, no waivers other than the
MULTITOP note above. Of the 2M random words fed to the decoder, 259,405
(13.0%) were legal instructions, so the sweep exercised the legal decode space
as well as the trap path.
