"""Clone a bound composition and compact its post-xprop model without dropping properties.

This prepares an experiment, never a release proof. The caller must check the
before/after property lists as well as the eventual SBY verdict.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


ANCHOR = 'xprop -formal -split-ports -assume-def-inputs miter\n'
# Explicit opt_merge -keepdc avoids merging state with undefined initialization.
# Do not use opt_dff or change the xprop/assumption policy here.
CLEANUP = '''select -write properties_before.txt t:$assert t:$assume t:$check t:$live t:$fair t:$cover
setattr -set keep 1 t:$assert t:$assume t:$check t:$live t:$fair t:$cover
opt_expr -keepdc
opt_merge -keepdc
opt_clean -purge
opt_expr -keepdc
opt_merge -keepdc
opt_clean -purge
select -write properties_after.txt t:$assert t:$assume t:$check t:$live t:$fair t:$cover
stat
'''


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            digest.update(block)
    return digest.hexdigest()


def inside(root, name):
    path = (root / name).resolve()
    path.relative_to(root.resolve())
    return path


def property_inventory(before, after):
    old, new = before.splitlines(), after.splitlines()
    if (not old or any(not name.strip() for name in old + new)
            or len(old) != len(set(old)) or len(new) != len(set(new))
            or set(old) != set(new)):
        raise ValueError('formal property inventory changed or is empty')
    return len(old)


def prepare(origin, destination):
    manifest_path = origin / 'composition.json'
    manifest_hash = sha(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    result_path = origin / 'result.json'
    result_hash = sha(result_path)
    result = json.loads(result_path.read_text())
    if (result['composition_sha256'] != manifest_hash or result.get('mutation') is not None
            or result.get('inputs_unchanged') is not True
            or result['asserted_output_bits'] != len(manifest['outputs'])):
        raise ValueError('unbound or mutated origin composition')
    for name, digest in manifest['source_sha256'].items():
        if sha(inside(origin, name)) != digest:
            raise ValueError('changed composition input: ' + name)
    config = (origin / 'proof.sby').read_text()
    if (config.count(ANCHOR) != 1 or '\nmode prove\n' not in config
            or CLEANUP in config or manifest.get('compaction')):
        raise ValueError('unsupported proof configuration')
    optimized = config.replace(ANCHOR, ANCHOR + CLEANUP)
    if optimized.replace(CLEANUP, '', 1) != config:
        raise ValueError('cleanup changed original proof configuration')
    destination.mkdir(parents=True, exist_ok=False)
    for name in manifest['source_sha256']:
        source = inside(origin, name)
        target = inside(destination, name)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        if sha(target) != manifest['source_sha256'][name]:
            raise ValueError('composition input changed while copying')
    (destination / 'proof.sby').write_text(optimized)
    shutil.copyfile(Path(__file__), destination / 'compact_proof.py')
    record = dict(manifest)
    record.update(release_eligible=False, full_design_equivalence=False)
    record['source_sha256'] = {name: sha(destination / name) for name in manifest['source_sha256']}
    record['source_sha256']['compact_proof.py'] = sha(destination / 'compact_proof.py')
    record['compaction'] = dict(origin=str(origin.resolve()), origin_result_sha256=result_hash,
        origin_composition_sha256=manifest_hash, original_config_sha256=sha(origin / 'proof.sby'),
        circuit_and_miter_inputs_unchanged=True, unknown_value_policy_unchanged=True,
        original_asserted_outputs=len(manifest['outputs']), property_inventory_check_required=True)
    if sha(manifest_path) != manifest_hash or sha(result_path) != result_hash:
        raise ValueError('origin changed during preparation')
    (destination / 'composition.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    args = parser.parse_args()
    result = prepare(args.origin, args.build)
    print('Prepared', len(result['outputs']), 'unchanged asserted outputs; property census required.')
