#!/usr/bin/env python3
"""Simulate four exact archived Caravel tops with digital SRAM models.

Checks GPIO/LA/IRQ behavior and chained UART traffic, and independently audits
solutions in Python and Zig. No analog, timing, or production-process claim.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'pd'))
from run_inputs import check_release_sources, contained, digest, resolve_path


def qualify(manifest_path, build):
    manifest_path = contained(manifest_path, ROOT)
    archive = manifest_path.parent
    manifest_hash = digest(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    archived = {}
    for name, expected in manifest['files'].items():
        path = contained(archive / name, archive)
        if digest(path) != expected:
            raise ValueError('archive hash mismatch: ' + name)
        archived[path] = expected
    config_path = archive / 'config.json'
    if config_path not in archived:
        raise ValueError('unbound configuration')
    config = json.loads(config_path.read_text())
    if config['DESIGN_NAME'] != 'user_project_wrapper':
        raise ValueError('expected exact Caravel top')
    # This harness exercises the fixed zeq200_tc configuration, not arbitrary
    # overridden physical elaborations.
    if config.get('SYNTH_PARAMETERS') or config.get('VERILOG_DEFINES'):
        raise ValueError('unsupported elaboration overrides')
    sources = [resolve_path(p, ROOT, ROOT / 'pd/wrapper') for p in config['VERILOG_FILES']]
    for p in [*sources, archive / 'tb/tb_chain.sv', archive / 'tb/sky130_sram_model.v']:
        if p not in archived:
            raise ValueError('unbound simulation input: ' + str(p))
    check_release_sources(dict(sources=sources, archived=archived))
    build = contained(build, ROOT / 'build')
    build.mkdir()  # never overwrite old evidence
    result = dict(status='FAIL', scope=__doc__.strip(), source_manifest_sha256=manifest_hash)

    def run(command, log, *, env=None, timeout=900):
        with (build / log).open('w') as out:
            subprocess.run(command, cwd=ROOT, env=env, stdout=out, stderr=subprocess.STDOUT,
                           check=True, timeout=timeout)

    try:
        image = subprocess.check_output(['docker', 'image', 'inspect', '--format', '{{.Id}}',
                                         'verilator/verilator:latest'], text=True).strip()
        (build / 'verilator-image-id.txt').write_text(image + '\n')
        shutil.copy2(ROOT.parent.parent / 'zig-out/bin/zcash-miner', build / 'zcash-miner')
        # Copy the independent checker and its imports so later edits cannot
        # change the reference while the compiled simulation is running.
        model = build / 'model'
        model.mkdir()
        for source, sha in archived.items():
            if source.parent == archive / 'model':
                target = model / source.name
                shutil.copyfile(source, target)
                if digest(target) != sha:
                    raise ValueError('checker changed during copy')
        if not (model / 'check_chain.py').is_file():
            raise ValueError('archive lacks independent checker')
        env = dict(os.environ, SHARE_FILTER='0', LANES='1', PAR_CHAIN='1',
                   PAR_CFG='3,128,relaxed', ZCASH_MINER=str(build / 'zcash-miner'))
        inputs = dict(source_manifest_sha256=manifest_hash, image_id=image,
                      verifier_sha256=digest(build / 'zcash-miner'), driver_sha256=digest(__file__),
                      source_sha256={str(p.relative_to(archive)): sha for p, sha in archived.items()},
                      parameters=dict(N=48, K=5, DIV=16, LANES=1, HASH_SPLIT=4, ARCH=1,
                                      PAR_BB=3, PAR_PB=1, PAR_SB=7, PAR_HPB=0, SHARE_FILTER=0),
                      checker_scope='Archived checker validates solutions and requires >=70% of unbounded model solutions on completed attempts; not full-yield qualification')
        (build / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
        shutil.copyfile(__file__, build / 'qualify_wrapper.py')
        run([sys.executable, str(model / 'check_chain.py'), 'prepare', '48', '5', str(build)],
            'prepare.log', env=env)
        def container_path(path):
            return '/work/' + str(path.relative_to(ROOT))
        docker = ['docker', 'run', '--rm', '-u', f'{os.getuid()}:{os.getgid()}',
                  '-e', 'CCACHE_DISABLE=1', '-v', str(ROOT) + ':/work', '-w', '/work']
        command = [*docker, image, '--binary', '--timing', '-j', '2', '-Wall',
                   '--timescale', '1ns/1ps', '-DTEST_CARAVEL',
                   '-Wno-DECLFILENAME', '-Wno-UNUSEDPARAM', '-Wno-UNUSEDSIGNAL',
                   '-Wno-PINCONNECTEMPTY', '-Wno-PROCASSINIT', '-Wno-MULTIDRIVEN', '-Wno-BLKSEQ',
                   # Harness observes asynchronous reset pins in synchronous LA
                   # assertions. This is not a CDC/RDC qualification. Imported
                   # Caravel defines.v has no final newline.
                   '-Wno-SYNCASYNCNET', '-Wno-EOFNEWLINE',
                   '--top-module', 'tb_chain', '--Mdir', container_path(build / 'obj'), '-o', 'simulation']
        command += [f'-G{k}={v}' for k, v in inputs['parameters'].items()]
        command += [container_path(p) for p in sources]
        command += [container_path(archive / 'tb' / name) for name in ('sky130_sram_model.v', 'tb_chain.sv')]
        run(command, 'compile.log')
        run([*docker, '-w', container_path(build), '--entrypoint',
             container_path(build / 'obj/simulation'), image], 'simulation.log')
        run([sys.executable, str(model / 'check_chain.py'), 'check', '48', '5', str(build)],
            'check.log', env=env)
        if 'check_chain: PASS' not in (build / 'check.log').read_text():
            raise ValueError('independent checker emitted no PASS')
        for source, sha in archived.items():
            if digest(source) != sha:
                raise ValueError('archive changed during qualification: ' + str(source))
        if digest(manifest_path) != manifest_hash:
            raise ValueError('manifest changed during qualification')
        result['status'] = 'PASS'
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        result['reason'] = str(exc)
    result['evidence_sha256'] = {str(p.relative_to(build)): digest(p) for p in sorted(build.rglob('*'))
                                 if p.is_file() and 'obj' not in p.relative_to(build).parts
                                 and '__pycache__' not in p.relative_to(build).parts}
    (build / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    (build / 'exit_code').write_text('0\n' if result['status'] == 'PASS' else '1\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'evidence_sha256'}, indent=2))
    return result['status'] == 'PASS'


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source-manifest', required=True, type=Path)
    ap.add_argument('--build', required=True, type=Path)
    args = ap.parse_args()
    raise SystemExit(0 if qualify(args.source_manifest, args.build) else 1)
