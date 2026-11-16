"""Paired RTL comparisons must catch lost solutions even on overflowing jobs."""
from pathlib import Path
import tempfile
import unittest

from compare_rtl import compare
from equihash_ref import Params, hw_solve


class CompareRTLTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.params = Params(48, 5)
        cls.header = (5).to_bytes(4, "little") + bytes(136)
        cls.solutions = hw_solve(cls.params, cls.header)
        assert len(cls.solutions) >= 2
        cls.miner = Path(__file__).resolve().parents[3] / "zig-out/bin/zcash-miner"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.before = self.write("before", self.solutions)

    def write(self, name, solutions, header=None, complete=True):
        path = self.root / name
        path.mkdir()
        (path / "solver_hdr.hex").write_text((header or self.header)[::-1].hex() + "\n")
        body = "A 0\n" + "".join("S " + " ".join(map(str, s)) + "\n" for s in solutions)
        if complete:
            body += f"D {len(solutions)} 100 999\n"
        (path / "solver_out.txt").write_text(body)
        return path

    def check(self, candidate):
        return compare(self.before, candidate, self.params, self.miner)

    def test_reordered_solutions_pass(self):
        result = self.check(self.write("after", list(reversed(self.solutions))))
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["cycle_change_fraction"], 0)

    def test_overflow_does_not_waive_loss(self):
        result = self.check(self.write("after", self.solutions[:-1]))
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["attempts"][0]["missing"], 1)

    def test_duplicate_cannot_replace_missing_solution(self):
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.check(self.write("after", [self.solutions[0]] * len(self.solutions)))

    def test_equal_counts_cannot_hide_different_valid_solutions(self):
        self.before = self.write("one-before", self.solutions[:1])
        result = self.check(self.write("after", self.solutions[1:2]))
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["attempts"][0]["missing"], 1)
        self.assertEqual(result["attempts"][0]["added"], 1)

    def test_incomplete_attempt_rejected(self):
        with self.assertRaisesRegex(ValueError, "incomplete"):
            self.check(self.write("after", self.solutions, complete=False))

    def test_changed_headers_rejected(self):
        with self.assertRaisesRegex(ValueError, "headers differ"):
            self.check(self.write("after", self.solutions, header=bytes([1]) * 140))

    def test_short_zero_solution_headers_rejected(self):
        self.before = self.write("short-before", [], header=b'\x00')
        with self.assertRaisesRegex(ValueError, "140 bytes"):
            self.check(self.write("after", [], header=b'\x00'))

    def extend_baseline(self, complete=True):
        with (self.before / "solver_hdr.hex").open("a") as out:
            out.write(self.header[::-1].hex() + "\n")
        with (self.before / "solver_out.txt").open("a") as out:
            out.write("A 1\n" + ("D 0 900 0\n" if complete else ""))

    def test_prefix_is_explicit_and_reports_full_corpus_sizes(self):
        self.extend_baseline()
        candidate = self.write("after", self.solutions)
        with self.assertRaisesRegex(ValueError, "headers differ"):
            self.check(candidate)
        result = compare(self.before, candidate, self.params, self.miner, header_limit=1)
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["headers"], 1)
        self.assertEqual(result["corpus_headers"], {"baseline": 2, "candidate": 1})
        self.assertEqual(result["selection"], "first requested headers only")
        self.assertEqual(result["baseline_cycles"], 100)

    def test_prefix_cannot_hide_incomplete_trailing_attempt(self):
        self.extend_baseline(complete=False)
        with self.assertRaisesRegex(ValueError, "incomplete"):
            compare(self.before, self.write("after", self.solutions), self.params,
                    self.miner, header_limit=1)

    def test_prefix_rejects_invalid_limit_or_mismatched_headers(self):
        candidate = self.write("after", self.solutions)
        for limit in (0, -1, 2, True):
            with self.subTest(limit=limit), self.assertRaisesRegex(ValueError, "header limit"):
                compare(self.before, candidate, self.params, self.miner, header_limit=limit)
        changed = self.write("changed", self.solutions, header=bytes([1]) * 140)
        with self.assertRaisesRegex(ValueError, "headers differ"):
            compare(self.before, changed, self.params, self.miner, header_limit=1)

    def test_prefix_does_not_waive_solution_loss(self):
        self.extend_baseline()
        result = compare(self.before, self.write("after", self.solutions[:-1]),
                         self.params, self.miner, header_limit=1)
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["attempts"][0]["missing"], 1)


if __name__ == "__main__":
    unittest.main()
