//! Logical text and cells belong to the UI thread. Nothing here reads the TTY
//! or joins a worker. The supplied writer owns output credit and cancellation.
const std = @import("std");
const vaxis = @import("vaxis");
const Viewport = @import("ConversationViewport.zig");
const Document = Viewport.Document;
const Position = Viewport.Position;
const Frame = @import("TerminalFrame.zig");
const View = @import("session_view.zig");
const ConsentPolicy = @import("session_consent.zig");
const Self = @This();

/// What the conversation area shows. The transcript is a frozen copy of live
/// text that can grow older canonical pages at its top; inspection, Action and
/// Message documents come from files. Only an Action view can collect consent
/// reads.
pub const ViewKind = enum { live, transcript, inspection, action, message };

/// What a frame encoded: its Action rows and whether it asked for a decision.
pub const Ticket = struct {
    frame: u64,
    scope: u64,
    action: ?u64,
    decision_prompt: bool,
    first: Position,
    next: Position,
    delivered: bool = false,
};

/// Proof that every byte of one frame was written and flushed. Only `render`
/// returns it, after its final flush; `presented` applies it once.
pub const Delivered = struct { frame: u64 };

/// What the frontend must do after a receipt: clear old choice text and draw
/// the decision instructions once reading completes.
pub const PresentationChange = struct { read_completed: bool = false };

vx: vaxis.Vaxis = undefined,
memory: Memory = .{},
// Live text and its transcript copy keep a right margin for user Messages'
// times; pages loaded from files use the full width.
live: Document = .{ .sidenotes = true },
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
// The first Action row no delivered frame has shown in this layout.
action_seen: Position = .{},
// Borrowed from the frontend: immutable and open until releaseAction or screen
// disposal. This owner neither closes the file nor grants its consent authority.
action_view: ?struct { io: std.Io, file: std.Io.File } = null,
// The exact adopted Action and its fresh typing scope. Only this owner
// changes it, from delivered frames and the frontend's completed observations.
consent: ConsentPolicy.Consent = .{},
// Advances whenever view, layout or consent authority is invalidated. A frame
// receipt from an older scope credits nothing.
scope: u64 = 0,
// The projection the latest frame encodes. Input routes by it until the next
// frame is selected, even while that frame's output pumps input.
selected: ConsentPolicy.Projection = .{},
// The latest frame's ticket: one issued frame at a time, delivered at most once.
ticket: ?Ticket = null,
frames: u64 = 0,
// The view a Message page returns to. A transcript keeps its rows and
// position in `browsing` meanwhile: the page is shown from `staging`.
message_return: ViewKind = .live,
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

fn textLayout(self: *const Self) Viewport.Layout {
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

/// Paging a long Action moves its "Run Bash" and Workspace rows off screen.
pub fn actionTopHidden(self: *const Self) bool {
    return self.actionVisible() and !self.browsing.atTop(self.textLayout(), self.height);
}

/// Delivered frames showed every Action row in the current layout.
pub fn actionRead(self: *const Self) bool {
    return self.action_seen.order(.end) == .eq;
}

/// Width, geometry and adoption changes restart reading from the top.
fn invalidateLayout(self: *Self) void {
    self.action_seen = .{};
    self.scope +%= 1;
}

/// View and consent changes revoke any in-flight frame's authority.
fn invalidateScope(self: *Self) void {
    self.scope +%= 1;
}

fn shownAction(self: *const Self) ConsentPolicy.Shown {
    return .{ .action_page = self.actionVisible(), .whole = self.preview_complete, .read = self.actionRead() };
}

/// Selects the next frame's editor and approval through the pure policy.
/// A visible incomplete preview is export-only for the rest of its life.
pub fn select(self: *Self, command_blocked: bool, line_open: bool) ConsentPolicy.Projection {
    if (self.consent.active() and self.actionVisible() and !self.preview_complete) self.consent.presentation = .preview;
    self.selected = ConsentPolicy.project(self.consent, self.shownAction(), command_blocked, line_open);
    return self.selected;
}

/// Adopts the exact Action with its immutable file after the permission read
/// joined and the draft decoder relinquished custody.
pub fn adopt(self: *Self, io: std.Io, file: std.Io.File, action: u64) !void {
    const presentation: ConsentPolicy.Presentation = if ((try file.stat(io)).size <= Viewport.capacity) .complete else .preview;
    try self.prepareAction(io, file);
    self.consent.adopt(action, presentation);
    self.invalidateScope();
}

/// Revokes freshness; the Action and its read rows remain.
pub fn invalidateChoice(self: *Self) void {
    self.consent.invalidate();
    self.invalidateScope();
}

/// Ends consent without leaving the Action's file (exit and interruption).
pub fn interruptConsent(self: *Self) void {
    self.consent.interrupt();
    self.invalidateScope();
}

/// Applies one frame receipt. A stale, duplicate or superseded receipt, or one
/// whose scope or Action changed during its write, credits nothing.
pub fn presented(self: *Self, delivered: Delivered) PresentationChange {
    const ticket = &(self.ticket orelse return .{});
    if (ticket.frame != delivered.frame or ticket.delivered) return .{};
    ticket.delivered = true;
    if (ticket.scope != self.scope or ticket.action != self.consent.action or ticket.action == null or !self.actionVisible() or !self.preview_complete) return .{};
    const was_read = self.actionRead();
    // Only rows delivered contiguously from the top count as read.
    if (ticket.first.order(self.action_seen) != .gt and ticket.next.order(self.action_seen) == .gt) self.action_seen = ticket.next;
    return .{ .read_completed = !was_read and self.actionRead() };
}

/// The latest delivered frame asked for this Action's decision, and nothing
/// revoked its scope since.
pub fn decisionPromptDelivered(self: *const Self) bool {
    const ticket = self.ticket orelse return false;
    return ticket.delivered and ticket.decision_prompt and ticket.scope == self.scope and ticket.action != null and ticket.action == self.consent.action;
}

/// Opens the fresh typing scope from post-write input observations, only for
/// the delivered decision prompt of an unchanged Action and scope.
pub fn promptCompleted(self: *Self, service: ConsentPolicy.Service, decoder_pending: bool, blocked: bool) bool {
    if (!self.decisionPromptDelivered() or !self.actionRead()) return false;
    return self.consent.promptCompleted(service, decoder_pending, blocked);
}

/// Why a probed decision cannot consume the Action now.
pub const DecisionBlock = enum { not_ready, command, layout };

/// A live probe before consumption: current geometry, command and selection,
/// never the readiness of the frame that drew the prompt.
pub fn submitChoice(self: *Self, text: []const u8, size: std.posix.winsize, command_blocked: bool) union(enum) { decision: ConsentPolicy.Decision, blocked: DecisionBlock, other } {
    if (size.col != self.vx.screen.width or size.row != self.vx.screen.height) {
        self.invalidateLayout();
        self.consent.invalidate();
        return .{ .blocked = .layout };
    }
    const live = ConsentPolicy.project(self.consent, self.shownAction(), command_blocked, false);
    if (self.selected.editor != .choice or live.approval != .ready) {
        self.invalidateChoice();
        return .{ .blocked = if (command_blocked and self.actionRead()) .command else .not_ready };
    }
    const decision = self.consent.submit(text);
    self.invalidateScope();
    return if (decision) |value| .{ .decision = value } else .other;
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
    self.invalidateScope();
}

/// Pages or lines through the shown document. Returns true when a downward
/// move passed the transcript's end: the caller returns to the latest view,
/// which is the pending Action if there is one.
pub fn browse(self: *Self, down: bool, page: bool) bool {
    std.debug.assert(self.view != .live);
    const document = self.viewed();
    const end = document.atBottom(self.textLayout(), self.height);
    const moves: usize = if (page) self.height else 1;
    if (self.view == .transcript) self.overscroll = if (down) 0 else if (document.atTop(self.textLayout(), self.height)) @min(self.overscroll + moves, 4 * @as(usize, self.height)) else 0;
    const unseen = if (self.actionVisible() and self.preview_complete and !self.actionRead()) self.action_seen else null;
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

/// Shows one Message's full text over the live view or the transcript.
pub fn showMessage(self: *Self, io: std.Io, file: std.Io.File) !void {
    std.debug.assert(self.view == .live or self.view == .transcript);
    try self.load(&self.staging, io, file, true);
    self.staging.top = .{};
    self.message_return = self.view;
    self.view = .message;
    self.invalidateScope();
}

/// Returns from a Message page to the view it came from, at the same
/// position. An Action that became pending meanwhile takes precedence.
pub fn leaveMessage(self: *Self) !void {
    std.debug.assert(self.view == .message);
    self.staging.clear();
    if (self.action_view != null) return self.latest();
    self.view = self.message_return;
    self.invalidateScope();
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
    } else self.view = .live;
    self.invalidateScope();
}

/// Inspection and Action files show their prefix; an older page keeps its
/// newest text, which adjoins the transcript.
fn load(self: *Self, document: *Document, io: std.Io, file: std.Io.File, prefix: bool) !void {
    const length = (try file.stat(io)).size;
    const end = if (prefix) @min(Viewport.capacity, length) else length;
    document.clear();
    document.sidenotes = false;
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
    if (action) {
        self.action_seen = .{};
        self.action_view = .{ .io = io, .file = file };
    }
    self.invalidateScope();
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
    self.invalidateScope();
}

/// The Action stopped pending elsewhere: end consent, leave its page and keep
/// any other view.
pub fn withdrawAction(self: *Self) void {
    self.consent.interrupt();
    self.action_view = null;
    if (self.view == .action) self.view = .live;
    self.invalidateLayout();
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

/// Encodes the selected projection and returns its receipt only after every
/// byte is written and flushed. Rendering credits nothing; `presented` does.
pub fn render(self: *Self, out: *std.Io.Writer, size: std.posix.winsize, bytes: []const u8, cursor: usize, status: []const u8, live: *const View.Live) !Delivered {
    // The terminal reports untrusted geometry. Cell allocations (including
    // replacement grids during resize) share the same bounded allocator.
    const draft = try self.prepareDraft(bytes, size);
    var frame: std.Io.Writer.Allocating = .init(self.memory.allocator());
    defer frame.deinit();
    if (size.col != self.vx.screen.width or size.row != self.vx.screen.height) {
        // Reflow keeps the first browsed line in view and the draft bytes and
        // caret unchanged. An Action restarts its reading from the top.
        const browsed = self.view == .transcript or self.view == .inspection or (self.view == .message and self.message_return == .transcript);
        const anchor: Position = if (browsed) .{ .offset = self.browsing.first(self.textLayout(), self.height).offset } else .{};
        self.browsing.top = anchor;
        if (self.view == .message) self.staging.top = .{ .offset = self.staging.first(self.textLayout(), self.height).offset };
        self.invalidateLayout();
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
    const approval = self.selected.editor == .choice;
    const prompt = if (approval) "> " else "› ";
    var call_storage: [3][View.Live.line_bytes]u8 = undefined;
    var calls: [3][]const u8 = undefined;
    const selected = self.view != .live;
    if (!selected) for (0..live.count) |index| {
        calls[index] = try live.line(index, &call_storage[index]);
    };
    const document = self.viewed();
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
    const failure = std.mem.startsWith(u8, status, "!") or std.mem.startsWith(u8, status, "Rejected");
    _ = layout.status.draw(window.child(.{ .y_off = layout.status_row, .height = layout.status_height }), .{}, true, self.colour, self.style(if (approval) .attention else .quiet));
    // Only a failure's own line is marked; standing notices below stay quiet.
    if (failure and !approval) _ = layout.status.draw(window.child(.{ .y_off = layout.status_row, .height = layout.status.lineRows(self.textLayout(), 0) }), .{}, true, self.colour, self.style(.failure));
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
    // Issue the ticket before output can pump input. A width report, resize
    // or any other invalidation during the write advances the scope, so the
    // receipt then credits nothing; redrawing those rows is safe.
    self.frames +%= 1;
    self.ticket = .{
        .frame = self.frames,
        .scope = self.scope,
        .action = if (self.actionVisible()) self.consent.action else null,
        .decision_prompt = self.selected.approval == .draining or self.selected.approval == .ready,
        .first = layout.first,
        .next = layout.action_seen,
    };
    try out.writeAll(frame.written());
    try out.flush();
    return .{ .frame = self.frames };
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
    _ = try screen.render(&out.writer, wide, &long, long.len, "", &.{});
    std.debug.print("renderer allocation wide5000X: retained={d}, peak={d} bytes (page charged, not RSS)\n", .{ screen.memory.used, screen.memory.peak });
    try screen.append(&long);
    try screen.append("\n");
    screen.memory.peak = screen.memory.used;
    _ = try screen.render(&out.writer, narrow, "", 0, "", &.{});
    std.debug.print("renderer allocation resize2048→80: retained={d}, peak={d} bytes\n", .{ screen.memory.used, screen.memory.peak });
    var draft: [4097]u8 = undefined;
    draft[0] = 'a';
    for (0..2048) |index| @memcpy(draft[1 + index * 2 ..][0..2], "\u{301}");
    for (0..2049) |marks| {
        const text = draft[0 .. 1 + marks * 2];
        _ = try screen.render(&out.writer, narrow, text, text.len, "", &.{});
    }
    const window = screen.vx.window();
    try std.testing.expectEqualStrings(&draft, window.readCell(2, screen.vx.screen.cursor.row).?.char.grapheme);
    try std.testing.expectError(error.TerminalTooLarge, screen.render(&out.writer, .{ .row = 135, .col = 480, .xpixel = 0, .ypixel = 0 }, "", 0, "", &.{}));
    screen.colour = true;
    screen.vx.caps.no_color = false;
    for ([_][]const u8{ "中", "é", "🐄", "\x1b[1m\x1b[3m\x1b[4m\x1b[91mX\x1b[0mX" }) |pattern| {
        screen.live.clear();
        const cells: usize = if (std.mem.indexOf(u8, pattern, "\x1b") != null or std.mem.eql(u8, pattern, "中") or std.mem.eql(u8, pattern, "🐄")) 2 else 1;
        for (0..Frame.max_cells / cells) |_| try screen.append(pattern);
        for ([_]std.posix.winsize{ .{ .row = 192, .col = 256, .xpixel = 0, .ypixel = 0 }, wide }) |size| {
            screen.memory.peak = screen.memory.used;
            _ = try screen.render(&out.writer, size, "", 0, "", &.{});
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

test "a transcript's front is taken after escaping, which can grow live text past the view" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    // 135 KiB of zero-width spaces fit unescaped; escaped they exceed the view.
    try screen.append("GROWS-FIRST\n");
    for (0..45000) |_| try screen.append("\u{200b}");
    try screen.append("\nGROWS-END\n");
    try std.testing.expectEqual(@as(u64, 0), screen.live.origin);
    const front = try screen.liveStart();
    try std.testing.expect(front > 0);
    try screen.beginTranscript(front);
    try std.testing.expectEqual(front, screen.browsing.origin);
    try std.testing.expectEqualStrings(screen.live.text(), screen.browsing.text());
    try std.testing.expectEqual(front + screen.live.length, try screen.liveEnd());
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
    _ = try screen.render(&out.writer, size, "", 0, "", &.{});
    const window = screen.vx.window();
    try std.testing.expectEqualStrings("›", window.readCell(0, 0).?.char.grapheme);
    try screen.append("› inspect\n  Done.\n");
    _ = try screen.render(&out.writer, size, "next\nline", 9, "", &.{});
    try std.testing.expectEqualStrings("›", window.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("D", window.readCell(2, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("›", window.readCell(0, 3).?.char.grapheme);
    // A draft continuation has no glyph; its text aligns under the first row.
    try std.testing.expectEqualStrings(" ", window.readCell(0, 4).?.char.grapheme);
    try std.testing.expectEqualStrings("l", window.readCell(2, 4).?.char.grapheme);
    _ = try screen.render(&out.writer, size, "next", 4, "Working…", &.{});
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
            _ = try screen.render(&out.writer, size, "", 0, "", &.{});
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
            _ = try screen.render(&out.writer, size, "", 0, "", &.{});
            // The browsing heading takes a row; the first row stays reachable.
            try std.testing.expectEqualStrings("B", window.readCell(0, 0).?.char.grapheme);
            try std.testing.expectEqualStrings("r", window.readCell(0, 1).?.char.grapheme);
            try std.testing.expectEqualStrings("0", window.readCell(4, 1).?.char.grapheme);
            // Paging past the transcript's end returns to live output.
            try std.testing.expect(screen.browse(true, true));
            try screen.latest();
            try std.testing.expectEqual(ViewKind.live, screen.view);
            _ = try screen.render(&out.writer, size, "", 0, "", &.{});
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
    _ = try screen.render(&out.writer, size, "", 0, "1234567中Z", &live);
    const window = screen.vx.window();
    try std.testing.expectEqualStrings("7", window.readCell(6, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("中", window.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("Z", window.readCell(2, 1).?.char.grapheme);
    live.count = 1;
    live.total = 1;
    live.entries[0] = .{ .operation = 7, .ordinal = 9, .presentation = .{ .description = .{}, .code = .unresolved, .publication_position = null } };
    try live.entries[0].presentation.description.?.set("12345中Z");
    _ = try screen.render(&out.writer, size, "", 0, "Idle", &live);
    // The continuation aligns under the call's text, after its glyph.
    try std.testing.expectEqualStrings("5", window.readCell(6, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("中", window.readCell(2, 2).?.char.grapheme);
    try std.testing.expectEqualStrings("Z", window.readCell(4, 2).?.char.grapheme);
    _ = try screen.render(&out.writer, size, "", 0, "́Z", &live);
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
    _ = try screen.render(&out.writer, .{ .row = 3, .col = 24, .xpixel = 0, .ypixel = 0 }, "", 0, "Idle", &live);
    const window = screen.vx.window();
    try std.testing.expectEqualStrings("I", window.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("+", window.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("/", window.readCell(7, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("›", window.readCell(0, 2).?.char.grapheme);
    try std.testing.expectError(error.TerminalTooSmall, screen.render(&out.writer, .{ .row = 2, .col = 24, .xpixel = 0, .ypixel = 0 }, "", 0, "Idle", &live));
    try std.testing.expectError(error.TerminalTooSmall, renderChoice(screen, &out.writer, .{ .row = 3, .col = 12, .xpixel = 0, .ypixel = 0 }, Frame.approval_choice ++ "\n! Original retained"));
    var calls: View.Live = .{ .count = 3, .total = 4 };
    for ([_][]const u8{ "Wait for bypass café", "Inspect application settings and report configuration errors before applying changes to local assets", "Wait for bypass café" }, 0..) |label, index| {
        calls.entries[index] = .{ .operation = 7, .ordinal = index, .presentation = .{ .description = .{}, .code = if (index == 1) .failed else .unresolved, .publication_position = null } };
        try calls.entries[index].presentation.description.?.set(label);
    }
    const before = out.written().len;
    screen.vx.queueRefresh();
    _ = try screen.render(&out.writer, .{ .row = 6, .col = 32, .xpixel = 0, .ypixel = 0 }, "live cafXé!", "live cafX".len, "Working…\nCommand still running.", &calls);
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
            _ = try screen.render(&out.writer, .{ .row = 24, .col = columns, .xpixel = 0, .ypixel = 0 }, "", 0, status, &.{});
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
    _ = try screen.render(&out.writer, .{ .row = 12, .col = 80, .xpixel = 0, .ypixel = 0 }, "", 0, "", &.{});
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
        screen.consent = .{};
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
        try screen.adopt(io, action, 5);
        try std.testing.expectEqualStrings(status, screen.browsing.text());
        try std.testing.expectEqual(position, screen.browsing.top);
        try std.testing.expect(!screen.actionVisible());
        try std.testing.expect(screen.preview_complete);
        try screen.latest();
        try std.testing.expect(screen.actionVisible());
        try std.testing.expectEqual(!oversized, screen.preview_complete);
        try std.testing.expect(std.mem.startsWith(u8, screen.browsing.text(), "Run Bash: exact command\n"));
        if (!oversized) {
            try std.testing.expectEqual(ConsentPolicy.Editor.choice, screen.select(false, false).editor);
            _ = try screen.render(&out.writer, .{ .row = 12, .col = 80, .xpixel = 0, .ypixel = 0 }, "", 0, Frame.approval_choice, &.{});
            const window = screen.vx.window();
            try std.testing.expectEqualStrings("R", window.readCell(0, 0).?.char.grapheme);
            try std.testing.expectEqualStrings("T", window.readCell(0, 2).?.char.grapheme);
            try std.testing.expectEqualStrings(">", window.readCell(0, 3).?.char.grapheme);
        }
        screen.releaseAction();
        screen.consent = .{};
        try screen.adopt(io, action, 6);
        try std.testing.expect(screen.actionVisible());
    }
}

/// Renders a choice frame without an adopted Action, for layout checks only.
fn renderChoice(screen: *Self, out: *std.Io.Writer, size: std.posix.winsize, status: []const u8) !Delivered {
    screen.selected = .{ .editor = .choice, .approval = .ready };
    defer screen.selected = .{};
    return screen.render(out, size, "", 0, status, &.{});
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

    _ = try screen.render(&out.writer, size, "", 0, "", &.{});
    try screen.adopt(io, action, 3);
    try screen.latest();
    var seen: [40]bool = @splat(false);
    var steps: usize = 0;
    while (true) : (steps += 1) {
        try std.testing.expect(steps < 100);
        _ = screen.select(false, false);
        _ = screen.presented(try screen.render(&out.writer, size, "", 0, "", &.{}));
        for (0..12) |row| {
            const shown = rowText(screen, @intCast(row), &storage);
            if (std.mem.startsWith(u8, shown, "row ")) seen[try std.fmt.parseInt(usize, shown[4..6], 10)] = true;
        }
        if (screen.actionRead()) break;
        // Undrawn scrolling cannot pass the first unseen row, so repeated
        // moves between frames cannot credit rows that never reached the screen.
        for (0..if (steps == 0) 100 else 1) |_| _ = screen.browse(true, steps % 2 == 0);
    }
    try std.testing.expect(steps > 3);
    for (seen) |drawn| try std.testing.expect(drawn);

    // A transcript keeps its first visible row while an older page arrives.
    screen.releaseAction();
    screen.consent = .{};
    try screen.latest();
    for (0..30) |line| {
        var buffer: [16]u8 = undefined;
        try screen.append(try std.fmt.bufPrint(&buffer, "live {d:0>2}\n", .{line}));
    }
    // A word that ends at the edge leaves its following space undrawn.
    try screen.append("0123456789012345678901234567890123456789 next\n");
    _ = try screen.render(&out.writer, size, "", 0, "", &.{});
    try screen.beginTranscript(0);
    for (0..5) |_| _ = screen.browse(false, false);
    _ = try screen.render(&out.writer, size, "", 0, "", &.{});
    const before = try std.testing.allocator.dupe(u8, rowText(screen, 1, &storage));
    defer std.testing.allocator.free(before);
    try std.testing.expect(std.mem.startsWith(u8, before, "live "));
    try std.testing.expect(!screen.transcriptAtTop());
    const older = try tmp.dir.createFile(io, "older", .{ .read = true });
    defer older.close(io);
    try older.writePositionalAll(io, "older 1\nolder 2\nolder 3\n", 0);
    try screen.prependFile(io, older);
    _ = try screen.render(&out.writer, size, "", 0, "", &.{});
    try std.testing.expectEqualStrings(before, rowText(screen, 1, &storage));
    // Resize keeps the first browsed line in view.
    _ = try screen.render(&out.writer, .{ .row = 10, .col = 30, .xpixel = 0, .ypixel = 0 }, "", 0, "", &.{});
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
    _ = try screen.render(&out.writer, size, "", 0, "Working…", &.{});
    const before = out.written().len;
    // Observation polls redraw several times a second while idle.
    _ = try screen.render(&out.writer, size, "", 0, "Working…", &.{});
    try std.testing.expectEqual(before, out.written().len);
    _ = try screen.render(&out.writer, size, "a", 1, "Working…", &.{});
    try std.testing.expect(out.written().len > before);
}

test "a Message page returns to the view and position it came from" {
    const io = std.testing.io;
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for (0..60) |index| {
        var line: [32]u8 = undefined;
        try screen.append(try std.fmt.bufPrint(&line, "conversation row {d}\n", .{index}));
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const page = try tmp.dir.createFile(io, "message", .{ .read = true });
    defer page.close(io);
    try page.writePositionalAll(io, "Message · 2 lines\n\nfirst\nsecond\n", 0);
    var action = try ActionFixture.init(4);
    defer action.deinit();
    const size: std.posix.winsize = .{ .row = 12, .col = 40, .xpixel = 0, .ypixel = 0 };
    const narrow: std.posix.winsize = .{ .row = 12, .col = 30, .xpixel = 0, .ypixel = 0 };
    var expected: [12][64]u8 = undefined;
    var lengths: [12]usize = undefined;
    var storage: [64]u8 = undefined;
    for ([_]ViewKind{ .live, .transcript }) |origin| {
        try screen.latest();
        if (origin == .transcript) {
            _ = try screen.render(&out.writer, size, "", 0, "", &.{});
            try screen.beginTranscript(0);
            for (0..2) |_| try std.testing.expect(!screen.browse(false, true));
        }
        for ([_]bool{ false, true }) |resized| {
            _ = try screen.render(&out.writer, size, "", 0, "", &.{});
            for (0..12) |row| {
                const text = rowText(screen, @intCast(row), &storage);
                @memcpy(expected[row][0..text.len], text);
                lengths[row] = text.len;
            }
            try screen.showMessage(io, page);
            _ = try screen.render(&out.writer, size, "", 0, "", &.{});
            try std.testing.expectEqualStrings("Message · 2 lines", rowText(screen, 1, &storage));
            try std.testing.expectEqualStrings("second", rowText(screen, 4, &storage));
            // A resize on the page reflows the hidden view from its first row.
            if (resized) {
                _ = try screen.render(&out.writer, narrow, "", 0, "", &.{});
                _ = try screen.render(&out.writer, size, "", 0, "", &.{});
            }
            try screen.leaveMessage();
            try std.testing.expectEqual(origin, screen.view);
            _ = try screen.render(&out.writer, size, "", 0, "", &.{});
            for (0..12) |row| try std.testing.expectEqualStrings(expected[row][0..lengths[row]], rowText(screen, @intCast(row), &storage));
        }
    }
    // An Action pending meanwhile is where the page returns.
    try screen.latest();
    try screen.showMessage(io, page);
    try screen.adopt(io, action.file, 7);
    try std.testing.expectEqual(ViewKind.message, screen.view);
    try screen.leaveMessage();
    try std.testing.expectEqual(ViewKind.action, screen.view);
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
            _ = try screen.render(&out.writer, size, "", 0, "", &.{});
            try screen.beginTranscript(0);
            for (0..moves) |_| {
                try std.testing.expect(!screen.browse(false, false));
                _ = try screen.render(&out.writer, size, "", 0, "", &.{});
            }
            for (0..moves) |step| {
                try std.testing.expectEqual(step + 1 == moves, screen.browse(true, false));
                _ = try screen.render(&out.writer, size, "", 0, "", &.{});
            }
            try screen.latest();
        }
    }
}

/// A frame writer that runs `hook` once, as output pumping does, before it
/// accepts or refuses the frame's bytes.
const HeldWriter = struct {
    writer: std.Io.Writer,
    screen: *Self,
    hook: ?*const fn (*Self) anyerror!void = null,
    failure: enum { none, first, flush } = .none,
    drains: usize = 0,
    written: usize = 0,

    fn init(screen: *Self, buffer: []u8) HeldWriter {
        return .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer }, .screen = screen };
    }

    fn drain(writer: *std.Io.Writer, parts: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *HeldWriter = @fieldParentPtr("writer", writer);
        if (self.hook) |hook| {
            self.hook = null;
            hook(self.screen) catch return error.WriteFailed;
        }
        const flush = parts.len == 1 and parts[0].len == 0;
        if (self.failure == .first or (self.failure == .flush and flush)) return error.WriteFailed;
        self.drains += 1;
        self.written += writer.end;
        writer.end = 0;
        var count: usize = 0;
        for (parts[0 .. parts.len - 1]) |part| count += part.len;
        count += parts[parts.len - 1].len * splat;
        // Leave a short tail to the final flush, as a congested writer does.
        const kept = if (self.failure == .flush and count > 16) count - 16 else count;
        self.written += kept;
        return kept;
    }
};

const ActionFixture = struct {
    tmp: std.testing.TmpDir,
    file: std.Io.File,

    fn init(rows: usize) !ActionFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const file = try tmp.dir.createFile(std.testing.io, "action", .{ .read = true });
        var line: [16]u8 = undefined;
        for (0..rows) |row| try file.writePositionalAll(std.testing.io, try std.fmt.bufPrint(&line, "row {d:0>3}\n", .{row}), row * 8);
        return .{ .tmp = tmp, .file = file };
    }

    fn deinit(self: *ActionFixture) void {
        self.file.close(std.testing.io);
        self.tmp.cleanup();
    }
};

test "only a complete frame write in an unchanged scope credits Action rows" {
    const io = std.testing.io;
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(io, &environ, false);
    defer screen.deinit();
    const size: std.posix.winsize = .{ .row = 12, .col = 40, .xpixel = 0, .ypixel = 0 };
    var fixture = try ActionFixture.init(4);
    defer fixture.deinit();
    var buffer: [256]u8 = undefined;
    const Hooks = struct {
        var file: std.Io.File = undefined;
        fn width(screen_: *Self) !void {
            screen_.setWidth(if (screen_.vx.caps.unicode == .unicode) .wcwidth else .unicode);
        }
        fn replace(screen_: *Self) !void {
            // Another client decided A; B is adopted before A's frame ends.
            screen_.withdrawAction();
            try screen_.adopt(std.testing.io, file, 0xb);
        }
        fn leave(screen_: *Self) !void {
            try screen_.showFile(std.testing.io, file, false);
        }
    };
    Hooks.file = fixture.file;
    for ([_]enum { fails, fails_finally, width, replaced, left, stale, delivered }{ .fails, .fails_finally, .width, .replaced, .left, .stale, .delivered }) |case| {
        errdefer std.debug.print("receipt case={s}\n", .{@tagName(case)});
        screen.withdrawAction();
        screen.view = .live;
        try screen.adopt(io, fixture.file, 0xa);
        try std.testing.expectEqual(ConsentPolicy.Approval.reading, screen.select(false, false).approval);
        var held: HeldWriter = .init(screen, &buffer);
        held.failure = switch (case) {
            .fails => .first,
            // Earlier frame bytes were accepted; only the final flush fails.
            .fails_finally => .flush,
            else => .none,
        };
        held.hook = switch (case) {
            .width => Hooks.width,
            .replaced => Hooks.replace,
            .left => Hooks.leave,
            else => null,
        };
        // Each case writes a whole frame, not a diff against the last case.
        screen.vx.queueRefresh();
        // The whole proposal fits: one frame would complete reading.
        const result = screen.render(&held.writer, size, "", 0, "", &.{});
        if (case == .fails or case == .fails_finally) {
            try std.testing.expectError(error.WriteFailed, result);
            try std.testing.expectEqual(case == .fails, held.written == 0);
            try std.testing.expect(!screen.actionRead());
            continue;
        }
        const delivered = try result;
        if (case == .stale) {
            // A later frame supersedes the earlier receipt.
            const newer = try screen.render(&held.writer, size, "", 0, "", &.{});
            try std.testing.expect(!screen.presented(delivered).read_completed);
            try std.testing.expect(!screen.actionRead());
            try std.testing.expect(screen.presented(newer).read_completed);
            continue;
        }
        // The hook ran during this frame's output, not before it.
        try std.testing.expect(held.hook == null and held.written != 0);
        const change = screen.presented(delivered);
        try std.testing.expectEqual(case == .delivered, change.read_completed);
        try std.testing.expectEqual(case == .delivered, screen.actionRead());
        // A duplicate receipt changes nothing.
        try std.testing.expect(!screen.presented(delivered).read_completed);
        if (case == .replaced) {
            try std.testing.expectEqual(@as(?u64, 0xb), screen.consent.action);
            try std.testing.expectEqual(ConsentPolicy.Approval.reading, screen.select(false, false).approval);
        }
    }
}

fn expectBlocked(expected: DecisionBlock, result: @typeInfo(@TypeOf(submitChoice)).@"fn".return_type.?) !void {
    // Taking the decision here is the defect this assertion catches.
    try std.testing.expect(result == .blocked);
    try std.testing.expectEqual(expected, result.blocked);
}

test "a decision prompt opens freshness only after its own delivered frame" {
    const io = std.testing.io;
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(io, &environ, false);
    defer screen.deinit();
    const size: std.posix.winsize = .{ .row = 12, .col = 40, .xpixel = 0, .ypixel = 0 };
    var fixture = try ActionFixture.init(4);
    defer fixture.deinit();
    var buffer: [256]u8 = undefined;
    var held: HeldWriter = .init(screen, &buffer);
    try screen.adopt(io, fixture.file, 0xa);
    // The frame that completes reading still said "read the rest".
    _ = screen.select(false, false);
    try std.testing.expect(screen.presented(try screen.render(&held.writer, size, "", 0, "", &.{})).read_completed);
    try std.testing.expect(!screen.decisionPromptDelivered());
    try std.testing.expect(!screen.promptCompleted(.empty, false, false));
    try std.testing.expectEqual(ConsentPolicy.Approval.draining, screen.select(false, false).approval);
    // A planned decision prompt is not a delivered one.
    try std.testing.expect(!screen.promptCompleted(.empty, false, false));
    const prompt = try screen.render(&held.writer, size, "", 0, Frame.approval_choice, &.{});
    _ = screen.presented(prompt);
    try std.testing.expect(screen.decisionPromptDelivered());
    for ([_]ConsentPolicy.Service{ .byte, .decoder_pending, .decoder_expired, .budget_exhausted }) |service|
        try std.testing.expect(!screen.promptCompleted(service, false, false));
    try std.testing.expect(!screen.promptCompleted(.empty, true, false));
    try std.testing.expect(!screen.promptCompleted(.empty, false, true));
    try std.testing.expect(screen.promptCompleted(.empty, false, false));
    try std.testing.expectEqual(ConsentPolicy.Approval.ready, screen.select(false, false).approval);
    // A resize between the prompt and Enter fails the live probe and restarts reading.
    const resized: std.posix.winsize = .{ .row = 10, .col = 40, .xpixel = 0, .ypixel = 0 };
    try expectBlocked(.layout, screen.submitChoice("a", resized, false));
    try std.testing.expect(!screen.actionRead());
    try std.testing.expect(!screen.consent.acceptsInput());
    try std.testing.expectEqual(@as(?u64, 0xa), screen.consent.action);
    // Read again, prompt again, then a queued command blocks the decision.
    _ = screen.select(false, false);
    _ = screen.presented(try screen.render(&held.writer, size, "", 0, "", &.{}));
    _ = screen.select(false, false);
    _ = screen.presented(try screen.render(&held.writer, size, "", 0, Frame.approval_choice, &.{}));
    try std.testing.expect(screen.promptCompleted(.empty, false, false));
    _ = screen.select(false, false);
    try expectBlocked(.command, screen.submitChoice("a", size, true));
    try std.testing.expectEqual(@as(?u64, 0xa), screen.consent.action);
    // While the command holds the choice, its frames ask for no decision.
    try std.testing.expectEqual(ConsentPolicy.Approval.held, screen.select(true, false).approval);
    _ = screen.presented(try screen.render(&held.writer, size, "", 0, "", &.{}));
    try std.testing.expect(!screen.decisionPromptDelivered());
    // The same Action needs a new delivered prompt and empty service.
    try std.testing.expect(!screen.promptCompleted(.empty, false, false));
    _ = screen.select(false, false);
    _ = screen.presented(try screen.render(&held.writer, size, "", 0, Frame.approval_choice, &.{}));
    try std.testing.expect(screen.promptCompleted(.empty, false, false));
    _ = screen.select(false, false);
    const decided = screen.submitChoice("d", size, false);
    try std.testing.expect(decided == .decision);
    try std.testing.expectEqual(ConsentPolicy.Decision{ .action = 0xa, .choice = .deny }, decided.decision);
    // Consumed once: neither the old ready frame nor a repeat decides again.
    try std.testing.expect(!screen.consent.active());
    try std.testing.expect(!screen.decisionPromptDelivered());
    try std.testing.expect(screen.submitChoice("d", size, false) != .decision);
}
