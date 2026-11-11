//! Screen selection and the one recurring application tick. Screens own their
//! workers and apply completed results when they receive that tick.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Split = @import("widgets/Split.zig");
const TerminalApp = @import("TerminalApp.zig");
const Self = @This();

pub const list_width = 40;
pub const split_at = 100;

overview: vxfw.Widget,
list: vxfw.Widget,
compose: vxfw.Widget,
divider_style: vaxis.Style = .{},
session: ?vxfw.Widget = null,
pasting: bool = false,
frames: u64 = 0,
/// This frame's shell layout, published before drawing its Session.
list_visible: bool = false,

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
    self.list_visible = size.width >= split_at and size.height != 0;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    const child = if (!self.list_visible)
        try (self.session orelse self.overview).draw(ctx)
    else wide: {
        const split = try ctx.arena.create(Split);
        split.* = .{
            .left = self.list,
            .right = self.session orelse self.compose,
            .left_width = list_width,
            // Root has already selected this frame's wide layout.
            .min_width = 0,
            .narrow = .right,
            .divider = .{ .style = self.divider_style },
        };
        break :wide try split.widget().draw(ctx);
    };
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = child };
    self.frames += 1;
    return .{ .size = size, .widget = self.widget(), .buffer = &.{}, .children = children };
}

test "App root switches between overview and Session without retaining the hidden screen" {
    const overview: vxfw.Text = .{ .text = "Overview" };
    const session: vxfw.Text = .{ .text = "Session" };
    var root: Self = .{ .overview = overview.widget(), .list = overview.widget(), .compose = overview.widget() };
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

test "App root places list and compose or the open child at desktop and phone widths" {
    const Pane = struct {
        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .drawFn = @This().draw };
        }
        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .widget = self.widget(), .size = ctx.max.size(), .buffer = &.{}, .children = &.{} };
        }
    };
    var whole: Pane = .{};
    var list: Pane = .{};
    var compose: Pane = .{};
    var opened: Pane = .{};
    var root: Self = .{ .overview = whole.widget(), .list = list.widget(), .compose = compose.widget() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |active| {
        root.session = if (active) opened.widget() else null;
        for ([_]vxfw.Size{ .{ .width = 140, .height = 40 }, .{ .width = 46, .height = 26 }, .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 1 }, .{ .width = 41, .height = 1 }, .{ .width = 99, .height = 1 }, .{ .width = 100, .height = 1 }, .{ .width = 100, .height = 0 } }) |size| {
            const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{} };
            const surface = try root.widget().draw(ctx);
            try std.testing.expectEqual(size, surface.size);
            try std.testing.expectEqual(size.width >= split_at and size.height != 0, root.list_visible);
            const layout = surface.children[0].surface;
            if (size.width >= 100 and size.height > 0) {
                try std.testing.expectEqual(@as(usize, 3), layout.children.len);
                try std.testing.expect(layout.children[0].surface.widget.eql(list.widget()));
                try std.testing.expectEqual(vxfw.RelativePoint{ .row = 0, .col = 0 }, layout.children[0].origin);
                try std.testing.expectEqual(@as(u16, 40), layout.children[0].surface.size.width);
                try std.testing.expectEqual(@as(i17, 40), layout.children[1].origin.col);
                try std.testing.expectEqualStrings("│", layout.children[1].surface.buffer[0].char.grapheme);
                try std.testing.expectEqual(vxfw.RelativePoint{ .row = 0, .col = 41 }, layout.children[2].origin);
                try std.testing.expectEqual(size.width - 41, layout.children[2].surface.size.width);
                try std.testing.expect(layout.children[2].surface.widget.eql(if (active) opened.widget() else compose.widget()));
            } else if (size.width < 100) {
                try std.testing.expect(layout.widget.eql(if (active) opened.widget() else whole.widget()));
                try std.testing.expectEqual(size.width, layout.size.width);
            }
            for (layout.children) |child| {
                try std.testing.expect(child.origin.col >= 0 and child.origin.row >= 0);
                try std.testing.expect(child.origin.col + child.surface.size.width <= size.width);
                try std.testing.expect(child.origin.row + child.surface.size.height <= size.height);
            }
        }
    }
}

test "App root resizing keeps the open child's draft scroll and focus without another init" {
    const Pane = struct {
        draft: []const u8 = "kept draft",
        scroll: u16 = 7,
        inits: usize = 0,
        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .eventHandler = @This().event, .drawFn = @This().draw };
        }
        fn event(raw: *anyopaque, _: *vxfw.EventContext, input: vxfw.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (input == .init) self.inits += 1;
        }
        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .widget = self.widget(), .size = ctx.max.size(), .buffer = &.{}, .children = &.{}, .cursor = .{ .row = 0, .col = 0 } };
        }
    };
    var whole: Pane = .{};
    var list: Pane = .{};
    var compose: Pane = .{};
    var opened: Pane = .{};
    var root: Self = .{ .overview = whole.widget(), .list = list.widget(), .compose = compose.widget() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try root.openSession(&events, opened.widget());
    try std.testing.expectEqual(@as(usize, 1), events.cmds.items.len);
    try std.testing.expect(events.cmds.items[0].request_focus.eql(opened.widget()));
    for ([_]u16{ 140, 46, 99, 100, 46, 140 }) |width| {
        const surface = try root.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 26 }, .cell_size = .{} });
        try std.testing.expect(root.session.?.eql(opened.widget()));
        try std.testing.expectEqual(@as(usize, 1), events.cmds.items.len);
        try std.testing.expectEqual(@as(usize, 1), opened.inits);
        try std.testing.expectEqualStrings("kept draft", opened.draft);
        try std.testing.expectEqual(@as(u16, 7), opened.scroll);
        var screen: vaxis.Screen = try .init(arena.allocator(), .{ .cols = width, .rows = 26, .x_pixel = 0, .y_pixel = 0 });
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 26, .screen = &screen };
        surface.render(window, opened.widget());
        try std.testing.expect(screen.cursor_vis);
        try std.testing.expectEqual(@as(u16, if (width >= 100) 41 else 0), screen.cursor.col);
    }
    try root.closeSession(&events);
    try std.testing.expect(root.session == null);
    try std.testing.expect(events.cmds.items[1].request_focus.eql(whole.widget()));
}
