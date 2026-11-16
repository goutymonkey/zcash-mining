#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Expose a source-bound RTL UART simulation as a local binary TCP device."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import sys
import time
import uuid

CHIP = Path(__file__).resolve().parents[1]
ROOT = CHIP.parents[1]
STOPPING = False
sys.path.insert(0, str(CHIP / "model"))
from equihash_ref import Params, crc8, packet, job_input, indices_to_minimal, zcash_verify


class Build:
    def __init__(self, directory):
        self.directory = directory.resolve()
        result = json.loads((self.directory / "result.json").read_text())
        if result["status"] != "BUILT":
            raise ValueError("simulation build did not complete")
        self.inputs = json.loads((self.directory / "inputs.json").read_text())
        self.geometry = self.inputs["geometry"]
        self.image = result["image"]
        if self.image != self.inputs["toolchain"]["verilator"]["image"]:
            raise ValueError("toolchain binding mismatch")
        self.binary = self.directory / result["binary"]
        self.binary_sha256 = result["binary_sha256"]
        for path, expected in ((self.binary, self.binary_sha256), (self.directory / "inputs.json", result["inputs_sha256"])):
            if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                raise ValueError(f"artifact hash mismatch: {path.name}")
        for name, expected in self.inputs["sources"].items():
            path = self.directory / "source/asic/chip" / name
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                raise ValueError(f"missing or altered frozen source: {name}")

    def launch(self, stderr):
        name = "zcash-rtl-" + uuid.uuid4().hex[:16]
        command = ["docker", "run", "--rm", "--name", name, "--network=none", "--read-only", "--cpus=2",
                   "--memory=8g", "--pids-limit=256", "-i", "-u", f"{os.getuid()}:{os.getgid()}",
                   "-v", f"{self.directory}:/simulation:ro", "-w", "/simulation", "--entrypoint",
                   "/simulation/" + str(self.binary.relative_to(self.directory)), self.image]
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, bufsize=0)
        return process, name


def stop_process(process, name):
    try:
        process.stdin.close()
    except BrokenPipeError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        # Remove only the uniquely named disposable container we created.
        subprocess.run(["docker", "rm", "--force", name], capture_output=True, timeout=10)
        process.wait(timeout=5)
    process.stdout.close()


def read_frame(process, pending, deadline):
    while time.monotonic() < deadline:
        if STOPPING:
            raise InterruptedError("RTL smoke test interrupted")
        if len(pending) >= 5:
            if pending[0] != 0x5a:
                raise ValueError("RTL output lost UART frame alignment")
            length = int.from_bytes(pending[3:5], "little")
            if length > 2052:
                raise ValueError("RTL response exceeds maximum payload")
            size = length + 6
            if len(pending) >= size:
                frame = bytes(pending[:size])
                del pending[:size]
                if crc8(frame[1:-1]) != frame[-1]:
                    raise ValueError("RTL UART response CRC mismatch")
                return frame[1], frame[2], frame[5:-1]
        ready, _, _ = select.select([process.stdout], [], [], 0.1)
        if ready:
            data = os.read(process.stdout.fileno(), 4096)
            if not data:
                raise EOFError("RTL bridge exited before expected reply")
            pending.extend(data)
    raise TimeoutError("RTL UART reply timeout")


def smoke(build, report, timeout):
    if report.exists():
        raise FileExistsError("use a new smoke report path")
    n, k = build.geometry["N"], build.geometry["K"]
    chips = build.geometry["CHIPS"]
    params = Params(n, k)
    if n == 48:
        header = bytearray(140)
        header[:4] = struct.pack("<I", 4)
        header[4:29] = b"zcash-benchmark-corpus-v1"
        sys.path.insert(0, str(ROOT / "tests"))
        from solver_reference import complete_solutions
        expected = {addr: complete_solutions(job_input(header, addr, 0)) for addr in range(chips)}
        oracle_scope = "complete independent explicit-tree solution sets, one attempt per chip"
    else:
        fixture = json.loads((ROOT / "tests/fixtures/mainnet-shares.json").read_text())
        header = bytes.fromhex(fixture["vectors"][0]["input"])
        expected = {0: {v["solution"] for v in fixture["vectors"] if v["input"] == header.hex()}}
        oracle_scope = "recorded CPU solution set for chip zero; independently verify all reported solutions"
    received = {addr: set() for addr in range(chips)}
    done = {}
    pongs = {}
    pending = bytearray()
    result = {"status": "FAIL", "geometry": build.geometry, "binary_sha256": build.binary_sha256,
              "scope": oracle_scope, "header": bytes(header).hex(), "expected": {str(a): sorted(s) for a, s in expected.items()}}
    try:
        with report.with_suffix(".stderr.log").open("wb") as stderr:
            process, name = build.launch(stderr)
            try:
                deadline = time.monotonic() + timeout
                process.stdin.write(packet(0xa5, 4, 0xff))
                while len(pongs) < chips:
                    kind, address, payload = read_frame(process, pending, deadline)
                    if kind != 0x84 or address >= chips or len(payload) != 4 or payload[0] != 2:
                        raise ValueError("unexpected discovery reply")
                    if address in pongs:
                        raise ValueError("duplicate chip address")
                    pongs[address] = list(payload)
                process.stdin.write(packet(0xa5, 5, 0xff, b"\xff" * 32))
                process.stdin.write(packet(0xa5, 1, 0xff, b"\x27" + bytes(header)))
                while True:
                    kind, address, payload = read_frame(process, pending, deadline)
                    if address >= chips or len(payload) < 4:
                        raise ValueError("unexpected mining reply")
                    if payload[0] != 0x27:
                        raise ValueError("wrong job identifier")
                    attempt = int.from_bytes(payload[1:4], "little")
                    if attempt != 0:
                        continue
                    if kind == 0x81:
                        if len(payload) != 4 + 4 * params.nsol:
                            raise ValueError("incorrect solution index payload size")
                        indices = struct.unpack(">" + "I" * params.nsol, payload[4:])
                        effective = job_input(header, address, attempt)
                        if any(i >= params.init for i in indices) or not zcash_verify(params, effective, indices):
                            raise ValueError("independent verifier rejected RTL solution")
                        minimal = indices_to_minimal(params, indices).hex()
                        if minimal in received[address]:
                            raise ValueError("duplicate RTL solution")
                        received[address].add(minimal)
                    elif kind == 0x85:
                        if len(payload) != 5:
                            raise ValueError("incorrect DONE payload")
                        done[address] = payload[4]
                    else:
                        raise ValueError("unexpected response type during mining")
                    if len(done) == chips and all(len(received[a]) == done[a] for a in range(chips)):
                        break
                process.stdin.write(packet(0xa5, 2, 0xff))
                for address, solutions in expected.items():
                    if received[address] != solutions:
                        raise ValueError(f"solution-set mismatch for chip {address}: expected {len(solutions)}, got {len(received[address])}")
                if not sum(map(len, received.values())):
                    raise ValueError("smoke workload produced no verifying solutions")
                result.update(status="PASS", pongs=pongs, done=done,
                              received={str(a): sorted(s) for a, s in received.items()})
            finally:
                stop_process(process, name)
                result["bridge_exit_code"] = process.returncode
                if process.returncode:
                    result["status"] = "FAIL"
    except Exception as exc:
        result["error"] = str(exc)
        raise
    finally:
        report.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "PASS" else 1


def forward(connection, build, stderr):
    # Development environments may HTTP-probe any open TCP port. Those are
    # not device sessions and must not hold the simulator ahead of the host.
    connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    connection.settimeout(5)
    try:
        first = connection.recv(4, socket.MSG_PEEK)
    except socket.timeout:
        return
    if not first or first.startswith(b"GET "):
        return
    connection.setblocking(False)
    process, name = build.launch(stderr)
    os.set_blocking(process.stdin.fileno(), False)
    os.set_blocking(process.stdout.fileno(), False)
    to_device, to_host = bytearray(), bytearray()
    cap = 65536
    try:
        while not STOPPING and process.poll() is None:
            reads = ([connection] if len(to_device) < cap else []) + ([process.stdout] if len(to_host) < cap else [])
            writes = ([process.stdin] if to_device else []) + ([connection] if to_host else [])
            ready_read, ready_write, _ = select.select(reads, writes, [], 0.1)
            for source in ready_read:
                try:
                    if source is connection:
                        data = connection.recv(min(4096, cap - len(to_device)))
                        destination = to_device
                    else:
                        data = os.read(process.stdout.fileno(), min(4096, cap - len(to_host)))
                        destination = to_host
                except BlockingIOError:
                    continue
                if not data:
                    return
                destination.extend(data)
            for destination in ready_write:
                try:
                    if destination is connection:
                        count = connection.send(to_host)
                        del to_host[:count]
                    else:
                        count = os.write(process.stdin.fileno(), to_device)
                        del to_device[:count]
                except BlockingIOError:
                    continue
    finally:
        stop_process(process, name)
        if process.returncode:
            raise RuntimeError(f"RTL simulation exited with status {process.returncode}")


def main():
    # Let normal cleanup finish even if SIGTERM arrives while waiting for our
    # container to exit. Raising from a signal handler can interrupt finally.
    def shutdown(signum, frame):
        global STOPPING
        STOPPING = True

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", type=Path)
    parser.add_argument("--smoke-report", type=Path)
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args()
    build = Build(args.build)
    if args.smoke_report:
        return smoke(build, args.smoke_report, args.timeout)
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", args.port))
        listener.listen(4)
        listener.settimeout(0.2)
        port = listener.getsockname()[1]
        if args.port_file:
            args.port_file.write_text(str(port) + "\n")
        print(json.dumps({"event": "ready", "port": port, "geometry": build.geometry,
                          "binary_sha256": build.binary_sha256}), flush=True)
        while not STOPPING:
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            with connection:
                try:
                    forward(connection, build, sys.stderr)
                except (ConnectionError, BrokenPipeError) as exc:
                    print(f"device session ended: {exc}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
