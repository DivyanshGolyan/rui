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
    const surface = try reference.widget().draw(.{ .arena = allocator, .cell_arena = allocator, .min = .{}, .max = .{ .width = width, .height = keymap.list.len }, .cell_size = .{} });
    var output: std.Io.Writer.Allocating = .init(allocator);
    for (0..surface.size.height) |row| {
        var line: std.Io.Writer.Allocating = .init(allocator);
        for (0..surface.size.width) |col| try line.writer.writeAll(surface.readCell(@intCast(col), @intCast(row)).char.grapheme);
        try output.writer.writeAll(std.mem.trimEnd(u8, line.written(), " "));
        try output.writer.writeByte('\n');
    }
    return std.mem.trimEnd(u8, output.written(), "\n");
}

test "Keys panel uses every shared key row including both footer navigation directions" {
    const reference = panel(.{});
    try std.testing.expectEqual(keymap.list.len, reference.fields.len);
    var tabs: usize = 0;
    var reverse_tabs: usize = 0;
    for (keymap.list, reference.fields) |row, field| {
        try std.testing.expectEqualStrings(row.key, field.label);
        try std.testing.expectEqualStrings(row.meaning, field.value);
        tabs += @intFromBool(std.mem.eql(u8, row.key, "tab"));
        reverse_tabs += @intFromBool(std.mem.eql(u8, row.key, "⇧tab"));
    }
    try std.testing.expectEqual(@as(usize, 1), tabs);
    try std.testing.expectEqual(@as(usize, 1), reverse_tabs);
}

test "Keys panel renders shared rows in two columns at 140 and one column at 46" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u16{ 140, 46 }) |width| {
        const rendered = try text(arena.allocator(), width);
        const columns: usize = if (width == 140) 2 else 1;
        var lines = std.mem.splitScalar(u8, rendered, '\n');
        var index: usize = 0;
        while (lines.next()) |line| {
            const count = @min(columns, keymap.list.len - index);
            var after: usize = 0;
            for (keymap.list[index..][0..count]) |row| {
                const label = std.mem.indexOfPos(u8, line, after, row.key) orelse return error.TestUnexpectedResult;
                const meaning = std.mem.indexOfPos(u8, line, label + row.key.len, row.meaning) orelse return error.TestUnexpectedResult;
                after = meaning + row.meaning.len;
            }
            index += count;
        }
        try std.testing.expectEqual(keymap.list.len, index);
        for ([_][]const u8{ "/help", "Ctrl-X twice", "?", "Commands", "Marks", "press", "close", "ctrl+g", "ctrl+d", "ctrl+n", "ctrl+end", "pgup", "pgdn", "home", "latest", "select" }) |absent| try std.testing.expect(std.mem.indexOf(u8, rendered, absent) == null);
    }
}

test "Keys panel aligns strong keys and plain meanings over every width through 160" {
    // Text and row count come only from the keymap. The generic Panel owns
    // measured column layout; this boundary checks that its app binding keeps
    // the complete shared table and strong-key/plain-meaning styles.
    var key_widths = [_]usize{ 0, 0 };
    var value_widths = [_]usize{ 0, 0 };
    for (keymap.list, 0..) |row, index| {
        key_widths[index % 2] = @max(key_widths[index % 2], vaxis.gwidth.gwidth(row.key, .unicode));
        value_widths[index % 2] = @max(value_widths[index % 2], vaxis.gwidth.gwidth(row.meaning, .unicode));
    }
    const left_width = 1 + key_widths[0] + 3 + value_widths[0];
    const right_width = 1 + key_widths[1] + 3 + value_widths[1];
    for (0..161) |width| for ([_]u16{ 0, 1, 6, 11, keymap.list.len, 30 }) |height| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var reference = panel(.{});
        const surface = try reference.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = height }, .cell_size = .{} });
        const columns: usize = if (width >= left_width + 2 + right_width) 2 else 1;
        const occupied = try arena.allocator().alloc(bool, width * height);
        @memset(occupied, false);
        for (keymap.list, 0..) |entry, index| {
            const row = index / columns;
            if (row >= height) break;
            const start: usize = if (index % columns == 0) 0 else left_width + 2;
            const key_width = if (columns == 1) @max(key_widths[0], key_widths[1]) else key_widths[index % columns];
            for ([_]struct { text: []const u8, col: usize, bold: bool }{
                .{ .text = entry.key, .col = start + 1, .bold = true },
                .{ .text = entry.meaning, .col = start + 1 + key_width + 3, .bold = false },
            }) |part| {
                var col = part.col;
                var iter = std.unicode.Utf8View.initUnchecked(part.text).iterator();
                while (iter.nextCodepointSlice()) |scalar| : (col += 1) {
                    if (col >= width) break;
                    const cell = surface.readCell(@intCast(col), @intCast(row));
                    occupied[row * width + col] = true;
                    try std.testing.expectEqualStrings(scalar, cell.char.grapheme);
                    try std.testing.expectEqual(part.bold, cell.style.bold);
                }
            }
        }
        // Also cover every gap and unused row, retaining the complete-cell
        // check of the old snapshots without keeping a second text table.
        for (surface.buffer, occupied) |cell, used| if (!used) {
            try std.testing.expectEqualStrings(" ", cell.char.grapheme);
            try std.testing.expect(!cell.style.bold);
        };
    };
}
