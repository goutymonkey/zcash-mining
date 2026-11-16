"""Verify and copy a completed mapping prefix before continuing in a fresh build."""
import gzip
import errno
import hashlib
import json
import os
import shutil
from pathlib import Path

if __package__:
    from .solver_mapping import batch_script, pending_cells
else:
    from solver_mapping import batch_script, pending_cells


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1048576), b''):
            h.update(block)
    return h.hexdigest()


def link_verified(source, destination, expected):
    """Share a frozen input on the same filesystem; never overwrite a path.

    Consumers must only read this input and write distinct output names.
    Cross-filesystem archives retain the ordinary copy behavior.
    """
    if destination.exists() or destination.is_symlink():
        raise ValueError('verified input destination already exists')
    if sha(source) != expected:
        raise ValueError('verified input source changed')
    try:
        os.link(source, destination)
    except OSError as exc:
        if exc.errno != errno.EXDEV:
            raise
        with source.open('rb') as src, destination.open('xb') as dst:
            shutil.copyfileobj(src, dst)
    if sha(destination) != expected:
        raise ValueError('verified input changed during transfer')


def resume_mapping(origin, build, params, image, files, memories, batch_size):
    """Require an unbroken successful stage/hash chain; never reuse a verdict."""
    old = json.loads((origin/'result.json').read_text())
    if old.get('status') not in ('PASS', 'FAIL') or old.get('logical_sram_cells') != memories:
        raise ValueError('mapping origin lacks a terminal result or matching SRAM count')
    evidence = old['evidence_sha256']
    checked = {}

    def check(name):
        path = origin/name
        digest = sha(path)
        if digest != evidence[name]:
            raise ValueError('mapping origin artifact changed: ' + name)
        checked[name] = digest
        return path

    inputs = json.loads(check('inputs.json').read_text())
    if inputs['parameters'] != params or old['parameters'] != params or inputs['image_id'] != image:
        raise ValueError('mapping origin parameters or image differ')
    if inputs['mapping_batch_size'] != batch_size:
        raise ValueError('mapping batch size differs')
    for name, digest in inputs['source_sha256'].items():
        if sha(origin/name) != digest:
            raise ValueError('mapping origin source changed: ' + name)
        if name.startswith(('source/rtl/', 'source/model/')) or name == 'source/pd/synthesis_stage.py':
            if files.get(name) != digest:
                raise ValueError('mapping origin RTL/model/stage wrapper differs: ' + name)
    history = json.loads(check('mapping-history.json').read_text())
    if not isinstance(history, list) or not history:
        raise ValueError('no completed mapping prefix')
    archives = {}
    if (origin/'checkpoint-archives.json').exists():
        archives = json.loads(check('checkpoint-archives.json').read_text())
    raw_hashes = {}

    def raw(name):
        if name in raw_hashes:
            return raw_hashes[name]
        if name in evidence:
            check(name)
            digest = checked[name]
        else:
            entry = archives[name]
            if entry['archive'] != name + '.gz':
                raise ValueError('unexpected checkpoint archive path')
            archive = check(entry['archive'])
            if checked[entry['archive']] != entry['gzip_sha256']:
                raise ValueError('checkpoint gzip hash differs')
            restored = hashlib.sha256(); count = 0
            with gzip.open(archive, 'rb') as f:
                for chunk in iter(lambda: f.read(1048576), b''):
                    restored.update(chunk); count += len(chunk)
            digest = restored.hexdigest()
            if digest != entry['raw_sha256'] or count != entry['raw_bytes']:
                raise ValueError('checkpoint restoration mismatch')
        raw_hashes[name] = digest
        return digest

    stages = {}

    def stage(name, netlist, extras=()):
        recorded = old['stages'][name]
        detail = json.loads(check(name+'-execution.json').read_text())
        if (recorded.get('exit_code') != 0 or recorded.get('execution') != detail
                or detail.get('status') != 'PASS' or detail.get('exit_code') != 0
                or detail.get('inputs_unchanged') is not True
                or detail.get('command') != ['yosys', '-Q', '-T', '-s', name+'.ys']):
            raise ValueError('mapping prefix stage did not pass: ' + name)
        script = check(name+'.ys')
        expected = {name+'.ys': sha(script), 'source/pd/synthesis_stage.py': files['source/pd/synthesis_stage.py'], netlist: raw(netlist)}
        for item in extras:
            expected[item] = sha(check(item))
        if detail['input_sha256'] != expected:
            raise ValueError('mapping prefix input hash chain differs: ' + name)
        if name+'.log' in evidence:
            check(name+'.log')
        stages[name] = dict(recorded, reused=True, origin=str(origin))

    for name, source in [('premap', 'coarse.il'), ('simple', 'premap.il')]:
        if check(name+'.ys').read_bytes() != (build/(name+'.ys')).read_bytes():
            raise ValueError('mapping preparation script differs: ' + name)
        stage(name, source)
    current = 'simple.il'
    previous_after = None
    for index, item in enumerate(history):
        name = f'map-{index:03d}'
        if (item['name'] != name or item['input'] != current or item['output'] != name+'.il'
                or type(item['selected']) is not int or not 1 <= item['selected'] <= batch_size
                or type(item['before']) is not int or item['before'] < item['selected']
                or type(item['after']) is not int or item['after'] < 0
                or (previous_after is not None and item['before'] != previous_after)):
            raise ValueError('inconsistent mapping prefix history')
        selection = check(name+'.list').read_text().splitlines()
        if len(selection) != item['selected'] or len(set(selection)) != len(selection) or any(not cell.startswith('zeq_eh_par/') for cell in selection):
            raise ValueError('mapping selection differs from recorded batch')
        if check(name+'.ys').read_text() != batch_script(current, item['output'], name+'.list', len(selection), memories):
            raise ValueError('mapping batch script differs: ' + name)
        stage(name, current, [name+'.list'])
        raw(item['output'])
        current = item['output']; previous_after = item['after']
    # The latest output is retained uncompressed by the batched flow. Parse it
    # independently before continuing; neither history nor counters alone pass.
    check(current)
    if len(pending_cells(origin/current)) != history[-1]['after']:
        raise ValueError('mapping seed coarse-cell count differs')
    # Copy the verified prefix, including restoration archives, so another
    # interrupted continuation can itself be resumed without broken paths.
    for name, digest in checked.items():
        if name == 'inputs.json' or name == 'coarse.il':
            continue
        destination = build/name
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            if sha(destination) != digest:
                raise ValueError('resume destination conflicts: ' + name)
        else:
            # These ledgers are updated by the next completed batch. Sharing
            # their inode would mutate the archived origin's evidence.
            if name in ('mapping-history.json', 'checkpoint-archives.json'):
                shutil.copyfile(origin/name, destination)
            else:
                link_verified(origin/name, destination, digest)
        if sha(destination) != digest:
            raise ValueError('copied mapping evidence differs: ' + name)
    shutil.copyfile(origin/'inputs.json', build/'mapping-origin-inputs.json')
    shutil.copyfile(origin/'result.json', build/'mapping-origin-result.json')
    record = dict(origin=str(origin), origin_status=old['status'],
                  origin_result_sha256=sha(origin/'result.json'),
                  verified_artifact_sha256=checked, restored_checkpoint_sha256=raw_hashes,
                  resumed_after_batches=len(history), seed=current,
                  seed_sha256=sha(build/current), remaining_coarse_cells=history[-1]['after'],
                  scope='Verified mapping prefix only; final inventory and equivalence remain separate gates.')
    (build/'mapping-resume.json').write_text(json.dumps(record, indent=2)+'\n')
    return current, history, stages
