#!/usr/bin/env python3
"""Source-frozen solver yield qualification against an untruncated reference."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

from qualify_core_control import ROOT, sha, snapshot, verify_snapshot

RTL=['zeq_blake2b','zeq_eh_hash','zeq_mbist','zeq_ram','zeq_xbar_arb',
     'zeq_row_network','zeq_packed_values','zeq_eh_par']


def accept_audit(summary, expected_headers):
    if summary.get('headers') != expected_headers:
        raise ValueError('reference audit header count mismatch')
    rtl=summary['results']['rtl']
    if (rtl['reference_solutions']<=0 or rtl['solutions']!=rtl['reference_solutions']
            or rtl['missing_reference_solutions']!=0 or rtl['total_cycles']<=0):
        raise ValueError('RTL corpus lost reference solutions or has no meaningful yield evidence')
    return rtl


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build',required=True)
    ap.add_argument('--verifier',type=Path,help='explicit native verifier to freeze; defaults to the repository build')
    ap.add_argument('--n',type=int,choices=(48,200),default=200)
    ap.add_argument('--headers',type=int,default=16)
    ap.add_argument('--seed',default='zeq-production-yield-v1')
    ap.add_argument('--engines',type=int,choices=(2,4,8,16,32,64,128,256,512),
                    help='solver engines; default 4 at N48, 16 at N200')
    ap.add_argument('--hash-engines',type=int,choices=(1,2,4,8,16,32,64,128,256,512),
                    help='hash engines; default one per solver engine')
    ap.add_argument('--gmax',type=int,choices=(2,4,8,16,32,64),default=16)
    ap.add_argument('--group-replay',type=int,choices=(0,1),default=0)
    ap.add_argument('--hash-split',type=int,choices=(1,2,4),default=1)
    ap.add_argument('--slots',type=int,help='physical rows per bucket; default 80 at N48, 640 at N200')
    ap.add_argument('--bucket0-slots',type=int,help='optional extra rows only in bucket zero, within existing slot bits')
    ap.add_argument('--drop-zero',type=int,choices=(0,1),default=0,
                    help='discard all-zero intermediate rows (RTL DROP_ZERO); reference retention is still required')
    ap.add_argument('--leaf-set',type=int,choices=(0,1),default=0,
                    help='linear-time distinct-leaf check (RTL LEAF_SET)')
    ap.add_argument('--hash-units',type=int,choices=(1,2,4,8),default=1,
                    help='Blake2b units per hashing engine (RTL HASH_UNITS)')
    ap.add_argument('--set',action='append',default=[],metavar='NAME=INT',
                    help='extra candidate RTL parameter for tb_par (repeatable); recorded in inputs.json')
    ap.add_argument('--bist-first',type=int,choices=(0,1),default=0)
    ap.add_argument('--trace-drops',type=int,choices=(0,1),default=0,
                    help='record every capacity-discarded row for diagnosis; does not waive reference loss')
    ap.add_argument('--tile-trace-engine',type=int,default=-1,
                    help='record every packed-tile cycle for this engine; -1 disables (large files)')
    ap.add_argument('--compile-timeout',type=int,default=900)
    ap.add_argument('--output-groups',type=int,default=2,
                    help='Verilator C++ groups; 0 keeps generated files separate for larger builds')
    ap.add_argument('--simulation-timeout',type=int,default=14400)
    ap.add_argument('--audit-timeout',type=int,default=14400)
    a=ap.parse_args()
    if (not re.fullmatch(r'build/[A-Za-z0-9_-]+',a.build)
            or min(a.headers,a.compile_timeout,a.simulation_timeout,a.audit_timeout)<=0
            or a.output_groups<0):
        ap.error('fresh simple build path, positive counts/timeouts and nonnegative output groups required')
    k,bb,pb,sb,slots=(9,12,4,10,640) if a.n==200 else (5,4,2,7,80)
    if a.slots is not None:
        slots=a.slots
    if not 1 <= slots <= (1<<sb):
        ap.error('slots must be positive and fit the configured slot address width')
    sb=max(1,(slots-1).bit_length())
    if a.group_replay and a.gmax > (1 << sb):
        ap.error("replay buffer must fit the bucket slot address space")
    bucket0=slots if a.bucket0_slots is None else a.bucket0_slots
    if not slots <= bucket0 <= (1<<sb):
        ap.error('bucket-zero capacity must cover slots and fit the existing slot address width')
    engines=a.engines or (1<<pb)
    hashes=a.hash_engines or engines
    # The RTL slices both the engine index and the local bucket index.
    # Neither field can have zero width: 1 <= PB < BB.
    if engines>=(1<<bb) or hashes>engines:
        ap.error('solver engines must be fewer than buckets; hash engines cannot exceed solver engines')
    pb=engines.bit_length()-1;hpb=hashes.bit_length()-1
    if not -1 <= a.tile_trace_engine < engines:
        ap.error('tile trace engine must be -1 or an existing engine index')
    build=ROOT/a.build;build.mkdir();run_dir=build/'run';run_dir.mkdir()
    result=dict(status='FAIL',scope='Packed solver RTL on a fixed diverse corpus, exact reference-set retention and independent Python/Zig verification. No physical timing, energy, macro, IO or population-level yield qualification.')
    container='zeq-'+build.name;active_container=False

    def execute(command,log,timeout,docker=False):
        nonlocal active_container
        active_container=docker
        with (build/log).open('w') as out:
            proc=subprocess.Popen(command,cwd=ROOT,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
            try:code=proc.wait(timeout=timeout)
            except BaseException:
                os.killpg(proc.pid,signal.SIGKILL);proc.wait();raise
        if code:raise subprocess.CalledProcessError(code,command)
        active_container=False

    def interrupted(signum,frame):
        raise InterruptedError('runner interrupted by signal '+str(signum))

    signal.signal(signal.SIGTERM,interrupted);signal.signal(signal.SIGINT,interrupted)
    try:
        chip,files=snapshot(build,[ROOT/'tb/tb_par.sv',ROOT/'tb/qualify_par.py',ROOT/'tb/packed_tile_trace.sv', ROOT/'toolchain.json'], verifier_source=a.verifier)
        params=dict(N=a.n,K=k,NH=a.headers,BB=bb,PB=pb,HPB=hpb,HASH_SPLIT=a.hash_split,SB=sb,SLOTS=slots,
                    GMAX=a.gmax,GROUP_REPLAY=a.group_replay,PACKED_TABLES=1,SPLIT_KEYS=1,COMPACT_VALUES=1,STAGED_NETWORK=0,BIST_FIRST=a.bist_first)
        if bucket0 != slots:
            params['BUCKET0_SLOTS']=bucket0
        if a.drop_zero:
            params['DROP_ZERO']=1
        if a.leaf_set:
            params['LEAF_SET']=1
        if a.hash_units != 1:
            params['HASH_UNITS']=a.hash_units
        for item in a.set:
            match=re.fullmatch(r'([A-Z][A-Z0-9_]*)=(\d+)',item)
            # a candidate may also override a fixed setting (for example STAGED_NETWORK);
            # corpus and geometry stay under the named options
            if not match or match.group(1) in ('N','K','NH','BB','PB','SB','SLOTS'):
                raise ValueError('invalid extra parameter: '+item)
            params[match.group(1)]=int(match.group(2))
        if a.trace_drops:
            params['TRACE_DROPS']=1
        if a.tile_trace_engine >= 0:
            params['TILE_TRACE_ENGINE']=a.tile_trace_engine
        image_ref=json.loads((chip/'toolchain.json').read_text())['verilator']['image']
        image=subprocess.check_output(['docker','image','inspect','--format','{{.Id}}',image_ref],text=True,timeout=60).strip()
        runtime=json.loads(subprocess.check_output([sys.executable,'-E','-B','-c',
            'import json,sys,numpy; print(json.dumps(dict(python=sys.version,numpy=numpy.__version__)))'],text=True,timeout=60))
        checker=[sys.executable,'-E','-B','-u',str(chip/'model/par_qualification.py')]
        options=[str(run_dir),'--n',str(a.n),'--k',str(k),'--bb',str(bb),'--slots',str(slots),'--headers',str(a.headers),'--seed',a.seed]
        if bucket0 != slots:
            options.extend(['--bucket0-slots',str(bucket0)])
        execute([*checker,'prepare',*options],'prepare.log',60)
        headers_sha=sha(run_dir/'solver_hdr.hex')
        inputs=dict(parameters=params,seed=a.seed,image_id=image,image_ref=image_ref,files=files,python_runtime=runtime,
                    source_sha256=sha(build/'source.tgz'),headers_sha256=headers_sha,
                    compile_timeout_seconds=a.compile_timeout,
                    compiler_options=dict(build_jobs=2,output_groups=a.output_groups),
                    simulation_timeout_seconds=a.simulation_timeout,audit_timeout_seconds=a.audit_timeout)
        (build/'inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
        verify_snapshot(build,files)
        local=lambda p:'/work/'+str(p.relative_to(ROOT))
        base=['docker','run','--rm','--name',container,'--network=none','--cpus=2','--memory=6g','--pids-limit=256','-u',f'{os.getuid()}:{os.getgid()}',
              '-e','CCACHE_DISABLE=1','-v',str(ROOT)+':/work']
        execute([*base,'-w','/work',image,'--binary','--timing','-j','2',
                 '--output-groups',str(a.output_groups),'-Wall','--timescale','1ns/1ps',
                 '-Wno-DECLFILENAME','-Wno-UNUSEDPARAM','-Wno-UNUSEDSIGNAL','-Wno-PINCONNECTEMPTY','-Wno-PROCASSINIT',
                 '--top-module','tb_par',*[f'-G{n}={v}' for n,v in params.items()],
                 '--Mdir',local(build/'obj'),'-o','simulation',*[local(chip/'rtl'/(n+'.v')) for n in RTL],
                 local(chip/'tb/packed_tile_trace.sv'),local(chip/'tb/tb_par.sv')],'compile.log',a.compile_timeout,True)
        verify_snapshot(build,files);result['simulation_executable_sha256']=sha(build/'obj/simulation')
        execute([*base,'-w',local(run_dir),'--entrypoint',local(build/'obj/simulation'),image],
                'simulation.log',a.simulation_timeout,True)
        if a.tile_trace_engine >= 0:
            execute([sys.executable,'-E','-B',str(chip/'model/audit_tile_trace.py'),
                     str(run_dir/'packed_tile.trace'),'--output',str(run_dir/'tile-trace-review.json')],
                    'trace-audit.log',a.audit_timeout)
            result['tile_trace']=dict(engine=a.tile_trace_engine,
                review='run/tile-trace-review.json',scope='Complete interface capture; physical characterization and functional replay remain separate.')
        verify_snapshot(build,files)
        if sha(run_dir/'solver_hdr.hex')!=headers_sha:raise ValueError('headers changed during simulation')
        execute([*checker,'check',*options],'check.log',a.audit_timeout)
        summary=json.loads((run_dir/'audit/summary.json').read_text())
        result['yield']=accept_audit(summary,a.headers)
        verify_snapshot(build,files)
        if sha(run_dir/'solver_hdr.hex')!=headers_sha or sha(build/'obj/simulation')!=result['simulation_executable_sha256']:
            raise ValueError('simulation inputs/executable changed')
        result.update(status='PASS',archived_inputs_unchanged=True,headers=a.headers)
    except (OSError,ValueError,KeyError,subprocess.SubprocessError) as exc:
        result['reason']=str(exc)
    finally:
        if active_container:
            try:
                cleanup=subprocess.run(['docker','stop','--time','5',container],capture_output=True,text=True,timeout=20)
                result['container_cleanup_exit_code']=cleanup.returncode
            except (OSError,subprocess.SubprocessError) as exc:result['container_cleanup_unresolved']=str(exc)
        result['evidence_sha256']={p.name:sha(p) for p in build.iterdir() if p.is_file() and p.name!='result.json'}
        result['evidence_sha256'].update({str(p.relative_to(build)):sha(p) for p in run_dir.rglob('*') if p.is_file()})
        (build/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='evidence_sha256'},indent=2),flush=True)
    return result['status']=='PASS'


if __name__=='__main__':raise SystemExit(0 if main() else 1)
