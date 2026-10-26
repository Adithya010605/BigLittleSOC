# Physical design: tracker

The layout of the 2P+2E BigLittleSOC on ASAP7 with OpenROAD-flow-scripts
(ORFS). This file records **what was done, what was found, what was changed,
and why**, newest entries last. Add an entry every time a run teaches
something or a decision is made.

| | |
|---|---|
| Branch | `gds_flow` |
| Process | ASAP7 (7 nm predictive FinFET) |
| Tools | ORFS Docker image `openroad/orfs:latest`: OpenROAD 26Q3-771, Yosys 0.67 (`read_slang`), KLayout 0.30.7 |
| Method | Hierarchical: E-tile and P-tile laid out once each, placed twice in `soc_top_pd` |

---

## Status

| Block | Run 1 (automatic) | Run 2 (floorplan) | Run 3 (clock sweep) | Abstract |
|---|---|---|---|---|
| E-tile | ✓ done (GDS, timing not met at 1000 ps) | ✓ done: runs 2–4 (best: run 4, 741 MHz estimate, all electrical checks clean) | ✓ done: 1300–1500 ps, 714 MHz (section 10); without test ports, 1400 ps fails by 140 ps from synthesis noise (section 12) | trial from 1400 ps (section 11) |
| P-tile | — (hand floorplan from the start) | runs 1–2 out of memory in routing; run 3 (BTB 16) complete: 0 DRC, ~615 MHz estimate (sections 13–14); run 4 (multiplier RTL + low-Vt): 0 DRC, **790 MHz** estimate (section 15) | next | — |
| Top (`soc_top_pd`) | — | — | — | — |

---

## Folder layout

```
pd/
├── README.md             this tracker
├── asap7/soc_top/        what ORFS reads (committed)
│   ├── e_tile/           config.mk, constraint.sdc (+ io.tcl, macro_place.tcl in run 2)
│   └── p_tile/
├── results/              numbers and pictures kept from runs (committed)
└── orfs/                 raw ORFS runs: databases, GDS, logs (git-ignored)
```

Run a block (inside `scripts/orfs_shell.sh`, from `/OpenROAD-flow-scripts/flow`):

```sh
make DESIGN_CONFIG=/workspace/pd/asap7/soc_top/e_tile/config.mk NUM_CORES=12
```

---

## Log

### 1. Tool setup (2026-10-20)

**Done:** OpenROAD-flow-scripts runs from its Docker image through
`scripts/orfs_shell.sh`. The `gcd` example ran end to end on ASAP7 in about 1
minute (0 DRC errors).

**Found, and changed:**

| Problem | Cause | Fix |
|---|---|---|
| `openroad` not found in the container | The image puts it on `PATH` only after `source env.sh` | The launcher sources `env.sh` |
| GUI windows don't open | The display (Xwayland, Hyprland) only accepts the logged-in user; the container ran as root | The launcher runs the container as the host user |
| CTS crashed: `illegal instruction` | The image's `kepler-formal` equivalence checker needs AVX-512; this Ryzen 4800H has none, and ORFS turns the check on automatically | The launcher sets `LEC_CHECK=0` |
| Can't write results in the image | ORFS's folder is root-owned | Results go to `WORK_HOME`, set by the launcher to `pd/orfs/` (since 2026-10-22) |

### 2. Plan (2026-10-21)

**Decided:**
- **Hierarchical flow (method 1c),** for the **full 2P+2E coherent SoC**.
  - **Why:** each tile type appears twice, so it's laid out once and reused. It's
    also how industry builds multi-core chips. A simplified 1P+1E design without
    snooping was considered and rejected: the coherent 2P+2E SoC is the project.
- **ASAP7.**
  - **Why:** a modern node, fully supported by ORFS, with ready-made fake-RAM
    macros. It's predictive, so it can't be fabricated; that's stated openly.
- **A reset synchroniser was considered and left out.**
  - **Why:** not needed for layout results. It's recorded as a limitation (a
    production chip would add one).

### 3. RTL made ready for layout (2026-10-22, commit `b0033fe`)

| Change | Why |
|---|---|
| **Tiles:** `rtl/soc/p_tile.sv`, `e_tile.sv` = a core + its L1I + L1D + both clock gates. `rtl/cache/l1_pair.sv` holds a core's two caches. | A hard block must contain everything that talks every cycle (core and its caches). The L1s used to live in `coherent_mem`, away from their cores. |
| **SRAM wrapper** `rtl/cache/sram_sp.sv`: ASAP7 `fakeram7_256x256` in synthesis, a matching model in simulation | Cache data built from flip-flops would be about 3 million flip-flops: too big, too slow, unroutable. Memories must be SRAM macros. |
| **Cache data, L2 data and main RAM moved into SRAM.** Reads are synchronous (data next cycle), so a **cache hit now takes 2 cycles** | The macro has registered reads. The cores can't overlap requests, so the hit latency became 2 cycles. This was chosen for simplicity; performance roughly halves on cache-resident code. |
| **Snoop data and L2 data arrive one cycle later** (`snoop_bus.sv`: new `B_LDATA`, `B_SDATA`, `B_BDATA` states) | Same reason: SRAM read data comes the next cycle |
| **Partial writes to the main RAM are read-merge-write** (`sram_ctrl.sv`) | The macro has no byte enables |
| **SRAM model outputs garbage** unless read the cycle before | Matches the real macro, so a timing mistake fails a test instead of hiding |
| **Clock gate** = ASAP7 `ICGx1_ASAP7_75t_R` in synthesis (`clock_gate.sv`) | Timing analysis and clock-tree synthesis must recognise it as a clock gate, not a loose latch and AND gate |
| **`soc_top_pd.sv`:** chip top with only clock, reset and UART pins, 64 KB RAM | Testbench ports would become hundreds of fake pins. 64 KB RAM stands in for off-chip memory. |
| **`mc_auto` test:** IPC thresholds and its compute loop adjusted | With 2-cycle hits the highest possible IPC is 0.5, so the old "busy vs idle" thresholds no longer separated the two. Hardware unchanged. |

**Checked:** lint 0 warnings; coherence unit tests pass; 20/20 SoC programs pass.

### 4. E-tile run 1, attempt 1 (2026-10-23)

**Setup:** `pd/asap7/soc_top/e_tile/config.mk` + `constraint.sdc`. 1000 ps clock,
automatic floorplan at 40% utilisation, placement density 0.6.

**Found, and changed:**

| Finding | Cause | Fix |
|---|---|---|
| Run failed at once: paths like `.../soc_top_e_tile /base` | Comments at the end of `config.mk` lines: make keeps the spaces before `#`, so the name became `"soc_top_e_tile     "` | Comments moved onto their own lines |
| Synthesis OK: 2 data macros, 2 clock gates, 0 problems. But **126,885 cells, 13,487 flip-flops, 19,791 µm²**, and synthesis took 15 min | **10,752 of the flip-flops were cache tags and states** (2 caches × 256 sets × 21 bits), each read in two places (core, snoop), which needs huge multiplexers | See section 5 |
| Global routing: no overflow, 21% of tracks used | — | — |
| **Detailed routing killed** (error 247 = out of memory), at about 12–13.8 GB, with 16 and then 12 threads | The design's size, not the thread count: memory barely changed between 16 and 12 threads. The machine has 15 GB. | See section 5 |
| **WNS −628 ps at 1000 ps** | Worst path: E-core execute → fetch PC (branch decision and next PC), about 80 gates in a row. The core needs about 1.6 ns as built. | Not fixed yet: for the clock sweep and a possible RTL fix |

### 5. Cache tags moved into SRAM (2026-10-23)

**Decision:** move the L1 **tags** from flip-flops into a small SRAM
(`fakeram7_256x32`, 8.4 × 42 µm), one per cache way. The **states** (I/S/M)
stay flip-flops.

**Why:**
- The tags were 80% of the tile's flip-flops and most of its cells, so routing
  needed more memory than the machine has.
- Real caches keep tags in SRAM too.
- The states are small (1,024 bits) and needed instantly everywhere (snoop
  dirty checks, races), so they stay flip-flops.

**What changed:**

| Where | Change |
|---|---|
| `l1_dcache.sv` | Tags read with the data in the request cycle, compared next cycle (no extra latency, since the data already took that cycle). Victim tag kept in a register for writebacks. "Was a hit" remembered for upgrades and write-through. Tags written only on fills. |
| `l1_dcache.sv` (snoops) | A snoop reads tags and data in its cycle and answers (hit, dirty, line) in the next; its state change happens then. Flush steps wait while a snoop is in progress. |
| `snoop_bus.sv` | Reads the snoop answer in its existing data cycle (`B_SDATA`, `B_BDATA`): **no extra bus cycles** |
| `sram_sp.sv` | Also builds the 32-bit macro |
| `config.mk` | Adds the 256×32 macro's `.lef`/`.lib`; removes the raised flip-flop-memory limit |

**Result:**

| | Before | After |
|---|---|---|
| Cells | 126,885 | **37,613** (−70%) |
| Flip-flops | 13,487 | **3,857** |
| Area | 19,791 µm² | **10,595 µm²** (−46%) |
| Macros | 2 | 4 (2 data + 2 tag) |
| Synthesis time | 15 min | 1.5 min |
| SoC cycle counts | — | unchanged (same latency) |

**Checked:** lint 0 warnings in all 8 configurations; coherence unit tests about
170 million checks, 0 failures; 20/20 SoC programs pass.

**Also found:** the first synthesis attempt after this change failed ("Compilation
failed"), because `config.mk` listed only the 256×256 macro's files. Fixed by
adding the 256×32 files.

### 6. E-tile run 1, attempt 3: complete (2026-10-23)

**Setup:** unchanged: automatic floorplan, 40% utilisation, density 0.6, 1000 ps
clock; routing with 12 threads (`NUM_CORES=12`).

**Result:** the full flow finished, with a routed GDS (`6_final.gds`), in about
31 minutes. Peak memory was 9.2 GB, so it now fits in the machine's 15 GB.

| Metric | Value |
|---|---|
| Die | 165.5 × 165.5 µm (core 26,701 µm²) |
| Design area (cells + macros) | 11,280 µm², 42% utilisation |
| Macros | 4: 2 data (`fakeram7_256x256`), 2 tag (`fakeram7_256x32`) |
| Routed wirelength | 391,221 µm |
| Route DRC errors | **0** |
| Antenna violations | **0** |
| Setup at 1000 ps | **WNS −391.6 ps**, TNS −126,082 ps, 954 failing endpoints |
| Hold | **0 violations**; worst hold slack **+29.0 ps** (L1 controller state `cs_q[5]` → `cs_q[8]`). The reset-release check from `rst_ni` has +172 ps. |
| Minimum period (this run) | **1391.7 ps → fmax ≈ 719 MHz** |
| Clock skew (setup) | 53.8 ps |
| Power at 1 GHz (default activity) | 26.6 mW: combinational 52%, macros 23%, clock 12%, sequential 12% |

**Where the automatic placer put the macros:** the two data macros in the
**bottom-left and bottom-right corners**, the two tag macros **together at the
top left**. Each cache's tags therefore sit far from their own data, which run
2's hand floorplan should fix.

**Setup vs hold:**
- **Setup fails at 1000 ps** by 392 ps: the slowest path needs about 1392 ps.
  A slower clock fixes this, or a shorter path in the RTL.
- **Hold is clean,** with +29 ps of margin. Hold doesn't depend on the clock
  period, so a hold failure would mean the tile can't work at any speed. With
  hold clean, the only open question is how fast the tile can run.

**Clock gates and the clock tree:** both `ICGx1_ASAP7_75t_R` cells were placed,
near the centre of the 165.5 µm die, and the clock tree was built **through**
them:

| Clock gate | Instance | Position (µm) |
|---|---|---|
| Core clock gate | `u_cg.u_icg` | (84.0, 108.0) |
| Cache clock gate | `u_l1.u_cg.u_icg` | (74.6, 84.5) |

```
clk_i (tile clock pin) ── 2 sinks: the two clock gates
   ├──► core clock gate  ──► core_clk    ──► 2,025 flip-flops (the E-core)
   └──► cache clock gate ──► cache clock ─┬─► 4 SRAM macros (2 data, 2 tag)
                                          └─► 1,832 flip-flops (cache states, controllers)
```

So stopping the core's gate (sleep, park) stops all of the core's flip-flops,
and stopping the cache's gate (cluster off) stops the caches. Placing the gates
centrally keeps each sub-tree short and balanced, which is part of why the
setup skew is only 54 ps.

**Pictures** (OpenROAD GUI, saved in `results/e_tile/run1/`):

| Picture | What it shows |
|---|---|
| [Macro placement](results/e_tile/run1/macro_placement.png) | The automatic placer's choice: the two **data** macros (`..u_data..u_ram`, 33 × 84 µm) in the **bottom-left and bottom-right corners**, with their pins turned inward (left one flipped). The two thin **tag** macros side by side at the **top left**: each cache's tags are far from its own data. |
| [Routing congestion](results/e_tile/run1/routing_congestion.png) | Red (busy) over and along the **inner edges of the data macros**, where every line-data pin is reached, and in the column of logic **between the two data macros**. The logic in the middle is yellow-orange; the empty right and top areas are blue/green (idle). It routed with 0 DRC errors, but these are the hot spots to relieve in run 2. |
| [Layout](results/e_tile/run1/layout.png) | Cells (red) bunched in a **cluster around the centre and top**, a thin band between the data macros, and large empty areas on the right and the top. Pins on the left, right and top edges, wherever the tool put them. |
| [Critical path](results/e_tile/run1/critical_path.png) | The worst setup path drawn on the layout: launch clock (cyan) from the clock pin on the **left edge** into the middle, the data path through the E-core logic in the **centre**, capture (green) nearby. Start `u_core.u_ex_stage.idex_ctrl_o[22]`, end `u_core.u_if_stage.pc_q[28]`: the branch → next-PC path. The top of the list is all the same start point into different PC bits. |

**For run 2's floorplan, from these pictures:**
1. **Put each tag macro next to its own data macro.** Tag and data are read
   together every access, by the same cache controller.
2. **Give the data macros' pin edges more room:** a bigger halo on the pin side,
   or partial blockages there.
3. **Fix the tile size smaller.** The large empty areas and 42% utilisation mean
   the die can shrink, which also shortens wires.
4. **Place the pins deliberately** (bus/snoop on one edge, PMU on another,
   clock central) instead of wherever the tool put them. The clock currently
   enters on the left edge and travels across the tile.

**Worst path:** the same as attempt 1. E-core execute stage
(`u_ex_stage.idex_ctrl_o`) → fetch stage's PC (`u_if_stage.pc_q`): the branch
decision and next-PC logic, 1,596 ps of data delay. It's in the E-core itself,
not the caches. It improved from −628 ps to −392 ps, because the smaller tile
has shorter wires.

**What this tells us:**
- The tile routes cleanly at 42% utilisation, so there's room to make it
  smaller in run 2.
- The E-core's fmax is about 720 MHz as built. The branch/next-PC path is the
  target for the clock sweep and any RTL fix.
- 1000 ps is too fast for this tile. Run 2 should use a clock it can meet
  (e.g. 1400–1500 ps) so the floorplan is judged on congestion and wirelength
  rather than on an impossible clock.

### 7. E-tile run 2: hand macro placement, smaller tile, clock pin (2026-10-24)

**What changed from run 1, and why:**

| Change | Why |
|---|---|
| **Tag SRAMs stacked above their own data SRAMs** (`macro_place.tcl`): L1 data cache on the west edge (mirrored, pins east), L1 instruction cache on the east edge (pins west); tags 5 µm above the data, on the pin side | Run 1 left both tag macros at the top left, far from their data. Tag and data of a cache are read together by the same controller, so their pins should sit on one line next to it. Macros on the edges keep the middle as one region for the logic. |
| **Fixed 145 × 145 µm tile** (was 165.5 µm automatic at 40%) | Run 1 had large empty areas; a smaller tile shortens wires |
| **5 µm macro halo** | Keeps standard cells off the macros' edges (pin access) |
| **Clock pin at the middle of the top edge** (`io.tcl`) | In run 1 the clock entered on the left edge and crossed the tile to the clock gates near the centre |
| **Clock 1450 ps** (was 1000 ps) | Just above run 1's 1392 ps limit, so the floorplan is judged on wiring rather than an unreachable target |

**Checked:** the 4 macros are `FIXED` exactly where `macro_place.tcl` put them,
and the automatic macro placer reported "No unfixed macros… Skipping". The
clock pin is at (70.1, 145.0) µm, the middle of the top edge. Both clock gates
are near the centre: core gate (69.9, 59.1), cache gate (72.5, 72.4).

**Result, against run 1:**

| Metric | Run 1 (auto, 1000 ps) | Run 2 (hand, 1450 ps) | Change |
|---|---|---|---|
| Die | 165.5 × 165.5 µm | 145 × 145 µm | **−23% area** |
| Utilisation | 42% | 54% | |
| Routed wirelength | 391,221 µm | 272,174 µm | **−30%** |
| Routing tracks used (global route) | 19.8% | 18.9% | no overflow in either |
| Route DRC / antenna | 0 / 0 | 0 / 0 | |
| Setup WNS | −392 ps (at 1000 ps) | −175 ps (at 1450 ps) | not comparable: different targets |
| Failing setup endpoints | 954 | 94 | |
| Minimum period from this run | 1392 ps | **1625 ps** | **worse**, see below |
| Hold | 0 violations, +29.0 ps | 0 violations, +24.3 ps | |
| Clock skew (setup) | 53.8 ps | 55.8 ps | same |
| Power | 26.6 mW at 1 GHz | 17.6 mW at 690 MHz | ≈4% less energy per cycle |
| Runtime / peak memory | 31 min / 9.2 GB | 24 min / 7.4 GB | |

**Pictures:** ORFS's own images for both runs are now saved side by side
(`results/e_tile/run1/final_*.webp`, `results/e_tile/run2/final_*.webp`):
`final_all`, `final_placement`, `final_routing`, `final_congestion`,
`final_worst_path`, `final_clocks`.
- [Run 2 placement](results/e_tile/run2/final_placement.webp): macros on the
  edges with the tags on top, all pins facing the centre; the cells fill the
  channel between the two macro columns.
- [Run 2 congestion](results/e_tile/run2/final_congestion.webp): less red than
  run 1. The remaining hot spots are a band in the lower middle and the data
  macros' inner (pin) edges.
- The strips beside the tag macros, outside them (above each data macro), stay
  empty: no logic wants to be there. That's about 2 × 25 × 45 µm unused.

**Found:**
1. **The floorplan helped the wiring a lot:** 23% smaller, 30% less wire, about
   4% less energy per cycle, still 0 DRC.
2. **The minimum period got worse (1392 → 1625 ps), and this run can't tell us
   whether the floorplan is to blame.** The two runs had different clock
   targets, and timing repair after placement works only as hard as the target
   asks: at 1000 ps every path above 1000 ps was worked on; at 1450 ps far
   fewer. The fair test is the same floorplan at the same target as run 1.
3. **Synthesis never received the clock target, in either run.** ORFS reads the
   period from the SDC by looking for `set clk_period <number>`. The SDC
   computes it (`set clk_period [expr …]`), so ORFS read the text `[expr`, and
   synthesis was not timing-driven. Both runs got the identical netlist (37,613
   cells), so run 1 vs run 2 is still fair, but every run so far lost
   timing-driven synthesis. **To fix next:** write the period as a plain number
   in the SDC, and pass the sweep's period to synthesis too
   (`ABC_CLOCK_PERIOD_IN_PS`).

### 8. E-tile run 3: run 2's floorplan at 1000 ps, SDC fixed (2026-10-25)

**What changed, and why:**

| Change | Why |
|---|---|
| **SDC: the period is a plain number** on the first `set clk_period` line (`set clk_period 1000`); the sweep's override is on a separate `if` line | ORFS reads the synthesis target from the first `set clk_period <n>` line. The old `[expr …]` gave it the text `[expr`. |
| **Clock back to 1000 ps** | The same target as run 1, so the two floorplans are compared fairly |
| Floorplan, pins, halo, tile size | **Unchanged from run 2** |

**Checked:** `clock_period.txt` now holds `1000`, and synthesis (ABC) ran with
`-D 1000`. Run 1's log says `Setting clock period to [expr`.

**Finding about the SDC fix:** the netlist came out **identical** (37,613 cells,
10,594.502340 µm², to the last digit). ABC made the same choices with and
without the target. The fix was needed, but it hadn't changed any earlier
result.

**Result, same 1000 ps target as run 1:**

| Metric | Run 1 (automatic floorplan) | Run 3 (hand floorplan) | Change |
|---|---|---|---|
| Minimum period / fmax | 1392 ps / 719 MHz | **1363 ps / 734 MHz** | **−29 ps, 2% faster** |
| Setup WNS | −392 ps | −363 ps | better |
| Setup TNS | −126.1 ns | −97.9 ns | −22% |
| Failing setup endpoints | 954 | 934 | |
| Die | 165.5 × 165.5 µm | 145 × 145 µm | −23% area |
| Utilisation | 42% | 55% | |
| Routed wirelength | 391,221 µm | 278,122 µm | −29% |
| Power at 1 GHz | 26.6 mW | 26.2 mW | |
| Hold | +29.0 ps, clean | +28.6 ps, clean | |
| Clock skew (setup) | 53.8 ps | 51.9 ps | |
| Route DRC / antenna | 0 / 0 | 0 / 0 | |

Pictures: `results/e_tile/run3/final_*.webp`.

**Conclusions:**
1. **The hand floorplan is better on every count:** smaller, less wire,
   slightly faster, slightly less power, still clean. It stays as the E-tile
   floorplan.
2. **Run 2's worse minimum period (1625 ps) came from its relaxed 1450 ps
   target,** not from the floorplan. After placement, timing repair works only
   as hard as the target demands. Compare timing only at equal targets.
3. **The E-tile's speed limit is its logic, not its layout.** The worst path is
   still the E-core's branch decision (EX ALU result forwarded into ID's
   compare, then the next-PC mux), at about 1.36 ns. A floorplan moved it by
   2%. Getting much faster needs the synthesis options or the RTL change
   (branch-after-ALU stall) from the plan.

### 9. Decisions after run 3, and run 4: max fanout limit (2026-10-25)

**Decided: no parallel-prefix adder option (`SWAP_ARITH_OPERATORS`) for now.**
- **What it is:** an ORFS option that builds adders and comparators as
  parallel-prefix trees instead of full-adder chains. It would shorten the
  E-core's branch path.
- **Why not:** ORFS's own scripts call the underlying feature "not yet stable",
  and it requires switching the whole flow to hierarchical mode
  (`OPENROAD_HIERARCHICAL=1`). For a learning project, a stable, understood
  flow matters more than a few percent of speed. About 730 MHz is accepted for
  the E-tile for now; this can be revisited later.
- **Incident:** the edit adding this option was applied, and its synthesis
  started, even though the step was cancelled. Found before any result was
  used: both run-4 containers were stopped, the option removed from
  `config.mk`, and the partial run-4 output deleted.

**Checked on run 3, beyond timing and routing:**

| Check | Run 3 | Verdict |
|---|---|---|
| IR drop (power-grid voltage loss) | worst 5.1 mV of 0.77 V (0.7%), average 0.29 mV | ✓ far inside the usual 5–10% budget |
| Max capacitance / max fanout violations | 0 / 0 | ✓ (no fanout limit was set, so the fanout check had nothing to flag) |
| **Max slew violations** | **350** (run 1: 341, run 2: 857) | ✗ see below |

**Found: one net causes the slew violations.** A single buffer
(`place11221`, `BUFx6f`) drives **131 gate inputs**. Its edges take about
456 ps against the 320 ps slew limit, and every input on that net counts as a
violation. It's most likely one of the cache's wide select or enable signals,
which fans out across a 256-bit line. Every run has it, so it isn't caused by
the floorplan.

**Run 4, what changed and why:**

| Change | Why |
|---|---|
| `set_max_fanout 32 [current_design]` in `constraint.sdc` | With no fanout limit, the repair step left one buffer driving 131 inputs. With a limit, it has to split such nets into a buffer tree, which shortens each edge's transition. |
| Everything else | **Unchanged from run 3** (floorplan, pins, 1000 ps), so any difference comes from the fanout limit |

**Expected:** the slew violations drop to (near) zero; timing may improve a
little, since slow edges also slow down the gates they drive.

**Result:**

| Metric | Run 3 | Run 4 (max fanout 32) |
|---|---|---|
| **Max-slew violations** | **350** | **0** ✓ |
| Minimum period / fmax | 1363 ps / 734 MHz | **1349 ps / 741 MHz** |
| Setup TNS | −97.9 ns | −93.7 ns |
| Failing setup endpoints | 934 | 929 |
| Hold | +28.6 ps, clean | +31.5 ps, clean |
| Design area | 11,250 µm² | 11,258 µm² (+8 µm² of buffers) |
| Wirelength | 278,122 µm | 275,974 µm |
| Power at 1 GHz | 26.2 mW | 26.1 mW |
| Worst IR drop | 4.9 mV | 4.7 mV |
| DRC / antenna / max cap / max fanout | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |

Pictures: `results/e_tile/run4/final_*.webp`.

**Conclusion:** a one-line constraint removed every slew violation, for 8 µm²
of extra buffers, and gave a little timing back (about 1%). Run 4 is the
cleanest E-tile so far: every electrical check passes, and only setup at
1000 ps fails, because of the E-core's logic. It is the E-tile's current
best configuration.

### 10. E-tile clock sweep, 1300–1500 ps (2026-10-25)

**Setup:** run 4's configuration at 1300, 1350, 1400, 1450 and 1500 ps, the
range around run 4's 1349 ps estimate. `scripts/pd_sweep.sh` runs the full
flow once per period (`FLOW_VARIANT=sweep_<period>`, one at a time for
memory). It sets both the SDC clock (`CLK_PERIOD_PS`) and the synthesis target
(`ABC_CLOCK_PERIOD_IN_PS`); the 1300 ps synthesis log confirms
`clock period to 1300`. `scripts/pd_sweep_report.py` writes the table to
`results/e_tile/sweep/sweep.md` and `.csv`.

**Correction to sections 6–9: the hold slack figures were the wrong check.**
The first "min" path in ORFS's finish report is the reset-release (removal)
check from the `rst_ni` input, and that was recorded as the worst hold slack
(+172, +384, +196, +234 ps). The real worst hold slack (ORFS's
`finish__timing__hold__ws`), between two cache-controller flip-flops
(`cs_q[5]` → `cs_q[8]`), is **+29.0, +24.3, +28.6, +31.5 ps**. Hold is still
clean in every run, but the margin is about 30 ps, not 200. The tables above
are corrected.

**Found at 1300 ps (first attempt): the worst path wasn't the E-core.**

| Result at 1300 ps | |
|---|---|
| Setup WNS | −192 ps (estimate 670 MHz, *worse* than run 4) |
| Worst path | `dbg_csr_addr_i` (input) → `dbg_rf_rdata_o` (output), straight through the tile |
| E-core's own worst path (branch → next PC) | −94 ps, so about 1394 ps / 717 MHz |
| Slew violations | 8 (run 4: 0) |

Why:
- **The debug port is functional, not test-only.** The PMU uses `dbg_rf_*`,
  `dbg_csr_*` and `dbg_pc_*` to copy a task's registers, PC and CSRs from one
  core to another during migration, one item per cycle (`pmu.sv`).
- **The CSR port is shared** (`e_core_top.sv`:
  `csr_addr_i = dbg_en ? dbg_csr_addr_i : csr_addr`). STA can't know that the
  debug side is selected only while the core is halted, so it times
  `dbg_csr_addr_i` → CSR read → trap/retire logic → `retire_o`, `events_o`
  and on to `dbg_rf_rdata_o`.
- **The I/O budget gave such paths only 20% of the cycle.** Every input had
  40% of the cycle outside the tile, and every output 40%, so a path from an
  input to an output had 20% (260 ps at 1300 ps). The debug paths need about
  450 ps. At 1000 ps they were hidden behind the E-core's −349 ps path.

Paths from an input to an output failing at 1300 ps, all starting at
`dbg_csr_addr_i`:

| Output | Bits failing | Worst slack |
|---|---|---|
| `dbg_rf_rdata_o` | 32 / 32 | −192 ps |
| `dbg_csr_rdata_o` | 32 / 32 | −100 ps |
| `events_o` | 1 / 9 | −90 ps |
| `retire_o` | 1 / 1 | −89 ps |

**Decided: a 20% budget for the debug ports** (`dbg_*_i`, `dbg_*_o`), 40% for
all other ports.
- **Why:** on the PMU side the address comes straight from a counter register
  (`m_k_q`) and the read data passes two small muxes into a register
  (`buf_q`), so little of the cycle is used outside the tile. Every path stays
  timed, and the top level checks the assumption again.
- **Considered:** false paths (more exact, since the paths through the shared
  CSR mux can't happen, but a wrong false path is never caught by any tool,
  and the real CSR read path would still need a smaller budget); registering
  `dbg_csr_addr_i` inside the tile (removes every path from an input to an
  output, the usual rule for a hard block, but changes the RTL and the PMU).
  Kept as a possible later improvement.
- **Checked** on the first 1300 ps layout with the new SDC: the debug ports
  match (6 inputs, 3 outputs) and every debug path passes. One path remains:
  `bus_done_i[0]` → `retire_o`, −20 ps (bus finishes a miss, the core retires
  the same cycle). It's real and the PMU counts `retire_o` with an adder, so
  it keeps 40%, and the re-run's timing repair should close it.

The first 1300 ps run was deleted and the sweep restarted with the new SDC.

**Result** (`results/e_tile/sweep/sweep.md`, generated; pictures of the 1400 ps
run in `results/e_tile/sweep/1400/`):

| Period | Target | Setup WNS | Failing endpoints | Hold WNS | Area (µm²) | Repair buffers | Power | Energy/cycle | Slew viol. | Met? |
|---|---|---|---|---|---|---|---|---|---|---|
| 1300 ps | 769 MHz | −67.54 ps | 59 | +26.3 ps | 11,080 | 4,387 | 19.6 mW | 25.5 pJ | 0 | no |
| 1350 ps | 741 MHz | −11.04 ps | 11 | +26.5 ps | 11,054 | 4,133 | 18.8 mW | 25.4 pJ | 0 | no |
| **1400 ps** | **714 MHz** | **+3.63 ps** | **0** | **+29.9 ps** | 11,027 | 3,942 | 18.0 mW | 25.1 pJ | 0 | **yes** |
| 1450 ps | 690 MHz | −0.03 ps | 1 | +27.0 ps | 11,011 | 3,781 | 17.3 mW | 25.1 pJ | 0 | no (tie) |
| 1500 ps | 667 MHz | +1.94 ps | 0 | +27.8 ps | 11,005 | 3,670 | 16.7 mW | 25.1 pJ | 14 | no (slew) |

All five: 0 DRC, 0 max-cap, 0 max-fanout violations; worst IR drop 3.4–4.2 mV;
setup skew 53–64 ps.

**E-tile fmax: 714 MHz (1400 ps), proven:** setup and hold met, every check
clean. 1350 ps misses by 11 ps, so the real limit lies between 1350 and
1400 ps.

**Found:**
1. **Two paths set the limit, and they're nearly equal.** At 1400 ps:
   `bus_rdata_i` → `pc_q` (+3.6 ps: a cache fill from the bus goes through the
   core into the next-PC logic in the same cycle, and as a tile input it carries
   the 40% budget), and the E-core's branch → next PC (+25.8 ps). Speeding up
   only one of them gains little.
2. **The "fmax estimate" depends on the target,** as found in run 2: 731 MHz
   from the 1300 ps run, 716 MHz from 1400 ps, 668 MHz from 1500 ps. Only a run
   that meets timing proves a frequency.
3. **1450 ps "fails" by 0.03 ps on one endpoint.** Timing repair runs with
   `-setup_margin 0`, so at a relaxed target it stops at about zero slack, and
   detailed routing can tip one path just below. It's a tie, not a real limit,
   but it means a sweep point isn't guaranteed to pass just because a faster
   one did. A small setup margin would prevent this.
4. **1500 ps: 14 max-slew violations, all on one net.** A `BUFx3` drives 31
   inputs over about 56 µm (`net9876`, fed by an `AND2x2`). Under the
   32-fanout limit, but a long wire. With timing relaxed, repair picked the
   smallest buffer that met timing, and the routed wire made its edges 362 ps
   against 320 ps. Electrical, not timing; fmax unaffected. Possible fix: a
   slew margin for repair (`SLEW_MARGIN`).
5. **Slowing the clock saves power but not energy.** From 1300 to 1500 ps,
   power drops 15% (19.6 → 16.7 mW) but energy per cycle stays at about
   25 pJ. With the voltage fixed, each cycle costs the same; a lower frequency
   only spreads them out. Saving energy needs a lower voltage too (DVFS), which
   this flow doesn't model (one 0.77 V corner).
6. **A relaxed clock saves little area:** −0.7% design area and −16% repair
   buffers from 1300 to 1500 ps. The SRAM macros (6,288 µm²) don't change.

### 11. E-tile abstract, trial from the 1400 ps run (2026-10-26)

**What:** `make … FLOW_VARIANT=sweep_1400 generate_abstract` (ORFS
`generate_abstract.tcl`, 40 s) wrote the two views the top level uses for a
block, the same kind it already uses for the SRAMs:

| File | What it holds |
|---|---|
| `e_tile.lef` (454 KB) | `MACRO e_tile`, `CLASS BLOCK`, 145 × 145 µm; every pin with its layer and position; blockages (`OBS`) on M1–M7, so the top level can route over the tile only on M8–M9; VDD/VSS pins on M6 |
| `e_tile_typ.lib` (4.4 MB) | Timing model: 381 setup and 381 hold checks on inputs, 1,235 clock → output delays, 2,643 combinational (input → output) arcs |

The top level (`BLOCKS = e_tile p_tile`) finds these under
`results/asap7/soc_top_e_tile/<FLOW_VARIANT>/`, and the GDS (`6_final.gds`)
from the same run. This was a trial; the final abstract comes from the
tile's run at the chosen chip period. Neither file is committed (they are
regenerated from the run).

**Checked in the timing model:** the boundary matches the 1400 ps run.
`bus_rdata_i` needs 836 ps inside the tile before the clock (the 840 ps
left after the 40% budget, so +3.6 ps), `snoop_hit_o` comes 845 ps after it.

**Found:**
1. **41% of the tile's pins are test-only.** Of 2,803 signal pins, 1,137
   are testbench taps: `l1_dbg_*` (L1 debug read, 548), `rvfi_*`
   (instruction trace) and `perf_*` (data monitor, `dmon_*` in `soc_top`).
   `soc_top_pd` leaves them unconnected, but in a hierarchical flow a tile's
   ports are fixed when the tile is laid out, so they keep their pins (driven
   by tie cells: the logic behind them was already left out in synthesis, see
   section 12). Section 3 planned to leave such ports out with
   `` `ifndef SYNTHESIS `` (plan step 1.5); that was done for `soc_top_pd`'s
   pins but not for the tiles' ports.
2. **Every input → output path ends at a PMU-facing pin:** `dbg_*_rdata_o`,
   `retire_o`, `events_o`, `flush_done_o`. Most go through the register
   file's write-through bypass (for example 1,248 arcs `bus_rdata_i` →
   `dbg_rf_rdata_o`) and the shared CSR port (section 10). The bus and snoop
   interface has none: every bus/snoop output comes from a register, which
   keeps top-level timing simple.

### 12. Test-only ports removed from the tiles; E-tile re-run at 1400 ps (2026-10-26)

**RTL change** (`e_tile.sv`, `p_tile.sv`, `soc_top.sv`; simulation unchanged):

| Where | Change |
|---|---|
| Both tiles | The testbench ports (`l1_dbg_*`, `perf_*`, `rvfi_*`) are ports only under `` `ifndef SYNTHESIS ``. In synthesis they are local signals, still driven by the core and caches, and removed as nothing reads them. |
| `soc_top.sv` | The tile port macro is split: `SOC_TILE_PORTS` (the chip's) and `SOC_TILE_TB_PORTS` (testbench, empty in synthesis). In synthesis the outputs it fed (`dbg_state_o`, `dbg_data_o`, `dmon_*`, `rvfi_*`) read 0. |
| Kept | `events_o`: the sysctl performance counters read it, so it's a chip signal. |

**What the test ports actually cost:** less than estimated. The logic behind
them was already left out in synthesis (`l1_dcache.sv` and `sram_sp.sv` tie
the probe and monitor under `SYNTHESIS`; RVFI is off), so each pin was driven
by a tie cell.

| Synthesis | Before | After |
|---|---|---|
| Signal pins | 2,803 | 1,666 (−41%) |
| Cells | 37,613 | 36,476 (−1,137: one tie cell per pin) |
| Flip-flops | 3,857 | 3,857 |
| Area | 10,594.5 µm² | 10,515.5 µm² (−0.75%) |

**Checked:**
- Lint: all 8 configurations clean.
- The synthesis branch (`-DSYNTHESIS`, stub SRAM and clock-gate modules, tops
  `e_tile`, `p_tile`, `soc_top_pd`): the same warnings as before the change,
  none new. (That branch isn't part of `make lint`; its 4 warnings on
  `soc_top_pd` are older.)
- Every regression that passed before passes: unit, both cores' gates, cached
  E-core and P-core suites except `add_demo` (below), 20/20 SoC programs,
  benchmarks.

**Found: two failures from commit `b0033fe`, not from this change.** Both fail
identically on a clean checkout of the previous commit, and both pass on
`main` (`e03bb66`). So `make test` and `make soc-mutation` have not been fully
green on this branch since the PD-ready RTL change (section 3 recorded lint,
coherence unit tests and the 20 SoC programs, not the full gate).
1. **`add_demo` (cached E-core) fails:** it requires 100 dependent ADDs in at
   most 200 cycles. Behind the cache every instruction fetch is a 2-cycle hit,
   so they take 272. The hardware is as designed; the test's threshold assumes
   1-cycle fetch (the same kind of threshold `mc_auto` had adjusted in
   section 3).
2. **SoC mutation: 48 of 50 detected.** `hit_ignores_core_en` survives (on
   `main` a unit test caught it: "port answered while its core's clock is
   paused"; with 2-cycle SRAM hits it no longer triggers), and
   `flush_wb_race_ignored` is still caught by a unit assertion but counted as
   not detected.

**Result at 1400 ps: setup fails by 140 ps**, with every other check clean:

| | Sweep 1400 ps (with test pins) | This run |
|---|---|---|
| Setup WNS / failing endpoints | +3.6 ps / 0 | **−140.2 ps / 66** |
| Hold | +29.9 ps | +33.7 ps |
| Area / power | 11,027 µm² / 17.95 mW | 11,029 µm² / 18.23 mW |
| Wirelength | 278,909 µm | 274,646 µm |
| DRC / slew / cap / fanout | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |

**Why: synthesis mapped the critical path differently.** The E-core's branch →
next PC path (`idex_ctrl_o[22]` → `pc_q[29]`):

| | Sweep 1400 ps | This run |
|---|---|---|
| After synthesis (no wires) | 63 cells, 1,373 ps | 69 cells, 1,530 ps (+156 ps) |
| After routing | 62 cells, 1,540 ps gates + 21 ps wire | 71 cells, 1,678 ps gates + 23 ps wire |

The wire delay didn't change, and the bus pins sit on the same edges as
before (the north edge, which held most of the test pins, emptied). The core's
RTL didn't change either: removing outputs elsewhere changed the netlist that
ABC starts from, and its mapping of this one long path came out about 10%
slower (ABC is already in its default speed mode). **So the E-tile's fmax
carries roughly ±10% of synthesis noise**; the sweep's 714 MHz was a good
draw, not a stable figure.

### 13. P-tile setup and run 1 (2026-10-26)

**Setup** (`pd/asap7/soc_top/p_tile/`): the E-tile's final setup from the
start, so run 1 is already a hand floorplan.

| Carried over from the E-tile | P-tile |
|---|---|
| SDC: plain-number period, 40% I/O budget, 20% for `dbg_*` (section 10), max fanout 32 (section 9) | same `constraint.sdc` |
| No testbench pins (section 12) | from the start: the tile RTL has none in synthesis |
| Hand floorplan (section 8): each cache on one edge, pins facing the logic, 5 µm halo, clock pin top middle | 8 SRAMs (2-way caches). Each column: data way 0, tag 0, tag 1, data way 1, tags in the middle as all four are read together |
| Size from synthesis for about 55% utilisation | 162 × 275 µm, 53.5% |
| `soc_top_<block>` nickname for the top level | `soc_top_p_tile` |

**Synthesis:** 90,987 cells, 10,370 flip-flops, 23,122 µm² (2.5× the E-tile's
cells), 8 SRAMs, 2 clock gates, 0 problems, no latches. Flip-flops: branch
predictor 4,096 (BTB 64 × 55 bits, BHT 256 × 2), caches' state and LRU bits
3,374, register file 1,024, CSRs 740.

**Found and changed while setting up:**

| Finding | Cause | Fix |
|---|---|---|
| 220 `PDN-0110` warnings (an M4–M5 ground via not placed), all at x = 157.87 µm | At 160 µm wide, an M5 ground strap fell 1.1 µm inside the east core edge, too close for its vias | Tile 2 µm wider (162 µm): 0 warnings |
| Detailed placement failed: "Placed in rows check failed (1,409)" | Placement blockages added in the pockets beside the tags: tap-cell insertion fills every row with fixed tap and end-cap cells and ignores placement blockages, so all 1,409 sat inside them | Blockages removed (the E-tile's similar strips stayed empty without one) |

**Run 1 at 1000 ps: stopped in detailed routing, out of memory.** Global
routing was clean (no overflow, 28% of tracks, 0 antenna). Detailed routing
used 10.3 GB at 30% and was still rising; with the rest of the machine at
about 4 GB, Claude Code stopped the run before the system ran out. (The
E-tile peaked at 7.4–9.2 GB.)

**Timing after clock-tree synthesis, at 1000 ps:** WNS −786 ps, TNS
−2,192 ns, so about 560 MHz: the P-core is slower than the E-core so far.

| Worst paths | Slack | Failing endpoints |
|---|---|---|
| MEM-stage instruction → event decode → 7 × 64-bit performance counters (`mhpm_q`) | −788 ps | 124 |
| L1D request address / tags → hit → core stall → EX/MEM register enables (multiplier result, MEM exception address) | −582 ps | 94 |
| Bus/snoop outputs | −415 to −447 ps | ~270 |
| BTB/BHT training writes | −385 to −414 ps | ~2,500 |

**RTL change: counter increments** (`rtl/common/csr_unit.sv`, both cores).
`minstret` and the event counters were `q + (event ? 1 : 0)`: the events
(retirement, stalls, interlocks) settle late, and as the adder's carry-in they
rippled through all 64 bits. Now `event ? q + 1 : q`: the +1 comes from the
register alone, and the late event only selects. The same value every cycle.

| After synthesis (no wires) | Before | After |
|---|---|---|
| Counter path | −774 ps, 85 pins | −291 ps, 63 pins |
| Worst slack | −774 ps | −511 ps (now the cache → stall path) |
| TNS | −1,204 ns | −930 ns |
| Cells / area | 90,987 / 23,122 µm² | 91,576 / 23,195 µm² (+0.3%) |

Checked: lint clean (8 configurations); both cores' gates and mutation
suites pass (E-core 20 killed, 7 documented equivalents; P-core 34 / 2);
`add_demo` fails exactly as before (section 12).

**Considered: the BTB in SRAM** (`fakeram7_64x28` × 2 would hold the 55-bit
entries; the read can be issued with the next fetch address so the data
arrives on time). Not done: a single-port SRAM loses a lookup when training
writes, and a taken loop branch rewrites its entry every iteration, so
mispredict counts would depend on timing. `branch_predict.S` checks exact
counts at every wait-state setting. Keeping them exact needs a write buffer
with forwarding. And it would save at most the predictor's 17% of the cells.

**Where the cells are** (hierarchical synthesis, generic gates; the flat
total is within 0.1%, so tied-off ports hide almost nothing):

| Block | Cells | Share |
|---|---|---|
| L1 data cache (2-way, write-back) | 22,362 | 31% |
| L1 instruction cache | 18,477 | 25% |
| Branch predictor | 12,681 | 17% |
| CSRs (9 × 64-bit counters) | 4,418 | 6% |
| Register file | 4,107 | 6% |
| Multiplier | 3,584 | 5% |
| Rest | ~7,000 | 10% |

Nothing in it is dead logic: the testbench taps are gone (section 12) and
everything left is used by the chip. Making the tile smaller is a trade-off
(fewer BTB entries, 1-way caches, smaller counters, a multi-cycle multiplier).


### 14. P-tile run 3: BTB 16 entries, first complete layout (2026-10-26)

**RTL change:** the P-core's BTB from 64 to 16 entries (`p_core_pkg.sv`,
`BTB_IDX_W` 6 → 4), so detailed routing fits in memory. Synthesis: 77,160
cells (−16%), 7,714 flip-flops (−2,656), 21,400 µm² (−8%). Prediction only:
results don't change, a few more mispredicts. `fence_i.S` case 8 counts exact
mispredicts, and at the new size two of its instructions shared BTB entries,
so its loop and `stale_site` were moved to addresses that don't alias.

**Result at 1000 ps** (6 routing threads; pictures in `results/p_tile/run3/`):

| | P-tile run 3 | E-tile run 4 (same target) |
|---|---|---|
| Routed GDS, DRC / antenna | ✓, 0 / 0 | ✓, 0 / 0 |
| Setup WNS / failing endpoints | −627 ps / 4,176 | −349 ps / 929 |
| fmax estimate | **615 MHz** | 741 MHz |
| Hold | +18 ps, clean | +31 ps, clean |
| Max slew violations | 172 | 0 |
| Area / utilisation | 22,786 µm² / 52% | 11,258 µm² / 55% |
| Power at 1 GHz | 40.3 mW | 26.1 mW |
| Wirelength | 779 mm | 276 mm |
| Detailed routing peak memory | **13.3 GB**, 26 min | 7–9 GB |

**Found:** the P-tile is slower than the E-tile for now. Its worst path is the
L1D tag SRAM → hit → core stall → MEM-stage registers (−627 ps). Routing
memory is at the machine's limit: 13.3 GB of 15.4 GB.


### 15. Why the P-tile's fmax is low, and the fix: multiplier RTL + low-Vt (2026-10-26)

**The problem.** Run 3 reaches only about 615 MHz, below the E-tile's 714–741
MHz, although the P-core finishes programs 1.03–1.76× faster per cycle (bare
core: bubble_sort 7,113 vs 12,523 cycles, add_demo 3,893 vs 4,915, memcpy
240,053 vs 297,746, fib 421,169 vs 433,715). That speed-up is work per cycle
(5 stages, branch prediction, hardware multiply/divide, 2-way caches); fmax is
set by the single slowest path. A 5-stage pipeline should clock higher than a
3-stage one, but one path held it back:

```
L1D tag SRAM -> 2-way tag compare -> hit -> core may advance
   -> multiplier's first iteration on the forwarded operands
   -> 4 Booth partial products -> 64-bit add of 5 numbers
   -> product straight out -> EX result -> MEM register (result_q)
```

The SoC has one clock, so this tile would have set the whole chip's clock.

**Fix 1, RTL: the multiplier starts from registers and registers its result**
(`p_core_mul.sv`). The start cycle only captures the operands; the 4
iterations run from registers; the product goes into `result_q`, and
`done_o`/`result_o` come from registers. A late cache hit now only decides
"capture or not", and the 5-number add no longer feeds EX in the same cycle.
Results are unchanged; a MUL takes 6 cycles instead of 4.
- `p_perf.S`: one multiply is 5 busy cycles (was 3), cases 1 and 14.
- `mutation_test.sh`: `mul_result_not_held` now drops the held result by
  clearing `done_q` without `ack_i` (the old line it patched is gone).
- `docs/p_core_microarchitecture.md`: 6 cycles.
- Checked: lint clean (8 configurations); P-core assembly tests 20/20.

**Fix 2, layout: low-Vt cells on critical paths** (`config.mk`:
`ASAP7_USE_VT = RVT LVT`). RVT stays the main library; with LVT loaded too,
`repair_timing` swaps cells on failing paths to LVT (its `vt_swap` and
`crit_vt_swap` moves, on by default). LVT switches faster but leaks more, so
leakage rises (it was 1.0 mW of 40.3 mW). This matches big.LITTLE practice:
the big core spends leakage for speed; the E-tile stays RVT only.

**Run 4** = run 3 + both fixes, from synthesis, 1000 ps target (compares
directly with run 3). Expected: about 1.3–1.4 ns (roughly 700–770 MHz), so
the P-tile at least matches the E-tile.

**Run 4 result** (pictures in `results/p_tile/run4/`):

| 1000 ps target | E-tile run 4 | P-tile run 3 | P-tile run 4 |
|---|---|---|---|
| Setup WNS | −349 ps | −627 ps | **−266 ps** |
| fmax estimate | 741 MHz | 615 MHz | **790 MHz** |
| Setup TNS / failing endpoints | −94 ns / 929 | −842 ns / 4,176 | −241 ns / 2,870 |
| Hold | +31 ps | +18 ps | +11 ps |
| Area | 11,258 µm² | 22,786 µm² | 22,449 µm² |
| Power at 1 GHz / leakage | 26.1 / 0.5 mW | 40.3 / 1.0 mW | 42.5 / 1.1 mW |
| DRC / slew / cap violations | 0 / 0 / 0 | 0 / 172 / 0 | 0 / 65 / 0 |
| Routing peak memory | 7–9 GB | 13.3 GB | 13.3 GB |

After synthesis alone, worst slack went from −523 ps (run 3) to −20 ps; after
CTS, −637 → −291 ps.

**Found:**
1. **The P-tile is now the faster tile: 615 → 790 MHz (+28%)**, about 7% above
   the E-tile, on top of its 1.03–1.76× more work per cycle. The two changes
   ran together, so their separate shares aren't known.
2. **Low-Vt cost almost no leakage:** 1.0 → 1.1 mW with 20,817 of about
   82,000 cells LVT (synthesis already chose 24,606 LVT cells, not only
   timing repair).
3. **The worst path is now at the tile's edge:** L1D request → hit → core
   retire → the `retire_o` pin (PMU), which has the 40% output budget. The
   inside of the tile is no longer the limit; the top level checks the real
   budget.
4. **All timing so far is at the fast corner.** ORFS's ASAP7 default
   (`CORNER = BC`) loads the `_FF_` libraries, for both tiles in every run;
   earlier entries call it "typical". The comparisons stay fair (same corner
   everywhere), but sign-off needs the slow corner, where every fmax drops.

---

## Open items

| Item | Why it matters | When |
|---|---|---|
| E-tile fmax: 1400 ps fails by 140 ps after the test-port removal, from synthesis noise on the branch → next PC path (section 12) | The 714 MHz from the sweep isn't stable; the final tile needs a robust result | Next: over-constrain synthesis (`ABC_CLOCK_PERIOD_IN_PS` below the SDC period), or re-sweep, or the RTL fix (branch-after-ALU stall) |
| One slow net at 1500 ps (`BUFx3` driving 31 inputs, 14 slew violations) | Must be clean at whatever period the final E-tile uses | Only if the final period is above 1400 ps: try `SLEW_MARGIN` |
| Timing repair uses no setup margin | A relaxed run can end a hair below zero (1450 ps: −0.03 ps) | Final sign-off runs: add a small setup margin |
| Debug-port I/O budget (20%) is an assumption | Must hold once the PMU and wires are real | Check at the top level |
| `add_demo` fails on the cached E-core; 2 of 50 SoC mutations undetected (`hit_ignores_core_en`, `flush_wb_race_ignored`) | `make test` and `make soc-mutation` aren't green on this branch, since `b0033fe` (section 12) | Before the top level: adjust `add_demo`'s threshold for 2-cycle fetch; restore detection of the two mutations |
| P-tile detailed routing needs more than about 10 GB (run 1 stopped at 30%) | The machine has 15 GB, about 4 GB in use by everything else | Next P-tile run: fewer routing threads, and/or a smaller design |
| P-tile `retire_o` output path (−266 ps in run 4) | Now the P-tile's worst path: L1D → hit → retire → PMU pin, under the 40% output budget | Check the real budget at the top level |
| Only the fast (FF) corner checked (ORFS ASAP7 default) | Signoff needs the slow corner (setup) and fast corner (hold) | Before signing off the E-tile |
| L2 tags and sharer bits in flip-flops (about 57,000) | Same memory and size problem as the L1 tags, at the top level | Before the top-level layout |
| Cache hits take 2 cycles | About half the performance on cache-resident code | Possible later improvement (pipelined hits) |
| No reset synchroniser | Reset-release timing isn't checked; a production chip would add one | Documented limitation |
