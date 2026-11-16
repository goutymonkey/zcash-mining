#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Source-bound local pool -> miner -> actual UART RTL -> verified shares.

This establishes digital integration, not real clock timing, power, silicon,
or public-pool interoperability. Transport fault fixtures are separate tests.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time

from pool_harness import ROOT, ReferencePool
from qualify_mining import dump, sha, snapshot

sys.path.insert(0, str(ROOT / "asic/chip/sim"))
from bridge import Build


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--scenario", choices=("normal", "soak"), default="normal")
    args = parser.parse_args()
    if args.seconds < 2 or args.seconds > 3600:
        parser.error("use 2..3600 seconds for this bounded integration check")
    build = Build(args.build)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    miner = snapshot(output, ROOT / "zig-out/bin/zcash-miner")
    device = output / "device-build"
    device.mkdir()
    for name in ("result.json", "inputs.json", "lint.log", "build.log"):
        shutil.copy2(build.directory / name, device / name)
    shutil.copytree(build.directory / "source", device / "source")
    (device / "obj").mkdir()
    shutil.copy2(build.binary, device / "obj/zeq-host-sim")
    Build(device)  # Verify the archive, not just the original build.
    runner = output / "runner"
    paths = [ROOT / "asic/chip/sim/bridge.py", ROOT / "asic/chip/model/equihash_ref.py",
             Path(__file__), ROOT / "tests/pool_harness.py", ROOT / "tests/qualify_mining.py"]
    before = {str(p.relative_to(ROOT)): sha(p) for p in paths}
    for path in paths:
        target = runner / path.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    if before != {name: sha(runner / name) for name in before}:
        raise RuntimeError("runner changed while taking its snapshot")
    dump(output / "device-inputs.json", {
        "started_utc": datetime.now(timezone.utc).isoformat(), "geometry": build.geometry,
        "miner_sha256": sha(miner), "device_sha256": sha(build.binary),
        "runner_sources": before, "host_inputs_sha256": sha(output / "inputs.json"),
        "device_inputs_sha256": sha(device / "inputs.json"),
        "scope": "actual RTL, synthetic local pool; no physical or public-pool qualification"})
    port_file = output / "port.txt"
    result = {"status": "FAIL", "actual_rtl": True, "public_pool": False, "physical_device": False}
    process = None
    try:
        with (output / "bridge.stdout.jsonl").open("w") as bridge_out, (output / "bridge.stderr.log").open("w") as bridge_err:
            process = subprocess.Popen([sys.executable, str(runner / "asic/chip/sim/bridge.py"),
                                        "--build", str(device), "--port-file", str(port_file)],
                                       stdout=bridge_out, stderr=bridge_err)
            deadline = time.monotonic() + 15
            while not port_file.exists():
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("RTL TCP bridge failed to start")
                time.sleep(0.05)
            port = int(port_file.read_text())
            n, k = build.geometry["N"], build.geometry["K"]
            with ReferencePool(args.scenario, n, k) as pool:
                command = [str(miner), "--pool", f"127.0.0.1:{pool.port}", "--user", "local-rtl-qualification",
                           "--params", f"{n},{k}", "--backend", "rtl", "--device", f"127.0.0.1:{port}",
                           "--chips", str(build.geometry["CHIPS"]), "--device-timeout", str(min(args.seconds + 10, 3600)),
                           "--run-seconds", str(args.seconds), "--stats-interval", "1", "--reconnect-ms", "50",
                           "--timeout-seconds", str(min(args.seconds + 10, 3600)), "--memory-limit-mb", "64"]
                dump(output / "command.json", command)
                with (output / "stdout.jsonl").open("w") as stdout, (output / "stderr.log").open("w") as stderr:
                    completed = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=args.seconds + 20)
                pool_result = pool.summary()
            records = [json.loads(line) for line in (output / "stdout.jsonl").read_text().splitlines()]
            final = records[-1] if records else {}
            stats = final.get("stats", {})
            checks = {
                "exit_success": completed.returncode == 0,
                "rtl_selected": final.get("backend") == "rtl",
                "chips_discovered": final.get("device", {}).get("chips") == build.geometry["CHIPS"],
                "complete_duration": final.get("event") == "final" and final.get("elapsed_ms", 0) >= args.seconds * 1000,
                "independent_verifier_clean": not pool_result["errors"],
                "independent_valid_shares": pool_result["valid_shares"] > 0,
                "accepted_shares": stats.get("accepted", 0) > 0,
                "no_worker_failures": stats.get("worker_failures", -1) == 0,
                "accounting": stats.get("submitted", -1) == sum(stats.get(key, 0) for key in ("accepted", "rejected", "unknown")),
                "runner_unchanged": before == {str(p.relative_to(ROOT)): sha(p) for p in paths},
            }
            if args.scenario == "soak":
                checks.update(reconnect=stats.get("reconnects", 0) > 0,
                              jobs=pool_result["jobs_seen"] > 1, rejections=stats.get("rejected", 0) > 0)
            result.update(status="PASS" if all(checks.values()) else "FAIL", checks=checks,
                          geometry=build.geometry, miner=final, pool=pool_result)
    except Exception as exc:
        result["error"] = str(exc)
        raise
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                result.update(status="FAIL", error="RTL bridge failed to cleanly stop")
            result["bridge_exit_code"] = process.returncode
            if "checks" in result:
                result["checks"]["bridge_exit_success"] = process.returncode == 0
            if process.returncode:
                result["status"] = "FAIL"
        result["finished_utc"] = datetime.now(timezone.utc).isoformat()
        result["evidence"] = {str(p.relative_to(output)): sha(p) for p in sorted(output.rglob("*"))
                              if p.is_file() and p.name != "result.json" and "__pycache__" not in p.parts}
        dump(output / "result.json", result)
    print(json.dumps({"status": result["status"], "checks": result.get("checks"), "output": str(output)}), flush=True)
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
