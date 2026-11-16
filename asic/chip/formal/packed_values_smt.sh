#!/usr/bin/env bash
# Same 40-cycle arbitrary-data/address contract as the SAT check, using arrays.
set -euo pipefail
cd "$(dirname "$0")/.."
build=${BUILD:-build/packed-formal-smt}
mkdir -p "$build"
for cfg in '48 5 18' '200 9 32'; do
    read -r n k pw <<< "$cfg"
    yosys -Q -T -l "$build/n$n-yosys.log" -p "
      read_verilog -sv -D SYNTHESIS rtl/zeq_mbist.v rtl/zeq_ram.v rtl/zeq_packed_values.v;
      read_verilog -formal -sv formal/packed_values.sv;
      chparam -set N $n -set K $k -set PW $pw packed_values_formal;
      prep -top packed_values_formal -flatten;
      wreduce; opt -full; memory_collect; opt_clean; async2sync; dffunmap;
      write_smt2 -wires $build/n$n.smt2" > /dev/null
    yosys-smtbmc -s z3 -t 40 --presat --timeout 180 \
      --dump-vcd "$build/n$n-failure.vcd" "$build/n$n.smt2" > "$build/n$n-proof.log" 2>&1
    echo "packed values N=$n K=$k PW=$pw: 40-cycle SMT proof PASS"
done
