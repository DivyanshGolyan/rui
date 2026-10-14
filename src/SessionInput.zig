//! One invocation's logical drafts. Initialize in final storage; never move.
const std = @import("std");
const Editor = @import("TerminalEditor.zig");
const Self = @This();

pub const capacity = 65_536;
pub const Ticket = struct { owner: *const Self, serial: u64 };
pub const Event = union(enum) { editor: Editor.Event, message: Ticket, command, busy };
pub const View = struct { bytes: []const u8, cursor: usize };

banks: [2][capacity]u8 = undefined,
editors: [2]Editor = undefined,
command_buffer: [capacity]u8 = undefined,
command_length: ?usize = null,
active: u1 = 0,
submitted: ?struct { bank: u1, literal: bool } = null,
serial: u64 = 0,

pub fn init(self: *Self) void {
    self.* = .{};
    for (&self.editors, &self.banks) |*editor, *bank| editor.* = .{ .buffer = bank };
}

pub fn composition(self: *const Self) View {
    const editor = &self.editors[self.active];
    return .{ .bytes = editor.buffer[0..editor.length], .cursor = editor.cursor };
}

pub fn pending(self: *const Self) Editor.Pending {
    return self.editors[self.active].pending();
}

pub fn expire(self: *Self) !void {
    try self.editors[self.active].expire();
}

pub fn feed(self: *Self, byte: u8) Event {
    return self.feedSelected(byte, true);
}

pub fn feedSelected(self: *Self, byte: u8, selected: bool) Event {
    const event = self.editors[self.active].feed(byte);
    if (event == .invalid or event == .overflow) self.clear();
    if (event != .submit) return .{ .editor = event };
    const bytes = self.composition().bytes;
    if (bytes.len == 0) return .{ .editor = .none };
    if (bytes[0] == '/' and !std.mem.startsWith(u8, bytes, "//")) {
        if (self.command_length != null) return .busy;
        @memcpy(self.command_buffer[0..bytes.len], bytes);
        self.command_length = bytes.len;
        self.clear();
        return .command;
    }
    if (!selected or self.submitted != null) return .busy;
    return .{ .message = self.seal(false) };
}

/// Command-line text was validated before Session creation. It is literal,
/// including leading slashes, and uses the same retained submission bank.
pub fn submitText(self: *Self, text: []const u8) Ticket {
    std.debug.assert(self.submitted == null and text.len <= capacity);
    const editor = &self.editors[self.active];
    @memcpy(editor.buffer[0..text.len], text);
    editor.length = text.len;
    editor.cursor = text.len;
    editor.plain_ascii = false;
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
    self.editors[self.active] = .{ .buffer = &self.banks[self.active] };
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
    self.editors[submitted.bank] = .{ .buffer = &self.banks[submitted.bank] };
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
    try std.testing.expectEqual(.invalid, input.feed('\r').editor);
    for ([_][]const u8{ "\x1b\n", "\x1b\r", "\x1b[20\n", "\x1b[201\r" }) |sequence| {
        for ("\x1b[200~left") |byte| _ = input.feed(byte);
        for (sequence) |byte| _ = input.feed(byte);
        try std.testing.expectEqual(Editor.Pending.incomplete, input.pending());
        for ("a\r") |byte| try std.testing.expectEqual(.none, input.feed(byte).editor);
        for ("\x1b[201~") |byte| _ = input.feed(byte);
        try std.testing.expectEqual(.invalid, input.feed('\r').editor);
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
