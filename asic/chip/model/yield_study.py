"""Paired capacity study with verified reference solutions and resumable evidence.

Model capacity results are not RTL yield or power measurements. Optional RTL
logs are compared against the same per-header reference without waiving missing
solutions when buckets overflow. Reference truncation is a hard failure.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

import numpy as np

from equihash_ref import Params, indices_to_minimal, job_input, zcash_verify
from equihash_np import hw_solve_np
from par_model import solve_par

MODEL_DIR = Path(__file__).resolve().parent


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2) + "\n")
    tmp.replace(path)


def read_rtl(build, p):
    headers = [bytes.fromhex(x)[::-1] for x in (build / "solver_hdr.hex").read_text().splitlines()]
    runs = []
    current = None
    for line in (build / "solver_out.txt").read_text().splitlines():
        tag, *fields = line.split()
        if tag == "A":
            if current is not None or len(fields) != 1 or int(fields[0]) != len(runs):
                raise ValueError("invalid or incomplete RTL attempt sequence")
            current = {"solutions": []}
        elif tag == "S" and current is not None:
            sol = list(map(int, fields))
            if len(sol) != 1 << p.k:
                raise ValueError("wrong RTL solution length")
            current["solutions"].append(sol)
        elif tag == "D" and current is not None:
            if len(fields) != 3:
                raise ValueError("RTL log must include nsol, cycles and dropped")
            nsol, cycles, dropped = map(int, fields)
            if nsol != len(current["solutions"]) or cycles <= 0 or dropped < 0:
                raise ValueError("invalid RTL completion counters")
            current.update(cycles=cycles, dropped=dropped)
            runs.append(current)
            current = None
        else:
            raise ValueError("malformed RTL log")
    if current is not None or len(runs) != len(headers) or not runs:
        raise ValueError("RTL log is incomplete")
    return headers, runs


def validated_set(p, header, sols):
    result = set(map(tuple, sols))
    if len(result) != len(sols):
        raise ValueError("duplicate solutions inflate measured yield")
    if not all(zcash_verify(p, header, s) for s in sols):
        raise ValueError("independent Python verification failed")
    return result


def verify_zig(p, header, sols, miner):
    if not sols:
        return
    with tempfile.NamedTemporaryFile("w", suffix=".txt") as f:
        for sol in sols:
            f.write(header.hex() + " " + indices_to_minimal(p, sol).hex() + "\n")
        f.flush()
        r = subprocess.run([str(miner), "--verify", f.name, "--params", f"{p.n},{p.k}"],
                           capture_output=True, text=True)
        if r.returncode:
            raise ValueError("independent Zig verification failed: " + r.stderr)


def summarize(samples, names):
    reference = np.array([s["reference_count"] for s in samples], dtype=np.int64)
    total_ref = int(reference.sum())
    rng = np.random.default_rng(173)
    draws = rng.integers(0, len(samples), size=(4000, len(samples)))
    denominators = reference[draws].sum(axis=1)
    results = {}
    for name in names:
        counts = np.array([s["candidates"][name]["count"] for s in samples], dtype=np.int64)
        ratios = counts[draws].sum(axis=1)[denominators > 0] / denominators[denominators > 0]
        result = dict(solutions=int(counts.sum()), reference_solutions=total_ref,
                      retained_fraction=float(counts.sum() / total_ref) if total_ref else None,
                      paired_header_bootstrap_95=list(map(float, np.quantile(ratios, [0.025, 0.975]))) if len(ratios) else None,
                      missing_reference_solutions=int((reference-counts).sum()))
        if name == "rtl":
            cycles = sum(s["candidates"][name]["cycles"] for s in samples)
            result.update(total_cycles=cycles, verified_solutions_per_cycle=int(counts.sum())/cycles)
        results[name] = result
    return dict(headers=len(samples), results=results,
                uncertainty_note="Paired bootstrap resamples whole headers. A degenerate interval, especially with zero observed losses, does not establish population-level losslessness. No energy or attainable clock is measured.")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--k", type=int, default=9)
    ap.add_argument("--bb", type=int, default=12)
    ap.add_argument("--headers", type=int, default=16)
    ap.add_argument("--reference-cap-multiple", type=int, default=4)
    ap.add_argument("--seed", default="zeq-production-yield-v1")
    ap.add_argument("--capacities", type=int, nargs="+", default=[640, 768, 1024])
    ap.add_argument("--bucket0-slots", type=int)
    ap.add_argument("--rtl-build", type=Path)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    if args.headers <= 0 or args.reference_cap_multiple <= 0 or any(x <= 0 for x in args.capacities):
        ap.error("positive header count and capacities required")
    if args.bucket0_slots is not None and args.bucket0_slots < max(args.capacities):
        ap.error("bucket-zero capacity must cover every requested regular capacity")
    p = Params(args.n, args.k)
    if not 0 < args.bb < p.cb:
        ap.error("bucket bits must be below collision width")
    miner = (MODEL_DIR / "../../../zig-out/bin/zcash-miner").resolve()
    if not miner.is_file():
        ap.error("independent Zig verifier is required")
    rtl_runs = None
    if args.rtl_build:
        headers, rtl_runs = read_rtl(args.rtl_build, p)
    else:
        # Every case has a distinct base header as well as address/nonce.
        headers = [job_input(hashlib.shake_256(f"{args.seed}:{i}".encode()).digest(140),
                             addr=i % 4, attempt=i) for i in range(args.headers)]
    def capacity_name(c):
        return f"slots_{c}" + (f"_bucket0_{args.bucket0_slots}" if args.bucket0_slots is not None else "")
    names = [capacity_name(c) for c in args.capacities] + (["rtl"] if rtl_runs else [])
    source_hashes = {name: digest((MODEL_DIR / name).read_bytes()) for name in
                     ["yield_study.py", "par_model.py", "equihash_np.py", "equihash_ref.py"]}
    manifest = dict(n=p.n, k=p.k, bb=args.bb, capacities=args.capacities,
                    headers=[h.hex() for h in headers], source_hashes=source_hashes,
                    verifier_sha256=digest(miner.read_bytes()),
                    reference=dict(gmax=64, cap=args.reference_cap_multiple*p.init, require_no_truncation=True, prune_repeated_partial_indices=True),
                    rtl_log_sha256=digest((args.rtl_build / "solver_out.txt").read_bytes()) if rtl_runs else None,
                    scope="Capacity model and optional exact RTL log; no physical energy measurement")
    if args.bucket0_slots is not None:
        manifest['bucket0_slots'] = args.bucket0_slots
    args.output.mkdir(parents=True, exist_ok=True)
    manifest_path = args.output / "manifest.json"
    if manifest_path.exists() and json.loads(manifest_path.read_text()) != manifest:
        raise ValueError("existing study differs in inputs or implementation; use a new output directory")
    write_json(manifest_path, manifest)
    manifest_hash = digest(json.dumps(manifest, sort_keys=True).encode())
    samples = []
    for i, header in enumerate(headers):
        path = args.output / f"sample_{i:04d}.json"
        if path.exists():
            sample = json.loads(path.read_text())
            if sample["manifest_sha256"] != manifest_hash or sample["header"] != header.hex():
                raise ValueError("cached sample provenance mismatch")
        else:
            stats = {}
            full = hw_solve_np(p, header, cap=args.reference_cap_multiple*p.init, gmax=64, stats=stats, distinct=True)
            if any(stats.get("group_rows_dropped", [])) or any(stats.get("row_cap_dropped", [])):
                write_json(args.output / f"rejected_{i:04d}.json", dict(header=header.hex(), reference_stats=stats, manifest_sha256=manifest_hash))
                raise ValueError("reference solver truncated rows; cannot qualify yield: " + json.dumps(stats))
            reference = validated_set(p, header, full)
            verify_zig(p, header, full, miner)
            candidates = {}
            for capacity in args.capacities:
                st = {}
                sols = solve_par(p, header, args.bb, capacity, stats=st, bucket0_slots=args.bucket0_slots)
                got = validated_set(p, header, sols)
                if not got <= reference:
                    raise ValueError("candidate solution absent from untruncated reference")
                candidates[capacity_name(capacity)] = dict(count=len(got), dropped_by_level=st.get("dropped", []),
                                                        max_bucket_fill_by_level=st.get("maxfill", []))
            if rtl_runs:
                run = rtl_runs[i]
                got = validated_set(p, header, run["solutions"])
                verify_zig(p, header, run["solutions"], miner)
                if not got <= reference:
                    raise ValueError("RTL solution absent from untruncated reference")
                candidates["rtl"] = dict(count=len(got), cycles=run["cycles"], dropped=run["dropped"],
                                          missing_reference_solutions=len(reference-got))
            sample = dict(manifest_sha256=manifest_hash, header=header.hex(), reference_count=len(reference),
                          reference_stats=stats, candidates=candidates)
            write_json(path, sample)
        samples.append(sample)
        print(f"header {i}: reference {sample['reference_count']}, " +
              ", ".join(f"{n}={c['count']}" for n,c in sample["candidates"].items()), flush=True)
    result = summarize(samples, names)
    result["manifest_sha256"] = manifest_hash
    result["status"] = "completed; sample evidence only, not production qualification"
    write_json(args.output / "summary.json", result)
    print(json.dumps(result, indent=2), flush=True)


if __name__ == "__main__":
    main()
