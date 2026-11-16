#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for params in '48 5 18' '200 9 32'; do
    read -r n k pw <<< "$params"
    build="build/packed-unit$n"
    mkdir -p "$build"
    docker run --rm -u "$(id -u):$(id -g)" -e CCACHE_DISABLE=1 -v "$PWD":/work -w /work \
        verilator/verilator:latest --binary --timing -j 2 -Wall --timescale 1ns/1ps \
        -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-PROCASSINIT -Wno-BLKSEQ \
        --top-module tb_packed_values -GN="$n" -GK="$k" -GPW="$pw" \
        --Mdir "$build/obj" -o sim rtl/zeq_mbist.v rtl/zeq_ram.v rtl/zeq_packed_values.v tb/tb_packed_values.sv \
        > "$build/compile.log" 2>&1
    docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/work -w /work \
        --entrypoint "/work/$build/obj/sim" verilator/verilator:latest > "$build/simulation.log" 2>&1
    cat "$build/simulation.log"
done
