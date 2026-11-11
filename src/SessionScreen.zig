//! Logical text and cells belong to the UI thread. Nothing here reads the TTY
//! or joins a worker. The supplied writer owns output credit and cancellation.
const std = @import("std");
const vaxis = @import("vaxis");
const Viewport = @import("ConversationViewport.zig");
const Document = Viewport.Document;
const Position = Viewport.Position;
const slash_commands = @import("slash_commands.zig");
const View = @import("session_view.zig");
const ConsentPolicy = @import("session_consent.zig");
const session_id = @import("session_id.zig");
const tool_fold = @import("tool_fold.zig");
const Self = @This();

/// What the conversation area shows. The transcript is a frozen copy of live
/// text that can grow older canonical pages at its top; inspection, Action and
/// Message documents come from files. Only an Action view can collect consent
/// reads.
pub const ViewKind = enum { live, transcript, inspection, action, message };

vx: vaxis.Vaxis = undefined,
memory: Memory = .{},
// Live text and its transcript copy keep a right margin for user Messages'
// times; pages loaded from files use the full width.
live: Document = .{ .sidenotes = true },
browsing: Document = .{},
staging: Document = .{},
view: ViewKind = .live,
// Newer transcript rows left the copy so older pages fit; returning to them
// means returning to live.
newer_trimmed: bool = false,
// Rows asked for above the transcript's top while an older page loads; the
// page applies them, so holding PgUp or the wheel keeps moving.
overscroll: usize = 0,
browsing_height: u16 = 0,
preview_complete: bool = true,
// The first Action row no delivered frame has shown in this layout.
action_seen: Position = .{},
// Borrowed from the frontend: immutable and open until releaseAction or screen
// disposal. This owner neither closes the file nor grants its consent authority.
action_view: ?struct { io: std.Io, file: std.Io.File } = null,
// The exact adopted Action awaiting its decision, with its highlighted option
// and input row. Only this owner changes it.
consent: ?ConsentPolicy.Pending = null,
// The view a Message page returns to. A transcript keeps its rows and
// position in `browsing` meanwhile: the page is shown from `staging`.
message_return: ViewKind = .live,
// The rows of the shown document the latest frame drew.
drawn: struct { first: Position = .{}, rows: u16 = 0 } = .{},
// The command list the latest frame built for the draft: the one value the
// list's keys act on (`slash_commands.Shown`).
commands: ?slash_commands.Shown = null,
height: u16 = 1,
// Rows a scrolled-back view gives up below the transcript, where the `↓`
// marker sits; the latest view shows text there. Scrolling down returns to
// the latest once the view reaches where the latest one starts.
marker_rows: u16 = 0,
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

pub fn append(self: *Self, bytes: []const u8) !void {
    try self.live.append(bytes);
}

/// Absolute live offsets: bytes before `origin` left the retained view.
/// Preparing escapes oversized and invisible clusters, which changes the
/// length of text not yet prepared, so the end is taken after preparing.
/// Escaped text never changes again, and the next item begins a new
/// cluster, so the offset names the same text until it leaves the view.
/// Both ends are taken after preparing: escaping can also grow text and
/// move the origin past offsets recorded earlier.
pub fn liveEnd(self: *Self) !u64 {
    try self.live.prepare();
    return self.live.origin + self.live.length;
}

pub fn liveStart(self: *Self) !u64 {
    try self.live.prepare();
    return self.live.origin;
}

pub fn textLayout(self: *const Self) Viewport.Layout {
    return .{ .width = @max(1, self.vx.screen.width), .method = self.vx.caps.unicode };
}

pub fn setWidth(self: *Self, method: vaxis.gwidth.Method) void {
    if (self.vx.caps.unicode == method) return;
    self.invalidateLayout();
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

/// Starts browsing a copy of live text from absolute offset `front`, a
/// position from which older canonical pages continue without a gap.
pub fn beginTranscript(self: *Self, front: u64) !void {
    std.debug.assert(self.view == .live);
    self.browsing = self.live;
    self.browsing.discardFront(front);
    try self.browsing.prepare();
    // Moves apply to the transcript's own height, which its heading and the
    // absent calls make differ from the live view's. An unpinned live view
    // starts at its end; an open tool's explicit anchor survives the handoff.
    self.height = self.browsing_height;
    self.newer_trimmed = false;
    self.overscroll = 0;
    self.view = .transcript;
}

/// Pages or lines through the shown document. Returns true when a downward
/// move passed the transcript's end: the caller returns to the latest view,
/// which is the pending Action if there is one.
pub fn browse(self: *Self, down: bool, page: bool) bool {
    std.debug.assert(self.view != .live);
    const document = self.viewed();
    const latest_rows = self.height + self.marker_rows;
    const end = document.atBottom(self.textLayout(), latest_rows);
    const moves: usize = if (page) self.height else 1;
    if (self.view == .transcript) self.overscroll = if (down) 0 else if (document.atTop(self.textLayout(), self.height)) @min(self.overscroll + moves, 4 * @as(usize, self.height)) else 0;
    document.browse(self.textLayout(), down, moves, self.height, null);
    if (self.view != .transcript or !down) return false;
    // Untrimmed transcript ends where live output continues.
    return (end and self.newer_trimmed) or (!self.newer_trimmed and document.atBottom(self.textLayout(), latest_rows));
}

/// A drag held at the top or bottom row moves the view one row through
/// the text it already holds: it never reads older pages or changes view.
pub fn dragScroll(self: *Self, up: bool) void {
    self.viewed().browse(self.textLayout(), !up, 1, self.height, null);
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

/// The transcript shows its first retained row, so older text is wanted.
pub fn transcriptAtTop(self: *const Self) bool {
    return self.view == .transcript and self.browsing.atTop(self.textLayout(), self.height);
}

/// Prepends one older canonical page, rendered to `file`, above the
/// transcript without moving the rows in view.
pub fn prependFile(self: *Self, io: std.Io, file: std.Io.File) !Prepended {
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
    const before = self.browsing.collapsed(0, self.browsing.text().len).count;
    const older = self.staging.collapsed(0, self.staging.text().len).count;
    if (try self.browsing.prepend(&self.staging, self.textLayout(), self.height)) self.newer_trimmed = true;
    const first = self.browsing.first(self.textLayout(), self.height);
    self.browsing.top = self.browsing.up(self.textLayout(), first, self.overscroll);
    self.overscroll = 0;
    return .{ .older = older, .trimmed = before + older - self.browsing.collapsed(0, self.browsing.text().len).count };
}

/// Collapsed blocks an older page kept, its newest, and those newer rows
/// lost from the transcript's end.
pub const Prepended = struct { older: usize, trimmed: usize };

/// Collapsed blocks in the transcript.
pub fn transcriptCollapsed(self: *const Self) usize {
    return self.browsing.collapsed(0, self.browsing.text().len).count;
}

/// Shows that the transcript reached the start of the saved conversation.
/// Returns the collapsed blocks newer rows lost from the transcript's end.
pub fn markBeginning(self: *Self) !usize {
    return self.boundary("Start of conversation\n");
}

/// Shows that live rows above this point left the view and older saved
/// pages cannot join here without a gap. Returns as markBeginning does.
pub fn markGap(self: *Self) !usize {
    return self.boundary("Earlier rows left this view.\n");
}

fn boundary(self: *Self, text: []const u8) !usize {
    std.debug.assert(self.view == .transcript);
    var marker: Viewport.Sized(128, true) = .{ .width_method = self.browsing.width_method };
    try marker.append(View.Style.quiet.code(self.colour));
    try marker.append(text);
    try marker.append(View.Style.normal.code(self.colour));
    const before = self.transcriptCollapsed();
    if (try self.browsing.prepend(&marker, self.textLayout(), self.height)) self.newer_trimmed = true;
    return before - self.transcriptCollapsed();
}

/// What Ctrl-O opens: the lowest item the latest frame drew in the live
/// view or transcript, a collapsed user block, counted by how many collapsed
/// blocks follow it in that document, or a peer's name, by its Session's ID.
/// Call right after drawing: later text moves what the frame drew.
pub const Openable = union(enum) { message: usize, session: [session_id.bytes]u8, tool: tool_fold.Reference };

pub fn openableInView(self: *Self, gpa: std.mem.Allocator) !?Openable {
    if (self.view != .live and self.view != .transcript) return null;
    const document = self.viewed();
    const text = document.text().len;
    const next = document.measure(self.textLayout(), self.drawn.first, self.drawn.rows).next;
    // A line cut at the bottom shows its first rows, which hold the mark.
    const end = if (next.offset >= text) text else if (next.row != 0) document.lineEnd(next.offset) else next.offset;
    const start = @min(self.drawn.first.offset, text);
    const message = document.collapsed(start, end).last;
    const tool = document.lastTool(start, end);
    const mark = if (message) |value| if (tool) |row| @max(value, row) else value else tool;
    if (try document.lastShownSession(gpa, self.textLayout(), start, end)) |name| if (mark == null or name > mark.?) {
        const id = document.sessionAt(name).?;
        if (id.len == session_id.bytes) return .{ .session = id[0..session_id.bytes].* };
    };
    const last = mark orelse return null;
    if (tool != null and last == tool.?) return .{ .tool = document.toolAt(last).? };
    return .{ .message = document.collapsed(last + 1, text).count };
}

/// Shows one Message's full text over the live view or the transcript.
pub fn showMessage(self: *Self, io: std.Io, file: std.Io.File) !void {
    std.debug.assert(self.view == .live or self.view == .transcript);
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

fn viewed(self: *Self) *Document {
    return switch (self.view) {
        .live => &self.live,
        .message => &self.staging,
        .transcript, .inspection, .action => &self.browsing,
    };
}

pub fn latest(self: *Self) !void {
    if (self.action_view) |action| {
        const seen = self.action_seen;
        try self.showFile(action.io, action.file, true);
        self.action_seen = seen;
    } else {
        self.live.top = null;
        self.view = .live;
    }
}

/// Inspection and Action files show their prefix; an older page keeps its
/// newest text, which adjoins the transcript.
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
    if (self.view == .live) try self.showFile(io, file, true);
}

/// The decision was consumed: leave its page for the latest view.
pub fn releaseAction(self: *Self) void {
    self.action_view = null;
    self.view = .live;
}

/// The Action stopped pending elsewhere: end consent, leave its page and keep
/// any other view. A line typed beside it stays in the draft.
pub fn withdrawAction(self: *Self) void {
    self.consent = null;
    self.action_view = null;
    if (self.view == .action) self.view = .live;
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

/// Appends text that fits the view unescaped and whose zero-width spaces,
/// escaped, take 160 bytes more than the view holds. Shared by tests whose
/// point is that escaping can evict older live text.
pub fn appendEscapeGrowth(screen: *Self) !void {
    const spaces = 64; // 3 bytes each, 8 escaped: 320 more.
    const filler = try std.testing.allocator.alloc(u8, Viewport.capacity - "GROWS-FIRST\n".len - "\nGROWS-END\n".len - 3 * spaces - 160);
    defer std.testing.allocator.free(filler);
    for (filler, 0..) |*byte, index| byte.* = if (index % 64 == 63) '\n' else 'a';
    try screen.append(filler);
    for (0..spaces) |_| try screen.append("\u{200b}");
}

test "a transcript's front is taken after escaping, which can grow live text past the view" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    // Fits unescaped; escaping its zero-width spaces grows it past the view.
    try screen.append("GROWS-FIRST\n");
    try appendEscapeGrowth(screen);
    try screen.append("\nGROWS-END\n");
    try std.testing.expectEqual(@as(u64, 0), screen.live.origin);
    const front = try screen.liveStart();
    try std.testing.expect(front > 0);
    try screen.beginTranscript(front);
    try std.testing.expectEqual(front, screen.browsing.origin);
    try std.testing.expectEqualStrings(screen.live.text(), screen.browsing.text());
    try std.testing.expectEqual(front + screen.live.length, try screen.liveEnd());
}

test "pinned live anchors survive transcript entry, and latest releases the anchor" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    screen.vx.screen.width = 40;
    screen.browsing_height = 5;
    for (0..32) |_| try screen.append("Line\n");
    try screen.live.prepare();
    for ([_]?Position{ null, .{}, .{ .offset = 20 }, screen.live.bottom(screen.textLayout(), 6) }) |anchor| {
        screen.height = 6;
        screen.live.top = anchor;
        try screen.beginTranscript(0);
        try std.testing.expectEqualDeep(anchor, screen.browsing.top);
        try screen.latest();
        try std.testing.expectEqual(.live, screen.view);
        try std.testing.expect(screen.live.top == null);
        try std.testing.expect(screen.live.atBottom(screen.textLayout(), screen.height));
    }
}
