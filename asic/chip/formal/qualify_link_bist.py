#!/usr/bin/env python3
"""Prove actual link scheduling with symbolic decoded commands, and test mutants."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FILES = ['rtl/zeq_link.v','rtl/zeq_uart.v','rtl/zeq_fifo.v','rtl/zeq_ram.v',
         'rtl/zeq_mbist.v','formal/link_bist.sv','formal/qualify_link_bist.py']


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build',type=Path,required=True)
    ap.add_argument('--boot-bist',action='store_true')
    args=ap.parse_args();b=args.build.resolve();b.mkdir(parents=True,exist_ok=False)
    for name in FILES:
        dest=b/'source'/name;dest.parent.mkdir(parents=True,exist_ok=True)
        dest.write_bytes((ROOT/name).read_bytes())
    (b/'inputs.json').write_text(json.dumps(dict(files={n:sha(b/'source'/n) for n in FILES},boot_bist=args.boot_bist,
        yosys=subprocess.check_output(['yosys','-V'],text=True).strip()),indent=2)+'\n')
    cases=[]
    mutations=[('healthy',None),
        ('stale-done',('bist_running && bist_armed && bist_done','bist_running && bist_done')),
        ('ignore-failure',('!bist_fault',"1'b1"))]
    if args.boot_bist:
        mutations.append(('boot-disabled',('bist_pending <= (HAS_BIST != 0 && BOOT_BIST != 0);',"bist_pending <= 1'b0;")))
    for name,mutation in mutations:
        rtl=b/'source/rtl/zeq_link.v'
        if mutation:
            old,new=mutation;body=rtl.read_text()
            if old not in body:raise ValueError('missing mutation site')
            rtl=b/(name+'.v');rtl.write_text(body.replace(old,new))
        sources=[b/'source'/n for n in FILES if n.startswith('rtl/') and n!='rtl/zeq_link.v']+[rtl]
        script='read_verilog -sv -D SYNTHESIS '+' '.join(json.dumps(str(p)) for p in sources)+';\n'
        if args.boot_bist:script+='chparam -set BOOT_BIST 1 zeq_link;\n'
        script+='''hierarchy -check -top zeq_link;
proc; flatten;
expose -input w:cmd_job w:cmd_stop w:cmd_bist;
expose w:bist_running w:bist_armed w:bist_fault w:bist_pending w:cst w:lane_run w:job_req;
rename zeq_link link_control;
'''
        script+=f'read_verilog -formal -sv "{b}/source/formal/link_bist.sv";\n'
        if args.boot_bist:script+='chparam -set BOOT_BIST 1 link_bist_formal;\n'
        script+='prep -top link_bist_formal -flatten; opt -full; memory_map; opt -full; async2sync; dffunmap; techmap; opt -full;\n'
        if mutation:
            script+=f'sat -timeout 120 -seq 16 -set-assumes -prove-asserts -dump_json "{b}/{name}-counterexample.json";\n'
        else:
            script+='sat -timeout 120 -tempinduct -seq 4 -maxsteps 12 -set-assumes -prove-asserts -verify;\n'
        ys=b/(name+'.ys');ys.write_text(script);log=b/(name+'.log')
        with log.open('w') as out:
            proc=subprocess.run(['yosys','-Q','-T','-s',str(ys)],stdout=out,stderr=subprocess.STDOUT)
        marker='SAT proof finished - model found: FAIL!' if mutation else 'Induction step proven: SUCCESS!'
        passed=proc.returncode==0 and marker in log.read_text()
        trace=b/(name+'-counterexample.json')
        if mutation:passed=passed and trace.is_file()
        result=dict(name=name,status='PASS' if passed else 'FAIL',exit_code=proc.returncode,
                    check='reachable mutation counterexample' if mutation else 'induction',log_sha256=sha(log),script_sha256=sha(ys))
        if trace.exists():result['counterexample_sha256']=sha(trace)
        cases.append(result);print(name+': '+result['status'],flush=True)
    report=dict(status='PASS' if all(c['status']=='PASS' for c in cases) else 'FAIL',cases=cases,
        inputs_sha256=sha(b/'inputs.json'),boot_bist=args.boot_bist,scope='Actual one-lane link scheduler with arbitrary decoded command strobes, lane status and BIST responses. Startup mode includes mandatory memory qualification after every reset. UART receivers idle; no SRAM macro or serial-framing proof.')
    (b/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    raise SystemExit(0 if report['status']=='PASS' else 1)


if __name__=='__main__':main()
