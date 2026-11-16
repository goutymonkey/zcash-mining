#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=${BUILD:-build/link-bist}
[[ "$build" =~ ^build/[a-zA-Z0-9_-]+$ ]] || { echo 'Use a simple fresh build/ directory'; exit 1; }
mkdir "$build"
python3 - "$build" "${LINK_SOURCE:-rtl/zeq_link.v}" <<'PY'
import hashlib,json,sys
from pathlib import Path
b=Path(sys.argv[1]); files=['rtl/zeq_link.v','rtl/zeq_uart.v','rtl/zeq_fifo.v',
 'rtl/zeq_ram.v','rtl/zeq_mbist.v','tb/tb_link_bist.sv','tb/run_link_bist.sh']
for name in files:
 source=Path(sys.argv[2]) if name=='rtl/zeq_link.v' else Path(name)
 dest=b/'source'/name;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(source.read_bytes())
(b/'inputs.json').write_text(json.dumps({'files':{n:hashlib.sha256((b/'source'/n).read_bytes()).hexdigest() for n in files},
 'link_source':sys.argv[2],'scope':'UART-level link with delayed/sticky BIST completion model; no SRAM macro fault qualification'},indent=2)+'\n')
PY
trap 'code=$?; printf "%s\n" "$code" > "$build/exit_code"' EXIT
docker image inspect --format '{{.Id}}' verilator/verilator:latest > "$build/verilator-image-id.txt"
code=0
docker run --rm -u "$(id -u):$(id -g)" -e CCACHE_DISABLE=1 -v "$PWD":/work -w /work \
 --entrypoint /bin/bash verilator/verilator:latest -ec '
 b=$1
 legacy=()
 if [ "$2" = 1 ]; then legacy=(-DLEGACY_LINK); fi
 verilator --binary --timing -j 2 -Wall --timescale 1ns/1ps \
  -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PROCASSINIT -Wno-BLKSEQ -Wno-PINCONNECTEMPTY \
  --top-module tb_link_bist -GHAS_BIST="$3" "${legacy[@]}" --Mdir "$b/obj" -o sim \
  "$b/source/rtl/zeq_mbist.v" "$b/source/rtl/zeq_ram.v" "$b/source/rtl/zeq_uart.v" \
  "$b/source/rtl/zeq_fifo.v" "$b/source/rtl/zeq_link.v" "$b/source/tb/tb_link_bist.sv" \
  > "$b/compile.log" 2>&1
 "$b/obj/sim" > "$b/simulation.log" 2>&1
 ' link-bist "$build" "${EXPECT_OVERLAP:-0}" "${HAS_BIST:-1}" > "$build/runner.log" 2>&1 || code=$?
python3 - "$build" "$code" "${EXPECT_OVERLAP:-0}" "${HAS_BIST:-1}" <<'PY'
import hashlib,json,sys
from pathlib import Path
b=Path(sys.argv[1]);code=int(sys.argv[2]);negative=sys.argv[3]=='1';log=b/'simulation.log'
body=log.read_text() if log.exists() else ''
passed=(code!=0 and 'mining started while memory BIST active' in body) if negative else (code==0 and 'link BIST interlock PASS' in body)
result={'status':'PASS' if passed else 'FAIL','HAS_BIST':int(sys.argv[4]),'check':'reproduced BIST/JOB overlap' if negative else 'UART BIST ownership and job scheduling',
 'simulation_exit_code':code,'evidence_sha256':{n:hashlib.sha256((b/n).read_bytes()).hexdigest() for n in ['inputs.json','verilator-image-id.txt','compile.log','runner.log','simulation.log'] if (b/n).exists()}}
(b/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(result['check']+': '+result['status'])
raise SystemExit(0 if passed else 1)
PY
