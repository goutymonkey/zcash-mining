#!/usr/bin/env python3
"""Qualify actual-UART recovery at every strap address, with archived sources."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build', required=True)
    ap.add_argument('--n', type=int, choices=(48, 200), default=48)
    ap.add_argument('--link-source', type=Path, default=ROOT/'rtl/zeq_link.v')
    ap.add_argument('--expect-starvation', action='store_true')
    ap.add_argument('--downstream', action='store_true', help='qualify controller command recovery')
    ap.add_argument('--extended', action='store_true', help='include command timeout boundaries, CRC and exact-length checks')
    ap.add_argument('--mutation', choices=('no-length-guard', 'no-gap-timeout'),
                    help='require the regression to catch a fault in an archived RTL copy')
    ap.add_argument('--iverilog', action='store_true', help='run directly inside an existing EDA container')
    ap.add_argument('--image-id', help='immutable image ID of that existing container')
    args = ap.parse_args()
    if not re.fullmatch(r'build/[A-Za-z0-9_-]+', args.build):
        ap.error('use a fresh simple build/ path')
    if args.expect_starvation and args.mutation:
        ap.error('choose historical starvation or one explicit mutation')
    if args.extended and (not args.downstream or args.expect_starvation):
        ap.error('--extended requires --downstream and does not support historical starvation mode')
    build = ROOT/args.build
    build.mkdir()
    top = 'tb_link_command_recovery' if args.downstream else 'tb_link_recovery'
    files = ['rtl/'+n+'.v' for n in ('zeq_mbist','zeq_ram','zeq_fifo','zeq_uart','zeq_link')]
    files += ['tb/'+top+'.sv','tb/qualify_link_recovery.py']
    for name in files:
        dst = build/'source'/name
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes((args.link_source if name=='rtl/zeq_link.v' else ROOT/name).read_bytes())
    original_link_sha256 = sha(build/'source/rtl/zeq_link.v')
    if args.mutation:
        path = build/'source/rtl/zeq_link.v'
        mutation_sites = {
            'no-length-guard': ('if ({f_head, flen[7:0]} > SOL_LEN) ast <= A_IDLE;',
                                "if (1'b0) ast <= A_IDLE;"),
            'no-gap-timeout': ('if (forward_timeout) begin', "if (1'b0) begin"),
        }
        if args.downstream:
            mutation_sites = {
                'no-length-guard': ('if (!command_length_valid(ptyp, {d_byte, plen[7:0]}))', "if (1'b0)"),
                'no-gap-timeout': ('else if (command_timeout) begin', "else if (1'b0) begin"),
            }
        old, new = mutation_sites[args.mutation]
        body = path.read_text()
        if body.count(old) != 1:
            raise ValueError('mutation site missing or ambiguous')
        path.write_text(body.replace(old, new))
    if args.iverilog and not re.fullmatch(r'sha256:[0-9a-f]{64}', args.image_id or ''):
        ap.error('--iverilog requires the inspected container --image-id')
    image = args.image_id if args.iverilog else subprocess.check_output(['docker','image','inspect','--format','{{.Id}}','verilator/verilator:latest'],text=True).strip()
    inputs = dict(image_id=image,n=args.n,expect_starvation=args.expect_starvation,
                  downstream=args.downstream,extended=args.extended,
                  mutation=args.mutation,original_link_sha256=original_link_sha256,
                  source_sha256={n:sha(build/'source'/n) for n in files},
                  scope='Actual UART, malformed length, truncated header/payload, slow valid and maximum-payload forwarding, and local PONG recovery at addresses 0..3. No solver or analog claim.')
    if args.downstream:
        inputs['scope']='Actual command UART: oversized length, truncated header/payload, slow PING, SOF-like target payload, atomic target staging and subsequent valid commands at all addresses. No solver or analog claim.'
        if args.extended:
            inputs['scope']+=' Also missing/bad CRC, invalid command lengths and received-byte intervals four clocks below/above timeout.'
    if args.iverilog:
        inputs['iverilog_version'] = subprocess.run(['iverilog','-V'],capture_output=True,text=True,check=True).stdout.splitlines()[0]
        inputs['tool_sha256'] = {n:sha(Path(shutil.which(n))) for n in ('iverilog','vvp')}
    (build/'inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
    name='zeq-'+build.name
    docker=['docker','run','--rm','--name',name,'-u',f'{os.getuid()}:{os.getgid()}',
            '-e','CCACHE_DISABLE=1','-v',str(ROOT)+':/work','-w','/work']
    local=lambda p:'/work/'+str(p.relative_to(ROOT))
    command=[*docker,image,'--binary','--timing','-j','2','-Wall','--timescale','1ns/1ps',
             '-Wno-DECLFILENAME','-Wno-UNUSEDPARAM','-Wno-UNUSEDSIGNAL',
             '-Wno-PINCONNECTEMPTY','-Wno-PROCASSINIT','-Wno-BLKSEQ',
             '--top-module',top,f'-GN={args.n}',
             '--Mdir',local(build/'obj'),'-o','simulation']
    command += [local(build/'source'/n) for n in files if n.endswith(('.v','.sv'))]
    if args.iverilog:
        command=['iverilog','-g2012','-s',top,f'-P{top}.N={args.n}',
                 '-o',str(build/'simulation')]+[str(build/'source'/n) for n in files if n.endswith(('.v','.sv'))]
    cases=[]
    error=None
    try:
        with (build/'compile.log').open('w') as out:
            subprocess.run(command,stdout=out,stderr=subprocess.STDOUT,check=True,timeout=600)
        for scenario in range(13 if args.extended else 5):
            for addr in range(4):
                log=build/f'case-{scenario}-addr-{addr}.log'
                with log.open('w') as out:
                    sim = ['vvp',str(build/'simulation')] if args.iverilog else [*docker,'--entrypoint',local(build/'obj/simulation'),image]
                    proc=subprocess.run([*sim,f'+CASE={scenario}',f'+ADDR={addr}'],
                                        stdout=out,stderr=subprocess.STDOUT,timeout=60)
                length_cases=(0,7,12) if args.extended else (0,)
                timeout_cases=(1,2,5,6,10) if args.extended else (1,2)
                negative=(args.expect_starvation and scenario<3) or (
                    args.mutation=='no-length-guard' and scenario in length_cases) or (
                    args.mutation=='no-gap-timeout' and scenario in timeout_cases)
                body=log.read_text()
                direction='downstream' if args.downstream else 'upstream'
                failure_marker='local PONG starved after '+direction
                if args.extended and scenario in (7,12):failure_marker='invalid command committed'
                if args.extended and scenario==10:failure_marker='over-timeout command accepted'
                passed=(proc.returncode!=0 and failure_marker in body) if negative else (
                    proc.returncode==0 and 'link recovery PASS' in body)
                cases.append(dict(scenario=scenario,address=addr,status='PASS' if passed else 'FAIL',
                                  check='caught injected fault' if negative and args.mutation else (
                                      'reproduced starvation' if negative else 'recovery/valid traffic'),
                                  exit_code=proc.returncode,log_sha256=sha(log)))
                print(f'case={scenario} addr={addr}: '+cases[-1]['status'],flush=True)
    except subprocess.TimeoutExpired as exc:
        error=str(exc)
        if not args.iverilog:
            try:
                subprocess.run(['docker','stop','--time','5',name],capture_output=True,timeout=20)
            except (OSError,subprocess.TimeoutExpired) as cleanup:
                error += '; container cleanup unresolved: ' + str(cleanup)
    except (OSError,subprocess.CalledProcessError) as exc:
        error=str(exc)
    unchanged=all(sha(build/'source'/n)==h for n,h in inputs['source_sha256'].items())
    result=dict(status='PASS' if not error and unchanged and len(cases)==(52 if args.extended else 20) and all(c['status']=='PASS' for c in cases) else 'FAIL',
                cases=cases,error=error,source_unchanged=unchanged,inputs_sha256=sha(build/'inputs.json'),
                evidence_sha256={p.name:sha(p) for p in build.glob('*.log')})
    (build/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['status']=='PASS'

if __name__=='__main__':
    raise SystemExit(0 if main() else 1)
