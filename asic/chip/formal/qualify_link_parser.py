#!/usr/bin/env python3
"""Prove command commit guards on archived RTL; require concrete mutant traces."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess

ROOT=Path(__file__).resolve().parents[1]
FILES=['rtl/zeq_link.v','rtl/zeq_uart.v','rtl/zeq_fifo.v','rtl/zeq_ram.v',
       'rtl/zeq_mbist.v','formal/link_parser.sv','formal/qualify_link_parser.py']


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build',type=Path,required=True)
    ap.add_argument('--n',type=int,choices=(48,200),default=48)
    ap.add_argument('--boot-bist',action='store_true')
    args=ap.parse_args();build=args.build.resolve();build.relative_to(ROOT/'build')
    build.mkdir(parents=True,exist_ok=False)
    for n in FILES:
        p=build/'source'/n;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((ROOT/n).read_bytes())
    k=9 if args.n==200 else 5
    parameters=dict(N=args.n,K=k,BOOT_BIST=int(args.boot_bist))
    inputs=dict(files={n:sha(build/'source'/n) for n in FILES},parameters=parameters,
                yosys=subprocess.check_output(['yosys','-V'],text=True).strip())
    (build/'inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
    variants=[('healthy',None),
        ('crc-mutant',('d_byte == pcrc && (padr == my_id || padr == 8\'hFF)', '(padr == my_id || padr == 8\'hFF)')),
        ('address-mutant',('d_byte == pcrc && (padr == my_id || padr == 8\'hFF)', 'd_byte == pcrc')),
        ('length-mutant',('if (!command_length_valid(ptyp, {d_byte, plen[7:0]}))', "if (1'b0)")),
        ('header-mutant',("P_SOF: if (d_byte == DOWN_SOF) begin pcrc <= 8'd0; pst <= P_TYP; end", "P_SOF: if (d_byte == DOWN_SOF) begin pcrc <= 8'd0; pst <= P_CRC; end")),
        ('address-overwrite-mutant', ("pcnt <= pcnt + 1'b1;", "padr <= my_id;\n                pcnt <= pcnt + 1'b1;"))]
    cases=[]
    for name,mutation in variants:
        rtl=build/'source/rtl/zeq_link.v'
        if mutation:
            old,new=mutation;body=rtl.read_text()
            if body.count(old)!=1:raise ValueError('mutation site missing or ambiguous')
            rtl=build/(name+'.v');rtl.write_text(body.replace(old,new))
        sources=[build/'source'/n for n in FILES if n.startswith('rtl/') and n!='rtl/zeq_link.v']+[rtl]
        script='read_verilog -sv -D SYNTHESIS '+' '.join(json.dumps(str(p)) for p in sources)+';\n'
        script+=f'chparam -set N {args.n} -set K {k} -set BOOT_BIST {int(args.boot_bist)} zeq_link;\n'
        script+='''hierarchy -check -top zeq_link;
proc; flatten;
expose -input w:d_valid w:d_byte;
expose w:pst w:ptyp w:padr w:pcrc w:plen w:pcnt w:ot_thresh w:ot_stage w:tgt_stage w:command_timeout w:cmd_job w:cmd_stop w:cmd_ping w:cmd_bist;
rename zeq_link link_parser;
'''
        script+=f'read_verilog -formal -sv "{build}/source/formal/link_parser.sv";\n'
        script+=f'chparam -set N {args.n} -set K {k} link_parser_formal;\n'
        script+='prep -top link_parser_formal -flatten; opt -full; memory_map; opt -full; async2sync; dffunmap; techmap; opt -full;\n'
        trace=build/(name+'-counterexample.json')
        if mutation:script+=f'sat -timeout 120 -seq 12 -set-assumes -prove-asserts -dump_json "{trace}";\n'
        else:script+='sat -timeout 120 -tempinduct -seq 4 -maxsteps 12 -set-assumes -prove-asserts -verify;\n'
        ys=build/(name+'.ys');ys.write_text(script);log=build/(name+'.log');error=None
        with log.open('w') as out:
            proc=subprocess.Popen(['yosys','-Q','-T','-s',str(ys)],stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
            try:code=proc.wait(timeout=300)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid,signal.SIGKILL);proc.wait();code=124;error='proof process timed out'
        marker='SAT proof finished - model found: FAIL!' if mutation else 'Induction step proven: SUCCESS!'
        passed=code==0 and marker in log.read_text() and (not mutation or trace.is_file())
        item=dict(name=name,status='PASS' if passed else 'FAIL',exit_code=code,error=error,
                  check='reachable mutation counterexample' if mutation else 'induction',
                  rtl_sha256=sha(rtl),script_sha256=sha(ys),log_sha256=sha(log))
        if trace.exists():item['counterexample_sha256']=sha(trace)
        cases.append(item);print(name+': '+item['status'],flush=True)
    unchanged=all(sha(build/'source'/n)==h for n,h in inputs['files'].items())
    result=dict(status='PASS' if unchanged and len(cases)==len(variants) and all(c['status']=='PASS' for c in cases) else 'FAIL',
                cases=cases,archived_inputs_unchanged=unchanged,inputs_sha256=sha(build/'inputs.json'),
                parameters=parameters,
                scope='Actual parser with arbitrary decoded bytes, all static strap addresses and repeated reset. Header/state transitions, CRC recurrence, legal lengths, command strobes, atomic target/thermal commits and timeout-state exit. UART sampling, payload ordering, timeout duration, mining behavior and physical CDC/RDC excluded.')
    (build/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['status']=='PASS'


if __name__=='__main__':raise SystemExit(0 if main() else 1)
