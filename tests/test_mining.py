# SPDX-License-Identifier: Apache-2.0
import json
import os
from pathlib import Path
import subprocess
import socket
import time
import unittest
from pool_harness import ReferencePool, ROOT

MINER = Path(os.environ.get("ZCASH_MINER", str(ROOT / "zig-out/bin/zcash-miner")))


class MiningIntegrationTests(unittest.TestCase):
    def run_miner(self, scenario, seconds=2, extra=()):
        with ReferencePool(scenario) as pool:
            if scenario == "http_probe":
                with socket.create_connection(("127.0.0.1", pool.port)) as probe:
                    probe.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
            command = [str(MINER), "--pool", f"127.0.0.1:{pool.port}", "--user", 'worker"\\name',
                       "--params", "48,5", "--threads", "2", "--memory-limit-mb", "64",
                       "--run-seconds", str(seconds), "--stats-interval", "1", "--timeout-seconds", "1",
                       "--reconnect-ms", "20", *extra]
            result = subprocess.run(command, capture_output=True, text=True, timeout=seconds + 10)
            lines = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertTrue(lines, result.stderr)
            self.assertEqual(lines[-1]["event"], "final", result.stderr)
            self.assertEqual(pool.errors, [], result.stderr)
            return result, lines[-1]["stats"], pool.summary()

    def test_independent_wire_header_pow_and_share_acceptance(self):
        result, stats, pool = self.run_miner("normal")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(stats["accepted"], 0)
        self.assertGreater(pool["valid_shares"], 0)
        self.assertEqual(stats["submitted"], stats["accepted"] + stats["rejected"] + stats["unknown"])

    def test_rejected_authorization_never_starts_workers(self):
        result, stats, pool = self.run_miner("reject_auth")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(stats["attempts"], 0)
        self.assertEqual(pool["valid_shares"], 0)

    def test_nonclean_jobs_and_new_targets_are_adopted(self):
        result, stats, pool = self.run_miner("updates", seconds=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(pool["jobs_seen"], 2)
        self.assertGreater(stats["jobs"], 2)

    def test_set_target_does_not_retroactively_change_job(self):
        result, stats, _ = self.run_miner("target_updates")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(stats["accepted"], 1)

    def test_reconnect_reauthorizes_without_duplicate_shares(self):
        result, stats, pool = self.run_miner("reconnect", seconds=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(pool["connections"], 1)
        self.assertGreater(pool["authorizations"], 1)
        self.assertGreater(stats["reconnects"], 0)
        self.assertGreater(stats["accepted"], 12)

    def test_malformed_and_unsolicited_reply_do_not_count_as_accepted(self):
        result, stats, pool = self.run_miner("malformed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(stats["malformed"], 0)
        self.assertGreater(stats["unexpected_replies"], 0)
        self.assertLessEqual(stats["accepted"], pool["accepted"])

    def test_rejected_share_is_correlated_and_counted(self):
        result, stats, _ = self.run_miner("reject_share")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(stats["stale"], 0)
        self.assertEqual(stats["rejected"], stats["stale"])

    def test_idle_peer_times_out(self):
        result, stats, _ = self.run_miner("idle", seconds=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(stats["reconnects"], 0)
        self.assertEqual(stats["attempts"], 0)

    def test_oversized_message_is_bounded_and_reconnects(self):
        result, stats, _ = self.run_miner("oversized", seconds=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(stats["reconnects"], 0)
        self.assertGreater(stats["accepted"], 0)

    def test_worker_memory_failure_is_fatal_and_visible(self):
        result, stats, _ = self.run_miner("normal", extra=("--params", "200,9", "--memory-limit-mb", "1"))
        self.assertNotEqual(result.returncode, 0)
        self.assertGreater(stats["worker_failures"], 0)
        self.assertEqual(stats["submitted"], 0)

    def test_probe_does_not_mine(self):
        result, stats, _ = self.run_miner("normal", extra=("--probe",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stats["attempts"], 0)
        self.assertEqual(stats["jobs"], 1)

    def test_unrelated_initial_http_probe_is_separately_reported(self):
        result, stats, pool = self.run_miner("http_probe")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(stats["accepted"], 0)
        self.assertEqual(pool["unrelated_http_probes"], 1)
        self.assertEqual(pool["connections"], stats["connections"])

    def test_http_inside_a_mining_session_is_a_validation_failure(self):
        with ReferencePool() as pool:
            with socket.create_connection(("127.0.0.1", pool.port), timeout=2) as client:
                subscribe = {"id": 1, "method": "mining.subscribe", "params": ["test", None, "127.0.0.1", pool.port]}
                client.sendall(json.dumps(subscribe).encode() + b"\n")
                stream = client.makefile("rb")
                self.assertEqual(json.loads(stream.readline())["id"], 1)
                client.sendall(b"GET / HTTP/1.1\r\n\r\n")
                deadline = time.monotonic() + 2
                while not pool.errors and time.monotonic() < deadline:
                    time.sleep(0.01)
                stream.close()
            self.assertEqual(pool.unrelated_http_probes, 0)
            self.assertEqual(len(pool.errors), 1)


if __name__ == "__main__":
    unittest.main()
