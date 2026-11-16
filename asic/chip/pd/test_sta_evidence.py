import json
from pathlib import Path
import tempfile
import unittest
from check_sta_evidence import validate


class EvidenceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.run = Path(self.temp.name)
        self.step = self.run / '51-openroad-stapostpnr'
        self.step.mkdir()
        (self.step / 'config.json').write_text(json.dumps({'STA_CORNERS': ['tt', 'ss']}))
        (self.run / 'final').mkdir()
        self.metrics = {f'timing__{kind}__ws__corner:{corner}': 0.1
                        for kind in ('setup', 'hold') for corner in ('tt', 'ss')}
        for corner in ('tt', 'ss'):
            (self.step / corner).mkdir()
            (self.step / corner / 'checks.rpt').write_text(
                'report_checks\nreport_check_types -max_slew -max_cap -max_fanout -violators\n')
            for kind, suffix in [('Setup', 'max'), ('Hold', 'min')]:
                (self.step / corner / f'ws.{suffix}.rpt').write_text(
                    f'Worst Slack ({kind})\n{corner}: 0.1\n')
        self.save()

    def save(self):
        (self.run / 'final/metrics.json').write_text(json.dumps(self.metrics))

    def test_complete(self):
        self.assertEqual(validate(self.run), [])

    def test_missing_corner_report(self):
        (self.step / 'ss/checks.rpt').unlink()
        self.assertTrue(validate(self.run))

    def test_truncated_report(self):
        (self.step / 'ss/checks.rpt').write_text('report_checks\n')
        self.assertTrue(validate(self.run))

    def test_bad_corner_slack(self):
        for value in (-0.1, None, float('nan'), float('inf'), True):
            with self.subTest(value=value):
                self.metrics['timing__setup__ws__corner:ss'] = value
                self.save()
                self.assertTrue(validate(self.run))

    def test_no_step(self):
        self.assertTrue(validate(self.run / 'nonexistent'))

    def test_stale_positive_metric_cannot_hide_failing_report(self):
        (self.step / 'ss/ws.max.rpt').write_text('Worst Slack (Setup)\nss: -0.01\n')
        self.assertTrue(validate(self.run))

    def test_slack_report_must_match_metric(self):
        (self.step / 'ss/ws.max.rpt').write_text('Worst Slack (Setup)\nss: 0.2\n')
        self.assertTrue(validate(self.run))

    def test_invalid_report_rejected(self):
        for text in ('', 'Worst Slack (Hold)\nss: 0.1\n',
                     'Worst Slack (Setup)\nss: nan\n',
                     'Worst Slack (Setup)\ntt: 0.1\n',
                     'Worst Slack (Setup)\nss: 0.1\nss: 0.1\n'):
            with self.subTest(text=text):
                (self.step / 'ss/ws.max.rpt').write_text(text)
                self.assertTrue(validate(self.run))

    def test_missing_slack_report_rejected(self):
        (self.step / 'ss/ws.min.rpt').unlink()
        self.assertTrue(validate(self.run))

    def test_rounded_metric_accepted(self):
        self.metrics['timing__setup__ws__corner:ss'] = 5.06885
        (self.step / 'ss/ws.max.rpt').write_text('Worst Slack (Setup)\nss: 5.0688468190832685\n')
        self.save()
        self.assertEqual(validate(self.run), [])

    def test_invalid_corner_configuration_rejected(self):
        for corners in (['tt', 'tt'], ['tt', []], ['../tt'], [True]):
            with self.subTest(corners=corners):
                (self.step / 'config.json').write_text(json.dumps({'STA_CORNERS': corners}))
                self.assertTrue(validate(self.run))


if __name__ == '__main__':
    unittest.main()
