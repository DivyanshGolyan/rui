const std = @import("std");
const cli_value = @import("../cli_value.zig");

/// The code a command kind is saved under. A saved code outside this set is a corrupt Store.
pub fn codeOf(kind: cli_value.CommandKind) u8 {
    return switch (kind) {
        .configure => 1,
        .message => 2,
        .session_stop => 3,
        .model_interruption => 4,
        .permission_decision => 5,
        .session_archive => 6,
        .session_pin => 7,
        .action_background => 8,
        .action_stop => 9,
    };
}
pub fn kindOf(code: u8) ?cli_value.CommandKind {
    for (std.enums.values(cli_value.CommandKind)) |candidate| {
        if (codeOf(candidate) == code) return candidate;
    }
    return null;
}

pub const Saved = struct {
    kind: cli_value.CommandKind,
    target: []const u8,
    digest: [32]u8,
    accepted: bool,
    code: []const u8,
};
pub fn Replay(comptime Rejection: type) type {
    return union(enum) { fresh, conflict, accepted, rejected: Rejection };
}
/// A null `saved` is a fresh key. A saved answer of another kind, target or digest conflicts; Configure and
/// Message with an empty incoming target compare no target. An accepted answer replays; a rejected one replays
/// its code, which must be a tag of `Rejection`.
pub fn classify(
    comptime Rejection: type,
    saved: ?Saved,
    kind: cli_value.CommandKind,
    target: []const u8,
    digest: *const [32]u8,
) error{CorruptStore}!Replay(Rejection) {
    const existing = saved orelse return .fresh;
    if (existing.kind != kind or (!((kind == .configure or kind == .message) and target.len == 0) and !std.mem.eql(u8, existing.target, target)) or
        !std.mem.eql(u8, &existing.digest, digest)) return .conflict;
    if (existing.accepted) return .accepted;
    return .{ .rejected = std.meta.stringToEnum(Rejection, existing.code) orelse return error.CorruptStore };
}

const TestRejection = enum { missing, stale };
const Outcome = union(enum) { fresh, conflict, accepted, rejected: TestRejection, corrupt };

fn outcomeOf(result: error{CorruptStore}!Replay(TestRejection)) Outcome {
    const replay = result catch return .corrupt;
    return switch (replay) {
        .fresh => .fresh,
        .conflict => .conflict,
        .accepted => .accepted,
        .rejected => |tag| .{ .rejected = tag },
    };
}

// The rule as the row states it, typed from the base command.classify branches before the shell used this core.
fn expectedOutcome(s: Saved, kind: cli_value.CommandKind, target: []const u8, digest: *const [32]u8) Outcome {
    if (s.kind != kind) return .conflict;
    const skips_target = (kind == .configure or kind == .message) and target.len == 0;
    if (!skips_target and !std.mem.eql(u8, s.target, target)) return .conflict;
    if (!std.mem.eql(u8, &s.digest, digest)) return .conflict;
    if (s.accepted) return .accepted;
    if (std.meta.stringToEnum(TestRejection, s.code)) |tag| return .{ .rejected = tag };
    return .corrupt;
}

test "SH-98 one key answers once" {
    const kinds = std.enums.values(cli_value.CommandKind);
    const saved_targets = [_][]const u8{ "session", "" };
    const incoming_targets = [_][]const u8{ "session", "other", "" };
    const codes = [_][]const u8{ "stale", "missing", "bogus" };
    const digests = [_][32]u8{ @splat(7), @splat(8) };

    // Fresh: no saved row, whatever the incoming key is.
    var fresh: usize = 0;
    for (kinds) |kind| for (incoming_targets) |target| for (&digests) |*digest| {
        try std.testing.expectEqual(Outcome.fresh, outcomeOf(classify(TestRejection, null, kind, target, digest)));
        fresh += 1;
    };
    try std.testing.expectEqual(@as(usize, 54), fresh);

    // Saved: every kind pair, saved and incoming target, digest, accepted and code.
    const Tag = std.meta.Tag(Outcome);
    var tally: [std.enums.values(Tag).len]usize = @splat(0);
    for (kinds) |saved_kind| for (saved_targets) |saved_target| for (&digests) |*saved_digest|
        for ([_]bool{ false, true }) |accepted| for (codes) |code| {
            const saved: Saved = .{ .kind = saved_kind, .target = saved_target, .digest = saved_digest.*, .accepted = accepted, .code = code };
            for (kinds) |kind| for (incoming_targets) |target| for (&digests) |*digest| {
                const got = outcomeOf(classify(TestRejection, saved, kind, target, digest));
                try std.testing.expectEqual(expectedOutcome(saved, kind, target, digest), got);
                tally[@backingInt(std.meta.activeTag(got))] += 1;
            };
        };
    // Per kind pair: 2 saved targets, 3 incoming targets, 2 of 4 digest pairs equal, 2 accepted values, 3 codes.
    try std.testing.expectEqual(@as(usize, 11424), tally[@backingInt(Tag.conflict)]);
    try std.testing.expectEqual(@as(usize, 120), tally[@backingInt(Tag.accepted)]);
    try std.testing.expectEqual(@as(usize, 80), tally[@backingInt(Tag.rejected)]);
    try std.testing.expectEqual(@as(usize, 40), tally[@backingInt(Tag.corrupt)]);
    try std.testing.expectEqual(@as(usize, 0), tally[@backingInt(Tag.fresh)]);

    // Configure and Message compare no target when the incoming target is empty; the other kinds compare it.
    const saved_configure: Saved = .{ .kind = .configure, .target = "session", .digest = digests[0], .accepted = true, .code = "" };
    try std.testing.expectEqual(Outcome.accepted, outcomeOf(classify(TestRejection, saved_configure, .configure, "", &digests[0])));
    try std.testing.expectEqual(Outcome.conflict, outcomeOf(classify(TestRejection, saved_configure, .configure, "other", &digests[0])));
    const saved_stop: Saved = .{ .kind = .session_stop, .target = "session", .digest = digests[0], .accepted = true, .code = "" };
    try std.testing.expectEqual(Outcome.conflict, outcomeOf(classify(TestRejection, saved_stop, .session_stop, "", &digests[0])));

    // Kind codes are stored values: each kind has its own code, every other byte is no kind.
    var kind_count: usize = 0;
    for (0..256) |byte| {
        if (kindOf(@intCast(byte))) |kind| {
            try std.testing.expectEqual(@as(u8, @intCast(byte)), codeOf(kind));
            kind_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 9), kind_count);
    try std.testing.expectEqual(@as(u8, 1), codeOf(.configure));
    try std.testing.expectEqual(@as(u8, 9), codeOf(.action_stop));
    try std.testing.expectEqual(@as(?cli_value.CommandKind, null), kindOf(0));
    try std.testing.expectEqual(@as(?cli_value.CommandKind, null), kindOf(10));
}
