const std = @import("std");
const Editor = @import("DraftEditor.zig");
const keymap = @import("keymap.zig");
const slash_commands = @import("slash_commands.zig").conversation;
const Self = @This();
const media = @import("input_media.zig");
const parts = @import("input_parts.zig");
const protocol = @import("protocol.zig");

pub const max_image_bytes = 16 * 1024 * 1024;
pub const image_budget = 64 * 1024 * 1024;
pub const Image = struct {
    bytes: []const u8,
    identity: parts.Identity,

    pub fn validate(bytes: []const u8) !Image {
        var scanner = try media.Scanner.init(bytes.len, null, .{ .max_bytes = max_image_bytes });
        var allowance = bytes.len;
        _ = try scanner.advance(bytes, &allowance);
        return .{
            .bytes = bytes,
            .identity = .{ .length = bytes.len, .digest = protocol.contentDigest(bytes), .kind = .{ .image = .{ .media = try scanner.finish() } } },
        };
    }

    pub fn clone(self: Image) !Image {
        return .{ .bytes = try std.heap.page_allocator.dupe(u8, self.bytes), .identity = self.identity };
    }

    pub fn deinit(self: Image) void {
        std.heap.page_allocator.free(self.bytes);
    }
};

pub const capacity = 65_536;
pub const Ticket = struct { owner: *const Self, serial: u64 };
pub fn Event(comptime A: type) type {
    return union(enum) { editor: keymap.Outcome(A), message: Ticket, command, busy };
}
pub const View = struct { bytes: []const u8, cursor: usize };
pub const Snapshot = struct {
    bytes: []const u8,
    cursor: usize,
    anchor: ?Recalled = null,
    rejected: ?keymap.Refusal = null,
};
pub const Recalled = struct { position: u64, end: u64 };
pub const Recall = struct {
    shown: ?Recalled = null,
    pending: i32 = 0,
    reading: bool = false,
};
pub const Step = struct { from: ?Recalled, older: bool, revision: u64 };
pub const Found = struct { at: Recalled, length: usize, slash: bool };
pub const Landing = union(enum) {
    stale,
    oldest,
    emptied,
    show: Found,
};

banks: [2][capacity]u8 = undefined,
editors: [2]Editor = undefined,
images: [2]?Image = @splat(null),
command_buffer: [capacity]u8 = undefined,
command_length: ?usize = null,
active: u1 = 0,
submitted: ?struct { bank: u1, literal: bool, length: usize } = null,
serial: u64 = 0,
recall: Recall = .{},
revision: u64 = 0,

pub fn init(self: *Self) void {
    self.* = .{};
    for (&self.editors, 0..) |*editor, bank| editor.* = self.empty(@intCast(bank));
}

fn empty(self: *Self, bank: u1) Editor {
    return .init(&self.banks[bank]);
}

pub fn append(self: *Self, text: []const u8) Editor.KeyOutcome {
    return self.tracked(Editor.KeyOutcome, Editor.append, .{text});
}

pub fn replace(self: *Self, change: Editor.Replacement) Editor.KeyOutcome {
    return self.tracked(Editor.KeyOutcome, Editor.replace, .{change});
}

pub const Insertion = struct { owner: *const Self, revision: u64, bank: u1, caret: usize };

pub fn insertionTarget(self: *const Self) ?Insertion {
    const editor = &self.editors[self.active];
    if (editor.rejected != null or editor.pasting() or editor.area.partial_length != 0) return null;
    return .{ .owner = self, .revision = self.revision, .bank = self.active, .caret = editor.cursor() };
}

pub fn insertQuote(self: *Self, gpa: std.mem.Allocator, target: Insertion, body: []const u8) !Editor.KeyOutcome {
    if (!std.meta.eql(self.insertionTarget(), @as(?Insertion, target)) or body.len == 0) return .none;
    const draft = self.composition();
    const leading = target.caret != 0 and draft.bytes[target.caret - 1] != '\n';
    var length: usize = @intFromBool(leading);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.index == null and std.mem.endsWith(u8, body, "\n")) break;
        if (line.len > capacity or length > capacity - line.len) return .{ .refused = .overflow };
        length += line.len + 2 + @intFromBool(line.len != 0);
        if (length > capacity - draft.bytes.len) return .{ .refused = .overflow };
    }
    const markdown = try gpa.alloc(u8, length);
    defer gpa.free(markdown);
    var out = std.Io.Writer.fixed(markdown);
    if (leading) try out.writeByte('\n');
    lines.reset();
    while (lines.next()) |line| {
        if (line.len == 0 and lines.index == null and std.mem.endsWith(u8, body, "\n")) break;
        try out.writeByte('>');
        if (line.len != 0) try out.writeByte(' ');
        try out.writeAll(line);
        try out.writeByte('\n');
    }
    return self.tracked(std.mem.Allocator.Error!Editor.KeyOutcome, Editor.insertMultiline, .{ gpa, out.buffered() });
}

fn tracked(self: *Self, comptime Outcome: type, comptime method: anytype, args: anytype) Outcome {
    const editor = &self.editors[self.active];
    const edits = editor.edits;
    const outcome = @call(.auto, method, .{editor} ++ args);
    if (editor.edits != edits) self.changed();
    return outcome;
}

pub fn composition(self: *const Self) View {
    const editor = &self.editors[self.active];
    return .{ .bytes = editor.text(), .cursor = editor.cursor() };
}

pub fn snapshot(self: *const Self) Snapshot {
    const editor = &self.editors[self.active];
    return .{
        .bytes = editor.text(),
        .cursor = editor.cursor(),
        .anchor = self.recall.shown,
        .rejected = editor.rejected,
    };
}

pub fn restore(self: *Self, draft: Snapshot) void {
    self.restoreWithImage(draft, null);
}

pub fn restoreWithImage(self: *Self, draft: Snapshot, attachment: ?Image) void {
    std.debug.assert(draft.bytes.len <= capacity and draft.cursor <= draft.bytes.len);
    self.clear();
    self.images[self.active] = attachment;
    const editor = &self.editors[self.active];
    std.debug.assert(editor.set(draft.bytes, draft.cursor) == null);
    editor.rejected = draft.rejected;
    self.recall.shown = draft.anchor;
}

pub fn appEvent(self: *Self, comptime keys: anytype, event: @import("vaxis").vxfw.Event, pasting: bool, selected: bool) Event(@TypeOf(keys).Action) {
    const outcome = self.tracked(keymap.Outcome(@TypeOf(keys).Action), Editor.appEvent, .{ keys, event, pasting });
    if (outcome == .action and self.image() != null and event == .key_press and @import("keypress.zig").named(event.key_press) == .ctrl_d)
        return .{ .editor = .none };
    return self.accept(@TypeOf(keys).Action, outcome, selected);
}

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
    if (self.draftEmpty()) return .{ .editor = outcome };
    if (self.image() == null) switch (slash_commands.draftOf(bytes)) {
        .command => return if (self.admitsCommand()) .command else .busy,
        .message, .word => {},
    };
    if (!selected or self.submitted != null) return .busy;
    return .{ .message = self.seal(false, bytes.len) };
}

pub fn admitsCommand(self: *const Self) bool {
    return self.command_length == null;
}

pub fn queueCommand(self: *Self, text: []const u8) void {
    std.debug.assert(self.admitsCommand());
    @memcpy(self.command_buffer[0..text.len], text);
    self.command_length = text.len;
}

pub fn queuedCommand(self: *const Self) ?[]const u8 {
    return self.command_buffer[0 .. self.command_length orelse return null];
}

pub fn takeCommand(self: *Self) ?[]const u8 {
    const text = self.queuedCommand();
    self.command_length = null;
    return text;
}

pub fn submitText(self: *Self, text: []const u8) Ticket {
    std.debug.assert(self.submitted == null and text.len <= capacity);
    @memcpy(self.banks[self.active][0..text.len], text);
    return self.seal(true, text.len);
}

pub fn submitPreservingDraft(self: *Self, io: std.Io, file: std.Io.File, length: usize) !Ticket {
    std.debug.assert(self.submitted == null);
    if (length > capacity) return error.MessageTooLarge;
    const bank = self.active ^ 1;
    std.debug.assert(self.images[bank] == null);
    const bytes = self.banks[bank][0..length];
    if (try file.readPositionalAll(io, bytes, 0) != length) return error.TruncatedRetryScratch;
    self.editors[bank] = self.empty(bank);
    self.serial += 1;
    self.submitted = .{ .bank = bank, .literal = true, .length = length };
    return .{ .owner = self, .serial = self.serial };
}

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
    self.setImage(null);
}

pub fn setImage(self: *Self, attachment: ?Image) void {
    if (self.images[self.active]) |previous| previous.deinit();
    self.images[self.active] = attachment;
    self.changed();
}

pub fn image(self: *const Self) ?Image {
    return self.images[self.active];
}

pub fn draftEmpty(self: *const Self) bool {
    return self.image() == null and self.composition().bytes.len == 0;
}

pub fn submittedImageBytes(self: *const Self) usize {
    const bank = self.submitted orelse return 0;
    return if (self.images[bank.bank]) |attachment| attachment.bytes.len else 0;
}

pub fn deinit(self: *Self) void {
    for (&self.images) |*attachment| {
        if (attachment.*) |owned| owned.deinit();
        attachment.* = null;
    }
}

fn changed(self: *Self) void {
    self.revision +%= 1;
    self.recall.shown = null;
    self.recall.pending = 0;
}

pub fn press(self: *Self, older: bool) enum { queued, typed } {
    if (self.recall.shown == null and !self.draftEmpty()) return .typed;
    self.recall.pending += if (older) -1 else 1;
    return .queued;
}

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

pub fn abandonStep(self: *Self) void {
    self.recall.reading = false;
    self.recall.pending = 0;
}

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

pub fn fill(self: *Self, io: std.Io, file: std.Io.File, found: Found) !void {
    const editor = &self.editors[self.active];
    editor.* = self.empty(self.active);
    const bank = &self.banks[self.active];
    const start = @intFromBool(found.slash);
    if (found.slash) bank[0] = '/';
    if (try file.readPositionalAll(io, bank[start..][0..found.length], 0) != found.length) return error.TruncatedDisplayScratch;
    const length = start + found.length;
    std.debug.assert(editor.set(bank[0..length], length) == null);
    self.revision +%= 1;
    self.recall.shown = found.at;
}

pub fn message(self: *const Self, ticket: Ticket) ![]const u8 {
    const submitted = try self.checked(ticket);
    const bytes = self.banks[submitted.bank][0..submitted.length];
    return if (!submitted.literal and self.images[submitted.bank] == null and std.mem.startsWith(u8, bytes, "//")) bytes[1..] else bytes;
}

pub fn messageImage(self: *const Self, ticket: Ticket) !?Image {
    return self.images[(try self.checked(ticket)).bank];
}

pub fn release(self: *Self, ticket: Ticket) !void {
    const submitted = try self.checked(ticket);
    self.editors[submitted.bank] = self.empty(submitted.bank);
    if (self.images[submitted.bank]) |attachment| attachment.deinit();
    self.images[submitted.bank] = null;
    self.submitted = null;
}

fn checked(self: *const Self, ticket: Ticket) !@TypeOf(self.submitted.?) {
    if (ticket.owner != self or ticket.serial != self.serial) return error.SubmissionChanged;
    return self.submitted orelse error.NoSubmission;
}

test "SessionInput snapshot restore keeps recall anchor and submitted loan independent" {
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
    try input.fill(io, file, found);
    _ = input.typed("\x1b[D");
    var saved = input.snapshot();
    const bytes = try gpa.dupe(u8, saved.bytes);
    defer gpa.free(bytes);
    saved.bytes = bytes;
    _ = input.press(true);
    const step = input.nextStep().?;
    input.clear();
    _ = input.typed("discarded");
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
    try std.testing.expectEqual(.redraw, input.typed("\t").editor);
    try std.testing.expectEqualStrings("aé\tZ", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, "aé\t".len), input.composition().cursor);
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
    try input.fill(io, file, found);
    try std.testing.expectEqualStrings("//copy\nagain", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 12), input.composition().cursor);
    _ = input.typed("\x1b[A\x1b[D\x1b[C\x01\x05\x1b[B");
    try std.testing.expectEqual(found.at, input.recall.shown.?);
    for ([_][]const u8{ "x", "\x7f", "\x01\x1b[3~", "\x15", "\x1b[200~p\x1b[201~", "\xff", "\xc3\xa9", "\x1b[200~\n\xcc\x81\x1b[201~" }) |edit| {
        try input.fill(io, file, found);
        const revision = input.revision;
        _ = input.typed(edit);
        try std.testing.expect(input.recall.shown == null);
        try std.testing.expect(input.revision != revision);
    }
    try input.fill(io, file, .{ .at = found.at, .length = 5, .slash = false });
    try std.testing.expectEqualStrings("/copy", input.composition().bytes);
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

    try std.testing.expectEqual(.queued, input.press(true));
    var step = input.nextStep().?;
    try std.testing.expectEqual(@as(?Recalled, null), step.from);
    try std.testing.expect(input.nextStep() == null);
    _ = input.typed("a");
    try std.testing.expectEqual(.typed, input.press(true));
    try std.testing.expectEqual(Landing.stale, input.land(step, newest));
    try std.testing.expectEqualStrings("a", input.composition().bytes);
    try std.testing.expectEqual(@as(i32, 0), input.recall.pending);

    input.clear();
    _ = input.press(true);
    step = input.nextStep().?;
    try std.testing.expectEqual(Landing{ .show = newest }, input.land(step, newest));
    try input.fill(io, file, newest);
    _ = input.press(true);
    step = input.nextStep().?;
    try std.testing.expectEqual(@as(?Recalled, newest.at), step.from);
    const ticket = input.typed("\r").message;
    try std.testing.expectEqual(Landing.stale, input.land(step, newest));
    try std.testing.expectEqualStrings("", input.composition().bytes);
    try std.testing.expectEqualStrings("newest", try input.message(ticket));
    try input.release(ticket);

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
    _ = input.press(false);
    try std.testing.expectEqual(Landing.oldest, input.land(step, null));
    try std.testing.expectEqualStrings("newest", input.composition().bytes);
    step = input.nextStep().?;
    try std.testing.expect(!step.older);
    try std.testing.expectEqual(Landing.emptied, input.land(step, null));
    try std.testing.expectEqualStrings("", input.composition().bytes);
    try std.testing.expect(input.recall.shown == null);
    _ = input.press(false);
    try std.testing.expect(input.nextStep() == null);
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

test "quote insertion preserves draft banks revision and caret ownership" {
    const gpa = std.testing.allocator;
    const self = try gpa.create(Self);
    defer gpa.destroy(self);
    self.init();
    const ticket = self.submitText("loaned original");
    _ = self.append("leftRIGHT");
    self.editors[self.active].setCursor(4);
    const target = self.insertionTarget().?;
    const revision = self.revision;
    try std.testing.expectEqual(Editor.KeyOutcome.redraw, try self.insertQuote(gpa, target, "雪e\u{301}\n\n  indented"));
    try std.testing.expectEqualStrings("left\n> 雪e\u{301}\n>\n>   indented\nRIGHT", self.composition().bytes);
    try std.testing.expectEqual(@as(usize, "left\n> 雪e\u{301}\n>\n>   indented\n".len), self.composition().cursor);
    try std.testing.expectEqual(revision + 1, self.revision);
    try std.testing.expectEqualStrings("loaned original", try self.message(ticket));
    const after = self.composition();
    try std.testing.expectEqual(Editor.KeyOutcome.none, try self.insertQuote(gpa, target, "stale"));
    try std.testing.expectEqualStrings(after.bytes, self.composition().bytes);
    const moved = self.insertionTarget().?;
    self.editors[self.active].setCursor(0);
    try std.testing.expectEqual(Editor.KeyOutcome.none, try self.insertQuote(gpa, moved, "stale caret"));
    try std.testing.expectEqual(@as(usize, 0), self.composition().cursor);
}

test "quote insertion overflow leaves the draft usable and untouched" {
    const gpa = std.testing.allocator;
    const self = try gpa.create(Self);
    defer gpa.destroy(self);
    self.init();
    var text: [capacity - 1]u8 = @splat('a');
    _ = self.append(&text);
    self.editors[self.active].setCursor(3);
    const target = self.insertionTarget().?;
    const revision = self.revision;
    try std.testing.expectEqual(Editor.KeyOutcome{ .refused = .overflow }, try self.insertQuote(gpa, target, "a"));
    try std.testing.expectEqualStrings(&text, self.composition().bytes);
    try std.testing.expectEqual(@as(usize, 3), self.composition().cursor);
    try std.testing.expectEqual(revision, self.revision);
    try std.testing.expectEqual(null, self.editors[self.active].rejected);
    try std.testing.expect(self.typed("\r") == .message);
}

test "quote insertion never moves an existing regional indicator suffix into the quote" {
    const gpa = std.testing.allocator;
    const self = try gpa.create(Self);
    defer gpa.destroy(self);
    self.init();
    _ = self.append("🇧 original suffix");
    self.editors[self.active].setCursor(0);
    try std.testing.expectEqual(Editor.KeyOutcome.redraw, try self.insertQuote(gpa, self.insertionTarget().?, "🇦"));
    try std.testing.expectEqualStrings("> 🇦\n🇧 original suffix", self.composition().bytes);
    try std.testing.expectEqual(@as(usize, "> 🇦\n".len), self.composition().cursor);
}
