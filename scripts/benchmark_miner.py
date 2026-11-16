#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Reproduce paired first/all-solution benchmarks with independent verification."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "asic/chip/model"))
from equihash_ref import Params, minimal_to_indices, zcash_verify


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dump(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--params", choices=("48,5", "96,5", "200,9"), default="200,9")
    parser.add_argument("--cases", type=int, default=4)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--corpus", type=Path)
    parser.add_argument("--memory-limit-mb", type=int, default=3072)
    parser.add_argument("--timeout-seconds", type=int, default=3600)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--miner", type=Path, default=ROOT / "zig-out/bin/zcash-miner")
    args = parser.parse_args()
    if not 1 <= args.cases <= 256 or not 1 <= args.repeats <= 10:
        parser.error("cases must be 1..256 and repeats 1..10")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    source_files = [ROOT / "build.zig", ROOT / "build.zig.zon", *sorted((ROOT / "src").glob("*.zig")), *sorted((ROOT / "gpu").rglob("*.c")), *sorted((ROOT / "gpu").rglob("*.h"))]
    before_build = {str(p.relative_to(ROOT)): sha(p) for p in source_files}
    with (out / "build.log").open("w") as log:
        subprocess.run(["zig", "build", "-Doptimize=ReleaseFast"], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    if sha(args.miner.resolve()) != sha(ROOT / "zig-out/bin/zcash-miner"):
        raise ValueError("selected miner does not match the freshly built source")
    miner = out / "zcash-miner"
    shutil.copy2(args.miner.resolve(), miner)
    n, k = map(int, args.params.split(","))
    params = Params(n, k)
    corpus = out / "headers.txt"
    if args.corpus:
        corpus.write_bytes(args.corpus.read_bytes())
    else:
        # Hash-derived independent inputs do not select for solution count.
        headers = [hashlib.shake_256(f"zcash-public-benchmark-v1:{i}".encode()).digest(140) for i in range(args.cases)]
        corpus.write_text("# zcash-public-benchmark-v1, SHAKE256(seed:index), 140 bytes\n" + "\n".join(h.hex() for h in headers) + "\n")
    inputs = [bytes.fromhex(line.strip()) for line in corpus.read_text().splitlines() if line.strip() and not line.lstrip().startswith("#")]
    if not inputs or any(len(h) != 140 for h in inputs):
        parser.error("corpus must contain at least one 140-byte header input")
    cpu = "unknown"
    for line in Path("/proc/cpuinfo").read_text().splitlines():
        if line.startswith("model name"):
            cpu = line.partition(":")[2].strip()
            break
    metadata = {"started_utc": datetime.now(timezone.utc).isoformat(), "params": [n, k],
                "binary_sha256": sha(miner), "corpus_sha256": sha(corpus),
                "sources": {str(p.relative_to(ROOT)): sha(p) for p in source_files},
                "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "zig": subprocess.check_output(["zig", "version"], text=True).strip(),
                "cpu": cpu, "logical_cpus": os.cpu_count(), "platform": platform.platform(),
                "load_average_at_start": os.getloadavg(), "repeats": args.repeats,
                "scope": "CPU solver only; no pool, device energy or profitability measurement"}
    if metadata["sources"] != before_build:
        raise RuntimeError("sources changed during the benchmark build/snapshot")
    dump(out / "inputs.json", metadata)
    records = {"first": [], "all": []}
    reference_sets = None
    for repeat in range(args.repeats):
        # Alternate order to reduce a systematic first-run bias.
        for mode in (("first", "all") if repeat % 2 == 0 else ("all", "first")):
            command = [str(miner), "--bench", "--params", args.params, "--corpus", str(corpus),
                       "--solutions", mode, "--memory-limit-mb", str(args.memory_limit_mb)]
            result = subprocess.run(command, text=True, capture_output=True, timeout=args.timeout_seconds)
            (out / f"{mode}-{repeat}.jsonl").write_text(result.stdout)
            (out / f"{mode}-{repeat}.stderr").write_text(result.stderr)
            if result.returncode:
                dump(out / "result.json", {"status": "FAIL", "mode": mode, "repeat": repeat, "exit_code": result.returncode})
                return 1
            batch = [json.loads(line) for line in result.stdout.splitlines()]
            if len(batch) != len(inputs):
                raise ValueError("incomplete benchmark output")
            sets = []
            for expected_input, record in zip(inputs, batch):
                if bytes.fromhex(record["input"]) != expected_input:
                    raise ValueError("benchmark input differs from frozen corpus")
                solutions = record["solutions"]
                if len(set(solutions)) != len(solutions):
                    raise ValueError("duplicate solution")
                for solution in solutions:
                    minimal = bytes.fromhex(solution)
                    if len(minimal) != params.solution_size() or not zcash_verify(params, expected_input, minimal_to_indices(params, minimal)):
                        raise ValueError("independent verifier rejected solution")
                sets.append(set(solutions))
            if mode == "all":
                if reference_sets is not None and sets != reference_sets:
                    raise ValueError("solution sets changed across repeated identical inputs")
                reference_sets = sets
            records[mode].extend(batch)
    for i, record in enumerate(records["first"]):
        if not set(record["solutions"]) <= reference_sets[i % len(inputs)]:
            raise ValueError("all-solutions run lost a first-solution result")
    summary = {}
    for mode, batch in records.items():
        seconds = sum(r["elapsed_ns"] for r in batch) / 1e9
        total = sum(len(r["solutions"]) for r in batch)
        summary[mode] = {"verified_solutions": total, "solve_seconds": seconds,
                         "verified_solutions_per_second": total / seconds,
                         "median_nonce_seconds": statistics.median(r["elapsed_ns"] for r in batch) / 1e9,
                         "max_nonce_seconds": max(r["elapsed_ns"] for r in batch) / 1e9,
                         "peak_requested_bytes": max(r["peak_requested_bytes"] for r in batch),
                         "process_peak_rss_bytes": max(r["process_peak_rss_bytes"] for r in batch)}
    first_rate = summary["first"]["verified_solutions_per_second"]
    result = {"status": "PASS", "independent_verification": True,
              "universal_completeness_claim": False, "summary": summary,
              "all_over_first_throughput": summary["all"]["verified_solutions_per_second"] / first_rate if first_rate else None,
              "evidence": {p.name: sha(p) for p in sorted(out.iterdir()) if p.is_file()},
              "finished_utc": datetime.now(timezone.utc).isoformat()}
    dump(out / "result.json", result)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
