import json
import re
from pathlib import Path
import tempfile
import unittest

from partitioned import configuration, inspect_proof, matching_rules, state_correspondences, explicit_match_rules


class MatchingTest(unittest.TestCase):
    def test_scalar_alias_requires_unique_single_bit(self):
        bit = {'bits': [2]}
        matches, _ = matching_rules({'u.seen': bit}, {'u.seen[0]': bit})
        self.assertEqual(matches, [r'gold-match /^u\.seen$/ /^u\.seen\[0\]$/'])
        self.assertEqual(matching_rules({'u.seen': bit, 'u.seen[0]': bit},
                                        {'u.seen[0]': bit})[0], [])
        self.assertEqual(matching_rules({'u.seen': {'bits': [2, 3]}},
                                        {'u.seen[0]': bit})[0], [])

    def test_group_preserves_hierarchy_and_array_index(self):
        nets = {name: {'bits': [i]} for i, name in enumerate(
            ['u.bank[0].q[0]', 'u.bank[0].q[1]', 'u.bank[1].q[0]', 'unrelated'])}
        _, collect = matching_rules(nets, nets)
        self.assertEqual(collect, [r'group /^(u\.bank\[0\]\.q\[-?[0-9]+\])$/'])

    def test_aliases_merge_bus_groups_across_either_side(self):
        gold = {'a[0]': {'bits': [2]}, 'a[1]': {'bits': [3]},
                'b[0]': {'bits': [2]}, 'b[1]': {'bits': [4]}}
        gate = {name: {'bits': [i + 10]} for i, name in enumerate(gold)}
        expected = [r'group /^(a\[-?[0-9]+\]|b\[-?[0-9]+\])$/',
                    r'bind /^(a\[0\]|b\[0\])$/']
        self.assertEqual(matching_rules(gold, gate)[1], expected)
        self.assertEqual(matching_rules(gate, gold)[1], expected)

    def test_scalar_state_alias_cannot_become_independent_partition_inputs(self):
        gold = {'pulse': {'bits': [2]}, 'state[0]': {'bits': [3]}, 'state[1]': {'bits': [4]}}
        gate = {'pulse': {'bits': [7]}, 'state[0]': {'bits': [7]}, 'state[1]': {'bits': [8]}}
        expected = [r'group /^(pulse|state\[-?[0-9]+\])$/', r'bind /^(pulse|state\[0\])$/']
        self.assertEqual(matching_rules(gold, gate)[1], expected)
        self.assertEqual(matching_rules(gate, gold)[1], expected)

    def test_same_alias_relation_on_both_sides_does_not_expand_proof_cones(self):
        gold = {'a': {'bits': [2]}, 'b': {'bits': [2]}}
        gate = {'a': {'bits': [7]}, 'b': {'bits': [7]}}
        self.assertEqual(matching_rules(gold, gate)[1], [r'group /^(a|b)$/'])

    def test_one_sided_propagated_constant_retains_actual_producer(self):
        gold={'len[0]': {'bits': [2]}, 'len[1]': {'bits': [3]}}
        gate={'len[0]': {'bits': ['0']}, 'len[1]': {'bits': [7]}}
        expected=[r'group /^(len\[-?[0-9]+\])$/', r'bind /^(len\[0\])$/']
        self.assertEqual(matching_rules(gold,gate)[1],expected)
        self.assertEqual(matching_rules(gate,gold)[1],expected)
        self.assertNotIn('assume',' '.join(expected))

    def test_constants_do_not_merge_unrelated_buses(self):
        nets = {'a[0]': {'bits': ['0']}, 'a[1]': {'bits': [3]},
                'b[0]': {'bits': ['0']}, 'b[1]': {'bits': [4]}}
        self.assertEqual(len(matching_rules(nets, nets)[1]), 2)

    def test_private_normalization_temporaries_are_not_match_points(self):
        nets={'$temporary/source.v[0]': {'bits': [2]},
              'hidden/source.v[0]': {'bits': [2], 'hide_name': 1},
              'public': {'bits': [2]}}
        self.assertEqual(matching_rules(nets,nets),([],[]))

    def test_function_expansion_locals_are_not_correspondence_points(self):
        nets={'u.gmix$func$source/rtl/core.v:12$34.a[0]': {'bits': [2]},
              'public': {'bits': [2]}}
        self.assertEqual(matching_rules(nets,nets),([r'gold-nomatch /.*\$func\$.*/'],[]))

    def test_unsupported_pattern_names_fail_closed(self):
        with self.assertRaises(ValueError):
            matching_rules({'unsafe/name': {'bits': [2]}},
                           {'unsafe/name[0]': {'bits': [2]}})


class StateCorrespondenceTest(unittest.TestCase):
    def fixture(self, constant=False):
        nets={'a': {'bits': [2]}, 'q': {'bits': [3]}, 'state[0]': {'bits': ['0' if constant else 4]},
              'comb': {'bits': [5]}, 'u.fn$func$source/path': {'bits': [4]}}
        return {'netnames': nets,
                'ports': {'a': {'direction': 'input', 'bits': [2]}, 'q': {'direction': 'output', 'bits': [3]}},
                'cells': {'ff': {'type': '$dff', 'port_directions': {'Q': 'output'}, 'connections': {'Q': [4]}}}}

    def test_selects_state_and_every_boundary_without_combinational_cuts(self):
        gold=self.fixture();gate=self.fixture()
        self.assertEqual(state_correspondences(gold,gate),{'a':'a','q':'q','state[0]':'state[0]'})

    def test_propagated_constant_retains_state_correspondence(self):
        self.assertIn('state[0]',state_correspondences(self.fixture(),self.fixture(True)))
        self.assertIn('state[0]',state_correspondences(self.fixture(True),self.fixture()))

    def test_inconsistent_or_unscalarized_interfaces_rejected(self):
        for mode in ['missing','width','direction','hidden']:
            gold=self.fixture();gate=self.fixture()
            if mode=='missing':del gate['ports']['q']
            elif mode=='width':gate['ports']['q']['bits'].append(6)
            elif mode=='direction':gate['ports']['q']['direction']='input'
            else:gold['netnames']['q']['hide_name']=1
            with self.subTest(mode=mode), self.assertRaises(ValueError):state_correspondences(gold,gate)

    def test_configuration_matches_outputs_before_excluding_intermediates(self):
        with tempfile.TemporaryDirectory() as tmp:
            build=Path(tmp)
            for side in ('gold','gate'):
                (build/f'{side}-interface.json').write_text(json.dumps({'modules': {'top': self.fixture(side=='gate')}}))
            text=configuration(build,'top',state_only=True)
            patterns=[re.compile(line.split()[1][1:-1]) for line in text.splitlines() if line.startswith('gold-match ')]
            for name in ['a','q','state[0]']:
                self.assertTrue(any(pattern.fullmatch(name) for pattern in patterns))
            self.assertFalse(any(pattern.fullmatch('comb') for pattern in patterns))
            self.assertIn(r'bind /^(state\[0\])$/',text)
            self.assertNotIn('gold-match /^comb$/',text)
            self.assertLess(text.index('gold-match '),text.index('gold-nomatch *'))


class ExplicitMatchBatchTest(unittest.TestCase):
    def test_batches_preserve_the_exact_set_of_identity_names(self):
        names=[f'q[{i}]' for i in range(260)]
        rules=explicit_match_rules({n:n for n in names})
        self.assertEqual(len(rules),3)
        patterns=[re.compile(line.split()[1][1:-1]) for line in rules]
        for name in names:
            self.assertEqual(sum(bool(p.fullmatch(name)) for p in patterns),1)
        for extra in ['q[260]','q[-1]','prefix.q[0]','q[0].suffix']:
            self.assertFalse(any(p.fullmatch(extra) for p in patterns))

    def test_renamed_pairs_and_unsafe_names(self):
        self.assertEqual(explicit_match_rules({'x':'x[0]'}),[r'gold-match /^x$/ /^x\[0\]$/'])
        with self.assertRaises(ValueError):explicit_match_rules({'bad/name':'bad/name'})
        with self.assertRaises(ValueError):explicit_match_rules({'x':'x'},0)


class PartitionEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.build = Path(self.tmp.name)
        self.proof = self.build / 'eqy'
        self.proof.mkdir()
        for side in ('gold', 'gate'):
            (self.build / f'{side}-interface.json').write_text(json.dumps({'modules': {
                'top': {'ports': {'clk': {'direction': 'input', 'bits': [2]},
                                  'q': {'direction': 'output', 'bits': [3]}}}}}))
        (self.proof / 'PASS').touch()
        (self.proof / 'partition.list').write_text('top top.q xbits : q\ntop top.state xbits : state\n')
        (self.proof / 'partitions').mkdir()
        for name in ('top.q', 'top.state'):
            (self.proof / 'partitions' / (name + '.json')).write_text(json.dumps({
                'partition': {'name': name, 'outbits': {name[4:]: [0]}}}))
            path = self.proof / 'strategies' / name / 'pdr'
            path.mkdir(parents=True)
            (path / 'status').write_text('PASS\n')

    def inspect(self, code=0):
        return inspect_proof(self.build, 'top', code)

    def test_all_partitions_required(self):
        self.assertEqual(self.inspect()['status'], 'PASS')
        (self.proof / 'strategies/top.state/pdr/status').unlink()
        self.assertEqual(self.inspect()['status'], 'FAIL')

    def test_passing_internal_partition_cannot_hide_missing_output(self):
        path=self.proof/'partitions/top.q.json'
        path.write_text(json.dumps({'partition': {'name': 'top.q', 'outbits': {'internal': [0]}}}))
        self.assertIn('uncovered boundary output bits: q',self.inspect()['errors'])

    def test_every_output_bit_required_even_with_global_pass(self):
        for side in ('gold','gate'):
            path=self.build/f'{side}-interface.json'
            data=json.loads(path.read_text())
            data['modules']['top']['ports']['q']['bits'].append(4)
            path.write_text(json.dumps(data))
        self.assertEqual(self.inspect()['status'],'FAIL')
        path=self.proof/'partitions/top.q.json'
        data=json.loads(path.read_text());data['partition']['outbits']['q']=[0,1]
        path.write_text(json.dumps(data))
        self.assertEqual(self.inspect()['status'],'PASS')

    def test_partition_indices_are_wire_relative_not_declaration_offsets(self):
        for side in ('gold','gate'):
            path=self.build/f'{side}-interface.json'
            data=json.loads(path.read_text())
            data['modules']['top']['netnames']={'q': {'bits': [3], 'offset': 4}}
            path.write_text(json.dumps(data))
        self.assertEqual(self.inspect()['status'],'PASS')
        path=self.proof/'partitions/top.q.json'
        data=json.loads(path.read_text());data['partition']['outbits']['q']=[4]
        path.write_text(json.dumps(data))
        self.assertEqual(self.inspect()['status'],'FAIL')

    def test_scalar_pin_name_still_requires_its_own_local_output_bit(self):
        for side in ('gold','gate'):
            path=self.build/f'{side}-interface.json'
            data=json.loads(path.read_text());module=data['modules']['top']
            module['ports']['q[7]']=module['ports'].pop('q')
            module['netnames']={'q[7]': {'bits': [3], 'offset': 7}}
            path.write_text(json.dumps(data))
        path=self.proof/'partitions/top.q.json'
        data=json.loads(path.read_text());data['partition']['outbits']={'q[7]':[0]}
        path.write_text(json.dumps(data))
        self.assertEqual(self.inspect()['status'],'PASS')
        for wrong in [{'q[0]':[0]}, {'q[7]':[7]}, {'q[7]':[]}]:
            data['partition']['outbits']=wrong;path.write_text(json.dumps(data))
            self.assertEqual(self.inspect()['status'],'FAIL')

    def test_missing_or_wrong_partition_metadata_rejected(self):
        path=self.proof/'partitions/top.state.json'
        for content in ['{}','bad json',json.dumps({'partition': {'name':'wrong','outbits':{}}})]:
            path.write_text(content)
            self.assertEqual(self.inspect()['status'],'FAIL')
        path.unlink()
        self.assertEqual(self.inspect()['status'],'FAIL')

    def test_timeout_does_not_count_as_proof(self):
        (self.proof / 'strategies/top.state/pdr/status').write_text('TIMEOUT\n')
        self.assertEqual(self.inspect()['status'], 'FAIL')

    def add_smt_pass(self):
        path = self.proof / 'strategies/top.state/smt'
        path.mkdir()
        (path / 'status').write_text('PASS\n')

    def test_fallback_can_resolve_timeout_or_unknown(self):
        self.add_smt_pass()
        for state in ('TIMEOUT', 'UNKNOWN'):
            with self.subTest(state=state):
                (self.proof / 'strategies/top.state/pdr/status').write_text(state+'\n')
                self.assertEqual(self.inspect()['status'], 'PASS')

    def test_fallback_cannot_hide_counterexample_or_tool_error(self):
        self.add_smt_pass()
        for state in ('FAIL', 'ERROR', '', 'unexpected'):
            with self.subTest(state=state):
                (self.proof / 'strategies/top.state/pdr/status').write_text(state+'\n')
                self.assertEqual(self.inspect()['status'], 'FAIL')

    def test_empty_strategy_status_rejected(self):
        (self.proof / 'strategies/top.state/pdr/status').write_text('')
        self.assertEqual(self.inspect()['status'], 'FAIL')

    def test_global_marker_alone_insufficient(self):
        self.assertEqual(self.inspect(1)['status'], 'FAIL')
        (self.proof / 'ERROR').touch()
        self.assertEqual(self.inspect()['status'], 'FAIL')

    def test_empty_partitions_rejected(self):
        (self.proof / 'partition.list').write_text('')
        self.assertEqual(self.inspect()['status'], 'FAIL')

    def test_duplicate_partitions_rejected(self):
        (self.proof / 'partition.list').write_text('top top.q xbits : q\ntop top.q xbits : q\n')
        self.assertEqual(self.inspect()['status'], 'FAIL')

    def test_missing_memory_pin_rejected(self):
        path = self.build / 'gate-interface.json'
        data = json.loads(path.read_text())
        data['modules']['top']['ports']['mem.addr0'] = {'direction': 'output', 'bits': [4]}
        path.write_text(json.dumps(data))
        self.assertEqual(self.inspect()['status'], 'FAIL')


class StrategyConfigurationTest(unittest.TestCase):
    def test_explicit_binding_retains_exact_driven_net(self):
        with tempfile.TemporaryDirectory() as tmp:
            build=Path(tmp)
            for side in ('gold','gate'):
                (build/f'{side}-interface.json').write_text(json.dumps({'modules': {'top': {
                    'netnames': {'u.bank[0]': {'bits': [4]}}, 'ports': {}}}}))
            text=configuration(build,'top',600,'smt',['u.bank[0]'])
            self.assertIn(r'bind /^u\.bank\[0\]$/',text)

    def test_explicit_binding_rejects_missing_constant_bus_and_input_alias(self):
        with tempfile.TemporaryDirectory() as tmp:
            build=Path(tmp)
            for nets in [{}, {'bad': {'bits': ['0']}}, {'bad': {'bits': [4,5]}}, {'bad': {'bits': [2]}}]:
                for side in ('gold','gate'):
                    (build/f'{side}-interface.json').write_text(json.dumps({'modules': {'top': {
                        'netnames': nets, 'ports': {'input': {'direction': 'input', 'bits': [2]}}}}}))
                with self.assertRaises(ValueError):configuration(build,'top',600,'smt',['bad'])

    def test_unmatching_keeps_boundary_and_logic_in_configuration(self):
        with tempfile.TemporaryDirectory() as tmp:
            build=Path(tmp)
            for side in ('gold','gate'):
                (build/f'{side}-interface.json').write_text(json.dumps({'modules': {'top': {
                    'netnames': {'sum': {'bits': [4,5]}, 'q': {'bits': [3]}},
                    'ports': {'q': {'direction': 'output', 'bits': [3]}}}}}))
            text=configuration(build,'top',unmatch_nets=['sum'])
            self.assertIn('gold-nomatch /^sum$/',text)
            self.assertEqual(text.count('read_rtlil'),2)
            self.assertNotIn('delete ',text)
            self.assertNotIn('gold-nomatch /^q$/',text)
            self.assertNotIn('xprop off',text)

    def test_unmatching_rejects_boundary_alias_missing_constant_and_conflict(self):
        with tempfile.TemporaryDirectory() as tmp:
            build=Path(tmp)
            for bits in ([],['0'],[2],[3],[4,3]):
                for side in ('gold','gate'):
                    (build/f'{side}-interface.json').write_text(json.dumps({'modules': {'top': {
                        'netnames': {'bad': {'bits': bits}},
                        'ports': {'clk': {'direction': 'input', 'bits': [2]},
                                  'q': {'direction': 'output', 'bits': [3]}}}}}))
                with self.subTest(bits=bits), self.assertRaises(ValueError):
                    configuration(build,'top',unmatch_nets=['bad'])
            with self.assertRaises(ValueError):
                configuration(build,'top',bind_nets=['bad'],unmatch_nets=['bad'])

    def test_function_local_exclusion_cannot_remove_boundary_port(self):
        with tempfile.TemporaryDirectory() as tmp:
            build=Path(tmp)
            for side in ('gold','gate'):
                (build/f'{side}-interface.json').write_text(json.dumps({'modules': {'top': {
                    'netnames': {'q$func$': {'bits': [4]}},
                    'ports': {'q$func$': {'direction': 'output', 'bits': [4]}}}}}))
            with self.assertRaises(ValueError):configuration(build,'top')

    def test_only_requested_proving_engines_are_generated(self):
        with tempfile.TemporaryDirectory() as tmp:
            build = Path(tmp)
            for side in ('gold', 'gate'):
                (build / f'{side}-interface.json').write_text(json.dumps({
                    'modules': {'top': {'netnames': {}}}}))
            for strategy, engines in [('pdr', ['abc pdr']), ('smt', ['smtbmc bitwuzla']),
                                      ('pdr-smt', ['abc pdr', 'smtbmc bitwuzla']),
                                      ('smt-pdr', ['smtbmc bitwuzla', 'abc pdr'])]:
                with self.subTest(strategy=strategy):
                    text = configuration(build, 'top', 600, strategy)
                    self.assertEqual([line[7:] for line in text.splitlines()
                                      if line.startswith('engine ')], engines)
                    self.assertEqual(text.count('timeout 600'), len(engines))
                    self.assertNotIn('xprop off', text)
                    if strategy == 'smt':
                        self.assertNotIn('aigsmt', text)
            with self.assertRaises(ValueError):
                configuration(build, 'top', 600, 'bmc')


if __name__ == '__main__':
    unittest.main()
