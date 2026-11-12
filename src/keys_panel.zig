//! The app's keys-only reference. The keymap owns the rows; Panel owns cells.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Panel = @import("widgets/Panel.zig");
const keymap = @import("keymap.zig");
const widget_style = @import("widget_style.zig");
const view = @import("overview_view.zig");

const fields = blk: {
    var rows: [keymap.list.len]Panel.Field = undefined;
    for (keymap.list, 0..) |row, index| rows[index] = .{ .label = row.key, .value = row.meaning };
    break :blk rows;
};

/// A borrowed widget: the caller owns this value for the drawn frame.
pub fn panel(caps: view.Caps) Panel.KeyList {
    return .{
        .fields = &fields,
        .ground = widget_style.of(caps, .{ .background = .bar }),
        .strong = widget_style.of(caps, .{ .background = .bar, .colour = .strong, .bold = true }),
    };
}

fn text(allocator: std.mem.Allocator, width: u16) ![]const u8 {
    var reference = panel(.{});
    const surface = try reference.widget().draw(.{ .arena = allocator, .min = .{}, .max = .{ .width = width, .height = 11 }, .cell_size = .{} });
    var output: std.Io.Writer.Allocating = .init(allocator);
    for (0..surface.size.height) |row| {
        var line: std.Io.Writer.Allocating = .init(allocator);
        for (0..surface.size.width) |col| try line.writer.writeAll(surface.readCell(@intCast(col), @intCast(row)).char.grapheme);
        try output.writer.writeAll(std.mem.trimEnd(u8, line.written(), " "));
        try output.writer.writeByte('\n');
    }
    return std.mem.trimEnd(u8, output.written(), "\n");
}

test "Keys panel matches the short mock at 140 and falls back to one column at 46" {
    const wide =
        \\ enter    send              esc      back
        \\ ⇧enter   new line          ctrl+x   stop
        \\ ↑↓       scroll            ctrl+o   tool output
        \\ ctrl+p   earlier message   ctrl+r   retry
        \\ /        skills            alt+a    archive
        \\ ctrl+c   leave
    ;
    const narrow =
        \\ enter    send
        \\ esc      back
        \\ ⇧enter   new line
        \\ ctrl+x   stop
        \\ ↑↓       scroll
        \\ ctrl+o   tool output
        \\ ctrl+p   earlier message
        \\ ctrl+r   retry
        \\ /        skills
        \\ alt+a    archive
        \\ ctrl+c   leave
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u16{ 140, 46 }) |width| {
        const rendered = try text(arena.allocator(), width);
        std.debug.print("\nKeys panel at {d} columns:\n{s}\n", .{ width, rendered });
        try std.testing.expectEqualStrings(if (width == 140) wide else narrow, rendered);
        for ([_][]const u8{ "/help", "Ctrl-X twice", "?", "Commands", "Marks", "press", "close", "ctrl+g", "ctrl+d", "ctrl+n", "ctrl+end", "pgup", "pgdn", "home", "latest", "select" }) |absent| try std.testing.expect(std.mem.indexOf(u8, rendered, absent) == null);
    }
}

test "Keys panel aligns strong keys and plain meanings over every width through 160" {
    const labels = [_][]const u8{ "enter", "esc", "⇧enter", "ctrl+x", "↑↓", "ctrl+o", "ctrl+p", "ctrl+r", "/", "alt+a", "ctrl+c" };
    const meanings = [_][]const u8{ "send", "back", "new line", "stop", "scroll", "tool output", "earlier message", "retry", "skills", "archive", "leave" };
    for (0..161) |width| for ([_]u16{ 0, 1, 6, 11, 30 }) |height| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var reference = panel(.{});
        const surface = try reference.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = height }, .cell_size = .{} });
        // The independent mock needs 25 + 2 + 21 cells for both columns.
        const columns: usize = if (width >= 48) 2 else 1;
        for (labels, meanings, 0..) |label, meaning, index| {
            const row = index / columns;
            if (row >= height) break;
            const start: usize = if (index % columns == 0) 0 else 27;
            for ([_]struct { text: []const u8, col: usize, bold: bool }{
                .{ .text = label, .col = start + 1, .bold = true },
                .{ .text = meaning, .col = start + 10, .bold = false },
            }) |part| {
                var col = part.col;
                var iter = std.unicode.Utf8View.initUnchecked(part.text).iterator();
                while (iter.nextCodepointSlice()) |scalar| : (col += 1) {
                    if (col >= width) break;
                    const cell = surface.readCell(@intCast(col), @intCast(row));
                    try std.testing.expectEqualStrings(scalar, cell.char.grapheme);
                    try std.testing.expectEqual(part.bold, cell.style.bold);
                }
            }
        }
    };
}
