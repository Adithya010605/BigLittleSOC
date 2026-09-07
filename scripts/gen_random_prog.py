#!/usr/bin/env python3
"""Constrained-random RV32I_Zicsr program generator for lockstep testing.

The generator's job is to produce programs that are *interesting to a pipeline*
rather than merely legal: dense register reuse so that read-after-write hazards
occur at distance 1 constantly, branches whose operands were produced by the
immediately preceding instruction, loads feeding the very next instruction, and
memory traffic at every alignment.

Termination is structural, not hoped for:

  * every conditional branch and every jump targets a label FORWARD of itself,
    so control can only ever move down the program;
  * the one backward-branch construct is a counted loop whose counter register
    is reserved, initialised to a small constant, and decremented exactly once
    per iteration by the generator itself, so no random instruction can touch
    it;
  * the program ends with an unconditional store of 1 to `tohost`.

A program therefore cannot loop forever regardless of the data values it
computes, which matters because the testbench's cycle budget would otherwise
turn a generator bug into a mysterious timeout.

Registers are partitioned so the program cannot destroy its own preconditions:

  x0        zero
  x1        scratch-area base pointer, written once at entry
  x2 (sp)   left alone
  x3 (gp)   left alone
  x4        loop counter, only the generator touches it
  x5..x29   the working pool that random instructions read and write
  x30, x31  the epilogue and the trap handler

Cycle-dependent CSRs (mcycle, minstret, the performance counters, mip) are
never read: their values cannot be predicted by an architectural model, and
while the lockstep checker tolerates that, excluding them keeps a mismatch
unambiguous.
"""

import argparse
import random

WORKING = list(range(5, 30))          # x5..x29
HOT = None                            # a small subset, chosen per program
SCRATCH_WORDS = 64

ALU_RR = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
ALU_RI = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SHIFT_I = ["slli", "srli", "srai"]
BRANCHES = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LOADS = [("lb", 1), ("lbu", 1), ("lh", 2), ("lhu", 2), ("lw", 4)]
STORES = [("sb", 1), ("sh", 2), ("sw", 4)]


class Gen:
    def __init__(self, rng):
        self.rng = rng
        self.out = []
        self.n = 0
        # A small hot pool makes dependent instructions land next to each
        # other far more often than uniform selection over 25 registers would.
        self.hot = rng.sample(WORKING, 6)

    def reg(self):
        """A register biased towards the hot pool, so hazards are dense."""
        if self.rng.random() < 0.75:
            return self.rng.choice(self.hot)
        return self.rng.choice(WORKING)

    def emit(self, text):
        self.out.append("    " + text)
        self.n += 1

    def label(self, name):
        self.out.append(name + ":")

    # ---- individual instruction forms ------------------------------------
    def alu_rr(self):
        self.emit("%s x%d, x%d, x%d" % (self.rng.choice(ALU_RR), self.reg(),
                                        self.reg(), self.reg()))

    def alu_ri(self):
        self.emit("%s x%d, x%d, %d" % (self.rng.choice(ALU_RI), self.reg(),
                                       self.reg(), self.rng.randint(-2048, 2047)))

    def shift_i(self):
        self.emit("%s x%d, x%d, %d" % (self.rng.choice(SHIFT_I), self.reg(),
                                       self.reg(), self.rng.randint(0, 31)))

    def upper(self):
        if self.rng.random() < 0.5:
            self.emit("lui x%d, %d" % (self.reg(), self.rng.randint(0, 0xFFFFF)))
        else:
            self.emit("auipc x%d, %d" % (self.reg(), self.rng.randint(0, 0xFF)))

    def load(self):
        name, align = self.rng.choice(LOADS)
        off = self.rng.randrange(0, SCRATCH_WORDS * 4 - 4, align)
        self.emit("%s x%d, %d(x1)" % (name, self.reg(), off))

    def store(self):
        name, align = self.rng.choice(STORES)
        off = self.rng.randrange(0, SCRATCH_WORDS * 4 - 4, align)
        self.emit("%s x%d, %d(x1)" % (name, self.reg(), off))

    def branch(self, tag):
        """A forward branch, so control can only move down the program."""
        target = "fwd_%d" % tag
        self.emit("%s x%d, x%d, %s" % (self.rng.choice(BRANCHES), self.reg(),
                                       self.reg(), target))
        skipped = self.rng.randint(1, 4)
        for _ in range(skipped):
            self.any_simple()
        self.label(target)

    def jump(self, tag):
        target = "jmp_%d" % tag
        self.emit("jal x%d, %s" % (self.reg(), target))
        for _ in range(self.rng.randint(1, 3)):
            self.any_simple()
        self.label(target)

    def csr(self):
        # mscratch only: a plain read/write register with no side effects and
        # no dependence on how many cycles have elapsed.
        op = self.rng.choice(["csrrw", "csrrs", "csrrc"])
        self.emit("%s x%d, mscratch, x%d" % (op, self.reg(), self.reg()))

    def ecall(self):
        # The handler below advances mepc by four and returns, so an ECALL is
        # an expensive NOP that exercises trap entry and MRET.
        self.emit("ecall")

    def any_simple(self):
        r = self.rng.random()
        if r < 0.34:
            self.alu_rr()
        elif r < 0.55:
            self.alu_ri()
        elif r < 0.65:
            self.shift_i()
        elif r < 0.75:
            self.load()
        elif r < 0.85:
            self.store()
        elif r < 0.95:
            self.upper()
        else:
            self.csr()

    def loop(self, tag):
        """A counted backward loop. x4 is reserved so nothing else can touch it."""
        iters = self.rng.randint(2, 6)
        self.emit("li x4, %d" % iters)
        self.label("loop_%d" % tag)
        for _ in range(self.rng.randint(2, 6)):
            self.any_simple()
        self.emit("addi x4, x4, -1")
        self.emit("bne x4, x0, loop_%d" % tag)


def generate(seed, n_blocks):
    rng = random.Random(seed)
    g = Gen(rng)

    body = []
    tag = 0
    for _ in range(n_blocks):
        r = rng.random()
        if r < 0.55:
            for _ in range(rng.randint(2, 6)):
                g.any_simple()
        elif r < 0.72:
            g.branch(tag)
        elif r < 0.84:
            g.jump(tag)
        elif r < 0.96:
            g.loop(tag)
        else:
            g.ecall()
        tag += 1
    body = g.out

    lines = []
    lines.append("/* Generated by scripts/gen_random_prog.py, seed=%d." % seed)
    lines.append(" * Do not edit: regenerate with the same seed to reproduce.")
    lines.append(" */")
    lines.append("    .section .text.init, \"ax\"")
    lines.append("    .globl _start")
    lines.append("_start:")
    lines.append("    la      sp, _stack_top")
    lines.append("    la      x1, rnd_scratch")
    lines.append("    la      x31, trap_handler")
    lines.append("    csrw    mtvec, x31")
    # Start from a defined architectural state so the RTL and the reference
    # agree on every register from the first instruction.
    for r in [4] + WORKING + [30, 31]:
        lines.append("    li      x%d, 0" % r)
    lines.extend(body)
    # Epilogue: report success. x1 may have been overwritten by the body, so
    # the address is recomputed here.
    lines.append("    la      x30, tohost")
    lines.append("    li      x31, 1")
    lines.append("    sw      x31, 0(x30)")
    lines.append("1:  j       1b")
    lines.append("")
    lines.append("    .align 4")
    lines.append("trap_handler:")
    lines.append("    csrr    x30, mepc")
    lines.append("    addi    x30, x30, 4")
    lines.append("    csrw    mepc, x30")
    lines.append("    mret")
    lines.append("")
    lines.append("    .section .data")
    lines.append("    .align 4")
    lines.append("rnd_scratch:")
    lines.append("    .fill %d, 4, 0" % SCRATCH_WORDS)
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--blocks", type=int, default=60,
                    help="number of random blocks (default 60)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    with open(args.out, "w") as f:
        f.write(generate(args.seed, args.blocks))


if __name__ == "__main__":
    main()
