#!/usr/bin/env python3
"""Run digital-core integration using only archived RTL, models and verifier."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
RTL = ['zeq_blake2b','zeq_eh_hash','zeq_sfifo','zeq_eh_solver3','zeq_mbist','zeq_ram',
       'zeq_xbar_arb','zeq_row_network','zeq_packed_values','zeq_eh_par','zeq_sha256',
       'zeq_share','zeq_tables_sram','zeq_fifo','zeq_uart','zeq_link','zeq200_core','zeq200x']


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(build, extra_sources=(), *, verifier_source=None):
    # Preserve the repository-relative layout used by the independent checker
    # to locate zig-out/bin/zcash-miner three directories above its model file.
    verifier_source = Path(verifier_source) if verifier_source is not None else ROOT.parents[1]/'zig-out/bin/zcash-miner'
    if not verifier_source.is_file() or not os.access(verifier_source, os.X_OK):
        raise ValueError('an executable independent verifier is required')
    archive = build/'source'
    chip = archive/'asic/chip'
    sources = [ROOT/'tb/tb_core_control.sv', ROOT/'tb/qualify_core_control.py',
               *sorted((ROOT/'rtl').glob('*.v')), *sorted((ROOT/'model').glob('*.py')),
               *extra_sources]
    for source in sources:
        target = chip/source.relative_to(ROOT)
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(source,target)
    verifier = archive/'zig-out/bin/zcash-miner'
    verifier.parent.mkdir(parents=True)
    shutil.copy2(verifier_source,verifier)
    files = {str(p.relative_to(archive)):sha(p) for p in sorted(archive.rglob('*')) if p.is_file()}
    with tarfile.open(build/'source.tgz','w:gz') as tar:
        for name in files:
            tar.add(archive/name,arcname=name)
    return chip,files


def verify_snapshot(build, files):
    for name, expected in files.items():
        path = build/'source'/name
        if not path.is_file() or sha(path) != expected:
            raise ValueError('archived input changed: '+name)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build',required=True)
    ap.add_argument('--n',type=int,choices=(48,200),default=48)
    ap.add_argument('--staged-network',type=int,choices=(0,1),default=0)
    ap.add_argument('--packed-tables',type=int,choices=(0,1),default=1,
                    help='test packed candidate (1) or separate production-default tables (0)')
    ap.add_argument('--engines',type=int,choices=(2,4,8,16,32,64,128,256,512),
                    help='solver engines; default 4 at N48, 16 at N200')
    ap.add_argument('--hash-engines',type=int,choices=(1,2,4,8,16,32,64,128,256,512),
                    help='hash engines; default one per solver engine (4 at N48, 16 at N200)')
    ap.add_argument('--gmax',type=int,choices=(2,4,8,16,32,64),default=16)
    ap.add_argument('--group-replay',type=int,choices=(0,1),default=0)
    ap.add_argument('--hash-split',type=int,choices=(1,2,4),default=1)
    ap.add_argument('--bucket0-slots',type=int,help='optional extra capacity within existing slot bits')
    ap.add_argument('--drop-zero',type=int,choices=(0,1),default=0,help='RTL DROP_ZERO')
    ap.add_argument('--leaf-set',type=int,choices=(0,1),default=0,help='RTL LEAF_SET')
    ap.add_argument('--hash-units',type=int,choices=(1,2,4,8),default=1,help='RTL HASH_UNITS')
    ap.add_argument('--compile-timeout',type=int,default=900)
    ap.add_argument('--output-groups',type=int,default=0)
    ap.add_argument('--simulation-timeout',type=int,default=3600)
    a=ap.parse_args()
    if (not re.fullmatch(r'build/[A-Za-z0-9_-]+',a.build)
            or min(a.simulation_timeout,a.compile_timeout)<=0 or a.output_groups<0):
        ap.error('use a fresh simple build/ path and positive timeout')
    k,bb,pb,sb,slots=(9,12,4,10,640) if a.n==200 else (5,4,2,7,80)
    engines=a.engines or (1<<pb)
    if engines >= (1<<bb):
        ap.error('solver engines must be fewer than buckets')
    pb=engines.bit_length()-1
    bucket0=slots if a.bucket0_slots is None else a.bucket0_slots
    if not slots <= bucket0 <= (1<<sb):
        ap.error('bucket-zero capacity must cover slots and fit existing slot bits')
    hashes=a.hash_engines or (1<<pb)
    if hashes>(1<<pb):
        ap.error('hash engines cannot exceed solver engines')
    hpb=hashes.bit_length()-1
    build=ROOT/a.build
    build.mkdir()
    run_dir=build/'run'
    run_dir.mkdir()
    container='zeq-'+build.name
    result={'status':'FAIL','scope':__doc__.strip()+' No macro, physical IO or broad-yield qualification.'}
    active_container=False
    env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1')

    def run(command,log,timeout,docker=False):
        nonlocal active_container
        active_container=docker
        with (build/log).open('w') as out:
            proc=subprocess.Popen(command,cwd=ROOT,env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
            try:
                code=proc.wait(timeout=timeout)
            except BaseException:
                os.killpg(proc.pid,signal.SIGKILL)
                proc.wait()
                raise
        if code:
            raise subprocess.CalledProcessError(code,command)
        active_container=False

    def interrupted(signum,frame):
        raise InterruptedError('runner interrupted by signal '+str(signum))

    signal.signal(signal.SIGTERM,interrupted)
    signal.signal(signal.SIGINT,interrupted)
    try:
        chip,files=snapshot(build, [ROOT/'toolchain.json'])
        params=dict(N=a.n,K=k,BB=bb,PB=pb,HPB=hpb,HASH_SPLIT=a.hash_split,SB=sb,SLOTS=slots,STAGED_NETWORK=a.staged_network,
                    PACKED_TABLES=a.packed_tables,GMAX=a.gmax,GROUP_REPLAY=a.group_replay)
        if bucket0 != slots:
            params['BUCKET0_SLOTS']=bucket0
        for name,value,default in (('DROP_ZERO',a.drop_zero,0),('LEAF_SET',a.leaf_set,0),('HASH_UNITS',a.hash_units,1)):
            if value != default:
                params[name]=value
        image_ref=json.loads((chip/'toolchain.json').read_text())['verilator']['image']
        image=subprocess.check_output(['docker','image','inspect','--format','{{.Id}}',image_ref],text=True,timeout=60).strip()
        runtime=json.loads(subprocess.check_output([sys.executable,'-E','-B','-c',
            'import json,sys,numpy; print(json.dumps(dict(python=sys.version,numpy=numpy.__version__)))'],
            text=True,timeout=60))
        inputs=dict(parameters=params,PACKED_TABLES=a.packed_tables,SHARE_FILTER=1,BOOT_BIST=1,image_id=image,image_ref=image_ref,
                    source_sha256=sha(build/'source.tgz'),files=files,
                    simulation_timeout_seconds=a.simulation_timeout,
                    compile_timeout_seconds=a.compile_timeout,
                    compiler_options=dict(build_jobs=2,output_groups=a.output_groups),
                    python_runtime=runtime,scope=result['scope'])
        (build/'inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
        # The model uses assertions. Ignore PYTHONOPTIMIZE/PYTHONPATH so a
        # caller's Python settings cannot weaken it. NumPy remains a host
        # dependency (including user-site installs); record its version above.
        checker=[sys.executable,'-E','-B','-u',str(chip/'model/core_control.py')]
        options=[str(run_dir),'--n',str(a.n),'--k',str(k),'--bb',str(bb),'--slots',str(slots)]
        if bucket0 != slots:
            options.extend(['--bucket0-slots',str(bucket0)])
        run([*checker,'prepare',*options],'prepare.log',1800)
        verify_snapshot(build,files)
        local=lambda p:'/work/'+str(p.relative_to(ROOT))
        base=['docker','run','--rm','--name',container,'--network=none','--cpus=2','--memory=6g','--pids-limit=256','-u',f'{os.getuid()}:{os.getgid()}',
              '-e','CCACHE_DISABLE=1','-v',str(ROOT)+':/work']
        compile=[*base,'-w','/work',image,'--binary','--timing','-j','2',
                 '--output-groups',str(a.output_groups),'-Wall','--timescale','1ns/1ps',
                 '-Wno-DECLFILENAME','-Wno-UNUSEDPARAM','-Wno-UNUSEDSIGNAL',
                 '-Wno-PINCONNECTEMPTY','-Wno-PROCASSINIT','-Wno-BLKSEQ',
                 '--top-module','tb_core_control',*[f'-G{n}={v}' for n,v in params.items()],
                 '--Mdir',local(build/'obj'),'-o','simulation',
                 *[local(chip/'rtl'/(n+'.v')) for n in RTL],local(chip/'tb/tb_core_control.sv')]
        run(compile,'compile.log',a.compile_timeout,True)
        verify_snapshot(build,files)
        result['simulation_executable_sha256']=sha(build/'obj/simulation')
        run([*base,'-w',local(run_dir),'--entrypoint',local(build/'obj/simulation'),image],
            'simulation.log',a.simulation_timeout,True)
        # The checker writes only inside run/, never the runner's result.json.
        # An interruption before input/evidence binding cannot publish PASS.
        verify_snapshot(build,files)
        run([*checker,'check',*options],'check.log',1800)
        audit=json.loads((run_dir/'result.json').read_text())
        if audit.get('status')!='PASS':
            raise ValueError('independent audit did not pass')
        verify_snapshot(build,files)
        if sha(build/'obj/simulation')!=result['simulation_executable_sha256']:
            raise ValueError('simulation executable changed')
        result.update(status='PASS',audit=audit,archived_inputs_unchanged=True)
    except (OSError,ValueError,subprocess.SubprocessError) as exc:
        result['reason']=str(exc)
    finally:
        if active_container:
            try:
                cleanup=subprocess.run(['docker','stop','--time','5',container],capture_output=True,text=True,timeout=20)
                result['container_cleanup_exit_code']=cleanup.returncode
            except (OSError,subprocess.SubprocessError) as exc:
                result['container_cleanup_unresolved']=str(exc)
        result['evidence_sha256']={p.name:sha(p) for p in sorted(build.iterdir())
                                  if p.is_file() and p.name!='result.json'}
        result['evidence_sha256'].update({str(p.relative_to(build)):sha(p)
                                         for p in sorted(run_dir.rglob('*')) if p.is_file()})
        (build/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='evidence_sha256'},indent=2),flush=True)
    return result['status']=='PASS'


if __name__=='__main__':
    raise SystemExit(0 if main() else 1)
