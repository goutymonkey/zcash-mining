"""Process-independent inventory of the implemented mainnet solver.

Counts logical RAM bits and crossbar payload; excludes macro rounding,
registers, redundancy/ECC, PDN, clock trees, IO and physical routing.
Does not infer power, area, yield, or attainable frequency without a PDK.
"""
import argparse
import json


def network_inventory(pb, payload_bits):
    """Structural mux/register counts; excludes arbitration logic and wires."""
    if pb < 2 or payload_bits < 1:
        raise ValueError('staged fabric needs PB >= 2 and positive payload width')
    p=1 << pb; sb=pb//2; gb=pb-sb; s=1 << sb; g=1 << gb
    flat=p*(p-1)
    staged=g*g*(s-1)+p*(g-1)
    return {
        'ports':p,'payload_bits':payload_bits,'source_group_size':s,'groups':g,
        'flat_payload_mux_2to1_bits':flat*payload_bits,
        'staged_payload_mux_2to1_bits':staged*payload_bits,
        'staged_elastic_links':g*g,
        'staged_link_state_bits':g*g*(payload_bits+sb+1),
        'flat_round_robin_state_bits':p*pb,
        'staged_round_robin_state_bits':g*g*sb+p*gb,
        'status':'structural counts only; arbitration logic, mapping, routing, frequency and power are uncharacterized',
    }


def inventory(n=200, k=9, bb=12, pb=9, sb=10, compact=False, capacity=None, split_keys=False, packed=False, bucket0_capacity=None):
    if n % (k + 1) or not 1 <= pb < bb < n // (k + 1) or sb < 1:
        raise ValueError('require integral collision width and 1 <= PB < BB < CB')
    cb, p, buckets, slots = n // (k + 1), 1 << pb, 1 << bb, 1 << sb
    if capacity is not None:
        if not 1 <= capacity <= slots:
            raise ValueError('capacity must fit slot bits')
        slots = capacity
    bucket0 = slots if bucket0_capacity is None else bucket0_capacity
    if not slots <= bucket0 <= (1 << sb):
        raise ValueError('bucket-zero capacity must cover regular capacity and fit slot bits')
    extra = bucket0 - slots
    lb, iw, pw = cb - bb, cb + 1, bb + 2 * sb
    vw = n - cb if compact else n
    rows = buckets * slots + extra
    tables = {
        'values_and_keys': 2 * rows * (vw + lb),
        'parents': (k - 1) * rows * pw,
        'leaf_indices': rows * iw,
        'histograms': 2 * (1 << cb) * (sb + 1),
        'orders': (p * slots + extra) * sb,
    }
    if packed and not (compact and split_keys):
        raise ValueError('packed tables require compact values and separate keys')
    slices = max((n-(level+1)*cb+pw-1)//pw + (level+1)//2 for level in range(k))
    if packed:
        del tables['values_and_keys']
        del tables['parents']
        tables['packed_values_and_parents'] = 2*rows*slices*pw
        tables['keys'] = 2*rows*lb
    bpe = buckets // p
    shapes = [
        dict(name='value', count=2*p, depth=bpe*slots, width=vw if split_keys else vw+lb),
        dict(name='parents', count=p, depth=(k-1)*bpe*slots, width=pw),
        dict(name='leaf_indices', count=p, depth=bpe*slots, width=iw),
        dict(name='histogram', count=2*p, depth=(1 << cb)//p, width=sb+1),
        dict(name='order', count=p, depth=slots, width=sb),
    ]
    if packed:
        shapes = [dict(name='packed_values_and_parents', count=2*p*slices, depth=bpe*slots, width=pw)] + [s for s in shapes if s['name'] not in ('value', 'parents')]
    if split_keys:
        shapes.append(dict(name='key', count=2*p, depth=bpe*slots, width=lb))
    if extra:
        expanded = []
        for shape in shapes:
            if shape['name'] == 'histogram':
                expanded.append(shape)
                continue
            copies = shape['count'] // p
            stride = k - 1 if shape['name'] == 'parents' else 1
            expanded.extend([
                dict(shape, count=copies*(p-1)),
                dict(shape, count=copies, depth=shape['depth']+stride*extra),
            ])
        shapes = expanded
    assert sum(s['count']*s['depth']*s['width'] for s in shapes) == sum(tables.values())
    return {
        'logical_memory_shapes': shapes,
        'parameters': dict(n=n, k=k, bb=bb, pb=pb, sb=sb, compact=compact, capacity=slots, bucket0_capacity=bucket0, split_keys=split_keys, packed=packed),
        'engines': p, 'buckets': buckets, 'slots_per_bucket': slots,
        'ram_bits_by_table': tables, 'ram_bits': sum(tables.values()),
        'ram_MB_decimal': sum(tables.values()) / 8e6,
        'crossbar_row_payload_bits': vw + bb + lb + max(pw, iw),
        'crossbar_source_destination_pairs': p * p,
        'status': 'logical RTL inventory; no physical PPA or competitive claim',
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--engines-log2', type=int, default=9)
    ap.add_argument('--bucket-bits', type=int, default=12)
    ap.add_argument('--slot-bits', type=int, default=10)
    ap.add_argument('--capacity', type=int, default=640)
    ap.add_argument('--bucket0-capacity', type=int)
    a = ap.parse_args()
    old = inventory(pb=a.engines_log2, bb=a.bucket_bits, sb=a.slot_bits)
    new = inventory(pb=a.engines_log2, bb=a.bucket_bits, sb=a.slot_bits, compact=True, capacity=a.capacity, split_keys=True, bucket0_capacity=a.bucket0_capacity)
    packed = inventory(pb=a.engines_log2, bb=a.bucket_bits, sb=a.slot_bits, compact=True, capacity=a.capacity, split_keys=True, packed=True, bucket0_capacity=a.bucket0_capacity)
    print(json.dumps({'baseline': old, 'compact': new, 'packed_candidate': packed,
        'network_candidate':network_inventory(a.engines_log2,packed['crossbar_row_payload_bits']) if a.engines_log2>=2 else None,
        'packed_incremental_saved_MB': new['ram_MB_decimal']-packed['ram_MB_decimal'],
        'saved_ram_MB_decimal': (old['ram_bits'] - new['ram_bits']) / 8e6,
        'saved_payload_percent': 100 * (1 - new['crossbar_row_payload_bits'] /
                                       old['crossbar_row_payload_bits'])}, indent=2))


if __name__ == '__main__':
    main()
