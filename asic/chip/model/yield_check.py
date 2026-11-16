"""Solutions per attempt at mainnet (200,9): the chip's caps (GMAX=16,
CAP=2*INIT) versus a near-complete solver (GMAX=64, CAP=4*INIT) on the
same nonces. Every solution is checked with the independent verifier."""
import sys, time
from equihash_ref import Params, job_input, zcash_verify
from equihash_np import hw_solve_np

p = Params(200, 9)
base = bytes((i * 37 + 11) & 0xFF for i in range(140))
tries = int(sys.argv[1]) if len(sys.argv) > 1 else 8
chip = full = 0
for t in range(tries):
    hdr = job_input(base, 0, t)
    t0 = time.time()
    a = hw_solve_np(p, hdr)
    b = hw_solve_np(p, hdr, cap=4 * p.init, gmax=64)
    assert all(zcash_verify(p, hdr, s) for s in a + b)
    assert all(s in b for s in a), "capped solver found a solution the full one missed"
    chip += len(a)
    full += len(b)
    print("nonce %d: chip %d, near-complete %d  (%.0fs)" % (t, len(a), len(b), time.time() - t0), flush=True)
print("TOTAL over %d nonces: chip %d (%.2f/nonce), near-complete %d (%.2f/nonce), yield %.1f%%" % (
    tries, chip, chip / tries, full, full / tries, 100.0 * chip / max(full, 1)))
