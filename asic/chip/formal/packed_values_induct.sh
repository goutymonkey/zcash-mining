#!/usr/bin/env bash
# Prove the original functional outputs plus live-value/retained-parent
# storage invariants. Debug memory views only exist in this formal build.
set -euo pipefail
cd "$(dirname "$0")/.."
build=${BUILD:-build/packed-formal-induct}
mkdir -p "$build"
for cfg in '48 5 18' '200 9 32'; do
    read -r n k pw <<< "$cfg"
    yosys -Q -T -l "$build/n$n.log" -p "
      read_verilog -sv -D SYNTHESIS -D PACKED_PROOF rtl/zeq_mbist.v rtl/zeq_ram.v rtl/zeq_packed_values.v;
      read_verilog -formal -sv -D PACKED_PROOF formal/packed_values.sv;
      chparam -set N $n -set K $k -set PW $pw packed_values_formal;
      prep -top packed_values_formal -flatten;
      wreduce; opt -full; memory_map; opt -full; async2sync; dffunmap; techmap; opt -full;
      sat -timeout 180 -tempinduct -seq 2 -maxsteps 6 -prove-asserts -set-assumes -show-inputs -show-regs -dump_json $build/n$n-failure.json -verify" > /dev/null
    echo "packed memory N=$n K=$k PW=$pw: inductive outputs/storage PASS (depth 2, reset/cancel/restart, no BIST)"
done
