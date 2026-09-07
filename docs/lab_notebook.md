# E-Core Lab Notebook

Running log of design decisions, bugs, root causes and fixes. One entry per
working/debugging session, newest last.

---

## 2026-09-07 — M0: environment and repo skeleton

### Toolchain survey

Machine: Arch Linux, kernel 7.2.3.

| Tool | Found | Notes |
|---|---|---|
| Verilator | 5.050 (2026-07-01) | meets the v5.x hard requirement |
| g++ | 16.2.1 | C++17 fine |
| gtkwave | 3.3.128 | ok |
| make | GNU Make 4.4.1 | ok |
| python3 | 3.14.7 | ok |
| git | 2.55.0 | ok |
| RISC-V cross compiler | **absent** | none of `riscv{32,64}-{unknown-,}elf-gcc` or `riscv64-linux-gnu-gcc` present |
| yosys | **absent** | needed only by `make synth` |

Both missing packages need root, and this environment has no passwordless sudo,
so installation is handed to the user. Candidate Arch packages found in `extra`:
`riscv64-elf-gcc` + `riscv64-elf-newlib` + `riscv64-elf-binutils` (bare-metal),
`riscv64-linux-gnu-gcc` (multilib, works freestanding), and `yosys`.

### Decision: cross-compiler detection order

`riscv32-unknown-elf-` → `riscv64-unknown-elf-` → `riscv32-elf-` →
`riscv64-elf-` → `riscv64-linux-gnu-`, first match wins, overridable with
`make RISCV_PREFIX=...`.

Rationale: a native rv32 toolchain is preferred because it needs no multilib and
its default `-march`/`-mabi` already match. The rv64 bare-metal toolchains work
provided every compile carries `-march=rv32i_zicsr -mabi=ilp32`, which the
Makefile always supplies, so nothing depends on the compiler's defaults. The
`riscv64-linux-gnu-` variant is last because it targets Linux; it is only usable
here because every test program is built `-nostdlib -nostartfiles -ffreestanding`
and never touches libc or the dynamic loader. `scripts/check_tools.sh` does not
trust the name — it actually compiles a one-line file with the target flags and
fails if the object cannot be produced.

### Decision: one dispatch script per regression, not Makefile recipes

`make <target>` delegates to `scripts/run_tests.sh <mode>`, which execs a
per-mode script. The Makefile therefore has a stable surface from M0 onward
while the implementations fill in at M1–M8, and the same scripts can be run by
hand while debugging without re-deriving Verilator command lines. Each script
degrades gracefully when its inputs do not exist yet (prints "not present yet",
exits 0) so `make test` is meaningful at every milestone rather than only at the
end.

### Decision: `--x-assign unique --x-initial unique` on simulation builds

Randomising X-state instead of Verilator's default zero-fill means an
uninitialised pipeline register or a missing reset shows up as a lockstep
mismatch rather than silently behaving. This is cheap insurance against the
classic "works in simulation, breaks in synthesis" class of bug, and it costs
nothing since every architectural register in this core is explicitly reset.

### Decision: lint bar has no escape hatch

`VLINT_FLAGS` is `--lint-only -Wall --timing` with no `-Wno-fatal`. The spec
allows developing with `-Wno-fatal` and removing it afterwards; leaving it out
entirely from the start avoids accumulating warnings that then have to be paid
down in a batch at M8.

### Open at end of M0

- RISC-V cross compiler and yosys must be installed by the user before M2's
  program-driven tests and M8's area estimate can run. M1 (unit tests) is
  unblocked — it needs only Verilator and g++.
