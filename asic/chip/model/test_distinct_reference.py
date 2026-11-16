"""Cross-check early index pruning against a scalar explicit-tree solver."""
from collections import defaultdict
from itertools import combinations
import hashlib
import unittest

from equihash_ref import Params, leaf, zcash_verify
from equihash_np import hw_solve_np


def explicit_tree_solve(p, header):
    rows = [(leaf(p, header, i), (i,)) for i in range(p.init)]
    for round_number in range(1, p.k+1):
        shift = p.n - round_number*p.cb
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
                value = (left ^ right) & ((1 << shift)-1)
                if round_number < p.k or value == 0:
                    next_rows.append((value, a+b))
        rows = next_rows
    return set(indices for _, indices in rows)


class DistinctReferenceTest(unittest.TestCase):
    def test_explicit_tree_equivalence(self):
        total = 0
        for n, k in [(24, 3), (48, 5)]:
            p = Params(n, k)
            for case in range(12):
                header = hashlib.shake_256(f'distinct-reference:{n}:{case}'.encode()).digest(140)
                with self.subTest(n=n, case=case):
                    expected = explicit_tree_solve(p, header)
                    stats = {}
                    result = hw_solve_np(p, header, cap=4*p.init, gmax=64, stats=stats, distinct=True)
                    self.assertFalse(any(stats.get('row_cap_dropped', [])))
                    self.assertFalse(any(stats.get('group_rows_dropped', [])))
                    self.assertEqual(set(map(tuple, result)), expected)
                    self.assertEqual(len(result), len(expected))
                    self.assertTrue(all(zcash_verify(p, header, sol) for sol in result))
                    total += len(result)
        self.assertGreater(total, 0)


if __name__ == '__main__':
    unittest.main()
