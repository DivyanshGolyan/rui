const std = @import("std");
const credentials = @import("codex_credentials.zig");
const policy = @import("codex_credential_policy.zig");
const wire = @import("codex_token_wire.zig");
const plan_wire = @import("chatgpt_plan_wire.zig");
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
pub const Tokens = wire.Tokens;

pub const failureCode = policy.failureCode;

pub fn nowSeconds(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_s));
}

pub const Work = struct {
    credentials: credentials.Scratch = undefined,
    claims: policy.ClaimScratch = undefined,
};

pub const Login = struct {
    work: Work = undefined,
    tokens: Tokens = undefined,
    record: credentials.Record = undefined,
};

pub const Wire = enum {
    codex_device,
    chatgpt_plan,

    fn refreshRequest(self: Wire, current: *const credentials.Record, buffer: []u8) !wire.Request {
        return switch (self) {
            .codex_device => wire.refreshRequest(current, buffer),
            .chatgpt_plan => plan_wire.refreshRequest(current, buffer),
        };
    }

    fn parseRefreshResponse(self: Wire, current: *const credentials.Record, status: u16, json: []const u8, refreshed_at: i64, replacement: *credentials.Record, scratch: *wire.Scratch) !void {
        return switch (self) {
            .codex_device => wire.parseRefreshResponse(current, status, json, refreshed_at, replacement, scratch),
            .chatgpt_plan => plan_wire.parseRefreshResponse(current, status, json, refreshed_at, replacement, scratch),
        };
    }
};

pub const Source = struct {
    path: []const u8,
    profile_id: ?credentials.ProfileId = null,
    profile_home: ?[]const u8 = null,
    wire: Wire,
    refresh: RefreshTarget = .issuer,

    pub const RefreshTarget = union(enum) {
        issuer,
        synthetic,
        fixture_endpoint: []const u8,
    };

    fn resolvedPath(self: Source, buffer: []u8) ![]const u8 {
        const id = self.profile_id orelse return self.path;
        const home = self.profile_home orelse return error.ProfileUnavailable;
        if (!std.fs.path.isAbsolute(home)) return error.ProfileUnavailable;
        return std.fmt.bufPrint(buffer, "{s}/.config/rui/profiles/{s}", .{ home, id.slice() }) catch error.ProfileUnavailable;
    }

    pub fn fixture(self: Source) bool {
        return self.refresh != .issuer;
    }

    fn synthetic(self: Source) bool {
        return self.refresh == .synthetic;
    }
};

pub fn localStatus(path: []const u8, now_seconds: i64) !LocalStatus {
    var shown: Shown = undefined;
    try localSignIn(path, now_seconds, &shown);
    return shown.status;
}

pub const Shown = struct {
    status: LocalStatus,
    email: policy.Email = .{},
    expires_at: i64 = 0,
};

pub fn localSignIn(path: []const u8, now_seconds: i64, shown: *Shown) !void {
    shown.* = .{ .status = .missing };
    const mapped = try pages.Mapped(Work).map();
    defer mapped.unmap();
    const work = mapped.value;
    const record = &work.credentials.current;
    defer std.crypto.secureZero(u8, std.mem.asBytes(record));
    if (!try credentials.readSnapshotInto(path, record, &work.credentials)) return;
    shown.status = try policy.localStatus(record, now_seconds, &work.claims);
    if (!shown.status.usable()) return;
    shown.expires_at = record.expires_at;
    policy.emailOf(record.id_token.slice(), &work.claims, &shown.email) catch {};
}

pub const ProfileInfo = struct {
    wire: Wire,
    status: LocalStatus,
    signed_out: bool,
    email: policy.Email = .{},
};

pub fn profileInfo(path: []const u8, id: credentials.ProfileId, now_seconds: i64) !?ProfileInfo {
    const mapped = try pages.Mapped(Work).map();
    defer mapped.unmap();
    const work = mapped.value;
    const record = &work.credentials.current;
    defer record.wipe();
    if (!try credentials.readProfileSnapshotInto(path, id, record, &work.credentials)) return null;
    var info: ProfileInfo = .{
        .wire = if (record.client_id.len == 0) .codex_device else .chatgpt_plan,
        .status = try policy.localStatus(record, now_seconds, &work.claims),
        .signed_out = record.state == .signed_out,
    };
    if (info.status.usable()) policy.emailOf(record.id_token.slice(), &work.claims, &info.email) catch {};
    return info;
}

pub const ProfileEntry = union(enum) { ready: ProfileInfo, unavailable: anyerror };

pub fn listProfiles(directory: []const u8, now_seconds: i64, context: anytype, visit: anytype) !void {
    const list_io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(list_io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(list_io);
    var iterator = dir.iterate();
    while (try iterator.next(list_io)) |entry| {
        const id = credentials.ProfileId.parse(entry.name) catch continue;
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ directory, id.slice() }) catch {
            try visit(context, id, ProfileEntry{ .unavailable = error.NameTooLong });
            continue;
        };
        const info = profileInfo(path, id, now_seconds) catch |err| {
            try visit(context, id, ProfileEntry{ .unavailable = err });
            continue;
        };
        try visit(context, id, if (info) |value| ProfileEntry{ .ready = value } else ProfileEntry{ .unavailable = error.FileNotFound });
    }
}

pub fn acquireInto(io: std.Io, source: Source, work: *Work, destination: *credentials.Lease) !void {
    try leaseSource(source, destination, &work.credentials);
    const selection = select(source, &destination.record, nowSeconds(io), &work.claims) catch |err| {
        destination.release();
        return err;
    };
    if (selection == .refresh) {
        const generation = destination.record.generation;
        destination.release();
        _ = try exchangeAt(io, source, generation);
        try leaseSource(source, destination, &work.credentials);
    }
    errdefer destination.release();
    try policy.launchCheck(&destination.record, source.synthetic(), nowSeconds(io), &work.claims);
}

fn leaseSource(source: Source, destination: *credentials.Lease, scratch: *credentials.Scratch) !void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try source.resolvedPath(&path_buffer);
    if (source.profile_id) |id| {
        try credentials.leaseProfileInto(path, id, destination, scratch);
        const actual: Wire = if (destination.record.client_id.len == 0) .codex_device else .chatgpt_plan;
        if (actual != source.wire) {
            destination.release();
            return error.AccountMismatch;
        }
    } else try credentials.leaseInto(path, destination, scratch);
}

fn select(source: Source, record: *const credentials.Record, now_seconds: i64, claims: *policy.ClaimScratch) !policy.Selection {
    if (source.refresh == .fixture_endpoint) try policy.requireFixtureClient(record);
    return policy.select(record, source.synthetic(), now_seconds, claims);
}

pub fn forceRefresh(io: std.Io, source: Source, expected_generation: u64) !bool {
    return exchangeAt(io, source, expected_generation);
}

const Refresh = struct {
    credentials: credentials.Scratch = undefined,
    replacement: credentials.Record = undefined,
    wire: wire.Scratch = undefined,
    response: Response = undefined,
    body: [32 * 1024]u8 = undefined,
};

fn exchangeAt(io: std.Io, source: Source, expected_generation: u64) !bool {
    const mapped = try pages.Mapped(Refresh).map();
    defer mapped.unmap();
    const room = mapped.value;
    if (source.profile_id != null) {
        var selected: credentials.Lease = undefined;
        try leaseSource(source, &selected, &room.credentials);
        selected.release();
    }
    const Context = struct { io: std.Io, source: Source, room: *Refresh };
    const exchange = struct {
        fn exchange(context: Context, current: *const credentials.Record, replacement: *credentials.Record) !void {
            if (context.source.profile_id != null) {
                const actual: Wire = if (current.client_id.len == 0) .codex_device else .chatgpt_plan;
                if (actual != context.source.wire) return error.AccountMismatch;
            }
            try policy.validateSelected(current, context.source.synthetic(), &context.room.wire.claims);
            if (context.source.synthetic()) {
                replacement.* = current.*;
                replacement.state = .ready;
                replacement.refreshed_at = nowSeconds(context.io);
            } else try refresh(context.io, context.source, current, replacement, context.room);
        }
    }.exchange;
    const context: Context = .{ .io = io, .source = source, .room = room };
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try source.resolvedPath(&path_buffer);
    if (source.profile_id) |id| return credentials.exchangeProfileRefresh(path, id, expected_generation, &room.credentials, &room.replacement, context, exchange);
    return credentials.exchangeRefresh(path, expected_generation, &room.credentials, &room.replacement, context, exchange);
}

test "CM-48 profile authentication retains its owner across refresh" {
    const test_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(test_io, ".config/rui/profiles", .{ .permissions = .fromMode(0o700) });
    private.close(test_io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(test_io, &root);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/.config/rui/profiles/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .{root[0..root_len]});
    const id = try credentials.ProfileId.parse("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    var record: credentials.Record = .{ .generation = 0, .account_id = .{}, .id_token = .{}, .access_token = .{}, .refresh_token = .{}, .expires_at = 4_102_444_800, .refreshed_at = 100 };
    defer record.wipe();
    try record.account_id.set(fixture_account_id);
    try record.id_token.set(fixture_id_token);
    try record.access_token.set(fixture_access_token);
    try record.refresh_token.set("synthetic-refresh");
    var scratch: credentials.Scratch = undefined;
    try std.testing.expect((try credentials.createProfile(path, id, &record, &scratch)) == .durable);
    const source: Source = .{ .path = path, .profile_id = id, .profile_home = root[0..root_len], .wire = .codex_device, .refresh = .synthetic };
    try std.testing.expect(try forceRefresh(test_io, source, 1));
    var work: Work = undefined;
    var lease: credentials.Lease = undefined;
    try acquireInto(test_io, source, &work, &lease);
    try std.testing.expectEqualStrings(id.slice(), lease.record.profile_id.slice());
    try std.testing.expectEqual(@as(u64, 2), lease.record.generation);
    lease.release();
    const wrong: Source = .{ .path = path, .profile_id = try credentials.ProfileId.parse("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), .profile_home = root[0..root_len], .wire = .codex_device, .refresh = .synthetic };
    try std.testing.expectError(error.FileNotFound, acquireInto(test_io, wrong, &work, &lease));
    try std.testing.expectError(error.FileNotFound, forceRefresh(test_io, wrong, 2));
    const mismatched: Source = .{ .path = path, .profile_id = id, .profile_home = root[0..root_len], .wire = .chatgpt_plan, .refresh = .synthetic };
    try std.testing.expectError(error.AccountMismatch, acquireInto(test_io, mismatched, &work, &lease));
    try std.testing.expectError(error.AccountMismatch, forceRefresh(test_io, mismatched, 2));
    try acquireInto(test_io, source, &work, &lease);
    try std.testing.expectEqual(@as(u64, 2), lease.record.generation);
    lease.release();
    const legacy: Source = .{ .path = path, .wire = .codex_device, .refresh = .synthetic };
    try std.testing.expectError(error.OwnedCredential, acquireInto(test_io, legacy, &work, &lease));
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

    const source: Source = .{ .path = path, .wire = .codex_device, .refresh = .synthetic };
    try std.testing.expect(try forceRefresh(io, source, 1));
    try credentials.loadInto(path, committed, &scratch);
    try std.testing.expectEqual(@as(u64, 2), committed.generation);
    try std.testing.expectEqual(policy.State.ready, committed.state);
    try std.testing.expectEqualStrings(fixture_account_id, committed.account_id.slice());
    try std.testing.expect(!try forceRefresh(io, source, 1));
    try credentials.loadInto(path, committed, &scratch);
    try std.testing.expectEqual(@as(u64, 2), committed.generation);

    record.generation = 2;
    record.state = .refresh_pending;
    var pending_file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    var serialized: [policy.max_file_bytes]u8 = undefined;
    try pending_file.writeStreamingAll(io, try policy.encode(&record, &serialized));
    pending_file.close(io);
    try std.testing.expectError(error.RefreshRequiresLogin, forceRefresh(io, source, 2));
    try std.testing.expectEqualStrings("provider_sign_in_required", failureCode(error.RefreshRequiresLogin));
}

pub const Response = struct {
    bytes: [response_limit]u8 = undefined,
    len: usize = 0,
    request_not_sent: bool = true,
};

pub fn post(io: std.Io, request: wire.Request, response: *Response, cancelled: ?*const fn () bool) !u16 {
    response.* = .{};
    if (cancelled) |check| if (check()) return error.LoginInterrupted;
    const fields = [_]h2.Field{.{ .name = "content-type", .value = request.content_type }};
    const outcome = h2.exchange(io, .{
        .url = request.url,
        .fields = &fields,
        .body = request.body,
        .response = &response.bytes,
        .trust = .system,
        .proxy = h2.proxyFromEnvironment(),
        .connect_timeout_ns = 15 * std.time.ns_per_s,
        .total_timeout_ns = 60 * std.time.ns_per_s,
        .cancelled = cancelled,
    }) catch |err| switch (err) {
        error.InvalidUrl, error.CleartextNotLoopback => return error.TransportFailed,
        error.HttpsProxyInvalid, error.HttpsProxySchemeUnsupported => |proxy| return proxy,
        error.OutOfMemory, error.SystemResources, error.TooManyEndpoints, error.TrustUnavailable, error.InvalidCaFile, error.InvalidRequest => return error.TransportInitializationFailed,
        error.InvalidSslCertFile, error.InvalidSslCertDir => |trust| return trust,
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

    var url: [64]u8 = undefined;
    request.url = try testUrl(&url, try @import("socket_fixture.zig").refusedPort());
    answer.request_not_sent = false;
    try std.testing.expectError(error.TransportFailed, post(io, request, &answer, null));
    try std.testing.expect(answer.request_not_sent);
}

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
const empty_settings = [_]u8{ 0, 0, 0, 4, 0, 0, 0, 0, 0 };

test "refresh transport keeps not-sent evidence when the peer goes before it is ready" {
    var answer: Response = .{};
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

const Device = struct {
    response: Response = undefined,
    start: wire.DeviceStart = undefined,
    form: [32 * 1024]u8 = undefined,
    arena: [wire.wire_arena_bytes]u8 = undefined,
};

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
        const exchange_status = try post(io, exchange, answer, cancelled);
        return wire.parseTokenResponse(exchange_status, answer.bytes[0..answer.len], &room.arena, tokens);
    }
}

fn refresh(io: std.Io, source: Source, current: *const credentials.Record, replacement: *credentials.Record, room: *Refresh) !void {
    defer std.crypto.secureZero(u8, &room.body);
    const answer = &room.response;
    defer std.crypto.secureZero(u8, std.mem.asBytes(answer));
    var request = source.wire.refreshRequest(current, &room.body) catch return error.RefreshRequestNotSent;
    switch (source.refresh) {
        .issuer => {},
        .fixture_endpoint => |url| {
            policy.requireFixtureClient(current) catch return error.RefreshRequestNotSent;
            request.url = url;
        },
        .synthetic => unreachable,
    }
    const status = post(io, request, answer, null) catch |err| {
        if (answer.request_not_sent) return error.RefreshRequestNotSent;
        return err;
    };
    try source.wire.parseRefreshResponse(current, status, answer.bytes[0..answer.len], nowSeconds(io), replacement, &room.wire);
}

test "CM-50 profile listing reports a damaged entry without hiding a healthy one" {
    const test_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(test_io, "private", .{ .permissions = .fromMode(0o700) });
    private.close(test_io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(test_io, &root);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try std.fmt.bufPrint(&directory_buffer, "{s}/private", .{root[0..len]});
    const a = try credentials.ProfileId.parse("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const b = try credentials.ProfileId.parse("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    var a_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var b_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const a_path = try std.fmt.bufPrint(&a_buffer, "{s}/{s}", .{ directory, a.slice() });
    const b_path = try std.fmt.bufPrint(&b_buffer, "{s}/{s}", .{ directory, b.slice() });
    var scratch: credentials.Scratch = undefined;
    try std.testing.expect(try credentials.createPrivate(a_path, "invalid", &scratch.file));
    var record: credentials.Record = .{ .generation = 0, .account_id = .{}, .id_token = .{}, .access_token = .{}, .refresh_token = .{}, .expires_at = 4_102_444_800, .refreshed_at = 100 };
    defer record.wipe();
    try record.account_id.set(fixture_account_id);
    try record.id_token.set(fixture_id_token);
    try record.access_token.set(fixture_access_token);
    try record.refresh_token.set("synthetic-refresh");
    _ = try credentials.createProfile(b_path, b, &record, &scratch);
    const Seen = struct {
        damaged: bool = false,
        healthy: bool = false,
        fn visit(self: *@This(), id: credentials.ProfileId, entry: ProfileEntry) !void {
            if (std.mem.eql(u8, id.slice(), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")) self.damaged = entry == .unavailable;
            if (std.mem.eql(u8, id.slice(), "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")) self.healthy = entry == .ready;
        }
    };
    var seen: Seen = .{};
    try listProfiles(directory, 1_750_000_000, &seen, Seen.visit);
    try std.testing.expect(seen.damaged);
    try std.testing.expect(seen.healthy);
}
