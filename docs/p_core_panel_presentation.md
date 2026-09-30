# P-Core: Features, Results, and How to Present Them to the Panel

This covers the performance core (P-core) of the big.LITTLE RISC-V SoC, which
is Phase 2 of `RISC-V_SoC_Project_Plan.md`. It has four parts:

* **Part A**: every P-core feature and what it does.
* **Part B**: every result: correctness, verification, performance and area.
* **Part C**: how to present it: slide order, what to say, a live demo, and
  prepared answers to likely panel questions.
* **Part D**: the E-core and P-core compared side by side on the same metrics.

All numbers come from the clean `make test` run on 2026-09-26
(`docs/logs/make_test_2026-09-26.log`: 9m37s, exit 0, "All E-Core and P-Core
regressions passed") and from `make synth`. Tools: Verilator 5.052, Yosys,
GCC 15.2 (`riscv64-elf`). The longer references are
`docs/p_core_microarchitecture.md`, `docs/p_core_verification_plan.md`,
`docs/p_core_results.md` and `docs/lab_notebook.md`.

---

# PART A: Features

## A.1 Summary

| Property | Value |
|---|---|
| ISA | RV32I + M + Zicsr + Zifencei, machine mode (`misa = 0x4000_1100`) |
| Pipeline | 5-stage in-order: IF → ID → EX → MEM → WB |
| Branch prediction | 256-entry 2-bit BHT (`pc[9:2]`) + 64-entry direct-mapped BTB (`pc[7:2]`, full tag) |
| Branch resolution | In EX. Mispredict costs 2 cycles; a correctly predicted taken branch costs 0 |
| Forwarding | EX→EX, MEM→EX, MEM→MEM (store data) |
| Interlock | Load-use / CSR-use only: 1 cycle at zero wait states; none for load→store-data |
| Multiplier | Radix-4 Booth, iterative, 4 cycles |
| Divider | Restoring, 1 bit per cycle, 33 cycles, can be interrupted (abandoned on a flush) |
| Commit point | MEM, so all traps are precise |
| FENCE.I | Real: flush and refetch at commit (self-modifying code works) |
| Performance counters | `mcycle`, `minstret` + 7 event counters (`mhpmcounter3..9`) |
| Interface | **Same as the E-core's**: valid/ready instruction and data ports, 3 interrupt pins, RVFI trace |
| RTL size | 10 P-core files (~2,550 lines) + 7 shared modules (~1,430 lines) |
| Area | 5,273 LUTs, 1,907 FFs (Yosys `synth_xilinx`, 7-series estimate) |

## A.2 Pipeline structure

```
          +--------+     +--------+     +-------------+     +---------+     +------+
 fetch -->|   IF   |---->|   ID   |---->|     EX      |---->|   MEM   |---->|  WB  |
          | BPU    |IF/ID| decode |ID/EX| fwd muxes   |EX/  | LSU     |MEM/ | reg  |
          | lookup |     | regfile|     | ALU         |MEM  | data    |WB   | file |
          | skid   |     | imm    |     | branch cmp  |     |  port   |     | write|
          | buffer |     |        |     | MUL / DIV   |     | CSR,trap|     |      |
          +--------+     +--------+     +-------------+     +---------+     +------+
             ^   ^   mispredict redirect   |    ^  ^         |   ^
             |   +-------------------------+    |  +-EX->EX--+   | MEM->MEM (store data)
             |   trap / MRET / FENCE.I (from MEM)  MEM->EX (from WB)
             +---------------------------------------------------
```

| Stage | RTL file | Job |
|---|---|---|
| IF | `p_core_if_stage.sv`, `p_core_bpu.sv` | predicted fetch, one request in flight, 1-entry skid buffer, wrong-path discard |
| ID | `p_core_id_stage.sv` | decode (shared `decoder`, `RV32M=1`), immediate, write-first register-file read |
| EX | `p_core_ex_stage.sv`, `p_core_mul.sv`, `p_core_div.sv` | forwarding, ALU, branch resolution and mispredict check, MUL/DIV |
| MEM | `p_core_mem_stage.sv` | LSU, data port, CSRs, trap sources, **commit**, RVFI trace |
| WB | MEM/WB register | register-file write |
| Control | `p_core_hazard.sv` | every stall, flush, bubble and forwarding select, in one place |
| Traps | `e_core_trap.sv` | the E-core's trap unit, reused unchanged |

## A.3 Feature details

### 1. Instruction fetch with prediction
* One request in flight, and a **one-entry skid buffer**. Together they fetch
  one instruction per cycle from a memory that may answer in the same cycle,
  while ID can stall at any time.
* The in-flight address (`fetch_addr_q`) is kept separate from the next-fetch
  pc. A redirect never changes a request the memory has already seen; the
  wrong-path response is thrown away instead.
* The next pc is **predicted** instead of always being `pc+4`. The lookup uses
  a register (`fetch_addr_q`), so it starts at the clock edge and not after the
  redirect mux. That keeps it off the critical path.
* The prediction that steers fetch is the same one stored beside the
  instruction for EX to check, even if the predictor is retrained while the
  request is outstanding.

### 2. Branch predictor (`p_core_bpu.sv`)
| Table | Geometry | Contents |
|---|---|---|
| BHT | 256 × 2-bit saturating counters, index `pc[9:2]` | MSB = predict taken |
| BTB | 64 entries, direct-mapped, index `pc[7:2]` | valid, tag `pc[31:8]`, target, jump flag |

* A pc is predicted taken when the BTB hits **and** (the entry is a jump **or**
  the BHT says taken).
* Training happens once, when the instruction leaves EX. A branch that is never
  taken does not take a BTB slot. JAL/JALR always write the BTB. A non-control
  instruction that hits in the BTB **invalidates** the stale entry (this
  happens after self-modifying code).
* The BHT is trained from the counter value carried down the pipeline, so it
  needs **no second read port**.
* **A prediction can never cause a wrong result.** EX checks the actual next pc
  of *every* instruction against the predicted one. BTB aliasing, stale entries
  and uninitialised tables can only cost cycles. That is why the tables can be
  plain RAM with no reset (they map to distributed RAM: 23 × RAM64M).

### 3. Branch resolution in EX
* Actual next pc = `pc+4` unless the instruction is a taken branch or a jump,
  and it is compared with the prediction for every instruction.
* A mismatch is a mispredict: wrong direction, wrong target (e.g. a JALR to a
  new address) or a BTB hit on a non-branch.
* A second `alu` instance is the branch comparator, because the main ALU is
  busy computing `rs1 + imm`.
* The redirect is raised only when the instruction **leaves** EX, so a branch
  held behind a busy MEM does not flush the front end over and over.
* Mispredict penalty: **2 cycles** (the instructions in ID and IF are
  discarded).
* A jump to a misaligned target is not counted as a mispredict. It traps at
  MEM and never trains the predictor.

### 4. Full forwarding
Priority order for each source operand: **MEM (EX→EX) > WB (MEM→EX) > the value
in ID/EX**. The youngest producer wins. The forwarded operands feed the ALU,
the branch comparator, the JALR target, MUL/DIV, the CSR write value and the
store data.

### 5. Operand refresh
An instruction can wait in EX for many cycles (behind a divide, or a slow MEM)
while its producers drain out of WB, and a forwarded value would disappear
with them. So **whenever ID/EX is not being loaded, the forwarded operands are
written back into it**. This costs one mux, which is cheaper than a third
forwarding source, and it also handles a producer that has already written
back.

### 6. Interlock: the only data-hazard stall
Load data and CSR read values are produced *in* MEM, which is too late to
forward into EX. The interlock is decided in ID (the plan says "detect in ID,
stall IF+ID"), so EX never holds an instruction whose operand does not exist
yet.

| Producer (load/CSR) is… | Consumer in ID |
|---|---|
| in EX | hold |
| in MEM, not completing | hold |
| in MEM, completing this cycle | release (MEM→EX supplies it next cycle) |

At zero wait states this is the classic 1-cycle load-use bubble. With slower
memory the stall grows automatically.

### 7. Store-data exemption + MEM→MEM forwarding
`lw x5; sw x5, ...` (a copy loop) needs **no stall**. The store takes its data
from MEM/WB when it reaches MEM. The same refresh idea keeps `data_wdata_o`
stable from request to grant, as the bus protocol requires. This helps
`memcpy` and any code that copies records. Only the store *data* is exempt; the
store *address* still interlocks.

### 8. Radix-4 Booth multiplier (`p_core_mul.sv`): 4 cycles
* 16 Booth digits in {−2,−1,0,+1,+2}, four per cycle.
* The multiplier operand is always recoded **as signed**. For MULHSU/MULHU the
  correction `a << 32` is loaded as the accumulator's starting value, so all
  four ops use the same 64-bit datapath and differ only in operand extension
  and which half is returned.
* The first iteration runs in the start cycle, so the product is ready in
  exactly the 4th cycle.

### 9. Restoring divider (`p_core_div.sv`): 33 cycles
* Works on magnitudes, 1 quotient bit per cycle, and fixes the signs at the
  end. The dividend register doubles as the quotient register.
* Divide by zero gives all-ones for the quotient and the dividend for the
  remainder, as the ISA requires. Overflow (−2³¹/−1) gives `0x8000_0000` with
  no special case.
* It is **interruptible**: a trap on the older instruction in MEM kills the
  divide, and the divide restarts after MRET. An interrupt never waits up to 33
  cycles for a divide.

### 10. MUL/DIV handshake: start / done / ack / kill
* Operands are **captured at start**, so operand refresh cannot corrupt a
  running operation.
* The result is **held** in `result_q` until EX can hand it on. Without the
  hold, a result produced while MEM is busy would be recomputed. That would
  still give the right answer, but it would be a silent performance bug.

### 11. Precise traps, commit at MEM
* All externally visible effects happen at MEM: the data access, CSR write,
  trap entry, MRET and the FENCE.I refetch. Anything younger is still in
  EX/ID/IF and is simply flushed.
* Every cause except a bus error is known **before** the access is issued, so a
  faulting access never reaches the bus.
* `data_req_o` depends only on registers, never combinationally on the grant.
* Trap priority follows the spec. Interrupts are taken ahead of synchronous
  exceptions, and only on a non-memory instruction, so an access that already
  happened is never replayed.

### 12. FENCE.I (Zifencei)
The P-core can fetch up to three instructions past a store in MEM. At commit,
FENCE.I flushes and refetches `pc+4`. Stale BTB entries need no special
handling, because they show up as mispredicts and are invalidated. The rv32ui
`fence_i` compliance test passes (the E-core skips it, since its FENCE.I is a
NOP).

### 13. Performance counters
| CSR | Event |
|---|---|
| `mcycle` / `minstret` | cycles / instructions retired |
| `mhpmcounter3` | cycles ID held a valid instruction (stall) |
| `mhpmcounter4` | conditional branches retired |
| `mhpmcounter5` | …of which taken |
| `mhpmcounter6` | loads + stores retired |
| `mhpmcounter7` | **P-core:** mispredicts (redirects from EX) |
| `mhpmcounter8` | **P-core:** cycles EX waited on MUL/DIV |
| `mhpmcounter9` | **P-core:** cycles of load-use / CSR-use interlock |

Counters 3–6 mean exactly the same on both cores, so the E-core and P-core can
be compared counter for counter.

### 14. Reuse and a common interface
* Reused from the E-core: `alu`, `regfile`, `imm_gen`, `lsu`, `decoder`,
  `csr_unit`, `e_core_trap`.
* Only two shared modules changed, and only through **parameters**
  (`decoder`: `RV32M`; `csr_unit`: `MISA`, `NUM_HPM`). With the defaults, the
  E-core is exactly as before, and its full regression was re-run to show it.
* Both cores have the same ports, so they fit the same testbench now and the
  same SoC slot later. That is the requirement for big.LITTLE task migration
  (Phase 7).

### 15. Simulation assertions (inside the RTL)
* Instruction and data requests stay stable until granted (the bus protocol).
* EX never uses an operand still being produced in MEM.
* A mispredict redirect and a MEM redirect are never both acted on.
* Commits and register writes come only from valid, retired instructions.

---

# PART B: Results

## B.1 Plan exit criteria: all met

| Criterion (plan, Phase 2) | Result |
|---|---|
| Passes rv32ui | **41/41 pass** (including `fence_i`). `ma_data` is skipped because misaligned accesses trap by specification |
| Passes rv32um | **8/8 pass** (`mul mulh mulhsu mulhu div divu rem remu`) |
| Runs benchmark programs with measurable IPC | **Yes**: 6 C programs, outputs checked. Total **CPI 1.055 (IPC 0.948)**, 1.11× faster than the E-core |

## B.2 Verification results

| Gate | Result |
|---|---|
| Lint (`verilator -Wall`, both RVFI builds) | **0 warnings, no waivers** |
| Unit tests (new P-core modules) | MUL 1,262,806 · DIV 512,506 · BPU 1,301,297 checks, **all pass** |
| Unit tests (shared modules, P-core parameters) | decoder RV32M 50,655,483 · CSR 84 checks, **all pass** |
| **Total unit checks** | **≈ 53.7 million** |
| Directed assembly tests | **20/20** (13 shared + 7 P-core), each at **5 memory-latency configs** (0, 2, random:1, random:7, fast-fetch/slow-data `0/d3`) |
| P-core directed checks | muldiv_basic 64 · muldiv_hazard 22 · forwarding 21 · branch_predict 13 · fence_i 8 · irq_muldiv 7×64 · p_perf 17 |
| Compliance | **49 pass, 1 skip** (rv32ui + rv32um), at zero **and** random latency |
| C programs | **6/6** |
| Random lockstep vs golden ISS | **600 programs × 2 latency settings**, compared field by field every retired instruction |
| Mutation testing | **32 mutants: 30 killed, 2 equivalent (with written reasons), 0 unexplained survivors** |
| Line coverage | **100%** (`rtl/common` 139/139; `rtl/p_core` + trap 92/92) |
| Toggle coverage | 82.0% (common) / 83.2% (p_core). The missed bits are structural (listed in B.6) |
| Simulation assertions | on during every test run |

### Things verification caught (useful for the panel, since they show the method works)
1. **Test gap found by mutation.** Removing operand refresh was first caught by
   only one random test, because with equally slow ports fetch never got far
   enough ahead to trigger the case. Fix: a new **fast-fetch/slow-data (`0/d3`)
   config**, which models an I-cache hit beside a D-cache miss. Now 8 tests
   catch that mutant, including directed ones.
2. **Equivalent mutant explained.** `csr_not_late` survived. Tracing it showed
   the MEM-stage flag is redundant, because the ID interlock already covers the
   case. It is recorded as equivalent, and a stronger mutant
   (`csr_not_late_in_ex`) was added, which 26 tests catch.
3. **Dead code found by coverage.** The shared decoder had a line that can
   never run in the E-core build. It was fixed rather than waived, so both
   cores stay at 100% line coverage.
4. **Two bugs in my own tests**, where the RTL was right and the test was
   wrong: an interlock that slow fetch makes unnecessary, and a mispredict count
   worked out by hand as 4 when the RTL correctly gave 5.
5. **Six mutations that only affect performance** (never predict taken,
   mispredict everything, BHT never trained, BTB ignores the tag, stale entries
   never invalidated, MUL result not held). Every answer stays correct, so
   ordinary tests would miss them. **All six are caught by exact event-counter
   checks.** A performance feature that nothing measures is a feature nothing
   verifies.

### Exact branch-predictor checks (from `mhpmcounter7`)
| Scenario | Expected = measured mispredicts |
|---|---:|
| Loop 9 taken / 1 not-taken × 100 (unit test, the plan's "known pattern") | **101** |
| Cold 5-iteration loop | 2 |
| Three passes over a fresh loop | 6 |
| 9T/1N × 20 + outer loop | 23 |
| Non-branch aliasing a trained branch's BTB index (tag check) | 7 |
| Stale BTB entry after self-modifying code | 5 (would be 8 without invalidation) |

## B.3 Performance: C programs (whole-program cycles, zero wait states, same clock)

| Program | E-core cycles | P-core cycles | Speed-up | Why |
|---|---:|---:|---:|---|
| perf_counters | 14,999 | 7,767 | **1.93×** | MUL/DIV-heavy |
| bubble_sort | 12,523 | 7,113 | **1.76×** | MUL + predicted loop branches |
| add_demo | 4,915 | 3,893 | 1.26× | |
| memcpy_test | 298,242 | 240,549 | **1.24×** | same instruction count; no-stall load→store + predicted loops |
| hello | 675 | 631 | 1.07× | |
| fib | 511,036 | 500,623 | 1.02× | recursion: returns mispredict (no return-address stack) |
| **Total** | **842,390** | **760,576** | **1.11×** | |

## B.4 Where the speed-up comes from

The cycle count of a program is **instructions × CPI**, so a core can win in
two ways, and the P-core uses both:

| Source | Example | E-core | P-core |
|---|---|---|---|
| **Fewer instructions** (hardware MUL/DIV instead of a libgcc software loop) | `perf_counters` | 11,726 instructions | 5,598 (−52%) |
| **Lower CPI on the same instructions** (predicted branches, no load→store stall) | `memcpy_test` | CPI 1.264 | CPI **1.020**, same 235,936 instructions |

The performance counters show where the P-core still loses cycles:
`mhpmcounter7` (mispredicts, 2 cycles each), `mhpmcounter8` (waiting on
MUL/DIV) and `mhpmcounter9` (load-use interlock). `p_perf` and
`branch_predict` check those counters for exact values.

## B.5 Area (Yosys `synth_xilinx`, Xilinx 7-series, estimate)

| Resource | E-core | P-core | Ratio |
|---|---:|---:|---:|
| LUTs | 2,249 | **5,273** | 2.3× |
| Flip-flops | 968 | **1,907** | 2.0× |
| CARRY4 | 152 | 383 | |
| MUXF7 / MUXF8 | 143 / 49 | 992 / 278 | |
| RAM32M (register file) | 12 | 12 | |
| RAM64M (BHT + BTB) | 0 | 23 | |

It fits easily in any Artix-7. The extra area comes from four pipeline
registers, the MUL/DIV iteration registers, three more 64-bit counters and the
BTB valid bits. The predictor tables map to distributed RAM, as intended.

## B.6 Known limitations (say these yourself, before the panel does)

| Limitation | Reason / plan |
|---|---|
| **No Fmax figure** | No place-and-route tool (Vivado/nextpnr) is installed. Yosys `ltp` is not a timing estimate (tried; it counts ripple-adder bits). Measuring it is in Phase 8 FPGA bring-up |
| Only 1.11× overall per clock | The E-core is a strong baseline (it resolves branches in ID for a 1-cycle penalty). The 5-stage pipeline's main benefit is expected to be clock frequency, which is not measured yet |
| No return-address stack, direct-mapped BTB | The plan specified only a BHT + BTB. A RAS and a 2-way BTB are the next improvements |
| Interrupts not in lockstep runs | The ISS cannot know when an async interrupt arrives. Covered by `irq_timer` and `irq_muldiv` (interrupt at 64 points through a MUL/DIV sequence) |
| `ma_data` skipped | Misaligned accesses trap by design |
| Toggle coverage 82–83% | Structural: hardwired `mie`/`mip` bits, upper halves of 64-bit counters (need about 2³² events), address bits ≥ 18 unused in a 192 KiB map |
| No standard benchmark suite | CoreMark is not ported; the comparison uses the 6 C test programs |
| No caches yet | Phase 3, behind the existing valid/ready ports |

---

# PART D: E-core vs P-core, Same Metrics

Both cores were built and measured by the same `make test` run on 2026-09-26,
with the same testbench, memory model, golden ISS, compiler and counter
definitions. All performance numbers are at **zero wait states and the same
clock**, so they compare work per clock. Speed-up = E-core cycles ÷ P-core
cycles (above 1.00× means the P-core is faster).

## D.1 Headline comparison (use this as the slide)

| Metric | E-core | P-core | Winner |
|---|---:|---:|---|
| C programs, total cycles | 842,390 | **760,576** | P (1.11×) |
| C programs, total CPI | 1.145 | **1.055** | P |
| Best speed-up | – | **1.93×** (`perf_counters`) | P |
| Short, cold code (rv32ui suite total) | **16,426 cycles** | 18,005 cycles | E (P is 0.91×) |
| LUTs | **2,249** | 5,273 | E (2.3× smaller) |
| Flip-flops | **968** | 1,907 | E (2.0× smaller) |
| ISA | RV32I | **RV32IM** + real FENCE.I | P |
| Compliance | 40 pass, 2 skip | **49 pass, 1 skip** | both fully pass their ISA |
| Line coverage | 100% | 100% | tie |
| Mutation: unexplained survivors | 0 | 0 | tie |
| Fmax | not measured | not measured | open (Phase 8) |

**What it means:** the P-core does more work per clock on real, loop-heavy
programs, and a lot more on multiply/divide code. It costs 2.3× the area. On
short code that runs once, its cold predictor and 2-cycle mispredict penalty
make it slower than the E-core. That is exactly the big.LITTLE trade-off: a
small, efficient core for light work, and a bigger core for heavy work.

## D.2 Microarchitecture

| Feature | E-core | P-core |
|---|---|---|
| Role in big.LITTLE | LITTLE (efficiency) | big (performance) |
| ISA | RV32I + Zicsr | RV32I + M + Zicsr + Zifencei |
| `misa` | `0x4000_0100` | `0x4000_1100` |
| Pipeline | 3 stages: IF → ID/RF → EX/MEM/WB | 5 stages: IF → ID → EX → MEM → WB |
| Branch prediction | static not-taken | 256-entry 2-bit BHT + 64-entry BTB |
| Branches resolved in | ID (stage 2) | EX (stage 3) |
| Taken branch / jump cost | always 1 cycle | 0 if predicted, 2 if mispredicted |
| Not-taken branch cost | 0 | 0 if predicted, 2 if mispredicted |
| Forwarding | S3 → S2 + write-first register file | EX→EX, MEM→EX, MEM→MEM + write-first register file |
| Load → dependent ALU | 1-cycle interlock | 1-cycle interlock |
| Load → store data | 1-cycle interlock | **0** (MEM→MEM forwarding) |
| Multiply | software (libgcc) | hardware, 4 cycles |
| Divide | software (libgcc) | hardware, 33 cycles, interruptible |
| FENCE.I | NOP (nothing to flush) | flush + refetch |
| Commit point | stage 3 | MEM |
| Traps | precise | precise (same trap unit, reused) |
| Event counters | 4 (`mhpmcounter3..6`) | 7 (`mhpmcounter3..9`) |
| External interface | valid/ready I and D ports, 3 IRQs, RVFI | **identical** |
| RTL files linted | 13 | 18 |

## D.3 C programs (whole program, including start-up code)

| Program | E cycles | E instret | E CPI | P cycles | P instret | P CPI | Speed-up |
|---|---:|---:|---:|---:|---:|---:|---:|
| perf_counters | 14,999 | 11,726 | 1.279 | 7,767 | 5,598 | 1.387 | **1.93×** |
| bubble_sort | 12,523 | 10,075 | 1.243 | 7,113 | 5,819 | 1.222 | **1.76×** |
| add_demo | 4,915 | 3,703 | 1.327 | 3,893 | 2,944 | 1.322 | 1.26× |
| memcpy_test | 298,242 | 235,936 | 1.264 | 240,549 | 235,936 | **1.020** | 1.24× |
| hello | 675 | 487 | 1.386 | 631 | 487 | 1.296 | 1.07× |
| fib | 511,036 | 473,764 | 1.079 | 500,623 | 470,300 | 1.064 | 1.02× |
| **Total** | **842,390** | **735,691** | 1.145 | **760,576** | **721,084** | 1.055 | **1.11×** |

Two kinds of gain:
* **Fewer instructions** (hardware M extension): `perf_counters` retires 52%
  fewer, `bubble_sort` 42% fewer. Its CPI can even go *up* (`perf_counters`
  1.279 → 1.387, because of MUL/DIV busy cycles) and it is still 1.93× faster.
* **Lower CPI with the same instructions** (pipeline + predictor):
  `memcpy_test` retires exactly the same 235,936 instructions, but its CPI
  drops from 1.264 to **1.020**. That comes from the no-stall load→store path
  and predicted loop branches.

## D.4 Short, cold code: where the E-core wins

The compliance and directed tests are mostly straight-line code where each
branch runs once or a few times, so the predictor never warms up.

| Workload | Tests | E cycles | P cycles | Instret (E / P) | E CPI | P CPI | Speed-up |
|---|---:|---:|---:|---|---:|---:|---:|
| rv32ui compliance (both run) | 40 | **16,426** | 18,005 | 14,747 / 14,747 | 1.114 | 1.221 | **0.91×** |
| rv32ui branch tests (`beq bge bgeu blt bltu bne`) | 6 | **2,380** | 2,772 | 2,048 / 2,048 | 1.162 | 1.354 | 0.86× |
| Shared directed asm tests | 13 | 4,959 | **4,706** | 3,512 / 3,366 | 1.412 | 1.398 | 1.05× |

* On cold code every taken branch is a mispredict on the P-core (2 cycles),
  while the E-core pays 1 cycle. That is why the branch tests are 14% slower.
* A deeper pipeline also takes longer to refill after reset and after every
  trap or redirect.
* The directed-test total favours the P-core only because of three tests:
  `irq_timer` (1.31×), and `trap_exceptions` / `illegal_encodings`, which
  retire fewer instructions on the P-core because its MUL/DIV checks are
  omitted there (they no longer trap). The other ten directed tests run at
  0.80–1.01×.

**How to say it to the panel:** "On tiny programs that run once, the E-core is
about 10% faster per clock, because its branches cost 1 cycle and mine cost 2
until the predictor learns. On real programs with loops, the predictor learns
and the P-core wins. That is why a big.LITTLE system has both."

## D.5 Verification, same gates on both

| Gate | E-core | P-core |
|---|---|---|
| Lint `-Wall`, both RVFI builds | 0 warnings (13 files) | 0 warnings (18 files) |
| Unit testbenches | 6 shared modules | 6 shared + 2 re-elaborated with P-core parameters + 3 new (MUL, DIV, BPU) |
| Directed asm tests | 13 | 20 (13 shared + 7 new) |
| Latency configurations per directed test | 5 | 5 |
| rv32ui | 40 pass, skip `fence_i`, `ma_data` | 41 pass (incl. `fence_i`), skip `ma_data` |
| rv32um | n/a (no M) | 8 / 8 |
| C programs | 6 / 6 | 6 / 6 |
| Random lockstep vs golden ISS | 200 × 3 seeds × {0, random} | 200 × 3 seeds × {0, random}, with RV32M + JALR/trap constructs |
| Mutation tests run per mutant | 8 tests × 4 latency configs | 39 tests × 4 latency configs |
| Mutants | 23: 16 killed, 7 equivalent | 32: 30 killed, 2 equivalent |
| Unexplained survivors | 0 | 0 |
| Coverage programs replayed | 179 | 195 |
| Line coverage, `rtl/common` | 100% (139/139) | 100% (139/139) |
| Line coverage, core-specific | 100% (38/38) | 100% (92/92) |
| Toggle coverage, `rtl/common` | 81.3% | 82.0% |
| Toggle coverage, core-specific | 82.6% | 83.2% |
| In-RTL simulation assertions | – | 5 (protocol, interlock, flush, commit) |
| Performance features checked by exact counter values | stalls, branches (`csr_perf`) | + mispredicts, MUL/DIV busy, interlock (`branch_predict`, `fence_i`, `p_perf`) |

The E-core has more equivalent mutants (7 vs 2) because several of its
behaviours are implemented twice (e.g. explicit forwarding **and** a
write-first register file). Each E-core equivalent is paired with a combined
mutation that removes both copies, and that combined one is killed.

## D.6 Area (Yosys `synth_xilinx`, 7-series estimate, same flow)

| Resource | E-core | P-core | P / E |
|---|---:|---:|---:|
| LUTs | 2,249 | 5,273 | 2.34× |
| Flip-flops | 968 | 1,907 | 1.97× |
| CARRY4 | 152 | 383 | 2.52× |
| MUXF7 | 143 | 992 | 6.9× |
| MUXF8 | 49 | 278 | 5.7× |
| RAM32M (register file) | 12 | 12 | same |
| RAM64M (BHT + BTB) | 0 | 23 | new |

Performance per LUT, per clock: the P-core is 1.11× faster over the C
programs but 2.34× larger, so the E-core does about **2.1× more work per
LUT**, which is why it is the efficiency core. The
P-core's case rests on absolute speed: more per clock on real code, much more
on M-heavy code, and (to be measured) a higher clock.

## D.7 Comparison summary in one sentence per metric

* **Speed per clock:** P-core 1.11× across the C programs,
  up to 1.93× on multiply/divide code; 0.91× on short cold code.
* **Instructions:** P-core retires up to 52% fewer, thanks to the M extension.
* **CPI:** P-core is lower on real programs (1.055 vs 1.145 over the C
  programs; 1.020 vs 1.264 on `memcpy`).
* **Area:** P-core is 2.3× the LUTs and 2.0× the flip-flops.
* **Efficiency:** E-core does about 2.1× more work per LUT.
* **Correctness:** both pass their full compliance suites, lockstep, 100% line
  coverage and mutation with zero unexplained survivors.
* **Clock frequency:** not measured for either; that is the key open question.

---

# PART C: How to Present It to the Panel

## C.1 The one-line story

> "I built a 5-stage RV32IM performance core with branch prediction and
> hardware multiply/divide. It passes all compliance tests, and I verified it
> with a method that even checks the performance features. Across the test
> programs it is 1.11× faster per clock, and up to 1.93× on multiply-heavy
> code."

Keep coming back to three ideas: **it works** (compliance + lockstep), **it is
proven** (mutation + coverage + counters), **I understand it** (where the
speed-up comes from, honest limitations).

## C.2 Suggested slides (12–15 minutes, 12 slides)

| # | Slide | Time | Content | What to say |
|---|---|---|---|---|
| 1 | Title + where this fits | 0:30 | big.LITTLE SoC, Phase 2 of 8. E-core done, P-core done | "The E-core is the efficiency core; this is the performance core. Same interface, so they drop into the same SoC slot." |
| 2 | Goals / exit criteria | 0:45 | The plan's Phase 2 table with three ticks (B.1) | Start with the results: "All three exit criteria are met." |
| 3 | Pipeline diagram | 1:30 | Diagram from A.2 + stage table | Go through one instruction left to right. Point to the three forwarding arrows and the two redirect paths |
| 4 | Hazards | 1:30 | Cost table: ALU→ALU 0, load→use 1, load→store 0, mispredict 2, MUL 3, DIV 32 | Mention the **store-data exemption** and **operand refresh**. These are your own design decisions |
| 5 | Branch prediction | 1:30 | BHT + BTB geometry, predict rule, "every instruction's next pc is checked" | The key point: "A prediction can never cause a wrong result, only lost cycles. That's why the tables need no reset." |
| 6 | M-extension | 1:00 | Booth radix-4 (4 cyc), restoring div (33 cyc), start/done/ack/kill | Explain the MULHSU/MULHU `a<<32` trick and that the divider can be interrupted |
| 7 | Precise traps + FENCE.I | 0:45 | Commit at MEM; FENCE.I = flush + refetch | "The E-core's trap unit is reused unchanged." |
| 8 | Verification method | 1:30 | The 5 levels: unit → directed (5 latency configs) → compliance → lockstep vs ISS → mutation, plus assertions + coverage | "The ISS's M extension uses 64-bit host arithmetic, nothing like Booth, so the model and the RTL can't share a bug." |
| 9 | Verification results | 1:00 | B.2 table: 53.7M unit checks, 49/50 compliance, 600×2 lockstep, 30/32 mutants killed, 100% line | Give the numbers, then one story: the `0/d3` test gap found by mutation |
| 10 | E-core vs P-core | 1:30 | Part D headline table (D.1) + C-program speed-ups (bar chart) | "1.11× per clock across the programs, up to 1.93× on multiply-heavy code. On short cold code the P-core is about 9% slower; that is the price of a deeper pipeline." |
| 11 | Where the speed comes from | 1:00 | B.4: `perf_counters` (52% fewer instructions) and `memcpy_test` (same instructions, CPI 1.264 → 1.020) | "Two ways to win: run fewer instructions, or run them with fewer wasted cycles. The P-core does both." |
| 12 | Area, limitations, next steps | 1:00 | Area table; the honest list; Phase 3 caches, RAS, Fmax on FPGA | Say the limitations yourself. It builds trust |

Keep 3–5 minutes for questions.

### Visuals worth making
* **Pipeline diagram** with the forwarding paths in one colour and redirects in
  another.
* **A pipeline timing chart** (cycles across, instructions down) for `lw x5 →
  add x6,x5` (1 bubble) next to `lw x5 → sw x5` (0 bubbles). This explains the
  store exemption in 5 seconds.
* **A two-bar chart per program**: instructions and CPI, E-core vs P-core.
* **A speed-up bar chart** for the six C programs, sorted.
* **A verification pyramid**: unit at the bottom, mutation at the top, with
  numbers on each layer.
* One **GTKWave screenshot** of a mispredict: the redirect, two squashed
  instructions, and the correct-path fetch.

Existing decks to reuse from: `riscv_soc_review2.pptx`,
`biglittle_riscv_soc_review(1).pptx`, and the generators
`scripts/gen_review2_ppt.py`, `../presentation_build/generate_a1_ppt.py`.

## C.3 Live demo (optional, about 2 minutes, rehearse it)

Build first so nothing compiles live:

```sh
make sw-tests                            # C programs on the E-core (builds them)
make CORE=p_core sw-tests                # the same programs on the P-core
make bench                               # E-core vs P-core comparison table (~5 s)
make CORE=p_core riscv-tests             # compliance: rv32ui + rv32um pass
make wave TEST=branch_predict            # then: gtkwave build/branch_predict.vcd
```

The clearest single demo is one program on both cores, side by side (same
output, different cycle count):

```sh
build/e_core_sim --elf build/sw/bubble_sort.elf        --waits=0   # cycles=12523
build/p_core_sim --elf build/p_core/sw/bubble_sort.elf --waits=0   # cycles=7113
```

Backup plan: keep `docs/logs/make_test_2026-09-26.log` open in a terminal
(it ends with "All E-Core and P-Core regressions passed", `EXIT=0`) and have
screenshots ready. Never let a failed demo be the last thing the panel sees.

## C.4 Likely panel questions, with answers

**Q: Only 1.11× faster for 2.3× the area. Is it worth it?**
A: Per clock, yes, 1.11× across the test programs. But a 5-stage pipeline mainly exists to raise the
clock frequency, and I haven't measured that yet because it needs place and
route. The E-core resolves branches in ID for a 1-cycle penalty, so it is a
strong baseline per clock. On multiply/divide code the gain is up to 1.93×.
In big.LITTLE the point is that the two cores differ: the E-core stays small
for background work, and the P-core is for heavy work.

**Q: Why resolve branches in EX and not ID like the E-core?**
A: With a predictor, a correctly predicted branch costs 0 cycles wherever it
resolves. Resolving in EX keeps the forwarding muxes and comparator out of ID,
which should help the clock. The cost is a 2-cycle mispredict instead of 1.

**Q: How do you know your tests are good enough?**
A: Mutation testing. I injected 32 realistic bugs; 30 were caught, and the 2
that weren't are proven equivalent (the bug can't change behaviour). Line
coverage is 100%. Mutation testing also found a real test gap, which I fixed
with the fast-fetch/slow-data configuration.

**Q: How do you verify something that only affects performance, like the predictor?**
A: With exact counter values. For example, a 9-taken/1-not-taken loop run 100
times must mispredict exactly 101 times. Six performance-only mutants survive
every correctness test and are caught only by these counter checks.

**Q: What is operand refresh, and why do you need it?**
A: If an instruction waits in EX (on a divide or a slow memory), the producer
it was forwarding from can leave the pipeline. Writing the forwarded value
back into ID/EX every cycle it waits means it never loses the value. It costs
one mux.

**Q: What happens if an interrupt arrives during a 33-cycle divide?**
A: The divide is killed, the interrupt is taken at once, and the divide
restarts after MRET. `irq_muldiv` fires the timer at 64 different points
through a MUL/DIV sequence and checks every result.

**Q: How are traps precise in a 5-stage pipeline?**
A: MEM is the commit point. Nothing visible happens before MEM, so anything
younger than a trapping instruction has done nothing and is just flushed.

**Q: What is the golden reference?**
A: An instruction-set simulator written from the ISA manual. Every retired
instruction's pc, instruction, rd value, memory address/data/mask and trap is
compared, on 600 random programs at two latency settings.

**Q: Why no return-address stack?**
A: The plan specified a BHT + BTB. Without a RAS, a function called from
several places mispredicts its return, which is why recursive `fib` gains only
1.02×. A RAS is the clear next step.

**Q: Why is toggle coverage only 83%?**
A: The missed bits are structural: hardwired CSR bits, the upper halves of
64-bit counters that would need about 4 billion events, and address bits above
the 192 KiB memory map. The worst signals are listed in the coverage report.

**Q: What is the Fmax?**
A: Not measured. I don't want to quote a made-up number. Yosys's path analysis
isn't a timing estimate (I tried it). It will be measured on the FPGA in
Phase 8.

**Q: What would you do differently?**
A: Add the fast-fetch/slow-data latency config from the start, since it models
cache hit/miss combinations. Also add a RAS and a 2-way BTB, and port CoreMark
for a second benchmark.

## C.5 Presentation tips

* **Lead with results**, then explain how. Panels decide in the first two
  minutes.
* **Use exact numbers**: "30 of 32 mutants, 2 proven equivalent" is stronger
  than "most bugs caught".
* **State limitations first.** Saying "Fmax isn't measured yet, here's why" is
  much better than having it pointed out.
* **Explain your design decisions** (store exemption, operand refresh, check
  every pc, commit at MEM). This shows engineering judgement rather than
  following a textbook.
* **Tell one debugging story** (the `0/d3` test gap). A short story sticks
  better than a table.
* **Don't read the tables aloud.** Point to the one number that matters on
  each slide.
* **Rehearse to 12 minutes** so you have room for questions.
* Terms to be able to define in one sentence: CPI/IPC, BHT, BTB,
  forwarding, interlock, precise trap, mutation testing, equivalent mutant,
  lockstep, RVFI, toggle coverage.

## C.6 Checklist before the presentation

- [ ] Re-run `make test` on the presentation machine; confirm `EXIT=0`
- [ ] Build the simulators ahead of time; have the VCD open in GTKWave
- [ ] Slides: pipeline diagram, hazard timing chart, speed-up chart
- [ ] Log file and screenshots ready as a backup
- [ ] Practise the answers to the Fmax and "only 9%" questions out loud
- [ ] Time the talk: 12 minutes + questions
