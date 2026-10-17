//! Pure alternate-screen layout. Inputs and documents are values; this module
//! neither owns terminal custody nor performs rendering, file or clock effects.
const std = @import("std");
const Viewport = @import("ConversationViewport.zig");
const Self = @This();
pub const Composer = Viewport.Sized(65_536, false);
pub const Call = Viewport.Sized(512, false);
pub const inspection_ready = "Inspection ready · PgUp/PgDn · Ctrl-G returns";

status: Viewport.Sized(2048, false),
calls: [3]Call,
heading: Viewport.Sized(128, false),
used: usize,
height: usize,
first: usize,
document_rows: usize,
navigation_height: u16,
overflow_height: u16,
status_height: u16,
status_row: u16,
draft_first: usize,
draft_height: usize,
draft_top: u16,
caret_row: u16,
caret_column: u16,

pub const Input = struct {
    width: u16,
    height: u16,
    cursor: usize,
    status: []const u8,
    approval: bool,
    calls: []const []const u8,
    total_calls: u64,
    selected: bool,
    action_visible: bool,
    action_pending: bool = false,
    preview_complete: bool,
};

pub fn enabled(setting: []const u8, term: []const u8) bool {
    return std.mem.eql(u8, setting, "vaxis") and !std.mem.eql(u8, term, "dumb");
}

/// Returned row decisions borrow only the supplied document/composer values.
/// The shell consumes the plan before pumping input or changing either value.
pub fn plan(self: *Self, document: *Viewport.Document, composer: *Composer, input: Input) !void {
    if (input.height < 2 or input.width < 8) return error.TerminalTooSmall;
    const method = composer.width_method;
    self.* = .{
        .status = .{ .width_method = method },
        .calls = .{ .{}, .{}, .{} },
        .heading = .{ .width_method = method },
        .used = if (input.selected) 0 else input.calls.len,
        .height = 0,
        .first = 0,
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
    };
    if (input.width < 45 and std.mem.startsWith(u8, input.status, inspection_ready)) {
        try self.status.append(if (input.width >= 18) "PgUp/PgDn · Ctrl-G" else "PgUp\nPgDn\nCtrl-G");
        try self.status.append(input.status[inspection_ready.len..]);
    } else try self.status.append(input.status);
    try self.status.layout(input.width);
    const reserve: u16 = if (input.approval) 2 else 1;
    if (input.approval and self.status.displayRows() > input.height - reserve and
        std.mem.eql(u8, input.status, "a: Allow once / d: Deny (Enter)"))
    {
        self.status.clear();
        try self.status.append("a Allow / d Deny\nEnter");
        try self.status.layout(input.width);
    }
    self.status_height = if (input.status.len == 0) 0 else @intCast(self.status.displayRows());
    if (self.status_height > input.height - reserve) return error.TerminalTooSmall;
    self.draft_height = @max(1, @min(@min(composer.row_count, 5), (input.height - self.status_height) -| 2));
    const caret_row = composer.rowAt(input.cursor);
    self.draft_first = caret_row -| (self.draft_height - 1);
    const available: u16 = @intCast(input.height - self.draft_height - self.status_height);
    for (input.calls, 0..) |line, index| {
        self.calls[index].width_method = method;
        try self.calls[index].append(line);
        try self.calls[index].layout(input.width);
    }
    var call_rows: u16 = 0;
    var heading_height: u16 = 0;
    while (true) {
        call_rows = 0;
        for (self.calls[0..self.used]) |*call| call_rows += @intCast(call.displayRows());
        const omitted = if (input.selected) 0 else input.total_calls - self.used;
        var compact = input.width < 24;
        while (true) {
            self.heading.clear();
            if (omitted != 0) {
                var storage: [128]u8 = undefined;
                try self.heading.append(try std.fmt.bufPrint(&storage, "+{d}{s} · /status", .{ omitted, if (compact) "" else " more calls" }));
                try self.heading.layout(input.width);
                heading_height = @intCast(self.heading.displayRows());
            } else heading_height = if ((if (input.selected) !input.action_visible or !input.preview_complete else document.origin != 0) and available -| call_rows > 1) 1 else 0;
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
        try self.heading.append(if (input.action_visible) "Action preview · too large to approve here" else if (input.selected)
            (if (input.action_pending) "Browsing · Ctrl-G returns to Action" else "Browsing · PgUp/PgDn · Ctrl-G latest")
        else
            "Latest · PgUp browse · /history older");
        try self.heading.layout(input.width);
        if (self.heading.displayRows() > heading_height) {
            self.heading.clear();
            try self.heading.append(if (input.action_visible) (if (input.preview_complete or input.width < "Action preview".len) "Action" else "Action preview") else if (input.selected)
                (if (input.width < "Ctrl-G latest".len) "Ctrl-G" else if (input.action_pending) "Ctrl-G Action" else "Ctrl-G latest")
            else if (input.width < "PgUp /help".len) "PgUp" else "PgUp /help");
            try self.heading.layout(input.width);
        }
    }
    self.height = available - heading_height - call_rows;
    try document.layout(input.width);
    self.first = document.first(self.height);
    self.document_rows = if (document.text().len == 0) 0 else @min(self.height, document.displayRows() -| self.first);
    self.overflow_height = if (!input.selected and input.total_calls > self.used) heading_height else 0;
    self.navigation_height = heading_height - self.overflow_height;
    const end = self.navigation_height + self.document_rows;
    const spacer = @intFromBool(self.document_rows != 0 and end + self.status_height + call_rows + self.overflow_height + self.draft_height < input.height);
    self.status_row = @intCast(end + spacer);
    self.draft_top = self.status_row + self.status_height + call_rows + self.overflow_height;
    self.caret_row = self.draft_top + @as(u16, @intCast(caret_row - self.draft_first));
    self.caret_column = @min(try composer.columnAt(input.cursor) + 2, input.width - 1);
}

test "renderer selection is explicit and dumb terminals retain inline output" {
    for ([_][]const u8{ "", "1", "inline", "VAXIS", "vaxis" }) |setting| {
        try std.testing.expectEqual(std.mem.eql(u8, setting, "vaxis"), enabled(setting, "xterm-256color"));
        try std.testing.expect(!enabled(setting, "dumb"));
    }
}

test "compact frame keeps exact-fit transcript and multiline caret without bottom pinning" {
    var document: Viewport.Document = .{};
    var composer: Composer = .{};
    try document.append("› inspect\n  Done.\n");
    try composer.append("next\nline");
    try composer.layout(78);
    var frame: Self = undefined;
    var input: Input = .{ .width = 80, .height = 24, .cursor = 9, .status = "", .approval = false, .calls = &.{}, .total_calls = 0, .selected = false, .action_visible = false, .preview_complete = true };
    try frame.plan(&document, &composer, input);
    try std.testing.expectEqual(@as(u16, 3), frame.draft_top);
    try std.testing.expectEqual(@as(u16, 4), frame.caret_row);
    try std.testing.expectEqual(@as(u16, 6), frame.caret_column);
    document.clear();
    for (0..24) |_| try document.append("row\n");
    composer.clear();
    try composer.layout(78);
    input.cursor = 0;
    try frame.plan(&document, &composer, input);
    try std.testing.expectEqual(@as(usize, 1), frame.first);
    try std.testing.expectEqual(@as(u16, 23), frame.draft_top);
}

test "complete approval and overflow survive short layouts or fail before rendering" {
    var document: Viewport.Document = .{};
    var composer: Composer = .{};
    try composer.layout(22);
    var frame: Self = undefined;
    var input: Input = .{ .width = 24, .height = 3, .cursor = 0, .status = "Idle", .approval = false, .calls = &.{}, .total_calls = 100, .selected = false, .action_visible = false, .preview_complete = true };
    try frame.plan(&document, &composer, input);
    try std.testing.expectEqualStrings("+100 · /status", frame.heading.text());
    try std.testing.expectEqual(@as(u16, 2), frame.draft_top);
    input.height = 2;
    try std.testing.expectError(error.TerminalTooSmall, frame.plan(&document, &composer, input));
    input.height = 3;
    input.width = 12;
    input.approval = true;
    input.status = "a: Allow once / d: Deny (Enter)\n! Original retained";
    try std.testing.expectError(error.TerminalTooSmall, frame.plan(&document, &composer, input));
}

test "inspection navigation names its actual return target at narrow widths" {
    var document: Viewport.Document = .{};
    var composer: Composer = .{};
    var frame: Self = undefined;
    var input: Input = .{ .width = 20, .height = 16, .cursor = 0, .status = "", .approval = false, .calls = &.{}, .total_calls = 0, .selected = true, .action_visible = false, .preview_complete = true };
    for ([_]bool{ false, true }) |pending| {
        input.action_pending = pending;
        for ([_]u16{ 20, 8 }) |width| {
            input.width = width;
            try composer.layout(width - 2);
            try frame.plan(&document, &composer, input);
            try std.testing.expectEqualStrings(if (width == 8) "Ctrl-G" else if (pending) "Ctrl-G Action" else "Ctrl-G latest", frame.heading.text());
        }
    }
}

test "inspection notice preserves navigation and work status at narrow widths" {
    var document: Viewport.Document = .{};
    var composer: Composer = .{};
    var frame: Self = undefined;
    var input: Input = .{ .width = 80, .height = 24, .cursor = 0, .status = inspection_ready ++ "\nWorking…", .approval = false, .calls = &.{}, .total_calls = 0, .selected = true, .action_visible = false, .preview_complete = true };
    for ([_]u16{ 80, 20, 8 }) |width| {
        input.width = width;
        try composer.layout(width - 2);
        try frame.plan(&document, &composer, input);
        try std.testing.expectEqualStrings(if (width == 80) input.status else if (width == 20) "PgUp/PgDn · Ctrl-G\nWorking…" else "PgUp\nPgDn\nCtrl-G\nWorking…", frame.status.text());
        try std.testing.expect(frame.caret_row < input.height);
    }
}
