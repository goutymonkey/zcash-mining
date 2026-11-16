# SPDX-License-Identifier: Apache-2.0
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from pool_harness import ROOT, Params, minimal_to_indices, zcash_verify


class MainnetVectors(unittest.TestCase):
    def test_frozen_mainnet_shares_and_mutations(self):
        fixture = json.loads((Path(__file__).parent / "fixtures/mainnet-shares.json").read_text())
        self.assertEqual(fixture["params"], [200, 9])
        params = Params(200, 9)
        valid_lines, invalid_lines = [], []
        self.assertGreater(len(fixture["vectors"]), 0)
        for vector in fixture["vectors"]:
            header = bytes.fromhex(vector["input"])
            solution = bytes.fromhex(vector["solution"])
            self.assertEqual(len(header), 140)
            self.assertEqual(len(solution), 1344)
            self.assertTrue(zcash_verify(params, header, minimal_to_indices(params, solution)))
            encoded = b"\xfd" + struct.pack("<H", len(solution)) + solution
            digest = hashlib.sha256(hashlib.sha256(header + encoded).digest()).digest()
            self.assertEqual(digest.hex(), vector["block_hash_le"])
            self.assertLessEqual(int.from_bytes(digest, "little"), int(vector["target_be"], 16))
            mutated = bytearray(header)
            mutated[68] ^= 1  # Pool commitment bytes must participate in PoW.
            self.assertFalse(zcash_verify(params, mutated, minimal_to_indices(params, solution)))
            valid_lines.append(header.hex() + " " + solution.hex())
            invalid_lines.append(mutated.hex() + " " + solution.hex())
        miner = os.environ.get("ZCASH_MINER", str(ROOT / "zig-out/bin/zcash-miner"))
        with tempfile.TemporaryDirectory() as directory:
            for name, lines, succeeds in (("valid", valid_lines, True), ("invalid", invalid_lines, False)):
                path = Path(directory) / name
                path.write_text("\n".join(lines) + "\n")
                result = subprocess.run([miner, "--verify", str(path), "--params", "200,9"], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)


if __name__ == "__main__":
    unittest.main()
