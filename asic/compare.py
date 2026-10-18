"""Compare LibreLane runs saved under asic/results/<tag>/metrics.json.

    python3 asic/compare.py                  # every run in asic/results/
    python3 asic/compare.py tagA tagB ...    # selected runs, in this order
    python3 asic/compare.py --md ...         # Markdown table (for docs)
"""

import json
import sys
from pathlib import Path

RESULTS = Path(__file__).resolve().parent / "results"

CORNERS = [("tt", "nom_tt_025C_1v80"), ("ss", "nom_ss_100C_1v60"), ("ff", "nom_ff_n40C_1v95")]

# (label, metric key or function, format)
ROWS = [
    ("Std-cell area (um^2)",       "design__instance__area__stdcell",                    "{:,.0f}"),
    ("  sequential (um^2)",        "design__instance__area__class:sequential_cell",      "{:,.0f}"),
    ("  combinational (um^2)",     "design__instance__area__class:multi_input_combinational_cell", "{:,.0f}"),
    ("  timing-repair buf (um^2)", "design__instance__area__class:timing_repair_buffer", "{:,.0f}"),
    ("Die area (mm^2)",            lambda m: m.get("design__die__area", 0) / 1e6,        "{:.3f}"),
    ("Std cells",                  "design__instance__count__stdcell",                   "{:,}"),
    ("Flip-flops",                 "design__instance__count__class:sequential_cell",     "{:,}"),
] + [
    (f"Setup WNS {c} (ns)", f"timing__setup__ws__corner:{k}", "{:+.2f}") for c, k in CORNERS
] + [
    (f"Hold WNS {c} (ns)",  f"timing__hold__ws__corner:{k}",  "{:+.2f}") for c, k in CORNERS
] + [
    ("Setup TNS ss (ns)",          "timing__setup__tns__corner:nom_ss_100C_1v60",        "{:.1f}"),
    ("Fmax ss (MHz)",              lambda m: fmax(m, "nom_ss_100C_1v60"),                "{:.0f}"),
    ("Fmax tt (MHz)",              lambda m: fmax(m, "nom_tt_025C_1v80"),                "{:.0f}"),
    ("Max-slew violations",        "design__max_slew_violation__count",                  "{:,}"),
    ("Max-cap violations",         "design__max_cap_violation__count",                   "{:,}"),
    ("Max-fanout violations",      "design__max_fanout_violation__count",                "{:,}"),
    ("Hold buffers",               "design__instance__count__hold_buffer",               "{:,}"),
    ("Power, typical (mW)",        lambda m: m.get("power__total", 0) * 1e3,             "{:.2f}"),
    ("Magic DRC errors",           "magic__drc_error__count",                            "{}"),
    ("KLayout DRC errors",         "klayout__drc_error__count",                          "{}"),
    ("LVS errors",                 "design__lvs_error__count",                           "{}"),
]


def fmax(m, corner):
    """Max frequency implied by the setup slack at a corner, for the run's clock period."""
    ws = m.get(f"timing__setup__ws__corner:{corner}")
    period = m.get("_clock_period")
    if ws is None or not period:
        return None
    return 1e3 / (period - ws)


def load(tag):
    d = RESULTS / tag
    m = json.loads((d / "metrics.json").read_text())
    try:
        m["_clock_period"] = json.loads((d / "resolved.json").read_text())["CLOCK_PERIOD"]
    except (OSError, KeyError, ValueError):
        m["_clock_period"] = None
    return m


def cell(m, key, fmt):
    v = key(m) if callable(key) else m.get(key)
    if v is None:
        return "-"
    try:
        return fmt.format(v)
    except (ValueError, TypeError):
        return str(v)


def main(argv):
    md = "--md" in argv
    tags = [a for a in argv if a != "--md"] or sorted(p.name for p in RESULTS.iterdir()
                                                       if (p / "metrics.json").exists())
    runs = [(t, load(t)) for t in tags]
    if md:
        print("| Metric | " + " | ".join(f"`{t}`" for t, _ in runs) + " |")
        print("|---|" + "---:|" * len(runs))
        for label, key, fmt in ROWS:
            print(f"| {label.strip()} | " + " | ".join(cell(m, key, fmt) for _, m in runs) + " |")
    else:
        w = max(14, *(len(t) for t in tags)) + 2
        print(f"{'':28s}" + "".join(f"{t:>{w}s}" for t in tags))
        for label, key, fmt in ROWS:
            print(f"{label:28s}" + "".join(f"{cell(m, key, fmt):>{w}s}" for _, m in runs))


if __name__ == "__main__":
    main(sys.argv[1:])
