"""Blake2b leaf-hash vectors for tb_hash: random headers and g values,
expected digests from hashlib. Packed so byte i sits at bits [8i+:8]."""
import random, sys
from equihash_ref import Params, digest

def packed_hex(b):
    return b[::-1].hex()

n, k, count, out = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
p = Params(n, k)
rng = random.Random(1234)
with open(out + "/hash_hdr.hex", "w") as fh, open(out + "/hash_g.hex", "w") as fg, \
     open(out + "/hash_dig.hex", "w") as fd:
    for v in range(count):
        hdr = bytes(rng.randrange(256) for _ in range(140))
        # several g per header exercises midstate reuse
        for g in (0, 1, rng.randrange(1 << 20), 0xFFFFFFFF):
            fh.write(packed_hex(hdr) + "\n")
            fg.write("%08x\n" % g)
            fd.write(packed_hex(digest(p, hdr, g)) + "\n")
print("wrote %d vectors" % (count * 4))
