#!/usr/bin/env bash
# Prove that new diagnostics leave every existing BIST control/data port unchanged.
# Runs inside LibreLane. The golden model is the immutable Plan D source.
set -euo pipefail
cd "$(dirname "$0")/.."
build=${BUILD:-build/mbist-compat}
mkdir "$build"
for cfg in '1 8 1' '3 13 5' '6 32 64'; do
    read -r aw dw depth <<< "$cfg"
    yosys -Q -T -l "$build/depth$depth.log" -p "
      read_verilog -sv build/plan-d-source/rtl/zeq_mbist.v;
      rename zeq_mbist gold;
      read_verilog -sv rtl/zeq_mbist.v;
      rename zeq_mbist gate;
      chparam -set AW $aw -set DW $dw -set DEPTH $depth gold gate;
      proc; opt;
      select gate; delete w:fail_valid w:fail_addr w:fail_expected w:fail_observed w:fail_element w:fail_multirow;
      select *; opt_clean;
      equiv_make gold gate equiv;
      hierarchy -top equiv;
      equiv_simple; equiv_induct -seq 3; equiv_status -assert;
    " > /dev/null
    echo "BIST compatibility AW=$aw DW=$dw DEPTH=$depth: PASS"
done
