"""Reconcile logical RAM inventory against a flattened Yosys memory netlist."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re

from production_budget import inventory


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('netlist',type=Path)
    for key,value in [('n',48),('k',5),('bb',4),('pb',2),('sb',7),('capacity',80)]:
        ap.add_argument('--'+key,type=int,default=value)
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--bucket0-capacity',type=int)
    a=ap.parse_args()
    expected=inventory(n=a.n,k=a.k,bb=a.bb,pb=a.pb,sb=a.sb,capacity=a.capacity,compact=True,split_keys=True,packed=True,bucket0_capacity=a.bucket0_capacity)
    cells=json.loads(a.netlist.read_text())['modules']['zeq_eh_par']['cells']
    actual=Counter()
    old=[]
    for name,cell in cells.items():
        if not cell['type'].startswith('$mem') or not re.search(r'\.m_[^.]+\.mem$',name):
            continue
        if '.g_packed.' in name: table='packed_values_and_parents'
        elif '.g_split_keys.' in name: table='key'
        elif '.m_hist' in name: table='histogram'
        elif '.m_idx.' in name: table='leaf_indices'
        elif '.m_order.' in name: table='order'
        else:
            old.append(name)
            continue
        p=cell['parameters']
        actual[(table,int(p['WIDTH'],2),int(p['SIZE'],2))]+=1
    want=Counter({(s['name'],s['width'],s['depth']):s['count'] for s in expected['logical_memory_shapes']})
    if old or actual != want:
        raise ValueError(f'RAM inventory mismatch: unexpected={old}, missing={want-actual}, extra={actual-want}')
    result={'status':'PASS','scope':'logical solver table RAMs after synthesis optimization; excludes registers, ROM, macro padding and physical area',
            'parameters':expected['parameters'],'ram_bits':sum(w*d*c for (_,w,d),c in actual.items()),
            'shapes':expected['logical_memory_shapes'],'legacy_value_pointer_memories_retained':old}
    a.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':
    main()
