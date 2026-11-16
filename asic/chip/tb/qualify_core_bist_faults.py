#!/usr/bin/env python3
"""Qualify behavioral RAM fault propagation and quarantine through a small core.

N48/K5, four engines, packed and separate memories. Read-output stuck-at faults
exercise each memory class and all six packed slices in the last engine, plus
the first engine's leaf-index bank. Actual March engines and core aggregation
must detect faults; UART JOB/STOP/PING/BIST check quarantine, retest and reset.
No physical SRAM fault coverage, compiler repair or N200-scale qualification.
Run inside the pinned LibreLane image.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

from qualify_core_control import ROOT, RTL, sha

FILES = ['rtl/'+name+'.v' for name in RTL]
FILES += ['tb/tb_core_bist_fault.sv','tb/qualify_core_bist_faults.py','tb/qualify_core_control.py']


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build',required=True)
    ap.add_argument('--image-id',required=True)
    a=ap.parse_args()
    if not re.fullmatch(r'build/[A-Za-z0-9_-]+',a.build):
        ap.error('fresh simple build/ path required')
    if not re.fullmatch(r'sha256:[0-9a-f]{64}',a.image_id):
        ap.error('inspected immutable EDA image ID required')
    b=ROOT/a.build;b.mkdir()
    for name in FILES:
        target=b/'source'/name;target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(ROOT/name,target)
    files={name:sha(b/'source'/name) for name in FILES}
    inputs=dict(files=files,image_id=a.image_id,parameters=dict(N=48,K=5,PB=2,SLOTS=80,BOOT_BIST=1),
                tool_sha256={name:sha(Path(shutil.which(name))) for name in ['iverilog','vvp']},
                scope=__doc__.strip())
    (b/'inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
    cases=[]
    mutations={
        'masked-bank-failure':('rtl/zeq_eh_par.v','assign bist_fail = |e_bf;',"assign bist_fail = 1'b0;",
                               'BIST fault did not reach production link'),
        'ignore-quarantine':('rtl/zeq_link.v','!bist_fault',"1'b1",
                             'memory qualification bypassed by mining launch'),
    }
    result=dict(status='FAIL',scope=__doc__.strip(),release_eligible=False)
    try:
        for packed in [0,1]:
            for mode in ['healthy',*mutations]:
                c=b/f'packed{packed}-{mode}';c.mkdir()
                sources=[b/'source'/name for name in FILES if name.endswith(('.v','.sv'))]
                if mode in mutations:
                    name,old,new,_=mutations[mode]
                    original=b/'source'/name;body=original.read_text()
                    if old not in body:raise ValueError('missing mutation site: '+mode)
                    mutant=c/original.name;mutant.write_text(body.replace(old,new))
                    sources=[mutant if p==original else p for p in sources]
                with (c/'compile.log').open('w') as out:
                    subprocess.run(['iverilog','-g2012','-s','tb_core_bist_fault',
                        f'-Ptb_core_bist_fault.PACKED_TABLES={packed}','-o',str(c/'simulation'),
                        *map(str,sources)],stdout=out,stderr=subprocess.STDOUT,check=True,timeout=120)
                banks=range(-1,10 if packed==0 else 13) if mode=='healthy' else [-1,1]
                for bank in banks:
                    log=c/f'bank{bank}.log'
                    with log.open('w') as out:
                        proc=subprocess.run(['vvp',str(c/'simulation'),f'+bank={bank}'],
                            stdout=out,stderr=subprocess.STDOUT,timeout=60)
                    negative=mode!='healthy' and bank>=0
                    marker=mutations[mode][3] if negative else 'core RAM BIST fault PASS:'
                    passed=(proc.returncode!=0 if negative else proc.returncode==0) and marker in log.read_text()
                    cases.append(dict(packed_tables=packed,mode=mode,bank=bank,status='PASS' if passed else 'FAIL',
                        check='reachable aggregation/ownership fault detected' if negative else 'real March BIST RAM-output fault/recovery',
                        exit_code=proc.returncode,expected_marker=marker,log_sha256=sha(log),
                        executable_sha256=sha(c/'simulation')))
                    print(f'packed={packed} {mode} bank={bank}: '+cases[-1]['status'],flush=True)
                    if not passed:raise ValueError('fault qualification failed: '+str(log))
        unchanged=all(sha(b/'source'/name)==h for name,h in files.items())
        result.update(status='PASS' if unchanged and len(cases)==33 else 'FAIL',
                      source_unchanged=unchanged,inputs_sha256=sha(b/'inputs.json'))
    except (OSError,ValueError,subprocess.SubprocessError) as exc:
        result['reason']=str(exc)
    result['cases']=cases
    result['evidence_sha256']={str(p.relative_to(b)):sha(p) for p in b.rglob('*') if p.is_file() and p!=b/'result.json'}
    (b/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['status']=='PASS'


if __name__=='__main__':
    raise SystemExit(0 if main() else 1)
