//! Screen selection and the one recurring application tick. Screens own their
//! workers and apply completed results when they receive that tick.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Split = @import("widgets/Split.zig");
const AppSettings = @import("app_settings.zig");
const TerminalApp = @import("TerminalApp.zig");
const app_input = @import("app_input.zig");
const Self = @This();

pub const list_width = 40;
pub const split_at = 100;

/// A pane core's key owner: Root hands it each key and
/// paste mark `app_input.step` routes to that pane, with its delivery.
pub const Keys = struct {
    context: *anyopaque,
    take: *const fn (*anyopaque, *vxfw.EventContext, vxfw.Event, app_input.Effects.Delivery) anyerror!void,
};

/// The composed main screen ends its presentation when Root changes panes.
pub const MainPresentation = struct {
    context: *anyopaque,
    close: *const fn (*anyopaque) void,
};
main_presentation: ?MainPresentation = null,

overview: vxfw.Widget,
/// The overview's key owner: Root hands it each key and
/// paste mark `app_input.step` routes to the overview, with what it
/// arrived under. A Root with no overview core (UI-only tests and native
/// probes) hands those events to the `overview` widget instead.
overview_keys: ?Keys = null,
list: vxfw.Widget,
divider: Split.Divider = .{},
session: ?vxfw.Widget = null,
/// The open Session's key owner, which `openSession` and `closeSession`
/// set with `session`. A Session with none (UI-only tests) has its widget
/// handed those events instead.
session_keys: ?Keys = null,
settings_page: AppSettings = .{},
/// The sign-in page its owner supplies; Root only routes to and draws it.
sign_in: ?vxfw.Widget = null,
/// The layer over the main pane and the paste in progress; `app_input.step`
/// alone changes it.
input: app_input.State = .{},
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
    pane: app_input.Pane,
};

/// One derived pane decision drives drawing, visibility and return focus.
fn chooseLayout(self: *const Self) Layout {
    std.debug.assert(!self.input.layer.signInOpen() or self.sign_in != null);
    return .{
        .split = self.size.width >= split_at and app_input.pane(self.input.layer, self.session != null) != .overview,
        .pane = app_input.pane(self.input.layer, self.session != null),
    };
}

pub fn closeMainPresentation(self: *Self) void {
    if (self.main_presentation) |owner| owner.close(owner.context);
}

pub fn openSession(self: *Self, ctx: *vxfw.EventContext, session: vxfw.Widget, keys: ?Keys) !void {
    std.debug.assert(self.session == null);
    self.session = session;
    self.session_keys = keys;
    try self.showMain(ctx);
    try session.handleEvent(ctx, .init);
    ctx.redraw = true;
}

/// Show the main pane: the open Session, else the overview. Navigation
/// selects it before it is attempted, since a Session departure may stay
/// here with a notice, and Esc from settings returns to it.
pub fn showMain(self: *Self, ctx: *vxfw.EventContext) !void {
    try self.navigate(ctx, .show_main);
}

/// Settings takes the place of the main pane; it is no content of a feed.
/// The page reloads first, so a failed reload leaves the layer as it was.
pub fn openSettings(self: *Self, ctx: *vxfw.EventContext) !void {
    try self.settings_page.refresh();
    self.closeMainPresentation();
    try self.navigate(ctx, .open_settings);
}

/// The sign-in page covers the main pane or settings until it closes back.
pub fn openSignIn(self: *Self, ctx: *vxfw.EventContext) !void {
    self.closeMainPresentation();
    self.settings_page.cancelChoice();
    try self.navigate(ctx, .open_sign_in);
}

pub fn closeSignIn(self: *Self, ctx: *vxfw.EventContext) !void {
    try self.navigate(ctx, .close_sign_in);
}

/// Signing in closes the page and any settings under it, showing main.
pub fn signedIn(self: *Self, ctx: *vxfw.EventContext) !void {
    try self.navigate(ctx, .signed_in);
}

fn navigate(self: *Self, ctx: *vxfw.EventContext, request: app_input.Input) !void {
    const effects = app_input.step(&self.input, self.facts(null), request);
    std.debug.assert(effects.route == .pass);
    try self.apply(ctx, effects, null);
}

/// Whether a Session is open and, only while the settings page is open,
/// the page's answers for this event, read by value.
fn facts(self: *const Self, key: ?vaxis.Key) app_input.Facts {
    const session_open = self.session != null;
    if (!self.input.layer.settingsOpen()) return .{ .session_open = session_open };
    const page = &self.settings_page;
    return .{ .session_open = session_open, .settings = .{
        .keys_open = page.keys_open,
        .choice_open = page.hasChoice(),
        .takes_key = if (key) |pressed| page.takesKey(pressed) else false,
        .takes_paste = page.takesPaste(),
        .upgrade_takes_escape = page.upgradeTakesEscape(),
    } };
}

/// Applies what `app_input.step` decided, in its field order. `routed` is
/// the terminal event, null for a navigation request.
fn apply(self: *Self, ctx: *vxfw.EventContext, effects: app_input.Effects, routed: ?vxfw.Event) !void {
    switch (effects.page) {
        .keep => {},
        .close_keys => self.settings_page.keys_open = false,
        .cancel_choice => self.settings_page.cancelChoice(),
        .reset => {
            self.closeMainPresentation();
            self.settings_page.cancelChoice();
            self.settings_page.keys_open = false;
        },
    }
    if (effects.focus) |focus| try ctx.requestFocus(switch (focus) {
        .main => self.session orelse self.overview,
        .settings => self.settings_page.widget(),
        .sign_in => self.sign_in.?,
    });
    switch (effects.route) {
        .pass => {},
        .sign_in => {
            try self.sign_in.?.handleEvent(ctx, routed.?);
            ctx.consumeEvent();
        },
        .overview => |delivery| {
            if (self.overview_keys) |keys| try keys.take(keys.context, ctx, routed.?, delivery) else try self.overview.handleEvent(ctx, routed.?);
            ctx.consumeEvent();
        },
        .session => |delivery| {
            if (self.session_keys) |keys| try keys.take(keys.context, ctx, routed.?, delivery) else try self.session.?.handleEvent(ctx, routed.?);
            ctx.consumeEvent();
        },
        .colors => {
            try self.overview.handleEvent(ctx, routed.?);
            ctx.consumeEvent();
        },
        .swallow => ctx.consumeEvent(),
    }
    if (effects.redraw) ctx.redraw = true;
}

/// The Session has settled its borrowers before calling this. No terminal
/// leaves raw mode and no input stream is transferred between screens.
pub fn closeSession(self: *Self, ctx: *vxfw.EventContext) !void {
    self.closeMainPresentation();
    self.session = null;
    self.session_keys = null;
    if (!self.input.layer.settingsOpen()) self.settings_page.cancelChoice();
    if (self.input.layer == .main) try ctx.requestFocus(self.overview);
    ctx.redraw = true;
}

/// Every routed event goes through `app_input.step`; Root only applies it.
fn capture(raw: *anyopaque, ctx: *vxfw.EventContext, routed: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const input: app_input.Input = switch (routed) {
        .key_press => |key| .{ .key = .{ .named = @import("keymap.zig").named(key) } },
        .paste_start => .paste_start,
        .paste_end => .paste_end,
        .mouse => |mouse| .{ .mouse = switch (mouse.button) {
            .wheel_up, .wheel_down, .wheel_left, .wheel_right => .wheel,
            else => if (mouse.type == .motion) .motion else .click,
        } },
        .key_release => .key_release,
        .color_report, .color_scheme => .colors,
        else => .other,
    };
    const key = if (routed == .key_press) routed.key_press else null;
    try self.apply(ctx, app_input.step(&self.input, self.facts(key), input), routed);
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (input) {
        .init => {
            try ctx.requestFocus(self.overview);
            try self.overview.handleEvent(ctx, .init);
            if (self.input.layer.signInOpen()) try ctx.requestFocus(self.sign_in.?);
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
            // Leaving is terminal for this dispatch: a child must not start
            // old-client reobservation after Upgrade has requested departure.
            if (ctx.quit) return;
            if (self.session) |session| try session.handleEvent(ctx, .tick);
            if (ctx.quit) return;
            if (self.input.layer != .main) {
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
                if (self.input.layer.settingsOpen()) try self.settings_page.widget().handleEvent(ctx, .tick);
            }
            if (ctx.quit) return;
            if (self.sign_in) |page| try page.handleEvent(ctx, .tick);
            if (!ctx.quit) try ctx.tick(16, self.widget());
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
        .overview => self.overview,
        .session => self.session.?,
        .sign_in => self.sign_in.?,
        .settings => self.settings_page.widget(),
    };
    const child = if (layout.split) split: {
        const split = try ctx.arena.create(Split);
        split.* = .{
            .left = self.list,
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
    var root: Self = .{ .overview = overview.widget(), .list = overview.widget() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const draw_context: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .cell_arena = arena.allocator(),
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
    try root.openSession(&ctx, session.widget(), null);
    const opened = try root.widget().draw(draw_context);
    try std.testing.expectEqual(@as(usize, 1), opened.children.len);
    try std.testing.expectEqualStrings("S", opened.children[0].surface.buffer[0].char.grapheme);
    try root.closeSession(&ctx);
    const closed = try root.widget().draw(draw_context);
    try std.testing.expectEqualStrings("O", closed.children[0].surface.buffer[0].char.grapheme);
}

test "App root keeps the overview whole and places the list beside an open child at desktop widths" {
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
    var opened: Pane = .{};
    var root: Self = .{ .overview = whole.widget(), .list = list.widget() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |active| {
        root.session = if (active) opened.widget() else null;
        for ([_]vxfw.Size{ .{ .width = 140, .height = 40 }, .{ .width = 46, .height = 26 }, .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 1 }, .{ .width = 41, .height = 1 }, .{ .width = 99, .height = 1 }, .{ .width = 100, .height = 1 }, .{ .width = 100, .height = 0 } }) |size| {
            const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{} };
            const surface = try root.widget().draw(ctx);
            try std.testing.expectEqual(size, surface.size);
            const layout = surface.children[0].surface;
            if (active and size.width >= split_at and size.height > 0) {
                try std.testing.expectEqual(@as(usize, 3), layout.children.len);
                try std.testing.expect(layout.children[0].surface.widget.eql(list.widget()));
                try std.testing.expectEqual(vxfw.RelativePoint{ .row = 0, .col = 0 }, layout.children[0].origin);
                try std.testing.expectEqual(@as(u16, 40), layout.children[0].surface.size.width);
                try std.testing.expectEqual(@as(i17, 40), layout.children[1].origin.col);
                try std.testing.expectEqualStrings("│", layout.children[1].surface.buffer[0].char.grapheme);
                try std.testing.expectEqual(vxfw.RelativePoint{ .row = 0, .col = 41 }, layout.children[2].origin);
                try std.testing.expectEqual(size.width - 41, layout.children[2].surface.size.width);
                try std.testing.expect(layout.children[2].surface.widget.eql(if (active) opened.widget() else whole.widget()));
            } else if (!active or size.width < split_at) {
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
    var opened: Pane = .{};
    var root: Self = .{ .overview = whole.widget(), .list = list.widget() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try root.openSession(&events, opened.widget(), null);
    try std.testing.expectEqual(@as(usize, 1), events.cmds.items.len);
    try std.testing.expect(events.cmds.items[0].request_focus.eql(opened.widget()));
    for ([_]u16{ 140, 46, 99, 100, 46, 140 }) |width| {
        const surface = try root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 26 }, .cell_size = .{} });
        try std.testing.expect(root.session.?.eql(opened.widget()));
        try std.testing.expectEqual(@as(usize, 1), events.cmds.items.len);
        try std.testing.expectEqual(@as(usize, 1), opened.inits);
        try std.testing.expectEqualStrings("kept draft", opened.draft);
        try std.testing.expectEqual(@as(u16, 7), opened.scroll);
        var screen: vaxis.Screen = try .init(arena.allocator(), .{ .cols = width, .rows = 26, .x_pixel = 0, .y_pixel = 0 });
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 26, .screen = &screen };
        try surface.render(window, opened.widget());
        try std.testing.expect(screen.cursor_vis);
        try std.testing.expectEqual(@as(u16, if (width >= 100) 41 else 0), screen.cursor.col);
    }
    try root.showMain(&events);
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

test "App root opens settings in both layouts and Escape closes the choice, then the page" {
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
        /// Gives each pane an address of its own, so widgets compare apart.
        id: u8 = 0,
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
    var session: Pane = .{};
    var data: u8 = 0;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u16{ 140, 46 }) |width| {
        var root: Self = .{ .overview = whole.widget(), .list = list.widget(), .settings_page = .{ .backend = .{
            .context = &data,
            .read = Backend.read,
            .save = Backend.save,
            .save_state = Backend.saveState,
            .upgrade = Backend.upgrade,
            .run = Backend.run,
            .caps = Backend.caps,
        } } };
        const draw_context: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} };
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        _ = try root.widget().draw(draw_context);
        try root.openSettings(&ctx);
        try std.testing.expect(root.input.layer.settingsOpen());
        try std.testing.expect(ctx.cmds.items[0].request_focus.eql(root.settings_page.widget()));
        try std.testing.expectEqual(width >= split_at, root.listVisible());
        const opened = try root.widget().draw(draw_context);
        try std.testing.expectEqual(width < split_at, root.settings_page.narrow);
        const layout = opened.children[0].surface;
        const page = if (width >= split_at) layout.children[2].surface else layout;
        try std.testing.expect(page.widget.eql(root.settings_page.widget()));
        try std.testing.expectEqual(@as(u16, if (width >= split_at) 99 else 46), page.size.width);
        if (width >= split_at) try std.testing.expect(layout.children[0].surface.widget.eql(list.widget()));
        // The page takes the pane's place: nothing is drawn under it.
        try std.testing.expect(!containsWidget(opened, whole.widget()));

        // Root captures Escape ahead of the focused page.
        const escape: vxfw.Event = .{ .key_press = .{ .codepoint = vaxis.Key.escape } };
        root.settings_page.select(.keys);
        try root.settings_page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(root.settings_page.keys_open);
        ctx.phase = .capturing;
        try root.widget().captureEvent(&ctx, escape);
        try std.testing.expect(!root.settings_page.keys_open);
        try std.testing.expect(root.input.layer.settingsOpen());
        try std.testing.expect(root.session == null);
        root.settings_page.select(.model);
        try root.settings_page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(root.settings_page.hasChoice());
        ctx.phase = .capturing;
        try root.widget().captureEvent(&ctx, escape);
        try std.testing.expect(root.input.layer.settingsOpen());
        try std.testing.expect(!root.settings_page.hasChoice());
        try std.testing.expect(ctx.consume_event);
        ctx.consume_event = false;
        try root.widget().captureEvent(&ctx, escape);
        try std.testing.expect(!root.input.layer.settingsOpen());
        try std.testing.expect(ctx.consume_event);
        // Focus returns where it was before the page opened.
        try std.testing.expect(ctx.cmds.items[ctx.cmds.items.len - 1].request_focus.eql(whole.widget()));
        const closed = try root.widget().draw(draw_context);
        const closed_layout = closed.children[0].surface;
        try std.testing.expect(closed_layout.widget.eql(whole.widget()));
        try std.testing.expectEqual(width, closed_layout.size.width);
        try std.testing.expect(root.listVisible());
        // With no page open, Escape is the focused screen's.
        ctx.consume_event = false;
        try root.widget().captureEvent(&ctx, escape);
        try std.testing.expect(ctx.consume_event and !root.input.layer.settingsOpen());

        try root.openSettings(&ctx);
        try root.openSession(&ctx, session.widget(), null);
        try std.testing.expect(!root.input.layer.settingsOpen());
        try std.testing.expect(root.session.?.eql(session.widget()));
        // Escape from settings shows the retained Session again at both
        // widths and focuses it, without changing custody.
        try root.openSettings(&ctx);
        root.settings_page.select(.keys);
        try root.settings_page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(root.settings_page.keys_open);
        ctx.consume_event = false;
        try root.widget().captureEvent(&ctx, escape);
        try std.testing.expect(ctx.consume_event);
        try std.testing.expect(!root.settings_page.keys_open);
        try std.testing.expect(root.input.layer.settingsOpen());
        try std.testing.expect(root.session.?.eql(session.widget()));
        try std.testing.expect(ctx.cmds.items[ctx.cmds.items.len - 1].request_focus.eql(root.settings_page.widget()));
        try root.widget().captureEvent(&ctx, escape);
        const returned = try root.widget().draw(draw_context);
        try std.testing.expect(containsWidget(returned, session.widget()));
        try std.testing.expect(root.session.?.eql(session.widget()));
        try std.testing.expectEqual(width >= split_at, root.listVisible());
        try std.testing.expect(ctx.cmds.items[ctx.cmds.items.len - 1].request_focus.eql(session.widget()));
    }
}

test "App root gives Escape to a cancellable Upgrade after a choice and before closing settings, and consumes pasted keys outside the Model filter" {
    const upgrade_status = @import("upgrade_status.zig");
    const Fixture = struct {
        run: ?upgrade_status.Run = null,
        escapes: usize = 0,
        others: usize = 0,
        fn read(_: *anyopaque) !@import("preferences.zig").Values {
            return .{};
        }
        fn save(_: *anyopaque, _: @import("preferences.zig").Edit) !void {}
        fn saveState(_: *anyopaque) AppSettings.SaveState {
            return .idle;
        }
        fn upgrade(_: *anyopaque) !void {}
        fn running(raw: *anyopaque) ?upgrade_status.Run {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.run;
        }
        fn caps(_: *anyopaque) @import("overview_view.zig").Caps {
            return .{};
        }
        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .eventHandler = @This().event, .drawFn = @This().draw };
        }
        fn event(raw: *anyopaque, _: *vxfw.EventContext, input: vxfw.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (input != .key_press) return;
            if (input.key_press.matches(vaxis.Key.escape, .{})) self.escapes += 1 else self.others += 1;
        }
        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .widget = self.widget(), .size = ctx.max.size(), .buffer = &.{}, .children = &.{} };
        }
    };
    const found: upgrade_status.Found = .{ .host = .none };
    const runs = [_]?upgrade_status.Run{
        null,
        .checking,
        .cancelling,
        .{ .installing = .{ .found = found } },
        .{ .installing = .{ .found = found, .step = .publishing } },
        .{ .installing = .{ .found = found, .step = .restarting } },
        .{ .ended = .{ .how = .cancelled, .outcome = .unchanged } },
    };
    const escape: vxfw.Event = .{ .key_press = .{ .codepoint = vaxis.Key.escape } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (runs) |run| for ([_]bool{ false, true }) |choice| {
        var fixture: Fixture = .{ .run = run };
        var root: Self = .{ .overview = fixture.widget(), .list = fixture.widget(), .settings_page = .{ .backend = .{
            .context = &fixture,
            .read = Fixture.read,
            .save = Fixture.save,
            .save_state = Fixture.saveState,
            .upgrade = Fixture.upgrade,
            .run = Fixture.running,
            .caps = Fixture.caps,
        } } };
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty, .phase = .capturing };
        try root.openSettings(&ctx);
        root.settings_page.select(.keys);
        try root.settings_page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(root.settings_page.keys_open);
        ctx.consume_event = false;
        try root.widget().captureEvent(&ctx, escape);
        try std.testing.expect(ctx.consume_event);
        try std.testing.expect(!root.settings_page.keys_open);
        try std.testing.expect(root.input.layer.settingsOpen());
        try std.testing.expectEqual(@as(usize, 0), fixture.escapes);
        root.settings_page.select(.model);
        if (choice) {
            try root.settings_page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
            try std.testing.expect(root.settings_page.hasChoice());
            ctx.consume_event = false;
            try root.widget().captureEvent(&ctx, escape);
            try std.testing.expect(ctx.consume_event);
            try std.testing.expect(!root.settings_page.hasChoice());
            try std.testing.expect(root.input.layer.settingsOpen());
            try std.testing.expectEqual(@as(usize, 0), fixture.escapes);
        }
        // The run's own rule, not this table, says which phases take Escape.
        const cancels = if (run) |value| value.takesEscape() else false;
        ctx.consume_event = false;
        try root.widget().captureEvent(&ctx, escape);
        try std.testing.expect(ctx.consume_event);
        try std.testing.expectEqual(@as(usize, @intFromBool(cancels)), fixture.escapes);
        try std.testing.expectEqual(cancels, root.input.layer.settingsOpen());
        if (!cancels) continue;
        // The page's own keys stay with it; every other key is the app's,
        // whose owner decides what it does under the page.
        for ([_]vaxis.Key{ .{ .codepoint = vaxis.Key.up }, .{ .codepoint = vaxis.Key.down }, .{ .codepoint = vaxis.Key.enter } }) |key| {
            ctx.consume_event = false;
            try root.widget().captureEvent(&ctx, .{ .key_press = key });
            try std.testing.expect(!ctx.consume_event);
        }
        try std.testing.expectEqual(@as(usize, 0), fixture.others);
        for ([_]vaxis.Key{ .{ .codepoint = 'c', .mods = .{ .ctrl = true } }, .{ .codepoint = 'd', .mods = .{ .ctrl = true } }, .{ .codepoint = 'a' }, .{ .codepoint = vaxis.Key.end } }, 1..) |key, count| {
            ctx.consume_event = false;
            try root.widget().captureEvent(&ctx, .{ .key_press = key });
            try std.testing.expect(ctx.consume_event);
            try std.testing.expectEqual(count, fixture.others);
            try std.testing.expect(root.input.layer.settingsOpen());
        }
    };
    // Without a text editor, no pasted key reaches the page or closes it.
    var pasted: Fixture = .{};
    var page: Self = .{ .overview = pasted.widget(), .list = pasted.widget() };
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty, .phase = .capturing };
    try page.openSettings(&events);
    try page.widget().captureEvent(&events, .paste_start);
    for ([_]u21{ vaxis.Key.enter, vaxis.Key.escape, vaxis.Key.down, 'a' }) |codepoint| {
        events.consume_event = false;
        try page.widget().captureEvent(&events, .{ .key_press = .{ .codepoint = codepoint } });
        try std.testing.expect(events.consume_event);
        try std.testing.expect(page.input.layer.settingsOpen());
    }
    try page.widget().captureEvent(&events, .paste_end);
    events.consume_event = false;
    try page.widget().captureEvent(&events, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expect(!events.consume_event);
    try page.openSettings(&events);
    // Ctrl-G closes as Escape does.
    try page.widget().captureEvent(&events, .{ .key_press = .{ .codepoint = 'g', .mods = .{ .ctrl = true } } });
    try std.testing.expect(!page.input.layer.settingsOpen());
    try page.openSettings(&events);
    try page.widget().captureEvent(&events, escape);
    try std.testing.expect(!page.input.layer.settingsOpen());
    // With settings closed Escape is the main pane's to decide: Root hands
    // it to the overview, or to the open Session, once and stops it.
    var fixture: Fixture = .{ .run = .checking };
    var root: Self = .{ .overview = fixture.widget(), .list = fixture.widget() };
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty, .phase = .capturing };
    try root.widget().captureEvent(&ctx, escape);
    try std.testing.expect(ctx.consume_event);
    try std.testing.expectEqual(@as(usize, 1), fixture.escapes);
    var session: Fixture = .{};
    root.session = session.widget();
    ctx.consume_event = false;
    try root.widget().captureEvent(&ctx, escape);
    try std.testing.expect(ctx.consume_event);
    try std.testing.expectEqual(@as(usize, 1), fixture.escapes);
    try std.testing.expectEqual(@as(usize, 1), session.escapes);
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
    var root: Self = .{ .overview = whole.widget(), .list = whole.widget(), .session = hidden.widget(), .input = .{ .layer = .settings } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try ctx.requestFocus(root.settings_page.widget());
    try root.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqual(@as(usize, 1), hidden.ticks);
    try std.testing.expect(root.session.?.eql(hidden.widget()));
    try std.testing.expect(root.input.layer.settingsOpen());
    try std.testing.expect(ctx.redraw);
    try std.testing.expectEqual(@as(usize, 3), ctx.cmds.items.len);
    try std.testing.expect(ctx.cmds.items[0].request_focus.eql(root.settings_page.widget()));
    try std.testing.expect(ctx.cmds.items[1] == .tick);
    try std.testing.expect(ctx.cmds.items[2] == .tick);
    try root.showMain(&ctx);
    try std.testing.expect(!root.input.layer.settingsOpen());
    try std.testing.expect(root.session.?.eql(hidden.widget()));
    try std.testing.expect(ctx.cmds.items[3].request_focus.eql(hidden.widget()));
    // Closing settings returns presentation ownership to the retained Session.
    ctx.cmds.clearRetainingCapacity();
    try root.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(ctx.cmds.items[0].request_focus.eql(hidden.widget()));
}

test "App root relaunch departure stops child ticks and scheduling at the first quit" {
    const Pane = struct {
        ticks: usize = 0,
        quit: bool = false,
        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .eventHandler = onEvent, .drawFn = drawPane };
        }
        fn onEvent(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (input == .tick) {
                self.ticks += 1;
                if (self.quit) ctx.quit = true;
            }
        }
        fn drawPane(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .widget = self.widget(), .size = ctx.max.size(), .buffer = &.{}, .children = &.{} };
        }
    };
    for (std.enums.values(enum { overview, session, sign_in, none })) |quitter| {
        for ([_]bool{ false, true }) |settings| {
            var overview: Pane = .{ .quit = quitter == .overview };
            var session: Pane = .{ .quit = quitter == .session };
            var sign_in: Pane = .{ .quit = quitter == .sign_in };
            var root: Self = .{ .overview = overview.widget(), .list = overview.widget(), .session = session.widget(), .sign_in = sign_in.widget(), .input = .{ .layer = .{ .sign_in = .{ .over = if (settings) .settings else .main } } } };
            var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
            defer ctx.cmds.deinit(std.testing.allocator);
            try root.widget().handleEvent(&ctx, .tick);
            try std.testing.expectEqual(@as(usize, 1), overview.ticks);
            try std.testing.expectEqual(@as(usize, if (quitter == .overview) 0 else 1), session.ticks);
            try std.testing.expectEqual(@as(usize, if (quitter == .overview or quitter == .session) 0 else 1), sign_in.ticks);
            try std.testing.expectEqual(quitter != .none, ctx.quit);
            try std.testing.expectEqual(quitter == .none, ctx.cmds.items.len != 0);
        }
    }
}

test "App root routes Model filter typing to settings and Escape closes only its choice" {
    var text: vxfw.Text = .{ .text = "overview" };
    var root: Self = .{ .overview = text.widget(), .list = text.widget(), .input = .{ .layer = .settings } };
    root.settings_page.model_choice.open(null, .codex, "");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty, .phase = .capturing };
    const typed: vxfw.Event = .{ .key_press = .{ .codepoint = 'g', .text = "gpt" } };
    try root.widget().captureEvent(&ctx, typed);
    try std.testing.expect(!ctx.consume_event);
    try root.settings_page.widget().handleEvent(&ctx, typed);
    try std.testing.expectEqualStrings("gpt", root.settings_page.model_choice.editor.text());
    ctx.consume_event = false;
    try root.widget().captureEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
    try std.testing.expect(ctx.consume_event);
    try std.testing.expect(!root.settings_page.hasChoice());
    try std.testing.expect(root.input.layer.settingsOpen());
    ctx.consume_event = false;
    try root.widget().captureEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
    try std.testing.expect(ctx.consume_event);
    try std.testing.expect(!root.input.layer.settingsOpen());
}

test "App root routes typed and pasted settings text only to the Model filter without pasted activation" {
    const preferences = @import("preferences.zig");
    const Fixture = struct {
        saves: usize = 0,
        overview_keys: usize = 0,
        edit: ?preferences.Edit = null,
        fn backend(self: *@This()) AppSettings.Backend {
            return .{ .context = self, .read = read, .save = save, .save_state = saveState, .upgrade = upgrade, .run = run, .caps = caps };
        }
        fn read(_: *anyopaque) !preferences.Values {
            return .{};
        }
        fn save(raw: *anyopaque, edit: preferences.Edit) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.saves += 1;
            self.edit = edit;
        }
        fn saveState(_: *anyopaque) AppSettings.SaveState {
            return .pending;
        }
        fn upgrade(_: *anyopaque) !void {}
        fn run(_: *anyopaque) ?@import("upgrade_status.zig").Run {
            return null;
        }
        fn caps(_: *anyopaque) @import("overview_view.zig").Caps {
            return .{};
        }
        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .eventHandler = @This().event, .drawFn = @This().draw };
        }
        fn event(raw: *anyopaque, _: *vxfw.EventContext, input: vxfw.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (input == .key_press) self.overview_keys += 1;
        }
        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .widget = self.widget(), .size = ctx.max.size(), .buffer = &.{}, .children = &.{} };
        }
    };
    const Choice = enum { model, ordinary, none };
    const text = "gpt-5.5";
    const app_events = @import("testing/app_events.zig");
    for (std.enums.values(Choice)) |choice| for ([_]bool{ false, true }) |pasted| {
        errdefer std.debug.print("settings text choice={s}, pasted={}\n", .{ @tagName(choice), pasted });
        var fixture: Fixture = .{};
        var root: Self = .{ .overview = fixture.widget(), .list = fixture.widget(), .settings_page = .{ .backend = fixture.backend() } };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        try root.openSettings(&ctx);
        const page = &root.settings_page;
        page.select(switch (choice) {
            .model => .model,
            .ordinary => .effort,
            .none => .notifications,
        });
        if (choice != .none) try app_events.send(&ctx, "\r", root.widget(), page.widget());
        const row = page.panel.selected;
        try app_events.send(&ctx, if (pasted) "\x1b[200~" ++ text ++ "\x1b[201~" else text, root.widget(), page.widget());
        try std.testing.expectEqualStrings(if (choice == .model) text else "", page.model_choice.editor.text());
        try std.testing.expectEqual(@as(usize, if (choice == .model or pasted) 0 else text.len), fixture.overview_keys);
        try std.testing.expectEqual(choice != .none, page.hasChoice());
        try std.testing.expectEqual(row, page.panel.selected);
        try std.testing.expect(!root.input.pasting and !page.model_choice.pasting);
        try std.testing.expectEqual(@as(usize, 0), fixture.saves);
        // A pasted line break is never the Enter that chooses or acts.
        const overview_keys = fixture.overview_keys;
        const selected = if (page.panel.choice) |open| open.selected else null;
        try app_events.send(&ctx, "\x1b[200~\r\x1b[201~", root.widget(), page.widget());
        try std.testing.expectEqual(@as(usize, 0), fixture.saves);
        try std.testing.expectEqual(overview_keys, fixture.overview_keys);
        try std.testing.expectEqual(choice != .none, page.hasChoice());
        try std.testing.expectEqual(selected, if (page.panel.choice) |open| open.selected else null);
        try std.testing.expect(root.input.layer.settingsOpen() and !ctx.quit and !root.input.pasting);
        // A real Enter after the paste still changes the selected field.
        try app_events.send(&ctx, "\r", root.widget(), page.widget());
        try std.testing.expectEqual(@as(usize, 1), fixture.saves);
        switch (choice) {
            .model => try std.testing.expectEqualStrings(text, fixture.edit.?.model.set),
            .ordinary => try std.testing.expect(fixture.edit.?.reasoning_effort == .clear),
            .none => try std.testing.expectEqual(@as(?bool, false), fixture.edit.?.notifications),
        }
    };
}

test "Sign-in frames keep the list at 140 columns and the code link, browser link, masked entries and failure at 46" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const empty: vxfw.Text = .{ .text = "" };
    const list: vxfw.Text = .{ .text = " rui" };
    var root: Self = .{ .overview = empty.widget(), .list = list.widget(), .input = .{ .layer = .{ .sign_in = .{ .over = .main } } } };
    // As the page's owner does: the page names the app only when the
    // screen's list, whose header names it, is not shown.
    const Owner = struct {
        fn listVisible(raw: *anyopaque) bool {
            const owner: *Self = @ptrCast(@alignCast(raw));
            return owner.listVisible();
        }
    };
    var page: @import("SignIn.zig") = .{ .userdata = &root, .list_visible = Owner.listVisible };
    root.sign_in = page.widget();
    const SignIn = @import("SignIn.zig");
    const browser = try @import("os/pages.zig").Mapped(SignIn.Browser).map();
    defer browser.unmap();
    const link = "https://auth.openai.com/api/accounts/authorize?client_id=app_made_up&state=made-up";
    const pasted = "http://127.0.0.1:1455/auth/callback?code=made-up-grant";
    for ([_]u16{ 140, 46 }) |width| {
        for ([_]@import("sign_in.zig").Stage{ .choice, .browser_waiting, .codex_waiting, .key_entry, .failed }) |stage| {
            page.state = .{ .stage = stage, .failure = .answer };
            try page.code.set("BDL9-KI88H");
            const secret = "sk-secret";
            @memcpy(page.key.bytes[0..secret.len], secret);
            page.key.len = secret.len;
            browser.value.init();
            try browser.value.link.set(link);
            browser.value.edit(.{ .append = pasted });
            page.browser = if (stage == .browser_waiting) browser else null;
            defer page.browser = null;
            const surface = try root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 12 }, .cell_size = .{} });
            try std.testing.expectEqual(width >= split_at, root.listVisible());
            var screen = try vaxis.Screen.init(arena.allocator(), .{ .cols = width, .rows = 12, .x_pixel = 0, .y_pixel = 0 });
            try surface.render(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 12, .screen = &screen }, root.widget());
            var dump: std.Io.Writer.Allocating = .init(arena.allocator());
            var linked: usize = 0;
            var titles: usize = 0;
            for (0..12) |row| {
                var line: std.Io.Writer.Allocating = .init(arena.allocator());
                for (0..width) |col| {
                    const cell = screen.readCell(@intCast(col), @intCast(row)).?;
                    try line.writer.writeAll(cell.char.grapheme);
                    if (cell.link.uri.len != 0) {
                        // The browser's link is its whole address behind its host.
                        try std.testing.expectEqualStrings(if (stage == .browser_waiting) link else "https://auth.openai.com/codex/device", cell.link.uri);
                        try std.testing.expect(std.mem.indexOf(u8, if (stage == .browser_waiting) "auth.openai.com" else "auth.openai.com/codex/device", cell.char.grapheme) != null);
                        linked += 1;
                    }
                }
                if (row == 0) titles = std.mem.count(u8, line.written(), " rui");
                try dump.writer.writeAll(std.mem.trimEnd(u8, line.written(), " "));
                try dump.writer.writeByte('\n');
            }
            const text = dump.written();
            // One title on the top row: the list's beside the page, else the page's.
            try std.testing.expectEqual(@as(usize, 1), titles);
            try std.testing.expect(std.mem.startsWith(u8, text, " rui"));
            try std.testing.expect(std.mem.indexOf(u8, text, secret) == null);
            try std.testing.expect(std.mem.indexOf(u8, text, "made-up-grant") == null);
            // Tab offers the device code while the browser waits and after it failed.
            try std.testing.expectEqual(stage == .browser_waiting or stage == .failed, std.mem.indexOf(u8, text, "tab device code · esc back") != null);
            switch (stage) {
                .choice => try std.testing.expect(std.mem.indexOf(u8, text, "› ChatGPT    API key") != null),
                .browser_waiting => {
                    try std.testing.expectEqual(@as(usize, "auth.openai.com".len), linked);
                    try std.testing.expect(std.mem.indexOf(u8, text, "••••••••••") != null);
                },
                // SignIn's own test checks the failure line fits.
                .failed => {},
                .codex_waiting => {
                    try std.testing.expect(std.mem.indexOf(u8, text, "auth.openai.com/codex/device · BDL9-KI88H") != null);
                    try std.testing.expectEqual(@as(usize, "auth.openai.com/codex/device".len), linked);
                },
                .key_entry => try std.testing.expect(std.mem.indexOf(u8, text, "•••••••••") != null),
                else => unreachable,
            }
        }
    }
}

test "Sign-in input stays with the row over settings and a previously focused list" {
    const empty: vxfw.Text = .{ .text = "" };
    var page: @import("SignIn.zig") = .{};
    var root: Self = .{ .overview = empty.widget(), .list = empty.widget(), .sign_in = page.widget(), .input = .{ .layer = .{ .sign_in = .{ .over = .settings } } } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty, .phase = .capturing };
    const Events = @import("testing/app_events.zig").Events;
    var input: Events = .init("\x1b[C\r\x1b[200~sk-masked\r\x1b[201~");
    while (input.next()) |value| {
        ctx.consume_event = false;
        try root.widget().captureEvent(&ctx, value);
        try std.testing.expect(ctx.consume_event);
    }
    try std.testing.expectEqual(@import("sign_in.zig").Stage.key_entry, page.state.stage);
    try std.testing.expectEqualStrings("sk-masked", page.key.slice());
    try std.testing.expect(!root.settings_page.hasChoice());
    try root.widget().captureEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
    try std.testing.expectEqual(@import("sign_in.zig").Stage.choice, page.state.stage);
    try std.testing.expectEqual(@as(usize, 0), page.key.len);
    try std.testing.expect(root.input.layer.settingsOpen());
    try root.widget().captureEvent(&ctx, .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } });
    try std.testing.expect(ctx.quit);
}

test "Sign-in takes every click at each stage, over settings or not, and changes nothing" {
    const empty: vxfw.Text = .{ .text = "" };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const Stage = @import("sign_in.zig").Stage;
    for ([_]bool{ false, true }) |settings_open| for (std.enums.values(Stage)) |stage| {
        var page: @import("SignIn.zig") = .{ .state = .{ .stage = stage } };
        var root: Self = .{ .overview = empty.widget(), .list = empty.widget(), .sign_in = page.widget(), .input = .{ .layer = .{ .sign_in = .{ .over = if (settings_open) .settings else .main } } } };
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty, .phase = .capturing };
        for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| {
            ctx.consume_event = false;
            try root.widget().captureEvent(&ctx, .{ .mouse = .{ .col = 4, .row = 3, .button = .left, .type = kind, .mods = .{} } });
            try std.testing.expect(ctx.consume_event);
        }
        try std.testing.expect(root.input.layer.signInOpen());
        try std.testing.expectEqual(settings_open, root.input.layer.settingsOpen());
        try std.testing.expectEqual(stage, page.state.stage);
        try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);
    };
}

test "Root navigation closes the composed main presentation before focusing another pane" {
    const Owner = struct {
        root: *Self = undefined,
        closes: usize = 0,
        settings_when_closed: bool = false,
        session_when_closed: bool = false,
        fn close(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.closes += 1;
            self.settings_when_closed = self.root.input.layer.settingsOpen();
            self.session_when_closed = self.root.session != null;
        }
    };
    const empty: vxfw.Text = .{ .text = "" };
    var owner: Owner = .{};
    var root: Self = .{ .overview = empty.widget(), .list = empty.widget(), .main_presentation = .{ .context = &owner, .close = Owner.close } };
    owner.root = &root;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try root.openSettings(&ctx);
    try std.testing.expectEqual(@as(usize, 1), owner.closes);
    try std.testing.expect(!owner.settings_when_closed);
    try root.showMain(&ctx);
    try std.testing.expectEqual(@as(usize, 2), owner.closes);
    // The reducer commits the main layer before its reset effect closes scope.
    try std.testing.expect(!owner.settings_when_closed);
    try root.openSession(&ctx, empty.widget(), null);
    try std.testing.expectEqual(@as(usize, 3), owner.closes);
    try root.closeSession(&ctx);
    try std.testing.expectEqual(@as(usize, 4), owner.closes);
    try std.testing.expect(owner.session_when_closed);
    try std.testing.expect(root.session == null);
    // An unseen Session may leave while ordinary Settings remains active.
    // Its main presentation ends without cancelling the Settings field edit.
    try root.openSession(&ctx, empty.widget(), null);
    try root.openSettings(&ctx);
    root.settings_page.panel.fields = &.{.{ .label = "Effort", .value = "high" }};
    root.settings_page.panel.selected = 0;
    root.settings_page.panel.openChoice(&.{ "low", "high" }, 1);
    try root.closeSession(&ctx);
    try std.testing.expect(root.input.layer.settingsOpen());
    try std.testing.expect(root.settings_page.panel.choice != null);
    try std.testing.expectEqual(@as(usize, 7), owner.closes);
}
