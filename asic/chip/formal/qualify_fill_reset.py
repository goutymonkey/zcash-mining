#!/usr/bin/env python3
"""Prove the exact counter-reset rewrite by sequential equivalence of an arbitrary row.

The watched row is an arbitrary constant, so the proof covers every bank row.
Corresponding initial words are equal but otherwise unconstrained. All reset,
clear, write, data and parity inputs are arbitrary. This is a counter-state
transition proof, not full-solver/netlist equivalence or physical signoff.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

OLD = '                    for (ci = 0; ci < BPE; ci = ci + 1) fill[{dst_par, ci[JB-1:0]}] <= 0;'
NEW = '''                    // Constant reset addresses avoid a large inferred write-priority network.
                    for (ci = 0; ci < 2*BPE; ci = ci + 1)
                        if (dst_par == ci[JB]) fill[ci] <= 0;'''


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_change(before, after):
    if before.count(OLD) != 1 or after != before.replace(OLD, NEW):
        raise ValueError('source changes exceed the exact counter-reset rewrite')


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline',type=Path,required=True)
    ap.add_argument('--candidate',type=Path,default=Path('rtl/zeq_eh_par.v'))
    ap.add_argument('--build',type=Path,required=True)
    ap.add_argument('--yosys',default='yosys')
    a=ap.parse_args()
    check_change(a.baseline.read_text(),a.candidate.read_text())
    b=a.build.resolve();b.mkdir(parents=True,exist_ok=False)
    for name,p in [('baseline.v',a.baseline),('candidate.v',a.candidate),
                   ('watched.sv',Path(__file__).with_name('fill_reset.sv')),('runner.py',Path(__file__))]:
        shutil.copyfile(p,b/name)
    inputs={p.name:sha(p) for p in b.iterdir() if p.is_file()}
    result=dict(status='FAIL',scope=__doc__.strip(),inputs_sha256=inputs,cases=[])
    try:
        result['yosys_version']=subprocess.check_output([a.yosys,'-V'],text=True,timeout=30).strip()
        for aw in (1,2,3,6,8):
            for mutant in (0,1):
                name=f'row-aw{aw}-mut{mutant}'
                script=f'''read_verilog -formal -sv watched.sv
chparam -set AW {aw} -set MUTANT {mutant} watched
prep -top watched -flatten
async2sync
chformal -lower
sat -tempinduct -seq 2 -maxsteps 8 -set-assumes -prove-asserts -verify -dump_json {name}-counterexample.json
'''
                (b/(name+'.ys')).write_text(script)
                with (b/(name+'.log')).open('w') as log:
                    proc=subprocess.run([a.yosys,'-Q','-T','-s',name+'.ys'],cwd=b,
                                        stdout=log,stderr=subprocess.STDOUT,timeout=90)
                output=(b/(name+'.log')).read_text()
                if mutant:
                    passed=(proc.returncode!=0 and 'model found for base case: FAIL' in output
                            and (b/(name+'-counterexample.json')).is_file())
                else:
                    passed=proc.returncode==0 and 'Induction step proven: SUCCESS' in output
                case=dict(address_bits=aw,rows=2*(1<<aw),word_bits=11,mutant=bool(mutant),
                          status='PASS' if passed else 'FAIL')
                result['cases'].append(case)
                print(json.dumps(case),flush=True)
                if not passed:raise ValueError('proof or reachable mutant check failed: '+name)
        for name,digest in inputs.items():
            if sha(b/name)!=digest:raise ValueError('archived input changed: '+name)
        result['status']='PASS'
        result['archived_inputs_unchanged']=True
    except (OSError,ValueError,subprocess.SubprocessError) as exc:
        result['reason']=str(exc)
    result['evidence_sha256']={p.name:sha(p) for p in b.iterdir() if p.is_file() and p.name!='result.json'}
    (b/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['status']=='PASS'


if __name__=='__main__':
    raise SystemExit(0 if main() else 1)
