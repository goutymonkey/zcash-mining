#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/packed-formal
for cfg in '48 5 18' '200 9 32'; do
    read -r n k pw <<< "$cfg"
    yosys -Q -T -l "build/packed-formal/n$n.log" -p "
      read_verilog -sv -D SYNTHESIS rtl/zeq_mbist.v rtl/zeq_ram.v rtl/zeq_packed_values.v;
      read_verilog -formal -sv formal/packed_values.sv;
      chparam -set N $n -set K $k -set PW $pw packed_values_formal;
      prep -top packed_values_formal -flatten;
      wreduce; opt -full; memory_map; opt -full; wreduce; opt_clean; async2sync; dffunmap; techmap; opt -full;
      sat -timeout 180 -seq 40 -prove-asserts -set-assumes -verify" > /dev/null
    echo "packed values N=$n K=$k PW=$pw: 40-cycle symbolic data/address proof PASS"
done
