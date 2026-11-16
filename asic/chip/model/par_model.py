"""Bucket-parallel Equihash solver model (the ZEQ-200X architecture).

Rows of each level live in 2^BB buckets chosen by the top BB bits of the
row's *next* collision key, at most S slots per bucket. A round processes
each bucket on its own: local counting sort by the remaining CB-BB key
bits, pair within groups (first GMAX rows), and append each new row to the
bucket of its next key. Parents of a row are always in one source bucket,
so a pointer is (bucket, slot a, slot b). Level-0 slots also store the leaf
index.

This is exactly the solver in equihash_ref.hw_solve with the global row
cap replaced by per-bucket slot caps, so with caps that never bind it
finds the same solutions (checked below). Hardware engines process
buckets in parallel and slot order depends on arbitration, so tests
compare solution *sets*, not order.

Also reports on-die storage for an instance, with and without the
storage optimizations (bucket-implied key bits, packed widths,
bucket-relative pointers).
"""
import numpy as np

import equihash_np as E
from equihash_ref import Params


def group_pairs(sizes, gmax=16, replay=False):
    """Pair offsets in RTL emission order; never merge equal-valued rows.

    Legacy order is (group, left, right), keeping only the first gmax rows.
    Replay order is (group, anchor block, right, left) with no group cap.
    The model materializes offsets for numpy; RTL buffers only gmax anchors.
    """
    sizes = np.asarray(sizes, dtype=np.int64)
    if gmax < 2 or gmax & (gmax - 1):
        raise ValueError("gmax must be a power of two >= 2")
    kept = sizes if replay else np.minimum(sizes, gmax)
    limit = int(kept.max()) if len(kept) else 0
    grp, aa, bb = [], [], []
    if replay:
        # Do not rescan every group for every pair in the largest group.
        # A rare oversized group must not make all ordinary groups expensive.
        for length in np.unique(kept):
            if length < 2:
                continue
            groups = np.flatnonzero(kept == length)
            left, right = np.triu_indices(int(length), 1)
            grp.append(np.repeat(groups, len(left)))
            aa.append(np.tile(left, len(groups)))
            bb.append(np.tile(right, len(groups)))
    else:
        for a in range(limit):
            for b in range(a + 1, limit):
                g = np.flatnonzero(kept > b)
                grp.append(g)
                aa.append(np.full(len(g), a, dtype=np.int64))
                bb.append(np.full(len(g), b, dtype=np.int64))
    if not grp:
        return tuple(np.empty(0, dtype=np.int64) for _ in range(3))
    grp, aa, bb = map(np.concatenate, (grp, aa, bb))
    order = np.lexsort((aa, bb, aa // gmax, grp) if replay else (bb, aa, grp))
    return grp[order], aa[order], bb[order]


def solve_par(p, header140, bb, slots, gmax=16, stats=None, bucket0_slots=None, group_replay=False,
              drop_zero=False):
    # drop_zero: discard an intermediate row whose remaining bits are all
    # zero (RTL DROP_ZERO). Its parents hold equal values and stay stored.
    if gmax < 2 or gmax & (gmax - 1):
        raise ValueError("gmax must be a power of two >= 2")
    if bucket0_slots is not None and bucket0_slots < slots:
        raise ValueError('bucket-zero capacity cannot be below regular capacity')
    vals = E.leaves(p, header140)
    nb = 1 << bb
    # level-0 bucket = top bb bits of the round-1 key; slot = rank in bucket
    lvl_bucket, lvl_keep = None, None
    ptrs = [None]
    rows_idx = np.arange(len(vals))  # leaf index per level-0 row

    def bucketize(v, shift):
        key = E.extract(v, shift, p.cb)
        b = (key >> np.uint64(p.cb - bb)).astype(np.int64)
        # slot = order of arrival within the bucket; drop beyond `slots`
        order = np.argsort(b, kind="stable")
        sb = b[order]
        start = np.searchsorted(sb, np.arange(nb))
        rank = np.empty(len(b), np.int64)
        rank[order] = np.arange(len(b)) - start[sb]
        limits = slots if bucket0_slots is None else np.where(b == 0, bucket0_slots, slots)
        keep = rank < limits
        return b, rank, keep

    # level 0
    shift0 = p.n - p.cb
    b0, r0, k0 = bucketize(vals, shift0)
    if stats is not None:
        stats.setdefault("dropped", []).append(int((~k0).sum()))
        stats.setdefault("maxfill", []).append(int(np.bincount(b0, minlength=nb).max()))
    vals, rows_idx = vals[k0], rows_idx[k0]
    leaf_of = rows_idx
    sols = []
    for r in range(1, p.k + 1):
        width = p.n - (r - 1) * p.cb
        shift = width - p.cb
        key = E.extract(vals, shift, p.cb)
        # rows are processed bucket by bucket in slot (arrival) order, which
        # is a stable sort by the full key
        order = np.argsort(key, kind="stable")
        skey = key[order]
        nrows = len(order)
        if nrows == 0:
            break
        starts = np.flatnonzero(np.r_[True, skey[1:] != skey[:-1]])
        sizes = np.diff(np.r_[starts, nrows])
        grp, aa, bbv = group_pairs(sizes, gmax, group_replay)
        if stats is not None:
            stats.setdefault("group_truncated_rows", []).append(
                0 if group_replay else int(np.maximum(sizes-gmax, 0).sum()))
            stats.setdefault("pair_candidates", []).append(len(grp))
        ra = order[starts[grp] + aa]
        rb = order[starts[grp] + bbv]
        x = vals[ra] ^ vals[rb]
        if r < p.k:
            nv = E.mask_low(x, shift)
            zero = np.all(nv == 0, axis=1)
            if stats is not None:
                stats.setdefault("zero_rows", []).append(int(zero.sum()))
                stats.setdefault("zero_rows_discarded", []).append(int(zero.sum()) if drop_zero else 0)
            if drop_zero:
                nv, ra, rb = nv[~zero], ra[~zero], rb[~zero]
            dest_bucket, dest_rank, keep = bucketize(nv, shift - p.cb)
            if stats is not None:
                stats["dropped"].append(int((~keep).sum()))
                stats["maxfill"].append(int(np.bincount(dest_bucket, minlength=nb).max()))
            ptrs.append(np.stack([ra[keep], rb[keep]], axis=1))
            vals = nv[keep]
        else:
            hit = np.flatnonzero(np.all(E.mask_low(x, shift) == 0, axis=1))
            for h in hit:
                s = expand_leaf(p, ptrs, leaf_of, int(ra[h]), int(rb[h]))
                if s is not None:
                    sols.append(s)
    return sols


def expand_leaf(p, ptrs, leaf_of, a, b):
    x = np.array([a, b], dtype=np.int64)
    for lev in range(p.k - 1, 0, -1):
        x = ptrs[lev][x].reshape(-1)
    x = leaf_of[x].tolist()
    s = 1
    while s < len(x):
        for blk in range(0, len(x), 2 * s):
            if x[blk + s] < x[blk]:
                x[blk:blk + s], x[blk + s:blk + 2 * s] = x[blk + s:blk + 2 * s], x[blk:blk + s]
        s *= 2
    return None if len(set(x)) != len(x) else x


def storage_bits(p, bb, slots):
    """On-die bits for one instance, peak over the rounds, for two layouts."""
    rows = (1 << bb) * slots
    sb = int(np.ceil(np.log2(slots)))
    idx = p.cb + 1
    naive_ptr = 2 * (p.cb + 2)
    comp_ptr = bb + 2 * sb
    out = {}
    for name, packed in (("simple", False), ("optimized", True)):
        peak = 0
        for r in range(1, p.k + 1):
            w_prev = p.n - (r - 1) * p.cb
            w_new = p.n - r * p.cb
            if packed:  # bucket id implies BB key bits of every stored row
                w_prev -= bb
                w_new = max(w_new - bb, 0)
                ptr_bits = comp_ptr
            else:
                w_prev, ptr_bits = p.n, naive_ptr
                w_new = p.n
            live_ptr = (r - 1) * ptr_bits + (ptr_bits if r < p.k else 0)
            level0_idx = idx
            total = rows * (w_prev + (w_new if r < p.k else 0) + live_ptr + level0_idx)
            peak = max(peak, total)
        out[name] = peak
    return out


if __name__ == "__main__":
    import sys, time
    from equihash_ref import job_input
    from equihash_np import hw_solve_np
    base = bytes((i * 37 + 11) & 0xFF for i in range(140))
    # 1) generous caps => same solution set as the reference solver
    for n, k, bb, tries in [(48, 5, 4, 16), (96, 5, 8, 2)]:
        p = Params(n, k)
        for t in range(tries):
            hdr = job_input(base, t % 4, t)
            ref = sorted(hw_solve_np(p, hdr, cap=1 << 40))
            got = sorted(solve_par(p, hdr, bb, slots=1 << 30))
            assert ref == got, (n, k, t)
        print("(%d,%d) bb=%d: bucketed solver == reference on %d nonces" % (n, k, bb, tries))
    # 2) mainnet storage and yield with realistic slot caps
    p = Params(200, 9)
    bb = 12
    avg = p.init >> bb
    for slots in (int(avg * 1.25), int(avg * 1.5)):
        st = storage_bits(p, bb, slots)
        print("(200,9) bb=%d slots=%d: peak storage simple %.0f MB, optimized %.0f MB" % (
            bb, slots, st["simple"] / 8e6, st["optimized"] / 8e6))
    if "--yield" in sys.argv:
        slots = int(avg * 1.25)
        tot = ref_tot = 0
        for t in range(int(sys.argv[sys.argv.index("--yield") + 1])):
            hdr = job_input(base, 0, t)
            t0 = time.time()
            stt = {}
            a = solve_par(p, hdr, bb, slots, stats=stt)
            b = hw_solve_np(p, hdr, cap=4 * p.init, gmax=64)
            tot += len(a)
            ref_tot += len(b)
            print("nonce %d: bucketed %d, near-complete %d, dropped/level %s (%.0fs)" % (
                t, len(a), len(b), stt["dropped"], time.time() - t0), flush=True)
        print("yield %.1f%% (%d/%d)" % (100 * tot / max(ref_tot, 1), tot, ref_tot))
