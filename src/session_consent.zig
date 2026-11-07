//! What a waiting Action's input row shows, as values. When Enter may act is
//! SessionScreen's: it confirms only the choice of the latest frame, once
//! that frame was delivered and offered and nothing changed since.
const std = @import("std");

pub const Service = enum { byte, empty, decoder_pending, decoder_expired, budget_exhausted };
pub const Choice = enum { allow_once, deny };
/// What Enter would do: decide this Action with this option.
pub const Decision = struct { action: u64, choice: Choice };
pub const Presentation = enum { complete, preview };

/// What the input row shows: the draft editor, or the Allow once / Deny
/// selector.
pub const Row = enum { draft, selector };

/// The one adopted Action awaiting its decision. Absent means none.
pub const Pending = struct {
    action: u64,
    /// `preview` once the Action proved larger than the view, by its size at
    /// adoption or by any load of it; it never returns to `complete`.
    presentation: Presentation,
    /// Every Action starts at Allow once; only an arrow moves it.
    highlight: Choice = .allow_once,
    /// The input row the person chose beside this Action: the selector,
    /// unless they were writing a draft when it arrived or typed beside it,
    /// until Esc, Ctrl-G, Ctrl-End or End on an empty draft returns to it.
    row: Row,

    /// The decision this Action's selector shows.
    pub fn decision(self: Pending) Decision {
        return .{ .action = self.action, .choice = self.highlight };
    }
};

/// `held`: a command holds a read Action; the frame shows no decision prompt.
/// `reason`: the draft beside the shown Action, whose Enter sends it as the
/// reason and denies the Action.
pub const Approval = enum { absent, paused, held, choice, reason };
pub const Projection = struct { row: Row = .draft, approval: Approval = .absent };

/// Whether the adopted Action is the page currently shown.
pub const Shown = struct { action_page: bool };

/// Closed selection: callers never assemble a row and approval pair.
pub fn project(consent: ?Pending, shown: Shown, command_blocked: bool) Projection {
    const pending = consent orelse return .{};
    if (!shown.action_page) return .{ .approval = .paused };
    if (pending.row == .draft) return .{ .approval = if (command_blocked) .paused else .reason };
    if (command_blocked) return .{ .row = .selector, .approval = .held };
    return .{ .row = .selector, .approval = .choice };
}

/// Owner facts that can block a Message at the moment Enter would seal it.
pub const Blockers = struct {
    opening: bool = false,
    permission_preparing: bool = false,
    command: bool = false,
    original: enum { none, message, decision } = .none,
};

/// The option a frame with this approval offers Enter: the highlighted one at
/// the choice, Deny for a reason, otherwise none.
pub fn offered(consent: ?Pending, approval: Approval) ?Choice {
    return switch (approval) {
        .choice => consent.?.highlight,
        .reason => .deny,
        else => null,
    };
}

/// A draft of one choice letter is a keystroke meant for another tool's
/// prompt, never a reason: its Enter denies nothing.
pub fn choiceLetter(draft: []const u8) bool {
    const text = std.mem.trim(u8, draft, &std.ascii.whitespace);
    return text.len == 1 and std.mem.indexOfScalar(u8, "adynADYN", text[0]) != null;
}

/// A live probe, never cached from frame selection. Any adopted Action, even
/// hidden or previewed, holds Messages until it is decided or withdrawn,
/// except the reason sent with its denial: `reason` says the offer Enter
/// spent is that denial.
pub fn messageAllowed(consent: ?Pending, reason: bool, blockers: Blockers) bool {
    return (consent == null or reason) and !blockers.opening and !blockers.permission_preparing and !blockers.command and blockers.original != .decision;
}

test "projection offers the same choice for complete and previewed Actions" {
    const Case = struct { page: bool = true, typing: bool = false, command: bool = false, expected: Projection };
    try std.testing.expectEqual(Projection{}, project(null, .{ .action_page = true }, false));
    for ([_]Case{
        .{ .page = false, .expected = .{ .approval = .paused } },
        .{ .typing = true, .expected = .{ .approval = .reason } },
        .{ .typing = true, .command = true, .expected = .{ .approval = .paused } },
        .{ .typing = true, .page = false, .expected = .{ .approval = .paused } },
        .{ .command = true, .expected = .{ .row = .selector, .approval = .held } },
        .{ .expected = .{ .row = .selector, .approval = .choice } },
    }) |case| for ([_]Presentation{ .complete, .preview }) |presentation| {
        const consent: Pending = .{ .action = 7, .presentation = presentation, .row = if (case.typing) .draft else .selector };
        try std.testing.expectEqual(case.expected, project(consent, .{ .action_page = case.page }, case.command));
    };
}

test "a Message probe blocks on every live owner fact independently" {
    try std.testing.expect(messageAllowed(null, false, .{}));
    try std.testing.expect(messageAllowed(null, false, .{ .original = .message }));
    for ([_]Blockers{ .{ .opening = true }, .{ .permission_preparing = true }, .{ .command = true }, .{ .original = .decision } }) |blockers| for ([_]bool{ false, true }) |reason|
        try std.testing.expect(!messageAllowed(if (reason) .{ .action = 9, .presentation = .complete, .row = .draft } else null, reason, blockers));
    // Hidden, previewed or offered, an adopted Action holds Messages, except
    // the reason its denial sends.
    for ([_]Presentation{ .complete, .preview }) |presentation| for ([_]Row{ .draft, .selector }) |row| {
        const pending: Pending = .{ .action = 9, .presentation = presentation, .row = row };
        try std.testing.expect(!messageAllowed(pending, false, .{}));
        try std.testing.expect(messageAllowed(pending, true, .{}));
    };
}

test "a frame offers the highlighted option at the choice, Deny for a reason, and nothing otherwise" {
    // What Enter decides for each approval, with Allow once and then Deny
    // highlighted.
    const cases = [_]struct { Approval, ?Choice, ?Choice }{
        .{ .absent, null, null },
        .{ .paused, null, null },
        .{ .held, null, null },
        .{ .choice, .allow_once, .deny },
        .{ .reason, .deny, .deny },
    };
    try std.testing.expectEqual(std.enums.values(Approval).len, cases.len);
    for (cases) |case| for ([_]Choice{ .allow_once, .deny }, [_]?Choice{ case[1], case[2] }) |highlight, expected| {
        const pending: Pending = .{ .action = 9, .presentation = .complete, .highlight = highlight, .row = .selector };
        try std.testing.expectEqual(expected, offered(pending, case[0]));
    };
}

test "only a draft of exactly one choice letter is refused as a reason" {
    for ([_][]const u8{ "a", "d", "y", "n", "A", "D", "Y", "N", " y ", "\tn\n", "  a\r\n" }) |draft| try std.testing.expect(choiceLetter(draft));
    for ([_][]const u8{ "", " ", "b", "aa", "no", "yes", "a d", "é", "/a", "x" }) |draft| try std.testing.expect(!choiceLetter(draft));
}
