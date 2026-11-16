import json
import errno
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from compose_partitions import prepare, sha, pointer_obligations, common_aliases


class CompositionTests(unittest.TestCase):
    def fixture(self, root):
        origin, build = root / 'origin', root / 'composition'
        directory = origin / 'eqy/partitions'
        directory.mkdir(parents=True)
        for name, inputs, outputs in [('top.a', ['clk', 'b'], ['a']),
                                      ('top.b', ['clk', 'a'], ['b'])]:
            metadata = dict(partition=dict(name=name, inbits={n: [0] for n in inputs},
                                           outbits={n: [0] for n in outputs}))
            (directory / (name + '.json')).write_text(json.dumps(metadata))
            lines = []
            for side in ('gold', 'gate'):
                lines.append('module \\' + side + '.' + name)
                for i, signal in enumerate(inputs):
                    lines.append(f'  wire input {i+1} \\__pi_{signal}')
                for i, signal in enumerate(outputs):
                    lines.append(f'  wire output {i+1+len(inputs)} \\__po_{signal}')
                lines.append('end')
            (directory / (name + '.il')).write_text('\n'.join(lines) + '\n')
        self.rehash(origin)
        return origin, build, ['top.a', 'top.b']

    def rehash(self, origin):
        evidence = {str(p.relative_to(origin)): sha(p)
                    for p in (origin / 'eqy/partitions').iterdir()}
        (origin / 'result.json').write_text(json.dumps(dict(status='FAIL', evidence_sha256=evidence)))

    def test_both_producers_joined_without_removing_assertions(self):
        with tempfile.TemporaryDirectory() as t:
            args = self.fixture(Path(t))
            record = prepare(*args)
            self.assertEqual(record['outputs'], ['a', 'b'])
            self.assertEqual(record['external_input_bits'], 1)
            text = (args[1] / 'miter.sv').read_text()
            self.assertEqual(text.count('always @* assert'), 2)
            self.assertIn('.\\__pi_b (gold_s1)', text)
            self.assertIn('.\\__pi_b (gate_s1)', text)
            self.assertNotIn('assume', text)
            self.assertFalse(record['release_eligible'])
            self.assertFalse(record['full_design_equivalence'])
            for name, digest in record['source_sha256'].items():
                self.assertEqual(sha(args[1] / name), digest)

    def test_partition_tampering_fails_before_writing(self):
        with tempfile.TemporaryDirectory() as t:
            args = self.fixture(Path(t))
            (args[0] / 'eqy/partitions/top.a.il').write_text('changed')
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                prepare(*args)
            self.assertFalse(args[1].exists())

    def test_metadata_cannot_omit_an_actual_output(self):
        with tempfile.TemporaryDirectory() as t:
            args = self.fixture(Path(t))
            path = args[0] / 'eqy/partitions/top.a.il'
            path.write_text(path.read_text().replace('\nend', '\n  wire output 4 \\__po_extra\nend'))
            self.rehash(args[0])
            with self.assertRaisesRegex(ValueError, 'actual module ports'):
                prepare(*args)
            self.assertFalse(args[1].exists())

    def test_duplicate_partitions_and_path_escape_rejected(self):
        for names in ([], ['top.a', 'top.a'], ['../top.a']):
            with self.subTest(names=names), tempfile.TemporaryDirectory() as t:
                origin, build, _ = self.fixture(Path(t))
                with self.assertRaises(ValueError):
                    prepare(origin, build, names)
                self.assertFalse(build.exists())

    def test_multiple_producers_rejected(self):
        with tempfile.TemporaryDirectory() as t:
            args = self.fixture(Path(t))
            path = args[0] / 'eqy/partitions/top.b.json'
            data = json.loads(path.read_text())
            data['partition']['outbits'] = {'a': [0]}
            path.write_text(json.dumps(data))
            self.rehash(args[0])
            with self.assertRaisesRegex(ValueError, 'multiple producers'):
                prepare(*args)

    def test_bus_bits_rejected(self):
        with tempfile.TemporaryDirectory() as t:
            args = self.fixture(Path(t))
            path = args[0] / 'eqy/partitions/top.a.json'
            data = json.loads(path.read_text())
            data['partition']['outbits']['a'] = [0, 1]
            path.write_text(json.dumps(data))
            self.rehash(args[0])
            with self.assertRaisesRegex(ValueError, 'scalar partition'):
                prepare(*args)

    def test_existing_diagnostic_not_overwritten(self):
        with tempfile.TemporaryDirectory() as t:
            args = self.fixture(Path(t))
            prepare(*args)
            with self.assertRaisesRegex(ValueError, 'fresh'):
                prepare(*args)

    def pointer_fixture(self):
        lines = []
        for side in ('gold', 'gate'):
            lines.extend(['module \\' + side + '.top.a', '  wire input 1 \\__pi_clk',
                          '  wire output 2 \\__po_a'])
            if side == 'gold':
                wires = [f'\\g_eng[0].{p}[{i}]' for p in ('pa', 'pb') for i in range(4)]
                wires.append('\\g_eng[0].psel')
            else:
                wires = [f'$\\g_eng[0].grow$rdreg[{p}]$q[{i}]' for p in (0, 1) for i in range(4)]
                wires.append('$\\g_eng[0].grow$rdreg[0]$q[4]')
            lines.extend('  wire ' + wire for wire in wires)
            lines.append('end')
        return '\n'.join(lines) + '\n', dict(inbits={'clk': [0]}, outbits={'a': [0]})

    def test_pointer_obligations_preserve_all_circuit_lines_and_outputs(self):
        body, metadata = self.pointer_fixture()
        changed, additions = pointer_obligations(body, 'top.a', metadata, 0)
        self.assertEqual(len(additions), 9)
        self.assertEqual(len(metadata['outbits']), 10)
        self.assertEqual(metadata['outbits']['a'], [0])
        self.assertEqual([line for line in changed.splitlines() if '__po_lemma.' not in line],
                         body.splitlines())
        self.assertNotIn('assume', changed)

    def test_pointer_profile_must_exist_exactly_on_both_sides(self):
        for wire in ('\\g_eng[0].pa[0]', '$\\g_eng[0].grow$rdreg[0]$q[0]'):
            with self.subTest(wire=wire):
                body, metadata = self.pointer_fixture()
                body = body.replace('  wire ' + wire + '\n', '')
                with self.assertRaisesRegex(ValueError, 'scalar wire missing'):
                    pointer_obligations(body, 'top.a', metadata, 0)

    def test_pointer_profile_rejects_vector_in_place_of_scalar(self):
        body, metadata = self.pointer_fixture()
        body = body.replace('wire \\g_eng[0].pa[0]', 'wire width 2 \\g_eng[0].pa[0]')
        with self.assertRaisesRegex(ValueError, 'scalar wire missing'):
            pointer_obligations(body, 'top.a', metadata, 0)

    def test_pointer_profile_cannot_replace_an_existing_output(self):
        body, metadata = self.pointer_fixture()
        metadata['outbits']['lemma.top.a.pb0'] = [0]
        with self.assertRaisesRegex(ValueError, 'name collision'):
            pointer_obligations(body, 'top.a', metadata, 0)

    def test_discovered_engines_have_distinct_additional_assertions(self):
        with tempfile.TemporaryDirectory() as t:
            origin, build, names = self.fixture(Path(t))
            body, metadata = self.pointer_fixture()
            lines = []
            for line in body.splitlines():
                lines.append(line)
                if line.startswith('  wire ') and 'g_eng[0]' in line:
                    lines.append(line.replace('g_eng[0]', 'g_eng[1]'))
            path = origin / 'eqy/partitions/top.a.il'
            path.write_text('\n'.join(lines) + '\n')
            metadata['name'] = 'top.a'
            path.with_suffix('.json').write_text(json.dumps({'partition': metadata}))
            self.rehash(origin)
            record = prepare(origin, build, names, all_pointer_engines=True)
            self.assertEqual(len(record['additional_assertions']['top.a']), 18)
            self.assertEqual(record['additional_assertions']['top.b'], [])
            self.assertEqual(len(record['outputs']), 20)
            self.assertIn('lemma.top.a.engine1.pa0', record['outputs'])

    def test_engine_selection_modes_cannot_conflict(self):
        with tempfile.TemporaryDirectory() as t:
            args = self.fixture(Path(t))
            with self.assertRaisesRegex(ValueError, 'explicit or discovered'):
                prepare(*args, pointer_engine=0, all_pointer_engines=True)

    def test_alias_identity_must_hold_on_both_sides(self):
        gold = {'a': {'bits': [7]}, 'b': {'bits': [7]}, 'c': {'bits': [7]}}
        gate = {'a': {'bits': [9]}, 'b': {'bits': [9]}, 'c': {'bits': [10]}}
        self.assertEqual(common_aliases([gold, gate], ['c', 'b', 'a']),
                         {'a': 'a', 'b': 'a', 'c': 'c'})

    def test_constants_missing_names_and_buses_are_not_signal_aliases(self):
        nets = {'a': {'bits': ['0']}, 'b': {'bits': ['0']},
                'c': {'bits': [1, 2]}, 'd': {'bits': [1, 2]}}
        self.assertEqual(common_aliases([nets, nets], ['a', 'b', 'c', 'd', 'missing']),
                         {n: n for n in ['a', 'b', 'c', 'd', 'missing']})

    def test_unbound_interface_cannot_restore_aliases(self):
        with tempfile.TemporaryDirectory() as t:
            args = self.fixture(Path(t))
            (args[0] / 'gold-interface.json').write_text('{}')
            with self.assertRaisesRegex(ValueError, 'interface evidence hash mismatch'):
                prepare(*args, restore_aliases=True)
            self.assertFalse(args[1].exists())

    def test_verified_interface_storage_sharing_and_cross_filesystem_copy(self):
        for cross_filesystem in (False, True):
            with self.subTest(cross_filesystem=cross_filesystem), tempfile.TemporaryDirectory() as t:
                origin, build, names = self.fixture(Path(t))
                result = json.loads((origin / 'result.json').read_text())
                for side in ('gold', 'gate'):
                    path = origin / (side + '-interface.json')
                    path.write_text(json.dumps({'modules': {'top': {'netnames': {'clk': {'bits': [7]}}}}}))
                    result['evidence_sha256'][path.name] = sha(path)
                (origin / 'result.json').write_text(json.dumps(result))
                if cross_filesystem:
                    with mock.patch('compose_partitions.os.link', side_effect=OSError(errno.EXDEV, 'different filesystem')):
                        record = prepare(origin, build, names, restore_aliases=True)
                else:
                    record = prepare(origin, build, names, restore_aliases=True)
                for side in ('gold', 'gate'):
                    name = side + '-interface.json'
                    self.assertEqual(os.path.samefile(origin / name, build / name), not cross_filesystem)
                    self.assertEqual(sha(build / name), record['source_sha256'][name])

    def test_short_depth_keeps_full_induction_requirement(self):
        with tempfile.TemporaryDirectory() as t:
            args = self.fixture(Path(t))
            prepare(*args, depth=2)
            script = (args[1] / 'proof.sby').read_text()
            self.assertIn('mode prove\ndepth 2', script)
            self.assertNotIn('mode bmc', script)

    def test_changed_tool_cannot_claim_frozen_provenance(self):
        with tempfile.TemporaryDirectory() as t:
            args = self.fixture(Path(t))
            with mock.patch('compose_partitions.SOURCE_BYTES', b'old version'):
                with self.assertRaisesRegex(ValueError, 'tool changed'):
                    prepare(*args)
            self.assertFalse(args[1].exists())


if __name__ == '__main__':
    unittest.main()
