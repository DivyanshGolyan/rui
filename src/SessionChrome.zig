//! The Session screen's state slot, Footer line and clickable keys. It owns
//! the rows and chips that
//! present what `session_chrome` decided, and puts them in the Session
//! screen's slots each frame from the values the screen passes. It holds no
//! decision and no state but its widgets: the screen keeps the notice
//! (`session_chrome.Notice`) and the title (`session_chrome.Title`). Every
//! click runs one of the screen's own actions, the same one its key runs.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const chrome = @import("session_chrome.zig");
const AppScreen = @import("AppScreen.zig");
const ActivityBlock = @import("ActivityBlock.zig");
const StatusRow = @import("StatusRow.zig");
const Chip = @import("Chip.zig");
const Footer = @import("widgets/Footer.zig");
const session_line = @import("session_line.zig");
const Self = @This();
const empty_marker: vxfw.Text = .{ .text = "" };

/// The screen's actions a click runs.
pub const Actions = struct {
    userdata: *anyopaque,
    /// `ctrl+r retries`, or whatever key the needs text ends with.
    key: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
    /// `ctrl+x stop`.
    stop: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
    /// `‹`: back to the overview, as Esc.
    back: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
    /// Restore an archived chat.
    unarchive: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
    /// `↓`: the latest view, as Esc.
    latest: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
    /// `+N more running · /status`.
    status_page: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
};

/// Semantic identity stays intact until the footer knows its available cells.
/// The existing formatter owns whole-item omission and name ellipsis.
pub const Identity = struct {
    current: ?session_line.Facts = null,
    name: []const u8 = "",
    archive: @import("protocol.zig").SessionArchiveState = .active,

    fn fit(self: Identity, buffer: *[chrome.facts_bytes]u8, width: usize, method: vaxis.gwidth.Method) []const u8 {
        var current = self.current;
        if (current) |*value| value.asks = false;
        const badge: ?[]const u8 = switch (self.archive) {
            .active => null,
            .archiving => "Stopping and archiving",
            .archived => "Archived",
        };
        return chrome.factsRow(buffer, current, self.name, badge, width, method);
    }
};

/// What the screen read for this frame.
pub const View = struct {
    /// Shell fact, never inferred from this pane's width.
    list_visible: bool = false,
    /// Anchor held away from the end: the reserved marker row shows its chip.
    browsing: bool = false,
    /// Transcript entries that arrived below while browsing.
    new_entries: u64 = 0,
    /// What needs the person, ending in its key (`! Not confirmed · ctrl+r
    /// retries`), and that key's words, which become clickable.
    needs: ?[]const u8 = null,
    needs_key: []const u8 = "",
    /// Where a send stands (`chrome.Send.progress`).
    progress: ?[]const u8 = null,
    stoppable: bool = false,
    /// Identity after the narrow back control, or the wide input gutter.
    facts: Identity = .{},
    /// The reply to the last key that shows now (`Notice.current`), and
    /// what the overview says (`chrome.Facts.overview`), each borrowed
    /// until the next frame.
    notice: ?[]const u8 = null,
    overview: ?[]const u8 = null,
    /// The screen's palette, or null.
    overlay: ?vxfw.Widget = null,
    width: u16,
};

status: StatusRow,
facts: struct {
    identity: Identity = .{},
    style: vaxis.Style = .{},
    method: vaxis.gwidth.Method = .unicode,
    back: Chip,
},
activity: ActivityBlock,
marker: Chip,
marker_text: [chrome.marker_bytes]u8 = undefined,
state: vxfw.Text = .{ .text = "", .softwrap = false, .overflow = .clip, .width_basis = .parent },
unarchive: Chip,
list_visible: bool = false,
stoppable: bool = false,

pub fn init(actions: Actions) Self {
    const chip = struct {
        fn of(on_click: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void, userdata: *anyopaque) Chip {
            return .{ .label = "", .userdata = userdata, .on_click = on_click };
        }
    }.of;
    return .{
        .status = .{ .key = chip(actions.key, actions.userdata), .stop = chip(actions.stop, actions.userdata) },
        .facts = .{ .back = chip(actions.back, actions.userdata) },
        .activity = .{ .more = chip(actions.status_page, actions.userdata) },
        .marker = chip(actions.latest, actions.userdata),
        .unarchive = chip(actions.unarchive, actions.userdata),
    };
}

/// Puts this frame's chrome in the Session screen's slots.
pub fn place(self: *Self, screen: *AppScreen.Session, view: View) void {
    self.status.bar = chrome.bar(.{
        .needs = view.needs,
        .progress = view.progress,
        .notice = view.notice,
        .overview = view.overview,
        .width = view.width,
        .method = self.status.method,
    });
    self.status.key.label = if (view.needs != null) view.needs_key else "";
    self.facts.identity = view.facts;
    self.list_visible = view.list_visible;
    self.stoppable = view.stoppable;
    self.state.text = stateText(self.status.bar.left, self.status.key.label);
    self.state.style = if (self.status.bar.tone == .attention) self.status.attention else self.status.quiet;
    screen.input.facts = .{ .userdata = self, .drawFn = drawFooter };
    screen.input.status = self.state.widget();
    // Activity is the Feed's last entry, not a separate shell row.
    screen.tail = null;
    self.marker.label = chrome.marker(&self.marker_text, view.new_entries);
    screen.marker = if (view.browsing) self.marker.widget() else empty_marker.widget();
    screen.overlay = view.overlay;
}

fn stateText(text: []const u8, key: []const u8) []const u8 {
    if (key.len != 0 and std.mem.endsWith(u8, text, key)) {
        const prefix = text[0 .. text.len - key.len];
        if (std.mem.endsWith(u8, prefix, " · ")) return prefix[0 .. prefix.len - " · ".len];
    }
    return text;
}

/// Identity fits whole items in the left budget; Footer owns alignment and
/// final cell clipping. The chips only add mouse targets to
/// those same cells, using the same actions as the keyboard.
fn drawFooter(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.unarchive.label = if (self.facts.identity.archive == .archived) "/unarchive" else "";
    self.status.stop.label = if (self.stoppable) chrome.stop_key else "";
    const keys = [_]*Chip{ &self.status.key, &self.unarchive, &self.status.stop };
    var right: std.ArrayList(u8) = .empty;
    for (keys) |key| if (key.label.len != 0) {
        if (right.items.len != 0) try right.appendSlice(ctx.arena, " · ");
        try right.appendSlice(ctx.arena, key.label);
    };
    const size = ctx.max.size();
    const right_width: u16 = @intCast(@min(ctx.stringWidth(right.items), size.width));
    const right_col = size.width - right_width;
    const prefix = if (self.list_visible) " " else " ‹ ";
    const gap: u16 = @intFromBool(right_width != 0);
    const room = right_col -| gap -| @as(u16, @intCast(ctx.stringWidth(prefix)));
    const buffer = try ctx.arena.create([chrome.facts_bytes]u8);
    const label = self.facts.identity.fit(buffer, room, self.facts.method);
    const left = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, label });
    const footer = try ctx.arena.create(Footer);
    footer.* = .{ .left = left, .right = right.items, .style = self.facts.style };
    var surface = try footer.widget().draw(ctx);
    surface.widget = .{ .userdata = self, .drawFn = drawFooter };
    if (surface.size.width == 0 or surface.size.height == 0) return surface;
    const children = try ctx.arena.alloc(vxfw.SubSurface, keys.len + 1);
    var count: usize = 0;
    if (!self.list_visible and right_col > 1) {
        self.facts.back.label = "‹";
        children[count] = try footerChip(&self.facts.back, self.facts.style, ctx, 1, 1);
        count += 1;
    }
    var col: usize = right_col;
    var first = true;
    for (keys) |key| if (key.label.len != 0) {
        if (!first) col += ctx.stringWidth(" · ");
        first = false;
        if (col < surface.size.width) {
            const width: u16 = @intCast(@min(ctx.stringWidth(key.label), surface.size.width - col));
            children[count] = try footerChip(key, self.facts.style, ctx, @intCast(col), width);
            count += 1;
        }
        col += ctx.stringWidth(key.label);
    };
    surface.children = children[0..count];
    return surface;
}

fn footerChip(chip: *Chip, style: vaxis.Style, ctx: vxfw.DrawContext, col: u16, width: u16) !vxfw.SubSurface {
    chip.style = style;
    chip.hover = style;
    chip.hover.ul_style = .single;
    return .{ .origin = .{ .col = col, .row = 0 }, .surface = try chip.widget().draw(ctx.withConstraints(.{}, .{ .width = width, .height = 1 })) };
}

const Recorder = struct {
    clicked: std.enums.EnumArray(enum { key, stop, back, latest, status_page, unarchive }, usize) = .initFill(0),
    fn on(comptime which: anytype) *const fn (*anyopaque, *vxfw.EventContext) anyerror!void {
        return struct {
            fn click(raw: *anyopaque, _: *vxfw.EventContext) !void {
                const self: *Recorder = @ptrCast(@alignCast(raw));
                self.clicked.set(which, self.clicked.get(which) + 1);
            }
        }.click;
    }
    fn actions(self: *Recorder) Actions {
        return .{ .userdata = self, .key = on(.key), .stop = on(.stop), .back = on(.back), .latest = on(.latest), .status_page = on(.status_page), .unarchive = on(.unarchive) };
    }
    fn event(_: *anyopaque, _: *vxfw.EventContext, _: vxfw.Event) !void {}
};

fn clickAt(frame: vxfw.Surface, arena: std.mem.Allocator, ctx: *vxfw.EventContext, row: u16, col: u16) !void {
    var hits: std.ArrayList(vxfw.HitResult) = .empty;
    try frame.hitTest(arena, &hits, .{ .row = row, .col = col });
    const target = hits.items[hits.items.len - 1].widget;
    const press: vaxis.Mouse = .{ .col = @intCast(col), .row = @intCast(row), .button = .left, .mods = .{}, .type = .press };
    var release = press;
    release.type = .release;
    try target.handleEvent(ctx, .{ .mouse = press });
    try target.handleEvent(ctx, .{ .mouse = release });
}

test "the Session chrome fills the slots for the latest view and for browsing, and each click runs its action" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    var bytes: [16]u8 = undefined;
    const editor: @import("TerminalEditor.zig") = .{ .buffer = &bytes };
    var input: @import("InputArea.zig") = .{ .composer = .{ .editor = &editor } };
    const document = try std.testing.allocator.create(@import("ConversationViewport.zig").Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    try document.append("› Port the overview\nI'll start.\n");
    var transcript: @import("DocumentView.zig") = .{ .document = document };
    var facade: AppScreen.Content = .{ .shown = transcript.widget() };
    var screen: AppScreen.Session = .{ .content = &facade, .input = &input, .userdata = &recorder, .on_event = Recorder.event };
    self.activity.work = .{ .mark = "⠹", .tone = .normal, .words = "Thinking", .clock = .{ .elapsed = 12 } };
    self.activity.live.count = 0;
    self.activity.live.total = 5;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
    const view: View = .{ .needs = "! Not confirmed · ctrl+r retries", .needs_key = "ctrl+r retries", .stoppable = true, .facts = .{ .current = .{ .name = "Fix flaky store test", .model = "gpt-6.1-sol", .effort = .high, .left = 62 } }, .width = 80 };

    self.place(&screen, view);
    try std.testing.expect(screen.tail == null and screen.marker != null);
    const live = try screen.widget().draw(draw);
    try clickAt(live, arena.allocator(), &ctx, 22, 1);
    try clickAt(live, arena.allocator(), &ctx, 22, 55);
    try clickAt(live, arena.allocator(), &ctx, 22, 70);
    try std.testing.expectEqual(@as(usize, 0), recorder.clicked.get(.status_page));
    try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.back));
    try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.key));
    try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.stop));

    var browsing = view;
    browsing.browsing = true;
    browsing.new_entries = 3;
    self.place(&screen, browsing);
    try std.testing.expect(screen.tail == null);
    const back = try screen.widget().draw(draw);
    try std.testing.expectEqualStrings("↓ 3 new", self.marker.label);
    try clickAt(back, arena.allocator(), &ctx, 18, 75);
    try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.latest));
}

test "the status row shows the notice under what needs the person, and preserves the palette" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    var bytes: [16]u8 = undefined;
    const editor: @import("TerminalEditor.zig") = .{ .buffer = &bytes };
    var input: @import("InputArea.zig") = .{ .composer = .{ .editor = &editor } };
    const document = try std.testing.allocator.create(@import("ConversationViewport.zig").Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    var transcript: @import("DocumentView.zig") = .{ .document = document };
    var facade: AppScreen.Content = .{ .shown = transcript.widget() };
    var screen: AppScreen.Session = .{ .content = &facade, .input = &input, .userdata = &recorder, .on_event = Recorder.event };
    const palette: vxfw.Text = .{ .text = "/model" };

    self.place(&screen, .{ .width = 80, .notice = "Copied 12 lines", .overlay = palette.widget() });
    try std.testing.expectEqualStrings("Copied 12 lines", self.status.bar.left);
    try std.testing.expect(screen.overlay.?.eql(palette.widget()));
    self.place(&screen, .{ .width = 80 });
    try std.testing.expect(screen.overlay == null);
    self.place(&screen, .{ .width = 80, .notice = "Copied 12 lines", .needs = "! Not confirmed · ctrl+r retries", .needs_key = "ctrl+r retries" });
    try std.testing.expectEqualStrings("! Not confirmed · ctrl+r retries", self.status.bar.left);
    try std.testing.expectEqualStrings("ctrl+r retries", self.status.key.label);
}

test "SessionChrome footer keeps identity left and active keys right, with back only while the list is hidden" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    var bytes: [16]u8 = undefined;
    const editor: @import("TerminalEditor.zig") = .{ .buffer = &bytes };
    var input: @import("InputArea.zig") = .{ .composer = .{ .editor = &editor } };
    const document = try std.testing.allocator.create(@import("ConversationViewport.zig").Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    var transcript: @import("DocumentView.zig") = .{ .document = document };
    var facade: AppScreen.Content = .{ .shown = transcript.widget() };
    var screen: AppScreen.Session = .{ .content = &facade, .input = &input, .userdata = &recorder, .on_event = Recorder.event };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    // Visibility is an input from Root, never a width inference in the chat.
    for ([_]u16{ 140, 46 }) |width| for ([_]bool{ true, false }) |list_visible| {
        self.place(&screen, .{ .width = width, .facts = .{ .current = .{ .name = "Chat", .model = "model", .effort = .high, .left = 62 } }, .list_visible = list_visible, .stoppable = true, .notice = "Copied 12 lines" });
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} };
        const footer = try input.facts.draw(ctx);
        try std.testing.expectEqual(@as(u16, 1), footer.size.height);
        try std.testing.expectEqualStrings(" ", footer.readCell(0, 0).char.grapheme);
        try std.testing.expectEqualStrings(if (list_visible) "C" else "‹", footer.readCell(1, 0).char.grapheme);
        try std.testing.expectEqualStrings("c", footer.readCell(width - 11, 0).char.grapheme);
        try std.testing.expectEqualStrings("Copied 12 lines", self.state.text);
        if (!list_visible) try clickAt(footer, arena.allocator(), &events, 0, 1);
        try clickAt(footer, arena.allocator(), &events, 0, width - 1);
    };
    try std.testing.expectEqual(@as(usize, 2), recorder.clicked.get(.back));
    try std.testing.expectEqual(@as(usize, 4), recorder.clicked.get(.stop));
    self.place(&screen, .{ .width = 46, .facts = .{ .name = "Chat", .archive = .archived } });
    const archived = try input.facts.draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 1 }, .cell_size = .{} });
    try clickAt(archived, arena.allocator(), &events, 0, 45);
    try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.unarchive));
    for (0..8) |width| for (0..2) |height| {
        const tiny = try input.facts.draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = @intCast(height) }, .cell_size = .{} });
        try std.testing.expect(tiny.size.width <= width and tiny.size.height <= height);
        for (tiny.children) |child| try std.testing.expect(child.origin.col + child.surface.size.width <= width);
    };
}

test "SessionChrome identity omits permission settings and archive command hints" {
    var bytes: [chrome.facts_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Chat · model · high · 62% left", (@as(Identity, .{ .current = .{ .name = "Chat", .model = "model", .effort = .high, .left = 62, .asks = true }, .name = "ref" })).fit(&bytes, 140, .unicode));
    try std.testing.expectEqualStrings("ref · Archived", (@as(Identity, .{ .name = "ref", .archive = .archived })).fit(&bytes, 46, .unicode));
    try std.testing.expectEqualStrings("! Not confirmed", stateText("! Not confirmed · ctrl+r retries original", "ctrl+r retries original"));
    try std.testing.expectEqualStrings("Copied 12 lines", stateText("Copied 12 lines", ""));
}

test "SessionChrome footer keeps the input gutter beside the visible list" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    self.list_visible = true;
    self.facts.identity = .{ .current = .{ .name = "Fix retry deadline", .model = "gpt-6.1-sol", .effort = .high, .left = 100 } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // A 140-column shell leaves 99 columns to the chat beside its list.
    const footer = try drawFooter(&self, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 99, .height = 1 }, .cell_size = .{} });
    try std.testing.expectEqualStrings(" ", footer.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("F", footer.readCell(1, 0).char.grapheme);
    for (footer.buffer) |cell| try std.testing.expect(!std.mem.eql(u8, cell.char.grapheme, "‹"));
}

test "SessionChrome footer drops whole items with an ellipsis at narrow widths" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |list_visible| for ([_]u8{ 0, 1, 62, 100 }) |left| {
        self.list_visible = list_visible;
        self.facts.identity = .{ .current = .{ .name = "Fix retry deadline", .model = "gpt-6.1-sol", .effort = .high, .left = left } };
        const footer = try drawFooter(&self, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 1 }, .cell_size = .{} });
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (footer.buffer) |cell| try text.writer.writeAll(cell.char.grapheme);
        try std.testing.expectEqualStrings(if (list_visible) " Fix retry deadline · gpt-6.1-sol · high · …" else " ‹ Fix retry deadline · gpt-6.1-sol · high · …", std.mem.trimEnd(u8, text.written(), " "));
    };
    self.stoppable = true;
    const stopped = try drawFooter(&self, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 1 }, .cell_size = .{} });
    var text: std.Io.Writer.Allocating = .init(arena.allocator());
    for (stopped.buffer) |cell| try text.writer.writeAll(cell.char.grapheme);
    try std.testing.expectEqualStrings(" Fix retry deadline · …            ctrl+x stop", text.written());
}

test "Session chrome back control exists only while the shell hides the list" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    var bytes: [1]u8 = undefined;
    const editor: @import("TerminalEditor.zig") = .{ .buffer = &bytes };
    var input: @import("InputArea.zig") = .{ .composer = .{ .editor = &editor } };
    var screen: AppScreen.Session = .{ .content = undefined, .input = &input, .userdata = &recorder, .on_event = Recorder.event };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 1 }, .cell_size = .{} };
    for ([_]bool{ true, false, true, false }) |list_visible| {
        self.place(&screen, .{ .width = 80, .list_visible = list_visible, .facts = .{ .current = .{ .name = "demo", .model = "gpt-5.5", .effort = .low, .left = 100 } } });
        const row = try input.facts.draw(draw);
        if (list_visible) {
            try std.testing.expectEqualStrings("d", row.readCell(1, 0).char.grapheme);
            try std.testing.expectEqual(@as(usize, 0), row.children.len);
        } else {
            try std.testing.expectEqualStrings("d", row.readCell(3, 0).char.grapheme);
            try std.testing.expectEqualStrings("‹", row.children[0].surface.readCell(0, 0).char.grapheme);
        }
        const before = recorder.clicked.get(.back);
        const press: vaxis.Mouse = .{ .col = 1, .row = 0, .button = .left, .mods = .{}, .type = .press };
        var release = press;
        release.type = .release;
        try @import("testing/app_events.zig").mouse(&ctx, row, press);
        try @import("testing/app_events.zig").mouse(&ctx, row, release);
        try std.testing.expectEqual(before + @intFromBool(!list_visible), recorder.clicked.get(.back));
    }
}

test "SessionChrome footer and new-entry chips underline on hover without acting" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    self.facts.identity.archive = .archived;
    self.status.key.label = "ctrl+r retries";
    self.stoppable = true;
    self.marker.label = "↓ 3 new";
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 1 }, .cell_size = .{} };
    const footer = try drawFooter(&self, draw_ctx);
    try std.testing.expectEqual(@as(usize, 4), footer.children.len);
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]*Chip{ &self.facts.back, &self.status.key, &self.unarchive, &self.status.stop, &self.marker }) |chip| {
        try chip.widget().handleEvent(&ctx, .mouse_enter);
        const hovered = try chip.widget().draw(draw_ctx);
        try std.testing.expectEqual(.single, hovered.readCell(0, 0).style.ul_style);
        try std.testing.expectEqual(vaxis.Mouse.Shape.pointer, ctx.cmds.items[ctx.cmds.items.len - 1].set_mouse_shape);
        const press: vaxis.Mouse = .{ .col = 0, .row = 0, .button = .left, .mods = .{}, .type = .press };
        try chip.widget().handleEvent(&ctx, .{ .mouse = press });
        try chip.widget().handleEvent(&ctx, .mouse_leave);
        var release = press;
        release.type = .release;
        try chip.widget().handleEvent(&ctx, .{ .mouse = release });
        const left = try chip.widget().draw(draw_ctx);
        try std.testing.expectEqual(.off, left.readCell(0, 0).style.ul_style);
    }
    for (recorder.clicked.values) |count| try std.testing.expectEqual(@as(usize, 0), count);
}
