//! Codex device-login and token-exchange messages as values.
//!
//! Builds request bodies and interprets response statuses and bodies for the
//! pinned device-code flow and refresh. `codex_auth.zig` owns curl, the clock
//! and the polling loop, and passes each response here. Credential record
//! decisions live in `codex_credential_policy.zig`.
const std = @import("std");
const policy = @import("codex_credential_policy.zig");

pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const response_limit = 64 * 1024;
pub const token_limit = policy.max_token_bytes;
pub const account_limit = policy.max_account_id_bytes;
const Required = policy.Required;

/// Owns all credential bytes. Callers must keep this value out of diagnostics.
pub const Tokens = struct {
    id_token: Required(token_limit) = .{},
    access_token: Required(token_limit) = .{},
    refresh_token: Required(token_limit) = .{},
    account_id: Required(account_limit) = .{},
};

/// The token values a refresh exchange presents for an installed record.
pub fn tokensFromRecord(record: *const policy.Record, destination: *Tokens) !void {
    destination.* = .{};
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(destination));
    try destination.id_token.set(record.id_token.slice());
    try destination.access_token.set(record.access_token.slice());
    try destination.refresh_token.set(record.refresh_token.slice());
    try destination.account_id.set(record.account_id.slice());
}

/// Writes refreshed tokens into a copy of the claimed record. Routing and
/// expiry come from the new tokens; the generation is assigned at admission.
pub fn applyRefresh(replacement: *policy.Record, refreshed: *const Tokens, refreshed_at: i64) !void {
    try replacement.id_token.set(refreshed.id_token.slice());
    try replacement.access_token.set(refreshed.access_token.slice());
    try replacement.refresh_token.set(refreshed.refresh_token.slice());
    replacement.fedramp = (try policy.parseAccount(refreshed.id_token.slice())).fedramp;
    replacement.expires_at = (try policy.parseExpiry(refreshed.access_token.slice())) orelse 0;
    replacement.refreshed_at = refreshed_at;
    replacement.state = .ready;
}

const max_device_value_bytes = 1024;

pub const DeviceStart = struct {
    user_code: [max_device_value_bytes]u8 = undefined,
    user_code_len: usize = 0,
    /// Complete JSON body for each token poll.
    poll: [max_device_value_bytes]u8 = undefined,
    poll_len: usize = 0,
    interval_seconds: u16 = 0,

    pub fn userCode(self: *const DeviceStart) []const u8 {
        return self.user_code[0..self.user_code_len];
    }

    pub fn pollBody(self: *const DeviceStart) []const u8 {
        return self.poll[0..self.poll_len];
    }
};

/// Interprets the device-code start response.
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
    destination.* = .{ .interval_seconds = interval };
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(destination));
    if (user_code.len > destination.user_code.len) return error.InvalidDeviceResponse;
    @memcpy(destination.user_code[0..user_code.len], user_code);
    destination.user_code_len = user_code.len;
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

/// Builds the authorization-code exchange form from a device grant body.
pub fn grantExchangeBody(grant_body: []const u8, buffer: []u8) ![]const u8 {
    const Grant = struct { authorization_code: []const u8, code_challenge: []const u8, code_verifier: []const u8 };
    var arena: [32 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &arena);
    var fixed = std.heap.FixedBufferAllocator.init(&arena);
    const grant = std.json.parseFromSlice(Grant, fixed.allocator(), grant_body, .{ .ignore_unknown_fields = true }) catch return error.InvalidDeviceGrant;
    return formEncode(buffer, grant.value.authorization_code, grant.value.code_verifier);
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

pub fn refreshRequestBody(current: *const Tokens, buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll("{\"grant_type\":\"refresh_token\",\"client_id\":\"" ++ client_id ++ "\",\"refresh_token\":\"") catch return error.CredentialValueTooLong;
    writeJsonStringContent(&writer, current.refresh_token.slice()) catch return error.CredentialValueTooLong;
    writer.writeAll("\"}") catch return error.CredentialValueTooLong;
    return writer.buffered();
}

/// Applies a refresh response without erasing omitted rotating fields.
pub fn parseRefreshResponse(current: *const Tokens, status: u16, json: []const u8) !Tokens {
    if (status < 200 or status >= 300) return error.RefreshRejected;
    var wire: OwnedWire = .{};
    defer std.crypto.secureZero(u8, std.mem.asBytes(&wire));
    try parseWire(json, &wire);
    var result = current.*;
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(&result));
    if (wire.has_id) {
        const account = try policy.parseAccount(wire.id.slice());
        if (!std.mem.eql(u8, account.id.slice(), current.account_id.slice()) or
            account.fedramp != (try policy.parseAccount(current.id_token.slice())).fedramp)
            return error.AccountChanged;
        result.id_token = wire.id;
    }
    if (wire.has_access) result.access_token = wire.access;
    if (wire.has_refresh) result.refresh_token = wire.refresh;
    _ = try policy.parseExpiry(result.access_token.slice());
    return result;
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

test "refresh preserves omitted fields and refuses account replacement" {
    const old_id = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0XzEifQ.c2ln";
    const old_access = "e30.eyJleHAiOjQxMDI0NDQ4MDB9.c2ln";
    var current: Tokens = .{};
    try current.id_token.set(old_id);
    try current.access_token.set(old_access);
    try current.refresh_token.set("refresh-old");
    current.account_id = (try policy.parseAccount(old_id)).id;
    const updated = try parseRefreshResponse(&current, 200, "{\"refresh_token\":\"refresh-new\"}");
    try std.testing.expectEqualStrings(old_access, updated.access_token.slice());
    try std.testing.expectEqualStrings("refresh-new", updated.refresh_token.slice());
    try std.testing.expectEqualStrings(old_id, updated.id_token.slice());
    // Rotated tokens for the same account replace the old ones.
    const same_account = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0XzEiLCJzdWIiOiJ4In0.c2ln";
    const rotated_access = "e30.eyJleHAiOjQxMDI0NDQ4MDF9.c2ln";
    var rotated_json: [512]u8 = undefined;
    const rotated = try parseRefreshResponse(&current, 200, try std.fmt.bufPrint(&rotated_json, "{{\"id_token\":\"{s}\",\"access_token\":\"{s}\"}}", .{ same_account, rotated_access }));
    try std.testing.expectEqualStrings(same_account, rotated.id_token.slice());
    try std.testing.expectEqualStrings(rotated_access, rotated.access_token.slice());
    try std.testing.expectEqualStrings("refresh-old", rotated.refresh_token.slice());
    const foreign = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0XzIifQ.c2ln";
    var json: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(&json, "{{\"id_token\":\"{s}\"}}", .{foreign});
    try std.testing.expectError(error.AccountChanged, parseRefreshResponse(&current, 200, response));
    for ([_]u16{ 199, 300, 401, 500 }) |status| {
        try std.testing.expectError(error.RefreshRejected, parseRefreshResponse(&current, status, "{}"));
    }
}

test "refresh keeps the account's routing claim in both directions" {
    var current: Tokens = .{};
    try current.id_token.set(policy.fixture_id_token);
    try current.access_token.set("opaque-access");
    try current.refresh_token.set("refresh-old");
    current.account_id = (try policy.parseAccount(policy.fixture_id_token)).id;
    var json: [512]u8 = undefined;
    const to_federal = try std.fmt.bufPrint(&json, "{{\"id_token\":\"{s}\"}}", .{policy.fixture_fedramp_id_token});
    try std.testing.expectError(error.AccountChanged, parseRefreshResponse(&current, 200, to_federal));
    try current.id_token.set(policy.fixture_fedramp_id_token);
    const from_federal = try std.fmt.bufPrint(&json, "{{\"id_token\":\"{s}\"}}", .{policy.fixture_id_token});
    try std.testing.expectError(error.AccountChanged, parseRefreshResponse(&current, 200, from_federal));
}

test "a refreshed record takes routing and expiry from its new tokens" {
    var record: policy.Record = .{ .generation = 3, .account_id = .{}, .id_token = .{}, .access_token = .{}, .refresh_token = .{}, .expires_at = 1, .refreshed_at = 1, .state = .refresh_pending };
    try record.account_id.set(policy.fixture_account_id);
    try record.id_token.set(policy.fixture_id_token);
    try record.access_token.set("opaque-old");
    try record.refresh_token.set("refresh-old");
    var tokens: Tokens = undefined;
    try tokensFromRecord(&record, &tokens);
    try std.testing.expectEqualStrings("refresh-old", tokens.refresh_token.slice());
    try tokens.id_token.set(policy.fixture_fedramp_id_token);
    try tokens.access_token.set(policy.fixture_access_token);
    try tokens.refresh_token.set("refresh-new");
    try applyRefresh(&record, &tokens, 77);
    try std.testing.expect(record.fedramp);
    try std.testing.expectEqual(@as(i64, 4_102_444_800), record.expires_at);
    try std.testing.expectEqual(@as(i64, 77), record.refreshed_at);
    try std.testing.expectEqual(policy.State.ready, record.state);
    try std.testing.expectEqual(@as(u64, 3), record.generation);
    try std.testing.expectEqualStrings("refresh-new", record.refresh_token.slice());
    try tokens.access_token.set("opaque-new");
    try applyRefresh(&record, &tokens, 78);
    try std.testing.expectEqual(@as(i64, 0), record.expires_at);
}

test "refresh request escapes the refresh token as JSON" {
    var tokens: Tokens = .{};
    try tokens.refresh_token.set("a\"b\\c");
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"grant_type\":\"refresh_token\",\"client_id\":\"" ++ client_id ++ "\",\"refresh_token\":\"a\\\"b\\\\c\"}",
        try refreshRequestBody(&tokens, &buffer),
    );
    var small: [8]u8 = undefined;
    try std.testing.expectError(error.CredentialValueTooLong, refreshRequestBody(&tokens, &small));
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
    try std.testing.expectEqualStrings("{\"device_auth_id\":\"dev-1\",\"user_code\":\"ABCD-EFGH\"}", start.pollBody());
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
    try std.testing.expectEqual(@as(usize, 400), start.userCode().len);
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
    const body = try grantExchangeBody("{\"authorization_code\":\"a+b &\",\"code_challenge\":\"x\",\"code_verifier\":\"v/=+\"}", &buffer);
    try std.testing.expectEqualStrings(
        "grant_type=authorization_code&client_id=" ++ client_id ++
            "&code=a%2Bb%20%26&redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback&code_verifier=v%2F%3D%2B",
        body,
    );
    try std.testing.expectError(error.InvalidDeviceGrant, grantExchangeBody("{}", &buffer));
}
