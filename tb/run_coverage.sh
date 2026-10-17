#!/usr/bin/env bash
# Run every RTL testbench under Verilator with coverage, merge, and annotate.
#
#   ./run_coverage.sh            -> tb/coverage/summary.txt   (per-module report, waivers applied)
#                                   tb/coverage/annotated/*.v  (per-line hit counts;
#                                   lines never executed are marked '%000000')
# Includes the 720p stress test (STRESS=1), which only runs here.
# Needs Verilator >= 5.036 (cocotb 2.x) on PATH and the cocotb venv active.
set -euo pipefail
cd "$(dirname "$0")"

OUT=coverage
mkdir -p "$OUT/runs"

for t in skid window datapath regs top; do
    echo "== $t"
    (cd "$t" && STRESS=1 make SIM=verilator SIM_BUILD=sim_build_cov \
        EXTRA_ARGS="--coverage -Wno-fatal" > "../$OUT/runs/$t.log" 2>&1) || true
    grep -oE "TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+" "$OUT/runs/$t.log" || echo "   (no test summary, see $OUT/runs/$t.log)"
    mv "$t/coverage.dat" "$OUT/runs/$t.dat"
done

verilator_coverage --write "$OUT/merged.dat" "$OUT"/runs/*.dat
verilator_coverage --annotate "$OUT/annotated" --annotate-min 1 "$OUT/merged.dat" > /dev/null
python3 coverage_report.py "$OUT/merged.dat" | tee "$OUT/summary.txt"
