//! The providers a Host serves: where each one's requests go and which
//! credential they carry there.
const std = @import("std");
const protocol = @import("protocol.zig");
const model_adapter = @import("model_adapter.zig");

const Provider = protocol.Provider;

/// A provider's own endpoint, the only one its credential is sent to.
pub fn endpoint(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => model_adapter.managed_endpoint,
    };
}

/// The credential a provider's requests carry.
pub const Credential = union(enum) {
    /// A development endpoint, which takes no credential.
    none,
    chatgpt_device: model_adapter.Authentication,

    pub fn route(self: Credential) protocol.Route {
        return switch (self) {
            .none => .endpoint,
            .chatgpt_device => .chatgpt_device,
        };
    }
};

pub const Served = struct {
    endpoint: []const u8,
    credential: Credential,
};

/// What this Host serves, fixed at startup.
pub const Providers = struct {
    served: std.EnumArray(Provider, ?Served) = .initFill(null),
    /// Trust for every served endpoint; null is the system's.
    ca_file: ?[]const u8 = null,

    pub fn get(self: *const Providers, provider: Provider) ?*const Served {
        return if (self.served.getPtrConst(provider).*) |*served| served else null;
    }

    /// Whether any provider is served, so the Host makes model requests.
    pub fn any(self: *const Providers) bool {
        for (self.served.values) |served| if (served != null) return true;
        return false;
    }

    /// The one ChatGPT sign-in this Host's authentication worker serves.
    pub fn chatgpt(self: *const Providers) ?model_adapter.Authentication {
        for (self.served.values) |served| if (served) |value| switch (value.credential) {
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
    providers.served.set(.codex, .{ .endpoint = "http://127.0.0.1:1/responses", .credential = .none });
    try std.testing.expect(providers.any() and providers.serves(.codex));
    try std.testing.expectEqual(protocol.Route.endpoint, providers.routes().codex);
    try std.testing.expectEqual(@as(?model_adapter.Authentication, null), providers.chatgpt());
    providers.served.set(.codex, .{ .endpoint = endpoint(.codex), .credential = .{ .chatgpt_device = .{ .path = "/c" } } });
    try std.testing.expectEqual(protocol.Route.chatgpt_device, providers.routes().codex);
    try std.testing.expectEqualStrings("/c", providers.chatgpt().?.path);
}
