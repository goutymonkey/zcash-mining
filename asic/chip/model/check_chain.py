"""prepare: write the two JOB headers for tb_chain.   check: decode
everything the chain sent upstream and check it against the reference model:
  - valid framing and CRC on every packet (incl. ones forwarded 3 hops)
  - one PONG per chip, reporting LANES lanes
  - no DONE sent twice
  - for every finished attempt (job, addr, n): the SOLUTION packets equal
    hw_solve(that job's header with nonce {addr, n}) exactly, and DONE's
    count matches
  - attempts cut short by a new JOB or STOP sent a prefix of the model's
    solutions
  - both jobs finished ATTEMPTS attempts on every chip
  - every solution passes the Python and Zig verifiers"""
import collections, hashlib, os, subprocess, sys, tempfile
from equihash_ref import (Params, job_input, zcash_verify, indices_to_minimal,
                          parse_packets, RSP_SOLUTION, RSP_PONG, RSP_DONE)
from equihash_np import hw_solve_np as hw_solve  # == equihash_ref.hw_solve
from par_model import solve_par
from chain_audit import validate_packets
SHARE_FILTER = int(os.environ.get("SHARE_FILTER", "1")) != 0
PAR_CHAIN = bool(os.environ.get("PAR_CHAIN"))
# "bb,slots[,relaxed]": bucket config; relaxed = buckets may overflow, so
# check got is a subset of the complete set and >= 70% of it overall
PAR_CFG = os.environ.get("PAR_CFG", "4,256").split(",")
PAR_BB_, PAR_SLOTS = int(PAR_CFG[0]), int(PAR_CFG[1])
RELAXED = len(PAR_CFG) > 2
found_total, got_total = [0], [0]

CHIPS, ATTEMPTS = 4, 2
LANES = int(os.environ.get("LANES", "2"))
mode, n, k, build = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
p = Params(n, k)
jobs = {1: bytes((i * 91 + 7) & 0xFF for i in range(140)),
        2: bytes((i * 53 + 201) & 0xFF for i in range(140))}
# share target per job (big-endian): job 1 accepts all, job 2 about half
targets = {1: (1 << 256) - 1, 2: 1 << 255}


def is_share(hdr, sol, target):
    """Zcash block hash (as pow.zig blockHash) as LE number <= target."""
    m = indices_to_minimal(p, sol)
    pre = bytes([len(m)]) if len(m) < 253 else b"\xfd" + len(m).to_bytes(2, "little")
    h = hashlib.sha256(hashlib.sha256(hdr + pre + m).digest()).digest()
    return int.from_bytes(h, "little") <= target

if mode == "prepare":
    with open(os.path.join(build, "chain_job.hex"), "w") as f:
        f.write("\n".join("%02x" % b for b in jobs[1] + jobs[2]) + "\n")
    sys.exit(0)

raw = bytes(int(l, 16) for l in open(os.path.join(build, "chain_rx.hex")) if l.strip())
pkts = parse_packets(raw)          # raises on framing/CRC errors
validate_packets(pkts, p.nsol, CHIPS, jobs, LANES)
sols = collections.defaultdict(list)
dones = {}
dup_dones = []
pongs = collections.Counter()
lanes_seen = set()
for typ, addr, pay in pkts:
    if typ == RSP_PONG:
        pongs[addr] += 1
        lanes_seen.add(pay[3])
    elif typ == RSP_SOLUTION:
        key = (pay[0], addr, pay[1] | pay[2] << 8 | pay[3] << 16)
        idx = [int.from_bytes(pay[4 + 4 * w:8 + 4 * w], "big") for w in range(p.nsol)]
        sols[key].append(idx)
    elif typ == RSP_DONE:
        key = (pay[0], addr, pay[1] | pay[2] << 8 | pay[3] << 16)
        if key in dones:
            dup_dones.append(key)
        dones[key] = pay[4]

fails = 0
def fail(msg):
    global fails
    fails += 1
    print("FAIL:", msg)

print("%d packets, %d bytes; PONGs %s" % (len(pkts), len(raw), dict(pongs)))
if dup_dones:
    fail("DONE sent more than once for %s" % dup_dones)
if sorted(pongs) != list(range(CHIPS)) or any(c != 1 for c in pongs.values()):
    fail("expected exactly one PONG from each of %d chips" % CHIPS)
if lanes_seen != {LANES}:
    fail("PONG reported lanes %s, expected %d" % (lanes_seen, LANES))

lines, total = [], 0
filtered_total = [0]
bypassed_total = 0
for j in sorted(jobs):
    for a in range(CHIPS):
        done_atts = sorted(t for (jj, aa, t) in dones if (jj, aa) == (j, a))
        if len(done_atts) < ATTEMPTS * (2 if j == 2 else 1):
            fail("job %d chip %d finished only attempts %s" % (j, a, done_atts))
        for t in sorted({t for (jj, aa, t) in list(dones) + list(sols) if (jj, aa) == (j, a)}):
            hdr = job_input(jobs[j], a, t)
            if PAR_CHAIN:   # bucket-parallel lanes: compare solution sets
                found = sorted(solve_par(p, hdr, PAR_BB_, 1 << 30 if RELAXED else PAR_SLOTS))
            else:
                found = hw_solve(p, hdr)
            want = [s for s in found if not SHARE_FILTER or is_share(hdr, s, targets[j])]
            filtered_total[0] += len(found) - len(want)
            got = sols.get((j, a, t), [])
            finished = (j, a, t) in dones
            if PAR_CHAIN:
                got = sorted(got)
                if RELAXED:
                    ok = all(g in want for g in got)
                    if finished:
                        found_total[0] += len(want)
                        got_total[0] += len(got)
                else:
                    ok = got == want if finished else all(g in want for g in got)
            else:
                ok = got == want if finished else got == want[:len(got)]
            if finished and not RELAXED and dones[(j, a, t)] != len(found):
                ok = False    # DONE counts every solution, shares or not
            if finished and not SHARE_FILTER and dones[(j, a, t)] != len(got):
                ok = False  # bypass must deliver every counted solution
            for s in got:
                if j == 2 and not is_share(hdr, s, targets[j]):
                    bypassed_total += 1
                ok &= zcash_verify(p, hdr, s)
                lines.append(hdr.hex() + " " + indices_to_minimal(p, s).hex())
            total += len(got)
            print("job %d chip %d attempt %d: %d solutions (model %d)%s %s" % (
                j, a, t, len(got), len(want), "" if finished else " [cut short]", "OK" if ok else "MISMATCH"))
            if not ok:
                fail("job %d chip %d attempt %d" % (j, a, t))
unknown = [k for k in list(dones) + list(sols) if k[0] not in jobs]
if unknown:
    fail("packets with unknown job ids: %s" % unknown[:5])

miner = os.environ.get("ZCASH_MINER", os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "../../../zig-out/bin/zcash-miner"))
if lines:
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write("\n".join(lines) + "\n")
    r = subprocess.run([miner, "--verify", f.name, "--params", "%d,%d" % (n, k)],
                       capture_output=True, text=True)
    os.unlink(f.name)
    print("zig: " + r.stderr.strip().splitlines()[-1])
    if r.returncode != 0:
        fail("zig verifier rejected a solution")
if total == 0:
    fail("the chain found no solutions at all")
if RELAXED:
    print("relaxed: found %d of %d model shares on finished attempts" % (got_total[0], found_total[0]))
    if found_total[0] and got_total[0] < 0.7 * found_total[0]:
        fail("found under 70%% of the model's shares")
if SHARE_FILTER and (filtered_total[0] == 0 or not any(sols.get(k) for k in sols if k[0] == 2)):
    fail("job 2 needs both filtered and forwarded solutions to exercise the filter")
if not SHARE_FILTER:
    print("bypass: %d below-target solutions forwarded" % bypassed_total)
    if bypassed_total == 0:
        fail("bypass did not forward any below-target solution")
print("check_chain: %s (%d shares from %d chips; %d solutions filtered on chip)" % (
    "PASS" if fails == 0 else "FAIL", total, CHIPS, filtered_total[0]))
sys.exit(1 if fails else 0)
