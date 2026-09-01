# E-Core Microarchitecture

**Status:** skeleton written at M0. The datapath, forwarding/stall tables,
branch analysis, trap table, CSR map and design justifications are filled in as
the corresponding RTL lands (M1–M5) and are final at M8.

## 1. Scope

A 3-stage in-order RV32I_Zicsr core, machine mode only, targeting < 5K LUTs.
It is the "LITTLE" core of the big.LITTLE pair described in
`RISC-V_SoC_Project_Plan.md` section 2.1.

Not implemented, by design:
- No M extension. `MUL`/`DIV` opcodes raise illegal-instruction.
- No compressed instructions, no floating point, no user/supervisor modes.
- No branch prediction hardware (static not-taken).
- No caches, MMU or PMP. The memory ports are raw valid/ready.

## 2. Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `RESET_VECTOR` | `32'h0000_0000` | PC after reset |
| `HART_ID` | `32'h0000_0000` | value read from `mhartid` |
| `RVFI` | `1'b0` | when set, exposes the riscv-formal trace port |

## 3. Pipeline structure

_(filled in at M3)_

## 4. Forwarding and stall tables

_(filled in at M4)_

## 5. Branch penalty analysis

_(filled in at M3)_

## 6. Trap priority and CSR map

_(filled in at M5)_

## 7. Design justifications

_(branch-resolution-in-ID, write-first regfile, CSR stall instead of forward,
valid/ready memory protocol — written as each is implemented)_
