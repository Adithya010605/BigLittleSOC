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
| E-tile | ✓ done (GDS, timing not met at 1000 ps) | ✓ done: run 2 (1450 ps), run 3 (1000 ps, fair comparison) | next | — |
| P-tile | — | — | — | — |
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
| Hold | **0 violations**; worst hold slack **+172 ps** (reset input → an L1 state flip-flop) |
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
- **Hold is clean,** with +172 ps of margin. Hold doesn't depend on the clock
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
| Hold | 0 violations, +172 ps | 0 violations, +384 ps | |
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
| Hold | +172 ps, clean | +196 ps, clean | |
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

---

## Open items

| Item | Why it matters | When |
|---|---|---|
| E-core branch/next-PC path (~1.36 ns after run 3) | Sets the E-tile's fmax; layout alone gained only 2% | Synthesis options, then the branch-after-ALU stall (RTL), before the sweep |
| L2 tags and sharer bits in flip-flops (about 57,000) | Same memory and size problem as the L1 tags, at the top level | Before the top-level layout |
| Cache hits take 2 cycles | About half the performance on cache-resident code | Possible later improvement (pipelined hits) |
| No reset synchroniser | Reset-release timing isn't checked; a production chip would add one | Documented limitation |
