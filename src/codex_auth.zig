const std = @import("std");
const builtin = @import("builtin");
const credentials = @import("codex_credentials.zig");

const c = @cImport({
    @cInclude("curl/curl.h");
});

pub const issuer = "https://auth.openai.com";
pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const redirect_uri = "https://auth.openai.com/deviceauth/callback";
pub const upstream_pin = "968835997714baaff199cfed5f89a2c65d8ca77d";
// The fixture token cannot originate from Rui login. Only the explicit
// test-only managed endpoint may receive this exact canary.
pub const fixture_access_token = "e30.eyJleHAiOjQxMDI0NDQ4MDB9.c2ln";
pub const fixture_id_token = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJydWktdGVzdC1hY2NvdW50In0.c2ln";
pub const fixture_fedramp_id_token = "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoicnVpLXRlc3QtYWNjb3VudCIsImNoYXRncHRfYWNjb3VudF9pc19mZWRyYW1wIjp0cnVlfX0.c2ln";
pub const fixture_account_id = "rui-test-account";
pub const response_limit = 64 * 1024;
pub const token_limit = credentials.max_token_bytes;
pub const account_limit = credentials.max_account_id_bytes;

pub fn isFixtureId(id_token: []const u8) bool {
    return std.mem.eql(u8, id_token, fixture_id_token) or
        std.mem.eql(u8, id_token, fixture_fedramp_id_token);
}

fn Bounded(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn set(self: *@This(), value: []const u8) !void {
            if (value.len == 0) return error.EmptyCredentialValue;
            if (value.len > capacity) return error.CredentialValueTooLong;
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
        }
    };
}

/// Owns all credential bytes. Callers must keep this value out of diagnostics.
pub const Tokens = struct {
    id_token: Bounded(token_limit) = .{},
    access_token: Bounded(token_limit) = .{},
    refresh_token: Bounded(token_limit) = .{},
    account_id: Bounded(account_limit) = .{},
};

pub fn failureCode(err: anyerror) []const u8 {
    return switch (err) {
        error.RefreshRejected, error.RefreshRequiresLogin, error.ExpiredCredential, error.AccountMismatch, error.AccountChanged, error.InvalidCredentialExpiry => "provider_authentication_failed",
        else => "provider_authentication_backend_failed",
    };
}

fn shouldRefresh(record: *const credentials.Record, now: i64) bool {
    if (record.expires_at != 0) return record.expires_at <= now + 60;
    return now -| record.refreshed_at >= 8 * 24 * 60 * 60;
}

fn validateSelected(record: *const credentials.Record, fixture: bool) !void {
    if (fixture and
        (!std.mem.eql(u8, record.access_token.slice(), fixture_access_token) or
            !isFixtureId(record.id_token.slice()) or
            !std.mem.eql(u8, record.account_id.slice(), fixture_account_id)))
        return error.FixtureRequiresSyntheticCredential;
    const account = try parseAccount(record.id_token.slice());
    if (!std.mem.eql(u8, account.id.slice(), record.account_id.slice()) or
        account.fedramp != record.fedramp) return error.AccountMismatch;
    if (((try parseExpiry(record.access_token.slice())) orelse 0) != record.expires_at)
        return error.InvalidCredentialExpiry;
}

pub fn acquireInto(io: std.Io, path: []const u8, fixture: bool, destination: *credentials.Lease) !void {
    var record: credentials.Record = undefined;
    try credentials.loadInto(path, &record);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    if (record.state != .ready) return error.RefreshRequiresLogin;
    try validateSelected(&record, fixture);
    const now: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_s));
    if (shouldRefresh(&record, now)) {
        const Context = struct { io: std.Io, fixture: bool };
        _ = try credentials.exchangeRefresh(path, record.generation, Context{ .io = io, .fixture = fixture }, struct {
            fn exchange(context: Context, current: *const credentials.Record) !credentials.Record {
                try validateSelected(current, context.fixture);
                var tokens: Tokens = .{};
                defer std.crypto.secureZero(u8, std.mem.asBytes(&tokens));
                try tokens.id_token.set(current.id_token.slice());
                try tokens.access_token.set(current.access_token.slice());
                try tokens.refresh_token.set(current.refresh_token.slice());
                try tokens.account_id.set(current.account_id.slice());
                var refreshed = try refresh(&tokens);
                defer std.crypto.secureZero(u8, std.mem.asBytes(&refreshed));
                var replacement = current.*;
                defer std.crypto.secureZero(u8, std.mem.asBytes(&replacement));
                try replacement.id_token.set(refreshed.id_token.slice());
                try replacement.access_token.set(refreshed.access_token.slice());
                try replacement.refresh_token.set(refreshed.refresh_token.slice());
                replacement.fedramp = (try parseAccount(refreshed.id_token.slice())).fedramp;
                replacement.expires_at = (try parseExpiry(refreshed.access_token.slice())) orelse 0;
                replacement.refreshed_at = @intCast(@divFloor(std.Io.Clock.Timestamp.now(context.io, .real).raw.nanoseconds, std.time.ns_per_s));
                replacement.state = .ready;
                return replacement;
            }
        }.exchange);
    }
    try credentials.leaseInto(path, destination);
    errdefer destination.release();
    try validateSelected(&destination.record, fixture);
    const launch_now: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_s));
    if (destination.record.expires_at != 0 and destination.record.expires_at <= launch_now)
        return error.ExpiredCredential;
}

const TokenWire = struct {
    id_token: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
};

const Claims = struct {
    @"https://api.openai.com/auth": ?struct {
        chatgpt_account_id: ?[]const u8 = null,
        chatgpt_account_is_fedramp: ?bool = null,
    } = null,
    chatgpt_account_id: ?[]const u8 = null,
};

fn safeAscii(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

fn validBase64Url(bytes: []const u8) bool {
    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(bytes) catch return false;
    if (size > token_limit) return false;
    var decoded: [token_limit]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(decoded[0..size], bytes) catch return false;
    return true;
}

fn tokenPayload(token: []const u8, destination: []u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    const header = parts.next() orelse return error.InvalidCompactToken;
    const payload = parts.next() orelse return error.InvalidCompactToken;
    const signature = parts.next() orelse return error.InvalidCompactToken;
    if (parts.next() != null or
        !safeAscii(header) or !validBase64Url(header) or
        !safeAscii(payload) or !validBase64Url(payload) or
        !safeAscii(signature) or !validBase64Url(signature))
        return error.InvalidCompactToken;

    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch
        return error.InvalidTokenPayload;
    if (size > destination.len) return error.TokenPayloadTooLong;
    std.base64.url_safe_no_pad.Decoder.decode(destination[0..size], payload) catch
        return error.InvalidTokenPayload;
    return destination[0..size];
}

pub const Account = struct { id: Bounded(account_limit), fedramp: bool };

/// Decoded routing claims from the TLS peer's ID token, not a verified JWT.
pub fn parseAccount(id_token: []const u8) !Account {
    var decoded: [token_limit]u8 = undefined;
    defer std.crypto.secureZero(u8, &decoded);
    const payload = try tokenPayload(id_token, &decoded);

    var arena_bytes: [16 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &arena_bytes);
    var fixed = std.heap.FixedBufferAllocator.init(&arena_bytes);
    const parsed = std.json.parseFromSlice(Claims, fixed.allocator(), payload, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidTokenClaims;
    const claim = if (parsed.value.@"https://api.openai.com/auth") |namespace|
        namespace.chatgpt_account_id orelse parsed.value.chatgpt_account_id
    else
        parsed.value.chatgpt_account_id;
    const account = claim orelse return error.MissingAccountClaim;
    if (!safeAscii(account)) return error.InvalidAccountClaim;
    var result: Account = .{ .id = .{}, .fedramp = if (parsed.value.@"https://api.openai.com/auth") |namespace|
        namespace.chatgpt_account_is_fedramp orelse false
    else
        false };
    try result.id.set(account);
    return result;
}

/// A compact access token may carry an expiry. The issuer also returns opaque
/// access tokens; their lifetime is tracked from the last successful exchange.
pub fn parseExpiry(access_token: []const u8) !?i64 {
    if (!safeAscii(access_token)) return error.InvalidAccessToken;
    if (std.mem.indexOfScalar(u8, access_token, '.') == null) return null;
    var decoded: [token_limit]u8 = undefined;
    defer std.crypto.secureZero(u8, &decoded);
    const payload = try tokenPayload(access_token, &decoded);
    var arena_bytes: [16 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &arena_bytes);
    var fixed = std.heap.FixedBufferAllocator.init(&arena_bytes);
    const parsed = std.json.parseFromSlice(struct { exp: ?i64 = null }, fixed.allocator(), payload, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidTokenClaims;
    if (parsed.value.exp) |expiry| if (expiry <= 0) return error.InvalidTokenClaims;
    return parsed.value.exp;
}

/// Parses a complete authorization-code exchange response.
pub fn parseTokenResponse(json: []const u8) !Tokens {
    var wire: OwnedWire = .{};
    defer std.crypto.secureZero(u8, std.mem.asBytes(&wire));
    try parseWire(json, &wire);
    var result: Tokens = .{};
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(&result));
    if (!wire.has_id) return error.MissingIdToken;
    if (!wire.has_access) return error.MissingAccessToken;
    if (!wire.has_refresh) return error.MissingRefreshToken;
    result.id_token = wire.id;
    result.access_token = wire.access;
    result.refresh_token = wire.refresh;
    result.account_id = (try parseAccount(result.id_token.slice())).id;
    _ = try parseExpiry(result.access_token.slice());
    return result;
}

/// Applies a refresh response without erasing omitted rotating fields.
pub fn parseRefreshResponse(current: *const Tokens, json: []const u8) !Tokens {
    var wire: OwnedWire = .{};
    defer std.crypto.secureZero(u8, std.mem.asBytes(&wire));
    try parseWire(json, &wire);
    var result = current.*;
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(&result));
    if (wire.has_id) {
        const account = try parseAccount(wire.id.slice());
        if (!std.mem.eql(u8, account.id.slice(), current.account_id.slice())) return error.AccountChanged;
        result.id_token = wire.id;
    }
    if (wire.has_access) result.access_token = wire.access;
    if (wire.has_refresh) result.refresh_token = wire.refresh;
    _ = try parseExpiry(result.access_token.slice());
    return result;
}

fn parseWire(json: []const u8, result: *OwnedWire) !void {
    if (json.len > response_limit) return error.ResponseTooLong;
    var arena_bytes: [48 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &arena_bytes);
    var fixed = std.heap.FixedBufferAllocator.init(&arena_bytes);
    const parsed = std.json.parseFromSlice(TokenWire, fixed.allocator(), json, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidTokenResponse;
    result.* = .{};
    if (parsed.value.id_token) |value| {
        try result.id.set(value);
        result.has_id = true;
    }
    if (parsed.value.access_token) |value| {
        try result.access.set(value);
        result.has_access = true;
    }
    if (parsed.value.refresh_token) |value| {
        try result.refresh.set(value);
        result.has_refresh = true;
    }
}

const OwnedWire = struct {
    id: Bounded(token_limit) = .{},
    access: Bounded(token_limit) = .{},
    refresh: Bounded(token_limit) = .{},
    has_id: bool = false,
    has_access: bool = false,
    has_refresh: bool = false,
};

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

fn post(url: [:0]const u8, content_type: [*:0]const u8, body: []const u8, response: *Response) !u16 {
    const easy = c.curl_easy_init() orelse return error.TransportInitializationFailed;
    defer c.curl_easy_cleanup(easy);
    response.* = .{};
    var headers: ?*c.curl_slist = null;
    headers = c.curl_slist_append(headers, content_type) orelse return error.TransportInitializationFailed;
    defer c.curl_slist_free_all(headers);
    try opt(easy, c.CURLOPT_URL, url.ptr);
    try opt(easy, c.CURLOPT_POST, @as(c_long, 1));
    try opt(easy, c.CURLOPT_POSTFIELDS, body.ptr);
    try opt(easy, c.CURLOPT_POSTFIELDSIZE_LARGE, @as(c.curl_off_t, @intCast(body.len)));
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
    if (c.curl_easy_perform(easy) != c.CURLE_OK)
        return if (response.overflow) error.ResponseTooLong else error.TransportFailed;
    var status: c_long = 0;
    if (c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &status) != c.CURLE_OK)
        return error.TransportFailed;
    return @intCast(status);
}

fn opt(easy: *c.CURL, option: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(easy, option, value) != c.CURLE_OK) return error.TransportConfigurationFailed;
}

pub fn login(io: std.Io, callback: anytype) !Tokens {
    var begin: Response = .{};
    defer std.crypto.secureZero(u8, std.mem.asBytes(&begin));
    const begin_status = try post(issuer ++ "/api/accounts/deviceauth/usercode", "Content-Type: application/json", "{\"client_id\":\"" ++ client_id ++ "\"}", &begin);
    if (begin_status == 404) return error.DeviceAuthenticationUnavailable;
    if (begin_status < 200 or begin_status >= 300) return error.LoginStartRejected;
    const Device = struct { device_auth_id: []const u8, user_code: ?[]const u8 = null, usercode: ?[]const u8 = null, interval: []const u8 };
    var arena: [32 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &arena);
    var fixed = std.heap.FixedBufferAllocator.init(&arena);
    const parsed = std.json.parseFromSlice(Device, fixed.allocator(), begin.bytes[0..begin.len], .{ .ignore_unknown_fields = true }) catch return error.InvalidDeviceResponse;
    const user_code = parsed.value.user_code orelse parsed.value.usercode orelse return error.InvalidDeviceResponse;
    if (!safeAscii(parsed.value.device_auth_id) or !safeAscii(user_code) or
        std.mem.indexOfAny(u8, parsed.value.device_auth_id, "\"\\") != null or
        std.mem.indexOfAny(u8, user_code, "\"\\") != null)
        return error.InvalidDeviceResponse;
    const interval = std.fmt.parseInt(u16, parsed.value.interval, 10) catch return error.InvalidDeviceResponse;
    if (interval == 0 or interval > 900) return error.InvalidDeviceResponse;
    try callback(user_code);

    const started = std.Io.Clock.Timestamp.now(io, .boot);
    var poll_body: [1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &poll_body);
    const poll = std.fmt.bufPrint(&poll_body, "{{\"device_auth_id\":\"{s}\",\"user_code\":\"{s}\"}}", .{ parsed.value.device_auth_id, user_code }) catch return error.InvalidDeviceResponse;
    const deadline_ns = 15 * std.time.ns_per_min;
    while (true) {
        const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(io, .boot)).raw.nanoseconds;
        if (elapsed >= deadline_ns) return error.LoginExpired;
        var answer: Response = .{};
        defer std.crypto.secureZero(u8, std.mem.asBytes(&answer));
        const answer_status = try post(issuer ++ "/api/accounts/deviceauth/token", "Content-Type: application/json", poll, &answer);
        if (try pollingPending(answer_status, answer.bytes[0..answer.len])) {
            const remaining = deadline_ns - started.durationTo(std.Io.Clock.Timestamp.now(io, .boot)).raw.nanoseconds;
            if (remaining <= 0) return error.LoginExpired;
            try io.sleep(.fromNanoseconds(@min(@as(i96, interval) * std.time.ns_per_s, remaining)), .awake);
            continue;
        }
        const Grant = struct { authorization_code: []const u8, code_challenge: []const u8, code_verifier: []const u8 };
        var grant_arena: [32 * 1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &grant_arena);
        var grant_fixed = std.heap.FixedBufferAllocator.init(&grant_arena);
        const grant = std.json.parseFromSlice(Grant, grant_fixed.allocator(), answer.bytes[0..answer.len], .{ .ignore_unknown_fields = true }) catch return error.InvalidDeviceGrant;
        _ = grant.value.code_challenge;
        var form: [32 * 1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &form);
        const body = try formEncode(&form, grant.value.authorization_code, grant.value.code_verifier);
        var exchanged: Response = .{};
        defer std.crypto.secureZero(u8, std.mem.asBytes(&exchanged));
        const exchange_status = try post(issuer ++ "/oauth/token", "Content-Type: application/x-www-form-urlencoded", body, &exchanged);
        if (exchange_status < 200 or exchange_status >= 300) return error.TokenExchangeRejected;
        return parseTokenResponse(exchanged.bytes[0..exchanged.len]);
    }
}

fn pollingPending(status: u16, body: []const u8) !bool {
    if (status == 403 or status == 404) {
        // The pinned client treats these codes as pending, but a structured
        // terminal error from the peer must not be polled for fifteen minutes.
        var arena: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &arena);
        var fixed = std.heap.FixedBufferAllocator.init(&arena);
        const parsed = std.json.parseFromSlice(struct { @"error": ?[]const u8 = null }, fixed.allocator(), body, .{ .ignore_unknown_fields = true }) catch return true;
        const code = parsed.value.@"error" orelse return true;
        if (std.mem.eql(u8, code, "access_denied")) return error.LoginDenied;
        if (std.mem.eql(u8, code, "expired_token")) return error.LoginExpired;
        return error.LoginPollRejected;
    }
    if (status < 200 or status >= 300) return error.LoginPollRejected;
    return false;
}

pub fn refresh(current: *const Tokens) !Tokens {
    var body: [32 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &body);
    var writer = std.Io.Writer.fixed(&body);
    writer.writeAll("{\"grant_type\":\"refresh_token\",\"client_id\":\"" ++ client_id ++ "\",\"refresh_token\":\"") catch return error.CredentialValueTooLong;
    writeJsonStringContent(&writer, current.refresh_token.slice()) catch return error.CredentialValueTooLong;
    writer.writeAll("\"}") catch return error.CredentialValueTooLong;
    const json = writer.buffered();
    var answer: Response = .{};
    defer std.crypto.secureZero(u8, std.mem.asBytes(&answer));
    const status = try post(issuer ++ "/oauth/token", "Content-Type: application/json", json, &answer);
    if (status < 200 or status >= 300) return error.RefreshRejected;
    return parseRefreshResponse(current, answer.bytes[0..answer.len]);
}

fn formEncode(buffer: []u8, code: []const u8, verifier: []const u8) ![]const u8 {
    var stream = std.Io.Writer.fixed(buffer);
    try stream.writeAll("grant_type=authorization_code&client_id=" ++ client_id ++ "&code=");
    try percentEncode(&stream, code);
    try stream.writeAll("&redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback&code_verifier=");
    try percentEncode(&stream, verifier);
    return stream.buffered();
}

fn percentEncode(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try writer.writeByte(byte),
        else => try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 15] }),
    };
}

fn writeJsonStringContent(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789abcdef";
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        0...0x1f => try writer.writeAll(&.{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 15] }),
        else => try writer.writeByte(byte),
    };
}

test "extracts both pinned account claim spellings and rejects malformed compact tokens" {
    const nested = "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdF8xIn19.c2ln";
    const top = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0XzIifQ.c2ln";
    const federal = "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdF8xIiwiY2hhdGdwdF9hY2NvdW50X2lzX2ZlZHJhbXAiOnRydWV9fQ.c2ln";
    try std.testing.expectEqualStrings("acct_1", (try parseAccount(nested)).id.slice());
    try std.testing.expectEqualStrings("acct_2", (try parseAccount(top)).id.slice());
    try std.testing.expect(!(try parseAccount(nested)).fedramp);
    try std.testing.expect((try parseAccount(federal)).fedramp);
    try std.testing.expectError(error.InvalidCompactToken, parseAccount("a..c"));
}

test "refresh preserves omitted fields and refuses account replacement" {
    const old_id = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0XzEifQ.c2ln";
    const old_access = "e30.eyJleHAiOjQxMDI0NDQ4MDB9.c2ln";
    var current: Tokens = .{};
    try current.id_token.set(old_id);
    try current.access_token.set(old_access);
    try current.refresh_token.set("refresh-old");
    current.account_id = (try parseAccount(old_id)).id;
    const updated = try parseRefreshResponse(&current, "{\"refresh_token\":\"refresh-new\"}");
    try std.testing.expectEqualStrings(old_access, updated.access_token.slice());
    try std.testing.expectEqualStrings("refresh-new", updated.refresh_token.slice());
    const foreign = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0XzIifQ.c2ln";
    var json: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(&json, "{{\"id_token\":\"{s}\"}}", .{foreign});
    try std.testing.expectError(error.AccountChanged, parseRefreshResponse(&current, response));
}

test "authorization exchange requires and owns all token fields" {
    const id = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0XzEifQ.c2ln";
    const access = "e30.eyJleHAiOjQxMDI0NDQ4MDB9.c2ln";
    var json: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(&json, "{{\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"refresh_token\":\"refresh\"}}", .{ id, access });
    const tokens = try parseTokenResponse(response);
    try std.testing.expectEqualStrings("acct_1", tokens.account_id.slice());
    try std.testing.expectError(error.MissingRefreshToken, parseTokenResponse("{\"id_token\":\"x\",\"access_token\":\"y\"}"));
    const opaque_response = try std.fmt.bufPrint(&json, "{{\"id_token\":\"{s}\",\"access_token\":\"opaque-access\",\"refresh_token\":\"refresh\"}}", .{id});
    try std.testing.expectEqualStrings("opaque-access", (try parseTokenResponse(opaque_response)).access_token.slice());
    try std.testing.expect((try parseExpiry("opaque-access")) == null);
    try std.testing.expectError(error.InvalidCompactToken, parseExpiry("a..c"));
}

test "device polling recognizes structured denial and expiration without retrying" {
    try std.testing.expect(try pollingPending(403, ""));
    try std.testing.expect(try pollingPending(404, "{}"));
    try std.testing.expectError(error.LoginDenied, pollingPending(403, "{\"error\":\"access_denied\"}"));
    try std.testing.expectError(error.LoginExpired, pollingPending(404, "{\"error\":\"expired_token\"}"));
    try std.testing.expectError(error.LoginPollRejected, pollingPending(403, "{\"error\":\"unsupported\"}"));
    try std.testing.expectError(error.LoginPollRejected, pollingPending(429, ""));
    try std.testing.expect(!(try pollingPending(200, "{}")));
}

test "authorization exchange percent-encodes code and verifier independently" {
    var buffer: [512]u8 = undefined;
    const body = try formEncode(&buffer, "a+b &", "v/=+");
    try std.testing.expectEqualStrings(
        "grant_type=authorization_code&client_id=" ++ client_id ++
            "&code=a%2Bb%20%26&redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback&code_verifier=v%2F%3D%2B",
        body,
    );
}

test "credential refresh uses token expiry or the last successful opaque exchange" {
    var record: credentials.Record = undefined;
    record.expires_at = 1_000;
    record.refreshed_at = 100;
    try std.testing.expect(!shouldRefresh(&record, 939));
    try std.testing.expect(shouldRefresh(&record, 940));
    record.expires_at = 0;
    try std.testing.expect(!shouldRefresh(&record, 100 + 8 * 24 * 60 * 60 - 1));
    try std.testing.expect(shouldRefresh(&record, 100 + 8 * 24 * 60 * 60));
}
