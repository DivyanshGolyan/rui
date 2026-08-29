const std = @import("std");
const codex_provider = @import("codex_provider.zig");

pub const issuer = "https://auth.openai.com";
pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const verification_url = issuer ++ "/codex/device";
pub const max_token_size = codex_provider.max_access_token_size;
pub const max_response_size: usize = 64 * 1024;
pub const max_device_id_size: usize = 512;
pub const max_user_code_size: usize = 64;

pub const HttpResponse = struct {
    status: u16,
    body: []const u8,
};

pub const Http = struct {
    context: *anyopaque,
    post_fn: *const fn (*anyopaque, []const u8, []const u8, []const u8, []u8) anyerror!HttpResponse,

    pub fn post(
        self: Http,
        url: []const u8,
        content_type: []const u8,
        body: []const u8,
        out: []u8,
    ) !HttpResponse {
        return self.post_fn(self.context, url, content_type, body, out);
    }
};

pub const Store = struct {
    context: *anyopaque,
    load_fn: *const fn (*anyopaque, []u8) anyerror!?[]const u8,
    save_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    delete_fn: *const fn (*anyopaque) anyerror!void,

    pub fn load(self: Store, out: []u8) !?[]const u8 {
        return self.load_fn(self.context, out);
    }
    pub fn save(self: Store, bytes: []const u8) !void {
        try self.save_fn(self.context, bytes);
    }
    pub fn delete(self: Store) !void {
        try self.delete_fn(self.context);
    }
};

pub const DeviceCode = struct {
    device_id: [max_device_id_size]u8 = undefined,
    device_id_length: u16,
    user_code: [max_user_code_size]u8 = undefined,
    user_code_length: u8,
    interval_seconds: u16,

    pub fn deviceId(self: *const DeviceCode) []const u8 {
        return self.device_id[0..self.device_id_length];
    }
    pub fn userCode(self: *const DeviceCode) []const u8 {
        return self.user_code[0..self.user_code_length];
    }
};

pub const PollResult = union(enum) {
    pending,
    slow_down,
    authorization: AuthorizationCode,
};

pub const AuthorizationCode = struct {
    code: [max_token_size]u8 = undefined,
    code_length: u16,
    verifier: [max_token_size]u8 = undefined,
    verifier_length: u16,

    pub fn authorizationCode(self: *const AuthorizationCode) []const u8 {
        return self.code[0..self.code_length];
    }
    pub fn codeVerifier(self: *const AuthorizationCode) []const u8 {
        return self.verifier[0..self.verifier_length];
    }

    pub fn scrub(self: *AuthorizationCode) void {
        std.crypto.secureZero(u8, &self.code);
        std.crypto.secureZero(u8, &self.verifier);
        self.code_length = 0;
        self.verifier_length = 0;
    }
};

pub const Tokens = struct {
    access: [max_token_size]u8 = @splat(0),
    access_length: u16 = 0,
    refresh: [max_token_size]u8 = @splat(0),
    refresh_length: u16 = 0,
    id: [max_token_size]u8 = @splat(0),
    id_length: u16 = 0,
    account: [codex_provider.max_account_id_size]u8 = @splat(0),
    account_length: u8 = 0,

    pub fn accessToken(self: *const Tokens) []const u8 {
        return self.access[0..self.access_length];
    }
    pub fn refreshToken(self: *const Tokens) []const u8 {
        return self.refresh[0..self.refresh_length];
    }
    pub fn idToken(self: *const Tokens) []const u8 {
        return self.id[0..self.id_length];
    }
    pub fn accountId(self: *const Tokens) []const u8 {
        return self.account[0..self.account_length];
    }

    pub fn scrub(self: *Tokens) void {
        std.crypto.secureZero(u8, &self.access);
        std.crypto.secureZero(u8, &self.refresh);
        std.crypto.secureZero(u8, &self.id);
        std.crypto.secureZero(u8, &self.account);
        self.* = .{};
    }
};

pub fn requestDeviceCode(http: Http) !DeviceCode {
    var body: [128]u8 = undefined;
    const request = try std.fmt.bufPrint(&body, "{{\"client_id\":\"{s}\"}}", .{client_id});
    var response_bytes: [max_response_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &response_bytes);
    const response = try http.post(
        issuer ++ "/api/accounts/deviceauth/usercode",
        "application/json",
        request,
        &response_bytes,
    );
    if (response.status != 200) return error.DeviceAuthorizationUnavailable;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response.body, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.MalformedAuthorizationResponse,
    };
    const device_id = string(object.get("device_auth_id")) orelse return error.MalformedAuthorizationResponse;
    const user_code = string(object.get("user_code")) orelse string(object.get("usercode")) orelse
        return error.MalformedAuthorizationResponse;
    const interval: u16 = switch (object.get("interval") orelse return error.MalformedAuthorizationResponse) {
        .string => |value| try std.fmt.parseInt(u16, value, 10),
        .integer => |value| std.math.cast(u16, value) orelse return error.MalformedAuthorizationResponse,
        else => return error.MalformedAuthorizationResponse,
    };
    if (device_id.len == 0 or device_id.len > max_device_id_size or user_code.len == 0 or
        user_code.len > max_user_code_size or interval == 0 or interval > 60)
    {
        return error.MalformedAuthorizationResponse;
    }
    var result: DeviceCode = .{
        .device_id_length = @intCast(device_id.len),
        .user_code_length = @intCast(user_code.len),
        .interval_seconds = interval,
    };
    @memcpy(result.device_id[0..device_id.len], device_id);
    @memcpy(result.user_code[0..user_code.len], user_code);
    return result;
}

pub fn pollDeviceCode(http: Http, device: *const DeviceCode) !PollResult {
    var body: [max_device_id_size + max_user_code_size + 96]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &body,
        "{{\"device_auth_id\":\"{s}\",\"user_code\":\"{s}\"}}",
        .{ device.deviceId(), device.userCode() },
    );
    var response_bytes: [max_response_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &response_bytes);
    const response = try http.post(
        issuer ++ "/api/accounts/deviceauth/token",
        "application/json",
        request,
        &response_bytes,
    );
    if (response.status == 403 or response.status == 404 or
        responseErrorIs(response.body, "deviceauth_authorization_pending"))
    {
        return .pending;
    }
    if (responseErrorIs(response.body, "slow_down")) return .slow_down;
    if (response.status == 429) return .slow_down;
    if (response.status != 200) return error.DeviceAuthorizationFailed;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response.body, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.MalformedAuthorizationResponse,
    };
    const code = string(object.get("authorization_code")) orelse return error.MalformedAuthorizationResponse;
    const verifier = string(object.get("code_verifier")) orelse return error.MalformedAuthorizationResponse;
    if (code.len == 0 or code.len > max_token_size or verifier.len == 0 or verifier.len > max_token_size) {
        return error.MalformedAuthorizationResponse;
    }
    var authorization: AuthorizationCode = .{
        .code_length = @intCast(code.len),
        .verifier_length = @intCast(verifier.len),
    };
    @memcpy(authorization.code[0..code.len], code);
    @memcpy(authorization.verifier[0..verifier.len], verifier);
    return .{ .authorization = authorization };
}

pub fn exchangeCode(http: Http, authorization: *const AuthorizationCode) !Tokens {
    var body: [2 * max_token_size + 512]u8 = undefined;
    defer std.crypto.secureZero(u8, &body);
    var stream = std.Io.Writer.fixed(&body);
    try stream.writeAll("grant_type=authorization_code&code=");
    try percentEncode(&stream, authorization.authorizationCode());
    try stream.writeAll("&redirect_uri=");
    try percentEncode(&stream, issuer ++ "/deviceauth/callback");
    try stream.writeAll("&client_id=");
    try percentEncode(&stream, client_id);
    try stream.writeAll("&code_verifier=");
    try percentEncode(&stream, authorization.codeVerifier());
    var response_bytes: [max_response_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &response_bytes);
    const response = try http.post(issuer ++ "/oauth/token", "application/x-www-form-urlencoded", stream.buffered(), &response_bytes);
    if (response.status != 200) return error.TokenExchangeFailed;
    return parseTokens(response.body);
}

pub fn refresh(http: Http, existing: *const Tokens) !Tokens {
    if (existing.refreshToken().len == 0) return error.MissingRefreshToken;
    var body: [max_token_size + 256]u8 = undefined;
    defer std.crypto.secureZero(u8, &body);
    var stream = std.Io.Writer.fixed(&body);
    try stream.writeAll("grant_type=refresh_token&refresh_token=");
    try percentEncode(&stream, existing.refreshToken());
    try stream.writeAll("&client_id=");
    try percentEncode(&stream, client_id);
    var response_bytes: [max_response_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &response_bytes);
    const response = try http.post(issuer ++ "/oauth/token", "application/x-www-form-urlencoded", stream.buffered(), &response_bytes);
    if (response.status == 400 or response.status == 401) return error.RefreshRejected;
    if (response.status != 200) return error.RefreshFailed;
    var tokens = try parseTokensWithFallback(response.body, existing);
    errdefer tokens.scrub();
    if (!std.mem.eql(u8, tokens.accountId(), existing.accountId())) {
        return error.AccountBindingChanged;
    }
    return tokens;
}

pub fn revoke(http: Http, tokens: *const Tokens) !void {
    const token = if (tokens.refreshToken().len != 0) tokens.refreshToken() else tokens.accessToken();
    if (token.len == 0) return;
    var body: [max_token_size + 256]u8 = undefined;
    defer std.crypto.secureZero(u8, &body);
    var stream = std.Io.Writer.fixed(&body);
    try stream.writeAll("token=");
    try percentEncode(&stream, token);
    try stream.writeAll("&client_id=");
    try percentEncode(&stream, client_id);
    var response_bytes: [max_response_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &response_bytes);
    const response = try http.post(issuer ++ "/oauth/revoke", "application/x-www-form-urlencoded", stream.buffered(), &response_bytes);
    if (response.status < 200 or response.status >= 300) return error.RevokeFailed;
}

pub fn encodeStored(tokens: *const Tokens, out: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(out);
    try writer.writeAll("{\"access_token\":");
    try writeJsonString(&writer, tokens.accessToken());
    try writer.writeAll(",\"refresh_token\":");
    try writeJsonString(&writer, tokens.refreshToken());
    try writer.writeAll(",\"id_token\":");
    try writeJsonString(&writer, tokens.idToken());
    try writer.writeAll(",\"account_id\":");
    try writeJsonString(&writer, tokens.accountId());
    try writer.writeAll("}");
    return writer.buffered();
}

pub fn decodeStored(bytes: []const u8) !Tokens {
    return parseTokens(bytes);
}

fn parseTokens(bytes: []const u8) !Tokens {
    return parseTokensWithFallback(bytes, null);
}

fn parseTokensWithFallback(bytes: []const u8, fallback: ?*const Tokens) !Tokens {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, bytes, .{
        .allocate = .alloc_if_needed,
    });
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.MalformedTokenResponse,
    };
    const access = string(object.get("access_token")) orelse return error.MalformedTokenResponse;
    const refresh_token = string(object.get("refresh_token")) orelse
        if (fallback) |tokens| tokens.refreshToken() else "";
    const id_token = string(object.get("id_token")) orelse
        if (fallback) |tokens| tokens.idToken() else return error.MalformedTokenResponse;
    const stored_account = string(object.get("account_id")) orelse "";
    var decoded_account: [codex_provider.max_account_id_size]u8 = undefined;
    const account = if (stored_account.len != 0)
        stored_account
    else
        accountIdFromAccessToken(access, &decoded_account) catch if (fallback) |tokens|
            tokens.accountId()
        else
            return error.MalformedAccessToken;
    if (access.len == 0 or access.len > max_token_size or refresh_token.len > max_token_size or
        id_token.len == 0 or id_token.len > max_token_size or account.len == 0 or
        account.len > codex_provider.max_account_id_size)
    {
        return error.MalformedTokenResponse;
    }
    var tokens: Tokens = .{};
    @memcpy(tokens.access[0..access.len], access);
    tokens.access_length = @intCast(access.len);
    @memcpy(tokens.refresh[0..refresh_token.len], refresh_token);
    tokens.refresh_length = @intCast(refresh_token.len);
    @memcpy(tokens.id[0..id_token.len], id_token);
    tokens.id_length = @intCast(id_token.len);
    @memcpy(tokens.account[0..account.len], account);
    tokens.account_length = @intCast(account.len);
    return tokens;
}

fn accountIdFromAccessToken(jwt: []const u8, out: []u8) ![]const u8 {
    var pieces = std.mem.splitScalar(u8, jwt, '.');
    _ = pieces.next() orelse return error.MalformedAccessToken;
    const payload = pieces.next() orelse return error.MalformedAccessToken;
    var decoded: [max_token_size]u8 = undefined;
    const length = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload);
    if (length > decoded.len) return error.MalformedAccessToken;
    try std.base64.url_safe_no_pad.Decoder.decode(decoded[0..length], payload);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, decoded[0..length], .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.MalformedAccessToken,
    };
    const auth = switch (object.get("https://api.openai.com/auth") orelse return error.MalformedAccessToken) {
        .object => |value| value,
        else => return error.MalformedAccessToken,
    };
    const account = string(auth.get("chatgpt_account_id")) orelse return error.MalformedAccessToken;
    if (account.len == 0 or account.len > out.len) return error.MalformedAccessToken;
    @memcpy(out[0..account.len], account);
    return out[0..account.len];
}

fn string(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |text| text,
        else => null,
    };
}

fn responseErrorIs(bytes: []const u8, expected: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, bytes, .{
        .allocate = .alloc_if_needed,
    }) catch return false;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const code = string(object.get("error")) orelse string(object.get("code")) orelse return false;
    return std.mem.eql(u8, code, expected);
}

fn percentEncode(writer: *std.Io.Writer, bytes: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (bytes) |byte| if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
        try writer.writeByte(byte);
    } else {
        try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 15] });
    };
}

fn writeJsonString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    for (bytes) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

test "device authorization and refresh use the official subscription protocol" {
    var fake = FakeHttp{};
    const http: Http = .{ .context = &fake, .post_fn = FakeHttp.post };
    const device = try requestDeviceCode(http);
    try std.testing.expectEqualStrings("ABCD-EFGH", device.userCode());
    try std.testing.expect((try pollDeviceCode(http, &device)) == .pending);
    const polled = try pollDeviceCode(http, &device);
    var tokens = try exchangeCode(http, &polled.authorization);
    defer tokens.scrub();
    try std.testing.expectEqualStrings("acct-1", tokens.accountId());
    var renewed = try refresh(http, &tokens);
    defer renewed.scrub();
    try std.testing.expectEqualStrings("new-access", renewed.accessToken());
    try std.testing.expectEqualStrings("refresh", renewed.refreshToken());
    var stored: [3 * max_token_size + 1024]u8 = undefined;
    var reopened = try decodeStored(try encodeStored(&renewed, &stored));
    defer reopened.scrub();
    try std.testing.expectEqualStrings(renewed.accountId(), reopened.accountId());
    try std.testing.expect(responseErrorIs("{\"error\":\"slow_down\"}", "slow_down"));

    var changed = ChangedAccountHttp{};
    const changed_http: Http = .{ .context = &changed, .post_fn = ChangedAccountHttp.post };
    try std.testing.expectError(error.AccountBindingChanged, refresh(changed_http, &tokens));
}

test "account binding comes from the nested access-token auth claim" {
    var tokens = try parseTokens(
        "{\"access_token\":\"e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC1saXZlIn19.sig\"," ++
            "\"refresh_token\":\"refresh\",\"id_token\":\"e30.e30.sig\"}",
    );
    defer tokens.scrub();
    try std.testing.expectEqualStrings("acct-live", tokens.accountId());
}

const ChangedAccountHttp = struct {
    fn post(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8, out: []u8) anyerror!HttpResponse {
        const body = "{\"access_token\":\"e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0yIn19.sig\",\"refresh_token\":\"refresh\"}";
        @memcpy(out[0..body.len], body);
        return .{ .status = 200, .body = out[0..body.len] };
    }
};

const FakeHttp = struct {
    calls: u8 = 0,

    fn post(context: *anyopaque, url: []const u8, _: []const u8, _: []const u8, out: []u8) anyerror!HttpResponse {
        const self: *FakeHttp = @ptrCast(@alignCast(context));
        self.calls += 1;
        const body = if (std.mem.endsWith(u8, url, "/deviceauth/usercode"))
            "{\"device_auth_id\":\"device-1\",\"user_code\":\"ABCD-EFGH\",\"interval\":\"1\"}"
        else if (std.mem.endsWith(u8, url, "/deviceauth/token") and self.calls == 2)
            ""
        else if (std.mem.endsWith(u8, url, "/deviceauth/token"))
            "{\"authorization_code\":\"code\",\"code_challenge\":\"challenge\",\"code_verifier\":\"verifier\"}"
        else if (std.mem.endsWith(u8, url, "/oauth/token") and self.calls == 4)
            "{\"access_token\":\"e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0xIn19.sig\",\"refresh_token\":\"refresh\",\"id_token\":\"e30.e30.sig\"}"
        else
            "{\"access_token\":\"new-access\"}";
        if (body.len > out.len) return error.ResponseTooLarge;
        @memcpy(out[0..body.len], body);
        return .{ .status = if (self.calls == 2) 403 else 200, .body = out[0..body.len] };
    }
};
