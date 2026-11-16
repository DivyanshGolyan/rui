const std = @import("std");
const submission = @import("submission_state.zig");
const ConsentPolicy = @import("session_consent.zig");

pub const Held = struct { kind: submission.Kind, state: submission.State, failure: ?Failure = null };

pub const Failure = struct { line: []const u8, key: Key };

pub const Key = enum { retry, discard, status };

pub fn key(held: Held) ?Key {
    if (held.failure) |failure| return failure.key;
    return switch (held.state) {
        .not_started, .unconfirmed => .retry,
        .submitting => null,
        .rejected => .discard,
    };
}

pub const too_large = "! Environment too large; nothing sent · details";

pub fn status(opening: bool, waiting: bool, held: ?Held) ?[]const u8 {
    if (opening) return "Opening…";
    if (waiting) return "";
    const original = held orelse return null;
    if (original.failure) |failure| return failure.line;
    return switch (original.state) {
        .not_started => "Not sent · ctrl+r retries original",
        .submitting => "Sending…",
        .unconfirmed => if (original.kind == .decision) "! Decision not confirmed · ctrl+r retries original" else "! Not confirmed · ctrl+r retries original",
        .rejected => "Rejected · /discard",
    };
}

pub const Action = struct {
    preview: bool,
    visible: bool,
    reason: bool,
};

pub fn decision(action: Action) []const u8 {
    if (action.preview) return "! Action exceeds in-app preview. Approval disabled. Draft retained.";
    return if (action.visible) "! Action needs a decision; Esc returns to the choice. Draft retained." else "! Action needs a decision; Esc returns to it. Draft retained.";
}

pub const reason_not_ready = "! Not ready; nothing denied · " ++ ConsentPolicy.deny_words;

pub const Busy = struct {
    command: bool,
    held: ?Held,
    preparing: bool,
    action: ?Action,
    letter: bool,
};

pub fn busy(facts: Busy) []const u8 {
    if (facts.command) return "! Command still running. Draft retained.";
    if (facts.held) |held| if (held.state == .rejected) return "! Original rejected. Keep editing; /discard releases it. Draft retained.";
    if (facts.preparing) return "! Action needs a decision. Draft retained.";
    if (facts.action) |action| {
        if (!action.reason) return decision(action);
        return if (facts.letter) "! Use ←→ and Enter to choose; a message denies the call." else reason_not_ready;
    }
    if (facts.held) |held| if (held.kind == .decision) return "! Decision pending. Keep editing; Ctrl-R retries that decision.";
    return "! Input still pending. Keep editing; Ctrl-R retries the original.";
}

pub const Close = union(enum) { leave, stay: []const u8 };

pub fn close(held: ?submission.State, published: bool, draft_empty: bool) Close {
    if (held) |state| switch (state) {
        .not_started => return .{ .stay = "Esc returns to the overview once Ctrl-R retries the original." },
        .submitting => return .{ .stay = "Esc returns to the overview once the original is confirmed." },
        .unconfirmed => if (!published) return .{ .stay = "Esc returns to the overview once Ctrl-R retries the original." },
        .rejected => {},
    };
    return if (draft_empty) .leave else .{ .stay = "Esc returns to the overview once the draft is empty." };
}

pub fn follow(held: ?submission.State, published: bool, draft_empty: bool, action: bool, command: bool) Close {
    if (action) return .{ .stay = "Links open once the Action is decided." };
    if (command) return .{ .stay = "Links open once the command ends." };
    return close(held, published, draft_empty);
}

test "a Session link leaves only where Esc would, and never past a waiting Action or command" {
    try std.testing.expectEqual(Close.leave, follow(null, false, true, false, false));
    try std.testing.expectEqualStrings("Esc returns to the overview once the draft is empty.", follow(null, false, false, false, false).stay);
    try std.testing.expectEqualStrings("Esc returns to the overview once the original is confirmed.", follow(.submitting, false, true, false, false).stay);
    try std.testing.expectEqualStrings("Links open once the Action is decided.", follow(null, false, true, true, true).stay);
    try std.testing.expectEqualStrings("Links open once the command ends.", follow(null, false, true, false, true).stay);
}

test "the status says the opening first, nothing over a waiting Action, then the original's progress" {
    const unconfirmed: Held = .{ .kind = .decision, .state = .unconfirmed };
    try std.testing.expectEqualStrings("Opening…", status(true, true, unconfirmed).?);
    try std.testing.expectEqualStrings("", status(false, true, unconfirmed).?);
    try std.testing.expectEqual(@as(?[]const u8, null), status(false, false, null));
    try std.testing.expectEqualStrings("! Decision not confirmed · ctrl+r retries original", status(false, false, unconfirmed).?);
    try std.testing.expectEqualStrings("! Not confirmed · ctrl+r retries original", status(false, false, .{ .kind = .message, .state = .unconfirmed }).?);
    try std.testing.expectEqualStrings("Not sent · ctrl+r retries original", status(false, false, .{ .kind = .message, .state = .not_started }).?);
    try std.testing.expectEqualStrings("Rejected · /discard", status(false, false, .{ .kind = .decision, .state = .rejected }).?);
    const refused: Failure = .{ .line = too_large, .key = .status };
    try std.testing.expectEqualStrings(too_large, status(false, false, .{ .kind = .message, .state = .not_started, .failure = refused }).?);
    try std.testing.expectEqualStrings("Opening…", status(true, false, .{ .kind = .message, .state = .not_started, .failure = refused }).?);
    try std.testing.expectEqual(@as(?Key, .status), key(.{ .kind = .message, .state = .not_started, .failure = refused }));
    try std.testing.expectEqual(@as(?Key, .retry), key(.{ .kind = .message, .state = .not_started }));
    try std.testing.expectEqual(@as(?Key, .retry), key(unconfirmed));
    try std.testing.expectEqual(@as(?Key, .discard), key(.{ .kind = .decision, .state = .rejected }));
    try std.testing.expectEqual(@as(?Key, null), key(.{ .kind = .message, .state = .submitting }));
}

test "Enter in the draft says the most pressing reason it sent nothing" {
    const reason: Action = .{ .preview = false, .visible = true, .reason = true };
    const rejected: Held = .{ .kind = .message, .state = .rejected };
    const pending: Held = .{ .kind = .decision, .state = .unconfirmed };
    const cases = [_]struct { Busy, []const u8 }{
        .{ .{ .command = true, .held = rejected, .preparing = true, .action = reason, .letter = false }, "! Command still running. Draft retained." },
        .{ .{ .command = false, .held = rejected, .preparing = true, .action = reason, .letter = false }, "! Original rejected. Keep editing; /discard releases it. Draft retained." },
        .{ .{ .command = false, .held = pending, .preparing = true, .action = reason, .letter = false }, "! Action needs a decision. Draft retained." },
        .{ .{ .command = false, .held = pending, .preparing = false, .action = reason, .letter = false }, reason_not_ready },
        .{ .{ .command = false, .held = null, .preparing = false, .action = reason, .letter = true }, "! Use ←→ and Enter to choose; a message denies the call." },
        .{ .{ .command = false, .held = null, .preparing = false, .action = .{ .preview = false, .visible = false, .reason = false }, .letter = true }, "! Action needs a decision; Esc returns to it. Draft retained." },
        .{ .{ .command = false, .held = pending, .preparing = false, .action = null, .letter = true }, "! Decision pending. Keep editing; Ctrl-R retries that decision." },
        .{ .{ .command = false, .held = .{ .kind = .message, .state = .unconfirmed }, .preparing = false, .action = null, .letter = false }, "! Input still pending. Keep editing; Ctrl-R retries the original." },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], busy(case[0]));
    try std.testing.expect(std.mem.indexOf(u8, reason_not_ready, ConsentPolicy.deny_words) != null);
}

test "a waiting Action that is a preview says it is decided in the shell, whether or not it is on screen" {
    for ([_]bool{ false, true }) |visible| {
        try std.testing.expectEqualStrings("! Action exceeds in-app preview. Approval disabled. Draft retained.", decision(.{ .preview = true, .visible = visible, .reason = false }));
    }
    try std.testing.expectEqualStrings("! Action needs a decision; Esc returns to the choice. Draft retained.", decision(.{ .preview = false, .visible = true, .reason = false }));
}

test "Esc leaves the settled view with an empty draft unless the held original is not yet saved" {
    for ([_]?submission.State{ null, .unconfirmed, .rejected }) |held| {
        try std.testing.expectEqual(Close.leave, close(held, true, true));
        try std.testing.expectEqualStrings("Esc returns to the overview once the draft is empty.", close(held, true, false).stay);
    }
    try std.testing.expectEqualStrings("Esc returns to the overview once Ctrl-R retries the original.", close(.unconfirmed, false, true).stay);
    for ([_]bool{ false, true }) |empty| {
        try std.testing.expectEqualStrings("Esc returns to the overview once Ctrl-R retries the original.", close(.not_started, false, empty).stay);
        try std.testing.expectEqualStrings("Esc returns to the overview once the original is confirmed.", close(.submitting, false, empty).stay);
    }
}
