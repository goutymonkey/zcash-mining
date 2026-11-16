#!/usr/bin/env bash
# Harden a block with LibreLane (SKY130A, sky130_fd_sc_hd) in Docker.
#   ./run_flow.sh <block dir> [librelane args]   e.g. ./run_flow.sh blake2b
#   resume a killed run:  ./run_flow.sh tc --from OpenROAD.STAMidPNR
# The PDK is fetched into ./pdk on first use.
set -euo pipefail
cd "$(dirname "$0")"
BLOCK=${1:?block dir}; shift
if [ $# -gt 0 ]; then RUNARGS=(--last-run "$@"); else RUNARGS=(--run-tag latest --overwrite); fi
IMAGE=ghcr.io/librelane/librelane:3.0.14
mkdir -p pdk
docker run --rm -u "$(id -u):$(id -g)" \
    -e HOME=/tmp -e PDK_ROOT=/work/pd/pdk \
    -v "$(cd .. && pwd)":/work -w "/work/pd/$BLOCK" \
    "$IMAGE" librelane --pdk-root /work/pd/pdk --pdk sky130A \
    "${RUNARGS[@]}" config.json
