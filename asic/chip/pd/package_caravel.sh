#!/usr/bin/env bash
# Collect the ZEQ-200-TC shuttle submission into ../../zeq200_caravel (a
# caravel_user_project checkout).
#
# The chip is hardened flat as user_project_wrapper (pd/wrapper): the 18
# SRAM macros and the standard cells sit directly in the wrapper, which is
# the usual arrangement for SRAM designs (a nested macro limited to met4
# power could not reach the SRAMs' met4 power pins).
#   ./package_caravel.sh sync   copy the Caravel wrapper sources and fixed
#                               pin template into pd/wrapper/src (run before
#                               ./run_flow.sh wrapper)
#   ./package_caravel.sh        RTL + hardened views into the Caravel project
# Then, in zeq200_caravel: make precheck && make run-precheck
set -euo pipefail
cd "$(dirname "$0")"
CUP=$(cd ../.. && pwd)/zeq200_caravel
[ -d "$CUP" ] || { echo "no caravel_user_project checkout at $CUP"; exit 1; }

if [ "${1:-}" = sync ]; then
    mkdir -p wrapper/src
    cp "$CUP/verilog/rtl/defines.v" "$CUP/verilog/rtl/user_project_wrapper.v" wrapper/src/
    cp "$CUP/openlane/user_project_wrapper/fixed_dont_change/user_project_wrapper.def" wrapper/src/
    echo "synced wrapper sources"; exit 0
fi

# Normal packaging always uses an explicit physical run and its source archive.
: "${RUN:?set RUN to the physical run (for example wrapper/runs/d)}"
: "${SOURCE_MANIFEST:?set SOURCE_MANIFEST relative to pd/ or as an absolute path}"
: "${LEC_DIR:?set LEC_DIR to passing equivalence evidence for the final netlist}"
: "${BUNDLE:?set BUNDLE to a fresh staging directory}"
python3 ./release_bundle.py --run "$RUN" --source-manifest "$SOURCE_MANIFEST" \
    --policy "${SIGNOFF_POLICY:-wrapper/signoff_policy.json}" --lec "$LEC_DIR" \
    --output "$BUNDLE" --install "$CUP"
echo "source-bound bundle installed from $BUNDLE; Caravel precheck remains required"
