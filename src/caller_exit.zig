//! CLI-only policy: certainty precedes remedy; HTTP and saved answers are unchanged.
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

/// Only errors whose cause is already known, never an OS error without context.
pub fn knownError(err: anyerror) Status {
    return switch (err) {
        error.InvalidInvocation, error.InvalidModel, error.InvalidLabel, error.InvalidArguments, error.EmptyMessageInput, error.InvalidSession, error.InvalidRuiAddress, error.CrossStorePeerSend, error.InteractiveTerminalRequired, error.EnvironmentTooLarge => status(.fresh_invalid, .fix),
        error.HostStopped => forCode(.not_sent, .host_stopped),
        error.StoreAlreadyOwned => forCode(.not_sent, .store_locked),
        error.ApiKeyMissing => forCode(.not_sent, .sign_in_required),
        error.HostBusy => forCode(.confirmed, .host_busy),
        error.ResultNotReady => forCode(.confirmed, .result_not_ready),
        else => .unclassified,
    };
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
    try std.testing.expectEqual(Status.later, knownError(error.ResultNotReady));
}

test "CLI aggregate exits are cautious in every order" {
    const cautious = [_]Status{ .done, .invalid, .refused, .later, .environment, .unclassified, .unconfirmed };
    for (cautious, 0..) |a, i| for (cautious, 0..) |b, j| {
        const expected = cautious[@max(i, j)];
        try std.testing.expectEqual(expected, a.merge(b));
        try std.testing.expectEqual(expected, b.merge(a));
    };
}
