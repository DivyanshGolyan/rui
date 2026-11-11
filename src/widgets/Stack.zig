//! A bounded column with natural-height children and at most one remainder child.
const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const Self = @This();

/// Borrowed children; their widgets must outlive the drawn surface.
children: []const Child,

pub const Child = struct {
    widget: vxfw.Widget,
    sizing: enum { natural, fill } = .natural,
};

pub fn widget(self: *const Self) vxfw.Widget {
    return .{ .userdata = @constCast(self), .drawFn = draw };
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *const Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    if (size.width == 0 or size.height == 0) return .empty(self.widget());
    const children = try ctx.arena.alloc(vxfw.SubSurface, self.children.len);
    var remaining = size.height;
    var fill: ?usize = null;
    // Bottom rows keep their natural height first, even in a tiny column.
    var i = self.children.len;
    while (i > 0) {
        i -= 1;
        const child = self.children[i];
        if (child.sizing == .fill) {
            std.debug.assert(fill == null);
            fill = i;
            continue;
        }
        const surface = try child.widget.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = remaining }));
        children[i] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = surface };
        remaining -= surface.size.height;
    }
    if (fill) |index| {
        const surface = try self.children[index].widget.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = remaining }));
        children[index] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = surface };
    }
    var row: u16 = 0;
    for (children, 0..) |*child, index| {
        child.origin.row = row;
        row += if (fill == index) remaining else child.surface.size.height;
    }
    return .{ .widget = self.widget(), .size = .{ .width = size.width, .height = if (fill != null) size.height else row }, .buffer = &.{}, .children = children };
}

test "Stack reserves natural rows before giving the remainder to one child" {
    const top: vxfw.Text = .{ .text = "a\nb" };
    const middle: vxfw.Text = .{ .text = "c" };
    const bottom: vxfw.Text = .{ .text = "d\ne" };
    const stack: Self = .{ .children = &.{
        .{ .widget = top.widget() },
        .{ .widget = middle.widget(), .sizing = .fill },
        .{ .widget = bottom.widget() },
    } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 8, .height = 9 }, .cell_size = .{} };
    const drawn = try stack.widget().draw(ctx);
    try std.testing.expectEqual(@as(i17, 0), drawn.children[0].origin.row);
    try std.testing.expectEqual(@as(i17, 2), drawn.children[1].origin.row);
    try std.testing.expectEqual(@as(i17, 7), drawn.children[2].origin.row);
    for (0..4) |height| {
        const tiny = try stack.widget().draw(ctx.withConstraints(.{}, .{ .width = 1, .height = @intCast(height) }));
        try std.testing.expect(tiny.size.height <= height);
        for (tiny.children) |child| {
            try std.testing.expect(child.origin.row >= 0);
            try std.testing.expect(child.origin.row + child.surface.size.height <= height);
        }
    }
    const natural: Self = .{ .children = &.{ .{ .widget = top.widget() }, .{ .widget = bottom.widget() } } };
    const column = try natural.widget().draw(ctx);
    try std.testing.expectEqual(@as(i17, 2), column.children[1].origin.row);
    try std.testing.expectEqual(@as(u16, 4), column.size.height);
    const empty: Self = .{ .children = &.{} };
    try std.testing.expectEqual(@as(usize, 0), (try empty.widget().draw(ctx)).children.len);
    try std.testing.expectEqual(@as(u16, 0), (try stack.widget().draw(ctx.withConstraints(.{}, .{ .width = 0, .height = 1 }))).size.width);
}
