import json
from pathlib import Path
import tempfile
import unittest

from proof_progress import review, sha, summarize


def log(lines, terminal='TIMEOUT', code=8):
    return '\n'.join('SBY 19:00:00 [proof] ' + line for line in
                     [*lines, f'DONE ({terminal}, rc={code})']) + '\n'


class ProgressTests(unittest.TestCase):
    def test_selected_engine_without_search_is_preparation_timeout(self):
        text = log(['engine_0: abc pdr', 'base: starting process "yosys design.ys"',
                    'base: finished (returncode=0)', 'prep: starting process "yosys design_prep.ys"',
                    'summary: engine_0 (abc pdr) did not return a status'])
        result = summarize(text, 'TIMEOUT 8 600', 8)
        self.assertEqual(result['category'], 'MODEL_PREPARATION_TIMEOUT')
        self.assertEqual(result['terminal_stage'], 'prep')
        self.assertFalse(result['proof_search_started'])

    def test_actual_smt_and_pdr_searches_are_distinguished(self):
        for phase, command in [('engine_0', 'cd proof; yosys-abc -c pdr'),
                               ('engine_0.induction', 'yosys-smtbmc -i -t 3 design.smt2')]:
            result = summarize(log([f'{phase}: starting process "{command}"']), 'TIMEOUT 8 600', 8)
            self.assertEqual(result['category'], 'ENGINE_TIMEOUT')
            self.assertTrue(result['proof_search_started'])

    def test_witness_conversion_is_not_a_proof_search(self):
        for command in ('yosys-witness aiw2yw trace.aiw trace.yw',
                        'yosys-smtbmc --yw trace.yw design.smt2'):
            result = summarize(log([f'engine_0: starting process "{command}"']), 'TIMEOUT 8 600', 8)
            self.assertFalse(result['proof_search_started'])
            self.assertEqual(result['category'], 'UNKNOWN_STAGE_TIMEOUT')

    def test_no_started_stage_does_not_invent_one(self):
        result = summarize(log(['engine_0: abc pdr']), 'TIMEOUT 8 600', 8)
        self.assertIsNone(result['terminal_stage'])
        self.assertEqual(result['category'], 'UNKNOWN_STAGE_TIMEOUT')

    def test_terminal_results_never_create_release_eligibility(self):
        for state, code in [('PASS', 0), ('FAIL', 2), ('UNKNOWN', 4), ('ERROR', 16)]:
            result = summarize(log([], state, code), f'{state} {code} 0', code)
            self.assertEqual(result['terminal_status'], state)
            self.assertFalse(result['release_eligible'])
            self.assertFalse(result['full_design_equivalence'])

    def test_missing_contradictory_and_inconsistent_terminal_rejected(self):
        for text, status, code in [('', 'PASS 0 0', 0), (log([]), 'PASS 0 0', 0),
                                   (log([]) + log([], 'PASS', 0), 'TIMEOUT 8 0', 8),
                                   (log([]), 'TIMEOUT 0 0', 0), (log([]), 'TIMEOUT 8 0', True)]:
            with self.assertRaises(ValueError):
                summarize(text, status, code)

    def test_review_rejects_changed_and_unbound_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'proof').mkdir()
            (root / 'proof/status').write_text('TIMEOUT 8 600')
            (root / 'proof/logfile.txt').write_text(log(['prep: starting process "yosys prep.ys"']))
            result = dict(status='TIMEOUT', exit_code=8,
                          evidence_sha256={name: sha(root / name) for name in ('proof/status', 'proof/logfile.txt')})
            path = root / 'result.json'
            path.write_text(json.dumps(result))
            self.assertEqual(review(path)['category'], 'MODEL_PREPARATION_TIMEOUT')
            (root / 'proof/logfile.txt').write_text('changed')
            with self.assertRaisesRegex(ValueError, 'unbound progress'):
                review(path)
            del result['evidence_sha256']['proof/logfile.txt']
            path.write_text(json.dumps(result))
            with self.assertRaisesRegex(ValueError, 'unbound progress'):
                review(path)


if __name__ == '__main__':
    unittest.main()
