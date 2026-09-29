#!/usr/bin/env python3
"""Build the Review 2 slide deck.

Simplified edition: no verification-ladder / test-case slides, fewer words per
slide, fewer boxes.  Run with any Python that has python-pptx installed:

    python3 scripts/gen_review2_ppt.py [output.pptx]
"""

import sys
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE

OUT = sys.argv[1] if len(sys.argv) > 1 else "riscv_soc_review2_simple.pptx"

# ---------------------------------------------------------------- design system
NAVY   = RGBColor(0x0E, 0x1B, 0x2E)   # headings, dark panels
ORANGE = RGBColor(0xC4, 0x69, 0x2A)   # accent 1, eyebrows
TEAL   = RGBColor(0x2E, 0x8B, 0x84)   # accent 2, "done"
BODY   = RGBColor(0x3A, 0x4A, 0x5E)   # body copy
MUTED  = RGBColor(0x5B, 0x6B, 0x7C)   # secondary copy
FAINT  = RGBColor(0x9A, 0xA9, 0xB8)   # labels, page numbers
RULE   = RGBColor(0xD3, 0xDC, 0xE5)   # hairlines
PANEL  = RGBColor(0xF2, 0xF5, 0xF8)   # card fill
EDGE   = RGBColor(0xDD, 0xE4, 0xEB)   # card border
WHITE  = RGBColor(0xFF, 0xFF, 0xFF)
GREY   = RGBColor(0xC8, 0xD2, 0xDC)   # "not started" bars

SERIF = "Cambria"
SANS  = "Calibri"

L, R = 0.65, 12.65          # left margin, right edge
CW   = R - L                # content width = 12.00

prs = Presentation()
prs.slide_width  = Inches(13.333)
prs.slide_height = Inches(7.5)
BLANK = prs.slide_layouts[6]


# ------------------------------------------------------------------- primitives
def text(s, x, y, w, h, body, size=11, bold=False, color=BODY, font=SANS,
         align=PP_ALIGN.LEFT, italic=False, spacing=1.0, gap=0):
    """Text box.  `body` may contain newlines -> one paragraph per line."""
    tb = s.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = tb.text_frame
    tf.word_wrap = True
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
    for i, line in enumerate(body.split("\n")):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align
        p.line_spacing = spacing
        if gap:
            p.space_after = Pt(gap)
        r = p.add_run()
        r.text = line
        r.font.name = font
        r.font.size = Pt(size)
        r.font.bold = bold
        r.font.italic = italic
        r.font.color.rgb = color
    return tb


def rect(s, x, y, w, h, fill=None, line=None, lw=0.75, rounded=False, radius=0.10):
    shape = s.shapes.add_shape(
        MSO_SHAPE.ROUNDED_RECTANGLE if rounded else MSO_SHAPE.RECTANGLE,
        Inches(x), Inches(y), Inches(w), Inches(h))
    if rounded:
        try:
            shape.adjustments[0] = radius
        except Exception:
            pass
    if fill is None:
        shape.fill.background()
    else:
        shape.fill.solid()
        shape.fill.fore_color.rgb = fill
    if line is None:
        shape.line.fill.background()
    else:
        shape.line.color.rgb = line
        shape.line.width = Pt(lw)
    shape.shadow.inherit = False
    return shape


def hairline(s, x, y, w, color=RULE):
    rect(s, x, y, w, 0.012, fill=color)


def slide(eyebrow=None, title=None, number=None):
    s = prs.slides.add_slide(BLANK)
    if eyebrow:
        text(s, L, 0.40, CW, 0.26, eyebrow, 11, True, ORANGE)
    if title:
        text(s, L, 0.66, CW, 0.62, title, 32, True, NAVY, SERIF)
    if number is not None:
        text(s, 12.28, 7.08, 0.45, 0.28, str(number), 10, False, RULE,
             align=PP_ALIGN.RIGHT)
    return s


def card(s, x, y, w, h, heading, body, accent=ORANGE, hsize=12.5, bsize=9.5):
    """Light panel with a coloured spine, a heading and a paragraph."""
    rect(s, x, y, w, h, fill=PANEL, line=EDGE)
    rect(s, x, y + 0.22, 0.06, h - 0.44, fill=accent)
    text(s, x + 0.38, y + 0.24, w - 0.70, 0.28, heading, hsize, True, NAVY)
    text(s, x + 0.38, y + 0.58, w - 0.70, h - 0.82, body, bsize, color=BODY,
         spacing=1.20)


def chip(s, x, y, w, h, label, fill, color=WHITE, size=9, bold=True, radius=0.28):
    rect(s, x, y, w, h, fill=fill, rounded=True, radius=radius)
    text(s, x, y + (h - 0.17) / 2, w, 0.20, label, size, bold, color,
         align=PP_ALIGN.CENTER)


def bullets(s, x, y, w, h, items, size=10, color=BODY, spacing=1.18, gap=5):
    text(s, x, y, w, h, "\n".join("·  " + i for i in items), size,
         color=color, spacing=spacing, gap=gap)


def footnote(s, y, body, size=10.5):
    text(s, L, y, CW, 0.50, body, size, color=MUTED, italic=True, spacing=1.2)


def logo(s, x, y, size=0.88, fsize=30, edge=None):
    rect(s, x, y, size, size, fill=NAVY, rounded=True, radius=0.14, line=edge,
         lw=1.25)
    text(s, x, y + size / 2 - fsize / 144, size, 0.5, "P", fsize, True, WHITE,
         SERIF, PP_ALIGN.CENTER)
    rect(s, x + size + 0.14, y, size, size, fill=TEAL, rounded=True, radius=0.14)
    text(s, x + size + 0.14, y + size / 2 - fsize / 144, size, 0.5, "E", fsize,
         True, WHITE, SERIF, PP_ALIGN.CENTER)


# =============================================================== 1 · title slide
s = prs.slides.add_slide(BLANK)
text(s, L, 0.52, CW, 0.26,
     "VELLORE INSTITUTE OF TECHNOLOGY, CHENNAI   ·   SCHOOL OF ELECTRONICS ENGINEERING",
     10.5, True, ORANGE)
text(s, L, 0.92, CW, 0.30, "Final Year Project  —  Review 2 Presentation", 13,
     color=MUTED)
text(s, L, 1.62, 9.85, 1.90,
     "Design and Implementation of a Modular\nRISC-V SoC Supporting Heterogeneous\nMulti-Core Execution",
     34, True, NAVY, SERIF, spacing=1.16)
logo(s, 10.75, 1.72)
text(s, L, 3.62, 10.40, 0.85,
     "An asymmetric dual-cluster processor with cache coherence, hardware task "
     "migration and cluster-level power management — designed in SystemVerilog.",
     13, color=BODY, spacing=1.32)
hairline(s, L, 4.62, CW)
text(s, L, 4.82, 2.60, 0.24, "REVIEW 2 STATUS", 9.5, True, ORANGE)
text(s, L, 5.08, 11.60, 0.30,
     "Phase 1 is complete — the RV32I efficiency core is designed, built and "
     "synthesised at 2,273 LUTs. Phase 2, the performance core, begins now.",
     11.5, color=MUTED)

text(s, L, 5.72, 3.60, 0.24, "PRESENTED BY", 9.5, True, FAINT)
team = [("Vujwal", "23BVD1010", L), ("Adithya V", "23BVD1001", 3.00),
        ("Maadul Ram", "23BEC1188", 5.35)]
for name, reg, x in team:
    text(s, x, 6.00, 2.30, 0.28, name, 13, True, NAVY)
    text(s, x, 6.30, 2.30, 0.24, "Reg. No.  " + reg, 10, color=MUTED)
text(s, 9.50, 5.72, 3.15, 0.24, "PROJECT GUIDE", 9.5, True, FAINT,
     align=PP_ALIGN.RIGHT)
text(s, 9.00, 6.00, 3.65, 0.28, "Kiran Kumar Manivannan", 13, True, NAVY,
     align=PP_ALIGN.RIGHT)
text(s, 9.00, 6.30, 3.65, 0.24, "School of Electronics Engineering", 10,
     color=MUTED, align=PP_ALIGN.RIGHT)
hairline(s, L, 6.85, CW)
text(s, L, 7.00, 6.00, 0.26, "Academic Year 2026 – 2027", 10, color=FAINT)


# ==================================================================== 2 · outline
s = slide("OUTLINE", "What This Review Covers", 2)
items = [
    ("1", "Problem statement and background",
     "Why one type of core cannot do both jobs well"),
    ("2", "Literature survey",
     "Ten works, from MICRO 2003 to open RISC-V silicon"),
    ("3", "Existing solutions",
     "Commercial hybrids, open cores, and the gap between them"),
    ("4", "Proposed solution",
     "The target SoC and the blocks it is made of"),
    ("5", "Scope and objectives",
     "What we will build, and what we deliberately will not"),
    ("6", "Methodology",
     "How the design is put together, one block at a time"),
    ("7", "Work completed",
     "The E-Core, and where the project stands overall"),
    ("8", "Timeline and tools",
     "Nine phases to April 2027, and the toolchain behind them"),
]
for i, (n, title, sub) in enumerate(items):
    col, row = i % 2, i // 2
    x = L + col * 6.15
    y = 1.75 + row * 1.28
    chip(s, x, y, 0.52, 0.52, n, NAVY if col == 0 else TEAL, size=15,
         radius=0.16)
    text(s, x + 0.78, y + 0.02, 5.10, 0.30, title, 15, True, NAVY, SERIF)
    text(s, x + 0.78, y + 0.36, 5.10, 0.28, sub, 10.5, color=MUTED)
hairline(s, L, 6.68, CW)
footnote(s, 6.86, "Sections 1 to 3 set up the problem; sections 4 to 7 are the "
                  "work itself.")


# ================================================================= 3 · background
s = slide("SECTION 1  ·  PROBLEM STATEMENT AND BACKGROUND", "Background", 3)
text(s, L, 1.42, CW, 0.40,
     "Energy per instruction, not clock speed, is what limits processors today — "
     "and the industry's answer has been asymmetry: two kinds of core, one "
     "instruction set.", 13, color=NAVY, spacing=1.2)
cards = [
    ("Energy is the limit",
     "Power, not transistor count, caps sustained performance. A core built for "
     "peak speed wastes energy on light background work; a core built for "
     "efficiency stalls on heavy bursts. One core type cannot serve both.",
     ORANGE),
    ("One ISA, two core types",
     "Kumar et al. showed in 2003 that cores of different designs sharing one "
     "instruction set let each thread run on the cheapest core that can do the "
     "job — with no recompilation. ARM shipped this as big.LITTLE in 2011.",
     TEAL),
    ("RISC-V makes it buildable",
     "An open, royalty-free instruction set with a mature GCC toolchain. It is "
     "the first substrate on which a student team can design and measure a "
     "heterogeneous processor end to end.",
     ORANGE),
]
for i, (h, b, a) in enumerate(cards):
    card(s, L + i * 4.10, 2.10, 3.80, 2.05, h, b, a, hsize=13, bsize=10)

text(s, L, 4.55, CW, 0.24, "HOW THE IDEA TRAVELLED", 9.5, True, FAINT)
hairline(s, L, 5.28, CW, RULE)
milestones = [("2003", "Single-ISA\nheterogeneity"), ("2011", "ARM\nbig.LITTLE"),
              ("2017", "ARM\nDynamIQ"), ("2021", "Intel hybrid\nP + E cores"),
              ("2020s", "Open RISC-V\nheterogeneous SoCs")]
for i, (yr, what) in enumerate(milestones):
    x = L + i * (CW / 5)
    text(s, x, 4.88, 2.20, 0.28, yr, 15, True, NAVY, SERIF)
    rect(s, x, 5.22, 0.16, 0.16, fill=TEAL if i == 4 else ORANGE, rounded=True,
         radius=0.5)
    text(s, x, 5.46, 2.20, 0.60, what, 10, color=MUTED, spacing=1.16)
footnote(s, 6.45,
         "Where this project sits: rebuild that idea from first principles on "
         "RISC-V — two core types, a shared memory hierarchy and migration "
         "handled by hardware — in readable RTL.")


# ========================================================== 4 · problem statement
s = slide("SECTION 1  ·  PROBLEM STATEMENT AND BACKGROUND", "Problem Statement", 4)
rect(s, L, 1.50, CW, 0.95, fill=NAVY, rounded=True, radius=0.08)
text(s, 1.00, 1.72, 11.30, 0.60,
     "Design, build and verify an asymmetric multi-core RISC-V SoC in which a "
     "running thread can migrate between a performance core and an efficiency "
     "core in hardware, without the software knowing.",
     14, True, WHITE, SERIF, spacing=1.25)
subs = [
    ("Two designs, one instruction set",
     "A 5-stage RV32IM core and a 3-stage RV32I core must stay binary "
     "compatible, so a thread can stop on one and resume on the other.", ORANGE),
    ("Coherence across unequal caches",
     "One cluster's L1 is write-back and 2-way; the other's is write-through and "
     "direct-mapped. They must still agree on what memory holds.", TEAL),
    ("Migration has to pay for itself",
     "Moving a thread means moving 32 registers, the PC and the CSRs — about 140 "
     "bytes. If that costs more energy than it saves, there is no point.", ORANGE),
    ("No open reference exists",
     "Open RISC-V cores are almost all single-core point designs. Nothing puts "
     "two different cores under one coherent memory system.", TEAL),
]
for i, (h, b, a) in enumerate(subs):
    x = L + (i % 2) * 6.15
    y = 2.75 + (i // 2) * 1.48
    card(s, x, y, 5.85, 1.30, h, b, a)
footnote(s, 6.00, "These four sub-problems map one-to-one onto the objectives in "
                  "section 5. The first of them is now solved.")


# ========================================================= 5 · literature survey
s = slide("SECTION 2  ·  LITERATURE SURVEY", "Literature Survey", 5)
cols = [(L, 0.50, "REF"), (1.20, 0.55, "YEAR"), (1.85, 1.95, "WORK"),
        (3.90, 4.30, "WHAT IT CONTRIBUTED"),
        (8.30, 4.35, "WHAT IT DOES NOT DO")]
for x, w, label in cols:
    text(s, x, 1.42, w, 0.24, label, 9, True, FAINT)
hairline(s, L, 1.70, CW, NAVY)

lit = [
    ("[1]", "2003", "Kumar et al.\nMICRO-36",
     "Introduced single-ISA heterogeneity: large energy savings for a small loss in speed.",
     "Simulator study only — no RTL, no coherence and no migration hardware."),
    ("[2]", "2011", "Greenhalgh\nARM white paper",
     "big.LITTLE — Cortex-A15 and A7 clusters under one ISA. The reference industrial design.",
     "Proprietary RTL; switching is an OS decision, not a hardware mechanism."),
    ("[3]", "2016", "S. Mittal\nACM Comp. Surveys",
     "The standard map of the asymmetric multicore design space.",
     "Policy-centric — surveys results rather than giving hardware you can build."),
    ("[4]", "2022", "Rotem et al.\nIEEE Micro",
     "Intel Alder Lake — P and E cores on one die with a hardware thread director.",
     "Closed x86; ISA features had to be disabled to keep the two core types compatible."),
    ("[5]", "2019", "Zaruba & Benini\nIEEE TVLSI",
     "CVA6 / Ariane — an open 64-bit Linux-capable RISC-V core with full power data.",
     "A single class of core — homogeneous by construction, no asymmetric partner."),
    ("[6]", "2017", "Schiavone et al.\nPATMOS",
     "Quantifies the area-versus-energy trade-off across RV32 core sizes.",
     "Cores compared as separate designs — no shared memory, no migration path."),
    ("[7]", "2022", "Rossi et al.\nIEEE JSSC",
     "Vega — a ten-core RISC-V IoT SoC with a parallel compute cluster.",
     "Heterogeneity serves parallelism and accelerators, not same-ISA migration."),
    ("[8]", "2022", "Garofalo et al.\nIEEE OJ-SSCS",
     "DARKSIDE — a heterogeneous RISC-V cluster with accelerators for edge DNNs.",
     "Accelerator-centric; the general-purpose cores are all one microarchitecture."),
    ("[9]", "2020", "Nagarajan, Sorin,\nHill & Wood",
     "The standard reference on coherence protocols; the basis for the MSI protocol used here.",
     "Protocol theory — the asymmetric-L1 case is left to the implementer."),
    ("[10]", "2024", "lowRISC\nIbex core",
     "A small, production-quality open RV32 core with a clean, reusable memory port.",
     "Single core, no cache, no coherence — a component, not a system."),
]
y = 1.84
for i, row in enumerate(lit):
    if i % 2 == 1:
        rect(s, L, y - 0.06, CW, 0.47, fill=PANEL)
    text(s, cols[0][0], y, cols[0][1], 0.24, row[0], 9, True, ORANGE)
    text(s, cols[1][0], y, cols[1][1], 0.24, row[1], 9, True, NAVY)
    text(s, cols[2][0], y - 0.02, cols[2][1], 0.42, row[2], 8.5, True, NAVY,
         spacing=1.12)
    text(s, cols[3][0], y - 0.02, cols[3][1], 0.42, row[3], 8.5, color=BODY,
         spacing=1.12)
    text(s, cols[4][0], y - 0.02, cols[4][1], 0.42, row[4], 8.5, color=MUTED,
         spacing=1.12)
    y += 0.47
hairline(s, L, y - 0.04, CW)
footnote(s, y + 0.12, "Eight of the ten works are from 2016 or later. Full "
                      "citations are in section 8.")


# ========================================================== 6 · existing solutions
s = slide("SECTION 3  ·  EXISTING SOLUTIONS",
          "Existing Solutions and Their Limits", 6)
groups = [
    ("COMMERCIAL HYBRID CPUS",
     "ARM big.LITTLE and DynamIQ  ·  Intel Alder Lake  ·  Apple P / E clusters",
     ["Closed RTL — impossible to study, modify or measure inside",
      "Migration lives in firmware and the OS, so the hardware is invisible",
      "Licensing puts these designs out of reach for academic work"], ORANGE),
    ("OPEN RISC-V CORES",
     "Ibex  ·  CV32E40P  ·  Rocket  ·  CVA6 / Ariane  ·  BOOM",
     ["Each is a single point on the area-versus-performance curve",
      "Multi-core versions are homogeneous — the same core replicated",
      "No migration hardware: moving a thread is left entirely to software"], TEAL),
    ("RESEARCH HETEROGENEOUS SOCS",
     "PULP Vega  ·  DARKSIDE  ·  OpenPiton manycore",
     ["Heterogeneity is accelerator-driven, not single-ISA thread migration",
      "Coherence, where present, is sized for many cores — heavy for four",
      "Built by large groups on flows a student team cannot replicate"], ORANGE),
]
y = 1.45
for name, examples, pts, accent in groups:
    rect(s, L, y, CW, 1.34, fill=PANEL, line=EDGE)
    rect(s, L, y + 0.18, 0.06, 0.98, fill=accent)
    text(s, 1.03, y + 0.20, 4.60, 0.24, name, 10, True, accent)
    text(s, 1.03, y + 0.50, 4.60, 0.60, examples, 10.5, True, NAVY, spacing=1.16)
    bullets(s, 6.10, y + 0.22, 6.30, 0.95, pts, size=10, gap=4)
    y += 1.44

rect(s, L, 5.80, CW, 1.10, fill=NAVY, rounded=True, radius=0.06)
text(s, 1.00, 5.94, 3.00, 0.24, "THE GAP WE TARGET", 10, True, RGBColor(0xE8, 0xA8, 0x6C))
gaps = [
    "Two deliberately different cores under one ISA — asymmetry as the goal, not replication",
    "Coherence between caches with different write policies — the case the textbooks leave open",
    "Migration as hardware — a state machine that moves a thread in cycles, not an OS policy",
]
text(s, 1.00, 6.22, 11.30, 0.62,
     "\n".join("▸  " + g for g in gaps), 10, color=WHITE, spacing=1.16, gap=1)


# ====================================================== 7 · target soc architecture
s = slide("SECTION 4  ·  PROPOSED SOLUTION", "Target SoC Architecture", 7)

def cluster(x, label, accent, cores, l1, built):
    rect(s, x, 1.42, 5.85, 1.96, fill=PANEL, line=EDGE)
    text(s, x + 0.30, 1.60, 5.25, 0.24, label, 9.5, True, accent)
    for j, (nm, spec, is_built) in enumerate(cores):
        cx = x + 0.30 + j * 2.68
        rect(s, cx, 1.92, 2.48, 0.78, fill=WHITE,
             line=accent if is_built else EDGE, lw=1.25 if is_built else 0.75)
        text(s, cx, 2.04, 2.48, 0.26, nm, 12, True, NAVY, SERIF,
             align=PP_ALIGN.CENTER)
        text(s, cx, 2.34, 2.48, 0.24, spec, 8.5,
             color=TEAL if is_built else MUTED, align=PP_ALIGN.CENTER)
    rect(s, x + 0.30, 2.82, 5.25, 0.42, fill=NAVY if built else GREY)
    text(s, x + 0.30, 2.93, 5.25, 0.24, l1, 10, True,
         WHITE if built else NAVY, align=PP_ALIGN.CENTER)

cluster(L, "P-CLUSTER  ·  PERFORMANCE", ORANGE,
        [("P-Core 0", "RV32IM · 5-stage · phase 2", False),
         ("P-Core 1", "RV32IM · 5-stage · phase 2", False)],
        "P-Cluster L1  —  16 KB, 2-way, write-back", False)
cluster(6.80, "E-CLUSTER  ·  EFFICIENCY", TEAL,
        [("E-Core 0", "RV32I_Zicsr · 3-stage · BUILT", True),
         ("E-Core 1", "RV32I · 3-stage · phase 5", False)],
        "E-Cluster L1  —  8 KB, direct-mapped, write-through", False)

rect(s, L, 3.52, CW, 0.60, fill=PANEL, line=EDGE)
text(s, L, 3.62, CW, 0.26, "Coherent Interconnect  +  Snoop Bus", 12, True, NAVY,
     SERIF, align=PP_ALIGN.CENTER)
text(s, L, 3.88, CW, 0.22, "AXI4-Lite-style fabric with priority arbitration  ·  phase 4",
     8.5, color=MUTED, align=PP_ALIGN.CENTER)

rect(s, L, 4.24, CW, 0.60, fill=PANEL, line=EDGE)
text(s, L, 4.34, CW, 0.26, "Shared L2 Cache  —  64 KB, 4-way, inclusive, write-back",
     12, True, NAVY, SERIF, align=PP_ALIGN.CENTER)
text(s, L, 4.60, CW, 0.22, "with a bit-vector snoop filter  ·  phases 3 – 4", 8.5,
     color=MUTED, align=PP_ALIGN.CENTER)

blocks = [("Unified SRAM", "128 KB, banked"), ("Boot ROM", "64 KB"),
          ("UART · Timer · GPIO", "memory-mapped"),
          ("Task Migration Controller", "phase 6 · under 100 cycles"),
          ("Power Management Unit", "phase 7 · gating + DVFS")]
bw = (CW - 4 * 0.15) / 5
for i, (nm, sub) in enumerate(blocks):
    x = L + i * (bw + 0.15)
    rect(s, x, 4.96, bw, 0.80, fill=WHITE, line=EDGE)
    text(s, x + 0.08, 5.10, bw - 0.16, 0.26, nm, 10, True, NAVY,
         align=PP_ALIGN.CENTER, spacing=1.1)
    text(s, x + 0.08, 5.42, bw - 0.16, 0.22, sub, 8.5, color=MUTED,
         align=PP_ALIGN.CENTER)

rect(s, L, 5.98, 0.16, 0.16, fill=TEAL, rounded=True, radius=0.5)
text(s, 0.92, 5.97, 3.00, 0.24, "Built and verified (Review 2)", 9.5, color=MUTED)
rect(s, 4.10, 5.98, 0.16, 0.16, fill=GREY, rounded=True, radius=0.5)
text(s, 4.37, 5.97, 3.20, 0.24, "Planned — phases 2 to 8", 9.5, color=MUTED)
footnote(s, 6.42, "All four cores share one 32-bit address space. Migration, "
                  "power and performance registers are memory-mapped, so any "
                  "core can reach them.")


# ========================================================= 8 · scope & objectives
s = slide("SECTION 4  ·  PROPOSED SOLUTION", "Scope and Objectives", 8)
rect(s, L, 1.45, 5.85, 2.28, fill=PANEL, line=EDGE)
rect(s, L, 1.65, 0.06, 1.88, fill=TEAL)
text(s, 1.03, 1.66, 5.19, 0.24, "IN SCOPE", 10, True, TEAL)
bullets(s, 1.03, 2.00, 5.19, 1.60, [
    "RTL design in SystemVerilog-2012",
    "Simulation of the complete SoC",
    "A measured P-core versus E-core comparison on the same programs",
    "Yosys area estimates for every block",
], size=10.5, gap=6)

rect(s, L, 3.90, 5.85, 2.28, fill=PANEL, line=EDGE)
rect(s, L, 4.10, 0.06, 1.88, fill=ORANGE)
text(s, 1.03, 4.11, 5.19, 0.24, "OUT OF SCOPE", 10, True, ORANGE)
bullets(s, 1.03, 4.45, 5.19, 1.60, [
    "FPGA prototyping and ASIC tape-out",
    "Operating-system and scheduler integration",
    "Floating point, MMU and virtual memory",
    "Physical power measurement — energy is argued from area",
], size=10.5, color=MUTED, gap=6)

text(s, 6.80, 1.45, 5.85, 0.24, "OBJECTIVES", 10, True, FAINT)
objs = [
    ("1", "Design the E-Core", "RV32I_Zicsr, 3-stage, smallest practical area",
     "COMPLETE", TEAL),
    ("2", "Design the P-Core", "RV32IM, 5-stage, forwarding and branch prediction",
     "NEXT", ORANGE),
    ("3", "Build the memory hierarchy", "Two different L1s over a shared 64 KB L2",
     "PLANNED", GREY),
    ("4", "Implement MSI coherence", "Snoop-based, with a filter in the L2",
     "PLANNED", GREY),
    ("5", "Switch cores in hardware", "Migration FSM, clock gating and a DVFS stub",
     "PLANNED", GREY),
    ("6", "Compare P against E", "Cycles, CPI and area on identical workloads",
     "PLANNED", GREY),
]
y = 1.78
for n, title, sub, status, colr in objs:
    rect(s, 6.80, y, 5.85, 0.68, fill=PANEL if colr is GREY else WHITE,
         line=EDGE)
    chip(s, 6.96, y + 0.16, 0.36, 0.36, n, colr,
         WHITE if colr is not GREY else NAVY, size=10, radius=0.5)
    text(s, 7.46, y + 0.10, 3.20, 0.26, title, 11.5, True, NAVY)
    text(s, 7.46, y + 0.38, 3.60, 0.22, sub, 8.5, color=MUTED)
    text(s, 11.05, y + 0.24, 1.45, 0.22, status, 8.5, True,
         FAINT if colr is GREY else colr, align=PP_ALIGN.RIGHT)
    y += 0.74
footnote(s, 6.42, "Objective 1 is closed. Objective 2 starts this month; the "
                  "P-Core reuses six modules from the E-Core unchanged.")


# ==================================================================== 9 · method
s = slide("SECTION 4  ·  PROPOSED SOLUTION", "Methodology", 9)
text(s, L, 1.42, CW, 0.40,
     "Bottom-up construction: every block is built and proved on its own before "
     "it goes into a core, and never more than one new piece at a time.",
     13, color=NAVY, spacing=1.2)
steps = [
    ("STEP 1", "Specify",
     "Freeze the instruction subset, memory map and CSR list before any RTL"),
    ("STEP 2", "Build blocks",
     "ALU, register file, immediate generator, decoder, CSR unit, load/store unit"),
    ("STEP 3", "E-Core first",
     "The simple core proves out the shared blocks and the whole build flow"),
    ("STEP 4", "P-Core next",
     "Reuse the same blocks; add stages, branch prediction and multiply/divide"),
    ("STEP 5", "Integrate",
     "Caches, then interconnect, then coherence, then migration — one at a time"),
    ("STEP 6", "Quantify",
     "Cycles, CPI and area for the P-Core against the E-Core on the same programs"),
]
sw = (CW - 5 * 0.18) / 6
for i, (label, title, body) in enumerate(steps):
    x = L + i * (sw + 0.18)
    done = i <= 2
    rect(s, x, 2.20, sw, 2.30, fill=PANEL, line=EDGE)
    rect(s, x, 2.20, sw, 0.07, fill=TEAL if done else GREY)
    text(s, x + 0.20, 2.44, sw - 0.40, 0.22, label, 8.5, True,
         TEAL if done else FAINT)
    text(s, x + 0.20, 2.74, sw - 0.40, 0.34, title, 13, True, NAVY, SERIF,
         spacing=1.1)
    text(s, x + 0.20, 3.34, sw - 0.40, 1.00, body, 9, color=BODY, spacing=1.18)
    if i < 5:
        text(s, x + sw + 0.01, 3.16, 0.16, 0.26, "›", 15, True, FAINT,
             align=PP_ALIGN.CENTER)

rect(s, L, 4.86, CW, 1.10, fill=NAVY, rounded=True, radius=0.06)
text(s, 1.00, 5.02, 3.00, 0.24, "WHEN A STEP IS DONE", 10, True,
     RGBColor(0xE8, 0xA8, 0x6C))
text(s, 1.00, 5.30, 11.30, 0.55,
     "A step closes only when the whole design still builds and runs correctly "
     "from a clean checkout — one command, no manual setup, no warnings left "
     "behind.", 11.5, color=WHITE, spacing=1.2)
footnote(s, 6.24, "Steps 1 to 3 are complete. Step 4 is where Phase 2 begins.")


# =========================================================== 10 · work completed
s = slide("SECTION 5  ·  WORK COMPLETED", "Where the Project Stands", 10)
stats = [("3,000", "lines of RTL", "13 modules"),
         ("2,273", "LUTs on 7-series", "target was under 5,000"),
         ("1.24", "cycles per instruction", "bubble sort, no wait states"),
         ("2 of 9", "phases closed", "phase 2 begins now"),
         ("49 %", "of the design done", "weighted by effort")]
bw = (CW - 4 * 0.16) / 5
for i, (big, lab, sub) in enumerate(stats):
    x = L + i * (bw + 0.16)
    rect(s, x, 1.42, bw, 1.10, fill=PANEL, line=EDGE)
    text(s, x, 1.54, bw, 0.44, big, 26, True, NAVY, SERIF, PP_ALIGN.CENTER)
    text(s, x, 2.02, bw, 0.22, lab, 10, True, ORANGE, align=PP_ALIGN.CENTER)
    text(s, x, 2.26, bw, 0.20, sub, 8.5, color=MUTED, align=PP_ALIGN.CENTER)

text(s, L, 2.86, 6.00, 0.24, "WORKSTREAM", 9, True, FAINT)
text(s, 7.20, 2.86, 1.20, 0.24, "SHARE", 9, True, FAINT, align=PP_ALIGN.RIGHT)
text(s, 8.60, 2.86, 3.00, 0.24, "PROGRESS", 9, True, FAINT)
hairline(s, L, 3.12, CW, NAVY)

work = [("Toolchain and build system", 10, 100),
        ("Simulation infrastructure", 10, 100),
        ("E-Core RTL — RV32I_Zicsr, 3-stage, traps and interrupts", 20, 100),
        ("Documentation", 6, 70),
        ("P-Core — RV32IM, 5-stage, branch prediction", 14, 35),
        ("L1 caches and shared L2", 16, 0),
        ("Interconnect and MSI coherence", 12, 0),
        ("Migration, power management and SoC integration", 12, 0)]
y = 3.26
for name, weight, pct in work:
    text(s, L, y + 0.06, 6.30, 0.26, name, 11, color=NAVY)
    text(s, 7.20, y + 0.06, 1.20, 0.26, f"{weight} %", 11, True, MUTED,
         align=PP_ALIGN.RIGHT)
    rect(s, 8.60, y + 0.12, 3.10, 0.16, fill=RULE)
    if pct:
        rect(s, 8.60, y + 0.12, 3.10 * pct / 100.0, 0.16,
             fill=TEAL if pct == 100 else ORANGE)
    text(s, 11.85, y + 0.06, 0.80, 0.26, f"{pct} %", 10.5, True,
         TEAL if pct == 100 else (NAVY if pct else FAINT), align=PP_ALIGN.RIGHT)
    y += 0.40

rect(s, L, y + 0.04, CW, 0.50, fill=NAVY, rounded=True, radius=0.14)
text(s, 1.00, y + 0.18, 6.00, 0.26, "WEIGHTED COMPLETION", 11, True, WHITE)
text(s, 7.20, y + 0.18, 1.20, 0.26, "100 %", 11, True,
     RGBColor(0x9A, 0xB4, 0xC8), align=PP_ALIGN.RIGHT)
text(s, 8.60, y + 0.18, 3.10, 0.26, "Phases 0 and 1 closed", 10,
     color=RGBColor(0x9A, 0xB4, 0xC8))
text(s, 11.85, y + 0.16, 0.80, 0.28, "49 %", 13, True, WHITE, SERIF,
     align=PP_ALIGN.RIGHT)
footnote(s, y + 0.68,
         "Shares are each workstream's slice of total design effort. The 35 % "
         "credited to the P-Core is for the six common modules it reuses "
         "unchanged from the E-Core.", 9.5)


# ================================================================= 11 · the e-core
s = slide("SECTION 5  ·  WORK COMPLETED", "The E-Core — Built and Synthesised", 11)
stages = [("IF", "Instruction Fetch",
           "Program counter, a separate fetch-address register and a one-entry buffer"),
          ("ID / RF", "Decode and Register Read",
           "Decoder, immediate generator, register file, branch comparator and forwarding"),
          ("EX / MEM / WB", "Execute, Memory, Writeback",
           "ALU, load/store unit, CSR unit and trap unit, with single-cycle writeback")]
sw = (CW - 2 * 0.20) / 3
for i, (tag, name, body) in enumerate(stages):
    x = L + i * (sw + 0.20)
    rect(s, x, 1.42, sw, 1.20, fill=PANEL, line=EDGE)
    rect(s, x, 1.42, sw, 0.07, fill=TEAL)
    text(s, x + 0.22, 1.60, sw - 0.44, 0.24, tag, 9.5, True, TEAL)
    text(s, x + 0.22, 1.86, sw - 0.44, 0.26, name, 13, True, NAVY, SERIF)
    text(s, x + 0.22, 2.16, sw - 0.44, 0.42, body, 9, color=BODY, spacing=1.16)
    if i < 2:
        text(s, x + sw + 0.02, 1.94, 0.16, 0.26, "›", 15, True, FAINT,
             align=PP_ALIGN.CENTER)

text(s, L, 2.90, 5.85, 0.24, "WHAT IT IMPLEMENTS", 10, True, ORANGE)
hairline(s, L, 3.16, 5.85)
bullets(s, L, 3.32, 5.85, 2.40, [
    "All 40 RV32I instructions plus the 6 CSR instructions — 49 in total",
    "Machine mode with all 9 exceptions, correctly prioritised",
    "Timer, software and external interrupts, with return-from-trap",
    "64-bit cycle and instruction counters, plus four performance counters",
    "Two memory ports that tolerate any amount of latency",
], size=10.5, gap=11)

text(s, 6.80, 2.90, 5.85, 0.24, "DESIGN DECISIONS THAT PAID OFF", 10, True, TEAL)
hairline(s, 6.80, 3.16, 5.85)
bullets(s, 6.80, 3.32, 5.85, 2.40, [
    "Branches resolve one stage early — a taken branch costs one cycle, not two",
    "A one-entry buffer in fetch — without it throughput is capped at half an instruction per cycle",
    "The fetch address is a separate register from the PC, so a redirect cannot disturb a request already accepted",
    "The register file is not reset — it becomes 12 small RAMs instead of 1,024 flip-flops",
], size=10.5, gap=11)

rect(s, L, 5.55, CW, 1.05, fill=NAVY, rounded=True, radius=0.07)
nums = [("2,273", "LUTs"), ("968", "flip-flops"), ("12", "distributed RAMs"),
        ("49", "instructions")]
for i, (big, lab) in enumerate(nums):
    x = 1.00 + i * 1.55
    text(s, x, 5.73, 1.45, 0.34, big, 19, True, WHITE, SERIF)
    text(s, x, 6.11, 1.45, 0.22, lab, 9, color=RGBColor(0x9A, 0xB4, 0xC8))
text(s, 7.40, 5.81, 4.90, 0.60,
     "55 % under the 5,000-LUT budget. This is the baseline the P-Core has to "
     "beat on speed — and stay close to on area.", 11, color=WHITE, spacing=1.2)


# ================================================================== 12 · timeline
s = slide("SECTION 6  ·  PROJECT TIMELINE", "Project Timeline", 12)
months = ["AUG 26", "SEP 26", "OCT 26", "NOV 26", "DEC 26", "JAN 27", "FEB 27",
          "MAR 27", "APR 27"]
TX, TW = 4.30, R - 4.30          # track origin and width
MW = TW / len(months)            # month width
for i, m in enumerate(months):
    text(s, TX + i * MW, 1.42, MW, 0.24, m, 8.5, True, FAINT,
         align=PP_ALIGN.CENTER)
    if i:
        rect(s, TX + i * MW, 1.70, 0.008, 4.30, fill=RULE)
hairline(s, TX, 1.68, TW)

phases = [
    ("Phase 0", "Setup, toolchain and build system", 0, 1, "COMPLETE", TEAL),
    ("Phase 1", "E-Core and simulation infrastructure", 1, 1, "COMPLETE", TEAL),
    ("Phase 2", "P-Core — RV32IM with branch prediction", 2, 2, "IN PROGRESS", ORANGE),
    ("Phase 3", "L1 caches and shared L2", 3.5, 1.5, "", GREY),
    ("Phase 4", "Interconnect and MSI coherence", 4.5, 2, "HIGHEST RISK", GREY),
    ("Phase 5", "SoC integration and boot", 6, 1, "", GREY),
    ("Phase 6", "Task migration controller", 6.5, 1.5, "", GREY),
    ("Phase 7", "Power management — gating and DVFS stub", 7, 1, "", GREY),
    ("Phase 8", "Full-system testing and documentation", 7.5, 1.5, "", GREY),
]
y = 1.86
for name, desc, start, dur, tag, colr in phases:
    text(s, L, y + 0.02, 0.95, 0.24, name, 10, True, NAVY)
    text(s, 1.62, y + 0.03, 2.60, 0.24, desc, 9, color=MUTED)
    rect(s, TX + start * MW, y, dur * MW - 0.05, 0.30,
         fill=colr, rounded=True, radius=0.30)
    if tag:
        tc = WHITE if colr is not GREY else NAVY
        text(s, TX + start * MW, y + 0.06, dur * MW - 0.05, 0.20, tag, 8,
             True, tc, align=PP_ALIGN.CENTER)
    y += 0.46

rect(s, TX + 2 * MW - 0.008, 1.62, 0.02, 4.42, fill=ORANGE)
text(s, TX + 2 * MW - 0.90, 6.10, 1.80, 0.24, "REVIEW 2", 9, True, ORANGE,
     align=PP_ALIGN.CENTER)
footnote(s, 6.52,
         "Two of nine phases are closed — and they are the phases everything "
         "else is built on. Phase 4, coherence between a write-back and a "
         "write-through cache, carries the most risk and holds the biggest "
         "schedule buffer.")


# ===================================================================== 13 · tools
s = slide("SECTION 7  ·  TOOLS AND TECHNOLOGIES", "Tools and Technologies", 13)
panels = [
    ("RTL DESIGN", ORANGE, [
        "SystemVerilog-2012 (IEEE 1800) — packages, enums, packed structs",
        "RV32I with CSRs today; RV32IM from Phase 2",
        "13 modules and 3,000 lines across rtl/common and rtl/e_core",
        "Parameterised reset vector, hart ID and trace port"]),
    ("SIMULATION AND DEBUG", TEAL, [
        "Verilator 5.x — cycle-accurate, a hard requirement of the build",
        "C++17 testbenches with a memory model and an ELF loader",
        "GTKWave for waveform debug, driven from the Makefile",
        "Memory latency configurable — fixed or randomised back-pressure"]),
    ("SOFTWARE TOOLCHAIN", TEAL, [
        "riscv64-elf-gcc — five prefixes auto-detected by the Makefile",
        "Bare-metal C and start.S — no operating system, no libc startup",
        "Custom linker scripts for the SoC memory map",
        "libgcc supplies multiply and divide, which the E-Core omits"]),
    ("SYNTHESIS AND BUILD", ORANGE, [
        "Yosys — synth_xilinx targeting the Xilinx 7-series",
        "sv2v lowers SystemVerilog to Verilog-2005, fetched automatically",
        "GNU Make — one command builds and runs everything",
        "Git and GitHub — one commit per milestone"]),
]
for i, (name, accent, pts) in enumerate(panels):
    x = L + (i % 2) * 6.15
    y = 1.55 + (i // 2) * 2.55
    rect(s, x, y, 5.85, 2.30, fill=PANEL, line=EDGE)
    rect(s, x, y + 0.22, 0.06, 1.86, fill=accent)
    text(s, x + 0.38, y + 0.24, 5.19, 0.24, name, 10, True, accent)
    bullets(s, x + 0.38, y + 0.62, 5.19, 1.55, pts, size=10.5, gap=7)
footnote(s, 6.75, "Everything above is free and open source, and the whole flow "
                  "runs on a laptop.")


# ================================================================ 14 · references
s = slide("SECTION 8  ·  REFERENCES", "References", 14)
refs = [
    ("[1]", "R. Kumar, K. I. Farkas, N. P. Jouppi, P. Ranganathan and D. M. Tullsen, "
            "\"Single-ISA Heterogeneous Multi-Core Architectures: The Potential for "
            "Processor Power Reduction,\" in Proc. MICRO-36, Dec. 2003, pp. 81–92."),
    ("[2]", "P. Greenhalgh, \"big.LITTLE Processing with ARM Cortex-A15 and "
            "Cortex-A7,\" ARM Ltd., White Paper, Sept. 2011."),
    ("[3]", "S. Mittal, \"A Survey of Techniques for Architecting and Managing "
            "Asymmetric Multicore Processors,\" ACM Computing Surveys, vol. 48, "
            "no. 3, pp. 1–38, Feb. 2016."),
    ("[4]", "E. Rotem et al., \"Intel Alder Lake CPU Architectures,\" IEEE Micro, "
            "vol. 42, no. 3, pp. 13–19, May–June 2022."),
    ("[5]", "F. Zaruba and L. Benini, \"The Cost of Application-Class Processing: "
            "Energy and Performance Analysis of a Linux-Ready 1.7-GHz 64-Bit RISC-V "
            "Core in 22-nm FDSOI,\" IEEE Trans. VLSI Systems, vol. 27, no. 11, "
            "pp. 2629–2640, Nov. 2019."),
    ("[6]", "P. D. Schiavone et al., \"Slow and Steady Wins the Race? A Comparison "
            "of Ultra-Low-Power RISC-V Cores for IoT Applications,\" in Proc. "
            "PATMOS, 2017."),
    ("[7]", "D. Rossi et al., \"Vega: A Ten-Core SoC for IoT End-Nodes with DNN "
            "Acceleration and Cognitive Wake-Up from MRAM-Based State-Retentive "
            "Sleep Mode,\" IEEE J. Solid-State Circuits, vol. 57, no. 1, "
            "pp. 127–139, Jan. 2022."),
    ("[8]", "A. Garofalo et al., \"DARKSIDE: A Heterogeneous RISC-V Compute "
            "Cluster for Extreme-Edge On-Chip DNN Inference and Training,\" IEEE "
            "OJ-SSCS, vol. 2, pp. 231–243, 2022."),
    ("[9]", "V. Nagarajan, D. J. Sorin, M. D. Hill and D. A. Wood, A Primer on "
            "Memory Consistency and Cache Coherence, 2nd ed. Morgan & Claypool, 2020."),
    ("[10]", "lowRISC C.I.C., \"Ibex: An Embedded 32-bit RISC-V CPU Core,\" "
             "documentation and RTL, 2024. Available: github.com/lowRISC/ibex"),
    ("[11]", "A. Waterman and K. Asanović, Eds., The RISC-V Instruction Set Manual, "
             "Vols. I and II, RISC-V International."),
    ("[12]", "W. Snyder, \"Verilator: Open-Source SystemVerilog Simulator and Lint "
             "System,\" Veripool. Available: verilator.org"),
]
for i, (tag, body) in enumerate(refs):
    x = L + (i % 2) * 6.15
    y = 1.48 + (i // 2) * 0.84
    text(s, x, y, 0.55, 0.24, tag, 9.5, True, ORANGE)
    text(s, x + 0.60, y, 5.25, 0.80, body, 9, color=BODY, spacing=1.18)


# ================================================================= 15 · thank you
s = prs.slides.add_slide(BLANK)
rect(s, 0, 0, 13.333, 7.5, fill=NAVY)
text(s, L, 2.55, CW, 0.26, "REVIEW 2  ·  PHASE 1 COMPLETE", 11, True,
     RGBColor(0xE8, 0xA8, 0x6C))
text(s, L, 2.95, CW, 1.00, "Thank You", 54, True, WHITE, SERIF)
text(s, L, 4.10, 9.00, 0.36, "Questions and suggestions are welcome.", 15,
     color=RGBColor(0x9A, 0xB4, 0xC8))
rect(s, L, 4.80, 9.60, 0.012, fill=RGBColor(0x2A, 0x3B, 0x52))
text(s, L, 5.05, 9.50, 0.30,
     "Design and Implementation of a Modular RISC-V SoC Supporting "
     "Heterogeneous Multi-Core Execution", 11,
     color=RGBColor(0x6E, 0x83, 0x9A))
logo(s, 10.87, 4.52, 0.80, 26, edge=RGBColor(0x2A, 0x3B, 0x52))

prs.save(OUT)
print("wrote %s - %d slides" % (OUT, len(prs.slides._sldIdLst)))
