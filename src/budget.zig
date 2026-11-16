// SPDX-License-Identifier: Apache-2.0
// Per-worker allocation budget and peak requested-byte instrumentation.
const std = @import("std");

pub const Budget = struct {
    // Zig 0.15.2 resizeSmall skips memory accounting when safety=false.
    // Keep safety enabled even in ReleaseFast, otherwise a small resize/free
    // can underflow total_requested_bytes and falsely exhaust the budget.
    inner: std.heap.DebugAllocator(.{ .enable_memory_limit = true, .safety = true, .stack_trace_frames = 0, .thread_safe = false }) = .{},
    peak: usize = 0,

    pub fn init(limit: usize) Budget {
        var result = Budget{};
        result.inner.requested_memory_limit = limit;
        return result;
    }
    pub fn deinit(b: *Budget) void {
        std.debug.assert(b.inner.deinit() == .ok);
    }
    pub fn allocator(b: *Budget) std.mem.Allocator {
        return .{ .ptr = b, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn update(b: *Budget) void {
        b.peak = @max(b.peak, b.inner.total_requested_bytes);
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        const result = b.inner.allocator().rawAlloc(len, alignment, ra);
        b.update();
        return result;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        const result = b.inner.allocator().rawResize(memory, alignment, len, ra);
        b.update();
        return result;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        const result = b.inner.allocator().rawRemap(memory, alignment, len, ra);
        b.update();
        return result;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        b.inner.allocator().rawFree(memory, alignment, ra);
    }
};

test "budget survives repeated same-class resize and rejects real exhaustion" {
    var budget = Budget.init(128);
    defer budget.deinit();
    const gpa = budget.allocator();
    for (0..100) |_| {
        var bytes = try gpa.alloc(u8, 48);
        bytes = try gpa.realloc(bytes, 60);
        try std.testing.expectEqual(@as(usize, 60), budget.inner.total_requested_bytes);
        gpa.free(bytes);
        try std.testing.expectEqual(@as(usize, 0), budget.inner.total_requested_bytes);
    }
    try std.testing.expect(budget.peak >= 60 and budget.peak <= 128);
    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 129));
}
