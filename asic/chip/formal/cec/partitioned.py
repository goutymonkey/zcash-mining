#!/usr/bin/env python3
"""Partitioned EQY proof for chip.py's already archived input files.

Uses formal X propagation (safe replacement), not forced zero initialization.
SRAM output data is arbitrary; every exposed macro input is a proof output.
This is preparation evidence, not yet accepted by the release-bundle gate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalization(build, top, side):
    name = 'chip_rtl.v' if side == 'gold' else 'gate.v'
    return f'''read_liberty -ignore_miss_func "{build}/cells.lib"
read_verilog "{build}/sram.v" "{build}/{name}"
hierarchy -check -top {top}
proc
flatten
opt_clean
expose -evert t:sky130_sram_2kbyte_1rw1r_32x512_8
rename -hide w:_* w:net* w:clknet*
async2sync
techmap
opt -fast
splitnets -ports
write_json "{build}/{side}-interface.json"
write_rtlil "{build}/{side}-normalized.il"
'''


def exact_pattern(name):
    # EQY patterns are whitespace/comma separated and slash delimited.
    # Reject unsupported identifiers instead of broadening a matching rule.
    if re.search(r'[\s/,]', name):
        raise ValueError('unsupported EQY net name: ' + name)
    return '/^' + re.escape(name) + '$/'


def matching_rules(gold, gate):
    # EQY matches public signals. Yosys-generated private temporaries can
    # contain source paths and unstable IDs; they are not correspondence
    # points, even when normalization happens to give both the same name.
    function_locals = any('$func$' in n for side in (gold, gate) for n in side)
    gold = {n: v for n, v in gold.items() if not n.startswith('$')
            and '$func$' not in n and not v.get('hide_name', 0)}
    gate = {n: v for n, v in gate.items() if not n.startswith('$')
            and '$func$' not in n and not v.get('hide_name', 0)}
    # Flattened function locals may be public in RTLIL despite being compiler
    # temporaries. Exclude only their correspondence; preserve all their logic.
    matches = [r'gold-nomatch /.*\$func\$.*/'] if function_locals else []
    for name, net in sorted(gold.items()):
        candidate = name + '[0]'
        if (name not in gate and candidate in gate and candidate not in gold
                and len(net['bits']) == len(gate[candidate]['bits']) == 1):
            matches.append('gold-match ' + exact_pattern(name) + ' ' + exact_pattern(candidate))
    # Bus groups must include aliases on either side. Otherwise a reference
    # wire alias and a mapped buffer can create circular cut points whose
    # arbitrary inputs spuriously refute an otherwise equivalent circuit.
    candidates = {name: name for name in gold if name in gate}
    for name in gold:
        candidate = name + '[0]'
        if (name not in gate and candidate in gate and candidate not in gold
                and len(gold[name]['bits']) == len(gate[candidate]['bits']) == 1):
            candidates[name] = candidate
    parent = {name: name for name in candidates}

    def root(name):
        while parent[name] != name:
            parent[name] = parent[parent[name]]
            name = parent[name]
        return name

    def join(a, b):
        parent[root(a)] = root(b)

    buses = {}
    for name in candidates:
        match = re.fullmatch(r'(.+)\[(-?\d+)\]', name)
        if match:
            base = match[1]
            if base in buses:
                join(name, buses[base])
            buses[base] = name
    bind_aliases = set()
    for name, mapped in candidates.items():
        a, b = gold[name]['bits'], gate[mapped]['bits']
        if len(a) == len(b) == 1 and isinstance(a[0], int) != isinstance(b[0], int):
            # A constant propagated through state on one side must not become
            # an arbitrary independent input on the other. Keep its producer
            # in the consumer; proving the constant is still an obligation.
            bind_aliases.add(name)
    for side, mapping, other, other_mapping in (
            (gold, {n: n for n in candidates}, gate, candidates),
            (gate, candidates, gold, {n: n for n in candidates})):
        aliases = {}
        for name, mapped in mapping.items():
            bits = side[mapped]['bits']
            if len(bits) != 1 or not isinstance(bits[0], int):
                continue  # Constants are not shared signal identities.
            names = aliases.setdefault(bits[0], [])
            if names:
                join(name, names[0])
            names.append(name)
        # Grouping proves the producer together, but downstream partitions
        # can still drive its aliased outputs independently. If alias identity
        # differs between designs, keep those signals' logic in consumers.
        # This expands proof cones; it does not assume the aliases equivalent.
        for names in aliases.values():
            if len(names) > 1 and len({tuple(other[other_mapping[n]]['bits']) for n in names}) > 1:
                bind_aliases.update(names)
    groups = {}
    for name in candidates:
        groups.setdefault(root(name), []).append(name)
    collect = []
    for names in sorted(groups.values(), key=lambda names: min(names)):
        if len(names) < 2:
            continue
        patterns = set()
        for name in names:
            exact_pattern(name)
            match = re.fullmatch(r'(.+)\[(-?\d+)\]', name)
            patterns.add(re.escape(match[1]) + r'\[-?[0-9]+\]' if match else re.escape(name))
        collect.append('group /^(' + '|'.join(sorted(patterns)) + ')$/')
    if bind_aliases:
        for name in bind_aliases:
            exact_pattern(name)
        collect.append('bind /^(' + '|'.join(re.escape(n) for n in sorted(bind_aliases)) + ')$/')
    return matches, collect


def state_correspondences(gold, gate):
    """Select scalar boundary pins and common register state, never assumptions."""
    def state_bits(module):
        bits = set()
        word_types = {'$ff', '$dff', '$dffe', '$adff', '$adffe', '$aldff', '$aldffe',
                      '$sdff', '$sdffe', '$sdffce', '$dffsr', '$dffsre',
                      '$dlatch', '$adlatch', '$dlatchsr', '$sr'}
        for cell in module.get('cells', {}).values():
            kind = cell['type']
            if kind in word_types or kind.startswith(('$_DFF', '$_SDFF', '$_DLATCH', '$_SR_', '$_FF_')):
                if cell.get('port_directions', {}).get('Q') != 'output':
                    raise ValueError('state cell lacks an output Q port')
                bits.update(b for b in cell['connections']['Q'] if isinstance(b, int))
        return bits

    ports = [module.get('ports', {}) for module in (gold, gate)]
    if set(ports[0]) != set(ports[1]):
        raise ValueError('state matching requires identical boundary pin names')
    for name in ports[0]:
        if (any(len(p[name]['bits']) != 1 for p in ports)
                or ports[0][name]['direction'] != ports[1][name]['direction']):
            raise ValueError('state matching requires identical scalar boundary pins')
    states = [state_bits(module) for module in (gold, gate)]
    nets = [module['netnames'] for module in (gold, gate)]
    pairs = {}
    for name, net in sorted(nets[0].items()):
        if name.startswith('$') or '$func$' in name or net.get('hide_name', 0):
            continue
        candidate = name
        if candidate not in nets[1] and name + '[0]' not in nets[0]:
            candidate = name + '[0]'
        other = nets[1].get(candidate)
        if other is None or other.get('hide_name', 0):
            continue
        if len(net['bits']) != 1 or len(other['bits']) != 1:
            raise ValueError('state matching requires scalar public nets')
        a, b = net['bits'][0], other['bits'][0]
        is_state = ((a in states[0] and (b in states[1] or isinstance(b, str)))
                    or (b in states[1] and isinstance(a, str)))
        if name in ports[0] or is_state:
            exact_pattern(name); exact_pattern(candidate)
            pairs[name] = candidate
    if not set(ports[0]) <= set(pairs):
        raise ValueError('state matching omitted a boundary pin')
    return pairs


def explicit_match_rules(pairs, batch_size=128):
    """Batch exact identity names to avoid one full EQY name scan per bit."""
    if type(batch_size) is not int or batch_size < 1:
        raise ValueError('positive match batch size required')
    same = []
    rules = []
    for name, other in sorted(pairs.items()):
        exact_pattern(name); exact_pattern(other)
        if name == other:
            same.append(name)
        else:
            rules.append('gold-match ' + exact_pattern(name) + ' ' + exact_pattern(other))
    for start in range(0, len(same), batch_size):
        rules.append('gold-match /^(' + '|'.join(re.escape(name) for name in same[start:start+batch_size]) + ')$/')
    return rules


STRATEGIES = ('pdr', 'smt', 'pdr-smt', 'smt-pdr')


def configuration(build, top, partition_timeout=120, strategy='pdr', bind_nets=(), unmatch_nets=(), state_only=False):
    if not isinstance(partition_timeout, int) or partition_timeout <= 0:
        raise ValueError('partition timeout must be a positive integer')
    if strategy not in STRATEGIES:
        raise ValueError('unsupported proof strategy')
    interfaces = [json.loads((build / f'{side}-interface.json').read_text())
                  ['modules'][top] for side in ('gold', 'gate')]
    nets = [module['netnames'] for module in interfaces]
    if any('$func$' in name for module in interfaces for name in module.get('ports', {})):
        raise ValueError('boundary port collides with compiler function-local namespace')
    excluded = sorted(set(unmatch_nets))
    if set(excluded) & set(bind_nets):
        raise ValueError('a net cannot be both bound and unmatched')
    for name in excluded:
        exact_pattern(name)
        for module in interfaces:
            bits = module['netnames'].get(name, {}).get('bits', [])
            boundary = {b for port in module.get('ports', {}).values()
                        for b in port['bits'] if isinstance(b, int)}
            if (name in module.get('ports', {}) or not bits
                    or not any(isinstance(b, int) for b in bits)
                    or any(b in boundary for b in bits if isinstance(b, int))):
                raise ValueError('unmatching requires a common internal net with no boundary alias: ' + name)
    # Remove only internal correspondence points. Their logic stays in the
    # consuming proof cones; every top and SRAM interface remains matched.
    if state_only:
        pairs = state_correspondences(*interfaces)
        pairs = {name: other for name, other in pairs.items() if name not in excluded}
        if any(name in interfaces[0]['ports'] for name in excluded):
            raise ValueError('cannot exclude a boundary match')
        _, collect = matching_rules({name: nets[0][name] for name in pairs},
                                    {other: nets[1][other] for other in pairs.values()})
        matches = explicit_match_rules(pairs)
        # Explicit matches are retained. Remaining intermediate names are not
        # cut points; their logic stays in the observable/register proof cones.
        matches.append('gold-nomatch *')
    else:
        matches, collect = matching_rules(*[
            {name: net for name, net in side.items() if name not in excluded}
            for side in nets])
        matches = ['gold-nomatch ' + exact_pattern(name) for name in excluded] + matches
    for name in sorted(set(bind_nets)):
        pattern = exact_pattern(name)
        for module in interfaces:
            bits = module['netnames'].get(name, {}).get('bits', [])
            boundary = {b for port in module['ports'].values() if port['direction'] == 'input'
                        for b in port['bits']}
            if len(bits) != 1 or not isinstance(bits[0], int) or bits[0] in boundary:
                raise ValueError('binding requires a common driven scalar net, not an input/constant: ' + name)
        # Retain the actual driver in consuming partitions. This adds logic
        # obligations; it never assumes the net's value or omits an output.
        collect.append('bind ' + pattern)
    parts = ['[options]\nsplitnets off\n']
    for side in ('gold', 'gate'):
        parts.append(f'[{side}]\nread_rtlil "{build}/{side}-normalized.il"\n')
    if matches:
        parts.append('[match *]\n' + '\n'.join(matches))
    parts.append('[collect *]\njoin *\n' + '\n'.join(collect))
    # EQY tries strategies in declaration order. Prefer SMT when controller
    # induction closes quickly, while retaining PDR for harder data cones.
    for engine in strategy.split('-'):
        if engine == 'pdr':
            parts.append(f'''[strategy pdr]
use sby
engine abc pdr
timeout {partition_timeout}
option aigsmt bitwuzla
''')
        else:
            # mode prove requires base case and induction, not bounded BMC.
            parts.append(f'''[strategy smt]
use sby
engine smtbmc bitwuzla
depth 5
timeout {partition_timeout}
''')
    return '\n'.join(parts)


def inspect_proof(build, top, returncode):
    proof = build / 'eqy'
    errors = []
    if returncode != 0:
        errors.append(f'EQY exited with status {returncode}')
    if not (proof / 'PASS').is_file() or any((proof / s).exists() for s in ('FAIL', 'ERROR', 'UNKNOWN')):
        errors.append('missing or conflicting global EQY verdict')
    interfaces = []
    modules = []
    for side in ('gold', 'gate'):
        data = json.loads((build / f'{side}-interface.json').read_text())
        modules.append(data['modules'][top])
        ports = modules[-1]['ports']
        interfaces.append({name: (port['direction'], len(port['bits'])) for name, port in ports.items()})
    if interfaces[0] != interfaces[1]:
        errors.append('top/SRAM cut-point interfaces differ')
    # Inspect the complete generated partition list rather than counting
    # successful log lines. Missing, failed and unfinished partitions block.
    partitions = []
    covered = {}
    for line in (proof / 'partition.list').read_text().splitlines():
        fields = line.split()
        if len(fields) < 2:
            raise ValueError('invalid partition list')
        name = fields[1]
        if fields[0] != top:
            errors.append('unexpected partition module: ' + fields[0])
        if '/' in name or name in ('.', '..'):
            raise ValueError('invalid partition name')
        try:
            details = json.loads((proof / 'partitions' / (name + '.json')).read_text())['partition']
            if details['name'] != name:
                raise ValueError('partition name mismatch')
            for net, bits in details['outbits'].items():
                if not isinstance(bits, list) or any(type(b) is not int or b < 0 for b in bits):
                    raise ValueError('invalid output bit indices')
                covered.setdefault(net, set()).update(bits)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            errors.append('invalid partition coverage: ' + name + ': ' + str(exc))
        states = {}
        for status in sorted((proof / 'strategies' / name).glob('*/status')):
            words = status.read_text().split()
            states[status.parent.name] = words[0] if words else 'ERROR'
        if 'PASS' not in states.values():
            errors.append('unproven partition: ' + name)
        if any(state not in ('PASS', 'TIMEOUT', 'UNKNOWN') for state in states.values()):
            errors.append('failed, erroneous or invalid strategy verdict: ' + name)
        partitions.append(dict(name=name, strategies=states))
    if not partitions or len({p['name'] for p in partitions}) != len(partitions):
        errors.append('empty or duplicate partition list')
    # A global PASS covers only the obligations EQY generated. Independently
    # require every observable output bit (including exposed SRAM controls)
    # to occur in those obligations, so matching errors cannot hide a port.
    required_bits = 0
    for name, port in modules[0]['ports'].items():
        if port['direction'] != 'output':
            continue
        # EQY records SigBit offsets relative to each wire, not Verilog
        # declaration indices. A split pin named q[7] still has local bit 0,
        # even when Yosys preserves its original offset=7 metadata.
        expected = set(range(len(port['bits'])))
        required_bits += len(expected)
        if expected - covered.get(name, set()):
            errors.append('uncovered boundary output bits: ' + name)
    if required_bits == 0:
        errors.append('no boundary output obligations')
    return dict(status='FAIL' if errors else 'PASS', errors=errors, partitions=partitions,
                required_boundary_output_bits=required_bits,
                interface_port_count=len(interfaces[0]),
                scope='EQY safe-replacement equivalence with formal X propagation and arbitrary SRAM read data. No zero initialization, macro internals, analog IO or physical timing proof.',
                release_eligible=False)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build', type=Path, required=True)
    ap.add_argument('--top', required=True)
    ap.add_argument('--jobs', type=int, default=2)
    ap.add_argument('--partition-timeout', type=int, default=120)
    ap.add_argument('--strategy', choices=STRATEGIES, default='pdr')
    ap.add_argument('--bind-net', action='append', default=[])
    ap.add_argument('--unmatch-net', action='append', default=[])
    ap.add_argument('--state-only', action='store_true')
    args = ap.parse_args()
    if (not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', args.top)
            or args.jobs < 1 or args.partition_timeout < 1):
        ap.error('invalid top, jobs or partition timeout')
    build = args.build.resolve()
    if not re.fullmatch(r'[A-Za-z0-9_./-]+', str(build)):
        ap.error('unsupported build path')
    # Never reuse an existing result or proof directory.
    if (build / 'eqy').exists() or (build / 'eqy-result.json').exists():
        raise ValueError('partitioned proof already exists')
    root = Path.cwd()  # chip.py executes every stage from the chip root.
    make_bin = root / 'build/eda-tools/bin'
    env = dict(os.environ)
    if (make_bin / 'make').is_file():
        env['PATH'] = str(make_bin) + os.pathsep + env['PATH']
    make = shutil.which('make', path=env['PATH'])
    if not make:
        raise ValueError('GNU Make missing; run formal/cec/bootstrap_make.sh on host')
    # Expose only missing helpers from the static BusyBox staged by the
    # host bootstrap, with tool hashes recorded below.
    toolbin = build / 'tool-bin'
    toolbin.mkdir()
    busybox = make_bin / 'busybox'
    for name in ('awk', 'sed'):
        if not shutil.which(name, path=env['PATH']):
            if not busybox.is_file():
                raise ValueError('missing static BusyBox; run bootstrap_make.sh')
            applets = subprocess.check_output([str(busybox), '--list'], text=True).split()
            if name not in applets:
                raise ValueError('BusyBox lacks ' + name)
            (toolbin / name).symlink_to(busybox)
    if not shutil.which('bitwuzla', path=env['PATH']):
        solvers = sorted(Path('/nix/store').glob('*bitwuzla*/bin/bitwuzla'))
        if len(solvers) != 1:
            raise ValueError('Bitwuzla missing; needed to validate counterexamples')
        (toolbin / 'bitwuzla').symlink_to(solvers[0])
    env['PATH'] = str(toolbin) + os.pathsep + env['PATH']
    for side in ('gold', 'gate'):
        script = build / (side + '-normalize.ys')
        script.write_text(normalization(build, args.top, side))
        with (build / (side + '-normalize.log')).open('w') as out:
            subprocess.run(['yosys', '-Q', '-T', '-s', str(script)], env=env,
                           stdout=out, stderr=subprocess.STDOUT, check=True)
    config = build / 'chip.eqy'
    config.write_text(configuration(build, args.top, args.partition_timeout, args.strategy, args.bind_net, args.unmatch_net, args.state_only))
    with (build / 'proof.txt').open('w') as out:
        # Continue independent obligations after a tool error so one failed
        # job does not conceal the rest. Every obligation is still required.
        proc = subprocess.run(['eqy', '-k', '-j', str(args.jobs), '-d', str(build / 'eqy'), str(config)],
                              env=env, stdout=out, stderr=subprocess.STDOUT)
    try:
        result = inspect_proof(build, args.top, proc.returncode)
    except (OSError, ValueError, KeyError, IndexError) as exc:
        result = dict(status='FAIL', errors=[str(exc)], release_eligible=False)
    result['eqy_returncode'] = proc.returncode
    result['jobs'] = args.jobs
    result['partition_timeout_seconds'] = args.partition_timeout
    result['strategy'] = args.strategy
    result['bound_nets'] = sorted(set(args.bind_net))
    result['unmatched_internal_nets'] = sorted(set(args.unmatch_net))
    result['state_only_correspondence'] = args.state_only
    result['make_sha256'] = digest(Path(make))
    result['helper_sha256'] = {name: digest(Path(shutil.which(name, path=env['PATH'])))
                               for name in ('awk', 'sed', 'bitwuzla')}
    result['eqy_version'] = subprocess.check_output(['eqy', '--version'], text=True).strip()
    # Bind every generated partition, strategy, trace and verdict, not only
    # the summary. The external chip runner binds this manifest in turn.
    result['evidence_sha256'] = {str(p.relative_to(build)): digest(p)
                               for p in sorted((build / 'eqy').rglob('*')) if p.is_file()}
    for name in ('chip.eqy', 'proof.txt', 'gold-interface.json', 'gate-interface.json',
                 'gold-normalize.ys', 'gate-normalize.ys', 'gold-normalize.log',
                 'gate-normalize.log', 'gold-normalized.il', 'gate-normalized.il'):
        if (build / name).is_file():
            result['evidence_sha256'][name] = digest(build / name)
    (build / 'eqy-result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Partitioned equivalence: ' + result['status'], flush=True)
    raise SystemExit(0 if result['status'] == 'PASS' else 1)


if __name__ == '__main__':
    main()
