#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build the live UART RTL bridge with the pinned, network-isolated toolchain."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid

CHIP = Path(__file__).resolve().parents[1]
RTL = ["zeq_blake2b.v", "zeq_eh_hash.v", "zeq_sfifo.v", "zeq_eh_solver3.v",
       "zeq_mbist.v", "zeq_ram.v", "zeq_xbar_arb.v", "zeq_row_network.v",
       "zeq_packed_values.v", "zeq_eh_par.v", "zeq_sha256.v", "zeq_share.v",
       "zeq_tables_sram.v", "zeq_fifo.v", "zeq_uart.v", "zeq_link.v", "zeq200_core.v"]
WARNINGS = ["-Wall", "-Wno-DECLFILENAME", "-Wno-UNUSEDPARAM", "-Wno-UNUSEDSIGNAL",
            "-Wno-PINCONNECTEMPTY", "-Wno-PROCASSINIT"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dump(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--n", type=int, choices=(48, 200), default=48)
    parser.add_argument("--chips", type=int, choices=(1, 2, 3, 4), default=1)
    parser.add_argument("--divider", type=int, choices=(8, 16), default=8)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--build", type=Path, required=True, help="fresh output directory below asic/chip/build")
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()
    build = args.build.resolve()
    relative = build.relative_to(CHIP / "build")
    if not relative.parts or args.jobs < 1 or args.jobs > 8:
        parser.error("use a new build subdirectory and 1..8 compile jobs")
    if shutil.disk_usage(CHIP).free < 2 * 1024 ** 3:
        raise RuntimeError("at least 2 GiB free disk is required before RTL compilation")
    build.mkdir(parents=True, exist_ok=False)
    toolchain = json.loads((CHIP / "toolchain.json").read_text())
    image = toolchain["verilator"]["image"]
    files = ["rtl/" + name for name in RTL] + ["tb/zeq_sim_top.sv", "sim/uart_bridge.cpp", "sim/build.py", "sim/bridge.py", "toolchain.json"]
    hashes = {name: sha(CHIP / name) for name in files}
    source = build / "source"
    for name, expected in hashes.items():
        destination = source / "asic/chip" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(CHIP / name, destination)
        if sha(destination) != expected:
            raise RuntimeError(f"source changed while freezing: {name}")
    root = CHIP.parents[1]
    for name in ("LICENSE", "LICENSING.md", "NOTICE", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(root / name, source / name)
    shutil.copytree(root / "LICENSES", source / "LICENSES")
    geometry = {"N": args.n, "K": 9 if args.n == 200 else 5, "CHIPS": args.chips, "DIV": args.divider}
    container = "zcash-rtl-build-" + uuid.uuid4().hex[:16]
    docker = ["docker", "run", "--rm", "--name", container, "--network=none", "--cpus", str(args.jobs),
              "--memory", "8g" if args.n == 200 else "4g", "--pids-limit", "256",
              "-u", f"{os.getuid()}:{os.getgid()}", "-e", "CCACHE_DISABLE=1",
              "-v", f"{source / 'asic/chip'}:/work:ro", "-v", f"{build}:/out", "-w", "/work", image]
    sources = ["rtl/" + name for name in RTL] + ["tb/zeq_sim_top.sv"]
    common = ["--top-module", "zeq_sim_top", "--assert", "--timescale", "1ns/1ps",
              *WARNINGS, *(f"-G{key}={value}" for key, value in geometry.items())]
    obj = "/out/obj"
    commands = {
        "lint": docker + ["--lint-only", *common, *sources],
        "build": docker + ["--cc", "--exe", "--build", "-j", str(args.jobs), *common,
                           "--Mdir", obj, "-o", "zeq-host-sim", "-CFLAGS",
                           f"-std=c++17 -DZEQ_UART_DIV={args.divider}", *sources, "/work/sim/uart_bridge.cpp"],
    }
    dump(build / "inputs.json", {"started_utc": datetime.now(timezone.utc).isoformat(),
         "sources": hashes, "toolchain": toolchain, "geometry": geometry, "commands": commands,
         "scope": "Digital UART-connected RTL simulation; no physical timing, power, or manufacturing qualification"})
    phase = "lint"
    try:
        for phase, command in commands.items():
            with (build / f"{phase}.log").open("w") as log:
                try:
                    subprocess.run(command, cwd=CHIP, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout, check=True)
                except BaseException:
                    # A terminated Docker client does not necessarily stop its
                    # container. Remove only this invocation's named container.
                    subprocess.run(["docker", "rm", "--force", container], capture_output=True, timeout=15)
                    raise
        if hashes != {name: sha(source / "asic/chip" / name) for name in files}:
            raise RuntimeError("frozen sources changed during RTL compilation")
        binary = build / "obj/zeq-host-sim"
        result = {"status": "BUILT", "geometry": geometry, "binary": "obj/zeq-host-sim", "binary_sha256": sha(binary),
                  "image": image, "inputs_sha256": sha(build / "inputs.json"),
                  "logs": {name: sha(build / name) for name in ("lint.log", "build.log")}}
    except Exception as exc:
        result = {"status": "FAIL", "phase": phase, "error": str(exc), "inputs_sha256": sha(build / "inputs.json")}
        dump(build / "result.json", result)
        raise
    dump(build / "result.json", result)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
