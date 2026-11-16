// SPDX-License-Identifier: Apache-2.0
// Zcash Stratum (ZIP 301), https://zips.z.cash/zip-0301.
// Header hex is already in wire order. Never reverse hashes or reconstruct
// a Bitcoin coinbase. The pool owns every header byte except NONCE_2.
const std = @import("std");
const util = @import("util.zig");
const pow = @import("pow.zig");

pub const max_line_bytes = 64 * 1024;
pub const max_job_id_bytes = 256;

pub const Job = struct {
    gpa: std.mem.Allocator,
    id: []u8,
    header: [108]u8,
    clean: bool,

    pub fn deinit(j: *Job) void {
        j.gpa.free(j.id);
    }

    pub fn input(j: *const Job, nonce: *const [32]u8) [140]u8 {
        var out: [140]u8 = undefined;
        @memcpy(out[0..108], &j.header);
        @memcpy(out[108..140], nonce);
        return out;
    }

    pub fn networkTarget(j: *const Job) ![32]u8 {
        var target: [32]u8 = undefined;
        var negative: bool = undefined;
        var overflow: bool = undefined;
        pow.compactToTarget(std.mem.readInt(u32, j.header[104..108], .little), &target, &negative, &overflow);
        if (negative or overflow or std.mem.allEqual(u8, &target, 0)) return error.InvalidTarget;
        return target;
    }
};

pub fn array(value: std.json.Value) ![]const std.json.Value {
    return switch (value) {
        .array => |a| a.items,
        else => error.BadMessage,
    };
}

pub fn string(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.BadMessage,
    };
}

fn decodeExact(out: []u8, value: std.json.Value) !void {
    const s = try string(value);
    if (s.len != out.len * 2) return error.BadMessage;
    _ = try std.fmt.hexToBytes(out, s);
}

pub fn parseNotify(gpa: std.mem.Allocator, params: std.json.Value) !Job {
    const items = try array(params);
    if (items.len != 8) return error.BadMessage;
    const id = try string(items[0]);
    if (id.len == 0 or id.len > max_job_id_bytes) return error.BadMessage;
    var header: [108]u8 = undefined;
    try decodeExact(header[0..4], items[1]);
    if (std.mem.readInt(u32, header[0..4], .little) != 4) return error.UnsupportedVersion;
    try decodeExact(header[4..36], items[2]);
    try decodeExact(header[36..68], items[3]);
    try decodeExact(header[68..100], items[4]);
    try decodeExact(header[100..104], items[5]);
    try decodeExact(header[104..108], items[6]);
    const clean = switch (items[7]) {
        .bool => |b| b,
        else => return error.BadMessage,
    };
    var job = Job{ .gpa = gpa, .id = try gpa.dupe(u8, id), .header = header, .clean = clean };
    errdefer job.deinit();
    _ = try job.networkTarget();
    return job;
}

pub const Subscription = struct {
    nonce1: [32]u8 = [_]u8{0} ** 32,
    nonce1_len: usize,
    // Session resumption is deliberately not requested: every reconnect starts
    // a fresh session and invalidates all old jobs, requests and nonce ranges.
};

pub fn parseSubscribe(result: std.json.Value) !Subscription {
    const items = try array(result);
    if (items.len != 2) return error.BadMessage;
    switch (items[0]) {
        .null => {},
        .string => |s| if (s.len > 1024) return error.BadMessage,
        else => return error.BadMessage,
    }
    const prefix = try string(items[1]);
    if (prefix.len >= 64 or prefix.len % 2 != 0) return error.BadNonce;
    var sub = Subscription{ .nonce1_len = prefix.len / 2 };
    _ = try std.fmt.hexToBytes(sub.nonce1[0..sub.nonce1_len], prefix);
    return sub;
}

/// Applies to the next notify and subsequent jobs, NOT retroactively to jobs.
pub fn parseSetTarget(params: std.json.Value) ![32]u8 {
    const items = try array(params);
    if (items.len != 1) return error.BadMessage;
    var target: [32]u8 = undefined;
    try decodeExact(&target, items[0]);
    if (std.mem.allEqual(u8, &target, 0)) return error.InvalidTarget;
    return target;
}

/// Serialize typed parameters so usernames and server job IDs cannot inject JSON.
pub fn formatRequest(gpa: std.mem.Allocator, id: u64, method: []const u8, params: anytype) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(gpa, .{ .id = id, .method = method, .params = params }, .{});
    defer gpa.free(json);
    return std.mem.concat(gpa, u8, &.{ json, "\n" });
}

pub fn formatSubmit(gpa: std.mem.Allocator, id: u64, user: []const u8, job_id: []const u8, time: *const [4]u8, nonce2: []const u8, solution: []const u8) ![]u8 {
    if (nonce2.len == 0 or nonce2.len > 32 or solution.len > 65535) return error.BadMessage;
    const time_hex = try util.hexEncode(gpa, time);
    defer gpa.free(time_hex);
    const nonce_hex = try util.hexEncode(gpa, nonce2);
    defer gpa.free(nonce_hex);
    var prefix: [3]u8 = undefined;
    const prefix_len: usize = if (solution.len < 253) blk: {
        prefix[0] = @intCast(solution.len);
        break :blk 1;
    } else blk: {
        prefix[0] = 0xfd;
        std.mem.writeInt(u16, prefix[1..3], @intCast(solution.len), .little);
        break :blk 3;
    };
    const encoded = try std.mem.concat(gpa, u8, &.{ prefix[0..prefix_len], solution });
    defer gpa.free(encoded);
    const solution_hex = try util.hexEncode(gpa, encoded);
    defer gpa.free(solution_hex);
    return formatRequest(gpa, id, "mining.submit", .{ user, job_id, time_hex, nonce_hex, solution_hex });
}

/// Bounded framing independent of sockets; parsed messages own their strings.
/// This ownership is essential when several messages arrive in one read.
pub const Decoder = struct {
    gpa: std.mem.Allocator,
    pending: std.ArrayList(u8) = .empty,

    pub fn deinit(d: *Decoder) void {
        d.pending.deinit(d.gpa);
    }

    pub fn feed(d: *Decoder, bytes: []const u8) !void {
        if (d.pending.items.len + bytes.len > max_line_bytes) return error.MessageTooLarge;
        try d.pending.appendSlice(d.gpa, bytes);
    }

    pub fn next(d: *Decoder) !?std.json.Parsed(std.json.Value) {
        const pos = std.mem.indexOfScalar(u8, d.pending.items, '\n') orelse return null;
        const line = std.mem.trimEnd(u8, d.pending.items[0..pos], "\r");
        // Consume even malformed complete lines, allowing a caller to count
        // and reject them rather than spinning on the same invalid frame.
        defer {
            const remaining = d.pending.items.len - pos - 1;
            std.mem.copyForwards(u8, d.pending.items[0..remaining], d.pending.items[pos + 1 ..]);
            d.pending.items.len = remaining;
        }
        return try std.json.parseFromSlice(std.json.Value, d.gpa, line, .{ .allocate = .alloc_always, .max_value_len = max_line_bytes });
    }
};

pub const Conn = struct {
    stream: std.net.Stream,
    decoder: Decoder,

    pub fn init(gpa: std.mem.Allocator, stream: std.net.Stream) Conn {
        return .{ .stream = stream, .decoder = .{ .gpa = gpa } };
    }

    pub fn deinit(c: *Conn) void {
        c.decoder.deinit();
        c.stream.close();
    }

    pub fn sendAll(c: *Conn, bytes: []const u8) !void {
        var timer = try std.time.Timer.start();
        var sent: usize = 0;
        while (sent < bytes.len) {
            if (timer.read() > 5 * std.time.ns_per_s) return error.WriteTimeout;
            if (!try c.ready(std.posix.POLL.OUT, 100)) continue;
            const n = c.stream.write(bytes[sent..]) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (n == 0) return error.Eof;
            sent += n;
        }
    }

    fn ready(c: *Conn, event: i16, timeout_ms: i32) !bool {
        var fds = [_]std.posix.pollfd{.{ .fd = c.stream.handle, .events = event, .revents = 0 }};
        return (try std.posix.poll(&fds, timeout_ms)) != 0;
    }

    /// Timeout bounds the call even when a peer trickles a partial line.
    pub fn readJson(c: *Conn, timeout_ms: u32) !?std.json.Parsed(std.json.Value) {
        var timer = try std.time.Timer.start();
        while (true) {
            if (try c.decoder.next()) |parsed| return parsed;
            const elapsed = timer.read() / std.time.ns_per_ms;
            if (elapsed >= timeout_ms) return error.ReadTimeout;
            if (!try c.ready(std.posix.POLL.IN, @intCast(timeout_ms - elapsed))) return error.ReadTimeout;
            var tmp: [4096]u8 = undefined;
            const room = max_line_bytes - c.decoder.pending.items.len;
            if (room == 0) return error.MessageTooLarge;
            const n = c.stream.read(tmp[0..@min(room, tmp.len)]) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (n == 0) {
                if (c.decoder.pending.items.len == 0) return null;
                return error.TruncatedMessage;
            }
            try c.decoder.feed(tmp[0..n]);
        }
    }
};

const fixture =
    \\["job42","04000000","000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f","202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f","404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f","78563412","ffff071f",true]
;

test "ZIP 301 header preserves pool wire bytes including commitments" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixture, .{});
    defer parsed.deinit();
    var job = try parseNotify(gpa, parsed.value);
    defer job.deinit();
    try std.testing.expectEqualStrings("job42", job.id);
    const input = job.input(&([_]u8{0xab} ** 32));
    try std.testing.expectEqualSlices(u8, &.{ 4, 0, 0, 0 }, input[0..4]);
    for (0..96) |i| try std.testing.expectEqual(@as(u8, @intCast(i)), input[4 + i]);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, input[100..104]);
    try std.testing.expectEqual(@as(u8, 0xab), input[139]);
    _ = try job.networkTarget();
}

test "ZIP 301 subscription derives nonce2 length and rejects Bitcoin tuple" {
    const gpa = std.testing.allocator;
    var p = try std.json.parseFromSlice(std.json.Value, gpa, "[null,\"aabb\"]", .{});
    defer p.deinit();
    const sub = try parseSubscribe(p.value);
    try std.testing.expectEqual(@as(usize, 30), 32 - sub.nonce1_len);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, sub.nonce1[0..2]);
    for ([_][]const u8{ "[[],\"aabb\",4]", "[null,\"a\"]", "[null,\"zz\"]", "[5,\"\"]", "[null,\"" ++ "00" ** 32 ++ "\"]" }) |bad| {
        var v = try std.json.parseFromSlice(std.json.Value, gpa, bad, .{});
        defer v.deinit();
        if (parseSubscribe(v.value)) |_| return error.AcceptedBadSubscription else |_| {}
    }
}

test "submit escapes strings and includes nonce2, LE time and canonical mainnet size" {
    const gpa = std.testing.allocator;
    const solution = [_]u8{0xab} ** 1344;
    const line = try formatSubmit(gpa, 7, "worker\"\n", "job\\id", &.{ 0x78, 0x56, 0x34, 0x12 }, &.{ 1, 2 }, &solution);
    defer gpa.free(line);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
    defer parsed.deinit();
    const params = try array(parsed.value.object.get("params").?);
    try std.testing.expectEqualStrings("worker\"\n", try string(params[0]));
    try std.testing.expectEqualStrings("job\\id", try string(params[1]));
    try std.testing.expectEqualStrings("78563412", try string(params[2]));
    try std.testing.expectEqualStrings("0102", try string(params[3]));
    try std.testing.expectEqualStrings("fd4005", (try string(params[4]))[0..6]);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
}

test "batched JSON messages retain owned strings after buffer reuse" {
    var decoder = Decoder{ .gpa = std.testing.allocator };
    defer decoder.deinit();
    try decoder.feed("{\"method\":\"first\",\"params\":[\"original\"]}\n{\"method\":\"second\"}\n");
    var first = (try decoder.next()).?;
    defer first.deinit();
    var second = (try decoder.next()).?;
    defer second.deinit();
    try decoder.feed("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx");
    try std.testing.expectEqualStrings("first", try string(first.value.object.get("method").?));
    try std.testing.expectEqualStrings("original", (try array(first.value.object.get("params").?))[0].string);
    try std.testing.expectEqualStrings("second", try string(second.value.object.get("method").?));
}

test "framing handles fragmentation, malformed lines and limits" {
    var decoder = Decoder{ .gpa = std.testing.allocator };
    defer decoder.deinit();
    try decoder.feed("{\"result\":");
    try std.testing.expect((try decoder.next()) == null);
    try decoder.feed("true}\r\ninvalid\n{\"id\":1}\n");
    var first = (try decoder.next()).?;
    defer first.deinit();
    try std.testing.expect(first.value.object.get("result").?.bool);
    if (decoder.next()) |_| return error.AcceptedInvalidJson else |_| {}
    var last = (try decoder.next()).?;
    defer last.deinit();
    try std.testing.expectEqual(@as(i64, 1), last.value.object.get("id").?.integer);
    const too_large = try std.testing.allocator.alloc(u8, max_line_bytes + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, 'x');
    try std.testing.expectError(error.MessageTooLarge, decoder.feed(too_large));
}
