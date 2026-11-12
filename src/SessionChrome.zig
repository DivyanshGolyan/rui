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
    close: ?*const fn (*anyopaque, *vxfw.EventContext) anyerror!void = null,
    pick: ?*const fn (*anyopaque, *vxfw.EventContext) anyerror!void = null,
    model: ?*const fn (*anyopaque, *vxfw.EventContext) anyerror!void = null,
    effort: ?*const fn (*anyopaque, *vxfw.EventContext) anyerror!void = null,
    details: ?*const fn (*anyopaque, *vxfw.EventContext) anyerror!void = null,
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
    /// The chat info panel.
    status_page: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
};

/// Semantic identity stays intact until the footer knows its available cells.
/// The existing formatter owns whole-item omission and name ellipsis.
pub const Identity = struct {
    current: ?session_line.Facts = null,
    name: []const u8 = "",
    archive: @import("protocol.zig").SessionArchiveState = .active,

    fn fit(self: Identity, buffer: *[chrome.facts_bytes]u8, width: usize, method: vaxis.gwidth.Method) []const u8 {
        return self.spans(buffer, width, method).text;
    }

    fn spans(self: Identity, buffer: *[chrome.facts_bytes]u8, width: usize, method: vaxis.gwidth.Method) chrome.FooterSpans {
        const badge: ?[]const u8 = switch (self.archive) {
            .active => null,
            .archiving => "Stopping and archiving",
            .archived => "Archived",
        };
        return chrome.factsSpans(buffer, self.current, self.name, badge, width, method);
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
    details: bool = false,
    /// Identity after the narrow back control, or the wide input gutter.
    facts: Identity = .{},
    /// The reply to the last key that shows now (`Notice.current`), and
    /// what the overview says (`chrome.Facts.overview`), each borrowed
    /// until the next frame.
    notice: ?[]const u8 = null,
    overview: ?[]const u8 = null,
    /// The screen's palette, or null.
    overlay: ?vxfw.Widget = null,
    choice: chrome.ChoiceState = .closed,
    width: u16,
};

status: StatusRow,
facts: struct {
    identity: Identity = .{},
    style: vaxis.Style = .{},
    method: vaxis.gwidth.Method = .unicode,
    back: Chip,
    model: Chip,
    effort: Chip,
    focus: chrome.FooterFocus = .input,
    selected: vaxis.Style = .{ .reverse = true },
},
activity: ActivityBlock,
marker: Chip,
marker_text: [chrome.marker_bytes]u8 = undefined,
state: vxfw.Text = .{ .text = "", .softwrap = false, .overflow = .clip, .width_basis = .parent },
unarchive: Chip,
info: Chip,
pick: Chip,
close: Chip,
keys: chrome.FooterKeys = chrome.footerKeys(.closed),
details: Chip,
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
        .facts = .{ .back = chip(actions.back, actions.userdata), .model = chip(actions.model orelse actions.status_page, actions.userdata), .effort = chip(actions.effort orelse actions.status_page, actions.userdata) },
        .activity = .{ .more = chip(actions.status_page, actions.userdata) },
        .marker = chip(actions.latest, actions.userdata),
        .unarchive = chip(actions.unarchive, actions.userdata),
        .info = chip(actions.status_page, actions.userdata),
        .pick = chip(actions.pick orelse actions.status_page, actions.userdata),
        .close = chip(actions.close orelse actions.status_page, actions.userdata),
        .details = chip(actions.details orelse actions.key, actions.userdata),
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
    self.keys = chrome.footerKeys(view.choice);
    self.details.label = if (view.details) "alt+d details" else "";
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
    self.unarchive.label = if (self.keys.other_actions and self.facts.identity.archive == .archived) "/unarchive" else "";
    self.status.stop.label = if (self.keys.other_actions and self.stoppable) chrome.stop_key else "";
    const primary = if (self.keys.choice) |keys| self.choiceChip(keys.actions[0].action) else switch (self.keys.action) {
        .info => &self.info,
        .pick => &self.pick,
    };
    const secondary = if (self.keys.choice) |keys| self.choiceChip(keys.actions[1].action) else &self.close;
    primary.label = self.keys.text;
    secondary.label = if (self.keys.choice) |keys| keys.actions[1].text else "";
    if (!self.keys.other_actions) {
        self.status.key.label = "";
        self.details.label = "";
    }
    const primary_width = primary.width() + self.status.key.width() + self.unarchive.width() + self.status.stop.width() + 9;
    if (primary_width + self.details.width() > ctx.max.width.?) self.details.label = "";
    const keys = [_]*Chip{ primary, secondary, &self.details, &self.status.key, &self.unarchive, &self.status.stop };
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
    const spans = self.facts.identity.spans(buffer, room, self.facts.method);
    const label = spans.text;
    const left = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, label });
    const footer = try ctx.arena.create(Footer);
    footer.* = .{ .left = left, .right = right.items, .style = self.facts.style };
    var surface = try footer.widget().draw(ctx);
    surface.widget = .{ .userdata = self, .drawFn = drawFooter };
    if (surface.size.width == 0 or surface.size.height == 0) return surface;
    const children = try ctx.arena.alloc(vxfw.SubSurface, keys.len + spans.len + 1);
    var count: usize = 0;
    if (!self.list_visible and right_col > 1) {
        self.facts.back.label = "‹";
        children[count] = try footerChip(&self.facts.back, self.facts.style, self.facts.method, ctx, 1, 1);
        count += 1;
    }
    var identity_col: usize = ctx.stringWidth(prefix);
    for (spans.spans[0..spans.len]) |span| {
        const width = ctx.stringWidth(span.text);
        if (span.field) |field| {
            const chip = switch (field) {
                .model => &self.facts.model,
                .effort => &self.facts.effort,
            };
            chip.label = span.text;
            const selected = switch (field) {
                .model => self.facts.focus == .model,
                .effort => self.facts.focus == .effort,
            };
            if (identity_col + width <= right_col) {
                children[count] = try footerChip(chip, if (selected) self.facts.selected else self.facts.style, self.facts.method, ctx, @intCast(identity_col), @intCast(width));
                count += 1;
            }
        }
        identity_col += width;
    }
    var col: usize = right_col;
    var first = true;
    for (keys) |key| if (key.label.len != 0) {
        if (!first) col += ctx.stringWidth(" · ");
        first = false;
        if (col < surface.size.width) {
            const width: u16 = @intCast(@min(ctx.stringWidth(key.label), surface.size.width - col));
            children[count] = try footerChip(key, self.facts.style, self.facts.method, ctx, @intCast(col), width);
            count += 1;
        }
        col += ctx.stringWidth(key.label);
    };
    surface.children = children[0..count];
    return surface;
}

fn choiceChip(self: *Self, action: chrome.ChoiceAction) *Chip {
    return switch (action) {
        .pick => &self.pick,
        .close => &self.close,
    };
}

fn footerChip(chip: *Chip, style: vaxis.Style, method: vaxis.gwidth.Method, ctx: vxfw.DrawContext, col: u16, width: u16) !vxfw.SubSurface {
    chip.method = method;
    chip.style = style;
    chip.hover = style;
    chip.hover.ul_style = .single;
    return .{ .origin = .{ .col = col, .row = 0 }, .surface = try chip.widget().draw(ctx.withConstraints(.{}, .{ .width = width, .height = 1 })) };
}

const Recorder = struct {
    const Action = enum { key, stop, back, latest, status_page, unarchive, model, effort, pick, close };
    clicked: std.enums.EnumArray(Action, usize) = .initFill(0),
    fn on(comptime which: anytype) *const fn (*anyopaque, *vxfw.EventContext) anyerror!void {
        return struct {
            fn click(raw: *anyopaque, _: *vxfw.EventContext) !void {
                const self: *Recorder = @ptrCast(@alignCast(raw));
                self.clicked.set(which, self.clicked.get(which) + 1);
            }
        }.click;
    }
    fn actions(self: *Recorder) Actions {
        return .{ .userdata = self, .key = on(.key), .stop = on(.stop), .back = on(.back), .latest = on(.latest), .status_page = on(.status_page), .unarchive = on(.unarchive), .model = on(.model), .effort = on(.effort), .pick = on(.pick), .close = on(.close) };
    }
    fn event(_: *anyopaque, _: *vxfw.EventContext, _: vxfw.Event) !void {}
};

fn clickAt(frame: vxfw.Surface, arena: std.mem.Allocator, ctx: *vxfw.EventContext, row: u16, col: u16) !void {
    var hits: std.ArrayList(vxfw.HitResult) = .empty;
    try frame.hitTest(arena, &hits, .{ .row = row, .col = col });
    if (hits.items.len == 0) return;
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
    const palette: vxfw.Text = .{ .text = "/setup" };

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

test "SessionChrome identity includes short ask fact but omits archive command hints" {
    var bytes: [chrome.facts_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Chat · model · high · 62% left · ask", (@as(Identity, .{ .current = .{ .name = "Chat", .model = "model", .effort = .high, .left = 62, .asks = true }, .name = "ref" })).fit(&bytes, 140, .unicode));
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

test "SessionChrome narrow footer preserves model effort and context before the name" {
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
        const want = try std.fmt.allocPrint(arena.allocator(), "{s}{s}gpt-6.1-sol · high · {d}% left", .{ if (list_visible) " " else " ‹ ", if (list_visible and left < 10) "Fi… · " else if (list_visible and left < 100) "F… · " else "", left });
        try std.testing.expectEqualStrings(want, std.mem.trimEnd(u8, text.written()[0..std.mem.indexOf(u8, text.written(), "alt+i info").?], " "));
        try std.testing.expect(std.mem.endsWith(u8, text.written(), "alt+i info"));
    };
    self.stoppable = true;
    const stopped = try drawFooter(&self, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 1 }, .cell_size = .{} });
    var text: std.Io.Writer.Allocating = .init(arena.allocator());
    for (stopped.buffer) |cell| try text.writer.writeAll(cell.char.grapheme);
    try std.testing.expect(std.mem.startsWith(u8, text.written(), " gpt-6.1-sol · high"));
    try std.testing.expect(std.mem.endsWith(u8, text.written(), "alt+i info · ctrl+x stop"));
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
            try std.testing.expectEqual(@as(usize, 3), row.children.len);
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

test "SessionChrome model and effort words are independent controls beside the info hint" {
    for ([_]u16{ 46, 140 }) |width| for ([_]bool{ false, true }) |list_visible| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var recorder: Recorder = .{};
        var self: Self = .init(recorder.actions());
        self.list_visible = list_visible;
        self.facts.identity = .{ .current = .{ .name = "Chat", .model = "gpt-6-luna", .effort = .low, .left = 62 } };
        const footer = try drawFooter(&self, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} });
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        defer ctx.cmds.deinit(arena.allocator());
        var cells: usize = 0;
        for (footer.children) |child| if (child.surface.widget.eql(self.facts.model.widget()) or child.surface.widget.eql(self.facts.effort.widget()) or child.surface.widget.eql(self.info.widget())) {
            for (0..child.surface.size.width) |offset| {
                const col: i16 = @intCast(child.origin.col + @as(i17, @intCast(offset)));
                const action: Recorder.Action = if (child.surface.widget.eql(self.facts.model.widget())) .model else if (child.surface.widget.eql(self.facts.effort.widget())) .effort else .status_page;
                const before = recorder.clicked.get(action);
                for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try @import("testing/app_events.zig").mouse(&ctx, footer, .{ .row = 0, .col = col, .button = .left, .mods = .{}, .type = kind });
                try std.testing.expectEqual(before + 1, recorder.clicked.get(action));
                cells += 1;
            }
        };
        try std.testing.expect(cells >= "alt+i info".len);
        try std.testing.expectEqual(@as(usize, 0), recorder.clicked.get(.back));
        if (!list_visible) {
            for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try @import("testing/app_events.zig").mouse(&ctx, footer, .{ .row = 0, .col = 1, .button = .left, .mods = .{}, .type = kind });
            try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.back));
        }
    };
}

test "SessionChrome identity chips preserve cells and clicks for every terminal width method" {
    defer vxfw.DrawContext.init(.unicode);
    const names = [_][]const u8{ "👩‍🚀X", "❤️X", "Retry 👩‍🚀 with ❤️" };
    for ([_]vaxis.gwidth.Method{ .wcwidth, .unicode, .no_zwj }) |method| for (names) |name| for ([_]bool{ false, true }) |list_visible| for (0..66) |size| {
        const width: u16 = if (size == 65) 140 else @intCast(size);
        vxfw.DrawContext.init(method);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var recorder: Recorder = .{};
        var self: Self = .init(recorder.actions());
        self.list_visible = list_visible;
        self.facts.method = method;
        self.facts.identity = .{ .current = .{ .name = name, .model = "model", .effort = .low, .left = 62 } };
        const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} };
        const footer = try drawFooter(&self, draw);
        var terminal: vaxis.Screen = .{ .width = width, .height = 1, .width_method = method, .buf = try arena.allocator().alloc(vaxis.Cell, width) };
        @memset(terminal.buf, .{});
        footer.render(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 1, .screen = &terminal }, self.facts.model.widget());
        // Footer owns the text and its cell positions. Adding mouse targets
        // must not move or repaint any glyph with a different terminal width.
        for (footer.buffer, terminal.buf) |expected, actual| {
            try std.testing.expectEqualStrings(expected.char.grapheme, actual.char.grapheme);
            try std.testing.expectEqual(expected.char.width, actual.char.width);
        }
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        defer events.cmds.deinit(arena.allocator());
        for (footer.children) |child| {
            try std.testing.expect(child.origin.col >= 0);
            try std.testing.expect(child.origin.col + child.surface.size.width <= width);
            for (child.surface.buffer, 0..) |cell, col| try std.testing.expect(col + cell.char.width <= child.surface.size.width);
            if (!child.surface.widget.eql(self.facts.model.widget()) and !child.surface.widget.eql(self.facts.effort.widget()) and !child.surface.widget.eql(self.info.widget())) continue;
            for (0..child.surface.size.width) |offset| {
                const col: i16 = @intCast(child.origin.col + @as(i17, @intCast(offset)));
                const action: Recorder.Action = if (child.surface.widget.eql(self.facts.model.widget())) .model else if (child.surface.widget.eql(self.facts.effort.widget())) .effort else .status_page;
                const before = recorder.clicked.get(action);
                for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try @import("testing/app_events.zig").mouse(&events, footer, .{ .row = 0, .col = col, .button = .left, .mods = .{}, .type = kind });
                try std.testing.expectEqual(before + 1, recorder.clicked.get(action));
            }
        }
        try std.testing.expectEqual(@as(usize, 0), recorder.clicked.get(.back));
    };
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
    try std.testing.expectEqual(@as(usize, 5), footer.children.len);
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

test "SessionChrome drawn field identity survives a newer model and nonbutton words do not open choices" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    self.list_visible = true;
    self.facts.identity = .{ .current = .{ .name = "model", .model = "model", .effort = .low, .left = 62, .asks = true } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const footer = try drawFooter(&self, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 1 }, .cell_size = .{} });
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    // Same word appears as name and model: only the semantic model span acts.
    try clickAt(footer, arena.allocator(), &ctx, 0, 1);
    try std.testing.expectEqual(@as(usize, 0), recorder.clicked.get(.model));
    try std.testing.expectEqual(@as(usize, 0), recorder.clicked.get(.effort));
    try clickAt(footer, arena.allocator(), &ctx, 0, 9);
    try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.model));
    // Facts changed after draw; the drawn effort still names effort.
    self.facts.identity.current.?.effort = null;
    for (footer.children) |child| if (child.surface.widget.eql(self.facts.effort.widget())) {
        try clickAt(footer, arena.allocator(), &ctx, 0, @intCast(child.origin.col));
    };
    try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.effort));
    try std.testing.expectEqual(@as(usize, 0), recorder.clicked.get(.status_page));
}

test "SessionChrome footer text and button styling cover both widths applied efforts and ask bypass" {
    for ([_]u16{ 140, 46 }) |width| for ([_]chrome.FooterFocus{ .input, .model, .effort }) |focus| for ([_]bool{ false, true }) |explicit| for ([_]bool{ false, true }) |asks| {
        var recorder: Recorder = .{};
        var self: Self = .init(recorder.actions());
        self.facts.focus = focus;
        self.facts.identity = .{ .current = .{ .name = "C", .model = "m", .effort = if (explicit) .low else .high, .left = 62, .asks = asks } };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} };
        const footer = try drawFooter(&self, draw);
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (footer.buffer) |cell| try text.writer.writeAll(cell.char.grapheme);
        const left = try std.fmt.allocPrint(arena.allocator(), " ‹ C · m · {s} · 62% left{s}", .{ if (explicit) "low" else "high", if (asks) " · ask" else "" });
        try std.testing.expectEqualStrings(left, std.mem.trimEnd(u8, text.written()[0..std.mem.indexOf(u8, text.written(), "alt+i info").?], " "));
        try std.testing.expect(std.mem.endsWith(u8, text.written(), "alt+i info"));
        var buttons: usize = 0;
        for (footer.children) |child| {
            const model = child.surface.widget.eql(self.facts.model.widget());
            const effort = child.surface.widget.eql(self.facts.effort.widget());
            if (!model and !effort) continue;
            buttons += 1;
            try std.testing.expectEqual(if (model) focus == .model else focus == .effort, child.surface.readCell(0, 0).style.reverse);
            var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
            try child.surface.widget.handleEvent(&ctx, .mouse_enter);
            const hovered = try child.surface.widget.draw(draw);
            try std.testing.expectEqual(.single, hovered.readCell(0, 0).style.ul_style);
        }
        try std.testing.expectEqual(@as(usize, 2), buttons);
    };
}

test "SessionChrome standalone choice footer offers bounded existing pick and close actions" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    self.keys = chrome.footerKeys(.pick);
    self.stoppable = true;
    self.status.key.label = "ctrl+r retries";
    self.details.label = "alt+d details";
    self.facts.identity = .{ .name = "Chat", .archive = .archived };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const footer = try drawFooter(&self, .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 1 }, .cell_size = .{} });
    var text: std.Io.Writer.Allocating = .init(arena.allocator());
    for (footer.buffer) |cell| try text.writer.writeAll(cell.char.grapheme);
    try std.testing.expect(std.mem.endsWith(u8, text.written(), "enter pick · esc close"));
    for ([_][]const u8{ "alt+i", "alt+d", "ctrl+r", "ctrl+x", "/unarchive" }) |blocked| try std.testing.expect(std.mem.indexOf(u8, text.written(), blocked) == null);
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try clickAt(footer, arena.allocator(), &ctx, 0, 45);
    try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.close));
    try clickAt(footer, arena.allocator(), &ctx, 0, 25);
    try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.pick));
    try std.testing.expectEqual(@as(usize, 0), recorder.clicked.get(.status_page));
}
