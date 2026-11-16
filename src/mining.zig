// SPDX-License-Identifier: Apache-2.0
// One network owner, bounded worker results, immutable per-job targets.
const std = @import("std");
const stratum = @import("stratum.zig");
const equihash = @import("equihash.zig");
const pow = @import("pow.zig");
const Budget = @import("budget.zig").Budget;
const backend = @import("backend.zig");

pub const Options = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    pass: []const u8 = "x",
    agent: []const u8,
    params: equihash.Params = equihash.MAINNET,
    threads: usize = 1,
    memory_mb: usize = 3072,
    timeout_ms: u32 = 120_000,
    stats_ms: u32 = 5_000,
    run_seconds: u32 = 0,
    reconnect_ms: u32 = 1_000,
    probe: bool = false,
    backend: backend.Options = .{},
};

pub var interrupted = std.atomic.Value(bool).init(false);
fn signalHandler(_: i32) callconv(.c) void {
    interrupted.store(true, .seq_cst);
}
pub fn installSignals() void {
    const action = std.posix.Sigaction{ .handler = .{ .handler = signalHandler }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

pub const Stats = struct {
    connections: u64 = 0,
    reconnects: u64 = 0,
    jobs: u64 = 0,
    attempts: u64 = 0,
    solutions: u64 = 0,
    submitted: u64 = 0,
    accepted: u64 = 0,
    rejected: u64 = 0,
    stale: u64 = 0,
    discarded: u64 = 0,
    unknown: u64 = 0,
    unexpected_replies: u64 = 0,
    malformed: u64 = 0,
    worker_failures: u64 = 0,
    response_ms_total: u64 = 0,
};

const Work = struct {
    id: [stratum.max_job_id_bytes]u8 = undefined,
    id_len: usize,
    header: [108]u8,
    target: [32]u8,
    epoch: u64,
    generation: u64,

    fn name(w: *const Work) []const u8 {
        return w.id[0..w.id_len];
    }
};

/// Kept across reconnects so a reused server prefix cannot restart our range.
/// Exhaustion requires a new prefix; a one-byte nonce2 never silently wraps.
pub const Nonces = struct {
    next: [32]u8 = [_]u8{0} ** 32,
    prefix_len: usize,
    exhausted: bool = false,

    pub fn init(sub: stratum.Subscription) Nonces {
        return .{ .next = sub.nonce1, .prefix_len = sub.nonce1_len };
    }
    pub fn take(n: *Nonces) ![32]u8 {
        return n.reserve(0);
    }
    pub fn reserve(n: *Nonces, device_bytes: usize) ![32]u8 {
        if (device_bytes > 4 or n.prefix_len >= 32 - device_bytes) return error.UnsupportedDeviceNoncePrefix;
        if (n.exhausted) return error.NonceExhausted;
        const result = n.next;
        var i = n.prefix_len;
        while (i < 32 - device_bytes) : (i += 1) {
            n.next[i] +%= 1;
            if (n.next[i] != 0) return result;
        }
        n.exhausted = true;
        return result;
    }
};

const Share = struct {
    work: Work,
    input: [140]u8,
    bytes: [1344]u8 = undefined,
    len: usize,
};

const Shared = struct {
    mutex: std.Thread.Mutex = .{},
    wake: std.Thread.Condition = .{},
    stop: bool = false,
    failed: bool = false,
    work: ?Work = null,
    nonces: *Nonces,
    options: Options,
    workers: []Worker,
    epoch: u64 = 0,
    generation: u64 = 0,
    queue: [64]Share = undefined,
    head: usize = 0,
    len: usize = 0,
    attempts: u64 = 0,
    solutions: u64 = 0,
    discarded: u64 = 0,
    failures: u64 = 0,
    device: backend.Status = .{},

    fn replace(s: *Shared, job: *const stratum.Job, target: [32]u8) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        // Reusing an ID with different work also invalidates in-flight results.
        const reused = if (s.work) |*w| std.mem.eql(u8, w.name(), job.id) else false;
        if (job.clean or reused) {
            s.epoch += 1;
            for (s.workers) |*worker| worker.cancel.store(true, .seq_cst);
        }
        s.generation += 1; // EVERY notify becomes the next work, even clean=false.
        var work = Work{ .id_len = job.id.len, .header = job.header, .target = target, .epoch = s.epoch, .generation = s.generation };
        @memcpy(work.id[0..job.id.len], job.id);
        s.work = work;
        s.wake.broadcast();
    }

    fn shutdown(s: *Shared) void {
        s.mutex.lock();
        s.stop = true;
        for (s.workers) |*w| w.cancel.store(true, .seq_cst);
        s.wake.broadcast();
        s.mutex.unlock();
        for (s.workers) |*w| if (w.thread) |thread| thread.join();
    }

    fn pop(s: *Shared) ?Share {
        s.mutex.lock();
        defer s.mutex.unlock();
        defer s.wake.broadcast();
        while (s.len != 0) {
            const share = s.queue[s.head];
            s.head = (s.head + 1) % s.queue.len;
            s.len -= 1;
            if (share.work.epoch != s.epoch) {
                s.discarded += 1;
                continue;
            }
            return share;
        }
        return null;
    }
};

const Worker = struct {
    shared: *Shared,
    cancel: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn run(w: *Worker) void {
        const s = w.shared;
        var allocator = Budget.init(s.options.memory_mb * 1024 * 1024 / s.options.threads);
        defer allocator.deinit();
        const gpa = allocator.allocator();
        var engine = backend.Engine{ .options = s.options.backend };
        defer engine.deinit();
        while (true) {
            s.mutex.lock();
            while (!s.stop and s.work == null) s.wake.wait(&s.mutex);
            if (s.stop) {
                s.mutex.unlock();
                return;
            }
            const work = s.work.?;
            const nonce = s.nonces.reserve(if (s.options.backend.kind == .cpu) 0 else 4) catch |err| {
                std.debug.print("nonce allocation failed: {s}\n", .{@errorName(err)});
                s.failed = true;
                s.failures += 1;
                s.mutex.unlock();
                return;
            };
            w.cancel.store(false, .seq_cst);
            s.attempts += if (s.options.backend.kind == .cpu) 1 else s.options.backend.chips;
            s.mutex.unlock();
            var input: [140]u8 = undefined;
            @memcpy(input[0..108], &work.header);
            @memcpy(input[108..140], &nonce);
            var emission = Emission{ .worker = w, .work = work, .input = input, .gpa = gpa };
            engine.solve(gpa, s.options.params, &input, &w.cancel, .{ .context = &emission, .candidate = Emission.emit, .status = Emission.status }) catch |err| {
                if (err == error.Cancelled) continue;
                std.debug.print("worker failed: {s} (allocated={d}, budget={d})\n", .{ @errorName(err), allocator.inner.total_requested_bytes, allocator.inner.requested_memory_limit });
                s.mutex.lock();
                s.failed = true;
                s.failures += 1;
                s.mutex.unlock();
                return;
            };
        }
    }
};

const Emission = struct {
    worker: *Worker,
    work: Work,
    input: [140]u8,
    gpa: std.mem.Allocator,

    fn status(ctx: *anyopaque, value: backend.Status) void {
        const e: *Emission = @ptrCast(@alignCast(ctx));
        const s = e.worker.shared;
        s.mutex.lock();
        defer s.mutex.unlock();
        s.device = value;
    }

    fn emit(ctx: *anyopaque, input: *const [140]u8, solution: []const u8) !bool {
        const e: *Emission = @ptrCast(@alignCast(ctx));
        const s = e.worker.shared;
        if (e.worker.cancel.load(.seq_cst)) return false;
        if (!std.mem.eql(u8, input[0..136], e.input[0..136]) or
            solution.len != s.options.params.solutionSize() or
            !try equihash.verify(e.gpa, s.options.params, input, solution)) return error.InvalidBackendSolution;
        var hash: [32]u8 = undefined;
        pow.blockHash(input, solution, &hash);
        s.mutex.lock();
        defer s.mutex.unlock();
        s.solutions += 1;
        if (s.stop or e.work.epoch != s.epoch) {
            s.discarded += 1;
            return false;
        }
        if (!pow.meetsTarget(&hash, &e.work.target)) return true;
        while (!s.stop and e.work.epoch == s.epoch and s.len == s.queue.len) s.wake.wait(&s.mutex);
        if (s.stop or e.work.epoch != s.epoch) {
            s.discarded += 1;
            return false;
        }
        var share = Share{ .work = e.work, .input = input.*, .len = solution.len };
        @memcpy(share.bytes[0..share.len], solution);
        s.queue[(s.head + s.len) % s.queue.len] = share;
        s.len += 1;
        return true;
    }
};

const Pending = struct { id: u64, sent_ms: u64 };
const Runtime = struct {
    gpa: std.mem.Allocator,
    options: Options,
    timer: std.time.Timer,
    stats: Stats = .{},
    next_id: u64 = 3,
    spaces: std.ArrayList(Nonces) = .empty,
    last_stats_ms: u64 = 0,
    retry_delay_ms: u32 = 0,
    device: backend.Status = .{},

    fn now(r: *Runtime) u64 {
        return r.timer.read() / std.time.ns_per_ms;
    }
    fn stopped(r: *Runtime) bool {
        return interrupted.load(.seq_cst) or (r.options.run_seconds != 0 and r.now() >= @as(u64, r.options.run_seconds) * 1000);
    }
    fn report(r: *Runtime, shared: ?*Shared, final: bool) !void {
        const elapsed = r.now();
        if (!final and elapsed - r.last_stats_ms < r.options.stats_ms) return;
        var stats = r.stats;
        if (shared) |s| {
            s.mutex.lock();
            stats.attempts += s.attempts;
            stats.solutions += s.solutions;
            stats.discarded += s.discarded;
            stats.worker_failures += s.failures;
            r.device = s.device;
            s.mutex.unlock();
        }
        const json = try std.json.Stringify.valueAlloc(r.gpa, .{ .event = if (final) "final" else "stats", .elapsed_ms = elapsed, .backend = r.options.backend.kind, .device = r.device, .stats = stats }, .{});
        defer r.gpa.free(json);
        try std.fs.File.stdout().writeAll(json);
        try std.fs.File.stdout().writeAll("\n");
        r.last_stats_ms = elapsed;
    }
    fn nonceSpace(r: *Runtime, sub: stratum.Subscription) !*Nonces {
        for (r.spaces.items) |*space| {
            if (space.prefix_len == sub.nonce1_len and std.mem.eql(u8, space.next[0..space.prefix_len], sub.nonce1[0..sub.nonce1_len])) return space;
        }
        if (r.spaces.items.len == 1024) return error.TooManyNoncePrefixes;
        try r.spaces.append(r.gpa, Nonces.init(sub));
        return &r.spaces.items[r.spaces.items.len - 1];
    }
    fn connect(r: *Runtime) !std.net.Stream {
        const list = try std.net.getAddressList(r.gpa, r.options.host, r.options.port);
        defer list.deinit();
        for (list.addrs) |address| {
            const fd = try std.posix.socket(address.any.family, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, std.posix.IPPROTO.TCP);
            var connected = false;
            defer if (!connected) std.posix.close(fd);
            std.posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
                error.WouldBlock => {
                    const start = r.now();
                    while (true) {
                        if (r.stopped()) return error.Stopped;
                        if (r.now() - start >= r.options.timeout_ms) break;
                        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                        if (try std.posix.poll(&fds, 100) != 0) break;
                    }
                    std.posix.getsockoptError(fd) catch continue;
                    // SO_ERROR may still be zero for a connect not yet completed.
                    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                    if (try std.posix.poll(&fds, 0) == 0) continue;
                },
                else => continue,
            };
            connected = true;
            return .{ .handle = fd };
        }
        return error.ConnectionFailed;
    }
    fn send(r: *Runtime, conn: *stratum.Conn, id: u64, method: []const u8, params: anytype) !void {
        const line = try stratum.formatRequest(r.gpa, id, method, params);
        defer r.gpa.free(line);
        try conn.sendAll(line);
    }
    fn session(r: *Runtime) !void {
        var conn = stratum.Conn.init(r.gpa, try r.connect());
        defer conn.deinit();
        r.stats.connections += 1;
        try r.send(&conn, 1, "mining.subscribe", .{ r.options.agent, @as(?[]const u8, null), r.options.host, r.options.port });
        var subscribed: ?stratum.Subscription = null;
        var authorized = false;
        var target: ?[32]u8 = null;
        var job: ?stratum.Job = null;
        var job_target: ?[32]u8 = null;
        defer if (job) |*j| j.deinit();
        var pending: [128]?Pending = @splat(null);
        defer for (pending) |p| {
            if (p != null) r.stats.unknown += 1;
        };
        const workers = try r.gpa.alloc(Worker, if (r.options.probe) 0 else r.options.threads);
        defer r.gpa.free(workers);
        var shared: Shared = undefined;
        var started = false;
        defer if (started) {
            shared.shutdown();
            r.stats.attempts += shared.attempts;
            r.stats.solutions += shared.solutions;
            r.stats.discarded += shared.discarded;
            r.stats.worker_failures += shared.failures;
            r.device = shared.device;
        };
        var last_message_ms = r.now();
        const handshake_start = last_message_ms;
        var malformed_streak: usize = 0;
        while (!r.stopped()) {
            const now_ms = r.now();
            if (now_ms - last_message_ms >= r.options.timeout_ms) return error.IdleTimeout;
            if (!authorized and now_ms - handshake_start >= r.options.timeout_ms) return error.HandshakeTimeout;
            for (&pending) |*p| if (p.*) |request| {
                if (now_ms - request.sent_ms >= r.options.timeout_ms) {
                    r.stats.unknown += 1;
                    p.* = null;
                }
            };
            if (started) {
                shared.mutex.lock();
                const failed = shared.failed;
                shared.mutex.unlock();
                if (failed) return error.WorkerFailed;
                var sent_this_tick: usize = 0;
                for (&pending) |*slot| {
                    // Process already-received pool messages before sending
                    // more work. Bound each send batch so notifications and
                    // acknowledgements cannot starve behind fast CPU workers.
                    if (sent_this_tick >= 8 or std.mem.indexOfScalar(u8, conn.decoder.pending.items, '\n') != null) break;
                    if (slot.* != null) continue;
                    const share = shared.pop() orelse break;
                    const id = r.next_id;
                    r.next_id += 1;
                    const line = try stratum.formatSubmit(r.gpa, id, r.options.user, share.work.name(), share.input[100..104], share.input[108 + subscribed.?.nonce1_len ..], share.bytes[0..share.len]);
                    defer r.gpa.free(line);
                    // A failed write may have reached the peer. Account for it
                    // as unknown, never accepted, and never replay it blindly.
                    slot.* = .{ .id = id, .sent_ms = r.now() };
                    r.stats.submitted += 1;
                    try conn.sendAll(line);
                    sent_this_tick += 1;
                }
            }
            try r.report(if (started) &shared else null, false);
            var msg = (conn.readJson(100) catch |err| switch (err) {
                error.ReadTimeout => continue,
                error.SyntaxError, error.UnexpectedToken, error.InvalidCharacter, error.UnexpectedEndOfInput, error.InvalidNumber, error.Overflow => {
                    r.stats.malformed += 1;
                    malformed_streak += 1;
                    if (malformed_streak >= 8) return error.MalformedPeer;
                    continue;
                },
                else => return err,
            }) orelse return error.Eof;
            defer msg.deinit();
            if (msg.value != .object) {
                r.stats.malformed += 1;
                continue;
            }
            const obj = msg.value.object;
            last_message_ms = r.now();
            malformed_streak = 0;
            if (obj.get("method")) |method_value| {
                const method = stratum.string(method_value) catch {
                    r.stats.malformed += 1;
                    continue;
                };
                const params = obj.get("params") orelse {
                    r.stats.malformed += 1;
                    continue;
                };
                if (std.mem.eql(u8, method, "mining.set_target")) {
                    target = stratum.parseSetTarget(params) catch {
                        r.stats.malformed += 1;
                        continue;
                    };
                } else if (std.mem.eql(u8, method, "mining.notify")) {
                    const next = stratum.parseNotify(r.gpa, params) catch |err| {
                        std.debug.print("ignored job: {s}\n", .{@errorName(err)});
                        r.stats.malformed += 1;
                        continue;
                    };
                    if (job) |*j| j.deinit();
                    job = next;
                    job_target = target orelse try job.?.networkTarget();
                    r.stats.jobs += 1;
                    if (started) shared.replace(&job.?, job_target.?);
                } else if (std.mem.eql(u8, method, "client.reconnect") or std.mem.eql(u8, method, "mining.reconnect")) {
                    // Reconnect only to the configured endpoint. A server
                    // cannot redirect the user's credentials to another host.
                    const args = stratum.array(params) catch return error.BadReconnect;
                    if (args.len == 3 and args[2] == .integer and args[2].integer >= 0 and args[2].integer <= 300) r.retry_delay_ms = @intCast(args[2].integer * 1000);
                    return error.PoolReconnect;
                }
            } else {
                const id_value = obj.get("id") orelse {
                    r.stats.unexpected_replies += 1;
                    continue;
                };
                if (id_value != .integer or id_value.integer < 0) {
                    r.stats.unexpected_replies += 1;
                    continue;
                }
                const id: u64 = @intCast(id_value.integer);
                const result = obj.get("result") orelse .null;
                const err = obj.get("error") orelse .null;
                if (id == 1 and subscribed == null) {
                    if (err != .null) return error.SubscriptionRejected;
                    subscribed = try stratum.parseSubscribe(result);
                    try r.send(&conn, 2, "mining.authorize", .{ r.options.user, r.options.pass });
                } else if (id == 2 and !authorized) {
                    if (subscribed == null or err != .null or result != .bool or !result.bool) return error.AuthorizationRejected;
                    authorized = true;
                } else {
                    var matched = false;
                    for (&pending) |*slot| if (slot.*) |request| {
                        if (request.id != id) continue;
                        matched = true;
                        r.stats.response_ms_total += r.now() - request.sent_ms;
                        if (err == .null and result == .bool and result.bool) {
                            r.stats.accepted += 1;
                        } else if (err != .null or (result == .bool and !result.bool)) {
                            r.stats.rejected += 1;
                            if (err == .array and err.array.items.len > 0 and err.array.items[0] == .integer and err.array.items[0].integer == 21) r.stats.stale += 1;
                        } else {
                            r.stats.unknown += 1;
                            r.stats.malformed += 1;
                        }
                        slot.* = null;
                        break;
                    };
                    if (!matched) r.stats.unexpected_replies += 1;
                }
            }
            if (!started and authorized and subscribed != null and job != null) {
                if (r.options.probe) {
                    std.debug.print("pool probe passed: authorized; ZIP 301 job parsed\n", .{});
                    return;
                }
                shared = .{ .nonces = try r.nonceSpace(subscribed.?), .options = r.options, .workers = workers };
                for (workers) |*w| w.* = .{ .shared = &shared };
                started = true; // defer joins every successfully spawned worker.
                for (workers) |*w| w.thread = try std.Thread.spawn(.{}, Worker.run, .{w});
                shared.replace(&job.?, job_target.?);
            }
        }
    }
};

pub fn run(gpa: std.mem.Allocator, options: Options) !void {
    if (options.threads == 0 or options.threads > 256 or options.memory_mb == 0 or options.memory_mb > std.math.maxInt(usize) / (1024 * 1024) or options.timeout_ms < 100 or options.timeout_ms > 3_600_000 or options.stats_ms == 0 or options.reconnect_ms > 60_000) return error.InvalidConfiguration;
    if (options.backend.kind != .cpu and (options.threads != 1 or options.backend.endpoint.len == 0 or options.backend.chips == 0 or options.backend.chips > 4 or options.backend.timeout_ms < 100 or options.backend.timeout_ms > 3_600_000)) return error.InvalidBackendConfiguration;
    var runtime = Runtime{ .gpa = gpa, .options = options, .timer = try std.time.Timer.start() };
    defer runtime.spaces.deinit(gpa);
    defer runtime.report(null, true) catch {};
    var delay = options.reconnect_ms;
    while (!runtime.stopped()) {
        const accepted_before = runtime.stats.accepted;
        runtime.session() catch |err| {
            if (runtime.stopped()) break;
            std.debug.print("pool session ended: {s}\n", .{@errorName(err)});
            switch (err) {
                error.AuthorizationRejected, error.SubscriptionRejected, error.WorkerFailed, error.OutOfMemory, error.TooManyNoncePrefixes => return err,
                else => {},
            }
            runtime.stats.reconnects += 1;
            if (runtime.stats.accepted > accepted_before) delay = options.reconnect_ms;
            const jitter = std.crypto.random.intRangeAtMost(u32, 0, delay / 4);
            const wait_ms = @max(delay + jitter, runtime.retry_delay_ms);
            runtime.retry_delay_ms = 0;
            const deadline = runtime.now() + wait_ms;
            while (!runtime.stopped() and runtime.now() < deadline) {
                try runtime.report(null, false);
                std.Thread.sleep(20 * std.time.ns_per_ms);
            }
            delay = @min(@max(delay, 100) * 2, 30_000);
            continue;
        };
        break;
    }
}

test "device nonce allocation reserves chip and attempt suffix without overlap" {
    var nonces = Nonces.init(.{ .nonce1_len = 27 });
    for (0..256) |i| {
        const n = try nonces.reserve(4);
        try std.testing.expectEqual(@as(u8, @intCast(i)), n[27]);
        try std.testing.expect(std.mem.allEqual(u8, n[28..32], 0));
    }
    try std.testing.expectError(error.NonceExhausted, nonces.reserve(4));
    var too_long = Nonces.init(.{ .nonce1_len = 28 });
    try std.testing.expectError(error.UnsupportedDeviceNoncePrefix, too_long.reserve(4));
}

test "nonce allocation exhausts suffix without changing prefix or wrapping" {
    var sub = stratum.Subscription{ .nonce1_len = 31 };
    @memset(sub.nonce1[0..31], 0x42);
    var nonces = Nonces.init(sub);
    for (0..256) |i| {
        const n = try nonces.take();
        try std.testing.expectEqual(@as(u8, @intCast(i)), n[31]);
        try std.testing.expect(std.mem.allEqual(u8, n[0..31], 0x42));
    }
    try std.testing.expectError(error.NonceExhausted, nonces.take());
}

test "non-clean notify advances generation and binds target without invalidating old work" {
    var nonces = Nonces.init(.{ .nonce1_len = 0 });
    var s = Shared{ .nonces = &nonces, .options = .{ .host = "", .port = 0, .user = "", .agent = "" }, .workers = &.{} };
    const gpa = std.testing.allocator;
    var j = stratum.Job{ .gpa = gpa, .id = try gpa.dupe(u8, "first"), .header = @splat(0), .clean = false };
    defer j.deinit();
    s.replace(&j, @splat(1));
    const old = s.work.?;
    var second = stratum.Job{ .gpa = gpa, .id = try gpa.dupe(u8, "second"), .header = @splat(0), .clean = false };
    defer second.deinit();
    s.replace(&second, @splat(2));
    try std.testing.expect(s.work.?.generation > old.generation);
    try std.testing.expectEqual(old.epoch, s.work.?.epoch);
    try std.testing.expectEqual(@as(u8, 1), old.target[0]);
    try std.testing.expectEqual(@as(u8, 2), s.work.?.target[0]);
    second.clean = true;
    s.replace(&second, @splat(3));
    try std.testing.expect(s.work.?.epoch > old.epoch);
}
