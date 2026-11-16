#!/usr/bin/env bash
# Full 232-bit packet safety with a checked storage invariant. Progress is
# a separate control proof; disabling its age assertion does not prove liveness.
set -euo pipefail
cd "$(dirname "$0")/.."
build=${BUILD:-build/row-network-induct}
mkdir -p "$build"
for pb in ${PBS:-2 3 4}; do
    yosys -Q -T -l "$build/pb$pb.log" -p "
      read_verilog -sv -D SYNTHESIS -D NETWORK_PROOF rtl/zeq_xbar_arb.v rtl/zeq_row_network.v;
      read_verilog -sv -formal -D NETWORK_PROOF formal/row_network.sv;
      chparam -set PB $pb -set DW 232 -set CHECK_PROGRESS 0 row_network_formal;
      prep -top row_network_formal -flatten;
      wreduce; opt -full; async2sync; dffunmap; techmap; opt -full;
      sat -timeout 180 -tempinduct -seq 2 -maxsteps 6 -set-at 1 rst 1 -prove-asserts -verify" > /dev/null
    echo "row network PB=$pb DW=232: inductive packet safety PASS (progress separate)"
done
