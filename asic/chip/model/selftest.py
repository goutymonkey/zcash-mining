"""Model self-test: hw_solve output must pass the independent verifier and
the Zig consensus verifier; tampered solutions must fail."""
import os, subprocess, sys, tempfile, time
from equihash_ref import *

p = Params(48, 5)
base = bytes(range(140))
lines, total, t0 = [], 0, time.time()
for attempt in range(8):
    hdr = job_input(base, addr=0, attempt=attempt)
    sols = hw_solve(p, hdr)
    for s in sols:
        assert zcash_verify(p, hdr, s), ("python verifier rejected", attempt, s)
        assert minimal_to_indices(p, indices_to_minimal(p, s)) == s
        lines.append(hdr.hex() + " " + indices_to_minimal(p, s).hex())
        # tamper: swap the two halves' order -> must fail ordering check
        bad = s[16:] + s[:16]
        assert not zcash_verify(p, hdr, bad)
        bad2 = list(s); bad2[3] ^= 1
        assert not zcash_verify(p, hdr, bad2)
    total += len(sols)
    print("attempt %d: %d solutions" % (attempt, len(sols)))
print("model: %d solutions in %.1fs, all pass python verifier" % (total, time.time() - t0))
with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
    f.write("\n".join(lines) + "\n")
miner = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../zig-out/bin/zcash-miner")
r = subprocess.run([miner, "--verify", f.name, "--params", "48,5"], capture_output=True, text=True)
os.unlink(f.name)
print(r.stderr.strip().splitlines()[-1])
sys.exit(r.returncode)
