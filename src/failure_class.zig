//! What a person can do about a saved Turn failure code. Views branch on
//! the class, never on code spellings of their own.
const std = @import("std");
const transport_policy = @import("transport_policy.zig");
const codex_credential_policy = @import("codex_credential_policy.zig");

pub const Class = enum {
    /// The provider refused the content; resending it will be refused again.
    policy,
    /// The account is out of quota or credit until it resets or is topped up.
    quota,
    /// The account's plan does not include the model.
    plan,
    /// The provider does not serve the model.
    model,
    /// Only a new login resolves it.
    sign_in,
    /// The conversation no longer fits, even after compaction.
    overflow,
    /// The provider answered with a permanent HTTP error: the same request
    /// gets the same answer.
    refused,
    /// The provider could not be reached in a way retrying does not fix.
    unreachable_provider,
    retries_exhausted,
    interrupted,
    /// Anything else, including malformed output, which a new try may avoid.
    other,
};

pub fn of(code: []const u8) Class {
    if (transport_policy.Refusal.ofFailureCode(code)) |refusal| return switch (refusal) {
        .usage_not_included => .plan,
        .model_not_found => .model,
        else => switch (refusal.class()) {
            .quota => .quota,
            .policy => .policy,
            .model => .model,
        },
    };
    if (codex_credential_policy.requiresLogin(code)) return .sign_in;
    // Temporary statuses save `provider_temporary_http_`, so this prefix
    // names only permanent ones.
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

/// A retry's saved cause is a provider's temporary HTTP 429: the provider
/// asked for fewer requests, and the retry waits it out.
pub fn rateLimited(cause: []const u8) bool {
    return std.mem.eql(u8, cause, "provider_temporary_http_429");
}

test "saved failure codes name what the person can do" {
    const cases = .{
        .{ "provider_cyber_policy", Class.policy },
        .{ "provider_invalid_prompt", Class.policy },
        .{ "provider_insufficient_quota", Class.quota },
        .{ "provider_usage_limit_reached", Class.quota },
        .{ "provider_usage_not_included", Class.plan },
        .{ "provider_model_not_found", Class.model },
        .{ "provider_http_401", Class.sign_in },
        .{ "provider_refresh_token_expired", Class.sign_in },
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
