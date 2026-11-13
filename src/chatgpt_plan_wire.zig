//! ChatGPT plan sign-in messages as values: the open-source "Sign in with
//! ChatGPT" flow, which pays from the user's plan.
//!
//! Builds the authorization address, reads the loopback callback, builds the
//! token exchange, refresh and revocation requests, checks the token response
//! and builds the record it produces, and spells the host id. Callers own the
//! random bytes, the clock, the listener, the browser and the transport. The
//! record is `codex_credential_policy.zig`'s and its custody
//! `codex_credentials.zig`'s, as for a Codex login; this flow adds the client
//! id the issuer gives it, and the policy reads such a record's account from
//! its ID token's `sub`, since these tokens carry no ChatGPT account claim. The issuer is the one Codex login uses, so its
//! token fields and refresh rejections are read by `codex_token_wire.zig`.
//!
//! Also reads the plan's model list, the IDs a person signed in this way can
//! pick, under `model_list.zig`'s bounds.
const std = @import("std");
const policy = @import("codex_credential_policy.zig");
const codex = @import("codex_token_wire.zig");
const json_scalar = @import("json_scalar.zig");
const model_list = @import("model_list.zig");

pub const Request = codex.Request;
pub const issuer = codex.issuer;
/// The client a first sign-in names; the issuer answers with the client id
/// this installation keeps.
pub const first_client_id = "dynamic_agent_client";
pub const agent_name = "Rui";
pub const scope = "openid profile email offline_access resource.invoke " ++ plan_scope;
/// The scope that lets the tokens spend the plan. Without it the sign-in is
/// an identity only.
pub const plan_scope = "chatgpt.tokens.use.direct";
pub const resource = "https://api.openai.com/v1";
pub const max_code_bytes = 2048;
pub const max_refusal_bytes = 128;

pub const authorize_url = issuer ++ "/api/accounts/authorize";
const token_url = issuer ++ "/api/accounts/oauth/token";
const revoke_url = issuer ++ "/api/accounts/oauth/revoke";
/// Only the port of the redirect address may vary.
const loopback_origin = "http://127.0.0.1:";
const callback_path = "/auth/callback";
const ClientId = policy.Bounded(policy.max_client_id_bytes);

const secret_bytes = 32;
const secret_text_len = std.base64.url_safe_no_pad.Encoder.calcSize(secret_bytes);
/// Random bytes one attempt takes: its state, its nonce and its PKCE verifier.
pub const random_bytes = 3 * secret_bytes;

/// One sign-in attempt, from the authorization address to the record. Its
/// verifier is secret: the caller wipes the attempt when the attempt ends.
pub const Attempt = struct {
    state: [secret_text_len]u8,
    nonce: [secret_text_len]u8,
    verifier: [secret_text_len]u8,
    port: u16,
    /// The issued client id a returning sign-in names; null on the first.
    saved_client_id: ?ClientId,
};

/// Starts one attempt from `random` and returns the address the user opens,
/// written into `buffer`. `saved` is the record of an earlier sign-in, if
/// any, signed in or out: its issued client id makes this a returning
/// sign-in, which names no agent. The address is printed for the user to
/// open, so it never carries a token: it sends no `id_token_hint`, which the
/// issuer takes as optional, and the user picks the account. On error
/// `attempt` is zeroed.
pub fn authorize(random: *const [random_bytes]u8, port: u16, host_id: []const u8, saved: ?*const policy.Record, attempt: *Attempt, buffer: []u8) ![]const u8 {
    std.debug.assert(port != 0);
    try validateHostId(host_id);
    attempt.* = .{ .state = undefined, .nonce = undefined, .verifier = undefined, .port = port, .saved_client_id = null };
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(attempt));
    const encoder = std.base64.url_safe_no_pad.Encoder;
    _ = encoder.encode(&attempt.state, random[0..secret_bytes]);
    _ = encoder.encode(&attempt.nonce, random[secret_bytes..][0..secret_bytes]);
    _ = encoder.encode(&attempt.verifier, random[2 * secret_bytes ..][0..secret_bytes]);
    if (saved) |record| {
        if (record.client_id.len == 0) return error.MissingClientId;
        attempt.saved_client_id = record.client_id;
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&attempt.verifier, &digest, .{});
    var challenge: [encoder.calcSize(digest.len)]u8 = undefined;
    _ = encoder.encode(&challenge, &digest);

    var writer = std.Io.Writer.fixed(buffer);
    writeAuthorize(&writer, attempt, host_id, saved, &challenge) catch return error.RequestTooLong;
    return writer.buffered();
}

fn writeAuthorize(writer: *std.Io.Writer, attempt: *const Attempt, host_id: []const u8, saved: ?*const policy.Record, challenge: []const u8) !void {
    try writer.writeAll(authorize_url);
    if (saved) |record| {
        try param(writer, "?client_id=", record.client_id.slice());
    } else {
        try param(writer, "?client_id=", first_client_id);
        try param(writer, "&agent_name_hint=", agent_name);
    }
    try param(writer, "&ext_agent_host_id=", host_id);
    try param(writer, "&response_type=", "code");
    try redirectParam(writer, "&redirect_uri=", attempt.port);
    try param(writer, "&scope=", scope);
    try param(writer, "&resource=", resource);
    try param(writer, "&state=", &attempt.state);
    try param(writer, "&nonce=", &attempt.nonce);
    try param(writer, "&code_challenge_method=", "S256");
    try param(writer, "&code_challenge=", challenge);
}

fn param(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.writeAll(name);
    try codex.percentEncode(writer, value);
}

fn redirectParam(writer: *std.Io.Writer, name: []const u8, port: u16) !void {
    var address: [loopback_origin.len + 5 + callback_path.len]u8 = undefined;
    try param(writer, name, std.fmt.bufPrint(&address, loopback_origin ++ "{d}" ++ callback_path, .{port}) catch unreachable);
}

/// What the issuer granted, read from the callback. The code is secret.
pub const Grant = struct {
    code: policy.Required(max_code_bytes) = .{},
    /// The issued client id: the callback's, else the saved one.
    client_id: policy.Required(policy.max_client_id_bytes) = .{},
};

pub const Callback = union(enum) {
    granted: Grant,
    /// The issuer's `error` code, such as `access_denied`.
    refused: policy.Required(max_refusal_bytes),
};

/// Reads the callback for `attempt` from `received`: the request target a
/// loopback listener got (`/auth/callback?...`) or the whole address the user
/// pasted (`http://127.0.0.1:<port>/auth/callback?...`). A paste may carry
/// surrounding whitespace or backticks and `&amp;` for `&`, as a chat app
/// leaves it. The state is checked before anything else the query says. On
/// error `destination` is zeroed.
pub fn parseCallback(attempt: *const Attempt, received: []const u8, destination: *Callback) !void {
    destination.* = .{ .granted = .{} };
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(destination));
    var target = std.mem.trim(u8, received, " \t\r\n`");
    if (!std.mem.startsWith(u8, target, "/")) {
        var origin: [loopback_origin.len + 5]u8 = undefined;
        const expected = std.fmt.bufPrint(&origin, loopback_origin ++ "{d}", .{attempt.port}) catch unreachable;
        if (!std.mem.startsWith(u8, target, expected)) return error.NotCallbackAddress;
        target = target[expected.len..];
    }
    target = target[0 .. std.mem.indexOfScalar(u8, target, '#') orelse target.len];
    const question = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    if (!std.mem.eql(u8, target[0..question], callback_path)) return error.NotCallbackAddress;

    var query: Query = .{};
    var params = std.mem.splitScalar(u8, target[@min(question + 1, target.len)..], '&');
    while (params.next()) |raw| {
        const pair = if (std.mem.startsWith(u8, raw, "amp;")) raw["amp;".len..] else raw;
        if (pair.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const value = pair[@min(equals + 1, pair.len)..];
        inline for (@typeInfo(Query).@"struct".field_names) |name| {
            if (std.mem.eql(u8, pair[0..equals], name)) {
                if (@field(query, name) != null) return error.InvalidCallback;
                @field(query, name) = value;
            }
        }
    }

    var state: [secret_text_len]u8 = undefined;
    const sent_state = try decode(query.state orelse return error.StateMismatch, &state, error.StateMismatch);
    if (!std.mem.eql(u8, sent_state, &attempt.state)) return error.StateMismatch;
    if (query.@"error") |code| {
        destination.* = .{ .refused = .{} };
        destination.refused.len = (try decode(code, &destination.refused.bytes, error.InvalidCallback)).len;
        return;
    }
    const grant = &destination.granted;
    const code = query.code orelse return error.MissingCode;
    if (code.len == 0) return error.MissingCode;
    grant.code.len = (try decode(code, &grant.code.bytes, error.InvalidCallback)).len;
    if (query.client_id) |client_id| {
        grant.client_id.len = (try decode(client_id, &grant.client_id.bytes, error.InvalidCallback)).len;
        // A returning sign-in keeps the client it named; the issuer's guide
        // rejects an answer for another.
        if (attempt.saved_client_id) |saved| if (!std.mem.eql(u8, saved.slice(), grant.client_id.slice()))
            return error.ClientIdMismatch;
    } else {
        const saved = attempt.saved_client_id orelse return error.MissingClientId;
        try grant.client_id.set(saved.slice());
    }
}

/// The request target of the HTTP request a loopback listener has read so
/// far: null until its request line is complete. Only a `GET` can be the
/// callback; any other request is not one.
pub fn requestTarget(received: []const u8) !?[]const u8 {
    const end = std.mem.indexOf(u8, received, "\r\n") orelse {
        if (received.len >= max_request_line_bytes) return error.NotCallbackAddress;
        return null;
    };
    var words = std.mem.splitScalar(u8, received[0..end], ' ');
    const method = words.next().?;
    const target = words.next() orelse return error.NotCallbackAddress;
    const version = words.next() orelse return error.NotCallbackAddress;
    if (!std.mem.eql(u8, method, "GET") or words.next() != null or !std.mem.startsWith(u8, version, "HTTP/1.") or target.len == 0)
        return error.NotCallbackAddress;
    return target;
}

/// The most of a request the listener reads before its request line must
/// have ended: a callback's code, state, scope and client id fit well inside.
pub const max_request_line_bytes = 8 * 1024;

/// The listener's answers to the browser, each one plain line. A failure
/// sends the person back to Rui, whether the command line or the first-run
/// screen is waiting there.
pub const page_signed_in = page("200 OK", "Signed in. You can close this tab.\n");
pub const page_failed = page("400 Bad Request", "Sign-in did not finish. Go back to Rui.\n");
pub const page_not_found = page("404 Not Found", "Not found.\n");

fn page(comptime status: []const u8, comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint("HTTP/1.1 {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{s}", .{ status, body.len, body });
}

/// The callback parameters this flow reads, each borrowing the received text.
const Query = struct {
    code: ?[]const u8 = null,
    state: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// A query value decoded into `out`: `%XX` escapes and `+` for a space. The
/// value must be nonempty printable ASCII once decoded and fit `out`;
/// otherwise `refusal` is returned.
fn decode(value: []const u8, out: []u8, comptime refusal: anyerror) ![]u8 {
    var len: usize = 0;
    var index: usize = 0;
    while (index < value.len) : (len += 1) {
        if (len == out.len) return refusal;
        var byte = value[index];
        if (byte == '%') {
            if (index + 3 > value.len) return refusal;
            byte = std.fmt.parseInt(u8, value[index + 1 .. index + 3], 16) catch return refusal;
            index += 3;
        } else {
            if (byte == '+') byte = ' ';
            index += 1;
        }
        out[len] = byte;
    }
    if (!policy.safeAscii(out[0..len])) return refusal;
    return out[0..len];
}

/// The authorization-code exchange for a granted callback.
pub fn exchangeRequest(attempt: *const Attempt, grant: *const Grant, buffer: []u8) !Request {
    var writer = std.Io.Writer.fixed(buffer);
    writeExchange(&writer, attempt, grant) catch return error.RequestTooLong;
    return .{ .url = token_url, .content_type = codex.form_content, .body = writer.buffered() };
}

fn writeExchange(writer: *std.Io.Writer, attempt: *const Attempt, grant: *const Grant) !void {
    try writer.writeAll("grant_type=authorization_code");
    try param(writer, "&client_id=", grant.client_id.slice());
    try param(writer, "&code=", grant.code.slice());
    try param(writer, "&code_verifier=", &attempt.verifier);
    try redirectParam(writer, "&redirect_uri=", attempt.port);
    try param(writer, "&resource=", resource);
}

/// Room to read one token response into a record: the issuer's parse room
/// and the tokens it carries. Its owner keeps it off the stack.
pub const Scratch = struct {
    wire: codex.Scratch = undefined,
    tokens: codex.Tokens = undefined,
};

/// Builds the record a sign-in installs from the exchange's response, after
/// checking its ID token and granted scope. The record keeps the issued
/// client id, which makes its account the ID token's `sub` and its expiry the
/// access token's (`policy.deriveClaims`). The generation is assigned at
/// admission. On error the record is zeroed; `PlanScopeMissing` means the
/// user signed in but has not let this app use the plan.
pub fn loginRecord(attempt: *const Attempt, grant: *const Grant, status: u16, json: []const u8, now_seconds: i64, record: *policy.Record, scratch: *Scratch) !void {
    defer std.crypto.secureZero(u8, std.mem.asBytes(&scratch.tokens));
    codex.parseTokenResponse(status, json, &scratch.wire.json, &scratch.tokens) catch |err| {
        std.crypto.secureZero(u8, std.mem.asBytes(record));
        return err;
    };
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(record));
    try checkIdToken(scratch.tokens.id_token.slice(), grant.client_id.slice(), &attempt.nonce, now_seconds, &scratch.wire.claims);
    try requirePlanScope(json, &scratch.wire.json);
    record.* = .{ .generation = 0, .account_id = .{}, .id_token = .{}, .access_token = .{}, .refresh_token = .{}, .expires_at = 0, .refreshed_at = now_seconds };
    try record.client_id.set(grant.client_id.slice());
    try record.id_token.set(scratch.tokens.id_token.slice());
    try record.access_token.set(scratch.tokens.access_token.slice());
    try record.refresh_token.set(scratch.tokens.refresh_token.slice());
    try policy.deriveClaims(record, &scratch.wire.claims);
}

/// The ID token must name this issuer, this client and this attempt's nonce,
/// and not have expired. Its signature is not checked: the token comes
/// straight from the issuer's token endpoint over TLS, which OpenID Connect
/// Core 3.1.3.7 accepts in place of a signature.
fn checkIdToken(id_token: []const u8, client_id: []const u8, nonce: []const u8, now_seconds: i64, claims: *policy.ClaimScratch) !void {
    const payload = try policy.tokenPayload(id_token, &claims.decoded);
    defer std.crypto.secureZero(u8, payload);
    defer std.crypto.secureZero(u8, &claims.arena);
    var fixed = std.heap.FixedBufferAllocator.init(&claims.arena);
    const parsed = std.json.parseFromSlice(IdClaims, fixed.allocator(), payload, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidTokenClaims;
    const value = parsed.value;
    if (!std.mem.eql(u8, if (value.iss) |iss| iss.slice else "", issuer)) return error.IdTokenIssuerMismatch;
    const audience: []const json_scalar.Text = if (value.aud) |aud| aud.names else &.{};
    for (audience) |name| {
        if (std.mem.eql(u8, name.slice, client_id)) break;
    } else return error.IdTokenAudienceMismatch;
    if ((if (value.exp) |exp| exp.value else 0) <= now_seconds) return error.IdTokenExpired;
    if (!std.mem.eql(u8, if (value.nonce) |sent| sent.slice else "", nonce)) return error.IdTokenNonceMismatch;
}

const IdClaims = struct {
    iss: ?json_scalar.Text = null,
    aud: ?Audience = null,
    exp: ?json_scalar.Int(i64) = null,
    nonce: ?json_scalar.Text = null,
};

/// OpenID Connect's `aud`: one string, or an array of them.
const Audience = struct {
    names: []const json_scalar.Text,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Audience {
        if (try source.peekNextTokenType() != .string)
            return .{ .names = try std.json.innerParse([]const json_scalar.Text, allocator, source, options) };
        const one = try allocator.alloc(json_scalar.Text, 1);
        one[0] = try json_scalar.Text.jsonParse(allocator, source, options);
        return .{ .names = one };
    }
};

/// A response that names its granted scope must include the plan scope; one
/// that does not granted what was asked (RFC 6749, 5.1).
fn requirePlanScope(json: []const u8, arena: *[codex.wire_arena_bytes]u8) !void {
    defer std.crypto.secureZero(u8, arena);
    var fixed = std.heap.FixedBufferAllocator.init(arena);
    const parsed = std.json.parseFromSlice(struct { scope: ?json_scalar.Text = null }, fixed.allocator(), json, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidTokenResponse;
    const granted = parsed.value.scope orelse return;
    var names = std.mem.tokenizeScalar(u8, granted.slice, ' ');
    while (names.next()) |name| if (std.mem.eql(u8, name, plan_scope)) return;
    return error.PlanScopeMissing;
}

/// The refresh of a claimed record, as its issued client.
pub fn refreshRequest(current: *const policy.Record, buffer: []u8) !Request {
    if (current.client_id.len == 0) return error.MissingClientId;
    var writer = std.Io.Writer.fixed(buffer);
    writeRefresh(&writer, current) catch return error.RequestTooLong;
    return .{ .url = token_url, .content_type = codex.form_content, .body = writer.buffered() };
}

fn writeRefresh(writer: *std.Io.Writer, current: *const policy.Record) !void {
    try writer.writeAll("grant_type=refresh_token");
    try param(writer, "&client_id=", current.client_id.slice());
    try param(writer, "&refresh_token=", current.refresh_token.slice());
    try param(writer, "&resource=", resource);
}

/// Builds the replacement for a claimed plan record from a refresh response.
/// The issuer answers as it answers a Codex refresh (`codex.parseRefreshResponse`:
/// rotated tokens for the same account, or a rejection in
/// `policy.LoginRequired`), and the granted scope must still let the tokens
/// spend the plan, as at sign-in. The replacement keeps the record's issued
/// client id. On error the replacement is zeroed.
pub fn parseRefreshResponse(current: *const policy.Record, status: u16, json: []const u8, refreshed_at: i64, replacement: *policy.Record, scratch: *codex.Scratch) !void {
    try codex.parseRefreshResponse(current, status, json, refreshed_at, replacement, scratch);
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(replacement));
    try requirePlanScope(json, &scratch.json);
}

/// Revokes the record's refresh token, as its issued client.
pub fn revokeRequest(current: *const policy.Record, buffer: []u8) !Request {
    if (current.client_id.len == 0) return error.MissingClientId;
    var writer = std.Io.Writer.fixed(buffer);
    writeRevoke(&writer, current) catch return error.RequestTooLong;
    return .{ .url = revoke_url, .content_type = codex.form_content, .body = writer.buffered() };
}

/// What a revocation's answer means. A 200 is success, even for a token
/// already invalid; a server failure may be retried while the refresh token
/// is still held; any other answer is a refusal.
pub const Revocation = enum { revoked, retry, refused };

pub fn revocation(status: u16) Revocation {
    return switch (status) {
        200 => .revoked,
        429, 500...599 => .retry,
        else => .refused,
    };
}

fn writeRevoke(writer: *std.Io.Writer, current: *const policy.Record) !void {
    try param(writer, "token=", current.refresh_token.slice());
    try param(writer, "&token_type_hint=", "refresh_token");
    try param(writer, "&client_id=", current.client_id.slice());
}

const uuid_prefix = "urn:uuid:";
pub const host_id_len = uuid_prefix.len + 36;

/// The host id this installation names in every sign-in: a version 4 UUID URN
/// spelled from 16 random bytes.
pub fn formatHostId(random: *const [16]u8) [host_id_len]u8 {
    var bytes = random.*;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    var text: [host_id_len]u8 = undefined;
    _ = std.fmt.bufPrint(&text, uuid_prefix ++ "{x}-{x}-{x}-{x}-{x}", .{ bytes[0..4], bytes[4..6], bytes[6..8], bytes[8..10], bytes[10..16] }) catch unreachable;
    return text;
}

/// Accepts exactly what `formatHostId` writes: a lowercase version 4 UUID URN.
pub fn validateHostId(text: []const u8) !void {
    if (text.len != host_id_len or !std.mem.startsWith(u8, text, uuid_prefix)) return error.InvalidHostId;
    const uuid = text[uuid_prefix.len..];
    for (uuid, 0..) |byte, index| switch (index) {
        8, 13, 18, 23 => if (byte != '-') return error.InvalidHostId,
        else => if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidHostId,
    };
    if (uuid[14] != '4' or std.mem.indexOfScalar(u8, "89ab", uuid[19]) == null) return error.InvalidHostId;
}

/// The model IDs a plan's list (`{"models":[{"slug":...,"visibility":...},...]}`)
/// offers for picking, in the server's order, written to `out` under
/// `model_list`'s bounds. Only an entry whose `visibility` is `"list"` is
/// offered; every entry names its `slug`. `scratch` holds the parse and is
/// freed by the caller.
pub fn parseModels(scratch: std.mem.Allocator, body: []const u8, out: *model_list.IdBuffer) !model_list.Ids {
    // A token walk, as `model_list.parseOpenAi`'s: other members are skipped
    // unread, so no number is ever converted.
    var scanner: std.json.Scanner = .initCompleteInput(scratch, body);
    var kept: model_list.Kept = .{ .out = out };
    var models_seen = false;
    if (try model_list.nextToken(&scanner, scratch) != .object_begin) return error.InvalidModelList;
    while (try model_list.objectKey(&scanner, scratch)) |key| {
        if (!std.mem.eql(u8, key, "models")) {
            scanner.skipValue() catch return error.InvalidModelList;
            continue;
        }
        models_seen = true;
        if (try model_list.nextToken(&scanner, scratch) != .array_begin) return error.InvalidModelList;
        while (true) {
            switch (try model_list.nextToken(&scanner, scratch)) {
                .array_end => break,
                .object_begin => {},
                else => return error.InvalidModelList,
            }
            var slug: ?[]const u8 = null;
            var listed = false;
            while (try model_list.objectKey(&scanner, scratch)) |member| {
                const field: enum { slug, visibility } = if (std.mem.eql(u8, member, "slug")) .slug else if (std.mem.eql(u8, member, "visibility")) .visibility else {
                    scanner.skipValue() catch return error.InvalidModelList;
                    continue;
                };
                const text = switch (try model_list.nextToken(&scanner, scratch)) {
                    .string, .allocated_string => |text| text,
                    else => return error.InvalidModelList,
                };
                switch (field) {
                    .slug => slug = text,
                    .visibility => listed = std.mem.eql(u8, text, "list"),
                }
            }
            const entry = slug orelse return error.InvalidModelList;
            if (listed) try kept.keep(entry);
        }
    }
    if (!models_seen or try model_list.nextToken(&scanner, scratch) != .end_of_document) return error.InvalidModelList;
    return kept.ids();
}

const test_host_id = "urn:uuid:00010203-0405-4607-8809-0a0b0c0d0e0f";
const test_client_id = "oaiapp_test_client";
/// RFC 7636, appendix B: the verifier's octets, its text and its S256 challenge.
const rfc_verifier_bytes = [_]u8{ 116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186, 22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121 };
const rfc_verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
const rfc_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
const zero_state: [secret_text_len]u8 = @splat('A');
const ones_nonce = @as([secret_text_len - 1]u8, @splat('_')) ++ "8";

fn testRandom() [random_bytes]u8 {
    return @as([secret_bytes]u8, @splat(0)) ++ @as([secret_bytes]u8, @splat(0xff)) ++ rfc_verifier_bytes;
}

fn testAttempt(saved: ?*const policy.Record, attempt: *Attempt) !void {
    var url: [4096]u8 = undefined;
    _ = try authorize(&testRandom(), 1455, test_host_id, saved, attempt, &url);
}

/// A compact token whose payload is `claims`, written into `buffer`.
fn testToken(claims: []const u8, buffer: []u8) []const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const header = "e30.";
    @memcpy(buffer[0..header.len], header);
    const payload = encoder.encode(buffer[header.len..], claims);
    const end = header.len + payload.len;
    @memcpy(buffer[end..][0..".c2ln".len], ".c2ln");
    return buffer[0 .. end + ".c2ln".len];
}

/// A compact token whose payload is `claims`, built at compile time.
fn compactToken(comptime claims: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        const encoder = std.base64.url_safe_no_pad.Encoder;
        var payload: [encoder.calcSize(claims.len)]u8 = undefined;
        _ = encoder.encode(&payload, claims);
        const token = "e30." ++ payload ++ ".c2ln";
        return token;
    }
}

/// Made-up ID token claims shaped like the issuer's: the auth object holds no
/// account claim, and a refreshed token has no nonce.
const plan_subject = "user-made-up-1";
fn planClaims(comptime sub: []const u8, comptime nonce_claim: []const u8) []const u8 {
    return "{\"iss\":\"https://auth.openai.com\",\"sub\":\"" ++ sub ++ "\",\"aud\":[\"" ++ test_client_id ++ "\"]," ++ nonce_claim ++
        "\"auth_time\":1700000000,\"email\":\"someone@example.com\",\"email_verified\":true,\"name\":\"Some One\",\"sid\":\"sid-made-up\"," ++
        "\"https://api.openai.com/auth\":{\"per_user_salt\":\"salt-made-up\"},\"iat\":1800000000,\"exp\":1800000001,\"jti\":\"jti-made-up\",\"at_hash\":\"hash-made-up\"}";
}
const signed_in_claims = planClaims(plan_subject, "\"nonce\":\"" ++ ones_nonce ++ "\",");
const refreshed_id_token = compactToken(planClaims(plan_subject, ""));

fn testSavedRecord(record: *policy.Record) !void {
    record.* = .{ .generation = 4, .account_id = .{}, .id_token = .{}, .access_token = .{}, .refresh_token = .{}, .expires_at = 4_102_444_800, .refreshed_at = 100 };
    try record.account_id.set(plan_subject);
    try record.client_id.set(test_client_id);
    try record.id_token.set(refreshed_id_token);
    try record.access_token.set(policy.fixture_access_token);
    try record.refresh_token.set("refresh-old");
}

test "the authorization address names the first or the saved client" {
    var attempt: Attempt = undefined;
    var url: [4096]u8 = undefined;
    const tail = "&ext_agent_host_id=urn%3Auuid%3A00010203-0405-4607-8809-0a0b0c0d0e0f&response_type=code" ++
        "&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback" ++
        "&scope=openid%20profile%20email%20offline_access%20resource.invoke%20chatgpt.tokens.use.direct" ++
        "&resource=https%3A%2F%2Fapi.openai.com%2Fv1&state=" ++ zero_state ++ "&nonce=" ++ ones_nonce ++
        "&code_challenge_method=S256&code_challenge=" ++ rfc_challenge;
    try std.testing.expectEqualStrings(
        "https://auth.openai.com/api/accounts/authorize?client_id=dynamic_agent_client&agent_name_hint=Rui" ++ tail,
        try authorize(&testRandom(), 1455, test_host_id, null, &attempt, &url),
    );
    try std.testing.expectEqualStrings(&zero_state, &attempt.state);
    try std.testing.expectEqualStrings(ones_nonce, &attempt.nonce);
    try std.testing.expectEqualStrings(rfc_verifier, &attempt.verifier);
    try std.testing.expectEqual(@as(?ClientId, null), attempt.saved_client_id);

    var saved: policy.Record = undefined;
    try testSavedRecord(&saved);
    // A returning sign-in names its issued client, no agent and no token,
    // whether its record is signed in or out.
    const returning = "https://auth.openai.com/api/accounts/authorize?client_id=" ++ test_client_id ++ tail;
    try std.testing.expectEqualStrings(returning, try authorize(&testRandom(), 1455, test_host_id, &saved, &attempt, &url));
    try std.testing.expectEqualStrings(test_client_id, attempt.saved_client_id.?.slice());
    try std.testing.expect(std.mem.indexOf(u8, returning, "e30.") == null);
    var signed_out = saved;
    try policy.signOut(&signed_out);
    try std.testing.expectEqualStrings(returning, try authorize(&testRandom(), 1455, test_host_id, &signed_out, &attempt, &url));
    // Only the port varies in the redirect address.
    try std.testing.expect(std.mem.indexOf(u8, try authorize(&testRandom(), 50001, test_host_id, null, &attempt, &url), "127.0.0.1%3A50001%2Fauth%2Fcallback&") != null);

    // A saved record without an issued client, a bad host id or a short
    // buffer leaves no attempt behind.
    saved.client_id.wipe();
    try std.testing.expectError(error.MissingClientId, authorize(&testRandom(), 1455, test_host_id, &saved, &attempt, &url));
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&attempt), 0));
    try std.testing.expectError(error.InvalidHostId, authorize(&testRandom(), 1455, "urn:uuid:x", null, &attempt, &url));
    try std.testing.expectError(error.RequestTooLong, authorize(&testRandom(), 1455, test_host_id, null, &attempt, url[0..200]));
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&attempt), 0));
}

test "a callback yields the code and issued client id from a listener or a paste" {
    var attempt: Attempt = undefined;
    try testAttempt(null, &attempt);
    var callback: Callback = undefined;
    const query = "?code=ac_made%2Dup%2Bcode&scope=openid+profile&state=" ++ zero_state ++ "&client_id=oaiapp_issued";
    inline for (.{
        "/auth/callback" ++ query,
        "http://127.0.0.1:1455/auth/callback" ++ query ++ "#fragment",
        // As a chat app hands the address back.
        " \t`http://127.0.0.1:1455/auth/callback?code=ac_made%2Dup%2Bcode&amp;scope=openid+profile&amp;state=" ++ zero_state ++ "&amp;client_id=oaiapp_issued`\n",
    }) |received| {
        try parseCallback(&attempt, received, &callback);
        try std.testing.expectEqualStrings("ac_made-up+code", callback.granted.code.slice());
        try std.testing.expectEqualStrings("oaiapp_issued", callback.granted.client_id.slice());
    }
    // A returning sign-in may get no client id back and keeps its saved one.
    var saved: policy.Record = undefined;
    try testSavedRecord(&saved);
    var returning: Attempt = undefined;
    try testAttempt(&saved, &returning);
    try parseCallback(&returning, "/auth/callback?code=c&state=" ++ zero_state, &callback);
    try std.testing.expectEqualStrings(test_client_id, callback.granted.client_id.slice());
    try parseCallback(&returning, "/auth/callback?code=c&state=" ++ zero_state ++ "&client_id=" ++ test_client_id, &callback);
    try std.testing.expectEqualStrings(test_client_id, callback.granted.client_id.slice());
    // An answer for another client is not this sign-in's.
    try std.testing.expectError(error.ClientIdMismatch, parseCallback(&returning, "/auth/callback?code=c&state=" ++ zero_state ++ "&client_id=oaiapp_new", &callback));
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&callback), 0));
    // The issuer's refusal carries its code.
    try parseCallback(&attempt, "/auth/callback?error=access_denied&error_description=No+thanks&state=" ++ zero_state, &callback);
    try std.testing.expectEqualStrings("access_denied", callback.refused.slice());
}

test "a callback that is not this attempt's grant is refused by cause" {
    var attempt: Attempt = undefined;
    try testAttempt(null, &attempt);
    var callback: Callback = undefined;
    const state = "&state=" ++ zero_state;
    for ([_]struct { []const u8, anyerror }{
        .{ "/auth/other?code=c&client_id=x" ++ state, error.NotCallbackAddress },
        .{ "/auth/callback/x?code=c&client_id=x" ++ state, error.NotCallbackAddress },
        .{ "http://localhost:1455/auth/callback?code=c&client_id=x" ++ state, error.NotCallbackAddress },
        .{ "http://127.0.0.1:1456/auth/callback?code=c&client_id=x" ++ state, error.NotCallbackAddress },
        .{ "auth/callback?code=c&client_id=x" ++ state, error.NotCallbackAddress },
        .{ "/auth/callback?code=c&client_id=x", error.StateMismatch },
        .{ "/auth/callback?code=c&client_id=x&state=" ++ ones_nonce, error.StateMismatch },
        .{ "/auth/callback?code=c&client_id=x&state=", error.StateMismatch },
        // The state is checked before a refusal is believed.
        .{ "/auth/callback?error=access_denied&state=AAAA", error.StateMismatch },
        .{ "/auth/callback?client_id=x" ++ state, error.MissingCode },
        .{ "/auth/callback?code=&client_id=x" ++ state, error.MissingCode },
        .{ "/auth/callback?code=c" ++ state, error.MissingClientId },
        .{ "/auth/callback?code=c&code=d&client_id=x" ++ state, error.InvalidCallback },
        .{ "/auth/callback?code=%2&client_id=x" ++ state, error.InvalidCallback },
        .{ "/auth/callback?code=a%0Ab&client_id=x" ++ state, error.InvalidCallback },
        // A raw `+` is a space, which no code or client id holds.
        .{ "/auth/callback?code=a+b&client_id=x" ++ state, error.InvalidCallback },
        .{ "/auth/callback?code=c&client_id=" ++ state, error.InvalidCallback },
        .{ "/auth/callback?error=&client_id=x" ++ state, error.InvalidCallback },
    }) |case| {
        try std.testing.expectError(case[1], parseCallback(&attempt, case[0], &callback));
        try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&callback), 0));
    }
    var long: [max_code_bytes + 128]u8 = undefined;
    const overlong = try std.fmt.bufPrint(&long, "/auth/callback?code={s}&client_id=x" ++ state, .{&@as([max_code_bytes + 1]u8, @splat('c'))});
    try std.testing.expectError(error.InvalidCallback, parseCallback(&attempt, overlong, &callback));
}

test "the exchange, refresh and revocation requests are the issued client's forms" {
    var attempt: Attempt = undefined;
    try testAttempt(null, &attempt);
    var grant: Grant = .{};
    try grant.code.set("ac_made-up/code");
    try grant.client_id.set(test_client_id);
    var buffer: [1024]u8 = undefined;
    const exchange = try exchangeRequest(&attempt, &grant, &buffer);
    try std.testing.expectEqualStrings("https://auth.openai.com/api/accounts/oauth/token", exchange.url);
    try std.testing.expectEqualStrings("application/x-www-form-urlencoded", exchange.content_type);
    try std.testing.expectEqualStrings("grant_type=authorization_code&client_id=" ++ test_client_id ++ "&code=ac_made-up%2Fcode&code_verifier=" ++ rfc_verifier ++
        "&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&resource=https%3A%2F%2Fapi.openai.com%2Fv1", exchange.body);
    try std.testing.expectError(error.RequestTooLong, exchangeRequest(&attempt, &grant, buffer[0..40]));

    var record: policy.Record = undefined;
    try testSavedRecord(&record);
    try record.refresh_token.set("rt_made+up");
    const refresh = try refreshRequest(&record, &buffer);
    try std.testing.expectEqualStrings("https://auth.openai.com/api/accounts/oauth/token", refresh.url);
    try std.testing.expectEqualStrings("application/x-www-form-urlencoded", refresh.content_type);
    try std.testing.expectEqualStrings("grant_type=refresh_token&client_id=" ++ test_client_id ++ "&refresh_token=rt_made%2Bup&resource=https%3A%2F%2Fapi.openai.com%2Fv1", refresh.body);
    const revoke = try revokeRequest(&record, &buffer);
    try std.testing.expectEqualStrings("https://auth.openai.com/api/accounts/oauth/revoke", revoke.url);
    try std.testing.expectEqualStrings("application/x-www-form-urlencoded", revoke.content_type);
    try std.testing.expectEqualStrings("token=rt_made%2Bup&token_type_hint=refresh_token&client_id=" ++ test_client_id, revoke.body);
    try std.testing.expectError(error.RequestTooLong, refreshRequest(&record, buffer[0..40]));
    try std.testing.expectError(error.RequestTooLong, revokeRequest(&record, buffer[0..20]));
    // A Codex record has no issued client to speak for.
    record.client_id.wipe();
    try std.testing.expectError(error.MissingClientId, refreshRequest(&record, &buffer));
    try std.testing.expectError(error.MissingClientId, revokeRequest(&record, &buffer));
}

/// An exchange response whose ID token carries `claims`.
fn testResponse(claims: []const u8, scope_field: []const u8, buffer: []u8) ![]const u8 {
    var token: [1024]u8 = undefined;
    return std.fmt.bufPrint(buffer, "{{\"access_token\":\"{s}\",\"id_token\":\"{s}\",\"refresh_token\":\"rt_made_up\",\"expires_in\":3600,\"token_type\":\"Bearer\"{s}}}", .{ policy.fixture_access_token, testToken(claims, &token), scope_field });
}

const granted_scope = ",\"scope\":\"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct\"";

test "a token response becomes a record only for this issuer, client, nonce and plan" {
    var attempt: Attempt = undefined;
    try testAttempt(null, &attempt);
    var grant: Grant = .{};
    try grant.code.set("ac_made_up");
    try grant.client_id.set(test_client_id);
    var room: Scratch = undefined;
    const scratch = &room;
    var record: policy.Record = undefined;
    var json: [2048]u8 = undefined;
    const now: i64 = 1_800_000_000;
    const good = signed_in_claims;
    try loginRecord(&attempt, &grant, 200, try testResponse(good, granted_scope, &json), now, &record, scratch);
    try std.testing.expectEqualStrings(test_client_id, record.client_id.slice());
    try std.testing.expectEqualStrings(plan_subject, record.account_id.slice());
    try std.testing.expect(!record.fedramp);
    try std.testing.expectEqualStrings("rt_made_up", record.refresh_token.slice());
    try std.testing.expectEqual(@as(i64, 4_102_444_800), record.expires_at);
    try std.testing.expectEqual(now, record.refreshed_at);
    try std.testing.expectEqual(@as(u64, 0), record.generation);
    try policy.validateSelected(&record, false, &scratch.wire.claims);
    // The record round-trips through the credential file with its client id.
    var file: [policy.max_file_bytes]u8 = undefined;
    var decoded: policy.Record = undefined;
    try policy.parseInto(try policy.encode(&record, &file), &decoded);
    try std.testing.expectEqualStrings(test_client_id, decoded.client_id.slice());
    try std.testing.expectEqualStrings(record.id_token.slice(), decoded.id_token.slice());
    // A single audience string and an absent scope, which grants what was asked, pass.
    const single = "{\"iss\":\"https://auth.openai.com\",\"aud\":\"" ++ test_client_id ++ "\",\"exp\":1800000001,\"nonce\":\"" ++ ones_nonce ++ "\",\"sub\":\"" ++ plan_subject ++ "\"}";
    try loginRecord(&attempt, &grant, 200, try testResponse(single, "", &json), now, &record, scratch);

    for ([_]struct { []const u8, []const u8, anyerror }{
        .{ "{\"iss\":\"https://auth.openai.com/\",\"aud\":\"" ++ test_client_id ++ "\",\"exp\":1800000001,\"nonce\":\"" ++ ones_nonce ++ "\"}", granted_scope, error.IdTokenIssuerMismatch },
        .{ "{\"aud\":\"" ++ test_client_id ++ "\",\"exp\":1800000001,\"nonce\":\"" ++ ones_nonce ++ "\"}", granted_scope, error.IdTokenIssuerMismatch },
        .{ "{\"iss\":\"https://auth.openai.com\",\"aud\":[\"oaiapp_other\",\"dynamic_agent_client\"],\"exp\":1800000001,\"nonce\":\"" ++ ones_nonce ++ "\"}", granted_scope, error.IdTokenAudienceMismatch },
        .{ "{\"iss\":\"https://auth.openai.com\",\"exp\":1800000001,\"nonce\":\"" ++ ones_nonce ++ "\"}", granted_scope, error.IdTokenAudienceMismatch },
        .{ "{\"iss\":\"https://auth.openai.com\",\"aud\":\"" ++ test_client_id ++ "\",\"exp\":1800000000,\"nonce\":\"" ++ ones_nonce ++ "\"}", granted_scope, error.IdTokenExpired },
        .{ "{\"iss\":\"https://auth.openai.com\",\"aud\":\"" ++ test_client_id ++ "\",\"nonce\":\"" ++ ones_nonce ++ "\"}", granted_scope, error.IdTokenExpired },
        .{ "{\"iss\":\"https://auth.openai.com\",\"aud\":\"" ++ test_client_id ++ "\",\"exp\":1800000001,\"nonce\":\"" ++ zero_state ++ "\"}", granted_scope, error.IdTokenNonceMismatch },
        .{ "{\"iss\":\"https://auth.openai.com\",\"aud\":\"" ++ test_client_id ++ "\",\"exp\":1800000001}", granted_scope, error.IdTokenNonceMismatch },
        .{ "{\"iss\":7}", granted_scope, error.InvalidTokenClaims },
        .{ good, ",\"scope\":\"openid profile email offline_access resource.invoke\"", error.PlanScopeMissing },
        .{ good, ",\"scope\":\"chatgpt.tokens.use.direct.extra\"", error.PlanScopeMissing },
        // A ChatGPT account claim does not stand in for the subject.
        .{ "{\"iss\":\"https://auth.openai.com\",\"aud\":\"" ++ test_client_id ++ "\",\"exp\":1800000001,\"nonce\":\"" ++ ones_nonce ++ "\",\"chatgpt_account_id\":\"acct\"}", granted_scope, error.MissingAccountClaim },
    }) |case| {
        try std.testing.expectError(case[2], loginRecord(&attempt, &grant, 200, try testResponse(case[0], case[1], &json), now, &record, scratch));
        try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&record), 0));
    }
    try std.testing.expectError(error.TokenExchangeRejected, loginRecord(&attempt, &grant, 400, "{\"error\":\"invalid_grant\"}", now, &record, scratch));
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&record), 0));
    try std.testing.expectError(error.MissingRefreshToken, loginRecord(&attempt, &grant, 200, "{\"id_token\":\"x\",\"access_token\":\"y\"}", now, &record, scratch));
}

test "a refresh rotates the plan record's tokens and keeps its client" {
    var room: Scratch = undefined;
    const scratch = &room;
    var current: policy.Record = undefined;
    try testSavedRecord(&current);
    current.state = .refresh_pending;
    var replacement: policy.Record = undefined;
    try parseRefreshResponse(&current, 200, "{\"access_token\":\"" ++ policy.fixture_access_token ++ "\",\"refresh_token\":\"refresh-new\",\"scope\":\"" ++ scope ++ "\"}", 77, &replacement, &scratch.wire);
    try std.testing.expectEqualStrings("refresh-new", replacement.refresh_token.slice());
    try std.testing.expectEqualStrings(test_client_id, replacement.client_id.slice());
    try std.testing.expectEqual(@as(u64, 5), try policy.admitReplacement(&current, &replacement, 4));
    // A rotated ID token, without a nonce, for the same subject is taken.
    const rotated = comptime compactToken(planClaims(plan_subject, "\"amr\":[\"pwd\"],"));
    try parseRefreshResponse(&current, 200, "{\"id_token\":\"" ++ rotated ++ "\"}", 78, &replacement, &scratch.wire);
    try std.testing.expectEqualStrings(rotated, replacement.id_token.slice());
    try std.testing.expectEqualStrings(plan_subject, replacement.account_id.slice());
    try std.testing.expectEqual(@as(u64, 5), try policy.admitReplacement(&current, &replacement, 4));
    // Another subject is another account; a Codex-shaped token names none.
    try std.testing.expectError(error.AccountChanged, parseRefreshResponse(&current, 200, "{\"id_token\":\"" ++ comptime compactToken(planClaims("user-made-up-2", "")) ++ "\"}", 78, &replacement, &scratch.wire));
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&replacement), 0));
    try std.testing.expectError(error.MissingAccountClaim, parseRefreshResponse(&current, 200, "{\"id_token\":\"" ++ policy.fixture_id_token ++ "\"}", 78, &replacement, &scratch.wire));
    inline for (.{
        .{ "{\"error\":\"refresh_token_expired\"}", error.RefreshTokenExpired },
        .{ "{\"error\":{\"code\":\"refresh_token_reused\"}}", error.RefreshTokenReused },
        .{ "{\"code\":\"refresh_token_invalidated\"}", error.RefreshTokenInvalidated },
        .{ "{\"error\":\"invalid_grant\"}", error.RefreshRejected },
    }) |case| {
        try std.testing.expectError(case[1], parseRefreshResponse(&current, 401, case[0], 77, &replacement, &scratch.wire));
        try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&replacement), 0));
        // Each is a failure only a new sign-in resolves.
        const required: policy.LoginRequired = case[1];
        try std.testing.expectEqual(@as(anyerror, case[1]), required);
    }
}

test "each record validates by its own kind's account claim" {
    var claims: policy.ClaimScratch = undefined;
    // A Codex record: the ChatGPT account claim, read without a client id.
    var codex_record: policy.Record = undefined;
    try testSavedRecord(&codex_record);
    codex_record.client_id.wipe();
    try codex_record.account_id.set(policy.fixture_account_id);
    try codex_record.id_token.set(policy.fixture_id_token);
    try policy.validateSelected(&codex_record, false, &claims);
    // Read as a plan record, its token has no subject.
    try codex_record.client_id.set(test_client_id);
    try std.testing.expectError(error.MissingAccountClaim, policy.validateSelected(&codex_record, false, &claims));

    // A plan record: the subject, through every check that reads the tokens.
    var plan: policy.Record = undefined;
    try testSavedRecord(&plan);
    try policy.validateSelected(&plan, false, &claims);
    try std.testing.expectEqual(policy.Selection.use, try policy.select(&plan, false, 0, &claims));
    try policy.launchCheck(&plan, false, 0, &claims);
    try std.testing.expectEqual(policy.LocalStatus.configured, try policy.localStatus(&plan, 0, &claims));
    try plan.account_id.set("user-made-up-2");
    try std.testing.expectError(error.AccountMismatch, policy.validateSelected(&plan, false, &claims));
    try std.testing.expectError(error.AccountMismatch, policy.select(&plan, false, 0, &claims));
    try std.testing.expectError(error.AccountMismatch, policy.launchCheck(&plan, false, 0, &claims));
    try std.testing.expectError(error.AccountMismatch, policy.localStatus(&plan, 0, &claims));
    try plan.account_id.set(plan_subject);
    plan.fedramp = true;
    try std.testing.expectError(error.AccountMismatch, policy.validateSelected(&plan, false, &claims));
    // Read as a Codex record, the plan token names no account.
    plan.fedramp = false;
    plan.client_id.wipe();
    try std.testing.expectError(error.MissingAccountClaim, policy.validateSelected(&plan, false, &claims));
}

test "sign-in and refresh accept a granted scope only with the plan scope" {
    var attempt: Attempt = undefined;
    try testAttempt(null, &attempt);
    var grant: Grant = .{};
    try grant.code.set("ac_made_up");
    try grant.client_id.set(test_client_id);
    var room: Scratch = undefined;
    var current: policy.Record = undefined;
    try testSavedRecord(&current);
    current.state = .refresh_pending;
    var record: policy.Record = undefined;
    var json: [2048]u8 = undefined;
    for ([_]struct { []const u8, ?anyerror }{
        // Absent: granted as asked (RFC 6749, 5.1).
        .{ "", null },
        .{ granted_scope, null },
        .{ ",\"scope\":\"openid profile email offline_access resource.invoke\"", error.PlanScopeMissing },
    }) |case| {
        const response = try testResponse(signed_in_claims, case[0], &json);
        const login = loginRecord(&attempt, &grant, 200, response, 1_800_000_000, &record, &room);
        const renewal = parseRefreshResponse(&current, 200, response, 77, &record, &room.wire);
        if (case[1]) |failure| {
            try std.testing.expectError(failure, login);
            try std.testing.expectError(failure, renewal);
            try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&record), 0));
            // A sign-in failure, distinct from one a new sign-in alone resolves.
            const required: policy.LoginRequired = error.PlanScopeMissing;
            try std.testing.expectEqualStrings("provider_sign_in_plan_scope_missing", policy.failureCode(required));
        } else {
            try login;
            try renewal;
            try std.testing.expectEqualStrings("rt_made_up", record.refresh_token.slice());
        }
    }
}

test "the listener reads a GET's target once its request line ends" {
    try std.testing.expectEqualStrings("/auth/callback?code=c", (try requestTarget("GET /auth/callback?code=c HTTP/1.1\r\nHost: 127.0.0.1\r\n")).?);
    try std.testing.expectEqualStrings("/favicon.ico", (try requestTarget("GET /favicon.ico HTTP/1.0\r\n")).?);
    // Not yet a whole line: wait for more.
    for ([_][]const u8{ "", "GET /auth/callback?code=c HTTP/1.1", "GET /auth/callback?code=c HTTP/1.1\r" }) |partial|
        try std.testing.expectEqual(@as(?[]const u8, null), try requestTarget(partial));
    for ([_][]const u8{
        "POST /auth/callback HTTP/1.1\r\n",
        "GET /auth/callback\r\n",
        "GET  HTTP/1.1\r\n",
        "GET /a b HTTP/1.1\r\n",
        "GET /auth/callback HTTP/2\r\n",
        "\r\n",
    }) |refused| try std.testing.expectError(error.NotCallbackAddress, requestTarget(refused));
    // A request line that never ends within the bound is not a callback.
    const endless: [max_request_line_bytes]u8 = @splat('a');
    try std.testing.expectEqual(@as(?[]const u8, null), try requestTarget(endless[0 .. endless.len - 1]));
    try std.testing.expectError(error.NotCallbackAddress, requestTarget(&endless));
}

test "a revocation is confirmed only by a 200, and retried only after a server failure" {
    var status: u16 = 100;
    while (status < 600) : (status += 1) {
        const expected: Revocation = if (status == 200) .revoked else if (status == 429 or status >= 500) .retry else .refused;
        try std.testing.expectEqual(expected, revocation(status));
    }
}

test "the listener's pages are one plain line each" {
    for ([_][]const u8{ page_signed_in, page_failed, page_not_found }) |answer| {
        const head_end = std.mem.indexOf(u8, answer, "\r\n\r\n").? + 4;
        const body = answer[head_end..];
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "\n"));
        try std.testing.expect(std.mem.endsWith(u8, body, "\n"));
        var length: [32]u8 = undefined;
        try std.testing.expect(std.mem.indexOf(u8, answer[0..head_end], try std.fmt.bufPrint(&length, "Content-Length: {d}\r\n", .{body.len})) != null);
        // The screen and the command line both wait on a login; no page
        // names only one of them.
        try std.testing.expect(std.mem.indexOf(u8, body, "terminal") == null);
    }
}

test "a host id is a lowercase version 4 UUID URN" {
    var random: [16]u8 = undefined;
    for (&random, 0..) |*byte, index| byte.* = @intCast(index);
    const formatted = formatHostId(&random);
    try std.testing.expectEqualStrings(test_host_id, &formatted);
    try validateHostId(&formatted);
    @memset(&random, 0xff);
    try std.testing.expectEqualStrings("urn:uuid:ffffffff-ffff-4fff-bfff-ffffffffffff", &formatHostId(&random));
    for ([_][]const u8{
        "",
        "00010203-0405-4607-8809-0a0b0c0d0e0f",
        "urn:uuid:00010203-0405-4607-8809-0a0b0c0d0e0f\n",
        "urn:uuid:00010203-0405-4607-8809-0A0B0C0D0E0F",
        "urn:uuid:00010203-0405-1607-8809-0a0b0c0d0e0f",
        "urn:uuid:00010203-0405-4607-c809-0a0b0c0d0e0f",
        "urn:uuid:00010203x0405-4607-8809-0a0b0c0d0e0f",
        "urn:uuid:0001020g-0405-4607-8809-0a0b0c0d0e0f",
        "URN:UUID:00010203-0405-4607-8809-0a0b0c0d0e0f",
    }) |text| try std.testing.expectError(error.InvalidHostId, validateHostId(text));
}

test "a plan's model list offers listed slugs in the server's order and skips other members unread" {
    var out: model_list.IdBuffer = undefined;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Shaped like the server's: nested objects and arrays, numbers and
    // fields in any order.
    const body =
        \\{"models":[
        \\{"slug":"gpt-6-sol","display_name":"Sol","visibility":"list","context_window":400000,"supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}],"auto_compact_token_limit":1.5e5},
        \\{"visibility":"hide","slug":"gpt-6-hidden"},
        \\{"slug":"gpt-6-quiet"},
        \\{"visibility":"list","slug":"gpt-5.5","extra":{"slug":"nested-not-kept","visibility":"list","models":[]}},
        \\{"slug":"has space","visibility":"list"},
        \\{"slug":"a\/b","visibility":"list"},
        \\{"slug":"gpt-6-luna","visibility":"LIST"}
        \\],"etag":"made-up"}
    ;
    try std.testing.expectEqualStrings("gpt-6-sol\ngpt-5.5\na/b\n", (try parseModels(a, body, &out)).bytes);
    try std.testing.expectEqualStrings("", (try parseModels(a, "{\"models\":[]}", &out)).bytes);
    for ([_][]const u8{
        // The OpenAI API's shape is not a plan's.
        "{\"object\":\"list\",\"data\":[{\"id\":\"gpt-6-sol\"}]}",
        "{\"models\":[{\"slug\":7,\"visibility\":\"list\"}]}",
        "{\"models\":[{\"slug\":null,\"visibility\":\"list\"}]}",
        "{\"models\":[{\"slug\":\"gpt-6-sol\",\"visibility\":true}]}",
        "{\"models\":[{\"visibility\":\"list\"}]}",
        "{\"models\":[\"gpt-6-sol\"]}",
        "{\"models\":{}}",
        "{\"models\":[]} {}",
        "{\"models\":[]}x",
        "[]",
        "<html>",
        "",
    }) |refused| try std.testing.expectError(error.InvalidModelList, parseModels(a, refused, &out));
}

test "a plan's model list past either bound is refused, not cut" {
    var out: model_list.IdBuffer = undefined;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var body: std.Io.Writer.Allocating = .init(arena.allocator());
    try body.writer.writeAll("{\"models\":[");
    for (0..model_list.max_live_models) |index| try body.writer.print("{s}{{\"slug\":\"m{d}\",\"visibility\":\"list\"}}", .{ if (index == 0) "" else ",", index });
    // Hidden entries do not count toward the bound.
    try body.writer.writeAll(",{\"slug\":\"hidden\",\"visibility\":\"hide\"}]}");
    try std.testing.expectEqual(@as(usize, model_list.max_live_models), std.mem.count(u8, (try parseModels(arena.allocator(), body.written(), &out)).bytes, "\n"));
    const one_more = try std.mem.concat(arena.allocator(), u8, &.{ body.written()[0 .. body.written().len - 2], ",{\"slug\":\"x\",\"visibility\":\"list\"}]}" });
    try std.testing.expectError(error.ModelListTooLarge, parseModels(arena.allocator(), one_more, &out));

    // Exactly the byte bound fits: 64 IDs of 256 bytes are 16 KiB.
    body.clearRetainingCapacity();
    try body.writer.writeAll("{\"models\":[");
    for (0..64) |index| try body.writer.print("{s}{{\"visibility\":\"list\",\"slug\":\"{d:0>256}\"}}", .{ if (index == 0) "" else ",", index });
    try body.writer.writeAll("]}");
    try std.testing.expectEqual(@as(usize, 64 * 257), (try parseModels(arena.allocator(), body.written(), &out)).bytes.len);
    const more = try std.mem.concat(arena.allocator(), u8, &.{ body.written()[0 .. body.written().len - 2], ",{\"slug\":\"x\",\"visibility\":\"list\"}]}" });
    try std.testing.expectError(error.ModelListTooLarge, parseModels(arena.allocator(), more, &out));
}
