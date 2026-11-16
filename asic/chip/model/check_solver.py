"""prepare: write headers for tb_solver.   check: compare the RTL log with
hw_solve bit-exactly, then verify every solution with the independent
Python verifier and the Zig consensus verifier."""
import os, subprocess, sys, tempfile
from equihash_ref import Params, job_input, zcash_verify, indices_to_minimal
from equihash_np import hw_solve_np as hw_solve  # == equihash_ref.hw_solve

mode, n, k, build = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
NH = int(sys.argv[5]) if len(sys.argv) > 5 else 8
p = Params(n, k)
base = bytes((i * 37 + 11) & 0xFF for i in range(140))
# HDRS="addr:attempt,..." picks specific nonces (e.g. ones known to have
# solutions at mainnet, where an attempt costs ~15 min of simulation)
if os.environ.get("HDRS"):
    picks = [tuple(int(x) for x in t.split(":")) for t in os.environ["HDRS"].split(",")]
    assert len(picks) == NH, "HDRS must list NH headers"
    headers = [job_input(base, addr=a, attempt=t) for a, t in picks]
else:
    headers = [job_input(base, addr=h % 4, attempt=h) for h in range(NH)]

if mode == "prepare":
    with open(os.path.join(build, "solver_hdr.hex"), "w") as f:
        for hd in headers:
            f.write(hd[::-1].hex() + "\n")
    sys.exit(0)

runs, cur = [], None
for line in open(os.path.join(build, "solver_out.txt")):
    tag, *rest = line.split()
    if tag == "A":
        cur = {"sols": []}
        runs.append(cur)
    elif tag == "S":
        cur["sols"].append([int(x) for x in rest])
    elif tag == "D":
        cur["nsol"], cur["cycles"] = int(rest[0]), int(rest[1])
        cur["dropped"] = int(rest[2]) if len(rest) > 2 else 0

assert len(runs) == NH, "expected %d attempts, got %d" % (NH, len(runs))
fails, lines, total = 0, [], 0
PAR = os.environ.get("PAR")   # "bb,slots": bucket-parallel solver, compare sets
DROP_ZERO = os.environ.get("DROP_ZERO", "0") != "0"   # RTL built with DROP_ZERO=1
zero_path = os.path.join(build, "zero_rows.csv")
zero_rows = ([int(line.split(",")[1]) for line in open(zero_path).read().split()[1:]]
             if PAR and os.path.exists(zero_path) else None)
if zero_rows is not None:
    assert len(zero_rows) == NH, "zero-row profile does not cover every attempt"
    assert DROP_ZERO or not any(zero_rows), "rows discarded with DROP_ZERO disabled"
for h, (hd, run) in enumerate(zip(headers, runs)):
    if PAR:
        from par_model import solve_par
        bb, slots = (int(x) for x in PAR.split(","))
        want = solve_par(p, hd, bb, slots, drop_zero=DROP_ZERO)
        if run["dropped"] == 0:
            ok = sorted(run["sols"]) == sorted(want)
        else:   # arbitration decides which rows a full bucket loses
            ok = True
            print("  (%d rows dropped by full buckets: set comparison skipped)" % run["dropped"])
        ok = ok and run["nsol"] == len(run["sols"])
    else:
        want = hw_solve(p, hd)
        ok = run["sols"] == want and run["nsol"] == len(want)
    for s in run["sols"]:
        ok &= zcash_verify(p, hd, s)
        lines.append(hd.hex() + " " + indices_to_minimal(p, s).hex())
    total += len(run["sols"])
    print("attempt %d: rtl %d sols, model %d, %d cycles %s" % (
        h, len(run["sols"]), len(want), run["cycles"], "OK" if ok else "MISMATCH"))
    if not ok:
        fails += 1
        print("  rtl  :", run["sols"])
        print("  model:", want)

miner = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../zig-out/bin/zcash-miner")
if lines:
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write("\n".join(lines) + "\n")
    r = subprocess.run([miner, "--verify", f.name, "--params", "%d,%d" % (n, k)],
                       capture_output=True, text=True)
    os.unlink(f.name)
    print("zig: " + r.stderr.strip().splitlines()[-1])
    fails += r.returncode != 0
if DROP_ZERO:
    print("zero rows discarded per attempt: %s" % zero_rows)
    if not zero_rows or not any(zero_rows):
        print("DROP_ZERO never discarded a row: test is not meaningful")
        fails += 1
if total == 0:
    print("no solutions found at all: test is not meaningful")
    fails += 1
print("check_solver: %s" % ("PASS" if fails == 0 else "FAIL"))
sys.exit(1 if fails else 0)
