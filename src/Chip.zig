//! A clickable label on one row: `‹`, `↓ 3 new`, `ctrl+x stop`, `ctrl+r
//! retries`, `+2 more running · info`. A press and release on it runs
//! `on_click`, the same action as its key; moving off before release
//! cancels. Hover changes only its look and the pointer shape. It never
//! takes focus, so the composer keeps typing.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Self = @This();

label: []const u8,
style: vaxis.Style = .{},
/// While the pointer is over it.
hover: vaxis.Style = .{ .ul_style = .single },
method: vaxis.gwidth.Method = .unicode,
userdata: *anyopaque,
on_click: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
pressed: bool = false,
hovered: bool = false,

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

/// Cells the label takes.
pub fn width(self: *const Self) u16 {
    return @intCast(@min(vaxis.gwidth.gwidth(self.label, self.method), std.math.maxInt(u16)));
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (input) {
        .mouse => |mouse| {
            if (mouse.button == .left and mouse.type == .press) {
                self.pressed = true;
                return ctx.consumeAndRedraw();
            }
            if (mouse.type == .release and self.pressed) {
                self.pressed = false;
                ctx.consumeAndRedraw();
                return self.on_click(self.userdata, ctx);
            }
        },
        .mouse_enter => {
            self.hovered = true;
            try ctx.setMouseShape(.pointer);
            ctx.redraw = true;
        },
        .mouse_leave => {
            self.hovered = false;
            self.pressed = false;
            try ctx.setMouseShape(.default);
            ctx.redraw = true;
        },
        else => {},
    }
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const max = ctx.max.size();
    const size: vxfw.Size = .{ .width = @min(self.width(), max.width), .height = @min(1, max.height) };
    const surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), size);
    const style = if (self.hovered) self.hover else self.style;
    @memset(surface.buffer, .{ .style = style });
    _ = print(surface, self.method, 0, 0, self.label, style, size.width);
    return surface;
}

/// Prints `text` on `row` of `surface` from `column`, clipped at column
/// `end` and the surface's edge, and returns the column after it. Shared by
/// the Session chrome's rows.
pub fn print(surface: vxfw.Surface, method: vaxis.gwidth.Method, column: u16, row: u16, text: []const u8, style: vaxis.Style, end: u16) u16 {
    const limit = @min(end, surface.size.width);
    if (row >= surface.size.height or column >= limit) return column;
    var screen: vaxis.Screen = .{ .width = surface.size.width, .height = surface.size.height, .width_method = method, .buf = surface.buffer };
    const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.width, .height = screen.height, .screen = &screen };
    const after = window.child(.{ .x_off = column, .y_off = row, .width = limit - column, .height = 1 }).printSegment(.{ .text = text, .style = style }, .{ .wrap = .none });
    return @min(column + after.col, limit);
}

test "a Chip runs its action on press and release over it, and not when the pointer leaves first" {
    const Count = struct {
        clicks: usize = 0,
        fn click(raw: *anyopaque, _: *vxfw.EventContext) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.clicks += 1;
        }
    };
    var count: Count = .{};
    var chip: Self = .{ .label = "ctrl+x stop", .style = .{ .fg = .{ .index = 8 } }, .userdata = &count, .on_click = Count.click };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const press: vaxis.Mouse = .{ .col = 1, .row = 0, .button = .left, .mods = .{}, .type = .press };
    var release = press;
    release.type = .release;
    try chip.widget().handleEvent(&ctx, .{ .mouse = press });
    try chip.widget().handleEvent(&ctx, .{ .mouse = release });
    try std.testing.expectEqual(@as(usize, 1), count.clicks);
    // Pressed, moved off and released elsewhere: nothing runs.
    try chip.widget().handleEvent(&ctx, .{ .mouse = press });
    try chip.widget().handleEvent(&ctx, .mouse_leave);
    try chip.widget().handleEvent(&ctx, .{ .mouse = release });
    try std.testing.expectEqual(@as(usize, 1), count.clicks);
    // A release without a press here (a drag that ended on it) does nothing.
    try chip.widget().handleEvent(&ctx, .{ .mouse = release });
    try std.testing.expectEqual(@as(usize, 1), count.clicks);
    // Motion acts on nothing.
    var motion = press;
    motion.type = .motion;
    try chip.widget().handleEvent(&ctx, .{ .mouse = motion });
    try std.testing.expectEqual(@as(usize, 1), count.clicks);

    const drawn = try chip.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 3 }, .cell_size = .{} });
    try std.testing.expectEqual(vxfw.Size{ .width = 11, .height = 1 }, drawn.size);
    try std.testing.expectEqualStrings("c", drawn.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("p", drawn.readCell(10, 0).char.grapheme);
    try std.testing.expect(drawn.readCell(0, 0).style.ul_style == .off);
    try chip.widget().handleEvent(&ctx, .mouse_enter);
    const hovered = try chip.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 4, .height = 1 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(u16, 4), hovered.size.width);
    try std.testing.expect(hovered.readCell(0, 0).style.ul_style == .single);
    try std.testing.expectEqual(@as(usize, 1), count.clicks);
}
