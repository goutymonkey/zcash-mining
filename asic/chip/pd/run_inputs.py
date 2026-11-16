"""Resolve a physical run's RTL against an explicitly supplied source archive.

Never substitute today's default config or infer source identity from mtimes.
Container /work paths are mapped to the chip directory for host-side checks.
"""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def equivalence_proved(body):
    # ABC dprove uses a distinct verdict for combinational miters.
    return bool(re.search(r'^(?:Networks are equivalent\b|UNSATISFIABLE\s+Time\s*=)',
                          body, re.MULTILINE))


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def check_release_sources(inputs, root=ROOT):
    """Reject exact known-bad RTL even if a run was copied or its marker lost.

    This is a defect registry, not an allowlist or substitute for verification.
    Return its checked digest so the release bundle can bind the same policy.
    """
    path = Path(root) / 'production/blocked_sources.json'
    body = path.read_bytes()
    registry = json.loads(body)
    if registry.get('schema') != 1 or not isinstance(registry.get('entries'), list):
        raise ValueError('invalid blocked-source registry')
    blocked = {}
    for entry in registry['entries']:
        sha = entry.get('sha256')
        reason = entry.get('reason')
        if (not isinstance(sha, str) or not re.fullmatch('[0-9a-f]{64}', sha)
                or sha in blocked or not isinstance(reason, str) or not reason.strip()):
            raise ValueError('invalid or duplicate blocked-source entry')
        blocked[sha] = reason
    for source in inputs['sources']:
        sha = inputs['archived'][source]
        if sha in blocked:
            raise ValueError('known defective release source: ' + source.name + ': ' + blocked[sha])
    return path, hashlib.sha256(body).hexdigest()


def contained(path, root):
    path = Path(path).resolve()
    path.relative_to(Path(root).resolve())
    return path


def resolve_path(value, root=ROOT, config_dir=None):
    if not isinstance(value, str):
        raise ValueError('expected a source path')
    if value.startswith('/work/'):
        path = Path(root) / value[6:]
    elif value.startswith('dir::') and config_dir:
        path = Path(config_dir) / value[5:]
    elif Path(value).is_absolute():
        path = Path(value)
    else:
        raise ValueError('unresolved run path: ' + value)
    return contained(path, root)


def verified_inputs(run, manifest_path, root=ROOT):
    root = Path(root).resolve()
    run = contained(run, root)
    manifest_path = contained(manifest_path, root)
    manifest = json.loads(manifest_path.read_text())
    files = manifest['files']
    if not isinstance(files, dict) or not files:
        raise ValueError('source manifest has no files')
    archived = {}
    for name, expected in files.items():
        path = contained(manifest_path.parent / name, manifest_path.parent)
        if digest(path) != expected:
            raise ValueError('source archive hash mismatch: ' + name)
        archived[path] = expected
    config_path = manifest_path.parent / 'config.json'
    if config_path not in archived:
        raise ValueError('source manifest must bind config.json')
    original = json.loads(config_path.read_text())
    resolved_path = run / 'resolved.json'
    resolved = json.loads(resolved_path.read_text())
    if resolved['DESIGN_NAME'] != original['DESIGN_NAME']:
        raise ValueError('run top differs from archived config')
    sources = [resolve_path(p, root) for p in resolved['VERILOG_FILES']]
    intended = [resolve_path(p, root, run.parent.parent) for p in original['VERILOG_FILES']]
    if sources != intended or not sources or len(set(sources)) != len(sources):
        raise ValueError('run source list/order differs from archived config')
    for path in sources:
        if path not in archived:
            raise ValueError('RTL is not bound by source manifest: ' + str(path))
    constraints = []
    for name in ('PNR_SDC_FILE', 'SIGNOFF_SDC_FILE'):
        path = resolve_path(resolved[name], root)
        if path != resolve_path(original[name], root, run.parent.parent) or path not in archived:
            raise ValueError('unbound or changed constraint: ' + name)
        constraints.append(path)
    # Do not silently run equivalence under a different elaboration contract.
    for name in ('VERILOG_DEFINES', 'SYNTH_PARAMETERS'):
        if (resolved.get(name) or []) != (original.get(name) or []):
            raise ValueError('run elaboration differs from archive: ' + name)
    return dict(run=run, manifest=manifest_path, manifest_sha256=digest(manifest_path),
                resolved=resolved, resolved_path=resolved_path, sources=sources,
                constraints=constraints, archived=archived)
