# E-Core Microarchitecture

A three-stage, in-order, single-issue RV32I_Zicsr core, machine mode only,
targeting under 5K LUTs. This is the "LITTLE" core of the big.LITTLE pair in
`RISC-V_SoC_Project_Plan.md` section 2.1.

**Status:** complete. Measured numbers referenced here are in
[`e_core_results.md`](e_core_results.md).

---

## 1. Scope

Implemented: the full RV32I base integer instruction set, `FENCE` and `FENCE.I`
as architectural NOPs, and (from M5) the Zicsr instructions with a machine-mode
CSR file, trap entry, `MRET`, and timer/software/external interrupts.

Deliberately absent:

| Not implemented | Consequence |
|---|---|
| M extension | `MUL`/`DIV`/`REM` raise illegal-instruction; multiply and divide are done in software via libgcc |
| Compressed instructions | `instr[1:0] != 2'b11` raises illegal-instruction |
| Floating point | no F/D state, no `fcsr` |
| User and supervisor modes | machine mode only; `mstatus.MPP` is hardwired to `2'b11` |
| Branch prediction | static not-taken, no BHT, no BTB |
| Caches, MMU, PMP | the two memory ports are raw valid/ready |
| Misaligned access fixup | misaligned loads and stores trap; hardware never splits an access |

Decoding is **closed**: every 32-bit word either matches a legal encoding or
asserts `illegal_instr_o`. There is no silent-NOP fallback, and an illegal
instruction asserts no enable of any kind.

## 2. Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `RESET_VECTOR` | `32'h0000_0000` | PC after reset |
| `HART_ID` | `32'h0000_0000` | value read from `mhartid` |
| `RVFI` | `1'b0` | exposes the riscv-formal trace port; tied off and pruned when clear |

## 3. Pipeline structure

```
        ┌───────────────────────┐   ┌────────────────────────┐   ┌──────────────────────────┐
        │  S1  IF               │   │  S2  ID / RF           │   │  S3  EX / MEM / WB       │
        │                       │   │                        │   │                          │
  ─────▶│  pc_q, fetch_addr_q   │──▶│  decoder               │──▶│  ALU                     │──▶ regfile write
        │  instr port handshake │   │  imm_gen               │   │  LSU (be, align, extend) │
        │  skid buffer          │   │  regfile read (2 port) │   │  data port handshake     │
        │  redirect mux         │   │  forward muxes         │   │  csr_unit  (M5)          │
        │                       │   │  branch comparator     │   │  trap unit (M5)          │
        │                       │   │  target adder          │   │                          │
        └───────────────────────┘   └────────────────────────┘   └──────────────────────────┘
                    │  IF/ID reg                  │  ID/EX reg                  │
                    │  valid,pc,instr,err         │  valid,pc,instr,ctrl,       │
                    │                             │  rs1,rs2,imm,rd,...         │
                    ▼                             ▼                             ▼
              flushed on redirect           bubble on interlock          result forwarded back to S2
```

Both pipeline registers carry a `valid` bit. A flush clears `valid` rather than
zeroing the payload, so no datapath signal has to be reset for correctness.

The IF/ID register lives inside `e_core_if_stage`; the ID/EX register lives
inside `e_core_ex_stage`. Each stage therefore owns its own input boundary, and
`e_core_top` contains no control logic beyond RVFI trace assembly.

### 3.1 Why the IF stage has a skid buffer

The instruction port may answer in the request cycle or many cycles later, and
ID may stall at any time, so a returning instruction can arrive when IF/ID is
still occupied.

The simple rule — do not issue a fetch until IF/ID is empty — is correct but
caps throughput at **0.5 IPC even with a zero-latency memory**, because a
response cannot arrive before the cycle after the request, so IF/ID is refilled
only every other cycle.

A single-entry skid buffer removes that restriction: a fetch is issued whenever
the skid is free, and a response that finds IF/ID occupied waits in the skid
until it drains. At most one request is in flight and at most one instruction is
buffered. Cost: one 32-bit register plus a valid bit. Benefit: 1 IPC on
straight-line code.

### 3.2 Why the fetch address is a separate register from the PC

`instr_addr_o` must hold still from the cycle a request is asserted until it is
granted. A branch resolving in S2 can redirect the PC inside that window.

`fetch_addr_q` holds the address of the request in flight; `pc_q` holds the
address to fetch next. A redirect changes `pc_q` only, so an outstanding request
keeps presenting the address the memory already saw, and its wrong-path response
is consumed and discarded via `discard_q`. The alternative — dropping `req`
before `gnt` — is a protocol violation a real slave would be entitled to
mishandle.

---

## 4. Hazards

All stall, flush and forwarding decisions are made in `e_core_hazard.sv`. No
stage file contains a stall term.

### 4.1 Forwarding table

| Source (S3) | Destination (S2) | Condition | Action |
|---|---|---|---|
| ALU result | ALU operand A | `idex_valid & rf_we & rd != x0 & rd == rs1 & rs1_used` | `fwd_rs1` selects `ex_result` |
| ALU result | ALU operand B | same, with rs2 | `fwd_rs2` selects `ex_result` |
| ALU result | branch comparator | same | comparator reads the forwarded operands |
| ALU result | JALR target adder | same, rs1 only | target adder reads the forwarded rs1 |
| ALU result | store data (rs2) | same, with rs2 | LSU receives the forwarded value |
| JAL/JALR link (PC+4) | any of the above | same | `ex_result` is `pc + 4` for `WB_PC4` |
| **Load data** | — | — | **not forwarded**: stall instead (§4.2) |
| **CSR read value** | — | — | **not forwarded**: stall instead (§4.3) |

Forwarding is suppressed when `rd == x0`, so an instruction that nominally
writes x0 cannot leak its discarded result to a consumer.

### 4.2 Stall table

| Condition | Detected by | S1 | S2 | S3 | Duration |
|---|---|---|---|---|---|
| Load in S3, its `rd` read by S2 | `ex_result_late & dependency` | hold | hold | bubble | 1 cycle at zero wait states; extends automatically until `rvalid` |
| CSR instruction in S3, its `rd` read by S2 | same term, `csr_en` | hold | hold | bubble | as above |
| Data memory access outstanding | `~ex_ready` | hold | hold | hold | until `data_rvalid_i` |
| Instruction fetch outstanding, IF/ID and skid both full | fetch not issued | — | — | — | until IF/ID drains |

There is no separate multi-cycle stall case to get right. `ex_ready_o` is low
for as long as a memory access is outstanding, so a slow memory extends the same
term that a fast memory satisfies in one cycle.

### 4.3 Why CSR reads stall instead of forwarding

The CSR read value is produced by `csr_unit` late in S3, after address decode
and the read-only/WARL checks. Routing it into the S2 operand muxes would put a
CSR address decode plus a mux into the branch comparator's path — a cost paid on
**every branch**, to speed up an instruction class that is rare. A one-cycle
stall on a dependent CSR read costs nothing measurable by comparison.

### 4.4 A measured redundancy, recorded honestly

Mutation testing (`make mutation`) established two facts that are not obvious
from reading the RTL:

1. **The forward muxes and the write-first register file are exactly
   redundant.** Both are qualified by `rf_we_o` and both carry `rf_wdata`, so
   they deliver the same value in the same cycle. Disabling either alone changes
   nothing observable; only removing both breaks the design.

2. **The load-use interlock is not required for correctness in this
   configuration.** `ex_ready_o` implies `data_rvalid_i`, so by the cycle a load
   retires its data is valid, `rf_we_o` is asserted, and the write-first register
   file hands the value to S2 in that same cycle.

Both mechanisms are specified and both are implemented. The redundancy is
recorded rather than removed because the forward muxes stay correct if the
register file is ever replaced by a bypass-free memory macro — the likely
direction for an ASIC flow — and the interlock is the only thing that would then
keep memory read data out of the S2 operand path.

The consequence worth knowing: as built, the core pays the CPI of the interlock
*and* carries the long path through the register file bypass. A coherent
alternative would drop one or the other.

---

## 5. Control transfer

### 5.1 Branch resolution in ID, and the alternative

Branches and jumps resolve in **S2**, using a comparator and a PC+immediate
adder that are dedicated hardware, separate from the main ALU in S3.

| | Resolve in S2 (chosen) | Resolve in S3 (rejected) |
|---|---|---|
| Wrong-path instructions on a taken branch | 1 (the one in S1) | 2 (S1 and S2) |
| Taken-branch penalty | **1 cycle** | 2 cycles |
| Extra hardware | one 32-bit comparator, one 32-bit adder | none; reuses the main ALU |
| Operand source | forwarded S3 result or register file | already in the ID/EX register |

With static not-taken prediction and no BTB, every taken branch pays the
penalty, so halving it is worth one adder and one comparator on a core whose
budget is 5K LUTs. The comparator is an instance of `alu` driven as a
subtraction, which is how that module exports `cmp_eq`/`cmp_lt`/`cmp_ltu`;
reusing it means the signed and unsigned comparison logic exists once in the
design and is covered once by `tb_alu`.

`JALR` computes `(rs1 + imm) & ~32'b1` in the same stage, with bit 0 cleared and
bit 1 left intact, per the ISA.

### 5.2 Redirect qualification

A redirect fires only when the redirecting instruction actually advances into
S3 (`id_advances & id_take_branch`). Redirecting while the instruction is
stalled would flush S1 and re-fetch the same target once per stalled cycle.

### 5.3 Branch penalty derivation

At zero wait states, with a branch at address A resolving in S2 during cycle N:

| Cycle | Without branch | With taken branch to T |
|---|---|---|
| N | branch in S2; A+4 returning | branch in S2; A+4 returning, then flushed |
| N+1 | A+4 in S2 | fetch T issued and returned |
| N+2 | A+8 in S2 | T in S2 |

The instruction stream resumes one cycle later than it would have — a **1-cycle
penalty**, matching the plan's "static not-taken, flush 1".

---

## 6. CSR map and trap priority

### 6.1 CSR map

All machine mode. A write to a read-only register, or any access to a register
not listed here, raises illegal-instruction. `CSRRS`/`CSRRC` with `rs1 == x0`
do not write, and so remain legal against a read-only register — the decoder
computes that distinction and `csr_unit` acts on it.

| CSR | Address | Access | Behaviour |
|---|---|---|---|
| `mstatus` | `0x300` | RW | `MIE` (bit 3) and `MPIE` (bit 7) writable; `MPP` (bits 12:11) hardwired `2'b11` |
| `misa` | `0x301` | RO | `0x4000_0100` — MXL=1, extension `I` only |
| `mie` | `0x304` | RW | only `MSIE`(3), `MTIE`(7), `MEIE`(11) implemented; other bits read zero |
| `mtvec` | `0x305` | RW | direct mode only; the WARL mode bits are forced to zero |
| `mcountinhibit` | `0x320` | RW | `CY` (bit 0) and `IR` (bit 2) |
| `mscratch` | `0x340` | RW | plain register |
| `mepc` | `0x341` | RW | bit 0 hardwired zero |
| `mcause` | `0x342` | RW | bit 31 = interrupt, bits 4:0 = cause |
| `mtval` | `0x343` | RW | faulting address or instruction word |
| `mip` | `0x344` | RO | a read-only view of the three interrupt pins |
| `mcycle` / `mcycleh` | `0xB00` / `0xB80` | RW | 64-bit cycle counter, writable |
| `minstret` / `minstreth` | `0xB02` / `0xB82` | RW | 64-bit retired-instruction counter, writable |
| `mhpmcounter3` / `..3h` | `0xB03` / `0xB83` | RW | stall cycles |
| `mhpmcounter4` / `..4h` | `0xB04` / `0xB84` | RW | branch instructions |
| `mhpmcounter5` / `..5h` | `0xB05` / `0xB85` | RW | taken branches |
| `mhpmcounter6` / `..6h` | `0xB06` / `0xB86` | RW | loads and stores |
| `mvendorid`, `marchid`, `mimpid` | `0xF11`–`0xF13` | RO | zero |
| `mhartid` | `0xF14` | RO | the `HART_ID` parameter |

Counter semantics are given in [`e_core_results.md`](e_core_results.md)
section 3.2, because they are what the Phase 2 comparison depends on.

### 6.2 Trap priority

Highest first. `e_core_trap.sv` implements this as a priority chain, and
`trap_exceptions.S` checks the cause, `mtval` and `mepc` of every row.

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

On trap: `mepc` ← the PC of the faulting instruction, `mcause`/`mtval` set,
`mstatus.MPIE` ← `MIE`, `MIE` ← 0, PC ← `mtvec`.
On `MRET`: PC ← `mepc`, `MIE` ← `MPIE`, `MPIE` ← 1.

Hardware never advances `mepc`. That is required for an interrupt — the
instruction has not executed and must run on return — and is the specified
behaviour for every exception here; `ECALL` and `EBREAK` handlers advance it by
four themselves.

### 6.3 Interrupts

Cause codes 3 (software), 7 (timer) and 11 (external), with `mcause` bit 31
set. An interrupt is taken when `mstatus.MIE` is set and `mie & mip` is
non-zero. It takes precedence over any synchronous exception, because it is
taken *instead of* the instruction rather than because of it.

**Loads and stores are not interruptible.** A memory access commits at the bus
when the request is granted, which is before the instruction reaches its
completion cycle. Taking an interrupt there would leave the access performed
while `mepc` still pointed at the instruction, so `MRET` would perform it a
second time. For an ordinary store that is a silent double-write; for a store
to a device register it can livelock, which is how this was found. The
interrupt is simply taken on the next non-memory instruction instead.

`WFI` is implemented as a NOP. It is architecturally a hint, and with no
low-power state to enter, retiring it normally is both correct and simplest;
an enabled interrupt is then taken by the ordinary path.

---

## 7. Memory interface

Two independent ports, both using the same Ibex-style valid/ready handshake, so
the core drops behind a cache or onto the NoC in a later phase without change.

```
  req    ───┐ asserted until gnt, address held stable
  gnt    ───┘ the cycle the request is accepted
  rvalid ──── the cycle rdata/err are valid: SAME cycle as gnt, or any later
```

### 7.1 Why valid/ready rather than a simple synchronous memory

A single-cycle synchronous SRAM interface would be simpler and would work today,
but it fixes the latency into the pipeline control. Every later phase of the
project — L1 caches, the shared L2, the QoS interconnect — introduces variable
latency. Adopting the handshake now means the pipeline's back-pressure paths are
exercised from M2 onward by randomised wait states, rather than being written
and debugged later against a cache that is itself new.

The protocol permits `rvalid` in the **same** cycle as `gnt`, because that is
what a cache hit looks like. Refusing to model it would defeat the purpose.

### 7.2 The contract both sides rely on

`instr_req_o` and `data_req_o` are functions of core registers only. Neither
depends combinationally on its port's `gnt` or `rvalid`. This is what allows the
testbench's memory model to compute its response in a single settle pass per
cycle instead of iterating to a fixed point, and it is stated in both
`memory_model.h` and the RTL headers so neither side can quietly break it.

### 7.3 Byte enables and alignment

`lsu.sv` owns every byte-lane decision. Sub-word stores place their data by
replicating it across the word, so whichever lanes `be_o` enables hold the
correct bytes; replication is cheaper than a shifter and gives the same result.
Loads select and sign- or zero-extend on the way back. Misaligned accesses
assert `misaligned_o`, which the trap unit turns into cause 4 or 6.

---

## 8. Verification-relevant design choices

| Choice | Reason |
|---|---|
| `ALU_ADD` encoded `4'b1111`, `SZ_WORD` on `default` | puts a common operation on the `default` case arm so it is reachable, instead of leaving dead code that permanently caps line coverage |
| Register file array is not reset | allows inference as distributed RAM; resetting 1024 flops is the single biggest risk to the 5K LUT target. Simulation determinism comes from an `` `ifndef SYNTHESIS `` zero-fill, which the coding standard permits for memory initialisation |
| Decoder exposes individual ports, not a packed struct | Verilator flattens a packed struct on a port into an opaque vector, so the unit testbench would have to reproduce the bit layout by hand and would break silently when a field is added |
| Hazard unit takes four individual control bits | makes the dependency explicit in the port list; adding a control signal cannot silently change stall behaviour |
| Illegal instructions squashed in one place | a single block at the end of the decoder forces every enable low, so a future decode addition cannot forget to |
| RVFI implemented from M2 | the retirement log, the failure dump and the M7 lockstep checker all share one mechanism instead of three |
