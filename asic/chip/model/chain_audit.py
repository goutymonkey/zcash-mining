"""Structural checks before independent per-attempt chain solution checking."""
from collections import defaultdict


def validate_packets(packets, nsol, chips, jobs, lanes):
    seen_solutions = defaultdict(set)
    seen_done = set()
    for typ, addr, payload in packets:
        if not 0 <= addr < chips:
            raise ValueError('packet from unknown chip address')
        sizes = {0x81: 4 + 4 * nsol, 0x84: 4, 0x85: 5}
        if typ not in sizes or len(payload) != sizes[typ]:
            raise ValueError('unknown response type or incorrect payload length')
        if typ == 0x84:
            if payload[3] != lanes:
                raise ValueError('PONG lane count mismatch')
            continue
        job, attempt = payload[0], int.from_bytes(payload[1:4], 'little')
        if job not in jobs:
            raise ValueError('packet for unknown job')
        key = job, addr, attempt
        if typ == 0x81:
            if key in seen_done:
                raise ValueError('solution emitted after its DONE')
            solution = bytes(payload[4:])
            if solution in seen_solutions[key]:
                raise ValueError('duplicate solution packet for an attempt')
            seen_solutions[key].add(solution)
        else:
            if key in seen_done:
                raise ValueError('duplicate DONE')
            seen_done.add(key)
