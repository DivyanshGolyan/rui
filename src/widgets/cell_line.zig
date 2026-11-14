//! One line of text in terminal cells: only its first line (up to CR or LF),
//! cut before the first grapheme that does not fit. Footer and Panel draw
//! their single-line text through it.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

pub const Fit = struct { text: []const u8, width: u16 };

/// The longest prefix of `text`'s first line that fits `limit` cells, and
/// the cells it takes.
pub fn fit(ctx: vxfw.DrawContext, text: []const u8, limit: u16) Fit {
    return walk(ctx, text, limit, null);
}

/// Paints what `fit` keeps of `text` from column `start` on `row`, within
/// the first `limit` columns, and returns the column after it. A grapheme
/// that takes no cell is not written.
pub fn paint(ctx: vxfw.DrawContext, surface: vxfw.Surface, text: []const u8, start: u16, row: u16, style: vaxis.Style, limit: u16) u16 {
    const col = @min(start, limit);
    return col + walk(ctx, text, limit - col, .{ .surface = surface, .row = row, .col = col, .style = style }).width;
}

const Target = struct { surface: vxfw.Surface, row: u16, col: u16, style: vaxis.Style };

fn walk(ctx: vxfw.DrawContext, text: []const u8, limit: u16, target: ?Target) Fit {
    var iter = ctx.graphemeIterator(text);
    var width: u16 = 0;
    var end: usize = 0;
    while (iter.next()) |part| {
        const grapheme = part.bytes(text);
        if (std.mem.indexOfAny(u8, grapheme, "\r\n") != null) break;
        const cells = ctx.stringWidth(grapheme);
        if (cells > limit - width) break;
        if (target) |into| if (cells != 0) into.surface.writeCell(into.col + width, into.row, .{ .char = .{ .grapheme = grapheme, .width = @intCast(cells) }, .style = into.style });
        width += @intCast(cells);
        end += grapheme.len;
    }
    return .{ .text = text[0..end], .width = width };
}

test "a cell line stops at a line end and before the first grapheme that does not fit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 6, .height = 1 }, .cell_size = .{} };
    try std.testing.expectEqualStrings("ab", fit(ctx, "ab\ncd", 6).text);
    const wide = fit(ctx, "a界b", 2);
    try std.testing.expectEqualStrings("a", wide.text);
    try std.testing.expectEqual(@as(u16, 1), wide.width);
    try std.testing.expectEqual(@as(u16, 4), fit(ctx, "a界b", 4).width);
    const surface = try vxfw.Surface.init(arena.allocator(), undefined, .{ .width = 6, .height = 1 });
    @memset(surface.buffer, .{});
    try std.testing.expectEqual(@as(u16, 5), paint(ctx, surface, "a界bcd", 1, 0, .{}, 5));
    try std.testing.expectEqualStrings("a", surface.readCell(1, 0).char.grapheme);
    try std.testing.expectEqualStrings("界", surface.readCell(2, 0).char.grapheme);
    try std.testing.expectEqualStrings("b", surface.readCell(4, 0).char.grapheme);
    try std.testing.expectEqualStrings(" ", surface.readCell(5, 0).char.grapheme);
    try std.testing.expectEqual(@as(u16, 5), paint(ctx, surface, "x", 7, 0, .{}, 5));
}
