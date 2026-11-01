//! Alternate-screen row budget. vaxis measures and wraps text; this module
//! decides which rows each region gets and which Action rows a frame delivers.
//! It owns no terminal custody, cells, files or clocks.
const std = @import("std");
const Viewport = @import("ConversationViewport.zig");
const Position = Viewport.Position;
const draft_layout = @import("draft_layout.zig");
const Self = @This();
pub const Call = Viewport.Sized(512, false);
/// Bytes of status text a frame holds; the frontend fits its status to this.
pub const status_capacity = 2048;
// Includes the historical 24 × 2048 resize witness; the shell accounts dense
// Unicode cells, retained graphemes and frame bytes together under 32 MiB.
pub const max_cells = 24 * 2048;

pub fn validateGeometry(width: u16, height: u16) !void {
    if (height < 2 or width < 8) return error.TerminalTooSmall;
    if (@as(u32, width) * height > max_cells) return error.TerminalTooLarge;
}

/// The input row of a waiting Action: Allow once, then Deny. Each option is
/// a two-cell marker, its label and a space; the labels shorten to fit.
pub const Choice = struct { labels: [2][]const u8, columns: [2]u16 };

pub fn choice(width: u16) Choice {
    const forms = [_]struct { labels: [2][]const u8, start: u16, gap: u16 }{
        .{ .labels = .{ "Allow once", "Deny" }, .start = 2, .gap = 3 },
        .{ .labels = .{ "Allow", "Deny" }, .start = 2, .gap = 3 },
        .{ .labels = .{ "A", "D" }, .start = 0, .gap = 0 },
    };
    for (forms) |form| {
        const second: u16 = @intCast(form.start + form.labels[0].len + 3 + form.gap);
        if (second + form.labels[1].len + 3 <= width) return .{ .labels = form.labels, .columns = .{ form.start, second } };
    }
    // validateGeometry keeps every frame at least as wide as the last form.
    unreachable;
}

status: Viewport.Sized(status_capacity, false),
/// A notice, shown in the rows under the input until the next key.
notice: Viewport.Sized(status_capacity, false),
calls: [3]Call,
call_heights: [3]u16,
heading: Viewport.Sized(128, false),
used: usize,
height: u16,
/// Document rows a transcript would have with this frame's status and draft:
/// no calls, and a heading row when one fits.
browsing_height: u16,
first: Position,
document_rows: usize,
/// Rows above a whole Action, so that it ends right above the input. The
/// conversation's latest rows fill them; they are never Action rows.
document_offset: u16,
navigation_height: u16,
overflow_height: u16,
status_height: u16,
/// The status stands directly above the rule: it is about the input.
status_row: u16,
/// The calls, their overflow row and the live line follow the document as
/// the conversation's last lines, from this row.
calls_row: u16,
/// The live line's row, under the calls, when `live_height` is one.
live_row: u16,
live_height: u16,
/// The rule above the input and its list; its row is `list_row - 1` when
/// this is one.
rule_height: u16,
/// The rows under the input, from `height - line_height`: the notice's rows
/// when there is one, else one row for the Session line, or how to decide a
/// waiting Action, once three rows remain under the status.
line_height: u16,
/// The command list's rows, right above the draft: rows the draft could
/// still grow into, never the input's own.
list_height: u16,
list_row: u16,
/// The draft lines shown, `draft.rows` of `draft_lines` from the top, and
/// the lines the rule says are hidden.
draft: draft_layout.View,
draft_top: u16,
draft_lines: [draft_layout.max_rows]draft_layout.Line = @splat(.{ .start = 0, .end = 0, .cells = 0 }),
caret_row: u16,
caret_column: u16,
action_seen: Position,
approval_ready: bool,

pub const Input = struct {
    width: u16,
    height: u16,
    method: Viewport.Method = .wcwidth,
    draft: []const u8 = "",
    cursor: usize,
    /// The byte that started the previous frame's first draft line.
    draft_anchor: usize = 0,
    status: []const u8,
    notice: []const u8 = "",
    /// The command list's lines, each one row.
    commands: usize = 0,
    calls: []const []const u8,
    total_calls: u64,
    /// Work is under way: a line saying what it is doing now follows the
    /// shown text, unless the running call's own row shows its clock.
    live: bool = false,
    /// The index in `calls` of the running call whose row carries the
    /// work's clock.
    clock_call: ?usize = null,
    selected: bool,
    action_visible: bool,
    action_pending: bool = false,
    /// The first Action row not yet delivered in a frame.
    action_seen: Position = .{},
    preview_complete: bool,
};

fn rows(text: anytype, layout: Viewport.Layout) !u16 {
    try text.prepare();
    return @intCast(text.measure(layout, .{}, std.math.maxInt(u16)).rows);
}

/// Sets the heading to the overflow row counting `omitted` calls and
/// returns its rows.
fn overflow(self: *Self, layout: Viewport.Layout, omitted: u64, compact: bool) !u16 {
    self.heading.clear();
    var storage: [128]u8 = undefined;
    try self.heading.append(try std.fmt.bufPrint(&storage, "+{d}{s} · /status", .{ omitted, if (compact) "" else " more calls" }));
    return rows(&self.heading, layout);
}

/// Plans rows for vaxis to fill. Decisions borrow only the supplied document
/// and draft; the shell consumes the plan before pumping input or changing them.
pub fn plan(self: *Self, document: *Viewport.Document, input: Input) !void {
    try validateGeometry(input.width, input.height);
    const layout: Viewport.Layout = .{ .width = input.width, .method = input.method };
    self.* = .{
        .status = .{ .width_method = input.method },
        .notice = .{ .width_method = input.method },
        .calls = .{ .{ .width_method = input.method }, .{ .width_method = input.method }, .{ .width_method = input.method } },
        .call_heights = .{ 0, 0, 0 },
        .heading = .{ .width_method = input.method },
        .used = if (input.selected) 0 else input.calls.len,
        .height = 0,
        .browsing_height = 0,
        .first = .{},
        .document_rows = 0,
        .document_offset = 0,
        .navigation_height = 0,
        .overflow_height = 0,
        .status_height = 0,
        .status_row = 0,
        .calls_row = 0,
        .live_row = 0,
        .live_height = 0,
        .rule_height = 0,
        .line_height = 0,
        .list_height = 0,
        .list_row = 0,
        .draft = .{ .first = 0, .rows = 0, .hidden_above = 0, .hidden_below = 0 },
        .draft_top = 0,
        .caret_row = 0,
        .caret_column = 0,
        .action_seen = input.action_seen,
        .approval_ready = false,
    };
    try self.status.append(input.status);
    self.status_height = try rows(&self.status, layout);
    try self.notice.append(input.notice);
    self.line_height = if (input.notice.len != 0) try rows(&self.notice, layout) else @intFromBool(input.height -| self.status_height >= 3);
    // The input keeps one row: the draft's first line, or a waiting Action's
    // choice.
    if (@as(u32, self.status_height) + self.line_height > input.height - 1) return error.TerminalTooSmall;
    const pieces: Viewport.DraftPieces = .{ .bytes = input.draft, .method = input.method };
    const shape = draft_layout.shape(pieces, input.width - 2, input.cursor, input.draft_anchor);
    // The rows the draft asks for, up to its cap.
    const needed: u16 = @intCast(@min(shape.lines, draft_layout.cap(input.height)));
    const footer = self.status_height + self.line_height;
    // A rule separates the input once the terminal has room for one.
    self.rule_height = @intFromBool(input.height - footer >= 4);
    // Fit required footer and navigation rows with one draft row first;
    // the draft can then grow up to its cap.
    var available: u16 = input.height - 1 - self.rule_height - footer;
    try document.prepare();
    for (input.calls, 0..) |line, index| {
        try self.calls[index].append(line);
        self.call_heights[index] = try rows(&self.calls[index], layout);
    }
    var call_rows: u16 = 0;
    var heading_height: u16 = 0;
    // Work under way keeps a row for its live line ahead of call rows, which
    // the overflow row counts, but never ahead of a required row: when even
    // the overflow row needs it, the live line goes. A page keeps a readable
    // row besides it.
    const live_fits = input.live and if (input.selected)
        document.text().len != 0 and available >= 2
    else
        available > if (input.total_calls != 0) try self.overflow(layout, input.total_calls, true) else 0;
    while (true) {
        // The line draws unless the running call's own row shows its clock.
        const said = if (input.clock_call) |index| index < self.used else false;
        self.live_height = @intFromBool(live_fits and !said);
        const budget = available - self.live_height;
        call_rows = 0;
        for (self.call_heights[0..self.used]) |height| call_rows += height;
        const omitted = if (input.selected) 0 else input.total_calls - self.used;
        var compact = input.width < 24;
        while (true) {
            self.heading.clear();
            if (omitted != 0) {
                heading_height = try self.overflow(layout, omitted, compact);
            } else heading_height = if (input.selected and (!input.action_visible or !input.preview_complete or document.measure(layout, .{}, budget -| (needed - 1)).next.order(.end) != .eq) and budget -| call_rows > 1) 1 else 0;
            if (@as(u32, call_rows) + heading_height <= budget) break;
            if (omitted != 0 and !compact) {
                compact = true;
                continue;
            }
            break;
        }
        if (@as(u32, call_rows) + heading_height <= budget) break;
        if (self.used == 0) return error.TerminalTooSmall;
        self.used -= 1;
    }
    if (self.heading.length == 0 and heading_height != 0) {
        try self.heading.append(if (input.action_visible) "Action preview · too large to approve here" else if (input.action_pending) "Browsing · Esc returns to Action" else "Browsing · Esc returns");
        if (try rows(&self.heading, layout) > heading_height) {
            self.heading.clear();
            try self.heading.append(if (input.action_visible) (if (input.preview_complete or input.width < "Action preview".len) "Action" else "Action preview") else if (input.width < "Esc · Action".len) "Esc" else if (input.action_pending) "Esc · Action" else "Esc returns");
        }
    }
    const budget = available - self.live_height;
    // A selected page needs a readable row so browsing can still advance.
    const document_reserve: u16 = @intFromBool(input.selected and document.text().len != 0 and budget > heading_height + call_rows);
    const room = input.height - self.rule_height - footer - heading_height - call_rows - self.live_height - document_reserve;
    const input_rows = @min(draft_layout.cap(input.height), room);
    self.draft = draft_layout.fit(pieces, input.width - 2, input.cursor, shape, input_rows, &self.draft_lines);
    self.list_height = @intCast(@min(input.commands, input_rows - self.draft.rows));
    const unreserved = input.height - self.draft.rows - self.list_height - self.rule_height - footer;
    // A transcript of this text shows the live line under its heading and a
    // readable row.
    const navigation: u16 = @intFromBool(unreserved > 1);
    self.browsing_height = unreserved - navigation - @intFromBool(input.live and document.text().len != 0 and unreserved > navigation + 1);
    available = unreserved - self.live_height;
    self.height = available - heading_height - call_rows;
    self.first = document.first(layout, self.height);
    const shown = document.measure(layout, self.first, self.height);
    self.document_rows = shown.rows;
    if (input.action_visible and input.preview_complete) {
        // A whole Action sits right above the input; a taller one pages from
        // its top.
        if (self.first.order(.{}) == .eq and shown.next.order(.end) == .eq) self.document_offset = self.height - @as(u16, @intCast(shown.rows));
        // Only rows delivered contiguously from the top count as read.
        if (self.first.order(input.action_seen) != .gt and shown.next.order(input.action_seen) == .gt) self.action_seen = shown.next;
        self.approval_ready = self.action_seen.order(.end) == .eq;
        if (heading_height != 0) {
            self.heading.clear();
            try self.heading.append(if (self.approval_ready) (if (input.width >= 11) "Action read" else "Read") else if (input.width >= 24) "Action continues · PgDn" else "PgDn");
        }
    }
    try self.heading.prepare();
    try self.notice.prepare();
    self.overflow_height = if (!input.selected and input.total_calls > self.used) heading_height else 0;
    self.navigation_height = heading_height - self.overflow_height;
    // The input keeps the bottom rows above the line under it, with the
    // status and the rule above it. The shown text starts at the top and the
    // calls and live line follow it, so short text leaves the gap under its
    // last line; only a whole Action is pushed down to the input.
    self.draft_top = input.height - self.line_height - self.draft.rows;
    self.list_row = self.draft_top - self.list_height;
    self.status_row = self.list_row - self.rule_height - self.status_height;
    self.calls_row = self.navigation_height + self.document_offset + @as(u16, @intCast(self.document_rows));
    self.live_row = self.calls_row + call_rows + self.overflow_height;
    self.caret_row = self.draft_top + @as(u16, @intCast(shape.caret_line - self.draft.first));
    self.caret_column = @min(shape.caret_column + 2, input.width - 1);
}

test "geometry is bounded before the shell allocates cells" {
    try validateGeometry(2048, 24);
    try validateGeometry(256, 192);
    try std.testing.expectError(error.TerminalTooLarge, validateGeometry(2049, 24));
    try std.testing.expectError(error.TerminalTooLarge, validateGeometry(480, 135));
}

test "the draft keeps the bottom rows under a rule and over the Session line, and the transcript fills the rows above" {
    var document: Viewport.Document = .{};
    try document.append("› inspect\n  Done.\n");
    var frame: Self = undefined;
    var input: Input = .{ .width = 80, .height = 24, .draft = "next\nline", .cursor = 9, .status = "", .calls = &.{}, .total_calls = 0, .selected = false, .action_visible = false, .preview_complete = true };
    try frame.plan(&document, input);
    try std.testing.expectEqual(@as(u16, 1), frame.rule_height);
    try std.testing.expectEqual(@as(u16, 1), frame.line_height);
    try std.testing.expectEqual(@as(u16, 21), frame.draft_top);
    try std.testing.expectEqual(@as(u16, 22), frame.caret_row);
    try std.testing.expectEqual(@as(u16, 6), frame.caret_column);
    // Twenty-one rows sit above the rule, a one-row draft and the line.
    document.clear();
    for (0..24) |_| try document.append("row\n");
    input.draft = "";
    input.cursor = 0;
    try frame.plan(&document, input);
    try std.testing.expectEqual(Position{ .offset = 12 }, frame.first);
    try std.testing.expectEqual(@as(u16, 21), frame.height);
    try std.testing.expectEqual(@as(u16, 22), frame.draft_top);
    input.notice = "! Unknown command /x · /help";
    try frame.plan(&document, input);
    try std.testing.expectEqual(@as(u16, 1), frame.line_height);
    try std.testing.expectEqual(@as(u16, 22), frame.draft_top);
    input.width = 20;
    try frame.plan(&document, input);
    try std.testing.expectEqual(@as(u16, 2), frame.line_height);
    try std.testing.expectEqual(@as(u16, 21), frame.draft_top);
    try std.testing.expectEqual(@as(u16, 20), frame.height);
}

test "the command list takes rows the draft could grow into, under the rule, and never the input's row" {
    var document: Viewport.Document = .{};
    for (0..40) |_| try document.append("row\n");
    var frame: Self = undefined;
    var input: Input = .{ .width = 80, .height = 24, .draft = "/c", .cursor = 2, .status = "", .commands = 2, .calls = &.{}, .total_calls = 0, .selected = false, .action_visible = false, .preview_complete = true };
    try frame.plan(&document, input);
    try std.testing.expectEqual(@as(u16, 2), frame.list_height);
    try std.testing.expectEqual(@as(u16, 22), frame.draft_top);
    try std.testing.expectEqual(@as(u16, 20), frame.list_row);
    try std.testing.expectEqual(@as(u16, 19), frame.status_row);
    try std.testing.expectEqual(@as(u16, 19), frame.height);
    // A third of 24 rows is eight; the draft keeps one of them.
    input.commands = 15;
    try frame.plan(&document, input);
    try std.testing.expectEqual(@as(u16, 7), frame.list_height);
    try std.testing.expectEqual(@as(u16, 22), frame.draft_top);
    try std.testing.expectEqual(@as(u16, 15), frame.list_row);
    input.height = 6;
    try frame.plan(&document, input);
    try std.testing.expectEqual(@as(u16, 1), frame.list_height);
    try std.testing.expectEqual(@as(u16, 4), frame.draft_top);
    try std.testing.expectEqual(@as(u16, 3), frame.list_row);
    try std.testing.expectEqual(@as(u16, 2), frame.height);
    input.height = 4;
    try frame.plan(&document, input);
    try std.testing.expectEqual(@as(u16, 0), frame.list_height);
    try std.testing.expectEqual(@as(u16, 2), frame.draft_top);
}

test "the status stays above the rule while calls and the live line follow the conversation's last line" {
    var document: Viewport.Document = .{};
    var frame: Self = undefined;
    var input: Input = .{ .width = 80, .height = 24, .draft = "next\nline", .cursor = 9, .status = "Sending…", .calls = &.{"• Inspect layout"}, .total_calls = 1, .live = true, .selected = false, .action_visible = false, .preview_complete = true };
    for ([_][]const u8{ "", "Done.", "Done.\n\nMore." }, [_]usize{ 0, 1, 3 }) |text, document_rows| {
        document.clear();
        try document.append(text);
        try frame.plan(&document, input);
        try std.testing.expectEqual(document_rows, frame.document_rows);
        try std.testing.expectEqual(@as(u16, 21), frame.draft_top);
        try std.testing.expectEqual(@as(u16, 19), frame.status_row);
        try std.testing.expectEqual(@as(u16, @intCast(document_rows)), frame.calls_row);
        try std.testing.expectEqual(@as(u16, @intCast(document_rows + 1)), frame.live_row);
        try std.testing.expectEqual(@as(u16, 1), frame.live_height);
    }
    // A long conversation fills the rows above them, leaving no gap.
    document.clear();
    for (0..40) |_| try document.append("row\n");
    try frame.plan(&document, input);
    try std.testing.expectEqual(frame.status_row, frame.live_row + 1);
    // The running call's row carries the clock while it shows, so no live
    // line follows it.
    input.clock_call = 0;
    try frame.plan(&document, input);
    try std.testing.expectEqual(@as(u16, 0), frame.live_height);
    try std.testing.expectEqual(frame.status_row, frame.calls_row + 1);
    // A browsed page keeps the live line above the status, and a transcript
    // opened now would give it a row.
    const browsing = frame.browsing_height;
    input.selected = true;
    try frame.plan(&document, input);
    try std.testing.expectEqual(@as(u16, 1), frame.live_height);
    try std.testing.expectEqual(frame.status_row, frame.live_row + 1);
    try std.testing.expectEqual(browsing, frame.height);
    input.live = false;
    try frame.plan(&document, input);
    try std.testing.expectEqual(@as(u16, 0), frame.live_height);
    try std.testing.expectEqual(browsing + 1, frame.browsing_height);
}

test "the live line takes a row after every required row and before call rows" {
    var document: Viewport.Document = .{};
    var frame: Self = undefined;
    // Without a free row the line is dropped; the frame still renders.
    for ([_][]const u8{ "Idle", "Two lines\nof status" }, [_]u16{ 3, 4 }) |status, height| {
        for ([_]bool{ false, true }) |live| {
            try frame.plan(&document, .{ .width = 24, .height = height, .status = status, .cursor = 0, .calls = &.{}, .total_calls = 100, .live = live, .selected = false, .action_visible = false, .preview_complete = true });
            try std.testing.expectEqual(@as(u16, 1), frame.overflow_height);
            try std.testing.expectEqual(@as(u16, 0), frame.live_height);
        }
    }
    try frame.plan(&document, .{ .width = 24, .height = 4, .status = "Idle", .notice = "! a notice", .cursor = 0, .calls = &.{}, .total_calls = 0, .live = true, .selected = false, .action_visible = false, .preview_complete = true });
    try std.testing.expectEqual(@as(u16, 1), frame.live_height);
    // The live line keeps its row before a call does; the overflow row
    // counts the call.
    try frame.plan(&document, .{ .width = 24, .height = 5, .status = "", .cursor = 0, .calls = &.{ "• First", "• Second" }, .total_calls = 2, .live = true, .selected = false, .action_visible = false, .preview_complete = true });
    try std.testing.expectEqual(@as(usize, 0), frame.used);
    try std.testing.expectEqualStrings("+2 more calls · /status", frame.heading.text());
    try std.testing.expectEqual(@as(u16, 1), frame.live_height);
    // A running call whose row is not shown leaves its clock to the live
    // line.
    const calls = [_][]const u8{ "• First", "• Second call whose description wraps over three rows · 4s" };
    try frame.plan(&document, .{ .width = 24, .height = 6, .status = "", .cursor = 0, .calls = &calls, .total_calls = 2, .live = true, .clock_call = 1, .selected = false, .action_visible = false, .preview_complete = true });
    try std.testing.expectEqual(@as(usize, 1), frame.used);
    try std.testing.expectEqual(@as(u16, 1), frame.overflow_height);
    try std.testing.expectEqual(@as(u16, 1), frame.live_height);
    try std.testing.expectEqual(frame.live_row, frame.calls_row + 2);
}

test "the live row is kept only while the live line draws" {
    var document: Viewport.Document = .{};
    var frame: Self = undefined;
    const calls = [_][]const u8{ "• First", "• Second", "• Third" };
    // The input leaves 80×5 two rows for calls, 80×6 three and 80×7 four.
    // While the clock call's row shows, first or last, no live line takes a
    // row; while it does not, the live line takes one and the overflow row
    // counts the calls it displaces.
    const cases = [_]struct { height: u16, total: u64, clock_call: ?usize, used: usize, live: u16 }{
        .{ .height = 6, .total = 3, .clock_call = 0, .used = 3, .live = 0 },
        .{ .height = 6, .total = 3, .clock_call = 2, .used = 3, .live = 0 },
        .{ .height = 6, .total = 3, .clock_call = null, .used = 1, .live = 1 },
        .{ .height = 7, .total = 5, .clock_call = 0, .used = 3, .live = 0 },
        .{ .height = 7, .total = 5, .clock_call = 2, .used = 3, .live = 0 },
        .{ .height = 7, .total = 5, .clock_call = null, .used = 2, .live = 1 },
        .{ .height = 5, .total = 3, .clock_call = 0, .used = 1, .live = 0 },
        .{ .height = 5, .total = 3, .clock_call = 1, .used = 0, .live = 1 },
        .{ .height = 5, .total = 3, .clock_call = 2, .used = 0, .live = 1 },
    };
    for (cases) |case| {
        try frame.plan(&document, .{ .width = 80, .height = case.height, .status = "", .cursor = 0, .calls = &calls, .total_calls = case.total, .live = true, .clock_call = case.clock_call, .selected = false, .action_visible = false, .preview_complete = true });
        try std.testing.expectEqual(case.used, frame.used);
        try std.testing.expectEqual(case.live, frame.live_height);
        try std.testing.expectEqual(@as(u16, @intFromBool(case.total > case.used)), frame.overflow_height);
        // The calls, overflow and live rows fill the rows above the rule.
        try std.testing.expectEqual(frame.draft_top - 1, frame.live_row + frame.live_height);
    }
    // A page or transcript with no text draws no live line, so it keeps no
    // row for one.
    for ([_]bool{ false, true }) |selected| {
        const input: Input = .{ .width = 80, .height = 24, .status = "", .cursor = 0, .calls = &.{}, .total_calls = 0, .live = true, .selected = selected, .action_visible = false, .preview_complete = true };
        try frame.plan(&document, input);
        const height = frame.height;
        const browsing = frame.browsing_height;
        try std.testing.expectEqual(@as(u16, @intFromBool(!selected)), frame.live_height);
        var idle = input;
        idle.live = false;
        try frame.plan(&document, idle);
        try std.testing.expectEqual(browsing, frame.browsing_height);
        if (selected) try std.testing.expectEqual(frame.height, height);
    }
}

test "the Session line shows once three rows remain under the status, then the rule once four remain above the line" {
    var document: Viewport.Document = .{};
    var frame: Self = undefined;
    for ([_][]const u8{ "", "Sending…" }, [_]u16{ 0, 1 }) |status, status_rows| for ([_][]const u8{ "", "! notice" }) |notice| for (2..10) |h| for ([_]usize{ 0, 1, 15 }) |commands| {
        const height: u16 = @intCast(h);
        const notice_rows: u16 = @intFromBool(notice.len != 0);
        const input: Input = .{ .width = 20, .height = height, .draft = "/c", .cursor = 2, .status = status, .notice = notice, .commands = commands, .calls = &.{}, .total_calls = 0, .selected = false, .action_visible = false, .preview_complete = true };
        if (height < status_rows + notice_rows + 1) {
            try std.testing.expectError(error.TerminalTooSmall, frame.plan(&document, input));
            continue;
        }
        try frame.plan(&document, input);
        const line: u16 = if (notice_rows != 0) 1 else @intFromBool(height - status_rows >= 3);
        try std.testing.expectEqual(line, frame.line_height);
        try std.testing.expectEqual(@as(u16, @intFromBool(height - status_rows - line >= 4)), frame.rule_height);
        try std.testing.expectEqual(height - line - 1, frame.draft_top);
        try std.testing.expectEqual(height - line - 1, frame.caret_row);
        // The list never moves the input: it takes rows a third of the
        // screen would give a growing draft.
        const list: u16 = @intCast(@min(commands, @max(1, height / 3) - 1));
        try std.testing.expectEqual(list, frame.list_height);
        try std.testing.expectEqual(height - line - 1 - list - frame.rule_height - status_rows, frame.status_row);
    };
}

test "a full-capacity draft of spaces keeps the caret on screen" {
    var document: Viewport.Document = .{};
    var frame: Self = undefined;
    const spaces: [65536]u8 = @splat(' ');
    try frame.plan(&document, .{ .width = 80, .height = 24, .draft = &spaces, .cursor = spaces.len, .status = "", .calls = &.{}, .total_calls = 0, .selected = false, .action_visible = false, .preview_complete = true });
    try std.testing.expectEqual(@as(u16, 2), frame.draft.rows);
    try std.testing.expectEqual(@as(u16, 22), frame.caret_row);
    try std.testing.expectEqual(@as(u16, 2), frame.caret_column);
}

test "an exactly filled draft row puts the caret on the next row" {
    var document: Viewport.Document = .{};
    var frame: Self = undefined;
    // Eight columns leave six for the draft: "abcdef" fills its row.
    for ([_][]const u8{ "abcde", "abcdef" }, [_]u16{ 1, 2 }, [_]u16{ 7, 2 }) |draft, height, column| {
        try frame.plan(&document, .{ .width = 8, .height = 12, .draft = draft, .cursor = draft.len, .status = "", .calls = &.{}, .total_calls = 0, .selected = false, .action_visible = false, .preview_complete = true });
        try std.testing.expectEqual(height, frame.draft.rows);
        try std.testing.expectEqual(frame.draft_top + height - 1, frame.caret_row);
        try std.testing.expectEqual(column, frame.caret_column);
    }
}

test "a multiline draft grows to its cap and then scrolls inside the input" {
    var document: Viewport.Document = .{};
    try document.append("› hi\nHi! What would you like to work on?\n");
    const draft = "Please inspect this project.\n\nFirst read README.md.\nKeep all input bytes unchanged.\n\nThen compare the layout.\n\nDo not claim a missing recording was inspected.\n\nPeer A: summarise README.md and preserve literal backticks in the report so every character wraps to the next visual row.\n\nEnd of representative paste.";
    var frame: Self = undefined;
    // Twelve logical lines, with the Peer line wrapping once: thirteen rows,
    // more than the cap of six (twenty rows) or eight (twenty-four).
    for ([_]u16{ 20, 24 }, [_]u16{ 6, 8 }) |height, cap| {
        for ([_]usize{ 0, draft.len }, [_]usize{ 0, 13 - cap }) |cursor, first| {
            try frame.plan(&document, .{ .width = 100, .height = height, .draft = draft, .cursor = cursor, .status = "", .calls = &.{}, .total_calls = 0, .selected = false, .action_visible = false, .preview_complete = true });
            try std.testing.expectEqual(cap, frame.draft.rows);
            try std.testing.expectEqual(first, frame.draft.first);
            try std.testing.expectEqual(first, frame.draft.hidden_above);
            try std.testing.expectEqual(13 - cap - first, frame.draft.hidden_below);
            try std.testing.expectEqual(Position{}, frame.first);
            try std.testing.expectEqual(height - 1 - cap, frame.draft_top);
        }
    }
    // Under status, calls and an overflow row, a short terminal still gives
    // the draft what remains, up to its cap.
    var tall: [200]u8 = undefined;
    for (0..40) |index| @memcpy(tall[index * 5 ..][0..5], "line\n");
    for ([_]u16{ 8, 24 }, [_]u16{ 1, 8 }) |height, draft_rows| {
        try frame.plan(&document, .{ .width = 100, .height = height, .draft = &tall, .cursor = tall.len, .status = "Sending…", .calls = &.{ "• Inspect\n  continued", "• Compare" }, .total_calls = 3, .selected = false, .action_visible = false, .preview_complete = true });
        try std.testing.expectEqual(@as(usize, 2), frame.used);
        try std.testing.expectEqualStrings("+1 more calls · /status", frame.heading.text());
        try std.testing.expectEqual(draft_rows, frame.draft.rows);
        try std.testing.expectEqual(@as(usize, 41) - draft_rows, frame.draft.first);
        try std.testing.expectEqual(height - 2, frame.caret_row);
    }
    // A capped draft leaves browsing and Action pages their rows: this short
    // page shows whole, so an Action on it is read.
    document.top = .{};
    for ([_]bool{ false, true }) |action| {
        try frame.plan(&document, .{ .width = 100, .height = 24, .draft = &tall, .cursor = tall.len, .status = "", .calls = &.{}, .total_calls = 0, .selected = true, .action_visible = action, .preview_complete = true });
        try std.testing.expectEqual(@as(usize, 2), frame.document_rows);
        try std.testing.expectEqualStrings(if (action) "" else "Browsing · Esc returns", frame.heading.text());
        try std.testing.expectEqual(action, frame.approval_ready);
    }
}

test "complete approval and overflow survive short layouts or fail before rendering" {
    var document: Viewport.Document = .{};
    var frame: Self = undefined;
    var input: Input = .{ .width = 24, .height = 3, .cursor = 0, .status = "Idle", .calls = &.{}, .total_calls = 100, .selected = false, .action_visible = false, .preview_complete = true };
    try frame.plan(&document, input);
    try std.testing.expectEqualStrings("+100 · /status", frame.heading.text());
    try std.testing.expectEqual(@as(u16, 2), frame.draft_top);
    input.height = 2;
    try std.testing.expectError(error.TerminalTooSmall, frame.plan(&document, input));
    // At the smallest geometry the input row is a waiting Action's choice;
    // a status that leaves the input no row fails before rendering.
    input = .{ .width = 8, .height = 2, .cursor = 0, .status = "", .calls = &.{}, .total_calls = 0, .selected = true, .action_visible = true, .preview_complete = true };
    try frame.plan(&document, input);
    try std.testing.expectEqual(@as(u16, 1), frame.draft_top);
    try std.testing.expectEqual(@as(u16, 0), frame.line_height);
    input.status = "? Delete\n! Original retained";
    try std.testing.expectError(error.TerminalTooSmall, frame.plan(&document, input));
}

test "the choice fits every width, its labels shortening only when they must" {
    for (8..2049) |columns| {
        const width: u16 = @intCast(columns);
        const row = choice(width);
        const first_end = row.columns[0] + row.labels[0].len + 3;
        try std.testing.expect(first_end <= row.columns[1]);
        try std.testing.expect(row.columns[1] + row.labels[1].len + 3 <= width);
        const full = width >= 25;
        try std.testing.expectEqualStrings(if (full) "Allow once" else if (width >= 20) "Allow" else "A", row.labels[0]);
        try std.testing.expectEqualStrings(if (width >= 20) "Deny" else "D", row.labels[1]);
    }
    // The mock's row: the input's two cells, then Allow once, then Deny.
    try std.testing.expectEqual([2]u16{ 2, 18 }, choice(80).columns);
}

test "a whole Action ends right above the input, a taller one pages from the top" {
    var document: Viewport.Document = .{};
    try document.append("\n? Delete the Zig build cache\n  $ rm -rf .zig-cache zig-out\n");
    var frame: Self = undefined;
    var input: Input = .{ .width = 80, .height = 24, .cursor = 0, .status = "", .calls = &.{}, .total_calls = 0, .selected = true, .action_visible = true, .preview_complete = true };
    document.top = .{};
    try frame.plan(&document, input);
    try std.testing.expectEqual(@as(usize, 3), frame.document_rows);
    try std.testing.expectEqual(@as(u16, 0), frame.navigation_height);
    // Its last row is the row above the rule.
    try std.testing.expectEqual(frame.draft_top - frame.rule_height - frame.status_height, frame.document_offset + 3);
    try std.testing.expect(frame.approval_ready);
    // An inspection page or transcript keeps its text at the top.
    input.action_visible = false;
    try frame.plan(&document, input);
    try std.testing.expectEqual(@as(u16, 0), frame.document_offset);
    // A taller Action pages under its heading from the top.
    input.action_visible = true;
    for (0..40) |_| try document.append("  more\n");
    try frame.plan(&document, input);
    try std.testing.expectEqual(@as(u16, 0), frame.document_offset);
    try std.testing.expectEqualStrings("Action continues · PgDn", frame.heading.text());
}

test "inspection navigation names its actual return target at narrow widths" {
    var document: Viewport.Document = .{};
    var frame: Self = undefined;
    var input: Input = .{ .width = 20, .height = 16, .cursor = 0, .status = "", .calls = &.{}, .total_calls = 0, .selected = true, .action_visible = false, .preview_complete = true };
    for ([_]bool{ false, true }) |pending| {
        input.action_pending = pending;
        for ([_]u16{ 20, 8 }) |width| {
            input.width = width;
            try frame.plan(&document, input);
            try std.testing.expectEqualStrings(if (width == 8) "Esc" else if (pending) "Esc · Action" else "Esc returns", frame.heading.text());
        }
    }
}

test "Action approval requires contiguous displayed rows and resets after resize" {
    var document: Viewport.Document = .{};
    for (0..100) |_| try document.append("command line\n");
    var frame: Self = undefined;
    var input: Input = .{ .width = 80, .height = 24, .cursor = 0, .status = "", .calls = &.{}, .total_calls = 0, .selected = true, .action_visible = true, .preview_complete = true };
    const layout: Viewport.Layout = .{ .width = 80, .method = .wcwidth };
    document.top = .{};
    try frame.plan(&document, input);
    try std.testing.expect(!frame.approval_ready);
    try std.testing.expectEqualStrings("Action continues · PgDn", frame.heading.text());
    const seen = frame.action_seen;
    document.top = .{ .offset = 70 * 13 }; // A jump must not certify the skipped rows.
    input.action_seen = seen;
    try frame.plan(&document, input);
    try std.testing.expect(!frame.approval_ready);
    try std.testing.expectEqual(seen, frame.action_seen);
    document.top = .{};
    for (0..8) |_| {
        input.action_seen = frame.action_seen;
        // Coalesced repeat cannot scroll past the first unread row even when
        // many more keys arrive than could fit between two physical frames.
        for (0..20) |_| document.browse(layout, true, frame.height, frame.height, if (frame.approval_ready) null else input.action_seen);
        try frame.plan(&document, input);
    }
    try std.testing.expect(frame.approval_ready);
    input.action_seen = .{};
    input.width = 40;
    try frame.plan(&document, input);
    try std.testing.expect(!frame.approval_ready);
}
