# E-Core Verification Plan

**Status:** skeleton written at M0. The test matrix is populated as tests are
written (M1–M7); coverage numbers and uncovered-line justifications are final at
M8.

## 1. Verification strategy

Four levels, mirroring section 9.1 of the project plan:

1. **Unit** — one C++ Verilator harness per module in `rtl/common/`, each
   combining directed corner cases with randomised vectors checked against a
   C++ reference model.
2. **Directed integration** — hand-written self-checking assembly in `tb/asm/`,
   targeting specific hazard, branch, trap and CSR behaviours.
3. **Compliance** — the upstream `rv32ui-p` suite from `riscv-tests`.
4. **Randomised lockstep** — constrained-random programs run simultaneously on
   the RTL and a C++ architectural ISS, compared instruction by instruction at
   retirement.

Every integration-level test runs at both zero wait states and randomised wait
states, so memory back-pressure is exercised continuously rather than in a
single dedicated test.

## 2. Test matrix

_(populated M1–M7)_

## 3. Coverage

Target: ≥ 95% line and toggle coverage on `rtl/common/` and `rtl/e_core/`,
measured by `make coverage`.

_(numbers and per-line justifications added at M8)_

## 4. Known limitations

_(populated as they are discovered; the `fence_i` exclusion from the compliance
suite is recorded here at M6)_
