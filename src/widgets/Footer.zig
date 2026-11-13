//! One filled row: a left label and right-aligned state, with the right side taking priority.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Self = @This();

left: []const u8,
right: []const u8,
/// A transient reply replaces the keys, never adding a row.
notice: ?[]const u8 = null,
style: vaxis.Style = .{},
right_style: ?vaxis.Style = null,

pub fn widget(self: *const Self) vxfw.Widget {
    return .{ .userdata = @constCast(self), .drawFn = draw };
}

/// A reply replaces the keys; callers supply display-safe single-line text.
pub fn rightText(self: *const Self) []const u8 {
    return self.notice orelse self.right;
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *const Self = @ptrCast(@alignCast(raw));
    const max = ctx.max.size();
    const size: vxfw.Size = .{ .width = max.width, .height = @min(1, max.height) };
    const surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), size);
    @memset(surface.buffer, .{ .style = self.style });
    if (size.width == 0 or size.height == 0) return surface;
    const right = prefix(ctx, self.rightText(), size.width);
    const right_col = size.width - right.width;
    const left = prefix(ctx, self.left, right_col);
    paint(ctx, surface, left.text, 0, self.style);
    paint(ctx, surface, right.text, right_col, self.right_style orelse self.style);
    return surface;
}

fn prefix(ctx: vxfw.DrawContext, text: []const u8, limit: u16) struct { text: []const u8, width: u16 } {
    var iter = ctx.graphemeIterator(text);
    var width: u16 = 0;
    var end: usize = 0;
    while (iter.next()) |part| {
        const grapheme = part.bytes(text);
        if (std.mem.indexOfAny(u8, grapheme, "\r\n") != null) break;
        const cells = ctx.stringWidth(grapheme);
        if (cells > limit - width) break;
        width += @intCast(cells);
        end += grapheme.len;
    }
    return .{ .text = text[0..end], .width = width };
}

fn paint(ctx: vxfw.DrawContext, surface: vxfw.Surface, text: []const u8, start: u16, style: vaxis.Style) void {
    var iter = ctx.graphemeIterator(text);
    var col = start;
    while (iter.next()) |part| {
        const grapheme = part.bytes(text);
        const width: u8 = @intCast(ctx.stringWidth(grapheme));
        if (width == 0) continue;
        surface.writeCell(col, 0, .{ .char = .{ .grapheme = grapheme, .width = width }, .style = style });
        col += width;
    }
}

test "Footer aligns keys and cuts the label first in terminal cells" {
    var footer: Self = .{ .left = "abcdef", .right = "xy", .style = .{ .bold = true } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 10, .height = 3 }, .cell_size = .{} };
    const drawn = try footer.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 1), drawn.size.height);
    try std.testing.expectEqualStrings("a", drawn.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("x", drawn.readCell(8, 0).char.grapheme);
    try std.testing.expectEqualStrings("y", drawn.readCell(9, 0).char.grapheme);
    for (drawn.buffer) |cell| try std.testing.expect(cell.style.bold);
    const clipped = try footer.widget().draw(ctx.withConstraints(.{}, .{ .width = 4, .height = 1 }));
    for ([_][]const u8{ "a", "b", "x", "y" }, 0..) |expected, col| try std.testing.expectEqualStrings(expected, clipped.readCell(col, 0).char.grapheme);
    const keys_only = try footer.widget().draw(ctx.withConstraints(.{}, .{ .width = 1, .height = 1 }));
    try std.testing.expectEqualStrings("x", keys_only.readCell(0, 0).char.grapheme);
    footer.left = "界e\u{301}q";
    footer.right = "界!";
    const unicode = try footer.widget().draw(ctx.withConstraints(.{}, .{ .width = 6, .height = 1 }));
    try std.testing.expectEqualStrings("界", unicode.readCell(0, 0).char.grapheme);
    try std.testing.expectEqual(@as(u8, 2), unicode.readCell(0, 0).char.width);
    try std.testing.expectEqualStrings("e\u{301}", unicode.readCell(2, 0).char.grapheme);
    try std.testing.expectEqualStrings("界", unicode.readCell(3, 0).char.grapheme);
    try std.testing.expectEqualStrings("!", unicode.readCell(5, 0).char.grapheme);
    for (0..8) |width| for (0..2) |height| {
        const tiny = try footer.widget().draw(ctx.withConstraints(.{}, .{ .width = @intCast(width), .height = @intCast(height) }));
        try std.testing.expect(tiny.size.width <= width and tiny.size.height <= height);
        for (tiny.buffer, 0..) |cell, col| try std.testing.expect(col + cell.char.width <= width);
    };
    footer.left = "";
    footer.right = "";
    const empty = try footer.widget().draw(ctx);
    for (empty.buffer) |cell| try std.testing.expectEqualStrings(" ", cell.char.grapheme);
}

test "Footer notice fits right, truncates in terminal cells, and the next notice replaces it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 32, .height = 4 }, .cell_size = .{} };
    var footer: Self = .{ .left = "Chat", .right = "ctrl+x stop", .notice = "Copied 12 lines" };
    const fitted = try footer.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 1), fitted.size.height);
    for ("Copied 12 lines", 17..) |byte, col| try std.testing.expectEqual(byte, fitted.readCell(col, 0).char.grapheme[0]);
    const clipped = try footer.widget().draw(ctx.withConstraints(.{}, .{ .width = 12, .height = 4 }));
    try std.testing.expectEqual(@as(u16, 1), clipped.size.height);
    for ("Copied 12 li", 0..) |byte, col| try std.testing.expectEqual(byte, clipped.readCell(col, 0).char.grapheme[0]);
    footer.notice = "Copied 3 lines";
    const next = try footer.widget().draw(ctx);
    for ("Copied 3 lines", 18..) |byte, col| try std.testing.expectEqual(byte, next.readCell(col, 0).char.grapheme[0]);
    footer.notice = "界e\u{301}x";
    const unicode = try footer.widget().draw(ctx.withConstraints(.{}, .{ .width = 3, .height = 1 }));
    try std.testing.expectEqualStrings("界", unicode.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("e\u{301}", unicode.readCell(2, 0).char.grapheme);
    footer.notice = null;
    try std.testing.expectEqualStrings("ctrl+x stop", footer.rightText());
}
