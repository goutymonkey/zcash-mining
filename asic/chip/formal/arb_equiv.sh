#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/arb_equiv
for pb in ${ARB_PBS:-1 2 3 4}; do
    for bank in 0 $(((1 << pb) - 1)); do
        log="build/arb_equiv/pb${pb}_bank${bank}.log"
        yosys -Q -T -l "$log" -p "
          read_verilog -sv rtl/zeq_xbar_arb.v formal/zeq_xbar_arb_reference.v;
          read_verilog -formal formal/arb_equiv.sv;
          chparam -set PB $pb -set BANK $bank arb_equiv;
          prep -top arb_equiv -flatten;
          async2sync; dffunmap;
          sat -tempinduct -prove-asserts -set-at 1 rst 1 -seq 2 -maxsteps 8 -verify" > /dev/null
        echo "arbiter equivalence PB=$pb BANK=$bank: PASS"
    done
done
