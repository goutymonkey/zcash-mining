#!/usr/bin/env python3
"""Screen SKY130 SRAM address-input slew with pinned Liberty and ideal wires.

Run inside the EDA container with --image-id set to its immutable image ID.
This is a buffer/load sensitivity experiment, not characterization or signoff.
The SRAM tables and electrical limits are never modified.
"""
import argparse
import fnmatch
import json
import math
from pathlib import Path
import re
import shutil
import subprocess

from check_macro_timing import nominal_pvt
from run_inputs import ROOT, digest, resolve_path

MACRO = 'sky130_sram_2kbyte_1rw1r_32x512_8'
BUFFERS = tuple('sky130_fd_sc_hd__' + name for name in (
    'buf_1', 'buf_2', 'buf_4', 'buf_6', 'buf_8', 'buf_12', 'buf_16',
    'clkbuf_1', 'clkbuf_2', 'clkbuf_4', 'clkbuf_8', 'clkbuf_16'))
SLEWS = (0.01, 0.04, 0.13, 0.3)
LOADS = (0.0, 0.005, 0.02, 0.05)
SCOPE = ('TT 1.8 V 25 C ideal-wire buffer screening at one SRAM addr0 input; '
         'real Liberty pin capacitance plus lumped added wire capacitance. '
         'Input slew uses standard-cell thresholds; measured sink slew uses SRAM '
         'thresholds. No routed RC, other pins, SS/FF, SPICE characterization, '
         'power, full-chip timing or release qualification.')


def select_view(mapping, corner):
    matches = [paths for pattern, paths in mapping.items()
               if fnmatch.fnmatchcase(corner, pattern)]
    if len(matches) != 1 or not isinstance(matches[0], list) or len(matches[0]) != 1:
        raise ValueError('screen requires exactly one unambiguous Liberty per library')
    return resolve_path(matches[0][0])


def fixture():
    body = ['module screen(input stimulus, output [%d:0] observable);' % (len(BUFFERS)*64-1)]
    for i, cell in enumerate(BUFFERS):
        body += [f'wire n{i};', f'{cell} drv{i}(.A(stimulus), .X(n{i}));',
                 f'{MACRO} mem{i}(.clk0(stimulus), .clk1(stimulus),',
                 f'.csb0(stimulus), .csb1(stimulus), .web0(stimulus),',
                 f'.wmask0(4\'b0000), .addr0({{8\'b00000000,n{i}}}),',
                 f'.addr1(9\'b000000000), .din0(32\'b0),',
                 f'.dout0(observable[{i*64+31}:{i*64}]),',
                 f'.dout1(observable[{i*64+63}:{i*64+32}]));']
    return '\n'.join(body + ['endmodule', ''])


def script():
    return '''read_liberty cells.lib
read_liberty sram.lib
read_verilog fixture.v
link_design screen
report_units
foreach input_slew {%s} {
    set_input_transition $input_slew [all_inputs]
    foreach wire_cap {%s} {
        for {set i 0} {$i < %d} {incr i} {
            set_load $wire_cap [get_nets n$i]
            puts "ZEQ_CASE $i $input_slew $wire_cap"
            report_check_types -max_slew -net n$i -digits 9
            report_net -digits 9 n$i
        }
    }
}
puts ZEQ_COMPLETE
exit
''' % (' '.join(map(str, SLEWS)), ' '.join(map(str, LOADS)), len(BUFFERS))


def parse_measurements(body):
    # OpenSTA can exit zero after Tcl errors: require explicit completion, every
    # measurement and no diagnostics. Do not turn partial output into a result.
    if re.search(r'^\s*(?:Error|Warning)\b', body, re.MULTILINE):
        raise ValueError('timing tool reported an error or warning')
    if body.splitlines().count('ZEQ_COMPLETE') != 1:
        raise ValueError('missing or duplicate completion marker')
    if not re.search(r'^\s*time 1ns\s*$', body, re.MULTILINE) or not re.search(
            r'^\s*capacitance 1pF\s*$', body, re.MULTILINE):
        raise ValueError('unexpected timing or capacitance units')
    chunks = re.split(r'^ZEQ_CASE (\d+) (\S+) (\S+)\s*$', body, flags=re.MULTILINE)
    expected = {(i, s, c) for i in range(len(BUFFERS)) for s in SLEWS for c in LOADS}
    seen, rows = set(), []
    for j in range(1, len(chunks), 4):
        i, slew, cap = int(chunks[j]), float(chunks[j+1]), float(chunks[j+2])
        key = (i, slew, cap)
        if key not in expected or key in seen:
            raise ValueError('unexpected or duplicate sweep case')
        seen.add(key)
        section = chunks[j+3]
        matches = re.findall(r'^mem' + str(i) + r'/addr0\[0\]\s+(\S+)\s+(\S+)\s+(\S+)\s+\((MET|VIOLATED)\)\s*$',
                             section, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError('missing or ambiguous SRAM sink measurement')
        def net_value(label):
            values = re.findall(r'^\s*' + re.escape(label) + r':\s*(\S+)\s*$',
                                section, re.MULTILINE)
            if len(values) != 1 or not math.isfinite(float(values[0])):
                raise ValueError('missing or invalid net ' + label)
            return float(values[0])
        pin_cap, wire_cap = net_value('Pin capacitance'), net_value('Wire capacitance')
        if (pin_cap <= 0 or not math.isclose(wire_cap, cap, abs_tol=1e-8)
                or not math.isclose(net_value('Total capacitance'), pin_cap+wire_cap, abs_tol=1e-8)
                or net_value('Number of drivers') != 1 or net_value('Number of loads') != 1):
            raise ValueError('sweep load or driver topology mismatch')
        limit, actual, slack = map(float, matches[0][:3])
        verdict = matches[0][3]
        if (not all(math.isfinite(v) for v in (limit, actual, slack)) or limit <= 0 or actual < 0
                or not math.isclose(limit-actual, slack, abs_tol=1e-7, rel_tol=1e-6)
                or (verdict == 'MET') != (slack >= 0)):
            raise ValueError('invalid SRAM slew measurement')
        rows.append(dict(buffer=BUFFERS[i], input_slew_ns=slew, wire_cap_pf=cap,
                         pin_cap_pf=pin_cap,
                         limit_ns=limit, sink_slew_ns=actual, slack_ns=slack,
                         meets_limit=verdict == 'MET'))
    if seen != expected:
        raise ValueError('incomplete sweep')
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--config', type=Path, required=True)
    ap.add_argument('--build', type=Path, required=True)
    ap.add_argument('--image-id', required=True)
    args = ap.parse_args()
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', args.image_id):
        ap.error('supply the inspected immutable EDA image ID')
    build = args.build.resolve()
    build.relative_to(ROOT/'build')
    config = json.loads(args.config.read_text())
    corner = 'nom_tt_025C_1v80'
    sources = dict(cells=select_view(config['LIB'], corner),
                   sram=select_view(config['MACROS'][MACRO]['lib'], corner))
    if any(nominal_pvt(p) != (25, 1.8) for p in sources.values()):
        raise ValueError('screen supports only TT 1.8 V 25 C library selection')
    build.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(args.config, build/'resolved.json')
    for name, path in sources.items():
        if path.suffix != '.lib':
            raise ValueError('screen requires uncompressed Liberty')
        shutil.copyfile(path, build/(name+'.lib'))
    for name in ('screen_sram_slew.py', 'run_inputs.py', 'check_macro_timing.py'):
        shutil.copyfile(ROOT/'pd'/name, build/name)
    (build/'fixture.v').write_text(fixture())
    (build/'screen.tcl').write_text(script())
    files = {p.name: digest(p) for p in build.iterdir() if p.is_file()}
    sta = Path(shutil.which('sta'))
    inputs = dict(scope=SCOPE, image_id=args.image_id, tool_sha256=digest(sta),
                  source_paths={k: str(p) for k,p in sources.items()}, files=files)
    (build/'inputs.json').write_text(json.dumps(inputs, indent=2)+'\n')
    rows, error, code = [], None, None
    try:
        with (build/'screen.log').open('w') as out:
            proc = subprocess.run([str(sta), '-exit', 'screen.tcl'], cwd=build,
                                  stdout=out, stderr=subprocess.STDOUT, timeout=180)
        code = proc.returncode
        if code != 0:
            raise ValueError('timing tool returned nonzero')
        rows = parse_measurements((build/'screen.log').read_text())
        if any(digest(build/name) != sha for name,sha in files.items()):
            raise ValueError('archived input changed')
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        error = str(exc)
    result = dict(status='ERROR' if error else 'MEASURED', release_eligible=False,
                  scope=SCOPE, error=error, exit_code=code, measurements=rows,
                  inputs_sha256=digest(build/'inputs.json'),
                  log_sha256=digest(build/'screen.log'))
    if rows:
        result['meets_limit_count'] = sum(r['meets_limit'] for r in rows)
        result['best_by_load_and_input'] = [min((r for r in rows if
            r['input_slew_ns']==s and r['wire_cap_pf']==c), key=lambda r: r['sink_slew_ns'])
            for s in SLEWS for c in LOADS]
    (build/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print(result['status'], len(rows), 'measurements;', error or SCOPE)
    return error is None


if __name__ == '__main__':
    raise SystemExit(0 if main() else 1)
