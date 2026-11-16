"""Compare complete paired RTL attempts, independently verifying both outputs.

Order may change with arbitration. Compare per-header sets, preserving missing
and added solutions as failures rather than accepting equal solution counts.
This is finite-corpus equivalence, not qualification of the baseline's yield.
"""
import argparse
import csv
import json
from pathlib import Path

from equihash_ref import Params
from yield_study import digest, read_rtl, validated_set, verify_zig, write_json


def read_activity(path):
    """Read all-engine word activity, rejecting malformed/duplicate records."""
    records = {}
    with path.open(newline="") as stream:
        for row in csv.DictReader(stream):
            engine, width, reads, writes = (int(row[k]) for k in
                ("engine", "width_bits", "read_words", "write_words"))
            key = (engine, row["table"])
            if engine < 0 or width <= 0 or min(reads, writes) < 0 or key in records:
                raise ValueError("invalid or duplicate activity record")
            records[key] = (width, reads, writes)
    if not records:
        raise ValueError("empty activity profile")
    engines = {key[0] for key in records}
    if engines != set(range(max(engines) + 1)):
        raise ValueError("noncontiguous activity engines")
    tables = {key[1] for key in records}
    if not {"value", "key", "histogram", "parents", "leaf_indices", "order"} <= tables:
        raise ValueError("missing activity table")
    if set(records) != {(e, t) for e in engines for t in tables}:
        raise ValueError("incomplete engine/table activity profile")
    return records


def compare_activity(baseline, candidate, baseline_solutions, candidate_solutions):
    old, new = read_activity(baseline), read_activity(candidate)
    if old.keys() != new.keys() or any(old[k][0] != new[k][0] for k in old):
        raise ValueError("activity geometries differ")
    def summarize(rows, solutions):
        reads = sum(w*r for w, r, _ in rows.values())
        writes = sum(w*v for w, _, v in rows.values())
        return dict(read_bits=reads, write_bits=writes,
                    accessed_bytes_per_solution=(reads+writes)/8/solutions if solutions else None)
    a, b = summarize(old, baseline_solutions), summarize(new, candidate_solutions)
    return dict(baseline=a, candidate=b,
                read_bit_change_fraction=b["read_bits"]/a["read_bits"]-1 if a["read_bits"] else None,
                scope="Busy-window logical word payload activity across all profiled engines. Not physical access energy, leakage, area or wall power.")


def compare(baseline, candidate, p, miner, *, header_limit=None):
    headers, before = read_rtl(baseline, p)
    after_headers, after = read_rtl(candidate, p)
    corpus_headers = dict(baseline=len(headers), candidate=len(after_headers))
    if any(len(header) != 140 for header in headers + after_headers):
        raise ValueError("RTL headers must contain 140 bytes")
    if header_limit is not None:
        if (type(header_limit) is not int or header_limit <= 0
                or header_limit > min(corpus_headers.values())):
            raise ValueError("header limit must be positive and present in both complete corpora")
        # Parse both entire logs first: a prefix cannot waive an unfinished run.
        headers, before = headers[:header_limit], before[:header_limit]
        after_headers, after = after_headers[:header_limit], after[:header_limit]
    if headers != after_headers:
        raise ValueError("paired RTL headers differ")
    cases = []
    for index, (header, old, new) in enumerate(zip(headers, before, after)):
        a = validated_set(p, header, old["solutions"])
        b = validated_set(p, header, new["solutions"])
        verify_zig(p, header, old["solutions"], miner)
        verify_zig(p, header, new["solutions"], miner)
        cases.append(dict(attempt=index, verified_solutions=len(b), baseline_solutions=len(a),
                          missing=len(a-b), added=len(b-a),
                          baseline_cycles=old["cycles"], candidate_cycles=new["cycles"],
                          baseline_drops=old["dropped"], candidate_drops=new["dropped"]))
    old_cycles = sum(c["baseline_cycles"] for c in cases)
    new_cycles = sum(c["candidate_cycles"] for c in cases)
    evidence = [miner, Path(__file__), Path(__file__).with_name("yield_study.py"),
                Path(__file__).with_name("equihash_ref.py")]
    for directory in (baseline, candidate):
        evidence.extend(directory / name for name in ("solver_hdr.hex", "solver_out.txt"))
        # Older builds have no manifest; never imply one was checked.
        if (directory / "inputs.json").exists():
            evidence.append(directory / "inputs.json")
    return dict(status="PASS" if all(c["missing"] == c["added"] == 0 for c in cases) else "FAIL",
                scope="Exact per-header solution-set comparison with Python and Zig verification; finite corpus only, no physical performance or population yield claim.",
                corpus_headers=corpus_headers,
                selection="all headers" if header_limit is None else "first requested headers only",
                headers=len(headers), verified_solutions=sum(c["verified_solutions"] for c in cases),
                baseline_cycles=old_cycles, candidate_cycles=new_cycles,
                cycle_change_fraction=new_cycles / old_cycles - 1,
                evidence_sha256={str(path): digest(path.read_bytes()) for path in evidence},
                attempts=cases)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("baseline", type=Path)
    ap.add_argument("candidate", type=Path)
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--k", type=int, default=9)
    ap.add_argument("--activity", action="store_true", help="compare complete-corpus SRAM payload activity")
    ap.add_argument("--headers", type=int,
                    help="compare this many initial headers from two complete runs; default requires identical full corpora")
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    if args.headers is not None and args.headers <= 0:
        ap.error("--headers must be positive")
    if args.activity and args.headers is not None:
        ap.error("activity profiles cover entire runs; --headers cannot be combined with --activity")
    # A failed rerun must never leave an old PASS report in the requested path.
    if args.output.exists():
        ap.error("output already exists; choose a new evidence path")
    miner = (Path(__file__).resolve().parents[3] / "zig-out/bin/zcash-miner")
    result = compare(args.baseline, args.candidate, Params(args.n, args.k), miner,
                     header_limit=args.headers)
    if args.activity:
        paths = [d / "memory_accesses.csv" for d in (args.baseline, args.candidate)]
        result["activity"] = compare_activity(*paths, sum(c["baseline_solutions"] for c in result["attempts"]),
                                              result["verified_solutions"])
        result["evidence_sha256"].update({str(p): digest(p.read_bytes()) for p in paths})
    write_json(args.output, result)
    print(json.dumps({k: result[k] for k in ("status", "headers", "verified_solutions",
                                            "baseline_cycles", "candidate_cycles", "cycle_change_fraction")}, indent=2))
    raise SystemExit(0 if result["status"] == "PASS" else 1)


if __name__ == "__main__":
    main()
