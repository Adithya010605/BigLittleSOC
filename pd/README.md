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
| E-tile | in progress (attempt 3) | — | — | — |
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

### 6. E-tile run 1, attempt 3 (2026-10-23): in progress

---

## Open items

| Item | Why it matters | When |
|---|---|---|
| E-core branch/next-PC path (~1.6 ns) | Sets the E-tile's fmax | During the clock sweep |
| L2 tags and sharer bits in flip-flops (about 57,000) | Same memory and size problem as the L1 tags, at the top level | Before the top-level layout |
| Cache hits take 2 cycles | About half the performance on cache-resident code | Possible later improvement (pipelined hits) |
| No reset synchroniser | Reset-release timing isn't checked; a production chip would add one | Documented limitation |
