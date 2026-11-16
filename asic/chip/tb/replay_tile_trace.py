#!/usr/bin/env python3
"""Replay a validated packed-tile trace against frozen generic RTL, not physical IP."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'model'))
from audit_tile_trace import audit


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--trace',type=Path,required=True)
    parser.add_argument('--build',type=Path,required=True)
    args=parser.parse_args()
    review=audit(args.trace)
    build=args.build.resolve();build.relative_to(ROOT/'build')
    build.mkdir(parents=True,exist_ok=False)
    source=build/'source';source.mkdir()
    names=['rtl/zeq_mbist.v','rtl/zeq_ram.v','rtl/zeq_packed_values.v',
           'tb/tb_packed_tile_replay.sv','tb/replay_tile_trace.py','model/audit_tile_trace.py']
    import hashlib
    def sha(p):
        h=hashlib.sha256()
        with p.open('rb') as stream:
            for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
        return h.hexdigest()
    for name in names:
        dest=source/name;dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(ROOT/name,dest)
    bindings={name:sha(source/name) for name in names}
    shutil.copyfile(args.trace,build/'packed_tile.trace')
    if sha(build/'packed_tile.trace')!=review['trace_sha256']:raise ValueError('trace changed during copy')
    image=subprocess.check_output(['docker','image','inspect','--format','{{.Id}}','verilator/verilator:latest'],text=True).strip()
    local=lambda path:'/work/'+str(path.relative_to(ROOT))
    container='zeq-replay-'+build.name
    base=['docker','run','--rm','--name',container,'--cpus','2','--memory','4g','--ulimit','core=0',
          '-u',f'{os.getuid()}:{os.getgid()}','-e','CCACHE_DISABLE=1','-v',str(ROOT)+':/work','-w',local(build)]
    commands=[]
    def execute(command,log):
        commands.append(command)
        with (build/log).open('w') as out:
            try:subprocess.run(command,stdout=out,stderr=subprocess.STDOUT,check=True,timeout=900)
            except subprocess.TimeoutExpired:
                subprocess.run(['docker','stop','--time','5',container],capture_output=True,timeout=20)
                raise
    result=dict(status='FAIL',release_eligible=False,production_tapeout_ready=False,
                scope='Generic RTL functional replay only; workload provenance and physical SRAM qualification are separate.',
                trace=review,image_id=image,source_sha256=bindings)
    try:
        execute([*base,image,'--binary','--timing','-j','2','-Wall','--timescale','1ns/1ps',
                 '-Wno-DECLFILENAME','-Wno-UNUSEDPARAM','-Wno-UNUSEDSIGNAL','-Wno-PROCASSINIT',
                 '-Wno-BLKSEQ','-Wno-PINCONNECTEMPTY','--top-module','tb_packed_tile_replay',
                 *[f'-G{k}={v}' for k,v in review['geometry'].items()],
                 '--Mdir',local(build/'obj'),'-o','sim',*[local(source/n) for n in names[:4]]],'compile.log')
        execute([*base,'--entrypoint',local(build/'obj/sim'),image],'replay.log')
        if f"TILE_REPLAY_PASS cycles={review['cycles']}" not in (build/'replay.log').read_text():
            raise ValueError('missing replay completion')
        if sha(build/'packed_tile.trace')!=review['trace_sha256']:raise ValueError('trace changed')
        for name,digest in bindings.items():
            if sha(source/name)!=digest:raise ValueError('source changed')
        result['status']='PASS'
    except (OSError,ValueError,subprocess.SubprocessError) as error:result['reason']=str(error)
    result['commands']=commands
    result['evidence_sha256']={p.name:sha(p) for p in build.iterdir() if p.is_file()}
    if (build/'obj/sim').exists():result['evidence_sha256']['obj/sim']=sha(build/'obj/sim')
    (build/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(result['status'])
    return 0 if result['status']=='PASS' else 1


if __name__=='__main__':raise SystemExit(main())
