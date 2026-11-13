//! The shared plain-text input surface. The screen routes keys through the
//! editor and owns submission; this widget owns only the visible draft rows.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Editor = @import("TerminalEditor.zig");
const layout = @import("draft_layout.zig");
const viewport = @import("ConversationViewport.zig");
const Self = @This();
const view = @import("overview_view.zig");
const widget_style = @import("widget_style.zig");

editor: *const Editor,
method: vaxis.gwidth.Method = .unicode,
style: vaxis.Style = .{},
quiet: vaxis.Style = .{ .dim = true },
rule_style: vaxis.Style = .{ .dim = true },
placeholder: []const u8 = "",
anchor: usize = 0,
/// Draw rules, marks and the prompt in ASCII, for a terminal without
/// Unicode.
ascii: bool = false,
/// Show the terminal's cursor at the caret; false while keys cannot edit.
caret: bool = true,

/// Both New Session and chat use the same draft surface, independent of focus.
pub fn setCaps(self: *Self, caps: view.Caps) void {
    self.style = widget_style.of(caps, .{ .background = .input_surface });
    self.quiet = widget_style.of(caps, .{ .colour = .quiet, .background = .input_surface });
    self.rule_style = widget_style.of(caps, .{ .colour = .quiet });
    self.method = caps.width;
    self.ascii = !caps.unicode;
}

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

fn event(_: *anyopaque, _: *vxfw.EventContext, _: vxfw.Event) !void {}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const width = ctx.max.width.?;
    const height = ctx.max.height.?;
    if (width == 0 or height == 0) return vxfw.Surface.init(ctx.arena, self.widget(), .{});
    const rule: u16 = if (height >= 3) 1 else 0;
    // One column of margin, as every line of the screen has, then the mark.
    const prefix: u16 = if (width >= 4) 3 else 0;
    const draft = try ctx.arena.dupe(u8, self.editor.buffer[0..self.editor.length]);
    for (draft) |*byte| if (byte.* == '\t') {
        byte.* = ' ';
    };
    const pieces: viewport.DraftPieces = .{ .bytes = draft, .method = self.method };
    const shape = layout.shape(pieces, width - prefix, self.editor.cursor, self.anchor);
    var lines: [layout.max_rows]layout.Line = undefined;
    const shown = layout.fit(pieces, width - prefix, self.editor.cursor, shape, height - 2 * rule, &lines);
    self.anchor = lines[0].start;
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = shown.rows + 2 * rule });
    @memset(surface.buffer, .{ .style = self.style });
    var screen: vaxis.Screen = .{
        .width = surface.size.width,
        .height = surface.size.height,
        .width_method = self.method,
        .buf = surface.buffer,
    };
    const window: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
    };
    if (rule != 0) for (0..width) |column| {
        const cell: vaxis.Cell = .{ .char = .{ .grapheme = if (self.ascii) "-" else "─", .width = 1 }, .style = self.rule_style };
        surface.writeCell(@intCast(column), 0, cell);
        surface.writeCell(@intCast(column), surface.size.height - 1, cell);
    };
    const label_storage = try ctx.arena.create([64]u8);
    const label = layout.label(label_storage, shown, if (self.ascii) .{ .up = "^", .down = "v", .dot = "-" } else .{ .up = "↑", .down = "↓", .dot = "·" });
    if (rule != 0) if (layout.labelColumn(vaxis.gwidth.gwidth(label, self.method), width)) |column| {
        _ = window.child(.{ .x_off = @intCast(column), .height = 1 }).printSegment(.{ .text = label, .style = self.rule_style }, .{ .wrap = .none });
    };
    for (lines[0..shown.rows], 0..) |line, index| {
        const row: u16 = @intCast(index + rule);
        if (prefix != 0) _ = window.child(.{ .y_off = row, .height = 1, .width = prefix }).printSegment(.{
            .text = if (shown.first + index != 0) "   " else if (self.ascii) " > " else " › ",
            .style = if (self.caret) self.style else self.quiet,
        }, .{ .wrap = .none });
        _ = window.child(.{ .x_off = prefix, .y_off = row, .height = 1 }).printSegment(.{
            .text = if (draft.len == 0) self.placeholder else draft[line.start..line.end],
            .style = if (draft.len == 0) self.quiet else self.style,
        }, .{ .wrap = .none });
    }
    if (self.caret) surface.cursor = .{ .row = @intCast(shape.caret_line - shown.first + rule), .col = shape.caret_column + prefix };
    return surface;
}

test "Composer keeps the caret visible between rules without changing draft bytes" {
    var bytes = "one\ntwo\nthree\nfour\nfive\nsix".*;
    var editor: Editor = .{ .buffer = &bytes, .length = bytes.len, .cursor = bytes.len };
    var composer: Self = .{ .editor = &editor };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 5 }, .cell_size = .{} };
    const tail = try composer.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 5), tail.size.height);
    try std.testing.expectEqualStrings("f", tail.readCell(3, 1).char.grapheme);
    try std.testing.expectEqualStrings("s", tail.readCell(3, 3).char.grapheme);
    try std.testing.expectEqual(@as(u16, 3), tail.cursor.?.row);
    try std.testing.expectEqual(@as(u16, 6), tail.cursor.?.col);
    try std.testing.expectEqualStrings("─", tail.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("─", tail.readCell(0, 4).char.grapheme);
    editor.cursor = 0;
    const head = try composer.widget().draw(ctx.withConstraints(.{}, .{ .width = 8, .height = 5 }));
    try std.testing.expectEqualStrings("›", head.readCell(1, 1).char.grapheme);
    try std.testing.expectEqualStrings(" ", head.readCell(0, 1).char.grapheme);
    try std.testing.expectEqualStrings("o", head.readCell(3, 1).char.grapheme);
    try std.testing.expectEqual(@as(u16, 1), head.cursor.?.row);
    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour\nfive\nsix", &bytes);
}

test "Composer draws between paste fragments that join the original suffix" {
    const keys: @import("keymap.zig").Keymap(void) = comptime .{ .meanings = .initFill(null) };
    for ([_]struct { initial: []const u8, first: []const u8, second: []const u8, expected: []const u8 }{
        .{ .initial = "L👩TAIL", .first = "👨‍", .second = "👧", .expected = "L👨‍👧👩TAIL" },
        .{ .initial = "L🇧TAIL", .first = "🇦", .second = "🇨", .expected = "L🇦🇨🇧TAIL" },
    }) |case| {
        var bytes: [64]u8 = undefined;
        @memcpy(bytes[0..case.initial.len], case.initial);
        var editor: Editor = .{ .buffer = &bytes, .length = case.initial.len, .cursor = 1 };
        var composer: Self = .{ .editor = &editor };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 8 }, .cell_size = .{} };
        _ = editor.appEvent(keys, .paste_start, true);
        _ = editor.appEvent(keys, .{ .key_press = .{ .codepoint = 0, .text = case.first } }, true);
        const joined = try composer.widget().draw(ctx);
        try std.testing.expectEqual(@as(u16, 6), joined.cursor.?.col);
        _ = editor.appEvent(keys, .{ .key_press = .{ .codepoint = 0, .text = case.second } }, true);
        const continued = try composer.widget().draw(ctx);
        try std.testing.expectEqualStrings(case.expected, bytes[0..editor.length]);
        try std.testing.expectEqual(@as(u16, 6), continued.cursor.?.col);
        _ = editor.appEvent(keys, .paste_end, false);
        const ended = try composer.widget().draw(ctx);
        try std.testing.expectEqualDeep(continued.cursor, ended.cursor);
        try std.testing.expectEqualStrings(case.expected, bytes[0..editor.length]);
    }
}

test "Composer empty draft shows the screen's placeholder and an input cursor" {
    var bytes: [32]u8 = undefined;
    const editor: Editor = .{ .buffer = &bytes };
    var composer: Self = .{ .editor = &editor, .placeholder = "Type a task", .style = .{ .bg = .{ .index = 19 } }, .quiet = .{ .dim = true, .bg = .{ .index = 19 } } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const surface = try composer.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 10 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(u16, 3), surface.size.height);
    try std.testing.expectEqualStrings("T", surface.readCell(3, 1).char.grapheme);
    try std.testing.expect(surface.readCell(3, 1).style.dim);
    try std.testing.expectEqual(@as(u16, 3), surface.cursor.?.col);
    try std.testing.expectEqual(@as(usize, 0), editor.length);
    for (0..surface.size.width) |col| try std.testing.expectEqual(vaxis.Color{ .index = 19 }, surface.readCell(col, 1).style.bg);
}

test "Composer clips wide text at every small size without moving its logical caret" {
    var bytes = "中e\u{0301}\n👩‍💻end".*;
    var editor: Editor = .{ .buffer = &bytes, .length = bytes.len };
    var composer: Self = .{ .editor = &editor };
    for ([_]usize{ 0, "中".len, "中e\u{0301}\n".len, bytes.len }) |cursor| {
        editor.cursor = cursor;
        for (0..6) |width| for (0..6) |height| {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const surface = try composer.widget().draw(.{
                .arena = arena.allocator(),
                .min = .{},
                .max = .{ .width = @intCast(width), .height = @intCast(height) },
                .cell_size = .{},
            });
            try std.testing.expect(surface.size.width <= width and surface.size.height <= height);
            if (width == 0 or height == 0) {
                try std.testing.expectEqual(@as(usize, 0), surface.buffer.len);
                try std.testing.expectEqual(null, surface.cursor);
            } else {
                try std.testing.expect(surface.cursor.?.col < width and surface.cursor.?.row < height);
            }
            try std.testing.expectEqual(cursor, editor.cursor);
            try std.testing.expectEqualStrings("中e\u{0301}\n👩‍💻end", editor.buffer[0..editor.length]);
        };
    }
}

test "Composer empty chat shows only its prompt and rules" {
    var bytes: [16]u8 = undefined;
    const editor: Editor = .{ .buffer = &bytes };
    var composer: Self = .{ .editor = &editor };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u16{ 140, 46 }) |width| {
        const shown = try composer.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 3 }, .cell_size = .{} });
        try std.testing.expectEqual(@as(u16, 3), shown.size.height);
        try std.testing.expectEqualStrings("›", shown.readCell(1, 1).char.grapheme);
        for (3..width) |col| try std.testing.expectEqualStrings(" ", shown.readCell(col, 1).char.grapheme);
        try std.testing.expectEqual(@as(u16, 3), shown.cursor.?.col);
    }
}

test "Composer inactive prompt uses quiet style and no caret without dimming draft text" {
    var bytes = "draft".*;
    const editor: Editor = .{ .buffer = &bytes, .length = bytes.len, .cursor = 0 };
    var composer: Self = .{ .editor = &editor, .style = .{}, .quiet = .{ .dim = true } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 5 }, .cell_size = .{} };
    const focused = try composer.widget().draw(ctx);
    try std.testing.expect(focused.cursor != null);
    try std.testing.expect(!focused.readCell(1, 1).style.dim);
    composer.caret = false;
    const inactive = try composer.widget().draw(ctx);
    try std.testing.expect(inactive.cursor == null);
    try std.testing.expect(inactive.readCell(1, 1).style.dim);
    try std.testing.expect(!inactive.readCell(3, 1).style.dim);
}

test "Composer surface role covers New Session and chat drafts in both themes and widths" {
    var bytes = "first\nsecond\nthird".*;
    var editor: Editor = .{ .buffer = &bytes };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]?view.Rgb{ null, .{ 255, 255, 255 } }) |background| {
        for ([_]view.Caps.Depth{ .direct, .indexed, .none }) |depth| {
            const caps: view.Caps = .{ .background = background, .depth = depth };
            const input = widget_style.of(caps, .{ .background = .input_surface });
            const ground = widget_style.of(caps, .{ .colour = .quiet });
            for ([_]u16{ 140, 46 }) |width| for ([_][]const u8{ "Type a task", "" }) |placeholder| {
                for ([_]bool{ false, true }) |has_draft| for ([_]bool{ false, true }) |caret| {
                    editor.length = if (has_draft) bytes.len else 0;
                    editor.cursor = editor.length;
                    var composer: Self = .{ .editor = &editor, .placeholder = placeholder, .caret = caret };
                    composer.setCaps(caps);
                    const surface = try composer.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 10 }, .cell_size = .{} });
                    try std.testing.expectEqual(@as(u16, if (has_draft) 5 else 3), surface.size.height);
                    for (0..width) |col| {
                        for (1..surface.size.height - 1) |row| try std.testing.expectEqual(input.bg, surface.readCell(col, row).style.bg);
                        try std.testing.expectEqual(ground.bg, surface.readCell(col, 0).style.bg);
                        try std.testing.expectEqual(ground.bg, surface.readCell(col, surface.size.height - 1).style.bg);
                    }
                    try std.testing.expectEqual(caret, surface.cursor != null);
                };
            };
        }
    }
}
