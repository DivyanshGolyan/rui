const std = @import("std");
const credentials = @import("codex_credentials.zig");
const policy = @import("codex_credential_policy.zig");
const wire = @import("codex_token_wire.zig");
const pages = @import("os/pages.zig");

const h2 = @import("h2");

pub const issuer = wire.issuer;
pub const client_id = wire.client_id;
pub const upstream_pin = "968835997714baaff199cfed5f89a2c65d8ca77d";
pub const fixture_access_token = policy.fixture_access_token;
pub const fixture_id_token = policy.fixture_id_token;
pub const fixture_account_id = policy.fixture_account_id;
pub const response_limit = wire.response_limit;
pub const loginRecord = wire.loginRecord;
pub const LocalStatus = policy.LocalStatus;
/// Owns all credential bytes. Callers must keep this value out of diagnostics.
pub const Tokens = wire.Tokens;

pub const failureCode = policy.failureCode;

pub fn nowSeconds(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_s));
}

/// Storage for reading and checking one credential: the file, the record a
/// status check or login reads, and the token claims. Its owner keeps it off
/// the stack: the Host's AuthWorker for every acquisition, or a CLI command.
pub const Work = struct {
    credentials: credentials.Scratch = undefined,
    claims: policy.ClaimScratch = undefined,
};

/// Storage for one `rui auth login`: the snapshot and installation it reads
/// and writes through, the tokens its exchange returns, and the record it
/// builds from them. The command maps it for the call (`pages.Mapped`), as a
/// refresh maps its own, instead of holding it on its stack.
pub const Login = struct {
    work: Work = undefined,
    tokens: Tokens = undefined,
    record: credentials.Record = undefined,
};

/// Reads a snapshot without a refresh lock and applies the runtime's routing
/// and expiry checks to it.
pub fn localStatus(path: []const u8, now_seconds: i64) !LocalStatus {
    const mapped = try pages.Mapped(Work).map();
    defer mapped.unmap();
    const work = mapped.value;
    const record = &work.credentials.current;
    defer std.crypto.secureZero(u8, std.mem.asBytes(record));
    if (!try credentials.readSnapshotInto(path, record, &work.credentials)) return .missing;
    return policy.localStatus(record, now_seconds, &work.claims);
}

/// Selects on the lease it holds; a due refresh releases it, exchanges, and
/// leases the replacement.
pub fn acquireInto(io: std.Io, path: []const u8, fixture: bool, work: *Work, destination: *credentials.Lease) !void {
    try credentials.leaseInto(path, destination, &work.credentials);
    const selection = policy.select(&destination.record, fixture, nowSeconds(io), &work.claims) catch |err| {
        destination.release();
        return err;
    };
    if (selection == .refresh) {
        const generation = destination.record.generation;
        destination.release();
        _ = try exchangeAt(io, path, fixture, generation);
        try credentials.leaseInto(path, destination, &work.credentials);
    }
    errdefer destination.release();
    try policy.launchCheck(&destination.record, fixture, nowSeconds(io), &work.claims);
}

/// After a model 401, refreshes once if the committed credential generation
/// still equals the rejected lease's. Returns false when another Host or a
/// login already advanced the generation; the caller then fails as before.
pub fn forceRefresh(io: std.Io, path: []const u8, fixture: bool, expected_generation: u64) !bool {
    return exchangeAt(io, path, fixture, expected_generation);
}

/// Storage for one refresh: the records it claims and builds, the request,
/// the response and what parsing it needs. A refresh or a login runs a few
/// times an hour at most, so its storage lives in pages mapped for the call
/// and leaves nothing resident or on a stack once the call returns.
const Refresh = struct {
    credentials: credentials.Scratch = undefined,
    replacement: credentials.Record = undefined,
    wire: wire.Scratch = undefined,
    response: Response = undefined,
    body: [32 * 1024]u8 = undefined,
};

/// One refresh claim at `expected_generation` under the exclusive credential
/// lock. The synthetic fixture credential cannot reach the real issuer, so
/// its exchange republishes the same tokens; generation, claim and
/// replacement admission still follow the production owner.
fn exchangeAt(io: std.Io, path: []const u8, fixture: bool, expected_generation: u64) !bool {
    const mapped = try pages.Mapped(Refresh).map();
    defer mapped.unmap();
    const room = mapped.value;
    const Context = struct { io: std.Io, fixture: bool, room: *Refresh };
    return credentials.exchangeRefresh(path, expected_generation, &room.credentials, &room.replacement, Context{ .io = io, .fixture = fixture, .room = room }, struct {
        fn exchange(context: Context, current: *const credentials.Record, replacement: *credentials.Record) !void {
            try policy.validateSelected(current, context.fixture, &context.room.wire.claims);
            if (context.fixture) {
                replacement.* = current.*;
                replacement.state = .ready;
                replacement.refreshed_at = nowSeconds(context.io);
            } else try refresh(context.io, current, replacement, context.room);
        }
    }.exchange);
}

test "a forced refresh runs only for the rejected lease's unchanged generation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(io, "private", .{ .permissions = .fromMode(0o700) });
    private.close(io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/private/codex.json", .{root[0..root_len]});
    var record: credentials.Record = .{
        .generation = 0,
        .account_id = .{},
        .id_token = .{},
        .access_token = .{},
        .refresh_token = .{},
        .expires_at = 4_102_444_800,
        .refreshed_at = 100,
    };
    try record.account_id.set(fixture_account_id);
    try record.id_token.set(fixture_id_token);
    try record.access_token.set(fixture_access_token);
    try record.refresh_token.set("synthetic-refresh");
    var scratch: credentials.Scratch = undefined;
    const committed = &scratch.current;
    try credentials.install(path, &record, null, &scratch);
    try credentials.loadInto(path, committed, &scratch);
    try std.testing.expectEqual(@as(u64, 1), committed.generation);

    // Unchanged generation: one exchange advances it and leaves it ready.
    try std.testing.expect(try forceRefresh(io, path, true, 1));
    try credentials.loadInto(path, committed, &scratch);
    try std.testing.expectEqual(@as(u64, 2), committed.generation);
    try std.testing.expectEqual(policy.State.ready, committed.state);
    try std.testing.expectEqualStrings(fixture_account_id, committed.account_id.slice());
    // A second Host holding the same stale lease sees the advanced
    // generation and performs no exchange.
    try std.testing.expect(!try forceRefresh(io, path, true, 1));
    try credentials.loadInto(path, committed, &scratch);
    try std.testing.expectEqual(@as(u64, 2), committed.generation);

    // A pending record requires login and is not exchanged again.
    record.generation = 2;
    record.state = .refresh_pending;
    var pending_file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    var serialized: [policy.max_file_bytes]u8 = undefined;
    try pending_file.writeStreamingAll(io, try policy.encode(&record, &serialized));
    pending_file.close(io);
    try std.testing.expectError(error.RefreshRequiresLogin, forceRefresh(io, path, true, 2));
    try std.testing.expectEqualStrings("provider_authentication_failed", failureCode(error.RefreshRequiresLogin));
}

const Response = struct {
    bytes: [response_limit]u8 = undefined,
    len: usize = 0,
    request_not_sent: bool = true,
};

fn post(io: std.Io, request: wire.Request, response: *Response, cancelled: ?*const fn () bool) !u16 {
    response.* = .{};
    if (cancelled) |check| if (check()) return error.LoginInterrupted;
    const fields = [_]h2.Field{.{ .name = "content-type", .value = request.content_type }};
    const outcome = h2.exchange(io, .{
        .url = request.url,
        .fields = &fields,
        .body = request.body,
        .response = &response.bytes,
        // The issuer is verified by the system's trust; --provider-ca-file
        // is the model provider's alone.
        .trust = .system,
        .proxy = h2.proxyFromEnvironment(),
        .connect_timeout_ns = 15 * std.time.ns_per_s,
        .total_timeout_ns = 60 * std.time.ns_per_s,
        .cancelled = cancelled,
    }) catch |err| switch (err) {
        // Before the request was launched: nothing can have been sent.
        error.InvalidUrl, error.CleartextNotLoopback => return error.TransportFailed,
        // A login reports these by name, for the setting to fix.
        error.HttpsProxyInvalid, error.HttpsProxySchemeUnsupported => |proxy| return proxy,
        error.OutOfMemory, error.SystemResources, error.TooManyEndpoints, error.TrustUnavailable, error.InvalidCaFile, error.InvalidRequest => return error.TransportInitializationFailed,
        // Named for the variable to fix: SSL_CERT_FILE or SSL_CERT_DIR.
        error.InvalidSslCertFile, error.InvalidSslCertDir => |trust| return trust,
        // While it was in flight: no evidence either way.
        error.Interrupted => {
            response.request_not_sent = false;
            return error.LoginInterrupted;
        },
        error.PollFailed => {
            response.request_not_sent = false;
            return error.TransportFailed;
        },
    };
    switch (outcome) {
        .answered => |answer| {
            response.request_not_sent = false;
            response.len = answer.body.len;
            // A login cancelled while its answer arrived still stops here.
            if (cancelled) |check| if (check()) return error.LoginInterrupted;
            return answer.status;
        },
        .failed => |end| {
            response.request_not_sent = !end.request_sent;
            return if (end.cause == .sink_refused) error.ResponseTooLong else error.TransportFailed;
        },
        .timed_out => |timed_out| {
            response.request_not_sent = !timed_out.request_sent;
            return error.TransportFailed;
        },
    }
}

const json_request = wire.Request{ .url = "", .content_type = "application/json", .body = "synthetic" };

fn testUrl(buffer: []u8, port: u16) ![]const u8 {
    return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/oauth/token", .{port});
}

test "refresh transport requires positive evidence that no request was sent" {
    const io = std.testing.io;
    var answer: Response = .{};
    var request = json_request;
    request.url = "://";
    try std.testing.expectError(error.TransportFailed, post(io, request, &answer, null));
    try std.testing.expect(answer.request_not_sent);

    // A port whose listener just closed refuses the connection.
    var listener = try (try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0")).listen(io, .{});
    const port = listener.socket.address.getPort();
    listener.deinit(io);
    var url: [64]u8 = undefined;
    request.url = try testUrl(&url, port);
    answer.request_not_sent = false;
    try std.testing.expectError(error.TransportFailed, post(io, request, &answer, null));
    try std.testing.expect(answer.request_not_sent);
}

/// A raw TCP peer: it writes `greeting`, reads the client's bytes until
/// `until` appears, and closes. A `reply` is written only then, so a client
/// that fails on it has already been seen, and the peer reads on until the
/// client closes: closing first on unread bytes could reset the connection
/// before the client reads the reply.
const RawPeer = struct {
    fn run(server: *std.Io.net.Server, greeting: []const u8, until: []const u8, reply: []const u8) bool {
        const io = std.testing.io;
        const peer = server.accept(io) catch return false;
        defer peer.close(io);
        var writer = peer.writer(io, &.{});
        writer.interface.writeAll(greeting) catch return false;
        var received: [4096]u8 = undefined;
        var used: usize = 0;
        while (used < received.len) {
            var data = [_][]u8{received[used..]};
            const count = (peer.readWithControl(io, &data, &.{}) catch return false).data_len;
            if (count == 0) return false;
            used += count;
            if (std.mem.indexOf(u8, received[0..used], until) != null) {
                // `until` was seen; a client gone before the reply changes nothing.
                if (reply.len == 0) return true;
                writer.interface.writeAll(reply) catch return true;
                while (true) {
                    var rest = [_][]u8{&received};
                    const drained = (peer.readWithControl(io, &rest, &.{}) catch return true).data_len;
                    if (drained == 0) return true;
                }
            }
        }
        return false;
    }

    /// Posts against a RawPeer and reports whether the peer saw `until`.
    /// The peer is cancelled after the post, so a post that never connects
    /// fails the test instead of leaving `accept` blocked.
    fn exchangeWith(greeting: []const u8, until: []const u8, reply: []const u8, answer: *Response) !struct { anyerror!u16, bool } {
        const io = std.testing.io;
        var listener = try (try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0")).listen(io, .{});
        defer listener.deinit(io);
        var url: [64]u8 = undefined;
        var request = json_request;
        request.url = try testUrl(&url, listener.socket.address.getPort());
        var peer = try std.Io.concurrent(io, run, .{ &listener, greeting, until, reply });
        const outcome = post(io, request, answer, null);
        return .{ outcome, peer.cancel(io) };
    }
};

const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
/// An empty SETTINGS frame, which makes the client's connection ready.
const empty_settings = [_]u8{ 0, 0, 0, 4, 0, 0, 0, 0, 0 };

test "refresh transport keeps not-sent evidence when the peer goes before it is ready" {
    var answer: Response = .{};
    // The peer closes after the client's preface, without its own SETTINGS.
    const outcome, const saw = try RawPeer.exchangeWith("", preface, "", &answer);
    try std.testing.expect(saw);
    try std.testing.expectError(error.TransportFailed, outcome);
    try std.testing.expect(answer.request_not_sent);
}

test "refresh transport keeps not-sent evidence when the peer does not speak HTTP/2" {
    var answer: Response = .{};
    const outcome, const saw = try RawPeer.exchangeWith("", preface, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", &answer);
    try std.testing.expect(saw);
    try std.testing.expectError(error.TransportFailed, outcome);
    try std.testing.expect(answer.request_not_sent);
}

test "refresh transport retains sent evidence when the peer loses its reply" {
    var answer: Response = .{};
    // DATA payloads are plain bytes on h2c, so the body shows on the wire.
    const outcome, const saw = try RawPeer.exchangeWith(&empty_settings, "synthetic", "", &answer);
    try std.testing.expect(saw);
    try std.testing.expectError(error.TransportFailed, outcome);
    try std.testing.expect(!answer.request_not_sent);
}

test "device login cancellation rejects before a provider request" {
    const cancelled = struct {
        fn yes() bool {
            return true;
        }
    }.yes;
    var tokens: Tokens = undefined;
    try std.testing.expectError(error.LoginInterrupted, login(std.testing.io, struct {
        fn display(_: []const u8) !void {}
    }.display, cancelled, &tokens));
}

/// Storage for a device login's exchanges: the one response it reads at a
/// time, the device code, the exchange form and the parse arena.
const Device = struct {
    response: Response = undefined,
    start: wire.DeviceStart = undefined,
    form: [32 * 1024]u8 = undefined,
    arena: [wire.wire_arena_bytes]u8 = undefined,
};

/// Runs a device login and fills `tokens` from its authorization exchange.
pub fn login(io: std.Io, callback: anytype, cancelled: *const fn () bool, tokens: *Tokens) !void {
    const mapped = try pages.Mapped(Device).map();
    defer mapped.unmap();
    const room = mapped.value;
    const answer = &room.response;
    const device = &room.start;
    defer std.crypto.secureZero(u8, std.mem.asBytes(device));
    {
        defer std.crypto.secureZero(u8, std.mem.asBytes(answer));
        const begin_status = try post(io, wire.device_start, answer, cancelled);
        try wire.parseDeviceStart(begin_status, answer.bytes[0..answer.len], &room.arena, device);
    }
    try callback(device.userCode());

    const started = std.Io.Clock.Timestamp.now(io, .boot);
    const deadline_ns = 15 * std.time.ns_per_min;
    while (true) {
        if (cancelled()) return error.LoginInterrupted;
        const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(io, .boot)).raw.nanoseconds;
        if (elapsed >= deadline_ns) return error.LoginExpired;
        defer std.crypto.secureZero(u8, std.mem.asBytes(answer));
        const answer_status = try post(io, device.pollRequest(), answer, cancelled);
        if (try wire.classifyPoll(answer_status, answer.bytes[0..answer.len]) == .pending) {
            const remaining = deadline_ns - started.durationTo(std.Io.Clock.Timestamp.now(io, .boot)).raw.nanoseconds;
            if (remaining <= 0) return error.LoginExpired;
            var waiting = @min(@as(i96, device.interval_seconds) * std.time.ns_per_s, remaining);
            while (waiting > 0) {
                if (cancelled()) return error.LoginInterrupted;
                const slice = @min(waiting, 100 * std.time.ns_per_ms);
                io.sleep(.fromNanoseconds(slice), .awake) catch |err| {
                    if (cancelled()) return error.LoginInterrupted;
                    return err;
                };
                waiting -= slice;
            }
            continue;
        }
        defer std.crypto.secureZero(u8, &room.form);
        const exchange = try wire.grantExchangeRequest(answer.bytes[0..answer.len], &room.form, &room.arena);
        // The grant is consumed; the exchange's answer replaces it.
        const exchange_status = try post(io, exchange, answer, cancelled);
        return wire.parseTokenResponse(exchange_status, answer.bytes[0..answer.len], &room.arena, tokens);
    }
}

/// Exchanges the claimed record's refresh token and builds its replacement.
fn refresh(io: std.Io, current: *const credentials.Record, replacement: *credentials.Record, room: *Refresh) !void {
    defer std.crypto.secureZero(u8, &room.body);
    const answer = &room.response;
    defer std.crypto.secureZero(u8, std.mem.asBytes(answer));
    const request = wire.refreshRequest(current, &room.body) catch return error.RefreshRequestNotSent;
    const status = post(io, request, answer, null) catch |err| {
        if (answer.request_not_sent) return error.RefreshRequestNotSent;
        return err;
    };
    try wire.parseRefreshResponse(current, status, answer.bytes[0..answer.len], nowSeconds(io), replacement, &room.wire);
}
