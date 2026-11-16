"""Reject tampered archival evidence and checker failures during recovery."""
import contextlib
import io
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import audit_par_archive as runner


class ArchiveAuditTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root/'build/original'
        files = {}
        for name in ['asic/chip/model/par_qualification.py','asic/chip/rtl/zeq_eh_par.v',
                     'zig-out/bin/zcash-miner']:
            p = self.source/'source'/name
            p.parent.mkdir(parents=True,exist_ok=True)
            p.write_text('archived '+name)
            files[name] = runner.sha(p)
        for name in ['source.tgz','compile.log','simulation.log','obj/simulation',
                     'run/solver_hdr.hex','run/solver_out.txt','run/memory_accesses.csv',
                     'run/network_activity.csv','run/par_profile.txt','run/memory_profile.txt']:
            p = self.source/name
            p.parent.mkdir(parents=True,exist_ok=True)
            p.write_text('original '+name)
        params = dict(N=48,K=5,NH=4,BB=4,PB=2,HPB=2,SB=7,SLOTS=80,
                      PACKED_TABLES=1,SPLIT_KEYS=1,COMPACT_VALUES=1,
                      STAGED_NETWORK=0,BIST_FIRST=0)
        self.inputs = dict(parameters=params,files=files,seed='test',
                           source_sha256=runner.sha(self.source/'source.tgz'),
                           headers_sha256=runner.sha(self.source/'run/solver_hdr.hex'))
        (self.source/'inputs.json').write_text(json.dumps(self.inputs))
        self.input_hash = runner.sha(self.source/'inputs.json')
        self.output_hash = runner.sha(self.source/'run/solver_out.txt')
        p = self.root/'model/audit_solver_log.py'
        p.parent.mkdir()
        p.write_text('new reference-set checker')
        self.build = self.root/'build/review'
        self.build.mkdir()

    def freeze(self):
        with patch.object(runner,'ROOT',self.root):
            return runner.freeze_archive(self.source,self.build,self.input_hash,self.output_hash)

    def test_copy_preserves_original_and_checker_verifier_layout(self):
        inputs, files = self.freeze()
        runner.verify_files(self.build,files)
        model = self.build/'source/asic/chip/model'
        self.assertEqual((model/'../../../zig-out/bin/zcash-miner').resolve(),
                         self.build/'source/zig-out/bin/zcash-miner')
        self.assertEqual(runner.sha(self.source/'inputs.json'),self.input_hash)
        self.assertEqual(inputs,self.inputs)

    def test_hash_pipeline_metadata_is_bound_and_unsupported_split_rejected(self):
        self.inputs['parameters']['HASH_SPLIT']=4
        p=self.source/'inputs.json';p.write_text(json.dumps(self.inputs))
        self.input_hash=runner.sha(p)
        inputs,files=self.freeze()
        self.assertEqual(inputs['parameters']['HASH_SPLIT'],4)
        self.assertEqual(files['original/inputs.json'],self.input_hash)
        self.inputs['parameters']['HASH_SPLIT']=3
        p.write_text(json.dumps(self.inputs));self.input_hash=runner.sha(p)
        with self.assertRaisesRegex(ValueError,'unsupported archived hash split'):
            self.freeze()

    def test_input_or_output_binding_changes_are_rejected(self):
        for name in ['inputs.json','run/solver_out.txt']:
            p = self.source/name
            old = p.read_bytes()
            p.write_text('changed')
            with self.subTest(name=name), self.assertRaisesRegex(ValueError,'hash mismatch'):
                self.freeze()
            p.write_bytes(old)

    def test_bucket_zero_capacity_is_bound_and_must_fit_existing_slot_bits(self):
        p=self.source/'inputs.json'
        for capacity in (112,79,129):
            self.inputs['parameters']['BUCKET0_SLOTS']=capacity
            p.write_text(json.dumps(self.inputs));self.input_hash=runner.sha(p)
            if capacity == 112:
                inputs,files=self.freeze()
                self.assertEqual(inputs['parameters']['BUCKET0_SLOTS'],112)
                self.assertEqual(files['original/inputs.json'],self.input_hash)
            else:
                with self.subTest(capacity=capacity), self.assertRaises(ValueError):
                    self.freeze()

    def test_drop_trace_is_required_and_preserved_when_enabled(self):
        self.inputs['parameters']['TRACE_DROPS']=1
        p=self.source/'inputs.json';p.write_text(json.dumps(self.inputs))
        self.input_hash=runner.sha(p)
        with self.assertRaisesRegex(ValueError,'missing archived file: run/dropped_rows.csv'):
            self.freeze()
        trace=self.source/'run/dropped_rows.csv';trace.write_text('diagnostic rows\n')
        inputs,files=self.freeze()
        self.assertEqual(files['original/run/dropped_rows.csv'],runner.sha(trace))
        self.assertEqual(inputs['parameters']['TRACE_DROPS'],1)
        self.inputs['parameters']['TRACE_DROPS']=2
        p.write_text(json.dumps(self.inputs));self.input_hash=runner.sha(p)
        with self.assertRaisesRegex(ValueError,'unsupported archived drop trace mode'):
            self.freeze()

    def test_model_verifier_header_or_tar_tampering_is_rejected(self):
        for name in ['source/asic/chip/model/par_qualification.py',
                     'source/zig-out/bin/zcash-miner','run/solver_hdr.hex','source.tgz']:
            p = self.source/name
            old = p.read_bytes()
            p.write_text('changed')
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.freeze()
            p.write_bytes(old)

    def test_paths_cannot_escape_archived_root(self):
        for name in ['../outside','/tmp/outside']:
            with self.subTest(name=name), self.assertRaisesRegex(ValueError,'invalid archived path'):
                runner.safe_file(self.source,name)
        (self.source/'escape').symlink_to(self.root/'model/audit_solver_log.py')
        with self.assertRaises(ValueError):
            runner.safe_file(self.source,'escape')

    def test_copied_verifier_or_output_changes_are_rejected(self):
        _, files = self.freeze()
        for name in ['source/zig-out/bin/zcash-miner','original/run/solver_out.txt']:
            p = self.build/name
            old = p.read_bytes()
            p.write_text('changed')
            with self.subTest(name=name), self.assertRaisesRegex(ValueError,'audit input changed'):
                runner.verify_files(self.build,files)
            p.write_bytes(old)

    def run_driver(self, fault=None):
        out = self.root/'build/driver'
        calls = []
        class Process:
            pid = 12345
            def __init__(inner,command,**kwargs):
                calls.append(command)
            def wait(inner,timeout=None):
                if timeout is None:
                    return -9
                if fault=='signal':
                    signal.getsignal(signal.SIGTERM)(signal.SIGTERM,None)
                audit = out/'audit'
                audit.mkdir()
                summary = dict(status='PASS',headers=4,results=dict(rtl=dict(
                    solutions=1,reference_solutions=1,missing_reference_solutions=0,total_cycles=100)))
                (audit/'summary.json').write_text(json.dumps(summary))
                if fault=='changed-verifier':
                    (out/'source/zig-out/bin/zcash-miner').write_text('changed')
                return 1 if fault=='checker-exit' else 0
        args = ['audit_par_archive.py','--source-build','build/original','--build','build/driver',
                '--expected-inputs-sha256',self.input_hash,'--expected-output-sha256',self.output_hash]
        with patch.object(runner,'ROOT',self.root), patch('sys.argv',args), \
             patch.object(subprocess,'Popen',Process), patch.object(runner.os,'killpg') as kill, \
             contextlib.redirect_stdout(io.StringIO()):
            passed = runner.main()
            if fault=='signal':
                kill.assert_called_once_with(12345,signal.SIGKILL)
        return passed,json.loads((out/'result.json').read_text()),calls

    def test_failed_process_cannot_publish_pass(self):
        passed,result,_ = self.run_driver('checker-exit')
        self.assertFalse(passed)
        self.assertEqual(result['status'],'FAIL')

    def test_input_tampering_after_checker_blocks_pass(self):
        passed,result,_ = self.run_driver('changed-verifier')
        self.assertFalse(passed)
        self.assertIn('audit input changed',result['reason'])

    def test_interruption_kills_checker_preserves_failure_and_restores_handlers(self):
        handlers = {s:signal.getsignal(s) for s in (signal.SIGTERM,signal.SIGINT)}
        passed,result,_ = self.run_driver('signal')
        self.assertFalse(passed)
        self.assertEqual(result['status'],'FAIL')
        self.assertIn('interrupted by signal',result['reason'])
        for signum,handler in handlers.items():
            self.assertIs(signal.getsignal(signum),handler)

    def test_success_keeps_scope_limited_and_runs_frozen_checker(self):
        passed,result,calls = self.run_driver()
        self.assertTrue(passed)
        self.assertFalse(result['production_release_qualified'])
        self.assertFalse(result['simulation_replayed'])
        self.assertFalse(result['original_runner_result_reconstructed'])
        self.assertIn('-E',calls[0])
        self.assertIn('-B',calls[0])
        self.assertIn('/source/asic/chip/model/audit_solver_log.py',calls[0][4])
        self.assertIn('original/run/solver_out.txt',result['evidence_sha256'])
        self.assertFalse((self.source/'result.json').exists())


if __name__ == '__main__':
    unittest.main()
