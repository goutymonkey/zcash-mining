#!/usr/bin/env bash
# Qualify the exact isolated demonstrator source snapshot with SRAM models.
set -euo pipefail
cd "$(dirname "$0")/.."
build=build/plan-d-chain
src=build/plan-d-source/rtl
mkdir "$build"
trap 'code=$?; printf "%s\n" "$code" > "$build/exit_code"' EXIT
python3 model/check_chain.py prepare 48 5 "$build"
docker run --rm -u "$(id -u):$(id -g)" -e CCACHE_DISABLE=1 -v "$PWD":/work -w /work \
  verilator/verilator:latest --binary --timing -j 2 -Wall --timescale 1ns/1ps \
  -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY -Wno-PROCASSINIT \
  -Wno-MULTIDRIVEN -Wno-BLKSEQ --top-module tb_chain -GN=48 -GK=5 \
  -GLANES=1 -GHASH_SPLIT=4 -GARCH=1 -GPAR_BB=3 -GPAR_PB=1 -GPAR_SB=7 -GPAR_HPB=0 -GSHARE_FILTER=0 \
  --Mdir "$build/obj" -o simulation \
  "$src"/zeq_blake2b.v "$src"/zeq_eh_hash.v "$src"/zeq_sfifo.v "$src"/zeq_eh_solver3.v \
  "$src"/zeq_mbist.v "$src"/tech/sky130/zeq_ram.v "$src"/zeq_xbar_arb.v "$src"/zeq_eh_par.v \
  "$src"/zeq_sha256.v "$src"/zeq_share.v "$src"/tech/sky130/zeq_sram_port.v \
  "$src"/zeq_fifo.v "$src"/zeq_uart.v "$src"/zeq_link.v "$src"/zeq200_core.v "$src"/zeq200.v \
  tb/sky130_sram_model.v tb/tb_chain.sv > "$build/compile.log" 2>&1
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/work -w "/work/$build" \
  --entrypoint "/work/$build/obj/simulation" verilator/verilator:latest > "$build/simulation.log" 2>&1
SHARE_FILTER=0 LANES=1 PAR_CHAIN=1 PAR_CFG=3,128,relaxed \
  python3 model/check_chain.py check 48 5 "$build" > "$build/check.log" 2>&1
