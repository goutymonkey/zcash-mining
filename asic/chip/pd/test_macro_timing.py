"""Reject false multi-corner coverage from a reused typical-only SRAM view."""
import json
from pathlib import Path
import tempfile
import unittest

from check_macro_timing import check_config, validate
from run_inputs import digest


class MacroTimingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.lib = self.root / 'sram.lib'
        self.lib.write_text('library(sram_tt) { nom_temperature : 25; nom_voltage : 1.8; }\n')
        self.corner = 'nom_tt_025C_1v80'
        self.config = {'MACROS': {'sram': {'lib': {'*': ['/work/sram.lib']}}}}
        self.policy = {'required_corners': [self.corner], 'macro_timing_views': {
            'sram': {self.corner: {'process': 'tt', 'temperature_c': 25, 'voltage_v': 1.8,
                                   'sha256': [digest(self.lib)]}}}}

    def check(self):
        return check_config(self.config, self.policy, self.root)

    def test_reviewed_exact_view(self):
        errors, evidence = self.check()
        self.assertEqual(errors, [])
        self.assertEqual(evidence, {self.lib: digest(self.lib)})

    def test_typical_wildcard_cannot_qualify_ss_or_ff(self):
        self.policy['required_corners'] += ['nom_ss_100C_1v60', 'nom_ff_n40C_1v95']
        errors, _ = self.check()
        self.assertEqual(len(errors), 2)
        self.assertTrue(all('Liberty PVT mismatch' in e for e in errors))

    def test_correct_numeric_pvt_requires_process_review(self):
        self.policy['macro_timing_views'] = {}
        self.assertIn('reviewed macro characterization', self.check()[0][0])

    def test_changed_library_invalidates_review(self):
        self.lib.write_text(self.lib.read_text() + '// changed timing table\n')
        self.assertIn('reviewed macro characterization', self.check()[0][0])

    def test_process_review_must_match_corner(self):
        self.policy['macro_timing_views']['sram'][self.corner]['process'] = 'ss'
        self.assertTrue(self.check()[0])

    def test_liberty_metadata_is_required_and_finite(self):
        for body in ('', 'nom_temperature: nan; nom_voltage: 1.8;',
                     'nom_temperature: 25; nom_voltage: 1.8; nom_voltage: 1.8;'):
            with self.subTest(body=body):
                self.lib.write_text(body)
                self.assertTrue(self.check()[0])

    def test_selection_must_be_unambiguous(self):
        self.config['MACROS']['sram']['lib'][self.corner] = ['/work/sram.lib']
        self.assertIn('ambiguous', self.check()[0][0])

    def test_missing_file_rejected(self):
        self.lib.unlink()
        self.assertTrue(self.check()[0])

    def test_final_sta_views_must_match_resolved(self):
        (self.root / 'resolved.json').write_text(json.dumps(self.config))
        step = self.root / '51-openroad-stapostpnr'
        step.mkdir()
        (step / 'config.json').write_text(json.dumps({'MACROS': {}}))
        errors, _ = validate(self.root, self.policy, self.root)
        self.assertIn('differ', errors[0])
        (step / 'config.json').write_text(json.dumps(self.config))
        self.assertEqual(validate(self.root, self.policy, self.root)[0], [])

    def test_rc_corner_can_share_same_pvt_view_with_explicit_review(self):
        extra = 'max_tt_025C_1v80'
        self.policy['required_corners'].append(extra)
        self.policy['macro_timing_views']['sram'][extra] = self.policy['macro_timing_views']['sram'][self.corner]
        self.assertEqual(self.check()[0], [])
