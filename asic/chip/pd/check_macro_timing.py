#!/usr/bin/env python3
"""Check SKY130 macro Liberty coverage against each required PVT corner.

Standard-cell corner names do not establish SRAM corner coverage. Nominal
voltage/temperature are checked from Liberty bytes. Process characterization
requires independently reviewed library hashes in the release policy; numeric
Liberty nom_process alone cannot distinguish foundry TT/SS/FF conventions.
"""
import fnmatch
import gzip
import json
import math
from pathlib import Path
import re

from run_inputs import ROOT, digest, resolve_path


def corner_pvt(corner):
    m = re.fullmatch(r'(?:min|nom|max)_(tt|ss|ff)_(n?\d+)C_(\d+)v(\d+)', corner)
    if not m:
        raise ValueError('unsupported SKY130 PVT corner: ' + corner)
    return (m[1], float(m[2].replace('n', '-')), float(m[3] + '.' + m[4]))


def nominal_pvt(path):
    data = gzip.decompress(path.read_bytes()) if path.suffix == '.gz' else path.read_bytes()
    body = re.sub(r'/\*.*?\*/|//[^\n]*', '', data.decode(), flags=re.DOTALL)
    values = []
    for name in ('nom_temperature', 'nom_voltage'):
        matches = re.findall(r'\b' + name + r'\s*:\s*([^;]+);', body)
        if len(matches) != 1:
            raise ValueError('missing/ambiguous Liberty ' + name)
        value = float(matches[0])
        if not math.isfinite(value):
            raise ValueError('nonfinite Liberty ' + name)
        values.append(value)
    return tuple(values)


def check_config(config, policy, root=ROOT):
    errors, evidence = [], {}
    macros = config.get('MACROS') or {}
    if not isinstance(macros, dict):
        return ['invalid MACROS configuration'], evidence
    qualified = policy.get('macro_timing_views', {})
    if not isinstance(qualified, dict):
        return ['invalid macro_timing_views policy'], evidence
    for macro, views in macros.items():
        if not isinstance(views, dict) or not isinstance(views.get('lib'), dict):
            errors.append(f'{macro}: missing macro Liberty mapping')
            continue
        for corner in policy['required_corners']:
            try:
                process, temperature, voltage = corner_pvt(corner)
                matches = [paths for pattern, paths in views['lib'].items()
                           if fnmatch.fnmatchcase(corner, pattern)]
                if len(matches) != 1 or not isinstance(matches[0], list) or not matches[0]:
                    raise ValueError('missing/ambiguous macro Liberty selection')
                paths = [resolve_path(p, root) for p in matches[0]]
                if len(set(paths)) != len(paths):
                    raise ValueError('duplicate macro Liberty file')
                hashes = []
                for path in paths:
                    temp, volts = nominal_pvt(path)
                    if not math.isclose(temp, temperature, abs_tol=1e-9) or not math.isclose(volts, voltage, abs_tol=1e-9):
                        raise ValueError(f'Liberty PVT mismatch: {path.name} has {temp:g} C/{volts:g} V; '
                                         f'corner requires {temperature:g} C/{voltage:g} V')
                    hashes.append(digest(path))
                    evidence[path] = hashes[-1]
                approval = qualified.get(macro, {}).get(corner, {})
                if (approval.get('process') != process or approval.get('temperature_c') != temperature
                        or approval.get('voltage_v') != voltage
                        or approval.get('sha256') != hashes):
                    raise ValueError('no matching reviewed macro characterization hashes/PVT in release policy')
            except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
                errors.append(f'{macro}/{corner}: {exc}')
    return errors, evidence


def validate(run, policy, root=ROOT):
    run = Path(run)
    try:
        resolved = json.loads((run / 'resolved.json').read_text())
        steps = sorted(run.glob('*-openroad-stapostpnr'), key=lambda p: int(p.name.split('-')[0]))
        if not steps:
            return ['no final STA configuration for macro timing qualification'], {}
        final = json.loads((steps[-1] / 'config.json').read_text())
        if (final.get('MACROS') or {}) != (resolved.get('MACROS') or {}):
            return ['final STA macro views differ from resolved physical configuration'], {}
        return check_config(final, policy, root)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return [f'invalid macro timing evidence: {exc}'], {}
