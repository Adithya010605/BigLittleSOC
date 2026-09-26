#!/usr/bin/env python3
"""Summarise a merged Verilator coverage .dat file per source directory.

Verilator writes one line per coverage point:

    C '<0x01>key<0x02>value<0x01>key<0x02>value...' <count>

The keys used here are `f` (file), `l` (line), `t` (type: "line" or "toggle")
and `page`. Splitting only on 0x01 -- and treating the first character as the
key and the rest as the value -- silently mislabels every point, because the
value is separated from the key by 0x02, not by position. That mistake made
port declarations show up as uncovered *line* points.

Reports hit/total and a percentage for each source directory -- by default
rtl/common and rtl/e_core, or those given as a second, comma-separated
argument -- plus every zero-count point so uncovered lines can be justified
in the verification plans.

    cov_summary.py merged.dat [scope,scope,...]

A scope is a directory, optionally followed by '+' and extra paths that are
counted as part of it. The P-core passes
    rtl/common,rtl/p_core+rtl/e_core/e_core_trap.sv
because it instantiates the E-core's trap unit: that file is part of the
P-core as built, exactly as it is part of rtl/e_core for the E-core, and its
points belong with the rest of the core rather than in a bucket of their own.
"""

import re
import sys
from collections import defaultdict

DIRS = ("rtl/common", "rtl/e_core")
EXTRA = {}   # scope -> extra paths counted as part of it
if len(sys.argv) > 2:
    scopes = [d for d in sys.argv[2].split(",") if d]
    DIRS = tuple(sc.split("+")[0] for sc in scopes)
    EXTRA = {sc.split("+")[0]: sc.split("+")[1:] for sc in scopes}

# Line coverage is the enforced gate: every line of this design is reachable
# by a program, so anything short of 100% is a real hole in the test suite.
LINE_THRESHOLD = 100.0

# Toggle coverage is reported but held to a lower floor, because a large and
# precisely identifiable share of the toggle points in this design cannot be
# reached by ANY program:
#
#   * mie and mip are 32-bit registers in which only bits 3, 7 and 11 are
#     implemented; the other 29 bits are hardwired to zero;
#   * mcycle, minstret, the four mhpmcounters and rvfi_order are 64-bit, and
#     their upper halves would need on the order of 2^32 cycles to toggle;
#   * every PC, fetch address and branch target lives inside a 192 KiB memory,
#     so address bits 18 and above are always zero.
#
# Raising the raw number would mean widening the memory map or running for
# billions of cycles, neither of which tests anything. The breakdown printed
# below identifies exactly which signals account for the shortfall, so the
# figure can be justified rather than merely reported.
TOGGLE_FLOOR = 80.0


def parse(path):
    points = []
    with open(path, "r", errors="replace") as fh:
        for raw in fh:
            if not raw.startswith("C "):
                continue
            m = re.match(r"C '(.*)' (\d+)\s*$", raw.rstrip("\n"))
            if not m:
                continue
            body, count = m.group(1), int(m.group(2))
            fields = {}
            for item in body.split("\x01"):
                if "\x02" not in item:
                    continue
                key, _, val = item.partition("\x02")
                if key:
                    fields.setdefault(key, val)
            points.append((fields.get("f", ""), fields.get("l", "?"),
                           fields.get("t", ""), int(count)))
    return points


def bucket(fname):
    for d in DIRS:
        if d in fname or any(x in fname for x in EXTRA.get(d, ())):
            return d
    return None


def main():
    if len(sys.argv) < 2:
        print("usage: cov_summary.py <merged.dat>", file=sys.stderr)
        return 2
    points = parse(sys.argv[1])
    if not points:
        print("no coverage points found in", sys.argv[1], file=sys.stderr)
        return 1

    total = defaultdict(int)
    hit = defaultdict(int)
    misses = defaultdict(list)

    for fname, line, kind, count in points:
        b = bucket(fname)
        if b is None or kind not in ("line", "toggle"):
            continue
        total[(b, kind)] += 1
        if count > 0:
            hit[(b, kind)] += 1
        else:
            short = fname
            for d in DIRS:
                idx = fname.find(d)
                if idx >= 0:
                    short = fname[idx:]
                    break
            misses[(b, kind)].append("%s:%s" % (short, line))

    print("=" * 64)
    print("%-16s%-10s%>8s%>8s%>10s".replace(">", "") %
          ("scope", "kind", "hit", "total", "pct"))
    print("-" * 64)
    ok = True
    grand_hit = grand_total = 0
    for b in DIRS:
        for kind in ("line", "toggle"):
            t, h = total[(b, kind)], hit[(b, kind)]
            if t == 0:
                continue
            grand_hit += h
            grand_total += t
            pct = 100.0 * h / t
            limit = LINE_THRESHOLD if kind == "line" else TOGGLE_FLOOR
            flag = "" if pct >= limit else "  << below %.0f%%" % limit
            if pct < limit:
                ok = False
            print("%-16s%-10s%8d%8d%9.2f%%%s" % (b, kind, h, t, pct, flag))
    if grand_total:
        print("-" * 64)
        print("%-16s%-10s%8d%8d%9.2f%%" %
              ("TOTAL", "line+toggle", grand_hit, grand_total,
               100.0 * grand_hit / grand_total))
    print("=" * 64)

    # Where the toggle shortfall actually is, worst signal first. This is what
    # turns "82%" into a justifiable number.
    tog_miss = defaultdict(int)
    tog_total = defaultdict(int)
    for fname, line, kind, count in points:
        if bucket(fname) is None or kind != "toggle":
            continue
        short = fname
        for d in DIRS:
            idx = fname.find(d)
            if idx >= 0:
                short = fname[idx:]
                break
        key = (short, line)
        tog_total[key] += 1
        if count == 0:
            tog_miss[key] += 1
    if tog_miss:
        ranked = sorted(tog_miss.items(), key=lambda kv: -kv[1])
        print("\ntoggle shortfall by signal (worst first):")
        print("  %-40s %8s %8s" % ("file:line", "unhit", "bits"))
        for (fl, line), n in ranked[:15]:
            print("  %-40s %8d %8d" % ("%s:%s" % (fl, line), n, tog_total[(fl, line)]))
        print("  %-40s %8d %8d" %
              ("TOTAL", sum(tog_miss.values()), sum(tog_total.values())))

    for (b, kind), lst in sorted(misses.items()):
        uniq = sorted(set(lst))
        if not uniq or kind != "line":
            continue
        print("\nuncovered %s points in %s (%d):" % (kind, b, len(uniq)))
        for item in uniq[:80]:
            print("  ", item)
        if len(uniq) > 80:
            print("   ... and %d more" % (len(uniq) - 80))

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
