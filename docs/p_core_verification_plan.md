# P-Core Verification Plan and Status

**Status:** complete for Phase 2. Every item below runs under `make p-test`
(and `make test`, which gates both cores). Final numbers are from the run
logged in `docs/logs/make_test_2026-09-26.log`.

## 1. Strategy

The P-core is verified with the same five-level method as the E-core, reusing
its infrastructure wherever the two cores share behaviour, plus two additions:
**simulation assertions** inside the RTL, and **exact event-counter checks**
that turn the performance features into testable behaviour.

1. **Unit** — a C++ Verilator harness per new module (`p_core_mul`,
   `p_core_div`, `p_core_bpu`), each against a reference model that shares no
   structure with the RTL; plus second elaborations of the shared `decoder`
   (`RV32M = 1`) and `csr_unit` (P-core parameters).
2. **Directed integration** — the E-core's 13 self-checking assembly tests,
   unchanged except where the ISA legitimately differs, plus 7 P-core tests.
   Every test runs at 0, 2, `random:1`, `random:7` wait states and `0/d3` (fast fetch, slow data).
3. **Compliance** — `rv32ui-p` **and** `rv32um-p` from `riscv-tests`, each at
   zero and randomised latency.
4. **Randomised lockstep** — constrained-random RV32IM programs compared
   instruction by instruction against the golden ISS at retirement.
5. **Mutation** — realistic defects injected into the RTL, each of which the
   suite must detect.

Plus line/toggle **coverage**, **Dhrystone** as an end-to-end program with
verified results, and the lint gate (`-Wall`, zero warnings, no waivers, both
RVFI elaborations).

### What is shared, and why it is trustworthy for both cores

The testbench (`tb/integration/tb_core.cpp`), memory model and golden ISS are
common to both cores; `-DCORE_P` selects the P-core and the matching ISS
configuration (RV32IM, seven event counters). The ISS's M extension is written
from the ISA manual with 64-bit host arithmetic — nothing like the RTL's Booth
multiplier or restoring divider — so the two cannot share a mistake.

### Changes to E-core tests

Three checks in shared tests hold only on a core without M. They are not
skipped on the P-core; they are made core-aware with `CORE_HAS_M`:

| Test | E-core expects | P-core expects |
|---|---|---|
| `csr_basic` check 16 | `misa = 0x4000_0100` | `misa = 0x4000_1100` |
| `trap_exceptions` checks 11–13 | MUL/DIV trap as illegal | (omitted; `muldiv_basic` checks their results) |
| `illegal_encodings` checks 51–57 | MUL/DIV/DIVU/REMU trap | (omitted; likewise) |

## 2. Test matrix

### 2.1 Unit level (`make unit`)

| Test | Module | Features covered | Checks | Status |
|---|---|---|---:|---|
| `tb_p_core_mul` | `p_core_mul.sv` | MUL/MULH/MULHSU/MULHU over a 15-value corner set, all pairings; every operand sign combination; single-bit operands in every Booth-digit position; 400k corner-biased random ops; result in exactly the 4th cycle; result **held** until acknowledged; operands **captured** at start (inputs scrambled afterwards); **kill** in every cycle incl. after completion; 5,000 back-to-back ops with no idle cycle | 1,262,806 | pass |
| `tb_p_core_div` | `p_core_div.sv` | divide-by-zero and INT_MIN/−1 for all four ops; corner set, all pairings; every sign combination; dividends either side of a multiple; power-of-two divisors; 150k random ops; result in exactly the 33rd cycle; hold, capture, kill at every phase | 512,506 | pass |
| `tb_p_core_bpu` | `p_core_bpu.sv` | nothing predicted after reset; 400k cycles of random training and lookup over a deliberately colliding pc pool vs a behavioural model (taken, target, hit, counter); lookup/train of the same entry in one cycle sees old contents; BTB alias eviction and tag mismatch; **loop 9T/1N × 100 = exactly 101 mispredicts** (the plan's "loop with known pattern"); stale entry invalidation | 1,301,297 | pass |
| `tb_decoder_rv32m` | `decoder.sv`, `RV32M = 1` | the full E-core decoder test with the M extension legal: all 8 M encodings × rd, `md_op = funct3`; adjacent funct7 values still trap; OP-IMM funct7 = 1 still traps; FENCE.I flagged; 2M random words, one in eight steered into the OP/M space | 50,655,483 | pass |
| `tb_csr_unit_p` | `csr_unit.sv`, P-core parameters | the full CSR test with `misa = RV32IM` and 7 event counters: each counter counts its own event bit only (distinct counts expose crossed wires); high halves independent; carry into the high half; `mhpmcounter10` and `0xB8A` illegal | 84 | pass |

The E-core's unit tests (`tb_alu`, `tb_regfile`, `tb_imm_gen`, `tb_lsu`,
`tb_decoder`, `tb_csr_unit`) still pass against the shared modules, now
including checks of the new `fence_i_o` / `md_en_o` outputs (constant zero at
`RV32M = 0`) and of the generalised counter block.

### 2.2 Directed integration (`make CORE=p_core asm-tests`)

The 13 E-core tests (`m2_basic`, `hazard_raw`, `hazard_load_use`,
`branch_basic`, `branch_hazard`, `jump_link`, `mem_align`, `x0_writes`,
`csr_basic`, `csr_perf`, `trap_exceptions`, `illegal_encodings`, `irq_timer`)
all pass on the P-core. The P-core adds:

| Test | Features covered | Checks | Status |
|---|---|---:|---|
| `muldiv_basic` | all 8 M instructions on the values the ISA special-cases and the ones that break multipliers/dividers; expected values precomputed by an independent model; rd = x0 discards; operands untouched; rd = rs1 = rs2 | 64 | pass |
| `muldiv_hazard` | MUL result at distance 1 (EX→EX) and 2 (MEM→EX); a branch on a DIV result; load → MUL interlock; dependent DIV chains; storing a MUL result; MUL chains; DIV operands from EX→EX and MEM→EX at once; a MUL result as a JALR target (and its link); **operand refresh** across a stalled store; MUL to x0; a DIV on the wrong path of a mispredict must not complete | 22 | pass |
| `forwarding` | youngest producer wins; distance 1/2/3; both operands from different stages; **load → store data with no stall** for word, sign-extended byte, byte and halfword stores; CSR read → store data; load → store *address* must interlock; load → ALU, load → load address, load → branch, load → JALR; CSR → ALU; x0 loads and writes forward nothing (also into MEM→MEM); a younger ALU write supersedes a load for store data; JAL link at distance 1 | 21 | pass |
| `branch_predict` | correctness under cold entries, direction changes, alternating directions, a call site alternating between two returns, a taken branch to its own fall-through, BTB aliases; **exact** mispredict counts from `mhpmcounter7`: cold 5-iteration loop = 2; three passes over a fresh loop = 6; 9T/1N × 20 plus its outer loop = 23; the BTB **tag** is compared (a non-branch sharing an index with a trained branch is not predicted) = 7 | 13 | pass |
| `fence_i` | self-modifying code where the patched word is the one immediately after the FENCE.I (certainly in flight), patched on three passes to three values; patching a subroutine that has already run and been learnt; a **stale BTB entry** (jump patched into an addi) mispredicts exactly once and is invalidated (count = 5, would be 8) | 8 | pass |
| `irq_muldiv` | a timer interrupt landing at 64 successive points through a DIVU/MUL/REM/DIV/MULH sequence: every result checked every pass; exactly one interrupt per pass; the handler's own MUL and DIVU get correct results (an abandoned operation that was not truly abandoned would hand them a stale one) | 7 × 64 | pass |
| `p_perf` | `mhpmcounter8` exactly 3 per MUL and 32 per DIV, 64 for two DIVs, 0 for ALU work — **including behind a stalled store**, where the result must be held, not recomputed; `mhpmcounter9` 0 for load → store data, ≥ 1 for load → ALU; `mhpmcounter7` 1 for a cold taken branch, 0 for a cold not-taken one; `mhpmcounter10` and `0xB8A` trap, `mhpmcounter9h` does not | 17 | pass |

Exact counter values are architectural functions of the program and the
predictor's rules, not of memory latency, so they are checked at every wait
state setting. One check had to be restructured to make that true: a load
followed by a dependent add interlocks only if both are in the pipeline
together, which slow instruction fetch can prevent. `p_perf` check 7 puts a
divide in front so the pair is always queued together (lab notebook,
2026-09-26).

### 2.3 Compliance (`make CORE=p_core riscv-tests`)

| Suite | Result |
|---|---|
| `rv32ui-p` | 41 / 41 run pass; `ma_data` skipped by specification (misaligned accesses trap, see the E-core plan) |
| `rv32um-p` | 8 / 8 pass: `mul mulh mulhsu mulhu div divu rem remu` |
| `fence_i` | **passes** on the P-core (it is skipped on the E-core, whose FENCE.I is a NOP) |

Every test passes twice: at zero wait states and at randomised latency on both
ports.

### 2.4 Randomised lockstep (`make CORE=p_core random`)

The generator gains two options, both off for the E-core so its programs are
bit-identical for a given seed:

* `--rv32m` — multiplies and divides (≈12% of instructions), with operands
  frequently forced to 0, 1, −1, INT_MIN, INT_MAX and similar;
* `--extended` — JALR through a computed address; a store of the value loaded
  by the instruction just before it (MEM→MEM); a JALR to a misaligned target
  (traps, cause 0); an illegal instruction word (traps, cause 2).

600 programs (200 × 3 seeds), each run at zero wait states and at randomised
latency, compared field by field against the ISS: pc, instruction, trap,
next pc, rd and its value, store address/data/mask, load mask.

### 2.5 Mutation testing (`make CORE=p_core mutation`)

32 realistic defects, each rebuilt and run against the 20 directed tests,
the M and control-flow compliance tests, and 8 lockstep programs, at four
latency configurations (0, 2, `random:7`, `0/d3`). **30 killed, 2 documented equivalent, 0 unexplained survivors.**

| Group | Mutations (all killed unless marked) |
|---|---|
| Forwarding | no EX→EX; no MEM→EX on rs2; forwarding ignores x0; no operand refresh; forwarding allowed from a load in MEM **(equivalent**, paired with a kill that also removes the MEM→MEM repair) |
| Interlock | no interlock; no second (MEM) term; CSR not late in EX; CSR not late in MEM **(equivalent)**; store data not exempt (performance only — killed by `p_perf`) |
| Store data | no MEM→MEM forwarding; no store-data refresh (killed by the protocol-stability assertion) |
| Flush / advance | no mispredict flush; wrong-path instruction enters EX; trap does not flush EX; EX overwritten while busy; no FENCE.I refetch; trapped instruction writes the register file |
| Fetch | fetch ignores the prediction it records; no wrong-path discard |
| Prediction (performance only) | never predict taken; mispredict everything; BHT never trained; BTB ignores the tag; stale entries never invalidated |
| Multiply / divide | no MULHSU/MULHU correction; MULHSU treats rs2 as signed; result not held (performance only); divide-by-zero case lost; wrong quotient sign; divide not killed by a flush |

Six of these break **only performance**: the core still computes every answer
correctly, just more slowly. They are killed anyway, by the exact counter
checks in `branch_predict`, `fence_i` and `p_perf`. That is the point of those
checks: a performance feature that nothing measures is a feature nothing
verifies.

**The two equivalents.** Both concern the *MEM-stage* "value is late" flag.
The ID-stage interlock already keeps every consumer of a load or CSR result out
of EX until the producer reaches WB, and the one consumer it lets through — a
store's data — is repaired in MEM from WB. So removing the MEM copy's
exclusion (for loads, or for CSRs) changes nothing observable. Each is paired
with a mutation that removes the second mechanism as well, which is killed.

### 2.6 Simulation assertions (`p_core_top.sv`, built with `--assert`)

| Assertion | Why |
|---|---|
| an instruction request is held, unchanged, until granted | memory protocol; a redirect must not move an outstanding fetch |
| a data request — address, we, be, **wdata** — is held until granted | memory protocol; exercises the store-data refresh |
| EX never consumes an operand still being produced in MEM (store data excepted) | the interlock's guarantee, checked every cycle |
| a mispredict redirect and a MEM redirect are never both acted on | flush priority |
| a commit only with a valid instruction in MEM; a register write only from a retired one | commit bookkeeping |

A failing assertion stops the simulation with a non-zero status, so it fails
whichever test was running. The `no_store_refresh` mutation is killed by the
second one.

## 3. Coverage (`make CORE=p_core coverage`)

196 programs replayed on a coverage build (directed, C, compliance, the
first 120 lockstep programs, Dhrystone), every third at randomised latency.

| Scope | Line | Toggle |
|---|---:|---:|
| `rtl/common` | **100%** (140/140) | 82.0% |
| `rtl/p_core` + shared trap unit | **100%** (92/92) | 83.2% |

The toggle shortfall is structural, as for the E-core: `mie`/`mip` have 29
hardwired bits each; seven 64-bit counters, `mcycle`, `minstret` and
`rvfi_order` have upper halves that need ~2³² events; every pc, target and
address lives inside a 192 KiB map, so bits 18 and up never toggle; the BTB tag
and target arrays carry those same always-zero address bits. The ranked list is
in `build/p_core/coverage/summary.txt`.

## 4. Known limitations

* **No Fmax figure.** Neither core's clock frequency is measured: that needs
  place and route (Vivado or nextpnr), which is not installed here, and Yosys'
  own longest-path pass is not a timing estimate (it counts ripple adders bit
  by bit and does not recognise vendor flip-flops). The P-core's comparison
  with the E-core is therefore per clock only; the frequency benefit a deeper
  pipeline is meant to buy is unquantified. See `docs/p_core_results.md`.
* **Prediction is the plan's BHT + BTB, nothing more.** There is no
  return-address stack, so a return from a function called from several sites
  mispredicts; and the BTB is direct-mapped over `pc[7:2]`, so any two control
  transfers 256 bytes apart evict each other. In Dhrystone, returns are the
  largest single source of mispredicts (≈44%), then BTB conflicts on JALs
  (≈28%) and branches (≈28%); see `docs/p_core_results.md`.
* **Interrupts are not in the lockstep runs**, for the same reason as the
  E-core: the ISS cannot know when an asynchronous interrupt arrives. They are
  covered by `irq_timer` and `irq_muldiv`.
* **`ma_data`** is skipped: misaligned accesses trap by specification.
* **No caches yet** (Phase 3), so there are no cache-miss counters.
