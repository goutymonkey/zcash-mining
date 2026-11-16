#!/usr/bin/env python3
"""Stage a source-bound SKY130 Caravel bundle only after signoff and LEC.

No fabrication submission is performed. Foundry acceptance, manufacturing
test and production-process qualification are outside this demonstrator flow.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile

from run_inputs import ROOT, check_release_sources, contained, digest, equivalence_proved, verified_inputs
from signoff_gate import validate
from check_macro_timing import validate as validate_macros


def plan_bundle(run, source_manifest, policy, lec, root=ROOT):
    inputs = verified_inputs(run, source_manifest, root)
    defect_policy, defect_policy_sha256 = check_release_sources(inputs, root)
    run = inputs['run']
    errors = validate(run, policy, root)
    if errors:
        raise ValueError('physical signoff rejected: ' + '; '.join(errors[:8])
                         + f' ({len(errors)} errors)')
    design = inputs['resolved']['DESIGN_NAME']
    if design != 'user_project_wrapper':
        raise ValueError('Caravel bundle requires user_project_wrapper')
    corners = json.loads(Path(policy).read_text())['required_corners']
    final = run / 'final'
    gate = final / 'nl' / (design + '.nl.v')
    lec = Path(lec).resolve()
    result = json.loads((lec / 'result.json').read_text())
    if result.get('release_eligible') is not True or result.get('engine') != 'abc':
        raise ValueError('LEC engine is not yet qualified for release packaging')
    if (result.get('status') != 'PASS'
            or result.get('source_manifest_sha256') != inputs['manifest_sha256']
            or result.get('resolved_sha256') != digest(inputs['resolved_path'])
            or result.get('gate_sha256') != digest(gate)):
        raise ValueError('LEC does not qualify this exact source/configuration/final netlist')
    for name in ('inputs.json', 'proof.txt', 'cec.log', 'chip_rtl.v', 'gate.v', 'cells.lib', 'sram.v', 'cec.sh'):
        if result.get('evidence_sha256', {}).get(name) != digest(lec / name):
            raise ValueError('LEC artifact hash mismatch: ' + name)
    if not equivalence_proved((lec / 'proof.txt').read_text()):
        raise ValueError('LEC has no successful proof verdict')
    if digest(lec / 'gate.v') != digest(gate):
        raise ValueError('LEC gate copy differs from final netlist')
    proof_inputs = json.loads((lec / 'inputs.json').read_text())
    if proof_inputs.get('engine') != result['engine']:
        raise ValueError('LEC input/result mismatch: engine')
    for key in ('source_manifest_sha256', 'resolved_sha256', 'gate_sha256'):
        if proof_inputs.get(key) != result.get(key):
            raise ValueError('LEC input/result mismatch: ' + key)
    if proof_inputs.get('library_sha256') != digest(lec / 'cells.lib'):
        raise ValueError('LEC library does not match input record')
    expected_sources = {'sources/%03d.v' % i: inputs['archived'][p]
                        for i, p in enumerate(inputs['sources'])}
    if proof_inputs.get('source_sha256') != expected_sources:
        raise ValueError('LEC source copies do not match run RTL')
    for name, expected in expected_sources.items():
        if digest(lec / name) != expected:
            raise ValueError('LEC source copy changed: ' + name)
    entries = {}

    def add(source, destination, expected=None):
        source = Path(source)
        if not source.is_file() or source.stat().st_size == 0:
            raise ValueError('missing/empty release artifact: ' + str(source))
        if destination in entries:
            raise ValueError('duplicate release destination: ' + destination)
        actual = digest(source)
        if expected is not None and expected != actual:
            raise ValueError('artifact changed during planning: ' + str(source))
        entries[destination] = dict(source=source, sha256=actual)

    for fmt, dest, extension in [('gds', 'gds', 'gds'), ('lef', 'lef', 'lef'),
                                 ('def', 'def', 'def'), ('sdc', 'sdc', 'sdc')]:
        add(final / fmt / (design + '.' + extension), dest + '/' + design + '.' + extension)
    add(final / 'pnl' / (design + '.pnl.v'), 'verilog/gl/' + design + '.v')
    add(gate, 'evidence/final.nl.v')
    # LibreLane exports SPEF under min/, nom/, max/, not min_*/etc.
    for rc in sorted({corner.split('_', 1)[0] for corner in corners}):
        if rc not in ('min', 'nom', 'max'):
            raise ValueError('unsupported RC corner: ' + rc)
        add(final / 'spef' / rc / (design + '.' + rc + '.spef'),
            'spef/multicorner/' + design + '.' + rc + '.spef')
    for corner in corners:
        add(final / 'sdf' / corner / (design + '__' + corner + '.sdf'),
            'sdf/multicorner/' + design + '__' + corner + '.sdf')
    for path, expected in inputs['archived'].items():
        add(path, 'evidence/source/' + str(path.relative_to(inputs['manifest'].parent)), expected)
    own_rtl = []
    for path in inputs['sources']:
        if path.name in ('defines.v', 'user_project_wrapper.v'):
            add(path, 'verilog/rtl/' + path.name, inputs['archived'][path])
        else:
            own_rtl.append(path)
    if not own_rtl or any('verilog/rtl/' + n not in entries for n in ('defines.v', 'user_project_wrapper.v')):
        raise ValueError('missing archived Caravel wrapper or chip RTL')
    for name, path in [('resolved.json', inputs['resolved_path']),
                       ('source-manifest.json', inputs['manifest']),
                       ('signoff-policy.json', policy), ('metrics.json', final / 'metrics.json')]:
        add(path, 'evidence/' + name)
    add(defect_policy, 'evidence/blocked_sources.json', defect_policy_sha256)
    macro_errors, macro_views = validate_macros(run, json.loads(Path(policy).read_text()), root)
    if macro_errors:
        raise ValueError('macro timing qualification changed during packaging: ' + '; '.join(macro_errors))
    for index, (path, sha) in enumerate(sorted(macro_views.items())):
        add(path, f'evidence/macro-libraries/{index:03d}-' + path.name, sha)
    step = max(run.glob('*-openroad-stapostpnr'), key=lambda p: int(p.name.split('-')[0]))
    add(step / 'config.json', 'evidence/sta/config.json')
    for corner in corners:
        for name in ('checks.rpt', 'ws.max.rpt', 'ws.min.rpt'):
            add(step / corner / name, 'evidence/sta/' + corner + '/' + name)
    for name in ('result.json', *result['evidence_sha256']):
        # Result entries are file basenames, never arbitrary filesystem paths.
        if Path(name).name != name or name in ('.', '..'):
            raise ValueError('invalid LEC evidence filename')
        add(lec / name, 'evidence/lec/' + name)
    for name, expected in expected_sources.items():
        add(lec / name, 'evidence/lec/' + name, expected)
    return inputs, entries, own_rtl


def stage_bundle(run, source_manifest, policy, lec, output, root=ROOT):
    output = Path(output).resolve()
    if output.exists():
        raise ValueError('output already exists; use a new bundle directory')
    inputs, entries, own_rtl = plan_bundle(run, source_manifest, policy, lec, root)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.zeq-release-', dir=output.parent) as tmp:
        stage = Path(tmp) / 'bundle'
        stage.mkdir()
        for dest, entry in entries.items():
            data = entry['source'].read_bytes()
            if hashlib.sha256(data).hexdigest() != entry['sha256']:
                raise ValueError('artifact changed while staging: ' + str(entry['source']))
            path = stage / dest
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        # Assemble from the staged, hash-checked archive, in the run's order.
        rtl = '// Generated from the verified physical-run source snapshot.\n'
        for source in own_rtl:
            rel = source.relative_to(inputs['manifest'].parent)
            rtl += '\n// source: ' + str(rel) + '\n'
            rtl += (stage / 'evidence/source' / rel).read_text() + '\n`default_nettype wire\n'
        path = stage / 'verilog/rtl/zeq/zeq_all.v'
        path.parent.mkdir(parents=True)
        path.write_text(rtl)
        hashes = {str(p.relative_to(stage)): digest(p) for p in sorted(stage.rglob('*')) if p.is_file()}
        manifest = dict(schema=1, scope='SKY130 demonstrator, not production N7 or foundry acceptance',
                        source_manifest_sha256=inputs['manifest_sha256'],
                        resolved_sha256=digest(stage / 'evidence/resolved.json'),
                        precheck_status='not_run', files=hashes)
        (stage / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        stage.rename(output)
    return manifest


def install_bundle(bundle, destination):
    """Validate everything before copying; a partial install blocks precheck."""
    bundle, destination = Path(bundle).resolve(), Path(destination).resolve()
    if not destination.is_dir():
        raise ValueError('Caravel checkout is missing')
    manifest = json.loads((bundle / 'release-manifest.json').read_text())
    copies = []
    for name, expected in manifest['files'].items():
        source = contained(bundle / name, bundle)
        target = contained(destination / name, destination)
        if digest(source) != expected:
            raise ValueError('bundle hash mismatch: ' + name)
        copies.append((source, target, expected))
    marker = destination / 'RELEASE_INCOMPLETE.json'
    with marker.open('x') as out:
        json.dump({'bundle': str(bundle), 'status': 'installation incomplete'}, out)
    for source, target, expected in copies:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        if digest(target) != expected:
            raise ValueError('installed file hash mismatch: ' + str(target))
    shutil.copyfile(bundle / 'release-manifest.json', destination / 'release-manifest.json')
    marker.unlink()


def verify_bundle(directory):
    directory = Path(directory).resolve()
    if (directory / 'RELEASE_INCOMPLETE.json').exists():
        raise ValueError('incomplete package installation')
    manifest = json.loads((directory / 'release-manifest.json').read_text())
    if manifest.get('schema') != 1 or not manifest.get('files'):
        raise ValueError('invalid release manifest')
    for name, expected in manifest['files'].items():
        if digest(contained(directory / name, directory)) != expected:
            raise ValueError('installed bundle hash mismatch: ' + name)
    return digest(directory / 'release-manifest.json')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('run', 'source-manifest', 'policy', 'lec', 'output'):
        ap.add_argument('--' + name, type=Path, required=True)
    ap.add_argument('--install', type=Path)
    args = ap.parse_args()
    result = stage_bundle(args.run, args.source_manifest, args.policy, args.lec, args.output)
    if args.install:
        install_bundle(args.output, args.install)
    print(f'Staged {len(result["files"])} verified files in {args.output}; precheck remains required.')


if __name__ == '__main__':
    main()
