"""Vectors for tb_share: header, 2^K random indices (CB+1 bits), target.
Expected pass = SHA256d(header || CompactSize || minimal) as a
little-endian number <= target (Zcash block-hash rule, as pow.zig)."""
import hashlib, random, sys
from equihash_ref import Params, indices_to_minimal

n, k, count, out = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
p = Params(n, k)
rng = random.Random(77)

def block_hash(hdr, sol):
    pre = bytes([len(sol)]) if len(sol) < 253 else b"\xfd" + len(sol).to_bytes(2, "little")
    return hashlib.sha256(hashlib.sha256(hdr + pre + sol).digest()).digest()

# target near the median hash so about half pass
t_be = (1 << 255).to_bytes(32, "big")
with open(out + "/share_vec.txt", "w") as f:
    for v in range(count):
        hdr = bytes(rng.randrange(256) for _ in range(140))
        idx = [rng.randrange(1 << (p.cb + 1)) for _ in range(p.nsol)]
        h = block_hash(hdr, indices_to_minimal(p, idx))
        ok = int.from_bytes(h, "little") <= int.from_bytes(t_be, "big")
        # hdr packed byte i at [8i+:8]; indices one per line; target big-endian
        f.write("%s %s %d %s\n" % (hdr[::-1].hex(), t_be.hex(), int(ok),
                                   " ".join("%x" % i for i in idx)))
print("wrote", count)
