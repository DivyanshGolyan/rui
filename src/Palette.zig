//! The slash-command overlay. The screen owns its draft and completion;
//! the same Shown value supplies both these rows and the screen's key policy.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const commands = @import("slash_commands.zig");
const Self = @This();

shown: *commands.Shown,
method: vaxis.gwidth.Method = .unicode,
style: vaxis.Style = .{},
quiet: vaxis.Style = .{ .dim = true },

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (input != .mouse) return;
    // Never let a click through to a covered transcript or Session row.
    ctx.consumeEvent();
    if (self.shown.seen != .drawn) return;
    switch (input.mouse.button) {
        .wheel_up, .wheel_down => {
            self.shown.move(input.mouse.button == .wheel_down);
            ctx.redraw = true;
        },
        else => {},
    }
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const height: u16 = @intCast(@min(self.shown.rows(), ctx.max.height.?));
    const width = ctx.max.width.?;
    self.shown.drew(width > 2 and height != 0);
    if (self.shown.seen != .drawn) return .empty(self.widget());
    const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    @memset(surface.buffer, .{ .style = self.style });
    var screen: vaxis.Screen = .{ .width = width, .height = height, .width_method = self.method, .buf = surface.buffer };
    const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen };
    const list = &self.shown.list;
    const count = commands.named(list.count, height);
    const first = list.firstShown(self.shown.highlight, height);
    const column = list.descriptionColumn();
    for (list.shown()[first..][0..count], first..) |entry, index| {
        var style = self.style;
        style.reverse = index == self.shown.highlight;
        const row: u16 = @intCast(index - first);
        if (style.reverse) @memset(surface.buffer[@as(usize, row) * width ..][0..width], .{ .style = style });
        const line = window.child(.{ .y_off = row, .height = 1 });
        _ = line.printSegment(.{ .text = entry.shown, .style = style }, .{ .wrap = .none });
        if (column < width) {
            var description = self.quiet;
            description.reverse = style.reverse;
            _ = line.child(.{ .x_off = @intCast(column) }).printSegment(.{ .text = entry.description, .style = description }, .{ .wrap = .none });
        }
    }
    if (count < list.count and count < height) {
        const label = try std.fmt.allocPrint(ctx.arena, commands.more, .{list.count - count});
        _ = window.child(.{ .y_off = @intCast(count), .height = 1 }).printSegment(.{ .text = label, .style = self.quiet }, .{ .wrap = .none });
    }
    return surface;
}

test "Palette keeps the selected command visible at one row and hides closed or clipped choices" {
    var shown = commands.Shown.next(null, 7, commands.conversation.suggest("/", .{})).?;
    shown.highlight = shown.list.count - 1;
    var palette: Self = .{ .shown = &shown };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 1 }, .cell_size = .{} };
    const surface = try palette.widget().draw(ctx);
    try std.testing.expectEqual(.drawn, shown.seen);
    try std.testing.expectEqual(@as(u16, 1), surface.size.height);
    try std.testing.expect(surface.readCell(0, 0).style.reverse);
    var text: [80]u8 = undefined;
    var used: usize = 0;
    for (surface.buffer) |cell| {
        if (cell.char.grapheme.len == 0) continue;
        @memcpy(text[used..][0..cell.char.grapheme.len], cell.char.grapheme);
        used += cell.char.grapheme.len;
    }
    try std.testing.expect(std.mem.startsWith(u8, text[0..used], shown.list.entries[shown.highlight].shown));
    const clipped = try palette.widget().draw(ctx.withConstraints(.{}, .{ .width = 2, .height = 1 }));
    try std.testing.expectEqual(@as(usize, 0), clipped.buffer.len);
    try std.testing.expectEqual(.hidden, shown.seen);
    shown.close();
    const closed = try palette.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 0), closed.buffer.len);
    try std.testing.expectEqual(.closed, shown.seen);
}

test "Palette renders names-only slash lists on conversation and overview" {
    const cases = .{
        .{ commands.conversation, &[_][]const u8{ "/archive", "/configure", "/copy           code · file", "/effort", "/help", "/model", "/reload-skills", "/rename", "/setup", "/status", "/unarchive" } },
        .{ commands.overview, &[_][]const u8{ "/archive", "/configure", "/help", "/model", "/rename", "/sessions   unarchived · archived · all", "/setup", "/unarchive" } },
    };
    inline for (cases) |case| {
        var shown = commands.Shown.next(null, 1, case[0].suggest("/", .{})).?;
        var palette: Self = .{ .shown = &shown };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
        const surface = try palette.widget().draw(ctx);
        try std.testing.expectEqual(case[1].len, surface.size.height);
        std.debug.print("\n{s} / list:\n", .{if (case[0] == commands.conversation) "Conversation" else "Overview"});
        for (case[1], 0..) |expected, row| {
            var text: [256]u8 = undefined;
            var used: usize = 0;
            for (surface.buffer[row * 80 ..][0..80]) |cell| {
                @memcpy(text[used..][0..cell.char.grapheme.len], cell.char.grapheme);
                used += cell.char.grapheme.len;
            }
            const line = std.mem.trimEnd(u8, text[0..used], " ");
            try std.testing.expectEqualStrings(expected, line);
            std.debug.print("{s}\n", .{line});
            if (std.mem.indexOf(u8, expected, " · ") != null) {
                try std.testing.expect(!surface.readCell(0, @intCast(row)).style.dim);
                try std.testing.expect(surface.readCell(@intCast(shown.list.descriptionColumn()), @intCast(row)).style.dim);
            }
        }
    }
}
