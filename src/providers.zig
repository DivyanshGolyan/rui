//! The providers a Host serves: where each one's requests go, and the sign-in
//! source behind the credential they carry there. Core asks a `Credential`
//! what it needs (`leased`, `validate`, `fields`, `rejection`,
//! `routingOwner`) and never which kind it is; what a ChatGPT sign-in or an
//! API key writes, and where it may go, lives here.
const std = @import("std");
const protocol = @import("protocol.zig");
const h2 = @import("h2");
const api_key = @import("api_key.zig");
const codex_auth = @import("codex_auth.zig");
const codex_credentials = @import("codex_credentials.zig");
const failure_class = @import("failure_class.zig");
const provider_transport = @import("provider.zig");
const turn_states = @import("turn_states.zig");

const Provider = protocol.Provider;

/// The ChatGPT subscription's Responses endpoint, the only one a signed-in
/// account's token goes to (a fixture's loopback aside).
pub const managed_endpoint = "https://chatgpt.com/backend-api/codex/responses";

/// A ChatGPT sign-in's credential file, and whether it is the test fixture.
/// The Host's sign-in worker runs its jobs: a launch lease, or the one
/// forced refresh after a model 401.
pub const Authentication = struct {
    path: []const u8,
    fixture: bool = false,

    /// The storage an acquisition reads through, which the worker keeps.
    pub const Work = codex_auth.Work;

    /// Leases the current token into `lease`, refreshing it first when due.
    pub fn acquire(self: Authentication, io: std.Io, work: *Work, lease: *Lease) !void {
        try codex_auth.acquireInto(io, self.path, self.fixture, work, lease);
    }

    /// Refreshes the token a 401 rejected at `generation`; false when another
    /// refresh already replaced it.
    pub fn refresh(self: Authentication, io: std.Io, generation: u64) !bool {
        return codex_auth.forceRefresh(io, self.path, self.fixture, generation);
    }
};

/// A sign-in's current token, which the Host's sign-in worker leases.
pub const Lease = codex_credentials.Lease;

/// The failure a sign-in worker's lease or refresh error settles under.
pub fn leaseFailureCode(err: anyerror) []const u8 {
    return codex_auth.failureCode(err);
}

/// A provider's own endpoint, the only one its credential is sent to.
pub fn endpoint(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => managed_endpoint,
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
    validateKeyEndpoint(under, null, false) catch return error.InvalidBaseUrl;
    return under;
}

/// The base a Responses endpoint sits under (`BASE` of `BASE/responses`),
/// whose model list (`BASE/models`) its key may also reach, or null when
/// the endpoint is not one.
pub fn responsesBase(responses: []const u8) ?[]const u8 {
    return std.mem.cutSuffix(u8, responses, "/responses");
}

/// The sign-in source behind a provider's requests: a closed set, since
/// each holds a secret. Each answers for itself where it may go, what it
/// writes, what a rejection of it means and who a routing value belongs to.
pub const Credential = union(enum) {
    /// A development endpoint, which takes no credential.
    none,
    /// A ChatGPT sign-in, whose token the Host's sign-in worker leases.
    chatgpt_device: Authentication,
    /// An API key, borrowed for the Host's life. It goes only to its entry's
    /// endpoint, over https; `fixture` admits a loopback endpoint instead.
    key_file: struct { key: []const u8, fixture: bool = false },

    /// What a 401 from the model endpoint means for the credential a
    /// transfer presented.
    pub const Rejection = union(enum) {
        /// The answer settles as it is.
        settle,
        /// The Operation may spend its one forced refresh of the lease
        /// generation the transfer presented.
        refresh_once: u64,
        /// The answer settles under this code, which names its remedy.
        code: []const u8,
    };

    /// Whether a request waits for the sign-in worker's lease before it
    /// launches, and its launch then passes that lease to `fields`.
    pub fn leased(self: Credential) bool {
        return self == .chatgpt_device;
    }

    /// Refuses an endpoint this credential may not go to, at Host start.
    pub fn validate(self: Credential, served_endpoint: []const u8, ca_file: ?[]const u8) !void {
        switch (self) {
            .none => {},
            .chatgpt_device => |authentication| try validateAuthenticationEndpoint(served_endpoint, ca_file, authentication),
            .key_file => |key| try validateKeyEndpoint(served_endpoint, ca_file, key.fixture),
        }
    }

    /// Writes this credential's fields into `headers`, sharing the secret
    /// through `shared`. A leased credential takes its `lease`; the others
    /// take none.
    pub fn fields(self: Credential, served_endpoint: []const u8, ca_file: ?[]const u8, lease: ?*const Lease, shared: *provider_transport.Credentials, headers: *Headers) !void {
        std.debug.assert(self.leased() == (lease != null));
        switch (self) {
            .none => {},
            .chatgpt_device => |authentication| try headers.initSignIn(served_endpoint, ca_file, authentication, lease.?, shared),
            .key_file => |key| try headers.initKey(served_endpoint, ca_file, key.key, key.fixture, shared),
        }
    }

    /// What a 401 means for a transfer that presented this credential and
    /// `lease`: a sign-in may refresh once, a key names its own remedy, and
    /// no credential settles as answered.
    pub fn rejection(self: Credential, lease: ?*const Lease) Rejection {
        return switch (self) {
            .none => .settle,
            .chatgpt_device => .{ .refresh_once = lease.?.record.generation },
            .key_file => .{ .code = failure_class.api_key_rejected },
        };
    }

    /// Who a Turn's routing value belongs to (`turn_states`): a signed-in
    /// account's values go back only to that account. A sign-in owner is
    /// its account and FedRAMP binding, which a refresh keeps, read from
    /// `lease`. A key or no credential is fixed for the Host's life, so it
    /// is one owner.
    pub fn routingOwner(self: Credential, lease: ?*const Lease) turn_states.TurnStates.Owner {
        return switch (self) {
            .none, .key_file => @splat(0),
            .chatgpt_device => owner: {
                const record = &lease.?.record;
                var hash = std.crypto.hash.sha2.Sha256.init(.{});
                hash.update(&.{@intFromBool(record.fedramp)});
                hash.update(record.account_id.slice());
                break :owner hash.finalResult();
            },
        };
    }

    pub fn route(self: Credential) protocol.Route {
        return switch (self) {
            .none => .endpoint,
            .chatgpt_device => .chatgpt_device,
            .key_file => .key_file,
        };
    }
};

fn fixtureEndpoint(target: []const u8, ca_file: ?[]const u8) bool {
    return std.mem.startsWith(u8, target, "http://127.0.0.1:") or
        std.mem.startsWith(u8, target, "http://[::1]:") or
        (std.mem.startsWith(u8, target, "https://localhost:") and ca_file != null);
}

fn validateAuthenticationEndpoint(target: []const u8, ca_file: ?[]const u8, authentication: Authentication) !void {
    if (authentication.fixture and !fixtureEndpoint(target, ca_file))
        return error.InvalidCodexFixtureEndpoint;
}

/// An API key goes over https, or to a loopback fixture when `fixture`.
fn validateKeyEndpoint(target: []const u8, ca_file: ?[]const u8, fixture: bool) !void {
    if (fixture) {
        if (!fixtureEndpoint(target, ca_file)) return error.InvalidKeyFixtureEndpoint;
    } else if (!std.mem.startsWith(u8, target, "https://")) return error.InsecureKeyEndpoint;
}

/// The fields the Host writes after the codec's headers: the credential's,
/// which its sign-in source writes (`Credential.fields`), user-agent, and the
/// Turn's routing value, each named in `provider.host_request_fields` so no
/// codec header can name it.
pub const Headers = struct {
    entries: [5]h2.Field = undefined,
    length: usize = 0,
    credentials: *provider_transport.Credentials = undefined,
    /// A use of the Reactor's copy of this credential, owned until
    /// `takeCredential` hands it to the Transfer.
    credential: ?*provider_transport.SharedCredential = null,

    /// Initialize in final stack storage. The fields are borrowed only until
    /// Transfer.start, whose stream copies the per-request ones; h2 borrows
    /// the credential (its Transfer then holds the use) and the literals.
    fn initSignIn(self: *Headers, target: []const u8, ca_file: ?[]const u8, authentication: Authentication, credential: *const Lease, shared_credentials: *provider_transport.Credentials) !void {
        const access = credential.record.access_token.slice();
        const account_id = credential.record.account_id.slice();
        if (authentication.fixture) {
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
        // Borrowed where two addresses (16 bytes) are smaller than a copy.
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

    /// An API key's fields: the key and user-agent. The key goes only over
    /// https, or for a fixture to a loopback target.
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

    /// The Turn's routing value under the codec's routing header, last and
    /// only when the Turn has one: whatever credential the request carries,
    /// a provider that never sent the header is never sent one. Borrowed
    /// until Transfer.start, like the others.
    pub fn routing(self: *Headers, name: []const u8, value: []const u8) void {
        if (name.len == 0 or value.len == 0) return;
        self.entries[self.length] = .{ .name = name, .value = value };
        self.length += 1;
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

    /// The one leased sign-in whose leases and refreshes this Host's
    /// sign-in worker serves, if any.
    pub fn leaseWorker(self: *const Providers) ?Authentication {
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

    /// The OpenAI key whose model list the Host fetches at start: served,
    /// with a Responses endpoint the list sits beside. ChatGPT has none.
    pub fn modelListKey(self: *const Providers) ?*const Served {
        const served = self.get(.openai) orelse return null;
        if (served.credential != .key_file or responsesBase(served.endpoint) == null) return null;
        return served;
    }

    /// Whether a Session of `provider` can be admitted here.
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
    var credentials: provider_transport.Credentials = .{ .allocator = std.testing.allocator };
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
        // A key's request echoes a routing value the same way a sign-in's does.
        headers.routing("x-codex-turn-state", "sticky");
        try std.testing.expectEqual(@as(usize, 3), headers.fields().len);
        try std.testing.expectEqualStrings("sticky", headers.fields()[2].value);
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

test "ChatGPT headers carry the routing value only when the Turn has one" {
    var credential: Lease = undefined;
    var credentials: provider_transport.Credentials = .{ .allocator = std.testing.allocator };
    for ([_]bool{ false, true }) |fedramp| {
        credential.record = try testRecord(codex_auth.fixture_account_id, fedramp, codex_auth.fixture_access_token, 1);
        for ([_][]const u8{ "", "sticky value", &@as([provider_transport.max_turn_state_bytes]u8, @splat('v')) }) |turn_state| {
            var headers: Headers = .{};
            defer headers.deinit();
            try headers.initSignIn("http://127.0.0.1:1/responses", null, .{ .path = "unused", .fixture = true }, &credential, &credentials);
            headers.routing("x-codex-turn-state", turn_state);
            const entries = headers.fields();
            var found: ?[]const u8 = null;
            var fedramp_found = false;
            for (entries) |entry| {
                // h2 sends names as given, and HTTP/2 requires them lowercase.
                for (entry.name) |byte| try std.testing.expect(!std.ascii.isUpper(byte));
                try std.testing.expectEqual(std.mem.eql(u8, entry.name, "authorization") or
                    std.mem.eql(u8, entry.name, "chatgpt-account-id"), entry.sensitive);
                if (std.mem.eql(u8, entry.name, "x-codex-turn-state")) {
                    try std.testing.expect(found == null);
                    found = entry.value;
                }
                if (std.mem.eql(u8, entry.name, "x-openai-fedramp")) fedramp_found = std.mem.eql(u8, entry.value, "true");
                if (std.mem.eql(u8, entry.name, "authorization"))
                    try std.testing.expectEqualStrings("Bearer " ++ codex_auth.fixture_access_token, entry.value);
                // No codec header names it.
                try std.testing.expect(provider_transport.hostField(entry.name));
            }
            // The credential is the Reactor's one copy, which h2 borrows;
            // only the per-request values are copied into each stream.
            for (entries) |entry| try std.testing.expectEqual(entry.name.len + entry.value.len > 16 and
                !std.mem.eql(u8, entry.name, "x-codex-turn-state"), entry.borrowed);
            // They follow the codec's headers: the credential, user-agent,
            // FedRAMP, turn state.
            const shared = headers.credential.?;
            try std.testing.expectEqualStrings("authorization", entries[0].name);
            try std.testing.expectEqual(shared.authorization().ptr, entries[0].value.ptr);
            try std.testing.expectEqualStrings("chatgpt-account-id", entries[1].name);
            try std.testing.expectEqual(shared.accountId().ptr, entries[1].value.ptr);
            try std.testing.expectEqualStrings("user-agent", entries[2].name);
            if (fedramp) try std.testing.expectEqualStrings("x-openai-fedramp", entries[3].name);
            if (turn_state.len != 0) try std.testing.expectEqualStrings("x-codex-turn-state", entries[entries.len - 1].name);
            try std.testing.expectEqual(fedramp, fedramp_found);
            try std.testing.expectEqual(@as(usize, 3) + @intFromBool(fedramp) + @intFromBool(turn_state.len != 0), entries.len);
            try std.testing.expectEqualStrings(turn_state, found orelse "");
        }
    }
}

test "each sign-in source says whether it waits for a lease and what a 401 means" {
    var lease: Lease = undefined;
    lease.record = try testRecord(codex_auth.fixture_account_id, false, codex_auth.fixture_access_token, 7);
    const signed_in: Credential = .{ .chatgpt_device = .{ .path = "/c", .fixture = true } };
    const keyed: Credential = .{ .key_file = .{ .key = "sk-test" } };
    try std.testing.expect(signed_in.leased() and !keyed.leased() and !Credential.leased(.none));
    // A sign-in may refresh the generation it presented; a key names its remedy.
    try std.testing.expectEqual(Credential.Rejection{ .refresh_once = 7 }, signed_in.rejection(&lease));
    try std.testing.expectEqualStrings(failure_class.api_key_rejected, keyed.rejection(null).code);
    try std.testing.expectEqual(Credential.Rejection.settle, Credential.rejection(.none, null));
    // Each refuses an endpoint it may not go to.
    try signed_in.validate("http://127.0.0.1:9/responses", null);
    try std.testing.expectError(error.InvalidCodexFixtureEndpoint, signed_in.validate(managed_endpoint, null));
    try std.testing.expectError(error.InsecureKeyEndpoint, keyed.validate("http://127.0.0.1:9/responses", null));
    try Credential.validate(.none, "http://127.0.0.1:9/responses", null);
    // No credential writes no fields.
    var shared: provider_transport.Credentials = .{ .allocator = std.testing.allocator };
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
    try std.testing.expectEqual(@as(?Authentication, null), providers.leaseWorker());
    providers.table.set(.codex, .{ .endpoint = endpoint(.codex), .credential = .{ .chatgpt_device = .{ .path = "/c" } } });
    try std.testing.expectEqual(protocol.Route.chatgpt_device, providers.routes().codex);
    try std.testing.expectEqualStrings("/c", providers.leaseWorker().?.path);
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
    // A refreshed token is the same owner; another account or FedRAMP is not.
    try std.testing.expectEqualSlices(u8, &owners[0], &owners[1]);
    try std.testing.expect(!std.mem.eql(u8, &owners[0], &owners[2]));
    try std.testing.expect(!std.mem.eql(u8, &owners[0], &owners[3]));
    const keyed: Credential = .{ .key_file = .{ .key = "sk-test" } };
    try std.testing.expectEqualSlices(u8, &keyed.routingOwner(null), &Credential.routingOwner(.none, null));
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
    const long = "https://h/" ++ @as([provider_transport.max_endpoint_bytes]u8, @splat('a'));
    try std.testing.expectError(error.InvalidBaseUrl, endpointUnder(allocator, long));
}

test "the model list sits beside the Responses endpoint" {
    try std.testing.expectEqualStrings("https://api.openai.com/v1", responsesBase(endpoint(.openai)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), responsesBase("https://host/v1/chat"));
}
