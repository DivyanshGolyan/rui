const std = @import("std");
const protocol = @import("protocol.zig");
const h2 = @import("h2");
const api_key = @import("api_key.zig");
const codex_auth = @import("codex_auth.zig");
const codex_credentials = @import("codex_credentials.zig");
const chatgpt_plan_wire = @import("chatgpt_plan_wire.zig");
const model_list = @import("model_list.zig");
const credential_policy = @import("codex_credential_policy.zig");
const provider_transport = @import("provider.zig");
const turn_states = @import("turn_states.zig");

const Provider = protocol.Provider;

pub const managed_endpoint = @import("provider_name.zig").managed_endpoint;

pub const api_endpoint = @import("provider_name.zig").api_endpoint;

pub fn fromSettings(settings: *const @import("host_settings.zig").Settings) Providers {
    var result: Providers = .{ .ca_file = if (settings.network.ca_file) |*ca| ca.slice() else null };
    inline for (std.enums.values(Provider)) |named| {
        if (@field(settings.providers.entries, @tagName(named))) |*entry| {
            const target = if (entry.endpoint) |*url| url.slice() else endpoint(named);
            const fixture = @import("host_settings.zig").fixtureEndpoint(settings, target);
            result.table.set(named, .{
                .endpoint = target,
                .credential = if (entry.unauthenticated.value) .none else switch (comptime named.facts().credential) {
                    .api_key => .{ .key_file = .{ .key = entry.key.value(), .fixture = fixture } },
                    .sign_in => switch (named) {
                        .codex => .{ .chatgpt_device = .{ .path = entry.credential_file.?.slice(), .refresh = if (fixture) .synthetic else .issuer } },
                        .chatgpt => .{ .chatgpt_plan = .{ .path = entry.credential_file.?.slice(), .refresh = if (fixture and entry.token_endpoint != null) .{ .fixture_endpoint = entry.token_endpoint.?.slice() } else .issuer } },
                        .openai => unreachable,
                    },
                },
            });
        }
    }
    return result;
}

pub const api_models_endpoint = responsesBase(api_endpoint).? ++ "/models";

pub const Authentication = codex_auth.Source;

pub const SignIn = struct {
    path: []const u8,
    refresh: Authentication.RefreshTarget = .issuer,

    fn source(self: SignIn, wire: codex_auth.Wire) Authentication {
        return .{ .path = self.path, .wire = wire, .refresh = self.refresh };
    }
};

pub const Work = codex_auth.Work;

pub fn acquire(source: Authentication, io: std.Io, work: *Work, lease: *Lease) !void {
    try codex_auth.acquireInto(io, source, work, lease);
}

pub fn refresh(source: Authentication, io: std.Io, generation: u64) !bool {
    return codex_auth.forceRefresh(io, source, generation);
}

pub const Lease = codex_credentials.Lease;

pub fn leaseFailureCode(err: anyerror) []const u8 {
    return codex_auth.failureCode(err);
}

/// Whether a Session served over `route` may ask for structured output:
/// the ChatGPT backend refuses it.
pub fn acceptsOutputSchema(route: protocol.Route) bool {
    return route != .chatgpt_device;
}

pub fn endpoint(provider: Provider) []const u8 {
    return provider.facts().endpoint;
}

pub fn responsesBase(responses: []const u8) ?[]const u8 {
    return std.mem.cutSuffix(u8, responses, "/responses");
}

pub const Credential = union(enum) {
    none,
    chatgpt_device: SignIn,
    chatgpt_plan: SignIn,
    key_file: struct { key: []const u8, fixture: bool = false },

    pub const Rejection = union(enum) {
        settle,
        refresh_once: Refresh,
        key_rejected,
    };

    pub const Refresh = struct { source: Authentication, generation: u64 };

    pub fn leased(self: Credential) bool {
        return self.signIn() != null;
    }

    pub fn signIn(self: Credential) ?Authentication {
        return switch (self) {
            .none, .key_file => null,
            .chatgpt_device => |sign_in| sign_in.source(.codex_device),
            .chatgpt_plan => |sign_in| sign_in.source(.chatgpt_plan),
        };
    }

    pub fn validate(self: Credential, served_endpoint: []const u8, ca_file: ?[]const u8) !void {
        switch (self) {
            .none => {},
            .chatgpt_device, .chatgpt_plan => try validateAuthenticationEndpoint(served_endpoint, ca_file, self.signIn().?),
            .key_file => |key| try validateKeyEndpoint(served_endpoint, ca_file, key.fixture),
        }
    }

    pub fn fields(self: Credential, served_endpoint: []const u8, ca_file: ?[]const u8, lease: ?*const Lease, shared: *provider_transport.Credentials, headers: *Headers) !void {
        std.debug.assert(self.leased() == (lease != null));
        switch (self) {
            .none => {},
            .chatgpt_device => |sign_in| try headers.initDevice(served_endpoint, ca_file, sign_in, lease.?, shared),
            .chatgpt_plan => |sign_in| try headers.initPlan(served_endpoint, ca_file, sign_in, lease.?, shared),
            .key_file => |key| try headers.initKey(served_endpoint, ca_file, key.key, key.fixture, shared),
        }
    }

    pub fn rejection(self: Credential, lease: ?*const Lease) Rejection {
        return switch (self) {
            .none => .settle,
            .chatgpt_device, .chatgpt_plan => .{ .refresh_once = .{ .source = self.signIn().?, .generation = lease.?.record.generation } },
            .key_file => .key_rejected,
        };
    }

    pub fn routingOwner(self: Credential, lease: ?*const Lease) turn_states.TurnStates.Owner {
        return switch (self) {
            .none, .key_file => @splat(0),
            .chatgpt_device, .chatgpt_plan => owner: {
                const record = &lease.?.record;
                var hash = std.crypto.hash.sha2.Sha256.init(.{});
                hash.update(&.{@intFromBool(record.fedramp)});
                hash.update(record.account_id.slice());
                break :owner hash.finalResult();
            },
        };
    }

    /// How this route's model list (`GET BASE/models` beside its Responses
    /// endpoint) reads, or null when it has none: an API key reads OpenAI's
    /// list shape, a ChatGPT plan its own. The device sign-in's backend
    /// publishes none, and a development endpoint takes no credential.
    pub fn listing(self: Credential) ?Listing {
        return switch (self) {
            .none, .chatgpt_device => null,
            .chatgpt_plan => .chatgpt_plan,
            .key_file => .openai,
        };
    }

    pub fn route(self: Credential) protocol.Route {
        return switch (self) {
            .none => .endpoint,
            .chatgpt_device => .chatgpt_device,
            .chatgpt_plan => .chatgpt_plan,
            .key_file => .key_file,
        };
    }
};

pub const Listing = enum {
    openai,
    chatgpt_plan,

    pub fn parse(self: Listing, scratch: std.mem.Allocator, body: []const u8, out: *model_list.IdBuffer) !model_list.Ids {
        return switch (self) {
            .openai => model_list.parseOpenAi(scratch, body, out),
            .chatgpt_plan => chatgpt_plan_wire.parseModels(scratch, body, out),
        };
    }
};

const fixtureEndpoint = @import("endpoint_value.zig").fixtureEndpoint;

fn validateAuthenticationEndpoint(target: []const u8, ca_file: ?[]const u8, authentication: Authentication) !void {
    if (authentication.fixture() and !fixtureEndpoint(target, ca_file))
        return error.InvalidCodexFixtureEndpoint;
    switch (authentication.refresh) {
        .issuer, .synthetic => {},
        .fixture_endpoint => |url| if (!fixtureEndpoint(url, null)) return error.InvalidCodexFixtureEndpoint,
    }
}

const validateKeyEndpoint = @import("endpoint_value.zig").validateKeyEndpoint;

pub const Headers = struct {
    entries: [4]h2.Field = undefined,
    length: usize = 0,
    credentials: *provider_transport.Credentials = undefined,
    credential: ?*provider_transport.SharedCredential = null,

    fn initDevice(self: *Headers, target: []const u8, ca_file: ?[]const u8, sign_in: SignIn, credential: *const Lease, shared_credentials: *provider_transport.Credentials) !void {
        const access = credential.record.access_token.slice();
        const account_id = credential.record.account_id.slice();
        if (sign_in.refresh != .issuer) {
            if (!fixtureEndpoint(target, ca_file) or
                !std.mem.eql(u8, access, codex_auth.fixture_access_token) or
                !std.mem.eql(u8, account_id, codex_auth.fixture_account_id))
                return error.InvalidManagedFixture;
        } else if (!std.mem.eql(u8, target, managed_endpoint)) return error.ManagedEndpointMismatch;
        if (access.len == 0 or account_id.len == 0)
            return error.InvalidCredentialHeader;
        for (access) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidCredentialHeader;
        for (account_id) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidCredentialHeader;
        const shared = try shared_credentials.share(access, account_id);
        self.credentials = shared_credentials;
        self.credential = shared;
        self.entries[0..3].* = .{
            .{ .name = "authorization", .value = shared.authorization(), .sensitive = true, .borrowed = true },
            .{ .name = "chatgpt-account-id", .value = shared.accountId(), .sensitive = true, .borrowed = true },
            .{ .name = "user-agent", .value = "rui/" ++ @import("transport_options").revision, .borrowed = true },
        };
        self.length = 3;
        if (credential.record.fedramp) {
            self.entries[self.length] = .{ .name = "x-openai-fedramp", .value = "true", .borrowed = true };
            self.length += 1;
        }
    }

    /// A ChatGPT plan sign-in's fields: its access token as a bearer, and
    /// user-agent. OpenAI's API names the account from the token, so no
    /// account or FedRAMP field is sent. A fixture accepts only a record
    /// issued to the fixture client, so a real sign-in never reaches it.
    fn initPlan(self: *Headers, target: []const u8, ca_file: ?[]const u8, sign_in: SignIn, credential: *const Lease, shared_credentials: *provider_transport.Credentials) !void {
        const access = credential.record.access_token.slice();
        if (sign_in.refresh != .issuer) {
            if (!fixtureEndpoint(target, ca_file) or
                !std.mem.eql(u8, credential.record.client_id.slice(), credential_policy.fixture_client_id))
                return error.InvalidManagedFixture;
        } else if (!std.mem.eql(u8, target, api_endpoint) and !std.mem.eql(u8, target, api_models_endpoint))
            return error.ManagedEndpointMismatch;
        if (access.len == 0) return error.InvalidCredentialHeader;
        for (access) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidCredentialHeader;
        const shared = try shared_credentials.share(access, "");
        self.credentials = shared_credentials;
        self.credential = shared;
        self.entries[0..2].* = .{
            .{ .name = "authorization", .value = shared.authorization(), .sensitive = true, .borrowed = true },
            .{ .name = "user-agent", .value = "rui/" ++ @import("transport_options").revision, .borrowed = true },
        };
        self.length = 2;
    }

    fn initKey(self: *Headers, target: []const u8, ca_file: ?[]const u8, key: []const u8, fixture: bool, shared_credentials: *provider_transport.Credentials) !void {
        try validateKeyEndpoint(target, ca_file, fixture);
        if (!api_key.valid(key)) return error.InvalidCredentialHeader;
        const shared = try shared_credentials.share(key, "");
        self.credentials = shared_credentials;
        self.credential = shared;
        self.entries[0..2].* = .{
            .{ .name = "authorization", .value = shared.authorization(), .sensitive = true, .borrowed = true },
            .{ .name = "user-agent", .value = "rui/" ++ @import("transport_options").revision, .borrowed = true },
        };
        self.length = 2;
    }

    pub fn fields(self: *const Headers) []const h2.Field {
        return self.entries[0..self.length];
    }

    pub fn takeCredential(self: *Headers) ?*provider_transport.SharedCredential {
        defer self.credential = null;
        return self.credential;
    }

    pub fn deinit(self: *Headers) void {
        if (self.credential) |shared| self.credentials.release(shared);
        self.* = undefined;
    }
};

pub const Served = struct {
    endpoint: []const u8,
    credential: Credential,
};

pub const none: Providers = .{};

pub const Providers = struct {
    table: std.EnumArray(Provider, ?Served) = .initFill(null),
    ca_file: ?[]const u8 = null,

    pub fn get(self: *const Providers, provider: Provider) ?*const Served {
        return if (self.table.getPtrConst(provider).*) |*served| served else null;
    }

    pub fn any(self: *const Providers) bool {
        for (self.table.values) |served| if (served != null) return true;
        return false;
    }

    pub fn proxyRefusal(self: *const Providers, allocator: std.mem.Allocator) error{ OutOfMemory, SystemResources }!?[]const u8 {
        if (!self.any()) return null;
        const proxy = h2.proxyFromEnvironment() orelse return null;
        h2.checkProxy(allocator, proxy) catch |err| return switch (err) {
            error.HttpsProxySchemeUnsupported => "names a scheme other than http://",
            error.HttpsProxyInvalid => "is not a usable proxy URL",
            error.OutOfMemory, error.SystemResources => |other| other,
        };
        return null;
    }

    pub fn anySignIn(self: *const Providers) bool {
        for (self.table.values) |served| if (served) |value| if (value.credential.leased()) return true;
        return false;
    }

    pub fn routes(self: *const Providers) protocol.Routes {
        var out: protocol.Routes = undefined;
        inline for (@typeInfo(Provider).@"enum".field_names) |name|
            @field(out, name) = if (self.get(@field(Provider, name))) |served| served.credential.route() else .unserved;
        return out;
    }

    pub fn liveList(self: *const Providers, provider: Provider) ?*const Served {
        if (provider.facts().model_list != .live) return null;
        const served = self.get(provider) orelse return null;
        if (served.credential.listing() == null or responsesBase(served.endpoint) == null) return null;
        return served;
    }

    pub fn liveLists(self: *const Providers) usize {
        var count: usize = 0;
        for (std.enums.values(Provider)) |provider| count += @intFromBool(self.liveList(provider) != null);
        return count;
    }

    pub fn serves(self: *const Providers, provider: Provider) bool {
        return self.get(provider) != null;
    }
};

fn testRecord(account_id: []const u8, fedramp: bool, access: []const u8, generation: u64) !codex_credentials.Record {
    var record: codex_credentials.Record = .{
        .generation = generation,
        .account_id = .{},
        .fedramp = fedramp,
        .id_token = .{},
        .access_token = .{},
        .refresh_token = .{},
        .expires_at = 0,
        .refreshed_at = 0,
    };
    try record.account_id.set(account_id);
    try record.access_token.set(access);
    return record;
}

test "an API key goes only over https or to a loopback fixture, with no account" {
    var credentials: provider_transport.Credentials = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    const own = "https://api.openai.com/v1/responses";
    {
        var headers: Headers = .{};
        defer headers.deinit();
        try headers.initKey(own, null, "sk-test", false, &credentials);
        const entries = headers.fields();
        try std.testing.expectEqual(@as(usize, 2), entries.len);
        try std.testing.expectEqualStrings("authorization", entries[0].name);
        try std.testing.expectEqualStrings("Bearer sk-test", entries[0].value);
        try std.testing.expect(entries[0].sensitive);
        try std.testing.expectEqualStrings("user-agent", entries[1].name);
        for (entries) |entry| try std.testing.expect(provider_transport.hostField(entry.name));
    }
    {
        var headers: Headers = .{};
        defer headers.deinit();
        try headers.initKey("http://127.0.0.1:9/responses", null, "sk-test", true, &credentials);
    }
    var refused: Headers = .{};
    try std.testing.expectError(error.InsecureKeyEndpoint, refused.initKey("http://127.0.0.1:9/responses", null, "sk-test", false, &credentials));
    try std.testing.expectError(error.InvalidKeyFixtureEndpoint, refused.initKey(own, null, "sk-test", true, &credentials));
    try std.testing.expectError(error.InvalidCredentialHeader, refused.initKey(own, null, "sk test", false, &credentials));
    try std.testing.expectEqual(@as(?*provider_transport.SharedCredential, null), credentials.head);
}

test "ChatGPT headers carry the credential, user-agent and FedRAMP fields" {
    var credential: Lease = undefined;
    var credentials: provider_transport.Credentials = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    for ([_]bool{ false, true }) |fedramp| {
        credential.record = try testRecord(codex_auth.fixture_account_id, fedramp, codex_auth.fixture_access_token, 1);
        {
            var headers: Headers = .{};
            defer headers.deinit();
            try headers.initDevice("http://127.0.0.1:1/responses", null, .{ .path = "unused", .refresh = .synthetic }, &credential, &credentials);
            const entries = headers.fields();
            var fedramp_found = false;
            for (entries) |entry| {
                // h2 sends names as given, and HTTP/2 requires them lowercase.
                for (entry.name) |byte| try std.testing.expect(!std.ascii.isUpper(byte));
                try std.testing.expectEqual(std.mem.eql(u8, entry.name, "authorization") or
                    std.mem.eql(u8, entry.name, "chatgpt-account-id"), entry.sensitive);
                if (std.mem.eql(u8, entry.name, "x-openai-fedramp")) fedramp_found = std.mem.eql(u8, entry.value, "true");
                if (std.mem.eql(u8, entry.name, "authorization"))
                    try std.testing.expectEqualStrings("Bearer " ++ codex_auth.fixture_access_token, entry.value);
                // The account and FedRAMP fields are connection headers, not host-owned names.
                if (!std.mem.eql(u8, entry.name, "chatgpt-account-id") and !std.mem.eql(u8, entry.name, "x-openai-fedramp"))
                    try std.testing.expect(provider_transport.hostField(entry.name));
            }
            for (entries) |entry| try std.testing.expectEqual(entry.name.len + entry.value.len > 16, entry.borrowed);
            const shared = headers.credential.?;
            try std.testing.expectEqualStrings("authorization", entries[0].name);
            try std.testing.expectEqual(shared.authorization().ptr, entries[0].value.ptr);
            try std.testing.expectEqualStrings("chatgpt-account-id", entries[1].name);
            try std.testing.expectEqual(shared.accountId().ptr, entries[1].value.ptr);
            try std.testing.expectEqualStrings("user-agent", entries[2].name);
            if (fedramp) try std.testing.expectEqualStrings("x-openai-fedramp", entries[3].name);
            try std.testing.expectEqual(fedramp, fedramp_found);
            try std.testing.expectEqual(@as(usize, 3) + @intFromBool(fedramp), entries.len);
        }
    }
}

test "each sign-in source says whether it waits for a lease and what a 401 means" {
    var lease: Lease = undefined;
    lease.record = try testRecord(codex_auth.fixture_account_id, false, codex_auth.fixture_access_token, 7);
    const source: Authentication = .{ .path = "/c", .wire = .codex_device, .refresh = .synthetic };
    const signed_in: Credential = .{ .chatgpt_device = .{ .path = "/c", .refresh = .synthetic } };
    const keyed: Credential = .{ .key_file = .{ .key = "sk-test" } };
    try std.testing.expect(signed_in.leased() and !keyed.leased() and !Credential.leased(.none));
    try std.testing.expectEqual(Credential.Rejection{ .refresh_once = .{ .source = source, .generation = 7 } }, signed_in.rejection(&lease));
    try std.testing.expectEqual(Credential.Rejection.key_rejected, keyed.rejection(null));
    try std.testing.expectEqual(Credential.Rejection.settle, Credential.rejection(.none, null));
    try signed_in.validate("http://127.0.0.1:9/responses", null);
    try std.testing.expectError(error.InvalidCodexFixtureEndpoint, signed_in.validate(managed_endpoint, null));
    try std.testing.expectError(error.InsecureKeyEndpoint, keyed.validate("http://127.0.0.1:9/responses", null));
    try Credential.validate(.none, "http://127.0.0.1:9/responses", null);
    var shared: provider_transport.Credentials = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    var headers: Headers = .{};
    defer headers.deinit();
    try Credential.fields(.none, "http://127.0.0.1:9/responses", null, null, &shared, &headers);
    try std.testing.expectEqual(@as(usize, 0), headers.fields().len);
}

test "a Host's routes name each provider it serves and its credential" {
    var providers: Providers = .{};
    try std.testing.expect(!providers.any());
    try std.testing.expectEqual(protocol.Route.unserved, providers.routes().codex);
    providers.table.set(.codex, .{ .endpoint = "http://127.0.0.1:1/responses", .credential = .none });
    try std.testing.expect(providers.any() and providers.serves(.codex));
    try std.testing.expectEqual(protocol.Route.endpoint, providers.routes().codex);
    try std.testing.expect(!providers.anySignIn());
    providers.table.set(.codex, .{ .endpoint = endpoint(.codex), .credential = .{ .chatgpt_device = .{ .path = "/c" } } });
    try std.testing.expectEqual(protocol.Route.chatgpt_device, providers.routes().codex);
    try std.testing.expect(providers.anySignIn());
    try std.testing.expectEqualStrings("/c", providers.get(.codex).?.credential.signIn().?.path);
    providers.table.set(.chatgpt, .{ .endpoint = endpoint(.chatgpt), .credential = .{ .chatgpt_plan = .{ .path = "/p" } } });
    try std.testing.expectEqual(protocol.Route.chatgpt_plan, providers.routes().chatgpt);
    try std.testing.expectEqual(protocol.Route.unserved, providers.routes().openai);
    try std.testing.expectEqual(Authentication{ .path = "/c", .wire = .codex_device }, providers.get(.codex).?.credential.signIn().?);
    try std.testing.expectEqual(Authentication{ .path = "/p", .wire = .chatgpt_plan }, providers.get(.chatgpt).?.credential.signIn().?);
    try std.testing.expect(!acceptsOutputSchema(.chatgpt_device) and acceptsOutputSchema(.chatgpt_plan));
}

test "a ChatGPT plan sign-in sends a bearer and user-agent, only to OpenAI's API" {
    var lease: Lease = undefined;
    lease.record = try testRecord("plan-subject", false, "plan-access", 4);
    var credentials: provider_transport.Credentials = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    const plan: Credential = .{ .chatgpt_plan = .{ .path = "/p" } };
    try std.testing.expect(plan.leased());
    {
        var headers: Headers = .{};
        defer headers.deinit();
        try plan.fields(api_endpoint, null, &lease, &credentials, &headers);
        const entries = headers.fields();
        try std.testing.expectEqual(@as(usize, 2), entries.len);
        try std.testing.expectEqualStrings("authorization", entries[0].name);
        try std.testing.expectEqualStrings("Bearer plan-access", entries[0].value);
        try std.testing.expect(entries[0].sensitive);
        try std.testing.expectEqualStrings("user-agent", entries[1].name);
        for (entries) |entry| try std.testing.expect(provider_transport.hostField(entry.name));
    }
    {
        var headers: Headers = .{};
        defer headers.deinit();
        try plan.fields(api_models_endpoint, null, &lease, &credentials, &headers);
        try std.testing.expectEqualStrings("https://api.openai.com/v1/models", api_models_endpoint);
        try std.testing.expectEqualStrings("Bearer plan-access", headers.fields()[0].value);
    }
    var refused: Headers = .{};
    for ([_][]const u8{
        managed_endpoint,                  "https://proxy.example/v1/responses", "https://proxy.example/v1/models",
        "https://api.openai.com/v1/files", "https://api.openai.com/v1/models/x", "http://api.openai.com/v1/models",
        "http://127.0.0.1:9/responses",
    }) |target|
        try std.testing.expectError(error.ManagedEndpointMismatch, plan.fields(target, null, &lease, &credentials, &refused));
    const fixture: Credential = .{ .chatgpt_plan = .{ .path = "/p", .refresh = .{ .fixture_endpoint = "http://127.0.0.1:9/token" } } };
    try std.testing.expectError(error.InvalidManagedFixture, fixture.fields("http://127.0.0.1:9/responses", null, &lease, &credentials, &refused));
    try lease.record.client_id.set(credential_policy.fixture_client_id);
    try std.testing.expectError(error.InvalidManagedFixture, fixture.fields(api_endpoint, null, &lease, &credentials, &refused));
    {
        var headers: Headers = .{};
        defer headers.deinit();
        try fixture.fields("http://127.0.0.1:9/responses", null, &lease, &credentials, &headers);
        try std.testing.expectEqual(@as(usize, 2), headers.fields().len);
    }
    try fixture.validate("http://127.0.0.1:9/responses", null);
    try std.testing.expectError(error.InvalidCodexFixtureEndpoint, fixture.validate(api_endpoint, null));
    const remote_token: Credential = .{ .chatgpt_plan = .{ .path = "/p", .refresh = .{ .fixture_endpoint = "https://auth.example/token" } } };
    try std.testing.expectError(error.InvalidCodexFixtureEndpoint, remote_token.validate("http://127.0.0.1:9/responses", null));
    try std.testing.expectEqual(Credential.Rejection{ .refresh_once = .{ .source = .{ .path = "/p", .wire = .chatgpt_plan }, .generation = 4 } }, plan.rejection(&lease));
    try std.testing.expectEqual(@as(?*provider_transport.SharedCredential, null), credentials.head);
}

test "a sign-in's routing owner is its account and FedRAMP binding, which a refresh keeps" {
    const signed_in: Credential = .{ .chatgpt_device = .{ .path = "/c" } };
    var owners: [4]turn_states.TurnStates.Owner = undefined;
    for ([_][]const u8{ "acct", "acct", "other", "acct" }, [_]bool{ false, false, false, true }, [_][]const u8{ "token-1", "token-2", "token-1", "token-1" }, &owners) |account, fedramp, access, *owner| {
        var lease: Lease = undefined;
        lease.record = .{ .generation = 1, .account_id = .{}, .fedramp = fedramp, .id_token = .{}, .access_token = .{}, .refresh_token = .{}, .expires_at = 0, .refreshed_at = 0 };
        try lease.record.account_id.set(account);
        try lease.record.access_token.set(access);
        owner.* = signed_in.routingOwner(&lease);
    }
    try std.testing.expectEqualSlices(u8, &owners[0], &owners[1]);
    try std.testing.expect(!std.mem.eql(u8, &owners[0], &owners[2]));
    try std.testing.expect(!std.mem.eql(u8, &owners[0], &owners[3]));
    const keyed: Credential = .{ .key_file = .{ .key = "sk-test" } };
    try std.testing.expectEqualSlices(u8, &keyed.routingOwner(null), &Credential.routingOwner(.none, null));
}

test "the model list sits beside the Responses endpoint" {
    try std.testing.expectEqualStrings("https://api.openai.com/v1", responsesBase(endpoint(.openai)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), responsesBase("https://host/v1/chat"));
}

test "prepared provider projection derives every credential endpoint and Host trust" {
    const hs = @import("host_settings.zig");
    const gpa = std.testing.allocator;
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    settings.network.ca_file = .{};
    try settings.network.ca_file.?.text.set("relative/root.pem");
    inline for (std.enums.values(Provider)) |named| {
        const entry = &@field(settings.providers.entries, @tagName(named)).?;
        switch (comptime named.facts().credential) {
            .api_key => {
                entry.key.bytes.len = 3;
                @memcpy(entry.key.bytes.bytes[0..3], "key");
                entry.endpoint = .{};
                try entry.endpoint.?.text.set("https://proxy.example/responses");
            },
            .sign_in => {
                entry.credential_file = .{};
                try entry.credential_file.?.text.set("/tmp/" ++ @tagName(named) ++ ".json");
            },
        }
    }
    const served = fromSettings(settings);
    try std.testing.expectEqualStrings("relative/root.pem", served.ca_file.?);
    inline for (std.enums.values(Provider)) |named| {
        const entry = served.get(named).?;
        try std.testing.expectEqualStrings(if (comptime named.facts().credential == .api_key) "https://proxy.example/responses" else endpoint(named), entry.endpoint);
        switch (comptime named.facts().credential) {
            .api_key => try std.testing.expectEqualStrings("key", entry.credential.key_file.key),
            .sign_in => try std.testing.expectEqualStrings("/tmp/" ++ @tagName(named) ++ ".json", entry.credential.signIn().?.path),
        }
        @field(settings.providers.entries, @tagName(named)).?.unauthenticated.value = true;
    }
    const uncredentialed = fromSettings(settings);
    inline for (std.enums.values(Provider)) |named| try std.testing.expect(uncredentialed.get(named).?.credential == .none);
    inline for (std.enums.values(Provider)) |named| {
        const entry = &@field(settings.providers.entries, @tagName(named)).?;
        entry.unauthenticated.value = false;
        entry.endpoint = .{};
        try entry.endpoint.?.text.set("http://127.0.0.1:9/responses");
    }
    settings.providers.entries.chatgpt.?.token_endpoint = .{};
    try settings.providers.entries.chatgpt.?.token_endpoint.?.text.set("http://127.0.0.1:9/oauth/token");
    const fixture = fromSettings(settings);
    try std.testing.expect(fixture.get(.openai).?.credential.key_file.fixture);
    try std.testing.expect(fixture.get(.codex).?.credential.chatgpt_device.refresh == .synthetic);
    try std.testing.expectEqualStrings("http://127.0.0.1:9/oauth/token", fixture.get(.chatgpt).?.credential.chatgpt_plan.refresh.fixture_endpoint);
    inline for (std.enums.values(Provider)) |named| {
        @field(settings.providers.entries, @tagName(named)).?.unauthenticated.value = true;
    }
    const unauthenticated_fixture = fromSettings(settings);
    inline for (std.enums.values(Provider)) |named| try std.testing.expect(unauthenticated_fixture.get(named).?.credential == .none);
    settings.providers.entries.openai = null;
    try std.testing.expect(!fromSettings(settings).serves(.openai));
}

test "each route says how its model list reads, and a provider's list is live only over one that has a list" {
    const plan: Credential = .{ .chatgpt_plan = .{ .path = "/p" } };
    const keyed: Credential = .{ .key_file = .{ .key = "sk-test" } };
    const device: Credential = .{ .chatgpt_device = .{ .path = "/c" } };
    try std.testing.expectEqual(@as(?Listing, .chatgpt_plan), plan.listing());
    try std.testing.expectEqual(@as(?Listing, .openai), keyed.listing());
    try std.testing.expectEqual(@as(?Listing, null), device.listing());
    try std.testing.expectEqual(@as(?Listing, null), Credential.listing(.none));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: model_list.IdBuffer = undefined;
    const plan_body = "{\"models\":[{\"slug\":\"gpt-6-sol\",\"visibility\":\"list\"},{\"slug\":\"hidden\",\"visibility\":\"hide\"}]}";
    const key_body = "{\"data\":[{\"id\":\"gpt-6-luna\"}]}";
    try std.testing.expectEqualStrings("gpt-6-sol\n", (try Listing.chatgpt_plan.parse(arena.allocator(), plan_body, &out)).bytes);
    try std.testing.expectError(error.InvalidModelList, Listing.chatgpt_plan.parse(arena.allocator(), key_body, &out));
    try std.testing.expectEqualStrings("gpt-6-luna\n", (try Listing.openai.parse(arena.allocator(), key_body, &out)).bytes);
    try std.testing.expectError(error.InvalidModelList, Listing.openai.parse(arena.allocator(), plan_body, &out));

    var providers: Providers = .{};
    for (std.enums.values(Provider)) |name| try std.testing.expect(providers.liveList(name) == null);
    try std.testing.expectEqual(@as(usize, 0), providers.liveLists());
    providers.table.set(.codex, .{ .endpoint = endpoint(.codex), .credential = device });
    providers.table.set(.openai, .{ .endpoint = endpoint(.openai), .credential = keyed });
    providers.table.set(.chatgpt, .{ .endpoint = endpoint(.chatgpt), .credential = plan });
    try std.testing.expect(providers.liveList(.codex) == null);
    try std.testing.expectEqual(providers.get(.openai).?, providers.liveList(.openai).?);
    try std.testing.expectEqual(providers.get(.chatgpt).?, providers.liveList(.chatgpt).?);
    try std.testing.expectEqual(@as(usize, 2), providers.liveLists());
    providers.table.set(.openai, .{ .endpoint = "http://127.0.0.1:9/responses", .credential = .none });
    providers.table.set(.chatgpt, .{ .endpoint = "http://127.0.0.1:9/chat", .credential = plan });
    try std.testing.expect(providers.liveList(.openai) == null and providers.liveList(.chatgpt) == null);
    try std.testing.expectEqual(@as(usize, 0), providers.liveLists());
}
