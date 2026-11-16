#!/usr/bin/env python3
"""Compare qualified architecture variants on one identical complete corpus."""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'model'))
from compare_read_gating import sha, verify_archive
from compare_rtl import compare, read_activity
from equihash_ref import Params
from qualify_par import RTL, accept_audit

VARIABLES = ('PB', 'HPB', 'HASH_SPLIT', 'SLOTS', 'BUCKET0_SLOTS', 'SB', 'GMAX', 'GROUP_REPLAY', 'STAGED_NETWORK')
RUNNERS = {'asic/chip/tb/qualify_core_control.py', 'asic/chip/tb/qualify_par.py'}
COMPARISON_MODELS = ('compare_rtl.py', 'yield_study.py', 'equihash_ref.py', 'equihash_np.py', 'par_model.py')
REQUIRED_SOURCES = {'asic/chip/rtl/' + name + '.v' for name in RTL} | {
    'asic/chip/tb/tb_par.sv', 'zig-out/bin/zcash-miner',
    'asic/chip/model/par_qualification.py', 'asic/chip/model/yield_study.py',
    'asic/chip/model/equihash_ref.py', 'asic/chip/model/equihash_np.py'}


def verify_pair(baseline, candidate, varied):
    declared = set(varied)
    if not declared or not declared <= set(VARIABLES):
        raise ValueError('declare supported architecture parameters')
    a, ar = verify_archive(baseline)
    b, br = verify_archive(candidate)
    for key in ('seed', 'image_id', 'python_runtime', 'headers_sha256', 'compiler_options'):
        if a[key] != b[key]:
            raise ValueError('paired configuration differs: ' + key)
    changed = {key for key in a['parameters'].keys() | b['parameters'].keys()
               if a['parameters'].get(key) != b['parameters'].get(key)}
    if changed != declared:
        raise ValueError('parameter changes differ from declared experiment')
    if a['files'].keys() != b['files'].keys() or not REQUIRED_SOURCES <= a['files'].keys():
        raise ValueError('paired source set differs or omits required sources')
    source_changes = {name for name in a['files'] if a['files'][name] != b['files'][name]}
    if source_changes - RUNNERS:
        raise ValueError('paired RTL, testbench, model or verifier differs')
    for root, inputs, result in ((baseline, a, ar), (candidate, b, br)):
        headers = inputs['parameters']['NH']
        summary = json.loads((root/'run/audit/summary.json').read_text())
        retention = accept_audit(summary, headers)
        if result['headers'] != headers or result['yield'] != retention:
            raise ValueError('qualification verdict disagrees with complete reference audit')
    return a, b, sorted(source_changes)


def verify_comparison_models(inputs, model_dir):
    # The paired verifier executes local Python helpers. Bind them to the
    # exact versions archived by both runs, not merely to each other.
    for name in COMPARISON_MODELS:
        if inputs['files'].get('asic/chip/model/' + name) != sha(model_dir/name):
            raise ValueError('comparison model differs from frozen qualification: ' + name)


def activity_summary(path, engines, solutions):
    rows = read_activity(path)
    if {e for e, _ in rows} != set(range(engines)) or solutions <= 0:
        raise ValueError('activity engine count or verified solution count differs')
    reads = sum(width * read for width, read, _ in rows.values())
    writes = sum(width * write for width, _, write in rows.values())
    return dict(engines=engines, read_bits=reads, write_bits=writes,
                accessed_bytes_per_solution=(reads+writes)/8/solutions)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('baseline', type=Path)
    ap.add_argument('candidate', type=Path)
    ap.add_argument('--vary', action='append', choices=VARIABLES, required=True)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    if args.output.exists():
        ap.error('use a fresh output path')
    old, new, runner_changes = verify_pair(args.baseline, args.candidate, args.vary)
    model_dir = Path(__file__).resolve().parents[1]/'model'
    verify_comparison_models(new, model_dir)
    params = new['parameters']
    miner = args.candidate/'source/zig-out/bin/zcash-miner'
    result = compare(args.baseline/'run', args.candidate/'run', Params(params['N'], params['K']), miner)
    expected = params['NH']
    if result['headers'] != expected or result['verified_solutions'] <= 0:
        raise ValueError('paired comparison did not cover the complete meaningful corpus')
    paths = [root/'run/memory_accesses.csv' for root in (args.baseline, args.candidate)]
    result['activity'] = {
        'baseline': activity_summary(paths[0], 1 << old['parameters']['PB'], sum(c['baseline_solutions'] for c in result['attempts'])),
        'candidate': activity_summary(paths[1], 1 << params['PB'], result['verified_solutions']),
        'scope': 'Logical SRAM payload activity only. Different engine counts are summed across their complete profiles; no energy, power, physical area or clock-frequency claim.'}
    result['parameters'] = {'baseline': old['parameters'], 'candidate': params}
    result['declared_parameter_changes'] = sorted(set(args.vary))
    result['changed_runner_sources'] = runner_changes
    result['qualification_inputs_verified'] = True
    result['production_architecture_selected'] = False
    evidence = [*(model_dir/name for name in COMPARISON_MODELS), Path(__file__), Path(__file__).with_name('qualify_par.py'),
                Path(__file__).resolve().parents[1]/'model/compare_read_gating.py', *paths]
    for root in (args.baseline, args.candidate):
        evidence.extend(root/name for name in ('inputs.json', 'result.json'))
    result['evidence_sha256'].update({str(path): sha(path) for path in evidence})
    # Recheck source-frozen evidence after the independently verified comparison.
    verify_pair(args.baseline, args.candidate, args.vary)
    verify_comparison_models(new, model_dir)
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k:result[k] for k in ('status','headers','verified_solutions','baseline_cycles','candidate_cycles','activity')}, indent=2))
    return result['status'] == 'PASS'


if __name__ == '__main__':
    raise SystemExit(0 if main() else 1)
