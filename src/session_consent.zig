//! What a waiting Action's input row shows, as values. When Enter may act is
//! SessionScreen's: it confirms only the decision a delivered frame offered.
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
pub const Approval = enum { absent, paused, preview, reading, held, choice };
pub const Projection = struct { row: Row = .draft, approval: Approval = .absent };

/// What the presentation owner shows of the adopted Action, sampled at
/// selection. `read` means delivered rows reached the end in this layout.
pub const Shown = struct { action_page: bool, whole: bool, read: bool };

/// Closed selection: callers never assemble a row and approval pair.
pub fn project(consent: ?Pending, shown: Shown, command_blocked: bool) Projection {
    const pending = consent orelse return .{};
    if (pending.presentation == .preview) return .{ .approval = .preview };
    if (!shown.action_page or pending.row == .draft) return .{ .approval = .paused };
    if (!shown.whole) return .{ .approval = .preview };
    if (!shown.read) return .{ .row = .selector, .approval = .reading };
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

/// A live probe, never cached from frame selection. Any adopted Action, even
/// hidden or previewed, holds Messages until it is decided or withdrawn.
pub fn messageAllowed(consent: ?Pending, blockers: Blockers) bool {
    return consent == null and !blockers.opening and !blockers.permission_preparing and !blockers.command and blockers.original != .decision;
}

test "projection selects the selector only beside a whole visible Action nobody is typing at" {
    const Case = struct { adopted: bool = true, preview: bool = false, page: bool = true, whole: bool = true, read: bool = true, typing: bool = false, command: bool = false, expected: Projection };
    for ([_]Case{
        .{ .adopted = false, .expected = .{} },
        // A hidden Action keeps the draft; Enter explains the pending decision.
        .{ .page = false, .read = false, .expected = .{ .approval = .paused } },
        .{ .page = false, .expected = .{ .approval = .paused } },
        // The draft row beside the Action pauses it at any stage of approval.
        .{ .typing = true, .expected = .{ .approval = .paused } },
        .{ .typing = true, .read = false, .expected = .{ .approval = .paused } },
        .{ .typing = true, .command = true, .expected = .{ .approval = .paused } },
        // An oversized proposal is decided only in the shell, visible or not.
        .{ .preview = true, .expected = .{ .approval = .preview } },
        .{ .preview = true, .page = false, .expected = .{ .approval = .preview } },
        .{ .preview = true, .typing = true, .expected = .{ .approval = .preview } },
        .{ .whole = false, .read = false, .expected = .{ .approval = .preview } },
        .{ .read = false, .expected = .{ .row = .selector, .approval = .reading } },
        .{ .command = true, .expected = .{ .row = .selector, .approval = .held } },
        .{ .command = true, .read = false, .expected = .{ .row = .selector, .approval = .reading } },
        .{ .expected = .{ .row = .selector, .approval = .choice } },
    }) |case| {
        const consent: ?Pending = if (case.adopted) .{ .action = 7, .presentation = if (case.preview) .preview else .complete, .row = if (case.typing) .draft else .selector } else null;
        const shown: Shown = .{ .action_page = case.page, .whole = case.whole, .read = case.read };
        try std.testing.expectEqual(case.expected, project(consent, shown, case.command));
    }
}

test "a Message probe blocks on every live owner fact independently" {
    try std.testing.expect(messageAllowed(null, .{}));
    try std.testing.expect(messageAllowed(null, .{ .original = .message }));
    for ([_]Blockers{ .{ .opening = true }, .{ .permission_preparing = true }, .{ .command = true }, .{ .original = .decision } }) |blockers|
        try std.testing.expect(!messageAllowed(null, blockers));
    // Hidden, previewed or offered, an adopted Action holds Messages.
    for ([_]Presentation{ .complete, .preview }) |presentation| for ([_]Row{ .draft, .selector }) |row|
        try std.testing.expect(!messageAllowed(.{ .action = 9, .presentation = presentation, .row = row }, .{}));
}
