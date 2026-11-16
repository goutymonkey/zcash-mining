#!/usr/bin/env bash
# Mainnet packed-table regression with regenerable compilation in tmpfs.
# Only source snapshots, logs and results consume persistent disk space.
set -euo pipefail
cd "$(dirname "$0")/.."
build=${BUILD:-build/packed200-ram}
nh=${NH:-4}
staged=${STAGED_NETWORK:-0}
[[ "$staged" = 0 || "$staged" = 1 ]] || exit 1
[[ "$build" =~ ^build/[a-zA-Z0-9_-]+$ ]] || { echo 'BUILD must be a simple build/ subdirectory'; exit 1; }
mkdir "$build"
python3 - "$build" "$nh" "$staged" <<'PY'
import hashlib,json,shutil,sys,tarfile
from pathlib import Path
import numpy
build=Path(sys.argv[1]); nh=int(sys.argv[2]); staged=int(sys.argv[3])
if shutil.disk_usage('.').free < 16*1024**2:
 raise SystemExit('Insufficient space for test evidence; compilation not started')
files=[Path('run.sh'), Path('tb/run_packed_mainnet.sh'), Path('tb/tb_par.sv'),*sorted(Path('rtl').rglob('*.v')),*sorted(Path('model').glob('*.py'))]
archive=build/'source.tgz'
with tarfile.open(archive,'w:gz') as tar:
 for p in files: tar.add(p,arcname=str(p))
manifest={'parameters':{'N':200,'K':9,'NH':nh,'BB':12,'PB':4,'SB':10,'SLOTS':640,'PACKED_TABLES':1,'SPLIT_KEYS':1,'COMPACT_VALUES':1,'BIST_FIRST':0,'STAGED_NETWORK':staged},'source_archive':str(archive),'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'files':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},'python':sys.version,'numpy':numpy.__version__,'compile_storage':'ephemeral container tmpfs; generated binaries are not retained'}
(build/'inputs.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
trap 'code=$?; printf "%s\n" "$code" > "$build/exit_code"' EXIT
python3 model/check_solver.py prepare 200 9 "$build" "$nh"
docker image inspect --format '{{.Id}}' verilator/verilator:latest > "$build/verilator-image-id.txt"
docker run --rm --name "${CONTAINER_NAME:-zeq-packed-mainnet-ram}" -u "$(id -u):$(id -g)" -e CCACHE_DISABLE=1 \
    --tmpfs /tmp:rw,exec,size=1073741824,mode=1777 -v "$PWD":/work -w /work \
    --entrypoint /bin/sh verilator/verilator:latest -ec '
    cp /bin/true /tmp/exec-probe
    /tmp/exec-probe
    verilator --binary --timing -j 2 -Wall --timescale 1ns/1ps \
      -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY -Wno-PROCASSINIT \
      --top-module tb_par -GN=200 -GK=9 -GNH="$2" -GBB=12 -GPB=4 -GSB=10 -GHPB=4 \
      -GSTAGED_NETWORK="$3" -GPACKED_TABLES=1 -GSPLIT_KEYS=1 -GCOMPACT_VALUES=1 -GSLOTS=640 \
      --Mdir /tmp/obj -o simulation \
      rtl/zeq_blake2b.v rtl/zeq_eh_hash.v rtl/zeq_mbist.v rtl/zeq_ram.v \
      rtl/zeq_xbar_arb.v rtl/zeq_row_network.v rtl/zeq_packed_values.v rtl/zeq_eh_par.v tb/tb_par.sv \
      > "/work/$1/compile.log" 2>&1
    cd "/work/$1"
    /tmp/obj/simulation
    ' packed-mainnet "$build" "$nh" "$staged" > "$build/simulation.log" 2>&1
PAR=12,640 python3 -u model/check_solver.py check 200 9 "$build" "$nh" > "$build/check.log" 2>&1
