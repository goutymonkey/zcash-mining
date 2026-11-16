import csv
from pathlib import Path
import tempfile
import unittest
from compare_rtl import read_activity, compare_activity


class ActivityComparisonTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.rows = [(e,t,32,100,50) for e in range(2) for t in
                     ('value','key','histogram','parents','leaf_indices','order')]

    def write(self, name, rows):
        path = self.root/name
        with path.open('w', newline='') as out:
            w = csv.writer(out)
            w.writerow(('engine','table','width_bits','read_words','write_words'))
            w.writerows(rows)
        return path

    def test_counts_all_engines_and_normalizes_by_solutions(self):
        before = self.write('before', self.rows)
        after = self.write('after', [(e,t,w,r//2,v) for e,t,w,r,v in self.rows])
        result = compare_activity(before, after, 10, 10)
        self.assertEqual(result['read_bit_change_fraction'], -.5)
        self.assertEqual(result['baseline']['read_bits'], 38400)
        self.assertEqual(result['candidate']['write_bits'], 19200)
        self.assertEqual(result['candidate']['accessed_bytes_per_solution'], 480)

    def test_missing_duplicate_negative_or_empty_profiles_fail(self):
        for rows in [[], self.rows[:-1], self.rows+self.rows[:1],
                     [(e,t,w,-1,v) for e,t,w,r,v in self.rows]]:
            with self.subTest(rows=len(rows)), self.assertRaises(ValueError):
                read_activity(self.write('bad', rows))

    def test_lost_yield_uses_each_runs_own_denominator(self):
        path = self.write('data', self.rows)
        result = compare_activity(path, path, 10, 5)
        self.assertEqual(result['candidate']['accessed_bytes_per_solution'],
                         2*result['baseline']['accessed_bytes_per_solution'])

    def test_mismatched_width_rejected(self):
        before = self.write('before', self.rows)
        after = self.write('after', [(e,t,w+1,r,v) for e,t,w,r,v in self.rows])
        with self.assertRaises(ValueError): compare_activity(before, after, 1, 1)

    def test_no_solutions_cannot_report_per_solution_efficiency(self):
        path = self.write('data', self.rows)
        self.assertIsNone(compare_activity(path, path, 0, 0)['candidate']['accessed_bytes_per_solution'])


if __name__ == '__main__': unittest.main()
