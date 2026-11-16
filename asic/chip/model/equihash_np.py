"""Vectorized hw_solve: same algorithm and emission order as
equihash_ref.hw_solve, fast and compact enough for mainnet (200,9).

Values are stored as 4 x uint64 limbs (little-endian limb order, limb 0 =
bits 0..63), which covers N <= 256. Memory at (200,9) is dominated by the
per-level pointer arrays: about (K-1) x CAP x 2 x 4 bytes = 256 MiB.
"""

import hashlib
import struct

import numpy as np

from equihash_ref import Params

LIMBS = 4


def leaves(p, header140):
    """All INIT leaf values as (INIT, 4) uint64 limbs."""
    ngroups = (p.init + p.ipho - 1) // p.ipho
    person = p.personalization()
    buf = bytearray(ngroups * p.hout)
    mv = memoryview(buf)
    for g in range(ngroups):
        h = hashlib.blake2b(digest_size=p.hout, person=person)
        h.update(header140)
        h.update(struct.pack("<I", g))
        mv[g * p.hout:(g + 1) * p.hout] = h.digest()
    nb = p.n // 8
    raw = np.frombuffer(bytes(buf), dtype=np.uint8).reshape(ngroups * p.ipho, nb)[:p.init]
    # big-endian N-bit value -> pad to 32 bytes on the left -> 4 BE u64 words
    padded = np.zeros((p.init, 32), dtype=np.uint8)
    padded[:, 32 - nb:] = raw
    words_be = padded.view(">u8").astype(np.uint64)  # word 0 = most significant
    return words_be[:, ::-1].copy()                   # limb 0 = least significant


def extract(v, lo, width):
    """Bits [lo, lo+width) of each row as uint64 (width <= 32)."""
    limb, off = divmod(lo, 64)
    x = v[:, limb] >> np.uint64(off)
    if off + width > 64 and limb + 1 < LIMBS:
        x = x | (v[:, limb + 1] << np.uint64(64 - off))
    return x & np.uint64((1 << width) - 1)


def mask_low(v, bits):
    """Keep only the low `bits` bits of each row."""
    out = v.copy()
    for limb in range(LIMBS):
        lo = limb * 64
        if bits <= lo:
            out[:, limb] = 0
        elif bits < lo + 64:
            out[:, limb] &= np.uint64((1 << (bits - lo)) - 1)
    return out


def expand_np(p, ptrs, a, b):
    """equihash_ref.expand on numpy pointer arrays."""
    x = np.array([a, b], dtype=np.int64)
    for lev in range(p.k - 1, 0, -1):
        x = ptrs[lev][x].reshape(-1)
    x = x.tolist()
    s = 1
    while s < len(x):
        for blk in range(0, len(x), 2 * s):
            if x[blk + s] < x[blk]:
                x[blk:blk + s], x[blk + s:blk + 2 * s] = (
                    x[blk + s:blk + 2 * s],
                    x[blk:blk + s],
                )
        s *= 2
    if len(set(x)) != len(x):
        return None
    return x


def distinct_pairs(ptrs, ra, rb, round_number, chunk=4096):
    """Reject repeated leaves before they can multiply into invalid subtrees.

    A repeated index in a partial tree can never produce a valid final
    Equihash solution. Expand in bounded batches to avoid a rows x 512
    allocation at mainnet parameters; retained row/pointer order is stable.
    """
    good = np.ones(len(ra), dtype=bool)
    for start in range(0, len(ra), chunk):
        stop = min(start + chunk, len(ra))
        leaves_in_pair = np.stack([ra[start:stop], rb[start:stop]], axis=1)
        for level in range(round_number - 1, 0, -1):
            leaves_in_pair = ptrs[level][leaves_in_pair].reshape(stop-start, -1)
        ordered = np.sort(leaves_in_pair, axis=1)
        good[start:stop] = np.all(ordered[:, 1:] != ordered[:, :-1], axis=1)
    return good


def hw_solve_np(p, header140, cap=None, gmax=16, stats=None, distinct=False):
    cap = cap or 2 * p.init
    vals = leaves(p, header140)
    ptrs = [None]
    sols = []
    for r in range(1, p.k + 1):
        width = p.n - (r - 1) * p.cb
        shift = width - p.cb
        key = extract(vals, shift, p.cb) if len(vals) else np.zeros(0, np.uint64)
        order = np.argsort(key, kind="stable")
        skey = key[order]
        nrows = len(order)
        if nrows == 0:
            ptrs.append(np.zeros((0, 2), np.int64))
            vals = vals[:0]
            continue
        starts = np.flatnonzero(np.r_[True, skey[1:] != skey[:-1]])
        sizes = np.diff(np.r_[starts, nrows])
        kept = np.minimum(sizes, gmax)
        if stats is not None:
            stats.setdefault("group_rows_dropped", []).append(int((sizes - kept).sum()))
            stats.setdefault("max_group", []).append(int(sizes.max()))
        # every (a, b) slot pair, a < b < kept size, in (group, a, b) order
        grp, aa, bb = [], [], []
        for a in range(min(gmax, int(sizes.max()))):
            for b in range(a + 1, min(gmax, int(sizes.max()))):
                g = np.flatnonzero(kept > b)
                grp.append(g)
                aa.append(np.full(len(g), a))
                bb.append(np.full(len(g), b))
        grp = np.concatenate(grp) if grp else np.empty(0, dtype=np.int64)
        aa = np.concatenate(aa) if aa else np.empty(0, dtype=np.int64)
        bb = np.concatenate(bb) if bb else np.empty(0, dtype=np.int64)
        o = np.lexsort((bb, aa, grp))
        grp, aa, bb = grp[o], aa[o], bb[o]
        ra = order[starts[grp] + aa]
        rb = order[starts[grp] + bb]
        if distinct and r > 1:
            keep = distinct_pairs(ptrs, ra, rb, r)
            if stats is not None:
                stats.setdefault("invalid_partial_pairs", []).append(int((~keep).sum()))
            ra, rb = ra[keep], rb[keep]
        x = vals[ra] ^ vals[rb]
        if r < p.k:
            if stats is not None:
                stats.setdefault("row_cap_dropped", []).append(max(0, len(ra) - cap))
            ra, rb, x = ra[:cap], rb[:cap], x[:cap]
            ptrs.append(np.stack([ra, rb], axis=1).astype(np.uint32))
            vals = mask_low(x, shift)
        else:
            hit = np.flatnonzero(np.all(mask_low(x, shift) == 0, axis=1))
            for h in hit:
                s = expand_np(p, ptrs, int(ra[h]), int(rb[h]))
                if s is not None:
                    sols.append(s)
    return sols


if __name__ == "__main__":
    import sys
    import time
    from equihash_ref import hw_solve, job_input

    base = bytes((i * 37 + 11) & 0xFF for i in range(140))
    for n, k, tries in [(48, 5, 8), (96, 5, 2)]:
        p = Params(n, k)
        for t in range(tries):
            hdr = job_input(base, t % 4, t)
            a, b = hw_solve(p, hdr), hw_solve_np(p, hdr)
            assert a == b, ("mismatch", n, k, t, a, b)
        print("(%d,%d): numpy model == reference model on %d attempts" % (n, k, tries))
    if "--mainnet" in sys.argv:
        p = Params(200, 9)
        t0 = time.time()
        s = hw_solve_np(p, job_input(base, 0, 0))
        print("(200,9): %d solutions in %.1fs" % (len(s), time.time() - t0))
