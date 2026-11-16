// Small shared helpers: hex encode/decode, byte reversal.
const std = @import("std");

pub fn hexDecode(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len % 2 != 0) return error.InvalidHexLength;
    const out = try gpa.alloc(u8, s.len / 2);
    errdefer gpa.free(out);
    _ = try std.fmt.hexToBytes(out, s);
    return out;
}

pub fn hexEncode(gpa: std.mem.Allocator, b: []const u8) ![]u8 {
    const hex = "0123456789abcdef";
    const out = try gpa.alloc(u8, b.len * 2);
    for (b, 0..) |byte, i| {
        out[2 * i] = hex[byte >> 4];
        out[2 * i + 1] = hex[byte & 0xF];
    }
    return out;
}

pub fn reverseBytes(s: []u8) void {
    std.mem.reverse(u8, s);
}
