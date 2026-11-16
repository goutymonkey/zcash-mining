"""Audit the complete boundary of a solver proof with table SRAMs exposed.

Reads canonical Yosys RTLIL incrementally. Identical memory contracts plus
proofs of every macro input support composition with arbitrary shared read
data. This check alone is not an equivalence verdict or a macro proof.
"""
import argparse
import json
from pathlib import Path


def read_design(path, scalarized=False):
    ports, memories = {}, {}
    module_seen = False
    module_open = False
    memory = None
    with Path(path).open() as stream:
        for line in stream:
            if line.startswith('module '):
                if module_seen or line.strip() != 'module \\zeq_eh_par':
                    raise ValueError('expected one flat zeq_eh_par module')
                module_seen = True
                module_open = True
            elif line.rstrip() == 'end':
                if not module_open:
                    raise ValueError('unexpected module end')
                module_open = False
            elif line.startswith('  wire '):
                tokens = line.split()[1:]
                kinds = [v for v in tokens[:-1] if v in ('input', 'output', 'inout')]
                if not kinds:
                    continue
                if len(kinds) != 1:
                    raise ValueError('ambiguous port direction')
                width = int(tokens[tokens.index('width') + 1]) if 'width' in tokens[:-1] else 1
                name = tokens[-1].lstrip('\\')
                offset = int(tokens[tokens.index('offset') + 1]) if 'offset' in tokens[:-1] else 0
                # splitnets retains a bit's original index as scalar metadata.
                # Accept that only when it agrees with the exact bit name.
                valid_offset = (scalarized and width == 1 and offset > 0
                                and name.endswith(f'[{offset}]'))
                if 'upto' in tokens[:-1] or (offset != 0 and not valid_offset):
                    raise ValueError('unsupported solver boundary indexing')
                if scalarized and width != 1:
                    raise ValueError('scalar proof boundary contains a bus')
                if width < 1 or name in ports:
                    raise ValueError('invalid or duplicate port')
                ports[name] = (kinds[0], width)
            elif line.startswith('  cell '):
                _, kind, name = line.strip().split(' ', 2)
                memory = None
                if kind == '$mem_v2':
                    name = name.lstrip('\\')
                    if name in memories:
                        raise ValueError('duplicate memory identity')
                    memory = {'parameters': {}, 'connections': set()}
                    memories[name] = memory
            elif memory is not None and line.startswith('    parameter '):
                fields = line.strip().split(' ', 2)
                name, value = fields[1].lstrip('\\'), fields[2]
                if name in memory['parameters']:
                    raise ValueError('duplicate memory parameter')
                memory['parameters'][name] = value
            elif memory is not None and line.startswith('    connect '):
                name = line.strip().split(' ', 2)[1].lstrip('\\')
                if name in memory['connections']:
                    raise ValueError('duplicate memory connection')
                memory['connections'].add(name)
            elif line.rstrip() == '  end':
                memory = None
    if not module_seen or module_open or not ports:
        raise ValueError('missing solver module or ports')
    return ports, memories


def table_memories(memories):
    return {name: memory for name, memory in memories.items()
            if '.m_' in name and name.endswith('.mem')}


def expected_boundary(ports, memories):
    result = dict(ports)
    for name, memory in memories.items():
        params = memory['parameters']
        # This solver's table interface is one write and one registered read.
        if params.get('RD_PORTS') != '1' or params.get('WR_PORTS') != '1':
            raise ValueError('unsupported table port count: ' + name)
        width, address = int(params['WIDTH']), int(params['ABITS'])
        if width < 1 or address < 1:
            raise ValueError('invalid table widths')
        sizes = dict(RD_ADDR=address, RD_ARST=1, RD_CLK=1, RD_DATA=width,
                     RD_EN=1, RD_SRST=1, WR_ADDR=address, WR_CLK=1,
                     WR_DATA=width, WR_EN=width)
        if memory['connections'] != set(sizes):
            raise ValueError('missing or unsupported memory ports: ' + name)
        for port, bits in sizes.items():
            exposed = name + '.' + port
            if exposed in result:
                raise ValueError('SRAM boundary name collides with a top port')
            result[exposed] = ('input' if port == 'RD_DATA' else 'output', bits)
    return result


def scalar_boundary(ports):
    """Exact zero-based scalar expansion used by Yosys splitnets -ports."""
    result = {}
    for name, (direction, width) in ports.items():
        for index in range(width):
            scalar = name if width == 1 else f'{name}[{index}]'
            if scalar in result:
                raise ValueError('scalar boundary name collision: ' + scalar)
            result[scalar] = (direction, 1)
    return result


def audit(gold_raw, gate_raw, gold_normalized, gate_normalized, expected_memories,
          scalarized=False):
    if type(expected_memories) is not int or expected_memories < 1:
        raise ValueError('a positive expected table count is required')
    gold_ports, gold_all = read_design(gold_raw)
    gate_ports, gate_all = read_design(gate_raw)
    gold, gate = table_memories(gold_all), table_memories(gate_all)
    if gold_ports != gate_ports:
        raise ValueError('raw top interfaces differ')
    if len(gold) != expected_memories or gold != gate:
        raise ValueError('table memory identities or behavioral contracts differ')
    if gate_all != gate:
        raise ValueError('generic netlist contains non-table memories')
    expected = expected_boundary(gold_ports, gold)
    logical_ports = len(expected)
    if scalarized:
        expected = scalar_boundary(expected)
    for path in (gold_normalized, gate_normalized):
        ports, memories = read_design(path, scalarized=scalarized)
        if memories or ports != expected:
            raise ValueError('normalized proof omits or changes a top/SRAM boundary')
    return dict(status='PASS', table_memories=len(gold),
                original_top_ports=len(gold_ports), proof_ports=len(expected),
                logical_boundary_ports=logical_ports, scalarized=scalarized,
                scope='Boundary coverage and unchanged logical SRAM contracts only; equivalence remains a separate gate.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('gold-raw', 'gate-raw', 'gold-normalized', 'gate-normalized'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--expected-memories', type=int, required=True)
    parser.add_argument('--scalarized', action='store_true')
    args = parser.parse_args()
    try:
        result = audit(args.gold_raw, args.gate_raw, args.gold_normalized,
                       args.gate_normalized, args.expected_memories, args.scalarized)
    except (OSError, KeyError, ValueError) as exc:
        print(json.dumps(dict(status='FAIL', reason=str(exc))))
        return False
    print(json.dumps(result, indent=2))
    return True


if __name__ == '__main__':
    raise SystemExit(0 if main() else 1)
