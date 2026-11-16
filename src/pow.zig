// Zcash block proof-of-work helpers: SHA256d block hash, compact (nBits)
// target decoding, header serialization, coinbase merkle root.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Double-SHA256, the Zcash/Bitcoin block hash function.
pub fn sha256d(data: []const u8, out: *[32]u8) void {
    var h1: [32]u8 = undefined;
    var hasher = Sha256.init(.{});
    hasher.update(data);
    hasher.final(&h1);
    var hasher2 = Sha256.init(.{});
    hasher2.update(&h1);
    hasher2.final(out);
}

/// Decode Bitcoin-style compact target (nBits) into a 32-byte big-endian
/// target. Port of arith_uint256::SetCompact. `negative`/`overflow` mirror
/// the consensus validity conditions.
pub fn compactToTarget(bits: u32, target_be: *[32]u8, negative: *bool, overflow: *bool) void {
    @memset(target_be, 0);
    const size: u32 = bits >> 24;
    var word: u32 = bits & 0x007fffff;
    if (size <= 3) word >>= @intCast(8 * (3 - size));
    negative.* = word != 0 and (bits & 0x00800000) != 0;
    overflow.* = word != 0 and (size > 34 or (word > 0xff and size > 33) or (word > 0xffff and size > 32));
    if (overflow.* or word == 0) return;
    if (size <= 3) {
        std.mem.writeInt(u32, target_be[28..32], word, .big);
    } else {
        for (0..3) |i| {
            const dest = 32 - @as(i32, @intCast(size)) + @as(i32, @intCast(i));
            if (dest >= 0 and dest < 32) target_be[@intCast(dest)] = @truncate(word >> @intCast(16 - 8 * i));
        }
    }
}

/// True when le-interpreted `hash` <= be-interpreted `target_be`.
/// Mirrors UintToArith256(hash) <= bnTarget.
pub fn meetsTarget(hash_le: *const [32]u8, target_be: *const [32]u8) bool {
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const hb = hash_le[31 - i];
        const tb = target_be[i];
        if (hb < tb) return true;
        if (hb > tb) return false;
    }
    return true; // equal
}

/// True when le-interpreted a <= le-interpreted b.
pub fn leLessEqual(a: *const [32]u8, b: *const [32]u8) bool {
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        if (a[i] < b[i]) return true;
        if (a[i] > b[i]) return false;
    }
    return true;
}

/// Serialize the 140-byte Equihash input (block header minus solution):
/// version(4le) || prevHash(32) || merkleRoot(32) || reserved(32) ||
/// time(4le) || bits(4le) || nonce(32).
pub fn buildHeaderInput(
    out: *[140]u8,
    version: u32,
    prev_hash: *const [32]u8,
    merkle_root: *const [32]u8,
    reserved: *const [32]u8,
    time: u32,
    bits: u32,
    nonce: *const [32]u8,
) void {
    std.mem.writeInt(u32, out[0..4], version, .little);
    @memcpy(out[4..36], prev_hash);
    @memcpy(out[36..68], merkle_root);
    @memcpy(out[68..100], reserved);
    std.mem.writeInt(u32, out[100..104], time, .little);
    std.mem.writeInt(u32, out[104..108], bits, .little);
    @memcpy(out[108..140], nonce);
}

/// Compute the coinbase txid, then fold in the merkle branches.
pub fn merkleRoot(coinbase: []const u8, branches: []const [32]u8, out: *[32]u8) void {
    sha256d(coinbase, out);
    var buf: [64]u8 = undefined;
    for (branches) |br| {
        @memcpy(buf[0..32], out);
        @memcpy(buf[32..64], &br);
        sha256d(&buf, out);
    }
}

/// Full block hash: sha256d(header_input || compactSize(solution) || solution).
pub fn blockHash(header_input: *const [140]u8, solution: []const u8, out: *[32]u8) void {
    var h = Sha256.init(.{});
    h.update(header_input);
    if (solution.len < 253) {
        h.update(&[_]u8{@truncate(solution.len)});
    } else {
        var pre: [3]u8 = undefined;
        pre[0] = 0xFD;
        std.mem.writeInt(u16, pre[1..3], @truncate(solution.len), .little);
        h.update(&pre);
    }
    h.update(solution);
    var h1: [32]u8 = undefined;
    h.final(&h1);
    var h2 = Sha256.init(.{});
    h2.update(&h1);
    h2.final(out);
}

// ---- tests ----

test "sha256d matches known vector" {
    // sha256d("") = 5df6e0e2761359d30a8275058e299fcc0381534545f55cf43e41983f5d4c9456
    const util = @import("util.zig");
    const gpa = std.testing.allocator;
    var out: [32]u8 = undefined;
    sha256d("", &out);
    const want = try util.hexDecode(gpa, "5df6e0e2761359d30a8275058e299fcc0381534545f55cf43e41983f5d4c9456");
    defer gpa.free(want);
    try std.testing.expectEqualSlices(u8, want, &out);
}

test "compact target decodes like Bitcoin" {
    const util = @import("util.zig");
    const gpa = std.testing.allocator;
    // Genesis nBits 0x1d00ffff.
    var t: [32]u8 = undefined;
    var neg: bool = undefined;
    var ovf: bool = undefined;
    compactToTarget(0x1d00ffff, &t, &neg, &ovf);
    try std.testing.expect(!neg and !ovf);
    const want = try util.hexDecode(gpa, "00000000ffff0000000000000000000000000000000000000000000000000000");
    defer gpa.free(want);
    try std.testing.expectEqualSlices(u8, want, &t);
    // Negative and overflow flags.
    compactToTarget(0x1d80ffff, &t, &neg, &ovf);
    try std.testing.expect(neg);
    compactToTarget(0x2200ffff, &t, &neg, &ovf);
    try std.testing.expect(ovf);
}

test "genesis-style hash meets its target" {
    // Genuine Bitcoin genesis block hash is below its target; here we check
    // the comparison direction with synthetic values instead.
    var lo: [32]u8 = [_]u8{0} ** 32;
    lo[0] = 1;
    var hi: [32]u8 = [_]u8{0} ** 32;
    hi[31] = 1;
    var target_be: [32]u8 = [_]u8{0} ** 32;
    target_be[31] = 0x10; // small target: 0x...10
    // lo as LE = 1 <= 0x10...00? target BE 0x00..10 => LE value huge; lo=1 meets.
    try std.testing.expect(meetsTarget(&lo, &target_be));
    // hi as LE = 1<<248 > target => fails.
    try std.testing.expect(!meetsTarget(&hi, &target_be));
}

test "header input layout is 140 bytes" {
    var out: [140]u8 = undefined;
    const z32: [32]u8 = [_]u8{0} ** 32;
    buildHeaderInput(&out, 4, &z32, &z32, &z32, 1234567890, 0x1d00ffff, &z32);
    try std.testing.expectEqual(@as(u8, 4), out[0]);
    try std.testing.expectEqual(@as(u32, 1234567890), std.mem.readInt(u32, out[100..104], .little));
    try std.testing.expectEqual(@as(u32, 0x1d00ffff), std.mem.readInt(u32, out[104..108], .little));
}

test "compact target boundary mantissas match 256-bit consensus overflow" {
    var target: [32]u8 = undefined;
    var negative: bool = undefined;
    var overflow: bool = undefined;
    compactToTarget(0x2100ffff, &target, &negative, &overflow);
    try std.testing.expect(!negative and !overflow);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff }, target[0..2]);
    compactToTarget(0x220000ff, &target, &negative, &overflow);
    try std.testing.expect(!overflow);
    try std.testing.expectEqual(@as(u8, 0xff), target[0]);
    compactToTarget(0x22000100, &target, &negative, &overflow);
    try std.testing.expect(overflow);
    compactToTarget(0x01800001, &target, &negative, &overflow);
    try std.testing.expect(!negative and !overflow);
    try std.testing.expect(std.mem.allEqual(u8, &target, 0));
}
