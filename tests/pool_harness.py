# SPDX-License-Identifier: Apache-2.0
"""Independent ZIP 301 pool harness. Never forwards shares to a public pool.

Wire validation is implemented here; Equihash is checked by the separate
Python consensus reference, not the miner. Small parameters test lifecycle;
(200,9) runs establish mainnet-parameter share validity, not a network block.
"""
from collections import OrderedDict
from pathlib import Path
import hashlib
import json
import socket
import struct
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "asic/chip/model"))
from equihash_ref import Params, minimal_to_indices, zcash_verify


class UnrelatedHttpProbe(Exception):
    pass


class Peer:
    def __init__(self, sock, stop):
        self.sock = sock
        self.stop = stop
        self.pending = bytearray()
        self.protocol_started = False
        sock.settimeout(0.1)

    def read(self):
        while not self.stop.is_set():
            if b"\n" in self.pending:
                line, _, rest = self.pending.partition(b"\n")
                self.pending = bytearray(rest)
                try:
                    return json.loads(line)
                except json.JSONDecodeError as exc:
                    if not self.protocol_started and line in (b"GET / HTTP/1.1\r", b"GET / HTTP/1.0\r", b"GET / HTTP/1.1", b"GET / HTTP/1.0"):
                        raise UnrelatedHttpProbe from exc
                    # This harness only serves local synthetic workers. Keep
                    # enough framing evidence to distinguish corrupt miner
                    # JSON from an unrelated localhost connection.
                    raise ValueError(f"invalid JSON from {self.sock.getpeername()}: length={len(line)}, prefix={bytes(line[:64])!r}") from exc
            if len(self.pending) > 65536:
                raise ValueError("oversized client message")
            try:
                data = self.sock.recv(4096)
            except socket.timeout:
                continue
            if not data:
                raise EOFError
            self.pending.extend(data)
        raise EOFError

    def send(self, *messages, fragment=False):
        data = b"".join(json.dumps(m, separators=(",", ":")).encode() + b"\n" for m in messages)
        if fragment:
            self.sock.sendall(data[:7])
            time.sleep(0.003)
            self.sock.sendall(data[7:])
        else:
            self.sock.sendall(data)


def response(request_id, result, error=None):
    return {"id": request_id, "result": result, "error": error}


def notice(method, params):
    return {"id": None, "method": method, "params": params}


class ReferencePool:
    def __init__(self, scenario="normal", n=48, k=5, pace=0.005):
        self.params = Params(n, k)
        self.scenario = scenario
        self.pace = pace
        self.stop = threading.Event()
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        self.listener.listen()
        self.listener.settimeout(0.1)
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.errors = []
        self.connections = 0
        self.transport_connections = 0
        self.unrelated_http_probes = 0
        self.authorizations = 0
        self.valid_shares = 0
        self.accepted = 0
        self.rejected = 0
        self.jobs_seen = set()
        self.job_sequence = 0
        self.seen = OrderedDict()
        self.samples = []
        self.last_nonce = None
        self.live = None

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        if self.live:
            try:
                self.live.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self.thread.join(timeout=5)
        self.listener.close()
        if self.thread.is_alive():
            raise RuntimeError("reference pool did not stop")

    def run(self):
        while not self.stop.is_set():
            try:
                sock, _ = self.listener.accept()
            except socket.timeout:
                continue
            self.transport_connections += 1
            self.live = sock
            try:
                with sock:
                    self.serve(Peer(sock, self.stop))
            except (EOFError, ConnectionError, socket.timeout):
                pass
            except UnrelatedHttpProbe:
                # Some development environments probe every listening port
                # using HTTP. Record and close those BEFORE any ZIP 301
                # session. HTTP inside a mining session remains a failure.
                self.unrelated_http_probes += 1
            except Exception as exc:
                if not self.stop.is_set():
                    self.errors.append(f"{type(exc).__name__}: {exc}")
            finally:
                self.live = None

    def job(self, clean=False, target=(1 << 256) - 1):
        self.job_sequence += 1
        # Nonzero hashes and commitment bytes catch coinbase reconstruction,
        # reversal, zeroed commitments, and wrong time endianness.
        name = f"job-{self.job_sequence}\\quoted\""
        seed = self.job_sequence.to_bytes(4, "little")
        fields = ["04000000", hashlib.sha256(b"prev" + seed).hexdigest(),
                  hashlib.sha256(b"merkle" + seed).hexdigest(),
                  hashlib.sha256(b"commitment" + seed).hexdigest(),
                  "78563412", "ffff071f"]
        header = bytes.fromhex("".join(fields))
        return name, header, target, notice("mining.notify", [name, *fields, clean])

    def validate(self, message, user, nonce1, jobs):
        if message.get("method") != "mining.submit":
            raise ValueError("unexpected request")
        args = message["params"]
        if len(args) != 5 or args[0] != user:
            raise ValueError("bad submit identity")
        job_id, time_hex, nonce2_hex, encoded_hex = args[1:]
        if job_id not in jobs:
            return False  # Old job explicitly invalidated by clean_jobs.
        header, target = jobs[job_id]
        if bytes.fromhex(time_hex) != header[100:104]:
            raise ValueError("time is not the pool's little-endian field")
        nonce2 = bytes.fromhex(nonce2_hex)
        if len(nonce2) != 32 - len(nonce1):
            raise ValueError("submit must contain only NONCE_2")
        encoded = bytes.fromhex(encoded_hex)
        expected_size = self.params.solution_size()
        expected_prefix = (bytes([expected_size]) if expected_size < 253
                           else b"\xfd" + struct.pack("<H", expected_size))
        if len(encoded) != len(expected_prefix) + expected_size or not encoded.startswith(expected_prefix):
            raise ValueError("incorrect canonical solution CompactSize")
        minimal = encoded[len(expected_prefix):]
        full_header = header + nonce1 + nonce2
        if not zcash_verify(self.params, full_header, minimal_to_indices(self.params, minimal)):
            raise ValueError("independent Equihash verifier rejected solution")
        digest = hashlib.sha256(hashlib.sha256(full_header + encoded).digest()).digest()
        if int.from_bytes(digest, "little") > target:
            raise ValueError("share exceeds job-bound target")
        if digest in self.seen:
            raise ValueError("duplicate header/solution submitted")
        self.seen[digest] = True
        if len(self.seen) > 65536:
            self.seen.popitem(last=False)
        self.valid_shares += 1
        self.last_nonce = nonce1 + nonce2
        if len(self.jobs_seen) < 1024:
            self.jobs_seen.add(job_id)
        if len(self.samples) < 8:
            self.samples.append({"input": full_header.hex(), "solution": minimal.hex(),
                                 "block_hash_le": digest.hex(), "target_be": f"{target:064x}"})
        return True

    def serve(self, peer):
        sub = peer.read()
        if sub["method"] != "mining.subscribe" or len(sub["params"]) != 4:
            raise ValueError("subscription must include agent, session, host and port")
        peer.protocol_started = True
        self.connections += 1
        if sub["params"][1] is not None or sub["params"][3] != self.port:
            raise ValueError("unexpected subscription parameters")
        nonce1 = b"\x08\x00\x00\x02"
        peer.send(response(sub["id"], [None, nonce1.hex()]), fragment=True)
        auth = peer.read()
        if auth["method"] != "mining.authorize" or len(auth["params"]) != 2:
            raise ValueError("missing authorization")
        user = auth["params"][0]
        self.authorizations += 1
        if self.scenario == "reject_auth":
            peer.send(response(auth["id"], None, [24, "Unauthorized worker", None]))
            self.stop.wait(1)
            return
        peer.send(response(auth["id"], True))
        if self.scenario == "idle":
            self.stop.wait(3)
            return
        if self.scenario == "oversized" and self.connections == 1:
            peer.sock.sendall(b"x" * 65537)
            self.stop.wait(0.2)
            return
        target = (1 << 256) - 1
        name, header, _, notification = self.job(clean=True, target=target)
        jobs = {name: (header, target)}
        peer.send(notice("mining.set_target", [f"{target:064x}"]), notification)
        if self.scenario == "target_updates":
            # This applies only to the NEXT job. The current job must continue
            # submitting against its original easy target.
            peer.send(notice("mining.set_target", [f"{1:064x}"]))
        if self.scenario in ("malformed", "soak"):
            peer.sock.sendall(b"{broken json}\n")
            peer.send(response(999999999, True))
        session_shares = 0
        while not self.stop.is_set():
            submit = peer.read()
            valid = self.validate(submit, user, nonce1, jobs)
            session_shares += 1
            reject = not valid or (self.scenario in ("reject_share", "soak") and session_shares % 7 == 1)
            if reject:
                self.rejected += 1
                peer.send(response(submit["id"], None, [21, "Stale job", None]))
            else:
                self.accepted += 1
                peer.send(response(submit["id"], True))
            if self.scenario in ("reconnect", "soak") and session_shares == 12:
                if self.connections % 2:
                    peer.send(notice("client.reconnect", []))
                    self.stop.wait(0.05)
                return  # Alternate requested reconnect and abrupt EOF.
            if self.scenario in ("updates", "soak") and session_shares % 3 == 0:
                target = ((1 << 256) - 1) if session_shares % 2 else ((1 << 255) - 1)
                clean = session_shares % 9 == 0
                name, header, _, notification = self.job(clean=clean, target=target)
                if clean:
                    jobs.clear()
                jobs[name] = (header, target)
                peer.send(notice("mining.set_target", [f"{target:064x}"]), notification, fragment=True)
            if self.pace:
                self.stop.wait(self.pace)

    def summary(self):
        return {"connections": self.connections, "authorizations": self.authorizations,
                "transport_connections": self.transport_connections,
                "unrelated_http_probes": self.unrelated_http_probes,
                "valid_shares": self.valid_shares, "accepted": self.accepted,
                "rejected": self.rejected, "jobs_seen": len(self.jobs_seen),
                "errors": list(self.errors), "samples": list(self.samples)}
