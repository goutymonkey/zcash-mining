#!/usr/bin/env bash
# cec.sh <gold.v> <gold top> <gate.v> <gate top> <workdir> [extra gate sources]
# Equivalence of two SKY130 gate netlists. Both are flattened to their
# liberty cell functions and joined in a miter on matching ports. Yosys
# builds the miter and ABC's dprove proves it never fires from the all-zero
# state (register correspondence by induction, fraiging, SAT).
# A pass means both netlists give the same outputs on every cycle for any
# input sequence. For the scan check the gate top is formal/cec/scan0.v
# (the scanned block with scan_en = 0). Runs in the LibreLane image.
set -euo pipefail
# EVERT_SRAM=1: SRAM macros (black boxes) become matched ports named
# <instance>.<pin> on both sides, so the rest of the chip is compared
# around them
EVERT=""
[ "${EVERT_SRAM:-}" = 1 ] && EVERT="expose -evert t:sky130_sram_2kbyte_1rw1r_32x512_8;"
GOLD=$1 GTOP=$2 GATE=$3 TTOP=$4 W=$5; shift 5; EXTRA="$*"
LIBFILE=${LIBFILE:-pd/pdk/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib}
mkdir -p "$W"
prep() {  # prep <sources> <top> <name>
    echo "read_liberty -ignore_miss_func $LIBFILE; read_verilog $1; hierarchy -top $2; proc; flatten;
          rename -hide w:_* w:net* w:clknet* w:*.* w:scan_q_*; opt_clean -purge; $EVERT
          async2sync; techmap; dfflegalize -cell \$_DFF_P_ x; techmap; opt -fast -purge; rename $2 $3; design -stash $3;"
}
yosys -q -l "$W/cec.log" -p "
  $(prep "$GOLD" $GTOP gold) $(prep "$GATE $EXTRA" $TTOP gate)
  design -copy-from gold -as gold gold; design -copy-from gate -as gate gate
  miter -equiv -flatten gold gate miter
  hierarchy -top miter; flatten; opt -fast -purge
  select -assert-count 1 o:trigger
  tee -o $W/stat.txt stat
  setundef -zero -init; async2sync; techmap; opt -fast -purge; dfflegalize -cell \$_DFF_P_ 01; techmap; setundef -zero -init; aigmap
  write_aiger -zinit -map $W/miter.map $W/miter.aig"
# ABC: signal/register correspondence (scorr), fraiging, then BMC/induction
yosys-abc -c "read_aiger $W/miter.aig; strash; print_stats; dprove -v" > "$W/proof.txt" 2>&1
if grep -Eq '^Networks are equivalent|^UNSATISFIABLE[[:space:]]+Time[[:space:]]*=' "$W/proof.txt"; then echo "cec: PASS"; exit 0; fi
if grep -Eq '^SATISFIABLE[[:space:]]+Time[[:space:]]*=' "$W/proof.txt"; then
    echo "cec: FAIL (combinational counterexample)"; exit 1
fi
# not proved: look for a concrete counterexample with deeper BMC
grep -q "was asserted in frame" "$W/proof.txt" || \
    yosys-abc -c "read_aiger $W/miter.aig; strash; bmc3 -F 400 -T 900 -v" >> "$W/proof.txt" 2>&1 || true
if f=$(grep -o "was asserted in frame [0-9]*" "$W/proof.txt" | head -1); [ -n "$f" ]; then
    echo "cec: FAIL (counterexample: miter ${f#was })"; exit 1
fi
echo "cec: UNDECIDED (see $W/proof.txt)"; exit 2
