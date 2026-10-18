"""Per-module coverage report from a merged Verilator coverage.dat.

Verilator records a separate point for every instance of a module, so a line
hit in the block-level testbench but not inside conv_engine (or vice versa)
would otherwise count as missed. This report merges points by source
location and point name, ignoring hierarchy: a point is covered if any
testbench hit it in any instance.

Points that can never be hit by construction are waived, each with a reason.

Usage: python3 coverage_report.py merged.dat
"""

import re
import sys
from collections import defaultdict

# (file, point-name regex, reason). Matched against the point's comment text.
WAIVERS = [
    ("conv_regs.v",     r"^s_axi_[br]resp\[",          "responses are always OKAY (2'b00) by design"),
    ("conv_engine.v",   r"^s_axi_ctrl_[br]resp\[",     "responses are always OKAY (2'b00) by design"),
    ("conv_regs.v",     r"^shift\[[4-7]\]",            "unused SHIFT bits, masked to 0 on write"),
    ("conv_regs.v",     r"^(s_axi_rdata|rd_mux)\[(26|27|28|29|31)\]",
                                                       "no register or the ID has these bits set"),
    ("conv_engine.v",   r"^s_axi_ctrl_rdata\[(26|27|28|29|31)\]",
                                                       "no register or the ID has these bits set"),
    ("conv_datapath.v", r"^rnd[01]\[(1[5-9])\]",       "rounding constant is at most 2^14 (shift <= 15)"),
    ("conv_datapath.v", r"^abs[01]\[19\]",             "|lane| <= 310,144 < 2^19, so bit 19 is always 0"),
    ("luma_axis.v",     r"^g1\[0\]",                   "150*G is always even, so bit 0 is always 0"),
    ("conv_window.v",   r"^\((s_user|s_valid)==0 && .* && r_zero==1 && c_zero==1\) => 0$",
                                                       "at position (0,0) the start-of-frame beat is still held "
                                                       "(AXI4-Stream), so s_valid=1 and s_user=1"),
    ("luma_axis.v",     r"^rb1\[15\]",                 "77*R + 29*B <= 26,010 < 2^15, so bit 15 is always 0"),
]


def parse(path):
    """Yield (file, line, type, name, count) for every point in a coverage.dat."""
    for raw in open(path, encoding="latin-1"):
        if not raw.startswith("C "):
            continue
        m = re.match(r"C '(.*)' (\d+)\s*$", raw)
        if not m:
            continue
        fields = dict(kv.split("\x02", 1) for kv in m.group(1).split("\x01") if "\x02" in kv)
        yield (fields.get("f", "?").split("/")[-1], int(fields.get("l", 0)),
               fields.get("t", "?"), fields.get("o", ""), int(m.group(2)))


def main(path):
    points = defaultdict(int)            # (file, line, type, name) -> total hits over all instances
    for f, line, typ, name, cnt in parse(path):
        points[(f, line, typ, name)] += cnt

    def waiver(f, name):
        for wf, pattern, reason in WAIVERS:
            if f == wf and re.search(pattern, name):
                return reason
        return None

    stats = defaultdict(lambda: [0, 0, 0])   # (file, type) -> [hit, total, waived]
    missed, waived = [], defaultdict(int)
    for (f, line, typ, name), cnt in points.items():
        reason = waiver(f, name) if cnt == 0 else None
        s = stats[(f, typ)]
        if reason:
            s[2] += 1
            waived[(f, reason)] += 1
            continue
        s[1] += 1
        if cnt:
            s[0] += 1
        else:
            missed.append((f, line, typ, name))

    types = ["line", "branch", "expr", "toggle"]
    files = sorted({f for f, _ in stats})
    print(f"{'module':18s}" + "".join(f"{t:>16s}" for t in types))
    tot = defaultdict(lambda: [0, 0])
    for f in files:
        row = f"{f:18s}"
        for t in types:
            hit, total, _ = stats.get((f, t), [0, 0, 0])
            tot[t][0] += hit
            tot[t][1] += total
            row += f"{f'{hit}/{total}':>10s} {100 * hit / total:4.0f}%" if total else f"{'-':>16s}"
        print(row)
    print(f"{'TOTAL':18s}" + "".join(
        f"{f'{h}/{n}':>10s} {100 * h / n:4.0f}%" if n else f"{'-':>16s}" for h, n in (tot[t] for t in types)))

    print(f"\nWaived points ({sum(waived.values())}):")
    for (f, reason), n in sorted(waived.items()):
        print(f"  {f:16s} {n:3d}  {reason}")

    print(f"\nUncovered points ({len(missed)}):")
    for f, line, typ, name in sorted(missed):
        print(f"  {f}:{line:<4d} {typ:7s} {name}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "coverage/merged.dat")
