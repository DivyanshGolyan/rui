//! Retained Host identities and exact content are distinct from Text widgets.
const std = @import("std");
const fw = @import("vaxis").vxfw;
const observations = @import("NativeObservations.zig");
const Self = @This();

sources: std.ArrayList(observations.Block) = .empty,
widgets: std.ArrayList(fw.Text) = .empty,

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.sources.deinit(allocator);
    self.widgets.deinit(allocator);
    self.* = .{};
}

pub fn clearRetainingCapacity(self: *Self) void {
    self.sources.clearRetainingCapacity();
    self.widgets.clearRetainingCapacity();
}

/// Blocks and their exact bytes borrow `arena` through the feed's lifetime.
pub fn append(self: *Self, allocator: std.mem.Allocator, arena: std.mem.Allocator, blocks: []const observations.Block) !void {
    const widgets = try arena.alloc(fw.Text, blocks.len);
    for (blocks, widgets) |block, *item| {
        const prefix = if (block.kind == .user) "You\n" else "Assistant\n";
        item.* = .{ .text = try std.fmt.allocPrint(arena, "{s}{s}\n", .{ prefix, block.display }), .softwrap = true, .width_basis = .parent };
    }
    try self.sources.ensureUnusedCapacity(allocator, blocks.len);
    try self.widgets.ensureUnusedCapacity(allocator, widgets.len);
    self.sources.appendSliceAssumeCapacity(blocks);
    self.widgets.appendSliceAssumeCapacity(widgets);
}

pub fn sourceAt(self: *const Self, position: u64, ordinal: u64) ?observations.Block {
    for (self.sources.items) |block| if (block.position == position and block.ordinal == ordinal) return block;
    return null;
}

test "native feed retains exact content and Host identity independently of display" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var feed: Self = .{};
    defer feed.deinit(std.testing.allocator);
    const original = "private\x1b[31m bytes\n";
    const content = observations.Block{
        .kind = .assistant,
        .position = 42,
        .ordinal = 0,
        .reference = .{ .length = original.len, .digest = @import("protocol.zig").contentDigest(original) },
        .source = original,
        .display = "private bytes\n",
    };
    try feed.append(std.testing.allocator, arena.allocator(), &.{content});
    const retained = feed.sourceAt(42, 0).?;
    try std.testing.expectEqualStrings(original, retained.source);
    try std.testing.expectEqualDeep(content.reference, retained.reference);
    try std.testing.expectEqualStrings("Assistant\nprivate bytes\n\n", feed.widgets.items[0].text);
    try std.testing.expect(feed.sourceAt(42, 1) == null);
}
