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

test "saved failure codes name what the person can do" {
    const cases = .{
        .{ "provider_policy", Class.policy },
        .{ "provider_quota", Class.quota },
        .{ "provider_plan", Class.plan },
        .{ "provider_model_unavailable", Class.model },
        .{ "provider_usage_limit_reached", Class.other },
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
