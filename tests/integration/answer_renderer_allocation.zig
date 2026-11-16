const std = @import("std");
const AnswerRenderer = @import("AnswerRenderer");

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
    const chunk = @as([4096]u8, @splat('a'));
    const allocated_before = accounting.allocated_bytes;
    const allocations_before = accounting.allocations;
    const live_before = accounting.allocated_bytes - accounting.freed_bytes;
    var renderer: AnswerRenderer = .{ .out = &discard.writer };
    for (0..4096) |_| try renderer.feed(&chunk);
    try renderer.finish();

    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024), discard.fullCount());
    for (0..256) |_| try renderer.feed("\n| `name` | 雪 |\n| --- | --- |\n| **value** | abc |\n\n```zig\ncode\n\n```\n");
    try renderer.finish();
    try std.testing.expectEqual(@as(usize, 0), accounting.allocated_bytes - allocated_before);
    try std.testing.expectEqual(@as(usize, 0), accounting.allocations - allocations_before);
    try std.testing.expectEqual(live_before, accounting.allocated_bytes - accounting.freed_bytes);
}
