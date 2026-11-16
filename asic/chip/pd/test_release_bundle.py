"""Release evidence must follow exact run sources, netlists and corner views."""
import json
from pathlib import Path
import tempfile
import unittest

from release_bundle import stage_bundle, install_bundle, verify_bundle
from run_inputs import digest, equivalence_proved, verified_inputs
from signoff_gate import KINDS, ZERO_METRICS


class ReleaseBundleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.archive = self.root / 'build/snapshot'
        self.run = self.root / 'pd/wrapper/runs/test'
        self.lec = self.root / 'build/lec'
        self.output = self.root / 'bundle'
        self.manifest = self.archive / 'manifest.json'
        self.policy = self.root / 'policy.json'
        self.corner = 'nom_tt_025C_1v80'
        self.design = 'user_project_wrapper'
        self.blocked_sources = self.root / 'production/blocked_sources.json'
        self.write(self.blocked_sources, json.dumps(dict(schema=1, entries=[])))
        names = ['rtl/defines.v', 'rtl/core.v', 'wrapper/user_project_wrapper.v']
        for name in names:
            self.write(self.archive / name, '// archived ' + name + '\n')
        self.write(self.archive / 'wrapper/chip.sdc', 'create_clock -period 25 clk\n')
        original = dict(DESIGN_NAME=self.design,
                        VERILOG_FILES=['dir::../../build/snapshot/' + n for n in names],
                        PNR_SDC_FILE='dir::../../build/snapshot/wrapper/chip.sdc',
                        SIGNOFF_SDC_FILE='dir::../../build/snapshot/wrapper/chip.sdc')
        self.write(self.archive / 'config.json', json.dumps(original))
        self.write(self.manifest, json.dumps({'files': {
            str(p.relative_to(self.archive)): digest(p) for p in self.archive.rglob('*') if p.is_file()}}))
        self.resolved = dict(original)
        self.resolved['VERILOG_FILES'] = ['/work/build/snapshot/' + n for n in names]
        for k in ('PNR_SDC_FILE', 'SIGNOFF_SDC_FILE'):
            self.resolved[k] = '/work/build/snapshot/wrapper/chip.sdc'
        self.write(self.run / 'resolved.json', json.dumps(self.resolved))
        self.write(self.policy, json.dumps(dict(required_corners=[self.corner], max_ir_drop_v=0.09, waivers=[])))
        self.step = self.run / '51-openroad-stapostpnr'
        self.write(self.step / 'config.json', json.dumps(dict(STA_CORNERS=[self.corner])))
        checks = ('report_checks\nreport_check_types -max_slew -max_cap -max_fanout -violators\n'
                  + ''.join(f'max {k} violation count 0\n' for k in KINDS))
        self.write(self.step / self.corner / 'checks.rpt', checks)
        metrics = {k: 0 for k in ZERO_METRICS}
        metrics['ir__drop__worst'] = 0.01
        for kind, suffix in [('setup', 'max'), ('hold', 'min')]:
            self.write(self.step / self.corner / f'ws.{suffix}.rpt',
                       f'Worst Slack ({kind.title()})\n{self.corner}: 0.1\n')
            metrics[f'timing__{kind}__ws__corner:{self.corner}'] = 0.1
        for k in KINDS:
            metrics[f'design__max_{k}_violation__count__corner:{self.corner}'] = 0
        self.write(self.run / 'final/metrics.json', json.dumps(metrics))
        for fmt, ext in [('gds', 'gds'), ('lef', 'lef'), ('def', 'def'), ('sdc', 'sdc'), ('nl', 'nl.v'), ('pnl', 'pnl.v')]:
            self.write(self.run / 'final' / fmt / (self.design + '.' + ext), 'fixture ' + fmt)
        self.write(self.run / 'final/spef/nom' / (self.design + '.nom.spef'), 'SPEF fixture')
        self.write(self.run / 'final/sdf' / self.corner / (self.design + '__' + self.corner + '.sdf'), 'SDF fixture')
        for name in ('cec.log', 'chip_rtl.v', 'cells.lib', 'sram.v', 'cec.sh'):
            self.write(self.lec / name, 'fixture ' + name)
        self.write(self.lec / 'gate.v', (self.run / 'final/nl' / (self.design + '.nl.v')).read_text())
        self.write(self.lec / 'proof.txt', 'Networks are equivalent\n')
        sources = {}
        for i, name in enumerate(names):
            key = 'sources/%03d.v' % i
            self.write(self.lec / key, (self.archive / name).read_text())
            sources[key] = digest(self.archive / name)
        self.write(self.lec / 'inputs.json', json.dumps(dict(
            engine='abc',
            source_manifest_sha256=digest(self.manifest),
            resolved_sha256=digest(self.run / 'resolved.json'),
            gate_sha256=digest(self.lec / 'gate.v'),
            library_sha256=digest(self.lec / 'cells.lib'), source_sha256=sources)))
        self.lec_result = dict(status='PASS', engine='abc', release_eligible=True,
                               source_manifest_sha256=digest(self.manifest),
                               resolved_sha256=digest(self.run / 'resolved.json'),
                               gate_sha256=digest(self.lec / 'gate.v'),
                               evidence_sha256={p.name: digest(p) for p in self.lec.iterdir() if p.is_file()})
        self.save_lec()

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def save_lec(self):
        self.write(self.lec / 'result.json', json.dumps(self.lec_result))

    def stage(self):
        return stage_bundle(self.run, self.manifest, self.policy, self.lec, self.output, self.root)

    def test_archived_sources_and_all_views_are_packaged(self):
        # Deliberately unrelated live default config must never be read.
        self.write(self.root / 'pd/wrapper/config.json', '{"VERILOG_FILES": ["wrong.v"]}')
        result = self.stage()
        self.assertIn('archived rtl/core.v', (self.output / 'verilog/rtl/zeq/zeq_all.v').read_text())
        self.assertIn('spef/multicorner/user_project_wrapper.nom.spef', result['files'])
        self.assertIn('sdf/multicorner/user_project_wrapper__nom_tt_025C_1v80.sdf', result['files'])
        self.assertEqual(result['precheck_status'], 'not_run')

    def test_reviewed_macro_library_is_bound_into_bundle(self):
        library = self.root / 'pdk/sram.lib'
        self.write(library, 'library(sram_tt) { nom_temperature: 25; nom_voltage: 1.8; }\n')
        macros = {'sram': {'lib': {'*': [str(library)]}}}
        self.resolved['MACROS'] = macros
        self.write(self.run / 'resolved.json', json.dumps(self.resolved))
        self.write(self.step / 'config.json', json.dumps(dict(STA_CORNERS=[self.corner], MACROS=macros)))
        policy = json.loads(self.policy.read_text())
        policy['macro_timing_views'] = {'sram': {self.corner: dict(
            process='tt', temperature_c=25, voltage_v=1.8, sha256=[digest(library)])}}
        self.write(self.policy, json.dumps(policy))
        # Fixture proof must bind the updated resolved configuration too.
        inputs = json.loads((self.lec / 'inputs.json').read_text())
        inputs['resolved_sha256'] = digest(self.run / 'resolved.json')
        self.write(self.lec / 'inputs.json', json.dumps(inputs))
        self.lec_result['resolved_sha256'] = inputs['resolved_sha256']
        self.lec_result['evidence_sha256']['inputs.json'] = digest(self.lec / 'inputs.json')
        self.save_lec()
        result = self.stage()
        name = 'evidence/macro-libraries/000-sram.lib'
        self.assertEqual(result['files'][name], digest(library))
        self.assertEqual((self.output / name).read_bytes(), library.read_bytes())

    def test_modified_source_rejected_before_staging(self):
        (self.archive / 'rtl/core.v').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            self.stage()
        self.assertFalse(self.output.exists())

    def test_changed_source_order_rejected(self):
        self.resolved['VERILOG_FILES'].reverse()
        self.write(self.run / 'resolved.json', json.dumps(self.resolved))
        with self.assertRaisesRegex(ValueError, 'source list/order'):
            self.stage()

    def test_unbound_constraint_rejected(self):
        self.resolved['SIGNOFF_SDC_FILE'] = '/work/live.sdc'
        self.write(self.run / 'resolved.json', json.dumps(self.resolved))
        with self.assertRaisesRegex(ValueError, 'constraint'):
            self.stage()

    def test_synthesis_only_lec_does_not_qualify_changed_final_netlist(self):
        self.write(self.run / 'final/nl' / (self.design + '.nl.v'), 'routed netlist differs')
        with self.assertRaisesRegex(ValueError, 'exact source/configuration/final netlist'):
            self.stage()

    def test_unproven_lec_rejected(self):
        self.lec_result['status'] = 'UNDECIDED'
        self.save_lec()
        with self.assertRaisesRegex(ValueError, 'LEC'):
            self.stage()

    def test_experimental_lec_cannot_qualify_release(self):
        self.lec_result.update(engine='eqy', release_eligible=False)
        self.save_lec()
        with self.assertRaisesRegex(ValueError, 'not yet qualified'):
            self.stage()

    def test_release_requires_explicit_boolean_eligibility(self):
        for value in (None, False, 0, 1, 'true', 'false'):
            with self.subTest(value=value):
                self.lec_result['release_eligible'] = value
                self.save_lec()
                with self.assertRaisesRegex(ValueError, 'not yet qualified'):
                    self.stage()
                self.assertFalse(self.output.exists())
        del self.lec_result['release_eligible']
        self.save_lec()
        with self.assertRaisesRegex(ValueError, 'not yet qualified'):
            self.stage()

    def test_release_requires_explicit_qualified_engine(self):
        for value in (None, '', 'eqy'):
            with self.subTest(value=value):
                self.lec_result['engine'] = value
                self.save_lec()
                with self.assertRaisesRegex(ValueError, 'not yet qualified'):
                    self.stage()
                self.assertFalse(self.output.exists())
        del self.lec_result['engine']
        self.save_lec()
        with self.assertRaisesRegex(ValueError, 'not yet qualified'):
            self.stage()

    def test_result_cannot_relabel_experimental_or_unknown_engine(self):
        for value in (None, 'eqy'):
            with self.subTest(value=value):
                inputs = json.loads((self.lec / 'inputs.json').read_text())
                if value is None:
                    inputs.pop('engine', None)
                else:
                    inputs['engine'] = value
                self.write(self.lec / 'inputs.json', json.dumps(inputs))
                self.lec_result['evidence_sha256']['inputs.json'] = digest(self.lec / 'inputs.json')
                self.save_lec()
                with self.assertRaisesRegex(ValueError, 'input/result mismatch: engine'):
                    self.stage()
                self.assertFalse(self.output.exists())

    def test_changed_lec_proof_rejected(self):
        (self.lec / 'proof.txt').write_text('changed proof')
        with self.assertRaisesRegex(ValueError, 'LEC artifact hash'):
            self.stage()

    def test_missing_sdf_rejected(self):
        next((self.run / 'final/sdf').rglob('*.sdf')).unlink()
        with self.assertRaisesRegex(ValueError, 'missing/empty release artifact'):
            self.stage()

    def test_missing_spef_rejected(self):
        next((self.run / 'final/spef').rglob('*.spef')).unlink()
        with self.assertRaisesRegex(ValueError, 'missing/empty release artifact'):
            self.stage()

    def test_known_release_blocker_rejected(self):
        (self.run / 'RELEASE_BLOCKED.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'physical signoff rejected'):
            self.stage()

    def test_known_bad_rtl_rejected_without_run_marker(self):
        # A copied run with clean physical fixtures and passing LEC still
        # cannot release RTL with a reproduced functional defect.
        self.write(self.blocked_sources, json.dumps(dict(schema=1, entries=[dict(
            sha256=digest(self.archive / 'rtl/core.v'), reason='reproduced functional defect') ])))
        with self.assertRaisesRegex(ValueError, 'known defective release source'):
            self.stage()
        self.assertFalse(self.output.exists())

    def test_missing_defect_registry_rejected(self):
        self.blocked_sources.unlink()
        with self.assertRaises(FileNotFoundError):
            self.stage()

    def test_malformed_defect_registry_rejected(self):
        self.write(self.blocked_sources, json.dumps(dict(schema=1, entries=[dict(sha256='bad', reason='bad') ])))
        with self.assertRaisesRegex(ValueError, 'blocked-source entry'):
            self.stage()

    def test_defect_registry_is_in_release_evidence(self):
        result = self.stage()
        self.assertEqual(result['files']['evidence/blocked_sources.json'], digest(self.blocked_sources))

    def test_existing_bundle_is_not_overwritten(self):
        self.stage()
        with self.assertRaisesRegex(ValueError, 'already exists'):
            self.stage()

    def test_tampered_bundle_does_not_modify_checkout(self):
        self.stage()
        (self.output / 'gds/user_project_wrapper.gds').write_text('tampered')
        destination = self.root / 'caravel'
        destination.mkdir()
        with self.assertRaisesRegex(ValueError, 'bundle hash mismatch'):
            install_bundle(self.output, destination)
        self.assertEqual(list(destination.iterdir()), [])

    def test_install_copies_verified_files(self):
        self.stage()
        destination = self.root / 'caravel'
        destination.mkdir()
        install_bundle(self.output, destination)
        self.assertTrue((destination / 'release-manifest.json').is_file())
        self.assertFalse((destination / 'RELEASE_INCOMPLETE.json').exists())
        self.assertEqual(verify_bundle(destination), digest(destination / 'release-manifest.json'))

    def test_changed_lec_source_copy_rejected(self):
        (self.lec / 'sources/001.v').write_text('different RTL')
        with self.assertRaisesRegex(ValueError, 'LEC source copy changed'):
            self.stage()

    def test_installed_file_tampering_rejected(self):
        self.stage()
        destination = self.root / 'caravel'
        destination.mkdir()
        install_bundle(self.output, destination)
        (destination / 'verilog/gl/user_project_wrapper.v').write_text('different netlist')
        with self.assertRaisesRegex(ValueError, 'installed bundle hash mismatch'):
            verify_bundle(destination)

    def test_archive_path_escape_rejected(self):
        self.write(self.root / 'outside.v', 'outside')
        data = json.loads(self.manifest.read_text())
        data['files']['../../outside.v'] = digest(self.root / 'outside.v')
        self.manifest.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            verified_inputs(self.run, self.manifest, self.root)

    def test_proof_verdicts_are_unambiguous(self):
        self.assertTrue(equivalence_proved('Networks are equivalent. Time = 1\n'))
        self.assertTrue(equivalence_proved('UNSATISFIABLE  Time = 0.01 sec\n'))
        for text in ('SATISFIABLE Time = 0.01 sec\n', 'Error: Networks are equivalent',
                     'UNDECIDED', 'timeout', ''):
            self.assertFalse(equivalence_proved(text))

    def test_stale_incomplete_install_is_not_overwritten(self):
        self.stage()
        destination = self.root / 'caravel'
        destination.mkdir()
        (destination / 'RELEASE_INCOMPLETE.json').write_text('{}')
        with self.assertRaises(FileExistsError):
            install_bundle(self.output, destination)
        self.assertFalse((destination / 'gds').exists())


if __name__ == '__main__':
    unittest.main()
