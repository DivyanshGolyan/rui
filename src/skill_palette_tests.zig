//! The floating Palette drawing skill rows the composer's core built.
const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const Palette = @import("Palette.zig");
const skill_completion = @import("skill_completion.zig");
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
    var rows: skill_completion.Rows = .{};
    const draft = "please /rev this";
    var shown = reads.shown(&rows, draft, "please /rev".len, 1, .{}, null).?;
    var palette: Palette = .{ .shown = &shown };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 5 }, .cell_size = .{} };
    const surface = try palette.widget().draw(ctx);
    try std.testing.expectEqual(.drawn, shown.seen);
    try std.testing.expectEqual(@as(u16, 3), surface.size.height);
    var text: [160]u8 = undefined;
    try std.testing.expectEqualStrings("/review  Review a change", rowText(surface, 1, &text));
    try std.testing.expect(surface.readCell(2, 1).style.reverse);
    try std.testing.expectEqual(surface.readCell(2, 1).style.reverse, surface.readCell(11, 1).style.reverse);
    // Backing up to `/re` lists all three from the same page; descriptions
    // start two columns past the widest name, `/rewrite`.
    shown = reads.shown(&rows, "please /re this", "please /re".len, 2, .{}, shown).?;
    const wider = try palette.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 5), wider.size.height);
    try std.testing.expectEqualStrings("/recap    Summarise", rowText(wider, 1, &text));
    try std.testing.expectEqualStrings("/rewrite  Rewrite a file", rowText(wider, 3, &text));
}

test "the Palette bolds each row's match, in both its name and its description, day and night" {
    const view = @import("overview_view.zig");
    const widget_style = @import("widget_style.zig");
    const entries = [_]skill_suggestions.Entry{
        .{ .name = "review-help", .description = "Help review a pull request" },
        .{ .name = "triage", .description = "Ask for help sorting issues" },
    };
    for ([_]?view.Rgb{ .{ 255, 255, 255 }, null }) |terminal| {
        const caps: view.Caps = .{ .background = terminal };
        var reads: skill_completion.Reads = .{};
        _ = reads.answer(reads.ask("").?.read, .{ .entries = &entries, .total = entries.len }, "");
        var rows: skill_completion.Rows = .{};
        var shown = reads.shown(&rows, "/help", 5, 1, .{}, null).?;
        var palette: Palette = .{ .shown = &shown };
        palette.setCaps(caps);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 60, .height = 5 }, .cell_size = .{} };
        const surface = try palette.widget().draw(ctx);
        var text: [240]u8 = undefined;
        const column = shown.list.descriptionColumn();
        try std.testing.expect(std.mem.startsWith(u8, rowText(surface, 1, &text), "/review-help"));
        try std.testing.expect(std.mem.startsWith(u8, rowText(surface, 2, &text), "/triage"));
        const strong = widget_style.of(caps, .{ .bold = true, .background = .input_surface });
        // `/review-help`: both occurrences of `help` bold, the rest plain.
        for (0.."/review-help".len) |col| {
            const cell = surface.readCell(@intCast(col + 2), 1);
            try std.testing.expectEqual(col >= "/review-".len, cell.style.bold);
            if (cell.style.bold) try std.testing.expectEqual(strong.fg, cell.style.fg);
        }
        for (0.."Help review".len) |col| try std.testing.expectEqual(col < 4, surface.readCell(@intCast(column + 2 + col), 1).style.bold);
        // `/triage`: the name plain, `help` in its description bold.
        for (0.."/triage".len) |col| try std.testing.expect(!surface.readCell(@intCast(col + 2), 2).style.bold);
        const at = column + "Ask for ".len;
        for (0..column + "Ask for help sorting".len) |col| {
            const cell = surface.readCell(@intCast(col + 2), 2);
            const inside = col >= at and col < at + "help".len;
            try std.testing.expectEqual(inside, cell.style.bold);
            if (inside) try std.testing.expectEqual(strong.fg, cell.style.fg);
        }
    }
}
