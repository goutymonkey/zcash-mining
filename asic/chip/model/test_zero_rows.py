"""Discarding all-zero intermediate rows: model behavior and solution retention.

An intermediate row whose remaining bits are all zero is the XOR of two
equal-valued parents. Apart from a negligible chance at mainnet width, the
parents share leaves, so no valid solution descends from it. Both parents
are kept; only their child is discarded.
"""
import hashlib
import unittest

from equihash_ref import Params, zcash_verify
from par_model import solve_par


def headers(count):
    return [hashlib.shake_256(f'zero-row-test:{i}'.encode()).digest(140) for i in range(count)]


class ZeroRowTest(unittest.TestCase):
    def test_solutions_retained_and_zero_rows_counted(self):
        p = Params(48, 5)
        zero_rows = solutions = 0
        for header in headers(24):
            keep_stats, drop_stats = {}, {}
            keep = solve_par(p, header, 4, 1 << 20, stats=keep_stats)
            drop = solve_par(p, header, 4, 1 << 20, stats=drop_stats, drop_zero=True)
            self.assertEqual(sorted(drop), sorted(keep))
            self.assertTrue(all(zcash_verify(p, header, s) for s in drop))
            # Both modes report the rows; only one discards them.
            self.assertEqual(len(keep_stats['zero_rows']), p.k - 1)
            self.assertEqual(keep_stats['zero_rows_discarded'], [0] * (p.k - 1))
            self.assertEqual(drop_stats['zero_rows_discarded'], drop_stats['zero_rows'])
            zero_rows += sum(drop_stats['zero_rows'])
            solutions += len(drop)
        # The corpus must exercise the behavior to mean anything.
        self.assertGreater(zero_rows, 0)
        self.assertGreater(solutions, 0)

    def test_discarding_removes_descendant_work(self):
        p = Params(48, 5)
        fewer = False
        for header in headers(24):
            keep_stats, drop_stats = {}, {}
            solve_par(p, header, 4, 1 << 20, stats=keep_stats)
            solve_par(p, header, 4, 1 << 20, stats=drop_stats, drop_zero=True)
            for kept, dropped in zip(keep_stats['pair_candidates'], drop_stats['pair_candidates']):
                self.assertLessEqual(dropped, kept)
            fewer |= sum(drop_stats['pair_candidates']) < sum(keep_stats['pair_candidates'])
        self.assertTrue(fewer)

    def test_default_is_unchanged(self):
        p = Params(48, 5)
        header = headers(1)[0]
        self.assertEqual(solve_par(p, header, 4, 128), solve_par(p, header, 4, 128, drop_zero=False))


if __name__ == '__main__':
    unittest.main()
