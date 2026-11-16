#!/usr/bin/env bash
# Exact-run equivalence. No default config or mtime-based netlist cache.
# RUN=pd/wrapper/runs/d SOURCE_MANIFEST=build/plan-d-source/manifest.json \
#   formal/cec/chip.sh <gate netlist> <new workdir>
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${RUN:?set RUN to the physical run}"
: "${SOURCE_MANIFEST:?set SOURCE_MANIFEST to its archived source manifest}"
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/work -w /work \
    --entrypoint python3 ghcr.io/librelane/librelane:3.0.14 formal/cec/chip.py \
    --run "$RUN" --source-manifest "$SOURCE_MANIFEST" \
    --gate "${1:?gate netlist}" --build "${2:?fresh workdir}" --timeout "${LEC_TIMEOUT:-1800}"
