#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=${BUILD:-build/repair-bank-formal}
mkdir "$build"
for cfg in '1 8 1' '3 13 5' '6 32 64'; do
    read -r aw dw depth <<< "$cfg"
    yosys -Q -T -l "$build/depth$depth.log" -p "
      read_verilog -sv -D SYNTHESIS rtl/zeq_mbist.v rtl/zeq_repair_bank.v;
      read_verilog -formal -sv formal/repair_bank.sv;
      chparam -set AW $aw -set DW $dw -set DEPTH $depth repair_bank_formal;
      prep -top repair_bank_formal -flatten;
      opt -full; async2sync; dffunmap; techmap; opt -full;
      sat -timeout 120 -tempinduct -seq 2 -maxsteps 6 -prove-asserts -set-assumes -verify;
    " > /dev/null
    echo "Repair bank control/remap AW=$aw DW=$dw DEPTH=$depth: PASS"
done
