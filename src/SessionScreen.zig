//! Logical text and cells belong to the UI thread. Nothing here reads the TTY
//! or joins a worker. The supplied writer owns output credit and cancellation.
const std = @import("std");
const vaxis = @import("vaxis");
const Viewport = @import("ConversationViewport.zig");
const Document = Viewport.Document;
const Position = Viewport.Position;
const Frame = @import("TerminalFrame.zig");
const View = @import("session_view.zig");
const Self = @This();

/// What the conversation area shows. The transcript is a frozen copy of live
/// text that can grow older canonical pages at its top; inspection and Action
/// documents come from files. Only an Action view can collect consent reads.
pub const ViewKind = enum { live, transcript, inspection, action };

vx: vaxis.Vaxis = undefined,
memory: Memory = .{},
live: Document = .{},
browsing: Document = .{},
staging: Document = .{},
// The draft as displayed: tabs show as one space so offsets stay exact.
composer: [65_536]u8 = undefined,
view: ViewKind = .live,
// Newer transcript rows left the copy so older pages fit; returning to them
// means returning to live.
newer_trimmed: bool = false,
// Rows asked for above the transcript's top while an older page loads; the
// page applies them, so holding PgUp or the wheel keeps moving.
overscroll: usize = 0,
browsing_height: u16 = 0,
preview_complete: bool = true,
action_seen: Position = .{},
approval_ready: bool = false,
// Borrowed from the frontend: immutable and open until releaseAction or screen
// disposal. This owner neither closes the file nor grants its consent authority.
action_view: ?struct { io: std.Io, file: std.Io.File } = null,
height: u16 = 1,
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

/// Absolute live offsets: bytes before `origin` left the retained view.
pub fn liveEnd(self: *const Self) u64 {
    return self.live.origin + self.live.length;
}

fn textLayout(self: *const Self) Viewport.Layout {
    return .{ .width = @max(1, self.vx.screen.width), .method = self.vx.caps.unicode };
}

pub fn setWidth(self: *Self, method: vaxis.gwidth.Method) void {
    if (self.vx.caps.unicode == method) return;
    self.action_seen = .{};
    self.approval_ready = false;
    self.vx.caps.unicode = method;
    self.vx.screen.width_method = method;
    inline for (.{ &self.live, &self.browsing, &self.staging }) |document| {
        document.width_method = method;
        document.dirty = true;
    }
    self.vx.queueRefresh();
}

pub fn actionVisible(self: *const Self) bool {
    return self.view == .action;
}

pub fn approvalReady(self: *const Self) bool {
    return self.actionVisible() and self.preview_complete and self.approval_ready;
}

/// Starts browsing a copy of live text from absolute offset `front`, a
/// position from which older canonical pages continue without a gap.
pub fn beginTranscript(self: *Self, front: u64) !void {
    std.debug.assert(self.view == .live);
    self.browsing = self.live;
    self.browsing.discardFront(front);
    try self.browsing.prepare();
    // Moves apply to the transcript's own height, which its heading and the
    // absent calls make differ from the live view's: start at its end so the
    // same rows down as up return to live output.
    self.height = self.browsing_height;
    self.browsing.top = null;
    self.newer_trimmed = false;
    self.overscroll = 0;
    self.view = .transcript;
}

/// Pages or lines through the shown document. Returns true when a downward
/// move passed the transcript's end: the caller returns to the latest view,
/// which is the pending Action if there is one.
pub fn browse(self: *Self, down: bool, page: bool) bool {
    std.debug.assert(self.view != .live);
    const document = &self.browsing;
    const end = document.atBottom(self.textLayout(), self.height);
    const moves: usize = if (page) self.height else 1;
    if (self.view == .transcript) self.overscroll = if (down) 0 else if (document.atTop(self.textLayout(), self.height)) @min(self.overscroll + moves, 4 * @as(usize, self.height)) else 0;
    const unseen = if (self.actionVisible() and self.preview_complete and !self.approval_ready) self.action_seen else null;
    document.browse(self.textLayout(), down, moves, self.height, unseen);
    if (self.view != .transcript or !down) return false;
    // Untrimmed transcript ends where live output continues.
    return (end and self.newer_trimmed) or (!self.newer_trimmed and document.atBottom(self.textLayout(), self.height));
}

/// The transcript shows its first retained row, so older text is wanted.
pub fn transcriptAtTop(self: *const Self) bool {
    return self.view == .transcript and self.browsing.atTop(self.textLayout(), self.height);
}

/// Prepends one older canonical page, rendered to `file`, above the
/// transcript without moving the rows in view.
pub fn prependFile(self: *Self, io: std.Io, file: std.Io.File) !void {
    std.debug.assert(self.view == .transcript);
    try self.load(&self.staging, io, file, false);
    if (self.staging.origin != 0) {
        // A page larger than the view cannot join its older neighbour without
        // a gap. Keep its newest whole lines and say so at the gap.
        const text = "Rui: Earlier rows of this saved page exceed the view.\n";
        const retained = self.staging.bytes[0..self.staging.length];
        const cut = std.mem.indexOfScalarPos(u8, retained, text.len, '\n') orelse retained.len - 1;
        self.staging.discardFront(self.staging.origin + cut + 1);
        var marker: Viewport.Sized(128, true) = .{ .width_method = self.staging.width_method };
        try marker.append(View.Style.quiet.code(self.colour));
        try marker.append(text);
        try marker.append(View.Style.normal.code(self.colour));
        _ = try self.staging.prepend(&marker, self.textLayout(), 1);
    }
    if (try self.browsing.prepend(&self.staging, self.textLayout(), self.height)) self.newer_trimmed = true;
    const first = self.browsing.first(self.textLayout(), self.height);
    self.browsing.top = self.browsing.up(self.textLayout(), first, self.overscroll);
    self.overscroll = 0;
}

/// Shows that the transcript reached the start of the saved conversation.
pub fn markBeginning(self: *Self) !void {
    try self.boundary("Start of conversation\n");
}

/// Shows that live rows above this point left the view and older saved
/// pages cannot join here without a gap.
pub fn markGap(self: *Self) !void {
    try self.boundary("Earlier rows left this view.\n");
}

fn boundary(self: *Self, text: []const u8) !void {
    std.debug.assert(self.view == .transcript);
    var marker: Viewport.Sized(128, true) = .{ .width_method = self.browsing.width_method };
    try marker.append(View.Style.quiet.code(self.colour));
    try marker.append(text);
    try marker.append(View.Style.normal.code(self.colour));
    if (try self.browsing.prepend(&marker, self.textLayout(), self.height)) self.newer_trimmed = true;
}

pub fn latest(self: *Self) !void {
    if (self.action_view) |action| {
        const seen = self.action_seen;
        try self.showFile(action.io, action.file, true);
        self.action_seen = seen;
    } else self.view = .live;
}

/// Inspection and Action files show their prefix; an older page keeps its
/// newest text, which adjoins the transcript.
fn load(self: *Self, document: *Document, io: std.Io, file: std.Io.File, prefix: bool) !void {
    const length = (try file.stat(io)).size;
    const end = if (prefix) @min(Viewport.capacity, length) else length;
    document.clear();
    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < end) {
        const wanted: usize = @intCast(@min(buffer.len, end - offset));
        if (try file.readPositionalAll(io, buffer[0..wanted], offset) != wanted) return error.TruncatedDisplayScratch;
        try document.append(buffer[0..wanted]);
        offset += wanted;
    }
    document.width_method = self.vx.caps.unicode;
    try document.prepare();
}

pub fn showFile(self: *Self, io: std.Io, file: std.Io.File, action: bool) !void {
    const length = (try file.stat(io)).size;
    self.view = if (action) .action else .inspection;
    try self.load(&self.browsing, io, file, true);
    self.browsing.top = .{};
    self.preview_complete = length <= Viewport.capacity and self.browsing.origin == 0;
    self.approval_ready = false;
    if (action) {
        self.action_seen = .{};
        self.action_view = .{ .io = io, .file = file };
    }
}

pub fn prepareAction(self: *Self, io: std.Io, file: std.Io.File) !void {
    self.action_seen = .{};
    self.approval_ready = false;
    self.action_view = .{ .io = io, .file = file };
    if (self.view == .live) try self.showFile(io, file, true);
}

pub fn releaseAction(self: *Self) void {
    self.action_view = null;
    self.view = .live;
}

/// The draft must have a cell for every cluster; the editor declines edits
/// that would not.
fn prepareDraft(self: *Self, bytes: []const u8, size: std.posix.winsize) ![]const u8 {
    try Frame.validateGeometry(size.col, size.row);
    var clusters = vaxis.unicode.graphemeIterator(bytes);
    while (clusters.next()) |cluster| {
        const text = cluster.bytes(bytes);
        if (std.mem.eql(u8, text, "\n") or std.mem.eql(u8, text, "\t")) continue;
        const cells = vaxis.gwidth.gwidth(text, self.vx.caps.unicode);
        if (cells == 0 or cells > size.col - 2) return error.UnrepresentableTerminalGrapheme;
    }
    const draft = self.composer[0..bytes.len];
    for (draft, bytes) |*shown, byte| shown.* = if (byte == '\t') ' ' else byte;
    return draft;
}

pub fn render(self: *Self, out: *std.Io.Writer, size: std.posix.winsize, bytes: []const u8, cursor: usize, status: []const u8, prompt: []const u8, live: *const View.Live) !void {
    // The terminal reports untrusted geometry. Cell allocations (including
    // replacement grids during resize) share the same bounded allocator.
    // Snapshot before either resize or frame output can pump keyboard input.
    const width_method = self.vx.caps.unicode;
    const draft = try self.prepareDraft(bytes, size);
    var frame: std.Io.Writer.Allocating = .init(self.memory.allocator());
    defer frame.deinit();
    if (size.col != self.vx.screen.width or size.row != self.vx.screen.height) {
        // Reflow keeps the first browsed line in view and the draft bytes and
        // caret unchanged. An Action restarts its reading from the top.
        const anchor: Position = if (self.view == .transcript or self.view == .inspection) .{ .offset = self.browsing.first(self.textLayout(), self.height).offset } else .{};
        self.browsing.top = anchor;
        self.action_seen = .{};
        self.approval_ready = false;
        // A render failure retires this invocation; no old grid is needed for
        // rollback. Retire it before allocating replacements, rather than
        // charging both geometries at once (notably on 16-KiB-page macOS).
        const empty = try vaxis.AllocatingScreen.init(self.memory.allocator(), 0, 0);
        self.vx.screen.deinit(self.memory.allocator());
        self.vx.screen_last.deinit(self.memory.allocator());
        self.vx.screen = .{};
        self.vx.screen_last = empty;
        self.vx.resize(self.memory.allocator(), &frame.writer, .{ .rows = size.row, .cols = size.col, .x_pixel = size.xpixel, .y_pixel = size.ypixel }) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory, // This writer only allocates frame memory.
            else => return err,
        };
    }
    const window = self.vx.window();
    window.clear();
    const approval = std.mem.eql(u8, prompt, "> ");
    var call_storage: [3][View.Live.line_bytes]u8 = undefined;
    var calls: [3][]const u8 = undefined;
    const selected = self.view != .live;
    if (!selected) for (0..live.count) |index| {
        calls[index] = try live.line(index, &call_storage[index]);
    };
    const document = if (selected) &self.browsing else &self.live;
    var layout: Frame = undefined;
    try layout.plan(document, .{
        .width = size.col,
        .height = size.row,
        .method = self.vx.caps.unicode,
        .draft = draft,
        .cursor = cursor,
        .status = status,
        .approval = approval,
        .calls = calls[0..if (selected) 0 else live.count],
        .total_calls = live.total,
        .selected = selected,
        .action_visible = self.actionVisible(),
        .action_pending = self.action_view != null,
        .action_seen = self.action_seen,
        .preview_complete = self.preview_complete,
    });
    self.height = layout.height;
    self.browsing_height = layout.browsing_height;
    _ = layout.heading.draw(window.child(.{ .height = layout.navigation_height }), .{}, true, self.colour, self.style(.quiet));
    _ = document.draw(window.child(.{ .y_off = layout.navigation_height, .height = @intCast(layout.document_rows) }), layout.first, true, self.colour, .{});
    const status_style = self.style(if (approval) .attention else if (std.mem.startsWith(u8, status, "!") or std.mem.startsWith(u8, status, "Rejected")) .failure else .quiet);
    _ = layout.status.draw(window.child(.{ .y_off = layout.status_row, .height = layout.status_height }), .{}, true, self.colour, status_style);
    var call_row = layout.status_row + layout.status_height;
    for (0..layout.used) |index| {
        _ = layout.calls[index].draw(window.child(.{ .y_off = call_row, .height = layout.call_heights[index] }), .{}, true, self.colour, self.style(live.style(index)));
        call_row += layout.call_heights[index];
    }
    _ = layout.heading.draw(window.child(.{ .y_off = call_row, .height = layout.overflow_height }), .{}, true, self.colour, self.style(.quiet));
    // Continuation rows align under the text; only the first row has a glyph.
    for (0..layout.draft_height) |line| _ = window.child(.{ .y_off = layout.draft_top + @as(u16, @intCast(line)), .height = 1, .width = 2 }).printSegment(.{ .text = if (line == 0) prompt else "  ", .style = self.style(if (approval) .attention else .user) }, .{});
    const draft_window = window.child(.{ .x_off = 2, .y_off = layout.draft_top, .height = layout.draft_height });
    _ = draft_window.child(.{ .y_off = -@as(i17, layout.draft_first) }).print(&.{.{ .text = draft }}, .{ .wrap = .grapheme });
    window.showCursor(layout.caret_column, layout.caret_row);
    // Finish consuming every borrowed cell before output can pump input and
    // change the browsing document. The frame shares the cell memory budget.
    // Any failure is fatal; never drop a frame and continue accepting consent.
    self.vx.render(&frame.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory, // Not a terminal I/O failure: frame allocation failed.
        else => return err,
    };
    try out.writeAll(frame.written());
    try out.flush();
    // Only delivered rows count as inspection; a partially written frame cannot
    // certify unseen Action text or grant permission during output pumping.
    if (self.vx.caps.unicode == width_method) {
        self.action_seen = layout.action_seen;
        self.approval_ready = layout.approval_ready;
    }
}

fn style(self: *const Self, value: View.Style) vaxis.Style {
    if (!self.colour) return .{};
    return .{
        .fg = switch (value) {
            .user => .{ .index = 12 },
            .quiet => .{ .index = 8 },
            .attention => .{ .index = 3 },
            .failure => .{ .index = 9 },
            .normal => .default,
        },
    };
}

// Account actual page-rounded backing bytes, not just requested cell bytes.
// The UI alone uses this allocator; resize peaks and Vaxis's retained grapheme
// arena share 32 MiB. At 49,152 cells the empty grids take 15.41 MiB; reserve
// the other half for dense multibyte graphemes, per-cell SGR and geometric frame
// growth, including 16-KiB allocation rounding. Refusal is fatal, not truncation.
const Memory = struct {
    used: usize = 0,
    peak: usize = 0,
    const limit = 32 * 1024 * 1024;

    fn allocator(self: *Memory) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }

    fn charge(length: usize) usize {
        // Exercise Apple Silicon's larger charge granule on Linux tests too.
        const page = if (@import("builtin").is_test) @max(16384, std.heap.pageSize()) else std.heap.pageSize();
        return std.mem.alignForward(usize, length, page);
    }

    fn alloc(raw: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *Memory = @ptrCast(@alignCast(raw));
        if (length > limit) return null;
        const amount = charge(length);
        if (amount > limit - self.used) return null;
        const result = std.heap.page_allocator.rawAlloc(length, alignment, address) orelse return null;
        self.used += amount;
        if (@import("builtin").is_test) self.peak = @max(self.peak, self.used);
        return result;
    }

    fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Memory = @ptrCast(@alignCast(raw));
        self.used -= charge(bytes.len);
        std.heap.page_allocator.rawFree(bytes, alignment, address);
    }
};

test "wide resize preserves a growing combining draft" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var storage: [4096]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&storage);
    const wide: std.posix.winsize = .{ .row = 24, .col = 2048, .xpixel = 0, .ypixel = 0 };
    const narrow: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    const long: [5000]u8 = @splat('X');
    try screen.render(&out.writer, wide, &long, long.len, "", "› ", &.{});
    std.debug.print("renderer allocation wide5000X: retained={d}, peak={d} bytes (page charged, not RSS)\n", .{ screen.memory.used, screen.memory.peak });
    try screen.append(&long);
    try screen.append("\n");
    screen.memory.peak = screen.memory.used;
    try screen.render(&out.writer, narrow, "", 0, "", "› ", &.{});
    std.debug.print("renderer allocation resize2048→80: retained={d}, peak={d} bytes\n", .{ screen.memory.used, screen.memory.peak });
    var draft: [4097]u8 = undefined;
    draft[0] = 'a';
    for (0..2048) |index| @memcpy(draft[1 + index * 2 ..][0..2], "\u{301}");
    for (0..2049) |marks| {
        const text = draft[0 .. 1 + marks * 2];
        try screen.render(&out.writer, narrow, text, text.len, "", "› ", &.{});
    }
    const window = screen.vx.window();
    try std.testing.expectEqualStrings(&draft, window.readCell(2, screen.vx.screen.cursor.row).?.char.grapheme);
    try std.testing.expectError(error.TerminalTooLarge, screen.render(&out.writer, .{ .row = 135, .col = 480, .xpixel = 0, .ypixel = 0 }, "", 0, "", "› ", &.{}));
    screen.colour = true;
    screen.vx.caps.no_color = false;
    for ([_][]const u8{ "中", "é", "🐄", "\x1b[1m\x1b[3m\x1b[4m\x1b[91mX\x1b[0mX" }) |pattern| {
        screen.live.clear();
        const cells: usize = if (std.mem.indexOf(u8, pattern, "\x1b") != null or std.mem.eql(u8, pattern, "中") or std.mem.eql(u8, pattern, "🐄")) 2 else 1;
        for (0..Frame.max_cells / cells) |_| try screen.append(pattern);
        for ([_]std.posix.winsize{ .{ .row = 192, .col = 256, .xpixel = 0, .ypixel = 0 }, wide }) |size| {
            screen.memory.peak = screen.memory.used;
            try screen.render(&out.writer, size, "", 0, "", "› ", &.{});
            std.debug.print("renderer allocation dense {s} {d}x{d}: retained={d}, peak={d} bytes\n", .{ if (cells == 1) "NFD" else if (std.mem.indexOf(u8, pattern, "\x1b") != null) "SGR" else pattern, size.row, size.col, screen.memory.used, screen.memory.peak });
            // Check emitted cells, not merely a non-crashing render.
            const first = screen.vx.window().readCell(0, 0).?;
            try std.testing.expectEqualStrings(if (cells == 1) "é" else if (std.mem.indexOf(u8, pattern, "\x1b") != null) "X" else pattern, first.char.grapheme);
            if (std.mem.indexOf(u8, pattern, "\x1b") != null) {
                try std.testing.expect(first.style.bold and first.style.italic and first.style.ul_style == .single);
                try std.testing.expect(!screen.vx.window().readCell(1, 0).?.style.bold);
            }
        }
    }
}

test "compact conversation keeps the composer beside content without persistent chrome" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, true);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const size: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    try screen.render(&out.writer, size, "", 0, "", "› ", &.{});
    const window = screen.vx.window();
    try std.testing.expectEqualStrings("›", window.readCell(0, 0).?.char.grapheme);
    try screen.append("› inspect\n  Done.\n");
    try screen.render(&out.writer, size, "next\nline", 9, "", "› ", &.{});
    try std.testing.expectEqualStrings("›", window.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("D", window.readCell(2, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("›", window.readCell(0, 3).?.char.grapheme);
    // A draft continuation has no glyph; its text aligns under the first row.
    try std.testing.expectEqualStrings(" ", window.readCell(0, 4).?.char.grapheme);
    try std.testing.expectEqualStrings("l", window.readCell(2, 4).?.char.grapheme);
    try screen.render(&out.writer, size, "next", 4, "Working…", "› ", &.{});
    try std.testing.expectEqualStrings("W", window.readCell(0, 3).?.char.grapheme);
    try std.testing.expectEqual(vaxis.Color{ .index = 8 }, window.readCell(0, 3).?.style.fg);
    try std.testing.expectEqualStrings("›", window.readCell(0, 4).?.char.grapheme);
}

test "optional spacing yields before exact-fit transcript rows" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const size: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    for ([_]usize{ 22, 23, 24 }) |rows| {
        for ([_]bool{ false, true }) |trailing_newline| {
            screen.live.clear();
            for (0..rows) |row| {
                var bytes: [16]u8 = undefined;
                const text = try std.fmt.bufPrint(&bytes, "row{d:0>2}{s}", .{ row, if (row + 1 < rows or trailing_newline) "\n" else "" });
                try screen.append(text);
            }
            try screen.render(&out.writer, size, "", 0, "", "› ", &.{});
            const window = screen.vx.window();
            const first = if (rows == 24) 1 else @as(usize, 0);
            for (first..rows, 0..) |row, y| {
                var bytes: [16]u8 = undefined;
                const expected = try std.fmt.bufPrint(&bytes, "row{d:0>2}", .{row});
                for (expected, 0..) |byte, x| try std.testing.expectEqualStrings(&.{byte}, window.readCell(@intCast(x), @intCast(y)).?.char.grapheme);
            }
            try std.testing.expectEqualStrings("›", window.readCell(0, 23).?.char.grapheme);
            try screen.beginTranscript(0);
            try std.testing.expect(!screen.browse(false, true));
            try screen.render(&out.writer, size, "", 0, "", "› ", &.{});
            // The browsing heading takes a row; the first row stays reachable.
            try std.testing.expectEqualStrings("B", window.readCell(0, 0).?.char.grapheme);
            try std.testing.expectEqualStrings("r", window.readCell(0, 1).?.char.grapheme);
            try std.testing.expectEqualStrings("0", window.readCell(4, 1).?.char.grapheme);
            // Paging past the transcript's end returns to live output.
            try std.testing.expect(screen.browse(true, true));
            try screen.latest();
            try std.testing.expectEqual(ViewKind.live, screen.view);
            try screen.render(&out.writer, size, "", 0, "", "› ", &.{});
            for (first..rows, 0..) |row, y| {
                var bytes: [16]u8 = undefined;
                const expected = try std.fmt.bufPrint(&bytes, "row{d:0>2}", .{row});
                for (expected, 0..) |byte, x| try std.testing.expectEqualStrings(&.{byte}, window.readCell(@intCast(x), @intCast(y)).?.char.grapheme);
            }
        }
    }
}

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
    try std.testing.expectEqualStrings("7", window.readCell(6, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("中", window.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("Z", window.readCell(2, 1).?.char.grapheme);
    live.count = 1;
    live.total = 1;
    live.entries[0] = .{ .operation = 7, .ordinal = 9, .presentation = .{ .description = .{}, .code = .unresolved, .publication_position = null } };
    try live.entries[0].presentation.description.?.set("12345中Z");
    try screen.render(&out.writer, size, "", 0, "Idle", "› ", &live);
    // The continuation aligns under the call's text, after its glyph.
    try std.testing.expectEqualStrings("5", window.readCell(6, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("中", window.readCell(2, 2).?.char.grapheme);
    try std.testing.expectEqualStrings("Z", window.readCell(4, 2).?.char.grapheme);
    try screen.render(&out.writer, size, "", 0, "́Z", "› ", &live);
    try std.testing.expectEqualStrings("\\", window.readCell(0, 0).?.char.grapheme);
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
    try std.testing.expectEqualStrings("I", window.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("+", window.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("/", window.readCell(7, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("›", window.readCell(0, 2).?.char.grapheme);
    try std.testing.expectError(error.TerminalTooSmall, screen.render(&out.writer, .{ .row = 2, .col = 24, .xpixel = 0, .ypixel = 0 }, "", 0, "Idle", "› ", &live));
    try std.testing.expectError(error.TerminalTooSmall, screen.render(&out.writer, .{ .row = 3, .col = 12, .xpixel = 0, .ypixel = 0 }, "", 0, Frame.approval_choice ++ "\n! Original retained", "> ", &.{}));
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
    try screen.beginTranscript(0);
    _ = screen.browse(false, true);
    for ([_]u16{ 8, 20 }) |columns| {
        for ([_][]const u8{ "", "Working…" }) |status| {
            const before = out.written().len;
            screen.vx.queueRefresh();
            try screen.render(&out.writer, .{ .row = 24, .col = columns, .xpixel = 0, .ypixel = 0 }, "", 0, status, "› ", &.{});
            try std.testing.expect(std.mem.indexOf(u8, out.written()[before..], "Esc") != null);
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
        _ = screen.browse(false, true);
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
        if (!oversized) {
            try screen.render(&out.writer, .{ .row = 12, .col = 80, .xpixel = 0, .ypixel = 0 }, "", 0, Frame.approval_choice, "> ", &.{});
            const window = screen.vx.window();
            try std.testing.expectEqualStrings("R", window.readCell(0, 0).?.char.grapheme);
            try std.testing.expectEqualStrings("T", window.readCell(0, 2).?.char.grapheme);
            try std.testing.expectEqualStrings(">", window.readCell(0, 3).?.char.grapheme);
        }
        screen.releaseAction();
        try screen.prepareAction(io, action);
        try std.testing.expect(screen.actionVisible());
    }
}

fn rowText(screen: *Self, row: u16, storage: []u8) []const u8 {
    const window = screen.vx.window();
    var length: usize = 0;
    for (0..window.width) |column| {
        const grapheme = (window.readCell(@intCast(column), row) orelse break).char.grapheme;
        if (length + grapheme.len > storage.len) break;
        @memcpy(storage[length..][0..grapheme.len], grapheme);
        length += grapheme.len;
    }
    return std.mem.trimEnd(u8, storage[0..length], " ");
}

test "line scrolling marks only drawn Action rows and older pages keep the row in view" {
    const io = std.testing.io;
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const size: std.posix.winsize = .{ .row = 12, .col = 40, .xpixel = 0, .ypixel = 0 };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const action = try tmp.dir.createFile(io, "action", .{ .read = true });
    defer action.close(io);
    var text: [40 * 8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&text);
    for (0..40) |row| try writer.print("row {d:0>2}\n", .{row});
    try action.writePositionalAll(io, writer.buffered(), 0);
    var storage: [160]u8 = undefined;

    try screen.render(&out.writer, size, "", 0, "", "› ", &.{});
    try screen.prepareAction(io, action);
    try screen.latest();
    var seen: [40]bool = @splat(false);
    var steps: usize = 0;
    while (true) : (steps += 1) {
        try std.testing.expect(steps < 100);
        try screen.render(&out.writer, size, "", 0, "", "> ", &.{});
        for (0..12) |row| {
            const shown = rowText(screen, @intCast(row), &storage);
            if (std.mem.startsWith(u8, shown, "row ")) seen[try std.fmt.parseInt(usize, shown[4..6], 10)] = true;
        }
        if (screen.approvalReady()) break;
        // Undrawn scrolling cannot pass the first unseen row, so repeated
        // moves between frames cannot credit rows that never reached the screen.
        for (0..if (steps == 0) 100 else 1) |_| _ = screen.browse(true, steps % 2 == 0);
    }
    try std.testing.expect(steps > 3);
    for (seen) |drawn| try std.testing.expect(drawn);

    // A transcript keeps its first visible row while an older page arrives.
    screen.releaseAction();
    try screen.latest();
    for (0..30) |line| {
        var buffer: [16]u8 = undefined;
        try screen.append(try std.fmt.bufPrint(&buffer, "live {d:0>2}\n", .{line}));
    }
    // A word that ends at the edge leaves its following space undrawn.
    try screen.append("0123456789012345678901234567890123456789 next\n");
    try screen.render(&out.writer, size, "", 0, "", "› ", &.{});
    try screen.beginTranscript(0);
    for (0..5) |_| _ = screen.browse(false, false);
    try screen.render(&out.writer, size, "", 0, "", "› ", &.{});
    const before = try std.testing.allocator.dupe(u8, rowText(screen, 1, &storage));
    defer std.testing.allocator.free(before);
    try std.testing.expect(std.mem.startsWith(u8, before, "live "));
    try std.testing.expect(!screen.transcriptAtTop());
    const older = try tmp.dir.createFile(io, "older", .{ .read = true });
    defer older.close(io);
    try older.writePositionalAll(io, "older 1\nolder 2\nolder 3\n", 0);
    try screen.prependFile(io, older);
    try screen.render(&out.writer, size, "", 0, "", "› ", &.{});
    try std.testing.expectEqualStrings(before, rowText(screen, 1, &storage));
    // Resize keeps the first browsed line in view.
    try screen.render(&out.writer, .{ .row = 10, .col = 30, .xpixel = 0, .ypixel = 0 }, "", 0, "", "› ", &.{});
    try std.testing.expectEqualStrings(before, rowText(screen, 1, &storage));
}

test "an unchanged frame writes nothing" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const size: std.posix.winsize = .{ .row = 10, .col = 40, .xpixel = 0, .ypixel = 0 };
    try screen.append("hello\n");
    try screen.render(&out.writer, size, "", 0, "Working…", "› ", &.{});
    const before = out.written().len;
    // Observation polls redraw several times a second while idle.
    try screen.render(&out.writer, size, "", 0, "Working…", "› ", &.{});
    try std.testing.expectEqual(before, out.written().len);
    try screen.render(&out.writer, size, "a", 1, "Working…", "› ", &.{});
    try std.testing.expect(out.written().len > before);
}

test "browsing up then down by the same rows returns to the latest view" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for (0..120) |index| {
        var line: [32]u8 = undefined;
        try screen.append(try std.fmt.bufPrint(&line, "conversation row {d}\n", .{index}));
    }
    for ([_]u16{ 30, 16 }) |rows| {
        for ([_]usize{ 1, 8, 40 }) |moves| {
            const size: std.posix.winsize = .{ .row = rows, .col = 60, .xpixel = 0, .ypixel = 0 };
            try screen.render(&out.writer, size, "", 0, "", "› ", &.{});
            try screen.beginTranscript(0);
            for (0..moves) |_| {
                try std.testing.expect(!screen.browse(false, false));
                try screen.render(&out.writer, size, "", 0, "", "› ", &.{});
            }
            for (0..moves) |step| {
                try std.testing.expectEqual(step + 1 == moves, screen.browse(true, false));
                try screen.render(&out.writer, size, "", 0, "", "› ", &.{});
            }
            try screen.latest();
        }
    }
}
