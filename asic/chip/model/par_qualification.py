"""Prepare a diverse fixed corpus and invoke strict, untruncated RTL yield audit."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import sys

from equihash_ref import job_input


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mode',choices=('prepare','check'))
    ap.add_argument('build',type=Path)
    for name in ('n','k','bb','slots','headers'):ap.add_argument('--'+name,type=int,required=True)
    ap.add_argument('--seed',required=True)
    ap.add_argument('--bucket0-slots',type=int)
    a=ap.parse_args()
    headers=[job_input(hashlib.shake_256(f'{a.seed}:{i}'.encode()).digest(140),addr=i%4,attempt=i) for i in range(a.headers)]
    expected=''.join(h[::-1].hex()+'\n' for h in headers)
    path=a.build/'solver_hdr.hex'
    if a.mode=='prepare':path.write_text(expected);return
    if path.read_text()!=expected:raise ValueError('RTL input corpus differs from requested headers')
    extra=[] if a.bucket0_slots is None else ['--bucket0-slots',str(a.bucket0_slots)]
    subprocess.run([sys.executable,'-E','-B','-u',str(Path(__file__).with_name('yield_study.py')),
                    '--n',str(a.n),'--k',str(a.k),'--bb',str(a.bb),'--capacities',str(a.slots),
                    '--rtl-build',str(a.build),'--output',str(a.build/'audit'),*extra],check=True)


if __name__=='__main__':main()
