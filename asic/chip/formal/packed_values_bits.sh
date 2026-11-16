#!/usr/bin/env bash
# Split the unchanged 40-cycle contract into output bits to reduce SAT cones.
# Every value and parent bit must pass; a partial run is not a word proof.
set -euo pipefail
cd "$(dirname "$0")/.."
n=${N:-48}; k=5; pw=18
if [ "$n" = 200 ]; then k=9; pw=32; fi
vw=$((n-n/(k+1)))
build=${BUILD:-build/packed-formal-bits$n}
mkdir -p "$build"
for bit in ${BITS:-$(seq 0 $((vw-1)))}; do
    parent=-2
    if [ "$bit" -lt "$pw" ]; then parent=$bit; fi
    yosys -Q -T -l "$build/bit$bit.log" -p "
      read_verilog -sv -D SYNTHESIS rtl/zeq_mbist.v rtl/zeq_ram.v rtl/zeq_packed_values.v;
      read_verilog -formal -sv formal/packed_values.sv;
      chparam -set N $n -set K $k -set PW $pw -set VALUE_BIT $bit -set PARENT_BIT $parent packed_values_formal;
      prep -top packed_values_formal -flatten;
      wreduce; opt -full; memory_map; opt -full; wreduce; opt_clean; async2sync; dffunmap; techmap; opt -full;
      sat -timeout 180 -seq 40 -prove-asserts -set-assumes -verify" > /dev/null
    echo "N=$n value bit $bit parent bit $parent: 40-cycle PASS"
done
