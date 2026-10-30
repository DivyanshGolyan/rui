//! Turn decisions over facts read under the Store transaction.
const std = @import("std");

pub const Purpose = enum { assistant_response, compaction };

/// What the provider produced, independent of queued input or Turn completion.
pub const OutputFact = enum {
    answer,
    tool_proposals,
    compacted,
};

/// Model operation resolutions that Turn policy decides on. A failure records
/// its own code, which never names one of these.
pub const Resolution = enum {
    answer,
    compacted,
    tool_proposals,
    interrupted,
    context_overflow,

    pub fn of(output: OutputFact) Resolution {
        return switch (output) {
            .answer => .answer,
            .tool_proposals => .tool_proposals,
            .compacted => .compacted,
        };
    }

    pub fn parse(code: []const u8) ?Resolution {
        return std.meta.stringToEnum(Resolution, code);
    }
};

/// Accepted provider output; context history and later Turn steps build on it.
pub const accepted = [_]Resolution{ .answer, .compacted, .tool_proposals };
/// The active Turn admits queued input without waiting for tool results.
pub const continues_with_input = [_]Resolution{ .answer, .compacted, .interrupted, .context_overflow };
/// The active Turn continues with tool results and no queued input. An
/// interrupted operation waits for new input.
pub const continues_without_input = [_]Resolution{ .answer, .compacted, .context_overflow };
// A Turn ready without input also takes queued input, so any queued Message
// in its Session is message selection's work, with no per-Turn eligibility read.
comptime {
    for (continues_without_input) |resolution| {
        if (!contains(&continues_with_input, resolution))
            @compileError("a Turn that continues without input must also continue with it");
    }
}

pub fn contains(comptime set: []const Resolution, resolution: Resolution) bool {
    return std.mem.indexOfScalar(Resolution, set, resolution) != null;
}

pub fn outputFact(purpose: Purpose, calls: u64) OutputFact {
    return if (purpose == .compaction) .compacted else if (calls != 0) .tool_proposals else .answer;
}

pub fn completesTurn(output: OutputFact, pending_messages: u64) bool {
    return output == .answer and pending_messages == 0;
}

pub fn recoversOverflow(purpose: Purpose, context_changed: bool) bool {
    return purpose == .assistant_response and context_changed;
}

pub const Previous = struct {
    purpose: Purpose,
    context_overflow: bool,
    turn_active: bool,
    same_input_prefix: bool,
};

pub const CompactionFacts = struct {
    previous: ?Previous = null,
    trigger: ?u64,
    context_changed: bool,
    usage_tokens: ?u64,
    uncovered_bytes: u64,
    output_reservation: u64,
};

/// A selected purpose needs no pressure queries. Null requests the bounded
/// pressure facts from the transaction owner, not another policy decision.
pub fn forcedPurpose(prior: ?Previous, trigger: ?u64) ?Purpose {
    const previous = prior orelse return .assistant_response;
    if (previous.turn_active and previous.context_overflow) return .compaction;
    // The input prefix must run after compaction, even when its Turn failed
    // before projection. A stop excludes that prefix rather than future input.
    if (previous.purpose == .compaction and (previous.turn_active or previous.same_input_prefix)) return .assistant_response;
    if (trigger == null) return .assistant_response;
    return null;
}

pub fn nextPurpose(facts: CompactionFacts) Purpose {
    if (forcedPurpose(facts.previous, facts.trigger)) |purpose| return purpose;
    if (!facts.context_changed) return .assistant_response;
    const pressure = (facts.usage_tokens orelse 0) +| (facts.uncovered_bytes / 4) +| facts.output_reservation;
    return if (pressure >= facts.trigger.?) .compaction else .assistant_response;
}

test "output facts do not encode the Turn continuation decision" {
    for ([_]Purpose{ .assistant_response, .compaction }) |purpose| {
        for ([_]u64{ 0, 2 }) |calls| {
            const fact = outputFact(purpose, calls);
            try std.testing.expectEqual(if (purpose == .compaction) OutputFact.compacted else if (calls != 0) OutputFact.tool_proposals else OutputFact.answer, fact);
            try std.testing.expectEqual(purpose == .assistant_response and calls == 0, completesTurn(fact, 0));
            try std.testing.expect(!completesTurn(fact, 3));
        }
    }
    try std.testing.expect(recoversOverflow(.assistant_response, true));
    try std.testing.expect(!recoversOverflow(.assistant_response, false));
    try std.testing.expect(!recoversOverflow(.compaction, true));
    try std.testing.expect(!recoversOverflow(.compaction, false));
}

test "every provider output is accepted context history" {
    for (std.enums.values(OutputFact)) |fact| try std.testing.expect(contains(&accepted, Resolution.of(fact)));
}

test "compaction purpose respects recovery prefix and both sides of pressure" {
    var facts: CompactionFacts = .{
        .trigger = 100,
        .context_changed = true,
        .usage_tokens = 83,
        .uncovered_bytes = 51,
        .output_reservation = 4,
    };
    try std.testing.expectEqual(Purpose.assistant_response, nextPurpose(facts));
    facts.previous = .{ .purpose = .assistant_response, .context_overflow = false, .turn_active = false, .same_input_prefix = false };
    try std.testing.expectEqual(Purpose.assistant_response, nextPurpose(facts));
    facts.uncovered_bytes = 52;
    try std.testing.expectEqual(Purpose.compaction, nextPurpose(facts));
    facts.context_changed = false;
    try std.testing.expectEqual(Purpose.assistant_response, nextPurpose(facts));
    facts.previous.?.context_overflow = true;
    facts.previous.?.turn_active = true;
    facts.trigger = null;
    try std.testing.expectEqual(Purpose.compaction, nextPurpose(facts));
    facts.previous.?.purpose = .compaction;
    facts.previous.?.context_overflow = false;
    try std.testing.expectEqual(Purpose.assistant_response, nextPurpose(facts));
    facts.previous.?.turn_active = false;
    facts.previous.?.same_input_prefix = true;
    facts.trigger = 0;
    facts.context_changed = true;
    try std.testing.expectEqual(Purpose.assistant_response, nextPurpose(facts));
    facts.previous.?.same_input_prefix = false;
    try std.testing.expectEqual(Purpose.compaction, nextPurpose(facts));
    facts.trigger = std.math.maxInt(u64);
    facts.usage_tokens = std.math.maxInt(u64) - 1;
    try std.testing.expectEqual(Purpose.compaction, nextPurpose(facts));
}
