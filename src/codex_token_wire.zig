//! Codex device-login and token-exchange messages as values.
//!
//! Builds request bodies and interprets response statuses and bodies for the
//! pinned device-code flow and refresh. `codex_auth.zig` owns curl, the clock
//! and the polling loop, and passes each response here. Credential record
//! decisions live in `codex_credential_policy.zig`.
const std = @import("std");
const policy = @import("codex_credential_policy.zig");

pub const issuer = "https://auth.openai.com";
pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const response_limit = 64 * 1024;
pub const token_limit = policy.max_token_bytes;
pub const account_limit = policy.max_account_id_bytes;
const Required = policy.Required;
const json_content = "Content-Type: application/json";
const form_content = "Content-Type: application/x-www-form-urlencoded";
const token_url = issuer ++ "/oauth/token";

/// One POST to the issuer. The body may borrow caller-owned secret bytes.
pub const Request = struct {
    url: [:0]const u8,
    content_type: [*:0]const u8,
    body: []const u8,
};

/// Owns all credential bytes. Callers must keep this value out of diagnostics.
pub const Tokens = struct {
    id_token: Required(token_limit) = .{},
    access_token: Required(token_limit) = .{},
    refresh_token: Required(token_limit) = .{},
    account_id: Required(account_limit) = .{},
};

pub const device_start: Request = .{
    .url = issuer ++ "/api/accounts/deviceauth/usercode",
    .content_type = json_content,
    .body = "{\"client_id\":\"" ++ client_id ++ "\"}",
};

pub const DeviceStart = struct {
    /// Complete JSON body for each token poll; it ends with the user code.
    poll: [1024]u8 = undefined,
    poll_len: usize = 0,
    user_code_len: usize = 0,
    interval_seconds: u16 = 0,

    pub fn userCode(self: *const DeviceStart) []const u8 {
        return self.poll[self.poll_len - "\"}".len - self.user_code_len ..][0..self.user_code_len];
    }

    pub fn pollRequest(self: *const DeviceStart) Request {
        return .{ .url = issuer ++ "/api/accounts/deviceauth/token", .content_type = json_content, .body = self.poll[0..self.poll_len] };
    }
};

/// Interprets the device-code start response. A code whose poll body cannot
/// be built is rejected before it can be shown.
pub fn parseDeviceStart(status: u16, body: []const u8, destination: *DeviceStart) !void {
    if (status == 404) return error.DeviceAuthenticationUnavailable;
    if (status < 200 or status >= 300) return error.LoginStartRejected;
    const Device = struct { device_auth_id: []const u8, user_code: ?[]const u8 = null, usercode: ?[]const u8 = null, interval: []const u8 };
    var arena: [32 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &arena);
    var fixed = std.heap.FixedBufferAllocator.init(&arena);
    const parsed = std.json.parseFromSlice(Device, fixed.allocator(), body, .{ .ignore_unknown_fields = true }) catch return error.InvalidDeviceResponse;
    const user_code = parsed.value.user_code orelse parsed.value.usercode orelse return error.InvalidDeviceResponse;
    if (!policy.safeAscii(parsed.value.device_auth_id) or !policy.safeAscii(user_code) or
        std.mem.indexOfAny(u8, parsed.value.device_auth_id, "\"\\") != null or
        std.mem.indexOfAny(u8, user_code, "\"\\") != null)
        return error.InvalidDeviceResponse;
    const interval = std.fmt.parseInt(u16, parsed.value.interval, 10) catch return error.InvalidDeviceResponse;
    if (interval == 0 or interval > 900) return error.InvalidDeviceResponse;
    destination.* = .{ .interval_seconds = interval, .user_code_len = user_code.len };
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(destination));
    destination.poll_len = (std.fmt.bufPrint(&destination.poll, "{{\"device_auth_id\":\"{s}\",\"user_code\":\"{s}\"}}", .{ parsed.value.device_auth_id, user_code }) catch
        return error.InvalidDeviceResponse).len;
}

pub const Poll = enum { pending, granted };

/// Interprets one token poll response; a granted body carries the grant.
pub fn classifyPoll(status: u16, body: []const u8) !Poll {
    if (status == 403 or status == 404) {
        // The pinned client treats these codes as pending, but a structured
        // terminal error from the peer must not be polled for fifteen minutes.
        var arena: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &arena);
        var fixed = std.heap.FixedBufferAllocator.init(&arena);
        const parsed = std.json.parseFromSlice(struct { @"error": ?[]const u8 = null }, fixed.allocator(), body, .{ .ignore_unknown_fields = true }) catch return .pending;
        const code = parsed.value.@"error" orelse return .pending;
        if (std.mem.eql(u8, code, "access_denied")) return error.LoginDenied;
        if (std.mem.eql(u8, code, "expired_token")) return error.LoginExpired;
        return error.LoginPollRejected;
    }
    if (status < 200 or status >= 300) return error.LoginPollRejected;
    return .granted;
}

/// Builds the authorization-code exchange from a device grant body.
pub fn grantExchangeRequest(grant_body: []const u8, buffer: []u8) !Request {
    const Grant = struct { authorization_code: []const u8, code_challenge: []const u8, code_verifier: []const u8 };
    var arena: [32 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &arena);
    var fixed = std.heap.FixedBufferAllocator.init(&arena);
    const grant = std.json.parseFromSlice(Grant, fixed.allocator(), grant_body, .{ .ignore_unknown_fields = true }) catch return error.InvalidDeviceGrant;
    return .{ .url = token_url, .content_type = form_content, .body = try formEncode(buffer, grant.value.authorization_code, grant.value.code_verifier) };
}

/// Parses a complete authorization-code exchange response.
pub fn parseTokenResponse(status: u16, json: []const u8) !Tokens {
    if (status < 200 or status >= 300) return error.TokenExchangeRejected;
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
    result.account_id = (try policy.parseAccount(result.id_token.slice())).id;
    _ = try policy.parseExpiry(result.access_token.slice());
    return result;
}

pub fn refreshRequest(current: *const policy.Record, buffer: []u8) !Request {
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll("{\"grant_type\":\"refresh_token\",\"client_id\":\"" ++ client_id ++ "\",\"refresh_token\":\"") catch return error.CredentialValueTooLong;
    writeJsonStringContent(&writer, current.refresh_token.slice()) catch return error.CredentialValueTooLong;
    writer.writeAll("\"}") catch return error.CredentialValueTooLong;
    return .{ .url = token_url, .content_type = json_content, .body = writer.buffered() };
}

/// Builds the replacement for a claimed record from a refresh response.
/// Omitted rotating fields are kept; routing and expiry follow the resulting
/// tokens. The generation is assigned at admission. On error the replacement
/// is zeroed.
pub fn parseRefreshResponse(current: *const policy.Record, status: u16, json: []const u8, refreshed_at: i64, replacement: *policy.Record) !void {
    if (status < 200 or status >= 300) return error.RefreshRejected;
    var wire: OwnedWire = .{};
    defer std.crypto.secureZero(u8, std.mem.asBytes(&wire));
    try parseWire(json, &wire);
    replacement.* = current.*;
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(replacement));
    if (wire.has_id) {
        const account = try policy.parseAccount(wire.id.slice());
        if (!std.mem.eql(u8, account.id.slice(), current.account_id.slice()) or
            account.fedramp != (try policy.parseAccount(current.id_token.slice())).fedramp)
            return error.AccountChanged;
        try replacement.id_token.set(wire.id.slice());
    }
    if (wire.has_access) try replacement.access_token.set(wire.access.slice());
    if (wire.has_refresh) try replacement.refresh_token.set(wire.refresh.slice());
    const expires_at = try policy.parseExpiry(replacement.access_token.slice());
    replacement.fedramp = (try policy.parseAccount(replacement.id_token.slice())).fedramp;
    replacement.expires_at = expires_at orelse 0;
    replacement.refreshed_at = refreshed_at;
    replacement.state = .ready;
}

const TokenWire = struct {
    id_token: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
};

const OwnedWire = struct {
    id: Required(token_limit) = .{},
    access: Required(token_limit) = .{},
    refresh: Required(token_limit) = .{},
    has_id: bool = false,
    has_access: bool = false,
    has_refresh: bool = false,
};

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

fn claimedRecord(id_token: []const u8, access_token: []const u8, record: *policy.Record) !void {
    record.* = .{ .generation = 3, .account_id = .{}, .id_token = .{}, .access_token = .{}, .refresh_token = .{}, .expires_at = 1, .refreshed_at = 1, .state = .refresh_pending };
    try record.id_token.set(id_token);
    record.account_id = .{};
    try record.account_id.set((try policy.parseAccount(id_token)).id.slice());
    record.fedramp = (try policy.parseAccount(id_token)).fedramp;
    try record.access_token.set(access_token);
    try record.refresh_token.set("refresh-old");
}

test "refresh preserves omitted fields and refuses account replacement" {
    const old_id = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0XzEifQ.c2ln";
    const old_access = "e30.eyJleHAiOjQxMDI0NDQ4MDB9.c2ln";
    var current: policy.Record = undefined;
    try claimedRecord(old_id, old_access, &current);
    var updated: policy.Record = undefined;
    try parseRefreshResponse(&current, 200, "{\"refresh_token\":\"refresh-new\"}", 77, &updated);
    try std.testing.expectEqualStrings(old_access, updated.access_token.slice());
    try std.testing.expectEqualStrings("refresh-new", updated.refresh_token.slice());
    try std.testing.expectEqualStrings(old_id, updated.id_token.slice());
    try std.testing.expectEqual(@as(i64, 4_102_444_800), updated.expires_at);
    // The replacement is ready, stamped and keeps the claimed generation.
    try std.testing.expectEqual(policy.State.ready, updated.state);
    try std.testing.expectEqual(@as(i64, 77), updated.refreshed_at);
    try std.testing.expectEqual(@as(u64, 3), updated.generation);
    // Rotated tokens for the same account replace the old ones.
    const same_account = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0XzEiLCJzdWIiOiJ4In0.c2ln";
    var json: [512]u8 = undefined;
    try parseRefreshResponse(&current, 200, try std.fmt.bufPrint(&json, "{{\"id_token\":\"{s}\",\"access_token\":\"opaque-new\"}}", .{same_account}), 78, &updated);
    try std.testing.expectEqualStrings(same_account, updated.id_token.slice());
    try std.testing.expectEqualStrings("opaque-new", updated.access_token.slice());
    try std.testing.expectEqualStrings("refresh-old", updated.refresh_token.slice());
    try std.testing.expectEqual(@as(i64, 0), updated.expires_at);
    // A foreign account or rejected status leaves no partial replacement.
    const foreign = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0XzIifQ.c2ln";
    const response = try std.fmt.bufPrint(&json, "{{\"id_token\":\"{s}\",\"refresh_token\":\"refresh-new\"}}", .{foreign});
    try std.testing.expectError(error.AccountChanged, parseRefreshResponse(&current, 200, response, 79, &updated));
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&updated), 0));
    for ([_]u16{ 199, 300, 401, 500 }) |status| {
        try std.testing.expectError(error.RefreshRejected, parseRefreshResponse(&current, status, "{}", 79, &updated));
    }
}

test "refresh keeps the account's routing claim in both directions" {
    var current: policy.Record = undefined;
    var updated: policy.Record = undefined;
    var json: [512]u8 = undefined;
    for ([_][2][]const u8{
        .{ policy.fixture_id_token, policy.fixture_fedramp_id_token },
        .{ policy.fixture_fedramp_id_token, policy.fixture_id_token },
    }) |case| {
        try claimedRecord(case[0], "opaque-access", &current);
        const response = try std.fmt.bufPrint(&json, "{{\"id_token\":\"{s}\"}}", .{case[1]});
        try std.testing.expectError(error.AccountChanged, parseRefreshResponse(&current, 200, response, 77, &updated));
    }
    // An unchanged routing claim is carried into the replacement.
    try parseRefreshResponse(&current, 200, "{\"access_token\":\"opaque-new\"}", 77, &updated);
    try std.testing.expect(updated.fedramp);
    // Routing is read from the resulting ID token, not copied from the record.
    current.fedramp = false;
    try parseRefreshResponse(&current, 200, "{}", 77, &updated);
    try std.testing.expect(updated.fedramp);
}

test "refresh request escapes the refresh token as JSON" {
    var record: policy.Record = undefined;
    try claimedRecord(policy.fixture_id_token, "opaque-access", &record);
    try record.refresh_token.set("a\"b\\c");
    var buffer: [256]u8 = undefined;
    const request = try refreshRequest(&record, &buffer);
    try std.testing.expectEqualStrings(issuer ++ "/oauth/token", request.url);
    try std.testing.expectEqualStrings(json_content, std.mem.span(request.content_type));
    try std.testing.expectEqualStrings(
        "{\"grant_type\":\"refresh_token\",\"client_id\":\"" ++ client_id ++ "\",\"refresh_token\":\"a\\\"b\\\\c\"}",
        request.body,
    );
    var small: [8]u8 = undefined;
    try std.testing.expectError(error.CredentialValueTooLong, refreshRequest(&record, &small));
}

test "authorization exchange requires and owns all token fields" {
    const id = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0XzEifQ.c2ln";
    const access = "e30.eyJleHAiOjQxMDI0NDQ4MDB9.c2ln";
    var json: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(&json, "{{\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"refresh_token\":\"refresh\"}}", .{ id, access });
    const tokens = try parseTokenResponse(200, response);
    try std.testing.expectEqualStrings("acct_1", tokens.account_id.slice());
    try std.testing.expectError(error.TokenExchangeRejected, parseTokenResponse(400, response));
    try std.testing.expectError(error.MissingRefreshToken, parseTokenResponse(200, "{\"id_token\":\"x\",\"access_token\":\"y\"}"));
    const opaque_response = try std.fmt.bufPrint(&json, "{{\"id_token\":\"{s}\",\"access_token\":\"opaque-access\",\"refresh_token\":\"refresh\"}}", .{id});
    try std.testing.expectEqualStrings("opaque-access", (try parseTokenResponse(200, opaque_response)).access_token.slice());
    try std.testing.expectError(error.InvalidTokenResponse, parseTokenResponse(200, "not json"));
}

test "device start validates codes and builds the poll body" {
    var start: DeviceStart = undefined;
    try parseDeviceStart(200, "{\"device_auth_id\":\"dev-1\",\"usercode\":\"ABCD-EFGH\",\"interval\":\"5\"}", &start);
    try std.testing.expectEqualStrings("ABCD-EFGH", start.userCode());
    try std.testing.expectEqual(@as(u16, 5), start.interval_seconds);
    const poll = start.pollRequest();
    try std.testing.expectEqualStrings(issuer ++ "/api/accounts/deviceauth/token", poll.url);
    try std.testing.expectEqualStrings(json_content, std.mem.span(poll.content_type));
    try std.testing.expectEqualStrings("{\"device_auth_id\":\"dev-1\",\"user_code\":\"ABCD-EFGH\"}", poll.body);
    try std.testing.expectEqualStrings("{\"client_id\":\"" ++ client_id ++ "\"}", device_start.body);
    try std.testing.expectError(error.DeviceAuthenticationUnavailable, parseDeviceStart(404, "", &start));
    try std.testing.expectError(error.LoginStartRejected, parseDeviceStart(500, "", &start));
    for ([_][]const u8{
        "{\"device_auth_id\":\"dev-1\",\"interval\":\"5\"}",
        "{\"device_auth_id\":\"dev\\\"1\",\"user_code\":\"A\",\"interval\":\"5\"}",
        "{\"device_auth_id\":\"dev-1\",\"user_code\":\"A\",\"interval\":\"0\"}",
        "{\"device_auth_id\":\"dev-1\",\"user_code\":\"A\",\"interval\":\"901\"}",
        "{\"device_auth_id\":\"dev 1\",\"user_code\":\"A\",\"interval\":\"5\"}",
    }) |body| try std.testing.expectError(error.InvalidDeviceResponse, parseDeviceStart(200, body, &start));
    // A code whose poll body cannot be built is rejected before it can be shown.
    var device_id: [600]u8 = undefined;
    @memset(&device_id, 'd');
    var code: [400]u8 = undefined;
    @memset(&code, 'U');
    var long: [2048]u8 = undefined;
    const overlong = try std.fmt.bufPrint(&long, "{{\"device_auth_id\":\"{s}\",\"user_code\":\"{s}\",\"interval\":\"5\"}}", .{ &device_id, &code });
    try std.testing.expectError(error.InvalidDeviceResponse, parseDeviceStart(200, overlong, &start));
    const fits = try std.fmt.bufPrint(&long, "{{\"device_auth_id\":\"{s}\",\"user_code\":\"{s}\",\"interval\":\"5\"}}", .{ device_id[0..500], &code });
    try parseDeviceStart(200, fits, &start);
    try std.testing.expectEqualSlices(u8, &code, start.userCode());
}

test "device polling recognizes structured denial and expiration without retrying" {
    try std.testing.expectEqual(Poll.pending, try classifyPoll(403, ""));
    try std.testing.expectEqual(Poll.pending, try classifyPoll(404, "{}"));
    try std.testing.expectEqual(Poll.pending, try classifyPoll(403, "not json"));
    try std.testing.expectError(error.LoginDenied, classifyPoll(403, "{\"error\":\"access_denied\"}"));
    try std.testing.expectError(error.LoginExpired, classifyPoll(404, "{\"error\":\"expired_token\"}"));
    try std.testing.expectError(error.LoginPollRejected, classifyPoll(403, "{\"error\":\"unsupported\"}"));
    try std.testing.expectError(error.LoginPollRejected, classifyPoll(429, ""));
    try std.testing.expectEqual(Poll.granted, try classifyPoll(200, "{}"));
}

test "authorization exchange percent-encodes code and verifier independently" {
    var buffer: [512]u8 = undefined;
    const request = try grantExchangeRequest("{\"authorization_code\":\"a+b &\",\"code_challenge\":\"x\",\"code_verifier\":\"v/=+\"}", &buffer);
    try std.testing.expectEqualStrings(issuer ++ "/oauth/token", request.url);
    try std.testing.expectEqualStrings(form_content, std.mem.span(request.content_type));
    try std.testing.expectEqualStrings(
        "grant_type=authorization_code&client_id=" ++ client_id ++
            "&code=a%2Bb%20%26&redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback&code_verifier=v%2F%3D%2B",
        request.body,
    );
    try std.testing.expectError(error.InvalidDeviceGrant, grantExchangeRequest("{}", &buffer));
}

fn raises(comptime function: anytype, comptime name: []const u8) bool {
    const Error = @typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.error_set;
    for (@typeInfo(Error).error_set.error_names.?) |member| {
        if (std.mem.eql(u8, member, name)) return true;
    }
    return false;
}

test "authentication failure classes name errors their producers raise" {
    // `policy.failureCode` classifies by name; a renamed producer error would
    // silently become a backend failure.
    inline for (.{
        .{ parseRefreshResponse, "RefreshRejected" },
        .{ parseRefreshResponse, "AccountChanged" },
        .{ policy.select, "RefreshRequiresLogin" },
        .{ policy.select, "AccountMismatch" },
        .{ policy.select, "InvalidCredentialExpiry" },
        .{ policy.launchCheck, "ExpiredCredential" },
    }) |case| {
        try std.testing.expect(comptime raises(case[0], case[1]));
        try std.testing.expectEqualStrings("provider_authentication_failed", policy.failureCode(@field(anyerror, case[1])));
    }
}
