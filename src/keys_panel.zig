const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Panel = @import("widgets/Panel.zig");
const keymap = @import("keymap.zig");
const view = @import("overview_view.zig");
const Dialog = @import("Dialog.zig");

const fields = blk: {
    var rows: [keymap.list.len]Panel.Field = undefined;
    for (keymap.list, 0..) |row, index| rows[index] = .{ .label = row.key, .value = row.meaning };
    break :blk rows;
};

/// The keys list in the dialog's full palette, so its selection, hover and quiet tints are the dialog's at every depth.
pub fn panel(caps: view.Caps) Panel.KeyList {
    const look: Dialog.Look = .of(caps);
    return .{
        .fields = &fields,
        .style = .{ .ground = look.ground, .quiet = look.quiet, .selection = look.selection, .hover = look.hover, .title = look.title },
        .strong = look.title,
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
        // The only ? left is the Alt-? question key; the ? shortcuts stay gone.
        try std.testing.expectEqual(std.mem.count(u8, rendered, "alt+?"), std.mem.count(u8, rendered, "?"));
        for ([_][]const u8{ "/help", "Ctrl-X twice", "Commands", "Marks", "press", "close", "ctrl+g", "ctrl+d", "ctrl+n", "ctrl+end", "pgup", "pgdn", "home", "latest", "select", "shift+enter or ctrl+j", "Esc returns", "‹ Rui · settings", "ctrl+c/d", "first session", "scroll / select" }) |absent| try std.testing.expect(std.mem.indexOf(u8, rendered, absent) == null);
    }
}

test "Keys panel aligns strong keys and plain meanings over every width through 160" {
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
        for (surface.buffer, occupied) |cell, used| if (!used) {
            try std.testing.expectEqualStrings(" ", cell.char.grapheme);
            try std.testing.expect(!cell.style.bold);
        };
    };
}

test "SUI-206 the keys panel takes the dialog palette at every colour depth, and a highlight keeps the ground's reverse and underline" {
    var blocks = [_]Panel.Block{ .{ .first = 0, .end = 1 }, .{ .first = 1, .end = 3 } };
    for (std.enums.values(view.Caps.Depth)) |depth| for ([_]bool{ true, false }) |unicode| {
        const caps: view.Caps = .{ .depth = depth, .unicode = unicode };
        const look: Dialog.Look = .of(caps);
        var list = panel(caps);
        try std.testing.expect(std.meta.eql(look.ground, list.style.ground));
        try std.testing.expect(std.meta.eql(look.quiet, list.style.quiet));
        try std.testing.expect(std.meta.eql(look.selection, list.style.selection));
        try std.testing.expect(std.meta.eql(look.hover, list.style.hover));
        try std.testing.expect(std.meta.eql(look.title, list.style.title));
        try std.testing.expect(std.meta.eql(look.title, list.strong));

        list.blocks = &blocks;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        const context: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 60, .height = keymap.list.len }, .cell_size = .{} };
        _ = try list.widget().draw(context);
        try list.widget().handleEvent(&events, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
        try list.widget().handleEvent(&events, .{ .mouse = .{ .button = .none, .type = .motion, .mods = .{}, .row = 0, .col = 5 } });
        const surface = try list.widget().draw(context);
        try std.testing.expectEqual(@as(usize, 1), list.selected);

        const selected = surface.readCell(0, 1).style;
        try std.testing.expect(std.meta.eql(look.selection.bg, selected.bg));
        try std.testing.expectEqual(look.ground.reverse or look.selection.reverse, selected.reverse);
        if (depth == .none) try std.testing.expect(selected.reverse);

        const hovered = surface.readCell(0, 0).style;
        try std.testing.expect(std.meta.eql(look.hover.bg, hovered.bg));
        try std.testing.expectEqual(look.hover.ul_style, hovered.ul_style);
        if (depth == .none) try std.testing.expectEqual(vaxis.Style.Underline.single, hovered.ul_style);

        const plain = surface.readCell(0, 3).style;
        try std.testing.expect(std.meta.eql(look.ground.bg, plain.bg));
        try std.testing.expectEqual(look.ground.reverse, plain.reverse);
        try std.testing.expectEqual(look.ground.ul_style, plain.ul_style);
    };
}
