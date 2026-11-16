"""Reference model for the ZEQ-200 Equihash ASIC.

Two independent things live here:

* ``hw_solve`` mirrors the RTL solver algorithm step for step (same row
  order, same caps, same candidate order), so simulation output can be
  compared bit-exactly.
* ``zcash_verify`` is a direct port of zcashd's ``IsValidSolution`` working
  on expanded hash bytes and index lists. It shares no code with
  ``hw_solve``, so a solution that passes it is valid regardless of how the
  solver found it.

The chain protocol (packet framing + CRC) used by the chip is also defined
here so testbenches and host tools agree on one encoding.
"""

import hashlib
import struct

# ---------------------------------------------------------------- params


class Params:
    def __init__(self, n, k):
        assert n % 8 == 0 and n % (k + 1) == 0
        self.n, self.k = n, k
        self.cb = n // (k + 1)  # collision bits per round
        self.cbl = (self.cb + 7) // 8  # collision bytes (expanded)
        self.init = 1 << (self.cb + 1)  # rows in the first list
        self.ipho = 512 // n  # indices per hash output
        self.hout = self.ipho * n // 8  # digest bytes
        self.nsol = 1 << k  # indices per solution
        self.hash_len = (k + 1) * self.cbl

    def personalization(self):
        return b"ZcashPoW" + struct.pack("<II", self.n, self.k)

    def solution_size(self):
        return self.nsol * (self.cb + 1) // 8


# ------------------------------------------------------------ hashing


def digest(p, header140, g):
    h = hashlib.blake2b(digest_size=p.hout, person=p.personalization())
    h.update(header140)
    h.update(struct.pack("<I", g))
    return h.digest()


def leaf(p, header140, i):
    """N-bit value of leaf index i (big-endian bits of its digest slice)."""
    d = digest(p, header140, i // p.ipho)
    j = i % p.ipho
    chunk = d[j * p.n // 8:(j + 1) * p.n // 8]
    return int.from_bytes(chunk, "big")


def job_input(header140, addr, attempt):
    """Nonce bytes the chip owns: input[136] = chip address,
    input[137..139] = 24-bit little-endian attempt counter."""
    b = bytearray(header140)
    b[136] = addr & 0xFF
    b[137:140] = struct.pack("<I", attempt)[:3]
    return bytes(b)


# ------------------------------------------------- hardware-exact solver


def hw_solve(p, header140, cap=None, gmax=16):
    """Exactly the RTL algorithm. Returns a list of solutions, each a list
    of 2^K leaf indices in canonical (zcash) order, in emission order."""
    cap = cap or 2 * p.init
    mask_cb = (1 << p.cb) - 1

    # level 0: rows are leaves, row id == leaf index
    vals = [[leaf(p, header140, i) for i in range(p.init)]]
    ptrs = [None]
    sols = []

    for r in range(1, p.k + 1):
        src = vals[r - 1]
        width = p.n - (r - 1) * p.cb  # bits still held by level r-1 rows
        shift = width - p.cb

        def key(v):
            return (v >> shift) & mask_cb

        # stable counting sort by the next collision chunk
        hist = [0] * (1 << p.cb)
        for v in src:
            hist[key(v)] += 1
        run = 0
        for b in range(len(hist)):
            hist[b], run = run, run + hist[b]
        order = [0] * len(src)
        for i, v in enumerate(src):
            order[hist[key(v)]] = i
            hist[key(v)] += 1

        new_vals, new_ptrs = [], []
        i = 0
        while i < len(order):
            j = i
            while j < len(order) and key(src[order[j]]) == key(src[order[i]]):
                j += 1
            group = order[i:min(j, i + gmax)]
            for a in range(len(group)):
                for b in range(a + 1, len(group)):
                    ra, rb = group[a], group[b]
                    x = src[ra] ^ src[rb]
                    if r < p.k:
                        if len(new_vals) < cap:
                            new_vals.append(x & ((1 << shift) - 1))
                            new_ptrs.append((ra, rb))
                    elif x & mask_cb == 0:
                        sol = expand(p, ptrs, ra, rb)
                        if sol is not None:
                            sols.append(sol)
            i = j
        vals.append(new_vals)
        ptrs.append(new_ptrs)
    return sols


def expand(p, ptrs, a, b):
    """Walk parent pointers down to leaves, order canonically, reject
    repeated indices. Mirrors the RTL's in-place expand/order/check."""
    x = [a, b]
    for lev in range(p.k - 1, 0, -1):
        x = [c for row in x for c in ptrs[lev][row]]
    s = 1
    while s < len(x):
        for blk in range(0, len(x), 2 * s):
            if x[blk + s] < x[blk]:
                x[blk:blk + s], x[blk + s:blk + 2 * s] = (
                    x[blk + s:blk + 2 * s],
                    x[blk:blk + s],
                )
        s *= 2
    if len(set(x)) != len(x):
        return None
    return x


# --------------------------------------------- independent zcash verifier


def expand_array(data, bit_len, byte_pad=0):
    """zcashd ExpandArray."""
    out_width = (bit_len + 7) // 8 + byte_pad
    mask = (1 << bit_len) - 1
    out = bytearray()
    acc, acc_bits = 0, 0
    for byte in data:
        acc = ((acc << 8) | byte) & 0xFFFFFFFF
        acc_bits += 8
        if acc_bits >= bit_len:
            acc_bits -= bit_len
            out += bytes(byte_pad)
            for x in range(byte_pad, out_width):
                out.append(
                    (acc >> (acc_bits + 8 * (out_width - x - 1)))
                    & ((mask >> (8 * (out_width - x - 1))) & 0xFF)
                )
    return bytes(out)


def compress_array(data, bit_len, byte_pad=0):
    """zcashd CompressArray."""
    in_width = (bit_len + 7) // 8 + byte_pad
    out_len = bit_len * len(data) // (8 * in_width)
    mask = (1 << bit_len) - 1
    out = bytearray()
    acc, acc_bits, j = 0, 0, 0
    for _ in range(out_len):
        if acc_bits < 8:
            acc = (acc << bit_len) & 0xFFFFFFFF
            for x in range(byte_pad, in_width):
                shift = 8 * (in_width - x - 1)
                acc |= (data[j + x] & ((mask >> shift) & 0xFF)) << shift
            j += in_width
            acc_bits += bit_len
        acc_bits -= 8
        out.append((acc >> acc_bits) & 0xFF)
    return bytes(out)


def indices_to_minimal(p, indices):
    bit_len = p.cb + 1
    byte_pad = 4 - (bit_len + 7) // 8
    raw = b"".join(struct.pack(">I", i) for i in indices)
    return compress_array(raw, bit_len, byte_pad)


def minimal_to_indices(p, minimal):
    bit_len = p.cb + 1
    byte_pad = 4 - (bit_len + 7) // 8
    raw = expand_array(minimal, bit_len, byte_pad)
    return [struct.unpack(">I", raw[i:i + 4])[0] for i in range(0, len(raw), 4)]


def zcash_verify(p, header140, indices):
    """Port of zcashd Equihash<N,K>::IsValidSolution on index lists."""
    if len(indices) != p.nsol:
        return False
    rows = []
    for i in indices:
        d = digest(p, header140, i // p.ipho)
        j = i % p.ipho
        h = expand_array(d[j * p.n // 8:(j + 1) * p.n // 8], p.cb)
        rows.append((h, struct.pack(">I", i)))
    hash_len = p.hash_len
    while len(rows) > 1:
        nxt = []
        for a in range(0, len(rows), 2):
            (ha, ia), (hb, ib) = rows[a], rows[a + 1]
            if ha[:p.cbl] != hb[:p.cbl]:
                return False  # HasCollision
            if ib < ia:
                return False  # IndicesBefore (memcmp of BE index lists)
            sa = {ia[t:t + 4] for t in range(0, len(ia), 4)}
            if any(ib[t:t + 4] in sa for t in range(0, len(ib), 4)):
                return False  # DistinctIndices
            h = bytes(x ^ y for x, y in zip(ha, hb))[p.cbl:]
            nxt.append((h, ia + ib))
        rows = nxt
        hash_len -= p.cbl
    return all(b == 0 for b in rows[0][0][:hash_len])


# ------------------------------------------------------- chain protocol

DOWN_SOF = 0xA5  # controller -> chips (CI/CO)
UP_SOF = 0x5A  # chips -> controller (RI/RO)
CMD_JOB, CMD_STOP, CMD_SET_OT, CMD_PING = 0x01, 0x02, 0x03, 0x04
RSP_SOLUTION, RSP_PONG, RSP_DONE = 0x81, 0x84, 0x85
BROADCAST = 0xFF


def crc8(data):
    """CRC-8, poly 0x07, init 0x00 (ATM/SMBus style)."""
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def packet(sof, typ, addr, payload=b""):
    body = bytes([typ, addr]) + struct.pack("<H", len(payload)) + payload
    return bytes([sof]) + body + bytes([crc8(body)])


def parse_packets(stream):
    """Split an upstream byte stream into (type, addr, payload) tuples;
    raises on a bad start byte or CRC."""
    out, i = [], 0
    while i < len(stream):
        if stream[i] != UP_SOF:
            raise ValueError("bad start byte 0x%02x at %d" % (stream[i], i))
        typ, addr = stream[i + 1], stream[i + 2]
        ln = stream[i + 3] | (stream[i + 4] << 8)
        body = stream[i + 1:i + 5 + ln]
        if crc8(body) != stream[i + 5 + ln]:
            raise ValueError("bad CRC in packet at %d" % i)
        out.append((typ, addr, bytes(stream[i + 5:i + 5 + ln])))
        i += 6 + ln
    return out
