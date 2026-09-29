# ALU, CSR Unit, and Instruction Fetch — Quick Reference

Three blocks: `rtl/common/alu.sv`, `rtl/common/csr_unit.sv`,
`rtl/e_core/e_core_if_stage.sv`.

Pipeline: **S1 fetch → S2 decode/register-read → S3 execute/memory/writeback.**
The ALU is in S3 (and a second copy in S2 as the branch comparator), the CSR
unit hangs off S3, fetch is S1.

---

## 1. ALU

### What it is
Combinational block. Takes an operation, two 32-bit operands, returns a result
plus three comparison flags.

```systemverilog
module alu (
  input  alu_op_e     operator_i,
  input  logic [31:0] operand_a_i, operand_b_i,
  output logic [31:0] result_o,
  output logic        cmp_eq_o, cmp_lt_o, cmp_ltu_o
);
```

### How it works

**One adder does add, subtract and both compares.**

```systemverilog
assign adder_b      = do_sub ? ~operand_b_i : operand_b_i;
assign adder_result = {1'b0, operand_a_i} + {1'b0, adder_b} + do_sub;
```

`do_sub` is 1 for SUB, SLT, SLTU. Subtraction is `a + ~b + 1`. The adder is
33 bits so the top bit is the carry-out.

```systemverilog
assign cmp_eq_o  = (adder_result[31:0] == 0);   // difference is zero
assign cmp_ltu_o = ~adder_result[32];           // no carry = borrow = a < b
assign cmp_lt_o  = signs_differ ? operand_a_i[31] : adder_result[31];
```

- Unsigned less-than is just the inverted carry-out.
- Signed less-than: if the signs are the same, the difference's sign bit is the
  answer. If the signs differ, the subtraction can overflow so that bit is
  unreliable — but then the answer is simply "is `a` negative".

**One right-shifter does SLL, SRL and SRA.**

```systemverilog
assign shift_operand = shift_left ? rev32(operand_a_i) : operand_a_i;
assign shift_input   = {shift_arith & shift_operand[31], shift_operand};
assign shift_result  = 32'($signed(shift_input) >>> shift_amt);
```

- **SRL**: extra top bit is 0, so the arithmetic shift behaves as logical.
- **SRA**: extra top bit is the sign, so the shift replicates it.
- **SLL**: bit-reverse the input, shift right, bit-reverse the output. A left
  shift is the mirror of a right shift, so no second shifter is needed.

**Result mux** picks between the adder output, the shifter output, the compare
results, and XOR/OR/AND.

### Operand sources (chosen in S3 from the decoder's control bits)

| Instruction | operand A | operand B | operation | result used as |
|---|---|---|---|---|
| ADD/SUB/AND… | rs1 | rs2 | from funct3/funct7 | writeback |
| ADDI/ANDI… | rs1 | imm | from funct3/funct7 | writeback |
| LUI | 0 | imm | ADD | writeback |
| AUIPC | PC | imm | ADD | writeback |
| LW / SW | rs1 | imm | ADD | memory **address** |
| JAL / JALR | – | – | – | writeback is `pc+4` |

Note there is no separate address adder — loads and stores use the ALU.

### Second use: branch comparator in S2
The same module is instantiated again with `operator_i` tied to `ALU_SUB`. Only
the compare outputs are used:

| Branch | condition |
|---|---|
| BEQ / BNE | `cmp_eq` / `~cmp_eq` |
| BLT / BGE | `cmp_lt` / `~cmp_lt` |
| BLTU / BGEU | `cmp_ltu` / `~cmp_ltu` |

Branches resolving in S2 means a taken branch flushes only one instruction →
**1-cycle penalty**.

---

## 2. CSR Unit

### What it is
Holds the machine-mode control/status registers, does the CSR read-modify-write,
and updates trap state and counters.

### The six CSR instructions

| Instruction | Operand | Writes CSR when | Reads CSR when |
|---|---|---|---|
| CSRRW / CSRRWI | rs1 / uimm | always | rd ≠ x0 |
| CSRRS / CSRRSI | rs1 / uimm | rs1 ≠ 0 | always |
| CSRRC / CSRRCI | rs1 / uimm | rs1 ≠ 0 | always |

The decoder works this out and passes `csr_write` in. Why it matters:
`csrrs t0, mip, x0` is **legal** (no write, so a read-only CSR is fine), but
`csrrw t0, mip, x0` is **illegal** (CSRRW always writes).

### Main registers

| CSR | Addr | Use |
|---|---|---|
| `mstatus` | 0x300 | MIE / MPIE — global interrupt enable |
| `mie` / `mip` | 0x304 / 0x344 | interrupt enable / pending |
| `mtvec` | 0x305 | trap handler address |
| `mepc` | 0x341 | PC of the trapping instruction |
| `mcause` | 0x342 | why the trap happened |
| `mtval` | 0x343 | faulting address or instruction |
| `mcycle`, `minstret` | 0xB00, 0xB02 | 64-bit cycle / retired-instruction counters |
| `mhpmcounter3–6` | 0xB03–0xB06 | stalls, branches, taken branches, memory ops |

### How it works

**Read** — one `case` on the 12-bit address gives `csr_rdata_o`, and sets two
flags: `exists` (address is implemented) and `read_only`.

**Legality:**
```systemverilog
assign csr_illegal_o = csr_en_i & (~exists | (read_only & csr_write_i));
```
Non-existent CSR, or a write to a read-only CSR → illegal instruction (cause 2).

**Modify:**
```systemverilog
CSR_OP_RS: wdata = csr_rdata_o |  csr_wdata_i;   // set bits
CSR_OP_RC: wdata = csr_rdata_o & ~csr_wdata_i;   // clear bits
default:   wdata = csr_wdata_i;                  // RW: replace
```

**Write — only if the instruction actually retires:**
```systemverilog
assign wr_en = csr_en_i & csr_write_i & csr_commit_i & exists & ~read_only;
```
`csr_commit_i` is the retire signal from S3 (`valid & ready & ~trap`). So a CSR
access that gets squashed by a trap in the same cycle leaves no trace.

**Trap entry / MRET** are applied after the explicit write, so they win:
```systemverilog
if (trap_i) begin
  mepc   <= faulting PC;   mcause <= {irq_flag, cause};   mtval <= tval;
  mstatus.MPIE <= mstatus.MIE;   mstatus.MIE <= 0;
end else if (mret_i) begin
  mstatus.MIE <= mstatus.MPIE;   mstatus.MPIE <= 1;
end
```
Hardware never advances `mepc` — the handler does that for ECALL/EBREAK.

**Counters** increment every cycle (`mcycle`) or on the relevant event
(`minstret` on retire, the `mhpmcounter`s on stall / branch / taken branch /
memory access). An explicit CSR write overrides the increment that cycle.

### Timing note
A CSR read is **not forwarded** to S2 — the value comes out late in S3, after
the address decode. A dependent instruction stalls one cycle instead.

---

## 3. Instruction Fetch (S1)

### What it owns
The PC, the instruction memory handshake, the IF/ID pipeline register, and a
one-entry **skid buffer**.

| Register | Purpose |
|---|---|
| `pc_q` | address to fetch **next** |
| `fetch_addr_q` | address of the request **in flight** |
| `fetch_active_q` | a request is outstanding |
| `fetch_gnt_q` | it has been granted |
| `discard_q` | it is on the wrong path |
| IF/ID reg | valid, pc, instr, err |
| skid buffer | valid, pc, instr, err |

Rule: **one request in flight, one instruction buffered — never more.**

### Bus interface
```systemverilog
assign instr_req_o  = fetch_active_q & ~fetch_gnt_q;
assign instr_addr_o = fetch_addr_q;
```
Both come from registers only, never combinationally from `gnt`/`rvalid`.
`req` stays asserted with a stable address until `gnt`; `rvalid` returns the
data the same cycle or later.

### Why the skid buffer
Memory latency is variable and ID can stall at any time, so a returning
instruction can arrive when IF/ID is still full.

The simple alternative — don't fetch until IF/ID is empty — works but gives
**0.5 IPC**, because the response can't arrive before the cycle after the
request. The skid buffer lets a fetch be issued whenever the skid is free, so a
response always has somewhere to land → **1 IPC**. Cost: one register.

### Why `fetch_addr_q` is separate from `pc_q`
A branch can redirect the PC while a fetch is still in flight. A redirect
changes `pc_q` only, so the outstanding request keeps showing the memory the
address it already accepted. The unwanted response is consumed and thrown away
using `discard_q`. Dropping `req` before `gnt` would break the bus protocol.

### The logic, in order (one `always_comb`)

1. record the grant
2. drain the skid buffer into IF/ID if there is room
3. accept the memory response → into IF/ID if free, else into the skid; if
   `discard_q` is set, throw it away
4. on a redirect: clear IF/ID and the skid, load the new PC, mark any in-flight
   fetch for discard
5. issue the next fetch if nothing is in flight and the skid is free

Order matters — the redirect comes after the response so it also kills an
instruction that arrived in the same cycle, and the new fetch comes last so it
uses the redirected PC.

### Operation examples

**Steady state, zero-latency memory:**

| Cycle | req / addr | rvalid | IF/ID after |
|---|---|---|---|
| 1 | 1 / 0x00 | 1 | A@00 |
| 2 | 1 / 0x04 | 1 | A@04 |
| 3 | 1 / 0x08 | 1 | A@08 |

**ID stalls one cycle — the skid catches the response:**

| Cycle | req / addr | ID accepts | IF/ID | Skid |
|---|---|---|---|---|
| 1 | 1 / 0x04 | yes | A@04 | – |
| 2 | 1 / 0x08 | **no** | A@04 held | **A@08** |
| 3 | 0 (skid full) | yes | A@08 | – |
| 4 | 1 / 0x0C | yes | A@0C | – |

**Taken branch while a fetch is in flight:**

| Cycle | What happens |
|---|---|
| N | redirect: IF/ID and skid cleared, `pc_q` = target, `discard_q` = 1 |
| N+1 | the old response arrives and is discarded; next fetch armed at the target |
| N+2 | fetch of the target goes out |

That flushed cycle is the 1-cycle branch penalty.

### Redirect sources
Taken branch/jump (from S2) or trap/MRET (from S3). **Trap wins**, because the
trapping instruction is one stage older than the branch. A branch redirects only
when it actually advances into S3, otherwise a stalled branch would re-fetch its
target every cycle.

---

## 4. Numbers worth quoting

| | |
|---|---|
| Area | 2,273 LUTs, 968 FFs (< 5K target) |
| CPI | 1.08 – 1.39 |
| Taken-branch penalty | 1 cycle |
| Branch rate (bubble sort) | 32% of instructions, 70% taken |
| CPI breakdown | 0.22 branches + 0.15 stalls ≈ the 0.39 above ideal |
