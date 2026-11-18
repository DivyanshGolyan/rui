const std = @import("std");
const submission = @import("submission_state.zig");
const ConsentPolicy = @import("session_consent.zig");

pub const Held = struct { kind: submission.Kind, state: submission.State, failure: ?Failure = null };

pub const Failure = struct { line: []const u8, key: Key };

pub const Key = enum { retry, discard, status };

pub const Presentation = struct {
    note: ?[]const u8 = null,
    status: ?[]const u8 = null,
    action: ?Key = null,
    details: bool = false,
    details_available: bool = false,
    repair_details: bool = false,
    in_flight: bool = false,
};

pub const too_large = "! Environment too large; nothing sent · details";

pub fn presentation(opening: bool, waiting: bool, held: ?Held) Presentation {
    var result: Presentation = .{};
    if (held) |original| {
        const shown: struct { line: ?[]const u8, action: ?Key } = if (original.failure) |failure|
            .{ .line = failure.line, .action = failure.key }
        else switch (original.state) {
            .not_started => .{ .line = "Not sent · ctrl+r retries original", .action = .retry },
            .submitting => .{ .line = if (original.kind == .decision) "Sending…" else null, .action = null },
            .unconfirmed => .{ .line = if (original.kind == .decision) "! Decision not confirmed · ctrl+r retries original" else "Not confirmed · ctrl+r retries original", .action = .retry },
            .rejected => .{ .line = "Rejected · /discard", .action = .discard },
        };
        if (original.kind == .message) result.note = shown.line else result.status = shown.line;
        result.action = shown.action;
        result.details = original.state != .submitting;
        result.details_available = true;
        result.repair_details = result.details and original.failure != null and shown.action == .status;
        result.in_flight = original.kind == .decision and original.state == .submitting;
    }
    if (opening) {
        result.status = "Opening…";
        result.in_flight = true;
    } else if (waiting) {
        result.status = "";
        result.in_flight = false;
    }
    return result;
}

pub fn key(held: Held) ?Key {
    return presentation(false, false, held).action;
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

test "original presentation preserves placement actions repair and opening precedence" {
    try std.testing.expectEqualDeep(Presentation{}, presentation(false, false, null));
    for ([_]submission.Kind{ .message, .decision }) |kind| {
        for ([_]submission.State{ .not_started, .submitting, .unconfirmed, .rejected }) |state| {
            const held: Held = .{ .kind = kind, .state = state };
            const shown = presentation(false, false, held);
            try std.testing.expect(shown.details_available);
            try std.testing.expectEqual(state != .submitting, shown.details);
            try std.testing.expect(!shown.repair_details);
            try std.testing.expectEqual(kind == .decision and state == .submitting, shown.in_flight);
            const words: ?[]const u8 = switch (state) {
                .not_started => "Not sent · ctrl+r retries original",
                .submitting => if (kind == .decision) "Sending…" else null,
                .unconfirmed => if (kind == .decision) "! Decision not confirmed · ctrl+r retries original" else "Not confirmed · ctrl+r retries original",
                .rejected => "Rejected · /discard",
            };
            const line = if (kind == .message) shown.note else shown.status;
            try std.testing.expectEqual(words == null, line == null);
            if (words) |expected| try std.testing.expectEqualStrings(expected, line.?);
            try std.testing.expect((if (kind == .message) shown.status else shown.note) == null);
            const action: ?Key = switch (state) {
                .not_started, .unconfirmed => .retry,
                .submitting => null,
                .rejected => .discard,
            };
            try std.testing.expectEqual(action, shown.action);
            try std.testing.expectEqual(action, key(held));
        }
        const refused: Held = .{ .kind = kind, .state = .not_started, .failure = .{ .line = too_large, .key = .status } };
        const shown = presentation(false, false, refused);
        try std.testing.expectEqualStrings(too_large, (if (kind == .message) shown.note else shown.status).?);
        try std.testing.expect(shown.details and shown.details_available and shown.repair_details);
        try std.testing.expectEqual(@as(?Key, .status), shown.action);
        try std.testing.expectEqual(@as(?Key, .status), key(refused));
        const opening = presentation(true, true, refused);
        try std.testing.expectEqualStrings("Opening…", opening.status.?);
        try std.testing.expect(opening.in_flight);
        if (kind == .message) try std.testing.expectEqualStrings(too_large, opening.note.?);
        const waiting = presentation(false, true, refused);
        try std.testing.expectEqualStrings("", waiting.status.?);
        try std.testing.expect(!waiting.in_flight);
    }
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

test "SUI-14 message and decision notices retain their placement during opening and waiting" {
    const Case = struct {
        held: Held,
        note: ?[]const u8,
        status: ?[]const u8,
        action: ?Key,
        details: bool,
        in_flight: bool,
    };
    const cases = [_]Case{
        .{ .held = .{ .kind = .message, .state = .not_started }, .note = "Not sent · ctrl+r retries original", .status = null, .action = .retry, .details = true, .in_flight = false },
        .{ .held = .{ .kind = .message, .state = .submitting }, .note = null, .status = null, .action = null, .details = false, .in_flight = false },
        .{ .held = .{ .kind = .message, .state = .unconfirmed }, .note = "Not confirmed · ctrl+r retries original", .status = null, .action = .retry, .details = true, .in_flight = false },
        .{ .held = .{ .kind = .message, .state = .rejected }, .note = "Rejected · /discard", .status = null, .action = .discard, .details = true, .in_flight = false },
        .{ .held = .{ .kind = .decision, .state = .not_started }, .note = null, .status = "Not sent · ctrl+r retries original", .action = .retry, .details = true, .in_flight = false },
        .{ .held = .{ .kind = .decision, .state = .submitting }, .note = null, .status = "Sending…", .action = null, .details = false, .in_flight = true },
        .{ .held = .{ .kind = .decision, .state = .unconfirmed }, .note = null, .status = "! Decision not confirmed · ctrl+r retries original", .action = .retry, .details = true, .in_flight = false },
        .{ .held = .{ .kind = .decision, .state = .rejected }, .note = null, .status = "Rejected · /discard", .action = .discard, .details = true, .in_flight = false },
    };
    const checkText = struct {
        fn check(expected: ?[]const u8, actual: ?[]const u8) !void {
            try std.testing.expectEqual(expected == null, actual == null);
            if (expected) |text| try std.testing.expectEqualStrings(text, actual.?);
        }
    }.check;
    for (cases) |case| {
        for ([_]bool{ false, true }) |opening| {
            for ([_]bool{ false, true }) |waiting| {
                const shown = presentation(opening, waiting, case.held);
                try checkText(case.note, shown.note);
                try checkText(if (opening) "Opening…" else if (waiting) "" else case.status, shown.status);
                try std.testing.expectEqual(case.action, shown.action);
                try std.testing.expectEqual(case.details, shown.details);
                try std.testing.expect(shown.details_available);
                try std.testing.expect(!shown.repair_details);
                try std.testing.expectEqual(if (opening) true else if (waiting) false else case.in_flight, shown.in_flight);
            }
        }
    }
}
