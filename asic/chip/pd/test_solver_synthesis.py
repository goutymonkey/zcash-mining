"""Reject contaminated evidence and changes outside the proven reset rewrite."""
import importlib.util
import json
import gzip
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


synthesis = load('pd.synthesis', ROOT / 'pd/qualify_solver_synthesis.py')
mapping = load('mapping', ROOT / 'pd/solver_mapping.py')
proof = load('proof', ROOT / 'formal/qualify_fill_reset.py')


class EvidenceGuards(unittest.TestCase):
    def test_exact_reset_rewrite(self):
        before = 'module top;\n' + proof.OLD + '\nendmodule\n'
        proof.check_change(before, before.replace(proof.OLD, proof.NEW))

    def test_reject_additional_rtl_change(self):
        before = 'module top;\n' + proof.OLD + '\nendmodule\n'
        after = before.replace(proof.OLD, proof.NEW).replace('module top;', 'module other;')
        with self.assertRaises(ValueError):
            proof.check_change(before, after)

    def test_reject_wrong_reset_parity(self):
        with self.assertRaises(ValueError):
            proof.check_change(proof.OLD, proof.NEW.replace('==', '!='))

    def test_reject_duplicate_reset_sites(self):
        before = proof.OLD + '\n' + proof.OLD
        with self.assertRaises(ValueError):
            proof.check_change(before, before.replace(proof.OLD, proof.NEW))

    def test_archived_source_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'rtl.v'
            source.write_text('original')
            manifest = {'rtl.v': synthesis.sha(source)}
            synthesis.verify(root, manifest)
            source.write_text('modified')
            with self.assertRaises(ValueError):
                synthesis.verify(root, manifest)

    def test_missing_archived_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(OSError):
                synthesis.verify(Path(tmp), {'missing.v': '0' * 64})


class MappingGuards(unittest.TestCase):
    def test_checkpoint_archive_restores_exact_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            data = bytes(range(256)) * 10000
            (root/'simple.il').write_bytes(data)
            mapping.archive_checkpoint(root, 'simple.il')
            record = json.loads((root/'checkpoint-archives.json').read_text())['simple.il']
            self.assertEqual(gzip.decompress((root/record['archive']).read_bytes()), data)
            self.assertEqual(record['raw_sha256'], hashlib.sha256(data).hexdigest())
            self.assertFalse((root/'simple.il').exists())

    def test_existing_archive_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/'simple.il').write_bytes(b'input')
            (root/'simple.il.gz').write_bytes(b'existing')
            with self.assertRaises(ValueError):
                mapping.archive_checkpoint(root, 'simple.il')
            self.assertEqual((root/'simple.il').read_bytes(), b'input')
            self.assertEqual((root/'simple.il.gz').read_bytes(), b'existing')

    def test_expansion_can_increase_cell_count(self):
        mapping.validate_progress({'top/mul': '$macc_v2'},
                                  {'top/add0': '$alu', 'top/add1': '$alu'}, ['top/mul'])

    def test_reject_unmapped_selection_even_if_total_decreases(self):
        with self.assertRaises(ValueError):
            mapping.validate_progress({'top/a': '$shiftx', 'top/b': '$alu'},
                                      {'top/a': '$shiftx'}, ['top/a'])

    def test_reject_script_injection(self):
        with self.assertRaises(ValueError):
            mapping.batch_script('input.il; exit', 'output.il', 'batch.list', 1, 288)

    def test_mapping_requires_every_coarse_cell_to_finish(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/'simple.il').write_text('module \\zeq_eh_par\n  cell $alu $add0\n  end\nend\n')
            def expand(name, current, extra):
                (root/(name+'.il')).write_text(
                    'module \\zeq_eh_par\n  cell $alu $new_add0\n  end\nend\n')
            with self.assertRaisesRegex(ValueError, 'unfinished'):
                mapping.map_batches(root, expand, 288, max_batches=1)

    def test_last_batch_can_finish_at_limit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/'simple.il').write_text('module \\zeq_eh_par\n  cell $alu $add0\n  end\nend\n')
            def finish(name, current, extra):
                (root/(name+'.il')).write_text(
                    'module \\zeq_eh_par\n  cell $_AND_ $gate0\n  end\n  cell $mem_v2 \\ram\n  end\nend\n')
            last, history = mapping.map_batches(root, finish, 288, max_batches=1)
            self.assertEqual(last, 'map-000.il')
            self.assertEqual(history[-1]['after'], 0)

    def test_reject_hierarchy(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'input.il'
            path.write_text('module \\zeq_eh_par\n  cell \\submodule \\child\n  end\nend\n')
            with self.assertRaises(ValueError):
                mapping.pending_cells(path)


class CoarseReuse(unittest.TestCase):
    def fixture(self, root):
        origin, dest = root/'origin', root/'dest'
        origin.mkdir(); dest.mkdir()
        (origin/'source/rtl').mkdir(parents=True)
        (origin/'source/rtl/top.v').write_text('module top; endmodule\n')
        files = {'source/rtl/top.v': synthesis.sha(origin/'source/rtl/top.v')}
        params = {'N': 200}
        inputs = dict(parameters=params, image_id='sha256:example', source_sha256=files)
        (origin/'inputs.json').write_text(json.dumps(inputs))
        for name in ('coarse.ys', 'coarse.il', 'coarse.json', 'coarse-inventory.json'):
            (origin/name).write_text(name)
        result = dict(status='FAIL', parameters=params,
                      stages={'coarse': {'exit_code': 0}, 'coarse-inventory': {'exit_code': 0},
                              'generic': {'exit_code': 137}},
                      evidence_sha256={p.name: synthesis.sha(p) for p in origin.iterdir() if p.is_file()})
        (origin/'result.json').write_text(json.dumps(result))
        return origin, dest, params, 'sha256:example', files, 'coarse.ys'

    def test_reuse_completed_coarse_from_failed_mapping(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.fixture(Path(tmp))
            result = synthesis.reuse_coarse(*args)
            self.assertTrue(result['reused'])
            self.assertEqual(result['origin_status'], 'FAIL')
            self.assertEqual((args[1]/'coarse.il').read_text(), 'coarse.il')

    def test_reject_modified_artifact_and_source(self):
        for name in ('coarse.il', 'coarse-inventory.json', 'source/rtl/top.v'):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                args = self.fixture(Path(tmp))
                (args[0]/name).write_text('changed')
                with self.assertRaises(ValueError):
                    synthesis.reuse_coarse(*args)

    def test_reject_different_run_inputs(self):
        for index, value in ((2, {'N': 48}), (3, 'different-image'),
                             (4, {'source/rtl/top.v': '0'*64}), (5, 'different-script')):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as tmp:
                args = list(self.fixture(Path(tmp)))
                args[index] = value
                with self.assertRaises(ValueError):
                    synthesis.reuse_coarse(*args)

    def test_reject_incomplete_coarse(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.fixture(Path(tmp))
            path = args[0]/'result.json'
            result = json.loads(path.read_text())
            result['stages']['coarse']['exit_code'] = 137
            path.write_text(json.dumps(result))
            with self.assertRaises(ValueError):
                synthesis.reuse_coarse(*args)


if __name__ == '__main__':
    unittest.main()
