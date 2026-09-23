# Demo and Explainer

**Who this is for:** anyone who has to *show* or *explain* this project without
having designed it. It assumes you know no computer architecture. Read section 2
once and you will understand the demo in section 4 well enough to present it.

---

## 1. The one-paragraph version

We built a **CPU** — a real processor — from scratch, in a hardware description
language, and then proved it works. Not simulated at a hand-wavy level: this is
the actual gate-level logic, the kind that gets manufactured onto silicon. It
runs real compiled C programs, it passes the official RISC-V compliance test
suite that the standards body publishes, and it fits in 2,273 logic blocks on an
FPGA. It's the small "efficiency" core of a bigger chip we're building, modelled
on how Apple's chips pair small and big cores together.

If someone asks "so what did you actually do" — you designed the circuit that
fetches instructions, figures out what they mean, and executes them, and you
built six independent layers of testing to prove it never gets an answer wrong.

---

## 2. What you need to understand: the pipeline

### 2.1 The laundry analogy

You have washing, drying, and folding to do, for three loads of laundry.

The dumb way: wash load 1, dry load 1, fold load 1, *then* start load 2. The
dryer sits idle the whole time you're washing.

The smart way: as soon as load 1 moves to the dryer, start washing load 2. Now
all three machines run at once. Same work, finishes far sooner.

That's a **pipeline**. A CPU does the same thing with instructions. Ours has
three stages:

| Stage | Name | What happens |
|---|---|---|
| 1 | **IF** — Instruction Fetch | Go get the next instruction from memory |
| 2 | **ID** — Instruction Decode | Work out what it means, read the input values |
| 3 | **EX** — Execute | Actually do it (add, load from memory, jump...) |

At full speed, three instructions are in flight at once — one in each stage — and
one instruction finishes every clock cycle. The clock is the heartbeat; ours ticks
and every tick, everything shuffles forward one stage.

### 2.2 The problem: instructions that depend on each other

Here's where it gets interesting, and this is the thing worth demoing.

Consider these two instructions back to back:

```asm
lw   x5, 0(x1)       # LOAD: go fetch a value from memory, put it in register x5
add  x6, x5, x0      # ADD:  use x5
```

The second instruction needs the answer from the first. But look at the timing —
the load doesn't *have* its value until it finishes stage 3, and by then the add
is already in stage 2 needing that value. **The answer isn't ready yet.**

This is called a **load-use hazard**. If the CPU ignores it, the add reads a
stale, garbage value from `x5` and the program silently computes the wrong
answer. This is exactly the class of bug that makes a processor useless.

### 2.3 The two fixes, and this is the whole design

**Fix 1 — forwarding.** For most instructions the answer *is* ready, just sitting
in the wrong place — it's been computed in stage 3 but not yet written back to the
register file. So we run a wire directly from stage 3 back to stage 2, handing the
value over early. This costs nothing in time. Our hazard unit does this **19
times** in the test below.

**Fix 2 — stalling.** For a *load*, forwarding can't save you: the value is
coming from memory and genuinely does not exist yet. There's nothing to forward.
So the CPU **freezes the pipeline for exactly one cycle**, waits for the data to
arrive, and then proceeds. It loses a cycle, but it gets the right answer.

> **This is the single most important sentence in the demo:** the processor
> detects that an instruction needs a value that isn't ready, stops itself for
> exactly one cycle, and continues — automatically, in hardware, with no help
> from the program.

That's what you're going to show.

---

## 3. Generating the waveform

```sh
make wave TEST=hazard_load_use
```

That runs the load-use test with tracing switched on and writes two files:

| File | What it is |
|---|---|
| `build/hazard_load_use.vcd` | the waveform — every signal, every cycle |
| `build/hazard_load_use.trace.log` | a human-readable list of what executed |

Open the waveform with:

```sh
gtkwave build/hazard_load_use.vcd
```

`TEST=` accepts the basename of anything in `tb/asm/` or `sw/tests/` — e.g.
`make wave TEST=branch_hazard`, `make wave TEST=fib`.

---

## 4. The demo

### 4.1 Lead with the trace log — it is far more convincing

Honestly: a waveform is a wall of squiggles that means nothing to a general
audience, and if you're not fluent in it you will get lost live. The trace log
makes the *same* point in a way anyone can see in five seconds. Lead with this,
and keep the waveform as the follow-up for whoever asks "prove it's really in the
hardware."

```sh
sed -n '1p;15,18p' build/hazard_load_use.trace.log
```

You get this — and look at the **cycle** column on the left:

```
 cycle  order  pc          insn      disassembly            effects
    16     13  0x00000034  0000a283  lw   t0, 0(ra)         x5<-0x11112222 [0x00010010]->0x11112222
    18     14  0x00000038  00028333  add  t1, t0, zero      x6<-0x11112222
    19     15  0x0000003c  11112fb7  lui  t6, 0x11112       x31<-0x11112000
    20     16  0x00000040  222f8f93  addi t6, t6, 546       x31<-0x11112222
```

**Cycle 17 is missing.** The load finishes at 16, the add lands at 18. That gap
is the stall — one cycle, exactly as designed. And then look: 18, 19, 20 —
consecutive again, back to one instruction per cycle. The CPU paused precisely as
long as it needed to and not a tick longer.

**Now the control experiment**, which is what makes it science rather than an
anecdote. The test deliberately runs the same computation again with one harmless
`nop` (do-nothing instruction) inserted between the load and the add:

```sh
sed -n '20,22p' build/hazard_load_use.trace.log
```

```
    23     18  0x0000005c  0000a383  lw   t2, 0(ra)         x7<-0x11112222
    24     19  0x00000060  00000013  addi zero, zero, 0     (nop)
    25     20  0x00000064  00038433  add  s0, t2, zero      x8<-0x11112222
```

**23, 24, 25 — no gap.** The nop gave the load the cycle it needed, so the
hardware saw no hazard and didn't stall. Same computation, same result, but the
stall appears only when it's actually required.

That's your demo. Two snippets, side by side:

> "Here the processor detects a problem and pauses for one cycle. Here, where I've
> given it a spare cycle, it detects nothing and doesn't pause. It's making that
> decision itself, in hardware, every single cycle."

### 4.2 Then the waveform, for the sceptic

Open GTKWave. On the left is a tree of every signal in the design. It is
overwhelming — **do not scroll it live in front of an audience.** Add exactly
these five, in this order, and nothing else:

| Signal (paste into GTKWave's filter box) | What it shows |
|---|---|
| `TOP.clk_i` | the clock — the heartbeat |
| `TOP.rvfi_insn_o` | the instruction currently completing |
| `TOP.e_core_top.u_hazard.dependency` | "this instruction needs an earlier one's result" |
| `TOP.e_core_top.u_hazard.data_hazard_stall` | **the money signal — "I must freeze"** |
| `TOP.e_core_top.u_id_stage.fwd_rs1_i` | "I solved it by forwarding instead" |

To find one: type its name in the **Filter** box at the bottom left, select it,
click **Append**. Then **View → Zoom → Zoom Full** to see the whole run, and zoom
into the first third where the action is.

What you'll point at: `data_hazard_stall` sits flat at 0, then pops up to 1 for a
single clock cycle, then drops. **It does that 7 times across this test** — once
per load-use pair in the program. Meanwhile `fwd_rs1_i` pulses **19 times**: those
are the cases forwarding handled for free, without ever stalling.

The line to say:

> "Flat means the pipeline is running full speed. Every one of those 7 spikes is
> the processor catching a hazard and freezing itself for exactly one cycle. The
> other 19 pulses on the bottom signal are hazards it fixed instantly by
> forwarding, at no cost. It's choosing between those two strategies, in
> hardware, every cycle."

If a hardware person is in the room, `TOP.e_core_top.u_hazard.ex_result_late` is
the signal that distinguishes the two — it's the hazard unit deciding "this
result won't be ready in time, forwarding won't save us, stall."

### 4.3 Also worth showing: it runs real software

```sh
make sw-tests
```

Compiles actual C programs with a real RISC-V compiler and runs them on the
processor. `hello` prints text through a simulated serial port. `fib` computes
Fibonacci recursively — function calls, a stack, the works. This lands well with
people who find waveforms abstract: it's a *computer*, and it runs *programs*.

---

## 5. Questions you'll get, and honest answers

**"Did you design the instruction set too?"**
No, and we shouldn't have — RISC-V is an open standard. We implemented it. That's
the point: because it's a published standard, there's an official test suite, and
we pass it. 40 tests, 0 failures.

**"Is this actually on a chip?"**
Not fabricated. It's verified in simulation and run through synthesis, which
translates the design into real logic gates and reports 2,273 LUTs on a Xilinx
FPGA. The next step would be loading it onto an FPGA board, which is Phase 7.
Fabricating silicon costs millions; nobody expects that here.

**"How do you know it's correct?"**
Six independent layers, and this is the strongest part of the project:
lint, 45.7 million unit checks, 13 hand-written pipeline tests each run at four
different memory speeds, the official compliance suite, 1,200 randomly generated
programs checked instruction-by-instruction against a separately written
reference simulator, and mutation testing. See below.

**"What's mutation testing?"** *(the best answer in the project — use it)*
We deliberately broke our own processor 23 different ways and checked the test
suite noticed. It caught 16. The other 7 turned out to be changes that provably
can't affect behaviour. **It's how we test the tests** — because a test suite
that passes on broken hardware is worse than no test suite at all.

**"What's the hardest bug you hit?"**
Open `docs/lab_notebook.md` — every bug is logged with its root cause. Pick one
and read it beforehand; this question comes up a lot and a specific war story
lands much better than a generic answer.

**"Why is it slower than one instruction per cycle?"**
It runs at CPI 1.24 on a sorting benchmark — 1.0 is the theoretical best. The 0.24
gap is measured and fully accounted for: 0.22 from branches, 0.15 from stalls like
the one demoed above. That's expected for a deliberately simple core, and closing
that gap is exactly what the bigger Phase 2 core is for.

**"What's next?"**
The P-core — a bigger, faster processor with branch prediction. Then the two get
connected to shared memory, which is where it becomes a big.LITTLE SoC rather than
a single CPU. Roadmap is in `RISC-V_SoC_Project_Plan.md`.

---

## 6. Numbers cheat sheet

Memorise the bold ones; the rest you can look up.

| | |
|---|---|
| What it is | RV32I + Zicsr, machine mode, **3-stage pipeline** |
| Compliance | **40 passed, 0 failed**, 2 skips (both documented, both by design) |
| Unit checks | 45.7 million |
| Random testing | 1,200 runs vs an independent reference simulator |
| Mutation testing | 23 injected faults, 16 killed, 7 provably equivalent |
| Line coverage | **100%** |
| Lint | 0 warnings, no waivers |
| Size | **2,273 LUTs** (target was under 5,000) |
| Speed | **CPI 1.24** on bubble sort |
| Language | SystemVerilog-2012, simulated with Verilator |

**If you remember three things:** it passes the official RISC-V compliance suite;
it has 100% line coverage; and we mutation-tested our own test suite to prove the
tests actually work.

---

## 7. Five-minute run sheet

```sh
make tools                      # 1. "here's the toolchain"      (5 s)
make lint                       # 2. "zero warnings, no waivers" (10 s)
make unit                       # 3. "45.7M checks pass"         (~1 min)
make asm-tests                  # 4. "13 pipeline tests, 4 memory speeds each"
make wave TEST=hazard_load_use  # 5. the demo in section 4
gtkwave build/hazard_load_use.vcd
```

Run these **before** you present, not live — `make unit` takes a minute and dead
air kills a demo. Have the terminal scrolled back to the green output and the
waveform already open in another window.

Skip `make test` in a live demo. It's the full gate and takes tens of minutes.
