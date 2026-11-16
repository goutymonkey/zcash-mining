import hashlib
from pathlib import Path
import tempfile
import unittest

from audit_tile_trace import audit


class TileTraceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path=Path(self.temp.name)/'trace'
        # N=48 K=5 PW=18 AW=5: 144 packed bits; reset is the high bit.
        self.valid='ZEQ_TILE_V1 48 5 18 5 17\n0 '+format(1<<143,'x')+'\n1 0\nEND 2\n'

    def test_complete_trace_and_hash(self):
        self.path.write_text(self.valid)
        result=audit(self.path)
        self.assertEqual(result['cycles'],2)
        self.assertEqual(result['activity']['reset'],1)
        self.assertEqual(result['trace_sha256'],hashlib.sha256(self.path.read_bytes()).hexdigest())
        self.assertFalse(result['release_eligible'])

    def test_truncation_sequence_unknown_and_extra_data_rejected(self):
        for text in (self.valid.replace('END 2\n',''),self.valid.replace('1 0','2 0'),
                     self.valid.replace('1 0','1 x'),self.valid+'0 0\n',
                     self.valid.replace('END 2','END 1')):
            self.path.write_text(text)
            with self.assertRaises(ValueError):audit(self.path)

    def test_missing_reset_and_oversized_sample_rejected(self):
        for text in ('ZEQ_TILE_V1 48 5 18 5 17\n0 0\nEND 1\n',
                     'ZEQ_TILE_V1 48 5 18 5 17\n0 '+format(1<<144,'x')+'\nEND 1\n'):
            self.path.write_text(text)
            with self.assertRaises(ValueError):audit(self.path)

    def test_inactive_parent_level_is_not_an_access(self):
        value=(1<<143) | (7<<66)
        self.path.write_text('ZEQ_TILE_V1 48 5 18 5 17\n0 '+format(value,'x')+'\nEND 1\n')
        self.assertEqual(audit(self.path)['cycles'],1)
        self.path.write_text('ZEQ_TILE_V1 48 5 18 5 17\n0 '+format(value | (1<<69),'x')+'\nEND 1\n')
        with self.assertRaisesRegex(ValueError,'invalid round'):audit(self.path)


if __name__=='__main__':unittest.main()
