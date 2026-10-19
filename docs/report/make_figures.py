"""Figures for the technical reports, generated from asic/results/*/metrics.json.

    python3 docs/report/make_figures.py      # writes docs/report/fig_*.png
"""

import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / "asic" / "results"
OUT = Path(__file__).resolve().parent

# Reference palette (validated: scripts/validate_palette.js, light mode)
BLUE, ORANGE = "#2a78d6", "#eb6834"
INK, INK2, GRID, SURF = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"

plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 8.5,
    "axes.edgecolor": INK2, "axes.labelcolor": INK2, "axes.titlecolor": INK,
    "axes.titlesize": 9.5, "axes.titleweight": "bold", "axes.titlelocation": "left",
    "xtick.color": INK2, "ytick.color": INK2, "axes.grid": True, "grid.color": GRID,
    "grid.linewidth": 0.7, "axes.spines.top": False, "axes.spines.right": False,
    "figure.facecolor": SURF, "axes.facecolor": SURF, "legend.frameon": False,
    "lines.linewidth": 2, "lines.markersize": 6,
})


def m(tag):
    return json.loads((RES / tag / "metrics.json").read_text())


def ss(tag, kind):
    return m(tag)[f"timing__{kind}__corner:nom_ss_100C_1v60"]


def timing_closure():
    runs = ["w128_100mhz_v1", "w128_100mhz_v2", "w128_100mhz_v3", "w128_80mhz_v4b",
            "w128_80mhz_v5", "w128_80mhz_v6", "w128_80mhz_v7"]
    labels = ["v1", "v2", "v3", "v4b", "v5", "v6", "v7"]
    x = np.arange(len(runs))
    setup = [ss(r, "setup__ws") for r in runs]
    hold = [ss(r, "hold__ws") for r in runs]
    tns = [-ss(r, "setup__tns") for r in runs]

    fig, (a, b) = plt.subplots(1, 2, figsize=(7.2, 2.7), gridspec_kw={"wspace": 0.32})
    a.axhline(0, color=INK2, lw=1, ls="--")
    a.axvspan(2.5, 6.5, color="#f1f0ec", zorder=0, lw=0)
    a.plot(x, setup, color=BLUE, marker="o", label="setup")
    a.plot(x, hold, color=ORANGE, marker="s", label="hold")
    a.text(1.0, 1.25, "100 MHz target", ha="center", color=INK2, fontsize=7.5)
    a.text(4.5, 1.25, "80 MHz target", ha="center", color=INK2, fontsize=7.5)
    a.annotate("hold closed (v5)", (4, hold[4]), (4.2, -0.75), color=INK2, fontsize=7.5,
               arrowprops=dict(arrowstyle="-", color=INK2, lw=0.8))
    a.set_xticks(x, labels)
    a.set_ylim(-4, 1.6)
    a.set_ylabel("worst slack at ss corner (ns)")
    a.set_title("Worst slack, slow corner (100 °C, 1.60 V)")
    a.legend(loc="lower left", ncol=2)

    bars = b.bar(x, tns, color=BLUE, width=0.6)
    b.set_yscale("log")
    b.set_ylim(5, 8000)
    b.set_xticks(x, labels)
    for xi, v in zip(x, tns):
        b.text(xi, v * 1.25, f"{v:,.0f}", ha="center", color=INK, fontsize=7.5)
    b.set_ylabel("total negative setup slack (ns, log)")
    b.set_title("Total setup violation, slow corner")
    b.grid(axis="x", visible=False)
    fig.savefig(OUT / "fig_timing_closure.png", dpi=220, bbox_inches="tight")


def width_sweep():
    tags = {64: "w64_80mhz", 128: "w128_80mhz_v7", 256: "w256_80mhz", 512: "w512_80mhz"}
    W = np.array(sorted(tags))
    area = np.array([m(tags[w])["design__instance__area__stdcell"] for w in W]) / 1e3
    period = 12.5
    fss = np.array([1e3 / (period - ss(tags[w], "setup__ws")) for w in W])
    ftt = np.array([1e3 / (period - m(tags[w])["timing__setup__ws__corner:nom_tt_025C_1v80"]) for w in W])
    k, c = np.polyfit(W, area, 1)
    hs = m("hs_w128_80mhz")
    hs_ss = 1e3 / (period - hs["timing__setup__ws__corner:nom_ss_100C_1v60"])

    fig, (a, b) = plt.subplots(1, 2, figsize=(7.2, 2.7), gridspec_kw={"wspace": 0.32})
    xs = np.linspace(0, 560, 50)
    a.plot(xs, c + k * xs, color=INK2, lw=1, ls="--", zorder=1)
    a.plot(W, area, color=BLUE, marker="o", lw=0, zorder=2)
    a.fill_between(xs, c, c + k * xs, color=BLUE, alpha=0.08, lw=0)
    a.fill_between(xs, 0, c, color="#f1f0ec", lw=0)
    a.text(330, c / 2, "fixed logic", color=INK2, fontsize=7.5, va="center")
    a.text(330, c + k * 330 - 140, "line buffers", color=BLUE, fontsize=7.5)
    a.text(20, 640, f"area = {c:,.0f} + {k:.3f}·W  (×10³ µm²)", color=INK, fontsize=7.5)
    a.set_xlim(0, 560)
    a.set_ylim(0, 720)
    a.set_xticks(W)
    a.set_xlabel("line-buffer width W (pixels)")
    a.set_ylabel("std-cell area (×10³ µm²)")
    a.set_title("Area vs line-buffer width (sky130 hd)")

    b.axhline(74.25, color=INK2, lw=1, ls="--")
    b.text(520, 77, "720p60 needs 74.25 MHz", ha="right", color=INK2, fontsize=7.5)
    b.plot(W, ftt, color=BLUE, marker="o", label="typical (tt)")
    b.plot(W, fss, color=ORANGE, marker="s", label="slow (ss)")
    b.plot([128], [hs_ss], marker="D", ms=7, mfc=SURF, mec=ORANGE, mew=2, lw=0)
    b.annotate("hs library, ss", (128, hs_ss), (175, 92), color=INK2, fontsize=7.5,
               arrowprops=dict(arrowstyle="-", color=INK2, lw=0.8))
    b.set_xticks(W)
    b.set_xlim(40, 540)
    b.set_ylim(40, 140)
    b.set_xlabel("line-buffer width W (pixels)")
    b.set_ylabel("estimated Fmax (MHz)")
    b.set_title("Fmax vs line-buffer width")
    b.legend(loc="upper right")
    fig.savefig(OUT / "fig_width_sweep.png", dpi=220, bbox_inches="tight")


def arch():
    """Block diagram of conv_engine."""
    fig, ax = plt.subplots(figsize=(7.2, 1.75))
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 24)
    ax.axis("off")
    # (x0, width, text, highlighted)
    blocks = [(0, 12, "AXI4-Stream\nvideo in\n24-bit RGB", False), (14, 6, "skid", False),
              (22, 10, "luma\n2 stages", False), (34, 6, "skid", False),
              (42, 15, "window gen.\n2 line buffers\n3×3 window", True), (59, 6, "skid", False),
              (67, 16, "MAC datapath\n2 lanes × 9 mult\n8 stages + FIFO", True),
              (85, 15, "skid →\nvideo out", False)]
    for x0, w, text, key in blocks:
        ax.add_patch(plt.Rectangle((x0, 9), w, 11, fc="#e8f0fb" if key else "#f1f0ec",
                                   ec=BLUE if key else INK2, lw=1.2))
        ax.text(x0 + w / 2, 14.5, text, ha="center", va="center", fontsize=6.8, color=INK)
    for (x0, w, _, _), (x1, _, _, _) in zip(blocks, blocks[1:]):
        ax.annotate("", (x1, 14.5), (x0 + w, 14.5), arrowprops=dict(arrowstyle="->", color=INK2, lw=1))
    ax.add_patch(plt.Rectangle((38, 1), 49, 5, fc="#f1f0ec", ec=INK2, lw=1))
    ax.text(62.5, 3.5, "AXI4-Lite registers (kernels, mode, threshold, frame size)", ha="center",
            va="center", fontsize=6.8, color=INK)
    for xc in (49.5, 75):
        ax.annotate("", (xc, 9), (xc, 6), arrowprops=dict(arrowstyle="->", color=INK2, lw=1))
    fig.savefig(OUT / "fig_architecture.png", dpi=220, bbox_inches="tight")


if __name__ == "__main__":
    arch()
    timing_closure()
    width_sweep()
    print("wrote", sorted(p.name for p in OUT.glob("fig_*.png")))
