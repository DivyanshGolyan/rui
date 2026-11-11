//! The Session screen's chrome, placed: it owns the rows and chips that
//! present what `session_chrome` decided, and puts them in the Session
//! screen's slots each frame from the values the screen passes. It holds no
//! decision and no state but its widgets: the screen keeps the notice
//! (`session_chrome.Notice`), whether the `?` shortcuts are open
//! (`session_chrome.shortcut`) and the title (`session_chrome.Title`). Every
//! click runs one of the screen's own actions, the same one its key runs.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const chrome = @import("session_chrome.zig");
const AppScreen = @import("AppScreen.zig");
const ActivityBlock = @import("ActivityBlock.zig");
const StatusRow = @import("StatusRow.zig");
const FactsRow = @import("FactsRow.zig");
const Shortcuts = @import("Shortcuts.zig");
const Chip = @import("Chip.zig");
const Self = @This();

/// The screen's actions a click runs.
pub const Actions = struct {
    userdata: *anyopaque,
    /// `ctrl+r retries`, or whatever key the needs text ends with.
    key: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
    /// `ctrl+x stop`.
    stop: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
    /// `‹`: back to the overview, as Esc.
    back: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
    /// `↓`: the latest view, as Esc.
    latest: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
    /// `+N more running · /status`.
    status_page: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
};

/// What the screen read for this frame.
pub const View = struct {
    /// Scrolled back from the latest: no activity tail, the marker shows.
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
    /// The facts after `‹ `.
    facts: []const u8 = "",
    /// The reply to the last key that shows now (`Notice.current`), and
    /// what the overview says (`chrome.Facts.overview`), each borrowed
    /// until the next frame.
    notice: ?[]const u8 = null,
    overview: ?[]const u8 = null,
    /// The `?` shortcuts are open.
    shortcuts: bool = false,
    /// The overlay the screen would show (the palette), or null. The `?`
    /// shortcuts take its place while open.
    overlay: ?vxfw.Widget = null,
    width: u16,
};

status: StatusRow,
facts: FactsRow,
activity: ActivityBlock,
marker: Chip,
marker_text: [chrome.marker_bytes]u8 = undefined,
shortcuts: Shortcuts = .{},

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
    };
}

/// Puts this frame's chrome in the Session screen's slots.
pub fn place(self: *Self, screen: *AppScreen.Session, view: View) void {
    self.status.bar = chrome.bar(.{
        .needs = view.needs,
        .progress = view.progress,
        .notice = view.notice,
        .overview = view.overview,
        .stoppable = view.stoppable,
        .width = view.width,
        .method = self.status.method,
    });
    self.status.key.label = if (view.needs != null) view.needs_key else "";
    self.facts.text = view.facts;
    screen.input.facts = self.facts.widget();
    screen.input.status = self.status.widget();
    screen.tail = if (view.browsing) null else self.activity.widget();
    self.marker.label = chrome.marker(&self.marker_text, view.new_entries);
    screen.marker = if (view.browsing) self.marker.widget() else null;
    screen.overlay = if (view.shortcuts) self.shortcuts.widget() else view.overlay;
}

const Recorder = struct {
    clicked: std.enums.EnumArray(enum { key, stop, back, latest, status_page }, usize) = .initFill(0),
    fn on(comptime which: anytype) *const fn (*anyopaque, *vxfw.EventContext) anyerror!void {
        return struct {
            fn click(raw: *anyopaque, _: *vxfw.EventContext) !void {
                const self: *Recorder = @ptrCast(@alignCast(raw));
                self.clicked.set(which, self.clicked.get(which) + 1);
            }
        }.click;
    }
    fn actions(self: *Recorder) Actions {
        return .{ .userdata = self, .key = on(.key), .stop = on(.stop), .back = on(.back), .latest = on(.latest), .status_page = on(.status_page) };
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
    var transcript: @import("Transcript.zig") = .{ .document = document };
    var screen: AppScreen.Session = .{ .content = &transcript, .input = &input, .userdata = &recorder, .on_event = Recorder.event };
    self.activity.work = .{ .mark = "⠹", .tone = .normal, .words = "Waiting", .clock = .{ .elapsed = 12 } };
    self.activity.live.count = 0;
    self.activity.live.total = 5;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
    const view: View = .{ .needs = "! Not confirmed · ctrl+r retries", .needs_key = "ctrl+r retries", .stoppable = true, .facts = "Fix flaky store test · gpt-6.1-sol · high · 62% left", .width = 80 };

    self.place(&screen, view);
    try std.testing.expect(screen.tail != null and screen.marker == null);
    const live = try screen.widget().draw(draw);
    // Tail: `+5 more running · /status` then the work line, right above the input at 19.
    try std.testing.expectEqual(@as(i17, 17), live.children[0].origin.row);
    try clickAt(live, arena.allocator(), &ctx, 17, 4);
    try clickAt(live, arena.allocator(), &ctx, 22, 1);
    try clickAt(live, arena.allocator(), &ctx, 23, 20);
    try clickAt(live, arena.allocator(), &ctx, 23, 70);
    try std.testing.expectEqual(@as(usize, 1), recorder.clicked.get(.status_page));
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

test "the status row shows the notice under what needs the person, and the ? shortcuts take the palette's place" {
    var recorder: Recorder = .{};
    var self: Self = .init(recorder.actions());
    var bytes: [16]u8 = undefined;
    const editor: @import("TerminalEditor.zig") = .{ .buffer = &bytes };
    var input: @import("InputArea.zig") = .{ .composer = .{ .editor = &editor } };
    const document = try std.testing.allocator.create(@import("ConversationViewport.zig").Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    var transcript: @import("Transcript.zig") = .{ .document = document };
    var screen: AppScreen.Session = .{ .content = &transcript, .input = &input, .userdata = &recorder, .on_event = Recorder.event };
    const palette: vxfw.Text = .{ .text = "/model" };

    self.place(&screen, .{ .width = 80, .notice = "Copied 12 lines", .overlay = palette.widget() });
    try std.testing.expectEqualStrings("Copied 12 lines", self.status.bar.left);
    try std.testing.expect(screen.overlay.?.eql(palette.widget()));
    self.place(&screen, .{ .width = 80, .shortcuts = true, .overlay = palette.widget() });
    try std.testing.expectEqualStrings("", self.status.bar.left);
    try std.testing.expect(screen.overlay.?.eql(self.shortcuts.widget()));
    self.place(&screen, .{ .width = 80 });
    try std.testing.expect(screen.overlay == null);
    self.place(&screen, .{ .width = 80, .notice = "Copied 12 lines", .needs = "! Not confirmed · ctrl+r retries", .needs_key = "ctrl+r retries" });
    try std.testing.expectEqualStrings("! Not confirmed · ctrl+r retries", self.status.bar.left);
    try std.testing.expectEqualStrings("ctrl+r retries", self.status.key.label);
}
