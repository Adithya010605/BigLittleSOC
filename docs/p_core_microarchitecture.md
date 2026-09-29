# P-Core Microarchitecture

RV32IM_Zicsr_Zifencei, machine mode only, five-stage in-order pipeline with
dynamic branch prediction. This is Phase 2 of the plan in
`RISC-V_SoC_Project_Plan.md` (weeks 5–7): the performance core of the
big.LITTLE pair.

The P-core has **exactly the same external interface as the E-core** — both
valid/ready memory ports, the three interrupt pins and the RVFI trace — so the
two drop into the same testbench now and the same SoC slot later.

| Property | Value |
|---|---|
| ISA | RV32I + M + Zicsr + Zifencei, machine mode (`misa = 0x4000_1100`) |
| Pipeline | 5 stages: `IF` → `ID` → `EX` → `MEM` → `WB` |
| Branch prediction | 256-entry 2-bit BHT (`pc[9:2]`) + 64-entry direct-mapped BTB (`pc[7:2]`, full tag) |
| Branch resolution | In EX; mispredict penalty 2 cycles; correctly predicted taken branch: 0 |
| Forwarding | EX→EX, MEM→EX (into EX), MEM→MEM (store data) |
| Interlock | Load-use / CSR-use: 1 cycle at zero wait states; none for load→store data |
| Multiply | Radix-4 Booth, iterative, 4 cycles in EX |
| Divide | Restoring, 1 bit/cycle, 33 cycles in EX, abandoned on a flush |
| Commit point | MEM: all traps precise, taken at MEM |
| FENCE.I | Flush and refetch at commit |
| Area (Xilinx 7-series, Yosys) | see `docs/p_core_results.md` |

## 1. Pipeline

```
          +--------+     +--------+     +-------------+     +---------+     +------+
 fetch -->|   IF   |---->|   ID   |---->|     EX      |---->|   MEM   |---->|  WB  |
          |        |IF/ID|        |ID/EX|             |EX/  |         |MEM/ |      |
          | BPU    |     | decode |     | fwd muxes   |MEM  | LSU     |WB   | reg  |
          | lookup |     | regfile|     | ALU         |     | data    |     | file |
          | skid   |     | imm    |     | branch cmp  |     |  port   |     | write|
          | buffer |     |        |     | target add  |     | CSR     |     |      |
          |        |     |        |     | MUL / DIV   |     | trap    |     |      |
          +--------+     +--------+     +-------------+     +---------+     +------+
             ^   ^                         |    |   ^  ^       |   |  ^         |
             |   |  mispredict redirect    |    |   |  |       |   |  |         |
             |   +-------------------------+    |   |  +-------+   |  +---------+
             |        trap / MRET / FENCE.I     |   |  EX->EX      |   MEM->MEM
             +----------------------------------+---+--------------+   (store data)
                                                    |  MEM->EX
                                                    +----------- WB
```

| Stage | File | Holds the register | Does |
|---|---|---|---|
| IF | `p_core_if_stage.sv`, `p_core_bpu.sv` | IF/ID + 1-entry skid | predicted fetch, one request in flight, wrong-path discard |
| ID | `p_core_id_stage.sv` | — (combinational) | decode (`decoder` with `RV32M = 1`), immediate, write-first register file read |
| EX | `p_core_ex_stage.sv`, `p_core_mul.sv`, `p_core_div.sv` | ID/EX | forwarding, ALU, branch resolution and mispredict check, multiply, divide |
| MEM | `p_core_mem_stage.sv` | EX/MEM, MEM/WB | LSU, data port, CSR access, trap sources, commit, RVFI |
| WB | (MEM/WB register) | — | register-file write |
| control | `p_core_hazard.sv` | — | every stall, flush, bubble and forwarding select |
| traps | `rtl/e_core/e_core_trap.sv` | — | the E-core's trap unit, reused unchanged |

Pipeline registers live in the stage that consumes them, as in the E-core.
Each carries a valid bit; a flush clears it.

## 2. Instruction fetch and branch prediction

### 2.1 Fetch

The fetch stage is the E-core's, with one change. It keeps:

* **one request in flight**, issued only when the skid buffer is free, so a
  response always has somewhere to land;
* a **one-entry skid buffer**, which is what lets it fetch one instruction
  per cycle against a memory that may answer in the request cycle, while ID
  may stall at any time;
* the **in-flight address (`fetch_addr_q`) separate from the next-fetch
  address (`pc_q`)**, so a redirect never changes the address of a request
  the memory has already seen; the wrong-path response is discarded instead.

The change: the next address is **predicted** rather than always `+4`.

### 2.2 Where the prediction is made

The predictor is looked up with `fetch_addr_q` — a register, so the lookup
starts at the clock edge rather than behind the redirect mux. The prediction is
consumed in the cycle the response arrives, when it becomes both the next
fetch address and the predicted next pc recorded beside the instruction in
IF/ID. Taking both from the same lookup in the same cycle guarantees that the
prediction EX later checks is exactly the one that steered fetch, even when the
predictor is retrained while the request is outstanding.

With a zero-latency memory, a correctly predicted taken branch costs **no**
bubble.

### 2.3 The predictor (`p_core_bpu.sv`)

| Table | Geometry | Contents | Reset |
|---|---|---|---|
| BHT | 256 × 2 bits, indexed `pc[9:2]` | saturating counter; MSB = predict taken | none (RAM); sim init weakly-not-taken |
| BTB | 64 entries, indexed `pc[7:2]` | valid, tag `pc[31:8]`, target `pc[31:2]`, jump flag | valid bits only |

A pc is predicted taken when the BTB **hits** and the entry is a jump or the
BHT counter's MSB is set. Without a BTB hit there is no target, so the
prediction is always fall-through.

Training happens once per instruction, as it leaves EX:

| Instruction | BHT | BTB |
|---|---|---|
| conditional branch | `sat(counter read at prediction, actual direction)` | write `{pc, taken target, jump=0}` if taken, or if it already had an entry; a never-taken branch does not claim a slot |
| JAL / JALR | — | write `{pc, target, jump=1}` |
| anything else | — | invalidate the entry if it hit (it is stale, e.g. after self-modifying code) |

The BHT is trained from the counter value carried down the pipeline with the
instruction, rather than re-read in EX, so it needs no second read port. Two
in-flight copies of one branch then train from the same old value, which loses
at most one step of hysteresis and never affects correctness.

**Prediction never affects correctness.** EX compares every instruction's
actual next pc with the predicted one, so a wrong prediction, a stale entry or
uninitialised table contents cost cycles only. That is what lets the tables be
RAM without reset.

## 3. Decode (ID)

ID is purely combinational: the shared `decoder` elaborated with `RV32M = 1`,
the shared `imm_gen`, and the shared write-first `regfile`. Nothing is
resolved in ID — unlike the E-core, which resolves branches there. The only
bypass in ID is the register file's own write-first path, which covers the
instruction in WB writing the register being read.

The ID stage is where the **interlock** holds an instruction (§5.3).

## 4. Execute (EX)

### 4.1 Operand forwarding

Each source operand is selected, in priority order, from

1. **MEM** — the EX/MEM result of the instruction one ahead (EX→EX path);
2. **WB** — the MEM/WB value of the instruction two ahead (MEM→EX path);
3. the value captured into ID/EX.

MEM wins over WB because it is the younger of the two producers and so holds
the newer value. MEM forwards only a value made in EX: a load's data and a
CSR read's value are produced *during* MEM, and the interlock keeps any
consumer of those out of EX until the producer reaches WB.

The forwarded operands feed the ALU, the branch comparator, the JALR target,
the multiplier and divider, the CSR write value and the store data.

### 4.2 Operand refresh

An instruction can sit in EX for many cycles — on the multiplier, the divider,
or behind a MEM stage waiting on memory — while the instructions ahead of it
drain out of WB. A value it was receiving by forwarding would then vanish with
its producer. So **whenever the ID/EX register is not being loaded, the
forwarded operands are written back into it.** The held instruction always
holds the latest value of each source register, and a producer that has left
the pipeline is no longer needed. (Mutation `no_operand_refresh` confirms the
randomised programs depend on this.)

### 4.3 Branch resolution and misprediction

For **every** instruction EX computes the actual next pc — `pc + 4` unless it
is a taken branch or a jump — and compares it with the predicted next pc. Any
difference is a mispredict: wrong direction, wrong target (JALR to a new
address, a BTB alias), or a BTB hit on an instruction that is not a branch at
all. The comparison uses a second `alu` instance as the branch comparator
(`rs1 - rs2`), as the E-core does, because the main ALU is busy with
`rs1 + imm` during a branch.

The redirect is raised **only when the instruction leaves EX**. A branch held
in EX behind a busy MEM does not flush the front end repeatedly.

A control transfer to a misaligned target is **not** a mispredict: the
instruction raises instruction-address-misaligned at MEM, the trap redirects to
`mtvec`, and fetch never goes to the misaligned address in the meantime. Such
an instruction also does not train the predictor.

Penalty: a mispredicted instruction redirects fetch in the cycle it leaves EX,
so the two younger instructions (in ID and IF) are lost — **2 cycles**.

### 4.4 Multiplier (`p_core_mul.sv`) — 4 cycles

Radix-4 Booth, four digits per cycle. The multiplicand is extended to 64 bits
(sign or zero); the multiplier is Booth-recoded **as a signed 32-bit number**
into 16 digits in {−2, −1, 0, +1, +2}. An unsigned multiplier with its top bit
set is worth 2³² more than its signed reading, so for MULHSU and MULHU the
correction `a << 32` is loaded into the accumulator as its starting value. The
Booth datapath therefore only ever sees a signed multiplier, and all four
operations are the same 64-bit product with different operand extension and a
different half returned.

The first iteration runs in the cycle the operation starts, straight from the
operands, so the 16 digits take exactly 4 cycles and the product is available
in the 4th.

### 4.5 Divider (`p_core_div.sv`) — 33 cycles

Restoring division on magnitudes, one quotient bit per cycle, signs fixed
afterwards (quotient negative when exactly one operand is; remainder takes the
dividend's sign). The dividend register doubles as the quotient register. The
ISA's special cases:

* **divide by zero** — the loop naturally yields all-ones and the dividend's
  magnitude; REM/REMU get the dividend back after the sign fix. The quotient is
  forced to all-ones, because the sign fix would otherwise negate it for a
  negative dividend.
* **overflow** (−2³¹ / −1) — magnitudes 2³¹ / 1 give quotient 2³¹, remainder
  0, signs agree, so `0x8000_0000` falls out exactly.

One setup cycle plus 32 iterations: 33 cycles in EX.

### 4.6 Handshake with EX, hold and kill

Both units share one handshake:

| Signal | Meaning |
|---|---|
| `start_i` | EX holds a valid multiply/divide; sampled only when the unit is idle |
| `done_o` | the result is on `result_o` this cycle |
| `ack_i` | the instruction leaves EX (the result has been taken) |
| `kill_i` | the instruction in EX is flushed: abandon the operation |

Operands are **captured when the operation starts**, so the operand refresh
may rewrite them underneath a running operation without effect. If EX cannot
hand the result on in the cycle it appears (MEM busy), the result is **held**
in `result_q` with `done_o` high until `ack_i`.

`kill_i` is what makes the divider *interruptible*: an interrupt taken on the
instruction ahead of it in MEM flushes EX, the operation is abandoned, and it
restarts from scratch when the handler returns. An interrupt never waits for a
divide.

## 5. Hazards and pipeline control (`p_core_hazard.sv`)

### 5.1 Advance

The pipeline drains from the back:

```
mem_free   = MEM empty  or  MEM completes this cycle
ex_advance = EX valid  and  EX ready (result exists)  and  mem_free  and  no MEM flush
ex_free    = EX empty  or  ex_advance
id_advance = IF/ID valid  and  ex_free  and  no interlock  and  no flush
```

A stage that is free but receives nothing is loaded with a bubble.

### 5.2 Flushes

| Flush | Raised by | Kills | Redirect to |
|---|---|---|---|
| `flush_mem` | trap entry, MRET, or FENCE.I retiring, in MEM | EX (including a running MUL/DIV), ID, IF | `mtvec` / `mepc` / `pc + 4` |
| `flush_ex` | a mispredicted instruction leaving EX | ID, IF | its actual next pc |

`flush_mem` wins: the instruction in MEM is older. A simulation assertion
checks the two are never both acted on.

### 5.3 Interlock — the only data-hazard stall

A load's data and a CSR read's value are produced during MEM, too late to be
forwarded from MEM into EX. An instruction in ID that reads such a value is
held until the producer will be at least in WB when the consumer is in EX:

| Producer (load / CSR read) is… | Consumer in ID |
|---|---|
| in EX | hold (next cycle the producer is in MEM at best) |
| in MEM, not completing this cycle | hold |
| in MEM, completing this cycle | **release**: next cycle producer in WB, consumer in EX, MEM→EX supplies it |

With a single-cycle memory that is exactly the classic one-cycle load-use
bubble; a slower memory extends it automatically.

**Exemption — store data.** A store's `rs2` is not needed until the store is in
MEM, by which time the load is in WB. The MEM stage takes the store data from
MEM/WB directly (§6.2), so a load followed by a store of the loaded value — a
copy loop — runs without a bubble. The store's *address* operand (`rs1`) is not
exempt.

### 5.4 Cases and costs (zero wait states)

| Sequence | Stall cycles |
|---|---:|
| ALU → dependent ALU (distance 1, 2, 3) | 0 |
| load → dependent ALU / branch / address | 1 |
| load → store data | 0 |
| CSR read → dependent instruction | 1 |
| CSR read → store data | 0 |
| MUL → anything | 3 (MUL occupies EX 4 cycles) |
| DIV → anything | 32 (DIV occupies EX 33 cycles) |
| correctly predicted branch/jump, taken or not | 0 |
| mispredicted branch/jump | 2 |

## 6. Memory, commit and write-back (MEM, WB)

### 6.1 MEM is the commit point

An instruction is architecturally complete when it leaves MEM without
trapping. Everything with an effect outside the pipeline happens there and
nowhere earlier: the data access, the CSR write, trap entry, MRET and the
FENCE.I refetch. That is what makes every trap precise: anything younger is
still in EX, ID or IF, has done nothing observable, and is simply flushed. WB
only writes the register file with a value MEM has already committed, and the
RVFI trace is emitted at MEM.

Everything that makes an instruction trap, apart from a bus error, is known
before its access is issued (misaligned address, illegal, ECALL, EBREAK,
misaligned jump target, faulting fetch), so a faulting access never reaches
the bus. `data_req_o` depends only on registers, never combinationally on
`data_gnt_i` or `data_rvalid_i`.

### 6.2 MEM→MEM forwarding and store-data refresh

When the instruction in WB wrote the store's `rs2`, the store data is taken
from MEM/WB. As in EX, the forwarded value is written back into EX/MEM while
the store waits in MEM, which also keeps `data_wdata_o` stable from request to
grant as the protocol requires (a simulation assertion checks this).

### 6.3 Traps

Trap prioritisation is the E-core's `e_core_trap.sv`, reused unchanged, fed
from MEM. Priority, highest first: instruction-address-misaligned,
instruction access fault, illegal instruction, breakpoint, load misaligned,
load access fault, store misaligned, store access fault, ECALL. Interrupts
take precedence over synchronous exceptions and are taken only on a
non-memory instruction (a memory access commits at the bus on grant, so
interrupting it would repeat it after MRET — see the E-core documentation).

`mepc` is the pc of the instruction in MEM. A divide or multiply running in EX
behind it is abandoned (§4.6).

### 6.4 FENCE.I

The P-core fetches up to three instructions ahead of a store in MEM, so a
FENCE.I that did nothing would let stale instructions execute. FENCE.I is
therefore implemented as a **flush and refetch of `pc + 4` when it retires**,
after every older store has been performed. Stale BTB entries need no special
handling: they are caught as mispredicts and invalidated (§2.3).

## 7. CSRs and performance counters

The CSR file is the shared `csr_unit.sv`, elaborated with `MISA = 0x4000_1100`
and `NUM_HPM = 7`. The first four event counters have exactly the E-core's
semantics, so the two cores are compared counter for counter.

| CSR | Event |
|---|---|
| `mcycle` / `minstret` | cycles / instructions retired |
| `mhpmcounter3` | cycles ID held a valid instruction back (stall) |
| `mhpmcounter4` | conditional branches retired |
| `mhpmcounter5` | …of which taken |
| `mhpmcounter6` | loads and stores retired |
| `mhpmcounter7` | **P-core:** instructions retired that redirected fetch from EX (mispredicts) |
| `mhpmcounter8` | **P-core:** cycles EX waited on the multiplier or divider |
| `mhpmcounter9` | **P-core:** cycles the load-use / CSR-use interlock held ID |

`mhpmcounter10` and up (and their high halves) do not exist and raise
illegal-instruction. The plan also lists cache-miss counters; there are no
caches yet (Phase 3).

## 8. Changes to shared modules

The P-core reuses `alu`, `regfile`, `imm_gen`, `lsu`, `decoder`, `csr_unit` and
`e_core_trap` from the E-core. Two shared modules gained parameters, with
defaults that leave the E-core exactly as it was (its full regression was
re-run to confirm):

| Module | Change |
|---|---|
| `decoder.sv` | `RV32M` parameter; outputs `md_en_o`, `md_op_o` (M extension, zero when `RV32M = 0`) and `fence_i_o` |
| `csr_unit.sv` | `MISA` and `NUM_HPM` parameters; the event inputs became one vector `hpm_event_i`, and the counter block is decoded by offset instead of one case arm per counter |

## 9. Design decisions

* **Branches resolve in EX, not ID.** The E-core resolves in ID to keep its
  taken-branch penalty at one cycle without a predictor. The P-core has a
  predictor, so the common case — a correctly predicted branch — costs
  nothing wherever it resolves, and resolving in EX keeps the forwarding muxes
  and the comparator out of the decode stage. The price is a 2-cycle
  mispredict penalty.
* **Every instruction is checked, not just branches.** Comparing the actual
  and predicted next pc for all instructions makes BTB aliasing, stale entries
  after self-modifying code, and uninitialised tables all harmless, and is
  what allows the tables to be un-reset RAM.
* **The interlock is in ID; forwarding is into EX.** Deciding the stall in ID
  (the plan's "detect in ID, stall IF+ID") means EX never holds an instruction
  whose operand does not exist yet, so the EX stage needs no data-hazard stall
  of its own.
* **Store data is exempt from the interlock.** A copy loop (`lw` then `sw` of
  the same register) is common in real code (`memcpy_test`, and Dhrystone's
  record copies); MEM→MEM forwarding makes it free.
* **Operand refresh rather than more forwarding.** Writing the forwarded
  operands back into ID/EX while an instruction waits costs a mux on the
  register's input. The alternative — forwarding from the register file's
  write port, or a third forwarding source — costs more and still misses the
  case of a producer that has already been written back.
* **MEM is the commit point.** It is the stage where the data access happens,
  so committing there gives precise traps without a separate commit stage, and
  it lets the E-core's trap unit be reused unchanged.
* **Multi-cycle units hold their result.** Without the hold, a result that
  appeared while MEM was busy would be lost and recomputed — functionally
  invisible, but a performance bug. The P-core's event counters make it
  visible, and the mutation suite checks that they do.
