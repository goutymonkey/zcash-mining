import json
from pathlib import Path
import tempfile
import unittest

from compare_architecture import REQUIRED_SOURCES, RUNNERS, COMPARISON_MODELS, activity_summary, verify_pair, verify_comparison_models
from compare_read_gating import sha


class ArchitectureComparisonTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup)
        self.old,self.new=[Path(tmp.name)/n for n in ('old','new')]
        for root,hpb in [(self.old,4),(self.new,3)]:
            files={name:'same source' for name in REQUIRED_SOURCES | RUNNERS}
            data={'source/'+name:body for name,body in files.items()}
            data.update({'source.tgz':'archive','obj/simulation':'simulation',
                         'run/solver_hdr.hex':'headers','run/solver_out.txt':'outputs',
                         'run/memory_accesses.csv':'activity'})
            retention=dict(solutions=5,reference_solutions=5,missing_reference_solutions=0,total_cycles=100)
            data['run/audit/summary.json']=json.dumps(dict(headers=16,results=dict(rtl=retention)))
            for name,body in data.items():
                p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(body)
            inputs=dict(parameters=dict(N=200,K=9,NH=16,PB=4,HPB=hpb,HASH_SPLIT=1),seed='same',image_id='same',
                        python_runtime={},compiler_options={},files={n:sha(root/'source'/n) for n in files},
                        source_sha256=sha(root/'source.tgz'),headers_sha256=sha(root/'run/solver_hdr.hex'))
            (root/'inputs.json').write_text(json.dumps(inputs))
            result=dict(status='PASS',archived_inputs_unchanged=True,headers=16,
                        simulation_executable_sha256=sha(root/'obj/simulation'),
                        **{'yield':retention}, evidence_sha256={n:sha(root/n) for n in
                        ['inputs.json','source.tgz','run/solver_hdr.hex','run/solver_out.txt','run/memory_accesses.csv','run/audit/summary.json']})
            (root/'result.json').write_text(json.dumps(result))

    def mutate_inputs(self,fn):
        p=self.new/'inputs.json';data=json.loads(p.read_text());fn(data);p.write_text(json.dumps(data));self.rebind('inputs.json')

    def rebind(self,name):
        p=self.new/'result.json';data=json.loads(p.read_text());data['evidence_sha256'][name]=sha(self.new/name);p.write_text(json.dumps(data))

    def test_exact_declared_hardware_change_is_accepted(self):
        a,b,changes=verify_pair(self.old,self.new,['HPB'])
        self.assertEqual((a['parameters']['HPB'],b['parameters']['HPB']),(4,3));self.assertEqual(changes,[])

    def test_undeclared_configuration_change_is_rejected(self):
        self.mutate_inputs(lambda d:d['parameters'].update(HASH_SPLIT=2))
        with self.assertRaisesRegex(ValueError,'declared experiment'):verify_pair(self.old,self.new,['HPB'])
        verify_pair(self.old,self.new,['HPB','HASH_SPLIT'])

    def test_algorithm_or_corpus_cannot_be_declared_as_hardware_change(self):
        for key in ['N','NH','seed','image_id']:
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,'supported architecture'):verify_pair(self.old,self.new,[key])

    def test_same_count_different_header_corpus_is_rejected(self):
        p=self.new/'run/solver_hdr.hex';p.write_text('other headers');self.rebind('run/solver_hdr.hex')
        self.mutate_inputs(lambda d:d.update(headers_sha256=sha(p)))
        with self.assertRaisesRegex(ValueError,'headers_sha256'):verify_pair(self.old,self.new,['HPB'])

    def test_rehashed_source_changes_cannot_confound_experiment(self):
        for name in ['asic/chip/rtl/zeq_eh_par.v','asic/chip/model/equihash_ref.py','zig-out/bin/zcash-miner','asic/chip/tb/tb_par.sv']:
            with self.subTest(name=name):
                p=self.new/'source'/name;before=p.read_text();p.write_text('changed')
                self.mutate_inputs(lambda d:d['files'].update({name:sha(p)}))
                with self.assertRaisesRegex(ValueError,'model or verifier differs'):verify_pair(self.old,self.new,['HPB'])
                p.write_text(before);self.mutate_inputs(lambda d:d['files'].update({name:sha(p)}))

    def test_runner_changes_are_disclosed(self):
        name='asic/chip/tb/qualify_par.py';p=self.new/'source'/name;p.write_text('new runner')
        self.mutate_inputs(lambda d:d['files'].update({name:sha(p)}))
        self.assertEqual(verify_pair(self.old,self.new,['HPB'])[2],[name])

    def test_tampered_activity_is_rejected(self):
        (self.new/'run/memory_accesses.csv').write_text('corrupt')
        with self.assertRaisesRegex(ValueError,'evidence hash mismatch'):verify_pair(self.old,self.new,['HPB'])

    def test_retention_loss_cannot_be_hidden_by_pass_result(self):
        p=self.new/'run/audit/summary.json';s=json.loads(p.read_text());s['results']['rtl']['missing_reference_solutions']=1
        p.write_text(json.dumps(s));self.rebind('run/audit/summary.json')
        with self.assertRaisesRegex(ValueError,'lost reference solutions'):verify_pair(self.old,self.new,['HPB'])

    def test_local_comparison_model_drift_is_rejected(self):
        model=self.new/'local-model';model.mkdir()
        inputs={'files':{}}
        for name in COMPARISON_MODELS:
            p=model/name;p.write_text('frozen model')
            inputs['files']['asic/chip/model/'+name]=sha(p)
        verify_comparison_models(inputs,model)
        (model/'equihash_ref.py').write_text('different verification')
        with self.assertRaisesRegex(ValueError,'comparison model differs'):
            verify_comparison_models(inputs,model)

    def test_activity_requires_every_expected_engine(self):
        p=self.new/'run/memory_accesses.csv'
        rows=['engine,table,width_bits,read_words,write_words']
        for e in range(2):
            for table in ['value','key','histogram','parents','leaf_indices','order']:
                rows.append(f'{e},{table},8,2,1')
        p.write_text('\n'.join(rows)+'\n')
        self.assertEqual(activity_summary(p,2,3)['accessed_bytes_per_solution'],12)
        with self.assertRaisesRegex(ValueError,'engine count'):activity_summary(p,4,3)
        with self.assertRaisesRegex(ValueError,'solution count'):activity_summary(p,2,0)

if __name__=='__main__':unittest.main()
