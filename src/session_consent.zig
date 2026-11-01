//! Consent authority from completed presentation and input observations only.
//! Decoders, deadlines, workers and terminal effects remain caller-owned.
const std = @import("std");

pub const Service = enum { byte, empty, decoder_pending, decoder_expired, budget_exhausted };
pub const Choice = enum { allow_once, deny };
pub const Decision = struct { action: u64, choice: Choice };
pub const Presentation = enum { complete, preview };

pub const Consent = struct {
    action: ?u64 = null,
    presentation: Presentation = .complete,
    ready: bool = false,
    /// The option the selector highlights, if any. Each new Action starts at
    /// Allow once; redraws, pages and resizes keep it, because every frame
    /// shows it. A refused decisive key clears it until an arrow picks again.
    selected: ?Choice = .allow_once,

    /// The exact proposal has been completely presented and its worker joined;
    /// the chat decoder has relinquished custody.
    pub fn adopt(self: *Consent, action: u64, presentation: Presentation) void {
        std.debug.assert(self.action == null);
        self.* = .{ .action = action, .presentation = presentation };
    }

    pub fn active(self: Consent) bool {
        return self.action != null;
    }

    pub fn acceptsInput(self: Consent) bool {
        return self.active() and self.presentation == .complete and self.ready;
    }

    /// Called after the complete prompt write, using post-write owner facts.
    /// Ordinary redraw does not revoke an already fresh typing scope.
    pub fn promptCompleted(self: *Consent, service: Service, decoder_pending: bool, stopped: bool) bool {
        if (!self.active() or self.presentation != .complete or self.ready or service != .empty or decoder_pending or stopped) return false;
        self.ready = true;
        return true;
    }

    pub fn invalidate(self: *Consent) void {
        self.ready = false;
    }

    pub fn interrupt(self: *Consent) void {
        self.* = .{};
    }

    /// An arrow moves the highlight only while input is fresh: a key pressed
    /// before the prompt was drawn never counts. Returns whether it counted.
    pub fn move(self: *Consent, to: Choice) bool {
        if (!self.acceptsInput()) return false;
        self.selected = to;
        return true;
    }

    /// An arrow or Enter that came too early: freshness is spent and nothing
    /// stays highlighted, so Enter pressed again, however fresh, decides
    /// nothing until an arrow picks an option.
    pub fn refuse(self: *Consent) void {
        self.invalidate();
        self.selected = null;
    }

    /// Enter: consumes the exact identity, with the highlighted option,
    /// before the caller attempts submission. With nothing highlighted it
    /// decides nothing.
    pub fn confirm(self: *Consent) ?Decision {
        if (!self.acceptsInput()) return null;
        const choice = self.selected orelse return null;
        self.invalidate();
        const action = self.action.?;
        self.action = null;
        return .{ .action = action, .choice = choice };
    }
};

/// What the input row shows: the draft editor, or the Allow once / Deny
/// selector. Showing the selector is not permission: Enter probes current
/// facts separately.
pub const Row = enum { draft, selector };
/// `held`: a command holds a read Action; the frame shows no decision prompt.
pub const Approval = enum { absent, paused, preview, reading, held, draining, ready };
pub const Projection = struct { row: Row = .draft, approval: Approval = .absent };

/// What the presentation owner shows of the adopted Action, sampled at
/// selection. `read` means delivered rows reached the end in this layout.
/// `typing` means a key typed beside the Action moved the input row to the
/// draft until Esc returns to the choice.
pub const Shown = struct { action_page: bool, whole: bool, read: bool, typing: bool = false };

/// Closed selection: callers never assemble a row and approval pair.
pub fn project(consent: Consent, shown: Shown, command_blocked: bool) Projection {
    if (consent.action == null) return .{};
    if (consent.presentation == .preview) return .{ .approval = .preview };
    if (!shown.action_page or shown.typing) return .{ .approval = .paused };
    if (!shown.whole) return .{ .approval = .preview };
    if (!shown.read) return .{ .row = .selector, .approval = .reading };
    if (command_blocked) return .{ .row = .selector, .approval = .held };
    if (!consent.ready) return .{ .row = .selector, .approval = .draining };
    return .{ .row = .selector, .approval = .ready };
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
pub fn messageAllowed(consent: Consent, blockers: Blockers) bool {
    return consent.action == null and !blockers.opening and !blockers.permission_preparing and !blockers.command and blockers.original != .decision;
}

test "consent requires real emptiness after completed prompt" {
    for (std.enums.values(Service)) |service| {
        var consent: Consent = .{};
        consent.adopt(913, .complete);
        const opened = consent.promptCompleted(service, false, false);
        try std.testing.expectEqual(service == .empty, opened);
        const decision = consent.confirm();
        if (service == .empty) {
            try std.testing.expectEqual(Decision{ .action = 913, .choice = .allow_once }, decision.?);
            try std.testing.expect(consent.confirm() == null);
            try std.testing.expect(!consent.promptCompleted(.empty, false, false));
            try std.testing.expect(!consent.move(.deny));
        } else try std.testing.expect(decision == null);
    }
    for ([_]bool{ true, false }) |pending| {
        var consent: Consent = .{};
        consent.adopt(42, .complete);
        try std.testing.expect(!consent.promptCompleted(.empty, pending, !pending));
        try std.testing.expect(!consent.move(.deny));
        try std.testing.expect(consent.confirm() == null);
    }
}

test "consent bounded lifecycle sequences preserve exact authority and the shown option" {
    // Every explored prefix is followed by Enter. The oracle tracks
    // contractual freshness and the highlighted option independently of the
    // policy state: an arrow counts only while fresh, and a refused decisive
    // key clears the highlight.
    const Event = enum { empty, budget, pending, expiry, redraw, invalid, refuse, interrupt, left, right };
    const events = std.enums.values(Event);
    const count = events.len * events.len * events.len;
    for (0..count) |sequence| {
        errdefer std.debug.print("consent sequence={d}\n", .{sequence});
        var consent: Consent = .{};
        consent.adopt(0xfeed, .complete);
        var fresh = false;
        var alive = true;
        var shown: ?Choice = .allow_once;
        var index = sequence;
        for (0..3) |_| {
            const event = events[index % events.len];
            errdefer std.debug.print("consent event={s}\n", .{@tagName(event)});
            index /= events.len;
            switch (event) {
                .empty => {
                    _ = consent.promptCompleted(.empty, false, !alive);
                    if (alive) fresh = true;
                },
                .budget, .pending, .expiry => {
                    const service: Service = switch (event) {
                        .budget => .budget_exhausted,
                        .pending => .decoder_pending,
                        .expiry => .decoder_expired,
                        else => unreachable,
                    };
                    _ = consent.promptCompleted(service, event == .pending, !alive);
                },
                .redraw => {
                    _ = consent.promptCompleted(.byte, false, !alive);
                },
                .invalid => {
                    consent.invalidate();
                    fresh = false;
                },
                .refuse => {
                    consent.refuse();
                    fresh = false;
                    shown = null;
                },
                .interrupt => {
                    consent.interrupt();
                    alive = false;
                    fresh = false;
                    shown = .allow_once;
                },
                .left, .right => {
                    const to: Choice = if (event == .left) .allow_once else .deny;
                    try std.testing.expectEqual(alive and fresh, consent.move(to));
                    if (alive and fresh) shown = to;
                },
            }
            try std.testing.expectEqual(shown, consent.selected);
            const copy = consent;
            var probe = copy;
            const decision = probe.confirm();
            try std.testing.expectEqual(alive and fresh and shown != null, decision != null);
            if (decision == null) try std.testing.expectEqual(copy, probe);
            if (decision) |value| {
                try std.testing.expectEqual(@as(u64, 0xfeed), value.action);
                try std.testing.expectEqual(shown.?, value.choice);
                try std.testing.expect(probe.confirm() == null);
                try std.testing.expect(!probe.move(.deny) and !probe.move(.allow_once));
            }
        }
    }
}

test "consent reentry and successor proposals require separate fresh scopes and start at Allow once" {
    var consent: Consent = .{};
    consent.adopt(71, .complete);
    try std.testing.expect(consent.confirm() == null);
    try std.testing.expect(consent.promptCompleted(.empty, false, false));
    try std.testing.expect(consent.move(.deny));
    // Reentry invalidates freshness but keeps the shown option.
    consent.invalidate();
    try std.testing.expect(consent.confirm() == null);
    try std.testing.expect(!consent.move(.allow_once));
    try std.testing.expect(consent.promptCompleted(.empty, false, false));
    try std.testing.expectEqual(Decision{ .action = 71, .choice = .deny }, consent.confirm().?);
    consent.adopt(902, .complete);
    try std.testing.expectEqual(@as(?Choice, .allow_once), consent.selected);
    try std.testing.expect(consent.confirm() == null);
    try std.testing.expect(consent.promptCompleted(.empty, false, false));
    try std.testing.expectEqual(Decision{ .action = 902, .choice = .allow_once }, consent.confirm().?);
}

test "after a refused decisive key, fresh input alone never decides: only an arrow restores a highlight" {
    var consent: Consent = .{};
    consent.adopt(77, .complete);
    // The first Enter of a doubled Enter, before the prompt was fresh.
    try std.testing.expect(consent.confirm() == null);
    consent.refuse();
    try std.testing.expectEqual(@as(?Choice, null), consent.selected);
    try std.testing.expect(consent.promptCompleted(.empty, false, false));
    // The second Enter, now fresh, finds nothing highlighted.
    try std.testing.expect(consent.confirm() == null);
    try std.testing.expect(consent.acceptsInput());
    try std.testing.expect(consent.move(.allow_once));
    try std.testing.expectEqual(Decision{ .action = 77, .choice = .allow_once }, consent.confirm().?);
    // The next Action starts at Allow once again.
    consent.adopt(78, .complete);
    try std.testing.expectEqual(@as(?Choice, .allow_once), consent.selected);
}

test "an oversized preview cannot authorize even after completed output and empty input" {
    for (std.enums.values(Service)) |service| {
        var consent: Consent = .{};
        consent.adopt(918, .preview);
        try std.testing.expect(!consent.promptCompleted(service, false, false));
        try std.testing.expect(!consent.acceptsInput());
        try std.testing.expect(!consent.move(.deny));
        try std.testing.expect(consent.confirm() == null);
        try std.testing.expectEqual(@as(?u64, 918), consent.action);
    }
}

test "projection selects the selector only beside a whole visible Action nobody is typing at" {
    const Case = struct { adopted: bool = true, preview: bool = false, page: bool = true, whole: bool = true, read: bool = true, typing: bool = false, command: bool = false, fresh: bool = false, expected: Projection };
    for ([_]Case{
        .{ .adopted = false, .expected = .{} },
        .{ .adopted = false, .typing = true, .expected = .{} },
        // A hidden Action keeps the draft; Enter explains the pending decision.
        .{ .page = false, .read = false, .expected = .{ .approval = .paused } },
        .{ .page = false, .fresh = true, .expected = .{ .approval = .paused } },
        // Typing beside the Action moves the input row to the draft, at any
        // stage of its approval.
        .{ .typing = true, .fresh = true, .expected = .{ .approval = .paused } },
        .{ .typing = true, .read = false, .expected = .{ .approval = .paused } },
        .{ .typing = true, .command = true, .expected = .{ .approval = .paused } },
        // An oversized proposal is decided only in the shell, visible or not.
        .{ .preview = true, .expected = .{ .approval = .preview } },
        .{ .preview = true, .page = false, .expected = .{ .approval = .preview } },
        .{ .preview = true, .typing = true, .expected = .{ .approval = .preview } },
        .{ .whole = false, .read = false, .expected = .{ .approval = .preview } },
        .{ .read = false, .fresh = true, .expected = .{ .row = .selector, .approval = .reading } },
        .{ .expected = .{ .row = .selector, .approval = .draining } },
        .{ .command = true, .expected = .{ .row = .selector, .approval = .held } },
        .{ .command = true, .fresh = true, .expected = .{ .row = .selector, .approval = .held } },
        .{ .command = true, .read = false, .expected = .{ .row = .selector, .approval = .reading } },
        .{ .fresh = true, .expected = .{ .row = .selector, .approval = .ready } },
    }) |case| {
        var consent: Consent = .{};
        if (case.adopted) consent.adopt(7, if (case.preview) .preview else .complete);
        consent.ready = case.adopted and case.fresh and !case.preview;
        const shown: Shown = .{ .action_page = case.page, .whole = case.whole, .read = case.read, .typing = case.typing };
        try std.testing.expectEqual(case.expected, project(consent, shown, case.command));
    }
}

test "a Message probe blocks on every live owner fact independently" {
    var consent: Consent = .{};
    try std.testing.expect(messageAllowed(consent, .{}));
    try std.testing.expect(messageAllowed(consent, .{ .original = .message }));
    for ([_]Blockers{ .{ .opening = true }, .{ .permission_preparing = true }, .{ .command = true }, .{ .original = .decision } }) |blockers|
        try std.testing.expect(!messageAllowed(consent, blockers));
    // Hidden, previewed or ready, an adopted Action holds Messages.
    for ([_]Presentation{ .complete, .preview }) |presentation| {
        consent = .{};
        consent.adopt(9, presentation);
        try std.testing.expect(!messageAllowed(consent, .{}));
    }
}
