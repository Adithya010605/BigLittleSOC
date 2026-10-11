# Task Migration and Power Management

The PMU (`rtl/power/pmu.sv`) does both jobs, because both act on the same
per-core state: which software context each core runs, and whether its clock
may run. This document covers the hardware it needs in the cores and the
caches, its register map, and how it is verified.

| | |
|---|---|
| Migration | software-requested or automatic (IPC monitor, power budget); 39 items of architectural state through the cores' debug ports; **84 cycles** from the request to the hart running on the other core (plan budget: 100) |
| Sleep | per hart; the core halts and its clock stops; any of the hart's interrupt lines, or a register write, wakes it |
| DVFS stub | per cluster, the cores' clock runs at 1/1, 1/2 or 1/4 of the system clock; caches and interconnect stay at full speed |
| Power domains | per cluster; the cluster's L1s are flushed (modified lines written back, everything invalidated), then their clocks stop; waking or migrating into the cluster switches it back on |
| Clock gating | one latch-based gate per core and one per core's pair of L1s (`rtl/power/clock_gate.sv`) |

## 1. Contexts and cores

Software sees **harts** (contexts) 0..N-1: the number `mhartid` reads, and the
interrupt controller's block of registers for that hart. Each **core** either
runs one hart (active), or none (parked: halted, clock stopped). At reset core
c runs hart c: harts 0–1 on the P-cores, 2–3 on the E-cores. A hart's partner
core is the other cluster's core with the same index (P0↔E0, i.e. core 0 ↔
core 2, and core 1 ↔ core 3).

The PMU drives each core's `hart_id_i` (so `mhartid` follows the hart), routes
each hart's interrupt lines to the core running it, and owns the cores' halt
and debug ports.

A hart can find out what kind of core it is on from `misa`, which differs in
the M bit. Nothing else is visible: one RV32I image runs everywhere.

## 2. What the cores and caches provide

### 2.1 The halt and debug port (both cores)

| Port | |
|---|---|
| `halt_req_i` | halt at the next instruction boundary the core could take an interrupt at; held high to stay halted, dropped to resume |
| `halted_o` | stopped: pipeline empty, no fetch in flight, nothing left to write back |
| `dbg_rf_addr_i`, `dbg_rf_we_i`, `dbg_rf_rdata_o` | register file access while halted |
| `dbg_csr_addr_i`, `dbg_csr_we_i`, `dbg_csr_rdata_o` | CSR access while halted |
| `dbg_pc_o`, `dbg_pc_we_i` | the resume PC |
| `dbg_wdata_i` | write data for all three |
| `hart_id_i` | what `mhartid` reads |
| `retire_o` | an instruction retired this cycle (the IPC monitor's input) |

The halt is taken by the trap unit, exactly like an interrupt and with
priority over one, but with no CSR side effects: the instruction at the
boundary is killed (it does not retire) and becomes the resume PC (`dpc_q`).
Fetch is held while the halt is pending or taken. While halted, the register
file's second read port and its write port, and the CSR port, are switched to
the debug port; the pipeline is empty, so nothing else uses them.
Deasserting `halt_req_i` redirects fetch to `dpc_q`.

### 2.2 The L1 caches (`rtl/cache/l1_dcache.sv`)

* **`core_en_i`**: the cache runs on the system clock, its core possibly
  slower (DVFS) or not at all. `core_en_i` is high in cycles that end with a
  core clock edge. The cache takes a new access only in such a cycle, and a
  bus transaction that completes in any other cycle has its response held
  (`C_HOLD`) for the core's next edge.
* **Performed-access monitor (`perf_*`)**: a held access has already taken
  effect, and a snoop may even have taken its line away since, so the cycle
  the core sees `gnt` is no longer always the cycle the access was performed.
  The monitor reports each access in the cycle it is performed, with the data
  it read; the coherence checkers in the testbenches follow it. At full speed
  the two coincide.
* **Flush (`flush_i` / `flush_done_o`)**: walks every line, writing back
  modified lines (`BUS_WB`) and invalidating everything. Snoops are answered
  during the walk; a modified line a snoop takes while its writeback waits for
  the bus is simply invalidated. `flush_done_o` stays high, and the cache
  idle, until `flush_i` drops. Both of a core's L1s flush together.

## 3. Migration

```
IDLE -> QUIESCE   halt the source core; wait for halted_o (and for the
                  destination cluster to be powered)
     -> SAVE      one item per cycle, source debug port -> buffer
     -> TRANSFER  the hart's number and interrupts move to the destination
     -> RESTORE   one item per cycle, buffer -> destination debug port
     -> DONE      release the destination; the source stays parked
```

The 39 items are x1..x31, the PC, `mstatus`, `mie`, `mtvec`, `mscratch`,
`mepc`, `mcause` and `mtval`. The performance counters (`mcycle`,
`minstret`, the event counters) belong to the core and stay behind.

Memory needs nothing: the caches are coherent, so a hart that moves finds
its data wherever it is, including in the source core's L1, which is
snooped like any other.

**Triggers.**

* **Software**: `MIG_CTRL` = go | destination core (or `0xF`: the partner) |
  hart. A hart may move itself; it is halted a few instructions after its
  store and carries on on the destination.
* **IPC monitor**: per window of `WINDOW` cycles the PMU counts each core's
  retired instructions. A P-core hart below `LOW` for `HYST` windows in a row
  moves to its E-core partner; an E-core hart above `HIGH` for `HYST` windows
  moves to its P-core partner. Enabled by `AUTO`.
* **Power budget**: with more than `BUDGET` P-cores running (and `AUTO` on),
  the lowest-numbered P-core hart whose partner is free moves to it.

A request is refused (STATUS bit 1, nothing changes) if the hart is not
running or asleep, the destination is not a parked core, the hart or core
number does not exist, or a cluster is being flushed. A request written while
another migration is in progress is ignored: software waits for `STATUS`
bit 0 to clear first (`pmu_migrate()` in `sw/common/pmu.h` does).

**Latency.** Measured: 84 cycles from the request to the release of the
destination (`MIG_LAST_LATENCY`), of which 2 × 39 are the copies.

## 4. Power

* **Clock gating.** `core_clk_en[c] = !off(cluster) && (migrating(c) ||
  (divider_pulse(cluster) && !(halted(c) && (asleep(c) || parked(c)))))`.
  A core's clock stops once it has halted for sleep or parking; a core taking
  part in a migration runs at full speed for its duration.
* **Sleep and wake.** `PWR_SLEEP` (a mask of harts) halts each hart's core at
  its next instruction boundary and stops its clock. Any of the hart's
  interrupt lines, whether enabled in `mie` or not, or a write to
  `PWR_WAKE`, clears the sleep; the core resumes where it stopped and takes
  the interrupt if `mstatus.MIE` and `mie` allow it.
* **Park.** `PWR_PARK` stops a hart for good (its core becomes free for
  migration).
* **DVFS stub.** `PWR_DVFS` sets each cluster's divider. Only the cores slow
  down; the L1s hold responses for them (§2.2).
* **Power domains.** Writing 1 to a cluster's bit of `PWR_PD_CTRL` asks for
  it to be switched off. If every core in the cluster is parked or asleep,
  and halted, and no migration is running, the cluster's L1s are flushed and
  then the cluster is off: L1 and core clocks stopped. Otherwise the request
  is refused (`PD_STATUS` bit 8). A wake for a sleeping hart in the cluster,
  a migration into it, or clearing the bit switches it back on. The model is
  state-retention power gating: the cores' registers keep their contents (so
  a sleeping hart survives), the L1s' contents are lost (hence the flush).

## 5. Register map

Power, at `0x4000_0000` (uncached):

| Offset | | |
|---|---|---|
| `0x00` | R | ID `0x504D5531` ("PMU1") |
| `0x04` | W | SLEEP: harts (bit mask) to put to sleep |
| `0x08` | W | WAKE: harts to wake |
| `0x0C` | W | PARK: harts to stop for good |
| `0x10` | RW | DVFS: [1:0] P cluster, [3:2] E cluster; 0 = 1/1, 1 = 1/2, 2/3 = 1/4 |
| `0x14` | RW | PD_CTRL: bit k = cluster k (0 P, 1 E) off |
| `0x18` | R | PD_STATUS: [1:0] off, [5:4] flushing, [8] last request refused |
| `0x20 + 4c` | R | CORE_STATE of core c: [0] active, [1] asleep, [2] halted, [3] core clock on, [4] L1 clock on, [11:8] hart |
| `0x80 + 8c` | R | cycles core c's clock ran |
| `0x84 + 8c` | R | cycles core c's clock was gated |

Migration, at `0x5000_0000` (uncached):

| Offset | | |
|---|---|---|
| `0x00` | R | ID `0x4D494731` ("MIG1") |
| `0x04` | W | CTRL: [3:0] hart, [7:4] destination core (`0xF` = partner), [31] go |
| `0x08` | R | STATUS: [0] busy, [1] last request refused, [10:8] FSM state |
| `0x0C` | R | COUNT: migrations completed |
| `0x10` | R | LAST_LATENCY: cycles, request to release |
| `0x14` | R | LAST_ROUTE: [3:0] source core, [7:4] destination core, [11:8] hart |
| `0x20` | RW | AUTO: bit 0 enables the monitors |
| `0x24` | RW | WINDOW: IPC window in cycles (default 1024) |
| `0x28` | RW | LOW: P-core threshold, instructions per window (default 0: never) |
| `0x2C` | RW | HIGH: E-core threshold (default `0xFFFFFFFF`: never) |
| `0x30` | RW | HYST: windows in a row (default 2) |
| `0x34` | RW | BUDGET: P-cores allowed to run (default NUM_P) |
| `0x40 + 4c` | R | CTX_OF_CORE: [31] active, [3:0] hart |
| `0x60 + 4h` | R | CORE_OF_CTX: [31] running, [3:0] core (shows the destination from TRANSFER on) |
| `0x80 + 4c` | R | LAST_IPC: core c's instructions in the last window |
| `0x100 + 4k` | R | the migration buffer, item k |

## 6. Verification

### 6.1 The halt and debug port, per core (`--halt-every`)

`tb_core.cpp` can play the PMU: at random intervals it requests a halt,
waits for `halted_o`, reads x1..x31, the PC and the seven travelling CSRs
through the debug port and, in lockstep runs, compares them with the golden
ISS's architectural state at that point. It then writes a random register,
the PC, `mscratch` and `mtval` with random values, reads each back, restores
the originals and reads those back, stays halted a few cycles and releases
the core. One request in eight is withdrawn before the core has halted.

Because every write is undone, the program must run exactly as it would
have without the halts: its own checks and the lockstep comparison are the
proof. This mode runs in:

* the directed suites, at random latency with a halt every ~60 cycles,
  except the two P-core tests that check exact event-counter and predictor
  values (`NO-HALT-MODE`): a halt re-executes the instruction it interrupts,
  and the core's own counters see that, as they should;
* half of the randomised lockstep programs (a halt every ~50 cycles);
* every fourth program of the coverage replay. Line coverage stays at 100%
  for both cores with the halt logic included.

### 6.2 The caches (`make unit`, `tb_coherent_mem*`)

The coherence harness checks values against the **performed-access
monitor** and then checks that each core-side response arrives in a cycle
the core's clock is enabled, after the monitor reported the access, with the
data it reported. Each core's enable can follow a 1/2 or 1/4 divider or a
random pattern. Randomised runs flush idle cores' caches in the middle of
the traffic and check that a completed flush leaves nothing behind. The
probe invariants (memory, L2 data, single writer) prove that no modified
line was lost on the way out. Directed tests cover the flush (exact
writebacks, a silent write-through flush) and a slow core.

### 6.3 Programs on the SoC (`make soc-tests`)

Every program runs at all six latency settings, with every load checked
against the coherent value:

| Program | What it shows |
|---|---|
| `mc_migrate` | P→E→P from inside the migrating hart: every register (but the one the wait loop uses) set before the request and checked after the move, and every travelling CSR (`mc_migrate.S`); `misa` changes, `mhartid` does not; PMU registers agree; latency ≤ 100 cycles; dirty data in the source L1 reads back from the destination; the hart's software interrupt follows it; a second hart moves while computing, its computation continuing across both moves; refused requests change nothing |
| `mc_sleep` | wake by an enabled interrupt (taken, on the woken core), by `PWR_WAKE`, and by a timer interrupt that is not enabled (no trap); `mcycle` barely moves while asleep; CORE_STATE and the RUN/GATED counters while asleep |
| `mc_dvfs` | four divider settings: every hart's `mcycle` / system-cycle ratio equals its cluster's divider; lock-protected shared work at each setting |
| `mc_power` | E cluster off (L1 clocks stopped, counters); migration into it switches it on; P cluster off with 128 modified lines in its L1s: the flush writes them back and the harts, now on the E-cores, read them; switching off the running cluster is refused; migration back switches P on |
| `mc_power_stress` | six rounds of: P-core harts dirty 32 lines and sleep; the P cluster is switched off while the E-core harts store into the same lines, sweeping against the flush's direction so that the two meet head-on: a line taken while its writeback waits for the bus must not be written back; woken again, everybody checks every word |
| `mc_auto` | IPC monitor: a low-IPC P-core hart moves to its E-core while a high-IPC one stays; on the E-core, a raised IPC brings it back; power budget moves exactly one P-core hart; the harts' checksums survive every move |
| `mc_stress_dvfs` | the racing-access stress with the P cluster at 1/2 and the E cluster at 1/4 speed |

The testbench samples each core's RVFI only in cycles its clock is enabled,
counts migrations and reports, per core, the cycles its clock ran (`--stats`).

### 6.4 Mutation testing

* `make soc-mutation` adds 18 mutations to the memory system's 32: six in the
  L1 (a paused core answered, a hit taken in a paused cycle -- performance
  only: the access is repeated, which only the LRU and the counters notice --
  held data lost, a flush that drops modified lines, finishes after one line,
  or ignores the writeback race) and twelve in the PMU (no wait for the halt, the last item
  or every register off by one, `mhartid` not moved, the source left
  running, interrupts routed by core, a parked core's clock left running,
  the divider ignored, interrupts that do not wake, power-off before the
  flush is done, no hysteresis, the budget ignored).
* `make mutation` (each core) adds the halt path: a resume PC past the halted
  instruction, a halted instruction that retires anyway, debug register and
  PC writes that are lost. All are killed by the halt-mode runs.

## 7. Limitations

* **One migration at a time.** A second request during a migration is
  ignored, not queued.
* **The source core's L1 is not flushed on migration.** It need not be: the
  caches are coherent. Its dirty lines move on demand. A cluster that is
  switched off is flushed then.
* **No real voltage scaling.** The DVFS stub divides the clock only; there is
  no voltage model and no PLL relock time.
* **Power domains retain core state.** A real implementation would need
  retention flops for a sleeping core, or would refuse to switch off a
  cluster with a sleeping hart.
