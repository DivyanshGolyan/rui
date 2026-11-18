const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const Palette = @import("Palette.zig");
const slash_menu = @import("slash_menu.zig");
const skill_completion = @import("skill_completion.zig");
const widget_style = @import("widget_style.zig");
const skill_suggestions = @import("skill_suggestions.zig");

fn rowText(surface: vxfw.Surface, row: u16, out: []u8) []const u8 {
    var used: usize = 0;
    for (surface.buffer[@as(usize, row) * surface.size.width + 2 ..][0 .. surface.size.width - 4]) |cell| {
        const grapheme = if (cell.char.grapheme.len == 0) " " else cell.char.grapheme;
        @memcpy(out[used..][0..grapheme.len], grapheme);
        used += grapheme.len;
    }
    return std.mem.trimEnd(u8, out[0..used], " ");
}

test "the Palette draws a /word's skill rows with their descriptions" {
    const entries = [_]skill_suggestions.Entry{
        .{ .name = "recap", .description = "Summarise" },
        .{ .name = "review", .description = "Review a change" },
        .{ .name = "rewrite", .description = "Rewrite a file" },
    };
    var reads: skill_completion.Reads = .{};
    _ = reads.ask("re").?;
    _ = reads.answer(1, .{ .entries = &entries, .total = entries.len }, "rev");
    const draft = "please /rev this";
    var menu: slash_menu.Menu = .{};
    const shown = menu.frame(.{ .draft = .{ .bytes = draft, .caret = "please /rev".len, .revision = 1, .skills = &reads } }).?;
    var palette: Palette = .{ .menu = &menu };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 5 }, .cell_size = .{} };
    const surface = try palette.widget().draw(ctx);
    try std.testing.expectEqual(.drawn, shown.seen);
    try std.testing.expectEqual(@as(u16, 1), surface.size.height);
    var text: [160]u8 = undefined;
    try std.testing.expectEqualStrings("/review  Review a change", rowText(surface, 0, &text));
    try std.testing.expectEqual(widget_style.of(palette.caps, .{ .background = .selection }), surface.readCell(0, 0).style);
    try std.testing.expectEqual(widget_style.of(palette.caps, .{ .bold = true, .background = .selection }), surface.readCell(11, 0).style);
    _ = menu.frame(.{ .draft = .{ .bytes = "please /re this", .caret = "please /re".len, .revision = 2, .skills = &reads } });
    const wider = try palette.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 3), wider.size.height);
    try std.testing.expectEqualStrings("/recap    Summarise", rowText(wider, 0, &text));
    try std.testing.expectEqualStrings("/rewrite  Rewrite a file", rowText(wider, 2, &text));
}

test "the Palette bolds each row's match, in both its name and its description, day and night" {
    const view = @import("overview_view.zig");
    const entries = [_]skill_suggestions.Entry{
        .{ .name = "review-help", .description = "Help review a pull request" },
        .{ .name = "triage", .description = "Ask for help sorting issues" },
    };
    for ([_]?view.Rgb{ .{ 255, 255, 255 }, null }) |terminal| {
        for ([_]view.Caps.Depth{ .direct, .indexed, .none }) |depth| {
            const caps: view.Caps = .{ .background = terminal, .depth = depth };
            var reads: skill_completion.Reads = .{};
            _ = reads.answer(reads.ask("").?.read, .{ .entries = &entries, .total = entries.len }, "");
            var menu: slash_menu.Menu = .{};
            const shown = menu.frame(.{ .draft = .{ .bytes = "/help", .caret = 5, .revision = 1, .skills = &reads } }).?;
            var palette: Palette = .{ .menu = &menu };
            palette.setCaps(caps);
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 60, .height = 5 }, .cell_size = .{} };
            const surface = try palette.widget().draw(ctx);
            var text: [240]u8 = undefined;
            const column = shown.list.descriptionColumn();
            try std.testing.expect(std.mem.startsWith(u8, rowText(surface, 0, &text), "/review-help"));
            try std.testing.expect(std.mem.startsWith(u8, rowText(surface, 1, &text), "/triage"));
            const selected_plain = widget_style.of(caps, .{ .background = .selection });
            const selected_strong = widget_style.of(caps, .{ .bold = true, .background = .selection });
            const strong = widget_style.of(caps, .{ .bold = true, .background = .ground });
            // `/review-help`: both occurrences of `help` bold, the rest plain.
            for (0.."/review-help".len) |col| {
                const cell = surface.readCell(@intCast(col + 2), 0);
                try std.testing.expectEqual(col >= "/review-".len, cell.style.bold);
                try std.testing.expectEqual(if (cell.style.bold) selected_strong else selected_plain, cell.style);
            }
            for (0.."Help review".len) |col| try std.testing.expectEqual(if (col < 4) selected_strong else selected_plain, surface.readCell(@intCast(column + 2 + col), 0).style);
            // `/triage`: the name plain, `help` in its description bold.
            for (0.."/triage".len) |col| try std.testing.expect(!surface.readCell(@intCast(col + 2), 1).style.bold);
            const at = column + "Ask for ".len;
            for (0..column + "Ask for help sorting".len) |col| {
                const cell = surface.readCell(@intCast(col + 2), 1);
                const inside = col >= at and col < at + "help".len;
                try std.testing.expectEqual(inside, cell.style.bold);
                if (inside) try std.testing.expectEqual(strong.fg, cell.style.fg);
            }
        }
    }
}

test "the Palette maps description matches through normalization and clipping without styling the ellipsis" {
    const view = @import("overview_view.zig");
    const vaxis = @import("vaxis");
    const Case = struct {
        source: []const u8,
        room: u16,
        unicode_text: []const u8,
        ascii_text: []const u8,
        unicode_start: usize,
        ascii_start: usize,
        unicode_bold: usize,
        ascii_bold: usize,
    };
    // Display strings and cell intervals are independent of the fitter's result.
    const cases = [_]Case{
        .{ .source = "界 Verify the project", .room = 40, .unicode_text = "界 Verify the project", .ascii_text = "? Verify the project", .unicode_start = 3, .ascii_start = 2, .unicode_bold = 6, .ascii_bold = 6 },
        .{ .source = "界 Verify the project", .room = 12, .unicode_text = "界 Verify t…", .ascii_text = "? Verify th.", .unicode_start = 3, .ascii_start = 2, .unicode_bold = 6, .ascii_bold = 6 },
        .{ .source = "界 Verify the project", .room = 7, .unicode_text = "界 Ver…", .ascii_text = "? Veri.", .unicode_start = 3, .ascii_start = 2, .unicode_bold = 3, .ascii_bold = 4 },
        .{ .source = "界 Verify the project", .room = 2, .unicode_text = "…", .ascii_text = "?.", .unicode_start = 0, .ascii_start = 0, .unicode_bold = 0, .ascii_bold = 0 },
        .{ .source = "\t\x01\tVerify the project", .room = 40, .unicode_text = " ? Verify the project", .ascii_text = " ? Verify the project", .unicode_start = 3, .ascii_start = 3, .unicode_bold = 6, .ascii_bold = 6 },
        .{ .source = "\t\x01\tVerify the project", .room = 12, .unicode_text = " ? Verify t…", .ascii_text = " ? Verify t.", .unicode_start = 3, .ascii_start = 3, .unicode_bold = 6, .ascii_bold = 6 },
        .{ .source = "\t\x01\tVerify the project", .room = 7, .unicode_text = " ? Ver…", .ascii_text = " ? Ver.", .unicode_start = 3, .ascii_start = 3, .unicode_bold = 3, .ascii_bold = 3 },
        .{ .source = "\t\x01\tVerify the project", .room = 2, .unicode_text = " …", .ascii_text = " .", .unicode_start = 0, .ascii_start = 0, .unicode_bold = 0, .ascii_bold = 0 },
    };
    for ([_]?view.Rgb{ .{ 255, 255, 255 }, null }) |terminal| {
        for ([_]view.Caps.Depth{ .direct, .indexed, .none }) |depth| {
            for (std.enums.values(vaxis.gwidth.Method)) |method| for ([_]bool{ true, false }) |unicode| {
                const caps: view.Caps = .{ .background = terminal, .depth = depth, .width = method, .unicode = unicode };
                for (cases) |case| for (0..2) |selected| {
                    const entries = [_]skill_suggestions.Entry{
                        .{ .name = "alpha", .description = case.source },
                        .{ .name = "beta", .description = case.source },
                    };
                    var reads: skill_completion.Reads = .{};
                    _ = reads.answer(reads.ask("verify").?.read, .{ .entries = &entries, .total = entries.len }, "verify");
                    const draft = "use /verify";
                    var menu: slash_menu.Menu = .{};
                    const shown = menu.frame(.{ .draft = .{ .bytes = draft, .caret = draft.len, .revision = 1, .skills = &reads } }).?;
                    shown.highlight = selected;
                    var palette: Palette = .{ .menu = &menu };
                    palette.setCaps(caps);
                    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                    defer arena.deinit();
                    const column = shown.list.descriptionColumn();
                    const width: u16 = @intCast(column + case.room + 4);
                    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 4 }, .cell_size = .{} };
                    const surface = try palette.widget().draw(ctx);
                    try std.testing.expectEqual(@as(u16, 2), surface.size.height);
                    const mark_start = if (unicode) case.unicode_start else case.ascii_start;
                    const mark_len = if (unicode) case.unicode_bold else case.ascii_bold;
                    for (0..2) |row| {
                        const background: view.Background = if (row == selected) .selection else .ground;
                        const plain = widget_style.of(caps, .{ .background = background });
                        const strong = widget_style.of(caps, .{ .background = background, .bold = true });
                        for (0..width) |col| {
                            const inside = col >= column + 2 + mark_start and col < column + 2 + mark_start + mark_len;
                            try std.testing.expectEqual(if (inside) strong else plain, surface.readCell(@intCast(col), @intCast(row)).style);
                        }
                        var text: std.Io.Writer.Allocating = .init(arena.allocator());
                        var col: usize = column + 2;
                        while (col < width - 2) {
                            const cell = surface.readCell(@intCast(col), @intCast(row));
                            try text.writer.writeAll(if (cell.char.grapheme.len == 0) " " else cell.char.grapheme);
                            col += @max(1, cell.char.width);
                        }
                        try std.testing.expectEqualStrings(if (unicode) case.unicode_text else case.ascii_text, std.mem.trimEnd(u8, text.written(), " "));
                    }
                };
            };
        }
    }
}
