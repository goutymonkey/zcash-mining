import json
from pathlib import Path
import tempfile
import unittest

from cover_partitions import prepare, sha, partition_names, terminal_status, bound, is_prove_config, reuse_coverage, proof_config


class CoverageTests(unittest.TestCase):
    def fixture(self, root):
        origin = root/'origin';parts=origin/'eqy/partitions';parts.mkdir(parents=True)
        (origin/'eqy/partition.list').write_text('zeq_eh_par zeq_eh_par.a xbits : a[0]\n')
        for ext in ('sv','il'):
            (parts/('zeq_eh_par.a.'+ext)).write_text('source '+ext)
        (parts/'zeq_eh_par.a.json').write_text(json.dumps(dict(partition=dict(name='zeq_eh_par.a',outbits={'a':[0]}))))
        self.bind_origin(origin)
        review=root/'production/review.json';review.parent.mkdir();review.write_text(json.dumps(dict(cases={},evidence_sha256={})))
        return origin, review, root/'build'

    def bind_origin(self, origin):
        evidence={str(p.relative_to(origin)):sha(p) for p in (origin/'eqy').rglob('*') if p.is_file()}
        (origin/'result.json').write_text(json.dumps(dict(status='FAIL',evidence_sha256=evidence)))

    def test_plan_counts_all_unproved_obligations(self):
        with tempfile.TemporaryDirectory() as t:
            args=self.fixture(Path(t));r=prepare(*args)
            self.assertEqual(r['required'],['zeq_eh_par.a'])
            self.assertEqual(r['pending'],r['required'])
            self.assertFalse(r['full_design_equivalence']);self.assertFalse(r['release_eligible'])
            self.assertEqual(r['runner_sha256'],sha(args[2]/'cover_partitions.py'))

    def test_cached_strategy_message_cannot_supply_a_proof(self):
        with tempfile.TemporaryDirectory() as t:
            args=self.fixture(Path(t));p=args[0]/'eqy/strategies/zeq_eh_par.a/pdr/status';p.parent.mkdir(parents=True);p.write_text('PASS (cached)\n')
            self.bind_origin(args[0]);r=prepare(*args)
            self.assertEqual(r['pending'],r['required'])

    def test_completed_actual_proof_is_reused_once(self):
        with tempfile.TemporaryDirectory() as t:
            args=self.fixture(Path(t));p=args[0]/'eqy/strategies/zeq_eh_par.a/smt/zeq_eh_par.a';p.mkdir(parents=True)
            (p.parent/'zeq_eh_par.a.sby').write_text('[options]\nmode prove\n');(p/'status').write_text('PASS 0 1\n');(p/'logfile.txt').write_text('DONE (PASS, rc=0)\n');self.bind_origin(args[0])
            r=prepare(*args);self.assertEqual(r['pending'],[]);self.assertEqual(len(r['reused']),1)
            self.assertFalse(r['full_design_equivalence'])

    def test_changed_partition_rejected(self):
        with tempfile.TemporaryDirectory() as t:
            args=self.fixture(Path(t));(args[0]/'eqy/partitions/zeq_eh_par.a.il').write_text('mutant')
            with self.assertRaisesRegex(ValueError,'changed evidence'):prepare(*args)
            self.assertFalse(args[2].exists())

    def test_status_without_terminal_log_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as t:
            args=self.fixture(Path(t));p=args[0]/'eqy/strategies/zeq_eh_par.a/smt/zeq_eh_par.a';p.mkdir(parents=True)
            (p.parent/'zeq_eh_par.a.sby').write_text('[options]\nmode prove\n');(p/'status').write_text('PASS 0 1\n');(p/'logfile.txt').write_text('unfinished\n');self.bind_origin(args[0])
            with self.assertRaisesRegex(ValueError,'invalid archived proof'):prepare(*args)

    def test_partition_inventory_rejects_omissions_duplicates_and_paths(self):
        for text in ('','bad','other top.a','zeq_eh_par ../escape','zeq_eh_par a\nzeq_eh_par a'):
            with self.subTest(text=text), self.assertRaises(ValueError):partition_names(text)

    def test_terminal_pass_requires_induction_and_matching_exit(self):
        log='successful proof by k-induction.\nDONE (PASS, rc=0)'
        self.assertEqual(terminal_status('PASS 0 5',log,0),'PASS')
        for status,text,code in [('PASS 0 5',log,1),('PASS',log,0),('PASS 0 5','DONE (PASS, rc=0)',0),('PASS 0 5','successful proof by k-induction.',0)]:
            with self.subTest(status=status,text=text,code=code):self.assertEqual(terminal_status(status,text,code),'ERROR')
        self.assertEqual(terminal_status('TIMEOUT 8 5','DONE (TIMEOUT, rc=8)',8),'TIMEOUT')
        self.assertEqual(terminal_status('FAIL 2 5','DONE (FAIL, rc=2)',2),'FAIL')

    def test_bounded_or_ambiguous_configs_are_not_inductive_proofs(self):
        self.assertTrue(is_prove_config('[options]\nmode prove\ndepth 3\n[engines]\nsmtbmc bitwuzla\n'))
        for config in ('[options]\nmode bmc\n', '[options]\nmode prove\nmode bmc\n', '[script]\nmode prove\n', '[options]\nmode prove\n[options]\nmode prove\n'):
            with self.subTest(config=config):self.assertFalse(is_prove_config(config))

    def prior_fixture(self, root):
        prior=root/'prior';job=prior/'jobs/zeq_eh_par.a';(job/'proof').mkdir(parents=True)
        (job/'proof/src').mkdir()
        for ext in ('sv', 'il'):
            (job/('proof/src/zeq_eh_par.a.'+ext)).write_text('original '+ext)
        partitions={'zeq_eh_par.a':{'files':{ext:sha(job/('proof/src/zeq_eh_par.a.'+ext)) for ext in ('sv','il')},'outputs':{'a':[0]}}}
        (prior/'plan.json').write_text(json.dumps(dict(origin_result_sha256='origin-hash',partitions=partitions)))
        (job/'proof.sby').write_text(proof_config('zeq_eh_par.a',60,3))
        (job/'proof/status').write_text('PASS 0 1\n')
        (job/'proof/logfile.txt').write_text('successful proof by k-induction.\nDONE (PASS, rc=0)\n')
        result=dict(status='PASS',partition='zeq_eh_par.a',exit_code=0,input_sha256={'/origin/eqy/partitions/zeq_eh_par.a.'+ext:partitions['zeq_eh_par.a']['files'][ext] for ext in ('sv','il')},evidence_sha256={str(p.relative_to(job)):sha(p) for p in job.rglob('*') if p.is_file()})
        (job/'result.json').write_text(json.dumps(result))
        (prior/'result.json').write_text(json.dumps(dict(plan_sha256=sha(prior/'plan.json'),jobs={'zeq_eh_par.a':dict(status='PASS',artifact='jobs/zeq_eh_par.a/result.json',sha256=sha(job/'result.json'))})))
        return prior,partitions

    def test_completed_sweep_proof_can_be_reused_without_a_global_verdict(self):
        with tempfile.TemporaryDirectory() as t:
            prior,parts=self.prior_fixture(Path(t));r=reuse_coverage(prior,'origin-hash',parts)
            self.assertEqual(set(r),{'zeq_eh_par.a'})
            self.assertEqual(r['zeq_eh_par.a']['kind'],'continued_partition')

    def test_changed_prior_proof_or_different_origin_is_rejected(self):
        with tempfile.TemporaryDirectory() as t:
            prior,parts=self.prior_fixture(Path(t))
            with self.assertRaisesRegex(ValueError,'different origin'):reuse_coverage(prior,'other',parts)
            (prior/'jobs/zeq_eh_par.a/proof/logfile.txt').write_text('changed')
            with self.assertRaisesRegex(ValueError,'changed evidence'):reuse_coverage(prior,'origin-hash',parts)

    def test_rehashed_vacuous_or_changed_source_proof_is_rejected(self):
        for target in ('proof.sby', 'proof/src/zeq_eh_par.a.il'):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as t:
                prior,parts=self.prior_fixture(Path(t));job=prior/'jobs/zeq_eh_par.a'
                p=job/target
                p.write_text(p.read_text().replace(' -D CHECK_OUTPUTS','') if target=='proof.sby' else 'mutated circuit')
                result=json.loads((job/'result.json').read_text())
                result['evidence_sha256'][target]=sha(p)
                (job/'result.json').write_text(json.dumps(result))
                report=json.loads((prior/'result.json').read_text())
                report['jobs']['zeq_eh_par.a']['sha256']=sha(job/'result.json')
                (prior/'result.json').write_text(json.dumps(report))
                with self.assertRaisesRegex(ValueError,'changed the obligation|different circuit source'):
                    reuse_coverage(prior,'origin-hash',parts)

    def test_existing_build_not_overwritten(self):
        with tempfile.TemporaryDirectory() as t:
            args=self.fixture(Path(t));args[2].mkdir()
            with self.assertRaisesRegex(ValueError,'fresh'):prepare(*args)

    def test_bound_evidence_cannot_escape_root(self):
        with tempfile.TemporaryDirectory() as t:
            root=Path(t);base=root/'base';base.mkdir();p=root/'outside';p.write_text('x')
            with self.assertRaises(ValueError):bound(base,'../outside',{'../outside':sha(p)})


if __name__=='__main__':unittest.main()
