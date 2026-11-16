// Equihash proof-of-work: solver + verifier.
//
// Faithful port of the reference algorithm in zcash/src/crypto/equihash.{h,cpp}
// (BasicSolve path) and the consensus packing helpers (CompressArray,
// ExpandArray, GetMinimalFromIndices, GetIndicesFromMinimal).
//
// Supported params: any N divisible by 8 with K < N. Blake2b output length is
// (512/N)*(N/8) bytes, so N=200 uses a 50-byte digest and N=48/N=96 use a
// 60-byte digest.
const std = @import("std");

const Blake2b400 = std.crypto.hash.blake2.Blake2b(400); // 50-byte digest (N=200)
const Blake2b480 = std.crypto.hash.blake2.Blake2b(480); // 60-byte digest (N=48,96)

pub const Params = struct {
    n: u32,
    k: u32,

    pub fn indicesPerHashOutput(p: Params) usize {
        return 512 / p.n;
    }
    pub fn hashOutput(p: Params) usize {
        return p.indicesPerHashOutput() * p.n / 8;
    }
    pub fn collisionBitLength(p: Params) usize {
        return p.n / (p.k + 1);
    }
    pub fn collisionByteLength(p: Params) usize {
        return (p.collisionBitLength() + 7) / 8;
    }
    pub fn hashLength(p: Params) usize {
        return (@as(usize, p.k) + 1) * p.collisionByteLength();
    }
    /// FullStepRow width used during the K-1 combining rounds.
    pub fn fullWidth(p: Params) usize {
        return 2 * p.collisionByteLength() + 4 * (@as(usize, 1) << @intCast(p.k - 1));
    }
    /// Minimal solution size in bytes: (1<<K)*(cBitLen+1)/8.
    pub fn solutionSize(p: Params) usize {
        return (@as(usize, 1) << @intCast(p.k)) * (p.collisionBitLength() + 1) / 8;
    }
    pub fn initSize(p: Params) usize {
        return @as(usize, 1) << @intCast(p.collisionBitLength() + 1);
    }
    /// Blake2b personalization: "ZcashPoW" || le32(n) || le32(k).
    pub fn personalization(p: Params) [16]u8 {
        var pers: [16]u8 = undefined;
        @memcpy(pers[0..8], "ZcashPoW");
        std.mem.writeInt(u32, pers[8..12], p.n, .little);
        std.mem.writeInt(u32, pers[12..16], p.k, .little);
        return pers;
    }
};

pub const MAINNET = Params{ .n = 200, .k = 9 };
pub const TEST_SMALL = Params{ .n = 48, .k = 5 };

/// Compress big-endian `bit_len`-wide elements (with `byte_pad` leading zero
/// bytes each) into a packed byte string. Direct port of CompressArray.
pub fn compressArray(in: []const u8, out: []u8, bit_len: usize, byte_pad: usize) void {
    std.debug.assert(bit_len >= 8 and bit_len < 32);
    const in_width = (bit_len + 7) / 8 + byte_pad;
    std.debug.assert(out.len == bit_len * in.len / (8 * in_width));
    const mask: u32 = (@as(u32, 1) << @intCast(bit_len)) - 1;

    var acc_bits: usize = 0;
    var acc_value: u32 = 0;
    var j: usize = 0;
    for (out) |*o| {
        if (acc_bits < 8) {
            acc_value <<= @intCast(bit_len);
            for (byte_pad..in_width) |x| {
                const shift: usize = 8 * (in_width - x - 1);
                const keep: u32 = (mask >> @intCast(shift)) & 0xFF;
                acc_value |= @as(u32, in[j + x] & @as(u8, @truncate(keep))) << @intCast(shift);
            }
            j += in_width;
            acc_bits += bit_len;
        }
        acc_bits -= 8;
        o.* = @truncate((acc_value >> @intCast(acc_bits)) & 0xFF);
    }
}

/// Minimal (packed) solution bytes -> u32 indices (big-endian elements).
/// Port of GetIndicesFromMinimal.
pub fn minimalToIndices(gpa: std.mem.Allocator, minimal: []const u8, c_bit_len: usize) ![]u32 {
    const bit_len = c_bit_len + 1;
    const byte_pad = 4 - (bit_len + 7) / 8;
    const len_indices = 8 * 4 * minimal.len / bit_len;
    const array = try gpa.alloc(u8, len_indices);
    defer gpa.free(array);
    expandArray(minimal, array, bit_len, byte_pad);
    std.debug.assert(len_indices % 4 == 0);
    const ret = try gpa.alloc(u32, len_indices / 4);
    for (ret, 0..) |*r, i| {
        r.* = std.mem.readInt(u32, array[i * 4 ..][0..4], .big);
    }
    return ret;
}

/// u32 indices -> minimal (packed) solution bytes. Port of GetMinimalFromIndices.
pub fn indicesToMinimal(gpa: std.mem.Allocator, indices: []const u32, c_bit_len: usize) ![]u8 {
    const bit_len = c_bit_len + 1;
    const byte_pad = 4 - (bit_len + 7) / 8;
    const array = try gpa.alloc(u8, indices.len * 4);
    defer gpa.free(array);
    for (indices, 0..) |idx, i| {
        std.mem.writeInt(u32, array[i * 4 ..][0..4], idx, .big);
    }
    const ret = try gpa.alloc(u8, bit_len * indices.len * 4 / (8 * 4));
    compressArray(array, ret, bit_len, byte_pad);
    return ret;
}

/// Expand a packed byte string into big-endian `bit_len`-wide elements.
/// Direct port of ExpandArray.
pub fn expandArray(in: []const u8, out: []u8, bit_len: usize, byte_pad: usize) void {
    std.debug.assert(bit_len >= 8 and bit_len < 32);
    const out_width = (bit_len + 7) / 8 + byte_pad;
    std.debug.assert(out.len == 8 * out_width * in.len / bit_len);
    const mask: u32 = (@as(u32, 1) << @intCast(bit_len)) - 1;

    var acc_bits: usize = 0;
    var acc_value: u32 = 0;
    var j: usize = 0;
    for (in) |b| {
        acc_value = (acc_value << 8) | b;
        acc_bits += 8;
        if (acc_bits >= bit_len) {
            acc_bits -= bit_len;
            for (0..byte_pad) |x| out[j + x] = 0;
            for (byte_pad..out_width) |x| {
                const shift: usize = acc_bits + 8 * (out_width - x - 1);
                const keep: u32 = (mask >> @intCast(8 * (out_width - x - 1))) & 0xFF;
                out[j + x] = @truncate(((acc_value >> @intCast(shift)) & keep));
            }
            j += out_width;
        }
    }
}

/// Hash state: the 140-byte header input plus Blake2b personalization.
/// Equivalent to zcashd's eh_HashState after Update(input).
pub const HashState = struct {
    input: []const u8,
    pers: [16]u8,

    pub fn init(params: Params, input: []const u8) HashState {
        return .{ .input = input, .pers = params.personalization() };
    }
};

/// GenerateHash: Blake2b(input || le32(g)), truncated to `out.len` bytes.
/// `out.len` selects the digest: 50 bytes for N=200, 60 for N=48/96.
pub fn generateHash(state: HashState, g: u32, out: []u8) void {
    var le: [4]u8 = undefined;
    std.mem.writeInt(u32, &le, g, .little);
    if (out.len == 50) {
        var h = Blake2b400.init(.{ .context = state.pers });
        h.update(state.input);
        h.update(&le);
        var d: [50]u8 = undefined;
        h.final(&d);
        @memcpy(out, &d);
    } else if (out.len == 60) {
        var h = Blake2b480.init(.{ .context = state.pers });
        h.update(state.input);
        h.update(&le);
        var d: [60]u8 = undefined;
        h.final(&d);
        @memcpy(out, &d);
    } else {
        unreachable;
    }
}

/// A Wagner table row: expanded hash bytes followed by big-endian u32 indices.
/// Width is fixed per parameter set so tables are single flat allocations
/// (like vector<StepRow<WIDTH>> in zcashd).
fn RowType(comptime W: usize) type {
    return struct {
        data: [W]u8,
    };
}

/// Parameter sets this miner can solve/verify.
pub fn checkParams(n: u32, k: u32) !Params {
    if ((n == 200 and k == 9) or (n == 96 and k == 5) or (n == 48 and k == 5)) {
        return Params{ .n = n, .k = k };
    }
    return error.UnsupportedParams;
}

/// Find one solution for `input`, appending minimal solution bytes to
/// `solution_out`. Returns false if none exists (or cancelled).
/// Port of Equihash<N,K>::BasicSolve. Kept as a differential-test oracle
/// for the optimized solver below.
pub fn solveBasic(
    gpa: std.mem.Allocator,
    params: Params,
    input: []const u8,
    cancel: ?*const std.atomic.Value(bool),
    solution_out: *std.ArrayList(u8),
) !bool {
    if (params.n == 200 and params.k == 9) {
        return solveBasicFor(gpa, Params{ .n = 200, .k = 9 }, input, cancel, solution_out);
    } else if (params.n == 96 and params.k == 5) {
        return solveBasicFor(gpa, Params{ .n = 96, .k = 5 }, input, cancel, solution_out);
    } else if (params.n == 48 and params.k == 5) {
        return solveBasicFor(gpa, Params{ .n = 48, .k = 5 }, input, cancel, solution_out);
    } else {
        return error.UnsupportedParams;
    }
}

/// Called synchronously with a verified, unique minimal solution. The bytes
/// are borrowed until the callback returns. Return false to stop enumeration.
pub const SolutionHandler = struct {
    context: *anyopaque,
    on_solution: *const fn (*anyopaque, []const u8) anyerror!bool,
};

const Collector = struct {
    gpa: std.mem.Allocator,
    handler: SolutionHandler,
    seen: std.StringHashMap(void),
    count: usize = 0,
    stopped: bool = false,

    fn deinit(c: *Collector) void {
        var keys = c.seen.keyIterator();
        while (keys.next()) |key| c.gpa.free(key.*);
        c.seen.deinit();
    }
    fn emit(c: *Collector, solution: []const u8) !void {
        if (c.seen.contains(solution)) return;
        const owned = try c.gpa.dupe(u8, solution);
        c.seen.put(owned, {}) catch |err| {
            c.gpa.free(owned);
            return err;
        };
        c.count += 1;
        c.stopped = !try c.handler.on_solution(c.handler.context, solution);
    }
};

/// Enumerate all distinct solutions retained by the optimized solver. Checks
/// cancellation throughout solving and permits the consumer to stop early.
/// Completeness is a differential-test obligation, not implied by verification.
pub fn solveEach(gpa: std.mem.Allocator, params: Params, input: []const u8, cancel: ?*const std.atomic.Value(bool), handler: SolutionHandler) !usize {
    var collector = Collector{ .gpa = gpa, .handler = handler, .seen = std.StringHashMap(void).init(gpa) };
    defer collector.deinit();
    var unused: std.ArrayList(u8) = .empty;
    defer unused.deinit(gpa);
    if (params.n == 200 and params.k == 9) {
        _ = try solveOptFor(gpa, .{ .n = 200, .k = 9 }, input, cancel, &unused, &collector);
    } else if (params.n == 96 and params.k == 5) {
        _ = try solveOptFor(gpa, .{ .n = 96, .k = 5 }, input, cancel, &unused, &collector);
    } else if (params.n == 48 and params.k == 5) {
        _ = try solveOptFor(gpa, .{ .n = 48, .k = 5 }, input, cancel, &unused, &collector);
    } else return error.UnsupportedParams;
    return collector.count;
}

/// Optimized solver entry point (truncated Wagner rounds + index
/// recreation). Same contract as solveBasic; this is what `solve` uses.
pub fn solve(
    gpa: std.mem.Allocator,
    params: Params,
    input: []const u8,
    cancel: ?*const std.atomic.Value(bool),
    solution_out: *std.ArrayList(u8),
) !bool {
    if (params.n == 200 and params.k == 9) {
        return solveOptFor(gpa, Params{ .n = 200, .k = 9 }, input, cancel, solution_out, null);
    } else if (params.n == 96 and params.k == 5) {
        return solveOptFor(gpa, Params{ .n = 96, .k = 5 }, input, cancel, solution_out, null);
    } else if (params.n == 48 and params.k == 5) {
        return solveOptFor(gpa, Params{ .n = 48, .k = 5 }, input, cancel, solution_out, null);
    } else {
        return error.UnsupportedParams;
    }
}

/// Keep the top 8 bits of an index. Port of TruncateIndex.
fn truncateIndex(idx: u32, ilen: usize) u8 {
    return @truncate((idx >> @intCast(ilen - 8)) & 0xff);
}

/// Prepend truncated byte `t` to the low bits `r`. Port of UntruncateIndex.
fn untruncateIndex(t: u8, r: u32, ilen: usize) u32 {
    return (@as(u32, t) << @intCast(ilen - 8)) | r;
}

/// Greedy full-pairing test on truncated index bytes: true iff every byte
/// finds a distinct equal partner. Port of IsProbablyDuplicate.
fn isProbablyDuplicate(idxs: []const u8) bool {
    std.debug.assert(idxs.len <= 512);
    var checked: [512]bool = [_]bool{false} ** 512;
    var count: usize = 0;
    for (0..idxs.len) |z| {
        if (!checked[z]) {
            for (z + 1..idxs.len) |y| {
                if (!checked[y] and idxs[z] == idxs[y]) {
                    checked[y] = true;
                    count += 2;
                    break;
                }
            }
        }
    }
    return count == idxs.len;
}

/// The subtree's minimum full index must truncate to the expected partial
/// byte. Port of IsValidBranch (rows are kept minimum-first).
fn validBranch(row: []const u8, hash_len: usize, ilen: usize, t: u8) bool {
    const idx = std.mem.readInt(u32, row[hash_len..][0..4], .big);
    return truncateIndex(idx, ilen) == t;
}

fn hasCollision(a: []const u8, b: []const u8, len: usize) bool {
    return std.mem.eql(u8, a[0..len], b[0..len]);
}

/// memcmp of the index regions, like FullStepRow::IndicesBefore.
fn indicesBefore(a: []const u8, b: []const u8, hash_len: usize, idx_len: usize) bool {
    return std.mem.order(u8, a[hash_len..][0..idx_len], b[hash_len..][0..idx_len]) == .lt;
}

/// No shared u32 index between the two rows, like DistinctIndices.
fn distinctIndices(a: []const u8, b: []const u8, hash_len: usize, idx_len: usize) bool {
    var i: usize = 0;
    while (i < idx_len) : (i += 4) {
        var j: usize = 0;
        while (j < idx_len) : (j += 4) {
            if (std.mem.eql(u8, a[hash_len..][i..][0..4], b[hash_len..][j..][0..4])) return false;
        }
    }
    return true;
}

fn isZero(s: []const u8) bool {
    for (s) |b| if (b != 0) return false;
    return true;
}

/// Sort rows lexicographically by `data[0..prefix_len]` with an LSD radix
/// sort over an index array plus an in-place cycle permutation: O(n) work
/// and O(n) u32 side buffers instead of O(n log n) full-row swaps.
/// Same grouping semantics the Wagner rounds need, and the same shape a
/// GPU radix kernel will implement (Unit 4).
fn radixSortRows(gpa: std.mem.Allocator, comptime R: type, rows: []R, prefix_len: usize) !void {
    const n = rows.len;
    if (n < 2 or prefix_len == 0) return;
    const order = try gpa.alloc(u32, n);
    defer gpa.free(order);
    const aux = try gpa.alloc(u32, n);
    defer gpa.free(aux);
    for (order, 0..) |*o, i| o.* = @truncate(i);
    var src = order;
    var dst = aux;
    var pos: usize = prefix_len;
    while (pos > 0) {
        pos -= 1;
        var counts = [_]usize{0} ** 256;
        for (src) |idx| counts[rows[@as(usize, idx)].data[pos]] += 1;
        var sum: usize = 0;
        for (&counts) |*c| {
            const t = c.*;
            c.* = sum;
            sum += t;
        }
        for (src) |idx| {
            const b = rows[@as(usize, idx)].data[pos];
            dst[counts[b]] = idx;
            counts[b] += 1;
        }
        const t = src;
        src = dst;
        dst = t;
    }
    var done = try gpa.alloc(bool, n);
    defer gpa.free(done);
    @memset(done, false);
    var tmp: R = undefined;
    for (0..n) |i| {
        if (done[i]) continue;
        var j = i;
        tmp = rows[i];
        while (true) {
            done[j] = true;
            const k: usize = @intCast(src[j]);
            if (k == i) {
                rows[j] = tmp;
                break;
            }
            rows[j] = rows[k];
            j = k;
        }
    }
}

/// Combine two colliding rows: xor hashes (dropping `trim` leading bytes),
/// concatenate index lists smaller-first. Port of FullStepRow(a, b, ...).
fn combineRow(out: []u8, a: []const u8, b: []const u8, hash_len: usize, idx_len: usize, trim: usize) void {
    for (trim..hash_len) |i| out[i - trim] = a[i] ^ b[i];
    const dst = (hash_len - trim);
    if (indicesBefore(a, b, hash_len, idx_len)) {
        @memcpy(out[dst..][0..idx_len], a[hash_len..][0..idx_len]);
        @memcpy(out[dst..][idx_len..][0..idx_len], b[hash_len..][0..idx_len]);
    } else {
        @memcpy(out[dst..][0..idx_len], b[hash_len..][0..idx_len]);
        @memcpy(out[dst..][idx_len..][0..idx_len], a[hash_len..][0..idx_len]);
    }
}

fn solveBasicFor(
    gpa: std.mem.Allocator,
    comptime P: Params,
    input: []const u8,
    cancel: ?*const std.atomic.Value(bool),
    solution_out: *std.ArrayList(u8),
) !bool {
    const CBL = comptime P.collisionByteLength();
    const HLEN0 = comptime P.hashLength();
    const IPHO = comptime P.indicesPerHashOutput();
    const N8: usize = comptime P.n / 8;
    const HOUT = comptime P.hashOutput();
    const INIT = comptime P.initSize();
    const NSOL: usize = comptime @as(usize, 1) << P.k;
    const R = RowType(comptime P.fullWidth());
    const FINAL_W = comptime 2 * CBL + 4 * NSOL;
    const state = HashState.init(P, input);

    // 1) Generate first list.
    var rows: std.ArrayList(R) = .empty;
    defer rows.deinit(gpa);
    try rows.ensureTotalCapacity(gpa, INIT);
    var tmp: [64]u8 = undefined;
    var g: u32 = 0;
    while (rows.items.len < INIT) : (g += 1) {
        if (cancel) |c| if (c.load(.seq_cst)) return false;
        generateHash(state, g, tmp[0..HOUT]);
        var i: usize = 0;
        while (i < IPHO and rows.items.len < INIT) : (i += 1) {
            var r: R = undefined;
            @memset(r.data[0..], 0);
            expandArray(tmp[i * N8 ..][0..N8], r.data[0..HLEN0], P.collisionBitLength(), 0);
            const idx: u32 = g * @as(u32, @intCast(IPHO)) + @as(u32, @intCast(i));
            std.mem.writeInt(u32, r.data[HLEN0..][0..4], idx, .big);
            try rows.append(gpa, r);
        }
    }

    // 2) K-1 combining rounds; each trims CBL bytes.
    var hash_len: usize = HLEN0;
    var idx_len: usize = 4;
    var round: u32 = 1;
    while (round < P.k and rows.items.len > 0) : (round += 1) {
        try radixSortRows(gpa, R, rows.items, CBL);
        var spill: std.ArrayList(R) = .empty;
        defer spill.deinit(gpa);
        const items = rows.items;
        var i: usize = 0;
        var pos_free: usize = 0;
        while (i + 1 < items.len) {
            if (cancel) |c| if (c.load(.seq_cst)) return false;
            var j: usize = 1;
            while (i + j < items.len and hasCollision(items[i].data[0..], items[i + j].data[0..], CBL)) {
                j += 1;
            }
            // Collect this group's pairs first: writing them back in-place
            // while still enumerating would clobber unread group members
            // once a group yields more pairs than it has rows.
            var l: usize = 0;
            while (l + 1 < j) : (l += 1) {
                var m: usize = l + 1;
                while (m < j) : (m += 1) {
                    const a = items[i + l].data[0..];
                    const b = items[i + m].data[0..];
                    if (distinctIndices(a, b, hash_len, idx_len)) {
                        var nr: R = undefined;
                        @memset(nr.data[0..], 0);
                        combineRow(nr.data[0..], a, b, hash_len, idx_len, CBL);
                        try spill.append(gpa, nr);
                    }
                }
            }
            while (pos_free < i + j and spill.items.len > 0) {
                items[pos_free] = spill.pop().?;
                pos_free += 1;
            }
            i += j;
        }
        while (pos_free < items.len and spill.items.len > 0) {
            items[pos_free] = spill.pop().?;
            pos_free += 1;
        }
        if (spill.items.len > 0) {
            try rows.appendSlice(gpa, spill.items);
        } else if (pos_free < items.len) {
            rows.shrinkRetainingCapacity(pos_free);
        }
        hash_len -= CBL;
        idx_len *= 2;
    }

    // 3) Final round: full collision on the remaining hash bytes.
    if (rows.items.len > 1) {
        try radixSortRows(gpa, R, rows.items, hash_len);
        const items = rows.items;
        var idxs: std.ArrayList(u32) = .empty;
        defer idxs.deinit(gpa);
        try idxs.ensureTotalCapacity(gpa, NSOL);
        var i: usize = 0;
        while (i + 1 < items.len) {
            if (cancel) |c| if (c.load(.seq_cst)) return false;
            var j: usize = 1;
            while (i + j < items.len and hasCollision(items[i].data[0..], items[i + j].data[0..], hash_len)) {
                j += 1;
            }
            var l: usize = 0;
            while (l + 1 < j) : (l += 1) {
                var m: usize = l + 1;
                while (m < j) : (m += 1) {
                    const a = items[i + l].data[0..];
                    const b = items[i + m].data[0..];
                    if (!distinctIndices(a, b, hash_len, idx_len)) continue;
                    var res: [FINAL_W]u8 = undefined;
                    @memset(res[0..], 0);
                    combineRow(res[0..], a, b, hash_len, idx_len, 0);
                    idxs.items.len = 0;
                    for (0..NSOL) |t| {
                        idxs.appendAssumeCapacity(std.mem.readInt(u32, res[hash_len + t * 4 ..][0..4], .big));
                    }
                    const minimal = try indicesToMinimal(gpa, idxs.items, P.collisionBitLength());
                    defer gpa.free(minimal);
                    try solution_out.appendSlice(gpa, minimal);
                    return true;
                }
            }
            i += j;
        }
    }
    return false;
}

/// Merge helper for the recreate phase: group rows by `clen`-byte hash
/// collision, keep pairs whose subtrees match the expected truncated
/// bytes (`lt` left, `rt` right). Port of CollideBranches.
fn collideBranches(
    gpa: std.mem.Allocator,
    comptime FR: type,
    rows: *std.ArrayList(FR),
    hash_len: usize,
    idx_len: usize,
    clen: usize,
    ilen: usize,
    lt: u8,
    rt: u8,
) !void {
    var spill: std.ArrayList(FR) = .empty;
    defer spill.deinit(gpa);
    const items = rows.items;
    var i: usize = 0;
    var pos_free: usize = 0;
    while (i + 1 < items.len) {
        var j: usize = 1;
        while (i + j < items.len and hasCollision(items[i].data[0..], items[i + j].data[0..], clen)) {
            j += 1;
        }
        var l: usize = 0;
        while (l + 1 < j) : (l += 1) {
            var m: usize = l + 1;
            while (m < j) : (m += 1) {
                const a = items[i + l].data[0..];
                const b = items[i + m].data[0..];
                if (!distinctIndices(a, b, hash_len, idx_len)) continue;
                const ok = (validBranch(a, hash_len, ilen, lt) and validBranch(b, hash_len, ilen, rt)) or
                    (validBranch(b, hash_len, ilen, lt) and validBranch(a, hash_len, ilen, rt));
                if (!ok) continue;
                var nr: FR = undefined;
                @memset(nr.data[0..], 0);
                combineRow(nr.data[0..], a, b, hash_len, idx_len, clen);
                try spill.append(gpa, nr);
            }
        }
        while (pos_free < i + j and spill.items.len > 0) {
            items[pos_free] = spill.pop().?;
            pos_free += 1;
        }
        i += j;
    }
    while (pos_free < items.len and spill.items.len > 0) {
        items[pos_free] = spill.pop().?;
        pos_free += 1;
    }
    if (spill.items.len > 0) {
        try rows.appendSlice(gpa, spill.items);
    } else if (pos_free < items.len) {
        rows.shrinkRetainingCapacity(pos_free);
    }
}

/// Recreate full indices for one partial (truncated-byte) solution and
/// return the first candidate the independent verifier accepts.
/// Port of the OptimisedSolve culling phase.
fn attemptPartial(
    gpa: std.mem.Allocator,
    comptime P: Params,
    input: []const u8,
    state: HashState,
    partial: []const u8,
    cancel: ?*const std.atomic.Value(bool),
    solution_out: *std.ArrayList(u8),
    collector: ?*Collector,
) anyerror!bool {
    const CBL = comptime P.collisionByteLength();
    const HLEN0 = comptime P.hashLength();
    const IPHO = comptime P.indicesPerHashOutput();
    const N8: usize = comptime P.n / 8;
    const HOUT = comptime P.hashOutput();
    const NSOL: usize = comptime @as(usize, 1) << P.k;
    const IBLEN = comptime P.collisionBitLength() + 1;
    const FW = comptime 2 * CBL + 4 * NSOL;
    const FR = RowType(FW);
    const RECREATE: u32 = comptime @as(u32, 1) << @intCast(IBLEN - 8);
    std.debug.assert(partial.len == NSOL);

    var X: [P.k + 1]?std.ArrayList(FR) = [_]?std.ArrayList(FR){null} ** (P.k + 1);
    defer {
        for (&X) |*slot| {
            if (slot.*) |*list| list.deinit(gpa);
        }
    }

    var tmpHash: [64]u8 = undefined;
    var idxs: std.ArrayList(u32) = .empty;
    defer idxs.deinit(gpa);
    try idxs.ensureTotalCapacity(gpa, NSOL);

    var i: usize = 0;
    while (i < NSOL) : (i += 1) {
        if (cancel) |c| if (c.load(.seq_cst)) return false;
        var ic: std.ArrayList(FR) = .empty;
        defer ic.deinit(gpa);
        try ic.ensureTotalCapacity(gpa, RECREATE);
        var last_g: u32 = std.math.maxInt(u32);
        var j: u32 = 0;
        while (j < RECREATE) : (j += 1) {
            const new_index = untruncateIndex(partial[i], j, IBLEN);
            const gi = new_index / @as(u32, @intCast(IPHO));
            const ii: usize = @intCast(new_index % @as(u32, @intCast(IPHO)));
            if (gi != last_g) {
                generateHash(state, gi, tmpHash[0..HOUT]);
                last_g = gi;
            }
            var r: FR = undefined;
            @memset(r.data[0..], 0);
            expandArray(tmpHash[ii * N8 ..][0..N8], r.data[0..HLEN0], P.collisionBitLength(), 0);
            std.mem.writeInt(u32, r.data[HLEN0..][0..4], new_index, .big);
            try ic.append(gpa, r);
        }
        // Binary-carry merge of this position's candidates into X.
        var hash_len: usize = HLEN0;
        var idx_len: usize = 4;
        var rti: usize = i;
        var r: usize = 0;
        while (true) {
            std.debug.assert(r <= P.k);
            if (cancel) |c| {
                if (c.load(.seq_cst)) {
                    return false;
                }
            }
            if (X[r] == null) {
                X[r] = ic;
                ic = .empty; // Ownership moves to X; the local defer is inert.
                break;
            }
            try ic.appendSlice(gpa, X[r].?.items);
            X[r].?.deinit(gpa);
            X[r] = null;
            try radixSortRows(gpa, FR, ic.items, hash_len);
            const lti = rti - (@as(usize, 1) << @intCast(r));
            try collideBranches(gpa, FR, &ic, hash_len, idx_len, CBL, IBLEN, partial[lti], partial[rti]);
            if (ic.items.len == 0) {
                return false;
            }
            hash_len -= CBL;
            idx_len *= 2;
            rti = lti;
            r += 1;
        }
    }

    // Top of the tree: X[K] rows carry CBL hash bytes plus all indices.
    if (X[P.k] == null) return false;
    for (X[P.k].?.items) |row| {
        if (cancel) |c| if (c.load(.seq_cst)) return false;
        idxs.items.len = 0;
        for (0..NSOL) |t| {
            idxs.appendAssumeCapacity(std.mem.readInt(u32, row.data[CBL + t * 4 ..][0..4], .big));
        }
        const minimal = try indicesToMinimal(gpa, idxs.items, P.collisionBitLength());
        defer gpa.free(minimal);
        // Safety gate: only emit what the independent verifier accepts.
        if (try verify(gpa, Params{ .n = P.n, .k = P.k }, input, minimal)) {
            if (collector) |c| {
                try c.emit(minimal);
                if (c.stopped) return true;
            } else {
                try solution_out.appendSlice(gpa, minimal);
                return true;
            }
        }
    }
    return false;
}

fn solveOptFor(
    gpa: std.mem.Allocator,
    comptime P: Params,
    input: []const u8,
    cancel: ?*const std.atomic.Value(bool),
    solution_out: *std.ArrayList(u8),
    collector: ?*Collector,
) anyerror!bool {
    if (cancel) |c| if (c.load(.seq_cst)) return false;
    const CBL = comptime P.collisionByteLength();
    const HLEN0 = comptime P.hashLength();
    const IPHO = comptime P.indicesPerHashOutput();
    const N8: usize = comptime P.n / 8;
    const HOUT = comptime P.hashOutput();
    const INIT = comptime P.initSize();
    const IBLEN = comptime P.collisionBitLength() + 1;
    const TW = comptime @max(HLEN0 + 1, 2 * CBL + (@as(usize, 1) << (P.k - 1)));
    const FTW = comptime @max(HLEN0 + 1, 2 * CBL + (@as(usize, 1) << P.k));
    const TR = RowType(TW);
    const state = HashState.init(P, input);

    // Phase A: truncated Wagner rounds -> partial solutions.
    var rows: std.ArrayList(TR) = .empty;
    defer rows.deinit(gpa);
    try rows.ensureTotalCapacity(gpa, INIT);
    var tmp: [64]u8 = undefined;
    var g: u32 = 0;
    while (rows.items.len < INIT) : (g += 1) {
        if (cancel) |c| if (c.load(.seq_cst)) return false;
        generateHash(state, g, tmp[0..HOUT]);
        var i: usize = 0;
        while (i < IPHO and rows.items.len < INIT) : (i += 1) {
            var r: TR = undefined;
            @memset(r.data[0..], 0);
            expandArray(tmp[i * N8 ..][0..N8], r.data[0..HLEN0], P.collisionBitLength(), 0);
            const idx: u32 = g * @as(u32, @intCast(IPHO)) + @as(u32, @intCast(i));
            r.data[HLEN0] = truncateIndex(idx, IBLEN);
            try rows.append(gpa, r);
        }
    }

    var hash_len: usize = HLEN0;
    var idx_len: usize = 1;
    var round: u32 = 1;
    while (round < P.k and rows.items.len > 0) : (round += 1) {
        try radixSortRows(gpa, TR, rows.items, CBL);
        var spill: std.ArrayList(TR) = .empty;
        defer spill.deinit(gpa);
        const items = rows.items;
        var pos_free: usize = 0;
        // Buckets: contiguous segments sharing the first sort byte. A
        // collision group shares the full prefix, so no group ever spans
        // buckets; enumeration order and output are unchanged. This is
        // the partition shape the GPU port needs for device memory.
        var bstart: usize = 0;
        while (bstart + 1 < items.len) {
            var bend = bstart + 1;
            const bkey = items[bstart].data[0];
            while (bend < items.len and items[bend].data[0] == bkey) bend += 1;
            var i: usize = bstart;
            while (i + 1 < bend) {
                if (cancel) |c| if (c.load(.seq_cst)) return false;
                var j: usize = 1;
                while (i + j < bend and hasCollision(items[i].data[0..], items[i + j].data[0..], CBL)) {
                    j += 1;
                }
                var l: usize = 0;
                while (l + 1 < j) : (l += 1) {
                    var m: usize = l + 1;
                    while (m < j) : (m += 1) {
                        const a = items[i + l].data[0..];
                        const b = items[i + m].data[0..];
                        var xi: [TW]u8 = undefined;
                        @memset(xi[0..], 0);
                        combineRow(xi[0..], a, b, hash_len, idx_len, CBL);
                        // Pairs that collide only because truncation hid
                        // distinct indices behind an all-zero xor are dropped.
                        if (isZero(xi[0 .. hash_len - CBL]) and
                            isProbablyDuplicate(xi[hash_len - CBL ..][0 .. 2 * idx_len]))
                        {
                            continue;
                        }
                        var nr: TR = undefined;
                        nr.data = xi;
                        try spill.append(gpa, nr);
                    }
                }
                while (pos_free < i + j and spill.items.len > 0) {
                    items[pos_free] = spill.pop().?;
                    pos_free += 1;
                }
                i += j;
            }
            bstart = bend;
        }
        while (pos_free < items.len and spill.items.len > 0) {
            items[pos_free] = spill.pop().?;
            pos_free += 1;
        }
        if (spill.items.len > 0) {
            try rows.appendSlice(gpa, spill.items);
        } else if (pos_free < items.len) {
            rows.shrinkRetainingCapacity(pos_free);
        }
        hash_len -= CBL;
        idx_len *= 2;
    }

    // Phase A final round: collect partial (truncated-index) solutions.
    var partials: std.ArrayList([]u8) = .empty;
    defer {
        for (partials.items) |p| gpa.free(p);
        partials.deinit(gpa);
    }
    if (rows.items.len > 1) {
        try radixSortRows(gpa, TR, rows.items, hash_len);
        const items = rows.items;
        var bstart: usize = 0;
        while (bstart + 1 < items.len) {
            var bend = bstart + 1;
            const bkey = items[bstart].data[0];
            while (bend < items.len and items[bend].data[0] == bkey) bend += 1;
            var i: usize = bstart;
            while (i + 1 < bend) {
                if (cancel) |c| if (c.load(.seq_cst)) return false;
                var j: usize = 1;
                while (i + j < bend and hasCollision(items[i].data[0..], items[i + j].data[0..], hash_len)) {
                    j += 1;
                }
                var l: usize = 0;
                while (l + 1 < j) : (l += 1) {
                    var m: usize = l + 1;
                    while (m < j) : (m += 1) {
                        const a = items[i + l].data[0..];
                        const b = items[i + m].data[0..];
                        var res: [FTW]u8 = undefined;
                        @memset(res[0..], 0);
                        combineRow(res[0..], a, b, hash_len, idx_len, 0);
                        const tb = res[hash_len..][0 .. 2 * idx_len];
                        if (isProbablyDuplicate(tb)) continue;
                        const partial = try gpa.dupe(u8, tb);
                        errdefer gpa.free(partial);
                        try partials.append(gpa, partial);
                    }
                }
                i += j;
            }
            bstart = bend;
        }
    }

    // Phase B: recreate full indices for each partial solution.
    for (partials.items) |p| {
        const found = try attemptPartial(gpa, P, input, state, p, cancel, solution_out, collector);
        if (collector) |c| {
            if (c.stopped) return c.count > 0;
        } else if (found) return true;
        if (cancel) |c| if (c.load(.seq_cst)) return false;
    }
    return false;
}

/// Verify a minimal solution against `input`. Returns false for any invalid
/// proof (wrong size, bad collisions, mis-ordered or duplicate indices,
/// non-zero final xor).
pub fn verify(
    gpa: std.mem.Allocator,
    params: Params,
    input: []const u8,
    minimal: []const u8,
) !bool {
    if (params.n == 200 and params.k == 9) {
        return verifyFor(gpa, Params{ .n = 200, .k = 9 }, input, minimal);
    } else if (params.n == 96 and params.k == 5) {
        return verifyFor(gpa, Params{ .n = 96, .k = 5 }, input, minimal);
    } else if (params.n == 48 and params.k == 5) {
        return verifyFor(gpa, Params{ .n = 48, .k = 5 }, input, minimal);
    } else {
        return error.UnsupportedParams;
    }
}

fn verifyFor(
    gpa: std.mem.Allocator,
    comptime P: Params,
    input: []const u8,
    minimal: []const u8,
) !bool {
    if (minimal.len != P.solutionSize()) return false;
    const CBL = comptime P.collisionByteLength();
    const HLEN0 = comptime P.hashLength();
    const IPHO = comptime P.indicesPerHashOutput();
    const N8: usize = comptime P.n / 8;
    const HOUT = comptime P.hashOutput();
    const NSOL: usize = comptime @as(usize, 1) << P.k;
    // The rebuilt tree collapses to a single row holding all 2^K indices,
    // so verifier rows use the final width (FinalFullWidth in zcashd).
    const R = RowType(comptime (2 * P.collisionByteLength() + 4 * (@as(usize, 1) << P.k)));
    const state = HashState.init(P, input);

    const idxs = try minimalToIndices(gpa, minimal, P.collisionBitLength());
    defer gpa.free(idxs);
    if (idxs.len != NSOL) return false;

    var rows: std.ArrayList(R) = .empty;
    defer rows.deinit(gpa);
    try rows.ensureTotalCapacity(gpa, NSOL);
    var tmp: [64]u8 = undefined;
    var last_g: u32 = std.math.maxInt(u32);
    for (idxs) |idx| {
        const gi: u32 = idx / @as(u32, @intCast(IPHO));
        const ii: usize = @as(usize, idx) % IPHO;
        if (gi != last_g) {
            generateHash(state, gi, tmp[0..HOUT]);
            last_g = gi;
        }
        var r: R = undefined;
        @memset(r.data[0..], 0);
        expandArray(tmp[ii * N8 ..][0..N8], r.data[0..HLEN0], P.collisionBitLength(), 0);
        std.mem.writeInt(u32, r.data[HLEN0..][0..4], idx, .big);
        try rows.append(gpa, r);
    }

    var hash_len: usize = HLEN0;
    var idx_len: usize = 4;
    while (rows.items.len > 1) {
        if (rows.items.len % 2 != 0) return false;
        var next: std.ArrayList(R) = .empty;
        defer next.deinit(gpa);
        try next.ensureTotalCapacity(gpa, rows.items.len / 2);
        var i: usize = 0;
        while (i < rows.items.len) : (i += 2) {
            const a = rows.items[i].data[0..];
            const b = rows.items[i + 1].data[0..];
            if (!hasCollision(a, b, CBL)) return false;
            if (indicesBefore(b, a, hash_len, idx_len)) return false;
            if (!distinctIndices(a, b, hash_len, idx_len)) return false;
            var nr: R = undefined;
            @memset(nr.data[0..], 0);
            combineRow(nr.data[0..], a, b, hash_len, idx_len, CBL);
            try next.append(gpa, nr);
        }
        rows.shrinkRetainingCapacity(0);
        try rows.appendSlice(gpa, next.items);
        hash_len -= CBL;
        idx_len *= 2;
    }
    return isZero(rows.items[0].data[0..hash_len]);
}

const util = @import("util.zig");

const cgpu = @cImport(@cInclude("equihash_gpu.h"));

fn cGeom(params: Params, hash_bytes: usize, idx_bytes: usize, prefix: usize, trim: usize, unit: u32, mode: u32) cgpu.eq_geom_t {
    return .{
        .n = params.n,
        .k = params.k,
        .hash_bytes = @truncate(hash_bytes),
        .idx_bytes = @truncate(idx_bytes),
        .prefix_bytes = @truncate(prefix),
        .trim_bytes = @truncate(trim),
        .index_unit = unit,
        .filter_mode = mode,
    };
}

fn expectHexEqual(gpa: std.mem.Allocator, got: []const u8, want_hex: []const u8) !void {
    const want = try util.hexDecode(gpa, want_hex);
    defer gpa.free(want);
    try std.testing.expectEqualSlices(u8, want, got);
}

test "expand/contract arrays match zcash vectors" {
    const gpa = std.testing.allocator;
    const Case = struct {
        bit_len: usize,
        byte_pad: usize,
        compact: []const u8,
        expanded: []const u8,
    };
    const cases = [_]Case{
        .{ .bit_len = 11, .byte_pad = 0, .compact = "ffffffffffffffffffffff", .expanded = "07ff07ff07ff07ff07ff07ff07ff07ff" },
        .{ .bit_len = 21, .byte_pad = 0, .compact = "aaaaad55556aaaab55555aaaaad55556aaaab55555", .expanded = "155555155555155555155555155555155555155555155555" },
        .{ .bit_len = 21, .byte_pad = 0, .compact = "000220000a7ffffe00123022b38226ac19bdf23456", .expanded = "0000440000291fffff0001230045670089ab00cdef123456" },
        .{ .bit_len = 14, .byte_pad = 0, .compact = "cccf333cccf333cccf333cccf333cccf333cccf333cccf333cccf333", .expanded = "3333333333333333333333333333333333333333333333333333333333333333" },
        .{ .bit_len = 11, .byte_pad = 2, .compact = "ffffffffffffffffffffff", .expanded = "000007ff000007ff000007ff000007ff000007ff000007ff000007ff000007ff" },
    };
    for (cases) |c| {
        const compact = try util.hexDecode(gpa, c.compact);
        defer gpa.free(compact);
        const want_exp = try util.hexDecode(gpa, c.expanded);
        defer gpa.free(want_exp);
        const out_width = (c.bit_len + 7) / 8 + c.byte_pad;
        const got_exp = try gpa.alloc(u8, 8 * out_width * compact.len / c.bit_len);
        defer gpa.free(got_exp);
        expandArray(compact, got_exp, c.bit_len, c.byte_pad);
        try std.testing.expectEqualSlices(u8, want_exp, got_exp);
        const in_width = (c.bit_len + 7) / 8 + c.byte_pad;
        const got_comp = try gpa.alloc(u8, c.bit_len * want_exp.len / (8 * in_width));
        defer gpa.free(got_comp);
        compressArray(want_exp, got_comp, c.bit_len, c.byte_pad);
        try std.testing.expectEqualSlices(u8, compact, got_comp);
    }
}

test "minimal solution representation matches zcash vectors" {
    const gpa = std.testing.allocator;
    const idx1 = [_]u32{ 1, 1, 1, 1, 1, 1, 1, 1 };
    const m1 = try indicesToMinimal(gpa, &idx1, 20);
    defer gpa.free(m1);
    try expectHexEqual(gpa, m1, "000008000040000200001000008000040000200001");
    const back1 = try minimalToIndices(gpa, m1, 20);
    defer gpa.free(back1);
    try std.testing.expectEqualSlices(u32, &idx1, back1);

    const idx2 = [_]u32{ 2097151, 2097151, 2097151, 2097151, 2097151, 2097151, 2097151, 2097151 };
    const m2 = try indicesToMinimal(gpa, &idx2, 20);
    defer gpa.free(m2);
    try expectHexEqual(gpa, m2, "ffffffffffffffffffffffffffffffffffffffffff");

    const idx3 = [_]u32{ 131071, 128, 131071, 128, 131071, 128, 131071, 128 };
    const m3 = try indicesToMinimal(gpa, &idx3, 20);
    defer gpa.free(m3);
    try expectHexEqual(gpa, m3, "0ffff8002003fffe000800ffff8002003fffe00080");

    const idx4 = [_]u32{ 68, 41, 2097151, 1233, 665, 1023, 1, 1048575 };
    const m4 = try indicesToMinimal(gpa, &idx4, 20);
    defer gpa.free(m4);
    try expectHexEqual(gpa, m4, "000220000a7ffffe004d10014c800ffc00002fffff");
    const back4 = try minimalToIndices(gpa, m4, 20);
    defer gpa.free(back4);
    try std.testing.expectEqualSlices(u32, &idx4, back4);
}

test "blake2b personalization matches python hashlib oracle" {
    // python3: blake2b(digest_size=50, person=b'ZcashPoW'+200_le32+9_le32)(b'')
    //   = 42fadb73...40726
    const params = Params{ .n = 200, .k = 9 };
    var h = Blake2b400.init(.{ .context = params.personalization() });
    var d: [50]u8 = undefined;
    h.final(&d);
    const gpa = std.testing.allocator;
    try expectHexEqual(gpa, &d, "42fadb7376483e2167dbb245215129da15280a65062e68cf07cc9bc3f71905b8070472455b9fc809308919b7834c78b40726");
}

test "radix sort orders rows by prefix, stably" {
    const gpa = std.testing.allocator;
    const T = struct { data: [4]u8 };
    var rows = [_]T{
        .{ .data = .{ 2, 0, 9, 9 } },
        .{ .data = .{ 1, 5, 0, 0 } },
        .{ .data = .{ 2, 0, 1, 1 } },
        .{ .data = .{ 0, 9, 9, 9 } },
        .{ .data = .{ 1, 5, 7, 7 } },
    };
    try radixSortRows(gpa, T, &rows, 2);
    const want = [_][4]u8{
        .{ 0, 9, 9, 9 },
        .{ 1, 5, 0, 0 },
        .{ 1, 5, 7, 7 },
        .{ 2, 0, 9, 9 },
        .{ 2, 0, 1, 1 },
    };
    for (rows, 0..) |r, i| try std.testing.expectEqualSlices(u8, &want[i], &r.data);
}

test "probably-duplicate matches zcash vectors" {
    // From TEST(EquihashTests, IsProbablyDuplicate).
    try std.testing.expect(!isProbablyDuplicate(&[_]u8{ 0, 1, 2, 3 }));
    try std.testing.expect(!isProbablyDuplicate(&[_]u8{ 0, 1, 1, 3 }));
    try std.testing.expect(isProbablyDuplicate(&[_]u8{ 3, 1, 1, 3 }));
}

test "basic and optimized solvers agree (48,5)" {
    const gpa = std.testing.allocator;
    const params = TEST_SMALL;
    var input: [140]u8 = [_]u8{0} ** 140;
    @memcpy(input[0..16], "zig-diff-test!!!");
    var paired: u8 = 0;
    var opt_hits: u8 = 0;
    var t: u8 = 0;
    while (t < 20 and (paired < 2 or opt_hits < 2)) : (t += 1) {
        input[139] = t;
        var s1: std.ArrayList(u8) = .empty;
        defer s1.deinit(gpa);
        var s2: std.ArrayList(u8) = .empty;
        defer s2.deinit(gpa);
        const f1 = try solveBasic(gpa, params, &input, null, &s1);
        const f2 = try solve(gpa, params, &input, null, &s2);
        if (f2) opt_hits += 1;
        if (f1 and f2) {
            try std.testing.expect(try verify(gpa, params, &input, s1.items));
            try std.testing.expect(try verify(gpa, params, &input, s2.items));
            paired += 1;
        }
    }
    try std.testing.expect(paired == 2);
    try std.testing.expect(opt_hits >= 2);
}

test "C eq_gen_rows matches Zig byte-for-byte" {
    const gpa = std.testing.allocator;
    for ([_]Params{ TEST_SMALL, MAINNET }) |params| {
        const HLEN0 = params.hashLength();
        const IPHO = params.indicesPerHashOutput();
        const N8 = params.n / 8;
        const TW: usize = @max(HLEN0 + 1, 2 * params.collisionByteLength() + (@as(usize, 1) << @intCast(params.k - 1)));
        var input: [140]u8 = [_]u8{0} ** 140;
        @memcpy(input[0..16], "zig-c-abi-test!!");
        const geom = cGeom(params, HLEN0, 1, 0, 0, 1, 0);
        const state = HashState.init(params, &input);
        var tmp: [64]u8 = undefined;
        for ([_]u32{ 0, 1, 2, 17 }) |gg| {
            const rows = try gpa.alloc(u8, IPHO * TW);
            defer gpa.free(rows);
            @memset(rows, 0xAA); // poison: C must overwrite every byte
            const wrote = cgpu.eq_gen_rows(&input, &geom, gg * @as(u32, @intCast(IPHO)), @as(u32, @intCast(IPHO)), rows.ptr, TW);
            try std.testing.expectEqual(IPHO, wrote);
            generateHash(state, gg, tmp[0..params.hashOutput()]);
            for (0..IPHO) |t| {
                var want: [2064]u8 = [_]u8{0} ** 2064;
                expandArray(tmp[t * N8 ..][0..N8], want[0..HLEN0], params.collisionBitLength(), 0);
                const idx: u32 = gg * @as(u32, @intCast(IPHO)) + @as(u32, @intCast(t));
                want[HLEN0] = truncateIndex(idx, params.collisionBitLength() + 1);
                try std.testing.expectEqualSlices(u8, want[0..TW], rows[t * TW ..][0..TW]);
            }
        }
    }
}

test "C sort+permute matches Zig radix sort" {
    const gpa = std.testing.allocator;
    var rnd = std.Random.DefaultPrng.init(0xC0FFEE);
    const T = struct { data: [16]u8 };
    const n = 300;
    const flat = try gpa.alloc(u8, n * 16);
    defer gpa.free(flat);
    for (0..n) |i| {
        rnd.random().bytes(flat[i * 16 ..][0..16]);
    }
    // Zig reference.
    const ref = try gpa.alloc(T, n);
    defer gpa.free(ref);
    for (ref, 0..) |*r, i| @memcpy(&r.data, flat[i * 16 ..][0..16]);
    try radixSortRows(gpa, T, ref, 3);
    // C path.
    const order = try gpa.alloc(u32, n);
    defer gpa.free(order);
    const scratch = try gpa.alloc(u32, n);
    defer gpa.free(scratch);
    const visited = try gpa.alloc(u8, n);
    defer gpa.free(visited);
    const tmprow = try gpa.alloc(u8, 16);
    defer gpa.free(tmprow);
    for (order, 0..) |*o, i| o.* = @truncate(i);
    cgpu.eq_sort_order(flat.ptr, 16, order.ptr, scratch.ptr, n, 3);
    cgpu.eq_permute_rows(flat.ptr, 16, order.ptr, n, tmprow.ptr, visited.ptr);
    for (ref, 0..) |r, i| {
        try std.testing.expectEqualSlices(u8, &r.data, flat[i * 16 ..][0..16]);
    }
}

test "C buckets delimit first-byte runs" {
    const flat = [_]u8{ 7, 7, 7, 3, 3, 9 };
    var bounds: [7]usize = undefined;
    const nb = cgpu.eq_find_buckets(&flat, 1, 6, &bounds);
    try std.testing.expectEqual(@as(usize, 3), nb);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 3, 5, 6 }, bounds[0 .. nb + 1]);
}

/// Full Phase-A solve driven through the C kernel ABI, finished with the
/// Zig recreate phase. Proves the ABI sufficient for a verifying solution.
fn solveViaC(
    gpa: std.mem.Allocator,
    comptime P: Params,
    input: []const u8,
) !?[]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const CBL = comptime P.collisionByteLength();
    const HLEN0 = comptime P.hashLength();
    const INIT = comptime P.initSize();
    const TW: usize = comptime @max(HLEN0 + 1, 2 * CBL + (@as(usize, 1) << (P.k - 1)));
    const FTW: usize = comptime @max(HLEN0 + 1, 2 * CBL + (@as(usize, 1) << P.k));
    const state = HashState.init(P, input);
    std.debug.assert(input.len == 140);

    var cur = try a.alloc(u8, INIT * TW);
    var cur_n: usize = INIT;
    {
        const geom = cGeom(.{ .n = P.n, .k = P.k }, HLEN0, 1, 0, 0, 1, 0);
        const wrote = cgpu.eq_gen_rows(input.ptr, &geom, 0, INIT, cur.ptr, TW);
        if (wrote != INIT) return null;
    }
    const order = try a.alloc(u32, INIT);
    const scratch = try a.alloc(u32, INIT);
    const visited = try a.alloc(u8, INIT);
    const tmprow = try a.alloc(u8, TW);
    const bounds = try a.alloc(usize, INIT + 1);
    var part_list: std.ArrayList([]u8) = .empty;

    var hash_len: usize = HLEN0;
    var idx_len: usize = 1;
    var round: u32 = 1;
    while (round < P.k and cur_n > 0) : (round += 1) {
        for (order[0..cur_n], 0..) |*o, i| o.* = @truncate(i);
        cgpu.eq_sort_order(cur.ptr, TW, order.ptr, scratch.ptr, cur_n, CBL);
        cgpu.eq_permute_rows(cur.ptr, TW, order.ptr, cur_n, tmprow.ptr, visited.ptr);
        const nb = cgpu.eq_find_buckets(cur.ptr, TW, cur_n, bounds.ptr);
        const geom = cGeom(.{ .n = P.n, .k = P.k }, hash_len, idx_len, CBL, CBL, 1, 1);
        var total: usize = 0;
        var b: usize = 0;
        while (b < nb) : (b += 1) {
            total += cgpu.eq_count_pairs(cur.ptr, TW, &geom, bounds[b], bounds[b + 1]);
        }
        if (total == 0) return null;
        const nxt = try a.alloc(u8, total * TW);
        var off: usize = 0;
        b = 0;
        while (b < nb) : (b += 1) {
            const m = cgpu.eq_combine_bucket(cur.ptr, TW, &geom, bounds[b], bounds[b + 1], nxt[off * TW ..].ptr, TW, total - off);
            off += m;
        }
        std.debug.assert(off == total);
        cur = nxt;
        cur_n = total;
        hash_len -= CBL;
        idx_len *= 2;
    }
    // Final round through C.
    for (order[0..cur_n], 0..) |*o, i| o.* = @truncate(i);
    cgpu.eq_sort_order(cur.ptr, TW, order.ptr, scratch.ptr, cur_n, hash_len);
    cgpu.eq_permute_rows(cur.ptr, TW, order.ptr, cur_n, tmprow.ptr, visited.ptr);
    {
        const nb = cgpu.eq_find_buckets(cur.ptr, TW, cur_n, bounds.ptr);
        const geom = cGeom(.{ .n = P.n, .k = P.k }, hash_len, idx_len, hash_len, 0, 1, 2);
        var b: usize = 0;
        while (b < nb) : (b += 1) {
            const cnt = cgpu.eq_count_pairs(cur.ptr, TW, &geom, bounds[b], bounds[b + 1]);
            if (cnt == 0) continue;
            const out = try a.alloc(u8, cnt * FTW);
            const m = cgpu.eq_combine_bucket(cur.ptr, TW, &geom, bounds[b], bounds[b + 1], out.ptr, FTW, cnt);
            std.debug.assert(m == cnt);
            var t: usize = 0;
            while (t < m) : (t += 1) {
                try part_list.append(a, out[t * FTW + hash_len ..][0 .. 2 * idx_len]);
            }
        }
    }
    for (part_list.items) |p| {
        var sol: std.ArrayList(u8) = .empty;
        defer sol.deinit(gpa);
        if (try attemptPartial(gpa, P, input, state, p, null, &sol, null)) {
            return try gpa.dupe(u8, sol.items);
        }
    }
    return null;
}

test "C-ABI Phase-A solve verifies (48,5)" {
    const gpa = std.testing.allocator;
    var input: [140]u8 = [_]u8{0} ** 140;
    @memcpy(input[0..16], "zig-c-solve-test");
    const sol = try solveViaC(gpa, .{ .n = 48, .k = 5 }, &input);
    try std.testing.expect(sol != null);
    defer gpa.free(sol.?);
    try std.testing.expectEqual(@as(usize, 36), sol.?.len);
    try std.testing.expect(try verify(gpa, TEST_SMALL, &input, sol.?));
}

test "param sizes match consensus" {
    try std.testing.expectEqual(@as(usize, 1344), MAINNET.solutionSize());
    try std.testing.expectEqual(@as(usize, 36), TEST_SMALL.solutionSize());
    try std.testing.expectEqual(@as(usize, 50), MAINNET.hashOutput());
    try std.testing.expectEqual(@as(usize, 60), TEST_SMALL.hashOutput());
    try std.testing.expectEqual(@as(usize, 30), MAINNET.hashLength());
}

test "solver finds solution that verifier accepts (48,5)" {
    const gpa = std.testing.allocator;
    const params = TEST_SMALL;
    var input: [140]u8 = [_]u8{0} ** 140;
    @memcpy(input[0..16], "zig-miner-test!!");
    var found = false;
    var nonce_try: u8 = 0;
    while (nonce_try < 50 and !found) : (nonce_try += 1) {
        input[139] = nonce_try;
        var sol: std.ArrayList(u8) = .empty;
        defer sol.deinit(gpa);
        if (try solve(gpa, params, &input, null, &sol)) {
            try std.testing.expectEqual(params.solutionSize(), sol.items.len);
            try std.testing.expect(try verify(gpa, params, &input, sol.items));
            // Tampered solution must fail.
            sol.items[0] ^= 0x01;
            try std.testing.expect(!try verify(gpa, params, &input, sol.items));
            sol.items[0] ^= 0x01;
            // Wrong input must fail.
            input[0] ^= 0x01;
            try std.testing.expect(!try verify(gpa, params, &input, sol.items));
            input[0] ^= 0x01;
            // Truncated solution must fail.
            try std.testing.expect(!try verify(gpa, params, &input, sol.items[0 .. sol.items.len - 1]));
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "stream callback can stop early and fail without leaking" {
    const Consumer = struct {
        fail: bool,
        count: usize = 0,
        fn emit(ctx: *anyopaque, _: []const u8) !bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
            if (self.fail) return error.ConsumerFailed;
            return false;
        }
    };
    var input: [140]u8 = @splat(0);
    @memcpy(input[0..16], "zig-c-solve-test");
    var consumer = Consumer{ .fail = false };
    const count = try solveEach(std.testing.allocator, TEST_SMALL, &input, null, .{ .context = &consumer, .on_solution = Consumer.emit });
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 1), consumer.count);
    consumer.fail = true;
    try std.testing.expectError(error.ConsumerFailed, solveEach(std.testing.allocator, TEST_SMALL, &input, null, .{ .context = &consumer, .on_solution = Consumer.emit }));
}

test "stream allocation failure releases every solver and deduplication buffer" {
    const Scenario = struct {
        fn emit(_: *anyopaque, _: []const u8) !bool {
            return true;
        }
        fn run(gpa: std.mem.Allocator) !void {
            var input: [140]u8 = @splat(0);
            @memcpy(input[0..16], "zig-c-solve-test");
            var unused: u8 = 0;
            _ = try solveEach(gpa, TEST_SMALL, &input, null, .{ .context = &unused, .on_solution = emit });
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}
