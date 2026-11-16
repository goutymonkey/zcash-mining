#!/usr/bin/env python3
"""Run packed SRAM induction and counterexample-required mutation checks.

Use inside the LibreLane image (yosys on PATH). Evidence records the exact
sources and tool version. A timeout, tool error or surviving mutant fails.
This checks concrete small depths, not arbitrary SRAM depth or macro timing.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ["rtl/zeq_mbist.v", "rtl/zeq_ram.v", "rtl/zeq_packed_values.v",
           "formal/packed_values.sv", "formal/qualify_packed.py"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_case(build, name, n, k, pw, depth, mutant=None):
    rtl = ROOT / "rtl/zeq_packed_values.v"
    if mutant:
        source = rtl.read_text()
        old, new = mutant
        if source.count(old) != 1:
            raise ValueError("mutation site must be unique")
        rtl = build / f"{name}.v"
        rtl.write_text(source.replace(old, new))
    aw = (depth - 1).bit_length()
    script = f'''
read_verilog -sv -D SYNTHESIS -D PACKED_PROOF "{ROOT}/rtl/zeq_mbist.v" "{ROOT}/rtl/zeq_ram.v" "{rtl}";
read_verilog -formal -sv -D PACKED_PROOF "{ROOT}/formal/packed_values.sv";
chparam -set N {n} -set K {k} -set PW {pw} -set AW {aw} -set DEPTH {depth} packed_values_formal;
prep -top packed_values_formal -flatten;
wreduce; opt -full; memory_map; opt -full; async2sync; dffunmap; techmap; opt -full;
'''
    # Bounded mutants must yield an actual reachable counterexample, rather
    # than merely failing induction from an unreachable internal state.
    if mutant:
        script += f'sat -timeout 180 -seq {k+4} -prove-asserts -set-assumes -dump_json "{build}/{name}-counterexample.json";\n'
    else:
        script += 'sat -timeout 180 -tempinduct -seq 2 -maxsteps 6 -prove-asserts -set-assumes -verify;\n'
    script_path = build / f"{name}.ys"
    script_path.write_text(script)
    log = build / f"{name}.log"
    with log.open("w") as out:
        proc = subprocess.run(["yosys", "-Q", "-T", "-s", str(script_path)],
                              cwd=ROOT, stdout=out, stderr=subprocess.STDOUT)
    output = log.read_text()
    marker = ("SAT proof finished - model found: FAIL!" if mutant
              else "Induction step proven: SUCCESS!")
    passed = proc.returncode == 0 and marker in output
    if mutant:
        passed &= (build / f"{name}-counterexample.json").is_file()
    result = dict(name=name, n=n, k=k, pw=pw, depth=depth,
                  check="reachable mutation counterexample" if mutant else "induction",
                  status="PASS" if passed else "FAIL", exit_code=proc.returncode,
                  log_sha256=sha(log), script_sha256=sha(script_path))
    print(f"{name}: {result['status']}", flush=True)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build", type=Path, required=True)
    args = ap.parse_args()
    build = args.build.resolve()
    # Do not permit stale PASS evidence to survive a failed or partial rerun.
    build.mkdir(parents=True, exist_ok=False)
    manifest = dict(files={p: sha(ROOT / p) for p in SOURCES},
                    yosys=subprocess.check_output(["yosys", "-V"], text=True).strip())
    with tarfile.open(build / "source.tgz", "w:gz") as archive:
        for p in SOURCES:
            archive.add(ROOT / p, arcname=p)
    manifest["archive_sha256"] = sha(build / "source.tgz")
    (build / "inputs.json").write_text(json.dumps(manifest, indent=2) + "\n")
    results = []
    for n, k, pw in [(48, 5, 18), (200, 9, 32)]:
        for depth in [2, 3]:
            results.append(run_case(build, f"n{n}-depth{depth}", n, k, pw, depth))
    for name, mutation in [
        ("value-corrupt", ("? q[32'(read_parity_q)*TOTAL+bit_i] : 1'b0;",
                           "? ~q[32'(read_parity_q)*TOTAL+bit_i] : 1'b0;")),
        ("parent-corrupt", ("assign pvalue = q[", "assign pvalue = ~q[")),
        ("write-address-alias", (".waddr(waddr), .wdata(wd)",
                                 ".waddr({AW{1'b0}}), .wdata(wd)")),
    ]:
        results.append(run_case(build, name, 48, 5, 18, 3, mutation))
    report = dict(status="PASS" if all(r["status"] == "PASS" for r in results) else "FAIL",
                  scope="Whole-word values and retained parents at depths 2 and 3; arbitrary data, legal addresses, phase stalls, cancellation to phase zero and repeated reset. BIST never started. No general-depth or physical macro proof.",
                  inputs_sha256=sha(build / "inputs.json"), cases=results)
    (build / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    raise SystemExit(0 if report["status"] == "PASS" else 1)


if __name__ == "__main__":
    main()
