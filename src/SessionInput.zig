//! One invocation's logical drafts. Initialize in final storage; never move.
const std = @import("std");
const Editor = @import("TerminalEditor.zig");
const Self = @This();

pub const capacity = 65_536;
pub const State = enum { submitting, unconfirmed, rejected };
pub const Ticket = struct { owner: *const Self, serial: u64 };
pub const Event = union(enum) { editor: Editor.Event, message: Ticket, command, busy };
pub const View = struct { bytes: []const u8, cursor: usize };

banks: [2][capacity]u8 = undefined,
editors: [2]Editor = undefined,
command_buffer: [capacity]u8 = undefined,
command_length: ?usize = null,
active: u1 = 0,
submitted: ?struct { bank: u1, state: State } = null,
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
    self.serial += 1;
    self.submitted = .{ .bank = self.active, .state = .submitting };
    self.active ^= 1;
    self.clear();
    return .{ .message = .{ .owner = self, .serial = self.serial } };
}

pub fn clear(self: *Self) void {
    self.editors[self.active] = .{ .buffer = &self.banks[self.active] };
}

/// The frontend retains this immutable loan through capture return and join.
pub fn message(self: *const Self, ticket: Ticket) ![]const u8 {
    const submitted = try self.checked(ticket);
    const editor = &self.editors[submitted.bank];
    const bytes = editor.buffer[0..editor.length];
    return if (std.mem.startsWith(u8, bytes, "//")) bytes[1..] else bytes;
}

/// Only the joined capture/send owner calls transitions. Acceptance is a Host
/// fact, not successful capture, a worker completion hint or a local timeout.
pub fn settle(self: *Self, ticket: Ticket, state: ?State) !void {
    const submitted = try self.checked(ticket);
    if (state) |value| {
        self.submitted.?.state = value;
    } else {
        self.editors[submitted.bank] = .{ .buffer = &self.banks[submitted.bank] };
        self.submitted = null;
    }
}

pub fn discard(self: *Self, ticket: Ticket) !void {
    if ((try self.checked(ticket)).state != .rejected) return error.SubmissionUnresolved;
    try self.settle(ticket, null);
}

fn checked(self: *const Self, ticket: Ticket) !@TypeOf(self.submitted.?) {
    if (ticket.owner != self or ticket.serial != self.serial) return error.SubmissionChanged;
    return self.submitted orelse error.NoSubmission;
}

test "SessionInput acceptance preserves next Unicode draft and cursor" {
    var input: Self = undefined;
    input.init();
    for ("aéZ\x1b[D") |byte| _ = input.feed(byte);
    const ticket = input.feed('\r').message;
    for ("next!\x1b[D\x1b[D") |byte| _ = input.feed(byte);
    try std.testing.expectEqualStrings("aéZ", try input.message(ticket));
    try input.settle(ticket, null);
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
    for ("valid") |byte| _ = input.feed(byte);
    try std.testing.expectEqualStrings("valid", input.composition().bytes);
    try std.testing.expectEqualStrings("original", try input.message(ticket));
}

test "SessionInput retained rejection and stale tickets cannot consume next composition" {
    var input: Self = undefined;
    input.init();
    for ("old") |byte| _ = input.feed(byte);
    const ticket = input.feed('\r').message;
    for ("new\x1b[D") |byte| _ = input.feed(byte);
    try input.settle(ticket, .unconfirmed);
    try std.testing.expectEqual(.busy, std.meta.activeTag(input.feed('\r')));
    try std.testing.expectError(error.SubmissionUnresolved, input.discard(ticket));
    try input.settle(ticket, .rejected);
    try input.discard(ticket);
    try std.testing.expectEqualStrings("new", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 2), input.composition().cursor);
    const next = input.feed('\r').message;
    try std.testing.expectError(error.SubmissionChanged, input.settle(ticket, null));
    try std.testing.expectEqualStrings("new", try input.message(next));
}
