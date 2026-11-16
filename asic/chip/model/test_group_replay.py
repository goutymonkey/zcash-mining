"""Independent pair-set and end-to-end reference checks for bounded replay."""
import hashlib
import itertools
import unittest
from equihash_ref import Params, zcash_verify
from equihash_np import hw_solve_np
from par_model import group_pairs, solve_par


class GroupReplayTest(unittest.TestCase):
    def test_every_pair_once_including_oversized_groups(self):
        sizes = [0, 1, 2, 7, 8, 9, 16, 17, 33, 64, 65]
        expected = {(g, a, b) for g, n in enumerate(sizes)
                    for a, b in itertools.combinations(range(n), 2)}
        for capacity in [2, 4, 8, 16, 32, 64]:
            got = list(zip(*group_pairs(sizes, capacity, True)))
            self.assertEqual(len(got), len(expected))
            self.assertEqual(set(got), expected)
            self.assertEqual(got, sorted(got, key=lambda x: (x[0], x[1]//capacity, x[2], x[1])))

    def test_legacy_cap_and_order_preserved(self):
        sizes = [1, 8, 17, 33]
        expected = [(g, a, b) for g, n in enumerate(sizes)
                    for a, b in itertools.combinations(range(min(n, 8)), 2)]
        self.assertEqual(list(zip(*group_pairs(sizes, 8))), expected)

    def test_invalid_buffer_and_empty_bucket(self):
        for capacity in [0, 1, 3, -2]:
            with self.assertRaises(ValueError): group_pairs([10], capacity, True)
        self.assertTrue(all(len(x) == 0 for x in group_pairs([], 8, True)))

    def test_solutions_match_uncapped_distinct_reference(self):
        p = Params(48, 5)
        total = 0
        for i in range(12):
            header = hashlib.shake_256(f'group-replay-test:{i}'.encode()).digest(140)
            stats = {}
            reference = {tuple(x) for x in hw_solve_np(p, header, cap=100000,
                          gmax=128, distinct=True, stats=stats)}
            # A truncated reference is not a completeness oracle.
            self.assertFalse(any(stats['group_rows_dropped']))
            self.assertFalse(any(stats['row_cap_dropped']))
            for capacity in [2, 8]:
                st = {}
                got = solve_par(p, header, bb=4, slots=4096, gmax=capacity,
                                group_replay=True, stats=st)
                self.assertFalse(any(st['dropped']))
                self.assertFalse(any(st['group_truncated_rows']))
                self.assertEqual({tuple(x) for x in got}, reference)
                for sol in got:
                    self.assertTrue(zcash_verify(p, header, sol))
            total += len(reference)
        self.assertGreater(total, 0)


if __name__ == '__main__': unittest.main()
