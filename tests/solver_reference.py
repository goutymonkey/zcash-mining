# SPDX-License-Identifier: Apache-2.0
"""Uncapped explicit-tree oracle for small Equihash parameters.

Adapted from asic/chip/model/test_distinct_reference.py. No truncated index
heuristics, row capacity, GPU kernels or calls to the Zig solver are used.
This intentionally expensive oracle is bounded to small test parameters.
"""
from collections import defaultdict
from itertools import combinations
from pool_harness import Params
from equihash_ref import leaf, indices_to_minimal


def complete_solutions(header, n=48, k=5):
    if n > 48:
        raise ValueError("explicit-tree oracle is only for small test parameters")
    p = Params(n, k)
    rows = [(leaf(p, header, i), (i,)) for i in range(p.init)]
    for round_number in range(1, p.k + 1):
        shift = p.n - round_number * p.cb
        groups = defaultdict(list)
        for value, indices in rows:
            groups[value >> shift].append((value, indices))
        next_rows = []
        for group in groups.values():
            for (left, a), (right, b) in combinations(group, 2):
                if set(a).intersection(b):
                    continue
                if b[0] < a[0]:
                    a, b = b, a
                value = (left ^ right) & ((1 << shift) - 1)
                if round_number < p.k or value == 0:
                    next_rows.append((value, a + b))
        rows = next_rows
    return {indices_to_minimal(p, indices).hex() for _, indices in rows}
