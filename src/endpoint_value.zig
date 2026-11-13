//! Pure provider endpoint syntax and credential transport admission.
const std = @import("std");
const url = @import("url");

pub const max_endpoint_bytes = url.max_url_bytes;

pub fn validateEndpoint(endpoint: []const u8) !void {
    if (endpoint.len == 0 or endpoint.len > max_endpoint_bytes or
        std.mem.indexOfScalar(u8, endpoint, 0) != null or !std.unicode.utf8ValidateSlice(endpoint))
    {
        return error.InvalidProviderEndpoint;
    }
    const uri = std.Uri.parse(endpoint) catch return error.InvalidProviderEndpoint;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidProviderEndpoint;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const component = uri.host orelse return error.InvalidProviderEndpoint;
    const host = component.toRaw(&host_buffer) catch return error.InvalidProviderEndpoint;
    if (host.len == 0) return error.InvalidProviderEndpoint;
    if (std.mem.eql(u8, uri.scheme, "http")) {
        if (!std.mem.eql(u8, host, "127.0.0.1") and !std.mem.eql(u8, host, "::1")) return error.InsecureProviderEndpoint;
    } else if (!std.mem.eql(u8, uri.scheme, "https")) return error.InvalidProviderEndpoint;
    _ = url.parseUrl(endpoint) catch |err| return switch (err) {
        error.CleartextNotLoopback => error.InsecureProviderEndpoint,
        error.InvalidUrl => error.InvalidProviderEndpoint,
    };
}

pub fn fixtureEndpoint(target: []const u8, ca_file: ?[]const u8) bool {
    return std.mem.startsWith(u8, target, "http://127.0.0.1:") or
        std.mem.startsWith(u8, target, "http://[::1]:") or
        (std.mem.startsWith(u8, target, "https://localhost:") and ca_file != null);
}

/// An API key goes over https, or to a loopback fixture when `fixture`.
pub fn validateKeyEndpoint(target: []const u8, ca_file: ?[]const u8, fixture: bool) !void {
    if (fixture) {
        if (!fixtureEndpoint(target, ca_file)) return error.InvalidKeyFixtureEndpoint;
    } else if (!std.mem.startsWith(u8, target, "https://")) return error.InsecureKeyEndpoint;
}

pub fn endpointUnder(allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    // `/responses` is appended to the path: with no host the path would
    // become one, and a query would swallow it.
    const uri = std.Uri.parse(base) catch return error.InvalidBaseUrl;
    if (uri.host == null or uri.host.?.isEmpty() or uri.query != null) return error.InvalidBaseUrl;
    const trimmed = std.mem.trimEnd(u8, base, "/");
    const under = try std.fmt.allocPrint(allocator, "{s}/responses", .{trimmed});
    errdefer allocator.free(under);
    validateEndpoint(under) catch return error.InvalidBaseUrl;
    validateKeyEndpoint(under, null, false) catch return error.InvalidBaseUrl;
    return under;
}

test "endpoint validation permits TLS and loopback fixture HTTP only" {
    try validateEndpoint("https://example.com/responses");
    try validateEndpoint("http://127.0.0.1:9876/fail");
    try std.testing.expectError(error.InsecureProviderEndpoint, validateEndpoint("http://example.com/fail"));
    try std.testing.expectError(
        error.InvalidProviderEndpoint,
        validateEndpoint("http://127.0.0.1:80@example.com/fail"),
    );
    try std.testing.expectError(
        error.InvalidProviderEndpoint,
        validateEndpoint("http://127.0.0.1:80@127.0.0.1:9876/fail"),
    );
    try std.testing.expectError(error.InvalidProviderEndpoint, validateEndpoint("https://user@example.com/fail"));
    try std.testing.expectError(error.InsecureProviderEndpoint, validateEndpoint("http://[::1]evil:80/fail"));
    // Accepted by the URI grammar but not by h2's: a query with no path.
    try std.testing.expectError(error.InvalidProviderEndpoint, validateEndpoint("https://example.com?q=1"));
}

test "a base URL names the https Responses endpoint under it, or nothing" {
    const allocator = std.testing.allocator;
    for ([_][2][]const u8{
        .{ "https://api.openai.com/v1", "https://api.openai.com/v1/responses" },
        .{ "https://proxy.example:8443/openai/v1/", "https://proxy.example:8443/openai/v1/responses" },
        .{ "https://host//", "https://host/responses" },
        .{ "https://[::1]/v1", "https://[::1]/v1/responses" },
    }) |case| {
        const under = try endpointUnder(allocator, case[0]);
        defer allocator.free(under);
        try std.testing.expectEqualStrings(case[1], under);
    }
    for ([_][]const u8{
        "http://api.openai.com/v1", "http://127.0.0.1:9/v1",   "https://",            "https:///v1",
        "https://:443/v1",          "https://user:pw@host/v1", "https://host/v1?x=1", "https://host/v1#f",
        "ftp://host",               "api.openai.com/v1",
    }) |bad| try std.testing.expectError(error.InvalidBaseUrl, endpointUnder(allocator, bad));
    const long = "https://h/" ++ @as([max_endpoint_bytes]u8, @splat('a'));
    try std.testing.expectError(error.InvalidBaseUrl, endpointUnder(allocator, long));
}

test "key admission preserves fixture opt-in and exclusive local CA" {
    try validateKeyEndpoint("https://example.com/responses", null, false);
    try std.testing.expectError(error.InsecureKeyEndpoint, validateKeyEndpoint("http://127.0.0.1:9/responses", null, false));
    try validateKeyEndpoint("http://127.0.0.1:9/responses", null, true);
    try validateKeyEndpoint("http://[::1]:9/responses", null, true);
    try std.testing.expectError(error.InvalidKeyFixtureEndpoint, validateKeyEndpoint("https://example.com/responses", null, true));
    try std.testing.expectError(error.InvalidKeyFixtureEndpoint, validateKeyEndpoint("https://localhost:9/responses", null, true));
    try validateKeyEndpoint("https://localhost:9/responses", "/ca.pem", true);
}
