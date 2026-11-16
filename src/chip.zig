// SPDX-License-Identifier: Apache-2.0
// Bounded ZEQ UART framing, shared by the RTL and physical serial transports.
const std = @import("std");

pub const max_payload = 2052;
pub const max_frame = max_payload + 6;
pub const Command = enum(u8) { job = 1, stop = 2, over_temperature = 3, ping = 4, target = 5, bist = 6 };
pub const Reply = enum(u8) { solution = 0x81, pong = 0x84, done = 0x85 };

pub fn crc8(bytes: []const u8) u8 {
    var crc: u8 = 0;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| crc = (crc << 1) ^ (if (crc & 0x80 != 0) @as(u8, 7) else 0);
    }
    return crc;
}

pub fn encode(output: []u8, kind: Command, address: u8, payload: []const u8) ![]const u8 {
    if (payload.len > max_payload or output.len < payload.len + 6) return error.FrameTooLarge;
    output[0] = 0xa5;
    output[1] = @intFromEnum(kind);
    output[2] = address;
    std.mem.writeInt(u16, output[3..5], @intCast(payload.len), .little);
    @memcpy(output[5..][0..payload.len], payload);
    output[5 + payload.len] = crc8(output[1 .. 5 + payload.len]);
    return output[0 .. payload.len + 6];
}

pub const Frame = struct {
    kind: u8,
    address: u8,
    len: usize,
    bytes: [max_payload]u8 = undefined,

    pub fn payload(f: *const Frame) []const u8 {
        return f.bytes[0..f.len];
    }
};

pub const Decoder = struct {
    bytes: [max_frame * 2]u8 = undefined,
    len: usize = 0,
    errors: u64 = 0,

    pub fn feed(d: *Decoder, bytes: []const u8) !void {
        if (bytes.len > d.bytes.len - d.len) return error.DeviceBufferFull;
        @memcpy(d.bytes[d.len..][0..bytes.len], bytes);
        d.len += bytes.len;
    }
    fn drop(d: *Decoder, n: usize) void {
        std.mem.copyForwards(u8, &d.bytes, d.bytes[n..d.len]);
        d.len -= n;
    }
    pub fn next(d: *Decoder) ?Frame {
        while (d.len != 0) {
            if (d.bytes[0] != 0x5a) {
                d.errors += 1;
                d.drop(1);
                continue;
            }
            if (d.len < 5) return null;
            const len = std.mem.readInt(u16, d.bytes[3..5], .little);
            if (len > max_payload) {
                d.errors += 1;
                d.drop(1);
                continue;
            }
            const size = @as(usize, len) + 6;
            if (d.len < size) return null;
            if (crc8(d.bytes[1 .. size - 1]) != d.bytes[size - 1]) {
                d.errors += 1;
                d.drop(1);
                continue;
            }
            var frame = Frame{ .kind = d.bytes[1], .address = d.bytes[2], .len = len };
            @memcpy(frame.bytes[0..len], d.bytes[5..][0..len]);
            d.drop(size);
            return frame;
        }
        return null;
    }
};

test "CRC and command match independent Python wire vectors" {
    try std.testing.expectEqual(@as(u8, 0xf4), crc8("123456789"));
    var bytes: [16]u8 = undefined;
    const command = try encode(&bytes, .ping, 0xff, &.{});
    // CRC independently computed by the Python hardware reference.
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 4, 0xff, 0, 0, 0x73 }, command);
}

test "bounded framing survives fragmentation, corruption and oversized lengths" {
    const good = [_]u8{ 0x5a, 0x84, 0, 4, 0, 2, 0, 60, 1, 0x79 };
    var d = Decoder{};
    var corrupt = good;
    corrupt[9] ^= 1;
    try d.feed(&.{ 0x12, 0x5a, 0x81, 0, 0xff, 0xff });
    try d.feed(&corrupt);
    try d.feed(good[0..3]);
    try std.testing.expect(d.next() == null);
    try d.feed(good[3..]);
    const frame = d.next() orelse return error.MissingFrame;
    try std.testing.expectEqual(@as(u8, 0x84), frame.kind);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 60, 1 }, frame.payload());
    try std.testing.expect(d.errors > 0);
    try std.testing.expect(d.next() == null);
    try std.testing.expectError(error.DeviceBufferFull, d.feed(&([_]u8{0} ** (max_frame * 2 + 1))));
}
