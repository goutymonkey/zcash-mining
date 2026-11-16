#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for pb in ${PBS:-2 3 4 5 6}; do
    build=build/row-network-pb$pb
    mkdir -p "$build"
    docker run --rm -u "$(id -u):$(id -g)" -e CCACHE_DISABLE=1 -v "$PWD":/work -w /work \
      verilator/verilator:latest --binary --timing -j 2 -Wall --timescale 1ns/1ps \
      -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-PROCASSINIT -Wno-BLKSEQ \
      --top-module tb_row_network -GPB="$pb" --Mdir "$build/obj" -o simulation \
      rtl/zeq_xbar_arb.v rtl/zeq_row_network.v tb/tb_row_network.sv > "$build/compile.log" 2>&1
    docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/work -w "/work/$build" \
      --entrypoint "/work/$build/obj/simulation" verilator/verilator:latest > "$build/simulation.log" 2>&1
    cat "$build/simulation.log"
done
