"""An interrupted mapping may reuse evidence only through a verified chain."""
import json
import errno
import os
from unittest import mock
from pathlib import Path
import tempfile
import unittest

from solver_mapping import archive_checkpoint, batch_script
from solver_resume import resume_mapping, sha, link_verified


class ResumeEvidence(unittest.TestCase):
    def fixture(self, root, compressed=False):
        origin, build = root / 'origin', root / 'build'
        origin.mkdir()
        build.mkdir()
        files = {}
        for name in ('source/rtl/top.v', 'source/pd/synthesis_stage.py'):
            path = origin / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
            files[name] = sha(path)
        params, image = {'N': 200}, 'sha256:test-image'
        inputs = dict(parameters=params, image_id=image, source_sha256=files,
                      mapping_batch_size=2)
        (origin / 'inputs.json').write_text(json.dumps(inputs))
        netlist = 'module \\zeq_eh_par\n  cell $alu \\remaining\n  end\nend\n'
        for name in ('coarse.il', 'premap.il', 'simple.il', 'map-000.il'):
            (origin / name).write_text(netlist)
        for name in ('premap', 'simple'):
            (origin / (name + '.ys')).write_text(name)
            (build / (name + '.ys')).write_text(name)
        (origin / 'map-000.list').write_text('zeq_eh_par/first\n')
        (origin / 'map-000.ys').write_text(batch_script(
            'simple.il', 'map-000.il', 'map-000.list', 1, 288))
        stages = {}
        for name, source in [('premap', 'coarse.il'), ('simple', 'premap.il'),
                             ('map-000', 'simple.il')]:
            names = [name + '.ys', source, 'source/pd/synthesis_stage.py']
            if name == 'map-000':
                names.append('map-000.list')
            detail = dict(status='PASS', exit_code=0, inputs_unchanged=True,
                          command=['yosys', '-Q', '-T', '-s', name + '.ys'],
                          input_sha256={n: sha(origin / n) for n in names})
            (origin / (name + '-execution.json')).write_text(json.dumps(detail))
            stages[name] = dict(exit_code=0, execution=detail)
        history = [dict(name='map-000', input='simple.il', output='map-000.il',
                        selected=1, before=2, after=1)]
        (origin / 'mapping-history.json').write_text(json.dumps(history))
        if compressed:
            archive_checkpoint(origin, 'simple.il')
        result = dict(status='FAIL', parameters=params, logical_sram_cells=288,
                      stages=stages, evidence_sha256={
                          str(p.relative_to(origin)): sha(p)
                          for p in origin.rglob('*') if p.is_file()})
        (origin / 'result.json').write_text(json.dumps(result))
        return origin, build, params, image, files, 288, 2

    def rewrite_bound(self, origin, name, value):
        (origin / name).write_text(json.dumps(value))
        result = json.loads((origin / 'result.json').read_text())
        result['evidence_sha256'][name] = sha(origin / name)
        (origin / 'result.json').write_text(json.dumps(result))

    def test_verified_input_link_preserves_bytes_and_rejects_replacement(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);src=root/'source';dst=root/'destination';src.write_bytes(b'frozen')
            link_verified(src,dst,sha(src))
            self.assertTrue(os.path.samefile(src,dst))
            with self.assertRaisesRegex(ValueError,'already exists'):link_verified(src,dst,sha(src))
            dst.unlink()
            self.assertEqual(src.read_bytes(),b'frozen')

    def test_cross_filesystem_input_falls_back_to_verified_copy(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);src=root/'source';dst=root/'destination';src.write_bytes(b'frozen')
            with mock.patch('solver_resume.os.link',side_effect=OSError(errno.EXDEV,'different filesystem')):
                link_verified(src,dst,sha(src))
            self.assertFalse(os.path.samefile(src,dst));self.assertEqual(sha(src),sha(dst))

    def test_resumed_mutable_ledgers_do_not_modify_archived_origin(self):
        with tempfile.TemporaryDirectory() as t:
            args=self.fixture(Path(t), compressed=True)
            resume_mapping(*args)
            for name in ('mapping-history.json','checkpoint-archives.json'):
                source,destination=args[0]/name,args[1]/name
                original=source.read_bytes()
                self.assertFalse(os.path.samefile(source,destination))
                destination.write_text('updated continuation ledger')
                self.assertEqual(source.read_bytes(),original)

    def test_verified_transfer_rejects_tampering_and_does_not_hide_permission_errors(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);src=root/'source';dst=root/'destination';src.write_bytes(b'frozen')
            with self.assertRaisesRegex(ValueError,'source changed'):link_verified(src,dst,'0'*64)
            self.assertFalse(dst.exists())
            with mock.patch('solver_resume.os.link',side_effect=PermissionError('denied')):
                with self.assertRaises(PermissionError):link_verified(src,dst,sha(src))
            self.assertFalse(dst.exists())

    def test_resume_failed_run_preserves_prefix_without_reusing_verdict(self):
        for compressed in (False, True):
            with self.subTest(compressed=compressed), tempfile.TemporaryDirectory() as t:
                args = self.fixture(Path(t), compressed)
                seed, history, stages = resume_mapping(*args)
                self.assertEqual(seed, 'map-000.il')
                self.assertEqual(len(history), 1)
                self.assertTrue(all(s['reused'] for s in stages.values()))
                record = json.loads((args[1] / 'mapping-resume.json').read_text())
                self.assertEqual(record['origin_status'], 'FAIL')
                self.assertEqual(record['remaining_coarse_cells'], 1)
                self.assertFalse((args[1] / 'result.json').exists())
                self.assertEqual(sha(args[0] / seed), sha(args[1] / seed))

    def test_changed_checkpoint_or_script_or_selection_is_rejected(self):
        for name in ('map-000.il', 'map-000.ys', 'map-000.list',
                     'source/rtl/top.v', 'simple.il.gz'):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as t:
                args = self.fixture(Path(t), compressed=True)
                (args[0] / name).write_text('changed')
                with self.assertRaises(ValueError):
                    resume_mapping(*args)
                self.assertFalse((args[1] / 'mapping-resume.json').exists())

    def test_inconsistent_history_fails_even_with_updated_hash(self):
        for key, value in [('name', 'map-001'), ('after', 0), ('selected', True)]:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as t:
                args = self.fixture(Path(t))
                history = json.loads((args[0] / 'mapping-history.json').read_text())
                history[0][key] = value
                self.rewrite_bound(args[0], 'mapping-history.json', history)
                with self.assertRaises(ValueError):
                    resume_mapping(*args)

    def test_failed_stage_cannot_be_reused(self):
        with tempfile.TemporaryDirectory() as t:
            args = self.fixture(Path(t))
            result = json.loads((args[0] / 'result.json').read_text())
            result['stages']['map-000']['exit_code'] = 137
            (args[0] / 'result.json').write_text(json.dumps(result))
            with self.assertRaisesRegex(ValueError, 'did not pass'):
                resume_mapping(*args)

    def test_different_rtl_or_tool_or_parameters_rejected(self):
        for index, value in [(2, {'N': 48}), (3, 'sha256:other'),
                             (4, {'source/rtl/top.v': '0' * 64}), (6, 1)]:
            with self.subTest(index=index), tempfile.TemporaryDirectory() as t:
                args = list(self.fixture(Path(t)))
                args[index] = value
                with self.assertRaises(ValueError):
                    resume_mapping(*args)

    def test_wrong_restoration_hash_rejected(self):
        with tempfile.TemporaryDirectory() as t:
            args = self.fixture(Path(t), compressed=True)
            ledger = json.loads((args[0] / 'checkpoint-archives.json').read_text())
            ledger['simple.il']['raw_sha256'] = '0' * 64
            self.rewrite_bound(args[0], 'checkpoint-archives.json', ledger)
            with self.assertRaisesRegex(ValueError, 'restoration mismatch'):
                resume_mapping(*args)

    def test_stage_input_chain_must_match(self):
        with tempfile.TemporaryDirectory() as t:
            args = self.fixture(Path(t))
            name = 'map-000-execution.json'
            detail = json.loads((args[0] / name).read_text())
            detail['input_sha256']['simple.il'] = '0' * 64
            self.rewrite_bound(args[0], name, detail)
            result = json.loads((args[0] / 'result.json').read_text())
            result['stages']['map-000']['execution'] = detail
            (args[0] / 'result.json').write_text(json.dumps(result))
            with self.assertRaisesRegex(ValueError, 'input hash chain differs'):
                resume_mapping(*args)


if __name__ == '__main__':
    unittest.main()
