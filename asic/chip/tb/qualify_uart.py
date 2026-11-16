#!/usr/bin/env python3
"""Qualify digital UART bytes, clock offsets, malformed frames and reset.

Run inside the pinned EDA container; each build directory must be fresh.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build', type=Path, required=True)
    ap.add_argument('--image-id', required=True)
    args = ap.parse_args()
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', args.image_id):
        ap.error('supply the inspected immutable EDA image ID')
    build = args.build.resolve()
    build.relative_to(ROOT / 'build')
    build.mkdir(parents=True, exist_ok=False)
    files = ('rtl/zeq_uart.v', 'tb/tb_uart_robustness.sv', 'tb/qualify_uart.py')
    for name in files:
        p = build / 'source' / name
        p.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, p)
    inputs = dict(image_id=args.image_id, files={n: sha(build/'source'/n) for n in files},
                  tools={n: sha(Path(shutil.which(n))) for n in ('iverilog', 'vvp')},
                  scope='Digital UART only: DIV 8 and 16, all byte values in back-to-back streams, bit periods -2/0/+2 percent, three start phases, bad stop bits, short glitches, reset in ten RX/TX bit phases. No metastability, pad, physical CDC/RDC, or full-chain proof.')
    (build/'inputs.json').write_text(json.dumps(inputs, indent=2)+'\n')
    cases = []
    variants = [('healthy', None, None),
                ('rx-order-mutant', ('data <= {rx, data[7:1]};', 'data <= {data[6:0], rx};'), 'RX byte mismatch'),
                ('stop-bit-mutant', ('valid <= rx;', "valid <= 1'b1;"), 'unexpected RX delivery'),
                ('rx-reset-mutant', ("st   <= 2'd0;", "case (st) 2'd2: st <= 2'd2; default: st <= 2'd0; endcase"), 'reset=1')]
    for name, mutation, expected_error in variants:
        rtl = build/'source/rtl/zeq_uart.v'
        if mutation:
            body = rtl.read_text()
            old, new = mutation
            if body.count(old) != 1:
                raise ValueError('missing or ambiguous mutation site')
            rtl = build/(name+'.v')
            rtl.write_text(body.replace(old, new))
        for div in (8, 16):
            case = build/f'{name}-div{div}'
            case.mkdir()
            binary = case/'simulation'
            log = case/'simulation.log'
            error = None
            code = None
            try:
                with (case/'compile.log').open('w') as out:
                    subprocess.run(['iverilog', '-g2012', '-s', 'tb_uart_robustness',
                                    f'-Ptb_uart_robustness.DIV={div}', '-o', str(binary),
                                    str(rtl), str(build/'source/tb/tb_uart_robustness.sv')],
                                   stdout=out, stderr=subprocess.STDOUT, check=True, timeout=60)
                with log.open('w') as out:
                    proc = subprocess.run(['vvp', str(binary)], stdout=out, stderr=subprocess.STDOUT, timeout=120)
                    code = proc.returncode
            except (OSError, subprocess.SubprocessError) as exc:
                error = str(exc)
            body = log.read_text() if log.exists() else ''
            marker = f'uart robustness PASS div={div} rx=2314 tx=266 rx_resets=10 tx_resets=10 bad_stops=256 glitches=3'
            passed = error is None and (code != 0 and expected_error in body if mutation else code == 0 and marker in body)
            cases.append(dict(name=name, div=div, status='PASS' if passed else 'FAIL',
                              check='caught injected fault' if mutation else 'UART behavior',
                              error=error, exit_code=code, rtl_sha256=sha(rtl),
                              evidence_sha256={str(p.relative_to(build)): sha(p) for p in case.iterdir() if p.is_file()}))
            print(f'{name} DIV={div}: '+cases[-1]['status'], flush=True)
    unchanged = all(sha(build/'source'/n) == h for n, h in inputs['files'].items())
    result = dict(status='PASS' if unchanged and len(cases)==8 and all(c['status']=='PASS' for c in cases) else 'FAIL',
                  scope=inputs['scope'], cases=cases, archived_inputs_unchanged=unchanged,
                  inputs_sha256=sha(build/'inputs.json'))
    (build/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    return result['status']=='PASS'


if __name__ == '__main__':
    raise SystemExit(0 if main() else 1)
