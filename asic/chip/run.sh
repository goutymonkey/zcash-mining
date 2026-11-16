#!/usr/bin/env bash
# ZEQ-200 RTL flow. Verilator runs from the official Docker image, so the
# only host needs are docker and python3.
#   ./run.sh hash | solver | chain | all | synth
set -euo pipefail
cd "$(dirname "$0")"
N=${N:-48}; K=${K:-5}; NH=${NH:-8}
BUILD=${BUILD:-build/n${N}k${K}}
mkdir -p "$BUILD"
RTL="rtl/zeq_blake2b.v rtl/zeq_eh_hash.v rtl/zeq_sfifo.v rtl/zeq_eh_solver3.v rtl/zeq_mbist.v rtl/zeq_ram.v rtl/zeq_xbar_arb.v rtl/zeq_row_network.v rtl/zeq_packed_values.v rtl/zeq_eh_par.v rtl/zeq_sha256.v rtl/zeq_share.v rtl/zeq_tables_sram.v rtl/zeq_fifo.v rtl/zeq_uart.v rtl/zeq_link.v rtl/zeq200_core.v rtl/zeq200.v"
# the same design with SKY130 memories (SRAM macro tiling + BIST)
SKY_RTL="$(echo $RTL | sed -e 's|rtl/zeq_tables_sram.v|rtl/tech/sky130/zeq_sram_port.v|' -e 's|rtl/zeq_ram.v|rtl/tech/sky130/zeq_ram.v|')"

# the image's entrypoint is verilator; override it to run the built sims
DOCKER=(docker run --rm -u "$(id -u):$(id -g)" -e CCACHE_DISABLE=1 -v "$PWD":/work -w /work)

verilate() {  # verilate <top> <tb file> [extra -G params...]
    local top=$1 tb=$2; shift 2
    "${DOCKER[@]}" verilator/verilator:latest --binary --timing -j ${JOBS:-2} -Wall --timescale 1ns/1ps \
        -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY -Wno-PROCASSINIT \
        --top-module "$top" -GN=$N -GK=$K "$@" \
        --Mdir "$BUILD/obj_$top" -o "V$top" ${SRCS:-$RTL} "$tb" >"$BUILD/verilate_$top.log" 2>&1 \
        || { cat "$BUILD/verilate_$top.log"; exit 1; }
}
simulate() {  # simulate <top> (runs inside build/ so data files resolve)
    "${DOCKER[@]}" -w "/work/$BUILD" --entrypoint "./obj_$1/V$1" verilator/verilator:latest
}

case "${1:-all}" in
group_replay)
    for buffer in 2 8 16; do
        REPLAY_BUILD="$BUILD/buffer$buffer"
        mkdir -p "$REPLAY_BUILD"
        "${DOCKER[@]}" verilator/verilator:latest --binary --timing -j "${JOBS:-2}" \
            -Wall --timescale 1ns/1ps -Wno-DECLFILENAME -Wno-UNUSEDPARAM \
            -Wno-UNUSEDSIGNAL -Wno-BLKSEQ -Wno-PROCASSINIT \
            --top-module tb_group_replay -GBUFFER="$buffer" \
            --Mdir "$REPLAY_BUILD/obj" rtl/zeq_eh_par.v tb/tb_group_replay.sv \
            >"$REPLAY_BUILD/compile.log" 2>&1 || { cat "$REPLAY_BUILD/compile.log"; exit 1; }
        "${DOCKER[@]}" --entrypoint "/work/$REPLAY_BUILD/obj/Vtb_group_replay" \
            verilator/verilator:latest | tee "$REPLAY_BUILD/simulation.log"
    done
    python3 -m unittest discover -s model -p test_group_replay.py ;;

startup_bist)
    STARTUP_IMAGE=$(docker image inspect --format '{{.Id}}' ghcr.io/librelane/librelane:3.0.14)
    "${DOCKER[@]}" --entrypoint python3 "$STARTUP_IMAGE" tb/qualify_startup_bist.py \
        --build "$BUILD-startup-bist" --image-id "$STARTUP_IMAGE"
    "${DOCKER[@]}" --entrypoint python3 "$STARTUP_IMAGE" formal/qualify_link_bist.py \
        --build "$BUILD-startup-bist-formal" --boot-bist
    "${DOCKER[@]}" --entrypoint python3 "$STARTUP_IMAGE" tb/qualify_core_bist_faults.py \
        --build "$BUILD-startup-core-faults" --image-id "$STARTUP_IMAGE" ;;
solver_yield)
    python3 tb/qualify_par.py --build "$BUILD-solver-yield" --n "$N" --headers "$NH" \
        --engines "${ENGINES:-$((N == 200 ? 16 : 4))}" \
        --hash-engines "${HASH_ENGINES:-${ENGINES:-$((N == 200 ? 16 : 4))}}" \
        --hash-split "${HASH_SPLIT:-1}" --gmax "${GMAX:-16}" --group-replay "${GROUP_REPLAY:-0}" \
        --slots "${SLOTS:-$((N == 200 ? 640 : 80))}" --trace-drops "${TRACE_DROPS:-0}" \
        --bucket0-slots "${BUCKET0_SLOTS:-${SLOTS:-$((N == 200 ? 640 : 80))}}" --bist-first "${BIST_FIRST:-0}" \
        --drop-zero "${DROP_ZERO:-0}" --leaf-set "${LEAF_SET:-0}" --hash-units "${HASH_UNITS:-1}" \
        --compile-timeout "${COMPILE_TIMEOUT:-900}" --output-groups "${OUTPUT_GROUPS:-2}" \
        --simulation-timeout "${SIMULATION_TIMEOUT:-14400}" --audit-timeout "${AUDIT_TIMEOUT:-14400}" ;;
parser_formal)
    PARSER_IMAGE=$(docker image inspect --format '{{.Id}}' ghcr.io/librelane/librelane:3.0.14)
    "${DOCKER[@]}" --entrypoint python3 "$PARSER_IMAGE" formal/qualify_link_parser.py \
        --build "$BUILD-parser-formal" --n "$N" --boot-bist ;;
uart)
    UART_IMAGE=$(docker image inspect --format '{{.Id}}' ghcr.io/librelane/librelane:3.0.14)
    "${DOCKER[@]}" --entrypoint python3 "$UART_IMAGE" tb/qualify_uart.py \
        --build "$BUILD-uart" --image-id "$UART_IMAGE" ;;
command_recovery)
    python3 tb/qualify_link_recovery.py --build "$BUILD-command48" --downstream --extended
    python3 tb/qualify_link_recovery.py --build "$BUILD-command200" --downstream --extended --n 200 ;;
core_control)
    python3 tb/qualify_core_control.py --build "$BUILD-core-control" --n "$N" \
        --packed-tables "${PACKED_TABLES:-1}" --staged-network "${STAGED_NETWORK:-0}" \
        --hash-engines "${HASH_ENGINES:-$((N == 200 ? 16 : 4))}" --hash-split "${HASH_SPLIT:-1}" \
        --gmax "${GMAX:-16}" --group-replay "${GROUP_REPLAY:-0}" \
        --drop-zero "${DROP_ZERO:-0}" --leaf-set "${LEAF_SET:-0}" --hash-units "${HASH_UNITS:-1}" \
        --simulation-timeout "${SIMULATION_TIMEOUT:-3600}" ;;
link_recovery)
    python3 tb/qualify_link_recovery.py --build "$BUILD-recovery48"
    python3 tb/qualify_link_recovery.py --build "$BUILD-recovery200" --n 200 ;;
transport)
    python3 tb/qualify_link_saturation.py --build "$BUILD-transport48" --duration-ns 500000000
    python3 tb/qualify_link_saturation.py --build "$BUILD-transport200" --n 200 --duration-ns 500000000 ;;
link_bist)
    BUILD="$BUILD-link-bist" bash tb/run_link_bist.sh
    BUILD="$BUILD-link-no-bist" HAS_BIST=0 bash tb/run_link_bist.sh ;;
repair)
    BUILD="$BUILD/repair-qualification" bash tb/run_repair_bank.sh ;;
packed_formal)
    # The evidence runner refuses to overwrite an existing qualification.
    "${DOCKER[@]}" --entrypoint python3 ghcr.io/librelane/librelane:3.0.14 \
        formal/qualify_packed.py --build "$BUILD/packed-qualification" ;;
hash)
    python3 model/gen_hash_vectors.py "$N" "$K" 16 "$BUILD"
    SRCS="rtl/zeq_blake2b.v rtl/zeq_eh_hash.v" verilate tb_hash tb/tb_hash.sv -GNV=64 -GSPLIT=${SPLIT:-1}
    simulate tb_hash ;;
tla)
    # TLA+ (TLC, exhaustive): the specs must pass, the mutants must fail
    cd formal/tla
    TLC="java -XX:+UseParallelGC -Xmx2g -cp tla2tools.jar tlc2.TLC -workers 2 -deadlock"
    META=$(mktemp -d)
    # (TLC exits non-zero on a violation; capture output so pipefail does not
    #  turn an expected mutant failure into a script failure)
    tlc() { $TLC -metadir "$META/$1-$RANDOM" -config "$2" "$1" 2>&1 || true; }
    for m in "ChainProtocol ChainProtocol.cfg" "ParRound ParRound.cfg" "JobTags JobTags.cfg"; do
        set -- $m
        if tlc $1 $2 | grep -q "No error has been found"; then echo "tla $1: PASS"
        else echo "tla $1: FAIL"; exit 1; fi
    done
    # mutants: the checks must catch a broken design
    sed 's/          Room = 2/          Room = 3/' ChainProtocol.cfg > "$META/noflow.cfg"
    cp "$META/noflow.cfg" Chain_noflow.cfg
    tlc ChainProtocol Chain_noflow.cfg | grep -q "NoOverflow is violated" && echo "tla mutant loose-flow-control: caught" || { echo "tla mutant: NOT caught"; exit 1; }
    tlc JobTags JobTags_buggy.cfg | grep -q "CorrectTags is violated" && echo "tla mutant current-job-tag: caught" || { echo "tla mutant: NOT caught"; exit 1; }
    sed -e 's/MODULE ParRound /MODULE ParRoundMut /' -e 's/    \/\\ \\A e \\in Eng : AtBar(e)/    \/\\ \\A e \\in Eng : left[e] = 0/' ParRound.tla > ParRoundMut.tla
    cp ParRound.cfg ParRoundMut.cfg
    tlc ParRoundMut ParRoundMut.cfg | grep -q "is violated" && echo "tla mutant barrier-ignores-inflight: caught" || { echo "tla mutant: NOT caught"; exit 1; }
    rm -f ParRoundMut.tla ParRoundMut.cfg Chain_noflow.cfg; rm -rf "$META" ;;
lean)
    # Lean 4 proofs: build, and refuse any sorry/admit
    ( cd formal/lean && lake build >"../../$BUILD/lean.log" 2>&1 ) || { tail -20 "$BUILD/lean.log"; echo "lean: FAIL"; exit 1; }
    if grep -rnE "\bsorry\b|\badmit\b" formal/lean/Zeq; then echo "lean: FAIL (sorry)"; exit 1; fi
    echo "lean: PASS (no sorry)" ;;
lec)
    # sequential equivalence (ABC dprove: register correspondence + SAT) on
    # the signed-off Blake2b block: RTL vs routed netlist, synthesis vs routed, and
    # vs the scan-inserted netlist with scan_en = 0; plus a mutant (scan mode left on) that must fail
    [ -f build/scan/zeq_blake2b_scan.v ] || "$0" scan
    SYN=pd/blake2b/runs/latest/02-yosys-synthesis/zeq_blake2b.nl.v
    FIN=pd/blake2b/runs/latest/final/nl/zeq_blake2b.nl.v
    mkdir -p build/cec
    # the RTL (SPLIT = 4, as hardened) lowered to generic gates
    ~/.local/bin/yowasp-yosys -q -p "read_verilog -sv rtl/zeq_blake2b.v; chparam -set SPLIT 4 zeq_blake2b;
        synth -flatten -top zeq_blake2b; opt_clean -purge; write_verilog -noattr build/cec/rtl_split4.v" >/dev/null
    LL=(docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/work -w /work ghcr.io/librelane/librelane:3.0.14)
    "${LL[@]}" formal/cec/cec.sh build/cec/rtl_split4.v zeq_blake2b $FIN zeq_blake2b \
        build/cec/rtl | sed 's/^cec/lec RTL = routed/' | tail -1
    "${LL[@]}" formal/cec/cec.sh $SYN zeq_blake2b $FIN zeq_blake2b \
        build/cec/pnr | sed 's/^cec/lec synthesis = routed/' | tail -1
    "${LL[@]}" formal/cec/cec.sh $SYN zeq_blake2b build/scan/zeq_blake2b_scan.v zeq_blake2b_func \
        build/cec/scan formal/cec/scan0.v | sed 's/^cec/lec synthesis = scan (scan_en 0)/' | tail -1
    # mutants must give a concrete counterexample, not just "not proved"
    r=$("${LL[@]}" formal/cec/cec.sh $SYN zeq_blake2b build/scan/zeq_blake2b_scan.v zeq_blake2b_func build/cec/mutant \
        formal/cec/scan1_mutant.v 2>&1 | tail -1) || true
    case "$r" in *counterexample*) echo "lec mutant (scan_en = 1): caught, ${r#*: }";; *) echo "lec mutant (scan_en = 1): NOT caught: $r"; exit 1;; esac
    grep -q "Networks are equivalent" build/cec/rtl/proof.txt && grep -q "Networks are equivalent" build/cec/pnr/proof.txt && grep -q "Networks are equivalent" build/cec/scan/proof.txt ;;
scan)
    # full-scan insertion on the Blake2b synthesis netlist, then a shift and
    # capture simulation using the liberty cell functions
    mkdir -p build/scan
    python3 pd/scan_insert.py pd/blake2b/runs/latest/02-yosys-synthesis/zeq_blake2b.nl.v \
        build/scan/zeq_blake2b_scan.v zeq_blake2b
    sed -i 's/^module zeq_blake2b(/module zeq_blake2b_scan(/' build/scan/zeq_blake2b_scan.v
    LIB=$(ls pd/pdk/ciel/sky130/versions/*/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib | head -1)
    ~/.local/bin/yowasp-yosys -q -l build/scan/sim.log -p "
        read_liberty -ignore_miss_func $LIB; read_verilog build/scan/zeq_blake2b_scan.v;
        hierarchy -top zeq_blake2b_scan; flatten; proc; opt_clean; techmap; opt -fast;
        write_verilog -noattr build/scan/scan_sim.v" >/dev/null
    SRCS="build/scan/scan_sim.v" verilate tb_scan tb/tb_scan.sv -Wno-fatal
    simulate tb_scan | tee "$BUILD/scan.log"
    grep -q "scan: PASS" "$BUILD/scan.log" ;;
formal)
    # SAT proofs (Yosys built-in solver): arbiter (induction, all time),
    # UART delivery of every byte, FIFO order/integrity (bounded)
    for f in arb uart fifo; do
        if ~/.local/bin/yowasp-yosys -s formal/$f.ys 2>&1 | grep -q "SUCCESS"; then
            echo "formal $f: PASS"
        else
            echo "formal $f: FAIL"; exit 1
        fi
    done ;;
mbist)
    SRCS="rtl/zeq_mbist.v" verilate tb_mbist tb/tb_mbist.sv -Wno-BLKSEQ -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
    simulate tb_mbist ;;
share)
    python3 model/gen_share_vectors.py "$N" "$K" 32 "$BUILD"
    SRCS="rtl/zeq_sha256.v rtl/zeq_share.v" verilate tb_share tb/tb_share.sv -GNV=32 -Wno-BLKSEQ
    simulate tb_share ;;
solver)
    python3 model/check_solver.py prepare "$N" "$K" "$BUILD" "$NH"
    SRCS="rtl/zeq_blake2b.v rtl/zeq_eh_hash.v rtl/zeq_eh_solver.v" verilate tb_solver tb/tb_solver.sv -GNH=$NH
    simulate tb_solver
    python3 model/check_solver.py check "$N" "$K" "$BUILD" "$NH" ;;
solver2)
    python3 model/check_solver.py prepare "$N" "$K" "$BUILD" "$NH"
    SRCS="rtl/zeq_blake2b.v rtl/zeq_eh_hash.v rtl/zeq_eh_solver2.v tb/zeq_mem_model.sv" \
        verilate tb_solver2 tb/tb_solver2.sv -GNH=$NH -GLAT=${LAT:-1} -GSTALL=${STALL:-0}
    simulate tb_solver2
    python3 model/check_solver.py check "$N" "$K" "$BUILD" "$NH" ;;
solver3)
    python3 model/check_solver.py prepare "$N" "$K" "$BUILD" "$NH"
    SRCS="rtl/zeq_blake2b.v rtl/zeq_eh_hash.v rtl/zeq_sfifo.v rtl/zeq_eh_solver3.v tb/zeq_mem_model.sv" \
        verilate tb_solver3 tb/tb_solver3.sv -GNH=$NH -GLAT=${LAT:-1} -GSTALL=${STALL:-0} -GD=${D:-8}
    simulate tb_solver3
    python3 model/check_solver.py check "$N" "$K" "$BUILD" "$NH" ;;
par)
    if [[ "${GROUP_REPLAY:-0}" != 0 || "${GMAX:-16}" != 16 ]]; then
        echo "Use solver_yield for GMAX/GROUP_REPLAY experiments; its reference audit never waives overflow loss." >&2
        exit 2
    fi
    python3 model/check_solver.py prepare "$N" "$K" "$BUILD" "$NH"
    SRCS="rtl/zeq_blake2b.v rtl/zeq_eh_hash.v rtl/zeq_mbist.v ${RAM:-rtl/zeq_ram.v} rtl/zeq_xbar_arb.v rtl/zeq_row_network.v rtl/zeq_packed_values.v rtl/zeq_eh_par.v" \
        verilate tb_par tb/tb_par.sv -GNH=$NH -GBB=${BB:-4} -GPB=${PB:-2} -GSB=${SB:-6} -GHPB=${HPB:-${PB:-2}} -GSTAGED_NETWORK=${STAGED_NETWORK:-0} -GPACKED_TABLES=${PACKED_TABLES:-0} -GSPLIT_KEYS=${SPLIT_KEYS:-0} -GCOMPACT_VALUES=${COMPACT_VALUES:-0} -GSLOTS=${SLOTS:-$((1 << ${SB:-6}))} -GBIST_FIRST=${BIST_FIRST:-0} -GDROP_ZERO=${DROP_ZERO:-0} -GLEAF_SET=${LEAF_SET:-0} -GHASH_UNITS=${HASH_UNITS:-1} -GCHAIN=${CHAIN:-0} -GGBUF=${GBUF:-2} -GQDEPTH=${QDEPTH:-4} -GEMIT=${EMIT:-1}
    simulate tb_par
    DROP_ZERO=${DROP_ZERO:-0} PAR="${BB:-4},${SLOTS:-$((1 << ${SB:-6}))}" python3 model/check_solver.py check "$N" "$K" "$BUILD" "$NH" ;;
chain)
    python3 model/check_chain.py prepare "$N" "$K" "$BUILD"
    verilate tb_chain tb/tb_chain.sv -Wno-MULTIDRIVEN
    simulate tb_chain
    python3 model/check_chain.py check "$N" "$K" "$BUILD" ;;
chain_par)
    # the board test with the bucket-parallel solver in every lane
    python3 model/check_chain.py prepare "$N" "$K" "$BUILD"
    verilate tb_chain tb/tb_chain.sv -Wno-MULTIDRIVEN -GARCH=1
    simulate tb_chain
    PAR_CHAIN=1 python3 model/check_chain.py check "$N" "$K" "$BUILD" ;;
chain_sky130)
    # the tapeout configuration (zeq200_tc): one lane of the bucket-parallel
    # solver (2 engines, 8 buckets x 128 slots), Blake2b SPLIT=4, every
    # table built from SKY130 SRAM macro models (with BIST)
    python3 model/check_chain.py prepare "$N" "$K" "$BUILD"
    SRCS="$SKY_RTL tb/sky130_sram_model.v" \
        verilate tb_chain tb/tb_chain.sv -Wno-MULTIDRIVEN -Wno-BLKSEQ -Wno-UNUSEDSIGNAL \
        -GLANES=1 -GHASH_SPLIT=4 -GARCH=1 -GPAR_BB=3 -GPAR_PB=1 -GPAR_SB=7 -GPAR_HPB=0 -GSHARE_FILTER=${SHARE_FILTER:-0}
    simulate tb_chain
    SHARE_FILTER=${SHARE_FILTER:-0} LANES=1 PAR_CHAIN=1 PAR_CFG=3,128,relaxed python3 model/check_chain.py check "$N" "$K" "$BUILD" ;;
lint_mainnet)
    "${DOCKER[@]}" verilator/verilator:latest --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM \
        -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY --top-module zeq200x -GPB=${PB:-4} -GSTAGED_NETWORK=${STAGED_NETWORK:-0} -GPACKED_TABLES=${PACKED_TABLES:-0} \
        $RTL rtl/zeq200x.v
    echo "mainnet lint: clean (PB=${PB:-4})" ;;
lint)
    # Verilator -Wall lint of the test-chip and mainnet tops, then a Yosys
    # structural check (multiple drivers, loops) that must be clean
    SRCS="$SKY_RTL tb/sky130_sram_model.v rtl/zeq200_tc.v rtl/zeq_caravel_wrapper.v"
    "${DOCKER[@]}" verilator/verilator:latest --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM \
        -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY --top-module zeq_caravel_wrapper $SRCS
    "${DOCKER[@]}" verilator/verilator:latest --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM \
        -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY --top-module zeq200m -GLANES=2 ${RTL/rtl\/zeq200.v/} rtl/zeq200m.v
    ~/.local/bin/yowasp-yosys -q -l "$BUILD/lint_yosys.log" -p "
        read_verilog -sv pd/tc/sram_blackbox.v $SKY_RTL rtl/zeq200_tc.v;
        hierarchy -top zeq200_tc; proc; flatten; check -assert" >/dev/null
    echo "lint: clean" ;;
chain_gl)
    # the board test on the Yosys gate-level netlist of the test-chip core
    # (build/gl/zeq200_core_gl.v, made by ./run.sh gl_netlist)
    if [ ! -f build/gl/zeq200_core_gl.v ] || [ -n "$(find rtl -newer build/gl/zeq200_core_gl.v -name '*.v')" ]; then
        "$0" gl_netlist
    fi
    python3 model/check_chain.py prepare "$N" "$K" "$BUILD"
    # the same testbench as `chain`, retargeted at the gate-level pad ring
    sed -e 's/module tb_chain;/module tb_chain_gl;/' -e 's/zeq200 #(/zeq200_gl #(/' \
        -e 's/tb_chain\.g_chip/tb_chain_gl.g_chip/' tb/tb_chain.sv > build/tb_chain_gl.sv
    SRCS="build/gl/zeq200_core_gl.v tb/zeq200_gl.v tb/sky130_sram_model.v" \
        verilate tb_chain_gl build/tb_chain_gl.sv -Wno-fatal -GLANES=1 -GHASH_SPLIT=4 -GARCH=1 \
        -GSHARE_FILTER=0 --top-module tb_chain_gl
    simulate tb_chain_gl
    SHARE_FILTER=0 LANES=1 PAR_CHAIN=1 PAR_CFG=3,128,relaxed python3 model/check_chain.py check "$N" "$K" "$BUILD" ;;
gl_netlist)
    mkdir -p build/gl
    ~/.local/bin/yowasp-yosys -q -l build/gl/synth.log -p "
        read_verilog -sv -DSYNTHESIS pd/tc/sram_blackbox.v $SKY_RTL;
        chparam -set N 48 -set K 5 -set LANES 1 -set EXT_MEM 0 -set DIV 8 -set HASH_SPLIT 4 -set ARCH 1 -set PAR_BB 3 -set PAR_PB 1 -set PAR_SB 7 -set PAR_HPB 0 -set SHARE_FILTER 0 zeq200_core;
        synth -top zeq200_core -flatten; opt_clean -purge;
        rename zeq200_core zeq200_core_gl;
        write_verilog -noattr build/gl/zeq200_core_gl.v" >/dev/null ;;
synth)
    # Memories stay as $mem cells (SRAM macros on silicon); everything else
    # is mapped to generic gates so the logic size is meaningful.
    ~/.local/bin/yowasp-yosys -q -l "$BUILD/synth.log" -p "
        read_verilog -sv $RTL;
        chparam -set N $N -set K $K zeq200;
        synth -top zeq200 -flatten -run begin:fine;
        opt -fast -full;
        techmap; opt -fast;
        abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX;
        opt_clean;
        tee -o $BUILD/synth_stat.txt stat -width;
        check -assert" >/dev/null
    cat "$BUILD/synth_stat.txt" ;;
all)
    "$0" lint && "$0" formal && "$0" parser_formal && "$0" hash && "$0" share && "$0" mbist && "$0" link_bist && "$0" solver && STALL=30 LAT=3 "$0" solver2 &&
        STALL=30 LAT=20 D=8 "$0" solver3 && SB=8 "$0" par && "$0" chain && "$0" chain_par &&
        "$0" chain_sky130 && "$0" startup_bist && "$0" core_control && "$0" uart && "$0" link_recovery && "$0" command_recovery && "$0" transport && "$0" tla && "$0" lean ;;
signoff)
    # implementation checks on the hardened blocks (slow: ~1 h)
    "$0" scan && "$0" lec && "$0" chain_gl ;;
*)
    echo "usage: $0 lint|lint_mainnet|hash|share|solver|solver2|solver3|par|solver_yield|group_replay|chain|chain_par|chain_sky130|chain_gl|gl_netlist|synth|scan|lec|formal|parser_formal|packed_formal|repair|link_bist|startup_bist|core_control|uart|link_recovery|command_recovery|transport|tla|lean|all|signoff"; exit 2 ;;
esac
