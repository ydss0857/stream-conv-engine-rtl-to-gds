"""Placement map of a routed conv_engine: every flip-flop coloured by RTL block.

Synthesis flattens the design, so cell instance names lose their hierarchy,
but each flip-flop's output (Q) net keeps its RTL name (u_window.ic[0], dw[3],
...). This script maps flip-flops to blocks through those net names and plots
their placed positions from the final DEF; all other cells are drawn in grey.

    python3 asic/placement_map.py <final.def> <out.png> [title]
"""

import re
import sys
from collections import Counter, defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# (label, colour, regex on the Q net name); first match wins
GROUPS = [
    ("line buffers",        "#d62728", r"^u_window\.lb[12]\."),
    ("window generator",    "#ff7f0e", r"^(u_window\.|win)"),
    ("MAC datapath + FIFO", "#1f77b4", r"^(u_datapath\.|pix)"),
    ("register block",      "#2ca02c", r"^u_regs\.|^cfg_|^frame_err"),
    ("skid buffers",        "#9467bd", r"^(u_\w*skid\.|dw|wl|in_|m_axis)"),
    ("luma",                "#8c564b", r"^(u_luma\.|luma)"),
]


def parse_def(path):
    units, die = 1000.0, None
    comps = {}                    # inst -> (cell, x, y)
    q_net = {}                    # inst -> name of the net on its Q pin
    section = None
    buf = ""
    with open(path) as f:
        for line in f:
            s = line.strip()
            if s.startswith("UNITS DISTANCE MICRONS"):
                units = float(s.split()[3])
            elif s.startswith("DIEAREA"):
                n = list(map(int, re.findall(r"-?\d+", s)))
                die = (n[0] / units, n[1] / units, n[2] / units, n[3] / units)
            elif s.startswith("COMPONENTS"):
                section, buf = "C", ""
            elif s.startswith("NETS"):
                section, buf = "N", ""
            elif s.startswith("END "):
                section = None
            elif section:
                buf += " " + s
                if not s.endswith(";"):
                    continue
                stmt, buf = buf.strip(), ""
                if section == "C":
                    m = re.match(r"- (\S+) (\S+) .*?\+ (?:PLACED|FIXED) \( (-?\d+) (-?\d+) \)", stmt)
                    if m:
                        comps[m.group(1)] = (m.group(2), int(m.group(3)) / units, int(m.group(4)) / units)
                else:
                    m = re.match(r"- (\S+)", stmt)
                    if m:
                        net = m.group(1).replace("\\", "")
                        for inst in re.findall(r"\( (\S+) Q \)", stmt):
                            q_net[inst] = net
    return die, comps, q_net


def main(def_path, out_png, title="conv_engine"):
    die, comps, q_net = parse_def(def_path)
    pts = defaultdict(list)
    other = []
    for inst, (cell, x, y) in comps.items():
        if "__dfxtp" in cell or "__dfrtp" in cell or "__edfxtp" in cell:
            net = q_net.get(inst, "")
            for label, _, rx in GROUPS:
                if re.search(rx, net):
                    pts[label].append((x, y))
                    break
            else:
                pts["other flops"].append((x, y))
        elif not any(k in cell for k in ("__fill", "__decap", "__tap", "__diode")):
            other.append((x, y))

    fig, ax = plt.subplots(figsize=(7.2, 7.6))
    if other:
        xs, ys = zip(*other)
        ax.scatter(xs, ys, s=0.4, c="#cfcfcf", linewidths=0, label=f"logic & buffers ({len(other):,})")
    for label, colour, _ in GROUPS + [("other flops", "#7f7f7f", "")]:
        if pts.get(label):
            xs, ys = zip(*pts[label])
            ax.scatter(xs, ys, s=1.6, c=colour, linewidths=0, label=f"{label} ({len(pts[label]):,} flops)")
    if die:
        x0, y0, x1, y1 = die
        ax.add_patch(plt.Rectangle((x0, y0), x1 - x0, y1 - y0, fill=False, lw=1, ec="black"))
        ax.set_xlim(x0 - 5, x1 + 5)
        ax.set_ylim(y0 - 5, y1 + 5)
        ax.set_title(f"{title}: {x1 - x0:.0f} x {y1 - y0:.0f} um, sky130_fd_sc_hd", fontsize=10)
    ax.set_aspect("equal")
    ax.set_xlabel("um")
    ax.set_ylabel("um")
    ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.09), ncol=2, fontsize=7.5, markerscale=6, frameon=False)
    fig.tight_layout()
    fig.savefig(out_png, dpi=150)
    counts = Counter({k: len(v) for k, v in pts.items()})
    print("flops per block:", dict(counts.most_common()), "| other cells:", len(other))


if __name__ == "__main__":
    main(*sys.argv[1:])
