//! Retained Host identities and exact content are distinct from Text widgets.
const std = @import("std");
const fw = @import("vaxis").vxfw;
const observations = @import("NativeObservations.zig");
const markdown = @import("markdown_prefix.zig");
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
    var widgets: std.ArrayList(fw.Text) = .empty;
    for (blocks) |block| {
        try widgets.append(arena, .{ .text = if (block.kind == .user) "You\n" else "Assistant\n" });
        try appendDisplay(&widgets, arena, block.display);
        try widgets.append(arena, .{ .text = " \n" });
    }
    try self.sources.ensureUnusedCapacity(allocator, blocks.len);
    try self.widgets.ensureUnusedCapacity(allocator, widgets.items.len);
    self.sources.appendSliceAssumeCapacity(blocks);
    self.widgets.appendSliceAssumeCapacity(widgets.items);
}

fn appendDisplay(widgets: *std.ArrayList(fw.Text), arena: std.mem.Allocator, display: []const u8) !void {
    var context: markdown.Context = .plain;
    var at: usize = 0;
    var segment_start: usize = 0;
    var previous: ?markdown.Context.Mode = null;
    while (at < display.len) {
        const end = if (std.mem.indexOfScalarPos(u8, display, at, '\n')) |i| i else display.len;
        const line = display[at..end];
        const head = line[0..@min(line.len, markdown.head_limit)];
        const ending: markdown.HeadEnding = if (head.len == markdown.head_limit) .limit_cut else if (end < display.len) .line_feed else .canonical_eof;
        const result = context.step(head, ending);
        const decision = switch (result) {
            .resolved => |value| value,
            .need_more => unreachable,
        };
        const mode = decision.projection.mode;
        if (previous) |last| if (last != mode) {
            try widgets.append(arena, .{ .text = display[segment_start..at], .softwrap = last == .prose });
            segment_start = at;
        };
        previous = mode;
        context = decision.next;
        at = if (end < display.len) end + 1 else end;
    }
    if (previous) |last| try widgets.append(arena, .{ .text = display[segment_start..], .softwrap = last == .prose });
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
    try std.testing.expectEqualStrings("Assistant\n", feed.widgets.items[0].text);
    try std.testing.expectEqualStrings("private bytes\n", feed.widgets.items[1].text);
    try std.testing.expect(feed.sourceAt(42, 1) == null);
}

test "native feed keeps prose wrapped and fenced source horizontally scrollable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var feed: Self = .{};
    defer feed.deinit(std.testing.allocator);
    const source = "before prose\n```zig\nlong-\x1b[31mcode-line\n```\nafter prose";
    const display = "before prose\n```zig\nlong-code-line\n```\nafter prose";
    try feed.append(std.testing.allocator, arena.allocator(), &.{.{
        .kind = .assistant,
        .position = 1,
        .ordinal = 0,
        .reference = .{ .length = source.len, .digest = @import("protocol.zig").contentDigest(source) },
        .source = source,
        .display = display,
    }});
    try std.testing.expect(feed.widgets.items[1].softwrap);
    try std.testing.expect(!feed.widgets.items[2].softwrap);
    try std.testing.expect(feed.widgets.items[3].softwrap);
    try std.testing.expectEqualStrings(source, feed.sourceAt(1, 0).?.source);
}
