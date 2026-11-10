//! Screen selection and the one recurring application tick. Screens own their
//! workers and apply completed results when they receive that tick.
const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const TerminalApp = @import("TerminalApp.zig");
const Self = @This();

overview: vxfw.Widget,
session: ?vxfw.Widget = null,
pasting: bool = false,
frames: u64 = 0,

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .captureHandler = capture, .eventHandler = event, .drawFn = draw };
}

pub fn openSession(self: *Self, ctx: *vxfw.EventContext, session: vxfw.Widget) !void {
    std.debug.assert(self.session == null);
    self.session = session;
    try ctx.requestFocus(session);
    try session.handleEvent(ctx, .init);
    ctx.redraw = true;
}

/// The Session has settled its borrowers before calling this. No terminal
/// leaves raw mode and no input stream is transferred between screens.
pub fn closeSession(self: *Self, ctx: *vxfw.EventContext) !void {
    self.session = null;
    try ctx.requestFocus(self.overview);
    ctx.redraw = true;
}

fn capture(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (input) {
        .paste_start => self.pasting = true,
        .paste_end => self.pasting = false,
        .color_report, .color_scheme => {
            try self.overview.handleEvent(ctx, input);
            ctx.consumeEvent();
        },
        .key_release => ctx.consumeEvent(),
        else => {},
    }
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (input) {
        .init => {
            try ctx.requestFocus(self.overview);
            try self.overview.handleEvent(ctx, .init);
            try ctx.tick(16, self.widget());
            ctx.redraw = true;
        },
        .tick => {
            if (TerminalApp.interrupted()) {
                ctx.quit = true;
                return;
            }
            try self.overview.handleEvent(ctx, .tick);
            if (self.session) |session| try session.handleEvent(ctx, .tick);
            try ctx.tick(16, self.widget());
        },
        else => {},
    }
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    const child = self.session orelse self.overview;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try child.draw(ctx) };
    self.frames += 1;
    return .{ .size = size, .widget = self.widget(), .buffer = &.{}, .children = children };
}

test "App root switches between overview and Session without retaining the hidden screen" {
    const overview: vxfw.Text = .{ .text = "Overview" };
    const session: vxfw.Text = .{ .text = "Session" };
    var root: Self = .{ .overview = overview.widget() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const draw_context: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 24 },
        .cell_size = .{},
    };
    var ctx: vxfw.EventContext = .{
        .io = std.testing.io,
        .alloc = arena.allocator(),
        .cmds = .empty,
    };
    const initial = try root.widget().draw(draw_context);
    try std.testing.expectEqual(@as(usize, 1), initial.children.len);
    try std.testing.expectEqualStrings("O", initial.children[0].surface.buffer[0].char.grapheme);
    try root.openSession(&ctx, session.widget());
    const opened = try root.widget().draw(draw_context);
    try std.testing.expectEqual(@as(usize, 1), opened.children.len);
    try std.testing.expectEqualStrings("S", opened.children[0].surface.buffer[0].char.grapheme);
    try root.closeSession(&ctx);
    const closed = try root.widget().draw(draw_context);
    try std.testing.expectEqualStrings("O", closed.children[0].surface.buffer[0].char.grapheme);
}
