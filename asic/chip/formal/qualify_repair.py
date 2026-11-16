#!/usr/bin/env python3
"""Archive and prove the repair adapter contract; require reachable mutant failures.

Run in LibreLane. Concrete geometries only; physical SRAM is unconstrained.
The separate simulation matrix checks memory behavior and BIST fault coverage.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['rtl/zeq_mbist.v', 'rtl/zeq_repair_bank.v', 'formal/repair_bank.sv',
           'formal/qualify_repair.py']


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build', type=Path, required=True)
    args = ap.parse_args()
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=False)
    # Execute the copied inputs, so concurrent edits cannot change the proof.
    for name in SOURCES:
        dest = build / 'source' / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes((ROOT / name).read_bytes())
    files = {name: sha(build / 'source' / name) for name in SOURCES}
    with tarfile.open(build / 'source.tgz', 'w:gz') as archive:
        for name in SOURCES:
            archive.add(build / 'source' / name, arcname=name)
    (build / 'inputs.json').write_text(json.dumps(dict(files=files,
        archive_sha256=sha(build / 'source.tgz'),
        yosys=subprocess.check_output(['yosys', '-V'], text=True).strip()), indent=2)+'\n')
    cases = []
    mutations = [
        ('write-remap', ('repair_active && wa==repair_row ? SPARE', "repair_active && wa==repair_row ? PAW'(0)")),
        ('read-remap', ('repair_active && ra==repair_row ? SPARE', "repair_active && ra==repair_row ? PAW'(0)")),
        ('stale-bist', ('assign bist_done=b_done && test_valid;', 'assign bist_done=b_done;')),
    ]
    jobs = [(f'depth{depth}', aw, dw, depth, None) for aw,dw,depth in [(1,8,1),(3,13,5),(6,32,64)]]
    # Depth one finishes a complete BIST within a bounded mutation trace.
    jobs += [(name, 1, 8, 1, mutation) for name,mutation in mutations]
    for name,aw,dw,depth,mutation in jobs:
        rtl = build / 'source/rtl/zeq_repair_bank.v'
        if mutation:
            body=rtl.read_text(); old,new=mutation
            if body.count(old)!=1:
                raise ValueError('mutation site must be unique: '+name)
            rtl=build/(name+'.v');rtl.write_text(body.replace(old,new))
        source=build/'source'
        script=f'''read_verilog -sv -D SYNTHESIS "{source}/rtl/zeq_mbist.v" "{rtl}";
read_verilog -formal -sv "{source}/formal/repair_bank.sv";
chparam -set AW {aw} -set DW {dw} -set DEPTH {depth} repair_bank_formal;
prep -top repair_bank_formal -flatten;
opt -full; async2sync; dffunmap; techmap; opt -full;
'''
        if mutation:
            steps=40 if name=='stale-bist' else 6
            script+=f'sat -timeout 120 -seq {steps} -prove-asserts -set-assumes -dump_json "{build}/{name}-counterexample.json";\n'
        else:
            script+='sat -timeout 120 -tempinduct -seq 2 -maxsteps 6 -prove-asserts -set-assumes -verify;\n'
        ys=build/(name+'.ys');ys.write_text(script)
        log=build/(name+'.log')
        with log.open('w') as out:
            proc=subprocess.run(['yosys','-Q','-T','-s',str(ys)],stdout=out,stderr=subprocess.STDOUT)
        marker='SAT proof finished - model found: FAIL!' if mutation else 'Induction step proven: SUCCESS!'
        passed=proc.returncode==0 and marker in log.read_text()
        cex=build/(name+'-counterexample.json')
        if mutation: passed=passed and cex.is_file()
        item=dict(name=name,AW=aw,DW=dw,DEPTH=depth,
            check='reachable mutation counterexample' if mutation else 'induction',
            status='PASS' if passed else 'FAIL',exit_code=proc.returncode,
            log_sha256=sha(log),script_sha256=sha(ys))
        if mutation and cex.is_file():item['counterexample_sha256']=sha(cex)
        if mutation:item['mutant_sha256']=sha(rtl)
        cases.append(item);print(name+': '+item['status'],flush=True)
    result=dict(status='PASS' if all(c['status']=='PASS' for c in cases) else 'FAIL',
        scope='Adapter application-port remapping, ownership, bounds, configuration rejection, reset and stale qualification. Depths 1/5/64 only. No physical macro or complete BIST algorithm proof.',
        inputs_sha256=sha(build/'inputs.json'),cases=cases)
    (build/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    raise SystemExit(0 if result['status']=='PASS' else 1)


if __name__=='__main__':
    main()
