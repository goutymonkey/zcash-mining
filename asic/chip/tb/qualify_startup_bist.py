#!/usr/bin/env python3
"""Qualify startup memory-test ownership through actual UARTs at N48/N200.

Run inside the pinned EDA image. Memory completion is a deliberate stale-DONE
model, not a physical SRAM. Mining launch, queued JOB/STOP, failure quarantine,
retest and reset requalification are checked; two control faults must fail.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FILES = ['rtl/'+n+'.v' for n in ['zeq_mbist','zeq_ram','zeq_fifo','zeq_uart','zeq_link']]
FILES += ['tb/tb_link_bist.sv','tb/qualify_startup_bist.py']


def sha(path):
    import hashlib
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build',required=True)
    ap.add_argument('--image-id',required=True)
    a = ap.parse_args()
    if not re.fullmatch(r'build/[A-Za-z0-9_-]+',a.build):
        ap.error('fresh simple build/ path required')
    if not re.fullmatch(r'sha256:[0-9a-f]{64}',a.image_id):
        ap.error('inspected immutable EDA image ID required')
    b = ROOT/a.build
    b.mkdir()
    for name in FILES:
        target = b/'source'/name
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(ROOT/name,target)
    files = {name:sha(b/'source'/name) for name in FILES}
    record = dict(image_id=a.image_id,files=files,scope=__doc__.strip(),
                  tool_sha256={name:sha(Path(shutil.which(name))) for name in ['iverilog','vvp']},
                  iverilog_version=subprocess.run(['iverilog','-V'],capture_output=True,text=True,check=True).stdout.splitlines()[0])
    (b/'inputs.json').write_text(json.dumps(record,indent=2)+'\n')
    cases = []
    mutations = {
        'boot-disabled': ('bist_pending <= (HAS_BIST != 0 && BOOT_BIST != 0);',"bist_pending <= 1'b0;"),
        'stale-done': ('bist_running && bist_armed && bist_done','bist_running && bist_done'),
    }
    try:
        for n,k in [(48,5),(200,9)]:
            for mode in ['startup','legacy','unsupported','boot-disabled','stale-done']:
                c = b/f'{mode}-{n}'
                c.mkdir()
                rtl = b/'source/rtl/zeq_link.v'
                if mode in mutations:
                    old,new = mutations[mode]
                    body = rtl.read_text()
                    if body.count(old)!=1:
                        raise ValueError('missing/ambiguous mutation site: '+mode)
                    rtl = c/'zeq_link_mutant.v'
                    rtl.write_text(body.replace(old,new))
                sources = [str(b/'source'/f) for f in FILES if f.endswith(('.v','.sv')) and f!='rtl/zeq_link.v']+[str(rtl)]
                cmd = ['iverilog','-g2012','-s','tb_link_bist',f'-Ptb_link_bist.N={n}',
                       f'-Ptb_link_bist.K={k}',f'-Ptb_link_bist.BOOT_BIST={0 if mode=="legacy" else 1}',
                       f'-Ptb_link_bist.HAS_BIST={0 if mode=="unsupported" else 1}',
                       '-o',str(c/'simulation'),*sources]
                with (c/'compile.log').open('w') as out:
                    subprocess.run(cmd,stdout=out,stderr=subprocess.STDOUT,check=True,timeout=120)
                with (c/'simulation.log').open('w') as out:
                    proc = subprocess.run(['vvp',str(c/'simulation')],stdout=out,stderr=subprocess.STDOUT,timeout=60)
                body = (c/'simulation.log').read_text()
                marker = 'startup BIST PASS' if mode=='startup' else 'link BIST interlock PASS'
                if mode=='boot-disabled':
                    marker = 'startup BIST did not acquire ownership'
                if mode=='stale-done':
                    marker = 'startup stale DONE or early JOB bypassed memory qualification'
                negative = mode in mutations
                passed = (proc.returncode!=0 if negative else proc.returncode==0) and marker in body
                cases.append(dict(n=n,k=k,mode=mode,status='PASS' if passed else 'FAIL',
                                  check='reachable control fault detected' if negative else 'UART startup/compatibility',
                                  exit_code=proc.returncode,expected_marker=marker,
                                  executable_sha256=sha(c/'simulation'),log_sha256=sha(c/'simulation.log')))
                print(f'{mode} N={n}: '+cases[-1]['status'],flush=True)
        unchanged = all(sha(b/'source'/f)==h for f,h in files.items())
        result = dict(status='PASS' if unchanged and len(cases)==10 and all(c['status']=='PASS' for c in cases) else 'FAIL',
                      cases=cases,source_unchanged=unchanged,inputs_sha256=sha(b/'inputs.json'),
                      scope=__doc__.strip(),release_eligible=False)
    except (OSError,ValueError,subprocess.SubprocessError) as exc:
        result = dict(status='FAIL',cases=cases,reason=str(exc),release_eligible=False)
    result['evidence_sha256'] = {str(p.relative_to(b)):sha(p) for p in b.rglob('*') if p.is_file() and p!=b/'result.json'}
    (b/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['status']=='PASS'


if __name__ == '__main__':
    raise SystemExit(0 if main() else 1)
