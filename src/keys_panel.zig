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
    const surface = try reference.widget().draw(.{ .arena = allocator, .min = .{}, .max = .{ .width = width, .height = 10 }, .cell_size = .{} });
    var output: std.Io.Writer.Allocating = .init(allocator);
    for (0..surface.size.height) |row| {
        var line: std.Io.Writer.Allocating = .init(allocator);
        for (0..surface.size.width) |col| try line.writer.writeAll(surface.readCell(@intCast(col), @intCast(row)).char.grapheme);
        try output.writer.writeAll(std.mem.trimEnd(u8, line.written(), " "));
        try output.writer.writeByte('\n');
    }
    return output.written();
}

test "Keys panel has only key meanings and strong keys at 140 and 46 columns" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u16{ 140, 46 }) |width| {
        const rendered = try text(arena.allocator(), width);
        std.debug.print("\nKeys panel at {d} columns:\n{s}", .{ width, rendered });
        const first = if (width == 140) " enter  send                 esc/ctrl+g back\n" else " enter  send            esc/ctrl+g back\n";
        try std.testing.expect(std.mem.startsWith(u8, rendered, first));
        for ([_][]const u8{ "new line", "earlier message", "ctrl+x", "stop", "tool output", "retry", "archive", "skills", "first session", "latest / last" }) |expected| try std.testing.expect(std.mem.indexOf(u8, rendered, expected) != null);
        for ([_][]const u8{ "/help", "Ctrl-X twice", "?", "Commands", "Marks", "press", "close" }) |absent| try std.testing.expect(std.mem.indexOf(u8, rendered, absent) == null);
        var reference = panel(.{});
        const surface = try reference.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 10 }, .cell_size = .{} });
        try std.testing.expect(surface.readCell(1, 0).style.bold);
        try std.testing.expect(!surface.readCell(8, 0).style.bold);
    }
}
