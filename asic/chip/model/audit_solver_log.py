"""Regenerate complete reference sets for an archived solver output log.

This audits outputs, not simulation provenance or production release. Invoke
through tb/audit_par_archive.py to freeze inputs and bind the resulting evidence.
"""
import argparse
import hashlib
import json
from pathlib import Path

from equihash_np import hw_solve_np
from equihash_ref import Params, job_input
from yield_study import read_rtl, summarize, validated_set, verify_zig, write_json


def audit_attempt(p, header, run, miner):
    stats = {}
    full = hw_solve_np(p, header, cap=4*p.init, gmax=64, stats=stats, distinct=True)
    if any(stats.get("group_rows_dropped", [])) or any(stats.get("row_cap_dropped", [])):
        raise ValueError("reference truncated rows; cannot qualify solution retention")
    reference = validated_set(p, header, full)
    verify_zig(p, header, full, miner)
    got = validated_set(p, header, run["solutions"])
    verify_zig(p, header, run["solutions"], miner)
    if got != reference:
        raise ValueError(f"reference set mismatch: {len(reference-got)} missing, "
                         f"{len(got-reference)} unexpected; row drops do not waive loss")
    return dict(header=header.hex(), reference_count=len(reference),
                reference_solutions=[list(s) for s in sorted(reference)],
                reference_stats=stats, candidates=dict(rtl=dict(
                    count=len(got), cycles=run["cycles"], dropped=run["dropped"],
                    missing_reference_solutions=0)))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--run", type=Path, required=True)
    ap.add_argument("--inputs", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    a = ap.parse_args()
    inputs = json.loads(a.inputs.read_text())
    cfg = inputs["parameters"]
    p = Params(cfg["N"], cfg["K"])
    headers, runs = read_rtl(a.run, p)
    expected = [job_input(hashlib.shake_256(f'{inputs["seed"]}:{i}'.encode()).digest(140),
                          addr=i%4, attempt=i) for i in range(cfg["NH"])]
    if headers != expected:
        raise ValueError("archived headers differ from the recorded deterministic corpus")
    miner = (Path(__file__).resolve().parent / "../../../zig-out/bin/zcash-miner").resolve()
    if not miner.is_file():
        raise ValueError("archived independent Zig verifier is missing")
    a.output.mkdir()
    samples = []
    for i, (header, run) in enumerate(zip(headers, runs)):
        sample = audit_attempt(p, header, run, miner)
        write_json(a.output/f"sample_{i:04d}.json", sample)
        samples.append(sample)
        print(f"header {i}: complete reference={sample['reference_count']}, "
              f"RTL={sample['candidates']['rtl']['count']}; exact set PASS", flush=True)
    result = summarize(samples, ["rtl"])
    result.update(status="PASS", scope=__doc__.strip(), simulation_replayed=False,
                  production_release_qualified=False)
    write_json(a.output/"summary.json", result)
    print(json.dumps(result, indent=2), flush=True)


if __name__ == "__main__":
    main()
