#!/usr/bin/env bash
# Same full-width safety contract and checked invariants as native SAT.
# Word-level SMT keeps payload muxes compact. Base covers all induction depths.
set -euo pipefail
cd "$(dirname "$0")/.."
build=${BUILD:-build/row-network-smt}
mkdir -p "$build"
for pb in ${PBS:-3 4}; do
    yosys -Q -T -l "$build/pb$pb-yosys.log" -p "
      read_verilog -sv -D SYNTHESIS -D NETWORK_PROOF rtl/zeq_xbar_arb.v rtl/zeq_row_network.v;
      read_verilog -sv -formal -D NETWORK_PROOF formal/row_network.sv;
      chparam -set PB $pb -set DW 232 -set CHECK_PROGRESS 0 row_network_formal;
      prep -top row_network_formal -flatten;
      wreduce; opt -full; async2sync; dffunmap;
      write_smt2 -wires $build/pb$pb.smt2" > /dev/null
    yosys-smtbmc -s z3 -t 4 --presat --timeout 180 --dump-vcd "$build/pb$pb-base-failure.vcd" \
      "$build/pb$pb.smt2" > "$build/pb$pb-base.log" 2>&1
    yosys-smtbmc -s z3 -i -t 4 --timeout 180 --dump-vcd "$build/pb$pb-induct-failure.vcd" \
      "$build/pb$pb.smt2" > "$build/pb$pb-induct.log" 2>&1
    echo "row network PB=$pb DW=232: SMT induction packet safety PASS (progress separate)"
done
