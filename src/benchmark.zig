// SPDX-License-Identifier: Apache-2.0
// JSONL benchmark records carry the exact input and verified solution set.
const std = @import("std");
const equihash = @import("equihash.zig");
const util = @import("util.zig");
const Budget = @import("budget.zig").Budget;

pub const Options = struct {
    params: equihash.Params,
    corpus: []const u8 = "",
    iterations: usize = 4,
    all_solutions: bool = true,
    memory_mb: usize = 3072,
    cancel_after_ms: u32 = 0,
};

const Output = struct {
    gpa: std.mem.Allocator,
    solutions: std.ArrayList([]u8) = .empty,
    fn emit(ctx: *anyopaque, solution: []const u8) !bool {
        const out: *Output = @ptrCast(@alignCast(ctx));
        const hex = try util.hexEncode(out.gpa, solution);
        errdefer out.gpa.free(hex);
        try out.solutions.append(out.gpa, hex);
        return true;
    }
    fn deinit(out: *Output) void {
        for (out.solutions.items) |s| out.gpa.free(s);
        out.solutions.deinit(out.gpa);
    }
};

const Cancellation = struct {
    timer: std.time.Timer,
    delay_ms: u32,
    flag: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    issued_ns: std.atomic.Value(u64) = .init(0),
    fn run(c: *Cancellation) void {
        var timer = c.timer;
        while (!c.done.load(.seq_cst)) {
            const elapsed = timer.read();
            if (elapsed >= @as(u64, c.delay_ms) * std.time.ns_per_ms) {
                c.issued_ns.store(elapsed, .seq_cst);
                c.flag.store(true, .seq_cst);
                return;
            }
            std.Thread.sleep(std.time.ns_per_ms);
        }
    }
};

fn one(gpa: std.mem.Allocator, options: Options, input: *const [140]u8, index: usize) !void {
    var budget = Budget.init(options.memory_mb * 1024 * 1024);
    defer budget.deinit();
    const allocator = budget.allocator();
    var output = Output{ .gpa = gpa };
    defer output.deinit();
    var timer = try std.time.Timer.start();
    var cancellation = Cancellation{ .timer = timer, .delay_ms = options.cancel_after_ms };
    const thread: ?std.Thread = if (options.cancel_after_ms != 0) try std.Thread.spawn(.{}, Cancellation.run, .{&cancellation}) else null;
    defer {
        cancellation.done.store(true, .seq_cst);
        if (thread) |t| t.join();
    }
    if (options.all_solutions) {
        _ = try equihash.solveEach(allocator, options.params, input, &cancellation.flag, .{ .context = &output, .on_solution = Output.emit });
    } else {
        var solution: std.ArrayList(u8) = .empty;
        defer solution.deinit(allocator);
        if (try equihash.solve(allocator, options.params, input, &cancellation.flag, &solution)) _ = try Output.emit(&output, solution.items);
    }
    const elapsed_ns = timer.read();
    // Tell the timer thread immediately; verification/output are not solve time.
    cancellation.done.store(true, .seq_cst);
    const issued = cancellation.issued_ns.load(.seq_cst);
    for (output.solutions.items) |hex| {
        const bytes = try util.hexDecode(gpa, hex);
        defer gpa.free(bytes);
        if (!try equihash.verify(gpa, options.params, input, bytes)) return error.InvalidSolverOutput;
    }
    const input_hex = try util.hexEncode(gpa, input);
    defer gpa.free(input_hex);
    const rss = std.posix.getrusage(0).maxrss;
    const json = try std.json.Stringify.valueAlloc(gpa, .{
        .schema = "zcash-miner-benchmark-v1",
        .index = index,
        .n = options.params.n,
        .k = options.params.k,
        .mode = if (options.all_solutions) "all" else "first",
        .input = input_hex,
        .solutions = output.solutions.items,
        .verified_solutions = output.solutions.items.len,
        .elapsed_ns = elapsed_ns,
        .solutions_per_second = @as(f64, @floatFromInt(output.solutions.items.len)) * 1e9 / @as(f64, @floatFromInt(@max(elapsed_ns, 1))),
        .peak_requested_bytes = budget.peak,
        // Linux ru_maxrss is KiB and is a process lifetime high-water mark.
        .process_peak_rss_bytes = @as(u64, @intCast(rss)) * 1024,
        .cancel_requested_ns = if (issued != 0) @as(?u64, issued) else null,
        .cancel_latency_ns = if (issued != 0 and elapsed_ns >= issued) @as(?u64, elapsed_ns - issued) else null,
    }, .{});
    defer gpa.free(json);
    try std.fs.File.stdout().writeAll(json);
    try std.fs.File.stdout().writeAll("\n");
}

pub fn run(gpa: std.mem.Allocator, options: Options) !void {
    if (options.memory_mb == 0 or options.memory_mb > std.math.maxInt(usize) / (1024 * 1024) or options.iterations == 0 or options.iterations > 1_000_000) return error.InvalidConfiguration;
    if (options.corpus.len > 0) {
        const data = try std.fs.cwd().readFileAlloc(gpa, options.corpus, 16 << 20);
        defer gpa.free(data);
        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        var index: usize = 0;
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r\t");
            if (line.len == 0 or line[0] == '#') continue;
            if (line.len != 280) return error.BadCorpusLine;
            var input: [140]u8 = undefined;
            _ = try std.fmt.hexToBytes(&input, line);
            try one(gpa, options, &input, index);
            index += 1;
        }
        if (index == 0) return error.EmptyCorpus;
    } else {
        for (0..options.iterations) |i| {
            var input: [140]u8 = @splat(0);
            input[0] = 4;
            @memcpy(input[4..29], "zcash-benchmark-corpus-v1");
            std.mem.writeInt(u64, input[108..116], @intCast(i), .little);
            try one(gpa, options, &input, i);
        }
    }
}

test {
    std.testing.refAllDecls(@import("budget.zig"));
}
