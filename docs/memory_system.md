# The Memory System: Caches, MSI Coherence, L2 and the QoS Interconnect

Everything in the SoC outside the cores: each core's private L1 instruction
and data caches, MSI snooping coherence, the shared inclusive L2 with its
snoop filter, the QoS-arbitrated system interconnect, and the RTL SRAM, UART,
interrupt controller and system-control block behind it. It covers the
plan's cache subsystem (`RISC-V_SoC_Project_Plan.md` Phase 3, weeks 8–9),
cache coherence (Phase 4, week 11) and the interconnect fabric (§3.1, Phase 4
week 10; README Phase 3).

| Item | Where |
|---|---|
| L1 cache (data: write-back MSI or write-through; instruction: read-only) | `rtl/cache/l1_dcache.sv` |
| Shared L2 arrays + snoop filter | `rtl/cache/l2_cache.sv` |
| Shared types, bus commands, line helpers, pseudo-LRU | `rtl/cache/cache_pkg.sv` |
| Snooping bus + L2 controller | `rtl/coherence/snoop_bus.sv` |
| L1s + bus + L2 (the coherent memory system) | `rtl/coherence/coherent_mem.sv` |
| QoS crossbar | `rtl/interconnect/qos_xbar.sv` |
| SRAM, UART, interrupt controller, system control | `rtl/periph/` |
| SoC top level (2 P-cores + 2 E-cores) | `rtl/soc/soc_top.sv` |
| Unit testbenches | `tb/unit/coherence/`, `tb/unit/interconnect/` |
| SoC harness (loader, coherence checker, traffic) | `tb/soc/tb_soc.cpp` |
| Multi-core programs | `sw/soc_tests/`, `sw/common/start_mc.S`, `sw/common/soc.h` |
| Mutation testing | `scripts/mutation_soc.py` |

```
  hart 0         hart 1         hart 2         hart 3
  P-core         P-core         E-core         E-core
 L1I   L1D      L1I   L1D      L1I   L1D      L1I   L1D
 16K   16K WB   16K   16K WB   8K    8K WT    8K    8K WT
  |     |        |     |        |     |        |     |
 +-------------------------------------------------------+
 |  snooping bus: one transaction at a time, round-robin |
 |  + L2 controller: 64 KB, 4-way, inclusive, write-back |
 |    sharer bit per L1 per line = snoop filter          |
 +-------------------------------------------------------+
                            | master 0
 +-------------------------------------------------------+   masters 1-3:
 |  QoS crossbar: priority + round-robin + anti-starve   |<- debug/loader,
 +-------------------------------------------------------+   traffic A, B
      |            |              |              |           (testbench)
   SRAM 192K     UART      interrupt ctrl    system ctrl
  0x0000_0000  0x1000_0000  0x1100_0000      0x1200_0000
```

## 1. The L1 caches (`l1_dcache.sv`)

Each core has an L1 instruction cache and an L1 data cache, all built from
one module:

| | P-core L1D | E-core L1D | L1I (both) |
|---|---|---|---|
| Size / ways | 16 KB, 2-way | 8 KB, direct-mapped | as the core's L1D |
| Write policy | write-back, write-allocate | write-through, no-write-allocate | read-only |
| Line states | I, S, M | I, S | I, S |
| Store hit on M | done in the cache | — | — |
| Store on S | `BusUpgr` | `BusWr` (own copy updated, stays S) | — |
| Store miss | `BusRdX` (after writing back an M victim) | `BusWr`, no allocation | — |
| Load / fetch miss | `BusRd` → S | `BusRd` → S | `BusRd` → S |
| Eviction | `BusWB` if M, silent if S | silent | silent |

Lines are 32 bytes. Index and tag come from the parameters: offset `[4:0]`,
index `[12:5]`, tag `[31:13]` at full size. (The plan's table gives the
P-cache tag as `[31:14]`, which would be right for 512 sets; 16 KB at 2 ways
with 32-byte lines is 256 sets.)

**The core side.** The cores' memory ports are unchanged. A cache grants
**only in the cycle it responds**, so every access takes effect in exactly the
cycle the core sees it complete. Hits are answered combinationally, in the
request cycle. A miss holds `gnt` low until its bus transaction completes.
That one property is what makes the system sequentially consistent (each core
has one access outstanding, in program order, performed at acknowledgement),
and it is what makes it checkable (§5).

**Instruction caches are coherent.** An instruction cache is the
write-through cache with its store path unused. It fills with `BusRd`, and
any write to the line, by any core, invalidates it. So a store to code by any
core invalidates every stale copy, the storing core's own included. The next
fetch misses and takes the new code, from the writer's data cache by a flush
if necessary. `FENCE.I` has nothing left to do but refetch, and the P-core's
`fence_i` tests (directed and compliance) pass behind the caches.

Addresses at or above 0x0003_0000 bypass the caches as uncached word
accesses, so peripherals see every access and access faults still reach the
core.

**The snoop side.** A second read port answers snoops combinationally (hit,
dirty, line); the state change happens at the end of the snoop cycle. The
cache accepts no core access in a snoop cycle, so the core and the snoop never
write the arrays in the same cycle (asserted).

## 2. The snooping bus and the L2 (`snoop_bus.sv`, `l2_cache.sv`)

**One transaction at a time, start to finish.** This removes every transient
coherence state. An L1 is never snooped for a line it is in the middle of
filling, and the L2 never changes underneath a transaction.

**The L2** is 64 KB, 4-way, 512 sets, write-back and write-allocate, with
tree pseudo-LRU replacement. It is **inclusive**: every line held by any L1 is
also in the L2. Each L2 line carries **a sharer bit per L1**, which is the
snoop filter. A coherent request snoops only the L1s whose bit is set, never
the whole cluster, and inclusion makes that sound: a line missing from the L2
is held by no L1, so an L2 miss needs no snoop at all.

| State | Does |
|---|---|
| `B_IDLE` | round-robin grant among the L1s; latch the request |
| `B_LOOKUP` | look the line up in the L2 |
| `B_SNOOP` | (hit, with other sharers) snoop them for one cycle; capture an M owner's line |
| `B_ACT` | (hit) update the L2 line — data, dirty, sharers — and respond |
| `B_BINV` | (miss, victim has sharers) **back-invalidate** the victim's L1 copies, taking an M copy's data |
| `B_VWB` | (miss, victim dirty) write the victim to memory |
| `B_FILL` | (miss) fetch the line, install it, respond in the same cycle |
| `B_MEM` | uncached word access to memory/peripherals |

| Command | Snoop | On an L2 hit | Sharers after |
|---|---|---|---|
| `BusRd` | `SNP_RD` | data = M owner's line (also written into the L2; owner → S) or the L2's | + requester |
| `BusRdX` | `SNP_INV` | data as `BusRd`; every other copy invalidated | requester only |
| `BusUpgr` | `SNP_INV` | no data | requester only |
| `BusWr` (write-through) | `SNP_INV` | word merged into the line, L2 copy dirty | requester only, if it had a copy |
| `BusWB` (L1 victim) | none | line written into the L2, dirty | writer's bit cleared |

Latency at zero memory wait states: an L1 miss that hits in the L2 takes 3
cycles (4 with a snoop); an L2 miss adds the memory access, plus the victim's
back-invalidation and writeback if needed.

**Sharer bits are conservative.** An L1 that drops a clean line silently keeps
its bit until the next invalidation clears it. A stale bit costs a snoop that
finds nothing; a missing bit would be a coherence bug, and the testbenches
check every cycle that there is none.

### Races a waiting request can lose

A request waiting for the bus can be overtaken by another L1's transaction.
The cache re-decides its command every cycle from its current state, and the
bus grants only while no snoop is in progress:

* **Lost upgrade.** Another write invalidated the S copy, so the `BusUpgr`
  becomes a `BusRdX`.
* **Flushed victim.** A snoop took the modified victim first, so the
  writeback is skipped (it would write stale data).

## 3. The interconnect (`qos_xbar.sv`)

An N-master × M-slave crossbar (4 × 4 in the SoC) with a decode-error
responder for unmapped addresses.

**Protocol: simplified AXI4-Lite.** Two channels per port with valid/ready
handshakes: a request channel (AXI's AW, W and AR merged: address, write,
data, byte strobes) and a response channel (R and B merged: data, error). The
data path is a cache line wide, so an L2 fill or writeback is one beat; a word
access puts its word in its lane with four strobes. Each master has one
transaction outstanding, so there are no IDs or bursts.

**Arbitration (plan §3.1), per slave.** Masters going to different slaves are
granted in the same cycle. Among masters requesting one slave:

1. **Anti-starvation.** A master that has waited `STARVE_LIMIT` cycles (16 by
   default) is granted first.
2. Otherwise **strict priority**: the highest QoS level wins (2 bits per
   master, programmable in the system-control block).
3. **Round-robin** among the masters at that level.

A slave is granted again in the cycle its previous response arrives, so
back-to-back transactions lose no arbitration cycle.

| Master | QoS at reset | Slave | Address |
|---|---|---|---|
| 0 CPU cluster (the L2) | 2 | SRAM, 192 KB, 1-cycle | 0x0000_0000–0x0002_FFFF |
| 1 debug / loader (testbench) | 0 | UART | 0x1000_0000–0x1000_00FF |
| 2 traffic A (testbench; the plan's DMA slot) | 1 | interrupt controller | 0x1100_0000–0x1100_FFFF |
| 3 traffic B (testbench; the plan's accelerator slot) | 3 | system control | 0x1200_0000–0x1200_0FFF |

## 4. The peripherals (`rtl/periph/`)

* **SRAM controller.** 192 KB, line-wide, byte strobes. It accepts when
  idle, writes at the end of the accept cycle, and responds one cycle later
  (the plan's "simple SRAM controller, 1-cycle access"). A `stall` input is
  the testbench's latency knob. The whole RAM is cacheable. The plan's
  read-only boot ROM region is RAM here, because the loader writes the program
  there and the self-modifying-code tests write code.
* **UART.** Transmit data at +0 and status at +4, at the addresses the
  programs always used; each byte appears on `uart_tx_valid/byte`.
* **Interrupt controller.** Per hart at +0x100·h, with exactly the old
  testbench model's semantics (+0 arm timer / pending, +4 clear, +8 software,
  +C external), so the interrupt tests run unchanged.
* **System control.** ID and configuration, the QoS registers, and
  performance counters: hits and misses for every L1, L2 hits, misses,
  writebacks and back-invalidations, and grants and wait cycles per
  interconnect master. Miss rates are measurable from software: `mc_sysctl`
  measures them.

Any other offset in a peripheral's window answers with an error, and any
address outside every window gets a decode error from the crossbar, so access
faults reach the cores as before.

**Boot.** The testbench holds the cores and caches in reset (`cpu_rst_ni`),
writes the program into the SRAM through the debug master, and then releases
them. Reported cycle counts start at that release.

## 5. Verification

### 5.1 Unit level (`make unit`)

**Coherent memory system** (`tb/unit/coherence/coh_harness.h`). It drives all
four data ports and all four instruction ports with protocol-correct traffic,
backs the L2 with a memory of configurable latency, and checks **every
cycle**:

1. **Atomicity.** `gnt` and `rvalid` rise together.
2. **Values.** Every load and fetch returns the reference memory's word.
3. **SWMR.** At most one M copy, and then no other copy. Only P-core data
   caches may own a line.
4. **Copies.** Every valid L1 copy equals the reference.
5. **Inclusion and filter.** Every L1 copy is in the L2, with its sharer bit
   set.
6. **L2 data.** The L2 copy is current whenever no L1 owns the line.
7. **Memory.** Memory is current whenever the L2 copy is not dirty and no L1
   owns the line.
8. **Liveness.** No request waits more than 5,000 cycles.

| Harness | Configuration | Checks |
|---|---|---:|
| `tb_coherent_mem` | full size; 13 directed scenarios + 4 random runs | 33.4M |
| `tb_coherent_mem_small` | every L1 and the L2 at 4 sets: L1s hold 3× more than the L2, so back-invalidation is constant | 52.6M |
| `tb_coherent_mem_wb4` | 4 write-back L1s, 16-line L2: ownership moving cache to cache | 21.9M |

The directed scenarios check the exact bus transaction (requester, command,
line, sharers/owner found) and every cache's state after each access. They
cover:

* the plan's MSI table: I→S, I→M, S→M, S→I on `BusRdX`, `BusUpgr` and
  write-through, M→S, M→I by forwarding, M→I by write-through flush, and
  writeback;
* LRU choice, and an invalid way chosen before the LRU way;
* both waiting-request races;
* uncached accesses and access errors;
* L2 miss then hit, with exact sharer bits;
* stale sharer bits after silent evictions;
* L2 eviction back-invalidating a modified L1 copy;
* a dirty L2 victim with no L1 copies;
* instruction-cache invalidation by a store from the same core and from
  another core.

**Crossbar** (`tb/unit/interconnect/tb_qos_xbar.cpp`, 4 masters × 3 slaves +
decode error). The C++ slaves apply random back-pressure and latency. A
reference arbiter predicts every grant, every cycle:

* a grant goes only to a waiting master;
* a free slave with a waiting master always grants (no dead cycles);
* starving masters first, then the highest priority, then round-robin;
* every request reaches its slave unchanged, exactly once;
* every response carries its slave's data;
* unmapped addresses get a decode error and reach no slave.

Directed scenarios then measure the outcome:

* strict priority starves the lower levels;
* with the plan's limit of 16, every master is served within the bound;
* equal priorities rotate exactly.

3.5M checks.

### 5.2 Each core behind the whole system (`make cached-tests`)

`CACHED=1` runs every per-core suite on a one-core SoC build: the core with
its L1s, the L2, the crossbar, the RTL SRAM and the peripherals.

| Suite | E-core | P-core |
|---|---|---|
| directed assembly × 5 latencies | 13 / 13 | **20 / 20** (incl. `fence_i`) |
| `riscv-tests` | 40 pass, 2 skip (as the bare E-core) | **49 pass**, 1 skip (as the bare P-core) |
| C programs | 6 / 6 | 6 / 6 |
| random lockstep vs golden ISS | 600 × 2 | 600 × 2 |

### 5.3 Multi-core programs (`make soc-tests`)

The SoC harness checks coherence on every run. It watches every core's data
port and checks every load against the coherent value, with the cycle, hart
and address on a mismatch. It probes the lines touched each cycle (plus one in
rotation) in all eight L1s, the L2 and the SRAM for invariants 3–7 above.
Every program runs at five SRAM latencies and once more under checked
background traffic from the two traffic masters.

| Program | Exercises |
|---|---|
| `mc_hello` | a turn passed hart to hart; ordered UART output (`.expected`) |
| `mc_pingpong` | a token and a counter migrating round all four caches |
| `mc_producer_consumer` | lock-free queues P→E and E→P; 2 KB bulk hand-offs |
| `mc_false_sharing` | every hart writing its own word / byte / halfword of shared lines |
| `mc_lock` | Lamport's bakery lock; a record that must never tear |
| `mc_dirty_sharing` | 24 KB written by one hart, read by all, rewritten by quarters |
| `mc_l2_thrash` | an 80 KB working set: constant L2 evictions, back-invalidations, writebacks |
| `mc_sysctl` | ID/config, QoS registers, performance counters from software |
| `mc_stress_s1..s4` | racing random accesses over lines colliding in every cache |

### 5.4 Mutation testing (`make soc-mutation`)

32 realistic defects, each rebuilt and run against the block's unit testbench
and the system: the 2P+2E SoC on the multi-core programs (one under traffic,
one with its UART output compared), and a cached one-core P-core on the
access-fault, self-modifying-code and timer-interrupt tests.

| Block | Mutation | Unit | System |
|---|---|---|---|
| L1 | snooped invalidate leaves S copies valid | killed (stale copy) | killed |
| L1 | snooped read leaves the owner in M | killed (SWMR) | killed |
| L1 | snooped invalidate downgrades to S instead of I | killed | killed |
| L1 | core access accepted during a snoop cycle | killed (assertion) | killed (assertion) |
| L1 | store hit on S done without an upgrade | killed | killed |
| L1 | upgrade issued after the S copy was lost | killed | killed (assertion) |
| L1 | victim written back without re-checking its state | killed (inclusion assertion) | killed (`mc_stress`) |
| L1 | write-through store skips the cache's own copy | killed | killed |
| L1 | uncached access error dropped | killed | killed (`trap_exceptions`) |
| L2 / filter | the filter never snoops on an L2 hit | killed (stale fetch) | killed |
| L2 / filter | a reader's sharer bit not recorded | killed (filter check) | killed |
| L2 / filter | a fill records no sharer | killed (filter check) | killed |
| L2 | the M owner's data ignored on a hit | killed (value) | killed |
| L2 | a flush not written into the L2 | killed (L2 data) | killed |
| L2 | write-through word not merged | killed (L2 data) | killed |
| L2 | no back-invalidation on eviction (inclusion broken) | killed (inclusion) | killed (`mc_l2_thrash`) |
| L2 | back-invalidation drops the modified L1 data | killed (memory) | killed (`mc_l2_thrash`) |
| L2 | dirty victim not written back | killed (memory) | killed (`mc_l2_thrash`) |
| interconnect | response routed from the wrong slave | killed (data) | killed (`mc_hello`) |
| interconnect | decoder window one byte too large | killed (routing) | killed (`mc_bus_errors`) |
| interconnect | byte strobes dropped | killed (routing) | killed (traffic) |
| interconnect | decode error answered as success | killed (data) | killed (`trap_exceptions`) |
| peripheral | SRAM ignores byte strobes | — | killed (traffic) |
| peripheral | timer interrupt cannot be cleared | — | killed (`irq_timer`) |
| peripheral | L1 miss counter dead | — | killed (`mc_sysctl`) |
| peripheral | UART transmits the wrong byte lane | — | killed (`mc_hello` output) |
| L1 (*perf*) | victim choice ignores an invalid way | killed (directed) | — |
| L1 (*perf*) | LRU bit never updated | killed (directed) | — |
| interconnect (*perf*) | QoS priority ignored | killed (grant rules) | — |
| interconnect (*perf*) | no anti-starvation | killed (grant rules) | — |
| interconnect (*perf*) | round-robin pointer frozen | killed (grant rules) | — |
| interconnect (*perf*) | an idle cycle between grants | killed (no-dead-cycle rule) | — |

**32 / 32 killed, 0 survivors.** The six performance and fairness defects
leave every value correct. The unit testbenches catch them because they check
every replacement choice and every arbitration decision exactly. Three of
them were found by this table:

* The L2-eviction defects first survived at system level, because no
  program overflowed the L2; `mc_l2_thrash` was written for them.
* The decoder off-by-one survived because no program touched a window's
  edge; `mc_bus_errors` was written for it.
* The SRAM-strobe and interconnect-strobe defects are visible only under
  partial-line writes; the checked traffic run supplies them.

## 6. Performance

Whole-program cycles. "Bare" is the core alone on the ideal zero-wait memory
model; "system" is the core behind its L1s, the L2, the crossbar and the RTL
SRAM.

| Program | E bare | E system | P bare | P system |
|---|---:|---:|---:|---:|
| bubble_sort | 12,523 | 17,193 | 7,113 | 9,578 |
| fib | 511,036 | 721,365 | 500,623 | 503,082 |
| memcpy_test | 298,242 | 443,864 | 240,549 | 241,385 |
| perf_counters | 14,999 | 20,898 | 7,767 | 11,804 |

Ideal memory is a bound no hierarchy beats. The P-core's write-back L1 costs
0.3–0.5% on fib and memcpy. The E-core pays a bus transaction for every store
(write-through, no write buffer): 1.4–1.5× slower. Programs dominated by UART
output (`perf_counters`) pay the extra latency of uncached accesses through
the interconnect.

**With slow memory** (8-cycle data memory for the bare core, SRAM stalled 4
cycles per access for the system), which is what a hierarchy is for:

| Program | E bare | E system | speed-up | P bare | P system | speed-up |
|---|---:|---:|---:|---:|---:|---:|
| bubble_sort | 30,423 | 17,541 | 1.73× | 20,085 | 9,881 | 2.03× |
| fib | 1,633,280 | 721,876 | 2.26× | 1,619,507 | 503,561 | 3.22× |
| memcpy_test | 908,726 | 444,086 | 2.05× | 851,033 | 241,612 | 3.52× |
| perf_counters | 32,849 | 21,316 | 1.54× | 23,181 | 12,187 | 1.90× |

The L2 absorbs almost everything: the system's cycle counts barely move with
SRAM latency. Every L2 miss in these programs is a first touch. Instruction
caches hit 99.4–99.99%. The E-core's write-through stores now hit in the L2
(3–4 cycles) instead of waiting for memory.

## 7. Known limitations and next steps

* **E-core write-through without a write buffer.** Every store stalls the
  E-core for an L2 transaction. A small write buffer would hide it, and the
  checker in §5 would then have to model stores as performed later than they
  complete.
* **Broadcast-free but serial.** The snoop filter limits snoops to actual
  sharers, but the bus still runs one transaction at a time. That is simple
  and correct for four cores; it is the bottleneck beyond that.
* **MSI, not MESI.** A line read and then written by one core costs a
  `BusRd` and then a `BusUpgr`. An E state would save the upgrade; the plan
  specifies MSI.
* **The crossbar's masters 2–3 are testbench ports today.** They are where
  the plan's DMA engine and accelerator would connect (both are Project A2,
  outside A1's scope), and where the task-migration controller can get memory
  access.
* **No synthesis figure for the memory system yet.** The cache and SRAM
  arrays are asynchronous-read register arrays with extra read ports for
  snoops and the debug probe. That is right for simulation, but for an FPGA or
  ASIC flow they should become synchronous SRAMs/BRAMs (one more cycle of hit
  latency, or duplicated tags for the snoop port). The debug probes are for
  simulation only.
