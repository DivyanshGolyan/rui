//! Alternate-screen row budget. vaxis measures and wraps text; this module
//! decides which rows each region gets and which Action rows a frame delivers.
//! It owns no terminal custody, cells, files or clocks.
const std = @import("std");
const Viewport = @import("ConversationViewport.zig");
const Position = Viewport.Position;
const Self = @This();
pub const Call = Viewport.Sized(512, false);
pub const approval_choice = "Type a + Enter to allow once · d + Enter to deny";
// Includes the historical 24 × 2048 resize witness; the shell accounts dense
// Unicode cells, retained graphemes and frame bytes together under 32 MiB.
pub const max_cells = 24 * 2048;
/// Drafts beyond this many rows scroll to keep the caret in view.
const draft_rows = 5;

pub fn validateGeometry(width: u16, height: u16) !void {
    if (height < 2 or width < 8) return error.TerminalTooSmall;
    if (@as(u32, width) * height > max_cells) return error.TerminalTooLarge;
}

status: Viewport.Sized(2048, false),
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
navigation_height: u16,
overflow_height: u16,
status_height: u16,
status_row: u16,
draft_first: u16,
draft_height: u16,
draft_top: u16,
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
    status: []const u8,
    approval: bool,
    calls: []const []const u8,
    total_calls: u64,
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

/// Plans rows for vaxis to fill. Decisions borrow only the supplied document
/// and draft; the shell consumes the plan before pumping input or changing them.
pub fn plan(self: *Self, document: *Viewport.Document, input: Input) !void {
    try validateGeometry(input.width, input.height);
    const layout: Viewport.Layout = .{ .width = input.width, .method = input.method };
    self.* = .{
        .status = .{ .width_method = input.method },
        .calls = .{ .{ .width_method = input.method }, .{ .width_method = input.method }, .{ .width_method = input.method } },
        .call_heights = .{ 0, 0, 0 },
        .heading = .{ .width_method = input.method },
        .used = if (input.selected) 0 else input.calls.len,
        .height = 0,
        .browsing_height = 0,
        .first = .{},
        .document_rows = 0,
        .navigation_height = 0,
        .overflow_height = 0,
        .status_height = 0,
        .status_row = 0,
        .draft_first = 0,
        .draft_height = 0,
        .draft_top = 0,
        .caret_row = 0,
        .caret_column = 0,
        .action_seen = input.action_seen,
        .approval_ready = false,
    };
    try self.status.append(input.status);
    const reserve: u16 = if (input.approval) 2 else 1;
    var status_rows = try rows(&self.status, layout);
    if (input.approval and status_rows > input.height - reserve and std.mem.eql(u8, input.status, approval_choice)) {
        self.status.clear();
        try self.status.append("a Allow / d Deny\nEnter");
        status_rows = try rows(&self.status, layout);
    }
    self.status_height = status_rows;
    if (self.status_height > input.height - reserve) return error.TerminalTooSmall;
    const draft: Viewport.Layout = .{ .width = input.width - 2, .method = input.method };
    const caret = Viewport.caret(draft, input.draft[0..input.cursor]);
    self.draft_height = @max(1, @min(@min(Viewport.draftRows(draft, input.draft), draft_rows), (input.height - self.status_height) -| 2));
    self.draft_first = caret.row -| (self.draft_height - 1);
    const available: u16 = input.height - self.draft_height - self.status_height;
    try document.prepare();
    for (input.calls, 0..) |line, index| {
        try self.calls[index].append(line);
        self.call_heights[index] = try rows(&self.calls[index], layout);
    }
    var call_rows: u16 = 0;
    var heading_height: u16 = 0;
    while (true) {
        call_rows = 0;
        for (self.call_heights[0..self.used]) |height| call_rows += height;
        const omitted = if (input.selected) 0 else input.total_calls - self.used;
        var compact = input.width < 24;
        while (true) {
            self.heading.clear();
            if (omitted != 0) {
                var storage: [128]u8 = undefined;
                try self.heading.append(try std.fmt.bufPrint(&storage, "+{d}{s} · /status", .{ omitted, if (compact) "" else " more calls" }));
                heading_height = try rows(&self.heading, layout);
            } else heading_height = if (input.selected and (!input.action_visible or !input.preview_complete or document.measure(layout, .{}, available).next.order(.end) != .eq) and available -| call_rows > 1) 1 else 0;
            if (@as(u32, call_rows) + heading_height <= available) break;
            if (omitted != 0 and !compact) {
                compact = true;
                continue;
            }
            break;
        }
        if (@as(u32, call_rows) + heading_height <= available) break;
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
    self.height = available - heading_height - call_rows;
    self.browsing_height = available - @intFromBool(available > 1);
    self.first = document.first(layout, self.height);
    const shown = document.measure(layout, self.first, self.height);
    self.document_rows = shown.rows;
    if (input.action_visible and input.preview_complete) {
        // Only rows delivered contiguously from the top count as read.
        if (self.first.order(input.action_seen) != .gt and shown.next.order(input.action_seen) == .gt) self.action_seen = shown.next;
        self.approval_ready = self.action_seen.order(.end) == .eq;
        if (heading_height != 0) {
            self.heading.clear();
            try self.heading.append(if (self.approval_ready) (if (input.width >= 11) "Action read" else "Read") else if (input.width >= 24) "Action continues · PgDn" else "PgDn");
        }
    }
    try self.heading.prepare();
    self.overflow_height = if (!input.selected and input.total_calls > self.used) heading_height else 0;
    self.navigation_height = heading_height - self.overflow_height;
    const end: u16 = self.navigation_height + @as(u16, @intCast(self.document_rows));
    const spacer = @intFromBool(self.document_rows != 0 and end + self.status_height + call_rows + self.overflow_height + self.draft_height < input.height);
    self.status_row = end + spacer;
    self.draft_top = self.status_row + self.status_height + call_rows + self.overflow_height;
    self.caret_row = self.draft_top + (caret.row - self.draft_first);
    self.caret_column = @min(caret.col + 2, input.width - 1);
}

test "geometry is bounded before the shell allocates cells" {
    try validateGeometry(2048, 24);
    try validateGeometry(256, 192);
    try std.testing.expectError(error.TerminalTooLarge, validateGeometry(2049, 24));
    try std.testing.expectError(error.TerminalTooLarge, validateGeometry(480, 135));
}

test "compact frame keeps exact-fit transcript and multiline caret without bottom pinning" {
    var document: Viewport.Document = .{};
    try document.append("› inspect\n  Done.\n");
    var frame: Self = undefined;
    var input: Input = .{ .width = 80, .height = 24, .draft = "next\nline", .cursor = 9, .status = "", .approval = false, .calls = &.{}, .total_calls = 0, .selected = false, .action_visible = false, .preview_complete = true };
    try frame.plan(&document, input);
    try std.testing.expectEqual(@as(u16, 3), frame.draft_top);
    try std.testing.expectEqual(@as(u16, 4), frame.caret_row);
    try std.testing.expectEqual(@as(u16, 6), frame.caret_column);
    document.clear();
    for (0..24) |_| try document.append("row\n");
    input.draft = "";
    input.cursor = 0;
    try frame.plan(&document, input);
    try std.testing.expectEqual(Position{ .offset = 4 }, frame.first);
    try std.testing.expectEqual(@as(u16, 23), frame.draft_top);
}

test "complete approval and overflow survive short layouts or fail before rendering" {
    var document: Viewport.Document = .{};
    var frame: Self = undefined;
    var input: Input = .{ .width = 24, .height = 3, .cursor = 0, .status = "Idle", .approval = false, .calls = &.{}, .total_calls = 100, .selected = false, .action_visible = false, .preview_complete = true };
    try frame.plan(&document, input);
    try std.testing.expectEqualStrings("+100 · /status", frame.heading.text());
    try std.testing.expectEqual(@as(u16, 2), frame.draft_top);
    input.height = 2;
    try std.testing.expectError(error.TerminalTooSmall, frame.plan(&document, input));
    input.height = 3;
    input.width = 12;
    input.approval = true;
    input.status = approval_choice ++ "\n! Original retained";
    try std.testing.expectError(error.TerminalTooSmall, frame.plan(&document, input));
}

test "inspection navigation names its actual return target at narrow widths" {
    var document: Viewport.Document = .{};
    var frame: Self = undefined;
    var input: Input = .{ .width = 20, .height = 16, .cursor = 0, .status = "", .approval = false, .calls = &.{}, .total_calls = 0, .selected = true, .action_visible = false, .preview_complete = true };
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
    var input: Input = .{ .width = 80, .height = 24, .cursor = 0, .status = approval_choice, .approval = true, .calls = &.{}, .total_calls = 0, .selected = true, .action_visible = true, .preview_complete = true };
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
