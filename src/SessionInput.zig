const std = @import("std");
const Input = @This();
const Editor = @import("TerminalEditor.zig");

pub const capacity = 65_536;
pub const State = enum { ready, capture_failed, not_sent, unconfirmed, rejected };
pub const Outcome = enum { accepted, not_sent, unconfirmed, rejected };
/// Treat as opaque; associates local outcomes, not Host identity or authority.
pub const Ticket = struct { owner: *const Input, serial: u64 };
pub const Event = union(enum) { editor: Editor.Event, message: Ticket, command, busy };
pub const View = struct { bytes: []const u8, cursor: usize };
const Submission = struct { bank: u1, state: State };

banks: [2][capacity]u8,
editors: [2]Editor,
active: u1 = 0,
submitted: ?Submission = null,
serial: u64 = 0,
message_borrowed: bool = false,
command_bank: [capacity]u8,
command_length: ?usize = null,
command_borrowed: bool = false,

/// Initialize in final storage; do not copy or move this pointer-bearing owner.
pub fn init(self: *Input) void {
    self.* = .{ .banks = undefined, .editors = undefined, .command_bank = undefined };
    for (&self.editors, &self.banks) |*editor, *bank| editor.* = .{ .buffer = bank };
}

/// View borrows the active draft until the next mutation.
pub fn composition(self: *const Input) View {
    const editor = &self.editors[self.active];
    return .{ .bytes = editor.buffer[0..editor.length], .cursor = editor.cursor };
}

/// Parser custody belongs to the active logical composition, not its layout.
pub fn pending(self: *const Input) Editor.Pending {
    return self.editors[self.active].pending();
}

pub fn expire(self: *Input) !void {
    try self.editors[self.active].expire();
}

pub fn submissionState(self: *const Input) ?State {
    return if (self.submitted) |submitted| submitted.state else null;
}

/// Borrows the sealed logical draft/cursor until settlement or explicit discard.
pub fn retained(self: *const Input) ?View {
    const submitted = self.submitted orelse return null;
    const editor = &self.editors[submitted.bank];
    return .{ .bytes = editor.buffer[0..editor.length], .cursor = editor.cursor };
}

/// Only a definite retained rejection may be explicitly abandoned. A later
/// ready/not-sent/unconfirmed submission cannot be released by an old decision.
pub fn discardRejected(self: *Input, ticket: Ticket) !void {
    const submitted = try self.checkedSubmission(ticket);
    if (submitted.state != .rejected) return error.SubmissionNotRejected;
    self.editors[submitted.bank] = .{ .buffer = &self.banks[submitted.bank] };
    self.submitted = null;
}

pub fn feed(self: *Input, byte: u8) Event {
    return self.feedForSelection(byte, true);
}

/// Selection may fence submission, never parser ingress or command custody.
pub fn feedForSelection(self: *Input, byte: u8, selected: bool) Event {
    const event = self.editors[self.active].feed(byte);
    if (event != .submit) return .{ .editor = event };
    const bytes = self.composition().bytes;
    if (bytes.len == 0) return .{ .editor = .none };
    if (bytes[0] == '/' and !std.mem.startsWith(u8, bytes, "//")) {
        if (self.command_length != null) return .busy;
        @memcpy(self.command_bank[0..bytes.len], bytes);
        self.command_length = bytes.len;
        self.clearComposition();
        return .command;
    }
    if (!selected or self.submitted != null) return .busy;
    self.serial += 1;
    self.submitted = .{ .bank = self.active, .state = .ready };
    self.active ^= 1;
    self.editors[self.active] = .{ .buffer = &self.banks[self.active] };
    return .{ .message = .{ .owner = self, .serial = self.serial } };
}

pub fn clearComposition(self: *Input) void {
    self.editors[self.active] = .{ .buffer = &self.banks[self.active] };
}

/// Mutable command bytes are loaned only through this synchronous handler.
pub fn withCommand(self: *Input, handler: anytype) !void {
    if (self.command_borrowed) return error.CommandBorrowed;
    const length = self.command_length orelse return error.NoCommand;
    self.command_borrowed = true;
    defer {
        self.command_borrowed = false;
        self.command_length = null;
    }
    try handler.command(self.command_bank[0..length]);
}

/// The capturer returns its actual owned immutable record. Mark captured before
/// returning it: no fallible announcement can reopen fresh-capture eligibility.
/// An error can follow publication. Retain the draft, fence fresh capture/send,
/// and leave explicit saved-record recovery to Client, not this input owner.
pub fn capture(self: *Input, ticket: Ticket, capturer: anytype) !@typeInfo(@TypeOf(capturer.capture(""))).error_union.payload {
    const submitted = try self.checkedSubmission(ticket);
    if (submitted.state != .ready) return error.SubmissionUnresolved;
    self.message_borrowed = true;
    defer self.message_borrowed = false;
    errdefer self.submitted.?.state = .capture_failed;
    const editor = &self.editors[submitted.bank];
    const bytes = editor.buffer[0..editor.length];
    const record = try capturer.capture(if (std.mem.startsWith(u8, bytes, "//")) bytes[1..] else bytes);
    self.submitted.?.state = .not_sent;
    return record;
}

/// Explicit recovery opens/validates the original saved record, never creates
/// replacement intent. The adapter checks its original destination and these
/// exact Message bytes; no bank releases before a confirmed Host outcome.
pub fn recover(self: *Input, ticket: Ticket, recovery: anytype) !@typeInfo(@TypeOf(recovery.recover(""))).error_union.payload {
    const submitted = try self.checkedSubmission(ticket);
    if (submitted.state != .capture_failed) return error.CaptureNotFailed;
    self.message_borrowed = true;
    defer self.message_borrowed = false;
    const bytes = self.retained().?.bytes;
    const record = try recovery.recover(if (std.mem.startsWith(u8, bytes, "//")) bytes[1..] else bytes);
    self.submitted.?.state = .not_sent;
    return record;
}

pub fn resolve(self: *Input, ticket: Ticket, outcome: Outcome) !void {
    const submitted = try self.checkedSubmission(ticket);
    if (submitted.state == .ready or submitted.state == .capture_failed) return error.SubmissionNotCaptured;
    if (submitted.state == .rejected) return error.SubmissionRejected;
    switch (outcome) {
        .accepted => {
            self.editors[submitted.bank] = .{ .buffer = &self.banks[submitted.bank] };
            self.submitted = null;
        },
        .rejected => {
            if (self.editors[self.active].pristine()) {
                self.active = submitted.bank;
                self.submitted = null;
            } else self.submitted.?.state = .rejected;
        },
        .unconfirmed => self.submitted.?.state = .unconfirmed,
        .not_sent => if (submitted.state != .unconfirmed) {
            self.submitted.?.state = .not_sent;
        },
    }
}

fn checkedSubmission(self: *Input, ticket: Ticket) !Submission {
    if (self.message_borrowed) return error.InputBorrowed;
    if (ticket.owner != self or ticket.serial != self.serial) return error.SubmissionChanged;
    return self.submitted orelse error.NoSubmission;
}

fn seal(input: *Input, bytes: []const u8) !Ticket {
    for (bytes) |byte| _ = input.feed(byte);
    const event = input.feed('\r');
    try std.testing.expectEqual(.message, std.meta.activeTag(event));
    return event.message;
}

test "SessionInput seals original cursor before later composition and acceptance" {
    var input: Input = undefined;
    input.init();
    for ("aéZ\x1b[D") |byte| _ = input.feed(byte);
    try std.testing.expectEqual(@as(usize, 3), input.composition().cursor);
    const ticket = try seal(&input, "");
    for ("next!\x1b[D\x1b[D") |byte| _ = input.feed(byte);
    const Capture = struct {
        pub fn capture(_: @This(), bytes: []const u8) !u8 {
            try std.testing.expectEqualStrings("aéZ", bytes);
            return 42;
        }
    };
    try std.testing.expectEqual(@as(u8, 42), try input.capture(ticket, Capture{}));
    try input.resolve(ticket, .accepted);
    try std.testing.expectEqualStrings("next!", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 3), input.composition().cursor);
    try std.testing.expect(input.submissionState() == null);
}

test "SessionInput failed capture releases its loan without losing either draft" {
    var input: Input = undefined;
    input.init();
    const ticket = try seal(&input, "old");
    const Forbidden = struct {
        pub fn capture(_: @This(), _: []const u8) !u8 {
            return error.UnexpectedCapture;
        }
    };
    const Failed = struct {
        input: *Input,
        ticket: Ticket,
        pub fn capture(self: @This(), bytes: []const u8) !u8 {
            try std.testing.expectEqualStrings("old", bytes);
            try std.testing.expectError(error.InputBorrowed, self.input.capture(self.ticket, Forbidden{}));
            try std.testing.expectError(error.InputBorrowed, self.input.resolve(self.ticket, .accepted));
            try std.testing.expectError(error.InputBorrowed, self.input.discardRejected(self.ticket));
            for ("next!\x1b[D") |byte| _ = self.input.feed(byte);
            try std.testing.expectEqualStrings("old", bytes);
            return error.CaptureFailed;
        }
    };
    try std.testing.expectError(error.CaptureFailed, input.capture(ticket, Failed{ .input = &input, .ticket = ticket }));
    try std.testing.expectEqual(.capture_failed, input.submissionState().?);
    try std.testing.expectEqualStrings("next!", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 4), input.composition().cursor);
    try std.testing.expectEqualStrings("old", input.retained().?.bytes);
    try std.testing.expectError(error.SubmissionUnresolved, input.capture(ticket, Forbidden{}));
    try std.testing.expectError(error.SubmissionNotCaptured, input.resolve(ticket, .accepted));
}

test "SessionInput unresolved submission blocks send not editing and cannot lose uncertainty" {
    var input: Input = undefined;
    input.init();
    const ticket = try seal(&input, "original");
    for ("new\x1b[D") |byte| _ = input.feed(byte);
    const Capture = struct {
        pub fn capture(_: @This(), bytes: []const u8) !void {
            try std.testing.expectEqualStrings("original", bytes);
        }
    };
    try input.capture(ticket, Capture{});
    try input.resolve(ticket, .unconfirmed);
    try std.testing.expectEqual(.busy, std.meta.activeTag(input.feed('\r')));
    try input.resolve(ticket, .not_sent);
    try std.testing.expectEqual(.unconfirmed, input.submissionState().?);
    try std.testing.expectEqualStrings("new", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 2), input.composition().cursor);
    try std.testing.expectError(error.SubmissionUnresolved, input.capture(ticket, Capture{}));
}

test "SessionInput rejection restores only pristine composition including invisible input" {
    const cases = [_]struct { bytes: []const u8, restores: bool, tail: []const u8 = "", expected: []const u8 = "" }{
        .{ .bytes = "", .restores = true },
        .{ .bytes = "new", .restores = false, .expected = "new" },
        .{ .bytes = "\xc3", .restores = false, .tail = "\xa9", .expected = "é" },
        .{ .bytes = "\x1b[", .restores = false, .tail = "Dq", .expected = "q" },
        .{ .bytes = "\x1b[200~", .restores = false, .tail = "p\x1b[201~", .expected = "p" },
        .{ .bytes = "\xff", .restores = false },
    };
    for (cases) |case| {
        var input: Input = undefined;
        input.init();
        const ticket = try seal(&input, "aéZ\x1b[D");
        const Capture = struct {
            pub fn capture(_: @This(), bytes: []const u8) !void {
                try std.testing.expectEqualStrings("aéZ", bytes);
            }
        };
        try input.capture(ticket, Capture{});
        for (case.bytes) |byte| _ = input.feed(byte);
        try input.resolve(ticket, .rejected);
        if (case.restores) {
            try std.testing.expect(input.submissionState() == null);
            try std.testing.expectEqualStrings("aéZ", input.composition().bytes);
            try std.testing.expectEqual(@as(usize, 3), input.composition().cursor);
        } else {
            try std.testing.expectEqual(@as(?State, .rejected), input.submissionState());
            for (case.tail) |byte| _ = input.feed(byte);
            try std.testing.expectEqualStrings(case.expected, input.composition().bytes);
            try std.testing.expectEqualStrings("aéZ", input.retained().?.bytes);
            try std.testing.expectEqual(@as(usize, 3), input.retained().?.cursor);
        }
    }
}

test "SessionInput command failure releases only its independent mutable loan" {
    var input: Input = undefined;
    input.init();
    for ("original\r/status") |byte| _ = input.feed(byte);
    try std.testing.expectEqual(.command, std.meta.activeTag(input.feed('\r')));
    const NoCommand = struct {
        pub fn command(_: @This(), _: []u8) !void {
            return error.UnexpectedCommand;
        }
    };
    const Failed = struct {
        input: *Input,
        pub fn command(self: @This(), bytes: []u8) !void {
            try std.testing.expectEqualStrings("/status", bytes);
            bytes[1] = 'S';
            try std.testing.expectError(error.CommandBorrowed, self.input.withCommand(NoCommand{}));
            for ("/nested") |byte| _ = self.input.feed(byte);
            try std.testing.expectEqual(.busy, std.meta.activeTag(self.input.feed('\r')));
            try std.testing.expectEqualStrings("/Status", bytes);
            self.input.clearComposition();
            for ("new\x1b[D") |byte| _ = self.input.feed(byte);
            return error.HandlerFailed;
        }
    };
    try std.testing.expectError(error.HandlerFailed, input.withCommand(Failed{ .input = &input }));
    try std.testing.expectEqualStrings("new", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 2), input.composition().cursor);
    try std.testing.expectEqual(@as(?State, .ready), input.submissionState());
    input.clearComposition();
    for ("/again") |byte| _ = input.feed(byte);
    try std.testing.expectEqual(.command, std.meta.activeTag(input.feed('\r')));
    try std.testing.expectError(error.UnexpectedCommand, input.withCommand(NoCommand{}));
}

test "SessionInput retained rejection cannot be settled again" {
    var input: Input = undefined;
    input.init();
    const ticket = try seal(&input, "original");
    for ("next") |byte| _ = input.feed(byte);
    const Capture = struct {
        pub fn capture(_: @This(), _: []const u8) !void {}
    };
    try input.capture(ticket, Capture{});
    try input.resolve(ticket, .rejected);
    for (std.enums.values(Outcome)) |outcome| {
        try std.testing.expectError(error.SubmissionRejected, input.resolve(ticket, outcome));
        try std.testing.expectEqual(.rejected, input.submissionState().?);
        try std.testing.expectEqualStrings("next", input.composition().bytes);
    }
}

test "SessionInput slash escape changes Message bytes not restored logical draft" {
    var input: Input = undefined;
    input.init();
    const ticket = try seal(&input, "//aéZ\x1b[D");
    const Capture = struct {
        pub fn capture(_: @This(), bytes: []const u8) !void {
            try std.testing.expectEqualStrings("/aéZ", bytes);
        }
    };
    try input.capture(ticket, Capture{});
    try input.resolve(ticket, .rejected);
    try std.testing.expectEqualStrings("//aéZ", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 5), input.composition().cursor);
}

test "SessionInput discard is rejection-only and cannot release later custody" {
    var input: Input = undefined;
    input.init();
    const Capture = struct {
        pub fn capture(_: @This(), _: []const u8) !void {}
    };
    const ticket = try seal(&input, "old\x1b[D");
    for ("next\x1b[D") |byte| _ = input.feed(byte);
    try std.testing.expectError(error.SubmissionNotRejected, input.discardRejected(ticket));
    try input.capture(ticket, Capture{});
    try std.testing.expectError(error.SubmissionNotRejected, input.discardRejected(ticket));
    try input.resolve(ticket, .unconfirmed);
    try std.testing.expectError(error.SubmissionNotRejected, input.discardRejected(ticket));
    try input.resolve(ticket, .rejected);
    try std.testing.expectEqualStrings("old", input.retained().?.bytes);
    try std.testing.expectEqual(@as(usize, 2), input.retained().?.cursor);
    try input.discardRejected(ticket);
    try std.testing.expectError(error.NoSubmission, input.discardRejected(ticket));
    try std.testing.expectEqualStrings("next", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 3), input.composition().cursor);
    const next = try seal(&input, "");
    try std.testing.expectError(error.SubmissionChanged, input.discardRejected(ticket));
    try std.testing.expectError(error.SubmissionNotRejected, input.discardRejected(next));
    try std.testing.expectEqualStrings("next", input.retained().?.bytes);
}

test "SessionInput exact byte capacity seals complete input crossing remains sticky" {
    var input: Input = undefined;
    input.init();
    for (0..capacity) |_| _ = input.feed('x');
    const ticket = try seal(&input, "");
    const Capture = struct {
        pub fn capture(_: @This(), bytes: []const u8) !void {
            try std.testing.expectEqual(@as(usize, 65_536), bytes.len);
            for (bytes) |byte| try std.testing.expectEqual(@as(u8, 'x'), byte);
        }
    };
    try input.capture(ticket, Capture{});
    try input.resolve(ticket, .accepted);
    for (0..capacity) |_| _ = input.feed('y');
    _ = input.feed('z');
    _ = input.feed(127);
    try std.testing.expectEqual(.overflow, input.feed('\r').editor);
    try std.testing.expect(input.submissionState() == null);
    input.clearComposition();
    _ = input.feed('q');
    try std.testing.expectEqual(.message, std.meta.activeTag(input.feed('\r')));
    try std.testing.expectEqualStrings("q", input.retained().?.bytes);
}

test "SessionInput failed publication needs explicit original recovery and releases failed recovery loan" {
    var input: Input = undefined;
    input.init();
    const ticket = try seal(&input, "//original");
    for ("next") |byte| _ = input.feed(byte);
    const Failed = struct {
        pub fn capture(_: @This(), _: []const u8) !u8 {
            return error.PublicationUnconfirmed;
        }
    };
    const Recovery = struct {
        input: *Input,
        ticket: Ticket,
        fails: bool,
        pub fn recover(self: @This(), bytes: []const u8) anyerror!u8 {
            try std.testing.expectEqualStrings("/original", bytes);
            try std.testing.expectError(error.InputBorrowed, self.input.resolve(self.ticket, .accepted));
            try std.testing.expectError(error.InputBorrowed, self.input.recover(self.ticket, self));
            if (self.fails) return error.RecordUnavailable;
            return 17;
        }
    };
    try std.testing.expectError(error.CaptureNotFailed, input.recover(ticket, Recovery{ .input = &input, .ticket = ticket, .fails = false }));
    try std.testing.expectError(error.PublicationUnconfirmed, input.capture(ticket, Failed{}));
    try std.testing.expectError(error.RecordUnavailable, input.recover(ticket, Recovery{ .input = &input, .ticket = ticket, .fails = true }));
    try std.testing.expectEqual(.capture_failed, input.submissionState().?);
    try std.testing.expectEqual(@as(u8, 17), try input.recover(ticket, Recovery{ .input = &input, .ticket = ticket, .fails = false }));
    try std.testing.expectEqual(.not_sent, input.submissionState().?);
    try input.resolve(ticket, .accepted);
    try std.testing.expectEqualStrings("next", input.composition().bytes);
}

test "SessionInput stale acceptance cannot release a later captured submission" {
    var input: Input = undefined;
    input.init();
    const Capture = struct {
        pub fn capture(_: @This(), _: []const u8) !void {}
    };
    const first = try seal(&input, "A");
    try input.capture(first, Capture{});
    try input.resolve(first, .accepted);
    const second = try seal(&input, "Bé!\x1b[D");
    for ("next\x1b[D") |byte| _ = input.feed(byte);
    try input.capture(second, Capture{});
    // Duplicate A acceptance, not a confirmed answer for B.
    try std.testing.expectError(error.SubmissionChanged, input.resolve(first, .accepted));
    try std.testing.expectError(error.SubmissionChanged, input.discardRejected(first));
    try std.testing.expectEqualStrings("Bé!", input.retained().?.bytes);
    try std.testing.expectEqual(@as(usize, 3), input.retained().?.cursor);
    try std.testing.expectEqualStrings("next", input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 3), input.composition().cursor);
    var foreign: Input = undefined;
    foreign.init();
    const prior = try seal(&foreign, "prior");
    try foreign.capture(prior, Capture{});
    try foreign.resolve(prior, .accepted);
    const other = try seal(&foreign, "foreign");
    try std.testing.expectError(error.SubmissionChanged, input.resolve(other, .accepted));
    try input.resolve(second, .accepted);
    try std.testing.expectEqualStrings("next", input.composition().bytes);
}
