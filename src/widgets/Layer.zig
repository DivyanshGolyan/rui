//! Independent panels painted above a base, each on its own ground.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Self = @This();

base: vxfw.Widget,
/// Borrowed, bottom to top. Widgets and callback data outlive the surface.
panels: []const Panel = &.{},

pub const Panel = struct {
    child: vxfw.Widget,
    /// Exclusive bottom row and inclusive top row, in base coordinates.
    bottom: u16,
    top: u16 = 0,
    style: vaxis.Style = .{},
    userdata: *anyopaque,
    on_close: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
};

pub fn widget(self: *const Self) vxfw.Widget {
    return .{ .userdata = @constCast(self), .captureHandler = capture, .drawFn = draw };
}

fn capture(raw: *anyopaque, ctx: *vxfw.EventContext, value: vxfw.Event) !void {
    const self: *const Self = @ptrCast(@alignCast(raw));
    if (self.panels.len == 0 or value != .key_press or !value.key_press.matches(vaxis.Key.escape, .{})) return;
    const panel = self.panels[self.panels.len - 1];
    ctx.consumeAndRedraw();
    try panel.on_close(panel.userdata, ctx);
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *const Self = @ptrCast(@alignCast(raw));
    return self.drawAbove(ctx, try self.base.draw(ctx));
}

/// Compose an already drawn base when panel bounds depend on its layout.
/// Tree metadata belongs to ctx.arena; cell buffers belong to ctx.cell_arena.
pub fn drawAbove(self: *const Self, ctx: vxfw.DrawContext, base: vxfw.Surface) std.mem.Allocator.Error!vxfw.Surface {
    std.debug.assert(self.panels.len <= 254);
    if (base.size.width == 0 or base.size.height == 0) return .empty(self.widget());
    const children = try ctx.arena.alloc(vxfw.SubSurface, self.panels.len + 1);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = base };
    for (self.panels, 0..) |panel, i| {
        const bottom = @min(panel.bottom, base.size.height);
        const top = @min(panel.top, bottom);
        const drawn = try panel.child.draw(ctx.withConstraints(.{}, .{ .width = base.size.width, .height = bottom - top }));
        var ground = try vxfw.Surface.init(ctx.cell_arena, .{ .userdata = @constCast(self), .drawFn = draw }, drawn.size);
        @memset(ground.buffer, .{ .style = panel.style });
        const above = try ctx.arena.alloc(vxfw.SubSurface, 1);
        above[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = drawn };
        ground.children = above;
        children[i + 1] = .{ .origin = .{ .row = bottom - drawn.size.height, .col = 0 }, .surface = ground, .z_index = @intCast(i + 2) };
    }
    return .{ .widget = self.widget(), .size = base.size, .buffer = &.{}, .children = children };
}

test "Layer panels have independent ground and ordered depth above a bounded base" {
    const base: vxfw.Text = .{ .text = "a\nb\nc\nd" };
    const first: vxfw.Text = .{ .text = "x\ny" };
    const second: vxfw.Text = .{ .text = "z" };
    const Close = struct {
        fn close(_: *anyopaque, _: *vxfw.EventContext) !void {}
    };
    var data: u8 = 0;
    const panels = [_]Panel{
        .{ .child = first.widget(), .bottom = 3, .style = .{ .bold = true }, .userdata = &data, .on_close = Close.close },
        .{ .child = second.widget(), .bottom = 3, .userdata = &data, .on_close = Close.close },
    };
    const layer: Self = .{ .base = base.widget(), .panels = &panels };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 8, .height = 4 }, .cell_size = .{} };
    const drawn = try layer.widget().draw(ctx);
    try std.testing.expect(drawn.children[0].surface.widget.eql(base.widget()));
    try std.testing.expectEqual(@as(u16, 4), drawn.children[0].surface.size.height);
    try std.testing.expectEqual(@as(i17, 1), drawn.children[1].origin.row);
    try std.testing.expectEqual(@as(i17, 2), drawn.children[2].origin.row);
    try std.testing.expectEqual(@as(u8, 2), drawn.children[1].z_index);
    try std.testing.expectEqual(@as(u8, 3), drawn.children[2].z_index);
    try std.testing.expect(drawn.children[1].surface.buffer[0].style.bold);
    for ([_]vxfw.Size{ .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 0 }, .{ .width = 1, .height = 1 } }) |size| {
        const tiny = try layer.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
        for (tiny.children) |child| try std.testing.expect(child.origin.row + child.surface.size.height <= size.height);
    }
    const clipped: Self = .{ .base = base.widget(), .panels = &.{.{ .child = first.widget(), .bottom = 99, .top = 3, .userdata = &data, .on_close = Close.close }} };
    const bounded = try clipped.widget().draw(ctx);
    try std.testing.expectEqual(@as(i17, 3), bounded.children[1].origin.row);
    try std.testing.expectEqual(@as(u16, 1), bounded.children[1].surface.size.height);
}

test "Layer captures Escape for only the topmost panel and passes it without panels" {
    const text: vxfw.Text = .{ .text = "x" };
    const Close = struct {
        fn close(raw: *anyopaque, _: *vxfw.EventContext) !void {
            const count: *u8 = @ptrCast(@alignCast(raw));
            count.* += 1;
        }
    };
    var lower: u8 = 0;
    var upper: u8 = 0;
    const panels = [_]Panel{
        .{ .child = text.widget(), .bottom = 1, .userdata = &lower, .on_close = Close.close },
        .{ .child = text.widget(), .bottom = 1, .userdata = &upper, .on_close = Close.close },
    };
    var layer: Self = .{ .base = text.widget(), .panels = &panels };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty, .phase = .capturing };
    const escape: vxfw.Event = .{ .key_press = .{ .codepoint = vaxis.Key.escape } };
    try layer.widget().captureEvent(&ctx, .{ .key_press = .{ .codepoint = 'x' } });
    try std.testing.expect(!ctx.consume_event);
    try layer.widget().captureEvent(&ctx, escape);
    try std.testing.expect(ctx.consume_event);
    try std.testing.expectEqual(@as(u8, 0), lower);
    try std.testing.expectEqual(@as(u8, 1), upper);
    layer.panels = panels[0..1];
    ctx.consume_event = false;
    try layer.widget().captureEvent(&ctx, escape);
    try std.testing.expect(ctx.consume_event);
    try std.testing.expectEqual(@as(u8, 1), lower);
    layer.panels = &.{};
    ctx.consume_event = false;
    try layer.widget().captureEvent(&ctx, escape);
    try std.testing.expect(!ctx.consume_event);
}
