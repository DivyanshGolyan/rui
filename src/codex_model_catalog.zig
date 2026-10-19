//! Codex model catalog decisions over values: parsing a fetched catalog body
//! into bounded rows, and classifying a requested model against the Host's
//! current catalog state. The Host shell owns fetching, credentials, clocks
//! and publication; see ARCHITECTURE.md "Codex model catalog".
const std = @import("std");

/// Equal to `protocol.max_model_bytes`; the shell asserts the equality.
pub const max_slug_bytes = 256;
pub const max_rows = 256;
pub const max_body_bytes = 4 * 1024 * 1024;
/// A catalog older than this starts a background refresh when used.
pub const refresh_after_ms: i64 = 5 * 60 * 1000;
/// A catalog this old or older is stale and never rejects.
pub const fresh_for_ms: i64 = 60 * 60 * 1000;

pub const Visibility = enum { list, other };

pub const Row = struct {
    slug: [max_slug_bytes]u8 = undefined,
    slug_len: u16 = 0,
    visibility: Visibility = .other,

    pub fn slice(self: *const Row) []const u8 {
        return self.slug[0..self.slug_len];
    }
};

/// Bounded rows in response order. About 66 KiB; the shell keeps one
/// published value and one fetch candidate.
pub const Catalog = struct {
    rows: [max_rows]Row = undefined,
    len: u16 = 0,

    pub fn items(self: *const Catalog) []const Row {
        return self.rows[0..self.len];
    }

    pub fn find(self: *const Catalog, slug: []const u8) ?*const Row {
        for (self.items()) |*row| if (std.mem.eql(u8, row.slice(), slug)) return row;
        return null;
    }

    pub fn listedCount(self: *const Catalog) usize {
        var count: usize = 0;
        for (self.items()) |*row| count += @intFromBool(row.visibility == .list);
        return count;
    }
};

/// Why a model could not be checked. Closed and free of secrets.
pub const Reason = enum {
    not_applicable,
    not_fetched,
    stale,
    other_account,
    credential_unavailable,
    transport_failure,
    timeout,
    http_status,
    too_large,
    unparseable,
};

pub const Verdict = union(enum) {
    listed,
    hidden,
    absent,
    unchecked: Reason,

    pub fn name(self: Verdict) []const u8 {
        return @tagName(self);
    }
};

/// Every verdict requires the shell to have reread the credential snapshot,
/// so no observation can assume the fetching account is still current.
pub const Account = enum {
    /// The shell reread the credential snapshot and it names this account.
    confirmed,
    /// The snapshot names another account, or cannot be read.
    unconfirmed,
};

/// Values the shell read under its lock, plus the current time.
pub const State = struct {
    applicable: bool = true,
    catalog: ?*const Catalog = null,
    fetched_at_ms: i64 = 0,
    now_ms: i64,
    last_failure: ?Reason = null,
};

pub fn classify(state: State, account: Account, model: []const u8) Verdict {
    if (!state.applicable) return .{ .unchecked = .not_applicable };
    const catalog = state.catalog orelse return .{ .unchecked = state.last_failure orelse .not_fetched };
    if (account == .unconfirmed) return .{ .unchecked = .other_account };
    if (state.now_ms - state.fetched_at_ms >= fresh_for_ms) return .{ .unchecked = .stale };
    const row = catalog.find(model) orelse return .absent;
    return if (row.visibility == .list) .listed else .hidden;
}

pub fn needsRefresh(state: State) bool {
    if (!state.applicable) return false;
    if (state.catalog == null) return true;
    return state.now_ms - state.fetched_at_ms >= refresh_after_ms;
}

pub const Observation = struct {
    verdict: Verdict,
    /// Age of the catalog the verdict used, when one exists.
    age_ms: ?i64 = null,
};

/// `{"verdict":...,"reason":...,"age_seconds":...}`; closed values only.
pub fn writeObservationJson(observation: Observation, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{{\"verdict\":\"{s}\",\"reason\":", .{observation.verdict.name()});
    switch (observation.verdict) {
        .unchecked => |reason| try writer.print("\"{s}\"", .{@tagName(reason)}),
        else => try writer.writeAll("null"),
    }
    try writer.writeAll(",\"age_seconds\":");
    if (observation.age_ms) |age| try writer.print("\"{d}\"", .{@divTrunc(@max(age, 0), 1000)}) else try writer.writeAll("null");
    try writer.writeAll("}");
}

pub const max_observation_json_bytes = "{\"verdict\":\"unchecked\",\"reason\":\"credential_unavailable\",\"age_seconds\":\"\"}".len + 20;

test "observation JSON carries only closed values" {
    var buffer: [max_observation_json_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeObservationJson(.{ .verdict = .{ .unchecked = .credential_unavailable }, .age_ms = std.math.maxInt(i64) }, &writer);
    try std.testing.expectEqualStrings("{\"verdict\":\"unchecked\",\"reason\":\"credential_unavailable\",\"age_seconds\":\"9223372036854775\"}", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try writeObservationJson(.{ .verdict = .absent }, &writer);
    try std.testing.expectEqualStrings("{\"verdict\":\"absent\",\"reason\":null,\"age_seconds\":null}", writer.buffered());
}

/// Model identifier syntax shared with `model_capability.validModel`.
fn validSlug(slug: []const u8) bool {
    if (slug.len == 0 or slug.len > max_slug_bytes) return false;
    for (slug) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

/// Parses a complete `{"models":[...]}` body. Reads only `slug` and
/// `visibility`; other fields are skipped. Any malformed, duplicate or
/// over-limit content fails the whole body rather than truncating it.
pub fn parse(body: []const u8, destination: *Catalog) error{ TooLarge, Unparseable }!void {
    if (body.len > max_body_bytes) return error.TooLarge;
    destination.len = 0;
    // Nesting stack and escaped-string scratch. Escaped strings are bounded
    // by max_value_len below; the stack by the scanner's depth on this body.
    var storage: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), body);
    defer scanner.deinit();
    parseTopLevel(&scanner, fixed.allocator(), destination) catch |err| return switch (err) {
        error.TooLarge => error.TooLarge,
        else => error.Unparseable,
    };
}

fn parseTopLevel(scanner: *std.json.Scanner, allocator: std.mem.Allocator, destination: *Catalog) !void {
    if (try scanner.next() != .object_begin) return error.Unparseable;
    var models_seen = false;
    while (true) {
        const token = try scanner.nextAllocMax(allocator, .alloc_if_needed, max_slug_bytes * 6);
        defer free(allocator, token);
        switch (token) {
            .object_end => break,
            .string, .allocated_string => |key| {
                if (std.mem.eql(u8, key, "models")) {
                    if (models_seen) return error.Unparseable;
                    models_seen = true;
                    try parseModels(scanner, allocator, destination);
                } else try scanner.skipValue();
            },
            else => return error.Unparseable,
        }
    }
    if (!models_seen or try scanner.next() != .end_of_document) return error.Unparseable;
}

fn parseModels(scanner: *std.json.Scanner, allocator: std.mem.Allocator, destination: *Catalog) !void {
    if (try scanner.next() != .array_begin) return error.Unparseable;
    while (true) {
        switch (try scanner.peekNextTokenType()) {
            .array_end => {
                _ = try scanner.next();
                return;
            },
            .object_begin => {},
            else => return error.Unparseable,
        }
        if (destination.len == max_rows) return error.TooLarge;
        const row = &destination.rows[destination.len];
        try parseRow(scanner, allocator, row);
        for (destination.items()) |*existing| if (std.mem.eql(u8, existing.slice(), row.slice())) return error.Unparseable;
        destination.len += 1;
    }
}

fn parseRow(scanner: *std.json.Scanner, allocator: std.mem.Allocator, row: *Row) !void {
    _ = try scanner.next();
    var slug_seen = false;
    var visibility_seen = false;
    while (true) {
        const token = try scanner.nextAllocMax(allocator, .alloc_if_needed, max_slug_bytes * 6);
        defer free(allocator, token);
        switch (token) {
            .object_end => break,
            .string, .allocated_string => |key| {
                if (std.mem.eql(u8, key, "slug")) {
                    if (slug_seen) return error.Unparseable;
                    slug_seen = true;
                    const value_token = try scanner.nextAllocMax(allocator, .alloc_if_needed, max_slug_bytes * 6);
                    defer free(allocator, value_token);
                    const value = try string(value_token);
                    if (!validSlug(value)) return error.Unparseable;
                    @memcpy(row.slug[0..value.len], value);
                    row.slug_len = @intCast(value.len);
                } else if (std.mem.eql(u8, key, "visibility")) {
                    if (visibility_seen) return error.Unparseable;
                    visibility_seen = true;
                    const value_token = try scanner.nextAllocMax(allocator, .alloc_if_needed, max_slug_bytes * 6);
                    defer free(allocator, value_token);
                    const value = try string(value_token);
                    row.visibility = if (std.mem.eql(u8, value, "list")) .list else .other;
                } else try scanner.skipValue();
            },
            else => return error.Unparseable,
        }
    }
    if (!slug_seen or !visibility_seen) return error.Unparseable;
}

fn string(token: std.json.Token) ![]const u8 {
    return switch (token) {
        .string, .allocated_string => |value| value,
        else => error.Unparseable,
    };
}

/// Escaped strings are allocated; free each one so a long body cannot
/// exhaust the fixed scratch.
fn free(allocator: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_string => |value| allocator.free(value),
        else => {},
    }
}

fn testParse(body: []const u8) !Catalog {
    var catalog: Catalog = .{};
    try parse(body, &catalog);
    return catalog;
}

test "parse keeps slug and visibility in order and skips other fields" {
    const catalog = try testParse(
        \\{"etag":"x","models":[
        \\{"slug":"gpt-6-luna","display_name":"Luna","visibility":"list","supported_in_api":false,"base_instructions":"long {[\"]}"},
        \\{"visibility":"hide","slug":"codex-auto-review","priority":43},
        \\{"slug":"fallback","visibility":"none"},
        \\{"slug":"future","visibility":"pinned"}]}
    );
    try std.testing.expectEqual(@as(u16, 4), catalog.len);
    try std.testing.expectEqualStrings("gpt-6-luna", catalog.rows[0].slice());
    try std.testing.expectEqual(Visibility.list, catalog.rows[0].visibility);
    try std.testing.expectEqualStrings("codex-auto-review", catalog.rows[1].slice());
    try std.testing.expectEqual(Visibility.other, catalog.rows[1].visibility);
    try std.testing.expectEqual(Visibility.other, catalog.rows[3].visibility);
    try std.testing.expectEqual(@as(usize, 1), catalog.listedCount());
}

test "parse rejects the whole body instead of using part of it" {
    const unparseable = [_][]const u8{
        "",
        "[]",
        "{}",
        "{\"models\":{}}",
        "{\"models\":[1]}",
        "{\"models\":[{\"slug\":\"a\"}]}",
        "{\"models\":[{\"visibility\":\"list\"}]}",
        "{\"models\":[{\"slug\":\"a\",\"visibility\":\"list\"},{\"slug\":\"a\",\"visibility\":\"hide\"}]}",
        "{\"models\":[{\"slug\":\"has space\",\"visibility\":\"list\"}]}",
        "{\"models\":[{\"slug\":\"\",\"visibility\":\"list\"}]}",
        "{\"models\":[{\"slug\":\"a\",\"slug\":\"b\",\"visibility\":\"list\"}]}",
        "{\"models\":[{\"slug\":7,\"visibility\":\"list\"}]}",
        "{\"models\":[],\"models\":[]}",
        "{\"models\":[]} trailing",
        "{\"models\":[{\"slug\":\"a\",\"visibility\":\"list\"}",
    };
    for (unparseable) |body| try std.testing.expectError(error.Unparseable, testParse(body));
    var catalog: Catalog = .{};
    try std.testing.expectError(error.Unparseable, parse("{\"models\":[{\"slug\":\"\\u00e9\",\"visibility\":\"list\"}]}", &catalog));
    try std.testing.expectEqual(@as(u16, 0), catalog.len);
}

test "parse accepts the slug length limit and rejects one byte more" {
    var body: [max_slug_bytes + 64]u8 = undefined;
    const at_limit_slug: [max_slug_bytes]u8 = @splat('a');
    const over_slug: [max_slug_bytes + 1]u8 = @splat('a');
    const at_limit = try std.fmt.bufPrint(&body, "{{\"models\":[{{\"slug\":\"{s}\",\"visibility\":\"list\"}}]}}", .{&at_limit_slug});
    try std.testing.expectEqual(@as(u16, max_slug_bytes), (try testParse(at_limit)).rows[0].slug_len);
    const over = try std.fmt.bufPrint(&body, "{{\"models\":[{{\"slug\":\"{s}\",\"visibility\":\"list\"}}]}}", .{&over_slug});
    try std.testing.expectError(error.Unparseable, testParse(over));
}

test "parse rejects more rows than the catalog retains" {
    var body: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer body.deinit();
    try body.writer.writeAll("{\"models\":[");
    for (0..max_rows + 1) |index| {
        if (index != 0) try body.writer.writeAll(",");
        try body.writer.print("{{\"slug\":\"m{d}\",\"visibility\":\"list\"}}", .{index});
    }
    try body.writer.writeAll("]}");
    try std.testing.expectError(error.TooLarge, testParse(body.written()));
    // The limit itself fits.
    var exact: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer exact.deinit();
    try exact.writer.writeAll("{\"models\":[");
    for (0..max_rows) |index| {
        if (index != 0) try exact.writer.writeAll(",");
        try exact.writer.print("{{\"slug\":\"m{d}\",\"visibility\":\"list\"}}", .{index});
    }
    try exact.writer.writeAll("]}");
    try std.testing.expectEqual(@as(u16, max_rows), (try testParse(exact.written())).len);
}

test "classify distinguishes definitive rows from every unchecked state" {
    const catalog = try testParse("{\"models\":[{\"slug\":\"gpt-6-luna\",\"visibility\":\"list\"},{\"slug\":\"codex-auto-review\",\"visibility\":\"hide\"}]}");
    const fresh: State = .{ .catalog = &catalog, .fetched_at_ms = 1_000, .now_ms = 1_000 + fresh_for_ms - 1 };
    try std.testing.expectEqual(Verdict.listed, classify(fresh, .confirmed, "gpt-6-luna"));
    try std.testing.expectEqual(Verdict.hidden, classify(fresh, .confirmed, "codex-auto-review"));
    try std.testing.expectEqual(Verdict.absent, classify(fresh, .confirmed, "gpt-5-codex"));
    // Exact bytes: no case or alias folding.
    try std.testing.expectEqual(Verdict.absent, classify(fresh, .confirmed, "GPT-6-LUNA"));
    try std.testing.expectEqual(Verdict.absent, classify(fresh, .confirmed, "gpt-6-luna-2026-10-01"));

    var stale = fresh;
    stale.now_ms = 1_000 + fresh_for_ms;
    try std.testing.expectEqual(Verdict{ .unchecked = .stale }, classify(stale, .confirmed, "gpt-5-codex"));
    try std.testing.expectEqual(Verdict{ .unchecked = .other_account }, classify(fresh, .unconfirmed, "gpt-5-codex"));
    try std.testing.expectEqual(Verdict{ .unchecked = .not_fetched }, classify(.{ .now_ms = 0 }, .confirmed, "gpt-5-codex"));
    try std.testing.expectEqual(Verdict{ .unchecked = .timeout }, classify(.{ .now_ms = 0, .last_failure = .timeout }, .confirmed, "gpt-5-codex"));
    try std.testing.expectEqual(Verdict{ .unchecked = .not_applicable }, classify(.{ .applicable = false, .catalog = &catalog, .now_ms = 1_000 }, .confirmed, "gpt-5-codex"));
    // A later failure keeps a fresh earlier catalog authoritative.
    var failed_after = fresh;
    failed_after.last_failure = .http_status;
    try std.testing.expectEqual(Verdict.absent, classify(failed_after, .confirmed, "gpt-5-codex"));
}

test "an unconfirmed account never yields a rejecting verdict" {
    var catalog: Catalog = .{};
    try parse("{\"models\":[{\"slug\":\"gpt-6-luna\",\"visibility\":\"list\"}]}", &catalog);
    const state: State = .{ .catalog = &catalog, .fetched_at_ms = 0, .now_ms = 1 };
    try std.testing.expectEqual(Verdict.absent, classify(state, .confirmed, "gpt-5-codex"));
    try std.testing.expectEqual(Verdict{ .unchecked = .other_account }, classify(state, .unconfirmed, "gpt-5-codex"));
    try std.testing.expectEqual(Verdict{ .unchecked = .other_account }, classify(state, .unconfirmed, "gpt-6-luna"));
}

test "refresh starts at five minutes and never for a Host without a catalog" {
    const catalog: Catalog = .{};
    try std.testing.expect(needsRefresh(.{ .now_ms = 0 }));
    try std.testing.expect(!needsRefresh(.{ .catalog = &catalog, .fetched_at_ms = 0, .now_ms = refresh_after_ms - 1 }));
    try std.testing.expect(needsRefresh(.{ .catalog = &catalog, .fetched_at_ms = 0, .now_ms = refresh_after_ms }));
    try std.testing.expect(!needsRefresh(.{ .applicable = false, .now_ms = 0 }));
}
