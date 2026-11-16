"""Run the numpy hw_solve at mainnet (200,9) and check every solution with
the independent verifier and the Zig consensus verifier."""
import os, subprocess, sys, tempfile, time
from equihash_ref import Params, job_input, zcash_verify, indices_to_minimal
from equihash_np import hw_solve_np

p = Params(200, 9)
base = bytes((i * 37 + 11) & 0xFF for i in range(140))
tries = int(sys.argv[1]) if len(sys.argv) > 1 else 2
lines, total = [], 0
for t in range(tries):
    hdr = job_input(base, 0, t)
    t0 = time.time()
    sols = hw_solve_np(p, hdr)
    ok = all(zcash_verify(p, hdr, s) for s in sols)
    total += len(sols)
    lines += [hdr.hex() + " " + indices_to_minimal(p, s).hex() for s in sols]
    print("attempt %d: %d solutions in %.0fs, python verifier %s" % (t, len(sols), time.time() - t0, "OK" if ok else "FAIL"))
with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
    f.write("\n".join(lines) + "\n")
miner = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../zig-out/bin/zcash-miner")
r = subprocess.run([miner, "--verify", f.name, "--params", "200,9"], capture_output=True, text=True)
os.unlink(f.name)
print("zig: " + r.stderr.strip().splitlines()[-1])
sys.exit(r.returncode)
