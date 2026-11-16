import json
from pathlib import Path
import tempfile
import unittest

from compact_proof import ANCHOR, CLEANUP, prepare, property_inventory, sha


class CompactTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.origin = self.root / 'origin'
        self.origin.mkdir()
        (self.origin / 'miter.sv').write_text('synthetic source fixture\n')
        (self.origin / 'proof.sby').write_text('[options]\nmode prove\ntimeout 600\n[script]\n' + ANCHOR)
        self.manifest = dict(outputs=['a', 'b'], source_sha256={name: sha(self.origin / name)
                              for name in ('miter.sv', 'proof.sby')})
        self.rebind()

    def rebind(self):
        (self.origin / 'composition.json').write_text(json.dumps(self.manifest))
        (self.origin / 'result.json').write_text(json.dumps(dict(
            status='TIMEOUT', composition_sha256=sha(self.origin / 'composition.json'),
            mutation=None, inputs_unchanged=True, asserted_output_bits=2)))

    def test_only_cleanup_is_added_and_circuits_stay_identical(self):
        build = self.root / 'new'
        record = prepare(self.origin, build)
        self.assertEqual((build / 'miter.sv').read_bytes(), (self.origin / 'miter.sv').read_bytes())
        self.assertEqual((build / 'proof.sby').read_text().replace(CLEANUP, '', 1),
                         (self.origin / 'proof.sby').read_text())
        self.assertEqual(record['outputs'], ['a', 'b'])
        self.assertFalse(record['release_eligible'])
        self.assertFalse(record['full_design_equivalence'])
        self.assertTrue(record['compaction']['property_inventory_check_required'])

    def test_stale_input_is_rejected_before_output_creation(self):
        (self.origin / 'miter.sv').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'changed composition input'):
            prepare(self.origin, self.root / 'new')
        self.assertFalse((self.root / 'new').exists())

    def test_missing_or_duplicated_anchor_rejected(self):
        for text in ('[options]\nmode prove\n', '[options]\nmode prove\n' + ANCHOR * 2,
                     '[options]\nmode prove\n' + ANCHOR + CLEANUP):
            (self.origin / 'proof.sby').write_text(text)
            self.manifest['source_sha256']['proof.sby'] = sha(self.origin / 'proof.sby')
            self.rebind()
            with self.assertRaisesRegex(ValueError, 'unsupported proof'):
                prepare(self.origin, self.root / 'new')

    def test_mutation_or_output_count_mismatch_rejected(self):
        path = self.origin / 'result.json'
        original = json.loads(path.read_text())
        for key, value in [('mutation', 'injected fault'), ('asserted_output_bits', 1), ('inputs_unchanged', False)]:
            path.write_text(json.dumps(dict(original, **{key: value})))
            with self.assertRaisesRegex(ValueError, 'unbound or mutated'):
                prepare(self.origin, self.root / 'new')

    def test_property_census_accepts_order_but_rejects_loss_replacement_and_duplicates(self):
        self.assertEqual(property_inventory('a\nb\n', 'b\na\n'), 2)
        for before, after in [('a\nb\n', 'a\n'), ('a\nb\n', 'a\nc\n'),
                              ('a\nb\n', 'a\nb\nb\n'), ('', ''), ('a\n', 'a\n\n')]:
            with self.assertRaisesRegex(ValueError, 'property inventory'):
                property_inventory(before, after)

    def test_existing_destination_is_preserved(self):
        build = self.root / 'new'
        prepare(self.origin, build)
        with self.assertRaises(FileExistsError):
            prepare(self.origin, build)

    def test_source_path_escape_rejected(self):
        outside = self.root / 'outside'
        outside.write_text('fixture')
        self.manifest['source_sha256']['../outside'] = sha(outside)
        self.rebind()
        with self.assertRaises(ValueError):
            prepare(self.origin, self.root / 'new')


if __name__ == '__main__':
    unittest.main()
