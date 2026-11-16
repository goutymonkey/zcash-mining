#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=${BUILD:-build/row-network-formal-optimized}
mkdir -p "$build"
for pb in ${PBS:-2 3}; do
    yosys -Q -T -l "$build/pb$pb.log" -p "
      read_verilog -sv -D SYNTHESIS rtl/zeq_xbar_arb.v rtl/zeq_row_network.v;
      read_verilog -sv -formal formal/row_network.sv;
      chparam -set PB $pb row_network_formal;
      prep -top row_network_formal -flatten;
      wreduce; opt -full; async2sync; dffunmap; techmap; opt -full;
      sat -timeout 180 -seq 20 -set-at 1 rst 1 -prove-asserts -verify" > /dev/null
    echo "row network PB=$pb: 20-cycle arbitrary-transaction safety/progress PASS"
done
