#!/usr/bin/env bash
# Diagnostic/repair qualification. Fresh output preserves failures and provenance.
set -euo pipefail
cd "$(dirname "$0")/.."
build=${BUILD:-build/repair-bank-v1}
[[ "$build" =~ ^build/[a-zA-Z0-9_/-]+$ ]] || { echo 'BUILD must be under build/'; exit 1; }
mkdir "$build"
python3 - "$build" <<'PY'
import hashlib,json,sys,tarfile
from pathlib import Path
b=Path(sys.argv[1])
files=['rtl/zeq_mbist.v','rtl/zeq_repair_bank.v','tb/tb_repair_bank.sv',
       'tb/tb_mbist.sv','tb/run_repair_bank.sh','run.sh']
with tarfile.open(b/'source.tgz','w:gz') as tar:
 for p in files:tar.add(p,arcname=p)
(b/'inputs.json').write_text(json.dumps({'files':{p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in files},
 'archive_sha256':hashlib.sha256((b/'source.tgz').read_bytes()).hexdigest(),
 'scope':'Generic 1W1R physical-memory model; one spare row. No compiler macro, fuse or chip-wide DFT qualification.'},indent=2)+'\n')
PY
trap 'code=$?; printf "%s\n" "$code" > "$build/exit_code"' EXIT
docker image inspect --format '{{.Id}}' verilator/verilator:latest > "$build/verilator-image-id.txt"
docker run --rm -u "$(id -u):$(id -g)" -e CCACHE_DISABLE=1 -v "$PWD":/work -w /work \
    --entrypoint /bin/bash verilator/verilator:latest -ec '
    for cfg in "1 8 1" "3 13 5" "6 32 64"; do
        read -r aw dw depth <<< "$cfg"
        case_dir="$1/depth$depth"
        mkdir "$case_dir"
        verilator --binary --timing -j 2 -Wall --timescale 1ns/1ps \
            -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PROCASSINIT \
            --top-module tb_repair_bank -GAW="$aw" -GDW="$dw" -GDEPTH="$depth" \
            --Mdir "$case_dir/obj" -o sim \
            rtl/zeq_mbist.v rtl/zeq_repair_bank.v tb/tb_repair_bank.sv \
            > "$case_dir/compile.log" 2>&1
        "$case_dir/obj/sim" > "$case_dir/simulation.log" 2>&1
        cat "$case_dir/simulation.log"
    done
    ' repair-bank "$build" > "$build/matrix.log" 2>&1
BUILD="$build/mbist" ./run.sh mbist > "$build/mbist.log" 2>&1
python3 - "$build" <<'PY'
import hashlib,json,sys
from pathlib import Path
b=Path(sys.argv[1]); logs=[b/f'depth{d}/simulation.log' for d in (1,5,64)]+[b/'mbist.log']
assert all('repair bank PASS' in p.read_text() for p in logs[:3])
assert 'tb_mbist PASS' in logs[-1].read_text()
(b/'result.json').write_text(json.dumps({'status':'PASS','depths':[1,5,64],
 'coverage':['first failure address/data/element','multiple faulty rows','repair and disable','bad spare retest',
 'old-data read/write collision','registered read hold','busy/invalid configuration rejection','stale qualification invalidation','reset during BIST','five March C- fault classes'],
 'evidence_sha256':{str(p.relative_to(b)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [b/'inputs.json',b/'verilator-image-id.txt',*logs]}},indent=2)+'\n')
print('Memory diagnosis/repair qualification PASS')
PY
