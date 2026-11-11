//! Screen selection and the one recurring application tick. Screens own their
//! workers and apply completed results when they receive that tick.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Split = @import("widgets/Split.zig");
const Layer = @import("widgets/Layer.zig");
const AppSettings = @import("app_settings.zig");
const TerminalApp = @import("TerminalApp.zig");
const Self = @This();

pub const list_width = 40;
pub const split_at = 100;

overview: vxfw.Widget,
list: vxfw.Widget,
compose: vxfw.Widget,
divider: Split.Divider = .{},
session: ?vxfw.Widget = null,
settings_page: AppSettings = .{},
settings_open: bool = false,
pasting: bool = false,
frames: u64 = 0,
size: vxfw.Size = .{},

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .captureHandler = capture, .eventHandler = event, .drawFn = draw };
}

/// Visibility follows the current viewport and screen selection, not the last
/// time the list happened to draw. Opening a Session can hide it before drawing.
pub fn listVisible(self: *const Self) bool {
    const layout = self.chooseLayout();
    return self.size.width > 0 and self.size.height > 0 and (layout.split or layout.pane == .overview);
}

const Layout = struct {
    split: bool,
    pane: enum { overview, session, settings },
};

/// One derived pane decision drives drawing, visibility and return focus.
fn chooseLayout(self: *const Self) Layout {
    return .{
        .split = self.size.width >= split_at,
        .pane = if (self.settings_open) .settings else if (self.session != null) .session else .overview,
    };
}

pub fn openSession(self: *Self, ctx: *vxfw.EventContext, session: vxfw.Widget) !void {
    std.debug.assert(self.session == null);
    self.session = session;
    try self.revealSession(ctx);
    try session.handleEvent(ctx, .init);
    ctx.redraw = true;
}

/// Reveal the retained Session without reopening it or initializing it again.
pub fn revealSession(self: *Self, ctx: *vxfw.EventContext) !void {
    const session = self.session orelse unreachable;
    self.settings_open = false;
    self.settings_page.cancelChoice();
    try ctx.requestFocus(session);
    ctx.redraw = true;
}

/// Settings is a right-pane occupant, not content in the conversation feed.
pub fn openSettings(self: *Self, ctx: *vxfw.EventContext) !void {
    self.settings_page.narrow = self.size.width < split_at;
    try self.settings_page.refresh();
    self.settings_open = true;
    try ctx.requestFocus(self.settings_page.widget());
    ctx.redraw = true;
}

pub fn closeSettings(self: *Self, ctx: *vxfw.EventContext) !void {
    self.settings_page.cancelChoice();
    self.settings_open = false;
    // On phones the retained Session fills the screen again. Never request
    // focus to a list which is absent from that layout.
    const layout = self.chooseLayout();
    try ctx.requestFocus(if (!layout.split and layout.pane == .session) self.session.? else self.listWidget());
    ctx.redraw = true;
}

/// The existing list renderer has no keyboard handler. Give the list a stable
/// focus identity in both layouts without forwarding focus_in to the composer.
fn listWidget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = listEvent, .drawFn = drawList };
}

fn listEvent(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (input) {
        .key_press, .paste_start, .paste_end, .invalid_key => try self.overview.handleEvent(ctx, input),
        else => {},
    }
}

fn drawList(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.size.width < split_at) {
        // Narrow mode keeps the overview's existing screen identity (including
        // its composer focus path). Its list shares that renderer, so attach a
        // zero-cell keyboard focus anchor rather than drawing the list twice.
        var surface = try self.overview.draw(ctx);
        const children = try ctx.arena.alloc(vxfw.SubSurface, surface.children.len + 1);
        @memcpy(children[0..surface.children.len], surface.children);
        children[surface.children.len] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = .empty(self.listWidget()) };
        surface.children = children;
        return surface;
    }
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.list.draw(ctx) };
    return .{ .widget = self.listWidget(), .size = ctx.max.size(), .buffer = &.{}, .children = children };
}

fn closePanel(raw: *anyopaque, ctx: *vxfw.EventContext) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.settings_page.hasChoice()) {
        self.settings_page.cancelChoice();
    } else try self.closeSettings(ctx);
}

fn settingsLayer(self: *Self, ctx: vxfw.DrawContext, base: vxfw.Widget) std.mem.Allocator.Error!vxfw.Widget {
    const layer = try ctx.arena.create(Layer);
    const panels = try ctx.arena.alloc(Layer.Panel, 1);
    panels[0] = .{ .child = self.settings_page.widget(), .bottom = ctx.max.size().height, .userdata = self, .on_close = closePanel };
    layer.* = .{ .base = base, .panels = panels };
    return layer.widget();
}

/// The Session has settled its borrowers before calling this. No terminal
/// leaves raw mode and no input stream is transferred between screens.
pub fn closeSession(self: *Self, ctx: *vxfw.EventContext) !void {
    self.session = null;
    if (!self.settings_open) try ctx.requestFocus(self.overview);
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
            const first_command = ctx.cmds.items.len;
            try self.overview.handleEvent(ctx, .tick);
            if (self.session) |session| try session.handleEvent(ctx, .tick);
            if (self.settings_open) {
                // Hidden screens still settle their workers and consent state,
                // but their presentation targets aren't in this focus tree.
                // Retain every other command; a real openSession transition
                // reveals the Session and keeps its own focus request.
                var kept = first_command;
                for (ctx.cmds.items[first_command..]) |command| {
                    if (command == .request_focus) continue;
                    ctx.cmds.items[kept] = command;
                    kept += 1;
                }
                ctx.cmds.items.len = kept;
                try self.settings_page.widget().handleEvent(ctx, .tick);
            }
            try ctx.tick(16, self.widget());
        },
        else => {},
    }
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    self.size = size;
    self.settings_page.narrow = size.width < split_at;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    const layout = self.chooseLayout();
    const pane = switch (layout.pane) {
        .overview => if (layout.split) self.compose else self.listWidget(),
        .session => self.session.?,
        .settings => try self.settingsLayer(ctx, if (layout.split) self.compose else self.listWidget()),
    };
    const child = if (layout.split) split: {
        const split = try ctx.arena.create(Split);
        split.* = .{
            .left = self.listWidget(),
            .right = pane,
            .left_width = list_width,
            // Root already chose the layout; Split only places the panes.
            .min_width = 0,
            .narrow = .right,
            .divider = self.divider,
        };
        break :split try split.widget().draw(ctx);
    } else try pane.draw(ctx);
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
            const layout = surface.children[0].surface;
            if (size.width >= 100 and size.height > 0) {
                try std.testing.expectEqual(@as(usize, 3), layout.children.len);
                try std.testing.expect(layout.children[0].surface.widget.eql(root.listWidget()));
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
    try root.revealSession(&events);
    try std.testing.expectEqual(@as(usize, 1), opened.inits);
    try std.testing.expectEqualStrings("kept draft", opened.draft);
    try std.testing.expectEqual(@as(u16, 7), opened.scroll);
    try std.testing.expect(events.cmds.items[1].request_focus.eql(opened.widget()));
    try root.closeSession(&events);
    try std.testing.expect(root.session == null);
    try std.testing.expect(events.cmds.items[2].request_focus.eql(whole.widget()));
}

fn containsWidget(surface: vxfw.Surface, target: vxfw.Widget) bool {
    if (surface.widget.eql(target)) return true;
    for (surface.children) |child| if (containsWidget(child.surface, target)) return true;
    return false;
}

test "App root opens settings in both layouts and Escape closes only the topmost choice" {
    const Backend = struct {
        fn read(_: *anyopaque) !@import("preferences.zig").Values {
            return .{};
        }
        fn save(_: *anyopaque, _: @import("preferences.zig").Edit) !void {}
        fn saveState(_: *anyopaque) AppSettings.SaveState {
            return .idle;
        }
        fn upgrade(_: *anyopaque) !void {}
        fn run(_: *anyopaque) ?@import("upgrade_status.zig").Run {
            return null;
        }
        fn caps(_: *anyopaque) @import("overview_view.zig").Caps {
            return .{};
        }
    };
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
    var session: Pane = .{};
    var data: u8 = 0;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u16{ 140, 46 }) |width| {
        var root: Self = .{ .overview = whole.widget(), .list = list.widget(), .compose = compose.widget(), .settings_page = .{ .backend = .{
            .context = &data,
            .read = Backend.read,
            .save = Backend.save,
            .save_state = Backend.saveState,
            .upgrade = Backend.upgrade,
            .run = Backend.run,
            .caps = Backend.caps,
        } } };
        const draw_context: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} };
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        _ = try root.widget().draw(draw_context);
        try root.openSettings(&ctx);
        try std.testing.expect(root.settings_open);
        try std.testing.expectEqual(width < split_at, root.settings_page.narrow);
        try std.testing.expect(ctx.cmds.items[0].request_focus.eql(root.settings_page.widget()));
        try std.testing.expectEqual(width >= split_at, root.listVisible());
        const opened = try root.widget().draw(draw_context);
        const layout = opened.children[0].surface;
        const layer = if (width >= split_at) layout.children[2].surface else layout;
        try std.testing.expectEqual(@as(u16, if (width >= split_at) 99 else 46), layer.size.width);
        try std.testing.expect(layer.children[1].surface.children[0].surface.widget.eql(root.settings_page.widget()));
        if (width >= split_at) try std.testing.expect(layout.children[0].surface.widget.eql(root.listWidget()));

        // Escape is routed by the actual Layer in the drawn focus ancestry.
        try root.settings_page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(root.settings_page.hasChoice());
        ctx.phase = .capturing;
        try layer.widget.captureEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
        try std.testing.expect(root.settings_open);
        try std.testing.expect(!root.settings_page.hasChoice());
        try std.testing.expect(ctx.consume_event);
        ctx.consume_event = false;
        try layer.widget.captureEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
        try std.testing.expect(!root.settings_open);
        try std.testing.expect(ctx.cmds.items[ctx.cmds.items.len - 1].request_focus.eql(root.listWidget()));
        const closed = try root.widget().draw(draw_context);
        const closed_layout = closed.children[0].surface;
        const focus = ctx.cmds.items[ctx.cmds.items.len - 1].request_focus;
        try std.testing.expect(focus.eventHandler != null);
        const list_surface = if (width >= split_at) closed_layout.children[0].surface else closed_layout;
        try std.testing.expect(containsWidget(list_surface, focus));
        const commands = ctx.cmds.items.len;
        try focus.handleEvent(&ctx, .focus_in);
        try std.testing.expectEqual(commands, ctx.cmds.items.len);
        try std.testing.expect((if (width >= split_at) closed_layout.children[2].surface.widget else closed_layout.widget).eql(if (width >= split_at) compose.widget() else whole.widget()));

        try root.openSettings(&ctx);
        try root.openSession(&ctx, session.widget());
        try std.testing.expect(!root.settings_open);
        try std.testing.expect(root.session.?.eql(session.widget()));
        // Closing settings derives the pane from the retained Session; at
        // phone width it fills the screen again, without changing custody.
        try root.openSettings(&ctx);
        try root.closeSettings(&ctx);
        const returned = try root.widget().draw(draw_context);
        const returned_layout = returned.children[0].surface;
        try std.testing.expect(containsWidget(returned_layout, session.widget()));
        try std.testing.expect(root.session.?.eql(session.widget()));
        try std.testing.expectEqual(width >= split_at, root.listVisible());
        const returned_focus = ctx.cmds.items[ctx.cmds.items.len - 1].request_focus;
        try std.testing.expect(returned_focus.eql(if (width >= split_at) root.listWidget() else session.widget()));
        try std.testing.expect(containsWidget(returned_layout, returned_focus));
    }
}

test "App root keeps settings focus while a hidden Session ticks and retains other commands" {
    const Hidden = struct {
        ticks: usize = 0,
        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .eventHandler = @This().event, .drawFn = @This().draw };
        }
        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .widget = self.widget(), .size = ctx.max.size(), .buffer = &.{}, .children = &.{} };
        }
        fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (input != .tick) return;
            self.ticks += 1;
            try ctx.requestFocus(self.widget());
            try ctx.tick(7, self.widget());
            ctx.redraw = true;
        }
    };
    const whole: vxfw.Text = .{ .text = "Overview" };
    var hidden: Hidden = .{};
    var root: Self = .{ .overview = whole.widget(), .list = whole.widget(), .compose = whole.widget(), .session = hidden.widget(), .settings_open = true };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try ctx.requestFocus(root.settings_page.widget());
    try root.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqual(@as(usize, 1), hidden.ticks);
    try std.testing.expect(root.session.?.eql(hidden.widget()));
    try std.testing.expect(root.settings_open);
    try std.testing.expect(ctx.redraw);
    try std.testing.expectEqual(@as(usize, 3), ctx.cmds.items.len);
    try std.testing.expect(ctx.cmds.items[0].request_focus.eql(root.settings_page.widget()));
    try std.testing.expect(ctx.cmds.items[1] == .tick);
    try std.testing.expect(ctx.cmds.items[2] == .tick);
    try root.closeSettings(&ctx);
    try std.testing.expect(!root.settings_open);
    try std.testing.expect(root.session.?.eql(hidden.widget()));
    try std.testing.expect(ctx.cmds.items[3].request_focus.eql(hidden.widget()));
    // Closing settings returns presentation ownership to the retained Session.
    ctx.cmds.clearRetainingCapacity();
    try root.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(ctx.cmds.items[0].request_focus.eql(hidden.widget()));
}
