"""Faults that must prevent archival output retention from qualifying."""
import unittest
from unittest.mock import patch

import audit_solver_log as audit
from equihash_ref import Params


class ReferenceSetAuditTest(unittest.TestCase):
    def setUp(self):
        self.p = Params(48,5)
        self.reference = [[1,2],[3,4]]
        self.run = dict(solutions=self.reference,cycles=100,dropped=123)

    def check(self, stats=None):
        def solve(*args, **kwargs):
            kwargs['stats'].update(stats or {})
            self.assertEqual(kwargs['cap'],4*self.p.init)
            self.assertEqual(kwargs['gmax'],64)
            self.assertTrue(kwargs['distinct'])
            return self.reference
        with patch.object(audit,'hw_solve_np',side_effect=solve), \
             patch.object(audit,'validated_set',side_effect=lambda p,h,s:set(map(tuple,s))), \
             patch.object(audit,'verify_zig'):
            return audit.audit_attempt(self.p,bytes(140),self.run,'archived-verifier')

    def test_equal_complete_sets_record_reference_solutions(self):
        sample = self.check()
        self.assertEqual(sample['reference_solutions'],self.reference)
        self.assertEqual(sample['candidates']['rtl']['dropped'],123)

    def test_nonzero_drops_cannot_waive_a_missing_solution(self):
        self.run['solutions'] = self.reference[:1]
        with self.assertRaisesRegex(ValueError,'1 missing'):
            self.check()

    def test_equal_counts_with_different_solutions_are_rejected(self):
        self.run['solutions'] = [[1,2],[5,6]]
        with self.assertRaisesRegex(ValueError,'1 missing, 1 unexpected'):
            self.check()

    def test_reference_group_or_capacity_truncation_is_rejected(self):
        for name in ['group_rows_dropped','row_cap_dropped']:
            with self.subTest(name=name), self.assertRaisesRegex(ValueError,'reference truncated'):
                self.check({name:[0,1,0]})

    def test_empty_complete_attempt_remains_valid(self):
        self.reference = []
        self.run['solutions'] = []
        self.assertEqual(self.check()['reference_count'],0)


if __name__ == '__main__':
    unittest.main()
