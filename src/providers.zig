//! The providers a Host serves: where each one's requests go and which
//! credential they carry there.
const std = @import("std");
const protocol = @import("protocol.zig");
const model_adapter = @import("model_adapter.zig");
const provider_transport = @import("provider.zig");

const Provider = protocol.Provider;

/// A provider's own endpoint, the only one its credential is sent to.
pub fn endpoint(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => model_adapter.managed_endpoint,
        .openai => "https://api.openai.com/v1/responses",
    };
}

/// The environment variable naming an OpenAI-compatible base URL, such as
/// `https://example.openai.azure.com/openai/v1`, in place of OpenAI's own.
pub const openai_base_url_variable = "RUI_OPENAI_BASE_URL";

/// Where a served `openai` sends its key: OpenAI's endpoint, or the one
/// under the base URL `environ` names, allocated with `allocator`.
pub fn openAiEndpoint(environ: *const std.process.Environ.Map, allocator: std.mem.Allocator) ![]const u8 {
    const base = environ.get(openai_base_url_variable) orelse return endpoint(.openai);
    return endpointUnder(allocator, base);
}

/// The Responses endpoint under `base`, allocated with `allocator`, which
/// both endpoint and key rules admit. Trailing slashes are dropped.
pub fn endpointUnder(allocator: std.mem.Allocator, base: []const u8) ![]const u8 {
    // `/responses` is appended to the path: with no host the path would
    // become one, and a query would swallow it.
    const uri = std.Uri.parse(base) catch return error.InvalidBaseUrl;
    if (uri.host == null or uri.host.?.isEmpty() or uri.query != null) return error.InvalidBaseUrl;
    const trimmed = std.mem.trimEnd(u8, base, "/");
    const under = try std.fmt.allocPrint(allocator, "{s}/responses", .{trimmed});
    errdefer allocator.free(under);
    provider_transport.validateEndpoint(under) catch return error.InvalidBaseUrl;
    model_adapter.validateKeyEndpoint(under, null, false) catch return error.InvalidBaseUrl;
    return under;
}

/// The credential a provider's requests carry.
pub const Credential = union(enum) {
    /// A development endpoint, which takes no credential.
    none,
    chatgpt_device: model_adapter.Authentication,
    /// An API key, borrowed for the Host's life. It goes only to its entry's
    /// endpoint, over https; `fixture` admits a loopback endpoint instead.
    key_file: struct { key: []const u8, fixture: bool = false },

    pub fn route(self: Credential) protocol.Route {
        return switch (self) {
            .none => .endpoint,
            .chatgpt_device => .chatgpt_device,
            .key_file => .key_file,
        };
    }
};

pub const Served = struct {
    endpoint: []const u8,
    credential: Credential,
};

/// A Host that serves no provider.
pub const none: Providers = .{};

/// What this Host serves, fixed at startup.
pub const Providers = struct {
    table: std.EnumArray(Provider, ?Served) = .initFill(null),
    /// Trust for every served endpoint; null is the system's.
    ca_file: ?[]const u8 = null,

    pub fn get(self: *const Providers, provider: Provider) ?*const Served {
        return if (self.table.getPtrConst(provider).*) |*served| served else null;
    }

    /// Whether any provider is served, so the Host makes model requests.
    pub fn any(self: *const Providers) bool {
        for (self.table.values) |served| if (served != null) return true;
        return false;
    }

    /// The one ChatGPT sign-in this Host's authentication worker serves.
    pub fn chatgpt(self: *const Providers) ?model_adapter.Authentication {
        for (self.table.values) |served| if (served) |value| switch (value.credential) {
            .chatgpt_device => |authentication| return authentication,
            else => {},
        };
        return null;
    }

    pub fn routes(self: *const Providers) protocol.Routes {
        var out: protocol.Routes = undefined;
        inline for (@typeInfo(Provider).@"enum".field_names) |name|
            @field(out, name) = if (self.get(@field(Provider, name))) |served| served.credential.route() else .unserved;
        return out;
    }

    /// Whether a Session of `provider` can be admitted here.
    pub fn serves(self: *const Providers, provider: Provider) bool {
        return self.get(provider) != null;
    }
};

test "a Host's routes name each provider it serves and its credential" {
    var providers: Providers = .{};
    try std.testing.expect(!providers.any());
    try std.testing.expectEqual(protocol.Route.unserved, providers.routes().codex);
    providers.table.set(.codex, .{ .endpoint = "http://127.0.0.1:1/responses", .credential = .none });
    try std.testing.expect(providers.any() and providers.serves(.codex));
    try std.testing.expectEqual(protocol.Route.endpoint, providers.routes().codex);
    try std.testing.expectEqual(@as(?model_adapter.Authentication, null), providers.chatgpt());
    providers.table.set(.codex, .{ .endpoint = endpoint(.codex), .credential = .{ .chatgpt_device = .{ .path = "/c" } } });
    try std.testing.expectEqual(protocol.Route.chatgpt_device, providers.routes().codex);
    try std.testing.expectEqualStrings("/c", providers.chatgpt().?.path);
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
        "http://api.openai.com/v1", "http://127.0.0.1:9/v1", "https://",   "https:///v1",
        "https://:443/v1",          "https://user:pw@host/v1", "https://host/v1?x=1", "https://host/v1#f",
        "ftp://host",               "api.openai.com/v1",
    }) |bad| try std.testing.expectError(error.InvalidBaseUrl, endpointUnder(allocator, bad));
    const long = "https://h/" ++ @as([provider_transport.max_endpoint_bytes]u8, @splat('a'));
    try std.testing.expectError(error.InvalidBaseUrl, endpointUnder(allocator, long));
}
