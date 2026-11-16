#!/usr/bin/env python3
"""Audit a completed archived solver log without reconstructing its runner verdict.

Copy and hash the old inputs, outputs, models and verifier into a fresh build;
regenerate untruncated reference sets with the archived model. A PASS establishes
reference retention for that log, not proof that the original executable ran
against those sources, a new simulation qualification, or production signoff.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys

from qualify_core_control import ROOT, sha
from qualify_par import accept_audit


def safe_file(base, name):
    if not isinstance(name, str):
        raise ValueError("archived file path must be a string")
    relative = Path(name)
    if relative.is_absolute() or '..' in relative.parts or not relative.parts:
        raise ValueError("invalid archived path: " + name)
    path = (base/relative).resolve()
    path.relative_to(base.resolve())
    if not path.is_file():
        raise ValueError("missing archived file: " + name)
    return path


def freeze_archive(source, build, expected_inputs, expected_outputs):
    if sha(source/'inputs.json') != expected_inputs:
        raise ValueError("original inputs hash mismatch")
    if sha(source/'run/solver_out.txt') != expected_outputs:
        raise ValueError("original output hash mismatch")
    inputs = json.loads((source/'inputs.json').read_text())
    if not isinstance(inputs.get('files'), dict) or not inputs['files']:
        raise ValueError("missing archived source inventory")
    for name, expected in inputs['files'].items():
        if not isinstance(expected, str) or not re.fullmatch('[0-9a-f]{64}',expected):
            raise ValueError("invalid archived digest")
        if sha(safe_file(source/'source', name)) != expected:
            raise ValueError("original archived input changed: " + name)
    if sha(source/'source.tgz') != inputs['source_sha256']:
        raise ValueError("original source archive hash mismatch")
    if sha(source/'run/solver_hdr.hex') != inputs['headers_sha256']:
        raise ValueError("original headers hash mismatch")
    cfg = inputs['parameters']
    required = {'N','K','NH','BB','PB','HPB','SB','SLOTS','PACKED_TABLES',
                'SPLIT_KEYS','COMPACT_VALUES','STAGED_NETWORK','BIST_FIRST'}
    if (not required <= set(cfg) <= required|{'HASH_SPLIT','TRACE_DROPS','BUCKET0_SLOTS','GMAX','GROUP_REPLAY',
                                             'DROP_ZERO','LEAF_SET','HASH_UNITS'}
            or any(type(v) is not int for v in cfg.values())):
        raise ValueError("invalid archived solver parameters")
    if cfg.get('HASH_SPLIT',1) not in (1,2,4):
        raise ValueError("unsupported archived hash split")
    if cfg.get('TRACE_DROPS',0) not in (0,1):
        raise ValueError("unsupported archived drop trace mode")
    if (cfg.get('GROUP_REPLAY',0) not in (0,1) or cfg.get('DROP_ZERO',0) not in (0,1)
            or cfg.get('LEAF_SET',0) not in (0,1) or cfg.get('GMAX',16) not in (2,4,8,16,32,64)
            or cfg.get('HASH_UNITS',1) not in (1,2,4,8)):
        raise ValueError("unsupported archived solver option")
    if not cfg['SLOTS'] <= cfg.get('BUCKET0_SLOTS',cfg['SLOTS']) <= (1 << cfg['SB']):
        raise ValueError("unsupported archived bucket-zero capacity")
    if cfg['N'] not in (48,200) or cfg['NH'] <= 0:
        raise ValueError("unsupported or empty archived corpus")
    files = {}
    for name in inputs['files']:
        target = build/'source'/name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(safe_file(source/'source', name), target)
        files['source/'+name] = sha(target)
    outputs = ['inputs.json','source.tgz','compile.log','simulation.log','obj/simulation',
                 'run/solver_hdr.hex','run/solver_out.txt','run/memory_accesses.csv',
                 'run/network_activity.csv','run/par_profile.txt','run/memory_profile.txt']
    if cfg.get('TRACE_DROPS',0):
        outputs.append('run/dropped_rows.csv')
    for name in outputs:
        original = safe_file(source, name)
        target = build/'original'/name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, target)
        files['original/'+name] = sha(target)
    checker = build/'source/asic/chip/model/audit_solver_log.py'
    shutil.copy2(ROOT/'model/audit_solver_log.py', checker)
    files[str(checker.relative_to(build))] = sha(checker)
    shutil.copy2(Path(__file__), build/'audit_par_archive.py')
    files['audit_par_archive.py'] = sha(build/'audit_par_archive.py')
    # Detect changes to the original while copying, as well as copied-file drift.
    if sha(source/'inputs.json') != expected_inputs or sha(source/'run/solver_out.txt') != expected_outputs:
        raise ValueError("original inputs/outputs changed during snapshot")
    for name, expected in inputs['files'].items():
        if sha(safe_file(source/'source', name)) != expected:
            raise ValueError("original archived input changed during snapshot: " + name)
        if files['source/'+name] != expected:
            raise ValueError("copied archived input mismatch: " + name)
    if files['original/source.tgz'] != inputs['source_sha256']:
        raise ValueError("copied source archive hash mismatch")
    if files['original/run/solver_hdr.hex'] != inputs['headers_sha256']:
        raise ValueError("copied header hash mismatch")
    if files['original/inputs.json'] != expected_inputs or files['original/run/solver_out.txt'] != expected_outputs:
        raise ValueError("copied inputs/outputs hash mismatch")
    return inputs, files


def verify_files(build, files):
    for name, expected in files.items():
        if sha(safe_file(build, name)) != expected:
            raise ValueError("audit input changed: " + name)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source-build', required=True)
    ap.add_argument('--build', required=True)
    ap.add_argument('--expected-inputs-sha256', required=True)
    ap.add_argument('--expected-output-sha256', required=True)
    ap.add_argument('--audit-timeout', type=int, default=14400)
    a = ap.parse_args()
    for name in [a.source_build,a.build]:
        if not re.fullmatch(r'build/[A-Za-z0-9_-]+',name):
            ap.error('simple build/ paths required; output must be fresh')
    if a.audit_timeout <= 0 or any(not re.fullmatch('[0-9a-f]{64}', h) for h in
                                 [a.expected_inputs_sha256,a.expected_output_sha256]):
        ap.error('positive timeout and SHA256 input/output bindings required')
    source = (ROOT/a.source_build).resolve()
    source.relative_to((ROOT/'build').resolve())
    build = ROOT/a.build
    build.mkdir()
    result = dict(status='FAIL', scope=__doc__.strip(), source_build=a.source_build,
                  simulation_replayed=False, original_runner_result_reconstructed=False,
                  production_release_qualified=False, release_eligible=False)

    def interrupted(signum, frame):
        raise InterruptedError('audit interrupted by signal ' + str(signum))

    handlers = {s:signal.getsignal(s) for s in (signal.SIGTERM,signal.SIGINT)}
    for signum in handlers:
        signal.signal(signum,interrupted)
    try:
        inputs, files = freeze_archive(source,build,a.expected_inputs_sha256,a.expected_output_sha256)
        record = dict(files=files, original_inputs_sha256=a.expected_inputs_sha256,
                      original_output_sha256=a.expected_output_sha256, parameters=inputs['parameters'],
                      audit_timeout_seconds=a.audit_timeout)
        (build/'inputs.json').write_text(json.dumps(record,indent=2)+'\n')
        files = {**files, 'inputs.json':sha(build/'inputs.json')}
        verify_files(build,files)
        checker = build/'source/asic/chip/model/audit_solver_log.py'
        command = [sys.executable,'-E','-B','-u',str(checker),
                   '--run',str(build/'original/run'), '--inputs',str(build/'original/inputs.json'),
                   '--output',str(build/'audit')]
        with (build/'check.log').open('w') as log:
            proc = subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            try:
                code = proc.wait(timeout=a.audit_timeout)
            except BaseException:
                os.killpg(proc.pid,signal.SIGKILL)
                proc.wait()
                raise
        if code:
            raise subprocess.CalledProcessError(code,command)
        summary = json.loads((build/'audit/summary.json').read_text())
        if summary.get('status') != 'PASS':
            raise ValueError('missing successful reference-set audit verdict')
        result['yield'] = accept_audit(summary,inputs['parameters']['NH'])
        verify_files(build,files)
        result.update(status='PASS', archived_inputs_unchanged=True,
                      headers=inputs['parameters']['NH'], inputs_sha256=sha(build/'inputs.json'))
    except (OSError,ValueError,KeyError,subprocess.SubprocessError) as exc:
        result['reason'] = str(exc)
    finally:
        try:
            result['evidence_sha256'] = {str(p.relative_to(build)):sha(p) for p in
                                        sorted(build.rglob('*')) if p.is_file() and p != build/'result.json'}
            (build/'result.json').write_text(json.dumps(result,indent=2)+'\n')
        finally:
            for signum,handler in handlers.items():
                signal.signal(signum,handler)
    print(json.dumps({k:v for k,v in result.items() if k!='evidence_sha256'},indent=2),flush=True)
    return result['status']=='PASS'


if __name__ == '__main__':
    raise SystemExit(0 if main() else 1)
