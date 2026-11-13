//! One invocation's logical drafts. Initialize in final storage; never move.
const std = @import("std");
const Editor = @import("DraftEditor.zig");
const keymap = @import("keymap.zig");
const slash_commands = @import("slash_commands.zig").conversation;
const Self = @This();

pub const capacity = 65_536;
pub const Ticket = struct { owner: *const Self, serial: u64 };
/// What one input did to the draft, on a screen whose keys mean `A`s.
pub fn Event(comptime A: type) type {
    return union(enum) { editor: keymap.Outcome(A), message: Ticket, command, busy };
}
pub const View = struct { bytes: []const u8, cursor: usize };
/// The whole logical draft, borrowing bytes until the input next changes.
/// Terminal decoding/paste state and outstanding recall reads stay local.
pub const Snapshot = struct {
    bytes: []const u8,
    cursor: usize,
    anchor: ?Recalled = null,
    rejected: ?keymap.Refusal = null,
};
/// A Message the person sent, by its Activity position, read at `end`.
pub const Recalled = struct { position: u64, end: u64 };
/// Ctrl-P and Ctrl-N over the Messages the person sent.
pub const Recall = struct {
    /// The sent Message the draft shows, until the draft changes.
    shown: ?Recalled = null,
    /// Presses not yet read, net: below zero older, above zero newer.
    pending: i32 = 0,
    reading: bool = false,
};
/// One step read from the shown Message, or from the newest when none is
/// shown. It lands only on the draft revision it began from.
pub const Step = struct { from: ?Recalled, older: bool, revision: u64 };
/// A sent Message staged for the draft: `length` bytes, and a `/` to put
/// before them.
pub const Found = struct { at: Recalled, length: usize, slash: bool };
pub const Landing = union(enum) {
    /// The draft changed while the step was read.
    stale,
    /// Nothing older; the draft stays.
    oldest,
    /// Past the newest; the draft is empty again.
    emptied,
    show: Found,
};

banks: [2][capacity]u8 = undefined,
editors: [2]Editor = undefined,
// The one queued inspection command; only queueCommand and takeCommand change it.
command_buffer: [capacity]u8 = undefined,
command_length: ?usize = null,
active: u1 = 0,
/// The loaned bank and its Message's length; the bank's editor no longer
/// holds it.
submitted: ?struct { bank: u1, literal: bool, length: usize } = null,
serial: u64 = 0,
recall: Recall = .{},
/// Counts the draft's changes: each edit, clear, send and recalled Message.
revision: u64 = 0,
/// What Tab adds; null until the screen sets it, so Tab types a tab.
completion: ?Editor.Completion = null,

pub fn init(self: *Self) void {
    self.* = .{};
    for (&self.editors, 0..) |*editor, bank| editor.* = self.empty(@intCast(bank));
}

/// A bank's empty draft, whose Tab completes what the command list shows.
fn empty(self: *Self, bank: u1) Editor {
    var editor: Editor = .init(&self.banks[bank]);
    editor.completion = self.completion;
    return editor;
}

/// Sets what Tab adds in every draft, now and after each reset.
pub fn complete(self: *Self, completion: Editor.Completion) void {
    self.completion = completion;
    for (&self.editors) |*editor| editor.completion = completion;
}

/// Adds `text` at the draft's end, as Tab's completion does.
pub fn append(self: *Self, text: []const u8) Editor.KeyOutcome {
    const editor = &self.editors[self.active];
    const edits = editor.edits;
    const outcome = editor.append(text);
    if (editor.edits != edits) self.changed();
    return outcome;
}

/// Puts `change`'s text in place of its range, as Tab's completion does.
pub fn replace(self: *Self, change: Editor.Replacement) Editor.KeyOutcome {
    const editor = &self.editors[self.active];
    const edits = editor.edits;
    const outcome = editor.replace(change);
    if (editor.edits != edits) self.changed();
    return outcome;
}

pub fn composition(self: *const Self) View {
    const editor = &self.editors[self.active];
    return .{ .bytes = editor.text(), .cursor = editor.cursor() };
}

/// Captures the active draft without transferring its storage.
pub fn snapshot(self: *const Self) Snapshot {
    const editor = &self.editors[self.active];
    return .{
        .bytes = editor.text(),
        .cursor = editor.cursor(),
        .anchor = self.recall.shown,
        .rejected = editor.rejected,
    };
}

/// Copies a saved draft into the active bank, leaving any submitted loan alone.
pub fn restore(self: *Self, draft: Snapshot) void {
    std.debug.assert(draft.bytes.len <= capacity and draft.cursor <= draft.bytes.len);
    self.clear();
    const editor = &self.editors[self.active];
    // A snapshot is this input's own draft, which its editor already held.
    std.debug.assert(editor.set(draft.bytes, draft.cursor) == null);
    editor.rejected = draft.rejected;
    self.recall.shown = draft.anchor;
}

pub fn appEvent(self: *Self, comptime keys: anytype, event: @import("vaxis").vxfw.Event, pasting: bool, selected: bool) Event(@TypeOf(keys).Action) {
    const editor = &self.editors[self.active];
    const edits = editor.edits;
    const outcome = editor.appEvent(keys, event, pasting);
    if (editor.edits != edits) self.changed();
    return self.accept(@TypeOf(keys).Action, outcome, selected);
}

/// Terminal bytes, decoded as App decodes them, each key as itself. For
/// tests. Returns the last event that is not an editor `.none`.
pub fn typed(self: *Self, bytes: []const u8) Event(keymap.Key) {
    var events: @import("testing/app_events.zig").Events = .init(bytes);
    var last: Event(keymap.Key) = .{ .editor = .none };
    while (events.next()) |input| {
        const event = self.appEvent(keymap.every, input, events.pasting, true);
        if (!(event == .editor and event.editor == .none)) last = event;
    }
    return last;
}

test "Ctrl-J inserts at the caret without submitting, in every encoding" {
    const self = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(self);
    for ([_][]const u8{ "\n", "\x1b[106;5u", "\x1b[106;5;106u", "\x1b[27;5;106~" }) |bytes| {
        errdefer std.debug.print("bytes={any}\n", .{bytes});
        self.init();
        _ = self.append("leftRIGHT");
        self.editors[self.active].setCursor(4);
        try std.testing.expect(self.typed(bytes) == .editor);
        try std.testing.expectEqualStrings("left\nRIGHT", self.composition().bytes);
        try std.testing.expectEqual(@as(usize, 5), self.composition().cursor);
        try std.testing.expectEqual(null, self.submitted);
        try std.testing.expect(self.typed("\r") == .message);
    }
}

fn accept(self: *Self, comptime Action: type, outcome: keymap.Outcome(Action), selected: bool) Event(Action) {
    if (outcome == .refused and outcome.refused.endsLine()) self.clear();
    if (outcome != .submit) return .{ .editor = outcome };
    const bytes = self.composition().bytes;
    // An empty draft's Enter stays the editor's, for a list the caller shows.
    if (bytes.len == 0) return .{ .editor = outcome };
    // A command line stays in the draft; the caller clears it once it runs.
    // While another waits, every draft command waits too, local ones included.
    // Any other draft, a leading `/skill` included, is a Message.
    switch (slash_commands.draftOf(bytes)) {
        .command => return if (self.admitsCommand()) .command else .busy,
        .message, .word => {},
    }
    if (!selected or self.submitted != null) return .busy;
    return .{ .message = self.seal(false, bytes.len) };
}

/// Whether a command may run now, typed or clicked: only while none waits.
pub fn admitsCommand(self: *const Self) bool {
    return self.command_length == null;
}

/// Queues one inspection command for the draft's reader.
pub fn queueCommand(self: *Self, text: []const u8) void {
    std.debug.assert(self.admitsCommand());
    @memcpy(self.command_buffer[0..text.len], text);
    self.command_length = text.len;
}

pub fn queuedCommand(self: *const Self) ?[]const u8 {
    return self.command_buffer[0 .. self.command_length orelse return null];
}

/// Takes the queued command. Its bytes stay until the next one queues.
pub fn takeCommand(self: *Self) ?[]const u8 {
    const text = self.queuedCommand();
    self.command_length = null;
    return text;
}

/// Command-line text was validated before Session creation. It is literal,
/// including leading slashes, and uses the same retained submission bank.
pub fn submitText(self: *Self, text: []const u8) Ticket {
    std.debug.assert(self.submitted == null and text.len <= capacity);
    @memcpy(self.banks[self.active][0..text.len], text);
    return self.seal(true, text.len);
}

/// Loans the staged Message's exact bytes, including slashes, without editing
/// the active draft or its recall/rejection state. Scratch is consumed now.
pub fn submitPreservingDraft(self: *Self, io: std.Io, file: std.Io.File, length: usize) !Ticket {
    std.debug.assert(self.submitted == null);
    if (length > capacity) return error.MessageTooLarge;
    const bank = self.active ^ 1;
    const bytes = self.banks[bank][0..length];
    if (try file.readPositionalAll(io, bytes, 0) != length) return error.TruncatedRetryScratch;
    self.editors[bank] = self.empty(bank);
    self.serial += 1;
    self.submitted = .{ .bank = bank, .literal = true, .length = length };
    return .{ .owner = self, .serial = self.serial };
}

/// Loans the active bank's first `length` bytes and edits in the other.
fn seal(self: *Self, literal: bool, length: usize) Ticket {
    self.serial += 1;
    self.submitted = .{ .bank = self.active, .literal = literal, .length = length };
    self.editors[self.active] = self.empty(self.active);
    self.active ^= 1;
    self.clear();
    return .{ .owner = self, .serial = self.serial };
}

pub fn clear(self: *Self) void {
    self.editors[self.active] = self.empty(self.active);
    self.changed();
}

/// Any change makes the draft an ordinary one and drops the presses not
/// yet read.
fn changed(self: *Self) void {
    self.revision +%= 1;
    self.recall.shown = null;
    self.recall.pending = 0;
}

/// Ctrl-P (`older`) or Ctrl-N. On a typed draft it does nothing and the
/// caller says to empty the draft first, even while a step is read.
pub fn press(self: *Self, older: bool) enum { queued, typed } {
    if (self.recall.shown == null and self.composition().bytes.len != 0) return .typed;
    self.recall.pending += if (older) -1 else 1;
    return .queued;
}

/// The next step to read, one at a time. Newer than an empty draft is
/// nothing.
pub fn nextStep(self: *Self) ?Step {
    if (self.recall.reading or self.recall.pending == 0) return null;
    const older = self.recall.pending < 0;
    if (!older and self.recall.shown == null) {
        self.recall.pending = 0;
        return null;
    }
    self.recall.pending += if (older) 1 else -1;
    self.recall.reading = true;
    return .{ .from = self.recall.shown, .older = older, .revision = self.revision };
}

/// A step that failed or was cancelled: the presses after it go too.
pub fn abandonStep(self: *Self) void {
    self.recall.reading = false;
    self.recall.pending = 0;
}

/// What a read step's result does to the draft. `show` is then `fill`ed.
pub fn land(self: *Self, step: Step, found: ?Found) Landing {
    self.recall.reading = false;
    if (step.revision != self.revision) return .stale;
    if (found) |sent| return .{ .show = sent };
    if (!step.older) {
        self.clear();
        return .emptied;
    }
    self.recall.pending = @max(self.recall.pending, 0);
    return .oldest;
}

/// Replaces the draft with a found Message's bytes from `file`, the caret at
/// their end. Text that begins with `/` takes a second one, as typing it
/// would, so Enter sends it rather than running a command. False when the
/// draft cannot hold that text, such as a mark with nothing to join: the
/// draft is then empty, and the recall moves past the Message.
pub fn fill(self: *Self, io: std.Io, file: std.Io.File, found: Found) !bool {
    const editor = &self.editors[self.active];
    editor.* = self.empty(self.active);
    const bank = &self.banks[self.active];
    const start = @intFromBool(found.slash);
    if (found.slash) bank[0] = '/';
    if (try file.readPositionalAll(io, bank[start..][0..found.length], 0) != found.length) return error.TruncatedDisplayScratch;
    const length = start + found.length;
    const held = editor.set(bank[0..length], length) == null;
    self.revision +%= 1;
    self.recall.shown = found.at;
    return held;
}

/// The submission owner retains this immutable loan through capture and join.
pub fn message(self: *const Self, ticket: Ticket) ![]const u8 {
    const submitted = try self.checked(ticket);
    const bytes = self.banks[submitted.bank][0..submitted.length];
    return if (!submitted.literal and std.mem.startsWith(u8, bytes, "//")) bytes[1..] else bytes;
}

/// The loan owner decides when borrowers have retired and release is allowed.
pub fn release(self: *Self, ticket: Ticket) !void {
    const submitted = try self.checked(ticket);
    self.editors[submitted.bank] = self.empty(submitted.bank);
    self.submitted = null;
}

fn checked(self: *const Self, ticket: Ticket) !@TypeOf(self.submitted.?) {
    if (ticket.owner != self or ticket.serial != self.serial) return error.SubmissionChanged;
    return self.submitted orelse error.NoSubmission;
}

test "SessionInput snapshot restore keeps recall anchor completion and submitted loan independent" {
    const gpa = std.testing.allocator;
    const input = try gpa.create(Self);
    defer gpa.destroy(input);
    input.init();
    _ = input.typed("original");
    const ticket = input.typed("\r").message;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "recalled", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "aéZ", 0);
    const found: Found = .{ .at = .{ .position = 7, .end = 9 }, .length = "aéZ".len, .slash = false };
    try std.testing.expect(try input.fill(io, file, found));
    _ = input.typed("\x1b[D");
    var saved = input.snapshot();
    const bytes = try gpa.dupe(u8, saved.bytes);
    defer gpa.free(bytes);
    saved.bytes = bytes;
    _ = input.press(true);
    const step = input.nextStep().?;
    input.clear();
    _ = input.typed("discarded");
    const Completion = struct {
        fn add(_: *const anyopaque, draft: []const u8, _: usize) ?Editor.Replacement {
            return .append(draft, "!");
        }
    };
    input.complete(.{ .context = &{}, .add = Completion.add });
    input.restore(saved);
    try std.testing.expectEqualStrings("aéZ", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, "aé".len), input.composition().cursor);
    try std.testing.expectEqual(found.at, input.snapshot().anchor.?);
    try std.testing.expectEqual(Landing.stale, input.land(step, found));
    try std.testing.expectEqualStrings("original", try input.message(ticket));
    try input.release(ticket);
    try std.testing.expectEqualStrings("aéZ", input.composition().bytes);
    try std.testing.expectEqual(.queued, input.press(true));
    try std.testing.expectEqual(found.at, input.nextStep().?.from.?);
    _ = input.typed("\t");
    try std.testing.expectEqualStrings("aéZ!", input.composition().bytes);
    try std.testing.expectEqual(null, input.snapshot().anchor);
}

test "SessionInput loan release preserves next Unicode draft and cursor" {
    var input: Self = undefined;
    input.init();
    _ = input.typed("aéZ\x1b[D");
    const ticket = input.typed("\r").message;
    _ = input.typed("next!\x1b[D\x1b[D");
    try std.testing.expectEqualStrings("aéZ", try input.message(ticket));
    try input.release(ticket);
    try std.testing.expectEqualStrings("next!", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 3), input.composition().cursor);
    try std.testing.expectError(error.NoSubmission, input.message(ticket));
}

test "SessionInput malformed rejection resets only the active composition" {
    var input: Self = undefined;
    input.init();
    _ = input.typed("original");
    const ticket = input.typed("\r").message;
    _ = input.typed("\xff");
    try std.testing.expect(std.meta.eql(input.typed("\r").editor, .{ .refused = .invalid }));
    try std.testing.expectEqualStrings("original", try input.message(ticket));
    _ = input.typed("valid");
    try std.testing.expectEqualStrings("valid", input.composition().bytes);
    try std.testing.expectEqualStrings("original", try input.message(ticket));
}

test "SessionInput retained loan and stale tickets cannot consume next composition" {
    var input: Self = undefined;
    input.init();
    _ = input.typed("old");
    const ticket = input.typed("\r").message;
    _ = input.typed("new\x1b[D");
    try std.testing.expectEqual(.busy, std.meta.activeTag(input.typed("\r")));
    try input.release(ticket);
    try std.testing.expectEqualStrings("new", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 2), input.composition().cursor);
    const next = input.typed("\r").message;
    try std.testing.expectError(error.SubmissionChanged, input.release(ticket));
    try std.testing.expectEqualStrings("new", try input.message(next));
}

test "a recalled Message is the draft until an edit, never a caret move" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "recalled", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "/copy\nagain", 0);
    var input: Self = undefined;
    input.init();
    const found: Found = .{ .at = .{ .position = 7, .end = 9 }, .length = "/copy\nagain".len, .slash = true };
    try std.testing.expect(try input.fill(io, file, found));
    try std.testing.expectEqualStrings("//copy\nagain", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 12), input.composition().cursor);
    _ = input.typed("\x1b[A\x1b[D\x1b[C\x01\x05\x1b[B");
    try std.testing.expectEqual(found.at, input.recall.shown.?);
    // Each edit, even one that keeps the length (a paste rolled back as a
    // whole), makes it an ordinary draft.
    for ([_][]const u8{ "x", "\x7f", "\x01\x1b[3~", "\x15", "\x1b[200~p\x1b[201~", "\xff", "\xc3\xa9", "\x1b[200~\n\xcc\x81\x1b[201~" }) |edit| {
        try std.testing.expect(try input.fill(io, file, found));
        const revision = input.revision;
        _ = input.typed(edit);
        try std.testing.expect(input.recall.shown == null);
        try std.testing.expect(input.revision != revision);
    }
    try std.testing.expect(try input.fill(io, file, .{ .at = found.at, .length = 5, .slash = false }));
    try std.testing.expectEqualStrings("/copy", input.composition().bytes);
    // Without the second slash, text whose first word names a command runs as one.
    try std.testing.expectEqual(.command, std.meta.activeTag(input.typed("\r")));
    input.clear();
    try std.testing.expect(input.recall.shown == null);
}

test "a recall step lands only on the draft it began from, one at a time" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "recalled", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "newest", 0);
    const newest: Found = .{ .at = .{ .position = 9, .end = 9 }, .length = 6, .slash = false };
    var input: Self = undefined;
    input.init();

    // Typing during a read: the read lands nowhere, and Ctrl-P on the typed
    // draft says so even while another read runs.
    try std.testing.expectEqual(.queued, input.press(true));
    var step = input.nextStep().?;
    try std.testing.expectEqual(@as(?Recalled, null), step.from);
    try std.testing.expect(input.nextStep() == null);
    _ = input.typed("a");
    try std.testing.expectEqual(.typed, input.press(true));
    try std.testing.expectEqual(Landing.stale, input.land(step, newest));
    try std.testing.expectEqualStrings("a", input.composition().bytes);
    try std.testing.expectEqual(@as(i32, 0), input.recall.pending);

    // Sending during a read: the sent draft's step lands nowhere.
    input.clear();
    _ = input.press(true);
    step = input.nextStep().?;
    try std.testing.expectEqual(Landing{ .show = newest }, input.land(step, newest));
    try std.testing.expect(try input.fill(io, file, newest));
    _ = input.press(true);
    step = input.nextStep().?;
    try std.testing.expectEqual(@as(?Recalled, newest.at), step.from);
    const ticket = input.typed("\r").message;
    try std.testing.expectEqual(Landing.stale, input.land(step, newest));
    try std.testing.expectEqualStrings("", input.composition().bytes);
    try std.testing.expectEqualStrings("newest", try input.message(ticket));
    try input.release(ticket);

    // Opposite presses cancel before a read; those made during one add up.
    _ = input.press(true);
    _ = input.press(false);
    try std.testing.expect(input.nextStep() == null);
    _ = input.press(true);
    step = input.nextStep().?;
    for (0..2) |_| _ = input.press(true);
    _ = input.press(false);
    try std.testing.expect(try input.fill(io, file, input.land(step, newest).show));
    step = input.nextStep().?;
    try std.testing.expect(step.older and input.nextStep() == null);
    // Nothing older: the draft stays and no older press waits; a newer one
    // still does, and past the newest the draft is empty again.
    _ = input.press(false);
    try std.testing.expectEqual(Landing.oldest, input.land(step, null));
    try std.testing.expectEqualStrings("newest", input.composition().bytes);
    step = input.nextStep().?;
    try std.testing.expect(!step.older);
    try std.testing.expectEqual(Landing.emptied, input.land(step, null));
    try std.testing.expectEqualStrings("", input.composition().bytes);
    try std.testing.expect(input.recall.shown == null);
    // Newer than an empty draft is nothing.
    _ = input.press(false);
    try std.testing.expect(input.nextStep() == null);
}

test "Tab puts in the list's first word at the draft's end and adds a tab anywhere else" {
    const List = struct {
        fn add(_: *const anyopaque, draft: []const u8, _: usize) ?Editor.Replacement {
            const list = slash_commands.suggest(draft, .{}) orelse return null;
            return .append(draft, if (list.count == 0) "" else list.completion(0));
        }
    };
    const cases = [_]struct { typed: []const u8, shown: []const u8 }{
        .{ .typed = "/ef\t", .shown = "/effort " },
        .{ .typed = "/ef\x1b[D\x1b[D\t", .shown = "/effort " },
        .{ .typed = "/cop\t", .shown = "/copy " },
        .{ .typed = "/s\t", .shown = "/setup " },
        .{ .typed = "/s\t\t", .shown = "/setup --model " },
        .{ .typed = "/zz\t", .shown = "/zz" },
        .{ .typed = "/copy \t", .shown = "/copy code" },
        .{ .typed = "/rename \t", .shown = "/rename \t" },
        .{ .typed = "//c\t", .shown = "//c\t" },
        .{ .typed = "hi\t", .shown = "hi\t" },
        .{ .typed = "\t", .shown = "\t" },
    };
    for (cases) |case| {
        var input: Self = undefined;
        input.init();
        input.complete(.{ .context = &{}, .add = List.add });
        _ = input.typed(case.typed);
        try std.testing.expectEqualStrings(case.shown, input.composition().bytes);
        try std.testing.expectEqual(case.shown.len, input.composition().cursor);
    }
}

test "SessionInput retry loan preserves the whole active editor and recall even on scratch failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "retry", .{ .read = true });
    defer file.close(io);
    const text = "//literal\n\t café 💚\r\n";
    try file.writePositionalAll(io, text, 0);
    const self = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(self);
    for ([_]bool{ false, true }) |rejected| {
        self.init();
        _ = self.typed("aéZ\x1b[D");
        self.recall = .{ .shown = .{ .position = 7, .end = 9 }, .pending = -1, .reading = true };
        if (rejected) self.editors[self.active].rejected = .invalid;
        const editor = self.editors[self.active];
        const recall = self.recall;
        const revision = self.revision;
        try std.testing.expectError(error.TruncatedRetryScratch, self.submitPreservingDraft(io, file, text.len + 1));
        try std.testing.expect(self.submitted == null);
        const ticket = try self.submitPreservingDraft(io, file, text.len);
        try std.testing.expectEqualStrings(text, try self.message(ticket));
        try std.testing.expectEqualDeep(editor, self.editors[self.active]);
        try std.testing.expectEqualDeep(recall, self.recall);
        try std.testing.expectEqual(revision, self.revision);
        try self.release(ticket);
        try std.testing.expectEqualStrings("aéZ", self.composition().bytes);
        try std.testing.expectEqualDeep(editor, self.editors[self.active]);
        try std.testing.expectEqualDeep(recall, self.recall);
    }
}
