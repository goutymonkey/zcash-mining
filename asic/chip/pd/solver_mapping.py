"""Deterministic mapping batches for a flat solver RTLIL netlist.

Only synthesis representation changes. The SRAM count is checked after every
batch; the independent shape inventory and equivalence remain separate gates.
"""
import json
import gzip
import hashlib
from pathlib import Path


def pending_cells(path):
    """Read exact RTLIL cell identities without loading a large JSON netlist."""
    cells = {}
    module = None
    with Path(path).open() as stream:
        for line in stream:
            text = line.strip()
            if text.startswith('module '):
                module = text.split(' ', 1)[1].lstrip('\\')
                if module != 'zeq_eh_par':
                    raise ValueError('mapping requires exactly the flat zeq_eh_par module')
            elif text.startswith('cell '):
                _, kind, name = text.split(' ', 2)
                if module is None or not kind.startswith('$'):
                    raise ValueError('unexpected cell outside the generic flat design')
                if not kind.startswith('$_') and kind != '$mem_v2':
                    identity = module + '/' + name.lstrip('\\')
                    if identity in cells:
                        raise ValueError('duplicate cell identity')
                    cells[identity] = kind
    if module is None:
        raise ValueError('missing solver module')
    return cells


def batch_script(input_name, output_name, selection_name, count, memories):
    # Generated internal filenames only; never interpolate arbitrary Yosys code.
    for name in (input_name, output_name, selection_name):
        if not name or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-.' for c in name):
            raise ValueError('unsafe mapping artifact name')
    if count < 1 or memories < 1:
        raise ValueError('positive batch and SRAM counts required')
    return f'''read_rtlil {input_name}
select -read {selection_name}
select -assert-count {count} %
techmap -recursive
select -clear
opt -fast
select -assert-count {memories} t:$mem_v2
write_rtlil {output_name}
'''


def validate_progress(before, after, selected):
    if not selected or any(name not in before for name in selected):
        raise ValueError('empty or invalid mapping batch')
    # Mapping a multiplier can introduce several smaller arithmetic cells.
    # Total cell count need not decrease, but each selected original operation
    # must be replaced. Completion still requires no remaining coarse cells.
    unchanged = [name for name in selected if after.get(name) == before[name]]
    if unchanged:
        raise ValueError('selected coarse cells were not mapped: ' + ', '.join(unchanged[:3]))


def archive_checkpoint(build, name):
    """Losslessly archive a consumed checkpoint; retain hashes for restoration."""
    source = build / name
    archive = build / (name + '.gz')
    if archive.exists():
        raise ValueError('checkpoint archive already exists: ' + archive.name)
    digest = hashlib.sha256()
    with source.open('rb') as src, archive.open('xb') as raw:
        with gzip.GzipFile(filename='', fileobj=raw, mode='wb', compresslevel=1, mtime=0) as dst:
            for block in iter(lambda: src.read(1024 * 1024), b''):
                digest.update(block)
                dst.write(block)
    restored = hashlib.sha256()
    compressed = hashlib.sha256()
    with gzip.open(archive, 'rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            restored.update(block)
    if restored.digest() != digest.digest():
        raise ValueError('checkpoint archive did not preserve its contents')
    with archive.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            compressed.update(block)
    ledger = build / 'checkpoint-archives.json'
    records = json.loads(ledger.read_text()) if ledger.exists() else {}
    records[name] = dict(archive=archive.name, raw_sha256=digest.hexdigest(),
                         gzip_sha256=compressed.hexdigest(), raw_bytes=source.stat().st_size)
    ledger.write_text(json.dumps(records, indent=2) + '\n')
    source.unlink()


def map_batches(build, execute, memories, batch_size=256, max_batches=256,
                compress_checkpoints=False, initial='simple.il', prior_history=()):
    if type(batch_size) is not int or not 1 <= batch_size <= 1024:
        raise ValueError('mapping batch size must be an integer in 1..1024')
    if type(max_batches) is not int or max_batches < 1:
        raise ValueError('positive batch limit required')
    current = initial
    history = list(prior_history)
    if (history and current != history[-1]['output']) or (not history and current != 'simple.il'):
        raise ValueError('mapping seed differs from the completed prefix')
    for index in range(len(history), max_batches):
        before = pending_cells(build / current)
        if not before:
            return current, history
        selected = sorted(before)[:batch_size]
        name = f'map-{index:03d}'
        (build / (name + '.list')).write_text('\n'.join(selected) + '\n')
        (build / (name + '.ys')).write_text(batch_script(
            current, name + '.il', name + '.list', len(selected), memories))
        execute(name, current, [name + '.list'])
        after = pending_cells(build / (name + '.il'))
        validate_progress(before, after, selected)
        history.append(dict(name=name, input=current, output=name + '.il',
                            selected=len(selected), before=len(before), after=len(after)))
        (build / 'mapping-history.json').write_text(json.dumps(history, indent=2) + '\n')
        if compress_checkpoints:
            archive_checkpoint(build, current)
        current = name + '.il'
    # A last batch is allowed to finish exactly at the limit.
    if pending_cells(build / current):
        raise ValueError('mapping batch limit reached with unfinished cells')
    return current, history
