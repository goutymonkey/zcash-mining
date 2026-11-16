#!/usr/bin/env python3
"""Resume complete archived partition obligations without changing their circuits.

The inventory counts distinct obligations, not cached strategy messages.
Individual passes and scoped compositions never create a global EQY verdict.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

SOURCE_BYTES = Path(__file__).read_bytes()


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            h.update(chunk)
    return h.hexdigest()


def bound(base, name, evidence):
    path = base / name
    if base.resolve() not in path.resolve().parents or sha(path) != evidence.get(name):
        raise ValueError('unbound or changed evidence: ' + name)
    return path


def partition_names(text):
    names = []
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 2 or fields[0] != 'zeq_eh_par' or not re.fullmatch(r'[A-Za-z0-9_.-]+', fields[1]):
            raise ValueError('invalid partition list')
        names.append(fields[1])
    if not names or len(names) != len(set(names)):
        raise ValueError('empty or duplicate partition list')
    return names


def terminal_status(status, log, returncode):
    words = status.split()
    if len(words) != 3 or not words[1].isdigit() or int(words[1]) != returncode:
        return 'ERROR'
    state = words[0]
    if state not in ('PASS', 'FAIL', 'UNKNOWN', 'TIMEOUT'):
        return 'ERROR'
    if f'DONE ({state}, rc={returncode})' not in log:
        return 'ERROR'
    if state == 'PASS' and (returncode != 0 or 'successful proof by k-induction' not in log):
        return 'ERROR'
    return state


def is_prove_config(config):
    sections = re.findall(r'(?ms)^\[options\]\s*\n(.*?)(?=^\[|\Z)', config)
    if len(sections) != 1:
        return False
    modes = [line.split() for line in sections[0].splitlines()
             if line.strip().startswith('mode ')]
    return modes == [['mode', 'prove']]


def reuse_coverage(prior, origin_hash, partitions):
    """Reuse only completed, source-bound proofs from an interrupted sweep."""
    prior = Path(prior)
    report_hash = sha(prior / 'result.json')
    report = json.loads((prior / 'result.json').read_text())
    if sha(prior / 'plan.json') != report['plan_sha256']:
        raise ValueError('prior coverage plan changed')
    plan = json.loads((prior / 'plan.json').read_text())
    if plan['origin_result_sha256'] != origin_hash or plan['partitions'] != partitions:
        raise ValueError('prior coverage has a different origin or obligations')
    reused = {}
    for name, case in report['jobs'].items():
        if case['status'] != 'PASS':
            continue
        if name not in partitions:
            raise ValueError('prior coverage claims an unknown partition')
        path = bound(prior, case['artifact'], {case['artifact']: case['sha256']})
        result = json.loads(path.read_text())
        expected = {'/origin/eqy/partitions/' + name + '.' + ext: partitions[name]['files'][ext]
                    for ext in ('sv', 'il')}
        if result['partition'] != name or result['input_sha256'] != expected or result['status'] != 'PASS':
            raise ValueError('prior proof input or identity differs')
        evidence = result['evidence_sha256']
        for rel in evidence:
            bound(path.parent, rel, evidence)
        config = bound(path.parent, 'proof.sby', evidence).read_text()
        state = bound(path.parent, 'proof/status', evidence).read_text()
        log = bound(path.parent, 'proof/logfile.txt', evidence).read_text()
        settings = re.fullmatch(r'\[options\]\nmode prove\ndepth ([1-9][0-9]*)\ntimeout ([1-9][0-9]*)\n.*', config, re.S)
        if not settings or config != proof_config(name, int(settings[2]), int(settings[1])):
            raise ValueError('prior proof configuration changed the obligation')
        for ext in ('sv', 'il'):
            copied = bound(path.parent, 'proof/src/' + name + '.' + ext, evidence)
            if sha(copied) != partitions[name]['files'][ext]:
                raise ValueError('prior proof used different circuit source')
        if not is_prove_config(config) or terminal_status(state, log, result['exit_code']) != 'PASS':
            raise ValueError('prior proof has no complete inductive pass')
        reused[name] = dict(kind='continued_partition', artifact=str(path.resolve()), sha256=sha(path))
    if sha(prior / 'result.json') != report_hash:
        raise ValueError('prior coverage still changing')
    return reused


def prepare(origin, review_path, build, prior_coverage=()):
    origin, review_path, build = Path(origin), Path(review_path), Path(build)
    if build.exists():
        raise ValueError('fresh build directory required')
    old = json.loads((origin / 'result.json').read_text())
    origin_hash = sha(origin / 'result.json')
    evidence = old['evidence_sha256']
    names = partition_names(bound(origin, 'eqy/partition.list', evidence).read_text())
    partitions, reused = {}, {}
    for name in names:
        files = {}
        for ext in ('json', 'il', 'sv'):
            rel = 'eqy/partitions/' + name + '.' + ext
            files[ext] = sha(bound(origin, rel, evidence))
        data = json.loads((origin / ('eqy/partitions/' + name + '.json')).read_text())['partition']
        if data['name'] != name or not data['outbits']:
            raise ValueError('partition identity or outputs missing')
        partitions[name] = dict(files=files, outputs=data['outbits'])
        for status in sorted((origin / 'eqy/strategies' / name).glob('*/*/status')):
            words = status.read_text().split()
            if not words or words[0] != 'PASS':
                continue
            # Bind the actual terminal proof and every retained strategy file;
            # cached PASS text in a sibling strategy is not a new proof.
            strategy = status.parent.parent
            prefix = str(strategy.relative_to(origin)) + '/'
            for rel in evidence:
                if rel.startswith(prefix):
                    bound(origin, rel, evidence)
            log = status.parent / 'logfile.txt'
            rel = str(status.relative_to(origin))
            bound(origin, rel, evidence)
            bound(origin, str(log.relative_to(origin)), evidence)
            text = log.read_text()
            config_path = strategy / (name + '.sby')
            bound(origin, str(config_path.relative_to(origin)), evidence)
            if (len(words) != 3 or words[1] != '0' or 'DONE (PASS, rc=0)' not in text
                    or not is_prove_config(config_path.read_text())):
                raise ValueError('invalid archived proof pass')
            reused[name] = dict(kind='original_partition', artifact=rel, sha256=sha(status))
            break
    review_hash = sha(review_path)
    review = json.loads(review_path.read_text())
    chip = review_path.parent.parent
    for case in review['cases'].values():
        if case['status'] != 'PASS' or case.get('mutation') is not None:
            continue
        result_path = bound(chip, case['artifact'], review['evidence_sha256'])
        result = json.loads(result_path.read_text())
        if result['status'] != 'PASS' or result['exit_code'] != 0 or result.get('mutation') is not None:
            raise ValueError('composition verdict mismatch')
        for rel, digest in result['evidence_sha256'].items():
            bound(result_path.parent, rel, result['evidence_sha256'])
        composition_path = result_path.parent / 'composition.json'
        if sha(composition_path) != result['composition_sha256']:
            raise ValueError('composition manifest mismatch')
        composition = json.loads(composition_path.read_text())
        if composition['origin_result_sha256'] != origin_hash:
            raise ValueError('composition has a different origin')
        if case['partitions'] != result['partitions'] or result['partitions'] != composition['partitions']:
            raise ValueError('composition partition claims differ')
        for name in result['partitions']:
            if name not in partitions or not set(partitions[name]['outputs']) <= set(composition['outputs']):
                raise ValueError('composition omitted original outputs')
            for ext in ('json', 'il'):
                rel = 'eqy/partitions/' + name + '.' + ext
                if composition['original_partition_sha256'].get(rel) != partitions[name]['files'][ext]:
                    raise ValueError('composition changed partition origin')
            reused[name] = dict(kind='scoped_composition', artifact=str(result_path), sha256=sha(result_path))
    for prior in prior_coverage:
        reused.update(reuse_coverage(prior, origin_hash, partitions))
    pending = sorted(set(names) - set(reused), key=lambda n: (origin / ('eqy/partitions/' + n + '.il')).stat().st_size)
    record = dict(scope=__doc__.strip(), release_eligible=False, full_design_equivalence=False,
                  origin=str(origin.resolve()), origin_result_sha256=origin_hash,
                  composition_review_sha256=review_hash, required=names,
                  partitions=partitions, reused=reused, pending=pending)
    if sha(origin / 'result.json') != origin_hash:
        raise ValueError('origin result changed while preparing')
    if sha(review_path) != review_hash:
        raise ValueError('composition review changed while preparing')
    if Path(__file__).read_bytes() != SOURCE_BYTES:
        raise ValueError('runner changed while preparing')
    build.mkdir(parents=True)
    (build / 'cover_partitions.py').write_bytes(SOURCE_BYTES)
    record['runner_sha256'] = sha(build / 'cover_partitions.py')
    (build / 'plan.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


def proof_config(name, timeout, depth):
    return f'''[options]
mode prove
depth {depth}
timeout {timeout}
[engines]
smtbmc bitwuzla
[script]
verilog_defaults -add -D CHECK_OUTPUTS
read_verilog -sv {name}.sv
read_rtlil {name}.il
hierarchy -top miter
proc
async2sync
formalff -clk2ff -ff2anyinit gate.{name}
setundef -anyseq gate.{name}
flatten -wb
dffunmap
opt_expr -keepdc -undriven
opt_clean
xprop -formal -split-ports -assume-def-inputs miter
[files]
{name}.sv /origin/eqy/partitions/{name}.sv
{name}.il /origin/eqy/partitions/{name}.il
'''


def prove(build, name, definition, timeout, depth):
    if shutil.disk_usage(build).free < 2 * 1024**3:
        return dict(status='BLOCKED_DISK', partition=name)
    job = build / 'jobs' / name
    job.mkdir(parents=True, exist_ok=False)
    sources = {}
    for ext in ('sv', 'il'):
        src = Path('/origin/eqy/partitions') / (name + '.' + ext)
        if sha(src) != definition['files'][ext]:
            raise ValueError('partition input changed')
        sources[str(src)] = definition['files'][ext]
    config = proof_config(name, timeout, depth)
    (job / 'proof.sby').write_text(config)
    start = time.monotonic()
    with (job / 'launcher.log').open('w') as stream:
        proc = subprocess.Popen(['sby', 'proof.sby'], cwd=job, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = proc.wait(timeout=timeout + 60)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                code = proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                code = proc.wait()
    state = 'ERROR'
    if (job / 'proof/status').exists() and (job / 'proof/logfile.txt').exists():
        state = terminal_status((job / 'proof/status').read_text(), (job / 'proof/logfile.txt').read_text(), code)
    if any(sha(Path(path)) != digest for path, digest in sources.items()):
        raise ValueError('partition changed during proof')
    result = dict(status=state, partition=name, exit_code=code, elapsed_seconds=time.monotonic()-start,
                  input_sha256=sources, release_eligible=False, full_design_equivalence=False,
                  evidence_sha256={str(p.relative_to(job)): sha(p) for p in job.rglob('*') if p.is_file()})
    (job / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def execute(build, jobs, timeout, depth):
    plan = json.loads((build / 'plan.json').read_text())
    if sha(Path(__file__)) != plan['runner_sha256']:
        raise ValueError('archived runner changed')
    records = {}
    def save():
        passed = sum(r['status'] == 'PASS' for r in records.values())
        report = dict(status='PARTIAL', release_eligible=False, full_design_equivalence=False,
                      required_partitions=len(plan['required']), reused_partitions=len(plan['reused']),
                      new_passed_partitions=passed, covered_partitions=len(plan['reused'])+passed,
                      remaining_partitions=len(plan['pending'])-passed,
                      plan_sha256=sha(build/'plan.json'), jobs=records)
        (build / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = {pool.submit(prove, build, name, plan['partitions'][name], timeout, depth): name for name in plan['pending']}
        for future in as_completed(futures):
            name = futures[future]
            try:
                result = future.result()
                records[name] = {k: result[k] for k in ('status', 'partition')}
                path = build / 'jobs' / name / 'result.json'
                if path.exists():
                    records[name].update(artifact=str(path.relative_to(build)), sha256=sha(path))
            except Exception as exc:
                records[name] = dict(status='ERROR', partition=name, reason=str(exc))
            if len(records) % 25 == 0 or records[name]['status'] != 'PASS':
                save()
                print(len(records), '/', len(plan['pending']), name, records[name]['status'], flush=True)
    save()
    print('Finished all scheduled obligations.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', required=True, type=Path)
    parser.add_argument('--origin', type=Path)
    parser.add_argument('--composition-review', type=Path)
    parser.add_argument('--prior-coverage', type=Path, action='append', default=[])
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--timeout', type=int, default=60)
    parser.add_argument('--depth', type=int, default=3)
    args = parser.parse_args()
    if min(args.jobs, args.timeout, args.depth) < 1 or args.jobs > 4:
        parser.error('positive depth/timeout and 1..4 jobs required')
    if args.execute:
        execute(args.build, args.jobs, args.timeout, args.depth)
    else:
        if args.origin is None or args.composition_review is None:
            parser.error('origin and composition review required')
        record = prepare(args.origin, args.composition_review, args.build, args.prior_coverage)
        print('Required:', len(record['required']), 'reused:', len(record['reused']), 'pending:', len(record['pending']))
