# SPDX-License-Identifier: Apache-2.0
"""Transport and host fault tests; actual RTL runs use qualify_device.py."""
import json
import os
from pathlib import Path
import subprocess
import unittest

from pool_harness import ReferencePool, ROOT
from device_harness import ReferenceDevice

MINER = Path(os.environ.get("ZCASH_MINER", str(ROOT / "zig-out/bin/zcash-miner")))


class BackendTests(unittest.TestCase):
    def run_case(self, transport="rtl", fault=None, chips=1, scenario="normal", seconds=2):
        with ReferenceDevice(transport, fault, chips) as device, ReferencePool(scenario) as pool:
            result = subprocess.run([str(MINER), "--pool", f"127.0.0.1:{pool.port}", "--user", "device-fixture",
                                     "--params", "48,5", "--backend", transport, "--device", device.endpoint,
                                     "--chips", str(chips), "--baud", "115200", "--memory-limit-mb", "32",
                                     "--run-seconds", str(seconds), "--device-timeout", "1", "--stats-interval", "1",
                                     "--reconnect-ms", "20"], capture_output=True, text=True, timeout=seconds + 8)
            records = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertTrue(records, result.stderr)
            final = records[-1]
            self.assertEqual(final["event"], "final")
            self.assertEqual(final["backend"], transport)
            self.assertEqual(pool.errors, [], result.stderr)
            self.assertEqual(device.errors, [], result.stderr)
            return result, final, pool.summary(), device.jobs

    def test_tcp_four_chip_nonce_assignment_and_done_before_solutions(self):
        result, final, pool, jobs = self.run_case(chips=4)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(final["device"]["chips"], 4)
        self.assertGreater(final["stats"]["accepted"], 0)
        self.assertGreater(pool["valid_shares"], 0)
        self.assertGreater(len(jobs), 1)
        self.assertEqual(len(jobs), len(set(jobs)))

    def test_serial_pty_runs_same_frame_and_verification_contract(self):
        result, final, _, _ = self.run_case(transport="serial")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(final["stats"]["accepted"], 0)

    def test_corrupt_discovery_frame_resynchronizes(self):
        result, final, _, _ = self.run_case(fault="crc")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(final["stats"]["accepted"], 0)

    def test_stale_job_replies_are_discarded(self):
        result, final, _, _ = self.run_case(fault="stale")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(final["stats"]["accepted"], 0)

    def test_late_discovery_reply_after_cancel_is_idempotent(self):
        result, final, _, _ = self.run_case(fault="late_pong")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(final["stats"]["accepted"], 0)

    def test_invalid_indices_and_proofs_never_reach_pool(self):
        for fault, message in (("index", "InvalidDeviceIndex"), ("proof", "InvalidBackendSolution")):
            with self.subTest(fault=fault):
                result, final, pool, _ = self.run_case(fault=fault)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(final["stats"]["accepted"], 0)
                self.assertEqual(pool["valid_shares"], 0)

    def test_bad_version_disconnect_and_stall_fail_visibly(self):
        for fault, message in (("version", "UnsupportedDeviceVersion"), ("disconnect", "DeviceDisconnected"), ("idle", "DeviceTimeout")):
            with self.subTest(fault=fault):
                result, final, _, _ = self.run_case(fault=fault)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(final["stats"]["worker_failures"], 1)

    def test_clean_jobs_and_reconnect_preserve_unique_host_nonces(self):
        result, final, pool, jobs = self.run_case(scenario="soak", seconds=6, chips=4)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(pool["jobs_seen"], 1)
        self.assertGreater(final["stats"]["reconnects"], 0)
        self.assertEqual(len(jobs), len(set(jobs)))
