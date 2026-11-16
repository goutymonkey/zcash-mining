import unittest

from chain_audit import validate_packets


class ChainAuditTest(unittest.TestCase):
    def setUp(self):
        self.sol = (0x81, 0, bytes([1, 0, 0, 0]) + bytes(range(8)))
        self.done = (0x85, 0, bytes([1, 0, 0, 0, 1]))

    def audit(self, packets):
        validate_packets(packets, nsol=2, chips=4, jobs={1, 2}, lanes=1)

    def test_complete_and_partial_attempts(self):
        self.audit([self.sol, self.done])
        self.audit([self.sol])
        self.audit([(0x84, 3, bytes([2, 0, 60, 1]))])

    def test_duplicate_solution_rejected(self):
        with self.assertRaisesRegex(ValueError, 'duplicate solution'):
            self.audit([self.sol, self.sol, self.done])

    def test_invalid_addresses_jobs_types_sizes_rejected(self):
        for packet in [(0x81, 4, self.sol[2]), (0x90, 0, b''), (0x81, 0, b''),
                       (0x81, 0, bytes([3]) + self.sol[2][1:]), (0x84, 0, bytes([2, 0, 60, 2]))]:
            with self.subTest(packet=packet), self.assertRaises(ValueError):
                self.audit([packet])

    def test_done_is_terminal_and_unique_per_attempt(self):
        for packets in ([self.done, self.sol], [self.done, self.done]):
            with self.subTest(packets=packets), self.assertRaises(ValueError):
                self.audit(packets)
