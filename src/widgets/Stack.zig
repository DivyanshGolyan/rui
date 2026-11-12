//! A bounded column with natural-height children and at most one remainder child.
const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const Self = @This();

/// Borrowed children; their widgets must outlive the drawn surface.
children: []const Child,
/// Which edge keeps its natural rows first when the column is too short.
priority: enum { top, bottom } = .bottom,

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
    if (size.width == 0) return .empty(self.widget());
    // Drawing also updates child layout state. Forward zero remaining height
    // through nested columns rather than leaving descendants at their old size.
    const children = try ctx.arena.alloc(vxfw.SubSurface, self.children.len);
    var remaining = size.height;
    var fill: ?usize = null;
    // Allocate natural rows in the caller's edge priority, without changing
    // their display order or the remainder child's position.
    for (0..self.children.len) |step| {
        const i = if (self.priority == .bottom) self.children.len - 1 - step else step;
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

test "Stack preserves the requested edge when natural rows compete" {
    const top: vxfw.Text = .{ .text = "top" };
    const bottom: vxfw.Text = .{ .text = "bottom" };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]@FieldType(Self, "priority"){ .top, .bottom }) |priority| for (0..3) |height| {
        const stack: Self = .{ .priority = priority, .children = &.{ .{ .widget = top.widget() }, .{ .widget = bottom.widget() } } };
        const surface = try stack.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 8, .height = @intCast(height) }, .cell_size = .{} });
        try std.testing.expectEqual(height, surface.size.height);
        try std.testing.expectEqual(@as(u16, @intFromBool(height == 2 or (height == 1 and priority == .top))), surface.children[0].surface.size.height);
        try std.testing.expectEqual(@as(u16, @intFromBool(height == 2 or (height == 1 and priority == .bottom))), surface.children[1].surface.size.height);
    };
}
