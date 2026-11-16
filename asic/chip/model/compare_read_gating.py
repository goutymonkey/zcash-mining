#!/usr/bin/env python3
"""Compare source-frozen read-gating runs, refusing confounded A/B evidence."""
import argparse
import hashlib
import json
from pathlib import Path

from compare_rtl import compare, compare_activity
from equihash_ref import Params

RTL = 'asic/chip/rtl/zeq_eh_par.v'
GATED = '(es == E_WK) && !hold_c && vb;'
UNGATED = '(es == E_WK) && !hold_c;'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked_path(root, name):
    path = (root / name).resolve()
    if root.resolve() not in path.parents:
        raise ValueError('evidence path escapes archive: ' + name)
    return path


def verify_archive(root):
    inputs = json.loads((root/'inputs.json').read_text())
    result = json.loads((root/'result.json').read_text())
    if result.get('status') != 'PASS' or result.get('archived_inputs_unchanged') is not True:
        raise ValueError('run did not pass source-frozen qualification')
    for name, expected in inputs['files'].items():
        if sha(checked_path(root/'source', name)) != expected:
            raise ValueError('source hash mismatch: '+name)
    for name, expected in result['evidence_sha256'].items():
        if sha(checked_path(root, name)) != expected:
            raise ValueError('evidence hash mismatch: '+name)
    required = {'inputs.json', 'source.tgz', 'run/solver_hdr.hex',
                'run/solver_out.txt', 'run/memory_accesses.csv', 'run/audit/summary.json'}
    if not required <= result['evidence_sha256'].keys():
        raise ValueError('qualification does not bind all required evidence')
    if sha(root/'source.tgz') != inputs['source_sha256']:
        raise ValueError('source archive hash mismatch')
    if sha(root/'run/solver_hdr.hex') != inputs['headers_sha256']:
        raise ValueError('header hash mismatch')
    if sha(root/'obj/simulation') != result['simulation_executable_sha256']:
        raise ValueError('executable hash mismatch')
    return inputs, result


def verify_pair(baseline, candidate):
    a, ar = verify_archive(baseline)
    b, br = verify_archive(candidate)
    for key in ('parameters', 'seed', 'image_id', 'python_runtime',
                'headers_sha256', 'compiler_options'):
        if a[key] != b[key]:
            raise ValueError('comparison configuration differs: '+key)
    if b['parameters'].get('GROUP_REPLAY') != 0:
        raise ValueError('read-gating comparison requires replay disabled')
    if a['files'].keys() != b['files'].keys():
        raise ValueError('archived source sets differ')
    changed = [p for p in a['files'] if a['files'][p] != b['files'][p]]
    if changed != [RTL]:
        raise ValueError('comparison must change only solver RTL')
    before = (baseline/'source'/RTL).read_text()
    after = (candidate/'source'/RTL).read_text()
    declaration = '            wire [SB-1:0]   oq;\n'
    anchor = '            wire            hold_c;\n'
    normalized_before = before
    normalized_after = after
    # The only permitted nonfunctional difference is this exact declaration
    # relocation, required by Yosys before kra uses oq's width.
    for text in (before, after):
        if text.count(declaration) > 1:
            raise ValueError('duplicate order declaration')
    if before.count(declaration) == after.count(declaration) == 1:
        if before.count(anchor) != 1 or after.count(anchor) != 1:
            raise ValueError('order declaration scope changed')
        def hoist(text):
            return text.replace(declaration, '').replace(anchor, anchor+declaration)
        # Accept either original placement or the one specific hoisted form.
        expected_after = hoist(before.replace(UNGATED, GATED))
        if after != before.replace(UNGATED, GATED) and after != expected_after:
            raise ValueError('solver changes exceed gate and exact declaration relocation')
        normalized_before, normalized_after = hoist(before), hoist(after)
    if after.count(GATED) != 1 or normalized_after.replace(GATED, UNGATED) != normalized_before:
        raise ValueError('solver changes exceed the read-enable gate')
    for inputs, result in ((a, ar), (b, br)):
        y = result['yield']
        if (result['headers'] != inputs['parameters']['NH'] or
                y['reference_solutions'] <= 0 or
                y['solutions'] != y['reference_solutions'] or
                y['missing_reference_solutions'] != 0):
            raise ValueError('incomplete independent reference retention')
    return b['parameters']


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('baseline', type=Path)
    ap.add_argument('candidate', type=Path)
    ap.add_argument('--output', type=Path, required=True)
    a = ap.parse_args()
    if a.output.exists():
        ap.error('output exists; use a fresh evidence path')
    params = verify_pair(a.baseline, a.candidate)
    miner = a.candidate/'source/zig-out/bin/zcash-miner'
    result = compare(a.baseline/'run', a.candidate/'run',
                     Params(params['N'], params['K']), miner)
    paths = [d/'run/memory_accesses.csv' for d in (a.baseline, a.candidate)]
    result['activity'] = compare_activity(*paths,
        sum(c['baseline_solutions'] for c in result['attempts']), result['verified_solutions'])
    result['parameters'] = params
    result['controlled_source_change'] = 'The legacy walker read-enable gains && vb; the oq wire declaration may be hoisted before its first use.'
    result['qualification_inputs_verified'] = True
    # This optimization must also preserve the exact schedule and writes.
    if (any(c['baseline_cycles'] != c['candidate_cycles'] or
            c['baseline_drops'] != c['candidate_drops'] for c in result['attempts']) or
            result['activity']['baseline']['write_bits'] != result['activity']['candidate']['write_bits']):
        result['status'] = 'FAIL'
    evidence = [Path(__file__), *paths]
    for root in (a.baseline, a.candidate):
        evidence += [root/'inputs.json', root/'result.json']
    result['evidence_sha256'].update({str(p):sha(p) for p in evidence})
    a.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('evidence_sha256','attempts')},indent=2))
    return result['status'] == 'PASS'


if __name__ == '__main__':
    raise SystemExit(0 if main() else 1)
