// SPDX-License-Identifier: Apache-2.0
// CPU, actual RTL UART bridge, and physical serial device implementations.
const std = @import("std");
const equihash = @import("equihash.zig");
const chip = @import("chip.zig");
const c = @cImport(@cInclude("termios.h"));

pub const Kind = enum { cpu, rtl, serial };
pub const Options = struct {
    kind: Kind = .cpu,
    endpoint: []const u8 = "",
    chips: u8 = 1,
    baud: u32 = 2_500_000,
    timeout_ms: u32 = 120_000,
};

pub const Status = struct {
    chips: u8 = 0,
    version: [4]u16 = @splat(0),
    flags: [4]u16 = @splat(0),
    sensor_code: [4]u16 = @splat(0),
    lanes: [4]u16 = @splat(0),
};

/// Both input and solution are borrowed for the duration of the callback.
/// The host performs the same final Equihash and target gate for every backend.
pub const Handler = struct {
    context: *anyopaque,
    candidate: *const fn (*anyopaque, *const [140]u8, []const u8) anyerror!bool,
    status: *const fn (*anyopaque, Status) void,
};

const CpuEmission = struct {
    input: *const [140]u8,
    handler: Handler,
    fn emit(ctx: *anyopaque, solution: []const u8) !bool {
        const e: *CpuEmission = @ptrCast(@alignCast(ctx));
        return e.handler.candidate(e.handler.context, e.input, solution);
    }
};

/// One owner per physical chain. Device instances retain the transport across
/// jobs; cancellation sends STOP, and every new job uses a fresh host nonce.
pub const Engine = struct {
    options: Options,
    fd: ?std.posix.fd_t = null,
    decoder: chip.Decoder = .{},
    next_job: u8 = 0,

    pub fn deinit(e: *Engine) void {
        if (e.fd) |fd| std.posix.close(fd);
        e.fd = null;
    }

    pub fn solve(e: *Engine, gpa: std.mem.Allocator, params: equihash.Params, input: *const [140]u8, cancel: *const std.atomic.Value(bool), handler: Handler) !void {
        if (e.options.kind == .cpu) {
            var emission = CpuEmission{ .input = input, .handler = handler };
            _ = try equihash.solveEach(gpa, params, input, cancel, .{ .context = &emission, .on_solution = CpuEmission.emit });
            return;
        }
        if (cancel.load(.seq_cst)) return error.Cancelled;
        if (e.fd == null) e.fd = try e.open(gpa, cancel);
        // STOP is attempted even on cancellation or a malformed device reply.
        defer e.send(.stop, &.{}, null, 100) catch {};
        try e.send(.stop, &.{}, cancel, e.options.timeout_ms);
        try e.send(.ping, &.{}, cancel, e.options.timeout_ms);
        var timer = try std.time.Timer.start();
        var status = Status{};
        var pong_seen: [4]bool = @splat(false);
        while (status.chips < e.options.chips) {
            const frame = try e.read(cancel, &timer);
            if (frame.kind != @intFromEnum(chip.Reply.pong)) continue; // drain previous job
            const address = frame.address;
            if (address >= e.options.chips or frame.len != 4) return error.BadDeviceDiscovery;
            const payload = frame.payload();
            if (payload[0] != 2 or payload[3] == 0) return error.UnsupportedDeviceVersion;
            if (payload[1] & 1 != 0) return error.DeviceOverTemperature;
            if (payload[1] & 8 != 0) return error.DeviceMemoryFault;
            if (!pong_seen[address]) status.chips += 1;
            pong_seen[address] = true;
            status.version[address] = payload[0];
            status.flags[address] = payload[1];
            status.sensor_code[address] = payload[2];
            status.lanes[address] = payload[3];
        }
        handler.status(handler.context, status);
        // Protocol v2 DONE counts pre-filter solutions. Request all of them so
        // the count is usable; the common host verifier applies the pool target.
        try e.send(.target, &([_]u8{0xff} ** 32), cancel, e.options.timeout_ms);
        const job = e.next_job;
        e.next_job +%= 1;
        var payload: [141]u8 = undefined;
        payload[0] = job;
        @memcpy(payload[1..], input);
        try e.send(.job, &payload, cancel, e.options.timeout_ms);
        timer.reset();
        var done: [4]?u8 = @splat(null);
        var received: [4]u16 = @splat(0);
        var seen: std.AutoHashMapUnmanaged([32]u8, void) = .empty;
        defer seen.deinit(gpa);
        while (true) {
            const frame = try e.read(cancel, &timer);
            if (frame.address >= e.options.chips) return error.UnexpectedDeviceAddress;
            // PING has no request identifier. A cancelled discovery can leave
            // replies queued behind an in-flight UART frame. Treat valid late
            // status idempotently, without extending the operation deadline.
            if (frame.kind == @intFromEnum(chip.Reply.pong)) {
                if (frame.len != 4 or frame.bytes[0] != 2 or frame.bytes[3] == 0) return error.BadDeviceDiscovery;
                if (frame.bytes[1] & 1 != 0) return error.DeviceOverTemperature;
                if (frame.bytes[1] & 8 != 0) return error.DeviceMemoryFault;
                status.flags[frame.address] = frame.bytes[1];
                status.sensor_code[frame.address] = frame.bytes[2];
                status.lanes[frame.address] = frame.bytes[3];
                handler.status(handler.context, status);
                continue;
            }
            if (frame.kind != @intFromEnum(chip.Reply.solution) and frame.kind != @intFromEnum(chip.Reply.done)) return error.UnexpectedDeviceReply;
            if (frame.len < 4) return error.BadDeviceReply;
            const bytes = frame.payload();
            if (bytes[0] != job) continue;
            const attempt = std.mem.readInt(u24, bytes[1..4], .little);
            // This driver reserves a whole chip/attempt suffix but accepts one
            // attempt per chip. Extra automatic attempts cannot overlap the
            // next host allocation. A larger batch can be added independently.
            if (attempt != 0) continue;
            const address = frame.address;
            if (frame.kind == @intFromEnum(chip.Reply.done)) {
                if (frame.len != 5 or done[address] != null) return error.BadDeviceDone;
                done[address] = bytes[4];
            } else {
                const count = @as(usize, 1) << @intCast(params.k);
                if (frame.len != 4 + 4 * count) return error.DeviceParameterMismatch;
                var indices: [512]u32 = undefined;
                for (indices[0..count], 0..) |*index, i| {
                    index.* = std.mem.readInt(u32, bytes[4 + i * 4 ..][0..4], .big);
                    if (index.* >= params.initSize()) return error.InvalidDeviceIndex;
                }
                const minimal = try equihash.indicesToMinimal(gpa, indices[0..count], params.collisionBitLength());
                defer gpa.free(minimal);
                var effective = input.*;
                effective[136] = address;
                @memset(effective[137..140], 0);
                var hasher = std.crypto.hash.sha2.Sha256.init(.{});
                hasher.update(&effective);
                hasher.update(minimal);
                const entry = try seen.getOrPut(gpa, hasher.finalResult());
                if (entry.found_existing) return error.DuplicateDeviceSolution;
                received[address] += 1;
                if (received[address] > 255) return error.DeviceSolutionOverflow;
                if (!try handler.candidate(handler.context, &effective, minimal)) return;
            }
            var complete = true;
            for (0..e.options.chips) |address_index| {
                if (done[address_index]) |expected| {
                    if (received[address_index] > expected) return error.BadDeviceDone;
                    if (received[address_index] != expected) complete = false;
                } else complete = false;
            }
            if (complete) return;
        }
    }

    fn open(e: *Engine, gpa: std.mem.Allocator, cancel: *const std.atomic.Value(bool)) !std.posix.fd_t {
        if (e.options.kind == .serial) {
            const fd = try std.posix.open(e.options.endpoint, .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true, .CLOEXEC = true }, 0);
            errdefer std.posix.close(fd);
            var settings: c.termios = undefined;
            if (c.tcgetattr(fd, &settings) != 0) return error.SerialSettings;
            c.cfmakeraw(&settings);
            settings.c_cflag |= c.CLOCAL | c.CREAD;
            settings.c_cflag &= ~@as(c.tcflag_t, c.CRTSCTS | c.CSTOPB);
            const speed: c.speed_t = switch (e.options.baud) {
                115200 => c.B115200,
                460800 => c.B460800,
                921600 => c.B921600,
                1000000 => c.B1000000,
                2500000 => c.B2500000,
                else => return error.UnsupportedBaudRate,
            };
            if (c.cfsetispeed(&settings, speed) != 0 or c.cfsetospeed(&settings, speed) != 0 or c.tcsetattr(fd, c.TCSAFLUSH, &settings) != 0) return error.SerialSettings;
            return fd;
        }
        const colon = std.mem.lastIndexOfScalar(u8, e.options.endpoint, ':') orelse return error.BadDeviceEndpoint;
        const port = try std.fmt.parseInt(u16, e.options.endpoint[colon + 1 ..], 10);
        const list = try std.net.getAddressList(gpa, e.options.endpoint[0..colon], port);
        defer list.deinit();
        for (list.addrs) |address| {
            const fd = try std.posix.socket(address.any.family, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.TCP);
            var connected = false;
            defer if (!connected) std.posix.close(fd);
            try std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
            std.posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
                error.WouldBlock => {
                    var timer = try std.time.Timer.start();
                    while (try wait(fd, std.posix.POLL.OUT, cancel, &timer, e.options.timeout_ms) == false) {}
                    std.posix.getsockoptError(fd) catch continue;
                },
                else => continue,
            };
            connected = true;
            return fd;
        }
        return error.DeviceConnectionFailed;
    }

    fn wait(fd: std.posix.fd_t, event: i16, cancel: ?*const std.atomic.Value(bool), timer: *std.time.Timer, timeout_ms: u32) !bool {
        if (cancel) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        if (timer.read() / std.time.ns_per_ms >= timeout_ms) return error.DeviceTimeout;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = event, .revents = 0 }};
        _ = try std.posix.poll(&fds, 20);
        if (fds[0].revents & event != 0) return true;
        if (fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) return error.DeviceDisconnected;
        return false;
    }

    fn send(e: *Engine, kind: chip.Command, payload: []const u8, cancel: ?*const std.atomic.Value(bool), timeout_ms: u32) !void {
        var buffer: [chip.max_frame]u8 = undefined;
        var bytes = try chip.encode(&buffer, kind, 0xff, payload);
        var timer = try std.time.Timer.start();
        while (bytes.len != 0) {
            if (!try wait(e.fd.?, std.posix.POLL.OUT, cancel, &timer, timeout_ms)) continue;
            const count = std.posix.write(e.fd.?, bytes) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (count == 0) return error.DeviceDisconnected;
            bytes = bytes[count..];
        }
    }

    fn read(e: *Engine, cancel: *const std.atomic.Value(bool), timer: *std.time.Timer) !chip.Frame {
        while (true) {
            if (cancel.load(.seq_cst)) return error.Cancelled;
            if (timer.read() / std.time.ns_per_ms >= e.options.timeout_ms) return error.DeviceTimeout;
            if (e.decoder.next()) |frame| return frame;
            if (!try wait(e.fd.?, std.posix.POLL.IN, cancel, timer, e.options.timeout_ms)) continue;
            var bytes: [chip.max_frame]u8 = undefined;
            const len = std.posix.read(e.fd.?, &bytes) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (len == 0) return error.DeviceDisconnected;
            try e.decoder.feed(bytes[0..len]);
        }
    }
};

test {
    std.testing.refAllDecls(chip);
}
