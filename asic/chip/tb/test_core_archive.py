import tempfile
import unittest
import contextlib
import io
import json
import signal
import subprocess
from pathlib import Path
from unittest.mock import patch

import qualify_core_control as runner


class CoreArchiveTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        repo=Path(self.tmp.name)/'repo'
        self.root=repo/'asic/chip'
        for name,body in [('rtl/zeq_link.v','original RTL'),('model/core_control.py','original checker'),
                          ('tb/tb_core_control.sv','original bench'),('tb/qualify_core_control.py','runner'),
                          ('toolchain.json',json.dumps({'verilator':{'image':'verilator/verilator@sha256:'+'0'*64}}))]:
            p=self.root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(body)
        p=repo/'zig-out/bin/zcash-miner';p.parent.mkdir(parents=True);p.write_text('verifier');p.chmod(0o755)
        self.build=self.root/'build/test';self.build.mkdir(parents=True)
        with patch.object(runner,'ROOT',self.root):
            self.chip,self.files=runner.snapshot(self.build)

    def test_worktree_edits_cannot_change_archived_compilation_or_checker(self):
        for name in ('rtl/zeq_link.v','model/core_control.py'):
            (self.root/name).write_text('later edit')
        runner.verify_snapshot(self.build,self.files)
        self.assertEqual((self.chip/'rtl/zeq_link.v').read_text(),'original RTL')
        self.assertEqual((self.chip/'model/core_control.py').read_text(),'original checker')

    def test_checker_relative_verifier_path_resolves_to_archived_binary(self):
        verifier=(self.chip/'model/../../../zig-out/bin/zcash-miner').resolve()
        self.assertEqual(verifier,self.build/'source/zig-out/bin/zcash-miner')
        self.assertEqual(verifier.read_text(),'verifier')
        self.assertTrue(verifier.stat().st_mode & 0o111)

    def test_explicit_verifier_is_frozen_without_replacing_default(self):
        selected=self.root/'release-verifier';selected.write_text('optimized verifier');selected.chmod(0o755)
        build=self.root/'build/explicit';build.mkdir()
        with patch.object(runner,'ROOT',self.root):
            _,files=runner.snapshot(build,verifier_source=selected)
        selected.write_text('changed later')
        runner.verify_snapshot(build,files)
        self.assertEqual((build/'source/zig-out/bin/zcash-miner').read_text(),'optimized verifier')
        self.assertEqual((self.root.parents[1]/'zig-out/bin/zcash-miner').read_text(),'verifier')

    def test_nonexecutable_verifier_rejected_before_snapshot(self):
        selected=self.root/'not-executable';selected.write_text('invalid');selected.chmod(0o644)
        build=self.root/'build/invalid';build.mkdir()
        with patch.object(runner,'ROOT',self.root), self.assertRaisesRegex(ValueError,'executable independent verifier'):
            runner.snapshot(build,verifier_source=selected)
        self.assertFalse((build/'source').exists())

    def test_tampering_with_checker_or_verifier_blocks_qualification(self):
        for name in ('asic/chip/model/core_control.py','zig-out/bin/zcash-miner'):
            with self.subTest(name=name):
                p=self.build/'source'/name;original=p.read_bytes();p.write_text('corrupted')
                with self.assertRaisesRegex(ValueError,'archived input changed'):
                    runner.verify_snapshot(self.build,self.files)
                p.write_bytes(original)

    def test_missing_archived_rtl_blocks_qualification(self):
        (self.chip/'rtl/zeq_link.v').unlink()
        with self.assertRaisesRegex(ValueError,'archived input changed'):
            runner.verify_snapshot(self.build,self.files)

    def run_driver(self, fault=None, options=()):
        build=self.root/'build/driver'
        calls=[]
        class Process:
            def __init__(inner, command, **kwargs):
                calls.append(command)
                inner.command=command
            def wait(inner, timeout):
                command=inner.command
                if '--binary' in command:
                    (build/'obj').mkdir()
                    (build/'obj/simulation').write_text('compiled simulation')
                if 'check' in command:
                    # A checker can publish its own PASS and subsequently fail.
                    (build/'run/result.json').write_text(json.dumps({'status':'PASS'}))
                    if fault=='checker-exit':
                        return 1
                    if fault=='changed-verifier':
                        (build/'source/zig-out/bin/zcash-miner').write_text('changed')
                return 0
        handlers={s:signal.getsignal(s) for s in (signal.SIGINT,signal.SIGTERM)}
        def output(command, **kwargs):
            return 'sha256:fixture-image\n' if command[0]=='docker' else '{"python":"test","numpy":"test"}'
        try:
            with patch.object(runner,'ROOT',self.root), \
                 patch('sys.argv',['qualify_core_control.py','--build','build/driver',*options]), \
                 patch.object(subprocess,'check_output',side_effect=output), \
                 patch.object(subprocess,'Popen',Process), contextlib.redirect_stdout(io.StringIO()):
                passed=runner.main()
        finally:
            for s,handler in handlers.items():signal.signal(s,handler)
        return passed,json.loads((build/'result.json').read_text()),calls

    def test_checker_pass_cannot_override_failed_process(self):
        passed,result,_=self.run_driver('checker-exit')
        self.assertFalse(passed)
        self.assertEqual(result['status'],'FAIL')
        self.assertIn('non-zero exit status',result['reason'])

    def test_checker_pass_cannot_override_changed_verifier(self):
        passed,result,_=self.run_driver('changed-verifier')
        self.assertFalse(passed)
        self.assertEqual(result['status'],'FAIL')
        self.assertIn('archived input changed',result['reason'])

    def test_driver_compiles_and_checks_archived_inputs(self):
        passed,result,calls=self.run_driver()
        self.assertTrue(passed)
        self.assertTrue(result['archived_inputs_unchanged'])
        self.assertIn('run/result.json',result['evidence_sha256'])
        inputs=json.loads((self.root/'build/driver/inputs.json').read_text())
        self.assertEqual(inputs['image_ref'],'verilator/verilator@sha256:'+'0'*64)
        self.assertIn('asic/chip/toolchain.json',inputs['files'])
        compile=next(c for c in calls if '--binary' in c)
        self.assertIn('--network=none',compile)
        sources=[s for s in compile if s.endswith(('.v','.sv'))]
        self.assertTrue(sources)
        self.assertTrue(all('/source/asic/chip/' in s for s in sources))
        for command in calls:
            if 'prepare' in command or 'check' in command:
                self.assertIn('-E',command)
                self.assertIn('/source/asic/chip/model/core_control.py',command[4])

    def test_scaled_capacity_configuration_is_compiled_and_recorded(self):
        passed,result,calls=self.run_driver(options=['--n','200','--engines','64',
            '--hash-engines','32','--bucket0-slots','768','--compile-timeout','3600'])
        self.assertTrue(passed)
        command=next(c for c in calls if '--binary' in c)
        for setting in ['-GPB=6','-GHPB=5','-GBUCKET0_SLOTS=768']:
            self.assertIn(setting,command)
        inputs=json.loads((self.root/'build/driver/inputs.json').read_text())
        self.assertEqual(inputs['parameters']['BUCKET0_SLOTS'],768)
        self.assertEqual(inputs['compile_timeout_seconds'],3600)
        for command in calls:
            if 'prepare' in command or 'check' in command:
                self.assertEqual(command[command.index('--bucket0-slots')+1],'768')

    def test_invalid_geometry_rejected_before_external_tools(self):
        for options in [('--bucket0-slots','79'),('--bucket0-slots','129'),
                        ('--engines','16'),('--hash-engines','8'),
                        ('--compile-timeout','0'),('--output-groups','-1')]:
            with self.subTest(options=options), patch('sys.argv',
                    ['qualify_core_control.py','--build','build/rejected',*options]), \
                    patch.object(subprocess,'check_output') as external, \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                runner.main()
            external.assert_not_called()


if __name__=='__main__':unittest.main()
