const std = @import("std");
const AnswerRenderer = @import("AnswerRenderer");

// Observe requests through the page-allocator singleton, not libc allocations,
// direct mappings, or physical footprint. Bypass the override in the backing
// allocator so the standard accounting wrapper cannot recurse into itself.
var accounting = std.testing.FailingAllocator.init(.{
    .ptr = undefined,
    .vtable = &std.heap.PageAllocator.vtable,
}, .{});

pub const os = struct {
    pub const heap = struct {
        pub const page_allocator: std.mem.Allocator = .{
            .ptr = &accounting,
            .vtable = accounting.allocator().vtable,
        };
    };
};

pub fn main() !void {
    var buffer: [4096]u8 = undefined;
    var discard = std.Io.Writer.Discarding.init(&buffer);
    const chunk = [_]u8{'a'} ** 4096;
    const allocated_before = accounting.allocated_bytes;
    const allocations_before = accounting.allocations;
    const live_before = accounting.allocated_bytes - accounting.freed_bytes;
    var renderer: AnswerRenderer = .{ .out = &discard.writer };
    for (0..4096) |_| try renderer.feed(&chunk);
    try renderer.finish();

    // Forwarding must pass before accounting: a freed full-answer buffer still
    // violates the allocation-volume assertion even with unchanged live bytes.
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024), discard.fullCount());
    try std.testing.expectEqual(@as(usize, 0), accounting.allocated_bytes - allocated_before);
    try std.testing.expectEqual(@as(usize, 0), accounting.allocations - allocations_before);
    try std.testing.expectEqual(live_before, accounting.allocated_bytes - accounting.freed_bytes);
}
