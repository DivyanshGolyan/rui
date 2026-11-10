//! The `?` shortcuts: the Session's Keys from the table /help shows, packed
//! into a few rows that float above the composer. Reference only: nothing
//! here is clickable, and the next key closes it.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const chrome = @import("session_chrome.zig");
const Chip = @import("Chip.zig");
const Self = @This();

method: vaxis.gwidth.Method = .unicode,
style: vaxis.Style = .{},

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .drawFn = draw };
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const max = ctx.max.size();
    if (max.width < 2) return vxfw.Surface.init(ctx.arena, self.widget(), .{});
    const buffer = try ctx.arena.create([chrome.shortcuts_bytes]u8);
    // One cell of margin on the left, as the palette sets it.
    const text = chrome.shortcuts(buffer, max.width - 1, self.method);
    const lines: u16 = @intCast(std.mem.count(u8, text, "\n") + 1);
    const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = max.width, .height = @min(lines, max.height) });
    @memset(surface.buffer, .{ .style = self.style });
    var rows = std.mem.splitScalar(u8, text, '\n');
    var row: u16 = 0;
    while (rows.next()) |line| : (row += 1) _ = Chip.print(surface, self.method, 1, row, line, self.style, max.width);
    return surface;
}

test "the ? shortcuts float the Keys table in a few rows that fit the screen" {
    var shortcuts: Self = .{ .style = .{ .fg = .{ .index = 8 } } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const drawn = try shortcuts.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 10 }, .cell_size = .{} });
    try std.testing.expectEqual(vxfw.Size{ .width = 80, .height = 3 }, drawn.size);
    try std.testing.expectEqualStrings(" ", drawn.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("e", drawn.readCell(1, 0).char.grapheme);
    // The last binding, `? shortcuts`, starts the third row.
    try std.testing.expectEqualStrings("?", drawn.readCell(1, 2).char.grapheme);
    try std.testing.expectEqualStrings("s", drawn.readCell(3, 2).char.grapheme);
    try std.testing.expectEqual(vaxis.Color{ .index = 8 }, drawn.readCell(79, 1).style.fg);
    const narrow = try shortcuts.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 4 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(u16, 4), narrow.size.height);
    for ([_]vxfw.Size{ .{ .width = 0, .height = 4 }, .{ .width = 1, .height = 1 }, .{ .width = 4, .height = 0 } }) |size| {
        const tiny = try shortcuts.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{} });
        try std.testing.expect(tiny.size.width <= size.width and tiny.size.height <= size.height);
    }
}
