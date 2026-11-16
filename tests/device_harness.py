# SPDX-License-Identifier: Apache-2.0
"""Independent transport fixtures; these are NOT RTL or silicon evidence."""
import errno
import os
import pty
import select
import socket
import struct
import threading
import time

from pool_harness import ROOT
from equihash_ref import Params, crc8, packet, job_input, minimal_to_indices
from solver_reference import complete_solutions


class ReferenceDevice:
    def __init__(self, transport="rtl", fault=None, chips=1):
        self.transport, self.fault, self.chips = transport, fault, chips
        self.stop = threading.Event()
        self.errors, self.jobs, self.commands = [], [], []
        self.current = None
        self.listener = None
        self.slave = None
        if transport == "serial":
            self.fd, self.slave = pty.openpty()
            self.endpoint = os.ttyname(self.slave)
        else:
            self.listener = socket.socket()
            self.listener.bind(("127.0.0.1", 0))
            self.listener.listen()
            self.listener.settimeout(0.1)
            self.endpoint = "127.0.0.1:" + str(self.listener.getsockname()[1])
        self.thread = threading.Thread(target=self.run, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        if self.current:
            try:
                self.current.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self.thread.join(timeout=5)
        if self.listener:
            self.listener.close()
        if self.slave is not None:
            os.close(self.slave)
            os.close(self.fd)
        if self.thread.is_alive():
            raise RuntimeError("reference device failed to stop")

    def run(self):
        while not self.stop.is_set():
            try:
                if self.listener:
                    try:
                        conn, _ = self.listener.accept()
                    except socket.timeout:
                        continue
                    self.current = conn
                    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    with conn:
                        self.serve(conn.fileno())
                    self.current = None
                else:
                    self.serve(self.fd)
            except (EOFError, BrokenPipeError, ConnectionResetError):
                pass
            except OSError as exc:
                if exc.errno != errno.EIO and not self.stop.is_set():
                    self.errors.append(str(exc))
            except Exception as exc:
                if not self.stop.is_set():
                    self.errors.append(f"{type(exc).__name__}: {exc}")

    def send(self, fd, payload):
        # Exercise byte-level fragmentation, rather than matching host reads.
        for part in (payload[:3], payload[3:]):
            while part and not self.stop.is_set():
                _, ready, _ = select.select([], [fd], [], 0.1)
                if ready:
                    part = part[os.write(fd, part):]

    def serve(self, fd):
        pending = bytearray()
        while not self.stop.is_set():
            if len(pending) < 5:
                ready, _, _ = select.select([fd], [], [], 0.1)
                if not ready:
                    continue
                data = os.read(fd, 4096)
                if not data:
                    raise EOFError
                pending.extend(data)
            if pending.startswith(b"GET ") and not self.commands:
                return
            if len(pending) < 5:
                continue
            if pending[0] != 0xa5:
                raise ValueError("bad command preamble")
            size = int.from_bytes(pending[3:5], "little") + 6
            if size > 2058:
                raise ValueError("unbounded command")
            if len(pending) < size:
                ready, _, _ = select.select([fd], [], [], 0.1)
                if ready:
                    data = os.read(fd, 4096)
                    if not data:
                        raise EOFError
                    pending.extend(data)
                continue
            frame = bytes(pending[:size])
            del pending[:size]
            if crc8(frame[1:-1]) != frame[-1]:
                raise ValueError("bad host CRC")
            kind, address, payload = frame[1], frame[2], frame[5:-1]
            self.commands.append(kind)
            if address != 0xff:
                raise ValueError("expected broadcast")
            if kind == 4:
                for addr in range(self.chips):
                    reply = packet(0x5a, 0x84, addr, bytes([3 if self.fault == "version" else 2, 0, 60, 1]))
                    if self.fault == "crc":
                        self.send(fd, reply[:-1] + bytes([reply[-1] ^ 1]))
                    self.send(fd, reply)
            elif kind == 1:
                self.jobs.append(payload[1:])
                if self.fault == "idle":
                    continue
                if self.fault == "disconnect":
                    return
                job, header = payload[0], payload[1:]
                if self.fault == "late_pong":
                    self.send(fd, packet(0x5a, 0x84, 0, bytes([2, 0, 60, 1])))
                if len(header) != 140:
                    raise ValueError("bad job length")
                for addr in range(self.chips):
                    effective = job_input(header, addr, 0)
                    solutions = sorted(complete_solutions(effective))
                    tag = bytes([job, 0, 0, 0])
                    # DONE has priority over SOLUTION in the real link.
                    self.send(fd, packet(0x5a, 0x85, addr, tag + bytes([len(solutions)])))
                    for solution in solutions:
                        indices = minimal_to_indices(Params(48, 5), bytes.fromhex(solution))
                        if self.fault == "index":
                            indices[0] = 0xffffffff
                        if self.fault == "proof":
                            indices[0] ^= 1
                        body = struct.pack(">" + "I" * len(indices), *indices)
                        if self.fault == "stale":
                            self.send(fd, packet(0x5a, 0x81, addr, bytes([(job - 1) & 255, 0, 0, 0]) + body))
                        reply = packet(0x5a, 0x81, addr, tag + body)
                        self.send(fd, reply)
                        if self.fault == "duplicate":
                            self.send(fd, reply)
            elif kind == 5:
                if payload != b"\xff" * 32:
                    raise ValueError("protocol v2 count requires all-solution reporting")
            elif kind != 2:
                raise ValueError("unsupported command")
            time.sleep(0.001)
