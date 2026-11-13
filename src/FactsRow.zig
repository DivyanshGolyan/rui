//! A Session's facts row under the composer, led by `‹`: clicking it goes
//! back to the overview, as Esc does. The facts' words are the screen's.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Chip = @import("Chip.zig");
const Self = @This();

/// The column the facts start at: one cell of margin, `‹`, then a space.
/// A shell measures the facts for the columns from here to the edge.
pub const text_column = 3;

back: Chip,
/// The facts after `‹ `: `Fix flaky store test · gpt-6.1-sol · high · 62% left`.
text: []const u8 = "",
method: vaxis.gwidth.Method = .unicode,
style: vaxis.Style = .{},

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .drawFn = draw };
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const max = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), .{ .width = max.width, .height = @min(1, max.height) });
    @memset(surface.buffer, .{ .style = self.style });
    if (surface.size.width < 2 or surface.size.height == 0) return surface;
    self.back.label = "‹";
    self.back.style = self.style;
    self.back.hover = self.style;
    self.back.hover.ul_style = .single;
    self.back.method = self.method;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    // One cell of margin, as the mocks set it; the chip is the `‹` alone.
    children[0] = .{ .origin = .{ .row = 0, .col = 1 }, .surface = try self.back.widget().draw(ctx.withConstraints(.{}, .{ .width = 1, .height = 1 })) };
    surface.children = children;
    _ = Chip.print(surface, self.method, text_column, 0, self.text, self.style, surface.size.width);
    return surface;
}

test "the facts row leads with a clickable ‹ back to the overview" {
    const Back = struct {
        count: usize = 0,
        fn back(raw: *anyopaque, _: *vxfw.EventContext) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.count += 1;
        }
    };
    var back: Back = .{};
    var row: Self = .{ .back = .{ .label = "", .userdata = &back, .on_click = Back.back }, .text = "Fix flaky store test · gpt-6.1-sol · high · 62% left" };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const drawn = try row.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 1 }, .cell_size = .{} });
    try std.testing.expectEqualStrings("F", drawn.readCell(3, 0).char.grapheme);
    try std.testing.expectEqual(@as(i17, 1), drawn.children[0].origin.col);
    try std.testing.expectEqualStrings("‹", drawn.children[0].surface.readCell(0, 0).char.grapheme);
    try std.testing.expect(drawn.children[0].surface.widget.eql(row.back.widget()));
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const press: vaxis.Mouse = .{ .col = 0, .row = 0, .button = .left, .mods = .{}, .type = .press };
    var release = press;
    release.type = .release;
    try row.back.widget().handleEvent(&ctx, .mouse_enter);
    const hovered = try row.back.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 1, .height = 1 }, .cell_size = .{} });
    try std.testing.expectEqual(.single, hovered.readCell(0, 0).style.ul_style);
    try std.testing.expectEqual(vaxis.Mouse.Shape.pointer, ctx.cmds.items[ctx.cmds.items.len - 1].set_mouse_shape);
    try row.back.widget().handleEvent(&ctx, .{ .mouse = press });
    try row.back.widget().handleEvent(&ctx, .{ .mouse = release });
    try std.testing.expectEqual(@as(usize, 1), back.count);
    try row.back.widget().handleEvent(&ctx, .mouse_leave);
    const left = try row.back.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 1, .height = 1 }, .cell_size = .{} });
    try std.testing.expectEqual(.off, left.readCell(0, 0).style.ul_style);
    for ([_]vxfw.Size{ .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 1 }, .{ .width = 3, .height = 0 } }) |size| {
        const tiny = try row.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{} });
        try std.testing.expect(tiny.size.width <= size.width and tiny.size.height <= size.height);
    }
}
