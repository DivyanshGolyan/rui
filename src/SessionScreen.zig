//! Logical text and cells belong to the UI thread. Nothing here reads the TTY
//! or joins a worker. The supplied writer owns output credit and cancellation.
const std = @import("std");
const vaxis = @import("vaxis");
const Viewport = @import("ConversationViewport.zig");
const Document = Viewport.Document;
const Position = Viewport.Position;
const Frame = @import("TerminalFrame.zig");
const draft_layout = @import("draft_layout.zig");
const session_line = @import("session_line.zig");
const work_line = @import("work_line.zig");
const queued_line = @import("queued_line.zig");
const View = @import("session_view.zig");
const protocol = @import("protocol.zig");
const ConsentPolicy = @import("session_consent.zig");
const Self = @This();

/// What the conversation area shows. The transcript is a frozen copy of live
/// text that can grow older canonical pages at its top; inspection, Action and
/// Message documents come from files. Only an Action view can collect consent
/// reads.
pub const ViewKind = enum { live, transcript, inspection, action, message };

/// What a reason's line under the input says, as its hint or a notice.
pub const deny_words = "enter denies the command and sends this";

/// What a frame encoded: its Action rows and the option Enter would decide.
pub const Ticket = struct {
    frame: u64,
    scope: u64,
    /// The Action whose rows the frame showed; null when it showed none.
    action: ?u64,
    /// The option the frame's choice showed highlighted, or Deny when it
    /// showed the draft beside the Action as a reason and said Enter denies;
    /// null otherwise.
    shown: ?ConsentPolicy.Choice,
    /// `inputs` when the frame was issued: any later input answered it.
    inputs: u64,
    first: Position,
    next: Position,
    delivered: bool = false,
};

/// Proof that every byte of one frame was written and flushed. Only `render`
/// returns it, after its final flush; `presented` applies it once.
pub const Delivered = struct { frame: u64 };

/// What a receipt changed. Completed reading revokes the frame, so the next
/// one draws the choice.
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
// The transcript's end is not where live output continues: newer rows left
// the copy so older pages fit, or it holds the rows after the read-through
// position. Only a move past its end returns to live.
ends_apart: bool = false,
// For a transcript copied from live output, what to add to its absolute
// offsets to get the live offsets of the same text; null for a transcript
// of pages alone. Prepending moves the copy's offsets, not its text.
copy_shift: ?i64 = null,
// The live offset the copy starts at: rows above it are older pages and
// labels, not live rows.
copy_front: u64 = 0,
// Rows asked for above the transcript's top while an older page loads; the
// page applies them, so holding PgUp or the wheel keeps moving.
overscroll: usize = 0,
browsing_height: u16 = 0,
// The byte the draft's first shown line started at in the latest frame,
// kept first by the next one so the input scrolls only when its caret
// leaves view. The choice never moves it.
draft_anchor: usize = 0,
preview_complete: bool = true,
// The first Action row no delivered frame has shown in this layout.
action_seen: Position = .{},
// Borrowed from the frontend: immutable and open until releaseAction or screen
// disposal. This owner neither closes the file nor grants its consent authority.
action_view: ?struct { io: std.Io, file: std.Io.File } = null,
// The exact adopted Action awaiting its decision, with its highlighted option
// and input row. Only this owner changes it.
consent: ?ConsentPolicy.Pending = null,
// The frame whose choice Enter may confirm: delivered, then input serviced
// empty with no key since. Only promptCompleted sets it, and only
// spendOffer, the entry of every input, clears it. It stands for a decision
// only while that frame is the latest and nothing changed since: any later
// frame or change retires it, so it needs no other clearing.
offer: ?u64 = null,
// Counts inputs, so a ticket knows whether any arrived after its frame.
inputs: u64 = 0,
// Advances whenever view, layout, Action or the shown choice is
// invalidated. A frame receipt from an older scope credits nothing, and a
// frame from an older scope is stale: the next one must be drawn.
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
// The rows of the shown document the latest frame drew.
drawn: struct { first: Position = .{}, rows: u16 = 0 } = .{},
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

/// Paging a long Action moves its `?` row off screen.
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

/// No frame was drawn, or a change since revoked the latest one: draw the
/// next before relying on what the screen shows.
pub fn stale(self: *const Self) bool {
    const ticket = self.ticket orelse return true;
    return ticket.scope != self.scope;
}

fn shownAction(self: *const Self) ConsentPolicy.Shown {
    return .{ .action_page = self.actionVisible(), .read = self.actionRead() };
}

/// Selects the next frame's input row and approval through the pure policy.
/// render calls it once the frame's geometry is adopted.
pub fn select(self: *Self, command_blocked: bool) ConsentPolicy.Projection {
    self.selected = ConsentPolicy.project(self.consent, self.shownAction(), command_blocked);
    return self.selected;
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
    if (pending.row == row) return;
    pending.row = row;
    self.invalidateScope();
}

/// The row input goes to: the one the latest frame shows, except that typing
/// beside the Action has already moved it to the draft.
pub fn inputRow(self: *const Self) ConsentPolicy.Row {
    if (self.consent) |pending| if (pending.row == .draft) return .draft;
    return self.selected.row;
}

/// Ends consent without leaving the Action's file (exit and interruption).
pub fn interruptConsent(self: *Self) void {
    self.consent = null;
    self.invalidateScope();
}

/// The entry of every input: returns the offer it may use and spends it, so
/// the next key counts only after a later frame is offered.
pub fn spendOffer(self: *Self) ?u64 {
    defer {
        self.offer = null;
        self.inputs +%= 1;
    }
    return self.offer;
}

/// Applies one frame receipt. A stale, duplicate or superseded receipt, or one
/// whose scope or Action changed during its write, credits nothing.
pub fn presented(self: *Self, delivered: Delivered) PresentationChange {
    const ticket = &(self.ticket orelse return .{});
    if (ticket.frame != delivered.frame or ticket.delivered) return .{};
    ticket.delivered = true;
    const action = if (self.consent) |pending| pending.action else null;
    if (ticket.scope != self.scope or ticket.action != action or ticket.action == null or !self.actionVisible() or !self.preview_complete) return .{};
    const was_read = self.actionRead();
    // Only rows delivered contiguously from the top count as read.
    if (ticket.first.order(self.action_seen) != .gt and ticket.next.order(self.action_seen) == .gt) self.action_seen = ticket.next;
    if (was_read or !self.actionRead()) return .{};
    self.invalidateScope();
    return .{ .read_completed = true };
}

/// The decision an offer of `frame` stands for: the choice that frame
/// showed, while it is the latest frame and nothing changed since it.
fn standing(self: *const Self, frame: ?u64) ?ConsentPolicy.Decision {
    const ticket = self.ticket orelse return null;
    if ((frame orelse return null) != ticket.frame or ticket.scope != self.scope) return null;
    return .{ .action = ticket.action orelse return null, .choice = ticket.shown orelse return null };
}

/// The decision Enter would confirm now, if it were the next input.
pub fn offered(self: *const Self) ?ConsentPolicy.Decision {
    return self.standing(self.offer);
}

/// The latest frame offered a decision, was delivered and is current, no input
/// followed it, and it is not yet offered: the frontend services input to
/// see whether it may be.
pub fn awaitsOffer(self: *const Self) bool {
    const ticket = self.ticket orelse return false;
    return ticket.delivered and ticket.inputs == self.inputs and self.offer != ticket.frame and self.standing(ticket.frame) != null;
}

/// The one place an offer is made: the latest frame, once input after its
/// delivery was serviced empty, with nothing pending, running or left to
/// draw. Returns whether this made the offer.
pub fn promptCompleted(self: *Self, service: ConsentPolicy.Service, decoder_pending: bool, blocked: bool) bool {
    if (!self.awaitsOffer() or service != .empty or decoder_pending or blocked) return false;
    self.offer = self.ticket.?.frame;
    return true;
}

/// A key that acts on the choice: an arrow moves the highlight, Enter decides.
pub const ChoiceKey = union(enum) { pick: ConsentPolicy.Choice, enter };

/// Why a key at the choice could not act now.
pub const DecisionBlock = enum { not_ready, reading, command, layout };

pub const ChoiceOutcome = union(enum) { picked, decision: ConsentPolicy.Decision, blocked: DecisionBlock };

/// An arrow or Enter at the choice, with the offer `spendOffer` returned for
/// this key. It acts only when that offer is the latest frame, unchanged
/// since, and the decision it showed is the Action's current one. A live
/// probe of geometry and command comes first.
pub fn choose(self: *Self, key: ChoiceKey, offer: ?u64, size: std.posix.winsize, command_blocked: bool) ChoiceOutcome {
    if (size.col != self.vx.screen.width or size.row != self.vx.screen.height) {
        self.invalidateLayout();
        return .{ .blocked = .layout };
    }
    switch (self.liveApproval(command_blocked)) {
        .choice => {},
        .reading => return .{ .blocked = .reading },
        .held => return .{ .blocked = .command },
        else => return .{ .blocked = .not_ready },
    }
    const pending = &self.consent.?;
    const shown = self.standing(offer) orelse return .{ .blocked = .not_ready };
    if (!std.meta.eql(shown, pending.decision())) return .{ .blocked = .not_ready };
    switch (key) {
        .pick => |to| {
            // The picked option is drawn before the next key is read.
            if (pending.highlight != to) self.invalidateScope();
            pending.highlight = to;
            return .picked;
        },
        .enter => {
            self.decide(shown);
            return .{ .decision = shown };
        },
    }
}

/// Enter in the draft beside an Action, with the offer `spendOffer` returned
/// for this key: the denial the draft is sent with, when that offer is the
/// latest frame, unchanged since, and it showed this draft as the reason.
/// A probe: nothing changes until `decide`.
pub fn reasonOffered(self: *const Self, offer: ?u64, size: std.posix.winsize, command_blocked: bool) ?ConsentPolicy.Decision {
    const shown = self.standing(offer) orelse return null;
    if (self.liveApproval(command_blocked) != .reason) return null;
    if (size.col != self.vx.screen.width or size.row != self.vx.screen.height) return null;
    const denial: ConsentPolicy.Decision = .{ .action = self.consent.?.action, .choice = .deny };
    return if (std.meta.eql(shown, denial)) denial else null;
}

/// Consent ends with this decision, before fallible submission starts.
pub fn decide(self: *Self, decision: ConsentPolicy.Decision) void {
    std.debug.assert(self.consent.?.action == decision.action);
    self.consent = null;
    self.invalidateScope();
}

/// What the input row would show now, without selecting a frame.
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
    // Start at its end, so the same rows down as up return to live output.
    self.enterTranscript(false);
    self.browsing.top = null;
    self.copy_shift = 0;
    self.copy_front = self.browsing.origin;
}

/// Starts an empty transcript at its top, which newer pages then fill.
pub fn beginNewer(self: *Self) void {
    std.debug.assert(self.view == .live);
    self.browsing.clear();
    self.browsing.sidenotes = self.live.sidenotes;
    self.browsing.quotes = false;
    self.browsing.width_method = self.live.width_method;
    self.enterTranscript(true);
    self.browsing.top = .{};
    self.copy_shift = null;
}

fn enterTranscript(self: *Self, apart: bool) void {
    // Moves apply to the transcript's own height, which its heading and the
    // absent calls make differ from the live view's.
    self.height = self.browsing_height;
    self.ends_apart = apart;
    self.overscroll = 0;
    self.view = .transcript;
    self.invalidateScope();
}

/// Appends one newer page, rendered to `file`, below the transcript without
/// moving the rows in view. Returns false when text no frame showed left
/// the transcript's front to make room.
pub fn appendFile(self: *Self, io: std.Io, file: std.Io.File) !bool {
    std.debug.assert(self.view == .transcript);
    const document = &self.browsing;
    try document.prepare();
    const first = document.first(self.textLayout(), self.height);
    const top = document.origin + first.offset;
    const unshown = document.origin + document.length;
    const length = (try file.stat(io)).size;
    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < length) {
        const wanted: usize = @intCast(@min(buffer.len, length - offset));
        if (try file.readPositionalAll(io, buffer[0..wanted], offset) != wanted) return error.TruncatedDisplayScratch;
        try document.append(buffer[0..wanted]);
        offset += wanted;
    }
    try document.prepare();
    document.top = if (top >= document.origin) .{ .offset = @intCast(top - document.origin), .row = first.row } else .{};
    return document.origin <= unshown;
}

/// The transcript shows its last row.
pub fn transcriptAtBottom(self: *const Self) bool {
    return self.view == .transcript and self.browsing.atBottom(self.textLayout(), self.height);
}

/// Whether the latest live view shows the row at absolute live offset `at`.
pub fn liveShows(self: *const Self, at: u64) bool {
    if (at < self.live.origin) return false;
    const first = self.live.first(self.textLayout(), self.height);
    return (Position{ .offset = @intCast(at - self.live.origin) }).order(first) != .lt;
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
    return (end and self.ends_apart) or (!self.ends_apart and document.atBottom(self.textLayout(), self.height));
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
    try self.prependBrowsing(&self.staging);
    const first = self.browsing.first(self.textLayout(), self.height);
    self.browsing.top = self.browsing.up(self.textLayout(), first, self.overscroll);
    self.overscroll = 0;
    return .{ .older = older, .trimmed = before + older - self.browsing.collapsed(0, self.browsing.text().len).count };
}

/// Places `older` above the transcript, keeping the copy's live offsets.
fn prependBrowsing(self: *Self, older: anytype) !void {
    try self.browsing.prepare();
    const front = self.browsing.origin;
    if (try self.browsing.prepend(older, self.textLayout(), self.height)) self.ends_apart = true;
    // The text that started at `front` now starts after the older text.
    if (self.copy_shift) |*shift| shift.* += @as(i64, @intCast(front)) - @as(i64, @intCast(self.browsing.origin + older.length));
}

/// The live offsets of the rows the latest transcript frame draws, from
/// its top row to the first row it leaves undrawn, for a transcript copied
/// from live output; null otherwise.
pub fn transcriptLiveSpan(self: *Self) !?struct { start: u64, end: u64 } {
    if (self.view != .transcript) return null;
    const shift = self.copy_shift orelse return null;
    const document = &self.browsing;
    try document.prepare();
    const layout = self.textLayout();
    const first = document.first(layout, self.height);
    // A partly drawn line is not drawn.
    const start = if (first.row == 0) first.offset else document.nextLine(first.offset) orelse document.text().len;
    const end = if (document.atBottom(layout, self.height)) document.text().len else document.down(layout, first, self.height).offset;
    // Text prepended above the copy sits before its live offsets, so only
    // the rows drawn from the copy itself map to live ones.
    const base = @as(i64, @intCast(document.origin)) + shift;
    const from = @max(base + @as(i64, @intCast(start)), @as(i64, @intCast(self.copy_front)));
    const to = base + @as(i64, @intCast(@max(start, end)));
    if (to <= from) return null;
    return .{ .start = @intCast(from), .end = @intCast(to) };
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
    try self.prependBrowsing(&marker);
    return before - self.transcriptCollapsed();
}

/// The lowest collapsed user block the latest frame drew in the live view
/// or transcript, as how many collapsed blocks follow it in that document.
/// Call right after drawing: later text moves what the frame drew.
pub fn collapsedInView(self: *Self) ?usize {
    if (self.view != .live and self.view != .transcript) return null;
    const document = self.viewed();
    const text = document.text().len;
    const next = document.measure(self.textLayout(), self.drawn.first, self.drawn.rows).next;
    // A line cut at the bottom shows its first rows, which hold the mark.
    const end = if (next.offset >= text) text else if (next.row != 0) document.lineEnd(next.offset) else next.offset;
    const last = document.collapsed(@min(self.drawn.first.offset, text), end).last orelse return null;
    return document.collapsed(last + 1, text).count;
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
/// any other view. A line typed beside it stays in the draft.
pub fn withdrawAction(self: *Self) void {
    self.consent = null;
    self.action_view = null;
    if (self.view == .action) self.view = .live;
    self.invalidateLayout();
}

/// The draft must have a cell for every cluster; the editor declines edits
/// that would not.
fn prepareDraft(self: *Self, bytes: []const u8, size: std.posix.winsize) ![]const u8 {
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

/// What a frame shows around the input: the status above the rule, and under
/// the input a notice until the next key, else the Session line. `live` is
/// what work under way is doing now: its running call's row carries the
/// clock, and any other work ends the shown text. `queued` is the newest
/// Message waiting behind the work and how many wait; the latest view shows
/// it dimmed, right above the status, when the frame has a row for it.
pub const Footer = struct {
    /// A command is running: a read Action's choice is held.
    command: bool = false,
    status: []const u8 = "",
    notice: []const u8 = "",
    session: ?SessionLine = null,
    live: ?work_line.Line = null,
    queued: ?Queued = null,

    /// While its row draws, the frame shows `status` in place of the
    /// footer's: the row confirms a send that status says `Sent` of.
    pub const Queued = struct { waiting: queued_line.Waiting, status: []const u8 };
};

/// The Session line's facts, and the caller's copy of the line it last
/// wrote, which it writes again when the facts change.
pub const SessionLine = struct { facts: session_line.Facts, shown: *session_line.Shown };

/// Adopts the frame's geometry, selects its projection, encodes it and
/// returns its receipt only after every byte is written and flushed.
/// Rendering credits nothing; `presented` does.
pub fn render(self: *Self, out: *std.Io.Writer, size: std.posix.winsize, bytes: []const u8, cursor: usize, footer: Footer, live: *const View.Live) !Delivered {
    const status = footer.status;
    // The terminal reports untrusted geometry. Cell allocations (including
    // replacement grids during resize) share the same bounded allocator.
    try Frame.validateGeometry(size.col, size.row);
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
    // Selected after the geometry: a resize restarts reading, and the frame
    // says so. The choice takes the input's row in place of the draft, which
    // it keeps.
    const selector = self.select(footer.command).row == .selector;
    const draft = try self.prepareDraft(if (selector) "" else bytes, size);
    const window = self.vx.window();
    window.clear();
    var call_storage: [3][View.Live.line_bytes]u8 = undefined;
    var calls: [3][]const u8 = undefined;
    const selected = self.view != .live;
    // Calls keep their places. While the work is a running Bash call, that
    // call's own row carries the clock; the live line says it only when the
    // row is not shown.
    var clock: [work_line.max_clock_bytes]u8 = undefined;
    const running: ?work_line.Call = if (footer.live) |line| line.call else null;
    var clock_call: ?usize = null;
    if (!selected) for (live.entries[0..live.count], 0..) |entry, index| {
        const named = if (running) |call| entry.operation == call.operation and entry.ordinal == call.ordinal else false;
        if (named) clock_call = index;
        calls[index] = try live.line(index, &call_storage[index], if (named) work_line.clockText(&clock, footer.live.?.clock, .conversation, .unicode) else "");
    };
    const document = self.viewed();
    var layout: Frame = undefined;
    try layout.plan(document, .{
        .width = size.col,
        .height = size.row,
        .method = self.vx.caps.unicode,
        .draft = draft,
        .cursor = if (selector) 0 else cursor,
        .draft_anchor = if (selector) 0 else self.draft_anchor,
        .status = status,
        .notice = footer.notice,
        .calls = calls[0..if (selected) 0 else live.count],
        .total_calls = live.total,
        .live = footer.live != null,
        .clock_call = clock_call,
        .queued = if (selected) null else if (footer.queued) |queued| queued.status else null,
        .selected = selected,
        .action_visible = self.actionVisible(),
        .action_pending = self.action_view != null,
        .action_seen = self.action_seen,
        .preview_complete = self.preview_complete,
    });
    self.height = layout.height;
    if (!selector) self.draft_anchor = layout.draft_lines[0].start;
    self.browsing_height = layout.browsing_height;
    self.drawn = .{ .first = layout.first, .rows = @intCast(layout.document_rows) };
    _ = layout.heading.draw(window.child(.{ .height = layout.navigation_height }), .{}, true, self.colour, self.style(.quiet));
    _ = document.draw(window.child(.{ .y_off = layout.navigation_height + layout.document_offset, .height = @intCast(layout.document_rows) }), layout.first, true, self.colour, .{});
    if (layout.document_offset != 0) {
        // The conversation's latest rows fill the rows above a whole Action;
        // they are context, never read rows of the Action.
        try self.live.prepare();
        _ = self.live.draw(window.child(.{ .y_off = layout.navigation_height, .height = layout.document_offset }), self.live.bottom(self.textLayout(), layout.document_offset), true, self.colour, .{});
    }
    const failure = std.mem.startsWith(u8, status, "!") or std.mem.startsWith(u8, status, "Rejected");
    _ = layout.status.draw(window.child(.{ .y_off = layout.status_row, .height = layout.status_height }), .{}, true, self.colour, self.style(if (selector) .attention else .quiet));
    // Only a failure's own line is marked; standing notices below stay quiet.
    if (failure and !selector) _ = layout.status.draw(window.child(.{ .y_off = layout.status_row, .height = layout.status.lineRows(self.textLayout(), 0) }), .{}, true, self.colour, self.style(.failure));
    var call_row = layout.calls_row;
    for (0..layout.used) |index| {
        _ = layout.calls[index].draw(window.child(.{ .y_off = call_row, .height = layout.call_heights[index] }), .{}, true, self.colour, self.style(live.style(index)));
        call_row += layout.call_heights[index];
    }
    _ = layout.heading.draw(window.child(.{ .y_off = call_row, .height = layout.overflow_height }), .{}, true, self.colour, self.style(.quiet));
    // Cells borrow the clock's bytes until the frame is rendered.
    var live_clock: [work_line.max_clock_bytes]u8 = undefined;
    if (layout.live_height != 0) self.drawLive(window.child(.{ .y_off = layout.live_row, .height = 1 }), size.col, footer.live.?, &live_clock);
    // Cells borrow the row's bytes until the frame is rendered.
    var queued_text: [queued_line.text_capacity]u8 = undefined;
    var queued_label: [queued_line.label_capacity]u8 = undefined;
    if (layout.queued_height != 0) {
        const queued = footer.queued.?.waiting;
        const row = queued_line.row(&queued_text, &queued_label, queued.line, queued.count, size.col, self.vx.caps.unicode);
        const cells = window.child(.{ .y_off = layout.queued_row, .height = 1 });
        _ = cells.printSegment(.{ .text = row.text, .style = self.style(.quiet) }, .{ .wrap = .none });
        _ = cells.child(.{ .x_off = @intCast(row.column) }).printSegment(.{ .text = row.label, .style = self.style(.quiet) }, .{ .wrap = .none });
    }
    // Cells borrow the rule's label until the frame is rendered too.
    var rule_label: [64]u8 = undefined;
    if (layout.rule_height != 0) try self.drawRule(window.child(.{ .y_off = layout.draft_top - 1, .height = 1 }), size.col, layout.draft, &rule_label);
    if (selector) self.drawChoice(window.child(.{ .y_off = layout.draft_top, .height = 1 }), size.col) else {
        // Continuation rows align under the text; only the draft's first
        // line has a glyph. Each shown line is printed whole: draft_layout
        // already broke it to fit.
        for (layout.draft_lines[0..layout.draft.rows], 0..) |line, index| {
            const row = layout.draft_top + @as(u16, @intCast(index));
            const first = layout.draft.first + index == 0;
            _ = window.child(.{ .y_off = row, .height = 1, .width = 2 }).printSegment(.{ .text = if (first) "› " else "  ", .style = self.style(.user) }, .{});
            _ = window.child(.{ .x_off = 2, .y_off = row, .height = 1 }).print(&.{.{ .text = draft[line.start..line.end] }}, .{ .wrap = .none });
        }
    }
    const line_row = size.row - layout.line_height;
    // Whether the line under the input says Enter denies: only then does a
    // reason's frame offer the denial.
    var says_deny = false;
    if (footer.notice.len != 0) {
        _ = layout.notice.draw(window.child(.{ .y_off = line_row, .height = layout.line_height }), .{}, true, self.colour, self.style(if (std.mem.startsWith(u8, footer.notice, "!")) .failure else .normal));
        says_deny = std.mem.indexOf(u8, footer.notice, deny_words) != null;
    } else if (layout.line_height != 0) {
        // While an Action waits, the line under the input says how to decide it.
        const text = if (self.selected.approval != .absent)
            approvalHint(self.selected.approval, self.actionVisible(), size.col, self.vx.caps.unicode)
        else if (footer.session) |line| line.shown.text(line.facts, size.col, self.vx.caps.unicode) else "";
        _ = window.child(.{ .y_off = line_row, .height = 1 }).printSegment(.{ .text = text, .style = self.style(.quiet) }, .{ .wrap = .none });
        says_deny = self.selected.approval == .reason and text.len != 0;
    }
    if (selector) window.hideCursor() else window.showCursor(layout.caret_column, layout.caret_row);
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
        .action = if (!self.actionVisible()) null else if (self.consent) |pending| pending.action else null,
        .shown = if (self.selected.approval == .reason and !says_deny) null else ConsentPolicy.offered(self.consent, self.selected.approval),
        .inputs = self.inputs,
        .first = layout.first,
        .next = layout.action_seen,
    };
    try out.writeAll(frame.written());
    try out.flush();
    return .{ .frame = self.frames };
}

/// The input row while an Action waits: Allow once and Deny with the
/// highlighted option in reverse video, or why there is no choice yet.
fn drawChoice(self: *const Self, window: vaxis.Window, width: u16) void {
    const waiting: []const u8 = switch (self.selected.approval) {
        .reading => "  PgDn reads the rest",
        .held => "  Command running…",
        else => "",
    };
    if (waiting.len != 0) {
        _ = window.printSegment(.{ .text = waiting, .style = self.style(.quiet) }, .{ .wrap = .none });
        return;
    }
    const row = Frame.choice(width);
    for (row.labels, row.columns, [_]ConsentPolicy.Choice{ .allow_once, .deny }) |label, column, option| {
        const chosen = self.consent.?.highlight == option;
        var look = self.style(if (chosen) .attention else .normal);
        look.reverse = chosen;
        var cells = window.child(.{ .x_off = column });
        for ([_][]const u8{ if (chosen) "› " else "  ", label, " " }) |piece| {
            const end = cells.printSegment(.{ .text = piece, .style = look }, .{ .wrap = .none });
            cells = cells.child(.{ .x_off = end.col });
        }
    }
}

/// The line under the input while an Action waits, shortened to `width`
/// cells or left empty.
fn approvalHint(approval: ConsentPolicy.Approval, action_visible: bool, width: u16, method: vaxis.gwidth.Method) []const u8 {
    const forms: []const []const u8 = switch (approval) {
        .absent => &.{},
        .choice => &.{ "←→ choose · enter confirms", "←→ · enter" },
        .reading => &.{ "PgDn reads the rest · then choose", "PgDn · then choose" },
        .held => &.{ "the choice returns when it ends", "then the choice" },
        .reason => &.{ deny_words ++ " · esc back to the choice", "enter denies and sends this · esc choice", "enter denies · esc choice" },
        .paused => if (action_visible) &.{ "Approval paused · Esc returns to the choice", "Esc · choice" } else &.{ "Approval paused · Esc returns to Action", "Esc · Action" },
        .preview => &.{ "Approval disabled · /help for exact shell commands", "Approval disabled" },
    };
    for (forms) |form| if (session_line.cells(form, method) <= width) return form;
    return "";
}

test "the line under a waiting Action shortens to its width or says nothing" {
    for (std.enums.values(ConsentPolicy.Approval)) |approval| for ([_]bool{ false, true }) |visible| {
        const full = approvalHint(approval, visible, 2048, .unicode);
        try std.testing.expectEqual(approval == .absent, full.len == 0);
        var previous: usize = 0;
        for (1..80) |columns| {
            const text = approvalHint(approval, visible, @intCast(columns), .unicode);
            const cells = session_line.cells(text, .unicode);
            try std.testing.expect(cells <= columns);
            // A wider line never says less.
            try std.testing.expect(cells >= previous);
            previous = cells;
        }
        try std.testing.expectEqualStrings(full, approvalHint(approval, visible, @intCast(session_line.cells(full, .unicode)), .unicode));
    };
}

/// The live line: its mark and words in the line's tone, then its clock,
/// quiet.
fn drawLive(self: *const Self, window: vaxis.Window, width: u16, line: work_line.Line, clock: *[work_line.max_clock_bytes]u8) void {
    const fitted = work_line.fit(clock, line, width, self.vx.caps.unicode);
    const words: View.Style = switch (line.tone) {
        .normal => .normal,
        .quiet => .quiet,
        .attention => .attention,
    };
    var column: u16 = 0;
    for ([_]struct { []const u8, View.Style }{
        .{ fitted.mark, if (line.tone == .attention) .attention else .quiet },
        .{ if (fitted.mark.len == 0) "" else " ", .normal },
        .{ fitted.words, words },
        .{ if (fitted.cut) session_line.ellipsis else "", words },
        .{ fitted.clock, .quiet },
    }) |piece| {
        if (piece[0].len == 0) continue;
        const end = window.child(.{ .x_off = column }).printSegment(.{ .text = piece[0], .style = self.style(piece[1]) }, .{ .wrap = .none });
        column += end.col;
    }
}

/// The rule above the input. It names the draft lines hidden above or
/// below the input when there are any.
fn drawRule(self: *const Self, window: vaxis.Window, width: u16, draft: draft_layout.View, buffer: *[64]u8) !void {
    const label = draft_layout.label(buffer, draft, .{ .up = "↑", .down = "↓", .dot = "·" });
    window.fill(.{ .char = .{ .grapheme = "─", .width = 1 }, .style = self.style(.quiet) });
    const column = draft_layout.labelColumn(vaxis.gwidth.gwidth(label, self.vx.caps.unicode), width) orelse return;
    _ = window.child(.{ .x_off = @intCast(column) }).printSegment(.{ .text = label, .style = self.style(.quiet) }, .{});
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

var test_words: [work_line.max_words_bytes]u8 = undefined;

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
    _ = try screen.render(&out.writer, wide, &long, long.len, .{}, &.{});
    std.debug.print("renderer allocation wide5000X: retained={d}, peak={d} bytes (page charged, not RSS)\n", .{ screen.memory.used, screen.memory.peak });
    try screen.append(&long);
    try screen.append("\n");
    screen.memory.peak = screen.memory.used;
    _ = try screen.render(&out.writer, narrow, "", 0, .{}, &.{});
    std.debug.print("renderer allocation resize2048→80: retained={d}, peak={d} bytes\n", .{ screen.memory.used, screen.memory.peak });
    var draft: [4097]u8 = undefined;
    draft[0] = 'a';
    for (0..2048) |index| @memcpy(draft[1 + index * 2 ..][0..2], "\u{301}");
    for (0..2049) |marks| {
        const text = draft[0 .. 1 + marks * 2];
        _ = try screen.render(&out.writer, narrow, text, text.len, .{}, &.{});
    }
    const window = screen.vx.window();
    try std.testing.expectEqualStrings(&draft, window.readCell(2, screen.vx.screen.cursor.row).?.char.grapheme);
    try std.testing.expectError(error.TerminalTooLarge, screen.render(&out.writer, .{ .row = 135, .col = 480, .xpixel = 0, .ypixel = 0 }, "", 0, .{}, &.{}));
    screen.colour = true;
    screen.vx.caps.no_color = false;
    for ([_][]const u8{ "中", "é", "🐄", "\x1b[1m\x1b[3m\x1b[4m\x1b[91mX\x1b[0mX" }) |pattern| {
        screen.live.clear();
        const cells: usize = if (std.mem.indexOf(u8, pattern, "\x1b") != null or std.mem.eql(u8, pattern, "中") or std.mem.eql(u8, pattern, "🐄")) 2 else 1;
        for (0..Frame.max_cells / cells) |_| try screen.append(pattern);
        for ([_]std.posix.winsize{ .{ .row = 192, .col = 256, .xpixel = 0, .ypixel = 0 }, wide }) |size| {
            screen.memory.peak = screen.memory.used;
            _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
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

test "the input keeps the bottom rows under a rule while content starts at the top" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, true);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const size: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    var shown: session_line.Shown = .{};
    const session: SessionLine = .{ .facts = .{ .name = "Fix flaky store tests", .model = "gpt-6.1-sol", .effort = .low, .left = 69 }, .shown = &shown };
    _ = try screen.render(&out.writer, size, "", 0, .{ .session = session }, &.{});
    const window = screen.vx.window();
    var storage: [160]u8 = undefined;
    try std.testing.expectEqualStrings("─", window.readCell(0, 21).?.char.grapheme);
    try std.testing.expectEqualStrings("─", window.readCell(79, 21).?.char.grapheme);
    try std.testing.expectEqualStrings("›", window.readCell(0, 22).?.char.grapheme);
    try std.testing.expectEqualStrings("Fix flaky store tests · gpt-6.1-sol · low · 69% left", rowText(screen, 23, &storage));
    try std.testing.expectEqual(vaxis.Color{ .index = 8 }, window.readCell(0, 23).?.style.fg);
    try screen.append("› inspect\n  Done.\n");
    _ = try screen.render(&out.writer, size, "next\nline", 9, .{ .session = session }, &.{});
    try std.testing.expectEqualStrings("›", window.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("D", window.readCell(2, 1).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", window.readCell(0, 2).?.char.grapheme);
    // The draft grows upward: the rule moves up, the line stays last.
    try std.testing.expectEqualStrings("─", window.readCell(0, 20).?.char.grapheme);
    try std.testing.expectEqualStrings("›", window.readCell(0, 21).?.char.grapheme);
    // A draft continuation has no glyph; its text aligns under the first row.
    try std.testing.expectEqualStrings(" ", window.readCell(0, 22).?.char.grapheme);
    try std.testing.expectEqualStrings("l", window.readCell(2, 22).?.char.grapheme);
    try std.testing.expectEqualStrings("F", window.readCell(0, 23).?.char.grapheme);
    // Status sits directly above the rule.
    _ = try screen.render(&out.writer, size, "next", 4, .{ .status = "Sending…", .session = session }, &.{});
    try std.testing.expectEqualStrings("S", window.readCell(0, 20).?.char.grapheme);
    try std.testing.expectEqual(vaxis.Color{ .index = 8 }, window.readCell(0, 20).?.style.fg);
    try std.testing.expectEqualStrings("─", window.readCell(0, 21).?.char.grapheme);
    try std.testing.expectEqualStrings("›", window.readCell(0, 22).?.char.grapheme);
    // A notice takes the line until the next key, in the failure colour
    // when it reports one; the input does not move.
    for ([_][]const u8{ "Work continues while you compose.", "! Unknown command /x · /help" }, [_]vaxis.Color{ .default, .{ .index = 9 } }) |notice, colour| {
        _ = try screen.render(&out.writer, size, "next", 4, .{ .status = "Sending…", .notice = notice, .session = session }, &.{});
        try std.testing.expectEqualStrings(notice, rowText(screen, 23, &storage));
        try std.testing.expectEqual(colour, window.readCell(0, 23).?.style.fg);
        try std.testing.expectEqualStrings("›", window.readCell(0, 22).?.char.grapheme);
        try std.testing.expectEqualStrings("S", window.readCell(0, 20).?.char.grapheme);
    }
    for ([_]u16{ 51, 40 }, [_][]const u8{ "Fix flaky store tests · gpt-6.1-sol · 69% left", "Fix flaky stor… · gpt-6.1-sol · 69% left" }) |columns, expected| {
        _ = try screen.render(&out.writer, .{ .row = 24, .col = columns, .xpixel = 0, .ypixel = 0 }, "", 0, .{ .session = session }, &.{});
        try std.testing.expectEqualStrings(expected, rowText(screen, 23, &storage));
    }
}

test "a draft past its cap scrolls inside the input and the rule counts what it hides" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const size: std.posix.winsize = .{ .row = 40, .col = 40, .xpixel = 0, .ypixel = 0 };
    // Thirteen lines: ten show, three hide above the caret at the end.
    const draft = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13";
    _ = try screen.render(&out.writer, size, draft, draft.len, .{}, &.{});
    var storage: [160]u8 = undefined;
    try std.testing.expectEqualStrings("──────────── ↑ 3 more lines ────────────", rowText(screen, 28, &storage));
    try std.testing.expectEqualStrings("  4", rowText(screen, 29, &storage));
    try std.testing.expectEqualStrings("  13", rowText(screen, 38, &storage));
    // Moving the caret up inside the shown lines keeps them; above them,
    // the input scrolls by one row and the rule counts both sides.
    _ = try screen.render(&out.writer, size, draft, 6, .{}, &.{});
    try std.testing.expectEqualStrings("  4", rowText(screen, 29, &storage));
    _ = try screen.render(&out.writer, size, draft, 4, .{}, &.{});
    try std.testing.expectEqualStrings("───────── ↑ 2 · ↓ 1 more lines ─────────", rowText(screen, 28, &storage));
    try std.testing.expectEqualStrings("  3", rowText(screen, 29, &storage));
    _ = try screen.render(&out.writer, size, draft, 0, .{}, &.{});
    try std.testing.expectEqualStrings("──────────── ↓ 3 more lines ────────────", rowText(screen, 28, &storage));
    try std.testing.expectEqualStrings("› 1", rowText(screen, 29, &storage));
}

test "the transcript fills every row above the rule" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const size: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    for ([_]usize{ 21, 22, 23 }) |rows| {
        for ([_]bool{ false, true }) |trailing_newline| {
            screen.live.clear();
            for (0..rows) |row| {
                var bytes: [16]u8 = undefined;
                const text = try std.fmt.bufPrint(&bytes, "row{d:0>2}{s}", .{ row, if (row + 1 < rows or trailing_newline) "\n" else "" });
                try screen.append(text);
            }
            _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
            const window = screen.vx.window();
            // Twenty-one rows sit above the rule, the input row and the line.
            const first = rows -| 21;
            for (first..rows, 0..) |row, y| {
                var bytes: [16]u8 = undefined;
                const expected = try std.fmt.bufPrint(&bytes, "row{d:0>2}", .{row});
                for (expected, 0..) |byte, x| try std.testing.expectEqualStrings(&.{byte}, window.readCell(@intCast(x), @intCast(y)).?.char.grapheme);
            }
            try std.testing.expectEqualStrings("›", window.readCell(0, 22).?.char.grapheme);
            try screen.beginTranscript(0);
            try std.testing.expect(!screen.browse(false, true));
            _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
            // The browsing heading takes a row; the first row stays reachable.
            try std.testing.expectEqualStrings("B", window.readCell(0, 0).?.char.grapheme);
            try std.testing.expectEqualStrings("r", window.readCell(0, 1).?.char.grapheme);
            try std.testing.expectEqualStrings("0", window.readCell(4, 1).?.char.grapheme);
            // Paging past the transcript's end returns to live output.
            try std.testing.expect(screen.browse(true, true));
            try screen.latest();
            try std.testing.expectEqual(ViewKind.live, screen.view);
            _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
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
    _ = try screen.render(&out.writer, size, "", 0, .{ .status = "1234567中Z" }, &live);
    const window = screen.vx.window();
    // Two status rows sit right above the rule on row 9.
    try std.testing.expectEqualStrings("7", window.readCell(6, 7).?.char.grapheme);
    try std.testing.expectEqualStrings("中", window.readCell(0, 8).?.char.grapheme);
    try std.testing.expectEqualStrings("Z", window.readCell(2, 8).?.char.grapheme);
    live.count = 1;
    live.total = 1;
    live.entries[0] = .{ .operation = 7, .ordinal = 9, .presentation = .{ .description = .{}, .code = .unresolved, .publication_position = null } };
    try live.entries[0].presentation.description.?.set("12345中Z");
    _ = try screen.render(&out.writer, size, "", 0, .{ .status = "Idle" }, &live);
    // The call follows the empty conversation from the top; the status
    // stays right above the rule on row 9. The continuation aligns under
    // the call's text, after its glyph.
    try std.testing.expectEqualStrings("5", window.readCell(6, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("中", window.readCell(2, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("Z", window.readCell(4, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("I", window.readCell(0, 8).?.char.grapheme);
    _ = try screen.render(&out.writer, size, "", 0, .{ .status = "́Z" }, &live);
    try std.testing.expectEqualStrings("\\", window.readCell(0, 8).?.char.grapheme);
    try std.testing.expectEqualStrings("中", window.readCell(2, 1).?.char.grapheme);
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
    _ = try screen.render(&out.writer, .{ .row = 3, .col = 24, .xpixel = 0, .ypixel = 0 }, "", 0, .{ .status = "Idle" }, &live);
    const window = screen.vx.window();
    try std.testing.expectEqualStrings("+", window.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("/", window.readCell(7, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("I", window.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("›", window.readCell(0, 2).?.char.grapheme);
    // Work under way gives up its line rather than the frame.
    const waiting: protocol.WorkState = .{ .working = .{ .since = 1 } };
    _ = try screen.render(&out.writer, .{ .row = 3, .col = 24, .xpixel = 0, .ypixel = 0 }, "", 0, .{ .status = "Idle", .live = work_line.of(&test_words, &waiting, null, 2_000) }, &live);
    try std.testing.expectEqualStrings("+", window.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("I", window.readCell(0, 1).?.char.grapheme);
    try std.testing.expectError(error.TerminalTooSmall, screen.render(&out.writer, .{ .row = 2, .col = 24, .xpixel = 0, .ypixel = 0 }, "", 0, .{ .status = "Idle" }, &live));
    // The choice's input row needs the same rows the draft does.
    var action = try ActionFixture.init(1);
    defer action.deinit();
    try screen.adopt(std.testing.io, action.file, 1, true);
    try std.testing.expectError(error.TerminalTooSmall, screen.render(&out.writer, .{ .row = 2, .col = 12, .xpixel = 0, .ypixel = 0 }, "", 0, .{ .command = true, .status = "? Delete\n! Original retained" }, &.{}));
    try std.testing.expectEqual(ConsentPolicy.Row.selector, screen.selected.row);
    screen.withdrawAction();
    var calls: View.Live = .{ .count = 3, .total = 4 };
    for ([_][]const u8{ "Wait for bypass café", "Inspect application settings and report configuration errors before applying changes to local assets", "Wait for bypass café" }, 0..) |label, index| {
        calls.entries[index] = .{ .operation = 7, .ordinal = index, .presentation = .{ .description = .{}, .code = if (index == 1) .failed else .unresolved, .publication_position = null } };
        try calls.entries[index].presentation.description.?.set(label);
    }
    const before = out.written().len;
    screen.vx.queueRefresh();
    _ = try screen.render(&out.writer, .{ .row = 6, .col = 32, .xpixel = 0, .ypixel = 0 }, "live cafXé!", "live cafX".len, .{ .status = "Sending…\nCommand still running." }, &calls);
    try std.testing.expect(std.mem.indexOf(u8, out.written()[before..], "+3 more calls") != null);
}

test "the running call's row carries the clock, in its place, and other work ends the conversation" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try screen.append("› run the store tests\n");
    var calls: View.Live = .{ .count = 3, .total = 3 };
    // Two running calls share a description; ordinals tell them apart.
    for ([_][]const u8{ "Read the failing test output", "Run zig build", "Run zig build" }, [_]protocol.ToolPresentation.Code{ .succeeded, .unresolved, .unresolved }, 0..) |label, code, index| {
        calls.entries[index] = .{ .operation = 7, .ordinal = index, .presentation = .{ .description = .{}, .code = code, .publication_position = null } };
        try calls.entries[index].presentation.description.?.set(label);
    }
    const size: std.posix.winsize = .{ .row = 12, .col = 52, .xpixel = 0, .ypixel = 0 };
    var buffer: [256]u8 = undefined;
    for ([_]u64{ 1, 2 }, [_][2][]const u8{ .{ "• Run zig build · 42s", "• Run zig build" }, .{ "• Run zig build", "• Run zig build · 42s" } }) |ordinal, rows| {
        const state: protocol.WorkState = .{ .bash = .{ .since = 100, .call = ordinal, .description = calls.entries[ordinal].presentation.description, .running = 2, .approvals = 0 } };
        _ = try screen.render(&out.writer, size, "", 0, .{ .live = work_line.of(&test_words, &state, 7, 142_000) }, &calls);
        try std.testing.expectEqualStrings("› run the store tests", rowText(screen, 0, &buffer));
        try std.testing.expectEqualStrings("✓ Read the failing test output", rowText(screen, 1, &buffer));
        try std.testing.expectEqualStrings(rows[0], rowText(screen, 2, &buffer));
        try std.testing.expectEqualStrings(rows[1], rowText(screen, 3, &buffer));
        try std.testing.expectEqualStrings("", rowText(screen, 4, &buffer));
        // A call of another Operation is not the one running.
        _ = try screen.render(&out.writer, size, "", 0, .{ .live = work_line.of(&test_words, &state, 8, 142_000) }, &calls);
        try std.testing.expectEqualStrings("• Run zig build", rowText(screen, 2, &buffer));
        try std.testing.expectEqualStrings("• Run zig build", rowText(screen, 3, &buffer));
        try std.testing.expectEqualStrings("• Run zig build · 42s", rowText(screen, 4, &buffer));
    }
    // Other work under way is the conversation's last line, then goes.
    const waiting: protocol.WorkState = .{ .working = .{ .since = 130 } };
    _ = try screen.render(&out.writer, size, "", 0, .{ .live = work_line.of(&test_words, &waiting, 7, 142_000) }, &calls);
    try std.testing.expectEqualStrings("• Run zig build", rowText(screen, 3, &buffer));
    try std.testing.expectEqualStrings("• Waiting · 12s", rowText(screen, 4, &buffer));
    _ = try screen.render(&out.writer, size, "", 0, .{}, &calls);
    try std.testing.expectEqualStrings("", rowText(screen, 4, &buffer));
    // A narrow line cuts the words and keeps the clock, under the
    // conversation and calls that now wrap.
    _ = try screen.render(&out.writer, .{ .row = 12, .col = 14, .xpixel = 0, .ypixel = 0 }, "", 0, .{ .live = work_line.of(&test_words, &waiting, 7, 142_000) }, &calls);
    try std.testing.expectEqualStrings("  build", rowText(screen, 7, &buffer));
    try std.testing.expectEqualStrings("• Waiti… · 12s", rowText(screen, 8, &buffer));
    try std.testing.expectEqualStrings("─", screen.vx.window().readCell(0, 9).?.char.grapheme);
    // Stopping says so quietly, with no clock.
    const stopping: protocol.WorkState = .{ .stopping = .{ .since = 130 } };
    screen.colour = true;
    _ = try screen.render(&out.writer, size, "", 0, .{ .live = work_line.of(&test_words, &stopping, 7, 142_000) }, &calls);
    try std.testing.expectEqualStrings("Stopping…", rowText(screen, 4, &buffer));
    try std.testing.expectEqual(screen.style(.quiet).fg, screen.vx.window().readCell(0, 4).?.style.fg);
    try std.testing.expect(!std.meta.eql(screen.style(.normal).fg, screen.style(.quiet).fg));
}

test "a browsed page keeps the live line above the status" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for (0..40) |index| {
        var bytes: [16]u8 = undefined;
        try screen.append(try std.fmt.bufPrint(&bytes, "row{d:0>2}\n", .{index}));
    }
    const size: std.posix.winsize = .{ .row = 12, .col = 40, .xpixel = 0, .ypixel = 0 };
    var calls: View.Live = .{ .count = 1, .total = 1 };
    calls.entries[0] = .{ .operation = 7, .ordinal = 0, .presentation = .{ .description = .{}, .code = .unresolved, .publication_position = null } };
    try calls.entries[0].presentation.description.?.set("Run zig build");
    const state: protocol.WorkState = .{ .bash = .{ .since = 100, .call = 0, .description = calls.entries[0].presentation.description, .running = 1, .approvals = 0 } };
    const footer: Footer = .{ .status = "Opening…", .live = work_line.of(&test_words, &state, 7, 142_000) };
    _ = try screen.render(&out.writer, size, "", 0, footer, &calls);
    try screen.beginTranscript(0);
    _ = screen.browse(false, true);
    _ = try screen.render(&out.writer, size, "", 0, footer, &calls);
    var buffer: [256]u8 = undefined;
    // Calls are not drawn on a page, so the line says the running call.
    try std.testing.expectEqualStrings("• Run zig build · 42s", rowText(screen, 7, &buffer));
    try std.testing.expectEqualStrings("Opening…", rowText(screen, 8, &buffer));
    // The page moves by the rows it shows.
    try std.testing.expectEqual(screen.height, screen.browsing_height);
}

test "a queued Message sits dimmed right above the status, in the latest view only" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for (0..40) |index| {
        var bytes: [16]u8 = undefined;
        try screen.append(try std.fmt.bufPrint(&bytes, "row{d:0>2}\n", .{index}));
    }
    const size: std.posix.winsize = .{ .row = 12, .col = 40, .xpixel = 0, .ypixel = 0 };
    const calls: View.Live = .{};
    // The row confirms the send, so the status no longer says Sent.
    const footer: Footer = .{ .status = "Sent", .queued = .{ .waiting = .{ .line = "also check the history scratch cache", .count = 2 }, .status = "" } };
    _ = try screen.render(&out.writer, size, "", 0, footer, &calls);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("row39", rowText(screen, 7, &buffer));
    try std.testing.expectEqualStrings("› also check the history scrat… 2 queued", rowText(screen, 8, &buffer));
    try std.testing.expect(!screenHas(screen, "Sent", &buffer));
    for ([_]u16{ 0, 32 }) |column| try std.testing.expectEqual(screen.style(.quiet).fg, screen.vx.window().readCell(column, 8).?.style.fg);
    // A short terminal with a call, the live line and a multiline draft has
    // no row for it: the status says Sent instead.
    var running: View.Live = .{ .count = 1, .total = 1 };
    running.entries[0] = .{ .operation = 7, .ordinal = 0, .presentation = .{ .description = .{}, .code = .unresolved, .publication_position = null } };
    try running.entries[0].presentation.description.?.set("Run zig build");
    const state: protocol.WorkState = .{ .working = .{ .since = 100 } };
    var working = footer;
    working.live = work_line.of(&test_words, &state, null, 142_000);
    const short: std.posix.winsize = .{ .row = 6, .col = 40, .xpixel = 0, .ypixel = 0 };
    const draft = "one\ntwo\nthree";
    _ = try screen.render(&out.writer, short, draft, draft.len, working, &running);
    try std.testing.expect(!screenHas(screen, "queued", &buffer));
    try std.testing.expect(screenHas(screen, "Sent", &buffer));
    try std.testing.expect(screenHas(screen, "Run zig build", &buffer));
    // With a one-line draft it has the row, and Sent goes.
    _ = try screen.render(&out.writer, short, "one", 3, working, &running);
    try std.testing.expect(screenHas(screen, "queued", &buffer));
    try std.testing.expect(!screenHas(screen, "Sent", &buffer));
    // A browsed page shows the conversation down to the status instead,
    // and Sent with it.
    try screen.beginTranscript(0);
    _ = screen.browse(false, true);
    _ = try screen.render(&out.writer, size, "", 0, footer, &calls);
    try std.testing.expect(!screenHas(screen, "queued", &buffer));
    try std.testing.expect(screenHas(screen, "Sent", &buffer));
}

fn screenHas(screen: *Self, text: []const u8, buffer: *[256]u8) bool {
    for (0..screen.vx.screen.height) |row| if (std.mem.indexOf(u8, rowText(screen, @intCast(row), buffer), text) != null) return true;
    return false;
}

test "a description's controls read escaped alike on its call row and on the live line" {
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(std.testing.io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try screen.append("row\n");
    const size: std.posix.winsize = .{ .row = 12, .col = 40, .xpixel = 0, .ypixel = 0 };
    var calls: View.Live = .{ .count = 1, .total = 1 };
    calls.entries[0] = .{ .operation = 7, .ordinal = 0, .presentation = .{ .description = .{}, .code = .unresolved, .publication_position = null } };
    try calls.entries[0].presentation.description.?.set("Run\t\x1b[2J\u{202e}tests");
    const shown = "• Run\\t\\x1b[2J\\u202etests · 42s";
    var buffer: [256]u8 = undefined;
    // On its call row.
    const state: protocol.WorkState = .{ .bash = .{ .since = 100, .call = 0, .description = calls.entries[0].presentation.description, .running = 1, .approvals = 0 } };
    _ = try screen.render(&out.writer, size, "", 0, .{ .live = work_line.of(&test_words, &state, 7, 142_000) }, &calls);
    try std.testing.expectEqualStrings(shown, rowText(screen, 1, &buffer));
    // On the live line: the call is not among the rows, as from an older
    // Host that names no call.
    const older: protocol.WorkState = .{ .bash = .{ .since = 100, .call = null, .description = calls.entries[0].presentation.description, .running = 1, .approvals = 0 } };
    _ = try screen.render(&out.writer, size, "", 0, .{ .live = work_line.of(&test_words, &older, 7, 142_000) }, &.{});
    try std.testing.expectEqualStrings(shown, rowText(screen, 1, &buffer));
    // Cut to a narrow line, the words are cut as shown, never as raw bytes.
    _ = try screen.render(&out.writer, .{ .row = 12, .col = 20, .xpixel = 0, .ypixel = 0 }, "", 0, .{ .live = work_line.of(&test_words, &older, 7, 142_000) }, &.{});
    try std.testing.expectEqualStrings("• Run\\t\\x1b[2… · 42s", rowText(screen, 1, &buffer));
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
        for ([_][]const u8{ "", "Sending…" }) |status| {
            const before = out.written().len;
            screen.vx.queueRefresh();
            _ = try screen.render(&out.writer, .{ .row = 24, .col = columns, .xpixel = 0, .ypixel = 0 }, "", 0, .{ .status = status }, &.{});
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
    _ = try screen.render(&out.writer, .{ .row = 12, .col = 80, .xpixel = 0, .ypixel = 0 }, "", 0, .{}, &.{});
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
        screen.consent = null;
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
        try screen.adopt(io, action, 5, true);
        try std.testing.expectEqualStrings(status, screen.browsing.text());
        try std.testing.expectEqual(position, screen.browsing.top);
        try std.testing.expect(!screen.actionVisible());
        try std.testing.expect(screen.preview_complete);
        try screen.latest();
        try std.testing.expect(screen.actionVisible());
        try std.testing.expectEqual(!oversized, screen.preview_complete);
        try std.testing.expect(std.mem.startsWith(u8, screen.browsing.text(), "Run Bash: exact command\n"));
        if (!oversized) {
            try screen.append("› clean the build cache\n");
            const size: std.posix.winsize = .{ .row = 12, .col = 80, .xpixel = 0, .ypixel = 0 };
            // The first frame adopts the terminal's size, which restarts reading.
            _ = try screen.render(&out.writer, size, "kept draft", 10, .{}, &.{});
            screen.action_seen = .end;
            try std.testing.expectEqual(ConsentPolicy.Projection{ .row = .selector, .approval = .choice }, screen.select(false));
            _ = screen.presented(try screen.render(&out.writer, size, "kept draft", 10, .{}, &.{}));
            try std.testing.expect(screen.promptCompleted(.empty, false, false));
            var storage: [160]u8 = undefined;
            // The conversation, then the whole Action right above the rule.
            try std.testing.expectEqualStrings("› clean the build cache", rowText(screen, 0, &storage));
            try std.testing.expectEqualStrings("", rowText(screen, 7, &storage));
            try std.testing.expectEqualStrings("Run Bash: exact command", rowText(screen, 8, &storage));
            try std.testing.expectEqualStrings("─", screen.vx.window().readCell(0, 9).?.char.grapheme);
            // The choice takes the input's row, Allow once highlighted; the
            // draft stays hidden, and the line under it says how to choose.
            try std.testing.expectEqualStrings("  › Allow once      Deny", rowText(screen, 10, &storage));
            try std.testing.expect(screen.vx.window().readCell(2, 10).?.style.reverse);
            try std.testing.expect(!screen.vx.window().readCell(18, 10).?.style.reverse);
            try std.testing.expect(!screen.vx.screen.cursor_vis);
            try std.testing.expectEqualStrings("←→ choose · enter confirms", rowText(screen, 11, &storage));
            try std.testing.expect(press(screen, .{ .pick = .deny }, size, false) == .picked);
            _ = try screen.render(&out.writer, size, "kept draft", 10, .{}, &.{});
            try std.testing.expectEqualStrings("    Allow once    › Deny", rowText(screen, 10, &storage));
            try std.testing.expect(screen.vx.window().readCell(18, 10).?.style.reverse);
        }
        screen.releaseAction();
        screen.consent = null;
        try screen.adopt(io, action, 6, true);
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

    _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
    try screen.adopt(io, action, 3, true);
    try screen.latest();
    var seen: [40]bool = @splat(false);
    var steps: usize = 0;
    while (true) : (steps += 1) {
        try std.testing.expect(steps < 100);
        _ = screen.select(false);
        _ = screen.presented(try screen.render(&out.writer, size, "", 0, .{}, &.{}));
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
    screen.consent = null;
    try screen.latest();
    for (0..30) |line| {
        var buffer: [16]u8 = undefined;
        try screen.append(try std.fmt.bufPrint(&buffer, "live {d:0>2}\n", .{line}));
    }
    // A word that ends at the edge leaves its following space undrawn.
    try screen.append("0123456789012345678901234567890123456789 next\n");
    _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
    try screen.beginTranscript(0);
    for (0..5) |_| _ = screen.browse(false, false);
    _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
    const before = try std.testing.allocator.dupe(u8, rowText(screen, 1, &storage));
    defer std.testing.allocator.free(before);
    try std.testing.expect(std.mem.startsWith(u8, before, "live "));
    try std.testing.expect(!screen.transcriptAtTop());
    const older = try tmp.dir.createFile(io, "older", .{ .read = true });
    defer older.close(io);
    try older.writePositionalAll(io, "older 1\nolder 2\nolder 3\n", 0);
    _ = try screen.prependFile(io, older);
    _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
    try std.testing.expectEqualStrings(before, rowText(screen, 1, &storage));
    // Resize keeps the first browsed line in view.
    _ = try screen.render(&out.writer, .{ .row = 10, .col = 30, .xpixel = 0, .ypixel = 0 }, "", 0, .{}, &.{});
    try std.testing.expectEqualStrings(before, rowText(screen, 1, &storage));
}

test "a transcript of live output names the live rows its frame drew, across older pages and labels" {
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
    var storage: [160]u8 = undefined;
    for (0..60) |line| {
        var buffer: [16]u8 = undefined;
        try screen.append(try std.fmt.bufPrint(&buffer, "live {d:0>2}\n", .{line}));
    }
    _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
    try std.testing.expect(try screen.transcriptLiveSpan() == null);
    try screen.beginTranscript(0);
    for (0..20) |_| _ = screen.browse(false, false);
    _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
    const drawn = (try screen.transcriptLiveSpan()).?;
    // From the top row drawn, whole rows only.
    const top = try std.testing.allocator.dupe(u8, rowText(screen, 1, &storage));
    defer std.testing.allocator.free(top);
    try std.testing.expect(std.mem.startsWith(u8, top, "live "));
    try std.testing.expect(std.mem.startsWith(u8, screen.live.text()[@intCast(drawn.start - screen.live.origin)..], top));
    try std.testing.expect(drawn.end > drawn.start and (drawn.end - drawn.start) % 8 == 0);
    try std.testing.expect(drawn.end < try screen.liveEnd());
    // Text above the copy moves its offsets, not the live rows it names.
    const older = try tmp.dir.createFile(io, "older", .{ .read = true });
    defer older.close(io);
    try older.writePositionalAll(io, "older 1\nolder 2\nolder 3\n", 0);
    _ = try screen.prependFile(io, older);
    _ = try screen.markGap();
    _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
    try std.testing.expectEqualStrings(top, rowText(screen, 1, &storage));
    const moved = (try screen.transcriptLiveSpan()).?;
    try std.testing.expectEqual(drawn.start, moved.start);
    try std.testing.expectEqual(drawn.end, moved.end);
    // A transcript of pages alone names no live rows.
    try screen.latest();
    screen.beginNewer();
    try std.testing.expect(try screen.transcriptLiveSpan() == null);
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
    _ = try screen.render(&out.writer, size, "", 0, .{ .status = "Sending…" }, &.{});
    const before = out.written().len;
    // Observation polls redraw several times a second while idle.
    _ = try screen.render(&out.writer, size, "", 0, .{ .status = "Sending…" }, &.{});
    try std.testing.expectEqual(before, out.written().len);
    _ = try screen.render(&out.writer, size, "a", 1, .{ .status = "Sending…" }, &.{});
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
            _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
            try screen.beginTranscript(0);
            for (0..2) |_| try std.testing.expect(!screen.browse(false, true));
        }
        for ([_]bool{ false, true }) |resized| {
            _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
            for (0..12) |row| {
                const text = rowText(screen, @intCast(row), &storage);
                @memcpy(expected[row][0..text.len], text);
                lengths[row] = text.len;
            }
            try screen.showMessage(io, page);
            _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
            try std.testing.expectEqualStrings("Message · 2 lines", rowText(screen, 1, &storage));
            try std.testing.expectEqualStrings("second", rowText(screen, 4, &storage));
            // A resize on the page reflows the hidden view from its first row.
            if (resized) {
                _ = try screen.render(&out.writer, narrow, "", 0, .{}, &.{});
                _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
            }
            try screen.leaveMessage();
            try std.testing.expectEqual(origin, screen.view);
            _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
            for (0..12) |row| try std.testing.expectEqualStrings(expected[row][0..lengths[row]], rowText(screen, @intCast(row), &storage));
        }
    }
    // An Action pending meanwhile is where the page returns.
    try screen.latest();
    try screen.showMessage(io, page);
    try screen.adopt(io, action.file, 7, true);
    try std.testing.expectEqual(ViewKind.message, screen.view);
    try screen.leaveMessage();
    try std.testing.expectEqual(ViewKind.action, screen.view);
}

test "Ctrl-O names the lowest collapsed block drawn, counted from the end" {
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
    // A ┄ the user typed is body text, not a block's summary.
    try screen.append("\n› " ++ View.Mark.body ++ "typed ┄ 3" ++ View.Mark.reset ++ "\n");
    // The middle block is a peer Message's line, which ends in `…`.
    for (0..3) |block| {
        var line: [64]u8 = undefined;
        try screen.append(if (block == 1)
            "\n" ++ View.Mark.summary ++ "← 9f8e7d · preview 1…" ++ View.Mark.sidenote ++ "08:00" ++ View.Mark.reset ++ "\n"
        else
            try std.fmt.bufPrint(&line, "\n› " ++ View.Mark.body ++ "preview {d}\n" ++ View.Mark.summary ++ "┄ 9 more lines" ++ View.Mark.reset ++ "\n", .{block}));
        for (0..12) |row| try screen.append(try std.fmt.bufPrint(&line, "answer {d} row {d}\n", .{ block, row }));
    }
    _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
    // The newest block scrolled off with its answer's rows below it.
    try std.testing.expectEqual(@as(?usize, null), screen.collapsedInView());
    try screen.beginTranscript(0);
    for (0..10) |_| _ = screen.browse(false, true);
    // Line by line down from the top, the lowest block drawn names each
    // block in turn, oldest (two newer follow it) first, and only those.
    var seen: [8]?usize = undefined;
    var count: usize = 0;
    while (true) {
        _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
        const index = screen.collapsedInView();
        if (count == 0 or !std.meta.eql(seen[count - 1], index)) {
            seen[count] = index;
            count += 1;
        }
        if (screen.browse(true, false)) break;
    }
    try std.testing.expectEqualSlices(?usize, &.{ 2, null, 1, null, 0, null }, seen[0..count]);
    try screen.latest();
    try screen.beginTranscript(0);
    try std.testing.expectEqual(@as(usize, 3), screen.transcriptCollapsed());
    // An older page keeps its newest block; its own count says so.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const older = try tmp.dir.createFile(io, "older", .{ .read = true });
    defer older.close(io);
    try older.writePositionalAll(io, "\n› " ++ View.Mark.summary ++ "┄" ++ View.Mark.reset ++ "\n", 0);
    const prepended = try screen.prependFile(io, older);
    try std.testing.expectEqual(Prepended{ .older = 1, .trimmed = 0 }, prepended);
    try std.testing.expectEqual(@as(usize, 4), screen.transcriptCollapsed());
    // A full transcript ending in a block: either label pushes that block
    // off the end and says so, so its Message leaves the map with it.
    for (0..2) |label| {
        try screen.latest();
        var line: [64]u8 = undefined;
        for (0..Viewport.capacity / 32) |row| try screen.append(try std.fmt.bufPrint(&line, "filler row {d:0>20}\n", .{row}));
        try screen.append("\n› " ++ View.Mark.summary ++ "┄ 9 more lines" ++ View.Mark.reset ++ "\n");
        try screen.beginTranscript(try screen.liveStart());
        try std.testing.expectEqual(@as(usize, 1), screen.transcriptCollapsed());
        try std.testing.expectEqual(@as(usize, 1), if (label == 0) try screen.markBeginning() else try screen.markGap());
        try std.testing.expectEqual(@as(usize, 0), screen.transcriptCollapsed());
    }
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
            _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
            try screen.beginTranscript(0);
            for (0..moves) |_| {
                try std.testing.expect(!screen.browse(false, false));
                _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
            }
            for (0..moves) |step| {
                try std.testing.expectEqual(step + 1 == moves, screen.browse(true, false));
                _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
            }
            try screen.latest();
        }
    }
}

test "a transcript of newer pages starts at its top, keeps its rows in view as pages join, and says when unshown text left" {
    const io = std.testing.io;
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(io, &environ, false);
    defer screen.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var storage: [64]u8 = undefined;
    const size: std.posix.winsize = .{ .row = 12, .col = 60, .xpixel = 0, .ypixel = 0 };
    try screen.append("latest row\n");
    _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const page = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer page.close(io);
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try text.writer.writeAll("── new since you looked ──\n");
    for (0..20) |index| try text.writer.print("new row {d}\n", .{index});
    try page.writePositionalAll(io, text.written(), 0);
    screen.beginNewer();
    try std.testing.expect(try screen.appendFile(io, page));
    _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
    // Under the transcript's heading.
    try std.testing.expectEqualStrings("── new since you looked ──", rowText(screen, 1, &storage));
    try std.testing.expect(!screen.transcriptAtBottom());
    while (!screen.transcriptAtBottom()) {
        try std.testing.expect(!screen.browse(true, true));
        _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
    }
    const shown = rowText(screen, 1, &storage);
    var kept: [64]u8 = undefined;
    @memcpy(kept[0..shown.len], shown);
    try page.setLength(io, 0);
    try page.writePositionalAll(io, "next row\n", 0);
    try std.testing.expect(try screen.appendFile(io, page));
    _ = try screen.render(&out.writer, size, "", 0, .{}, &.{});
    try std.testing.expectEqualStrings(kept[0..shown.len], rowText(screen, 1, &storage));
    try std.testing.expect(!screen.transcriptAtBottom());
    // Its end is not live output's: only a move past it returns there.
    while (!screen.transcriptAtBottom()) _ = screen.browse(true, true);
    try std.testing.expect(screen.browse(true, true));
    // A page larger than the view pushes out text no frame showed.
    try page.setLength(io, 0);
    for (0..Viewport.capacity / 32 + 1) |index| {
        var line: [32]u8 = undefined;
        _ = try std.fmt.bufPrint(&line, "filler row {d:0>20}\n", .{index});
        try page.writePositionalAll(io, &line, index * line.len);
    }
    try std.testing.expect(!try screen.appendFile(io, page));
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
            try screen_.adopt(std.testing.io, file, 0xb, true);
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
        try screen.adopt(io, fixture.file, 0xa, true);
        try std.testing.expectEqual(ConsentPolicy.Approval.reading, screen.select(false).approval);
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
        const result = screen.render(&held.writer, size, "", 0, .{}, &.{});
        if (case == .fails or case == .fails_finally) {
            try std.testing.expectError(error.WriteFailed, result);
            try std.testing.expectEqual(case == .fails, held.written == 0);
            try std.testing.expect(!screen.actionRead());
            continue;
        }
        const delivered = try result;
        if (case == .stale) {
            // A later frame supersedes the earlier receipt.
            const newer = try screen.render(&held.writer, size, "", 0, .{}, &.{});
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
            try std.testing.expectEqual(@as(u64, 0xb), screen.consent.?.action);
            try std.testing.expectEqual(ConsentPolicy.Approval.reading, screen.select(false).approval);
        }
    }
}

fn expectBlocked(expected: DecisionBlock, result: ChoiceOutcome) !void {
    // Taking the decision here is the defect this assertion catches.
    try std.testing.expect(result == .blocked);
    try std.testing.expectEqual(expected, result.blocked);
}

/// One key at the choice, as the frontend's input entry delivers it.
fn press(screen: *Self, key: ChoiceKey, size: std.posix.winsize, command_blocked: bool) ChoiceOutcome {
    return screen.choose(key, screen.spendOffer(), size, command_blocked);
}

test "a decision prompt is offered only after its own delivered frame" {
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
    try screen.adopt(io, fixture.file, 0xa, true);
    // The frame that completes reading still said "read the rest".
    _ = screen.select(false);
    try std.testing.expect(screen.presented(try screen.render(&held.writer, size, "", 0, .{}, &.{})).read_completed);
    try std.testing.expect(!screen.awaitsOffer());
    try std.testing.expect(!screen.promptCompleted(.empty, false, false));
    try std.testing.expectEqual(ConsentPolicy.Approval.choice, screen.select(false).approval);
    // A planned decision prompt is not a delivered one.
    try std.testing.expect(!screen.promptCompleted(.empty, false, false));
    const prompt = try screen.render(&held.writer, size, "", 0, .{}, &.{});
    _ = screen.presented(prompt);
    try std.testing.expect(screen.awaitsOffer());
    try std.testing.expect(screen.offered() == null);
    for ([_]ConsentPolicy.Service{ .byte, .decoder_pending, .decoder_expired, .budget_exhausted }) |service|
        try std.testing.expect(!screen.promptCompleted(service, false, false));
    try std.testing.expect(!screen.promptCompleted(.empty, true, false));
    try std.testing.expect(!screen.promptCompleted(.empty, false, true));
    try std.testing.expect(screen.promptCompleted(.empty, false, false));
    try std.testing.expectEqual(ConsentPolicy.Decision{ .action = 0xa, .choice = .allow_once }, screen.offered().?);
    // Offered once: the same frame offers nothing new.
    try std.testing.expect(!screen.promptCompleted(.empty, false, false));
    // A resize between the prompt and Enter fails the live probe and restarts reading.
    const resized: std.posix.winsize = .{ .row = 10, .col = 40, .xpixel = 0, .ypixel = 0 };
    try expectBlocked(.layout, press(screen, .enter, resized, false));
    try std.testing.expect(!screen.actionRead());
    try std.testing.expect(screen.stale());
    try std.testing.expectEqual(@as(u64, 0xa), screen.consent.?.action);
    // Read again, prompt again, then a queued command blocks the decision.
    _ = screen.select(false);
    _ = screen.presented(try screen.render(&held.writer, size, "", 0, .{}, &.{}));
    _ = screen.select(false);
    _ = screen.presented(try screen.render(&held.writer, size, "", 0, .{}, &.{}));
    try std.testing.expect(screen.promptCompleted(.empty, false, false));
    _ = screen.select(false);
    try expectBlocked(.command, press(screen, .enter, size, true));
    try std.testing.expectEqual(@as(u64, 0xa), screen.consent.?.action);
    // While the command holds the choice, its frames show no decision.
    _ = screen.presented(try screen.render(&held.writer, size, "", 0, .{ .command = true }, &.{}));
    try std.testing.expectEqual(ConsentPolicy.Approval.held, screen.selected.approval);
    try std.testing.expect(!screen.awaitsOffer());
    try std.testing.expect(!screen.promptCompleted(.empty, false, false));
    // The same Action needs a new delivered prompt and empty service.
    _ = screen.select(false);
    _ = screen.presented(try screen.render(&held.writer, size, "", 0, .{}, &.{}));
    try std.testing.expect(screen.promptCompleted(.empty, false, false));
    _ = screen.select(false);
    // An arrow moves the highlight only on an offer, and spends it: Enter
    // decides only once a delivered frame shows the move.
    try std.testing.expect(press(screen, .{ .pick = .deny }, size, false) == .picked);
    try std.testing.expect(screen.stale());
    try expectBlocked(.not_ready, press(screen, .enter, size, false));
    // A frame issued but not delivered offers nothing.
    _ = screen.select(false);
    const shows_deny = try screen.render(&held.writer, size, "", 0, .{}, &.{});
    try std.testing.expect(!screen.promptCompleted(.empty, false, false));
    _ = screen.presented(shows_deny);
    try std.testing.expect(screen.promptCompleted(.empty, false, false));
    const decided = press(screen, .enter, size, false);
    try std.testing.expect(decided == .decision);
    try std.testing.expectEqual(ConsentPolicy.Decision{ .action = 0xa, .choice = .deny }, decided.decision);
    // Consumed once: neither the old frame nor a repeat decides again.
    try std.testing.expect(screen.consent == null);
    try std.testing.expect(screen.offered() == null);
    try std.testing.expect(press(screen, .enter, size, false) != .decision);
}

test "an offer is spent by any input after its frame, even one that arrives while the frame is written" {
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
    try screen.adopt(io, fixture.file, 0xa, true);
    for (0..2) |_| {
        _ = screen.select(false);
        _ = screen.presented(try screen.render(&held.writer, size, "", 0, .{}, &.{}));
    }
    // A key read after the frame was issued and before its receipt.
    _ = screen.select(false);
    const frame = try screen.render(&held.writer, size, "", 0, .{}, &.{});
    try std.testing.expect(screen.spendOffer() == null);
    _ = screen.presented(frame);
    try std.testing.expect(!screen.awaitsOffer());
    try std.testing.expect(!screen.promptCompleted(.empty, false, false));
    // The next frame, with no key after it, offers its decision.
    _ = screen.select(false);
    _ = screen.presented(try screen.render(&held.writer, size, "", 0, .{}, &.{}));
    try std.testing.expect(screen.promptCompleted(.empty, false, false));
    try std.testing.expectEqual(ConsentPolicy.Decision{ .action = 0xa, .choice = .allow_once }, screen.offered().?);
    try std.testing.expect(screen.spendOffer() != null);
    try std.testing.expect(screen.offered() == null);
}

/// Writes and delivers one whole frame.
fn deliver(screen: *Self, held: *HeldWriter, size: std.posix.winsize) !void {
    _ = screen.presented(try screen.render(&held.writer, size, "", 0, .{}, &.{}));
}

test "an offer stands only for its own frame: no Enter decides on a later frame until that frame is offered" {
    const io = std.testing.io;
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const screen = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(screen);
    try screen.init(io, &environ, false);
    defer screen.deinit();
    const size: std.posix.winsize = .{ .row = 12, .col = 40, .xpixel = 0, .ypixel = 0 };
    const resized: std.posix.winsize = .{ .row = 14, .col = 44, .xpixel = 0, .ypixel = 0 };
    var fixture = try ActionFixture.init(3);
    defer fixture.deinit();
    var buffer: [256]u8 = undefined;
    var held: HeldWriter = .init(screen, &buffer);
    const Change = enum { resize, width, readopted, successor, held_write, redraw };
    for (std.enums.values(Change)) |change| {
        errdefer std.debug.print("change={s}\n", .{@tagName(change)});
        screen.withdrawAction();
        screen.view = .live;
        try screen.adopt(io, fixture.file, 0xa, true);
        try deliver(screen, &held, size);
        try deliver(screen, &held, size);
        try std.testing.expect(screen.promptCompleted(.empty, false, false));
        try std.testing.expect(screen.offered() != null);
        // No key arrives while the screen changes.
        var now = size;
        switch (change) {
            .resize => {
                now = resized;
                try deliver(screen, &held, now);
                // The frame at the new size restarts reading and says so.
                try std.testing.expectEqual(ConsentPolicy.Approval.reading, screen.selected.approval);
            },
            .width => {
                screen.setWidth(if (screen.vx.caps.unicode == .unicode) .wcwidth else .unicode);
                try expectBlocked(.reading, press(screen, .enter, now, false));
                try deliver(screen, &held, now);
            },
            .readopted, .successor => {
                screen.withdrawAction();
                try deliver(screen, &held, now);
                try screen.adopt(io, fixture.file, if (change == .successor) 0xb else 0xa, true);
                try deliver(screen, &held, now);
            },
            .held_write => {
                // A frame that shows the same choice is issued; an Enter read
                // while its bytes are written finds it not yet delivered.
                const pending = try screen.render(&held.writer, now, "", 0, .{}, &.{});
                try expectBlocked(.not_ready, press(screen, .enter, now, false));
                _ = screen.presented(pending);
                try std.testing.expect(screen.consent != null);
                continue;
            },
            .redraw => {},
        }
        // Whatever changed, the next delivered frame shows the choice again,
        // yet no empty service has offered it.
        try deliver(screen, &held, now);
        try std.testing.expectEqual(ConsentPolicy.Approval.choice, screen.selected.approval);
        try std.testing.expect(screen.offered() == null);
        try expectBlocked(.not_ready, press(screen, .enter, now, false));
        try std.testing.expect(screen.consent != null);
        // Once that frame is offered, the Enter after it decides what it showed.
        try deliver(screen, &held, now);
        try std.testing.expect(screen.promptCompleted(.empty, false, false));
        const decided = press(screen, .enter, now, false);
        try std.testing.expect(decided == .decision);
        try std.testing.expectEqual(ConsentPolicy.Decision{ .action = if (change == .successor) 0xb else 0xa, .choice = .allow_once }, decided.decision);
        screen.releaseAction();
        try deliver(screen, &held, size);
    }
}
