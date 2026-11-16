"""A partial, malformed or failed STA sweep must not produce usable evidence."""
import unittest

from screen_sram_slew import BUFFERS, LOADS, SLEWS, parse_measurements


def report():
    rows = [' time 1ns', ' capacitance 1pF']
    for i in range(len(BUFFERS)):
        for slew in SLEWS:
            for cap in LOADS:
                rows += [f'ZEQ_CASE {i} {slew} {cap}', 'max slew',
                         f'mem{i}/addr0[0] 0.04 0.05 -0.01 (VIOLATED)',
                         'Pin capacitance: 0.00689', f'Wire capacitance: {cap}',
                         f'Total capacitance: {cap+0.00689}',
                         'Number of drivers: 1', 'Number of loads: 1']
    return '\n'.join(rows + ['ZEQ_COMPLETE', ''])


class SlewEvidenceTest(unittest.TestCase):
    def test_complete_measurements_include_failures(self):
        rows = parse_measurements(report())
        self.assertEqual(len(rows), len(BUFFERS)*len(SLEWS)*len(LOADS))
        self.assertFalse(any(r['meets_limit'] for r in rows))

    def test_passing_measurements(self):
        rows = parse_measurements(report().replace('0.04 0.05 -0.01 (VIOLATED)',
                                                   '0.04 0.039 0.001 (MET)'))
        self.assertTrue(all(r['meets_limit'] for r in rows))

    def test_missing_duplicate_or_wrong_pin(self):
        line = 'mem0/addr0[0] 0.04 0.05 -0.01 (VIOLATED)'
        for replacement in ('', line+'\n'+line, line.replace('addr0', 'addr1')):
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                parse_measurements(report().replace(line, replacement, 1))

    def test_incomplete_duplicate_or_unexpected_cases(self):
        for value in (report().split('ZEQ_CASE 11')[0]+'ZEQ_COMPLETE\n',
                      report().replace('ZEQ_CASE 1 ', 'ZEQ_CASE 0 '),
                      report().replace('ZEQ_CASE 1 ', 'ZEQ_CASE 999 ')):
            with self.subTest(value=value[:30]), self.assertRaises(ValueError):
                parse_measurements(value)

    def test_exit_zero_error_warning_or_truncation_rejected(self):
        for value in (report()+'Error: could not read liberty\n',
                      report()+'Warning: missing load\n',
                      report().replace('ZEQ_COMPLETE', ''),
                      report()+'ZEQ_COMPLETE\n'):
            with self.subTest(value=value[-70:]), self.assertRaises(ValueError):
                parse_measurements(value)

    def test_numeric_consistency_and_units(self):
        for old, new in (('0.05', 'nan'), ('0.05', 'inf'), ('0.05', '-1'),
                         ('-0.01', '-0.02'), ('VIOLATED', 'MET'),
                         ('time 1ns', 'time 1ps'), ('capacitance 1pF', 'capacitance 1fF')):
            with self.subTest(new=new), self.assertRaises(ValueError):
                parse_measurements(report().replace(old, new))

    def test_ignored_load_or_wrong_topology(self):
        for old, new in (('Wire capacitance: 0.005', 'Wire capacitance: 0.0'),
                         ('Pin capacitance: 0.00689', 'Pin capacitance: 0'),
                         ('Number of loads: 1', 'Number of loads: 2'),
                         ('Number of drivers: 1', 'Number of drivers: 2')):
            with self.subTest(new=new), self.assertRaises(ValueError):
                parse_measurements(report().replace(old, new))


if __name__ == '__main__':
    unittest.main()
