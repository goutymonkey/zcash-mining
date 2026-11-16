import copy
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import qualify_par
from qualify_par import accept_audit


class YieldQualificationTest(unittest.TestCase):
    def setUp(self):
        self.summary=dict(headers=16,results=dict(rtl=dict(reference_solutions=33,
            solutions=33,missing_reference_solutions=0,total_cycles=1000)))

    def test_complete_retention_is_accepted(self):
        self.assertEqual(accept_audit(self.summary,16)['solutions'],33)

    def test_missing_solution_cannot_be_waived(self):
        self.summary['results']['rtl'].update(solutions=32,missing_reference_solutions=1)
        with self.assertRaises(ValueError):accept_audit(self.summary,16)

    def test_misleading_summary_fields_cannot_hide_loss(self):
        self.summary['results']['rtl']['solutions']=32
        with self.assertRaises(ValueError):accept_audit(self.summary,16)

    def test_zero_yield_corpus_cannot_qualify(self):
        self.summary['results']['rtl'].update(reference_solutions=0,solutions=0)
        with self.assertRaises(ValueError):accept_audit(self.summary,16)

    def test_incomplete_corpus_or_cycle_count_rejected(self):
        with self.assertRaises(ValueError):accept_audit(self.summary,17)
        for cycles in (0,-1):
            s=copy.deepcopy(self.summary);s['results']['rtl']['total_cycles']=cycles
            with self.assertRaises(ValueError):accept_audit(s,16)

    def test_unsupported_configuration_rejected_before_archiving(self):
        # These boundary geometries produce zero-width engine/local-bucket
        # slices in the actual RTL; reject before freezing or compiling them.
        cases=[['--engines','1'],['--engines','16'],
               ['--engines','4','--hash-engines','8'],
               ['--compile-timeout','0'],['--output-groups','-1'],
               ['--slots','0'],['--slots','129'],['--trace-drops','2'],
               ['--tile-trace-engine','-2'],['--tile-trace-engine','4'],
               ['--slots','8','--gmax','16','--group-replay','1'],['--gmax','3'],['--group-replay','2'],['--bucket0-slots','79'],['--bucket0-slots','129'],['--bist-first','2']]
        for options in cases:
            with self.subTest(options=options), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp)
                with patch.object(qualify_par,'ROOT',root), \
                     patch.object(qualify_par,'snapshot') as snapshot, \
                     patch('sys.argv',['qualify_par.py','--build','build/invalid','--n','48',*options]), \
                     contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as error:qualify_par.main()
                self.assertEqual(error.exception.code,2)
                self.assertFalse((root/'build/invalid').exists())
                snapshot.assert_not_called()


if __name__=='__main__':unittest.main()
