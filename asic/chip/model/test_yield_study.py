"""Protect yield evidence against incomplete logs and inflated solution counts."""
from pathlib import Path
import tempfile
import unittest

from equihash_ref import Params
from yield_study import read_rtl, summarize, validated_set


class YieldEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.build = Path(self.tmp.name)
        (self.build / 'solver_hdr.hex').write_text('00'*140+'\n')
        self.params = Params(48, 5)

    def log(self, text):
        (self.build / 'solver_out.txt').write_text(text)

    def test_truncated_attempt_rejected(self):
        self.log('A 0\n')
        with self.assertRaises(ValueError):
            read_rtl(self.build, self.params)

    def test_missing_header_attempt_rejected(self):
        self.log('A 0\nD 0 100 0\n')
        with (self.build / 'solver_hdr.hex').open('a') as f:
            f.write('11'*140+'\n')
        with self.assertRaises(ValueError):
            read_rtl(self.build, self.params)

    def test_count_inflation_rejected(self):
        self.log('A 0\nD 1 100 0\n')
        with self.assertRaises(ValueError):
            read_rtl(self.build, self.params)

    def test_duplicate_solutions_rejected(self):
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            validated_set(self.params, bytes(140), [list(range(32))]*2)

    def test_invalid_solution_rejected(self):
        with self.assertRaisesRegex(ValueError, 'verification'):
            validated_set(self.params, bytes(140), [list(range(32))])

    def test_bucket_drops_do_not_waive_missing_solutions(self):
        samples = [dict(reference_count=2, candidates=dict(rtl=dict(count=1, cycles=100, dropped=1))),
                   dict(reference_count=0, candidates=dict(rtl=dict(count=0, cycles=200, dropped=999)))]
        r = summarize(samples, ['rtl'])['results']['rtl']
        self.assertEqual(r['retained_fraction'], .5)
        self.assertEqual(r['missing_reference_solutions'], 1)
        self.assertEqual(r['verified_solutions_per_cycle'], 1/300)

    def test_no_reference_solutions_is_unknown_yield(self):
        samples = [dict(reference_count=0, candidates=dict(x=dict(count=0)))]
        r = summarize(samples, ['x'])['results']['x']
        self.assertIsNone(r['retained_fraction'])
        self.assertIsNone(r['paired_header_bootstrap_95'])

    def test_complete_zero_solution_attempt_is_valid_input(self):
        self.log('A 0\nD 0 100 17\n')
        headers, runs = read_rtl(self.build, self.params)
        self.assertEqual(headers, [bytes(140)])
        self.assertEqual(runs[0]['dropped'], 17)


if __name__ == '__main__':
    unittest.main()
