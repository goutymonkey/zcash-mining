#!/usr/bin/env bash
# prep.sh <netlist.v> <top> <out.blif> [scan]
# Flatten a SKY130 gate netlist to its liberty cell functions, cut it at
# the flip-flops (Q -> input, D -> output, matched by register name), and
# write a combinational BLIF for ABC's cec. With "scan", the scan ports
# are removed and scan_en/scan_in tied low first.
set -euo pipefail
NL=$1 TOP=$2 OUT=$3 MODE=${4:-}
SCAN=""
[ "$MODE" = scan ] && SCAN="delete -port $TOP/scan_en $TOP/scan_in $TOP/scan_out; connect -set scan_en 1'b0; connect -set scan_in 1'b0;"
yosys -q -l "$OUT.log" -p "
  read_liberty -ignore_miss_func pd/pdk/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
  read_verilog $NL
  hierarchy -top $TOP
  flatten
  $SCAN
  rename -hide w:_* w:net* w:clknet* w:*.* w:scan_q_*
  opt_clean -purge
  rename $TOP top
  expose -evert-dff
  opt_clean -purge
  techmap; opt -fast -purge
  write_blif -impltf $OUT"
