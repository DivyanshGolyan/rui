//! Logical text and cells belong to the UI thread. Nothing here reads the TTY
//! or joins a worker. The supplied writer owns output credit and cancellation.
const std = @import("std");
const vaxis = @import("vaxis");
const Viewport = @import("ConversationViewport.zig");
const Document = Viewport.Document;
const View = @import("session_view.zig");
const Self = @This();

vx: vaxis.Vaxis = undefined,
memory: Memory = .{},
live: Document = .{},
browsing: Document = .{},
composer: Viewport.Sized(@import("SessionInput.zig").capacity, false) = .{},
selected: bool = false,
file_action: bool = false,
preview_complete: bool = true,
// Borrowed from the frontend: immutable and open until releaseAction or screen
// disposal. This owner neither closes the file nor grants its consent authority.
action_view: ?struct { io: std.Io, file: std.Io.File } = null,
height: usize = 1,
colour: bool,

pub fn init(self: *Self, io: std.Io, environ: *std.process.Environ.Map, colour: bool) !void {
    self.* = .{ .colour = colour };
    self.vx = try vaxis.init(io, self.memory.allocator(), environ, .{});
    self.vx.caps.no_color = !colour;
    // SessionTerminal, not Vaxis.Tty, owns mode entry and restoration.
    self.vx.state.alt_screen = true;
}

pub fn deinit(self: *Self) void {
    // This is memory disposal only, after terminal restoration and joins.
    self.vx.screen.deinit(self.memory.allocator());
    self.vx.screen_last.deinit(self.memory.allocator());
    std.debug.assert(self.memory.used == 0);
}

pub fn append(self: *Self, bytes: []const u8) !void {
    try self.live.append(bytes);
}

pub fn setWidth(self: *Self, method: vaxis.gwidth.Method) void {
    if (self.vx.caps.unicode == method) return;
    self.vx.caps.unicode = method;
    self.vx.screen.width_method = method;
    inline for (.{ &self.live, &self.browsing, &self.composer }) |document| {
        document.width_method = method;
        document.dirty = true;
    }
    self.vx.queueRefresh();
}

pub fn actionVisible(self: *const Self) bool {
    return self.selected and self.file_action;
}

pub fn browse(self: *Self, down: bool) !void {
    if (!self.selected) {
        self.browsing = self.live;
        self.selected = true;
    }
    self.browsing.browse(down, self.height);
}

pub fn latest(self: *Self) !void {
    if (self.action_view) |action| {
        try self.showFile(action.io, action.file, true);
    } else {
        self.selected = false;
        self.file_action = false;
    }
}

pub fn showFile(self: *Self, io: std.Io, file: std.Io.File, action: bool) !void {
    const length = (try file.stat(io)).size;
    self.browsing.clear();
    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < @min(Viewport.capacity, length)) {
        const wanted: usize = @intCast(@min(buffer.len, @min(Viewport.capacity, length) - offset));
        if (try file.readPositionalAll(io, buffer[0..wanted], offset) != wanted) return error.TruncatedDisplayScratch;
        try self.browsing.append(buffer[0..wanted]);
        offset += wanted;
    }
    self.browsing.width_method = self.vx.caps.unicode;
    try self.browsing.layout(@max(1, self.vx.screen.width));
    self.browsing.top = 0;
    self.selected = true;
    self.file_action = action;
    self.preview_complete = length <= Viewport.capacity;
    if (action) self.action_view = .{ .io = io, .file = file };
}

pub fn prepareAction(self: *Self, io: std.Io, file: std.Io.File) !void {
    self.action_view = .{ .io = io, .file = file };
    if (!self.selected) try self.showFile(io, file, true);
}

pub fn releaseAction(self: *Self) void {
    self.action_view = null;
    self.file_action = false;
    self.selected = false;
}

pub fn prepareDraft(self: *Self, bytes: []const u8, size: std.posix.winsize) !void {
    if (size.row < 2 or size.col < 8) return error.TerminalTooSmall;
    self.composer.clear();
    self.composer.width_method = self.vx.caps.unicode;
    try self.composer.append(bytes);
    try self.composer.layout(size.col - 2);
}

pub fn render(self: *Self, out: *std.Io.Writer, size: std.posix.winsize, bytes: []const u8, cursor: usize, status: []const u8, prompt: []const u8, live: *const View.Live) !void {
    // The terminal reports untrusted geometry. Cell allocations (including
    // replacement grids during resize) share the same bounded allocator.
    // Snapshot before either resize or frame output can pump keyboard input.
    try self.prepareDraft(bytes, size);
    var frame: std.Io.Writer.Allocating = .init(self.memory.allocator());
    defer frame.deinit();
    if (size.col != self.vx.screen.width or size.row != self.vx.screen.height) {
        // Browsing resets on resize; draft bytes and its caret do not.
        self.browsing.top = 0;
        try self.vx.resize(self.memory.allocator(), &frame.writer, .{ .rows = size.row, .cols = size.col, .x_pixel = size.xpixel, .y_pixel = size.ypixel });
    }
    const window = self.vx.window();
    window.clear();
    const caret_row = self.composer.rowAt(cursor);
    const approval = std.mem.eql(u8, prompt, "> ");
    var status_text: Viewport.Sized(2048, false) = .{ .width_method = self.vx.caps.unicode };
    try status_text.append(status);
    try status_text.layout(size.col);
    const reserve: u16 = if (approval) 2 else 1;
    if (approval and status_text.displayRows() > size.row - reserve and std.mem.eql(u8, status, "a: Allow once / d: Deny (Enter)")) {
        status_text.clear();
        try status_text.append("a Allow / d Deny\nEnter");
        try status_text.layout(size.col);
    }
    const status_height: u16 = @intCast(status_text.displayRows());
    if (status_height > size.row - reserve) return error.TerminalTooSmall;
    const draft_height = @min(@min(self.composer.row_count, 5), (size.row - status_height) -| 2);
    const visible_draft_height = @max(@as(usize, 1), draft_height);
    const draft_first = caret_row -| (visible_draft_height - 1);
    const status_row: u16 = @intCast(size.row - visible_draft_height - status_height);
    // Calls are current facts, never appended outcomes. Short layouts disclose
    // the omitted population instead of clipping an outcome's explanation.
    var calls: [3]Viewport.Sized(View.Live.line_bytes, false) = .{ .{}, .{}, .{} };
    if (!self.selected) for (0..live.count) |index| {
        var storage: [View.Live.line_bytes]u8 = undefined;
        calls[index].width_method = self.vx.caps.unicode;
        try calls[index].append(try live.line(index, &storage));
        try calls[index].layout(size.col);
    };
    var heading: Viewport.Sized(128, false) = .{ .width_method = self.vx.caps.unicode };
    var used = if (self.selected) 0 else live.count;
    var call_rows: u16 = 0;
    var heading_height: u16 = 0;
    while (true) {
        call_rows = 0;
        for (0..used) |index| call_rows += @intCast(calls[index].displayRows());
        const omitted = if (self.selected) 0 else live.total - used;
        var compact = size.col < 24;
        while (true) {
            heading.clear();
            if (omitted != 0) {
                var storage: [128]u8 = undefined;
                try heading.append(try std.fmt.bufPrint(&storage, "+{d}{s} · /status", .{ omitted, if (compact) "" else " more calls" }));
                try heading.layout(size.col);
                heading_height = @intCast(heading.displayRows());
            } else heading_height = if (status_row -| call_rows > 1) 1 else 0;
            // Complete oldest call previews yield before status, input and
            // the exact undisplayed population. Conversation space and
            // optional wording yield before a complete fitting call preview.
            if (@as(u32, call_rows) + heading_height <= status_row) break;
            if (omitted != 0 and !compact) {
                compact = true;
                continue;
            }
            break;
        }
        if (@as(u32, call_rows) + heading_height <= status_row) break;
        if (used == 0) return error.TerminalTooSmall;
        used -= 1;
    }
    if (heading.length == 0 and heading_height != 0) {
        try heading.append(if (self.actionVisible()) (if (self.preview_complete) "Action · PgUp/PgDn review command" else "Action preview · too large to approve here") else if (self.selected)
            (if (self.action_view != null) "Browsing · Ctrl-G returns to Action" else "Browsing · PgUp/PgDn · Ctrl-G latest")
        else if (self.live.origin != 0) "Latest · PgUp browse · /history older" else "Rui · PgUp browse · /help");
        try heading.layout(size.col);
        if (heading.displayRows() > heading_height) {
            // A one-row hint must retain its next action, not a clipped prefix.
            heading.clear();
            try heading.append(if (self.actionVisible()) (if (self.preview_complete or size.col < "Action preview".len) "Action" else "Action preview") else if (self.selected)
                (if (size.col < "Ctrl-G latest".len) "Ctrl-G" else if (self.action_view != null) "Ctrl-G Action" else "Ctrl-G latest")
            else if (size.col < "PgUp /help".len) "PgUp" else "PgUp /help");
            try heading.layout(size.col);
        }
    }
    self.height = status_row - heading_height - call_rows;
    const document = if (self.selected) &self.browsing else &self.live;
    try document.layout(size.col);
    const first = document.first(self.height);
    for (0..heading_height) |row| try drawRow(window, &heading, row, @intCast(row), 0, self.colour, self.style(.quiet));
    for (first..@min(first + self.height, document.row_count), heading_height..) |row, screen_row|
        try drawRow(window, document, row, @intCast(screen_row), 0, self.colour, .{});
    var call_row = status_row - call_rows;
    for (0..used) |index| {
        for (0..calls[index].displayRows()) |row| try drawRow(window, &calls[index], row, call_row + @as(u16, @intCast(row)), 0, self.colour, self.style(live.style(index)));
        call_row += @intCast(calls[index].displayRows());
    }
    const status_style = self.style(if (approval) .attention else if (std.mem.startsWith(u8, status, "!") or std.mem.startsWith(u8, status, "Rejected")) .failure else .quiet);
    for (0..status_height) |row| try drawRow(window, &status_text, row, status_row + @as(u16, @intCast(row)), 0, self.colour, status_style);
    const draft_top = status_row + status_height;
    for (draft_first..@min(draft_first + visible_draft_height, self.composer.row_count), 0..) |row, line| {
        const screen_row = draft_top + @as(u16, @intCast(line));
        _ = window.child(.{ .y_off = screen_row, .height = 1, .width = 2 }).printSegment(.{ .text = if (line == 0) prompt else "> ", .style = self.style(if (approval) .attention else .user) }, .{});
        try drawRow(window, &self.composer, row, screen_row, 2, self.colour, .{});
    }
    const column = try self.composer.columnAt(cursor);
    window.showCursor(@min(column + 2, size.col - 1), draft_top + @as(u16, @intCast(caret_row - draft_first)));
    // Finish consuming every borrowed cell before output can pump input and
    // change the browsing document. The frame shares the cell memory budget.
    // Any failure is fatal; never drop a frame and continue accepting consent.
    try self.vx.render(&frame.writer);
    try out.writeAll(frame.written());
    try out.flush();
}

fn drawRow(window: vaxis.Window, document: anytype, document_row: usize, row: u16, start: u16, colour: bool, plain_style: vaxis.Style) !void {
    const text = document.rowText(document_row);
    const styles: []const u8 = if (document.styles.len == 0) &.{} else document.styles[document.offset(document_row)..];
    var column = start;
    var clusters = vaxis.unicode.graphemeIterator(text);
    while (clusters.next()) |cluster| {
        const bytes = cluster.bytes(text);
        const width = try document.advance(bytes, column - start);
        if (@as(u32, column) + width > window.width) return error.InvalidDisplayLayout;
        if (std.mem.eql(u8, bytes, "\t")) {
            column += width;
            continue;
        }
        const cell_style = if (styles.len != 0) Viewport.cellStyle(styles[cluster.start], colour) else plain_style;
        window.writeCell(column, row, .{ .char = .{ .grapheme = bytes, .width = @intCast(width) }, .style = cell_style });
        column += width;
    }
}

fn style(self: *const Self, value: View.Style) vaxis.Style {
    if (!self.colour) return .{};
    return .{
        .fg = switch (value) {
            .user => .{ .index = 12 },
            .attention => .{ .index = 3 },
            .failure => .{ .index = 9 },
            // Navigation and state must remain readable in the user's palette.
            .normal, .quiet => .default,
        },
    };
}

// Account actual page-rounded backing bytes, not just requested cell bytes.
// The UI alone uses this allocator; resize peaks and Vaxis's retained grapheme
// arena share 16 MiB. Refusal is a typed fatal render failure, never truncation.
const Memory = struct {
    used: usize = 0,
    const limit = 16 * 1024 * 1024;

    fn allocator(self: *Memory) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }

    fn charge(length: usize) usize {
        return std.mem.alignForward(usize, length, std.heap.pageSize());
    }

    fn alloc(raw: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *Memory = @ptrCast(@alignCast(raw));
        if (length > limit) return null;
        const amount = charge(length);
        if (amount > limit - self.used) return null;
        const result = std.heap.page_allocator.rawAlloc(length, alignment, address) orelse return null;
        self.used += amount;
        return result;
    }

    fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Memory = @ptrCast(@alignCast(raw));
        self.used -= charge(bytes.len);
        std.heap.page_allocator.rawFree(bytes, alignment, address);
    }
};

test "mandatory status and calls wrap wide clusters before the edge" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const size: std.posix.winsize = .{ .row = 12, .col = 8, .xpixel = 0, .ypixel = 0 };
    var live: View.Live = .{};
    try screen.render(&out.writer, size, "", 0, "1234567中Z", "› ", &live);
    const window = screen.vx.window();
    try std.testing.expectEqualStrings("7", window.readCell(6, 9).?.char.grapheme);
    try std.testing.expectEqualStrings("中", window.readCell(0, 10).?.char.grapheme);
    try std.testing.expectEqualStrings("Z", window.readCell(2, 10).?.char.grapheme);
    live.count = 1;
    live.total = 1;
    live.entries[0] = .{ .operation = 7, .ordinal = 9, .presentation = .{ .description = .{}, .code = .unresolved, .publication_position = null } };
    try live.entries[0].presentation.description.?.set("12345中Z");
    try screen.render(&out.writer, size, "", 0, "Idle", "› ", &live);
    try std.testing.expectEqualStrings("中", window.readCell(0, 9).?.char.grapheme);
    try std.testing.expectEqualStrings("Z", window.readCell(2, 9).?.char.grapheme);
    try std.testing.expectError(error.UnrepresentableTerminalGrapheme, screen.render(&out.writer, size, "", 0, "́Z", "› ", &live));
}

test "actual overflow yields wording before clipping required status" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const live: View.Live = .{ .total = 100 };
    try screen.render(&out.writer, .{ .row = 3, .col = 24, .xpixel = 0, .ypixel = 0 }, "", 0, "Idle", "› ", &live);
    const window = screen.vx.window();
    try std.testing.expectEqualStrings("+", window.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("/", window.readCell(7, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("I", window.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("›", window.readCell(0, 2).?.char.grapheme);
    try std.testing.expectError(error.TerminalTooSmall, screen.render(&out.writer, .{ .row = 2, .col = 24, .xpixel = 0, .ypixel = 0 }, "", 0, "Idle", "› ", &live));
    try std.testing.expectError(error.TerminalTooSmall, screen.render(&out.writer, .{ .row = 3, .col = 12, .xpixel = 0, .ypixel = 0 }, "", 0, "a: Allow once / d: Deny (Enter)\n! Original retained", "> ", &.{}));
    var calls: View.Live = .{ .count = 3, .total = 4 };
    for ([_][]const u8{ "Wait for bypass café", "Inspect application settings and report configuration errors before applying changes to local assets", "Wait for bypass café" }, 0..) |label, index| {
        calls.entries[index] = .{ .operation = 7, .ordinal = index, .presentation = .{ .description = .{}, .code = if (index == 1) .failed else .unresolved, .publication_position = null } };
        try calls.entries[index].presentation.description.?.set(label);
    }
    const before = out.written().len;
    screen.vx.queueRefresh();
    try screen.render(&out.writer, .{ .row = 6, .col = 32, .xpixel = 0, .ypixel = 0 }, "live cafXé!", "live cafX".len, "Working…\nBash runs without approval.", "› ", &calls);
    try std.testing.expect(std.mem.indexOf(u8, out.written()[before..], "+3 more calls") != null);
}

test "narrow browsing retains the complete return instruction" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try screen.append("retained conversation\n");
    try screen.browse(false);
    for ([_]u16{ 8, 20 }) |columns| {
        for ([_][]const u8{ "", "Working…" }) |status| {
            const before = out.written().len;
            screen.vx.queueRefresh();
            try screen.render(&out.writer, .{ .row = 24, .col = columns, .xpixel = 0, .ypixel = 0 }, "", 0, status, "› ", &.{});
            try std.testing.expect(std.mem.indexOf(u8, out.written()[before..], "Ctrl-G") != null);
        }
    }
}

test "prepared Action preserves selected inspection until explicit return" {
    const io = std.testing.io;
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try screen.render(&out.writer, .{ .row = 12, .col = 80, .xpixel = 0, .ypixel = 0 }, "", 0, "", "› ", &.{});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const inspection = try tmp.dir.createFile(io, "inspection", .{ .read = true });
    defer inspection.close(io);
    const action = try tmp.dir.createFile(io, "action", .{ .read = true });
    defer action.close(io);
    const status = "Status\nsettings unchanged\nolder row\n";
    try inspection.writePositionalAll(io, status, 0);
    for ([_]bool{ false, true }) |oversized| {
        screen.releaseAction();
        try action.setLength(io, 0);
        try action.writePositionalAll(io, "Run Bash: exact command\n", 0);
        if (oversized) {
            var block: [4096]u8 = @splat('x');
            var offset: u64 = "Run Bash: exact command\n".len;
            while (offset <= Viewport.capacity) {
                const count = @min(block.len, Viewport.capacity + 1 - offset);
                try action.writePositionalAll(io, block[0..count], offset);
                offset += count;
            }
        }
        try screen.showFile(io, inspection, false);
        try screen.browse(false);
        const position = screen.browsing.top;
        try screen.prepareAction(io, action);
        try std.testing.expectEqualStrings(status, screen.browsing.text());
        try std.testing.expectEqual(position, screen.browsing.top);
        try std.testing.expect(!screen.actionVisible());
        try std.testing.expect(screen.preview_complete);
        try screen.latest();
        try std.testing.expect(screen.actionVisible());
        try std.testing.expectEqual(!oversized, screen.preview_complete);
        try std.testing.expect(std.mem.startsWith(u8, screen.browsing.text(), "Run Bash: exact command\n"));
        screen.releaseAction();
        try screen.prepareAction(io, action);
        try std.testing.expect(screen.actionVisible());
    }
}
