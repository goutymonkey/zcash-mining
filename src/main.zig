// zcash-miner: reference CPU miner for Zcash (Equihash PoW) in Zig.
//
// Modes:
//   --demo            solve + verify one Equihash instance offline (default 48,5)
//   --bench           hash + solver micro-benchmarks
//   --verify FILE     check "input_hex solution_hex" lines (e.g. from the ASIC sim)
//   --pool H:P --user U   mine on a stratum pool (default params 200,9)
//   --params N,K      Equihash parameters (200,9 | 96,5 | 48,5)
const std = @import("std");
const equihash = @import("equihash.zig");
const pow = @import("pow.zig");
const stratum = @import("stratum.zig");
const util = @import("util.zig");
const mining = @import("mining.zig");
const benchmark = @import("benchmark.zig");
const backend = @import("backend.zig");

const VERSION = "0.6.0";

fn usage() void {
    std.debug.print(
        \\zcash-miner {s} - reference Zcash (Equihash) mining host
        \\
        \\Usage:
        \\  zcash-miner --demo [--params N,K]
        \\  zcash-miner --bench
        \\  zcash-miner --verify FILE [--params N,K]
        \\  zcash-miner --pool HOST:PORT --user USER [--pass P] [--threads N] [--params N,K]
        \\
        \\Options:
        \\  --pool HOST:PORT   stratum pool address
        \\  --user USER        pool username / transparent address (+ worker suffix)
        \\  --pass PASS        pool password (default "x")
        \\  --threads N        solver threads (default: 1)
        \\  --backend KIND     cpu (default), rtl, or serial
        \\  --device ENDPOINT  RTL HOST:PORT or serial device path
        \\  --chips N          device chain length 1..4 (default 1; one host thread)
        \\  --baud N           serial baud rate (default 2500000)
        \\  --device-timeout N  maximum seconds per device operation (default 120)
        \\  --params N,K       Equihash params: 200,9 (mainnet), 96,5 or 48,5 (default 200,9)
        \\  --demo             offline solve+verify demo (default params 48,5)
        \\  --bench            emit verified solve benchmarks as JSONL (default 48,5)
        \\  --verify FILE      verify "input_hex minimal_solution_hex" per line
        \\                     (default params 48,5); exits 1 if any fail
        \\  --memory-limit-mb N total solver allocation budget (default 3072 MiB)
        \\  --timeout-seconds N connection/session/share timeout (default 120)
        \\  --stats-interval N  JSON statistics interval in seconds (default 5)
        \\  --run-seconds N     stop after N seconds (default unlimited)
        \\  --reconnect-ms N    initial reconnect delay (default 1000)
        \\  --corpus FILE      benchmark 140-byte input hex lines
        \\  --iterations N     built-in benchmark corpus size (default 4)
        \\  --solutions MODE   benchmark all or first solutions (default all)
        \\  --cancel-after-ms N benchmark cancellation during a solve
        \\  --probe            authorize and parse a job without mining
        \\  --version          print version
        \\  --help             this text
        \\
    , .{VERSION});
}

const Config = struct {
    mode: enum { demo, bench, pool, verify } = .demo,
    verify_path: []const u8 = "",
    pool_host: []const u8 = "",
    pool_port: u16 = 0,
    user: []const u8 = "",
    pass: []const u8 = "x",
    threads: usize = 1,
    memory_mb: usize = 3072,
    timeout_seconds: u32 = 120,
    stats_seconds: u32 = 5,
    run_seconds: u32 = 0,
    reconnect_ms: u32 = 1000,
    probe: bool = false,
    corpus_path: []const u8 = "",
    iterations: usize = 4,
    all_solutions: bool = true,
    cancel_after_ms: u32 = 0,
    params: equihash.Params = equihash.MAINNET,
    demo_params: bool = false,
    backend: backend.Options = .{},
};

fn parseParams(s: []const u8) !equihash.Params {
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse return error.BadParams;
    const n = try std.fmt.parseInt(u32, s[0..comma], 10);
    const k = try std.fmt.parseInt(u32, s[comma + 1 ..], 10);
    return equihash.checkParams(n, k);
}

fn parseArgs(gpa: std.mem.Allocator) !Config {
    var cfg = Config{};
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            usage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "--demo")) {
            cfg.mode = .demo;
        } else if (std.mem.eql(u8, a, "--bench")) {
            cfg.mode = .bench;
        } else if (std.mem.eql(u8, a, "--verify")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.verify_path = args[i];
            cfg.mode = .verify;
        } else if (std.mem.eql(u8, a, "--pool")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const colon = std.mem.lastIndexOfScalar(u8, args[i], ':') orelse return error.BadPool;
            cfg.pool_host = args[i][0..colon];
            cfg.pool_port = try std.fmt.parseInt(u16, args[i][colon + 1 ..], 10);
            cfg.mode = .pool;
        } else if (std.mem.eql(u8, a, "--user")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.user = args[i];
            cfg.mode = .pool;
        } else if (std.mem.eql(u8, a, "--pass")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.pass = args[i];
        } else if (std.mem.eql(u8, a, "--threads")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.threads = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--backend") or std.mem.eql(u8, a, "--device") or std.mem.eql(u8, a, "--chips") or std.mem.eql(u8, a, "--baud") or std.mem.eql(u8, a, "--device-timeout")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (std.mem.eql(u8, a, "--backend")) {
                cfg.backend.kind = std.meta.stringToEnum(backend.Kind, args[i]) orelse return error.BadArgs;
            } else if (std.mem.eql(u8, a, "--device")) {
                cfg.backend.endpoint = args[i];
            } else if (std.mem.eql(u8, a, "--chips")) {
                cfg.backend.chips = try std.fmt.parseInt(u8, args[i], 10);
            } else if (std.mem.eql(u8, a, "--baud")) {
                cfg.backend.baud = try std.fmt.parseInt(u32, args[i], 10);
            } else {
                const seconds = try std.fmt.parseInt(u32, args[i], 10);
                if (seconds == 0 or seconds > 3600) return error.BadArgs;
                cfg.backend.timeout_ms = seconds * 1000;
            }
        } else if (std.mem.eql(u8, a, "--corpus")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.corpus_path = args[i];
        } else if (std.mem.eql(u8, a, "--solutions")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (std.mem.eql(u8, args[i], "all")) cfg.all_solutions = true else if (std.mem.eql(u8, args[i], "first")) cfg.all_solutions = false else return error.BadArgs;
        } else if (std.mem.eql(u8, a, "--probe")) {
            cfg.probe = true;
        } else if (std.mem.eql(u8, a, "--version")) {
            try std.fs.File.stdout().writeAll(VERSION ++ "\n");
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "--memory-limit-mb") or std.mem.eql(u8, a, "--timeout-seconds") or std.mem.eql(u8, a, "--stats-interval") or std.mem.eql(u8, a, "--run-seconds") or std.mem.eql(u8, a, "--reconnect-ms") or std.mem.eql(u8, a, "--iterations") or std.mem.eql(u8, a, "--cancel-after-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const value = try std.fmt.parseInt(u32, args[i], 10);
            if (std.mem.eql(u8, a, "--memory-limit-mb")) cfg.memory_mb = value else if (std.mem.eql(u8, a, "--timeout-seconds")) cfg.timeout_seconds = value else if (std.mem.eql(u8, a, "--stats-interval")) cfg.stats_seconds = value else if (std.mem.eql(u8, a, "--run-seconds")) cfg.run_seconds = value else if (std.mem.eql(u8, a, "--iterations")) cfg.iterations = value else if (std.mem.eql(u8, a, "--cancel-after-ms")) cfg.cancel_after_ms = value else cfg.reconnect_ms = value;
        } else if (std.mem.eql(u8, a, "--params")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.params = try parseParams(args[i]);
            cfg.demo_params = true;
        } else {
            std.debug.print("unknown arg: {s}\n", .{a});
            return error.BadArgs;
        }
    }
    if ((cfg.mode == .demo or cfg.mode == .verify or cfg.mode == .bench) and !cfg.demo_params) cfg.params = equihash.TEST_SMALL;
    if (cfg.threads == 0 or cfg.timeout_seconds == 0 or cfg.timeout_seconds > 3600 or cfg.stats_seconds == 0 or cfg.stats_seconds > 3600) return error.BadArgs;
    // args[] is freed below; keep process-lifetime copies.
    cfg.pool_host = try gpa.dupe(u8, cfg.pool_host);
    cfg.user = try gpa.dupe(u8, cfg.user);
    cfg.pass = try gpa.dupe(u8, cfg.pass);
    cfg.verify_path = try gpa.dupe(u8, cfg.verify_path);
    cfg.corpus_path = try gpa.dupe(u8, cfg.corpus_path);
    cfg.backend.endpoint = try gpa.dupe(u8, cfg.backend.endpoint);
    return cfg;
}

/// Verify externally produced solutions (one "input_hex solution_hex" per
/// line; blank lines and '#' comments skipped). Used to check the ZEQ-200
/// RTL simulation against the consensus-ported verifier.
fn verifyFile(gpa: std.mem.Allocator, params: equihash.Params, path: []const u8) !bool {
    const data = try std.fs.cwd().readFileAlloc(gpa, path, 64 << 20);
    defer gpa.free(data);
    var ok_count: usize = 0;
    var fail_count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const input_hex = fields.next() orelse return error.BadVerifyLine;
        const sol_hex = fields.next() orelse return error.BadVerifyLine;
        const input = try util.hexDecode(gpa, input_hex);
        defer gpa.free(input);
        const sol = try util.hexDecode(gpa, sol_hex);
        defer gpa.free(sol);
        const ok = sol.len == params.solutionSize() and
            try equihash.verify(gpa, params, input, sol);
        if (ok) ok_count += 1 else fail_count += 1;
        std.debug.print("{s} {s}...\n", .{ if (ok) "OK  " else "FAIL", sol_hex[0..@min(sol_hex.len, 16)] });
    }
    std.debug.print("verify: {d} ok, {d} failed (Equihash {d},{d})\n", .{ ok_count, fail_count, params.n, params.k });
    return fail_count == 0 and ok_count > 0;
}

fn demo(gpa: std.mem.Allocator, params: equihash.Params) !void {
    std.debug.print("demo: solving Equihash({d},{d}) offline...\n", .{ params.n, params.k });
    if (params.n == 200) {
        std.debug.print("note: (200,9) needs ~2.2GB RAM and several minutes on a reference solver.\n", .{});
    }
    const t0 = std.time.milliTimestamp();
    var input: [140]u8 = [_]u8{0} ** 140;
    @memcpy(input[0..16], "zcash-miner-demo");
    var attempts: u32 = 0;
    while (true) : (attempts += 1) {
        input[100] = @truncate(attempts);
        input[101] = @truncate(attempts >> 8);
        var sol: std.ArrayList(u8) = .empty;
        defer sol.deinit(gpa);
        const cancel: ?*const std.atomic.Value(bool) = null;
        const found = equihash.solve(gpa, params, &input, cancel, &sol) catch |err| {
            if (err == error.OutOfMemory) {
                std.debug.print("demo: out of memory (need ~2.2GB for 200,9). Try --params 96,5.\n", .{});
                return;
            }
            return err;
        };
        if (found) {
            const ms = std.time.milliTimestamp() - t0;
            const ok = try equihash.verify(gpa, params, &input, sol.items);
            const sol_hex = try util.hexEncode(gpa, sol.items);
            defer gpa.free(sol_hex);
            var bh: [32]u8 = undefined;
            pow.blockHash(&input, sol.items, &bh);
            // Show block hash in display (reversed) order.
            var rev = bh;
            util.reverseBytes(rev[0..]);
            const rev_hex = try util.hexEncode(gpa, &rev);
            defer gpa.free(rev_hex);
            std.debug.print("solved after {d} attempt(s) in {d} ms. verify={}\n", .{ attempts + 1, ms, ok });
            std.debug.print("solution ({d} bytes): {s}\n", .{ sol.items.len, sol_hex });
            std.debug.print("block hash: {s}\n", .{rev_hex});
            if (!ok) return error.VerifyFailed;
            return;
        }
        if (attempts > 100000) return error.NoSolution;
    }
}

fn poolMine(gpa: std.mem.Allocator, cfg: Config) !void {
    mining.installSignals();
    try mining.run(gpa, .{
        .host = cfg.pool_host,
        .port = cfg.pool_port,
        .user = cfg.user,
        .pass = cfg.pass,
        .agent = "zcash-miner-zig/" ++ VERSION,
        .params = cfg.params,
        .threads = cfg.threads,
        .memory_mb = cfg.memory_mb,
        .timeout_ms = cfg.timeout_seconds * 1000,
        .stats_ms = cfg.stats_seconds * 1000,
        .run_seconds = cfg.run_seconds,
        .reconnect_ms = cfg.reconnect_ms,
        .probe = cfg.probe,
        .backend = cfg.backend,
    });
}

test "params flag parses" {
    const p = try parseParams("200,9");
    try std.testing.expectEqual(equihash.MAINNET.n, p.n);
    try std.testing.expectEqual(equihash.MAINNET.k, p.k);
    try std.testing.expectError(error.UnsupportedParams, parseParams("100,3"));
}

// Anchor every module so `zig build test` runs all test blocks.
test {
    std.testing.refAllDecls(equihash);
    std.testing.refAllDecls(pow);
    std.testing.refAllDecls(stratum);
    std.testing.refAllDecls(util);
    std.testing.refAllDecls(mining);
    std.testing.refAllDecls(benchmark);
    std.testing.refAllDecls(backend);
}

pub fn main() !void {
    var dbg = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();
    const cfg = parseArgs(gpa) catch {
        usage();
        std.process.exit(2);
    };
    // parseArgs dupes these so they outlive argv; free them before the
    // leak-checking allocator deinits.
    defer {
        gpa.free(cfg.pool_host);
        gpa.free(cfg.user);
        gpa.free(cfg.pass);
        gpa.free(cfg.verify_path);
        gpa.free(cfg.corpus_path);
        gpa.free(cfg.backend.endpoint);
    }
    switch (cfg.mode) {
        .demo => try demo(gpa, cfg.params),
        .bench => try benchmark.run(gpa, .{ .params = cfg.params, .corpus = cfg.corpus_path, .iterations = cfg.iterations, .all_solutions = cfg.all_solutions, .memory_mb = cfg.memory_mb, .cancel_after_ms = cfg.cancel_after_ms }),
        .verify => if (!try verifyFile(gpa, cfg.params, cfg.verify_path)) std.process.exit(1),
        .pool => {
            if (cfg.pool_host.len == 0 or cfg.user.len == 0) {
                std.debug.print("pool mode needs --pool HOST:PORT and --user USER\n", .{});
                usage();
                std.process.exit(2);
            }
            try poolMine(gpa, cfg);
        },
    }
}
