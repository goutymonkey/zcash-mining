#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
n=${N:-48}; k=5; bb=4; pb=2; sb=7; slots=80
staged=${STAGED_NETWORK:-0}
if [ "$n" = 200 ]; then k=9; bb=12; pb=4; sb=10; slots=640; fi
build=${BUILD:-build/core-control$n}
[[ "$build" =~ ^build/[a-zA-Z0-9_-]+$ ]] || { echo 'BUILD must be a simple build/ subdirectory'; exit 1; }
mkdir "$build"
python3 - "$build" "$n" "$k" "$bb" "$pb" "$sb" "$slots" "$staged" <<'SNAPSHOT'
import hashlib,json,sys,tarfile
from pathlib import Path
b=Path(sys.argv[1]);files=[Path('tb/run_core_control.sh'),Path('tb/tb_core_control.sv'),*sorted(Path('rtl').glob('*.v')),*sorted(Path('model').glob('*.py'))]
with tarfile.open(b/'source.tgz','w:gz') as tar:
 for f in files: tar.add(f,arcname=str(f))
(b/'inputs.json').write_text(json.dumps({'parameters':dict(zip(['N','K','BB','PB','SB','SLOTS','STAGED_NETWORK'],map(int,sys.argv[2:]))),'PACKED_TABLES':1,'SHARE_FILTER':1,'source_sha256':hashlib.sha256((b/'source.tgz').read_bytes()).hexdigest(),'files':{str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}},indent=2)+'\n')
SNAPSHOT
trap 'code=$?; printf "%s\n" "$code" > "$build/exit_code"' EXIT
docker image inspect --format '{{.Id}}' verilator/verilator:latest > "$build/verilator-image-id.txt"
python3 model/core_control.py prepare "$build" --n "$n" --k "$k" --bb "$bb" --slots "$slots"
docker run --rm -u "$(id -u):$(id -g)" -e CCACHE_DISABLE=1 -v "$PWD":/work -w /work \
    verilator/verilator:latest --binary --timing -j 2 -Wall --timescale 1ns/1ps \
    -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY -Wno-PROCASSINIT -Wno-BLKSEQ \
    --top-module tb_core_control -GN="$n" -GK="$k" -GBB="$bb" -GPB="$pb" -GSB="$sb" -GSLOTS="$slots" -GSTAGED_NETWORK="$staged" \
    --Mdir "$build/obj" -o simulation \
    rtl/zeq_blake2b.v rtl/zeq_eh_hash.v rtl/zeq_sfifo.v rtl/zeq_eh_solver3.v rtl/zeq_mbist.v rtl/zeq_ram.v \
    rtl/zeq_xbar_arb.v rtl/zeq_row_network.v rtl/zeq_packed_values.v rtl/zeq_eh_par.v rtl/zeq_sha256.v rtl/zeq_share.v \
    rtl/zeq_tables_sram.v rtl/zeq_fifo.v rtl/zeq_uart.v rtl/zeq_link.v rtl/zeq200_core.v rtl/zeq200x.v tb/tb_core_control.sv \
    > "$build/compile.log" 2>&1
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/work -w "/work/$build" \
    --entrypoint "/work/$build/obj/simulation" verilator/verilator:latest > "$build/simulation.log" 2>&1
python3 -u model/core_control.py check "$build" --n "$n" --k "$k" --bb "$bb" --slots "$slots" > "$build/check.log" 2>&1
