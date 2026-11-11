//! Logical text and cells belong to the UI thread. Nothing here reads the TTY
//! or joins a worker. The supplied writer owns output credit and cancellation.
const std = @import("std");
const vaxis = @import("vaxis");
const Viewport = @import("ConversationViewport.zig");
const Document = Viewport.Document;
const Position = Viewport.Position;
const slash_commands = @import("slash_commands.zig");
const ConsentPolicy = @import("session_consent.zig");
const feed_window = @import("feed_window.zig");
const Self = @This();

/// The feed and three independent file-backed panel views.
pub const ViewKind = enum { feed, inspection, action, message };

vx: vaxis.Vaxis = undefined,
memory: Memory = .{},
feed: feed_window.Window = .{},
anchor: feed_window.Feed = .{},
// File-backed panels never borrow the feed's text or anchor.
browsing: Document = .{},
staging: Document = .{},
view: ViewKind = .feed,
preview_complete: bool = true,
// The first Action row no delivered frame has shown in this layout.
action_seen: Position = .{},
// Borrowed from the frontend: immutable and open until releaseAction or screen
// disposal. This owner neither closes the file nor grants its consent authority.
action_view: ?struct { io: std.Io, file: std.Io.File } = null,
// The exact adopted Action awaiting its decision, with its highlighted option
// and input row. Only this owner changes it.
consent: ?ConsentPolicy.Pending = null,
// A Message panel leaves the feed window and anchor untouched.
message_return: ViewKind = .feed,
// The rows of the shown document the latest frame drew.
drawn: struct { first: Position = .{}, rows: u16 = 0 } = .{},
// The command list the latest frame built for the draft: the one value the
// list's keys act on (`slash_commands.Shown`).
commands: ?slash_commands.Shown = null,
height: u16 = 1,
colour: bool,

pub fn init(self: *Self, io: std.Io, environ: *std.process.Environ.Map, colour: bool) !void {
    self.* = .{ .colour = colour };
    self.vx = try vaxis.init(io, self.memory.allocator(), environ, .{});
    self.vx.caps.no_color = !colour;
}

pub fn deinit(self: *Self) void {
    // This is memory disposal only, after terminal restoration and joins.
    self.vx.screen.deinit(self.memory.allocator());
    self.vx.screen_last.deinit(self.memory.allocator());
    std.debug.assert(self.memory.used == 0);
}

pub fn textLayout(self: *const Self) Viewport.Layout {
    return .{ .width = @max(1, self.vx.screen.width), .method = self.vx.caps.unicode };
}

pub fn setWidth(self: *Self, method: vaxis.gwidth.Method) void {
    if (self.vx.caps.unicode == method) return;
    self.invalidateLayout();
    self.vx.caps.unicode = method;
    self.vx.screen.width_method = method;
    inline for (.{ &self.browsing, &self.staging }) |document| {
        document.width_method = method;
        document.dirty = true;
    }
    self.vx.queueRefresh();
}

pub fn actionVisible(self: *const Self) bool {
    return self.view == .action;
}

/// Delivered frames showed every Action row in the current layout.
pub fn actionRead(self: *const Self) bool {
    return self.action_seen.order(.end) == .eq;
}

/// Width, geometry and adoption changes restart reading from the top.
fn invalidateLayout(self: *Self) void {
    self.action_seen = .{};
}

fn shownAction(self: *const Self) ConsentPolicy.Shown {
    return .{ .action_page = self.actionVisible(), .read = self.actionRead() };
}

/// Adopts the exact Action with its immutable file after the permission read
/// joined and the draft decoder relinquished custody. Its choice starts at
/// Allow once and takes the input row only from an empty draft: an Enter
/// meant for a line being written never reaches it. A file larger than the
/// view is a preview from the start; loading decides the rest.
pub fn adopt(self: *Self, io: std.Io, file: std.Io.File, action: u64, draft_empty: bool) !void {
    std.debug.assert(self.consent == null);
    const presentation: ConsentPolicy.Presentation = if ((try file.stat(io)).size <= Viewport.capacity) .complete else .preview;
    self.consent = .{ .action = action, .presentation = presentation, .row = if (draft_empty) .selector else .draft };
    try self.prepareAction(io, file);
}

/// The person moves the Action's input row: typing beside it takes the
/// draft at once, so the draft takes that key and those after it, and Esc
/// and the keys like it return to the choice.
pub fn moveRow(self: *Self, row: ConsentPolicy.Row) void {
    const pending = &(self.consent orelse return);
    pending.row = row;
}

/// What the input row shows now.
pub fn liveApproval(self: *const Self, command_blocked: bool) ConsentPolicy.Approval {
    return ConsentPolicy.project(self.consent, self.shownAction(), command_blocked).approval;
}

/// Panels scroll their document; the feed always scrolls its keyed anchor.
pub fn browse(self: *Self, down: bool, page: bool) void {
    std.debug.assert(self.view != .feed);
    self.viewed().browse(self.textLayout(), down, if (page) self.height else 1, self.height, null);
}

pub fn scrollFeed(self: *Self, rows: i32) void {
    self.anchor.scroll(self.feed.layoutEntries(self.textLayout()), self.height, rows, self.feed.edges());
}

pub fn dragScroll(self: *Self, up: bool) void {
    if (self.view == .feed) self.scrollFeed(if (up) -1 else 1) else self.browse(!up, false);
}

/// Scrolls the inspection page so line `line` begins in view, as little as
/// it takes.
pub fn revealLine(self: *Self, line: usize) void {
    std.debug.assert(self.view == .inspection);
    const document = &self.browsing;
    const start = lineStart(document, line) orelse return;
    const layout = self.textLayout();
    const first = document.first(layout, self.height);
    if (start < first.offset or (start == first.offset and first.row != 0)) {
        document.top = .{ .offset = start };
    } else if (document.measure(layout, first, self.height).next.order(.{ .offset = start }) != .gt) {
        document.top = document.up(layout, .{ .offset = start }, self.height -| 1);
    }
}

fn lineStart(document: *const Document, line: usize) ?usize {
    var offset: usize = 0;
    for (0..line) |_| offset = document.nextLine(offset) orelse return null;
    return offset;
}

/// Shows one Message's full text over the feed.
pub fn showMessage(self: *Self, io: std.Io, file: std.Io.File) !void {
    std.debug.assert(self.view == .feed);
    try self.load(&self.staging, io, file, true);
    self.staging.top = .{};
    self.message_return = self.view;
    self.view = .message;
}

/// Returns from a Message page to the view it came from, at the same
/// position. An Action that became pending meanwhile takes precedence.
pub fn leaveMessage(self: *Self) !void {
    std.debug.assert(self.view == .message);
    self.staging.clear();
    if (self.action_view != null) return self.latest();
    self.view = self.message_return;
}

pub fn viewed(self: *Self) *Document {
    return switch (self.view) {
        .feed => unreachable,
        .message => &self.staging,
        .inspection, .action => &self.browsing,
    };
}

pub fn latest(self: *Self) !void {
    if (self.action_view) |action| {
        const seen = self.action_seen;
        try self.showFile(action.io, action.file, true);
        self.action_seen = seen;
    } else self.view = .feed;
}

/// Panel files show their bounded prefix.
fn load(self: *Self, document: *Document, io: std.Io, file: std.Io.File, prefix: bool) !void {
    const length = (try file.stat(io)).size;
    const end = if (prefix) @min(Viewport.capacity, length) else length;
    document.clear();
    document.sidenotes = false;
    document.quotes = false;
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
    self.browsing.quotes = action;
    self.browsing.top = .{};
    self.preview_complete = length <= Viewport.capacity and self.browsing.origin == 0;
    if (action) {
        self.action_seen = .{};
        self.action_view = .{ .io = io, .file = file };
        // An Action that does not load whole is export-only for the rest of
        // its life, whatever a later load would show.
        if (self.consent) |*pending| if (!self.preview_complete) {
            pending.presentation = .preview;
        };
    }
}

/// Replaces the shown inspection with a newer copy of the same page. The first
/// visible line keeps its line number, clamped to the new page.
pub fn refreshFile(self: *Self, io: std.Io, file: std.Io.File) !void {
    std.debug.assert(self.view == .inspection);
    const document = &self.browsing;
    const first = document.first(self.textLayout(), self.height).offset;
    const line = std.mem.count(u8, document.bytes[0..@min(first, document.length)], "\n");
    const length = (try file.stat(io)).size;
    try self.load(document, io, file, true);
    var offset: usize = 0;
    for (0..line) |_| offset = 1 + (std.mem.indexOfScalarPos(u8, document.bytes[0..document.length], offset, '\n') orelse break);
    document.top = .{ .offset = offset };
    self.preview_complete = length <= Viewport.capacity and document.origin == 0;
}

fn prepareAction(self: *Self, io: std.Io, file: std.Io.File) !void {
    self.invalidateLayout();
    self.action_view = .{ .io = io, .file = file };
    if (self.view == .feed) try self.showFile(io, file, true);
}

/// The decision was consumed: leave its page for the latest view.
pub fn releaseAction(self: *Self) void {
    self.action_view = null;
    self.view = .feed;
}

/// The Action stopped pending elsewhere: end consent, leave its page and keep
/// any other view. A line typed beside it stays in the draft.
pub fn withdrawAction(self: *Self) void {
    self.consent = null;
    self.action_view = null;
    if (self.view == .action) self.view = .feed;
    self.invalidateLayout();
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

test "SessionScreen feed scrolling includes tail and latest only changes the view" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    screen.vx.screen.width = 16;
    screen.height = 3;
    screen.feed.at_start = true;
    screen.feed.at_end = true;
    try screen.feed.append(&.{.{ .key = .{ .position = 10 }, .text = .{ .bytes = "0\n1\n2\n3\n" } }});
    screen.feed.tail_rows = 2;
    screen.scrollFeed(-1);
    try std.testing.expectEqual(@as(u32, 2), screen.anchor.anchor.at.line);
    const held = screen.anchor.anchor;
    screen.feed.at_end = false;
    screen.view = .inspection;
    try screen.latest();
    try std.testing.expectEqual(ViewKind.feed, screen.view);
    try std.testing.expectEqualDeep(held, screen.anchor.anchor);
    try std.testing.expect(!screen.anchor.following());
    // Panels do not borrow the feed document or its reading position.
    try screen.browsing.append("one\ntwo\nthree\nfour\n");
    screen.view = .inspection;
    screen.browsing.top = .{};
    screen.browse(true, false);
    try std.testing.expectEqualDeep(held, screen.anchor.anchor);
    try std.testing.expectEqual(@as(usize, 4), screen.browsing.top.?.offset);
}
