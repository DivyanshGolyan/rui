//! Alternate-screen row budget. vaxis measures and wraps text; this module
//! decides which rows each region gets and which Action rows a frame delivers.
//! It owns no terminal custody, cells, files or clocks.
const std = @import("std");
const Viewport = @import("ConversationViewport.zig");
const Position = Viewport.Position;
const Self = @This();
pub const Call = Viewport.Sized(512, false);
/// Bytes of status text a frame holds; the frontend fits its status to this.
pub const status_capacity = 2048;
pub const approval_choice = "Type a + Enter to allow once · d + Enter to deny";
// Includes the historical 24 × 2048 resize witness; the shell accounts dense
// Unicode cells, retained graphemes and frame bytes together under 32 MiB.
pub const max_cells = 24 * 2048;

pub fn validateGeometry(width: u16, height: u16) !void {
    if (height < 2 or width < 8) return error.TerminalTooSmall;
    if (@as(u32, width) * height > max_cells) return error.TerminalTooLarge;
}

status: Viewport.Sized(status_capacity, false),
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
    // An exactly filled last row puts the caret on a row of its own.
    const needed = @max(Viewport.draftRows(draft, input.draft), caret.row + 1);
    // Fit required footer and navigation rows with one draft row first;
    // the draft can then grow into every remaining terminal row.
    var available: u16 = input.height - 1 - self.status_height;
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
            } else heading_height = if (input.selected and (!input.action_visible or !input.preview_complete or document.measure(layout, .{}, available -| (needed - 1)).next.order(.end) != .eq) and available -| call_rows > 1) 1 else 0;
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
    // A selected page needs a readable row so browsing can still advance.
    const document_reserve: u16 = @intFromBool(input.selected and document.text().len != 0 and available > heading_height + call_rows);
    self.draft_height = @min(needed, input.height - self.status_height - heading_height - call_rows - document_reserve);
    self.draft_first = caret.row -| (self.draft_height - 1);
    available = input.height - self.draft_height - self.status_height;
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
    // A trailing blank document line already separates content and footer.
    const last = document.bottom(layout, 1).offset;
    const blank = std.mem.trim(u8, document.text()[last..document.lineEnd(last)], " \t").len == 0;
    const spacer = @intFromBool(self.document_rows != 0 and !blank and end + self.status_height + call_rows + self.overflow_height + self.draft_height < input.height);
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

test "a transcript's final blank row already supplies the prompt spacer" {
    var document: Viewport.Document = .{};
    var frame: Self = undefined;
    var input: Input = .{ .width = 80, .height = 24, .draft = "next\nline", .cursor = 9, .status = "", .approval = false, .calls = &.{}, .total_calls = 0, .selected = false, .action_visible = false, .preview_complete = true };
    for ([_][]const u8{ "Done.", "Done.\n", "Done.\n\n", "Done.\n  \n", "Done.\n  " }) |text| {
        document.clear();
        try document.append(text);
        for ([_]bool{ false, true }) |selected| {
            input.selected = selected;
            for ([_]u16{ 24, 8 }) |height| {
                input.height = height;
                try frame.plan(&document, input);
                const heading: u16 = @intFromBool(selected);
                try std.testing.expectEqual(Position{}, frame.first);
                try std.testing.expectEqual(@as(u16, 2) + heading, frame.draft_top);
                try std.testing.expectEqual(frame.draft_top + frame.draft_height - 1, frame.caret_row);
            }
        }
    }
    // A nonempty footer still needs separation; a blank in the document is
    // already that separation, whether the footer has status or tool rows.
    input.height = 24;
    input.selected = false;
    input.status = "Working…";
    input.calls = &.{"• Inspect layout"};
    input.total_calls = 1;
    for ([_][]const u8{ "Done.\n", "Done.\n\n" }) |text| {
        document.clear();
        try document.append(text);
        try frame.plan(&document, input);
        try std.testing.expectEqual(@as(u16, 2), frame.status_row);
        try std.testing.expectEqual(@as(u16, 4), frame.draft_top);
    }
}

test "an exactly filled draft row puts the caret on the next row" {
    var document: Viewport.Document = .{};
    var frame: Self = undefined;
    // Eight columns leave six for the draft: "abcdef" fills its row.
    for ([_][]const u8{ "abcde", "abcdef" }, [_]u16{ 1, 2 }, [_]u16{ 7, 2 }) |draft, height, column| {
        try frame.plan(&document, .{ .width = 8, .height = 12, .draft = draft, .cursor = draft.len, .status = "", .approval = false, .calls = &.{}, .total_calls = 0, .selected = false, .action_visible = false, .preview_complete = true });
        try std.testing.expectEqual(height, frame.draft_height);
        try std.testing.expectEqual(frame.draft_top + height - 1, frame.caret_row);
        try std.testing.expectEqual(column, frame.caret_column);
    }
}

test "a fitting multiline draft uses free terminal rows without scrolling" {
    var document: Viewport.Document = .{};
    try document.append("› hi\nHi! What would you like to work on?\n");
    const draft = "Please inspect this project.\n\nFirst read README.md.\nKeep all input bytes unchanged.\n\nThen compare the layout.\n\nDo not claim a missing recording was inspected.\n\nPeer A: summarise README.md and preserve literal backticks in the report so every character wraps to the next visual row.\n\nEnd of representative paste.";
    var frame: Self = undefined;
    for ([_]u16{ 20, 24 }) |height| {
        for ([_]usize{ 0, draft.len / 2, draft.len }) |cursor| {
            try frame.plan(&document, .{ .width = 100, .height = height, .draft = draft, .cursor = cursor, .status = "", .approval = false, .calls = &.{}, .total_calls = 0, .selected = false, .action_visible = false, .preview_complete = true });
            // Twelve logical lines, with the Peer line wrapping once.
            try std.testing.expectEqual(@as(u16, 13), frame.draft_height);
            try std.testing.expectEqual(@as(u16, 0), frame.draft_first);
            try std.testing.expectEqual(Position{}, frame.first);
            try std.testing.expectEqual(@as(u16, 3), frame.draft_top);
            try std.testing.expect(frame.draft_top + frame.draft_height <= height);
        }
    }
    // Oversized drafts yield to the actual status, complete calls and overflow
    // rows, not a fixed transcript reservation or a fixed editor maximum.
    var tall: [200]u8 = undefined;
    for (0..40) |index| @memcpy(tall[index * 5 ..][0..5], "line\n");
    for ([_]u16{ 8, 24 }) |height| {
        try frame.plan(&document, .{ .width = 100, .height = height, .draft = &tall, .cursor = tall.len, .status = "Working…", .approval = false, .calls = &.{ "• Inspect\n  continued", "• Compare" }, .total_calls = 3, .selected = false, .action_visible = false, .preview_complete = true });
        try std.testing.expectEqual(@as(usize, 2), frame.used);
        try std.testing.expectEqualStrings("+1 more calls · /status", frame.heading.text());
        try std.testing.expectEqual(height - 5, frame.draft_height);
        try std.testing.expectEqual(@as(u16, 41) - frame.draft_height, frame.draft_first);
        try std.testing.expectEqual(height - 1, frame.caret_row);
    }
    // Browsing and Action pages must remain readable beside an oversized draft.
    document.top = .{};
    for ([_]bool{ false, true }) |action| {
        try frame.plan(&document, .{ .width = 100, .height = 24, .draft = &tall, .cursor = tall.len, .status = "", .approval = false, .calls = &.{}, .total_calls = 0, .selected = true, .action_visible = action, .preview_complete = true });
        try std.testing.expectEqual(@as(usize, 1), frame.document_rows);
        try std.testing.expectEqualStrings(if (action) "Action continues · PgDn" else "Browsing · Esc returns", frame.heading.text());
        try std.testing.expect(!frame.approval_ready);
    }
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
