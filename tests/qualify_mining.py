#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run a source-bound local mining qualification and retain its evidence.

Examples:
  python tests/qualify_mining.py --seconds 300 --params 200,9 --scenario normal --output private/mainnet-v1
  python tests/qualify_mining.py --seconds 86400 --scenario soak --output private/soak-v1

A short run is explicitly a short run. Only a completed 86400-second run can
claim 24-hour coverage. The independent server never contacts a public pool.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time
from pool_harness import ROOT, ReferencePool


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dump(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def snapshot(output, miner):
    source_paths = [ROOT / "build.zig", ROOT / "build.zig.zon", *sorted((ROOT / "src").glob("*.zig")),
                    *sorted((ROOT / "gpu").rglob("*.c")), *sorted((ROOT / "gpu").rglob("*.h"))]
    before = {str(p.relative_to(ROOT)): sha(p) for p in source_paths}
    with (output / "build.log").open("w") as log:
        subprocess.run(["zig", "build", "-Doptimize=ReleaseFast"], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    after = {str(p.relative_to(ROOT)): sha(p) for p in source_paths}
    if before != after:
        raise RuntimeError("sources changed during the qualification build")
    if sha(miner) != sha(ROOT / "zig-out/bin/zcash-miner"):
        raise ValueError("selected miner does not match the freshly built source")
    frozen = output / "zcash-miner"
    shutil.copy2(miner, frozen)
    source = output / "source"
    source.mkdir()
    for name in ("src", "gpu"):
        shutil.copytree(ROOT / name, source / name)
    for name in ("build.zig", "build.zig.zon", "LICENSE", "LICENSING.md", "NOTICE", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(ROOT / name, source / name)
    shutil.copytree(ROOT / "LICENSES", source / "LICENSES")
    if any(sha(source / name) != digest for name, digest in after.items()):
        raise RuntimeError("sources changed while taking the snapshot")
    verifier = output / "verifier"
    verifier.mkdir()
    for path in (Path(__file__), Path(__file__).with_name("pool_harness.py"), ROOT / "asic/chip/model/equihash_ref.py"):
        shutil.copy2(path, verifier / path.name)
    manifest = {str(p.relative_to(output)): sha(p) for p in sorted(output.rglob("*")) if p.is_file()}
    dump(output / "inputs.json", {"files": manifest,
        "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_snapshot_is_authoritative": True,
        "build_command": ["zig", "build", "-Doptimize=ReleaseFast"],
        "zig_version": subprocess.check_output(["zig", "version"], text=True).strip(),
        "public_pool_contacted": False})
    return frozen


def resource_sample(pid):
    try:
        fields = dict(line.split(":", 1) for line in Path(f"/proc/{pid}/status").read_text().splitlines() if ":" in line)
        return {"rss_kib": int(fields.get("VmRSS", "0 kB").split()[0]),
                "peak_rss_kib": int(fields.get("VmHWM", "0 kB").split()[0]),
                "threads": int(fields.get("Threads", "0"))}
    except (FileNotFoundError, ProcessLookupError):
        return {"rss_kib": 0, "peak_rss_kib": 0, "threads": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, required=True)
    parser.add_argument("--params", default="48,5", choices=("48,5", "96,5", "200,9"))
    parser.add_argument("--scenario", default="soak", choices=("normal", "soak"))
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--memory-limit-mb", type=int, default=3072)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--miner", type=Path, default=ROOT / "zig-out/bin/zcash-miner")
    args = parser.parse_args()
    if args.seconds < 1 or args.threads < 1:
        parser.error("duration and thread count must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    miner = snapshot(output, args.miner)
    n, k = map(int, args.params.split(","))
    started = datetime.now(timezone.utc).isoformat()
    peak_rss_kib = 0
    with ReferencePool(args.scenario, n, k, pace=0.02) as pool:
        command = [str(miner), "--pool", f"127.0.0.1:{pool.port}", "--user", "local-qualification",
                   "--params", args.params, "--threads", str(args.threads),
                   "--memory-limit-mb", str(args.memory_limit_mb), "--run-seconds", str(args.seconds),
                   "--stats-interval", "5", "--timeout-seconds", str(max(120, min(3600, args.seconds + 10))),
                   "--reconnect-ms", "100"]
        dump(output / "run.json", {"started_utc": started, "requested_seconds": args.seconds,
             "scenario": args.scenario, "command": command, "status": "RUNNING"})
        begin = time.monotonic()
        with (output / "stdout.jsonl").open("w") as stdout, (output / "stderr.log").open("w") as stderr, (output / "resources.jsonl").open("w") as resources:
            process = subprocess.Popen(command, stdout=stdout, stderr=stderr)
            try:
                while process.poll() is None:
                    sample = resource_sample(process.pid)
                    peak_rss_kib = max(peak_rss_kib, sample["peak_rss_kib"])
                    sample["elapsed_seconds"] = time.monotonic() - begin
                    resources.write(json.dumps(sample) + "\n")
                    resources.flush()
                    if sample["elapsed_seconds"] > args.seconds + 30:
                        raise TimeoutError("miner did not stop within its shutdown allowance")
                    if sample["rss_kib"] > (args.memory_limit_mb + 256) * 1024:
                        raise MemoryError("miner exceeded allocation budget plus process-overhead allowance")
                    time.sleep(1)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
        pool_result = pool.summary()
    records = [json.loads(line) for line in (output / "stdout.jsonl").read_text().splitlines()]
    final = records[-1] if records else {}
    stats = final.get("stats", {})
    checks = {
        "exit_success": process.returncode == 0,
        "complete_duration": final.get("event") == "final" and final.get("elapsed_ms", 0) >= args.seconds * 1000,
        "independent_verifier_clean": not pool_result["errors"],
        "independent_valid_shares": pool_result["valid_shares"] > 0,
        "acknowledged_acceptance": stats.get("accepted", 0) > 0,
        "submission_accounting": stats.get("submitted", -1) == sum(stats.get(key, 0) for key in ("accepted", "rejected", "unknown")),
        "no_worker_failure": stats.get("worker_failures", -1) == 0,
    }
    if args.scenario == "soak":
        checks.update({"reconnect_exercised": stats.get("reconnects", 0) > 0,
                       "malformed_input_exercised": stats.get("malformed", 0) > 0,
                       "rejection_exercised": stats.get("rejected", 0) > 0,
                       "job_updates_exercised": pool_result["jobs_seen"] > 1})
    result = {"status": "PASS" if all(checks.values()) else "FAIL", "checks": checks,
              "requested_seconds": args.seconds, "actual_seconds": time.monotonic() - begin,
              "qualifies_24_hours": args.seconds >= 86400 and all(checks.values()),
              "params": [n, k], "peak_rss_kib": peak_rss_kib, "miner": final, "pool": pool_result,
              "finished_utc": datetime.now(timezone.utc).isoformat(),
              "evidence": {name: sha(output / name) for name in ("inputs.json", "run.json", "stdout.jsonl", "stderr.log", "resources.jsonl")}}
    dump(output / "result.json", result)
    print(json.dumps({"status": result["status"], "output": str(output), "checks": checks}), flush=True)
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
