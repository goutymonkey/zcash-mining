#!/usr/bin/env python3
"""Exercise the source-bound EQY runner with mapped sequential/SRAM fixtures.

The mutants must produce a reachable SBY counterexample, not just
fail to prove. Run inside LibreLane after bootstrap_make.sh on the host.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOP = 'user_project_wrapper'
GOLD = '''module user_project_wrapper(
    input clk,rst,we,re,input [8:0] waddr,raddr,input [31:0] data,
    output wire [31:0] q,output wire [31:0] memq,output seen_out);
    reg [31:0] state;
    reg seen;
    assign q = state ^ 32'h12345678;
    assign seen_out = seen & we;
    always @(posedge clk) if(rst) seen<=1'b0; else seen<=re;
    always @(posedge clk) if(rst) state<=32'b0; else state<=data;
    sky130_sram_2kbyte_1rw1r_32x512_8 u_mem(
        .clk0(clk),.csb0(~we),.web0(1'b0),.wmask0(4'hf),
        .addr0(waddr),.din0(q),.dout0(),
        .clk1(clk),.csb1(~re),.addr1(raddr),.dout1(memq));
endmodule
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build', type=Path, required=True)
    ap.add_argument('--library', type=Path, required=True)
    ap.add_argument('--jobs', type=int, default=2)
    ap.add_argument('--partition-timeout', type=int, default=120)
    ap.add_argument('--strategy', choices=('pdr', 'smt', 'pdr-smt'), default='pdr')
    ap.add_argument('--bind-net', action='append', default=[])
    args = ap.parse_args()
    if min(args.jobs, args.partition_timeout) <= 0:
        ap.error('jobs and partition timeout must be positive')
    build = args.build.resolve()
    library = args.library.resolve()
    build.relative_to(ROOT)
    library.relative_to(ROOT)
    build.mkdir(parents=True, exist_ok=False)
    source = build / 'source'
    source.mkdir()
    (source / 'user_project_wrapper.v').write_text(GOLD)
    (source / 'chip.sdc').write_text('create_clock -period 20 [get_ports clk]\n')
    config = dict(DESIGN_NAME=TOP, VERILOG_FILES=[str(source / 'user_project_wrapper.v')],
                  PNR_SDC_FILE=str(source / 'chip.sdc'), SIGNOFF_SDC_FILE=str(source / 'chip.sdc'))
    (source / 'config.json').write_text(json.dumps(config, indent=2)+'\n')
    (source / 'manifest.json').write_text(json.dumps(dict(files={p.name: digest(p)
          for p in source.iterdir() if p.is_file()}), indent=2)+'\n')
    run = build / 'run'
    run.mkdir()
    (run / 'resolved.json').write_text(json.dumps(dict(config, LIB={'*_tt_025C_1v80': [str(library)]}), indent=2)+'\n')
    cases = []
    for name, body in [
        ('good', GOLD),
        ('reset-mutant', GOLD.replace("state<=32'b0", "state<=32'b1")),
        ('hold-mutant', GOLD.replace('else state<=data', 'else if(we) state<=data')),
        ('scalar-state-mutant', GOLD.replace('else seen<=re', 'else seen<=we')),
        ('sram-address-mutant', GOLD.replace('.addr0(waddr)', ".addr0(waddr ^ 9'b1)")),
    ]:
        variant = build / (name+'.v')
        variant.write_text(body)
        mapped = build / (name+'-mapped.v')
        ys = build / (name+'.ys')
        ys.write_text(f'''read_liberty -lib "{library}";
read_verilog -sv "{ROOT}/pd/tc/sram_blackbox.v" "{variant}";
synth -top {TOP} -flatten;
dfflibmap -liberty "{library}";
abc -liberty "{library}";
clean;
splitnets;
write_verilog -noattr "{mapped}";
''')
        with (build/(name+'-map.log')).open('w') as out:
            subprocess.run(['yosys','-Q','-T','-s',str(ys)], stdout=out,stderr=subprocess.STDOUT,check=True)
        proof = build / name
        command = [sys.executable,str(ROOT/'formal/cec/chip.py'), '--run',str(run),
                   '--source-manifest',str(source/'manifest.json'),'--gate',str(mapped),
                   '--build',str(proof),'--engine','eqy','--timeout','600',
                   '--jobs',str(args.jobs),'--partition-timeout',str(args.partition_timeout),
                   '--eqy-strategy',args.strategy,
                   *[arg for name in sorted(set(args.bind_net)) for arg in ('--eqy-bind-net',name)]]
        with (build/(name+'-runner.log')).open('w') as out:
            proc = subprocess.run(command,cwd=ROOT,stdout=out,stderr=subprocess.STDOUT)
        result = json.loads((proof/'result.json').read_text())
        # Require a reachable SBY counterexample with either engine.
        # Induction-only traces, tool errors and timeouts cannot pass.
        traces = []
        for status in (proof/'eqy/strategies').glob('*/*/*/status'):
            if status.read_text().split()[0] == 'FAIL':
                traces += list(status.parent.glob('engine_*/trace_tb.v'))
        good = name == 'good'
        passed = (proc.returncode == 0 and result['status']=='PASS') if good else (
            proc.returncode != 0 and result['status']=='FAIL' and bool(traces))
        item = dict(name=name,status='PASS' if passed else 'FAIL',
                    check='equivalence' if good else 'reachable mutation counterexample',
                    result_sha256=digest(proof/'result.json'),
                    counterexamples={str(p.relative_to(build)):digest(p) for p in traces})
        cases.append(item)
        print(name+': '+item['status'],flush=True)
    result = dict(status='PASS' if all(c['status']=='PASS' for c in cases) else 'FAIL',cases=cases,
                  jobs=args.jobs,partition_timeout_seconds=args.partition_timeout,
                  strategy=args.strategy,
                  bound_nets=sorted(set(args.bind_net)),
                  scope='Mapped sequential and SRAM-boundary fixtures. Does not qualify the full chip or production release.')
    (build/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    raise SystemExit(0 if result['status']=='PASS' else 1)


if __name__=='__main__':
    main()
