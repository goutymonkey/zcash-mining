# SPDX-License-Identifier: Apache-2.0
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from pool_harness import ROOT
from solver_reference import complete_solutions

MINER = Path(os.environ.get("ZCASH_MINER", str(ROOT / "zig-out/bin/zcash-miner")))


class SolverEnumerationTests(unittest.TestCase):
    def test_complete_sets_match_independent_explicit_tree_oracle(self):
        headers = [hashlib.shake_256(f"launch-solver:{i}".encode()).digest(140) for i in range(32)]
        with tempfile.TemporaryDirectory() as directory:
            corpus = Path(directory) / "headers.txt"
            corpus.write_text("\n".join(h.hex() for h in headers) + "\n")
            command = [str(MINER), "--bench", "--params", "48,5", "--corpus", str(corpus), "--memory-limit-mb", "64"]
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            records = [json.loads(line) for line in result.stdout.splitlines()]
            first_result = subprocess.run(command + ["--solutions", "first"], capture_output=True, text=True, timeout=30)
            self.assertEqual(first_result.returncode, 0, first_result.stderr)
            first_records = [json.loads(line) for line in first_result.stdout.splitlines()]
        self.assertEqual(len(records), len(headers))
        self.assertEqual(len(first_records), len(headers))
        total, multiple, empty = 0, 0, 0
        for header, record, first in zip(headers, records, first_records):
            with self.subTest(input=header.hex()[:24]):
                expected = complete_solutions(header)
                actual = record["solutions"]
                self.assertEqual(record["input"], header.hex())
                self.assertEqual(len(actual), len(set(actual)), "duplicate emission")
                self.assertEqual(set(actual), expected, "incomplete or incorrect solution set")
                self.assertEqual(record["verified_solutions"], len(expected))
                self.assertEqual(first["solutions"], actual[:1])
                self.assertGreater(record["peak_requested_bytes"], 0)
                self.assertLess(record["peak_requested_bytes"], 64 * 1024 * 1024)
                total += len(actual)
                multiple += len(actual) > 1
                empty += not actual
        self.assertGreater(total, 0)
        self.assertGreater(multiple, 0)
        self.assertGreater(empty, 0)

    def test_mainnet_cancellation_is_measured_without_finishing_solve(self):
        result = subprocess.run([str(MINER), "--bench", "--params", "200,9", "--iterations", "1",
                                 "--cancel-after-ms", "100", "--memory-limit-mb", "3072"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout)
        self.assertIsNotNone(record["cancel_latency_ns"])
        self.assertLess(record["cancel_latency_ns"], 2_000_000_000)
        self.assertEqual(record["solutions"], [])


if __name__ == "__main__":
    unittest.main()
