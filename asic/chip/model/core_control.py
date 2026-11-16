"""Prepare/check digital-core UART integration, including in-flight cancellation."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from equihash_ref import Params, job_input, parse_packets, zcash_verify, indices_to_minimal
from par_model import solve_par


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mode',choices=['prepare','check'])
    ap.add_argument('build',type=Path)
    ap.add_argument('--n',type=int,default=48)
    ap.add_argument('--k',type=int,default=5)
    ap.add_argument('--bb',type=int,default=4)
    ap.add_argument('--slots',type=int,default=80)
    ap.add_argument('--bucket0-slots',type=int)
    a=ap.parse_args();p=Params(a.n,a.k)
    if a.bucket0_slots is not None and a.bucket0_slots < a.slots:
        ap.error('bucket-zero capacity cannot be below regular capacity')
    case=a.build/'case.json'
    if a.mode=='prepare':
        a.build.mkdir(parents=True,exist_ok=True)
        first=bytes((i*37+11)&255 for i in range(140))
        if a.n != 200:
            for seed in range(100):
                candidate=hashlib.shake_256(f'core-control:{seed}'.encode()).digest(140)
                stats={}
                sols=solve_par(p,job_input(candidate,0,0),a.bb,a.slots,stats=stats,bucket0_slots=a.bucket0_slots)
                if sols and not any(stats['dropped']):
                    first=candidate;break
            else: raise ValueError('no positive uncapped small test case')
        second=bytes((i*91+7)&255 for i in range(140))
        data={'n':p.n,'k':p.k,'bb':a.bb,'slots':a.slots,'headers':[first.hex(),second.hex()],
              'scope':'UART digital-core integration, not physical IO or broad yield qualification'}
        if a.bucket0_slots is not None:
            data['bucket0_slots']=a.bucket0_slots
        case.write_text(json.dumps(data,indent=2)+'\n')
        (a.build/'core_jobs.hex').write_text(''.join(f'{b:02x}\n' for b in first+second))
        return
    data=json.loads(case.read_text())
    assert (data['n'],data['k'],data['bb'],data['slots']) == (p.n,p.k,a.bb,a.slots)
    assert data.get('bucket0_slots') == a.bucket0_slots, 'bucket-zero capacity mismatch'
    headers=[bytes.fromhex(h) for h in data['headers']]
    packets=parse_packets(bytes(int(line,16) for line in (a.build/'core_rx.hex').read_text().splitlines()))
    sols={0x33:[],0x34:[],0x35:[]};done={};forwarded=[];pongs=[];verify=[]
    for typ,addr,payload in packets:
        if addr==0x7e:
            assert typ==0xf0 and len(payload)==4+4*p.nsol
            forwarded.append(bytes(payload));continue
        assert addr==0,('unexpected response address',addr)
        if typ==0x84:
            assert len(payload)==4 and payload[3]==1
            pongs.append(payload);continue
        assert typ in (0x81,0x85),('unexpected response',typ)
        job=payload[0];attempt=int.from_bytes(payload[1:4],'little')
        assert job in sols,('stale or invalid-CRC job reported',job)
        assert attempt==0,('unexpected completed/output attempt',attempt)
        if typ==0x85:
            assert len(payload)==5 and job not in done
            done[job]=payload[4];continue
        assert len(payload)==4+4*p.nsol
        sol=[int.from_bytes(payload[4+4*i:8+4*i],'big') for i in range(p.nsol)]
        header=job_input(headers[1 if job==0x34 else 0],0,0)
        assert zcash_verify(p,header,sol),('invalid solution/job association',job)
        assert sol not in sols[job],('duplicate solution',job)
        sols[job].append(sol)
        verify.append(header.hex()+' '+indices_to_minimal(p,sol).hex())
    assert len(pongs)==3,('PING responses',len(pongs))
    assert pongs[-1][1]&4 and not pongs[-1][1]&8,('BIST status',pongs[-1])
    assert len(forwarded)==4
    for frame,payload in enumerate(forwarded):
        assert payload==bytes((i*29+frame*17)&255 for i in range(4+4*p.nsol)), 'forwarded packet corruption'
    assert len(sols[0x33])==1,'in-flight solution must finish exactly once before abort'
    assert not sols[0x35], 'zero target leaked a solution'
    expected_d=solve_par(p,job_input(headers[1],0,0),a.bb,a.slots,bucket0_slots=a.bucket0_slots)
    assert sorted(sols[0x34])==sorted(expected_d),'replacement job solution mismatch'
    assert done.get(0x34)==len(expected_d),'replacement job DONE count'
    expected_e=solve_par(p,job_input(headers[0],0,0),a.bb,a.slots,bucket0_slots=a.bucket0_slots)
    assert expected_e and done.get(0x35)==len(expected_e),'filtered job DONE must count raw solutions'
    coverage=dict(line.split() for line in (a.build/'coverage.txt').read_text().splitlines())
    required=['bad_crc_ignored','generation_cancel','round_reset','bist_pass','backpressure_cycles','stop_during_solution','filter_drops','startup_bist_pass','reset_bist_pass']
    if a.n==200:
        required+=['bist_job_deferred','bist_stop_canceled']
    for key in required:
        assert int(coverage[key])>0,('coverage missing',key)
    if p.n==200: assert int(coverage['job_during_solution'])>0
    miner=(Path(__file__).resolve().parent/'../../../zig-out/bin/zcash-miner').resolve()
    with tempfile.NamedTemporaryFile('w') as f:
        f.write('\n'.join(verify)+'\n');f.flush()
        r=subprocess.run([str(miner),'--verify',f.name,'--params',f'{p.n},{p.k}'],capture_output=True,text=True)
        assert r.returncode==0,r.stderr
    result={'status':'PASS','solutions_verified':len(verify),'forwarded_packets':4,'coverage':coverage,
            'scope':data['scope'],'partial_job_solutions':len(sols[0x33]),'replacement_job_solutions':len(sols[0x34]),'filtered_raw_solutions':done[0x35]}
    (a.build/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__': main()
