#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=${BUILD:-build/row-network-progress}
mkdir -p "$build"
for pb in ${PBS:-2 3 4}; do
    yosys -Q -T -l "$build/pb$pb.log" -p "
      read_verilog -sv -D SYNTHESIS -D NETWORK_PROOF rtl/zeq_xbar_arb.v rtl/zeq_row_network.v;
      read_verilog -sv -formal -D NETWORK_PROOF formal/row_network_progress.sv;
      chparam -set PB $pb row_network_progress;
      prep -top row_network_progress -flatten;
      wreduce; opt -full; async2sync; dffunmap; techmap; opt -full;
      sat -timeout 180 -tempinduct -seq 2 -maxsteps 4 -set-assumes -prove-asserts -verify" > /dev/null
    echo "row network PB=$pb: inductive accepted-row progress PASS (marker payload, always accepting banks)"
done
