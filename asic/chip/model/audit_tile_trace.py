"""Validate a complete packed-tile trace; no workload or physical qualification."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def audit(path):
    digest = hashlib.sha256()
    with path.open('rb', buffering=1024*1024) as stream:
        def line():
            raw = stream.readline()
            digest.update(raw)
            return raw.decode('ascii').split()
        header = line()
        if len(header) != 6 or header[0] != 'ZEQ_TILE_V1':
            raise ValueError('invalid trace header')
        n, k, pw, aw, depth = map(int, header[1:])
        if min(n,k,pw,aw,depth) <= 0 or n % (k+1) or depth > (1 << aw):
            raise ValueError('invalid trace geometry')
        vw, lw = n-n//(k+1), k.bit_length()
        fields = [('rst',1),('phase',lw),('we',1),('waddr',aw),('wvalue',vw),
                  ('wparent',pw),('re',1),('raddr',aw),('pre',1),('plevel',lw),
                  ('paddr',aw),('bist_start',1),('rvalue',vw),('pvalue',pw),
                  ('bist_done',1),('bist_fail',1)]
        bits = sum(width for _,width in fields)
        hexadecimal = re.compile(r'[0-9a-fA-F]+').fullmatch
        cycles = 0
        counts = {key:0 for key in ('reset','bist_start','write','value_read','parent_read','idle')}
        while True:
            row = line()
            if len(row) != 2:
                raise ValueError('missing footer or malformed trace row')
            if row[0] == 'END':
                if int(row[1]) != cycles or not cycles or stream.read(1):
                    raise ValueError('invalid trace footer or trailing data')
                break
            if int(row[0]) != cycles or hexadecimal(row[1]) is None:
                raise ValueError('invalid cycle sequence or unknown logic value')
            value = int(row[1],16)
            if value >= (1 << bits):
                raise ValueError('sample exceeds interface width')
            sample = {}
            for key,width in reversed(fields):
                sample[key] = value & ((1 << width)-1)
                value >>= width
            if ((sample['we'] or sample['re'] or sample['pre']) and sample['phase'] > k
                    or sample['pre'] and sample['plevel'] >= k):
                raise ValueError('invalid round in trace')
            for enable,addr in [('we','waddr'),('re','raddr'),('pre','paddr')]:
                if sample[enable] and sample[addr] >= depth:
                    raise ValueError('enabled address outside tile')
            counts['reset'] += sample['rst']
            counts['bist_start'] += sample['bist_start']
            counts['write'] += sample['we']
            counts['value_read'] += sample['re']
            counts['parent_read'] += sample['pre']
            counts['idle'] += int(not any(sample[x] for x in ('rst','we','re','pre','bist_start')))
            cycles += 1
    if not counts['reset']:
        raise ValueError('trace has no reset for replay initialization')
    return dict(schema=1, status='TRACE_FORMAT_VALID', trace_sha256=digest.hexdigest(),
                geometry=dict(N=n,K=k,PW=pw,AW=aw,DEPTH=depth), cycles=cycles, activity=counts,
                scope='Pre-edge module interface samples; idle means no external request, not no internal BIST activity. Counts may overlap. Functional replay and independently verified workload evidence are separate requirements.',
                release_eligible=False, production_tapeout_ready=False)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if args.output.exists(): parser.error('output already exists')
    try: result=audit(args.trace)
    except (ValueError,OSError,UnicodeError) as error: parser.error(str(error))
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
