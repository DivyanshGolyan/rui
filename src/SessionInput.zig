//! One invocation's logical drafts. Initialize in final storage; never move.
const std = @import("std");
const Editor = @import("TerminalEditor.zig");
const TerminalInput = @import("TerminalInput.zig");
const keymap = @import("keymap.zig");
const slash_commands = @import("slash_commands.zig");
const Self = @This();

pub const capacity = 65_536;
pub const Ticket = struct { owner: *const Self, serial: u64 };
/// What one input did to the draft, on a screen whose keys mean `A`s.
pub fn Event(comptime A: type) type {
    return union(enum) { editor: keymap.Outcome(A), message: Ticket, command, busy };
}
pub const View = struct { bytes: []const u8, cursor: usize };
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

/// The invocation's one terminal byte stream. Draft resets, bank switches and
/// the Session's choice editor never replace it.
stream: TerminalInput = .{},
banks: [2][capacity]u8 = undefined,
editors: [2]Editor = undefined,
// The one queued inspection command; only queueCommand and takeCommand change it.
command_buffer: [capacity]u8 = undefined,
command_length: ?usize = null,
active: u1 = 0,
submitted: ?struct { bank: u1, literal: bool } = null,
serial: u64 = 0,
recall: Recall = .{},
/// Counts the draft's changes: each edit, clear, send and recalled Message.
revision: u64 = 0,

pub fn init(self: *Self) void {
    self.* = .{};
    for (&self.editors, 0..) |*editor, bank| editor.* = self.empty(@intCast(bank));
}

/// A bank's empty draft, whose Tab completes a slash command.
fn empty(self: *Self, bank: u1) Editor {
    return .{ .buffer = &self.banks[bank], .completion = slash_commands.complete };
}

pub fn composition(self: *const Self) View {
    const editor = &self.editors[self.active];
    return .{ .bytes = editor.buffer[0..editor.length], .cursor = editor.cursor };
}

pub fn pending(self: *const Self) Editor.Pending {
    return self.stream.pending();
}

/// One byte for the draft and every event it completes (tests, which keep
/// clear of input deadlines), each key as itself. Returns the last event
/// that is not an editor `.none`.
pub fn feed(self: *Self, byte: u8) Event(keymap.Key) {
    var last: Event(keymap.Key) = .{ .editor = .none };
    var decoded = self.stream.feed(byte, 0);
    while (decoded != .none) : (decoded = self.stream.next()) {
        const event = self.applySelected(keymap.every, decoded, true);
        if (!(event == .editor and event.editor == .none)) last = event;
    }
    return last;
}

pub fn applySelected(self: *Self, comptime keys: anytype, decoded: TerminalInput.Decoded, selected: bool) Event(@TypeOf(keys).Action) {
    const editor = &self.editors[self.active];
    const edits = editor.edits;
    const outcome = editor.apply(keys, decoded);
    if (editor.edits != edits) self.changed();
    if (outcome == .refused and outcome.refused.endsLine()) self.clear();
    if (outcome != .submit) return .{ .editor = outcome };
    const bytes = self.composition().bytes;
    if (bytes.len == 0) return .{ .editor = .none };
    // A slash command stays in the draft; the caller clears it once it runs.
    // While another waits, every draft command waits too, local ones included.
    if (bytes[0] == '/' and !std.mem.startsWith(u8, bytes, "//")) return if (self.command_length != null) .busy else .command;
    if (!selected or self.submitted != null) return .busy;
    return .{ .message = self.seal(false) };
}

/// Queues one inspection command for the draft's reader. The draft admits a
/// command only while none waits.
pub fn queueCommand(self: *Self, text: []const u8) void {
    std.debug.assert(self.command_length == null);
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
    const editor = &self.editors[self.active];
    @memcpy(editor.buffer[0..text.len], text);
    editor.length = text.len;
    editor.cursor = text.len;
    return self.seal(true);
}

fn seal(self: *Self, literal: bool) Ticket {
    self.serial += 1;
    self.submitted = .{ .bank = self.active, .literal = literal };
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

/// No press waits once an Action's choice holds the input. A step already
/// read still lands on the draft it began from.
pub fn dropPresses(self: *Self) void {
    self.recall.pending = 0;
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
/// would, so Enter sends it rather than running a command.
pub fn fill(self: *Self, io: std.Io, file: std.Io.File, found: Found) !void {
    const editor = &self.editors[self.active];
    editor.* = self.empty(self.active);
    const start = @intFromBool(found.slash);
    if (found.slash) editor.buffer[0] = '/';
    if (try file.readPositionalAll(io, editor.buffer[start..][0..found.length], 0) != found.length) return error.TruncatedDisplayScratch;
    editor.length = start + found.length;
    editor.cursor = editor.length;
    self.revision +%= 1;
    self.recall.shown = found.at;
}

/// The submission owner retains this immutable loan through capture and join.
pub fn message(self: *const Self, ticket: Ticket) ![]const u8 {
    const submitted = try self.checked(ticket);
    const editor = &self.editors[submitted.bank];
    const bytes = editor.buffer[0..editor.length];
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

test "SessionInput loan release preserves next Unicode draft and cursor" {
    var input: Self = undefined;
    input.init();
    for ("aéZ\x1b[D") |byte| _ = input.feed(byte);
    const ticket = input.feed('\r').message;
    for ("next!\x1b[D\x1b[D") |byte| _ = input.feed(byte);
    try std.testing.expectEqualStrings("aéZ", try input.message(ticket));
    try input.release(ticket);
    try std.testing.expectEqualStrings("next!", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 3), input.composition().cursor);
    try std.testing.expectError(error.NoSubmission, input.message(ticket));
}

test "SessionInput malformed rejection resets only the active composition" {
    var input: Self = undefined;
    input.init();
    for ("original") |byte| _ = input.feed(byte);
    const ticket = input.feed('\r').message;
    for ("\xff") |byte| _ = input.feed(byte);
    try std.testing.expect(std.meta.eql(input.feed('\r').editor, .{ .refused = .invalid }));
    for ([_][]const u8{ "\x1b\n", "\x1b\r", "\x1b[20\n", "\x1b[201\r" }) |sequence| {
        for ("\x1b[200~left") |byte| _ = input.feed(byte);
        for (sequence) |byte| _ = input.feed(byte);
        try std.testing.expectEqual(Editor.Pending.incomplete, input.pending());
        for ("a\r") |byte| try std.testing.expect(input.feed(byte).editor == .none);
        for ("\x1b[201~") |byte| _ = input.feed(byte);
        try std.testing.expect(std.meta.eql(input.feed('\r').editor, .{ .refused = .invalid }));
        try std.testing.expectEqual(Editor.Pending.none, input.pending());
        try std.testing.expectEqualStrings("original", try input.message(ticket));
    }
    for ("valid") |byte| _ = input.feed(byte);
    try std.testing.expectEqualStrings("valid", input.composition().bytes);
    try std.testing.expectEqualStrings("original", try input.message(ticket));
}

test "SessionInput retained loan and stale tickets cannot consume next composition" {
    var input: Self = undefined;
    input.init();
    for ("old") |byte| _ = input.feed(byte);
    const ticket = input.feed('\r').message;
    for ("new\x1b[D") |byte| _ = input.feed(byte);
    try std.testing.expectEqual(.busy, std.meta.activeTag(input.feed('\r')));
    try input.release(ticket);
    try std.testing.expectEqualStrings("new", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 2), input.composition().cursor);
    const next = input.feed('\r').message;
    try std.testing.expectError(error.SubmissionChanged, input.release(ticket));
    try std.testing.expectEqualStrings("new", try input.message(next));
}

test "one stream survives draft resets and replacement editors" {
    var input: Self = undefined;
    input.init();
    // A sequence split across a draft reset is decoded once: an arrow, not
    // its final byte as typed text.
    for ("draft\x1b[") |byte| _ = input.feed(byte);
    input.clear();
    try std.testing.expectEqual(keymap.Outcome(keymap.Key){ .action = .up }, input.feed('A').editor);
    try std.testing.expectEqualStrings("", input.composition().bytes);
    // An editor that replaces another mid-paste, like a fresh choice field,
    // rejects the paste's remainder instead of adopting it as typed input.
    var storage: [16]u8 = undefined;
    for ("\x1b[200~") |byte| _ = input.feed(byte);
    var choice: Editor = .{ .buffer = &storage, .allow_paste = false };
    for ("a\x1b[201~") |byte| _ = choice.feed(&input.stream, byte);
    try std.testing.expectEqualStrings("", storage[0..choice.length]);
    try std.testing.expect(std.meta.eql(choice.feed(&input.stream, '\r'), .{ .refused = .invalid }));
    try std.testing.expectEqual(Editor.Pending.none, input.pending());
}

test "a recalled Message is the draft until an edit, never a caret move" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "recalled", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "/sent\nagain", 0);
    var input: Self = undefined;
    input.init();
    const found: Found = .{ .at = .{ .position = 7, .end = 9 }, .length = "/sent\nagain".len, .slash = true };
    try input.fill(io, file, found);
    try std.testing.expectEqualStrings("//sent\nagain", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 12), input.composition().cursor);
    for ("\x1b[A\x1b[D\x1b[C\x01\x05\x1b[B") |byte| _ = input.feed(byte);
    try std.testing.expectEqual(found.at, input.recall.shown.?);
    // Each edit, even one that keeps the length (a paste rolled back as a
    // whole), makes it an ordinary draft.
    for ([_][]const u8{ "x", "\x7f", "\x01\x1b[3~", "\x15", "\x1b[200~p\x1b[201~", "\x02", "\xc3\xa9", "\x1b[200~\n\xcc\x81\x1b[201~" }) |edit| {
        try input.fill(io, file, found);
        const revision = input.revision;
        for (edit) |byte| _ = input.feed(byte);
        try std.testing.expect(input.recall.shown == null);
        try std.testing.expect(input.revision != revision);
    }
    try input.fill(io, file, .{ .at = found.at, .length = 5, .slash = false });
    try std.testing.expectEqualStrings("/sent", input.composition().bytes);
    // Without the second slash, text that begins with one runs as a command.
    try std.testing.expectEqual(.command, std.meta.activeTag(input.feed('\r')));
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
    for ("a") |byte| _ = input.feed(byte);
    try std.testing.expectEqual(.typed, input.press(true));
    try std.testing.expectEqual(Landing.stale, input.land(step, newest));
    try std.testing.expectEqualStrings("a", input.composition().bytes);
    try std.testing.expectEqual(@as(i32, 0), input.recall.pending);

    // Sending during a read: the sent draft's step lands nowhere.
    input.clear();
    _ = input.press(true);
    step = input.nextStep().?;
    try std.testing.expectEqual(Landing{ .show = newest }, input.land(step, newest));
    try input.fill(io, file, newest);
    _ = input.press(true);
    step = input.nextStep().?;
    try std.testing.expectEqual(@as(?Recalled, newest.at), step.from);
    const ticket = input.feed('\r').message;
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
    try input.fill(io, file, input.land(step, newest).show);
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

    // A step that lands once an Action's choice is set up: the presses that
    // waited are dropped, and the one read lands on the unchanged draft.
    _ = input.press(true);
    step = input.nextStep().?;
    for (0..3) |_| _ = input.press(true);
    input.dropPresses();
    try std.testing.expectEqual(Landing{ .show = newest }, input.land(step, newest));
    try std.testing.expect(input.nextStep() == null);
}

test "Tab completes a command word at the draft's end and adds a tab anywhere else" {
    const cases = [_]struct { typed: []const u8, shown: []const u8 }{
        .{ .typed = "/st\t", .shown = "/status" },
        .{ .typed = "/st\x1b[D\x1b[D\t", .shown = "/status" },
        .{ .typed = "/cop\t", .shown = "/copy " },
        .{ .typed = "/c\t", .shown = "/co" },
        .{ .typed = "/c\t\t", .shown = "/co" },
        .{ .typed = "/zz\t", .shown = "/zz" },
        .{ .typed = "/copy \t", .shown = "/copy \t" },
        .{ .typed = "//c\t", .shown = "//c\t" },
        .{ .typed = "hi\t", .shown = "hi\t" },
        .{ .typed = "\t", .shown = "\t" },
    };
    for (cases) |case| {
        var input: Self = undefined;
        input.init();
        for (case.typed) |byte| _ = input.feed(byte);
        try std.testing.expectEqualStrings(case.shown, input.composition().bytes);
        try std.testing.expectEqual(case.shown.len, input.composition().cursor);
    }
}
