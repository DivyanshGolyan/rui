//! Two bounded panes with a one-cell divider and caller-chosen narrow fallback.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Self = @This();

left: vxfw.Widget,
right: vxfw.Widget,
left_width: u16,
min_width: u16,
narrow: enum { left, right },
divider: Divider = .{},

pub const Divider = struct { grapheme: []const u8 = "│", style: vaxis.Style = .{} };

pub fn widget(self: *const Self) vxfw.Widget {
    return .{ .userdata = @constCast(self), .drawFn = draw };
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *const Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    if (size.width == 0 or size.height == 0) return .empty(self.widget());
    if (size.width < self.min_width) {
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        const child = if (self.narrow == .left) self.left else self.right;
        children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try child.draw(ctx.withConstraints(.{}, ctx.max)) };
        return .{ .widget = self.widget(), .size = size, .buffer = &.{}, .children = children };
    }
    std.debug.assert(ctx.stringWidth(self.divider.grapheme) == 1);
    const left_width = @min(self.left_width, size.width - 1);
    const right_width = size.width - left_width - 1;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.left.draw(ctx.withConstraints(.{}, .{ .width = left_width, .height = size.height })) };
    const divider = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = 1, .height = size.height });
    @memset(divider.buffer, .{ .char = .{ .grapheme = self.divider.grapheme, .width = 1 }, .style = self.divider.style });
    children[1] = .{ .origin = .{ .row = 0, .col = left_width }, .surface = divider };
    children[2] = .{ .origin = .{ .row = 0, .col = left_width + 1 }, .surface = try self.right.draw(ctx.withConstraints(.{}, .{ .width = right_width, .height = size.height })) };
    return .{ .widget = self.widget(), .size = size, .buffer = &.{}, .children = children };
}

test "Split divides cells and selects only the named narrow pane" {
    const left: vxfw.Text = .{ .text = "界", .width_basis = .parent };
    const right: vxfw.Text = .{ .text = "r", .width_basis = .parent };
    var split: Self = .{ .left = left.widget(), .right = right.widget(), .left_width = 3, .min_width = 8, .narrow = .right, .divider = .{ .grapheme = "┃", .style = .{ .bold = true } } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 8, .height = 3 }, .cell_size = .{} };
    const drawn = try split.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 3), drawn.children[0].surface.size.width);
    try std.testing.expectEqual(@as(i17, 3), drawn.children[1].origin.col);
    try std.testing.expectEqual(@as(i17, 4), drawn.children[2].origin.col);
    try std.testing.expectEqual(@as(u16, 4), drawn.children[2].surface.size.width);
    try std.testing.expectEqual(@as(u16, 3), drawn.children[1].surface.size.height);
    for (drawn.children[1].surface.buffer) |cell| {
        try std.testing.expectEqualStrings("┃", cell.char.grapheme);
        try std.testing.expect(cell.style.bold);
    }
    for ([_]@TypeOf(split.narrow){ .left, .right }) |choice| {
        split.narrow = choice;
        const narrow = try split.widget().draw(ctx.withConstraints(.{}, .{ .width = 7, .height = 3 }));
        try std.testing.expectEqual(@as(usize, 1), narrow.children.len);
        try std.testing.expect(narrow.children[0].surface.widget.eql(if (choice == .left) left.widget() else right.widget()));
    }
    split.min_width = 0;
    split.left_width = 65535;
    for (0..4) |width| for (0..3) |height| {
        const tiny = try split.widget().draw(ctx.withConstraints(.{}, .{ .width = @intCast(width), .height = @intCast(height) }));
        try std.testing.expect(tiny.size.width <= width and tiny.size.height <= height);
        for (tiny.children) |child| {
            try std.testing.expect(child.origin.col >= 0);
            try std.testing.expect(child.origin.col + child.surface.size.width <= width);
            try std.testing.expect(child.surface.size.height <= height);
        }
    };
}
