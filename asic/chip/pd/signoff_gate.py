#!/usr/bin/env python3
"""Fail-closed SKY130 release gate. A pass is not production N7 signoff.

Waivers are exact pin/corner/check entries bound to a SHA256 of the reviewed
report. They require a numerical bound and an existing justification file.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys
from check_sta_evidence import validate as validate_sta
from check_macro_timing import validate as validate_macros
from run_inputs import ROOT

ZERO_METRICS = (
    'magic__drc_error__count', 'klayout__drc_error__count',
    'design__lvs_error__count', 'antenna__violating__nets',
    'design__xor_difference__count', 'route__drc_errors',
)
KINDS = ('slew', 'cap', 'fanout')
HEADINGS = {'max slew': 'slew', 'max capacitance': 'cap', 'max fanout': 'fanout'}


def finite(value):
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value)


def electrical_report(body):
    active, kind = False, None
    rows = []
    totals = {}
    for line in body.splitlines():
        stripped = line.strip()
        match = re.fullmatch(r'max (slew|cap|fanout) violation count (\d+)', stripped)
        if match:
            if match[1] in totals:
                raise ValueError('duplicate electrical summary')
            totals[match[1]] = int(match[2])
        if stripped.startswith('report_check_types '):
            active = True
            kind = None
        elif stripped.startswith('report_'):
            active = False
            kind = None
        if active and stripped in HEADINGS:
            kind = HEADINGS[stripped]
        elif active and 'VIOLATED' in stripped:
            if kind is None:
                raise ValueError('violation outside a recognized electrical section')
            parts = stripped.split()
            try:
                limit, actual = float(parts[1]), float(parts[2])
            except (IndexError, ValueError):
                raise ValueError('unparseable electrical violation')
            if not finite(limit) or not finite(actual) or actual <= limit:
                raise ValueError('invalid electrical violation values')
            rows.append((kind, parts[0], actual))
    for check in KINDS:
        if check not in totals or totals[check] != sum(row[0] == check for row in rows):
            raise ValueError(f'{check}: missing summary or violation count mismatch')
    return rows, totals


def validate(run, policy_path, root=ROOT):
    run, policy_path = Path(run), Path(policy_path)
    errors = validate_sta(run)
    if (run / 'RELEASE_BLOCKED.json').exists():
        errors.append('run has a known release blocker; see RELEASE_BLOCKED.json')
    try:
        metrics = json.loads((run / 'final/metrics.json').read_text())
        policy = json.loads(policy_path.read_text())
        corners = policy['required_corners']
        ir_limit = policy['max_ir_drop_v']
        if not isinstance(corners, list) or not corners or any(not isinstance(c, str) for c in corners) or len(set(corners)) != len(corners):
            raise ValueError('required_corners must be nonempty and unique')
        if not finite(ir_limit) or ir_limit <= 0:
            raise ValueError('invalid IR-drop budget')
        waivers = policy.get('waivers', [])
        if not isinstance(waivers, list):
            raise ValueError('waivers must be a list')
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return errors + [f'missing/invalid release policy or metrics: {exc}']
    macro_errors, _ = validate_macros(run, policy, root)
    errors.extend(macro_errors)
    for name in ZERO_METRICS:
        if not finite(metrics.get(name)) or metrics[name] != 0:
            errors.append(f'{name}: expected zero, got {metrics.get(name)}')
    drop = metrics.get('ir__drop__worst')
    if not finite(drop) or not 0 <= drop <= ir_limit:
        errors.append(f'IR drop {drop} outside [0, {ir_limit}] V')
    steps = sorted(run.glob('*-openroad-stapostpnr'), key=lambda p: int(p.name.split('-')[0]))
    if not steps:
        return errors
    step = steps[-1]
    try:
        configured = json.loads((step / 'config.json').read_text())['STA_CORNERS']
        if set(configured) != set(corners):
            errors.append('STA corners do not match the release policy')
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return errors + [f'invalid final STA configuration: {exc}']
    approved = {}
    for w in waivers:
        try:
            key = (w['corner'], w['check'], w['pin'])
            bound = w['max_actual']
            digest = w['report_sha256']
            justification = policy_path.parent / w['justification_file']
            if (key in approved or key[0] not in corners or key[1] not in KINDS
                    or not isinstance(key[2], str) or not key[2]
                    or not finite(bound) or bound <= 0
                    or not re.fullmatch('[0-9a-f]{64}', digest)
                    or not justification.is_file() or not justification.read_text().strip()):
                raise ValueError('duplicate, malformed or unsupported waiver')
            approved[key] = w
        except (KeyError, TypeError, ValueError, OSError) as exc:
            errors.append(f'invalid waiver: {exc}')
    used = set()
    for corner in corners:
        try:
            data = (step / corner / 'checks.rpt').read_bytes()
            rows, totals = electrical_report(data.decode())
            digest = hashlib.sha256(data).hexdigest()
        except (OSError, UnicodeError, ValueError) as exc:
            errors.append(f'{corner}: {exc}')
            continue
        for kind, count in totals.items():
            value = metrics.get(f'design__max_{kind}_violation__count__corner:{corner}')
            if not finite(value) or value != count:
                errors.append(f'{corner}: {kind} metric/report mismatch ({value}, {count})')
        for kind, pin, actual in rows:
            key = (corner, kind, pin)
            w = approved.get(key)
            if w is None or w['report_sha256'] != digest or actual > w['max_actual']:
                errors.append(f'{corner}: unwaived {kind} at {pin}: {actual}')
            else:
                used.add(key)
    for key in approved.keys() - used:
        errors.append(f'unused or stale waiver: {key}')
    return errors


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('run')
    ap.add_argument('--policy', required=True)
    args = ap.parse_args()
    failures = validate(args.run, args.policy)
    for failure in failures:
        print('BAD ' + failure)
    print('SIGNOFF GATE: ' + ('FAIL' if failures else 'PASS'))
    sys.exit(bool(failures))
