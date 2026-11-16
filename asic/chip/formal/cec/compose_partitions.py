#!/usr/bin/env python3
"""Prepare a diagnostic proof joining complete, hash-bound EQY partitions.

Each side uses its own actual producers for joined signals. Every included
output remains an assertion; only unjoined inputs remain arbitrary and shared.
A pass qualifies this composition, never the full design or release.
"""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import shutil

SOURCE_BYTES = Path(__file__).read_bytes()


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def identifier(name):
    if not isinstance(name, str) or not name or re.search(r'\s|\\', name):
        raise ValueError('unsupported escaped identifier')
    return '\\' + name + ' '


def check_interfaces(body, name, metadata):
    """Require metadata to describe every scalar port of both actual modules."""
    expected = {'__pi_' + n: 'input' for n in metadata['inbits']}
    expected.update({'__po_' + n: 'output' for n in metadata['outbits']})
    modules = {}
    module = None
    for line in body.splitlines():
        if line.startswith('module '):
            module = line.split()[1].lstrip('\\')
            if module in modules:
                raise ValueError('duplicate partition module')
            modules[module] = {}
        elif line.startswith('  wire '):
            tokens = line.split()
            kinds = [x for x in tokens[:-1] if x in ('input', 'output', 'inout')]
            if not kinds:
                continue
            width = int(tokens[tokens.index('width') + 1]) if 'width' in tokens else 1
            port = tokens[-1].lstrip('\\')
            if module is None or width != 1 or len(kinds) != 1 or port in modules[module]:
                raise ValueError('invalid scalar partition port')
            modules[module][port] = kinds[0]
    if modules != {side + '.' + name: expected for side in ('gold', 'gate')}:
        raise ValueError('partition metadata differs from actual module ports')


def pointer_obligations(body, name, metadata, engine):
    """Add observability for the inspected GMAX=16 memory-address copies.

    These are additional assertions, not assumptions or replacement cuts.
    Require the exact scalar wires on each side and preserve every old line.
    Other synthesis representations must be diagnosed separately.
    """
    if type(engine) is not int or engine < 0:
        raise ValueError('nonnegative solver engine required')
    prefix = f'g_eng[{engine}]'
    copies = [(f'pb{i}', f'{prefix}.pb[{i}]', f'$\\{prefix}.grow$rdreg[0]$q[{i}]')
              for i in range(4)]
    copies += [(f'pa{i}', f'{prefix}.pa[{i}]', f'$\\{prefix}.grow$rdreg[1]$q[{i}]')
               for i in range(4)]
    copies += [('psel', prefix + '.psel', f'$\\{prefix}.grow$rdreg[0]$q[4]')]
    extra = [('lemma.' + name + '.' + label, gold, gate) for label, gold, gate in copies]
    original_lines = body.splitlines()
    maxport = max(int(tokens[tokens.index(kind) + 1])
                  for line in original_lines if line.startswith('  wire ')
                  for tokens in [line.split()] for kind in ('input', 'output') if kind in tokens)
    lines, added = [], []
    side, wires = None, set()
    for line in original_lines:
        if line == 'end' and side:
            for signal, gold, gate in extra:
                target = '\\' + gold if side == 'gold' else gate
                if target not in wires:
                    raise ValueError('pointer-copy scalar wire missing: ' + side + ' ' + target)
                addition = '  connect \\__po_' + signal + ' ' + target
                lines.append(addition)
                added.append(addition)
        lines.append(line)
        if line.startswith('module '):
            side = 'gold' if line.startswith('module \\gold.') else 'gate'
            wires = set()
            for index, (signal, _, _) in enumerate(extra):
                if signal in metadata['inbits'] or signal in metadata['outbits']:
                    raise ValueError('pointer-copy obligation name collision')
                addition = f'  wire output {maxport + 1 + index} \\__po_' + signal
                lines.append(addition)
                added.append(addition)
        elif line.startswith('  wire '):
            tokens = line.split()
            width = int(tokens[tokens.index('width') + 1]) if 'width' in tokens else 1
            if width == 1:
                wires.add(tokens[-1])
        elif line == 'end':
            side = None
    # Existing circuits must be byte-for-byte unchanged after removing only
    # the new declarations and connections. No source line may be overwritten.
    added_set = set(added)
    if added_set.intersection(original_lines) or [line for line in lines if line not in added_set] != original_lines:
        raise ValueError('pointer obligations changed an existing circuit')
    metadata['outbits'].update({signal: [0] for signal, _, _ in extra})
    return '\n'.join(lines) + '\n', extra


def common_aliases(nets, external):
    """Collapse only exact scalar signal identities present on BOTH sides."""
    groups, aliases = {}, {}
    for name in sorted(external):
        bits = [side.get(name, {}).get('bits', []) for side in nets]
        if any(len(b) != 1 or type(b[0]) is not int for b in bits):
            aliases[name] = name
            continue
        identity = (bits[0][0], bits[1][0])
        aliases[name] = groups.setdefault(identity, name)
    return aliases


def prepare(origin, build, names, timeout=300, strategy='smt', pointer_engine=None,
            restore_aliases=False, depth=5, all_pointer_engines=False):
    origin, build = Path(origin), Path(build)
    if build.exists():
        raise ValueError('use a fresh composition directory')
    if type(timeout) is not int or timeout <= 0:
        raise ValueError('positive timeout required')
    if strategy not in ('smt', 'pdr'):
        raise ValueError('unsupported proof strategy')
    if type(depth) is not int or depth < 1:
        raise ValueError('positive induction depth required')
    if not names or len(set(names)) != len(names):
        raise ValueError('nonempty unique partitions required')
    if all_pointer_engines and pointer_engine is not None:
        raise ValueError('choose explicit or discovered pointer engines')
    result_path = origin / 'result.json'
    result_hash = sha(result_path)
    result = json.loads(result_path.read_text())
    evidence = result['evidence_sha256']
    sources, metadata, additions, original_hashes = {}, {}, {}, {}
    inputs, outputs = set(), set()
    for name in sorted(names):
        if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*', name):
            raise ValueError('unsafe partition filename')
        for extension in ('.il', '.json'):
            relative = 'eqy/partitions/' + name + extension
            path = origin / relative
            if origin.resolve() not in path.resolve().parents or sha(path) != evidence.get(relative):
                raise ValueError('partition evidence hash mismatch: ' + relative)
            sources[name + extension] = path.read_bytes()
            original_hashes[relative] = evidence[relative]
            if hashlib.sha256(sources[name + extension]).hexdigest() != evidence[relative]:
                raise ValueError('partition changed while reading')
        part = json.loads(sources[name + '.json'])['partition']
        if part['name'] != name or not part['outbits']:
            raise ValueError('partition identity or outputs missing')
        for kind in ('inbits', 'outbits'):
            for signal, bits in part[kind].items():
                identifier(signal)
                if bits != [0]:
                    raise ValueError('composition requires scalar partition ports')
        if outputs & part['outbits'].keys() or part['inbits'].keys() & part['outbits'].keys():
            raise ValueError('multiple producers or self-cut output')
        check_interfaces(sources[name + '.il'].decode(), name, part)
        if pointer_engine is not None or all_pointer_engines:
            body = sources[name + '.il'].decode()
            engines = [pointer_engine] if pointer_engine is not None else sorted({
                int(e) for e in re.findall(r'^  wire (?:width \d+ )?\$\\g_eng\[(\d+)\]\.grow\$rdreg\[', body, re.M)})
            additions[name] = []
            for engine_index in engines:
                label = name if pointer_engine is not None else name + '.engine' + str(engine_index)
                body, extra = pointer_obligations(body, label, part, engine_index)
                additions[name].extend(extra)
            check_interfaces(body, name, part)
            sources[name + '.il'] = body.encode()
            document = json.loads(sources[name + '.json'])
            document['partition'] = part
            sources[name + '.json'] = (json.dumps(document, indent=2) + '\n').encode()
        metadata[name] = part
        inputs.update(part['inbits'])
        outputs.update(part['outbits'])
    external = sorted(inputs - outputs)
    aliases = {name: name for name in external}
    interfaces = {}
    if restore_aliases:
        tops = {name.split('.', 1)[0] for name in names}
        if len(tops) != 1:
            raise ValueError('alias restoration requires one original top')
        top = next(iter(tops))
        nets = []
        for side in ('gold', 'gate'):
            filename = side + '-interface.json'
            path = origin / filename
            if origin.resolve() not in path.resolve().parents or sha(path) != evidence.get(filename):
                raise ValueError('original interface evidence hash mismatch')
            with path.open() as stream:
                design = json.load(stream)
            if set(design['modules']) != {top}:
                raise ValueError('expected one original top for alias restoration')
            wires = design['modules'][top]['netnames']
            nets.append({n: wires[n] for n in external if n in wires})
            del wires, design
            if sha(path) != evidence[filename]:
                raise ValueError('original interface changed while reading')
            interfaces[filename] = (path, evidence[filename])
        aliases = common_aliases(nets, external)
    canonical_inputs = sorted(set(aliases.values()))
    ids = {n: 's' + str(i) for i, n in enumerate(sorted(inputs | outputs))}
    lines = ['module miter(' + ', '.join('input ' + ids[n] for n in canonical_inputs) + ');']
    for side in ('gold', 'gate'):
        lines.extend('wire ' + side + '_' + ids[n] + ';' for n in sorted(outputs))
        for index, (name, part) in enumerate(sorted(metadata.items())):
            ports = []
            for signal in sorted(part['inbits']):
                wire = side + '_' + ids[signal] if signal in outputs else ids[aliases[signal]]
                ports.append('.' + identifier('__pi_' + signal) + '(' + wire + ')')
            for signal in sorted(part['outbits']):
                ports.append('.' + identifier('__po_' + signal) + '(' + side + '_' + ids[signal] + ')')
            lines.append(identifier(side + '.' + name) + side + str(index)
                         + ' (' + ', '.join(ports) + ');')
    for signal in sorted(outputs):
        gold, gate = 'gold_' + ids[signal], 'gate_' + ids[signal]
        lines.append('always @* assert (' + gold + " === 1'bx || " + gold + ' === ' + gate + ');')
    lines.append('endmodule')
    sources['miter.sv'] = ('\n'.join(lines) + '\n').encode()
    script = 'read_verilog -formal -sv miter.sv\n'
    script += '\n'.join('read_rtlil ' + n + '.il' for n in sorted(names))
    script += '''
hierarchy -top miter
proc
async2sync
formalff -clk2ff -ff2anyinit gate.*
setundef -anyseq gate.*
flatten -wb
dffunmap
opt_expr -keepdc -undriven
opt_clean
xprop -formal -split-ports -assume-def-inputs miter
'''
    engine = 'smtbmc bitwuzla' if strategy == 'smt' else 'abc pdr'
    options = 'aigsmt bitwuzla\n' if strategy == 'pdr' else ''
    sources['proof.sby'] = (f'[options]\nmode prove\ndepth {depth}\ntimeout {timeout}\n' + options
                            + '\n[engines]\n' + engine + '\n\n[script]\n' + script
                            + '\n[files]\nmiter.sv\n'
                            + '\n'.join(n + '.il' for n in sorted(names)) + '\n').encode()
    if sha(result_path) != result_hash:
        raise ValueError('origin result changed while preparing')
    if Path(__file__).read_bytes() != SOURCE_BYTES:
        raise ValueError('composition tool changed while preparing; retry from a fresh process')
    sources['compose_partitions.py'] = SOURCE_BYTES
    record = dict(scope=__doc__.strip(), origin=str(origin.resolve()),
                  origin_result_sha256=result_hash, partitions=sorted(names),
                  outputs=sorted(outputs), external_input_bits=len(canonical_inputs), signal_ids=ids,
                  restored_external_aliases={n: other for n, other in aliases.items() if n != other},
                  original_partition_sha256=original_hashes, additional_assertions=additions,
                  release_eligible=False, full_design_equivalence=False, strategy=strategy, depth=depth,
                  source_sha256={n: hashlib.sha256(body).hexdigest() for n, body in sources.items()})
    build.mkdir(parents=True)
    for name, body in sources.items():
        (build / name).write_bytes(body)
    for name, (path, expected) in interfaces.items():
        # Archived interface snapshots are read-only inputs; proof jobs only
        # consume the generated miter and partition IL. Share identical bytes
        # without multiplying these large snapshots across diagnostic runs.
        try:
            os.link(path, build / name)
        except OSError as exc:
            if exc.errno != errno.EXDEV:
                raise
            shutil.copyfile(path, build / name)
        if sha(build / name) != expected:
            raise ValueError('copied alias interface changed')
        record['source_sha256'][name] = expected
    (build / 'composition.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', required=True, type=Path)
    parser.add_argument('--build', required=True, type=Path)
    parser.add_argument('--partition', required=True, action='append')
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--strategy', choices=('smt', 'pdr'), default='smt')
    parser.add_argument('--pointer-engine', type=int,
                        help='add checked pointer-copy assertions for the inspected GMAX=16 solver profile')
    parser.add_argument('--restore-aliases', action='store_true',
                        help='preserve scalar input identities verified in both archived original netlists')
    parser.add_argument('--all-pointer-engines', action='store_true',
                        help='assert every inspected scalar pointer-copy profile found in each partition')
    parser.add_argument('--depth', type=int, default=5,
                        help='SMT induction depth; both base case and induction must still prove')
    args = parser.parse_args()
    record = prepare(args.origin, args.build, args.partition, args.timeout, args.strategy,
                     args.pointer_engine, args.restore_aliases, args.depth, args.all_pointer_engines)
    print(f"Prepared {len(record['partitions'])} partitions; {len(record['outputs'])} outputs remain asserted.")
