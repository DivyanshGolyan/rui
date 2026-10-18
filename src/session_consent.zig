//! Consent authority from completed presentation and input observations only.
//! Editors, decoder deadlines, workers and terminal effects remain caller-owned.
const std = @import("std");

pub const Service = enum { byte, empty, decoder_pending, decoder_expired, handoff, budget_exhausted };
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
    const Event = enum { empty, budget, pending, expiry, handoff, redraw, invalid, command, interrupt };
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
                    .budget, .pending, .expiry, .handoff => {
                        const service: Service = switch (event) {
                            .budget => .budget_exhausted,
                            .pending => .decoder_pending,
                            .expiry => .decoder_expired,
                            .handoff => .handoff,
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
