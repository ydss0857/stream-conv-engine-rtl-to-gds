#!/usr/bin/env bash
# Run conv_engine through LibreLane in a Linux-side work directory and copy the
# key results back into the repo.
#
#   asic/run_flow.sh <tag> [-c KEY=VALUE ...]
#
#   e.g. asic/run_flow.sh w128_80mhz
#        asic/run_flow.sh w256_80mhz -c SYNTH_PARAMETERS=MAX_WIDTH=256,AW=8
#        (list values are comma-separated, not JSON)
#
# Work dir : ~/asic_work/<tag>/   (full run, including GDS; not in git)
# Results  : asic/results/<tag>/  (metrics, timing/power reports, synth stats, layout render)
#
# Runs live on the Linux filesystem because a flow writes thousands of files;
# on /mnt/c the first run took 80 minutes.
#
# Each run is capped at MAX_RUNTIME (default 90m). On timeout the whole process
# group (LibreLane, OpenROAD, ...) is stopped, partial results are still copied
# back, and the script exits with status 124.
set -euo pipefail

TAG=${1:?usage: run_flow.sh <tag> [-c KEY=VALUE ...]}
shift
REPO=$(cd "$(dirname "$0")/.." && pwd)
LIBRELANE=${LIBRELANE:-$HOME/src/librelane-3.0.16}
MAX_RUNTIME=${MAX_RUNTIME:-90m}
WORK=$HOME/asic_work/$TAG
OUT=$REPO/asic/results/$TAG

mkdir -p "$WORK/rtl" "$WORK/asic/conv_engine"
cp "$REPO"/rtl/*.v "$WORK/rtl/"
cp "$REPO"/asic/conv_engine/{config.yaml,*.sdc} "$WORK/asic/conv_engine/"

ARGS=""
for a in "$@"; do ARGS+=" $(printf '%q' "$a")"; done

cd "$LIBRELANE"
set +e
timeout --kill-after=2m "$MAX_RUNTIME" \
    nix-shell --run "cd $WORK/asic/conv_engine && librelane --run-tag $TAG --overwrite$ARGS config.yaml" \
    > "$WORK/flow.log" 2>&1
STATUS=$?
if [ $STATUS -eq 124 ] || [ $STATUS -eq 137 ]; then
    echo "TIMEOUT: run exceeded $MAX_RUNTIME and was stopped" | tee -a "$WORK/flow.log"
    STATUS=124
fi
set -e

RUN=$WORK/asic/conv_engine/runs/$TAG
mkdir -p "$OUT"
tail -300 "$WORK/flow.log" > "$OUT/flow.log" 2>/dev/null || true
cp "$RUN/resolved.json" "$OUT/" 2>/dev/null || true
cp "$RUN/final/metrics.json" "$RUN/final/metrics.csv" "$OUT/" 2>/dev/null || true
cp "$RUN"/*-yosys-synthesis/reports/stat.rpt "$OUT/synth_stat.rpt" 2>/dev/null || true
cp "$RUN"/final/render/*.png "$OUT/" 2>/dev/null || true
STA=$(ls -d "$RUN"/*-openroad-stapostpnr 2>/dev/null | tail -1)
if [ -n "$STA" ]; then
    for c in nom_tt_025C_1v80 nom_ss_100C_1v60 nom_ff_n40C_1v95; do
        mkdir -p "$OUT/sta/$c"
        cp "$STA/$c"/{power.rpt,skew.max.rpt,skew.min.rpt} "$OUT/sta/$c/" 2>/dev/null || true
        for r in max min checks; do          # full reports are tens of MB: keep the worst paths
            head -400 "$STA/$c/$r.rpt" > "$OUT/sta/$c/$r.rpt" 2>/dev/null || true
        done
    done
fi
echo "flow exit status: $STATUS (results in asic/results/$TAG)"
exit $STATUS
