//! Owns when a draining pause ends (`rui host pause --drain`): how a stop
//! request combines with one already in force, when one execution pass counts
//! as quiet, and how the outcome is spelled in the Host's stop record.
//! Values in, decisions out: callers read the clock and act on the result.
const std = @import("std");

pub const default_seconds: u32 = 300;
pub const max_seconds: u32 = 86_400;

const ns_per_s: u64 = 1_000_000_000;

/// Quiet must hold this long before a drain counts as finished: one retry
/// maintenance pass, so a decision committed between passes is admitted
/// before the Host stops.
pub const settle_ns: u64 = ns_per_s;

/// How soon a stop request wants the Host to stop. Built only by `seconds`.
pub const Bound = union(enum) {
    immediate,
    within_ns: u64,

    /// null asks for a plain stop; 1..max_seconds asks for a drain.
    pub fn seconds(value: ?u32) error{InvalidDrainSeconds}!Bound {
        const given = value orelse return .immediate;
        if (given == 0 or given > max_seconds) return error.InvalidDrainSeconds;
        return .{ .within_ns = @as(u64, given) * ns_per_s };
    }
};

/// The Host's phase, as a stop request sees it. `ending` means execution is
/// already ending; `stopping` means a stop was already asked.
pub const PhaseView = enum { open, fenced, ending, stopping };

/// What a stop request does, given the deadline already in force.
pub const Ask = union(enum) {
    /// Stop at once through the existing stopping path.
    stop_now,
    /// Hold new Turns until `until_ns` (awake clock) at the latest.
    /// `changed` is false when a repeat left the deadline as it was.
    drain: struct { until_ns: u64, changed: bool },
    /// A stop was already asked; nothing to do.
    already_stopping,
};

/// Merge a stop request into the deadline in force. A repeat can only bring
/// the stop earlier, so retrying a lost reply never postpones it.
pub fn ask(phase: PhaseView, current_until_ns: ?u64, bound: Bound, now_ns: u64) Ask {
    if (phase == .stopping) return .already_stopping;
    // Execution already ending has nothing left to drain.
    if (phase == .ending) return .stop_now;
    const within = switch (bound) {
        .immediate => return .stop_now,
        .within_ns => |ns| ns,
    };
    const requested = now_ns +| within;
    if (current_until_ns) |current| if (current <= requested) return .{ .drain = .{ .until_ns = current, .changed = false } };
    return .{ .drain = .{ .until_ns = requested, .changed = true } };
}

/// When the next model retry of an open Turn falls due, as one pass knows it.
pub const RetryOutlook = union(enum) {
    none,
    /// Retries exist but this pass has not read when they fall due.
    unknown,
    in_ns: u64,
};

/// Facts from one completed execution pass.
pub const Pass = struct {
    now_ns: u64,
    /// Nothing progressed and no transport, Bash or MCP call is in flight.
    idle: bool,
    /// Effects in custody still running or about to launch, background
    /// Actions included; retained cleanup is not counted.
    running: usize,
    retry: RetryOutlook,
};

/// How a drain ended. `superseded` means a plain stop came first.
pub const Outcome = enum { finished, deadline, superseded };

pub const Decision = union(enum) {
    /// Keep serving; decide again within this many nanoseconds.
    wait_at_most_ns: u64,
    stop: Outcome,
};

/// The execution owner's view of one drain. It lives on that owner's stack.
pub const Watch = struct {
    until_ns: u64,
    quiet_since_ns: ?u64 = null,

    /// Running work is work the Host can advance by itself: a busy pass,
    /// running custody, or a retry due before the deadline. Work waiting on a
    /// person, on a held new Turn or on a clock past the deadline is parked,
    /// so it never holds a drain open.
    pub fn observe(self: *Watch, pass: Pass) Decision {
        if (pass.now_ns >= self.until_ns) return .{ .stop = .deadline };
        const left = self.until_ns - pass.now_ns;
        const retry_due = switch (pass.retry) {
            .none => false,
            .unknown => true,
            .in_ns => |ns| ns <= left,
        };
        if (!pass.idle or pass.running != 0 or retry_due) {
            self.quiet_since_ns = null;
            return .{ .wait_at_most_ns = left };
        }
        const since = self.quiet_since_ns orelse pass.now_ns;
        self.quiet_since_ns = since;
        const quiet = pass.now_ns - since;
        if (quiet >= settle_ns) return .{ .stop = .finished };
        return .{ .wait_at_most_ns = @min(left, settle_ns - quiet) };
    }
};

/// What the Host's stop record says. A plain stop writes an empty record, as
/// every earlier Host did; a drain writes its state and then its outcome.
pub const Record = enum {
    asked,
    draining,
    finished,
    deadline,
    superseded,
    /// No record, or one this version does not know.
    missing,

    pub fn text(self: Record) []const u8 {
        return switch (self) {
            .asked, .missing => "",
            inline else => |tag| @tagName(tag),
        };
    }

    pub fn of(outcome: Outcome) Record {
        return switch (outcome) {
            .finished => .finished,
            .deadline => .deadline,
            .superseded => .superseded,
        };
    }

    pub fn parse(bytes: ?[]const u8) Record {
        const content = bytes orelse return .missing;
        if (content.len == 0) return .asked;
        inline for (.{ .draining, .finished, .deadline, .superseded }) |tag| {
            if (std.mem.eql(u8, content, @tagName(tag))) return tag;
        }
        return .missing;
    }

    /// The `drain` member a draining pause reports. A plain stop that came
    /// first is `superseded`; a record still draining or gone is unconfirmed.
    pub fn reported(self: Record) []const u8 {
        return switch (self) {
            .finished, .deadline, .superseded => @tagName(self),
            .asked => "superseded",
            .draining, .missing => "unconfirmed",
        };
    }
};

test "a drain bound is 1 to 86400 seconds, and no bound is a plain stop" {
    try std.testing.expectEqual(Bound.immediate, try Bound.seconds(null));
    try std.testing.expectEqual(Bound{ .within_ns = ns_per_s }, try Bound.seconds(1));
    try std.testing.expectEqual(Bound{ .within_ns = max_seconds * ns_per_s }, try Bound.seconds(max_seconds));
    for ([_]u32{ 0, max_seconds + 1, std.math.maxInt(u32) }) |bad| try std.testing.expectError(error.InvalidDrainSeconds, Bound.seconds(bad));
}

test "a stop request only ever brings the stop earlier, a stopping Host ignores it, and an ending one just stops" {
    const at: u64 = 50 * ns_per_s;
    const within: u64 = 10 * ns_per_s;
    const requested = at + within;
    const currents = [_]?u64{ null, requested - 1, requested, requested + 1 };
    const bounds = [_]Bound{ .immediate, .{ .within_ns = within }, .{ .within_ns = std.math.maxInt(u64) } };
    for (std.enums.values(PhaseView)) |phase| for (currents) |current| for (bounds) |bound| {
        const got = ask(phase, current, bound, at);
        if (phase == .stopping) {
            try std.testing.expectEqual(Ask.already_stopping, got);
            continue;
        }
        if (bound == .immediate or phase == .ending) {
            try std.testing.expectEqual(Ask.stop_now, got);
            continue;
        }
        const wanted = at +| bound.within_ns;
        const until = if (current) |c| @min(c, wanted) else wanted;
        try std.testing.expectEqual(Ask{ .drain = .{ .until_ns = until, .changed = current == null or until != current.? } }, got);
        // Asking again with what is now in force changes nothing.
        try std.testing.expectEqual(Ask{ .drain = .{ .until_ns = until, .changed = false } }, ask(phase, until, bound, at));
    };
}

test "a drain stops at its deadline, waits on work the Host advances itself, and settles before finishing" {
    const until: u64 = 100 * ns_per_s;
    const before = until - 10 * ns_per_s;
    const left = until - before;
    const retries = [_]RetryOutlook{ .none, .unknown, .{ .in_ns = left - 1 }, .{ .in_ns = left }, .{ .in_ns = left + 1 } };
    const histories = [_]?u64{ null, before - settle_ns + 1, before - settle_ns };
    for ([_]u64{ before, until, until + 1 }) |at| for ([_]bool{ false, true }) |idle| for ([_]usize{ 0, 1, 3 }) |running| for (retries) |retry| for (histories) |history| {
        var watch: Watch = .{ .until_ns = until, .quiet_since_ns = history };
        const got = watch.observe(.{ .now_ns = at, .idle = idle, .running = running, .retry = retry });
        if (at >= until) {
            try std.testing.expectEqual(Decision{ .stop = .deadline }, got);
            continue;
        }
        const retry_due = switch (retry) {
            .none => false,
            .unknown => true,
            .in_ns => |ns| ns <= left,
        };
        const busy = !idle or running != 0 or retry_due;
        if (busy) {
            try std.testing.expectEqual(Decision{ .wait_at_most_ns = left }, got);
            try std.testing.expectEqual(@as(?u64, null), watch.quiet_since_ns);
            continue;
        }
        const since = history orelse at;
        if (at - since >= settle_ns) {
            try std.testing.expectEqual(Decision{ .stop = .finished }, got);
        } else {
            try std.testing.expectEqual(Decision{ .wait_at_most_ns = settle_ns - (at - since) }, got);
            try std.testing.expect(got.wait_at_most_ns <= left);
        }
    };
}

test "a busy pass restarts the settle window" {
    var watch: Watch = .{ .until_ns = 100 * ns_per_s };
    const quiet: Pass = .{ .now_ns = 0, .idle = true, .running = 0, .retry = .none };
    try std.testing.expectEqual(Decision{ .wait_at_most_ns = settle_ns }, watch.observe(quiet));
    var busy = quiet;
    busy.now_ns = settle_ns - 1;
    busy.running = 1;
    _ = watch.observe(busy);
    var later = quiet;
    later.now_ns = settle_ns;
    try std.testing.expectEqual(Decision{ .wait_at_most_ns = settle_ns }, watch.observe(later));
    later.now_ns = 2 * settle_ns;
    try std.testing.expectEqual(Decision{ .stop = .finished }, watch.observe(later));
}

test "the stop record round-trips every outcome and reads older and unknown records" {
    for (std.enums.values(Outcome)) |outcome| {
        const record = Record.of(outcome);
        try std.testing.expectEqual(record, Record.parse(record.text()));
        try std.testing.expectEqualStrings(@tagName(outcome), record.reported());
    }
    try std.testing.expectEqual(Record.draining, Record.parse("draining"));
    try std.testing.expectEqualStrings("unconfirmed", Record.draining.reported());
    try std.testing.expectEqual(Record.asked, Record.parse(""));
    try std.testing.expectEqualStrings("superseded", Record.asked.reported());
    for ([_]?[]const u8{ null, "finished\n", "stopping", "finishedfinished" }) |bytes| {
        try std.testing.expectEqual(Record.missing, Record.parse(bytes));
    }
    try std.testing.expectEqualStrings("unconfirmed", Record.missing.reported());
}
