#!/usr/bin/env python3
"""Source-frozen generic solver synthesis with independently reconciled table RAMs.

Retains logical SRAM cells; does not establish production macro mapping, area,
frequency, power, full-solver equivalence or release readiness.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

if __package__:
    from .solver_mapping import map_batches
    from .solver_resume import resume_mapping, link_verified
else:
    from solver_mapping import map_batches
    from solver_resume import resume_mapping, link_verified

ROOT=Path(__file__).resolve().parents[1]
RTL=('zeq_blake2b','zeq_eh_hash','zeq_mbist','zeq_ram','zeq_xbar_arb',
     'zeq_row_network','zeq_packed_values','zeq_eh_par')


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
    return h.hexdigest()


def verify(build,files):
    for name,digest in files.items():
        if sha(build/name)!=digest:raise ValueError('archived input changed: '+name)


def reuse_coarse(origin, build, params, image, files, script):
    """Reuse only a completed coarse stage bound to these exact RTL/model inputs."""
    previous=json.loads((origin/'result.json').read_text())
    inputs=json.loads((origin/'inputs.json').read_text())
    if any(previous['stages'][stage]['exit_code'] != 0 for stage in ('coarse','coarse-inventory')):
        raise ValueError('coarse source did not complete required stages')
    if inputs['parameters'] != params or previous['parameters'] != params or inputs['image_id'] != image:
        raise ValueError('coarse source parameters or tool image differ')
    verify(origin, inputs['source_sha256'])
    for name,digest in files.items():
        if name.startswith(('source/rtl/','source/model/')) and inputs['source_sha256'].get(name) != digest:
            raise ValueError('coarse source RTL/model differs: '+name)
    for name in ('inputs.json','coarse.ys','coarse.il','coarse.json','coarse-inventory.json'):
        if sha(origin/name) != previous['evidence_sha256'][name]:
            raise ValueError('coarse source artifact changed: '+name)
    if (origin/'coarse.ys').read_text() != script:
        raise ValueError('coarse synthesis script differs')
    for name in ('coarse.il','coarse.json'):
        link_verified(origin/name,build/name,previous['evidence_sha256'][name])
    shutil.copyfile(origin/'inputs.json',build/'coarse-origin-inputs.json')
    shutil.copyfile(origin/'result.json',build/'coarse-origin-result.json')
    return dict(exit_code=0,reused=True,origin=str(origin),origin_status=previous['status'],
                origin_result_sha256=sha(origin/'result.json'))


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build',required=True)
    ap.add_argument('--n',type=int,choices=(48,200),default=200)
    ap.add_argument('--engines',type=int)
    ap.add_argument('--slots',type=int)
    ap.add_argument('--bucket0-slots',type=int)
    ap.add_argument('--image',default='ghcr.io/librelane/librelane:3.0.14')
    ap.add_argument('--timeout',type=int,default=1800,help='per synthesis stage, seconds')
    ap.add_argument('--startup-timeout',type=int,default=120,
                    help='additional Docker startup allowance per stage, seconds; does not change the Yosys execution timeout')
    ap.add_argument('--coarse-only',action='store_true')
    ap.add_argument('--reuse-coarse',help='verified existing build/name with identical RTL, models, parameters and image')
    ap.add_argument('--resume-mapping',help='verified completed mapping prefix to continue in a fresh build')
    ap.add_argument('--mapping-batch-size',type=int,default=256)
    ap.add_argument('--compress-checkpoints',action='store_true',
                    help='losslessly gzip consumed mapping checkpoints with a restoration manifest')
    a=ap.parse_args()
    if not re.fullmatch(r'build/[A-Za-z0-9_-]+',a.build) or a.timeout<=0 or a.startup_timeout<=0:
        ap.error('fresh build/name path and positive timeout required')
    if a.reuse_coarse and (not re.fullmatch(r'build/[A-Za-z0-9_-]+',a.reuse_coarse) or a.reuse_coarse==a.build):
        ap.error('reuse requires a different existing build/name path')
    if a.resume_mapping and (a.reuse_coarse or a.coarse_only or not re.fullmatch(r'build/[A-Za-z0-9_-]+',a.resume_mapping) or a.resume_mapping==a.build):
        ap.error('resume requires a different build/name and excludes coarse-only/reuse-coarse')
    coarse_origin=a.resume_mapping or a.reuse_coarse
    if not 1 <= a.mapping_batch_size <= 1024:
        ap.error('mapping batch size must be in 1..1024')
    k,bb,max_sb,default_eng,default_slots=(9,12,10,16,640) if a.n==200 else (5,4,7,4,128)
    eng=default_eng if a.engines is None else a.engines;slots=a.slots if a.slots is not None else default_slots
    if eng<2 or eng&(eng-1) or eng>=1<<bb or not 1<=slots<=1<<max_sb:
        ap.error('engines must be a power of two below bucket count; slots must fit address width')
    sb=max(1,(slots-1).bit_length());bucket0=slots if a.bucket0_slots is None else a.bucket0_slots
    if not slots<=bucket0<=1<<sb:ap.error('bucket-zero slots must fit existing slot bits')
    params=dict(N=a.n,K=k,BB=bb,PB=eng.bit_length()-1,HPB=eng.bit_length()-1,
                SPLIT=1,SB=sb,SLOTS=slots,BUCKET0_SLOTS=bucket0,GMAX=16,GROUP_REPLAY=0,
                PACKED_TABLES=1,SPLIT_KEYS=1,COMPACT_VALUES=1,STAGED_NETWORK=0)
    b=ROOT/a.build;b.mkdir(parents=True,exist_ok=False)
    result=dict(status='FAIL',scope=__doc__.strip(),parameters=params,stages={})
    active=None
    def interrupted(signum,frame):raise InterruptedError('interrupted by signal '+str(signum))
    signal.signal(signal.SIGINT,interrupted);signal.signal(signal.SIGTERM,interrupted)
    try:
        sources=[*(ROOT/'rtl'/(n+'.v') for n in RTL),ROOT/'model/production_budget.py',
                 ROOT/'model/check_ram_inventory.py',Path(__file__).resolve(),
                 ROOT/'pd/solver_mapping.py',ROOT/'pd/solver_resume.py',ROOT/'pd/synthesis_stage.py']
        for p in sources:
            dst=b/'source'/p.relative_to(ROOT);dst.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(p,dst)
        files={str(p.relative_to(b)):sha(p) for p in sorted((b/'source').rglob('*')) if p.is_file()}
        image=subprocess.check_output(['docker','image','inspect','--format','{{.Id}}',a.image],text=True,timeout=30).strip()
        inputs=dict(parameters=params,image_id=image,source_sha256=files,
                    timeout_seconds=a.timeout,memory_limit='12g',cpu_limit=2,
                    container_startup_timeout_seconds=a.startup_timeout,
                    memory_swap_limit='12g',mapping_batch_size=a.mapping_batch_size,
                    compress_checkpoints=a.compress_checkpoints,
                    reuse_coarse=coarse_origin,resume_mapping=a.resume_mapping,
                    state_machine_recoding=False,coarse_only=a.coarse_only)
        (b/'inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
        def execute(name,entry,args,timeout):
            nonlocal active
            verify(b,files)
            if shutil.disk_usage(b).free < 10*1024**3:
                raise ValueError('disk guard: fewer than 10 GiB free')
            active='zeq-synth-'+b.name+'-'+name
            command=['docker','run','--rm','--name',active,'--memory','12g','--memory-swap','12g','--cpus','2',
                     '-u',f'{os.getuid()}:{os.getgid()}','-v',str(b)+':/work','-w','/work',
                     '--entrypoint',entry,image,*args]
            start=time.monotonic()
            with (b/(name+'.log')).open('w') as out:
                proc=subprocess.run(command,stdout=out,stderr=subprocess.STDOUT,timeout=timeout+a.startup_timeout)
            result['stages'][name]=dict(exit_code=proc.returncode,elapsed_seconds=time.monotonic()-start)
            active=None
            if proc.returncode:raise ValueError('stage failed: '+name)
            verify(b,files)
        def yosys_stage(name,netlist=None,extra_inputs=()):
            args=['source/pd/synthesis_stage.py','--name',name,'--timeout',str(a.timeout)]
            for item in ([netlist] if netlist else list(files)) + list(extra_inputs):
                args.extend(['--input',item])
            try:
                execute(name,'python3',args,a.timeout)
            finally:
                evidence=b/(name+'-execution.json')
                if evidence.is_file():
                    result['stages'].setdefault(name,{})['execution']=json.loads(evidence.read_text())
            detail=result['stages'].get(name,{}).get('execution',{})
            if detail.get('status')!='PASS' or not detail.get('inputs_unchanged'):
                raise ValueError('invalid Yosys stage evidence: '+name)
        execute('version','yosys',['-V'],0)
        ys='read_verilog -sv -D SYNTHESIS '+' '.join('source/rtl/'+n+'.v' for n in RTL)+'\n'
        ys+='chparam '+' '.join(f'-set {n} {v}' for n,v in params.items())+' zeq_eh_par\n'
        ys+='''synth -nofsm -top zeq_eh_par -flatten -run begin:fine
check -assert
stat
write_rtlil coarse.il
write_json coarse.json
'''
        (b/'coarse.ys').write_text(ys)
        if coarse_origin:
            result['stages']['coarse']=reuse_coarse(ROOT/coarse_origin,b,params,image,files,ys)
        else:
            yosys_stage('coarse')
        inventory_args=['source/model/check_ram_inventory.py','coarse.json',
                        '--n',str(a.n),'--k',str(k),'--bb',str(bb),'--pb',str(params['PB']),
                        '--sb',str(sb),'--capacity',str(slots),'--bucket0-capacity',str(bucket0),
                        '--output','coarse-inventory.json']
        execute('coarse-inventory','python3',inventory_args,180)
        inv=json.loads((b/'coarse-inventory.json').read_text())
        count=sum(s['count'] for s in inv['shapes'])
        result['logical_sram_bits']=inv['ram_bits'];result['logical_sram_cells']=count
        if not a.coarse_only:
            (b/'premap.ys').write_text(f'''read_rtlil coarse.il
opt -fast -full
select -set table_mems t:$mem_v2 c:*.m_*.mem %i
select -assert-count {count} @table_mems
memory_map t:$mem_v2 @table_mems %d
select -clear
delete t:$scopeinfo
opt -full
check -assert
write_rtlil premap.il
''')
            (b/'simple.ys').write_text(f'''read_rtlil premap.il
simplemap
opt -fast
check -assert
select -assert-count {count} t:$mem_v2
write_rtlil simple.il
''')
            seed,completed='simple.il',[]
            if a.resume_mapping:
                seed,completed,reused=resume_mapping(ROOT/a.resume_mapping,b,params,image,files,count,a.mapping_batch_size)
                result['stages'].update(reused)
                result['resumed_after_batches']=len(completed)
            else:
                yosys_stage('premap','coarse.il')
                yosys_stage('simple','premap.il')
            last,history=map_batches(b,yosys_stage,count,a.mapping_batch_size,
                                     compress_checkpoints=a.compress_checkpoints,initial=seed,prior_history=completed)
            result['mapping_batches']=history
            (b/'optimize.ys').write_text(f'''read_rtlil {last}
opt -fast
check -assert
select -assert-count {count} t:$mem_v2
select -assert-none t:$* t:$_* %d t:$mem_v2 %d
write_rtlil optimized.il
''')
            yosys_stage('optimize',last)
            (b/'generic.ys').write_text(f'''read_rtlil optimized.il
abc -g simple
opt_clean
check -assert
# Only the reconciled table SRAMs may remain as coarse cells.
select -assert-count {count} t:$mem_v2
select -assert-none t:$* t:$_* %d t:$mem_v2 %d
tee -o generic-stats.json stat -json
write_rtlil generic.il
write_json generic.json
''')
            yosys_stage('generic','optimized.il')
            args=inventory_args.copy();args[1]='generic.json';args[-1]='generic-inventory.json'
            execute('generic-inventory','python3',args,180)
            if json.loads((b/'generic-inventory.json').read_text())!=inv:
                raise ValueError('table inventory changed during logic mapping')
            result['generic_statistics']=json.loads((b/'generic-stats.json').read_text())
        verify(b,files)
        result.update(status='PASS',archived_inputs_unchanged=True,
                      completed='coarse synthesis' if a.coarse_only else 'generic logic synthesis with retained table SRAMs')
    except (KeyError,OSError,ValueError,subprocess.SubprocessError) as exc:
        result['reason']=str(exc)
    finally:
        if active:
            try:
                cleanup=subprocess.run(['docker','stop','--time','2',active],capture_output=True,text=True,timeout=20)
                result['container_cleanup_exit_code']=cleanup.returncode
            except (OSError,subprocess.SubprocessError) as exc:result['cleanup_error']=str(exc)
        result['evidence_sha256']={str(p.relative_to(b)):sha(p) for p in b.rglob('*') if p.is_file() and p!=b/'result.json'}
        (b/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('evidence_sha256','generic_statistics')},indent=2))
    return result['status']=='PASS'


if __name__=='__main__':raise SystemExit(0 if main() else 1)
