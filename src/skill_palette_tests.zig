//! The floating Palette drawing skill rows the composer's core built.
const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const Palette = @import("Palette.zig");
const skill_completion = @import("skill_completion.zig");
const skill_suggestions = @import("skill_suggestions.zig");

fn rowText(surface: vxfw.Surface, row: u16, out: []u8) []const u8 {
    var used: usize = 0;
    for (surface.buffer[@as(usize, row) * surface.size.width ..][0..surface.size.width]) |cell| {
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
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 5 }, .cell_size = .{} };
    const surface = try palette.widget().draw(ctx);
    try std.testing.expectEqual(.drawn, shown.seen);
    try std.testing.expectEqual(@as(u16, 1), surface.size.height);
    var text: [160]u8 = undefined;
    try std.testing.expectEqualStrings("/review  Review a change", rowText(surface, 0, &text));
    try std.testing.expect(surface.readCell(0, 0).style.reverse);
    try std.testing.expect(surface.readCell(9, 0).style.dim);
    // Backing up to `/re` lists all three from the same page; descriptions
    // start two columns past the widest name, `/rewrite`.
    shown = reads.shown(&rows, "please /re this", "please /re".len, 2, .{}, shown).?;
    const wider = try palette.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 3), wider.size.height);
    try std.testing.expectEqualStrings("/recap    Summarise", rowText(wider, 0, &text));
    try std.testing.expectEqualStrings("/rewrite  Rewrite a file", rowText(wider, 2, &text));
}
