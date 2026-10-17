const std = @import("std");
const builtin = @import("builtin");
const credentials = @import("codex_credentials.zig");
const policy = @import("codex_credential_policy.zig");
const wire = @import("codex_token_wire.zig");

const c = @import("curl");

pub const issuer = wire.issuer;
pub const client_id = wire.client_id;
pub const upstream_pin = "968835997714baaff199cfed5f89a2c65d8ca77d";
pub const fixture_access_token = policy.fixture_access_token;
pub const fixture_id_token = policy.fixture_id_token;
pub const fixture_account_id = policy.fixture_account_id;
pub const response_limit = wire.response_limit;
pub const parseAccount = policy.parseAccount;
pub const parseExpiry = policy.parseExpiry;
pub const LocalStatus = policy.LocalStatus;
/// Owns all credential bytes. Callers must keep this value out of diagnostics.
pub const Tokens = wire.Tokens;

pub const failureCode = policy.failureCode;

fn nowSeconds(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_s));
}

/// Reads a snapshot without a refresh lock and applies the runtime's routing
/// and expiry checks to it.
pub fn localStatus(path: []const u8, now_seconds: i64) !LocalStatus {
    var record: credentials.Record = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    if (!try credentials.readSnapshotInto(path, &record)) return .missing;
    return policy.localStatus(&record, now_seconds);
}

pub fn acquireInto(io: std.Io, path: []const u8, fixture: bool, destination: *credentials.Lease) !void {
    var record: credentials.Record = undefined;
    try credentials.loadInto(path, &record);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    if (try policy.select(&record, fixture, nowSeconds(io)) == .refresh) {
        const Context = struct { io: std.Io, fixture: bool };
        _ = try credentials.exchangeRefresh(path, record.generation, Context{ .io = io, .fixture = fixture }, struct {
            fn exchange(context: Context, current: *const credentials.Record) !credentials.Record {
                try policy.validateSelected(current, context.fixture);
                var replacement: credentials.Record = undefined;
                defer std.crypto.secureZero(u8, std.mem.asBytes(&replacement));
                try refresh(context.io, current, &replacement);
                return replacement;
            }
        }.exchange);
    }
    try credentials.leaseInto(path, destination);
    errdefer destination.release();
    try policy.launchCheck(&destination.record, fixture, nowSeconds(io));
}

const Response = struct {
    bytes: [response_limit]u8 = undefined,
    len: usize = 0,
    overflow: bool = false,
};

fn writeCallback(data: [*c]u8, size: usize, count: usize, context: ?*anyopaque) callconv(.c) usize {
    const length = std.math.mul(usize, size, count) catch return 0;
    const response: *Response = @ptrCast(@alignCast(context orelse return 0));
    if (length > response.bytes.len - response.len) {
        response.overflow = true;
        return 0;
    }
    @memcpy(response.bytes[response.len..][0..length], data[0..length]);
    response.len += length;
    return length;
}

fn post(request: wire.Request, response: *Response, cancelled: ?*const fn () bool) !u16 {
    if (cancelled) |check| if (check()) return error.LoginInterrupted;
    const easy = c.curl_easy_init() orelse return error.TransportInitializationFailed;
    defer c.curl_easy_cleanup(easy);
    response.* = .{};
    var headers: ?*c.curl_slist = null;
    headers = c.curl_slist_append(headers, request.content_type) orelse return error.TransportInitializationFailed;
    defer c.curl_slist_free_all(headers);
    try opt(easy, c.CURLOPT_URL, request.url.ptr);
    try opt(easy, c.CURLOPT_POST, @as(c_long, 1));
    try opt(easy, c.CURLOPT_POSTFIELDS, request.body.ptr);
    try opt(easy, c.CURLOPT_POSTFIELDSIZE_LARGE, @as(c.curl_off_t, @intCast(request.body.len)));
    try opt(easy, c.CURLOPT_HTTPHEADER, headers);
    try opt(easy, c.CURLOPT_WRITEFUNCTION, writeCallback);
    try opt(easy, c.CURLOPT_WRITEDATA, response);
    try opt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
    try opt(easy, c.CURLOPT_MAXREDIRS, @as(c_long, 0));
    try opt(easy, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
    try opt(easy, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
    if (builtin.os.tag == .macos)
        try opt(easy, c.CURLOPT_SSL_OPTIONS, @as(c_long, c.CURLSSLOPT_NATIVE_CA));
    try opt(easy, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, 15_000));
    try opt(easy, c.CURLOPT_TIMEOUT_MS, @as(c_long, 60_000));
    try opt(easy, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
    if (cancelled != null) {
        try opt(easy, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
        try opt(easy, c.CURLOPT_XFERINFOFUNCTION, loginProgress);
        try opt(easy, c.CURLOPT_XFERINFODATA, &cancelled);
    }
    const result = c.curl_easy_perform(easy);
    if (cancelled) |check| if (check()) return error.LoginInterrupted;
    if (result != c.CURLE_OK) return if (response.overflow) error.ResponseTooLong else error.TransportFailed;
    var status: c_long = 0;
    if (c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &status) != c.CURLE_OK)
        return error.TransportFailed;
    return @intCast(status);
}

fn loginProgress(context: ?*anyopaque, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
    const cancelled: *const ?*const fn () bool = @ptrCast(@alignCast(context orelse return 1));
    return if (cancelled.*) |check| @intFromBool(check()) else 0;
}

test "device login cancellation rejects before a provider request" {
    const cancelled = struct {
        fn yes() bool {
            return true;
        }
    }.yes;
    try std.testing.expectError(error.LoginInterrupted, login(std.testing.io, struct {
        fn display(_: []const u8) !void {}
    }.display, cancelled));
    var callback: ?*const fn () bool = cancelled;
    try std.testing.expectEqual(@as(c_int, 1), loginProgress(@ptrCast(&callback), 0, 0, 0, 0));
}

fn opt(easy: *c.CURL, option: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(easy, option, value) != c.CURLE_OK) return error.TransportConfigurationFailed;
}

pub fn login(io: std.Io, callback: anytype, cancelled: *const fn () bool) !Tokens {
    var begin: Response = .{};
    defer std.crypto.secureZero(u8, std.mem.asBytes(&begin));
    const begin_status = try post(wire.device_start, &begin, cancelled);
    var device: wire.DeviceStart = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&device));
    try wire.parseDeviceStart(begin_status, begin.bytes[0..begin.len], &device);
    try callback(device.userCode());

    const started = std.Io.Clock.Timestamp.now(io, .boot);
    const deadline_ns = 15 * std.time.ns_per_min;
    while (true) {
        if (cancelled()) return error.LoginInterrupted;
        const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(io, .boot)).raw.nanoseconds;
        if (elapsed >= deadline_ns) return error.LoginExpired;
        var answer: Response = .{};
        defer std.crypto.secureZero(u8, std.mem.asBytes(&answer));
        const answer_status = try post(device.pollRequest(), &answer, cancelled);
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
        var form: [32 * 1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &form);
        const exchange = try wire.grantExchangeRequest(answer.bytes[0..answer.len], &form);
        var exchanged: Response = .{};
        defer std.crypto.secureZero(u8, std.mem.asBytes(&exchanged));
        const exchange_status = try post(exchange, &exchanged, cancelled);
        return wire.parseTokenResponse(exchange_status, exchanged.bytes[0..exchanged.len]);
    }
}

/// Exchanges the claimed record's refresh token and builds its replacement.
fn refresh(io: std.Io, current: *const credentials.Record, replacement: *credentials.Record) !void {
    var body: [32 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &body);
    var answer: Response = .{};
    defer std.crypto.secureZero(u8, std.mem.asBytes(&answer));
    const status = try post(try wire.refreshRequest(current, &body), &answer, null);
    try wire.parseRefreshResponse(current, status, answer.bytes[0..answer.len], nowSeconds(io), replacement);
}

test "local readiness reads a snapshot without creating a lock or mutating it" {
    // Status decisions are value-tested in codex_credential_policy.zig. This
    // proves the shell reads missing, ready and pending records without the
    // refresh lock and without changing the file.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(io, "private", .{ .permissions = .fromMode(0o700) });
    defer private.close(io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &root);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/private/auth", .{root[0..length]});
    try std.testing.expectEqual(LocalStatus.missing, try localStatus(path, 100));
    try std.testing.expectError(error.FileNotFound, private.openFile(io, ".auth.lock", .{}));
    var record: credentials.Record = .{
        .generation = 0,
        .account_id = .{},
        .id_token = .{},
        .access_token = .{},
        .refresh_token = .{},
        .expires_at = 4_102_444_800,
        .refreshed_at = 100,
    };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    try record.account_id.set(fixture_account_id);
    try record.id_token.set(fixture_id_token);
    try record.access_token.set(fixture_access_token);
    try record.refresh_token.set("synthetic-refresh");
    try credentials.install(path, &record, null);
    try private.deleteFile(io, ".auth.lock");
    var before_buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &before_buffer);
    const before = try private.readFile(io, "auth", &before_buffer);
    try std.testing.expectEqual(LocalStatus.renewal_due, try localStatus(path, 4_102_444_800));
    try std.testing.expectError(error.FileNotFound, private.openFile(io, ".auth.lock", .{}));
    var after_buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &after_buffer);
    try std.testing.expectEqualStrings(before, try private.readFile(io, "auth", &after_buffer));
    try std.testing.expectError(error.InjectedRefreshFailure, credentials.exchangeRefresh(path, 1, {}, struct {
        fn fail(_: void, _: *const credentials.Record) error{InjectedRefreshFailure}!credentials.Record {
            return error.InjectedRefreshFailure;
        }
    }.fail));
    try std.testing.expectEqual(LocalStatus.refresh_required, try localStatus(path, 100));
}
