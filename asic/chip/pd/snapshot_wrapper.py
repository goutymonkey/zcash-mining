#!/usr/bin/env python3
"""Freeze the current SKY130 wrapper sources and verification inputs.

The destination config stays in pd/wrapper, where dir:: paths are resolved.
Fresh paths are mandatory. This freezes inputs; it does not qualify release.
"""
import argparse
import json
from pathlib import Path
import re

from run_inputs import ROOT, contained, digest, resolve_path


def snapshot(tag):
    if not re.fullmatch('[a-z0-9][a-z0-9_-]*', tag):
        raise ValueError('tag must contain only lowercase letters, digits, - or _')
    wrapper = ROOT / 'pd/wrapper'
    archive = ROOT / f'build/plan-{tag}-source'
    destination = wrapper / f'config-{tag}.json'
    if archive.exists() or destination.exists():
        raise ValueError('snapshot or config already exists; choose a fresh tag')
    base = wrapper / 'config.json'
    config = json.loads(base.read_text())
    files = {}
    for path in sorted((ROOT / 'rtl').rglob('*.v')):
        files[str(path.relative_to(ROOT))] = path.read_bytes()
    for path in sorted((wrapper / 'src').iterdir()):
        if path.is_file():
            files['wrapper-src/' + path.name] = path.read_bytes()
    for path in sorted((ROOT / 'model').glob('*.py')):
        files[str(path.relative_to(ROOT))] = path.read_bytes()
    for name in ('tb/tb_chain.sv', 'tb/sky130_sram_model.v', 'tb/qualify_wrapper.py',
                 'pd/snapshot_wrapper.py'):
        files[name] = (ROOT / name).read_bytes()

    def archived_path(value):
        source = resolve_path(value, ROOT, wrapper)
        if ROOT / 'rtl' in source.parents:
            name = str(source.relative_to(ROOT))
        else:
            name = 'wrapper-src/' + str(contained(source, wrapper / 'src').relative_to(wrapper / 'src'))
        if name not in files:
            raise ValueError('source not copied: ' + name)
        return f'dir::../../build/plan-{tag}-source/' + name

    config['VERILOG_FILES'] = [archived_path(p) for p in config['VERILOG_FILES']]
    for key in ('PNR_SDC_FILE', 'SIGNOFF_SDC_FILE', 'FP_DEF_TEMPLATE'):
        config[key] = archived_path(config[key])
    config_bytes = (json.dumps(config, indent=2) + '\n').encode()
    files['config.json'] = config_bytes
    archive.mkdir(parents=True)
    for name, body in files.items():
        path = archive / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(body)
    manifest = dict(schema=1, scope='SKY130 demonstrator input snapshot; not release qualification',
                    base_config_sha256=digest(base),
                    files={name: digest(archive / name) for name in sorted(files)})
    (archive / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    with destination.open('xb') as out:
        out.write(config_bytes)
    return dict(source_manifest=str((archive / 'manifest.json').relative_to(ROOT)),
                config=str(destination.relative_to(ROOT)),
                source_manifest_sha256=digest(archive / 'manifest.json'),
                config_sha256=digest(destination), files=len(files))


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('tag')
    args = ap.parse_args()
    print(json.dumps(snapshot(args.tag), indent=2))
