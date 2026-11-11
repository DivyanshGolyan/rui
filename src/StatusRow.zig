//! The Session's last row, as `session_chrome.bar` decides it: what needs
//! the person or a fresh notice on the left, its key clickable where it
//! has one (`ctrl+r retries`), and `ctrl+x stop` at the right while work
//! can be stopped. Clicking a key runs the same action as pressing it.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const chrome = @import("session_chrome.zig");
const Chip = @import("Chip.zig");
const Self = @This();

bar: chrome.Bar = .{},
/// The clickable key that ends `bar.left`, such as `ctrl+r retries`; its
/// label is empty when the left side has none.
key: Chip,
stop: Chip,
method: vaxis.gwidth.Method = .unicode,
quiet: vaxis.Style = .{},
attention: vaxis.Style = .{},

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .drawFn = draw };
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const max = ctx.max.size();
    // An open tool's right-slot key is on the facts line. Do not reserve
    // another row for it when there is no independent notice/status.
    const empty = self.bar.close_tool and self.bar.left.len == 0;
    const size: vxfw.Size = .{ .width = max.width, .height = if (empty) 0 else @min(1, max.height) };
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    @memset(surface.buffer, .{ .style = self.quiet });
    if (size.width == 0 or size.height == 0) return surface;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    var used: usize = 0;
    const tone = if (self.bar.tone == .attention) self.attention else self.quiet;
    const left_end: u16 = if (self.bar.stop and !self.bar.close_tool) self.bar.stop_column -| 2 else size.width;
    const keyed = self.key.label.len != 0 and std.mem.endsWith(u8, self.bar.left, self.key.label);
    const words = if (keyed) self.bar.left[0 .. self.bar.left.len - self.key.label.len] else self.bar.left;
    const column = Chip.print(surface, self.method, 0, 0, words, tone, left_end);
    if (keyed and column < left_end) {
        self.key.style = tone;
        self.key.hover = tone;
        self.key.hover.ul_style = .single;
        self.key.method = self.method;
        children[used] = .{ .origin = .{ .row = 0, .col = column }, .surface = try self.key.widget().draw(ctx.withConstraints(.{}, .{ .width = left_end - column, .height = 1 })) };
        used += 1;
    }
    if (self.bar.stop and !self.bar.close_tool and self.bar.stop_column < size.width) {
        self.stop.label = self.bar.right_key;
        self.stop.style = self.quiet;
        self.stop.hover = self.quiet;
        self.stop.hover.ul_style = .single;
        self.stop.method = self.method;
        children[used] = .{ .origin = .{ .row = 0, .col = self.bar.stop_column }, .surface = try self.stop.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width - self.bar.stop_column, .height = 1 })) };
        used += 1;
    }
    surface.children = children[0..used];
    return surface;
}

test "the status row shows what needs the person with its key clickable, and the stop key at the right" {
    const Actions = struct {
        retried: usize = 0,
        stopped: usize = 0,
        fn retry(raw: *anyopaque, _: *vxfw.EventContext) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.retried += 1;
        }
        fn stop(raw: *anyopaque, _: *vxfw.EventContext) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.stopped += 1;
        }
    };
    var actions: Actions = .{};
    var row: Self = .{
        .key = .{ .label = "ctrl+r retries", .userdata = &actions, .on_click = Actions.retry },
        .stop = .{ .label = "", .userdata = &actions, .on_click = Actions.stop },
        .quiet = .{ .fg = .{ .index = 8 } },
        .attention = .{ .fg = .{ .index = 3 } },
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const needs = "! Not confirmed · ctrl+r retries";
    row.bar = chrome.bar(.{ .needs = needs, .stoppable = true, .width = 80 });
    const drawn = try row.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 1 }, .cell_size = .{} });
    try std.testing.expectEqual(vxfw.Size{ .width = 80, .height = 1 }, drawn.size);
    try std.testing.expectEqualStrings("!", drawn.readCell(0, 0).char.grapheme);
    try std.testing.expectEqual(vaxis.Color{ .index = 3 }, drawn.readCell(0, 0).style.fg);
    try std.testing.expectEqual(@as(usize, 2), drawn.children.len);
    // The key is its own target, where the text puts it.
    try std.testing.expectEqual(@as(i17, 18), drawn.children[0].origin.col);
    try std.testing.expectEqualStrings("c", drawn.children[0].surface.readCell(0, 0).char.grapheme);
    try std.testing.expect(drawn.children[0].surface.widget.eql(row.key.widget()));
    try std.testing.expectEqual(vaxis.Color{ .index = 3 }, drawn.children[0].surface.readCell(0, 0).style.fg);
    // The stop key ends one cell before the edge.
    try std.testing.expectEqual(@as(i17, 68), drawn.children[1].origin.col);
    try std.testing.expectEqualStrings("ctrl+x stop", row.stop.label);
    try std.testing.expect(drawn.children[1].surface.widget.eql(row.stop.widget()));
    try std.testing.expectEqual(@as(u16, 11), drawn.children[1].surface.size.width);

    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const press: vaxis.Mouse = .{ .col = 0, .row = 0, .button = .left, .mods = .{}, .type = .press };
    var release = press;
    release.type = .release;
    for ([_]vxfw.Widget{ row.key.widget(), row.stop.widget() }) |target| {
        try target.handleEvent(&ctx, .{ .mouse = press });
        try target.handleEvent(&ctx, .{ .mouse = release });
    }
    try std.testing.expectEqual(@as(usize, 1), actions.retried);
    try std.testing.expectEqual(@as(usize, 1), actions.stopped);

    // A notice with no key: plain text, no key target.
    row.bar = chrome.bar(.{ .notice = "Copied 12 lines", .width = 40 });
    const notice = try row.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 1 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(usize, 0), notice.children.len);
    try std.testing.expectEqualStrings("C", notice.readCell(0, 0).char.grapheme);
    try std.testing.expectEqual(vaxis.Color{ .index = 8 }, notice.readCell(0, 0).style.fg);

    // Narrow: the left side wins, the stop key drops.
    row.bar = chrome.bar(.{ .needs = needs, .stoppable = true, .width = 30 });
    const narrow = try row.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 30, .height = 1 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(usize, 1), narrow.children.len);
    try std.testing.expect(narrow.children[0].surface.widget.eql(row.key.widget()));
    try std.testing.expect(narrow.children[0].surface.size.width <= 30 - 18);

    for ([_]vxfw.Size{ .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 0 }, .{ .width = 1, .height = 1 } }) |size| {
        row.bar = chrome.bar(.{ .needs = needs, .stoppable = true, .width = size.width });
        const tiny = try row.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{} });
        try std.testing.expect(tiny.size.width <= size.width and tiny.size.height <= size.height);
    }
}
