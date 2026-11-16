import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from signoff_gate import KINDS, ZERO_METRICS, validate, electrical_report


def report(kind=None, pin='u_mem/addr0[0]', actual=0.22):
    text = 'report_checks -unconstrained\nreport_check_types -max_slew -max_cap -max_fanout -violators\n'
    if kind:
        heading = 'capacitance' if kind == 'cap' else kind
        text += f'max {heading}\n{pin} 0.04 {actual} -0.18 (VIOLATED)\n'
    text += 'report_parasitic_annotation -report_unannotated\n'
    return text + ''.join(f'max {k} violation count {int(kind == k)}\n' for k in KINDS)


class GateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.run = Path(self.tmp.name)
        self.step = self.run / '51-openroad-stapostpnr'
        (self.step / 'tt').mkdir(parents=True)
        (self.run / 'final').mkdir()
        (self.run / 'resolved.json').write_text(json.dumps({'MACROS': {}}))
        (self.step / 'config.json').write_text(json.dumps({'STA_CORNERS': ['tt']}))
        self.rpt = self.step / 'tt/checks.rpt'
        self.rpt.write_text(report())
        for kind, suffix in [('Setup', 'max'), ('Hold', 'min')]:
            (self.step / 'tt' / f'ws.{suffix}.rpt').write_text(f'Worst Slack ({kind})\ntt: 0.1\n')
        self.policy_path = self.run / 'policy.json'
        self.policy = {'required_corners': ['tt'], 'max_ir_drop_v': 0.09, 'waivers': []}
        self.metrics = {k: 0 for k in ZERO_METRICS}
        self.metrics.update({'ir__drop__worst': 0.01, 'timing__setup__ws__corner:tt': 0.1,
                             'timing__hold__ws__corner:tt': 0.1})
        self.metrics.update({f'design__max_{k}_violation__count__corner:tt': 0 for k in KINDS})

    def run_gate(self):
        self.policy_path.write_text(json.dumps(self.policy))
        (self.run / 'final/metrics.json').write_text(json.dumps(self.metrics))
        return validate(self.run, self.policy_path)

    def violation(self, kind='slew'):
        self.rpt.write_text(report(kind))
        self.metrics[f'design__max_{kind}_violation__count__corner:tt'] = 1

    def waiver(self):
        (self.run / 'review.txt').write_text('Fixture justification, not a real signoff waiver.')
        self.policy['waivers'] = [dict(corner='tt', check='slew', pin='u_mem/addr0[0]',
                                      max_actual=0.23, report_sha256=hashlib.sha256(self.rpt.read_bytes()).hexdigest(),
                                      justification_file='review.txt')]

    def test_clean(self):
        self.assertEqual(self.run_gate(), [])

    def test_known_rtl_failure_blocks_even_clean_physical_reports(self):
        for body in ('', '{"reason":"known RTL failure"}', 'invalid json'):
            with self.subTest(body=body):
                (self.run / 'RELEASE_BLOCKED.json').write_text(body)
                self.assertTrue(any('known release blocker' in e for e in self.run_gate()))

    def test_macro_pin_is_not_automatically_waived(self):
        self.violation()
        self.assertTrue(self.run_gate())

    def test_fanout_and_cap_are_gated(self):
        for kind in ('fanout', 'cap'):
            with self.subTest(kind=kind):
                self.violation(kind)
                self.assertTrue(self.run_gate())

    def test_exact_bounded_waiver(self):
        self.violation()
        self.waiver()
        self.assertEqual(self.run_gate(), [])
        self.policy['waivers'][0]['max_actual'] = 0.20
        self.assertTrue(self.run_gate())

    def test_changed_report_invalidates_waiver(self):
        self.violation()
        self.waiver()
        self.rpt.write_text(self.rpt.read_text() + '\nchanged\n')
        self.assertTrue(self.run_gate())

    def test_other_pin_not_covered(self):
        self.violation()
        self.waiver()
        self.policy['waivers'][0]['pin'] = '*/addr0[0]'
        self.assertTrue(self.run_gate())

    def test_missing_evidence(self):
        self.violation()
        self.waiver()
        (self.run / 'review.txt').unlink()
        self.assertTrue(self.run_gate())

    def test_ir_budget(self):
        for value in (None, -0.01, 0.10, float('nan'), float('inf'), True):
            with self.subTest(value=value):
                self.metrics['ir__drop__worst'] = value
                self.assertTrue(self.run_gate())

    def test_missing_metric(self):
        del self.metrics[ZERO_METRICS[0]]
        self.assertTrue(self.run_gate())

    def test_corner_policy(self):
        self.policy['required_corners'].append('ss')
        self.assertTrue(self.run_gate())

    def test_electrical_count_mismatch(self):
        self.violation()
        self.rpt.write_text(self.rpt.read_text().replace('slew violation count 1', 'slew violation count 0'))
        self.assertTrue(self.run_gate())

    def test_missing_summary(self):
        with self.assertRaises(ValueError):
            electrical_report('report_check_types -max_slew -max_cap -max_fanout -violators\n')

    def test_metric_report_disagreement(self):
        self.metrics['design__max_slew_violation__count__corner:tt'] = 1
        self.assertTrue(self.run_gate())

    def test_stale_waiver(self):
        self.violation()
        self.waiver()
        self.rpt.write_text(report())
        self.metrics['design__max_slew_violation__count__corner:tt'] = 0
        self.assertTrue(self.run_gate())


if __name__ == '__main__':
    unittest.main()
