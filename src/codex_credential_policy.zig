//! Codex credential values and the decisions made about them.
//!
//! Records, their file format, decoded routing claims, the refresh, launch
//! and replacement decisions and the user-facing failure class live here as
//! values and pure functions.
//! The caller supplies the clock reading and the record it read. File
//! ownership, the cross-process lock, publication and the token exchange
//! stay in `codex_credentials.zig` and `codex_auth.zig`. See ARCHITECTURE.md,
//! "Authentication and transport lifetime".
const std = @import("std");

pub const max_account_id_bytes = 1024;
pub const max_token_bytes = 16 * 1024;
pub const max_file_bytes = 64 * 1024;

/// Runtime refreshes a compact token this long before its encoded expiry so
/// an acquired lease is not already stale at launch. Local status reports
/// renewal only once the token has expired.
pub const launch_refresh_margin_seconds: i64 = 60;
/// Opaque access tokens carry no expiry; refresh this long after the last
/// successful exchange.
pub const opaque_refresh_seconds: i64 = 8 * 24 * 60 * 60;

// The fixture token cannot originate from Rui login. Only the explicit
// test-only managed endpoint may receive this exact canary.
pub const fixture_access_token = "e30.eyJleHAiOjQxMDI0NDQ4MDB9.c2ln";
pub const fixture_id_token = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJydWktdGVzdC1hY2NvdW50In0.c2ln";
pub const fixture_fedramp_id_token = "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoicnVpLXRlc3QtYWNjb3VudCIsImNoYXRncHRfYWNjb3VudF9pc19mZWRyYW1wIjp0cnVlfX0.c2ln";
pub const fixture_account_id = "rui-test-account";

pub fn isFixtureId(id_token: []const u8) bool {
    return std.mem.eql(u8, id_token, fixture_id_token) or
        std.mem.eql(u8, id_token, fixture_fedramp_id_token);
}

/// Bounded storage for a credential record field; empty values are allowed
/// here and rejected by record validation.
pub fn Bounded(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *@This(), value: []const u8) !void {
            if (value.len > capacity) return error.CredentialFieldTooLong;
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

/// Bounded storage for a token-exchange value, which must be nonempty.
pub fn Required(comptime capacity: usize) type {
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

pub const State = enum { ready, refresh_pending };

/// A complete credential value. It owns every returned slice; no pathname or
/// file buffer is borrowed. Callers should overwrite it after the final header
/// consumer releases its borrow. Decisions borrow records rather than copy
/// token bytes.
pub const Record = struct {
    version: u32 = 3,
    generation: u64,
    account_id: Bounded(max_account_id_bytes),
    fedramp: bool = false,
    id_token: Bounded(max_token_bytes),
    access_token: Bounded(max_token_bytes),
    refresh_token: Bounded(max_token_bytes),
    expires_at: i64,
    refreshed_at: i64,
    state: State = .ready,
};

pub fn opaqueRefreshDue(refreshed_at: i64, now_seconds: i64) bool {
    return now_seconds -| refreshed_at >= opaque_refresh_seconds;
}

/// A compact access token refreshes `margin_seconds` before its expiry; an
/// opaque token refreshes eight days after the last successful exchange.
pub fn refreshDue(record: *const Record, now_seconds: i64, margin_seconds: i64) bool {
    if (record.expires_at != 0) return record.expires_at <= now_seconds +| margin_seconds;
    return opaqueRefreshDue(record.refreshed_at, now_seconds);
}

/// The record's decoded claims must agree with its stored routing binding
/// and expiry. A fixture selection accepts only the synthetic credential.
pub fn validateSelected(record: *const Record, fixture: bool) !void {
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

/// A pending record means an earlier claimant may have consumed the refresh
/// token, so only explicit login can recover it.
pub fn requireReady(record: *const Record) !void {
    if (record.state != .ready) return error.RefreshRequiresLogin;
}

pub const Selection = enum { use, refresh };

/// Chooses how a Host acquisition proceeds from the record it loaded.
pub fn select(record: *const Record, fixture: bool, now_seconds: i64) !Selection {
    try requireReady(record);
    try validateSelected(record, fixture);
    return if (refreshDue(record, now_seconds, launch_refresh_margin_seconds)) .refresh else .use;
}

/// The final check on the leased record before a model launch.
pub fn launchCheck(record: *const Record, fixture: bool, now_seconds: i64) !void {
    try validateSelected(record, fixture);
    if (record.expires_at != 0 and record.expires_at <= now_seconds) return error.ExpiredCredential;
}

pub const LocalStatus = enum {
    missing,
    configured,
    renewal_due,
    refresh_required,

    pub fn usable(self: LocalStatus) bool {
        return self == .configured or self == .renewal_due;
    }
};

/// Ready and renewal-due are locally usable, not remotely accepted. Applies
/// the runtime's routing and expiry checks to a read-only snapshot.
pub fn localStatus(record: ?*const Record, now_seconds: i64) !LocalStatus {
    const current = record orelse return .missing;
    if (current.state == .refresh_pending) return .refresh_required;
    try validateSelected(current, false);
    return if (refreshDue(current, now_seconds, 0)) .renewal_due else .configured;
}

/// Credential failures the user can resolve by logging in again are
/// authentication failures; everything else is a backend failure.
pub fn failureCode(err: anyerror) []const u8 {
    return switch (err) {
        error.RefreshRejected, error.RefreshRequiresLogin, error.ExpiredCredential, error.AccountMismatch, error.AccountChanged, error.InvalidCredentialExpiry => "provider_authentication_failed",
        else => "provider_authentication_backend_failed",
    };
}

pub const Claim = enum { claimed, superseded };

/// Claims a refresh under the exclusive lock by marking the record pending.
/// Another claimant that already advanced the generation supersedes this one;
/// a pending record requires explicit login rather than another exchange.
pub fn claimRefresh(record: *Record, expected_generation: u64) !Claim {
    try requireReady(record);
    if (record.generation != expected_generation) return .superseded;
    record.state = .refresh_pending;
    return .claimed;
}

/// A replacement must be a complete, ready record.
pub fn validateReplacement(record: *const Record) !void {
    try validateRecord(record);
    if (record.state != .ready) return error.InstallMustBeReady;
}

/// Returns the generation a replacement publishes with.
/// `expected_generation == null` is an explicit login: it may replace any
/// existing record, including another account, and advances its generation.
/// A non-null value completes the pending refresh at that generation and must
/// preserve the account ID and FedRAMP routing claim.
/// Returns the generation an installed replacement takes. Login passes no
/// expected generation; refresh completion passes the one it claimed.
pub fn admitReplacement(current: ?*const Record, replacement: *const Record, expected_generation: ?u64) !u64 {
    try validateReplacement(replacement);
    const expected = expected_generation orelse {
        const old = current orelse return 1;
        return std.math.add(u64, old.generation, 1) catch error.GenerationExhausted;
    };
    const old = current orelse return error.GenerationMismatch;
    if (old.generation != expected or old.state != .refresh_pending) return error.GenerationMismatch;
    if (!std.mem.eql(u8, old.account_id.slice(), replacement.account_id.slice()) or
        old.fedramp != replacement.fedramp)
        return error.AccountMismatch;
    return std.math.add(u64, expected, 1) catch error.GenerationExhausted;
}

fn validateText(value: []const u8, empty_allowed: bool) !void {
    if (!empty_allowed and value.len == 0) return error.EmptyCredentialField;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidCredentialByte;
}

pub fn validateRecord(record: *const Record) !void {
    if (record.version != 3) return error.UnsupportedCredentialVersion;
    try validateText(record.account_id.slice(), false);
    try validateText(record.id_token.slice(), false);
    try validateText(record.access_token.slice(), false);
    try validateText(record.refresh_token.slice(), false);
    if (record.expires_at < 0 or record.refreshed_at <= 0) return error.InvalidCredentialTime;
    var segments = std.mem.splitScalar(u8, record.access_token.slice(), '.');
    var count: usize = 0;
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.InvalidAccessToken;
        count += 1;
    }
    if (count != 1 and count != 3) return error.InvalidAccessToken;
}

pub fn encode(record: *const Record, destination: []u8) ![]const u8 {
    try validateRecord(record);
    return std.fmt.bufPrint(destination, "version=3\ngeneration={d}\naccount_id={s}\nfedramp={d}\nid_token={s}\naccess_token={s}\nrefresh_token={s}\nexpires_at={d}\nrefreshed_at={d}\nstate={s}\n", .{ record.generation, record.account_id.slice(), @intFromBool(record.fedramp), record.id_token.slice(), record.access_token.slice(), record.refresh_token.slice(), record.expires_at, record.refreshed_at, @tagName(record.state) }) catch
        return error.CredentialFileTooLarge;
}

pub fn parseInto(bytes: []const u8, record: *Record) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidCredentialFile, "version=3"))
        return error.UnsupportedCredentialVersion;
    record.* = .{ .generation = try decimal(u64, field(lines.next(), "generation=")), .account_id = .{}, .id_token = .{}, .access_token = .{}, .refresh_token = .{}, .expires_at = 0, .refreshed_at = 0 };
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(record));
    try record.account_id.set(try field(lines.next(), "account_id="));
    const fedramp = try field(lines.next(), "fedramp=");
    if (std.mem.eql(u8, fedramp, "1")) record.fedramp = true else if (!std.mem.eql(u8, fedramp, "0")) return error.InvalidCredentialFile;
    try record.id_token.set(try field(lines.next(), "id_token="));
    try record.access_token.set(try field(lines.next(), "access_token="));
    try record.refresh_token.set(try field(lines.next(), "refresh_token="));
    record.expires_at = try decimal(i64, field(lines.next(), "expires_at="));
    record.refreshed_at = try decimal(i64, field(lines.next(), "refreshed_at="));
    record.state = std.meta.stringToEnum(State, try field(lines.next(), "state=")) orelse
        return error.InvalidCredentialState;
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidCredentialFile, "") or lines.next() != null)
        return error.TrailingCredentialData;
    try validateRecord(record);
}

fn field(line: ?[]const u8, prefix: []const u8) ![]const u8 {
    const value = line orelse return error.InvalidCredentialFile;
    if (!std.mem.startsWith(u8, value, prefix)) return error.InvalidCredentialFile;
    return value[prefix.len..];
}

fn decimal(comptime T: type, value: anytype) !T {
    return std.fmt.parseInt(T, try value, 10) catch return error.InvalidCredentialNumber;
}

const Claims = struct {
    @"https://api.openai.com/auth": ?struct {
        chatgpt_account_id: ?[]const u8 = null,
        chatgpt_account_is_fedramp: ?bool = null,
    } = null,
    chatgpt_account_id: ?[]const u8 = null,
};

pub fn safeAscii(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

fn validBase64Url(bytes: []const u8) bool {
    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(bytes) catch return false;
    if (size > max_token_bytes) return false;
    var decoded: [max_token_bytes]u8 = undefined;
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

pub const Account = struct { id: Required(max_account_id_bytes), fedramp: bool };

/// Decoded routing claims from the TLS peer's ID token, not a verified JWT.
pub fn parseAccount(id_token: []const u8) !Account {
    var decoded: [max_token_bytes]u8 = undefined;
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
    var decoded: [max_token_bytes]u8 = undefined;
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

/// Fixture expiry encoded in `fixture_access_token`.
const fixture_expires_at: i64 = 4_102_444_800;

fn expectSameRecord(expected: *const Record, actual: *const Record) !void {
    try std.testing.expectEqual(expected.version, actual.version);
    try std.testing.expectEqual(expected.generation, actual.generation);
    try std.testing.expectEqualStrings(expected.account_id.slice(), actual.account_id.slice());
    try std.testing.expectEqual(expected.fedramp, actual.fedramp);
    try std.testing.expectEqualStrings(expected.id_token.slice(), actual.id_token.slice());
    try std.testing.expectEqualStrings(expected.access_token.slice(), actual.access_token.slice());
    try std.testing.expectEqualStrings(expected.refresh_token.slice(), actual.refresh_token.slice());
    try std.testing.expectEqual(expected.expires_at, actual.expires_at);
    try std.testing.expectEqual(expected.refreshed_at, actual.refreshed_at);
    try std.testing.expectEqual(expected.state, actual.state);
}

fn fixtureRecord(record: *Record) !void {
    record.* = .{
        .generation = 5,
        .account_id = .{},
        .id_token = .{},
        .access_token = .{},
        .refresh_token = .{},
        .expires_at = fixture_expires_at,
        .refreshed_at = 100,
    };
    try record.account_id.set(fixture_account_id);
    try record.id_token.set(fixture_id_token);
    try record.access_token.set(fixture_access_token);
    try record.refresh_token.set("synthetic-refresh");
}

test "format is bounded and strictly consumed" {
    var record: Record = undefined;
    try fixtureRecord(&record);
    record.generation = 7;
    record.refreshed_at = 123;
    record.fedramp = true;
    try record.id_token.set(fixture_fedramp_id_token);
    var bytes: [max_file_bytes]u8 = undefined;
    var decoded: Record = undefined;
    const encoded = try encode(&record, &bytes);
    try parseInto(encoded, &decoded);
    try expectSameRecord(&record, &decoded);
    // Unknown versions, routing values and states are refused.
    var edited: [max_file_bytes]u8 = undefined;
    for ([_][3][]const u8{
        .{ "version=3", "version=2", "UnsupportedCredentialVersion" },
        .{ "fedramp=1", "fedramp=2", "InvalidCredentialFile" },
        .{ "state=ready", "state=done", "InvalidCredentialState" },
    }) |case| {
        const at = std.mem.indexOf(u8, encoded, case[0]).?;
        @memcpy(edited[0..encoded.len], encoded);
        @memcpy(edited[at..][0..case[1].len], case[1]);
        const result = parseInto(edited[0 .. encoded.len - case[0].len + case[1].len], &decoded);
        try std.testing.expectEqualStrings(case[2], @errorName(if (result) |_| error.Accepted else |err| err));
    }
    try record.access_token.set("opaque-access");
    record.expires_at = 0;
    record.state = .refresh_pending;
    const opaque_encoded = try encode(&record, &bytes);
    try parseInto(opaque_encoded, &decoded);
    try expectSameRecord(&record, &decoded);
    var extra: [max_file_bytes]u8 = undefined;
    @memcpy(extra[0..opaque_encoded.len], opaque_encoded);
    @memcpy(extra[opaque_encoded.len..][0..4], "junk");
    try std.testing.expectError(error.TrailingCredentialData, parseInto(extra[0 .. opaque_encoded.len + 4], &decoded));
    // Empty fields, nonpositive refresh time and malformed compact tokens fail.
    record.refreshed_at = 0;
    try std.testing.expectError(error.InvalidCredentialTime, encode(&record, &bytes));
    record.refreshed_at = 100;
    try record.access_token.set("a..c");
    try std.testing.expectError(error.InvalidAccessToken, encode(&record, &bytes));
    try record.refresh_token.set("");
    try std.testing.expectError(error.EmptyCredentialField, encode(&record, &bytes));
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
    try std.testing.expectEqual(@as(?i64, fixture_expires_at), try parseExpiry(fixture_access_token));
    try std.testing.expectEqual(@as(?i64, null), try parseExpiry("opaque-access"));
    try std.testing.expectError(error.InvalidCompactToken, parseExpiry("a..c"));
}

test "refresh is due at the expiry margin or eight days after an opaque exchange" {
    var record: Record = undefined;
    record.expires_at = 1_000;
    record.refreshed_at = 100;
    try std.testing.expect(!refreshDue(&record, 939, launch_refresh_margin_seconds));
    try std.testing.expect(refreshDue(&record, 940, launch_refresh_margin_seconds));
    try std.testing.expect(!refreshDue(&record, 999, 0));
    try std.testing.expect(refreshDue(&record, 1_000, 0));
    // Opaque tokens ignore the margin.
    record.expires_at = 0;
    for ([_]i64{ 0, launch_refresh_margin_seconds }) |margin| {
        try std.testing.expect(!refreshDue(&record, 100 + opaque_refresh_seconds - 1, margin));
        try std.testing.expect(refreshDue(&record, 100 + opaque_refresh_seconds, margin));
    }
}

test "selection refreshes inside the launch margin and rejects unusable records" {
    var record: Record = undefined;
    try fixtureRecord(&record);
    try std.testing.expectEqual(Selection.use, try select(&record, true, fixture_expires_at - 61));
    try std.testing.expectEqual(Selection.refresh, try select(&record, true, fixture_expires_at - 60));
    try std.testing.expectEqual(Selection.use, try select(&record, false, 0));

    // A refresh left pending by a crashed claimant requires login.
    record.state = .refresh_pending;
    try std.testing.expectError(error.RefreshRequiresLogin, select(&record, false, 0));
    record.state = .ready;
    // Stored routing must match the ID token in both FedRAMP directions.
    record.fedramp = true;
    try std.testing.expectError(error.AccountMismatch, select(&record, false, 0));
    record.fedramp = false;
    try record.id_token.set(fixture_fedramp_id_token);
    try std.testing.expectError(error.AccountMismatch, select(&record, false, 0));
    record.fedramp = true;
    try std.testing.expectEqual(Selection.use, try select(&record, true, 0));
    // A fixture launch accepts only the synthetic tokens, even for its account.
    try fixtureRecord(&record);
    try record.id_token.set("e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJydWktdGVzdC1hY2NvdW50Iiwic3ViIjoieCJ9.c2ln");
    try std.testing.expectEqual(Selection.use, try select(&record, false, 0));
    try std.testing.expectError(error.FixtureRequiresSyntheticCredential, select(&record, true, 0));
    try fixtureRecord(&record);
    try record.access_token.set("e30.eyJleHAiOjQxMDI0NDQ4MDB9.c2lo");
    try std.testing.expectError(error.FixtureRequiresSyntheticCredential, select(&record, true, 0));
    try fixtureRecord(&record);
    try record.account_id.set("foreign-account");
    try std.testing.expectError(error.FixtureRequiresSyntheticCredential, select(&record, true, 0));
    try std.testing.expectError(error.AccountMismatch, select(&record, false, 0));
    // Stored expiry must match the access token's encoded expiry.
    try fixtureRecord(&record);
    record.expires_at = 1234;
    try std.testing.expectError(error.InvalidCredentialExpiry, select(&record, false, 0));
}

test "launch rejects a leased token that expired after selection" {
    var record: Record = undefined;
    try fixtureRecord(&record);
    try launchCheck(&record, true, fixture_expires_at - 1);
    try std.testing.expectError(error.ExpiredCredential, launchCheck(&record, true, fixture_expires_at));
    // Opaque tokens have no launch expiry; their refresh clock governs.
    try record.access_token.set("opaque-access");
    record.expires_at = 0;
    try launchCheck(&record, false, std.math.maxInt(i32));
    try std.testing.expectError(error.FixtureRequiresSyntheticCredential, launchCheck(&record, true, 0));
}

test "local status reports renewal only at expiry, without the launch margin" {
    var record: Record = undefined;
    try fixtureRecord(&record);
    try std.testing.expectEqual(LocalStatus.missing, try localStatus(null, 0));
    try std.testing.expectEqual(LocalStatus.configured, try localStatus(&record, fixture_expires_at - 1));
    try std.testing.expectEqual(LocalStatus.renewal_due, try localStatus(&record, fixture_expires_at));
    // Inside the launch margin, the runtime refreshes but local status is configured.
    try std.testing.expectEqual(Selection.refresh, try select(&record, false, fixture_expires_at - 1));
    try std.testing.expect((try localStatus(&record, fixture_expires_at)).usable());
    try std.testing.expect(!LocalStatus.missing.usable() and !LocalStatus.refresh_required.usable());
    record.state = .refresh_pending;
    try std.testing.expectEqual(LocalStatus.refresh_required, try localStatus(&record, 0));
    record.state = .ready;
    record.fedramp = true;
    try std.testing.expectError(error.AccountMismatch, localStatus(&record, 0));
}

test "a refresh claim marks the current generation pending once" {
    var record: Record = undefined;
    try fixtureRecord(&record);
    try std.testing.expectEqual(Claim.superseded, try claimRefresh(&record, 4));
    try std.testing.expectEqual(Claim.superseded, try claimRefresh(&record, 6));
    try std.testing.expectEqual(State.ready, record.state);
    try std.testing.expectEqual(Claim.claimed, try claimRefresh(&record, 5));
    try std.testing.expectEqual(State.refresh_pending, record.state);
    try std.testing.expectEqual(@as(u64, 5), record.generation);
    try std.testing.expectError(error.RefreshRequiresLogin, claimRefresh(&record, 5));
}

test "replacement admission advances generations and preserves refresh routing" {
    var current: Record = undefined;
    try fixtureRecord(&current);
    var replacement: Record = undefined;
    try fixtureRecord(&replacement);

    // Login creates generation 1 or advances any existing record.
    try std.testing.expectEqual(@as(u64, 1), try admitReplacement(null, &replacement, null));
    try std.testing.expectEqual(@as(u64, 6), try admitReplacement(&current, &replacement, null));
    try replacement.account_id.set("foreign-account");
    current.state = .refresh_pending;
    try std.testing.expectEqual(@as(u64, 6), try admitReplacement(&current, &replacement, null));

    // Refresh completion requires the same pending generation and binding.
    try std.testing.expectError(error.AccountMismatch, admitReplacement(&current, &replacement, 5));
    try replacement.account_id.set(fixture_account_id);
    try std.testing.expectEqual(@as(u64, 6), try admitReplacement(&current, &replacement, 5));
    try std.testing.expectError(error.GenerationMismatch, admitReplacement(null, &replacement, 5));
    try std.testing.expectError(error.GenerationMismatch, admitReplacement(&current, &replacement, 4));
    try std.testing.expectError(error.GenerationMismatch, admitReplacement(&current, &replacement, 6));
    current.state = .ready;
    try std.testing.expectError(error.GenerationMismatch, admitReplacement(&current, &replacement, 5));
    current.state = .refresh_pending;
    for ([_][2]bool{ .{ false, true }, .{ true, false } }) |routing| {
        current.fedramp = routing[0];
        replacement.fedramp = routing[1];
        try std.testing.expectError(error.AccountMismatch, admitReplacement(&current, &replacement, 5));
    }
    current.fedramp = false;
    replacement.fedramp = false;

    // Admission itself refuses a replacement that is not ready.
    replacement.state = .refresh_pending;
    try std.testing.expectError(error.InstallMustBeReady, admitReplacement(null, &replacement, null));
    replacement.state = .ready;

    const last = std.math.maxInt(u64);
    current.generation = last;
    try std.testing.expectError(error.GenerationExhausted, admitReplacement(&current, &replacement, last));
    try std.testing.expectError(error.GenerationExhausted, admitReplacement(&current, &replacement, null));
}

test "a replacement must be complete and ready" {
    var record: Record = undefined;
    try fixtureRecord(&record);
    try validateReplacement(&record);
    record.state = .refresh_pending;
    try std.testing.expectError(error.InstallMustBeReady, validateReplacement(&record));
    record.state = .ready;
    record.version = 2;
    try std.testing.expectError(error.UnsupportedCredentialVersion, validateReplacement(&record));
}

test "only failures resolved by logging in again are authentication failures" {
    for ([_]anyerror{ error.RefreshRejected, error.RefreshRequiresLogin, error.ExpiredCredential, error.AccountMismatch, error.AccountChanged, error.InvalidCredentialExpiry }) |err|
        try std.testing.expectEqualStrings("provider_authentication_failed", failureCode(err));
    for ([_]anyerror{ error.TransportFailed, error.GenerationMismatch, error.CredentialFileTooLarge, error.FixtureRequiresSyntheticCredential }) |err|
        try std.testing.expectEqualStrings("provider_authentication_backend_failed", failureCode(err));
}
