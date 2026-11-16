#!/usr/bin/env python3
"""Reject missing, incomplete or failing post-route timing evidence."""
import json
import math
from pathlib import Path
import re
import sys


def report_slack(path, corner, kind):
    """Read the corner-specific worst slack, not inherited flow metrics."""
    body = path.read_text()
    if f'Worst Slack ({kind.title()})' not in body:
        raise ValueError('missing worst-slack heading')
    entries = re.findall(r'^' + re.escape(corner) + r':\s*(\S+)\s*$', body, re.MULTILINE)
    if len(entries) != 1:
        raise ValueError('missing or duplicate corner slack')
    value = float(entries[0])
    if not math.isfinite(value) or value < 0:
        raise ValueError(f'report slack is nonfinite or negative ({value})')
    return value


def validate(run):
    run = Path(run)
    steps = sorted(run.glob('*-openroad-stapostpnr'), key=lambda p: int(p.name.split('-')[0]))
    if not steps:
        return ['no post-route STA step']
    step = steps[-1]
    try:
        config = json.loads((step / 'config.json').read_text())
        metrics = json.loads((run / 'final/metrics.json').read_text())
        corners = config['STA_CORNERS']
        if (not isinstance(corners, list) or not corners
                or any(not isinstance(c, str) or not c or '/' in c or c in ('.', '..') for c in corners)
                or len(set(corners)) != len(corners)):
            raise ValueError('STA_CORNERS must contain unique corner names')
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return [f'missing/invalid STA configuration or metrics: {exc}']
    errors = []
    for corner in corners:
        report = step / corner / 'checks.rpt'
        try:
            body = report.read_text()
        except OSError:
            errors.append(f'{corner}: missing checks.rpt')
            continue
        if 'report_checks' not in body or 'report_check_types -max_slew -max_cap -max_fanout -violators' not in body:
            errors.append(f'{corner}: incomplete timing/electrical report')
        for kind in ('setup', 'hold'):
            value = metrics.get(f'timing__{kind}__ws__corner:{corner}')
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                errors.append(f'{corner}: {kind} slack missing, nonfinite or negative ({value})')
            try:
                suffix = 'max' if kind == 'setup' else 'min'
                measured = report_slack(step / corner / f'ws.{suffix}.rpt', corner, kind)
                # JSON metrics may be rounded to six significant digits.
                if (isinstance(value, bool) or not isinstance(value, (int, float))
                        or not math.isclose(value, measured, rel_tol=1e-5, abs_tol=1e-9)):
                    errors.append(f'{corner}: {kind} metric/report mismatch ({value}, {measured})')
            except (OSError, ValueError) as exc:
                errors.append(f'{corner}: {kind} worst-slack report invalid: {exc}')
    return errors


if __name__ == '__main__':
    failures = validate(sys.argv[1])
    for failure in failures:
        print(f'BAD STA evidence: {failure}')
    if not failures:
        print('OK post-route reports and setup/hold metrics at every configured corner')
    sys.exit(bool(failures))
