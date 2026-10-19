//! Consent authority from completed presentation and input observations only.
//! Editors, decoder deadlines, workers and terminal effects remain caller-owned.
const std = @import("std");

pub const Service = enum { byte, empty, decoder_pending, decoder_expired, budget_exhausted };
pub const Choice = enum { allow_once, deny, other };
pub const Decision = struct { action: u64, choice: Choice };
pub const Presentation = enum { complete, preview };

pub const Consent = struct {
    action: ?u64 = null,
    presentation: Presentation = .complete,
    ready: bool = false,

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

    /// Consumes the exact identity before the caller attempts submission.
    /// Completed non-decisions also close freshness, without losing the Action.
    pub fn submit(self: *Consent, text: []const u8) ?Decision {
        if (!self.acceptsInput()) return null;
        self.invalidate();
        const choice = classify(text);
        if (choice == .other) return null;
        const action = self.action.?;
        self.action = null;
        return .{ .action = action, .choice = choice };
    }
};

/// Which editor a frame encodes and its events edit. Selection is not
/// permission: Enter probes current facts separately.
pub const Editor = enum { draft, choice };
/// `held`: a command holds a read Action; the frame shows no decision prompt.
pub const Approval = enum { absent, paused, preview, reading, held, draining, ready };
pub const Projection = struct { editor: Editor = .draft, approval: Approval = .absent };

/// What the presentation owner shows of the adopted Action, sampled at
/// selection. `read` means delivered rows reached the end in this layout.
pub const Shown = struct { action_page: bool, whole: bool, read: bool };

/// Closed selection: callers never assemble an editor and approval pair.
pub fn project(consent: Consent, shown: Shown, command_blocked: bool) Projection {
    if (consent.action == null) return .{};
    if (consent.presentation == .preview) return .{ .approval = .preview };
    if (!shown.action_page) return .{ .approval = .paused };
    if (!shown.whole) return .{ .approval = .preview };
    if (!shown.read) return .{ .editor = .choice, .approval = .reading };
    if (command_blocked) return .{ .editor = .choice, .approval = .held };
    if (!consent.ready) return .{ .editor = .choice, .approval = .draining };
    return .{ .editor = .choice, .approval = .ready };
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

pub fn classify(text: []const u8) Choice {
    if (std.mem.eql(u8, text, "a")) return .allow_once;
    if (std.mem.eql(u8, text, "d")) return .deny;
    return .other;
}

test "consent requires real emptiness after completed prompt" {
    for (std.enums.values(Service)) |service| {
        var consent: Consent = .{};
        consent.adopt(913, .complete);
        const opened = consent.promptCompleted(service, false, false);
        try std.testing.expectEqual(service == .empty, opened);
        const decision = consent.submit("a");
        if (service == .empty) {
            try std.testing.expectEqual(Decision{ .action = 913, .choice = .allow_once }, decision.?);
            try std.testing.expect(consent.submit("d") == null);
            try std.testing.expect(!consent.promptCompleted(.empty, false, false));
            try std.testing.expect(consent.submit("a") == null);
        } else try std.testing.expect(decision == null);
    }
    for ([_]bool{ true, false }) |pending| {
        var consent: Consent = .{};
        consent.adopt(42, .complete);
        try std.testing.expect(!consent.promptCompleted(.empty, pending, !pending));
        try std.testing.expect(consent.submit("d") == null);
    }
}

test "consent bounded lifecycle sequences preserve exact authority" {
    // Every explored prefix is followed by an authorization attempt. The
    // oracle tracks contractual freshness independently of the policy state.
    const Event = enum { empty, budget, pending, expiry, redraw, invalid, command, interrupt };
    const events = std.enums.values(Event);
    const count = events.len * events.len * events.len;
    for (0..count) |sequence| {
        for ([_][]const u8{ "a", "d" }) |text| {
            errdefer std.debug.print("consent sequence={d}, choice={s}\n", .{ sequence, text });
            var consent: Consent = .{};
            consent.adopt(0xfeed, .complete);
            var fresh = false;
            var alive = true;
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
                    .command => {
                        try std.testing.expect(consent.submit("/status") == null);
                        consent.invalidate();
                        fresh = false;
                    },
                    .interrupt => {
                        consent.interrupt();
                        alive = false;
                        fresh = false;
                    },
                }
                const copy = consent;
                var probe = copy;
                const decision = probe.submit(text);
                try std.testing.expectEqual(alive and fresh, decision != null);
                if (decision) |value| {
                    try std.testing.expectEqual(@as(u64, 0xfeed), value.action);
                    try std.testing.expectEqual(if (text[0] == 'a') Choice.allow_once else Choice.deny, value.choice);
                    try std.testing.expect(probe.submit(text) == null);
                }
            }
        }
    }
}

test "consent reentry and successor proposals require separate fresh scopes" {
    var consent: Consent = .{};
    consent.adopt(71, .complete);
    try std.testing.expect(consent.submit("a") == null);
    try std.testing.expect(consent.promptCompleted(.empty, false, false));
    // Complete commands and invalid text retain the same exact target, but
    // their trailing input cannot decide it. Reentry invalidates freshness.
    for ([_][]const u8{ "/history", "/details", "/status", "/exit", "A", " a", "a\n", "ad" }) |text| {
        try std.testing.expect(consent.submit(text) == null);
        try std.testing.expect(consent.submit("d") == null);
        try std.testing.expect(consent.promptCompleted(.empty, false, false));
    }
    consent.invalidate();
    try std.testing.expect(consent.submit("a") == null);
    try std.testing.expect(consent.promptCompleted(.empty, false, false));
    try std.testing.expectEqual(Decision{ .action = 71, .choice = .deny }, consent.submit("d").?);
    consent.adopt(902, .complete);
    try std.testing.expect(consent.submit("a") == null);
    try std.testing.expect(consent.promptCompleted(.empty, false, false));
    try std.testing.expectEqual(Decision{ .action = 902, .choice = .allow_once }, consent.submit("a").?);
}

test "an oversized preview cannot authorize even after completed output and empty input" {
    for (std.enums.values(Service)) |service| {
        var consent: Consent = .{};
        consent.adopt(918, .preview);
        try std.testing.expect(!consent.promptCompleted(service, false, false));
        try std.testing.expect(!consent.acceptsInput());
        try std.testing.expect(consent.submit("a") == null);
        try std.testing.expect(consent.submit("d") == null);
        try std.testing.expectEqual(@as(?u64, 918), consent.action);
    }
}

test "projection selects the choice editor only beside a whole visible Action" {
    const Case = struct { adopted: bool = true, preview: bool = false, page: bool = true, whole: bool = true, read: bool = true, command: bool = false, fresh: bool = false, expected: Projection };
    for ([_]Case{
        .{ .adopted = false, .expected = .{} },
        // A hidden Action keeps the draft; Enter explains the pending decision.
        .{ .page = false, .read = false, .expected = .{ .approval = .paused } },
        .{ .page = false, .fresh = true, .expected = .{ .approval = .paused } },
        // An oversized proposal is decided only in the shell, visible or not.
        .{ .preview = true, .expected = .{ .approval = .preview } },
        .{ .preview = true, .page = false, .expected = .{ .approval = .preview } },
        .{ .whole = false, .read = false, .expected = .{ .approval = .preview } },
        .{ .read = false, .fresh = true, .expected = .{ .editor = .choice, .approval = .reading } },
        .{ .expected = .{ .editor = .choice, .approval = .draining } },
        .{ .command = true, .expected = .{ .editor = .choice, .approval = .held } },
        .{ .command = true, .fresh = true, .expected = .{ .editor = .choice, .approval = .held } },
        .{ .command = true, .read = false, .expected = .{ .editor = .choice, .approval = .reading } },
        .{ .fresh = true, .expected = .{ .editor = .choice, .approval = .ready } },
    }) |case| {
        var consent: Consent = .{};
        if (case.adopted) consent.adopt(7, if (case.preview) .preview else .complete);
        consent.ready = case.adopted and case.fresh and !case.preview;
        const shown: Shown = .{ .action_page = case.page, .whole = case.whole, .read = case.read };
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
