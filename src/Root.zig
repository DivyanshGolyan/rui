const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Split = @import("widgets/Split.zig");
const AppSettings = @import("app_settings.zig");
const Dialog = @import("Dialog.zig");
const TerminalApp = @import("TerminalApp.zig");
const app_input = @import("app_input.zig");
const Self = @This();
const FocusRect = struct { row: i32, col: i32, width: i32, height: i32 };

pub const list_width = 40;
pub const split_at = 100;
const min_main_rows = 24;

fn mainHeight(height: u16) u16 {
    return height - @as(u16, @intFromBool(height > min_main_rows));
}

pub const Keys = struct {
    context: *anyopaque,
    take: *const fn (*anyopaque, *vxfw.EventContext, vxfw.Event, app_input.Effects.Delivery) anyerror!void,
};

pub const Activate = *const fn (*anyopaque, *vxfw.EventContext) anyerror!void;
pub const Candidate = struct { target: app_input.Target, widget: vxfw.Widget, activate: ?Activate = null, activation_context: ?*anyopaque = null };
pub const Projection = struct { len: usize, modal: bool = false };
pub const FocusOwner = struct {
    context: *anyopaque,
    /// Non-focus side effects of app navigation (pending choice, notices).
    changed: *const fn (*anyopaque) void,
    accepts_tab: ?*const fn (*anyopaque) bool = null,
    /// Live event custody; unlike the candidate order this is not draw state.
    modal: ?*const fn (*anyopaque) bool = null,
    candidates: *const fn (*anyopaque, *[std.enums.values(app_input.Target).len]Candidate) Projection,
};

/// The composed main screen ends its presentation when Root changes panes.
pub const MainPresentation = struct {
    context: *anyopaque,
    close: *const fn (*anyopaque) void,
};
main_presentation: ?MainPresentation = null,
presentation_hold: ?struct { context: *anyopaque, held: *const fn (*anyopaque, u16) bool } = null,
/// Told of every press, every move with no button held and every release no widget took. vxfw has no pointer
/// grab, so only the root sees the pointer wherever it is; a held-pointer gesture ends here.
pointer_free: ?struct { context: *anyopaque, free: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void } = null,

overview: vxfw.Widget,
overview_keys: ?Keys = null,
session_focus: ?FocusOwner = null,
settings_control: ?vxfw.Widget = null,
settings_activate: ?Activate = null,
settings_activate_context: ?*anyopaque = null,
focus_frame: app_input.Frame = .{},
drawn_focus: [std.enums.values(app_input.Target).len]Candidate = undefined,
focus_rects: [std.enums.values(app_input.Target).len]?FocusRect = @splat(null),
list: vxfw.Widget,
divider: ?Split.Divider = null,
bottom: @import("draft_layout.zig").FixedBottom = @import("draft_layout.zig").fixedBottom(0, 0, .overview),
session: ?vxfw.Widget = null,
session_keys: ?Keys = null,
settings_page: AppSettings = .{},
sign_in: ?vxfw.Widget = null,
input: app_input.State = .{},
frames: u64 = 0,
size: vxfw.Size = .{},

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .captureHandler = capture, .eventHandler = event, .drawFn = draw };
}

pub fn listVisible(self: *const Self) bool {
    const layout = self.chooseLayout();
    return self.size.width > 0 and self.size.height > 0 and (layout.split or layout.pane == .overview);
}

const Layout = struct {
    split: bool,
    pane: app_input.Pane,
};

fn chooseLayout(self: *const Self) Layout {
    std.debug.assert(!self.input.layer.signInOpen() or self.sign_in != null);
    const wide = self.size.width >= split_at;
    const pane = app_input.mainPane(self.input, self.session != null, wide);
    return .{ .split = wide and pane != .overview, .pane = pane };
}

pub fn closeMainPresentation(self: *Self) void {
    if (self.main_presentation) |owner| owner.close(owner.context);
}

pub fn openSession(self: *Self, ctx: *vxfw.EventContext, session: vxfw.Widget, keys: ?Keys) !void {
    std.debug.assert(self.session == null);
    self.focus_frame = .{};
    self.focus_rects = @splat(null);
    self.session = session;
    self.session_keys = keys;
    try self.showMain(ctx);
    try session.handleEvent(ctx, .init);
    ctx.redraw = true;
}

pub fn showMain(self: *Self, ctx: *vxfw.EventContext) !void {
    try self.navigate(ctx, .show_main);
}

pub fn focusChat(self: *Self, ctx: *vxfw.EventContext) !void {
    try self.navigate(ctx, .focus_chat);
}

/// A completed pointer action returns to the composer through the app owner.
pub fn focusInput(self: *Self, ctx: *vxfw.EventContext) !void {
    try self.navigate(ctx, .focus_input);
}

pub fn openSettings(self: *Self, ctx: *vxfw.EventContext) !void {
    try self.settings_page.refresh();
    self.closeMainPresentation();
    try self.navigate(ctx, .open_settings);
}

pub fn openSignIn(self: *Self, ctx: *vxfw.EventContext) !void {
    self.closeMainPresentation();
    self.settings_page.cancelChoice();
    try self.navigate(ctx, .open_sign_in);
}

pub fn closeSignIn(self: *Self, ctx: *vxfw.EventContext) !void {
    try self.navigate(ctx, .close_sign_in);
}

pub fn signedIn(self: *Self, ctx: *vxfw.EventContext) !void {
    try self.navigate(ctx, .signed_in);
}

fn navigate(self: *Self, ctx: *vxfw.EventContext, request: app_input.Input) !void {
    const effects = app_input.step(&self.input, self.facts(null), request);
    std.debug.assert(effects.route == .pass);
    try self.apply(ctx, effects, null);
}

fn facts(self: *const Self, key: ?vaxis.Key) app_input.Facts {
    const session_open = self.session != null;
    var frame = self.focus_frame;
    frame.modal = if (self.focusOwner()) |owner| if (owner.modal) |modal| modal(owner.context) else frame.modal else false;
    if (!self.input.layer.settingsOpen()) return .{ .session_open = session_open, .wide = self.size.width >= split_at, .frame = frame, .accepts_tab = if (self.focusOwner()) |owner| if (owner.accepts_tab) |accepts| accepts(owner.context) else false else false };
    const page = &self.settings_page;
    return .{ .session_open = session_open, .settings = .{
        .keys_open = page.keys_open,
        .choice_open = page.hasChoice(),
        .takes_key = if (key) |pressed| page.takesKey(pressed) else false,
        .takes_paste = page.takesPaste(),
        .upgrade_takes_escape = page.upgradeTakesEscape(),
    } };
}

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
    // The retained Session must also retire a pending footer read when the
    // transition hides it (for example Tab/click to a narrow list). A mouse
    // motion, wheel, modal click or pasted click has no focus effect.
    if (effects.field != null or (effects.focus != null and routed != null)) if (self.session_focus) |owner| owner.changed(owner.context);
    if (effects.activate) |target| for (self.drawn_focus[0..self.focus_frame.len]) |candidate| {
        if (candidate.target == target) {
            if (candidate.activate) |activate| try activate(candidate.activation_context orelse candidate.widget.userdata, ctx);
            break;
        }
    };
    if (effects.focus) |focus| try ctx.requestFocus(switch (focus) {
        .main => self.session orelse self.overview,
        .list => self.widget(),
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

pub fn focusList(self: *Self, ctx: *vxfw.EventContext) !bool {
    const effect = app_input.step(&self.input, self.facts(null), .back_to_list);
    try self.apply(ctx, effect, null);
    return effect.focus == .list;
}

pub fn closeSession(self: *Self, ctx: *vxfw.EventContext) !void {
    self.closeMainPresentation();
    self.focus_frame = .{};
    self.focus_rects = @splat(null);
    self.session = null;
    self.session_keys = null;
    self.session_focus = null;
    if (!self.input.layer.settingsOpen()) self.settings_page.cancelChoice();
    try self.navigate(ctx, .session_closed);
    ctx.redraw = true;
}

fn capture(raw: *anyopaque, ctx: *vxfw.EventContext, routed: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (routed == .mouse and (routed.mouse.type == .press or routed.mouse.type == .motion)) if (self.pointer_free) |hook| try hook.free(hook.context, ctx);
    var input: app_input.Input = switch (routed) {
        .key_press => |key| .{ .key = .{ .named = @import("keypress.zig").named(key), .enter = @import("keypress.zig").isEnter(key), .printable = @import("keypress.zig").classify(key) == .text } },
        .paste_start => .paste_start,
        .paste_end => .paste_end,
        .mouse => |mouse| .{ .mouse = switch (mouse.button) {
            .wheel_up, .wheel_down, .wheel_left, .wheel_right => .wheel,
            else => if (mouse.type == .motion) .motion else if (mouse.type != .press or mouse.button != .left or mouse.mods.alt or mouse.row < 0 or mouse.col < 0 or mouse.row >= mainHeight(self.size.height) or mouse.col >= self.size.width) .click else if ((self.size.width >= split_at and mouse.col < list_width) or self.chooseLayout().pane == .overview) .list_click else .chat_click,
        } },
        .key_release => .key_release,
        .color_report, .color_scheme => .colors,
        else => .other,
    };
    const key = if (routed == .key_press) routed.key_press else null;
    var input_facts = self.facts(key);
    if (routed == .mouse and routed.mouse.button == .left and routed.mouse.type == .press and !routed.mouse.mods.alt) {
        // Later candidates are deeper controls inside a pane-sized target.
        for (self.focus_frame.slice(), 0..) |target, i| if (self.focus_rects[i]) |rect| {
            if (routed.mouse.row >= rect.row and routed.mouse.row < rect.row + rect.height and routed.mouse.col >= rect.col and routed.mouse.col < rect.col + rect.width) {
                if (target == .settings_row) {
                    input_facts.mouse_target = null;
                    input = .{ .mouse = .click };
                } else input_facts.mouse_target = target;
            }
        };
    }
    try self.apply(ctx, app_input.step(&self.input, input_facts, input), routed);
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (input) {
        .mouse => |mouse| if (mouse.type == .release) if (self.pointer_free) |hook| try hook.free(hook.context, ctx),
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
            if (ctx.quit) return;
            if (self.session) |session| try session.handleEvent(ctx, .tick);
            if (ctx.quit) return;
            if (self.input.layer != .main or !self.input.mainFocused()) {
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

fn focusOwner(self: *const Self) ?FocusOwner {
    return if (self.chooseLayout().pane == .session) self.session_focus else null;
}

/// One projection from the cells just drawn. Candidates supply semantic
/// identities, never width/visibility decisions or an independent focus.
fn projectFocus(self: *Self, surface: vxfw.Surface, layout: Layout) void {
    self.focus_frame = .{};
    self.focus_rects = @splat(null);
    if (layout.split or layout.pane == .overview) {
        const list = if (layout.split) self.list else self.overview;
        if (focusRect(surface, list, 0, 0, surface.size.width, surface.size.height) != null) self.appendFocus(.{ .target = .list, .widget = list });
        if (self.settings_control) |control| if (focusRect(surface, control, 0, 0, surface.size.width, surface.size.height) != null) self.appendFocus(.{ .target = .settings_row, .widget = control, .activate = self.settings_activate, .activation_context = self.settings_activate_context });
    }
    if (self.focusOwner()) |owner| {
        var candidates: [std.enums.values(app_input.Target).len]Candidate = undefined;
        const projection = owner.candidates(owner.context, &candidates);
        self.focus_frame.modal = projection.modal;
        // Pane-major order: sidebar first, then main controls in the actual
        // row/column order. Omitted/clipped widgets never enter the cycle.
        const Placed = struct { candidate: Candidate, row: i32, col: i32 };
        var placed: [std.enums.values(app_input.Target).len]Placed = undefined;
        var count: usize = 0;
        for (candidates[0..projection.len]) |candidate| if (focusRect(surface, candidate.widget, 0, 0, surface.size.width, surface.size.height)) |rect| {
            placed[count] = .{ .candidate = candidate, .row = rect.row, .col = rect.col };
            count += 1;
        };
        const Order = struct {
            fn less(_: void, a: Placed, b: Placed) bool {
                return a.row < b.row or (a.row == b.row and a.col < b.col);
            }
        };
        std.mem.sort(Placed, placed[0..count], {}, Order.less);
        for (placed[0..count]) |item| self.appendFocus(item.candidate);
    }
    for (self.drawn_focus[0..self.focus_frame.len], 0..) |candidate, i| self.focus_rects[i] = focusRect(surface, candidate.widget, 0, 0, surface.size.width, surface.size.height);
}

fn focusRect(surface: vxfw.Surface, target: vxfw.Widget, row: i32, col: i32, width: i32, height: i32) ?FocusRect {
    return clippedFocusRect(surface, target, row, col, .{ .row = row, .col = col, .width = width, .height = height });
}

fn clippedFocusRect(surface: vxfw.Surface, target: vxfw.Widget, row: i32, col: i32, clip: FocusRect) ?FocusRect {
    const top = @max(row, clip.row);
    const left = @max(col, clip.col);
    const bottom = @min(row + surface.size.height, clip.row + clip.height);
    const right = @min(col + surface.size.width, clip.col + clip.width);
    if (bottom <= top or right <= left) return null;
    const rect: FocusRect = .{ .row = top, .col = left, .width = right - left, .height = bottom - top };
    if (surface.widget.eql(target)) return rect;
    for (surface.children) |child| {
        if (clippedFocusRect(child.surface, target, row + child.origin.row, col + child.origin.col, rect)) |found| return found;
    }
    return null;
}

fn appendFocus(self: *Self, candidate: Candidate) void {
    if (std.mem.indexOfScalar(app_input.Target, self.focus_frame.slice(), candidate.target) != null) return;
    self.drawn_focus[self.focus_frame.len] = candidate;
    self.focus_frame.append(candidate.target);
}

fn expectDividerUnchanged(split_frame: vxfw.Surface) !void {
    const divider = split_frame.children[1].surface;
    for (divider.buffer) |cell| {
        try std.testing.expectEqualStrings("┆", cell.char.grapheme);
        try std.testing.expect(cell.style.eql(@import("widgets/Stitch.zig").cell(true, .vertical, .{}).style));
    }
}

test "SUI-4 split pane focus dims only the inactive chat or sidebar" {
    const Pane = struct {
        glyph: []const u8,

        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .drawFn = drawPane };
        }
        fn drawPane(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), ctx.max.size());
            @memset(surface.buffer, .{ .char = .{ .grapheme = self.glyph, .width = 1 }, .style = .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bg = .{ .rgb = .{ 0, 0, 0 } } } });
            return surface;
        }
    };
    var overview: Pane = .{ .glyph = "o" };
    var list: Pane = .{ .glyph = "l" };
    var chat: Pane = .{ .glyph = "c" };
    try std.testing.expect(!overview.widget().eql(list.widget()));
    try std.testing.expect(!list.widget().eql(chat.widget()));
    try std.testing.expect(!overview.widget().eql(chat.widget()));
    var root: Self = .{ .overview = overview.widget(), .list = list.widget(), .session = chat.widget() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const drawAt = struct {
        fn run(root_: *Self, arena_: std.mem.Allocator, width: u16, height: u16) !vxfw.Surface {
            return root_.widget().draw(.{ .arena = arena_, .cell_arena = arena_, .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} });
        }
    }.run;

    root.input.area = .main;
    var frame = try drawAt(&root, arena.allocator(), 140, 26);
    var split_frame = frame.children[0].surface;
    try expectDividerUnchanged(split_frame);
    try std.testing.expectEqual(@as(u8, 209), split_frame.children[0].surface.buffer[0].style.fg.rgb[0]);
    try std.testing.expectEqual(@as(u8, 255), split_frame.children[2].surface.buffer[0].style.fg.rgb[0]);
    root.input.area = .list;
    frame = try drawAt(&root, arena.allocator(), 140, 26);
    split_frame = frame.children[0].surface;
    try expectDividerUnchanged(split_frame);
    try std.testing.expectEqual(@as(u8, 255), split_frame.children[0].surface.buffer[0].style.fg.rgb[0]);
    try std.testing.expectEqual(@as(u8, 209), split_frame.children[2].surface.buffer[0].style.fg.rgb[0]);
    root.input.area = .settings_row;
    frame = try drawAt(&root, arena.allocator(), 140, 26);
    split_frame = frame.children[0].surface;
    try expectDividerUnchanged(split_frame);
    try std.testing.expectEqual(@as(u8, 209), split_frame.children[2].surface.buffer[0].style.fg.rgb[0]);
    for ([_]app_input.Target{ .back, .model, .effort, .info, .latest, .details, .needs, .stop }) |target| {
        root.input.area = .{ .button = target };
        frame = try drawAt(&root, arena.allocator(), 140, 26);
        split_frame = frame.children[0].surface;
        try expectDividerUnchanged(split_frame);
        try std.testing.expectEqual(@as(u8, 209), split_frame.children[0].surface.buffer[0].style.fg.rgb[0]);
        try std.testing.expectEqual(@as(u8, 255), split_frame.children[2].surface.buffer[0].style.fg.rgb[0]);
    }

    root.input.area = .main;
    frame = try drawAt(&root, arena.allocator(), 46, 26);
    try std.testing.expect(frame.children[0].surface.widget.eql(chat.widget()));
    try std.testing.expectEqual(@as(u8, 255), frame.children[0].surface.buffer[0].style.fg.rgb[0]);

    root.input.layer = .settings;
    frame = try drawAt(&root, arena.allocator(), 140, 26);
    try std.testing.expectEqual(@as(usize, 2), frame.children.len);
    const backdrop = @import("widget_style.zig").backdrop(root.appCaps());
    for (frame.children[0].surface.buffer) |cell| try std.testing.expect(cell.style.eql(backdrop));
    try std.testing.expect(containsWidget(frame.children[1].surface, root.settings_page.widget()));
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    self.size = size;
    const height = mainHeight(size.height);
    const main_ctx = ctx.withConstraints(.{ .width = ctx.min.width, .height = @min(ctx.min.height, height) }, .{ .width = size.width, .height = height });
    self.bottom = @import("draft_layout.zig").fixedBottom(height, 0, .overview);
    if (self.presentation_hold) |hold| if (hold.held(hold.context, size.width)) {
        return try vxfw.Surface.init(ctx.cell_arena, self.widget(), size);
    };
    // Sign-in and Settings open as dialogs above the main screen, which fades behind them.
    // Sign-in opened from Settings takes Settings' place rather than stacking a second card.
    const signing = self.input.layer.signInOpen();
    const covering = signing or self.input.layer.settingsOpen();
    const inset = height < size.height;
    const children = try ctx.arena.alloc(vxfw.SubSurface, if (covering or inset) 2 else 1);
    var background = self.input;
    if (covering) background.layer = .main;
    const background_pane = app_input.mainPane(background, self.session != null, size.width >= split_at);
    const layout: Layout = if (covering) .{ .pane = background_pane, .split = size.width >= split_at and background_pane != .overview } else self.chooseLayout();
    const pane = switch (layout.pane) {
        .overview => self.overview,
        .session => self.session.?,
        // Sign-in and Settings are dialogs over the main pane, never panes of their own.
        .sign_in, .settings => unreachable,
    };
    const child = if (layout.split) split: {
        const split = try ctx.arena.create(Split);
        split.* = .{
            .left = self.list,
            .right = pane,
            .left_width = list_width,
            .min_width = 0,
            .narrow = .right,
            .divider = self.divider,
        };
        break :split try split.widget().draw(main_ctx);
    } else try pane.draw(main_ctx);
    if (layout.split and !covering) {
        const inactive = switch (self.input.area) {
            .list, .settings_row => self.session.?,
            .main, .button => self.list,
        };
        for (child.children) |pane_surface| if (pane_surface.surface.widget.eql(inactive)) {
            @import("widget_style.zig").dimSurface(pane_surface.surface, self.appCaps().depth == .none);
            break;
        };
    }
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = if (covering) try faded(ctx, child, @import("widget_style.zig").backdrop(self.appCaps()), self.backgroundWidget()) else child };
    self.projectFocus(child, layout);
    if (covering) {
        children[1] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = if (signing) try self.sign_in.?.draw(ctx) else try self.settingsDialog(ctx, size) };
    } else if (inset) {
        const ground = try vxfw.Surface.init(ctx.cell_arena, self.backgroundWidget(), .{ .width = size.width, .height = 1 });
        @memset(ground.buffer, .{ .style = @import("widget_style.zig").of(self.appCaps(), .{}) });
        children[1] = .{ .origin = .{ .row = @intCast(height), .col = 0 }, .surface = ground };
    }
    self.frames += 1;
    return .{ .size = size, .widget = self.widget(), .buffer = &.{}, .children = children };
}

/// The covered screen as one flat layer in the `backdrop` style: what it showed stays in
/// place, quiet behind the dialog, with no colour, cursor, link, image or highlight of its own.
/// vxfw's own render composes it, so the faded screen holds exactly what would have shown.
/// `outside` is a widget with no cursor in `screen`, so rendering shows none, and with no
/// handlers: the faded layer is its own, so no click or wheel on it reaches the screen it shows.
fn faded(ctx: vxfw.DrawContext, screen: vxfw.Surface, backdrop: vaxis.Style, outside: vxfw.Widget) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    var scratch = try vaxis.Screen.init(ctx.cell_arena, .{ .cols = size.width, .rows = size.height, .x_pixel = 0, .y_pixel = 0 });
    const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.size.width, .height = screen.size.height, .screen = &scratch };
    try screen.render(window, outside);
    const flat = try vxfw.Surface.init(ctx.cell_arena, outside, size);
    for (flat.buffer, scratch.buf) |*cell, drawn| cell.* = .{ .char = drawn.char, .style = backdrop };
    return flat;
}

/// Settings as a dialog: its rows, then its footer, laid on the card.
fn settingsDialog(self: *Self, ctx: vxfw.DrawContext, size: vxfw.Size) std.mem.Allocator.Error!vxfw.Surface {
    const look: Dialog.Look = .of(self.appCaps());
    const fit = Dialog.bound(size);
    const footer_height: u16 = @intFromBool(fit.height > 1);
    const body = try self.settings_page.widget().draw(ctx.withConstraints(.{}, .{ .width = fit.width, .height = fit.height - footer_height }));
    var content = try vxfw.Surface.init(ctx.cell_arena, self.backgroundWidget(), .{ .width = fit.width, .height = body.size.height + footer_height });
    @memset(content.buffer, .{ .style = look.ground });
    const parts = try ctx.arena.alloc(vxfw.SubSurface, @as(usize, 1) + footer_height);
    parts[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = body };
    if (footer_height == 1) parts[1] = .{ .origin = .{ .row = @intCast(body.size.height), .col = 0 }, .surface = try self.settings_page.footerWidget().draw(ctx.withConstraints(.{}, .{ .width = fit.width, .height = 1 })) };
    content.children = parts;
    return Dialog.lay(ctx, self.backgroundWidget(), look, content, size);
}

/// Root's drawing with no handlers, owning the bottom inset, faded screen and dialog surfaces: a
/// click or wheel the dialog does not use reaches nothing behind it, and Root's capture sits
/// in each event's path once.
fn backgroundWidget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .drawFn = draw };
}

/// The capabilities the app draws with, as app settings reads them.
fn appCaps(self: *const Self) @import("overview_view.zig").Caps {
    return if (self.settings_page.backend) |backend| backend.caps(backend.context) else .{};
}

/// A surface of the dialog or the faded screen takes no event itself: Root's own capture is
/// the only handler in each event's path.
fn inert(owner: vxfw.Widget) bool {
    return owner.eventHandler == null and owner.captureHandler == null;
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
                try std.testing.expectEqualStrings("┆", layout.children[1].surface.buffer[0].char.grapheme);
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
        // Settings is a dialog above the main screen, which stays in place but faded.
        try std.testing.expectEqual(@as(usize, 2), opened.children.len);
        try std.testing.expectEqual(@as(usize, 0), opened.children[0].surface.children.len);
        try std.testing.expect(inert(opened.children[1].surface.widget));
        try std.testing.expect(containsWidget(opened.children[1].surface, root.settings_page.widget()));

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
        try std.testing.expect(ctx.cmds.items[ctx.cmds.items.len - 1].request_focus.eql(whole.widget()));
        const closed = try root.widget().draw(draw_context);
        const closed_layout = closed.children[0].surface;
        try std.testing.expect(closed_layout.widget.eql(whole.widget()));
        try std.testing.expectEqual(width, closed_layout.size.width);
        try std.testing.expect(root.listVisible());
        ctx.consume_event = false;
        try root.widget().captureEvent(&ctx, escape);
        try std.testing.expect(ctx.consume_event and !root.input.layer.settingsOpen());

        try root.openSettings(&ctx);
        try root.openSession(&ctx, session.widget(), null);
        try std.testing.expect(!root.input.layer.settingsOpen());
        try std.testing.expect(root.session.?.eql(session.widget()));
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
        const cancels = if (run) |value| value.takesEscape() else false;
        ctx.consume_event = false;
        try root.widget().captureEvent(&ctx, escape);
        try std.testing.expect(ctx.consume_event);
        try std.testing.expectEqual(@as(usize, @intFromBool(cancels)), fixture.escapes);
        try std.testing.expectEqual(cancels, root.input.layer.settingsOpen());
        if (!cancels) continue;
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
    try page.widget().captureEvent(&events, .{ .key_press = .{ .codepoint = 'g', .mods = .{ .ctrl = true } } });
    try std.testing.expect(!page.input.layer.settingsOpen());
    try page.openSettings(&events);
    try page.widget().captureEvent(&events, escape);
    try std.testing.expect(!page.input.layer.settingsOpen());
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
        const overview_keys = fixture.overview_keys;
        const selected = if (page.panel.choice) |open| open.selected else null;
        try app_events.send(&ctx, "\x1b[200~\r\x1b[201~", root.widget(), page.widget());
        try std.testing.expectEqual(@as(usize, 0), fixture.saves);
        try std.testing.expectEqual(overview_keys, fixture.overview_keys);
        try std.testing.expectEqual(choice != .none, page.hasChoice());
        try std.testing.expectEqual(selected, if (page.panel.choice) |open| open.selected else null);
        try std.testing.expect(root.input.layer.settingsOpen() and !ctx.quit and !root.input.pasting);
        try app_events.send(&ctx, "\r", root.widget(), page.widget());
        try std.testing.expectEqual(@as(usize, 1), fixture.saves);
        switch (choice) {
            .model => try std.testing.expectEqualStrings(text, fixture.edit.?.model.set),
            .ordinary => try std.testing.expect(fixture.edit.?.reasoning_effort == .clear),
            .none => try std.testing.expectEqual(@as(?bool, false), fixture.edit.?.notifications),
        }
    };
}

test "Settings opens as a dialog over the faded screen, and Sign-in from it takes its place" {
    const background: vxfw.Text = .{ .text = "Retained draft" };
    var page: @import("SignIn.zig") = .{};
    var root: Self = .{ .overview = background.widget(), .list = background.widget(), .sign_in = page.widget() };
    for ([_]vxfw.Size{ .{ .width = 140, .height = 40 }, .{ .width = 46, .height = 30 }, .{ .width = 30, .height = 8 } }) |size| for ([_]bool{ false, true }) |signing| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        root.input.layer = if (signing) .{ .sign_in = .{ .over = .settings } } else .settings;
        const drawn = try root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{} });
        try std.testing.expectEqual(@as(usize, 2), drawn.children.len);
        // The main screen stays in place, faded onto the scrim, with nothing of its own above.
        const screen = drawn.children[0].surface;
        try std.testing.expectEqual(@as(usize, 0), screen.children.len);
        for (screen.buffer) |cell| try std.testing.expect(cell.style.eql(@import("widget_style.zig").backdrop(.{})));
        if (size.width >= 14) for ("Retained draft", 0..) |byte, col| try std.testing.expectEqual(byte, screen.buffer[col].char.grapheme[0]);
        const layer = drawn.children[1].surface;
        try std.testing.expectEqual(size, layer.size);
        // One dialog at a time: Sign-in replaces Settings rather than stacking a second card.
        try std.testing.expectEqual(!signing, containsWidget(layer, root.settings_page.widget()));
        try std.testing.expectEqual(signing, layer.widget.eql(page.widget()));
        if (signing) continue;
        try std.testing.expect(inert(layer.widget));
        try std.testing.expectEqual(@as(usize, if (Dialog.framed(size)) 2 else 1), layer.children.len);
        const content = layer.children[0];
        try std.testing.expect(content.surface.size.width <= Dialog.max_width);
        try std.testing.expectEqual(Dialog.origin(size, content.surface.size), content.origin);
        const raised = Dialog.Look.of(.{}).ground;
        for (content.surface.buffer) |cell| try std.testing.expect(cell.style.bg.eql(raised.bg));
    };
}

test "Sign-in is centered above the covered screen across every small bound" {
    const background: vxfw.Text = .{ .text = "Retained draft" };
    var page: @import("SignIn.zig") = .{};
    // Unframed, the dialog fills the screen with its own raised ground.
    const raised = @import("widget_style.zig").of(page.caps.*, .{ .background = .raised });
    var root: Self = .{ .overview = background.widget(), .list = background.widget(), .sign_in = page.widget(), .input = .{ .layer = .{ .sign_in = .{ .over = .main } } } };
    for ([_]bool{ false, true }) |unicode| {
        page.unicode = unicode;
        for (0..81) |width| for (0..25) |height| {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const surface = try root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = @intCast(height) }, .cell_size = .{} });
            try std.testing.expectEqual(@as(usize, 2), surface.children.len);
            try std.testing.expect(inert(surface.children[0].surface.widget));
            const cover = surface.children[1].surface;
            if (width == 0 or height == 0) continue;
            // The covered screen stays in place but faded; the layer above paints nothing of
            // its own outside the card, so only the faded screen shows around it.
            const screen = surface.children[0].surface;
            try std.testing.expectEqual(@as(usize, screen.size.width) * screen.size.height, screen.buffer.len);
            try std.testing.expectEqual(@as(usize, 0), screen.children.len);
            for (screen.buffer) |cell| try std.testing.expect(cell.style.eql(@import("widget_style.zig").backdrop(.{})));
            if (width >= 14) for ("Retained draft", 0..) |byte, col| try std.testing.expectEqual(byte, screen.buffer[col].char.grapheme[0]);
            // Framed, the layer paints nothing, so the faded screen shows around the card;
            // unframed, it fills the screen with the ground so nothing covered sits beside it.
            try std.testing.expectEqual(@as(usize, if (width >= 40 and height >= 10) 0 else width * height), cover.buffer.len);
            for (cover.buffer) |cell| {
                try std.testing.expect(cell.style.eql(raised));
                try std.testing.expect(cell.char.grapheme.len == 0 or std.mem.eql(u8, cell.char.grapheme, " "));
            }
            try std.testing.expectEqual(vxfw.Size{ .width = @intCast(width), .height = @intCast(height) }, cover.size);
            const dialog = cover.children[0];
            // With room the dialog is a card with a stitched edge; below that it fills its bound.
            const framed = width >= 40 and height >= 10;
            try std.testing.expectEqual(@as(usize, if (framed) 2 else 1), cover.children.len);
            if (framed) {
                // A margin of ground, the stitch, then (at the sides) a column of ground.
                const edge = cover.children[1];
                const across = if (unicode) "┄" else "-";
                const upright = if (unicode) "┆" else "|";
                const w = edge.surface.size.width;
                try std.testing.expect(edge.z_index < dialog.z_index);
                try std.testing.expectEqual(dialog.origin.row - 2, edge.origin.row);
                try std.testing.expectEqual(dialog.origin.col - 3, edge.origin.col);
                try std.testing.expectEqual(vxfw.Size{ .width = dialog.surface.size.width + 6, .height = dialog.surface.size.height + 4 }, edge.surface.size);
                for (0..w) |col| try std.testing.expect(edge.surface.buffer[col].char.grapheme.len == 0 or std.mem.eql(u8, edge.surface.buffer[col].char.grapheme, " "));
                try std.testing.expectEqualStrings(across, edge.surface.readCell(1, 1).char.grapheme);
                try std.testing.expectEqualStrings(across, edge.surface.readCell(w - 2, edge.surface.size.height - 2).char.grapheme);
                try std.testing.expectEqualStrings(upright, edge.surface.readCell(1, 2).char.grapheme);
                try std.testing.expectEqualStrings(upright, edge.surface.readCell(w - 2, 2).char.grapheme);
                try std.testing.expect(edge.surface.readCell(0, 2).char.grapheme.len == 0 or std.mem.eql(u8, edge.surface.readCell(0, 2).char.grapheme, " "));
                try std.testing.expect(edge.origin.row >= 0 and edge.origin.col >= 0);
                try std.testing.expect(edge.origin.row + edge.surface.size.height <= height and edge.origin.col + edge.surface.size.width <= width);
                if (!unicode) for (edge.surface.buffer) |cell| for (cell.char.grapheme) |byte| try std.testing.expect(byte < 128);
            }
            try std.testing.expectEqual(@as(i17, @intCast((width - dialog.surface.size.width) / 2)), dialog.origin.col);
            try std.testing.expectEqual(@as(i17, @intCast((height - dialog.surface.size.height) / 2)), dialog.origin.row);
            try std.testing.expect(dialog.origin.row + dialog.surface.size.height <= height);
            try std.testing.expect(dialog.origin.col + dialog.surface.size.width <= width);
            if (!unicode) for (dialog.surface.buffer) |cell| for (cell.char.grapheme) |byte| try std.testing.expect(byte < 128);
        };
    }
}

test "Sign-in fades the covered screen onto the scrim of the caps app settings draws with" {
    const Backend = struct {
        fn read(_: *anyopaque) !@import("preferences.zig").Values {
            return .{};
        }
        fn save(_: *anyopaque, _: @import("preferences.zig").Edit) !void {}
        fn saveState(_: *anyopaque) AppSettings.SaveState {
            return .pending;
        }
        fn upgrade(_: *anyopaque) !void {}
        fn run(_: *anyopaque) ?@import("upgrade_status.zig").Run {
            return null;
        }
        fn caps(_: *anyopaque) @import("overview_view.zig").Caps {
            return .{ .depth = .direct, .background = .{ 0xf4, 0xef, 0xe2 } };
        }
    };
    var context: u8 = 0;
    const background: vxfw.Text = .{ .text = "Covered" };
    var page: @import("SignIn.zig") = .{};
    var root: Self = .{
        .overview = background.widget(),
        .list = background.widget(),
        .sign_in = page.widget(),
        .settings_page = .{ .backend = .{ .context = &context, .read = Backend.read, .save = Backend.save, .save_state = Backend.saveState, .upgrade = Backend.upgrade, .run = Backend.run, .caps = Backend.caps } },
        .input = .{ .layer = .{ .sign_in = .{ .over = .main } } },
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const surface = try root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} });
    const day = @import("widget_style.zig").backdrop(Backend.caps(&context));
    // Day cloth: unlike the night default, so a Root that ignored app settings' caps fails.
    try std.testing.expect(!day.eql(@import("widget_style.zig").backdrop(.{})));
    try std.testing.expectEqual(@import("widget_style.zig").line(Backend.caps(&context), .horizontal).style.fg, day.fg);
    try std.testing.expect(surface.children[0].surface.buffer.len > 0);
    for (surface.children[0].surface.buffer) |cell| try std.testing.expect(cell.style.eql(day));
}

test "A faded screen holds what rendering shows: children above their parents in z order, clipped to them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx: vxfw.DrawContext = .{ .arena = a, .cell_arena = a, .min = .{}, .max = .{ .width = 4, .height = 2 }, .cell_size = .{} };
    const blank: vxfw.Text = .{ .text = "" };
    const none = blank.widget();
    const Fill = struct {
        fn of(allocator: std.mem.Allocator, size: vxfw.Size, glyph: []const u8, style: vaxis.Style) !vxfw.Surface {
            const text: vxfw.Text = .{ .text = "" };
            const surface = try vxfw.Surface.init(allocator, text.widget(), size);
            @memset(surface.buffer, .{ .char = .{ .grapheme = glyph, .width = 1 }, .style = style });
            return surface;
        }
    };
    const inner = try Fill.of(a, .{ .width = 3, .height = 3 }, "c", .{ .bold = true });
    var parent = try Fill.of(a, .{ .width = 2, .height = 2 }, "b", .{ .reverse = true });
    const low = try Fill.of(a, .{ .width = 1, .height = 1 }, "z", .{});
    parent.children = try a.dupe(vxfw.SubSurface, &.{.{ .origin = .{ .row = 1, .col = 1 }, .surface = inner }});
    const children = try a.dupe(vxfw.SubSurface, &.{
        .{ .origin = .{ .row = 0, .col = 2 }, .surface = parent, .z_index = 1 },
        .{ .origin = .{ .row = 0, .col = 2 }, .surface = low, .z_index = 0 },
        .{ .origin = .{ .row = -1, .col = -1 }, .surface = try Fill.of(a, .{ .width = 2, .height = 2 }, "n", .{}) },
    });
    var screen = try Fill.of(a, .{ .width = 4, .height = 2 }, "a", .{ .fg = .{ .index = 3 } });
    screen.widget = none;
    screen.children = children;
    const backdrop: vaxis.Style = .{ .fg = .{ .index = 8 } };
    var root: Self = .{ .overview = none, .list = none };
    const flat = try faded(ctx, screen, backdrop, root.widget());
    var text: [8]u8 = undefined;
    for (flat.buffer, 0..) |cell, i| {
        text[i] = cell.char.grapheme[0];
        try std.testing.expect(cell.style.eql(backdrop));
    }
    // "n" sits partly off screen; "z" lies under "b" by z order; "c" is clipped to "b"'s 2x2.
    try std.testing.expectEqualStrings("nabb" ++ "aabc", &text);
}

test "Sign-in captures every mouse action above settings without background activation" {
    const Find = struct {
        fn label(surface: vxfw.Surface, text: []const u8) ?vxfw.RelativePoint {
            for (0..surface.size.height) |row| for (0..surface.size.width) |col| {
                if (surface.buffer.len == 0 or col + text.len > surface.size.width) continue;
                for (text, 0..) |byte, offset| {
                    const cell = surface.buffer[row * surface.size.width + col + offset];
                    if (cell.char.grapheme.len != 1 or cell.char.grapheme[0] != byte) break;
                } else return .{ .row = @intCast(row), .col = @intCast(col) };
            };
            for (surface.children) |child| if (label(child.surface, text)) |point| return .{ .row = point.row + child.origin.row, .col = point.col + child.origin.col };
            return null;
        }
    };
    const background: vxfw.Text = .{ .text = "Covered Settings" };
    var page: @import("SignIn.zig") = .{};
    defer page.deinit();
    var root: Self = .{ .overview = background.widget(), .list = background.widget(), .sign_in = page.widget(), .input = .{ .layer = .{ .sign_in = .{ .over = .settings } } } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const surface = try root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 30 }, .cell_size = .{} });
    const api = Find.label(surface.children[1].surface, "API key") orelse return error.TestUnexpectedResult;
    try std.testing.expect(api.row > 0 and api.col > 0);
    for (std.enums.values(vaxis.Mouse.Type)) |kind| for (std.enums.values(vaxis.Mouse.Button)) |button| {
        const before = std.meta.activeTag(page.state.page);
        ctx.consume_event = false;
        try root.widget().captureEvent(&ctx, .{ .mouse = .{ .row = 0, .col = 0, .button = button, .type = kind, .mods = .{} } });
        try std.testing.expect(ctx.consume_event);
        try std.testing.expect(root.input.layer.signInOpen());
        try std.testing.expect(root.input.layer.settingsOpen());
        try std.testing.expectEqual(before, std.meta.activeTag(page.state.page));
    };
    ctx.consume_event = false;
    try root.widget().captureEvent(&ctx, .{ .mouse = .{ .row = @intCast(api.row), .col = @intCast(api.col), .button = .left, .type = .press, .mods = .{} } });
    try std.testing.expect(ctx.consume_event and page.state.page == .api);
    try std.testing.expect(root.input.layer.signInOpen() and root.input.layer.settingsOpen());
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
    try std.testing.expect(!owner.settings_when_closed);
    try root.openSession(&ctx, empty.widget(), null);
    try std.testing.expectEqual(@as(usize, 3), owner.closes);
    try root.closeSession(&ctx);
    try std.testing.expectEqual(@as(usize, 4), owner.closes);
    try std.testing.expect(owner.session_when_closed);
    try std.testing.expect(root.session == null);
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

test "Root resumes the open chat from the list by key or click without closing its presentation" {
    const Owner = struct {
        closes: usize = 0,
        fn close(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.closes += 1;
        }
    };
    const pane: vxfw.Text = .{ .text = "" };
    var owner: Owner = .{};
    var root: Self = .{ .overview = pane.widget(), .list = pane.widget(), .session = pane.widget(), .size = .{ .width = 140, .height = 40 }, .main_presentation = .{ .context = &owner, .close = Owner.close } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]bool{ false, true }) |click| {
        try std.testing.expect(try root.focusList(&ctx));
        if (click) {
            try root.widget().captureEvent(&ctx, .{ .mouse = .{ .col = 100, .row = 10, .button = .left, .type = .press, .mods = .{} } });
        } else try root.focusChat(&ctx);
        try std.testing.expect(!root.input.listFocused());
        try std.testing.expect(ctx.cmds.items[ctx.cmds.items.len - 1].request_focus.eql(root.session.?));
    }
    try std.testing.expectEqual(@as(usize, 0), owner.closes);
}

test "App root hands list activation unchanged to its one core" {
    const Selection = struct {
        calls: usize = 0,
        fn take(raw: *anyopaque, _: *vxfw.EventContext, input: vxfw.Event, delivery: app_input.Effects.Delivery) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expect(input.key_press.matches(vaxis.Key.enter, .{}) or input.key_press.matches(vaxis.Key.right, .{}));
            try std.testing.expect(delivery.under == .main and !delivery.pasted);
            self.calls += 1;
        }
    };
    const overview: vxfw.Text = .{ .text = "List" };
    const session: vxfw.Text = .{ .text = "Chat" };
    var selection: Selection = .{};
    var root: Self = .{
        .overview = overview.widget(),
        .list = overview.widget(),
        .session = session.widget(),
        .size = .{ .width = 140, .height = 40 },
        .overview_keys = .{ .context = &selection, .take = Selection.take },
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]u21{ vaxis.Key.right, vaxis.Key.enter }) |key| {
        try std.testing.expect(try root.focusList(&ctx));
        const target = ctx.cmds.items[ctx.cmds.items.len - 1].request_focus;
        try std.testing.expect(target.eventHandler != null);
        try std.testing.expect(target.eql(root.widget()));
        try root.widget().captureEvent(&ctx, .{ .key_press = .{ .codepoint = key } });
        try std.testing.expect(root.input.listFocused());
        try root.showMain(&ctx);
        try std.testing.expect(!root.input.listFocused());
    }
    try std.testing.expectEqual(@as(usize, 2), selection.calls);
    _ = try root.focusList(&ctx);
    for ([_]vaxis.Mouse{
        .{ .col = 50, .row = 10, .button = .left, .type = .motion, .mods = .{} },
        .{ .col = 50, .row = 10, .button = .left, .type = .release, .mods = .{} },
        .{ .col = 50, .row = 10, .button = .right, .type = .press, .mods = .{} },
        .{ .col = 50, .row = 10, .button = .left, .type = .press, .mods = .{ .alt = true } },
    }) |mouse| {
        try root.widget().captureEvent(&ctx, .{ .mouse = mouse });
        try std.testing.expect(root.input.listFocused());
    }
}

test "Root focus projection excludes nested clipped controls and clips negative origins" {
    const Fixture = struct {
        identity: u8 = 0,
        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .drawFn = @This().draw };
        }
        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .widget = self.widget(), .size = ctx.max.size(), .buffer = &.{}, .children = &.{} };
        }
    };
    const Owner = struct {
        controls: [3]vxfw.Widget,
        fn changed(_: *anyopaque) void {}
        fn candidates(raw: *anyopaque, out: *[std.enums.values(app_input.Target).len]Candidate) Projection {
            const self: *@This() = @ptrCast(@alignCast(raw));
            out[0] = .{ .target = .input, .widget = self.controls[0] };
            out[1] = .{ .target = .model, .widget = self.controls[1] };
            out[2] = .{ .target = .effort, .widget = self.controls[2] };
            return .{ .len = 3 };
        }
    };
    var fixtures: [5]Fixture = @splat(.{});
    var owner: Owner = .{ .controls = .{ fixtures[2].widget(), fixtures[3].widget(), fixtures[4].widget() } };
    var root: Self = .{
        .overview = fixtures[0].widget(),
        .list = fixtures[0].widget(),
        .session = fixtures[1].widget(),
        .size = .{ .width = 46, .height = 10 },
        .session_focus = .{ .context = &owner, .changed = Owner.changed, .candidates = Owner.candidates },
    };
    const leaf_size: vxfw.Size = .{ .width = 4, .height = 2 };
    var controls = [_]vxfw.SubSurface{
        // In the outer viewport, but entirely beyond its immediate parent.
        .{ .origin = .{ .row = 1, .col = 4 }, .surface = .{ .widget = fixtures[2].widget(), .size = leaf_size, .buffer = &.{}, .children = &.{} } },
        // Entirely above the parent's clipped top edge.
        .{ .origin = .{ .row = -3, .col = 1 }, .surface = .{ .widget = fixtures[3].widget(), .size = leaf_size, .buffer = &.{}, .children = &.{} } },
        .{ .origin = .{ .row = 1, .col = 1 }, .surface = .{ .widget = fixtures[4].widget(), .size = leaf_size, .buffer = &.{}, .children = &.{} } },
    };
    var parents = [_]vxfw.SubSurface{.{ .origin = .{ .row = -1, .col = -1 }, .surface = .{
        .widget = fixtures[1].widget(),
        .size = leaf_size,
        .buffer = &.{},
        .children = &controls,
    } }};
    const surface: vxfw.Surface = .{ .widget = root.widget(), .size = root.size, .buffer = &.{}, .children = &parents };
    root.projectFocus(surface, .{ .split = false, .pane = .session });
    try std.testing.expectEqualSlices(app_input.Target, &.{.effort}, root.focus_frame.slice());
    try std.testing.expectEqual(FocusRect{ .row = 0, .col = 0, .width = 3, .height = 1 }, root.focus_rects[0].?);
    // Sidebar and settings candidates use the same clipped admission.
    root.list = fixtures[2].widget();
    root.settings_control = fixtures[3].widget();
    root.session_focus = null;
    root.projectFocus(surface, .{ .split = true, .pane = .session });
    try std.testing.expectEqual(@as(usize, 0), root.focus_frame.len);
}

test "Root routes Keys scrolling to Settings over a retained multiline draft" {
    const app_events = @import("testing/app_events.zig");
    const draft = "one\ntwo\nthree\nfour\nfive\nsix";
    for ([_]u16{ 46, 140 }) |width| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const background: vxfw.Text = .{ .text = "Overview" };
        var root: Self = .{ .overview = background.widget(), .list = background.widget() };
        var storage: [128]u8 = undefined;
        var editor: @import("DraftEditor.zig") = .initText(&storage, draft, 7);
        var input: @import("InputArea.zig") = .{ .composer = .{ .editor = &editor, .caret = false } };
        root.overview = input.widget();
        const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 12 }, .cell_size = .{} };
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        _ = try root.widget().draw(draw_ctx);
        try root.openSettings(&events);
        try std.testing.expect(events.cmds.items[events.cmds.items.len - 1].request_focus.eql(root.settings_page.widget()));
        root.settings_page.select(.keys);
        try app_events.send(&events, "\r", root.widget(), root.settings_page.widget());
        try std.testing.expect(root.settings_page.keys_open);
        _ = try root.widget().draw(draw_ctx);
        const page = &root.settings_page;
        const bottom = page.keys_rows -| page.keys_height;
        try std.testing.expect(bottom > 0);
        try app_events.send(&events, "\x1b[B", root.widget(), page.widget());
        try std.testing.expectEqual(@as(usize, 1), page.keys_offset);
        try app_events.send(&events, "\x1b[A", root.widget(), page.widget());
        try std.testing.expectEqual(@as(usize, 0), page.keys_offset);
        try app_events.send(&events, "\x1b[6~", root.widget(), page.widget());
        try std.testing.expectEqual(@min(page.keys_height, bottom), page.keys_offset);
        try app_events.send(&events, "\x1b[5~", root.widget(), page.widget());
        try std.testing.expectEqual(@as(usize, 0), page.keys_offset);
        try std.testing.expectEqualStrings(draft, editor.text());
        try std.testing.expectEqual(@as(usize, 7), editor.cursor());
        try std.testing.expect(root.input.layer.settingsOpen());
    }
}
