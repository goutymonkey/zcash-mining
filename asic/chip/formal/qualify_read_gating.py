#!/usr/bin/env python3
"""Prove the local read contract and map/verify the extracted read-enable cone.

This is deliberately scoped: no full-solver equivalence, routed timing, SRAM
energy or production PDK claim. The temporal model abstracts addresses/data,
upstream valid traffic and stalls; useful reads must see identical samples.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def extract(text):
    match = re.search(r'wire\s+vrd\s*=\s*([^;]+);', text)
    if not match:
        raise ValueError('missing RTL read enable')
    candidate = match[1]
    expected = 'GROUP_REPLAY != 0 ? replay_order_pending : (es == E_WK) && !hold_c && vb'
    if ' '.join(candidate.split()) != expected:
        raise ValueError('read-enable expression changed; review the contract')
    # Fail closed if the validity pipeline or consumer changes.
    for fragment in ('E_WK = 9;', 'vc   <= vb;', 'vb   <= va;', 'if (!hold_c) begin',
                     'if (vc && !hold_c) begin',
                     "va <= 1'b0; vb <= 1'b0; vc <= 1'b0;"):
        if fragment not in text:
            raise ValueError('walker contract changed: ' + fragment)
    return candidate.replace(' && vb', ''), candidate


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--rtl', type=Path, default=Path('rtl/zeq_eh_par.v'))
    ap.add_argument('--build', type=Path, required=True)
    ap.add_argument('--yosys', default='yosys')
    ap.add_argument('--mapping-yosys', help='optional separate native Yosys for ABC mapping')
    ap.add_argument('--abc', help='optional ABC executable for mapping')
    ap.add_argument('--liberty', type=Path, required=True)
    a = ap.parse_args()
    a.build.mkdir(parents=True, exist_ok=False)
    b = a.build.resolve()
    shutil.copyfile(a.rtl, b/'zeq_eh_par.v')
    shutil.copyfile(a.liberty, b/'cells.lib')
    shutil.copyfile(Path(__file__).with_name('read_gating.sv'), b/'contract.sv')
    shutil.copyfile(__file__, b/'runner.py')
    old, new = extract((b/'zeq_eh_par.v').read_text())
    (b/'read_expressions.vh').write_text(f'assign reference_read = {old};\nassign candidate_read = {new};\n')
    result = dict(status='FAIL', scope=__doc__.strip(), checks={})
    def run(name, script, expect_failure=False, mapping=False):
        (b/(name+'.ys')).write_text(script+'\n')
        p = subprocess.run([(a.mapping_yosys or a.yosys) if mapping else a.yosys, '-Q', '-T', '-s', name+'.ys'], cwd=b,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=180)
        (b/(name+'.log')).write_text(p.stdout)
        if expect_failure:
            if (p.returncode == 0 or 'model found for base case: FAIL' not in p.stdout
                    or not (b/(name+'-counterexample.json')).exists()):
                raise ValueError('mutant did not produce a counterexample: '+name)
        elif p.returncode:
            raise ValueError('check failed: '+name)
        result['checks'][name] = 'COUNTEREXAMPLE' if expect_failure else 'PASS'
        return p.stdout
    try:
        result['yosys_version'] = subprocess.check_output([a.yosys,'-V'],text=True).strip()
        for mutant in (0,1,2):
            run('contract'+str(mutant), f'''
read_verilog -formal -sv contract.sv
chparam -set MUTANT {mutant} read_gating_contract
prep -top read_gating_contract -flatten
async2sync; chformal -lower
sat -tempinduct -seq 2 -maxsteps 8 -prove-asserts -verify -dump_json contract{mutant}-counterexample.json
''', expect_failure=bool(mutant))
        result['mapping_yosys_version'] = subprocess.check_output([a.mapping_yosys or a.yosys,'-V'],text=True).strip()
        result['mapping'] = {}
        abc_exe = ('-exe '+a.abc) if a.abc else ''
        for label, expression in (('baseline',old),('candidate',new)):
            source = f'''module {label}(input [3:0] es, input hold_c, vb, output vrd);
localparam [3:0] E_WK = 9;
localparam integer GROUP_REPLAY = 0;
wire replay_order_pending = 0;
assign vrd = {expression};
endmodule
'''
            (b/(label+'.v')).write_text(source)
            for load in (5,25,100):
                name = f'{label}_{load}ff'
                (b/(name+'.constraints')).write_text(f'set_driving_cell sky130_fd_sc_hd__buf_2\nset_load {load}\n')
                log = run(name, f'''
read_liberty -lib -ignore_miss_func cells.lib
read_verilog {label}.v
synth -top {label} -noabc
abc {abc_exe} -liberty cells.lib -constr {name}.constraints
clean
check -assert
stat -liberty cells.lib
write_verilog -noattr {name}.v
''', mapping=True)
                areas = re.findall(r'Chip area for module.*?:\s*([\d.]+)', log)
                delays = re.findall(r'Delay\s*=\s*([\d.]+)', log)
                if not areas or not delays:
                    raise ValueError('mapping did not report area and delay: '+name)
                result['mapping'][name] = dict(load_ff=load, area_um2=float(areas[-1]) if areas else None,
                                              abc_delay_ps=float(delays[-1]) if delays else None)
                # Verify every mapped output against its own RTL expression.
                (b/(name+'_gold.v')).write_text(source.replace('module '+label+'(', 'module gold('))
                mapped = (b/(name+'.v')).read_text().replace('module '+label+'(', 'module gate(')
                (b/(name+'_gate.v')).write_text(mapped)
                run(name+'_equiv', f'''
read_liberty -ignore_miss_func cells.lib
read_verilog {name}_gold.v {name}_gate.v
miter -equiv -flatten gold gate miter
hierarchy -top miter
proc; flatten; opt; techmap; opt
sat -verify -prove trigger 0 -show-inputs -show-outputs
''', mapping=True)
        result['status']='PASS'
        result['limitations'] = [
            'Temporal proof is a local interface contract, not actual full-solver sequential equivalence.',
            'Source-fragment guards detect selected changes but do not prove abstraction coverage.',
            'Cone inputs are es, hold_c and vb; their upstream paths and physical fanout are excluded.',
            'SKY130 typical-corner ABC estimates use illustrative 5/25/100 fF loads; no routed STA or production-node timing claim.',
            'Replay remains disabled; BIST, packed-memory mapping and scatter are covered by separate integration evidence.'
        ]
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        result['reason']=str(exc)
    result['evidence_sha256']={p.name:sha(p) for p in b.iterdir() if p.is_file() and p.name!='result.json'}
    (b/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
    return result['status']=='PASS'


if __name__=='__main__':
    raise SystemExit(0 if main() else 1)
