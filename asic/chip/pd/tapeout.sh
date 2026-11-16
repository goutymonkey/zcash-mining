#!/usr/bin/env bash
# The last mile: signoff gate -> package -> Caravel precheck.
# Requires explicit RUN, SOURCE_MANIFEST, LEC_DIR and fresh BUNDLE paths.
# 1. refuses to package unless LibreLane's own signoff metrics are clean
#    (DRC Magic + KLayout, LVS, antenna, XOR, setup/hold at every corner,
#    max slew/cap)
# 2. source-bound signoff + final-netlist LEC -> verified bundle -> checkout
# 3. runs the shuttle's mpw_precheck (all checks, including Magic/KLayout
#    DRC and LVS) on ../../zeq200_caravel and prints the verdict
set -euo pipefail
cd "$(dirname "$0")"
: "${RUN:?set RUN to the exact physical run}"
M=$RUN/final/metrics.json
[ -f "$M" ] || { echo "no finished wrapper run ($M)"; exit 1; }
POLICY=${SIGNOFF_POLICY:-wrapper/signoff_policy.json}
python3 ./signoff_gate.py "$RUN" --policy "$POLICY"
RUN="$RUN" ./package_caravel.sh
CUP=$(cd ../.. && pwd)/zeq200_caravel
[ ! -e "$CUP/RELEASE_INCOMPLETE.json" ] || { echo "incomplete package installation"; exit 1; }
# Use the PDK selected by the run, never the first installed version.
PDKR=$(python3 - "$RUN/resolved.json" <<'PYDK'
import json, sys
from run_inputs import resolve_path
c = json.load(open(sys.argv[1]))
print(resolve_path(c["PDK_ROOT"]))
PYDK
)
# Preserve previous qualification evidence instead of deleting it.
mkdir -p "$CUP/precheck_results"
OUT=${PRECHECK_OUT:-$CUP/precheck_results/$(date -u +%Y%m%dT%H%M%SZ)}
mkdir "$OUT"
BUNDLE_HASH=$(python3 - "$CUP" <<'PYVERIFY'
import sys
from release_bundle import verify_bundle
print(verify_bundle(sys.argv[1]))
PYVERIFY
)
if docker run --rm -v "$HOME/mpw_precheck":/pc -v "$CUP":"$CUP" -v "$PDKR":"$PDKR" \
    -e INPUT_DIRECTORY="$CUP" -e PDK_PATH="$PDKR/sky130A" -e PDK_ROOT="$PDKR" -e CARAVEL_ROOT="$CUP/caravel" \
    -u "$(id -u):$(id -g)" efabless/mpw_precheck:latest \
    bash -c 'cd /pc && exec python3 mpw_precheck.py --input_directory "$1" --pdk_path "$2" --output_directory "$3"' \
    precheck "$CUP" "$PDKR/sky130A" "$OUT" > "$OUT/precheck.log" 2>&1; then
    PRECHECK_CODE=0
else
    PRECHECK_CODE=$?
fi
python3 - "$CUP" "$OUT" "$BUNDLE_HASH" "$PRECHECK_CODE" <<'PYRESULT'
import json, sys
from pathlib import Path
from release_bundle import verify_bundle
from run_inputs import digest
cup, out = Path(sys.argv[1]), Path(sys.argv[2])
body = (out / 'precheck.log').read_text()
unchanged = False
try:
    unchanged = verify_bundle(cup) == sys.argv[3]
except (OSError, ValueError, KeyError):
    pass
passed = int(sys.argv[4]) == 0 and unchanged and '{{SUCCESS}} All Checks Passed !!!' in body
result = dict(status='PASS' if passed else 'FAIL', exit_code=int(sys.argv[4]),
              release_manifest_sha256=sys.argv[3], package_unchanged=unchanged,
              log_sha256=digest(out / 'precheck.log'))
(out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print('PRECHECK: ' + result['status'] + ' (see ' + str(out) + ')')
sys.exit(0 if passed else 1)
PYRESULT
