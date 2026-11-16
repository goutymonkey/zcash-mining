#!/usr/bin/env python3
"""Run source-bound chip equivalence in LibreLane; SRAMs are matched cut points."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'pd'))
from run_inputs import digest, equivalence_proved, resolve_path, verified_inputs


def execute(command, log, timeout, env=None):
    # Kill the entire proof process group on timeout, including ABC children.
    with log.open('w') as out:
        proc = subprocess.Popen(command, cwd=ROOT, env=env, stdout=out,
                                stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            raise
        if code:
            raise subprocess.CalledProcessError(code, command)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('run', 'source-manifest', 'gate', 'build'):
        ap.add_argument('--' + name, type=Path, required=True)
    ap.add_argument('--timeout', type=int, default=1800)
    ap.add_argument('--engine', choices=('abc', 'eqy'), default='abc')
    ap.add_argument('--eqy-strategy', choices=('pdr', 'smt', 'pdr-smt'), default='pdr')
    ap.add_argument('--eqy-bind-net', action='append', default=[])
    ap.add_argument('--jobs', type=int, default=2, help='concurrent EQY partition jobs')
    ap.add_argument('--partition-timeout', type=int, default=120,
                    help='wall seconds per EQY strategy, including preprocessing')
    args = ap.parse_args()
    if min(args.timeout, args.jobs, args.partition_timeout) <= 0:
        ap.error('timeouts and jobs must be positive')
    if args.engine != 'eqy' and (args.eqy_strategy != 'pdr' or args.eqy_bind_net):
        ap.error('EQY strategy/binding options require --engine eqy')
    info = verified_inputs(args.run, args.source_manifest)
    config = info['resolved']
    if config.get('VERILOG_DEFINES') or config.get('SYNTH_PARAMETERS'):
        raise ValueError('parameter/define overrides require an explicit equivalence adapter')
    top = config['DESIGN_NAME']
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', top):
        raise ValueError('unsupported Verilog top name')
    gate = resolve_path(str(args.gate.resolve()))
    build = args.build.resolve()
    relative = str(build.relative_to(ROOT))
    if not re.fullmatch(r'[A-Za-z0-9_./-]+', relative):
        raise ValueError('build path must use simple shell/Yosys-safe characters')
    libs = config['LIB'].get('*_tt_025C_1v80', [])
    if len(libs) != 1 or config.get('EXTRA_LIBS'):
        raise ValueError('expected one explicit SKY130 TT standard-cell library')
    library = resolve_path(libs[0])
    build.mkdir(parents=True, exist_ok=False)
    (build / 'sources').mkdir()
    copies = []
    for i, path in enumerate(info['sources']):
        copied = build / 'sources' / f'{i:03d}.v'
        copied.write_bytes(path.read_bytes())
        if digest(copied) != info['archived'][path]:
            raise ValueError('source copy differs from manifest')
        copies.append(copied)
    for source, name in [(gate, 'gate.v'), (library, 'cells.lib'),
                         (ROOT / 'pd/tc/sram_blackbox.v', 'sram.v'),
                         (ROOT / 'formal/cec/cec.sh', 'cec.sh'),
                         (ROOT / 'formal/cec/partitioned.py', 'partitioned.py')]:
        shutil.copyfile(source, build / name)
    script = ('read_verilog -sv -DSYNTHESIS ' + json.dumps(str(build / 'sram.v')) + ' '
              + ' '.join(json.dumps(str(p)) for p in copies)
              + f'; hierarchy -check -top {top}; synth -flatten -top {top}; opt_clean -purge; '
              + 'write_verilog -noattr ' + json.dumps(str(build / 'chip_rtl.v')) + '\n')
    (build / 'rtl.ys').write_text(script)
    record = dict(source_manifest_sha256=info['manifest_sha256'],
                  resolved_sha256=digest(info['resolved_path']), gate_sha256=digest(build / 'gate.v'),
                  source_sha256={str(p.relative_to(build)): digest(p) for p in copies},
                  library_sha256=digest(build / 'cells.lib'),
                  yosys=subprocess.check_output(['yosys', '-V'], text=True).strip(),
                  engine=args.engine,
                  eqy_jobs=args.jobs,
                  eqy_partition_timeout_seconds=args.partition_timeout,
                  eqy_strategy=args.eqy_strategy,
                  eqy_bound_nets=sorted(set(args.eqy_bind_net)),
                  timeout_seconds_per_stage=args.timeout)
    (build / 'inputs.json').write_text(json.dumps(record, indent=2) + '\n')
    result = dict(status='FAIL', source_manifest_sha256=record['source_manifest_sha256'],
                  resolved_sha256=record['resolved_sha256'], gate_sha256=record['gate_sha256'],
                  engine=args.engine,
                  scope='Full digital logic; SRAMs are matched cut points; cec.sh zero-initialization model. No physical or SRAM macro equivalence claim.')
    result['release_eligible'] = False
    if args.engine == 'eqy':
        result['scope'] = 'Partitioned EQY safe-replacement equivalence with formal X propagation; arbitrary SRAM read data. No physical or SRAM macro equivalence claim.'
    try:
        execute(['yosys', '-Q', '-T', '-s', str(build / 'rtl.ys')], build / 'rtl_synth.log', args.timeout)
        if args.engine == 'abc':
            env = dict(os.environ, EVERT_SRAM='1', LIBFILE=str(build / 'cells.lib'))
            execute(['bash', str(build / 'cec.sh'), f'{relative}/chip_rtl.v {relative}/sram.v', top,
                     f'{relative}/gate.v {relative}/sram.v', top, relative],
                    build / 'runner.log', args.timeout, env)
            if not equivalence_proved((build / 'proof.txt').read_text()):
                raise ValueError('missing successful equivalence verdict')
        else:
            execute([sys.executable, str(build / 'partitioned.py'), '--build', str(build), '--top', top,
                     '--jobs', str(args.jobs), '--partition-timeout', str(args.partition_timeout),
                     '--strategy', args.eqy_strategy,
                     *[arg for name in sorted(set(args.eqy_bind_net)) for arg in ('--bind-net', name)]],
                    build / 'runner.log', args.timeout)
            if json.loads((build / 'eqy-result.json').read_text())['status'] != 'PASS':
                raise ValueError('missing successful partitioned equivalence verdict')
        result['status'] = 'PASS'
        result['release_eligible'] = args.engine == 'abc'
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError) as exc:
        result['reason'] = str(exc)
    names = ('inputs.json', 'proof.txt', 'cec.log', 'chip_rtl.v', 'gate.v', 'cells.lib',
             'sram.v', 'cec.sh', 'rtl.ys', 'rtl_synth.log', 'runner.log',
             'partitioned.py', 'eqy-result.json')
    result['evidence_sha256'] = {n: digest(build / n) for n in names if (build / n).is_file()}
    (build / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Source-bound chip equivalence: ' + result['status'], flush=True)
    raise SystemExit(0 if result['status'] == 'PASS' else 1)


if __name__ == '__main__':
    main()
