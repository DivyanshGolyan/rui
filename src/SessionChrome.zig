const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const chrome = @import("session_chrome.zig");
const AppScreen = @import("AppScreen.zig");
const ActivityBlock = @import("ActivityBlock.zig");
const StatusRow = @import("StatusRow.zig");
const Chip = @import("Chip.zig");
const Hover = @import("widgets/Hover.zig");
const Footer = @import("widgets/Footer.zig");
const session_line = @import("session_line.zig");
const Self = @This();
const empty_marker: vxfw.Text = .{ .text = "" };

pub const Actions = struct {
    userdata: *anyopaque,
    close: ?*const fn (*anyopaque, *vxfw.EventContext) anyerror!void = null,
    pick: ?*const fn (*anyopaque, *vxfw.EventContext) anyerror!void = null,
    model: ?*const fn (*anyopaque, *vxfw.EventContext) anyerror!void = null,
    effort: ?*const fn (*anyopaque, *vxfw.EventContext) anyerror!void = null,
    details: ?*const fn (*anyopaque, *vxfw.EventContext) anyerror!void = null,
    key: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
    stop: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
    back: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
    latest: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
    status_page: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
};

pub const Identity = struct {
    current: ?session_line.Facts = null,
    archive: @import("protocol.zig").SessionArchiveState = .active,

    fn fit(self: Identity, buffer: *[chrome.facts_bytes]u8, width: usize, method: vaxis.gwidth.Method) []const u8 {
        return self.spans(buffer, width, method).text;
    }

    fn spans(self: Identity, buffer: *[chrome.facts_bytes]u8, width: usize, method: vaxis.gwidth.Method) chrome.FooterSpans {
        return chrome.factsSpans(buffer, self.current, chrome.archiveBadge(self.archive), width, method);
    }
};

pub const View = struct {
    list_visible: bool = false,
    browsing: bool = false,
    new_entries: u64 = 0,
    needs: ?[]const u8 = null,
    needs_key: []const u8 = "",
    progress: ?[]const u8 = null,
    stoppable: bool = false,
    details: bool = false,
    repair_details: bool = false,
    facts: Identity = .{},
    notice: ?[]const u8 = null,
    notice_priority: enum { normal, recovery } = .normal,
    overview: ?[]const u8 = null,
    overlay: ?@import("InputArea.zig").Panel = null,
    info_footer: ?vxfw.Widget = null,
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
    focus: ?chrome.FooterFocus = .input,
    selected: vaxis.Style = .{ .reverse = true },
},
activity: ActivityBlock,
marker: Chip,
marker_text: [chrome.marker_bytes]u8 = undefined,
state: vxfw.Text = .{ .text = "", .softwrap = false, .overflow = .clip, .width_basis = .parent },
info: Chip,
pick: Chip,
close: Chip,
keys: chrome.FooterKeys = chrome.footerKeys(.closed),
details: Chip,
repair_details: bool = false,
notice_priority: @FieldType(View, "notice_priority") = .normal,
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
        .info = chip(actions.status_page, actions.userdata),
        .pick = chip(actions.pick orelse actions.status_page, actions.userdata),
        .close = chip(actions.close orelse actions.status_page, actions.userdata),
        .details = chip(actions.details orelse actions.key, actions.userdata),
    };
}

pub fn place(self: *Self, screen: *AppScreen.Session, input: *@import("InputArea.zig"), view: View) void {
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
    self.repair_details = view.repair_details;
    self.notice_priority = view.notice_priority;
    self.state.text = stateText(self.status.bar.left, self.status.key.label);
    self.state.style = if (self.status.bar.tone == .attention) self.status.attention else self.status.quiet;
    input.facts = .{ .userdata = self, .drawFn = drawFooter };
    input.status = self.state.widget();
    if (view.info_footer) |footer| {
        input.facts = footer;
        input.status = null;
    }
    screen.tail = null;
    self.marker.label = chrome.marker(&self.marker_text, view.new_entries);
    screen.marker = if (view.browsing) self.marker.widget() else empty_marker.widget();
    input.panel = view.overlay;
}

fn stateText(text: []const u8, key: []const u8) []const u8 {
    if (key.len != 0 and std.mem.endsWith(u8, text, key)) {
        const prefix = text[0 .. text.len - key.len];
        if (std.mem.endsWith(u8, prefix, " · ")) return prefix[0 .. prefix.len - " · ".len];
    }
    return text;
}

fn drawFooter(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
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
    const repair_details = self.repair_details and self.keys.other_actions;
    if (repair_details) {
        self.status.key.label = "";
        if (primary.width() + self.details.width() + self.status.stop.width() + 9 > ctx.max.width.?) primary.label = "";
        if (self.details.width() + self.status.stop.width() + 6 > ctx.max.width.?) self.status.stop.label = "";
    } else {
        if (self.facts.identity.current) |facts| {
            if (facts.folder != null) self.details.label = "";
        }
        const primary_width = primary.width() + self.status.key.width() + self.status.stop.width() + 9;
        if (primary_width + self.details.width() > ctx.max.width.?) self.details.label = "";
    }
    const notice = if (repair_details and self.notice_priority == .normal) null else self.status.bar.notice;
    const keys = [_]*Chip{ primary, secondary, &self.details, &self.status.key, &self.status.stop };
    var right: std.ArrayList(u8) = .empty;
    for (keys) |key| if (key.label.len != 0) {
        if (right.items.len != 0) try right.appendSlice(ctx.arena, " · ");
        try right.appendSlice(ctx.arena, key.label);
    };
    const footer = try ctx.arena.create(Footer);
    footer.* = .{ .left = "", .right = right.items, .notice = if (notice) |text| try chrome.noticeLine(ctx.arena, text) else null, .style = self.facts.style };
    if (notice) |text| {
        var tone = self.facts.style;
        if (std.mem.startsWith(u8, text, "!")) tone.fg = self.status.attention.fg;
        footer.right_style = tone;
    }
    const size = ctx.max.size();
    const right_width: u16 = @intCast(@min(ctx.stringWidth(footer.rightText()), size.width));
    const right_col = size.width - right_width;
    const prefix = if (self.list_visible) " " else " ‹ ";
    const gap: u16 = @intFromBool(right_width != 0);
    const room = right_col -| gap -| @as(u16, @intCast(ctx.stringWidth(prefix)));
    const buffer = try ctx.arena.create([chrome.facts_bytes]u8);
    const spans = self.facts.identity.spans(buffer, room, self.facts.method);
    const label = spans.text;
    const left = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, label });
    footer.left = left;
    var surface = try footer.widget().draw(ctx);
    surface.widget = .{ .userdata = self, .drawFn = drawFooter, .eventHandler = footerEvent };
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
            const chip, const selected = switch (field) {
                .model => .{ &self.facts.model, self.facts.focus == .model },
                .effort => .{ &self.facts.effort, self.facts.focus == .effort },
            };
            chip.label = span.text;
            if (identity_col + width <= right_col) {
                children[count] = try footerChip(chip, if (selected) self.facts.selected else self.facts.style, self.facts.method, ctx, @intCast(identity_col), @intCast(width));
                count += 1;
            }
        }
        identity_col += width;
    }
    var col: usize = right_col;
    var first = true;
    for (keys) |key| if (notice == null and key.label.len != 0) {
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

fn footerEvent(raw: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.keys.choice == null) try self.info.widget().handleEvent(ctx, event);
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
    chip.hover = Hover.underlined(style);
    return .{ .origin = .{ .col = col, .row = 0 }, .surface = try chip.widget().draw(ctx.withConstraints(.{}, .{ .width = width, .height = 1 })) };
}

const Recorder = struct {
    const Action = enum { key, stop, back, latest, status_page, model, effort, pick, close };
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
        return .{ .userdata = self, .key = on(.key), .stop = on(.stop), .back = on(.back), .latest = on(.latest), .status_page = on(.status_page), .model = on(.model), .effort = on(.effort), .pick = on(.pick), .close = on(.close) };
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
    var editor: @import("DraftEditor.zig") = .init(&bytes);
    var input: @import("InputArea.zig") = .{ .composer = .{ .editor = &editor } };
    const document = try std.testing.allocator.create(@import("ConversationViewport.zig").Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    try document.append("› Port the overview\nI'll start.\n");
    var transcript: @import("DocumentView.zig") = .{ .document = document };
    var facade: AppScreen.Content = .{ .shown = transcript.widget() };
    var screen: AppScreen.Session = .{ .content = &facade, .input = input.widget(), .userdata = &recorder, .on_event = Recorder.event };
    self.activity.present(.{
        .work = .{ .mark = "◝", .tone = .normal, .words = "Thinking", .clock = .{ .elapsed = 12 } },
        .live = .{ .total = 5 },
    });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
    const view: View = .{ .needs = "! Not confirmed · ctrl+r retries", .needs_key = "ctrl+r retries", .stoppable = true, .facts = .{ .current = .{ .model = "gpt-6.1-sol", .effort = .high, .left = 62 } }, .width = 80 };

    self.place(&screen, &input, view);
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
    self.place(&screen, &input, browsing);
    try std.testing.expect(screen.tail == null);
    const back = try screen.widget().draw(draw);
    try std.testing.expectEqualStrings("↓ 3 new", self.marker.label);
    try clickAt(back, arena.allocator(), &ctx, 18, 75);
    try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.latest));
}

test "SessionChrome puts notices in Footer without a state row and preserves needs and palette" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    var bytes: [16]u8 = undefined;
    var editor: @import("DraftEditor.zig") = .init(&bytes);
    var input: @import("InputArea.zig") = .{ .composer = .{ .editor = &editor } };
    const document = try std.testing.allocator.create(@import("ConversationViewport.zig").Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    var transcript: @import("DocumentView.zig") = .{ .document = document };
    var facade: AppScreen.Content = .{ .shown = transcript.widget() };
    var screen: AppScreen.Session = .{ .content = &facade, .input = input.widget(), .userdata = &recorder, .on_event = Recorder.event };
    const palette: vxfw.Text = .{ .text = "/setup" };

    self.place(&screen, &input, .{ .width = 80, .notice = "Copied 12 lines", .overlay = .{ .inline_panel = palette.widget() } });
    try std.testing.expectEqualStrings("Copied 12 lines", self.status.bar.notice.?);
    try std.testing.expectEqualStrings("", self.state.text);
    try std.testing.expect(input.panel.?.inline_panel.eql(palette.widget()));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u16{ 46, 140 }) |width| {
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 12 }, .cell_size = .{} };
        self.place(&screen, &input, .{ .width = width, .facts = .{ .archive = .archived } });
        const idle = try input.widget().draw(ctx);
        self.place(&screen, &input, .{ .width = width, .facts = .{ .archive = .archived }, .progress = "Opening…" });
        const opening = try input.widget().draw(ctx);
        try std.testing.expectEqual(idle.size.height, opening.size.height);
        try std.testing.expectEqualStrings("", self.state.text);
        try std.testing.expectEqualStrings("Opening…", self.status.bar.notice.?);
        self.place(&screen, &input, .{ .width = width, .facts = .{ .archive = .archived }, .notice = "Copied 3 lines", .stoppable = true });
        const noticed = try input.widget().draw(ctx);
        try std.testing.expectEqual(idle.size.height, noticed.size.height);
        const footer = try input.facts.draw(ctx);
        for ("Copied 3 lines", width - "Copied 3 lines".len..) |byte, col| try std.testing.expectEqual(byte, footer.readCell(col, 0).char.grapheme[0]);
        try std.testing.expectEqual(@as(usize, 1), footer.children.len);
    }

    self.place(&screen, &input, .{ .width = 80 });
    try std.testing.expect(input.panel == null);
    self.place(&screen, &input, .{ .width = 80, .notice = "Copied 12 lines", .needs = "! Not confirmed · ctrl+r retries", .needs_key = "ctrl+r retries" });
    try std.testing.expectEqualStrings("! Not confirmed · ctrl+r retries", self.status.bar.left);
    try std.testing.expectEqualStrings("ctrl+r retries", self.status.key.label);
}

test "SUI-162 recovery notice priority follows the current view" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    var bytes: [16]u8 = undefined;
    var editor: @import("DraftEditor.zig") = .init(&bytes);
    var input: @import("InputArea.zig") = .{ .composer = .{ .editor = &editor } };
    var screen: AppScreen.Session = undefined;
    screen.input = input.widget();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 1 }, .cell_size = .{} };
    var view: View = .{ .width = 80, .repair_details = true, .details = true, .notice = "ctrl+r retries" };
    for ([_]bool{ false, true, false }) |recovery| {
        view.notice_priority = if (recovery) .recovery else .normal;
        self.place(&screen, &input, view);
        const footer = try input.facts.draw(ctx);
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (footer.buffer) |cell| if (cell.char.width != 0) try text.writer.writeAll(cell.char.grapheme);
        try std.testing.expectEqual(recovery, std.mem.indexOf(u8, text.written(), "ctrl+r retries") != null);
    }
    view.repair_details = false;
    self.place(&screen, &input, view);
    const footer = try input.facts.draw(ctx);
    var text: std.Io.Writer.Allocating = .init(arena.allocator());
    for (footer.buffer) |cell| if (cell.char.width != 0) try text.writer.writeAll(cell.char.grapheme);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "ctrl+r retries") != null);
    var info_footer: vxfw.Text = .{ .text = "info footer" };
    view.info_footer = info_footer.widget();
    view.notice_priority = .recovery;
    self.place(&screen, &input, view);
    try std.testing.expect(input.facts.eql(info_footer.widget()) and input.status == null);
    view.notice_priority = .normal;
    self.place(&screen, &input, view);
    try std.testing.expect(input.facts.eql(info_footer.widget()) and input.status == null);
}

test "SessionChrome footer keeps identity left and active keys right, with back only while the list is hidden" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    var bytes: [16]u8 = undefined;
    var editor: @import("DraftEditor.zig") = .init(&bytes);
    var input: @import("InputArea.zig") = .{ .composer = .{ .editor = &editor } };
    const document = try std.testing.allocator.create(@import("ConversationViewport.zig").Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    var transcript: @import("DocumentView.zig") = .{ .document = document };
    var facade: AppScreen.Content = .{ .shown = transcript.widget() };
    var screen: AppScreen.Session = .{ .content = &facade, .input = input.widget(), .userdata = &recorder, .on_event = Recorder.event };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]u16{ 140, 46 }) |width| for ([_]bool{ true, false }) |list_visible| {
        self.place(&screen, &input, .{ .width = width, .facts = .{ .current = .{ .model = "model", .effort = .high, .left = 62 } }, .list_visible = list_visible, .stoppable = true });
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} };
        const footer = try input.facts.draw(ctx);
        try std.testing.expectEqual(@as(u16, 1), footer.size.height);
        try std.testing.expectEqualStrings(" ", footer.readCell(0, 0).char.grapheme);
        try std.testing.expectEqualStrings(if (list_visible) "m" else "‹", footer.readCell(1, 0).char.grapheme);
        try std.testing.expectEqualStrings("c", footer.readCell(width - 11, 0).char.grapheme);
        try std.testing.expectEqualStrings("", self.state.text);
        if (!list_visible) try clickAt(footer, arena.allocator(), &events, 0, 1);
        try clickAt(footer, arena.allocator(), &events, 0, width - 1);
    };
    try std.testing.expectEqual(@as(usize, 2), recorder.clicked.get(.back));
    try std.testing.expectEqual(@as(usize, 4), recorder.clicked.get(.stop));
    self.place(&screen, &input, .{ .width = 46, .facts = .{ .archive = .archived } });
    const archived = try input.facts.draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 1 }, .cell_size = .{} });
    for (archived.buffer) |cell| try std.testing.expect(!std.mem.eql(u8, cell.char.grapheme, "/"));
    for (0..8) |width| for (0..2) |height| {
        const tiny = try input.facts.draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = @intCast(height) }, .cell_size = .{} });
        try std.testing.expect(tiny.size.width <= width and tiny.size.height <= height);
        for (tiny.children) |child| try std.testing.expect(child.origin.col + child.surface.size.width <= width);
    };
}

test "SessionChrome archive confirmation is one durable badge at both widths, with no empty row" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    var bytes: [16]u8 = undefined;
    var editor: @import("DraftEditor.zig") = .init(&bytes);
    var input: @import("InputArea.zig") = .{ .composer = .{ .editor = &editor } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var screen: AppScreen.Session = undefined;
    screen.input = input.widget();
    for ([_]u16{ 46, 99, 140 }) |width| {
        self.place(&screen, &input, .{ .width = width, .facts = .{ .current = .{ .model = "gpt-6.1-sol", .effort = .low, .left = 100 }, .archive = .archived } });
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 30 }, .cell_size = .{} };
        const drawn = try input.widget().draw(ctx);
        try std.testing.expectEqual(@as(u16, 4), drawn.size.height);
        try std.testing.expectEqual(@as(usize, 2), drawn.children.len);
        const footer = drawn.children[1].surface;
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (footer.buffer) |cell| if (cell.char.width != 0) try text.writer.writeAll(cell.char.grapheme);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text.written(), "Archived"));
        try std.testing.expect(std.mem.indexOf(u8, text.written(), " · Archived") != null);
        try std.testing.expectEqualStrings("", self.state.text);
        try std.testing.expect(self.status.bar.notice == null);
    }
}

test "SessionChrome transient reply categories appear once in Footer and never in status" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    var bytes: [16]u8 = undefined;
    var editor: @import("DraftEditor.zig") = .init(&bytes);
    var input: @import("InputArea.zig") = .{ .composer = .{ .editor = &editor } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var screen: AppScreen.Session = undefined;
    screen.input = input.widget();
    for ([_][]const u8{ "Copied 3 lines", "Configured.", "! Unknown command /nope", "! Copy unavailable", "Opening tool output…", "No earlier message.", "Restored chat" }) |notice| for ([_]u16{ 46, 99 }) |width| {
        self.place(&screen, &input, .{ .width = width, .facts = .{}, .notice = notice });
        const drawn = try input.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 30 }, .cell_size = .{} });
        try std.testing.expectEqual(@as(u16, 4), drawn.size.height);
        try std.testing.expectEqual(@as(usize, 2), drawn.children.len);
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (drawn.children[1].surface.buffer) |cell| if (cell.char.width != 0) try text.writer.writeAll(cell.char.grapheme);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text.written(), notice));
        try std.testing.expectEqualStrings("", self.state.text);
    };
}

test "SessionChrome identity omits permission and archive command hints" {
    var bytes: [chrome.facts_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("model · high", (@as(Identity, .{ .current = .{ .model = "model", .effort = .high, .left = 62 } })).fit(&bytes, 140, .unicode));
    try std.testing.expectEqualStrings("Archived", (@as(Identity, .{ .archive = .archived })).fit(&bytes, 46, .unicode));
    try std.testing.expectEqualStrings("! Not confirmed", stateText("! Not confirmed · ctrl+r retries original", "ctrl+r retries original"));
    try std.testing.expectEqualStrings("Copied 12 lines", stateText("Copied 12 lines", ""));
}

test "SessionChrome footer keeps the input gutter beside the visible list" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    self.list_visible = true;
    self.facts.identity = .{ .current = .{ .model = "gpt-6.1-sol", .effort = .high, .left = 100 } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const footer = try drawFooter(&self, .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 99, .height = 1 }, .cell_size = .{} });
    try std.testing.expectEqualStrings(" ", footer.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("g", footer.readCell(1, 0).char.grapheme);
    for (footer.buffer) |cell| try std.testing.expect(!std.mem.eql(u8, cell.char.grapheme, "‹"));
}

test "SessionChrome footer identity covers list visibility context threshold and both widths" {
    for ([_]bool{ false, true }) |list_visible| for ([_]u8{ 49, 50, 51 }) |left| for ([_]u16{ 46, 140 }) |width| {
        var recorder: Recorder = .{};
        var self: Self = .init(recorder.actions());
        self.list_visible = list_visible;
        self.facts.identity = .{ .current = .{ .model = "model", .effort = .high, .left = left } };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const footer = try drawFooter(&self, .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} });
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (footer.buffer) |cell| if (cell.char.width != 0) try text.writer.writeAll(cell.char.grapheme);
        const context = if (left <= 50) try std.fmt.allocPrint(arena.allocator(), " · {d}% context left", .{left}) else "";
        const want = try std.fmt.allocPrint(arena.allocator(), "{s}model · high{s}", .{ if (list_visible) " " else " ‹ ", context });
        try std.testing.expectEqualStrings(want, std.mem.trimEnd(u8, text.written(), " "));
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "alt+i") == null);
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        defer ctx.cmds.deinit(arena.allocator());
        const info_before = recorder.clicked.get(.status_page);
        try clickAt(footer, arena.allocator(), &ctx, 0, @intCast(width - 1));
        try std.testing.expectEqual(info_before + 1, recorder.clicked.get(.status_page));
        for (footer.children) |child| {
            const action: Recorder.Action = if (child.surface.widget.eql(self.facts.model.widget())) .model else if (child.surface.widget.eql(self.facts.effort.widget())) .effort else if (child.surface.widget.eql(self.facts.back.widget())) .back else .status_page;
            for (0..child.surface.size.width) |offset| {
                const before = recorder.clicked.get(action);
                try clickAt(footer, arena.allocator(), &ctx, 0, @intCast(child.origin.col + @as(i17, @intCast(offset))));
                try std.testing.expectEqual(before + 1, recorder.clicked.get(action));
            }
        }
    };
}

test "SessionChrome footer with no facts still draws one clickable row at both list states and widths" {
    for ([_]bool{ false, true }) |list_visible| for ([_]u16{ 46, 140 }) |width| {
        var recorder: Recorder = .{};
        var self: Self = .init(recorder.actions());
        self.list_visible = list_visible;
        self.facts.identity = .{};
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const footer = try drawFooter(&self, .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} });
        try std.testing.expectEqual(@as(u16, 1), footer.size.height);
        try std.testing.expectEqual(width, footer.size.width);
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (footer.buffer) |cell| if (cell.char.width != 0) try text.writer.writeAll(cell.char.grapheme);
        try std.testing.expectEqualStrings(if (list_visible) "" else "‹", std.mem.trim(u8, text.written(), " "));
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        defer ctx.cmds.deinit(arena.allocator());
        const info_before = recorder.clicked.get(.status_page);
        try clickAt(footer, arena.allocator(), &ctx, 0, @intCast(width - 1));
        try std.testing.expectEqual(info_before + 1, recorder.clicked.get(.status_page));
    };
}

test "Session chrome back control exists only while the shell hides the list" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    var bytes: [1]u8 = undefined;
    var editor: @import("DraftEditor.zig") = .init(&bytes);
    var input: @import("InputArea.zig") = .{ .composer = .{ .editor = &editor } };
    var screen: AppScreen.Session = .{ .content = undefined, .input = input.widget(), .userdata = &recorder, .on_event = Recorder.event };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 1 }, .cell_size = .{} };
    for ([_]bool{ true, false, true, false }) |list_visible| {
        self.place(&screen, &input, .{ .width = 80, .list_visible = list_visible, .facts = .{ .current = .{ .model = "gpt-5.5", .effort = .low, .left = 100 } } });
        const row = try input.facts.draw(draw);
        if (list_visible) {
            try std.testing.expectEqualStrings("g", row.readCell(1, 0).char.grapheme);
            try std.testing.expectEqual(@as(usize, 2), row.children.len);
        } else {
            try std.testing.expectEqualStrings("g", row.readCell(3, 0).char.grapheme);
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

test "SessionChrome model and effort words are independent controls beside the info background" {
    for ([_]u16{ 46, 140 }) |width| for ([_]bool{ false, true }) |list_visible| for ([_]@import("protocol.zig").SessionArchiveState{ .active, .archiving, .archived }) |archive| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var recorder: Recorder = .{};
        var self: Self = .init(recorder.actions());
        self.list_visible = list_visible;
        self.facts.identity = .{ .current = .{ .model = "gpt-6-luna", .effort = .low, .left = 62 }, .archive = archive };
        const footer = try drawFooter(&self, .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} });
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        defer ctx.cmds.deinit(arena.allocator());
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (footer.buffer) |cell| if (cell.char.width != 0) try text.writer.writeAll(cell.char.grapheme);
        const badge: ?[]const u8 = switch (archive) {
            .active => null,
            .archiving => " · Stopping and archiving",
            .archived => " · Archived",
        };
        if (badge) |label| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text.written(), label));
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "/unarchive") == null);
        var cells: usize = 0;
        for (footer.children) |child| if (child.surface.widget.eql(self.facts.model.widget()) or child.surface.widget.eql(self.facts.effort.widget())) {
            for (0..child.surface.size.width) |offset| {
                const col: i16 = @intCast(child.origin.col + @as(i17, @intCast(offset)));
                const action: Recorder.Action = if (child.surface.widget.eql(self.facts.model.widget())) .model else .effort;
                try std.testing.expectEqualStrings(footer.readCell(@intCast(col), 0).char.grapheme, child.surface.readCell(offset, 0).char.grapheme);
                const before = recorder.clicked.get(action);
                for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try @import("testing/app_events.zig").mouse(&ctx, footer, .{ .row = 0, .col = col, .button = .left, .mods = .{}, .type = kind });
                try std.testing.expectEqual(before + 1, recorder.clicked.get(action));
                cells += 1;
            }
        };
        try std.testing.expectEqual(@as(usize, self.facts.model.width()) + self.facts.effort.width(), cells);
        try std.testing.expectEqual(@as(usize, 0), recorder.clicked.get(.back));
        if (!list_visible) {
            for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try @import("testing/app_events.zig").mouse(&ctx, footer, .{ .row = 0, .col = 1, .button = .left, .mods = .{}, .type = kind });
            try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.back));
        }
    };
}

test "SessionChrome info background preserves control order without info focus stops" {
    for ([_]u16{ 46, 140 }) |width| for ([_]bool{ false, true }) |list_visible| for ([_]bool{ false, true }) |has_effort| for ([_]u8{ 49, 51 }) |left| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var recorder: Recorder = .{};
        var self: Self = .init(recorder.actions());
        self.list_visible = list_visible;
        self.facts.identity = .{ .current = .{ .model = "model", .effort = if (has_effort) .low else null, .left = left } };
        const footer = try drawFooter(&self, .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} });
        const controls = [_]vxfw.Widget{ self.facts.back.widget(), self.facts.model.widget(), self.facts.effort.widget() };
        const start: usize = @intFromBool(list_visible);
        const end: usize = if (has_effort) 3 else 2;
        try std.testing.expectEqual(end - start, footer.children.len);
        for (footer.children, controls[start..end]) |child, control| {
            try std.testing.expect(child.surface.widget.eql(control));
            try std.testing.expect(!child.surface.widget.eql(self.info.widget()));
        }
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        defer ctx.cmds.deinit(arena.allocator());
        for (0..width) |column| {
            var action: Recorder.Action = .status_page;
            const col: i32 = @intCast(column);
            for (footer.children) |child| {
                if (col < child.origin.col or col >= child.origin.col + child.surface.size.width) continue;
                action = if (child.surface.widget.eql(self.facts.model.widget())) .model else if (child.surface.widget.eql(self.facts.effort.widget())) .effort else .back;
            }
            const before = recorder.clicked.get(action);
            try clickAt(footer, arena.allocator(), &ctx, 0, @intCast(column));
            try std.testing.expectEqual(before + 1, recorder.clicked.get(action));
        }
    };
}

test "SessionChrome identity chips preserve cells and clicks for every terminal width method" {
    defer vxfw.DrawContext.init(.unicode);
    const models = [_][]const u8{ "👩‍🚀X", "❤️X", "Retry 👩‍🚀 with ❤️" };
    for ([_]vaxis.gwidth.Method{ .wcwidth, .unicode, .no_zwj }) |method| for (models) |model| for ([_]bool{ false, true }) |list_visible| for (0..66) |size| {
        const width: u16 = if (size == 65) 140 else @intCast(size);
        vxfw.DrawContext.init(method);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var recorder: Recorder = .{};
        var self: Self = .init(recorder.actions());
        self.list_visible = list_visible;
        self.facts.method = method;
        self.facts.identity = .{ .current = .{ .model = model, .effort = .low, .left = 62 } };
        const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} };
        const footer = try drawFooter(&self, draw);
        var terminal: vaxis.Screen = .{ .width = width, .height = 1, .width_method = method, .buf = try arena.allocator().alloc(vaxis.Cell, width) };
        @memset(terminal.buf, .{});
        try footer.render(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 1, .screen = &terminal }, self.facts.model.widget());
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
            if (!child.surface.widget.eql(self.facts.model.widget()) and !child.surface.widget.eql(self.facts.effort.widget())) continue;
            for (0..child.surface.size.width) |offset| {
                const col: i16 = @intCast(child.origin.col + @as(i17, @intCast(offset)));
                const action: Recorder.Action = if (child.surface.widget.eql(self.facts.model.widget())) .model else .effort;
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
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 100, .height = 1 }, .cell_size = .{} };
    const footer = try drawFooter(&self, draw_ctx);
    try std.testing.expectEqual(@as(usize, 3), footer.children.len);
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]*Chip{ &self.facts.back, &self.status.key, &self.status.stop, &self.marker }) |chip| {
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
    self.facts.identity = .{ .current = .{ .model = "model", .effort = .low, .left = 62 } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const footer = try drawFooter(&self, .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 1 }, .cell_size = .{} });
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try clickAt(footer, arena.allocator(), &ctx, 0, 6);
    try std.testing.expectEqual(@as(usize, 0), recorder.clicked.get(.model));
    try std.testing.expectEqual(@as(usize, 0), recorder.clicked.get(.effort));
    try clickAt(footer, arena.allocator(), &ctx, 0, 1);
    try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.model));
    self.facts.identity.current.?.effort = null;
    for (footer.children) |child| if (child.surface.widget.eql(self.facts.effort.widget())) {
        try clickAt(footer, arena.allocator(), &ctx, 0, @intCast(child.origin.col));
    };
    try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.effort));
    try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.status_page));
}

test "SessionChrome footer text and button styling cover both widths and applied efforts" {
    for ([_]u16{ 140, 46 }) |width| for ([_]chrome.FooterFocus{ .input, .model, .effort }) |focus| for ([_]bool{ false, true }) |explicit| {
        var recorder: Recorder = .{};
        var self: Self = .init(recorder.actions());
        self.facts.focus = focus;
        self.facts.identity = .{ .current = .{ .model = "m", .effort = if (explicit) .low else .high, .left = 62 } };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} };
        const footer = try drawFooter(&self, draw);
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (footer.buffer) |cell| try text.writer.writeAll(cell.char.grapheme);
        const left = try std.fmt.allocPrint(arena.allocator(), " ‹ m · {s}", .{if (explicit) "low" else "high"});
        try std.testing.expectEqualStrings(left, std.mem.trimEnd(u8, text.written(), " "));
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "alt+i") == null);
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
    self.facts.identity = .{ .archive = .archived };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const footer = try drawFooter(&self, .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 1 }, .cell_size = .{} });
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

test "SessionChrome empty chat footer preserves model effort folder at both widths" {
    for ([_]u16{ 46, 140 }) |width| for ([_]bool{ false, true }) |visible| {
        var recorder: Recorder = .{};
        var self: Self = .init(recorder.actions());
        self.list_visible = visible;
        self.keys = chrome.footerKeys(.closed);
        self.details.label = "alt+d details";
        self.facts.identity = .{ .current = .{ .model = "gpt-6.1-sol", .effort = .low, .folder = "/home/u/code/rui", .home = "/home/u" } };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const footer = try drawFooter(&self, .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} });
        var text: std.ArrayList(u8) = .empty;
        for (0..width) |col| try text.appendSlice(arena.allocator(), footer.readCell(col, 0).char.grapheme);
        try std.testing.expect(std.mem.indexOf(u8, text.items, "gpt-6.1-sol · low · ~/code/rui") != null);
        try std.testing.expect(std.mem.indexOf(u8, text.items, "reference") == null);
    };
}
