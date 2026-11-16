"""Confounders and stale evidence must never produce a controlled A/B PASS."""
import json
from pathlib import Path
import tempfile
import unittest

from compare_read_gating import GATED, UNGATED, RTL, sha, verify_pair


class ControlledComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old, self.new = self.root/'old', self.root/'new'
        for root, expression in ((self.old, UNGATED), (self.new, GATED)):
            for name, data in {
                'source/'+RTL: 'wire vrd = '+expression+'\n',
                'source/model.py': 'unchanged\n',
                'source.tgz': 'archive', 'obj/simulation': 'executable',
                'run/solver_hdr.hex': 'headers', 'run/solver_out.txt': 'output',
                'run/memory_accesses.csv': 'activity', 'run/audit/summary.json': '{}'
            }.items():
                p = root/name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(data)
            inputs = dict(parameters={'GROUP_REPLAY':0, 'NH':2, 'SLOTS':640},
                          seed='fixed', image_id='fixed', python_runtime={'numpy':'fixed'},
                          compiler_options={'build_jobs':2},
                          headers_sha256=sha(root/'run/solver_hdr.hex'),
                          source_sha256=sha(root/'source.tgz'),
                          files={name:sha(root/'source'/name) for name in (RTL,'model.py')})
            (root/'inputs.json').write_text(json.dumps(inputs))
            result = dict(status='PASS', archived_inputs_unchanged=True, headers=2,
                          simulation_executable_sha256=sha(root/'obj/simulation'),
                          **{'yield':dict(solutions=5,reference_solutions=5,missing_reference_solutions=0)},
                          evidence_sha256={str(p.relative_to(root)):sha(p) for p in root.rglob('*')
                                           if p.is_file() and 'source' not in p.parts and 'obj' not in p.parts})
            (root/'result.json').write_text(json.dumps(result))

    def update_inputs(self, change):
        p = self.new/'inputs.json'
        obj = json.loads(p.read_text()); change(obj); p.write_text(json.dumps(obj))
        self.update_result(lambda r:r['evidence_sha256'].update({'inputs.json':sha(p)}))

    def update_result(self, change):
        p = self.new/'result.json'
        obj=json.loads(p.read_text());change(obj);p.write_text(json.dumps(obj))

    def test_exact_change_accepted(self):
        self.assertEqual(verify_pair(self.old, self.new)['NH'], 2)

    def test_exact_declaration_relocation_accepted(self):
        declaration = '            wire [SB-1:0]   oq;\n'
        anchor = '            wire            hold_c;\n'
        for root, expression in ((self.old, UNGATED), (self.new, GATED)):
            text = anchor+'wire vrd = '+expression+'\n'+declaration
            if root == self.new:
                text = text.replace(declaration, '').replace(anchor, anchor+declaration)
            p = root/'source'/RTL
            p.write_text(text)
            ip = root/'inputs.json'
            i = json.loads(ip.read_text()); i['files'][RTL] = sha(p)
            ip.write_text(json.dumps(i))
            rp = root/'result.json'
            r=json.loads(rp.read_text());r['evidence_sha256']['inputs.json']=sha(ip)
            rp.write_text(json.dumps(r))
        self.assertEqual(verify_pair(self.old,self.new)['NH'],2)

    def test_capacity_confound_rejected(self):
        self.update_inputs(lambda i:i['parameters'].update(SLOTS=768))
        with self.assertRaisesRegex(ValueError, 'configuration differs'):
            verify_pair(self.old,self.new)

    def test_unrelated_rtl_change_rejected_even_with_fresh_hashes(self):
        p=self.new/'source'/RTL;p.write_text(p.read_text()+'wire extra;\n')
        self.update_inputs(lambda i:i['files'].update({RTL:sha(p)}))
        with self.assertRaisesRegex(ValueError, 'changes exceed'):
            verify_pair(self.old,self.new)

    def test_corrupt_activity_rejected(self):
        (self.new/'run/memory_accesses.csv').write_text('tampered')
        with self.assertRaisesRegex(ValueError, 'evidence hash mismatch'):
            verify_pair(self.old,self.new)

    def test_corrupt_binary_rejected(self):
        (self.new/'obj/simulation').write_text('tampered')
        with self.assertRaisesRegex(ValueError, 'executable hash mismatch'):
            verify_pair(self.old,self.new)

    def test_failed_reference_retention_rejected(self):
        self.update_result(lambda r:r['yield'].update(missing_reference_solutions=1))
        with self.assertRaisesRegex(ValueError, 'reference retention'):
            verify_pair(self.old,self.new)

    def test_unbound_activity_rejected(self):
        self.update_result(lambda r:r['evidence_sha256'].pop('run/memory_accesses.csv'))
        with self.assertRaisesRegex(ValueError, 'required evidence'):
            verify_pair(self.old,self.new)

    def test_source_escape_rejected(self):
        self.update_inputs(lambda i:i['files'].update({'../../outside':'anything'}))
        with self.assertRaisesRegex(ValueError, 'escapes archive'):
            verify_pair(self.old,self.new)


if __name__ == '__main__':
    unittest.main()
