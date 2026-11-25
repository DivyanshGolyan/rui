const std = @import("std");
const transport_policy = @import("transport_policy.zig");

pub const Class = enum {
    policy,
    quota,
    plan,
    model,
    sign_in,
    api_key,
    overflow,
    refused,
    unreachable_provider,
    retries_exhausted,
    interrupted,
    other,
};

pub const ordered_input_not_supported = "local_ordered_input_not_supported";
pub const ordered_input_limit = "local_ordered_input_limit";

pub const sign_in_prefix = "provider_sign_in_";

pub const api_key_rejected = "provider_api_key_rejected";

pub fn of(code: []const u8) Class {
    if (transport_policy.refusalOfCode(code)) |refusal| return switch (refusal) {
        .quota => .quota,
        .plan => .plan,
        .policy => .policy,
        .model_unavailable => .model,
    };
    if (std.mem.startsWith(u8, code, sign_in_prefix) or std.mem.eql(u8, code, "provider_http_401")) return .sign_in;
    if (std.mem.eql(u8, code, api_key_rejected)) return .api_key;
    if (std.mem.startsWith(u8, code, "provider_http_")) return .refused;
    const fixed = .{
        .{ "ResourceExceeded", Class.overflow },
        .{ "retry_exhausted", Class.retries_exhausted },
        .{ "cancelled", Class.interrupted },
        .{ "provider_transport_permanent", Class.unreachable_provider },
        .{ "provider_tls_verification_failed", Class.unreachable_provider },
        .{ "provider_http2_required", Class.unreachable_provider },
        .{ "invalid_provider_headers", Class.unreachable_provider },
    };
    inline for (fixed) |entry| if (std.mem.eql(u8, code, entry[0])) return entry[1];
    return .other;
}

pub fn rateLimited(cause: []const u8) bool {
    return std.mem.eql(u8, cause, "provider_temporary_http_429");
}

/// What provider trouble asks of the person across Sessions: the one thing a screen names when a provider and model cannot be reached.
pub const Trouble = enum {
    sign_in,
    api_key,
    quota,
    rate_limit,

    /// Signing in again clears an older failure: the credential it named has been replaced.
    pub fn clearedBySignIn(self: Trouble) bool {
        return self == .sign_in or self == .api_key;
    }

    /// The failure ends when the provider's saved reset time has passed.
    pub fn endsAtReset(self: Trouble) bool {
        return self == .quota;
    }
};

/// The trouble a failed Turn's saved code is, or null when it asks nothing beyond that Session.
pub fn troubleOfFailure(code: []const u8) ?Trouble {
    return switch (of(code)) {
        .sign_in => .sign_in,
        .api_key => .api_key,
        .quota, .plan => .quota,
        else => null,
    };
}

/// The trouble a retrying Turn's cause is, or null for a transient error that needs nobody.
pub fn troubleOfRetry(cause: []const u8) ?Trouble {
    return if (rateLimited(cause)) .rate_limit else null;
}

test "provider trouble follows the saved code, and only some troubles clear on sign-in or at a reset" {
    const failures = .{
        .{ "provider_http_401", Trouble.sign_in },
        .{ "provider_sign_in_required", Trouble.sign_in },
        .{ "provider_sign_in_refresh_token_expired", Trouble.sign_in },
        .{ api_key_rejected, Trouble.api_key },
        .{ "provider_quota", Trouble.quota },
        .{ "provider_plan", Trouble.quota },
    };
    inline for (failures) |case| try std.testing.expectEqual(@as(?Trouble, case[1]), troubleOfFailure(case[0]));
    for ([_][]const u8{ "provider_policy", "provider_authentication_backend_failed", "provider_model_unavailable", "provider_http_500", "retry_exhausted", "cancelled", "provider_temporary_http_429" }) |code| {
        try std.testing.expectEqual(@as(?Trouble, null), troubleOfFailure(code));
    }
    try std.testing.expectEqual(@as(?Trouble, .rate_limit), troubleOfRetry("provider_temporary_http_429"));
    try std.testing.expectEqual(@as(?Trouble, null), troubleOfRetry("provider_temporary_error"));
    inline for (comptime std.enums.values(Trouble)) |trouble| {
        try std.testing.expectEqual(trouble == .sign_in or trouble == .api_key, trouble.clearedBySignIn());
        try std.testing.expectEqual(trouble == .quota, trouble.endsAtReset());
    }
}

test "saved failure codes name what the person can do" {
    const cases = .{
        .{ "provider_policy", Class.policy },
        .{ "provider_quota", Class.quota },
        .{ "provider_plan", Class.plan },
        .{ "provider_model_unavailable", Class.model },
        .{ "provider_usage_limit_reached", Class.other },
        .{ ordered_input_not_supported, Class.other },
        .{ ordered_input_limit, Class.other },
        .{ "provider_http_401", Class.sign_in },
        .{ "provider_sign_in_required", Class.sign_in },
        .{ "provider_sign_in_refresh_token_expired", Class.sign_in },
        .{ api_key_rejected, Class.api_key },
        .{ "provider_http_400", Class.refused },
        .{ "provider_temporary_http_503", Class.other },
        .{ "provider_tls_verification_failed", Class.unreachable_provider },
        .{ "ResourceExceeded", Class.overflow },
        .{ "retry_exhausted", Class.retries_exhausted },
        .{ "cancelled", Class.interrupted },
        .{ "malformed_provider_output", Class.other },
        .{ "provider_authentication_backend_failed", Class.other },
    };
    inline for (cases) |case| try std.testing.expectEqual(case[1], of(case[0]));
}

test "only a temporary 429 is a rate limit" {
    try std.testing.expect(rateLimited("provider_temporary_http_429"));
    for ([_][]const u8{ "provider_temporary_http_503", "provider_http_429", "provider_temporary_http_4290", "" }) |cause| try std.testing.expect(!rateLimited(cause));
}
