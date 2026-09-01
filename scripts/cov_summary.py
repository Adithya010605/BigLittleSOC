#!/usr/bin/env python3
"""Summarise a merged Verilator coverage .dat file per source directory.

Verilator writes one line per coverage point:
  C '<\x01f<file>\x01l<line>\x01n<name>\x01page<page>...' <count>
Points whose page starts with 'v_line' are line coverage; 'v_toggle' are
toggle coverage. We report hit/total and percentage for rtl/common and
rtl/e_core, plus every zero-count point so uncovered lines can be justified
in docs/e_core_verification_plan.md.
"""
import re
import sys
from collections import defaultdict

DIRS = ("rtl/common", "rtl/e_core")


def parse(path):
    pts = []
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
                if len(item) < 2:
                    continue
                key, val = item[0], item[1:]
                if key == "p":              # page/point name, e.g. v_line/...
                    fields.setdefault("page", val)
                else:
                    fields[key] = val
            if "page" not in fields:
                mp = re.search(r"page([A-Za-z0-9_/]*)", body)
                fields["page"] = mp.group(1) if mp else ""
            pts.append((fields.get("f", ""), fields.get("l", "?"),
                        fields.get("page", ""), count))
    return pts


def bucket(fname):
    for d in DIRS:
        if d in fname:
            return d
    return None


def kind(page):
    if "toggle" in page:
        return "toggle"
    if "line" in page or "branch" in page:
        return "line"
    return "other"


def main():
    if len(sys.argv) < 2:
        print("usage: cov_summary.py <merged.dat>", file=sys.stderr)
        return 2
    pts = parse(sys.argv[1])
    if not pts:
        print("no coverage points found in", sys.argv[1], file=sys.stderr)
        return 1

    tot = defaultdict(int)
    hit = defaultdict(int)
    misses = defaultdict(list)
    for fname, line, page, count in pts:
        b = bucket(fname)
        if b is None:
            continue
        k = kind(page)
        if k == "other":
            continue
        tot[(b, k)] += 1
        if count > 0:
            hit[(b, k)] += 1
        else:
            misses[(b, k)].append(f"{fname}:{line}")

    print("=" * 62)
    print(f"{'scope':<16}{'kind':<10}{'hit':>8}{'total':>8}{'pct':>10}")
    print("-" * 62)
    overall_ok = True
    for b in DIRS:
        for k in ("line", "toggle"):
            t, h = tot[(b, k)], hit[(b, k)]
            if t == 0:
                continue
            pct = 100.0 * h / t
            flag = "" if pct >= 95.0 else "  << below 95%"
            if pct < 95.0:
                overall_ok = False
            print(f"{b:<16}{k:<10}{h:>8}{t:>8}{pct:>9.2f}%{flag}")
    print("=" * 62)

    for (b, k), lst in sorted(misses.items()):
        if not lst:
            continue
        print(f"\nuncovered {k} points in {b} ({len(lst)}):")
        for item in sorted(set(lst))[:60]:
            print("  ", item)
        if len(set(lst)) > 60:
            print(f"   ... and {len(set(lst)) - 60} more")

    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())
