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

---

## 2026-09-07 — M2: single-cycle datapath and the testbench harness

Built the permanent harness (`elf_loader`, `memory_model`, `disasm`,
`tb_e_core`), the bare-metal software base (`linker.ld`, `start.S`, `crt0.c`,
`uart.c`), the assembly-test macros, and the M2 single-cycle datapath.

### Bug found: a genuine combinational loop through the register file bypass

**Symptom.** Verilator reported UNOPTFLAT with the cycle
`regfile.we_qual -> rs2_data -> br_lt -> branch_taken -> unimplemented ->
rf_we_qual -> regfile.we_qual`.

**Root cause.** `regfile.sv` implements a write-first bypass, so `rdata`
depends combinationally on `we_i`. In the single-cycle datapath the register
file's write port and its read ports are used by the *same* instruction, so
`we_i` depended on whether that instruction commits, which depended on the
branch comparator and the JALR target, which depended on `rdata`.

This was not merely a lint complaint. The bypass is also *architecturally
wrong* in a single-cycle machine: with it in place, `add x1, x1, x2` would read
the value it is in the middle of computing rather than the old x1. Write-first
is correct only when the writer and the reader are different instructions,
which is exactly the situation once the pipeline exists at M3 (writer in S3,
reader in S2).

**Fix.** The M2 core commits its writeback through registers
(`wb_we_q`/`wb_addr_q`/`wb_data_q`), so the register file's write port is
flop-driven. The write lands in the cycle after ST_EXEC, which is always at or
before the next instruction's own ST_EXEC, so nothing observes stale state.
This breaks the loop and fixes the correctness problem at the same time.

**Consequence for M3.** No change is needed to `regfile.sv`. The write-first
bypass is right for the pipelined core and stays exactly as it is; it was only
the single-cycle *usage* that was incompatible.

### Bug found: two assembly checks were silently vacuous

**Symptom.** `m2_basic.S` failed check 8, reporting that `sub x12, x0, x5`
produced `0x80000000` instead of `-2047`.

**Root cause.** The check macros used `t0` (= x5) as scratch to materialise the
expected immediate. The test also held live values in x5. Check 8 compared
against a clobbered operand — but worse, checks 4 and 20 had the form
`CHECK_EQ x5, ...`, which expands to `li t0, val; beq x5, t0, ok`. With
`reg == t0` that is `li x5, val` followed by comparing x5 against itself: the
check passed unconditionally and tested nothing.

**Fix.** Reserved x31 as the sole scratch register and, crucially, made the
misuse a *build error* rather than a documented convention:

```asm
.macro _CHECK_NOT_SCRATCH reg
  .ifc "\reg","x31"
    .error "x31 is the macro scratch register and cannot be checked"
  .endif
.endm
```

A silently vacuous check is far more dangerous than a broken build, because it
reports success for work never done. Every comparison macro now invokes the
guard, and the guard was verified to fire by deliberately writing
`CHECK_EQ x31, 99, 1`.

### Bug found: the pass/fail verdict inverted the tohost convention

The harness compared `tohost >> 1` against 1. The riscv-tests convention is
that a *raw* tohost value of 1 means pass, and a failing check n is written as
`(n << 1) | 1`. The shifted value is therefore the check number, not the
verdict: comparing it against 1 called check 0 a pass and check 1 a failure.
The harness now compares the raw word against 1 and reports `raw >> 1` as the
identifying check number. A passing program was being reported as a failure,
which is the benign direction, but the same error would have silently accepted
a program that failed check 0.

### Bug found: `ls` sorted the RTL file list

`build_core.sh` built its file list with
`ls rtl/common/e_core_pkg.sv rtl/common/*.sv ...`, expecting the package to come
first. `ls` sorts its arguments, so `alu.sv` was compiled before the package
that defines `alu_op_e`, producing eleven "reference before declaration"
errors. Replaced with explicit array construction that puts the package first.
`lint.sh` already did this correctly, which is why lint passed while the build
failed.

### Decision: memory response may arrive in the same cycle as the grant

The valid/ready model allows `rvalid` in the same cycle as `gnt` (zero wait
states) or arbitrarily later. Same-cycle response is what a cache *hit* looks
like, and since the stated reason for adopting this protocol now is that the
core drops behind a cache later without change, refusing to model it would
defeat the purpose. `--waits=N` delays both the grant and the response by N
cycles; `--waits=random:SEED` draws both independently per transaction, with
the two ports given independent random streams so instruction and data latency
vary independently.

### Decision: the memory response never depends combinationally on itself

The model's response is a pure function of its own state and the core's request
signals, and the core never derives `req` from `gnt`. That contract is what
makes a single settle-then-respond pass per simulated cycle correct, rather
than needing to iterate to a fixed point. It is stated in both `memory_model.h`
and the RTL header so that neither side can quietly break it.

### Decision: `-lgcc` is part of the link

The first C link failed with undefined `__udivsi3`/`__umodsi3`. This is the M
extension's absence showing up exactly where it should: with no hardware
divider, GCC lowers every `/` and `%` to a libgcc call. Linking `-lgcc` after
the objects is what makes "multiply and divide are done in software" actually
work. Verified with `objdump` that the resulting image contains no `mul`,
`div` or `rem` instructions.

### Decision: RVFI is wired up from M2, not deferred

The RVFI trace port was implemented immediately rather than at M7, because the
harness needs a retirement stream anyway — for `--log`, for the last-50
instruction dump on failure, and later for lockstep. Building all of those on
RVFI from the start means one mechanism instead of three, and the lockstep
checker at M7 becomes a comparison against a port that is already exercised by
every test. The port is behind `parameter RVFI` and tied off when disabled, so
synthesis prunes it.

### M2 results

`m2_basic.S` — 24 checks over addi/add/sub/and/or/lw/sw/beq/jal, including
immediate extremes, arithmetic wraparound, store/load round trips with positive
and negative offsets, taken and not-taken branches, a backwards-branch loop,
and JAL link-register correctness.

| waits | cycles | retired |
|---|---:|---:|
| 0 | 221 | 106 |
| 1 | 450 | 105 |
| 2 | 679 | 105 |
| 3 | 908 | 105 |
| 5 | 1366 | 105 |
| 8 | 2053 | 105 |
| random:1 | 1068 | 105 |
| random:2 | 1042 | 106 |
| random:3 | 1003 | 105 |
| random:99 | 1056 | 105 |

The retired count differs by one between configurations because the final store
to `tohost` ends the simulation when the write commits at grant, which at
non-zero latency is before that instruction's own retirement is sampled. This
affects only the harness's diagnostic counter; from M5 the reported instruction
count comes from the core's own `minstret` CSR.

Lint: clean, 0 warnings, and now with **no waivers at all** — the MULTITOP
suppression from M1 disappeared automatically once `e_core_top.sv` gave the
design a unique top module.

---

## 2026-09-07 — M3: the three-stage pipeline

Replaced the M2 sequencer with `e_core_if_stage`, `e_core_id_stage`,
`e_core_ex_stage` and `e_core_hazard`, and rewrote `e_core_top` as pure wiring.
`regfile.sv` needed no change: the write-first bypass that was wrong for a
single-cycle datapath is exactly right once the writer (S3) and the reader (S2)
are different instructions.

`m2_basic` dropped from 221 cycles to 142 for the same 106 instructions.

### Decision: the IF stage needs a skid buffer to reach 1 IPC

The obvious fetch rule — do not issue a request until IF/ID is empty — is
correct but caps throughput at 0.5 IPC even with a zero-latency memory, because
a response cannot arrive before the cycle after the request, so IF/ID is
refilled only every other cycle. I traced this out cycle by cycle before
writing the code and it is not subtle: fetch, deliver, wait for ID to consume,
fetch again.

The fix is a single-entry skid buffer. A fetch is issued whenever the skid is
free, and a response that finds IF/ID occupied waits in the skid until IF/ID
drains. At most one request is in flight and at most one instruction is
buffered, so the storage cost is one 32-bit register plus a valid bit, and the
core runs at 1 IPC on straight-line code with a zero-wait-state memory.

### Decision: the fetch address is a separate register from the PC

`instr_addr_o` must hold still from the cycle a request is asserted until it is
granted. A branch resolving in ID can redirect the PC inside that window, so
driving `instr_addr_o` from the PC would change the address of a request the
memory had already seen — a protocol violation that a real slave would be
entitled to mishandle.

`fetch_addr_q` therefore holds the address of the request actually in flight
and `pc_q` holds the address to fetch next. A redirect changes `pc_q` only; the
outstanding request keeps presenting the address the memory saw, and its
wrong-path response is consumed and discarded via `discard_q`. Dropping `req`
before `gnt` would have been simpler but is exactly the protocol violation the
separate register avoids.

### Finding: the forward muxes and the write-first register file are redundant

This came out of mutation testing rather than review. Disabling the S3->S2
forward muxes changes nothing observable, and so does disabling the register
file's write-first bypass — because both are qualified by the same `rf_we_o`
and both carry the same `rf_wdata`, they deliver the identical value in the
identical cycle. Only removing both breaks the design.

The specification asks for both, and both are implemented, so this is recorded
rather than resolved. It does mean the forward muxes cost area without buying
correctness in the current configuration; their value is that they remain
correct if the register file is ever changed to a bypass-free memory macro,
which is the likely direction if this core is retargeted to an ASIC flow.

### Finding: the load-use interlock is not required for correctness here

Also from mutation testing. Removing the load-use stall entirely leaves every
test passing. The reason is timing: `ex_ready_o` implies `data_rvalid_i`, so by
the cycle a load retires its data is already valid, `rf_we_o` is already
asserted, and the write-first register file hands the value to S2 in that same
cycle. The dependent instruction never needs to wait.

The interlock is kept because it is what the specification asks for and because
it is the only thing that would keep memory read data out of the S2 operand
path if the register file bypass were removed. It costs one cycle per load-use
pair. This is worth flagging to review: the current design pays the CPI of
stalling AND carries the long path through the bypass, and a coherent
alternative would drop one or the other. See the M4 report.

### Decision: the hazard unit takes individual control bits, not `ctrl_t`

Passing the whole decoded bundle tripped UNUSEDSIGNAL, since only four of its
twenty fields affect hazard resolution. Rather than waive the warning, the
ports were narrowed to `idex_rf_we_i`, `idex_mem_req_i`, `idex_mem_we_i` and
`idex_csr_en_i`. The dependency is now explicit in the port list: adding a
control signal cannot silently change stall behaviour, and a reader can see at
a glance what this unit reacts to.

### Decision: the EX stage exports its captured operands

The first version of the RVFI assembly reached into `u_ex_stage.rs1_q` with
hierarchical references. That works in Verilator and is poor practice in
synthesizable RTL, so the ID/EX register now carries `rs1_addr`/`rs2_addr` and
exports them alongside the captured data. The trace port reports the values the
instruction actually executed with, already forwarded if forwarding took place.

### M3 results

Eight directed assembly tests, 200 checks total, all passing at zero wait
states:

| Test | Checks | Cycles | Retired | CPI |
|---|---:|---:|---:|---:|
| m2_basic | 24 | 142 | 106 | 1.34 |
| hazard_raw | 13 | 106 | 89 | 1.19 |
| hazard_load_use | 11 | 103 | 82 | 1.26 |
| branch_basic | 26 | 196 | 146 | 1.34 |
| branch_hazard | 14 | 86 | 67 | 1.28 |
| jump_link | 18 | 98 | 70 | 1.40 |
| mem_align | 31 | 209 | 170 | 1.23 |
| x0_writes | 21 | 98 | 74 | 1.32 |

Lint clean, 0 warnings, no waivers.
