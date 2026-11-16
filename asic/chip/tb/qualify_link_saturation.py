#!/usr/bin/env python3
"""Stress four real chain links with continuous synthetic lane traffic."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build', required=True)
    ap.add_argument('--duration-ns', type=int, default=500_000_000)
    ap.add_argument('--n', type=int, choices=(48, 200), default=48)
    ap.add_argument('--link-source', type=Path, default=ROOT / 'rtl/zeq_link.v')
    a = ap.parse_args()
    if not re.fullmatch('build/[a-zA-Z0-9_-]+', a.build) or a.duration_ns <= 0:
        ap.error('use a fresh simple build/ path and positive duration')
    build = ROOT / a.build
    build.mkdir()
    files = ['rtl/' + name + '.v' for name in
             ('zeq_mbist', 'zeq_ram', 'zeq_fifo', 'zeq_uart', 'zeq_link')]
    files += ['tb/tb_link_saturation.sv', 'tb/qualify_link_saturation.py', 'toolchain.json']
    for name in files:
        dst = build / 'source' / name
        dst.parent.mkdir(parents=True, exist_ok=True)
        source = a.link_source if name == 'rtl/zeq_link.v' else ROOT / name
        dst.write_bytes(source.read_bytes())
    image_ref = json.loads((build / 'source/toolchain.json').read_text())['verilator']['image']
    image = subprocess.check_output(['docker', 'image', 'inspect', '--format', '{{.Id}}',
                                     image_ref], text=True).strip()
    k = 9 if a.n == 200 else 5
    inputs = dict(image_id=image, image_ref=image_ref, duration_ns=a.duration_ns, n=a.n, k=k,
                  source_sha256={name: sha(build / 'source' / name) for name in files},
                  scope=f'Four links, N{a.n}K{k}/DIV16, synthetic continuously available results. '
                        'No Equihash, solver, physical SRAM, or unbounded liveness proof.')
    (build / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
    results = []
    for skew in (0, 1):
        case = build / f'skew-{skew}'
        case.mkdir()
        name = f'zeq-{build.name}-skew-{skew}'
        docker = ['docker', 'run', '--rm', '--name', name, '--network=none', '--cpus=2', '--memory=4g', '--pids-limit=256', '-u', f'{os.getuid()}:{os.getgid()}',
                  '-e', 'CCACHE_DISABLE=1', '-v', str(ROOT) + ':/work', '-w', '/work']
        local = lambda p: '/work/' + str(p.relative_to(ROOT))
        command = [*docker, image, '--binary', '--timing', '-j', '2', '-Wall',
                   '--timescale', '1ns/1ps', '-Wno-DECLFILENAME', '-Wno-UNUSEDPARAM',
                   '-Wno-UNUSEDSIGNAL', '-Wno-PINCONNECTEMPTY', '-Wno-PROCASSINIT', '-Wno-BLKSEQ',
                   '--top-module', 'tb_link_saturation', f'-GSKEW={skew}',
                   f'-GDURATION_NS={a.duration_ns}', f'-GN={a.n}', f'-GK={k}',
                   '--Mdir', local(case / 'obj'), '-o', 'simulation']
        command += [local(build / 'source' / n) for n in files if n.endswith(('.v', '.sv'))]
        result = dict(skew=skew, clock_periods_ns=[10, 10, 10, 10] if skew == 0 else [10.06, 10.04, 10.02, 10], status='FAIL')
        try:
            with (case / 'compile.log').open('w') as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
            with (case / 'simulation.log').open('w') as log:
                subprocess.run([*docker, '--entrypoint', local(case / 'obj/simulation'), image],
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
            if 'link saturation PASS' not in (case / 'simulation.log').read_text():
                raise ValueError('no simulation PASS')
            result['status'] = 'PASS'
        except subprocess.TimeoutExpired as exc:
            # Stop our named container too; killing only the Docker client
            # would leave a simulator running after a recorded timeout.
            subprocess.run(['docker', 'stop', '--time', '5', name], capture_output=True, timeout=20)
            result['reason'] = str(exc)
        except (OSError, ValueError, subprocess.CalledProcessError) as exc:
            result['reason'] = str(exc)
        result['evidence_sha256'] = {p.name: sha(p) for p in case.glob('*.log')}
        results.append(result)
        (build / 'result.json').write_text(json.dumps(dict(
            status='RUNNING', inputs_sha256=sha(build / 'inputs.json'), cases=results), indent=2) + '\n')
    unchanged = all(sha(build / 'source' / n) == h for n, h in inputs['source_sha256'].items())
    result = dict(status='PASS' if unchanged and all(r['status'] == 'PASS' for r in results) else 'FAIL',
                  inputs_sha256=sha(build / 'inputs.json'), source_unchanged=unchanged, cases=results)
    (build / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return result['status'] == 'PASS'


if __name__ == '__main__':
    raise SystemExit(0 if main() else 1)
