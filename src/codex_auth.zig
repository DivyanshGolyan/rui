const std = @import("std");
const codex_provider = @import("codex_provider.zig");

pub const issuer = "https://auth.openai.com";
pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const verification_url = issuer ++ "/codex/device";
pub const max_token_size = codex_provider.max_access_token_size;
pub const max_response_size: usize = 64 * 1024;
pub const max_device_id_size: usize = 512;
pub const max_user_code_size: usize = 64;
pub const request_timeout = std.Io.Duration.fromSeconds(300);
const max_json_nesting_depth: usize = 32;
const json_scanner_stack_size: usize = 2 * std.atomic.cache_line;

pub const HttpResponse = struct {
    status: u16,
    body: []const u8,
};

pub const Http = struct {
    context: *anyopaque,
    post_fn: *const fn (*anyopaque, []const u8, []const u8, []const u8, []u8, std.Io.Duration) anyerror!HttpResponse,
    timeout: std.Io.Duration = request_timeout,

    pub fn withTimeout(self: Http, timeout: std.Io.Duration) Http {
        var bounded = self;
        bounded.timeout = if (timeout.nanoseconds < self.timeout.nanoseconds) timeout else self.timeout;
        return bounded;
    }

    pub fn post(
        self: Http,
        url: []const u8,
        content_type: []const u8,
        body: []const u8,
        out: []u8,
    ) !HttpResponse {
        if (self.timeout.nanoseconds <= 0) return error.HttpRequestTimedOut;
        return self.post_fn(self.context, url, content_type, body, out, self.timeout);
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

const DeviceCodeEnvelope = struct {
    device_auth_id: ?[]const u8 = null,
    user_code: ?[]const u8 = null,
    usercode: ?[]const u8 = null,
    interval: ?std.json.Value = null,
};

const AuthorizationEnvelope = struct {
    authorization_code: ?[]const u8 = null,
    code_verifier: ?[]const u8 = null,
};

const ProviderTokenEnvelope = struct {
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    id_token: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
};

const StoredTokenEnvelope = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    id_token: []const u8,
    account_id: []const u8,
};

const AccessTokenClaims = struct {
    @"https://api.openai.com/auth": ?struct {
        chatgpt_account_id: ?[]const u8 = null,
    } = null,
};

const ErrorEnvelope = struct {
    @"error": ?[]const u8 = null,
    code: ?[]const u8 = null,
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
    var parsed = try parseProviderEnvelope(DeviceCodeEnvelope, response.body);
    defer parsed.deinit();
    const device_id = parsed.value.device_auth_id orelse return error.MalformedAuthorizationResponse;
    if (parsed.value.user_code != null and parsed.value.usercode != null) {
        return error.MalformedAuthorizationResponse;
    }
    const user_code = parsed.value.user_code orelse parsed.value.usercode orelse
        return error.MalformedAuthorizationResponse;
    const interval: u16 = switch (parsed.value.interval orelse return error.MalformedAuthorizationResponse) {
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
    var parsed = try parseProviderEnvelope(AuthorizationEnvelope, response.body);
    defer parsed.deinit();
    const code = parsed.value.authorization_code orelse return error.MalformedAuthorizationResponse;
    const verifier = parsed.value.code_verifier orelse return error.MalformedAuthorizationResponse;
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
    var parsed = try parseStoredEnvelope(StoredTokenEnvelope, bytes);
    defer parsed.deinit();
    return buildTokens(
        parsed.value.access_token,
        parsed.value.refresh_token,
        parsed.value.id_token,
        parsed.value.account_id,
    );
}

fn parseTokens(bytes: []const u8) !Tokens {
    return parseTokensWithFallback(bytes, null);
}

fn parseTokensWithFallback(bytes: []const u8, fallback: ?*const Tokens) !Tokens {
    var parsed = try parseProviderEnvelope(ProviderTokenEnvelope, bytes);
    defer parsed.deinit();
    const access = parsed.value.access_token orelse return error.MalformedTokenResponse;
    const refresh_token = parsed.value.refresh_token orelse
        if (fallback) |tokens| tokens.refreshToken() else "";
    const id_token = parsed.value.id_token orelse
        if (fallback) |tokens| tokens.idToken() else return error.MalformedTokenResponse;
    var decoded_account: [codex_provider.max_account_id_size]u8 = undefined;
    const account = try accountIdFromAccessToken(access, &decoded_account);
    if (parsed.value.account_id) |provider_account| {
        if (!std.mem.eql(u8, provider_account, account)) return error.AccountBindingMismatch;
    }
    return buildTokens(access, refresh_token, id_token, account);
}

fn buildTokens(
    access: []const u8,
    refresh_token: []const u8,
    id_token: []const u8,
    account: []const u8,
) !Tokens {
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
    var parsed = try parseProviderEnvelope(AccessTokenClaims, decoded[0..length]);
    defer parsed.deinit();
    const auth = @field(parsed.value, "https://api.openai.com/auth") orelse
        return error.MalformedAccessToken;
    const account = auth.chatgpt_account_id orelse return error.MalformedAccessToken;
    if (account.len == 0 or account.len > out.len) return error.MalformedAccessToken;
    @memcpy(out[0..account.len], account);
    return out[0..account.len];
}

fn responseErrorIs(bytes: []const u8, expected: []const u8) bool {
    var parsed = parseProviderEnvelope(ErrorEnvelope, bytes) catch return false;
    defer parsed.deinit();
    if (@field(parsed.value, "error") != null and parsed.value.code != null) return false;
    const code = @field(parsed.value, "error") orelse parsed.value.code orelse return false;
    return std.mem.eql(u8, code, expected);
}

fn parseProviderEnvelope(comptime T: type, bytes: []const u8) !std.json.Parsed(T) {
    try preflightJsonDepth(bytes);
    return std.json.parseFromSlice(T, std.heap.page_allocator, bytes, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    });
}

fn parseStoredEnvelope(comptime T: type, bytes: []const u8) !std.json.Parsed(T) {
    try preflightJsonDepth(bytes);
    return std.json.parseFromSlice(T, std.heap.page_allocator, bytes, .{
        .allocate = .alloc_if_needed,
    });
}

fn preflightJsonDepth(bytes: []const u8) !void {
    var stack: [json_scanner_stack_size]u8 align(@alignOf(usize)) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&stack);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), bytes);
    defer scanner.deinit();
    scanner.ensureTotalStackCapacity(max_json_nesting_depth + 1) catch
        return error.JsonNestingTooDeep;
    while (true) {
        const token = scanner.next() catch |err| return err;
        switch (token) {
            .object_begin, .array_begin => if (scanner.stackHeight() > max_json_nesting_depth) {
                return error.JsonNestingTooDeep;
            },
            .end_of_document => return,
            else => {},
        }
    }
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
    try std.testing.expectEqualStrings(
        "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0xIn19.sig",
        renewed.accessToken(),
    );
    try std.testing.expectEqualStrings("refresh", renewed.refreshToken());
    var stored: [3 * max_token_size + 1024]u8 = undefined;
    var reopened = try decodeStored(try encodeStored(&renewed, &stored));
    defer reopened.scrub();
    try std.testing.expectEqualStrings(renewed.accountId(), reopened.accountId());
    try std.testing.expect(responseErrorIs(
        "{\"future\":1,\"error\":\"slow_down\",\"future\":{}}",
        "slow_down",
    ));

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

test "provider token envelopes ignore unknown extensions but keep consumed fields strict" {
    const jwt = "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC1saXZlIn19.sig";
    var tokens = try parseTokens(
        "{\"future\":1,\"access_token\":\"" ++ jwt ++
            "\",\"future\":{\"nested\":true},\"refresh_token\":\"refresh\",\"id_token\":\"e30.e30.sig\"}",
    );
    defer tokens.scrub();
    try std.testing.expectEqualStrings("acct-live", tokens.accountId());
    try std.testing.expectError(
        error.DuplicateField,
        parseTokens(
            "{\"access_token\":\"" ++ jwt ++ "\",\"access_token\":\"" ++ jwt ++
                "\",\"refresh_token\":\"refresh\",\"id_token\":\"e30.e30.sig\"}",
        ),
    );

    const claim =
        "{\"future\":1,\"https://api.openai.com/auth\":{\"future\":1,\"chatgpt_account_id\":\"acct-live\",\"future\":2},\"future\":2}";
    var encoded_claim: [512]u8 = undefined;
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(&encoded_claim, claim);
    var jwt_bytes: [640]u8 = undefined;
    const claim_jwt = try std.fmt.bufPrint(&jwt_bytes, "e30.{s}.sig", .{encoded});
    var account: [codex_provider.max_account_id_size]u8 = undefined;
    try std.testing.expectEqualStrings("acct-live", try accountIdFromAccessToken(claim_jwt, &account));
}

test "provider account metadata cannot contradict the access-token claim" {
    const jwt = "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC1saXZlIn19.sig";
    try std.testing.expectError(
        error.AccountBindingMismatch,
        parseTokens(
            "{\"access_token\":\"" ++ jwt ++
                "\",\"refresh_token\":\"refresh\",\"id_token\":\"e30.e30.sig\",\"account_id\":\"acct-other\"}",
        ),
    );
}

test "open authorization envelopes reject ambiguous consumed fields" {
    {
        var parsed = try parseProviderEnvelope(
            DeviceCodeEnvelope,
            "{\"device_auth_id\":\"device\",\"user_code\":\"code\",\"future\":1,\"future\":{}}",
        );
        parsed.deinit();
    }
    try std.testing.expectError(
        error.DuplicateField,
        parseProviderEnvelope(
            DeviceCodeEnvelope,
            "{\"device_auth_id\":\"device\",\"device_auth_id\":\"other\",\"user_code\":\"code\"}",
        ),
    );
    try std.testing.expectError(
        error.UnexpectedToken,
        parseProviderEnvelope(
            DeviceCodeEnvelope,
            "{\"device_auth_id\":1,\"user_code\":\"code\"}",
        ),
    );
    try std.testing.expectError(
        error.DuplicateField,
        parseProviderEnvelope(
            AuthorizationEnvelope,
            "{\"authorization_code\":\"code\",\"authorization_code\":\"other\",\"code_verifier\":\"verifier\"}",
        ),
    );
    var wrong_authorization = WrongAuthorizationHttp{};
    const wrong_authorization_http: Http = .{
        .context = &wrong_authorization,
        .post_fn = WrongAuthorizationHttp.post,
    };
    const device: DeviceCode = .{
        .device_id_length = 0,
        .user_code_length = 0,
        .interval_seconds = 1,
    };
    try std.testing.expectError(
        error.MalformedAuthorizationResponse,
        pollDeviceCode(wrong_authorization_http, &device),
    );
    try std.testing.expect(!responseErrorIs(
        "{\"error\":\"slow_down\",\"code\":\"slow_down\"}",
        "slow_down",
    ));
    try std.testing.expect(!responseErrorIs("{\"error\":1}", "slow_down"));
}

test "open access-token claims reject ambiguous consumed fields" {
    const duplicate_claim =
        "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-a\",\"chatgpt_account_id\":\"acct-b\"}}";
    var duplicate_encoded_bytes: [512]u8 = undefined;
    const duplicate_encoded = std.base64.url_safe_no_pad.Encoder.encode(&duplicate_encoded_bytes, duplicate_claim);
    var duplicate_jwt_bytes: [640]u8 = undefined;
    const duplicate_jwt = try std.fmt.bufPrint(&duplicate_jwt_bytes, "e30.{s}.sig", .{duplicate_encoded});
    var account: [codex_provider.max_account_id_size]u8 = undefined;
    try std.testing.expectError(error.DuplicateField, accountIdFromAccessToken(duplicate_jwt, &account));

    const wrong_type_claim =
        "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":42}}";
    var wrong_type_encoded_bytes: [512]u8 = undefined;
    const wrong_type_encoded = std.base64.url_safe_no_pad.Encoder.encode(&wrong_type_encoded_bytes, wrong_type_claim);
    var wrong_type_jwt_bytes: [640]u8 = undefined;
    const wrong_type_jwt = try std.fmt.bufPrint(&wrong_type_jwt_bytes, "e30.{s}.sig", .{wrong_type_encoded});
    try std.testing.expectError(error.UnexpectedToken, accountIdFromAccessToken(wrong_type_jwt, &account));
}

test "authorization JSON has an explicit nesting bound" {
    var exact_bytes: [256]u8 = undefined;
    var exact = std.Io.Writer.fixed(&exact_bytes);
    try exact.writeAll("{\"future\":");
    for (0..max_json_nesting_depth - 1) |_| try exact.writeByte('[');
    try exact.writeByte('0');
    for (0..max_json_nesting_depth - 1) |_| try exact.writeByte(']');
    try exact.writeByte('}');
    var parsed = try parseProviderEnvelope(ErrorEnvelope, exact.buffered());
    parsed.deinit();

    var exceeded_bytes: [256]u8 = undefined;
    var exceeded = std.Io.Writer.fixed(&exceeded_bytes);
    try exceeded.writeAll("{\"future\":");
    for (0..max_json_nesting_depth) |_| try exceeded.writeByte('[');
    try exceeded.writeByte('0');
    for (0..max_json_nesting_depth) |_| try exceeded.writeByte(']');
    try exceeded.writeByte('}');
    try std.testing.expectError(
        error.JsonNestingTooDeep,
        parseProviderEnvelope(ErrorEnvelope, exceeded.buffered()),
    );
}

test "stored credentials use one closed exact shape" {
    const stored =
        "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"id_token\":\"id\",\"account_id\":\"account\",\"future\":true}";
    try std.testing.expectError(error.UnknownField, decodeStored(stored));
    try std.testing.expectError(
        error.MissingField,
        decodeStored("{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"id_token\":\"id\"}"),
    );
    try std.testing.expectError(
        error.DuplicateField,
        decodeStored(
            "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"id_token\":\"id\",\"account_id\":\"account\",\"account_id\":\"account\"}",
        ),
    );
}

test "refresh rejects a new access token without a trustworthy account claim" {
    var existing = try parseTokens(
        "{\"access_token\":\"e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0xIn19.sig\"," ++
            "\"refresh_token\":\"refresh\",\"id_token\":\"e30.e30.sig\"}",
    );
    defer existing.scrub();
    var missing = MissingAccountHttp{};
    const http: Http = .{ .context = &missing, .post_fn = MissingAccountHttp.post };
    try std.testing.expectError(error.MalformedAccessToken, refresh(http, &existing));
}

const ChangedAccountHttp = struct {
    fn post(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8, out: []u8, _: std.Io.Duration) anyerror!HttpResponse {
        const body = "{\"access_token\":\"e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0yIn19.sig\",\"refresh_token\":\"refresh\"}";
        @memcpy(out[0..body.len], body);
        return .{ .status = 200, .body = out[0..body.len] };
    }
};

const MissingAccountHttp = struct {
    fn post(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8, out: []u8, _: std.Io.Duration) anyerror!HttpResponse {
        const body = "{\"access_token\":\"e30.e30.sig\"}";
        @memcpy(out[0..body.len], body);
        return .{ .status = 200, .body = out[0..body.len] };
    }
};

const WrongAuthorizationHttp = struct {
    fn post(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8, out: []u8, _: std.Io.Duration) anyerror!HttpResponse {
        const body = "{\"authorization_code\":[],\"code_verifier\":\"verifier\"}";
        @memcpy(out[0..body.len], body);
        return .{ .status = 200, .body = out[0..body.len] };
    }
};

const FakeHttp = struct {
    calls: u8 = 0,

    fn post(context: *anyopaque, url: []const u8, _: []const u8, _: []const u8, out: []u8, _: std.Io.Duration) anyerror!HttpResponse {
        const self: *FakeHttp = @ptrCast(@alignCast(context));
        self.calls += 1;
        const body = if (std.mem.endsWith(u8, url, "/deviceauth/usercode"))
            "{\"future\":1,\"device_auth_id\":\"device-1\",\"user_code\":\"ABCD-EFGH\",\"interval\":\"1\",\"future\":{}}"
        else if (std.mem.endsWith(u8, url, "/deviceauth/token") and self.calls == 2)
            ""
        else if (std.mem.endsWith(u8, url, "/deviceauth/token"))
            "{\"future\":1,\"authorization_code\":\"code\",\"code_challenge\":\"challenge\",\"code_verifier\":\"verifier\",\"future\":{}}"
        else if (std.mem.endsWith(u8, url, "/oauth/token") and self.calls == 4)
            "{\"access_token\":\"e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0xIn19.sig\",\"refresh_token\":\"refresh\",\"id_token\":\"e30.e30.sig\"}"
        else
            "{\"access_token\":\"e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0xIn19.sig\"}";
        if (body.len > out.len) return error.ResponseTooLarge;
        @memcpy(out[0..body.len], body);
        return .{ .status = if (self.calls == 2) 403 else 200, .body = out[0..body.len] };
    }
};
