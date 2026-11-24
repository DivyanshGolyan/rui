const std = @import("std");
const caller_error = @import("caller_error.zig");

pub const Status = enum(u8) {
    done = 0,
    unclassified = 1,
    invalid = 2,
    refused = 3,
    unconfirmed = 4,
    later = 5,
    environment = 6,

    pub fn merge(a: Status, b: Status) Status {
        return if (priority(a) >= priority(b)) a else b;
    }

    fn priority(self: Status) u8 {
        return switch (self) {
            .done => 0,
            .invalid => 1,
            .refused => 2,
            .later => 3,
            .environment => 4,
            .unclassified => 5,
            .unconfirmed => 6,
        };
    }
};

pub const Certainty = enum { fresh_invalid, saved_refusal, unconfirmed, not_sent, confirmed };

pub fn status(certainty: Certainty, act: caller_error.Act) Status {
    return switch (certainty) {
        .fresh_invalid => .invalid,
        .saved_refusal => .refused,
        .unconfirmed => .unconfirmed,
        .not_sent, .confirmed => switch (act) {
            .fix => .invalid,
            .wait => .later,
            .operate => .environment,
            .recover => .unconfirmed,
            .report => .unclassified,
        },
    };
}

pub fn forCode(certainty: Certainty, code: caller_error.Code) Status {
    return status(certainty, caller_error.facts(code).act);
}

/// A handover that cannot confirm its result retains uncertainty at the CLI boundary.
pub fn handover(outcome: @import("host_activation.zig").Outcome) ?Status {
    return switch (outcome) {
        .unconfirmed => .unconfirmed,
        else => null,
    };
}

test "CLI-32 unconfirmed handover preserves exit certainty" {
    const activation = @import("host_activation.zig");
    const cases = [_]struct { outcome: activation.Outcome, status: ?Status }{
        .{ .outcome = .not_needed, .status = null },
        .{ .outcome = .superseded, .status = null },
        .{ .outcome = .{ .already_ready = .{ .instance = @splat(0), .pid = 1 } }, .status = null },
        .{ .outcome = .{ .ready = .{ .instance = @splat(0), .pid = 1 } }, .status = null },
        .{ .outcome = .{ .client_incompatible = 1 }, .status = null },
        .{ .outcome = .replacement_observed, .status = null },
        .{ .outcome = .cancelled, .status = null },
        .{ .outcome = .{ .pre_stop_failed = .resolve_target }, .status = null },
        .{ .outcome = .{ .refused = .{ .stage = .checking, .failure = @import("start_report.zig").Failure.init(.settings_invalid, "check refused") } }, .status = null },
        .{ .outcome = .{ .refused = .{ .stage = .starting, .failure = @import("start_report.zig").Failure.init(.settings_invalid, "start refused") } }, .status = null },
    };
    for (cases) |case| try std.testing.expectEqual(case.status, handover(case.outcome));
    for (std.enums.values(activation.Limitation)) |limitation| try std.testing.expectEqual(@as(?Status, null), handover(.{ .unsupported = limitation }));
    for (std.enums.values(activation.TargetStep)) |step| try std.testing.expectEqual(@as(?Status, null), handover(.{ .target_unusable = step }));
    for (std.enums.values(activation.Stage)) |stage| {
        try std.testing.expectEqual(@as(?Status, .unconfirmed), handover(.{ .unconfirmed = stage }));
        try std.testing.expectEqual(@as(?Status, null), handover(.{ .failed = stage }));
    }
}

pub fn knownError(err: anyerror) Status {
    return forCode(.not_sent, caller_error.of(err));
}

test "an invalid label refused before capture is a fresh invocation error" {
    try std.testing.expectEqual(Status.invalid, knownError(error.InvalidLabel));
}

test "CLI exits derive from certainty before remedy" {
    const acts = std.meta.tags(caller_error.Act);
    const remedies = [_]Status{ .invalid, .later, .environment, .unconfirmed, .unclassified };
    for (acts, remedies) |act, expected| {
        try std.testing.expectEqual(Status.invalid, status(.fresh_invalid, act));
        try std.testing.expectEqual(Status.refused, status(.saved_refusal, act));
        try std.testing.expectEqual(Status.unconfirmed, status(.unconfirmed, act));
        try std.testing.expectEqual(expected, status(.not_sent, act));
        try std.testing.expectEqual(expected, status(.confirmed, act));
    }
    try std.testing.expectEqual(Status.invalid, forCode(.fresh_invalid, .choice_unsupported));
    try std.testing.expectEqual(Status.unclassified, knownError(error.Unexpected));
    try std.testing.expectEqual(Status.environment, knownError(error.HostStopped));
    try std.testing.expectEqual(Status.environment, knownError(error.ApiKeyMissing));
    try std.testing.expectEqual(Status.environment, knownError(error.StoreAlreadyOwned));
    try std.testing.expectEqual(Status.environment, knownError(error.StoreIdentityMismatch));
    try std.testing.expectEqual(Status.later, knownError(error.ResultNotReady));
    try std.testing.expectEqual(Status.later, knownError(error.HostReadinessUnconfirmed));
    try std.testing.expectEqual(Status.unclassified, knownError(error.FileNotFound));
    try std.testing.expectEqual(Status.environment, knownError(error.HostNotServing));
    try std.testing.expectEqual(Status.environment, knownError(error.StoreUnavailable));
    try std.testing.expectEqual(Status.invalid, knownError(error.InvalidPreferenceModel));
    try std.testing.expectEqual(Status.invalid, knownError(error.InvalidPreferenceStore));
}

test "CLI aggregate exits are cautious in every order" {
    const cautious = [_]Status{ .done, .invalid, .refused, .later, .environment, .unclassified, .unconfirmed };
    for (cautious, 0..) |a, i| for (cautious, 0..) |b, j| {
        const expected = cautious[@max(i, j)];
        try std.testing.expectEqual(expected, a.merge(b));
        try std.testing.expectEqual(expected, b.merge(a));
    };
}

test "request wait catalog exits preserve the caller policy" {
    try std.testing.expectEqual(Status.later, forCode(.confirmed, .wait_timed_out));
    try std.testing.expectEqual(Status.unconfirmed, forCode(.confirmed, .request_absent));
}

test "guided sign-in native outcomes require environment repair rather than wait or successful exit" {
    for ([_]anyerror{ error.ConnectionSuperseded, error.ConnectionNotActive, error.SignInReportingUnavailable }) |cause| {
        try std.testing.expectEqual(Status.environment, knownError(cause));
        try std.testing.expectEqual(@as(u8, 6), @backingInt(knownError(cause)));
    }
    for ([_]anyerror{ error.NoSpaceLeft, error.WriteFailed, error.AccessDenied, error.SignInReceiptPartlyReported }) |cause| try std.testing.expectEqual(Status.unclassified, knownError(cause));
}
