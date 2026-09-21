# E-Core — Complete Technical Reference

A single-document description of the E-Core: what it is, what it implements,
how it works, and how it performs.

**E-Core** is a 3-stage, in-order, single-issue **RV32I_Zicsr** processor
implementing the RISC-V machine-mode privileged architecture. It is the
efficiency ("LITTLE") core of the big.LITTLE pair described in
`RISC-V_SoC_Project_Plan.md`, written in synthesizable SystemVerilog-2012 and
verified with Verilator.

| | |
|---|---|
| **ISA** | RV32I base + Zicsr extension (`rv32i_zicsr`, ABI `ilp32`) |
| **Privilege** | Machine mode only (M-mode) |
| **Pipeline** | 3 stages, in-order, single-issue |
| **Instructions implemented** | 49 |
| **Register file** | 32 × 32-bit, 2 read ports, 1 write port |
| **Branch handling** | Static not-taken, resolved in stage 2, 1-cycle penalty |
| **Memory interface** | Two independent valid/ready ports, arbitrary latency |
| **Area** | 2,273 LUTs, 968 flip-flops, 12 LUT-RAMs (Xilinx 7-series) |
| **Typical CPI** | 1.08 – 1.39 depending on workload, at zero wait states |
| **RTL size** | ~3,000 lines across 13 modules |

---

## Table of Contents

1. [Feature summary](#1-feature-summary)
2. [Programmer's model](#2-programmers-model)
3. [Instruction set — complete reference](#3-instruction-set--complete-reference)
4. [Microarchitecture](#4-microarchitecture)
5. [Hazards, forwarding and stalls](#5-hazards-forwarding-and-stalls)
6. [Control-status registers](#6-control-status-registers)
7. [Traps, exceptions and interrupts](#7-traps-exceptions-and-interrupts)
8. [Memory interface and memory map](#8-memory-interface-and-memory-map)
9. [Top-level interface](#9-top-level-interface)
10. [Module inventory](#10-module-inventory)
11. [Performance](#11-performance)
12. [Area and synthesis](#12-area-and-synthesis)
13. [Verification](#13-verification)
14. [Building and running](#14-building-and-running)
15. [Design decisions and rationale](#15-design-decisions-and-rationale)
16. [Limitations](#16-limitations)

---

## 1. Feature summary

### What is implemented

| Feature | Detail |
|---|---|
| **RV32I base integer ISA** | All 40 base instructions |
| **Zicsr extension** | All 6 CSR instructions with correct read/write side-effect rules |
| **Machine mode** | Full M-mode privileged architecture |
| **Exceptions** | All 9 machine-mode synchronous exceptions, correctly prioritised |
| **Interrupts** | Timer, software and external, with `mie`/`mip`/`mstatus.MIE` gating |
| **`MRET`** | Full trap return with `MIE`/`MPIE` restoration |
| **64-bit counters** | `mcycle`, `minstret`, both writable, both inhibitable |
| **Performance counters** | 4 custom 64-bit counters: stalls, branches, taken branches, memory ops |
| **Data forwarding** | Stage 3 → stage 2, feeding ALU, comparator, store data and JALR target |
| **Interlocks** | Load-use and CSR-use, extending automatically under memory latency |
| **Memory back-pressure** | Both ports tolerate arbitrary `gnt`/`rvalid` delay |
| **Misalignment detection** | Traps on misaligned load/store/instruction addresses |
| **Access faults** | Bus errors on either port raise the correct exception |
| **RVFI trace port** | Optional riscv-formal-compatible retirement trace |
| **Parameterisation** | Reset vector, hart ID, RVFI enable |

### What is deliberately absent

| Not implemented | Behaviour | Why |
|---|---|---|
| **M extension** (`MUL`, `DIV`, `REM`) | Raise illegal-instruction | Multiply/divide done in software (libgcc). Area target. |
| **C extension** (compressed) | `instr[1:0] != 2'b11` raises illegal-instruction | Not required; keeps fetch simple |
| **F/D extensions** (floating point) | Opcodes raise illegal-instruction | No FPU |
| **A extension** (atomics) | Opcodes raise illegal-instruction | Single core at this stage |
| **User / Supervisor modes** | `mstatus.MPP` hardwired to `2'b11` | M-mode only design |
| **Branch prediction** | Static not-taken, no BHT or BTB | This is the low-power core; the P-core gets prediction |
| **Caches, MMU, PMP** | Raw valid/ready memory ports | Caches arrive in a later project phase |
| **Misaligned access fixup** | Traps instead | Hardware splitting is expensive; software can emulate |

**Decoding is closed.** Every 32-bit word either matches a legal encoding or
raises illegal-instruction. There is no silent-NOP fallback, and an
illegal instruction asserts **no** enable of any kind — no register write, no
memory request, no control transfer, no CSR access.

---

## 2. Programmer's model

### 2.1 Register file

32 general-purpose 32-bit registers, `x0`–`x31`.

- **`x0` is hardwired to zero.** It is never written (the write enable is
  masked) and never read from storage (both read ports mux in a constant zero).
  The protection is deliberately doubled: a stray write cannot corrupt storage
  that a later change might start reading.
- Forwarding is suppressed when the destination is `x0`, so an instruction that
  nominally writes `x0` cannot leak its discarded result to a consumer.

Standard ABI names, used throughout the test suite:

| Register | ABI | Role |
|---|---|---|
| `x0` | `zero` | Hardwired zero |
| `x1` | `ra` | Return address |
| `x2` | `sp` | Stack pointer |
| `x3` | `gp` | Global pointer |
| `x4` | `tp` | Thread pointer |
| `x5`–`x7` | `t0`–`t2` | Temporaries |
| `x8`–`x9` | `s0`–`s1` | Saved registers |
| `x10`–`x17` | `a0`–`a7` | Arguments / return values |
| `x18`–`x27` | `s2`–`s11` | Saved registers |
| `x28`–`x31` | `t3`–`t6` | Temporaries |

### 2.2 Program counter

32-bit. Reset value is set by the `RESET_VECTOR` parameter (default
`0x0000_0000`). All instructions are 4 bytes and must be 4-byte aligned; a
control transfer to a misaligned address raises an
instruction-address-misaligned exception rather than being silently masked.

### 2.3 Data types and endianness

- **XLEN = 32.** All registers and addresses are 32 bits.
- **Little-endian.** Byte 0 of a word is the least significant byte.
- Native data types: byte (8), halfword (16), word (32).
- Loads of sub-word types come in signed (`LB`, `LH`) and unsigned
  (`LBU`, `LHU`) forms.

---

## 3. Instruction set — complete reference

49 instructions. Every one is verified by the unit-level decoder testbench,
the directed assembly suite, the `rv32ui-p` compliance suite, and randomised
lockstep against an independent architectural model.

### 3.1 Instruction formats

RISC-V uses six encoding formats. Bit positions are given MSB-first.

```
   31        25 24     20 19     15 14  12 11        7 6          0
  ┌────────────┬─────────┬─────────┬──────┬───────────┬────────────┐
R │   funct7   │   rs2   │   rs1   │funct3│     rd    │   opcode   │
  ├────────────┴─────────┼─────────┼──────┼───────────┼────────────┤
I │      imm[11:0]       │   rs1   │funct3│     rd    │   opcode   │
  ├────────────┬─────────┼─────────┼──────┼───────────┼────────────┤
S │  imm[11:5] │   rs2   │   rs1   │funct3│ imm[4:0]  │   opcode   │
  ├────────────┼─────────┼─────────┼──────┼───────────┼────────────┤
B │imm[12|10:5]│   rs2   │   rs1   │funct3│imm[4:1|11]│   opcode   │
  ├────────────┴─────────┴─────────┴──────┼───────────┼────────────┤
U │              imm[31:12]               │     rd    │   opcode   │
  ├───────────────────────────────────────┼───────────┼────────────┤
J │        imm[20|10:1|11|19:12]          │     rd    │   opcode   │
  └───────────────────────────────────────┴───────────┴────────────┘
```

**The B and J formats carry no bit 0.** Branch and jump targets are always
2-byte aligned, so the encoding reuses that bit position and the hardware
supplies the zero. Getting this wrong halves every displacement.

### 3.2 Integer register-immediate (9 instructions)

Opcode `0010011` (OP-IMM), I-format.

| Instruction | funct3 | funct7 | Operation |
|---|---|---|---|
| `ADDI rd, rs1, imm` | `000` | — | `rd = rs1 + sext(imm)` |
| `SLTI rd, rs1, imm` | `010` | — | `rd = (signed(rs1) < signed(imm)) ? 1 : 0` |
| `SLTIU rd, rs1, imm` | `011` | — | `rd = (unsigned(rs1) < unsigned(sext(imm))) ? 1 : 0` |
| `XORI rd, rs1, imm` | `100` | — | `rd = rs1 ^ sext(imm)` |
| `ORI rd, rs1, imm` | `110` | — | `rd = rs1 \| sext(imm)` |
| `ANDI rd, rs1, imm` | `111` | — | `rd = rs1 & sext(imm)` |
| `SLLI rd, rs1, shamt` | `001` | `0000000` | `rd = rs1 << shamt` |
| `SRLI rd, rs1, shamt` | `101` | `0000000` | `rd = rs1 >> shamt` (logical) |
| `SRAI rd, rs1, shamt` | `101` | `0100000` | `rd = rs1 >>> shamt` (arithmetic) |

`shamt` is `instr[24:20]`, 5 bits. Any other `funct7` on a shift-immediate is
a reserved encoding and raises illegal-instruction.

> **A subtlety worth stating.** For the *non-shift* OP-IMM forms,
> `instr[31:25]` is the top of the 12-bit immediate, **not** a funct7 field. An
> `ADDI` whose immediate happens to have bits 11:5 equal to `0100000` — any
> immediate in `[-2048, -1985]` — is still an add. Treating those bits as a
> SUB selector is a real bug this design had and fixed; only the shift-right
> encoding may be modified by `instr[31:25]`.

### 3.3 Integer register-register (10 instructions)

Opcode `0110011` (OP), R-format.

| Instruction | funct3 | funct7 | Operation |
|---|---|---|---|
| `ADD rd, rs1, rs2` | `000` | `0000000` | `rd = rs1 + rs2` |
| `SUB rd, rs1, rs2` | `000` | `0100000` | `rd = rs1 - rs2` |
| `SLL rd, rs1, rs2` | `001` | `0000000` | `rd = rs1 << rs2[4:0]` |
| `SLT rd, rs1, rs2` | `010` | `0000000` | `rd = (signed(rs1) < signed(rs2)) ? 1 : 0` |
| `SLTU rd, rs1, rs2` | `011` | `0000000` | `rd = (unsigned(rs1) < unsigned(rs2)) ? 1 : 0` |
| `XOR rd, rs1, rs2` | `100` | `0000000` | `rd = rs1 ^ rs2` |
| `SRL rd, rs1, rs2` | `101` | `0000000` | `rd = rs1 >> rs2[4:0]` (logical) |
| `SRA rd, rs1, rs2` | `101` | `0100000` | `rd = rs1 >>> rs2[4:0]` (arithmetic) |
| `OR rd, rs1, rs2` | `110` | `0000000` | `rd = rs1 \| rs2` |
| `AND rd, rs1, rs2` | `111` | `0000000` | `rd = rs1 & rs2` |

Only `funct7` values `0000000` and `0100000` are legal. **`funct7 = 0000001` is
the M extension** (`MUL`, `MULH`, `DIV`, `REM`, …) and raises
illegal-instruction on this core.

Shift amounts use only the low 5 bits of the operand; the upper 27 bits are
ignored.

### 3.4 Upper-immediate (2 instructions)

U-format.

| Instruction | Opcode | Operation |
|---|---|---|
| `LUI rd, imm` | `0110111` | `rd = imm << 12` (low 12 bits zero) |
| `AUIPC rd, imm` | `0010111` | `rd = pc + (imm << 12)` |

Together with `ADDI` these build any 32-bit constant (`LUI`+`ADDI`) or any
PC-relative address (`AUIPC`+`ADDI`), which is how the assembler's `li` and
`la` pseudo-instructions are expanded.

### 3.5 Control transfer (8 instructions)

**Unconditional jumps**

| Instruction | Opcode | Format | Operation |
|---|---|---|---|
| `JAL rd, offset` | `1101111` | J | `rd = pc + 4; pc = pc + sext(offset)` |
| `JALR rd, offset(rs1)` | `1100111` | I | `rd = pc + 4; pc = (rs1 + sext(offset)) & ~1` |

`JALR` clears **bit 0** of the computed target and leaves **bit 1** intact.
Since all instructions are 4-byte aligned here, a target with bit 1 set raises
instruction-address-misaligned.

`JALR` with `rd == rs1` computes the target from the **old** register value
before the link address overwrites it.

**Conditional branches** — opcode `1100011`, B-format. Taken if the condition
holds; `pc = pc + sext(offset)`, otherwise `pc = pc + 4`.

| Instruction | funct3 | Condition |
|---|---|---|
| `BEQ rs1, rs2, offset` | `000` | `rs1 == rs2` |
| `BNE rs1, rs2, offset` | `001` | `rs1 != rs2` |
| `BLT rs1, rs2, offset` | `100` | `signed(rs1) < signed(rs2)` |
| `BGE rs1, rs2, offset` | `101` | `signed(rs1) >= signed(rs2)` |
| `BLTU rs1, rs2, offset` | `110` | `unsigned(rs1) < unsigned(rs2)` |
| `BGEU rs1, rs2, offset` | `111` | `unsigned(rs1) >= unsigned(rs2)` |

funct3 values `010` and `011` are reserved and raise illegal-instruction.

### 3.6 Loads (5 instructions)

Opcode `0000011`, I-format. Address = `rs1 + sext(offset)`.

| Instruction | funct3 | Width | Extension |
|---|---|---|---|
| `LB rd, offset(rs1)` | `000` | byte | sign-extended |
| `LH rd, offset(rs1)` | `001` | halfword | sign-extended |
| `LW rd, offset(rs1)` | `010` | word | — |
| `LBU rd, offset(rs1)` | `100` | byte | zero-extended |
| `LHU rd, offset(rs1)` | `101` | halfword | zero-extended |

funct3 `011`, `110`, `111` are reserved and raise illegal-instruction.

**Alignment:** `LW` requires a 4-byte-aligned address, `LH`/`LHU` a
2-byte-aligned address. Byte loads are never misaligned. A violation raises
**load address misaligned** (cause 4) with `mtval` = the address.

### 3.7 Stores (3 instructions)

Opcode `0100011`, S-format. Address = `rs1 + sext(offset)`; the value stored is
`rs2`.

| Instruction | funct3 | Width |
|---|---|---|
| `SB rs2, offset(rs1)` | `000` | byte (low 8 bits of `rs2`) |
| `SH rs2, offset(rs1)` | `001` | halfword (low 16 bits of `rs2`) |
| `SW rs2, offset(rs1)` | `010` | word |

funct3 `011`–`111` are reserved and raise illegal-instruction. Alignment rules
match loads; a violation raises **store address misaligned** (cause 6).

A store that will trap **never reaches the bus** — memory is left untouched.

### 3.8 Memory ordering (2 instructions)

Opcode `0001111` (MISC-MEM).

| Instruction | funct3 | Behaviour |
|---|---|---|
| `FENCE` | `000` | Architectural NOP |
| `FENCE.I` | `001` | Architectural NOP |

Both are **accepted and retired as NOPs, never trapped**. This core has no
caches and no store buffer, and executes strictly in order, so there is nothing
for a fence to order. Any other funct3 under this opcode raises
illegal-instruction.

### 3.9 System instructions (4 instructions)

Opcode `1110011` with `funct3 = 000`. These are fully-specified 32-bit words:
every field outside the opcode is fixed, and the decoder compares the whole
instruction rather than decoding fields that must be zero.

| Instruction | Encoding | Behaviour |
|---|---|---|
| `ECALL` | `0x0000_0073` | Raises environment-call-from-M-mode (cause 11) |
| `EBREAK` | `0x0010_0073` | Raises breakpoint (cause 3), `mtval` = PC |
| `MRET` | `0x3020_0073` | `pc = mepc`; `MIE = MPIE`; `MPIE = 1` |
| `WFI` | `0x1050_0073` | NOP (see below) |

Any other `funct3 = 000` encoding under this opcode raises
illegal-instruction.

**`WFI` is implemented as a NOP.** It is architecturally a *hint*, and the
privileged specification explicitly permits implementing it this way. With no
clock gating or low-power state to enter, retiring it normally is both correct
and simplest; an enabled interrupt is then taken by the ordinary path on a
following instruction.

### 3.10 Zicsr — CSR instructions (6 instructions)

Opcode `1110011` with `funct3 != 000`. `csr` is `instr[31:20]`.

| Instruction | funct3 | Operation |
|---|---|---|
| `CSRRW rd, csr, rs1` | `001` | `rd = csr; csr = rs1` |
| `CSRRS rd, csr, rs1` | `010` | `rd = csr; csr = csr \| rs1` |
| `CSRRC rd, csr, rs1` | `011` | `rd = csr; csr = csr & ~rs1` |
| `CSRRWI rd, csr, uimm` | `101` | `rd = csr; csr = zext(uimm)` |
| `CSRRSI rd, csr, uimm` | `110` | `rd = csr; csr = csr \| zext(uimm)` |
| `CSRRCI rd, csr, uimm` | `111` | `rd = csr; csr = csr & ~zext(uimm)` |

`uimm` is the 5-bit field `instr[19:15]`, **zero-extended** (so `uimm = 31`
means 31, not −1). funct3 `100` is reserved and raises illegal-instruction.

**Side-effect rules — these decide legality, not just efficiency:**

| Form | Writes the CSR? | Reads the CSR? |
|---|---|---|
| `CSRRW` / `CSRRWI` | Always | Only when `rd != x0` |
| `CSRRS` / `CSRRC` / `CSRRSI` / `CSRRCI` | Only when the source operand is non-zero | Always |

Consequence: **`CSRRS rd, csr, x0` against a read-only CSR is legal** (it
performs no write), while `CSRRW` to the same CSR is **not**. The decoder
computes this distinction and the CSR unit acts on it.

A write to a read-only CSR, or any access to an unimplemented CSR, raises
illegal-instruction with `mtval` = the instruction word.

### 3.11 Instruction count summary

| Group | Count |
|---|---:|
| Register-immediate arithmetic/logic | 9 |
| Register-register arithmetic/logic | 10 |
| Upper immediate | 2 |
| Jumps | 2 |
| Conditional branches | 6 |
| Loads | 5 |
| Stores | 3 |
| Memory ordering | 2 |
| System / privileged | 4 |
| Zicsr | 6 |
| **Total** | **49** |

---

## 4. Microarchitecture

### 4.1 Pipeline overview

```
        ┌───────────────────────┐   ┌────────────────────────┐   ┌──────────────────────────┐
        │  S1   IF              │   │  S2   ID / RF          │   │  S3   EX / MEM / WB      │
        │                       │   │                        │   │                          │
  ─────▶│  program counter      │──▶│  decoder               │──▶│  ALU                     │──▶ register
        │  fetch address reg    │   │  immediate generator   │   │  load/store unit         │    writeback
        │  instr port handshake │   │  register file (2R)    │   │  data port handshake     │
        │  skid buffer          │   │  forwarding muxes      │   │  CSR file                │
        │  redirect mux         │   │  branch comparator     │   │  trap unit               │
        │                       │   │  target adder          │   │                          │
        └───────────────────────┘   └────────────────────────┘   └──────────────────────────┘
                    │                             │                             │
              ┌─────┴──────┐              ┌───────┴───────┐                     │
              │ IF/ID reg  │              │  ID/EX reg    │                     │
              │ valid,pc,  │              │ valid,pc,ctrl,│                     │
              │ instr,err  │              │ rs1,rs2,imm,rd│                     │
              └────────────┘              └───────────────┘                     │
                    ▲                             ▲                             │
                    │ flush on redirect           │ bubble on interlock         │
                    └─────────────────────────────┴─────────────────────────────┘
                                     S3 result forwarded back to S2
```

Both pipeline registers carry a **valid** bit. A flush clears `valid` rather
than zeroing the payload, so no datapath signal needs resetting for
correctness.

The IF/ID register lives inside `e_core_if_stage`; the ID/EX register lives
inside `e_core_ex_stage`. Each stage owns its own input boundary, and
`e_core_top` is pure wiring with no control logic of its own.

### 4.2 Stage 1 — Instruction Fetch (IF)

**Responsibilities:** hold the program counter, drive the instruction memory
handshake, buffer returned instructions, and apply redirects.

**State:**

| Register | Purpose |
|---|---|
| `pc_q` | Address to fetch **next** |
| `fetch_addr_q` | Address of the request currently **in flight** |
| `fetch_active_q` | A request is outstanding |
| `fetch_gnt_q` | That request has been granted |
| `discard_q` | The outstanding request is on a wrong path |
| IF/ID register | `valid`, `pc`, `instr`, `err` |
| Skid buffer | `valid`, `pc`, `instr`, `err` |

**Why there is a skid buffer.** The instruction port may answer in the request
cycle or many cycles later, and ID may stall at any time, so a returning
instruction can arrive when IF/ID is still occupied.

The simple rule — *do not issue a fetch until IF/ID is empty* — is correct but
caps throughput at **0.5 IPC even with a zero-latency memory**, because a
response cannot arrive before the cycle after the request, so IF/ID is refilled
only every other cycle. A single-entry skid buffer removes that restriction: a
fetch is issued whenever the skid is free, and a response that finds IF/ID
occupied waits in the skid until it drains. Cost: one 32-bit register plus a
valid bit. Benefit: **1 IPC on straight-line code**.

**Why the fetch address is a separate register from the PC.** `instr_addr_o`
must stay stable from the cycle a request is asserted until it is granted, but
a branch resolving in S2 can redirect the PC inside that window.
`fetch_addr_q` holds the address of the request in flight while `pc_q` holds
the address to fetch next; a redirect changes `pc_q` only, so the outstanding
request keeps presenting the address the memory already accepted. The
wrong-path response is then consumed and thrown away via `discard_q`. The
alternative — dropping `req` before `gnt` — violates the bus protocol.

At most **one request is in flight** and at most **one instruction is
buffered** at any time.

### 4.3 Stage 2 — Decode and Register Read (ID/RF)

Purely combinational apart from the register file it instantiates.

**Contents:** instruction decoder, immediate generator, register file (two read
ports), operand forwarding muxes, branch comparator, and the branch/jump target
adder.

**Branches and jumps resolve here, not in EX.** The comparator and the target
adder are dedicated hardware, separate from the main ALU in S3.

| | Resolve in S2 (chosen) | Resolve in S3 (rejected) |
|---|---|---|
| Wrong-path instructions on a taken branch | 1 (the one in S1) | 2 (S1 and S2) |
| Taken-branch penalty | **1 cycle** | 2 cycles |
| Extra hardware | one comparator, one adder | none; reuses the main ALU |

With static not-taken prediction and no BTB, every taken branch pays the
penalty, so halving it is worth one adder and one comparator on a core whose
budget is 5K LUTs. The comparator is an instance of the `alu` module driven as
a subtraction — that module exports `cmp_eq` / `cmp_lt` / `cmp_ltu` — so the
signed and unsigned comparison logic exists **once** in the design and is
covered once by its unit test.

Target formation:
- Branches and `JAL`: `pc + sext(imm)`
- `JALR`: `(rs1 + sext(imm)) & ~1`

Both use forwarded operands, so a branch or `JALR` that depends on the
immediately preceding instruction reads the correct value.

### 4.4 Stage 3 — Execute / Memory / Writeback (EX/MEM/WB)

**Contents:** ID/EX pipeline register, the main ALU, the load/store unit, the
data port handshake, the CSR file interface, the trap unit interface, and the
register file write port.

**Completion.** A non-memory instruction completes in the cycle it occupies
this stage. A load or store completes when `data_rvalid_i` arrives — which may
be the same cycle as the request or arbitrarily later — and `ex_ready` stays
low until then, back-pressuring ID and, through it, IF.

**Fault suppression.** An instruction that will trap for a reason known before
the access — an illegal encoding, a misaligned address, `ECALL`, `EBREAK`, a
faulting fetch — never asserts `data_req_o`. A faulting access does not reach
the bus, so a misaligned store cannot corrupt memory.

**Writeback sources:**

| Source | Used by |
|---|---|
| ALU result | arithmetic, logic, shifts, `LUI`, `AUIPC` |
| Memory read data (aligned + extended) | loads |
| `pc + 4` | `JAL`, `JALR` |
| CSR read value | Zicsr instructions |

### 4.5 The ALU

Purely combinational, and deliberately compact:

- **ADD, SUB, SLT and SLTU share one 33-bit adder.** SUB/SLT/SLTU drive it as
  `a + ~b + 1`; the comparison results are read straight out of that same
  subtraction. Carry-out gives unsigned less-than; the sign bit, corrected when
  the operand signs differ, gives signed less-than.
- **SLL, SRL and SRA share one 33-bit right-shift barrel shifter.** A left
  shift is performed by bit-reversing the operand in and the result out, which
  costs wiring instead of a second shifter. The 33rd bit carries the sign for
  `SRA` and is zero otherwise, so one arithmetic right shift covers both.
- The comparison outputs are exported as ports, which is how the S2 branch
  comparator is built from this same module.

### 4.6 The load/store unit

Owns every byte-lane decision in the core, so no stage has to reason about
addresses modulo four.

| Function | Behaviour |
|---|---|
| Byte enables | `SB`: `1 << addr[1:0]`; `SH`: `0b0011` or `0b1100`; `SW`: `0b1111` |
| Store data placement | The value is **replicated** across the word, so whichever lanes the byte enables select carry the correct bytes. Replication is cheaper than a shifter and gives the same result. |
| Load extraction | Selects the addressed byte or halfword, then sign- or zero-extends |
| Misalignment | Word requires `addr[1:0] == 0`; halfword requires `addr[0] == 0`; byte is always aligned |

---

## 5. Hazards, forwarding and stalls

Every stall, flush and forwarding decision is made in one module,
`e_core_hazard.sv`. No stage file contains a stall term of its own.

### 5.1 Forwarding: S3 → S2

The S3 result is forwarded into the S2 operand muxes whenever S3 holds a valid
instruction writing a register other than `x0` that S2 reads.

| Source (S3) | Destination (S2) | Condition |
|---|---|---|
| ALU result | ALU operand A | `idex_valid & rf_we & rd != x0 & rd == rs1 & rs1_used` |
| ALU result | ALU operand B | same, with `rs2` |
| ALU result | **branch comparator** | same |
| ALU result | **JALR target adder** | same, `rs1` only |
| ALU result | store data (`rs2`) | same, with `rs2` |
| `pc + 4` (link value) | any of the above | same |
| **Load data** | — | **not forwarded — stall instead** |
| **CSR read value** | — | **not forwarded — stall instead** |

Forwarding the comparator and the JALR adder — not just the ALU operands — is
what makes a branch immediately following its producer work.

### 5.2 Stall table

| Condition | Detected by | S1 | S2 | S3 | Duration |
|---|---|---|---|---|---|
| Load in S3, its `rd` read by S2 | `ex_result_late & dependency` | hold | hold | bubble | 1 cycle at zero wait states; extends automatically until `rvalid` |
| CSR instruction in S3, its `rd` read by S2 | same term, via `csr_en` | hold | hold | bubble | as above |
| Data memory access outstanding | `~ex_ready` | hold | hold | hold | until `data_rvalid_i` |
| Fetch outstanding, IF/ID and skid both full | fetch not issued | — | — | — | until IF/ID drains |

There is **no separate multi-cycle stall case**. `ex_ready` is low for as long
as a memory access is outstanding, so a slow memory extends the same term that
a fast memory satisfies in one cycle.

### 5.3 Why CSR reads stall instead of forwarding

The CSR read value is produced late in S3, after address decode and the
read-only/WARL checks. Routing it into the S2 operand muxes would put a CSR
address decode plus a mux into the **branch comparator's** path — a cost paid
on *every branch*, to speed up an instruction class that is rare. A one-cycle
stall on a dependent CSR read costs nothing measurable by comparison.

### 5.4 Branch penalty, derived

At zero wait states, with a branch at address A resolving in S2 during cycle N:

| Cycle | Without branch | With taken branch to T |
|---|---|---|
| N | branch in S2; A+4 returning | branch in S2; A+4 returning, then flushed |
| N+1 | A+4 in S2 | fetch T issued and returned |
| N+2 | A+8 in S2 | T in S2 |

The stream resumes one cycle later than it would have: a **1-cycle penalty**.

A redirect fires only when the redirecting instruction actually advances into
S3. Redirecting while it is stalled would flush S1 and re-fetch the same target
once per stalled cycle.

---

## 6. Control-status registers

All machine mode. A write to a read-only register, or any access to a register
not listed, raises illegal-instruction.

| CSR | Address | Access | Behaviour |
|---|---|---|---|
| `mstatus` | `0x300` | RW | `MIE` (bit 3) and `MPIE` (bit 7) writable; `MPP` (bits 12:11) hardwired `2'b11` |
| `misa` | `0x301` | RO | `0x4000_0100` — MXL=1 (32-bit), extension `I` only |
| `mie` | `0x304` | RW | only `MSIE`(3), `MTIE`(7), `MEIE`(11) implemented |
| `mtvec` | `0x305` | RW | direct mode only; WARL mode bits forced to zero |
| `mcountinhibit` | `0x320` | RW | `CY` (bit 0), `IR` (bit 2) |
| `mscratch` | `0x340` | RW | plain scratch register |
| `mepc` | `0x341` | RW | bit 0 hardwired zero |
| `mcause` | `0x342` | RW | bit 31 = interrupt flag, bits 4:0 = cause |
| `mtval` | `0x343` | RW | faulting address or instruction word |
| `mip` | `0x344` | RO | read-only view of the three interrupt pins |
| `mcycle` / `mcycleh` | `0xB00` / `0xB80` | RW | 64-bit cycle counter |
| `minstret` / `minstreth` | `0xB02` / `0xB82` | RW | 64-bit retired-instruction counter |
| `mhpmcounter3` / `..3h` | `0xB03` / `0xB83` | RW | **stall cycles** |
| `mhpmcounter4` / `..4h` | `0xB04` / `0xB84` | RW | **branch instructions** |
| `mhpmcounter5` / `..5h` | `0xB05` / `0xB85` | RW | **taken branches** |
| `mhpmcounter6` / `..6h` | `0xB06` / `0xB86` | RW | **loads and stores** |
| `mvendorid`, `marchid`, `mimpid` | `0xF11`–`0xF13` | RO | zero |
| `mhartid` | `0xF14` | RO | the `HART_ID` parameter |

### 6.1 Counter semantics

| Counter | Increments on |
|---|---|
| `mcycle` | every cycle, unless `mcountinhibit.CY` |
| `minstret` | an instruction **retiring** — never a flushed instruction, never a stall bubble — unless `mcountinhibit.IR` |
| `mhpmcounter3` | a cycle in which S2 held a valid instruction back |
| `mhpmcounter4` | a retired **conditional branch** (jumps excluded) |
| `mhpmcounter5` | a retired conditional branch whose condition was **true** |
| `mhpmcounter6` | a retired load or store |

`mhpmcounter3` measures **blocked work, not idle time**: if S2 has nothing to
hold back — because the instruction fetch has not returned yet — no stall is
counted. That distinction matters when comparing across memory latencies.

---

## 7. Traps, exceptions and interrupts

### 7.1 Exception priority

Highest first. Implemented as a priority chain in `e_core_trap.sv`.

| Priority | Cause | Exception | `mtval` |
|---:|---:|---|---|
| 1 | 0 | Instruction address misaligned | target address |
| 2 | 1 | Instruction access fault | faulting PC |
| 3 | 2 | Illegal instruction | the instruction word |
| 4 | 3 | Breakpoint (`EBREAK`) | PC |
| 5 | 4 | Load address misaligned | address |
| 6 | 5 | Load access fault | address |
| 7 | 6 | Store address misaligned | address |
| 8 | 7 | Store access fault | address |
| 9 | 11 | Environment call from M-mode | 0 |

### 7.2 Trap entry and return

**On trap:**
```
mepc    ← PC of the faulting instruction
mcause  ← {interrupt_flag, cause}
mtval   ← faulting address or instruction word
mstatus.MPIE ← mstatus.MIE
mstatus.MIE  ← 0
pc      ← mtvec
```

**On `MRET`:**
```
pc      ← mepc
mstatus.MIE  ← mstatus.MPIE
mstatus.MPIE ← 1
```

**Hardware never advances `mepc`.** That is required for an interrupt — the
instruction has not executed and must run on return — and is the specified
behaviour for every exception here. `ECALL` and `EBREAK` handlers advance
`mepc` by four themselves.

A trapping instruction does not write the register file and does not commit its
CSR write.

### 7.3 Interrupts

Three inputs: `irq_timer_i`, `irq_software_i`, `irq_external_i`.

| Interrupt | `mie`/`mip` bit | `mcause` |
|---|---:|---|
| Machine software | 3 | `0x8000_0003` |
| Machine timer | 7 | `0x8000_0007` |
| Machine external | 11 | `0x8000_000B` |

Taken when `mstatus.MIE` is set **and** `mie & mip` is non-zero. Interrupts
take precedence over synchronous exceptions, because an interrupt is taken
*instead of* the instruction rather than *because of* it. Fixed priority among
simultaneous interrupts: external, then software, then timer.

> **Loads and stores are not interruptible.** A memory access commits at the
> bus when the request is **granted**, which is before the instruction reaches
> its completion cycle. Taking an interrupt there would leave the access
> already performed while `mepc` still pointed at the instruction, so `MRET`
> would perform it a second time. For an ordinary store that is a silent
> double-write; for a store to a device register it can **livelock** — the
> handler clears the source and the returning store immediately re-asserts it.
> The interrupt is simply taken on the next non-memory instruction instead.

---

## 8. Memory interface and memory map

### 8.1 Protocol

Two independent ports (instruction and data), both using the same Ibex-style
valid/ready handshake:

```
  req    ───┐ asserted until gnt; address held stable throughout
  gnt    ───┘ the cycle the request is accepted
  rvalid ──── the cycle rdata/err are valid:
              the SAME cycle as gnt, or any number of cycles later
```

- `rvalid` is asserted for **writes as well as reads**, acknowledging
  completion.
- A **same-cycle response is permitted**, because that is exactly what a cache
  hit looks like — and the reason for adopting this protocol now is that the
  core drops behind a cache or onto a NoC later without change.
- One transaction per port is outstanding at a time.

**The contract both sides rely on:** `instr_req_o` and `data_req_o` are
functions of core registers only. Neither depends combinationally on its port's
`gnt` or `rvalid`. This is what lets a memory model compute its response in one
settle pass per cycle instead of iterating to a fixed point.

### 8.2 Memory map (as modelled by the testbench)

| Range | Contents |
|---|---|
| `0x0000_0000` – `0x0000_FFFF` | Code and read-only data (64 KiB) |
| `0x0001_0000` – `0x0002_FFFF` | Data, BSS, heap, stack (128 KiB) |
| `0x0002_FFF0` | Initial stack pointer |
| `0x1000_0000` | UART transmit data (write) |
| `0x1000_0004` | UART status (read; bit 0 = busy) |
| `0x1100_0000` – `0x1100_000C` | Interrupt controller (testbench only) |
| anything else | Unmapped — raises an access fault |

The reset vector is `0x0000_0000` by default.

---

## 9. Top-level interface

### 9.1 Parameters

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `RESET_VECTOR` | `logic [31:0]` | `32'h0000_0000` | PC after reset |
| `HART_ID` | `logic [31:0]` | `32'h0000_0000` | Value read from `mhartid` |
| `RVFI` | `bit` | `1'b0` | Enables the trace port; tied off and pruned when clear |

### 9.2 Ports

**Clock and reset**

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk_i` | in | 1 | Single clock, rising edge |
| `rst_ni` | in | 1 | Active-low reset |

**Instruction memory port**

| Port | Dir | Width | Description |
|---|---|---|---|
| `instr_req_o` | out | 1 | Request valid |
| `instr_addr_o` | out | 32 | Word-aligned fetch address |
| `instr_gnt_i` | in | 1 | Request accepted this cycle |
| `instr_rvalid_i` | in | 1 | `rdata` valid this cycle |
| `instr_rdata_i` | in | 32 | Instruction word |
| `instr_err_i` | in | 1 | Bus error → instruction access fault |

**Data memory port**

| Port | Dir | Width | Description |
|---|---|---|---|
| `data_req_o` | out | 1 | Request valid |
| `data_addr_o` | out | 32 | Word-aligned address |
| `data_we_o` | out | 1 | 1 = write, 0 = read |
| `data_be_o` | out | 4 | Byte enables |
| `data_wdata_o` | out | 32 | Write data, lane-aligned |
| `data_gnt_i` | in | 1 | Request accepted this cycle |
| `data_rvalid_i` | in | 1 | `rdata` valid / write complete |
| `data_rdata_i` | in | 32 | Read data |
| `data_err_i` | in | 1 | Bus error → load/store access fault |

**Interrupts**

| Port | Dir | Width | Description |
|---|---|---|---|
| `irq_timer_i` | in | 1 | Machine timer interrupt |
| `irq_software_i` | in | 1 | Machine software interrupt |
| `irq_external_i` | in | 1 | Machine external interrupt |

**RVFI trace port** (active when `RVFI = 1`)

`rvfi_valid_o`, `rvfi_order_o[63:0]`, `rvfi_insn_o[31:0]`, `rvfi_trap_o`,
`rvfi_halt_o`, `rvfi_intr_o`, `rvfi_mode_o[1:0]`, `rvfi_ixl_o[1:0]`,
`rvfi_rs1_addr_o[4:0]`, `rvfi_rs2_addr_o[4:0]`, `rvfi_rs1_rdata_o[31:0]`,
`rvfi_rs2_rdata_o[31:0]`, `rvfi_rd_addr_o[4:0]`, `rvfi_rd_wdata_o[31:0]`,
`rvfi_pc_rdata_o[31:0]`, `rvfi_pc_wdata_o[31:0]`, `rvfi_mem_addr_o[31:0]`,
`rvfi_mem_rmask_o[3:0]`, `rvfi_mem_wmask_o[3:0]`, `rvfi_mem_rdata_o[31:0]`,
`rvfi_mem_wdata_o[31:0]`.

This is the riscv-formal signal set. It makes the lockstep checker trivial and
lets formal verification run against the core unmodified.

---

## 10. Module inventory

| Module | Lines | Role |
|---|---:|---|
| `rtl/common/e_core_pkg.sv` | 287 | Shared types, enums, opcodes, CSR addresses, cause codes |
| `rtl/common/alu.sv` | 109 | Arithmetic/logic, shared adder and barrel shifter, comparison outputs |
| `rtl/common/regfile.sv` | 98 | 32×32 register file, 2R1W, write-first bypass, x0 protection |
| `rtl/common/imm_gen.sv` | 63 | Immediate extraction for all six formats |
| `rtl/common/decoder.sv` | 432 | Closed instruction decode; every word is legal or trapped |
| `rtl/common/csr_unit.sv` | 323 | Machine-mode CSR file, WARL behaviour, counters |
| `rtl/common/lsu.sv` | 108 | Byte enables, store placement, load extension, misalignment |
| `rtl/e_core/e_core_if_stage.sv` | 205 | PC, fetch handshake, skid buffer, IF/ID register |
| `rtl/e_core/e_core_id_stage.sv` | 239 | Decode, register read, forwarding, branch resolution |
| `rtl/e_core/e_core_ex_stage.sv` | 327 | ID/EX register, ALU, LSU, data port, writeback |
| `rtl/e_core/e_core_hazard.sv` | 156 | All stall, flush and forwarding control |
| `rtl/e_core/e_core_trap.sv` | 180 | Exception prioritisation, trap entry, MRET, interrupts |
| `rtl/e_core/e_core_top.sv` | 473 | Wiring and the RVFI trace assembly |
| **Total** | **~3,000** | |

---

## 11. Performance

All figures at zero wait states.

### 11.1 Benchmark CPI

| Program | Cycles | Retired | CPI | What it stresses |
|---|---:|---:|---:|---|
| `fib` | 511,036 | 473,764 | **1.079** | Recursion: calls, stack traffic, dependence chains |
| `bubble_sort` | 12,523 | 10,075 | **1.243** | Load-use interlocks and branches |
| `memcpy_test` | 298,242 | 235,936 | **1.264** | Every alignment through the LSU |
| `perf_counters` | 14,999 | 11,726 | **1.279** | Counter workload |
| `hello` | 675 | 487 | **1.386** | Boot path, UART poll loop |

`fib` has the lowest CPI because recursive Fibonacci is dominated by
straight-line arithmetic and calls, sustaining close to 1 IPC. `hello` has the
highest because it is short enough that startup and pipeline fill dominate.

### 11.2 Instruction mix and where the cycles go

Measured by the core's own counters over a 24-element bubble sort, with startup
excluded:

| Metric | Value |
|---|---:|
| Cycles | 2,481 |
| Instructions retired | 1,783 |
| Stall cycles | 276 |
| Branches retired | 575 (32.2% of instructions) |
| Branches taken | 400 (69.6% of branches) |
| Loads and stores | 812 (45.5% of instructions) |
| **CPI** | **1.39** |

**Accounting for the 0.39 cycles of overhead per instruction:**

| Source | Cycles/instruction |
|---|---:|
| Taken-branch flushes (400 / 1783) | 0.22 |
| Stalls (276 / 1783) | 0.15 |
| **Subtotal** | **0.37** |
| Pipeline fill after reset | ~0.02 |

That accounts for essentially all of it. This is the expected profile for a
static-not-taken machine on a branch-heavy workload — and it is precisely the
number a branch predictor would have to beat.

### 11.3 Latency sensitivity

Cycle counts for `m2_basic` (106 instructions) as memory latency rises:

| Wait states | Cycles | Relative | CPI |
|---:|---:|---:|---:|
| 0 | 142 | 1.00× | 1.34 |
| 1 | 409 | 2.88× | 3.86 |
| 2 | 680 | 4.79× | 6.42 |
| 3 | 951 | 6.70× | 8.97 |
| 5 | 1,493 | 10.51× | 14.08 |
| 8 | 2,306 | 16.24× | 21.75 |

The steep slope is expected and is the argument for the caches that arrive in a
later project phase: with no cache, every instruction fetch pays the full
memory latency.

---

## 12. Area and synthesis

Produced by `make synth` (Yosys, via `sv2v` lowering).

### Xilinx 7-series (`synth_xilinx -family xc7 -flatten`)

| Resource | Count |
|---|---:|
| **LUTs (LUT1–LUT6)** | **2,273** |
| Flip-flops (FDCE) | 968 |
| Distributed RAM (RAM32M) | 12 |
| Carry chains (CARRY4) | 146 |
| Wide muxes (MUXF7 / MUXF8) | 147 / 58 |

**2,273 LUTs against a < 5K target — 55% headroom.**

**The register file inferred as distributed RAM**, which was the entire point of
leaving the array un-reset: twelve `RAM32M` primitives hold the 32 × 32-bit
file. Had it been reset — the conventional choice — it would have become 1,024
flip-flops, more than doubling the flop count.

**Where the flip-flops go.** The counters dominate: `mcycle` and `minstret` are
64-bit and the four `mhpmcounter`s are 64-bit each, 384 bits between them — just
under 40% of all state in the core — before any pipeline register is counted.
That is a deliberate cost, since those counters are what make the cross-core
performance comparison measurable. Narrowing them to 32 bits would save roughly
192 flops.

This is an **area estimate only**: no timing constraint is applied and no
place-and-route is run.

---

## 13. Verification

| Level | What it does | Result |
|---|---|---|
| **Lint** | `verilator --lint-only -Wall` over all RTL | **0 warnings, no waivers** |
| **Unit tests** | One C++ harness per `rtl/common` module, each with a reference model written from the ISA spec rather than from the RTL | 6 modules, **45.7M checks** |
| **Directed assembly** | 13 self-checking programs, each check uniquely numbered | ~300 checks, each run at **4 memory latencies** |
| **Compliance** | The upstream `rv32ui-p` suite, re-linked at address 0 | **40 passed, 0 failed**, 2 documented skips |
| **Randomised lockstep** | Constrained-random programs run against an independent architectural interpreter, compared at every retirement | **600 programs × {0, random} waits = 1,200 runs** |
| **Mutation testing** | Deliberate RTL defects injected to prove the tests can detect them | 23 mutations: **16 killed, 7 documented equivalents** |
| **Coverage** | Line and toggle, over 177 replayed programs | **100% line**; 82% toggle (shortfall itemised) |

### 13.1 Directed test suite

| Test | Covers |
|---|---|
| `m2_basic` | Core arithmetic, logic, load/store, branches, `JAL` |
| `hazard_raw` | RAW forwarding at distances 1–3; forwarding into store data, store address, load address; `x0` producers not forwarded |
| `hazard_load_use` | Load-use interlocks in every operand position; pointer chases; store-then-load |
| `branch_basic` | All six conditions in both directions; signed vs unsigned; nested loops; long displacements |
| `branch_hazard` | Branches and `JALR` whose operands come from the immediately preceding instruction or load |
| `jump_link` | Link values, `JALR` LSB clearing, `rd == rs1`, call/return |
| `mem_align` | Every load/store width at every legal alignment, with neighbour-byte checks |
| `x0_writes` | `x0` as destination of every instruction format |
| `csr_basic` | Zicsr semantics, read-only enforcement, counter monotonicity |
| `csr_perf` | Performance counter semantics and all writable CSRs |
| `trap_exceptions` | All 9 exceptions, each checked for cause, `mtval` **and** `mepc` |
| `illegal_encodings` | Every reserved encoding inside an otherwise-valid opcode |
| `irq_timer` | Interrupt gating, cause encoding, mid-loop delivery, MRET restoration |

### 13.2 Notable properties asserted

- An illegal instruction asserts **no enable of any kind** — verified across 2M
  random instruction words.
- A faulting store leaves memory **unchanged**.
- The interrupt test reports **identical trap and instruction counts at every
  latency** from 0 to 8 and across random seeds — the evidence that no
  instruction is executed twice.
- Mutation testing distinguishes "survived" from "untested": each equivalent
  mutant is paired with a combined mutation that disables *both* redundant
  mechanisms and is killed.

---

## 14. Building and running

### Prerequisites

| Tool | Needed for |
|---|---|
| Verilator 5.x | All simulation and lint |
| g++ / clang++ (C++17) | Testbench harnesses |
| RISC-V cross compiler | Test programs (auto-detected; several prefixes accepted) |
| GNU make, python3, git | Build system and generators |
| yosys + sv2v | `make synth` only (sv2v fetched automatically) |
| gtkwave | Viewing `make wave` output only |

### Quick start

```sh
make riscv-tests-fetch      # pull third_party/riscv-tests
make tools                  # confirm the toolchain
make test                   # the full acceptance gate
```

### Targets

| Target | Action |
|---|---|
| `make lint` | Verilator lint over all RTL |
| `make unit` | Build and run every unit testbench |
| `make e_core` | Build the integration simulator |
| `make asm-tests` | Directed assembly, at 4 memory latencies each |
| `make sw-tests` | Compile and run the C programs |
| `make riscv-tests` | The `rv32ui-p` compliance suite |
| `make random` | Randomised lockstep against the golden ISS |
| `make mutation` | Verify the tests detect deliberately broken RTL |
| `make coverage` | Coverage build and report |
| `make synth` | Yosys area estimate |
| `make wave TEST=<name>` | Rerun one test with tracing → `build/<name>.vcd` |
| `make test` | Everything except synth — the acceptance gate |
| `make clean` | Remove build products |

### Simulator options

```
e_core_sim --elf=PROG.elf [options]
  --waits=0 | --waits=N | --waits=random[:SEED]   memory latency model
  --max-cycles=N                                  timeout (default 1,000,000)
  --trace=FILE.vcd                                waveform dump
  --log=FILE                                      per-instruction retirement trace
  --uart-out=FILE                                 capture UART output
  --lockstep                                      compare against the golden ISS
  --quiet                                         suppress the summary line
```

Any failure prints the PC, instruction word, disassembly and the last 50
retired instructions.

---

## 15. Design decisions and rationale

| Decision | Why |
|---|---|
| **Branches resolve in ID, not EX** | Halves the taken-branch penalty to 1 cycle for one adder and one comparator. With no branch predictor, every taken branch pays it. |
| **Register file is not reset** | Lets it infer as distributed RAM rather than 1,024 flip-flops — confirmed by 12 `RAM32M` in synthesis. Simulation determinism comes from an `` `ifndef SYNTHESIS `` zero-fill. |
| **Write-first bypass is explicit** | Read-during-write semantics differ between simulation, FPGA block RAM and ASIC compilers. An explicit mux behaves identically everywhere and is directly testable. |
| **IF has a one-entry skid buffer** | Without it, throughput caps at 0.5 IPC even with zero-latency memory. |
| **Fetch address is separate from the PC** | A branch redirect must not change the address of a request the memory has already accepted. |
| **CSR reads stall rather than forward** | Forwarding them would add a CSR decode to the branch comparator's path — paid on every branch, to speed up a rare instruction. |
| **Memory ports permit same-cycle response** | That is what a cache hit looks like; the protocol exists so the core drops behind a cache unchanged. |
| **Loads and stores are not interruptible** | A memory access commits at grant, before completion; interrupting there would re-execute it after `MRET`. |
| **`ALU_ADD` encoded `4'b1111`** | Puts a common operation on the `default` case arm so it is reachable, instead of leaving dead code that caps coverage. Same trick for `SZ_WORD`. |
| **Decoder exposes individual ports** | A packed struct on a port becomes an opaque vector in Verilator, so the testbench would have to reproduce the bit layout by hand and break silently when a field is added. |
| **Illegal instructions squashed in one place** | A single block forces every enable low, so a future decode addition cannot forget to. |
| **All stall logic in one module** | Makes the stall behaviour reviewable and testable rather than an emergent property of five files. |
| **RVFI implemented from the start** | The retirement log, failure dumps and the lockstep checker all share one mechanism instead of three. |

---

## 16. Limitations

| Limitation | Consequence | Rationale |
|---|---|---|
| Misaligned accesses trap; no hardware fixup | `ma_data` from the compliance suite cannot pass | By specification. Covered by `mem_align.S` and the misaligned cases in `trap_exceptions.S`. |
| No instruction cache | `fence_i` cannot distinguish a correct implementation from a broken one | `FENCE.I` decodes as an architectural NOP. |
| No M extension | `MUL`/`DIV`/`REM` trap; C code links libgcc for `__divsi3` etc. | By specification. Asserted by `illegal_encodings.S`. |
| Loads and stores not interruptible | An interrupt is deferred to the next non-memory instruction | Correctness, not an oversight — see §7.3. |
| Toggle coverage 82% | Cannot reach 95% | ~1,300 of 2,520 unhit points are structurally unreachable: `mie`/`mip` have 3 implemented bits of 32, six counters are 64-bit with upper halves needing 2³² events, and every address lives in a 192 KiB memory so bits 18+ are always zero. |
| Lockstep excludes cycle-dependent CSRs and interrupts | Not compared against the reference | Not architecturally predictable. Covered by directed tests instead. |
| No timing closure | Area estimate only | No constraints applied, no place-and-route run. |

---

## Related documents

| Document | Contents |
|---|---|
| [`e_core_microarchitecture.md`](e_core_microarchitecture.md) | Deeper microarchitectural argument, stall/forwarding tables |
| [`e_core_verification_plan.md`](e_core_verification_plan.md) | Full test matrix, coverage analysis, mutation results |
| [`e_core_results.md`](e_core_results.md) | Compliance table, benchmark numbers, area breakdown |
| [`lab_notebook.md`](lab_notebook.md) | Every design decision and bug, with root causes |
| [`../README.md`](../README.md) | Build and run instructions |
