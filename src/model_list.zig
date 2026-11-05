//! Each served provider's model list: the IDs its account can use, and
//! whether Rui's catalog knows each one's facts. ChatGPT has no public list,
//! so its list is the catalog's OpenAI IDs. The OpenAI API's is fetched once at Host start
//! (`GET BASE/models`) and kept; until it arrives, or when it fails, the
//! catalog's OpenAI IDs stand in. A model the catalog does not list runs with default
//! limits (`product_defaults.unlisted_context_window`).
const std = @import("std");
const catalog = @import("model_catalog.zig");
const model_capability = @import("model_capability.zig");
const provider_name = @import("provider_name.zig");

/// Where a provider's list came from.
pub const Source = enum {
    /// Catalog OpenAI IDs: the provider has no list.
    catalog,
    /// Catalog OpenAI IDs while the fetch is still in flight; ask again later.
    pending,
    /// Catalog OpenAI IDs because the fetch failed: offline, refused or too long.
    catalog_fallback,
    /// The provider's own list for this account.
    live,
};

/// The most model IDs a live list keeps, and the most bytes they take
/// together. A longer list falls back to the catalog rather than lose models
/// without saying so.
pub const max_live_models = 512;
pub const max_live_id_bytes = 16 * 1024;
/// The most bytes of a provider's `/models` answer Rui reads.
pub const max_response_bytes = 512 * 1024;

/// Room for a live list's IDs and their newlines.
pub const IdBuffer = [max_live_id_bytes + max_live_models]u8;

/// IDs kept for a live list, each followed by a newline. An ID is
/// `model_capability.validModelSyntax`, so it holds no whitespace.
pub const Ids = struct {
    bytes: []const u8,

    pub fn iterator(self: Ids) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, self.bytes, '\n');
    }
};

/// The IDs of an OpenAI-style list (`{"data":[{"id":...},...]}`) in the
/// provider's order, written to `out`. An ID Rui cannot select is skipped.
/// `scratch` holds the parse and is freed by the caller.
pub fn parseOpenAi(scratch: std.mem.Allocator, body: []const u8, out: *IdBuffer) !Ids {
    // A token walk, not a typed parse: other members are skipped unread,
    // so no number is ever converted.
    var scanner: std.json.Scanner = .initCompleteInput(scratch, body);
    var len: usize = 0;
    var count: usize = 0;
    var data_seen = false;
    if (try nextToken(&scanner, scratch) != .object_begin) return error.InvalidModelList;
    while (try objectKey(&scanner, scratch)) |key| {
        if (!std.mem.eql(u8, key, "data")) {
            scanner.skipValue() catch return error.InvalidModelList;
            continue;
        }
        data_seen = true;
        if (try nextToken(&scanner, scratch) != .array_begin) return error.InvalidModelList;
        while (true) {
            switch (try nextToken(&scanner, scratch)) {
                .array_end => break,
                .object_begin => {},
                else => return error.InvalidModelList,
            }
            var id: ?[]const u8 = null;
            while (try objectKey(&scanner, scratch)) |member| {
                if (!std.mem.eql(u8, member, "id")) {
                    scanner.skipValue() catch return error.InvalidModelList;
                    continue;
                }
                id = switch (try nextToken(&scanner, scratch)) {
                    .string, .allocated_string => |text| text,
                    else => return error.InvalidModelList,
                };
            }
            const entry = id orelse return error.InvalidModelList;
            if (!model_capability.validModelSyntax(entry)) continue;
            count += 1;
            // `len` counts the newlines too: one per ID kept so far.
            if (count > max_live_models or len - (count - 1) + entry.len > max_live_id_bytes) return error.ModelListTooLarge;
            @memcpy(out[len..][0..entry.len], entry);
            out[len + entry.len] = '\n';
            len += entry.len + 1;
        }
    }
    if (!data_seen or try nextToken(&scanner, scratch) != .end_of_document) return error.InvalidModelList;
    return .{ .bytes = out[0..len] };
}

fn nextToken(scanner: *std.json.Scanner, scratch: std.mem.Allocator) !std.json.Token {
    return scanner.nextAlloc(scratch, .alloc_if_needed) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidModelList,
    };
}

/// The next member's key, or null at the object's end.
fn objectKey(scanner: *std.json.Scanner, scratch: std.mem.Allocator) !?[]const u8 {
    return switch (try nextToken(scanner, scratch)) {
        .object_end => null,
        .string, .allocated_string => |key| key,
        else => error.InvalidModelList,
    };
}

/// Bytes one model entry adds to a reply beyond its ID's: an ID is printable
/// ASCII, so JSON escapes at most double it.
const model_overhead = "{\"id\":\"\",\"known\":false},".len;
const provider_overhead = ",{\"provider\":\"\",\"source\":\"catalog_fallback\",\"models\":[]}".len + max_provider_name_bytes;
const max_provider_name_bytes = blk: {
    var bytes = 0;
    for (std.meta.fieldNames(provider_name.Provider)) |name| bytes = @max(bytes, name.len);
    break :blk bytes;
};
const max_catalog_bytes = blk: {
    var bytes = 0;
    for (catalog.openai_ids) |id| bytes += model_overhead + 2 * id.len;
    break :blk bytes;
};
const provider_count = std.meta.fieldNames(provider_name.Provider).len;

/// The most bytes `writeProviders` writes.
pub const max_providers_bytes = "[]".len + provider_count * (provider_overhead + @max(max_catalog_bytes, max_live_models * model_overhead + 2 * max_live_id_bytes));

/// A provider's list: catalog OpenAI IDs, or the provider's own IDs.
pub const List = union(Source) {
    catalog,
    pending,
    catalog_fallback,
    live: Ids,
};

/// One provider's list as the reply carries it.
pub const Entry = struct {
    provider: provider_name.Provider,
    list: List,
};

/// `[{"provider":...,"source":...,"models":[{"id":...,"known":...},...]},...]`,
/// where `known` says Rui's catalog holds the model's facts.
pub fn writeProviders(out: *std.Io.Writer, entries: []const Entry) !void {
    try out.writeByte('[');
    for (entries, 0..) |entry, index| {
        if (index != 0) try out.writeByte(',');
        try out.print("{{\"provider\":\"{s}\",\"source\":\"{s}\",\"models\":[", .{ @tagName(entry.provider), @tagName(entry.list) });
        var first = true;
        switch (entry.list) {
            .live => |live| {
                var ids = live.iterator();
                while (ids.next()) |id| try writeModel(out, id, &first);
            },
            .catalog, .pending, .catalog_fallback => for (catalog.openai_ids) |id| try writeModel(out, id, &first),
        }
        try out.writeAll("]}");
    }
    try out.writeByte(']');
}

fn writeModel(out: *std.Io.Writer, id: []const u8, first: *bool) !void {
    if (!first.*) try out.writeByte(',');
    first.* = false;
    try out.writeAll("{\"id\":");
    try std.json.Stringify.encodeJsonString(id, .{}, out);
    try out.print(",\"known\":{}}}", .{model_capability.supportsModel(id)});
}

test "an OpenAI list keeps the provider's order and skips IDs Rui cannot select" {
    var out: IdBuffer = undefined;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"object":"list","data":[{"id":"gpt-6-luna","object":"model","created":1,"owned_by":"openai"},
        \\{"id":"whisper-1"},{"id":"has space"},{"id":""},{"id":"my\"model"}]}
    ;
    const ids = try parseOpenAi(arena.allocator(), body, &out);
    try std.testing.expectEqualStrings("gpt-6-luna\nwhisper-1\nmy\"model\n", ids.bytes);
    try std.testing.expectError(error.InvalidModelList, parseOpenAi(arena.allocator(), "{\"data\":7}", &out));
    try std.testing.expectError(error.InvalidModelList, parseOpenAi(arena.allocator(), "<html>", &out));
    try std.testing.expectError(error.InvalidModelList, parseOpenAi(arena.allocator(), "{\"object\":\"list\"}", &out));
    try std.testing.expectError(error.InvalidModelList, parseOpenAi(arena.allocator(), "{\"data\":[{\"name\":\"x\"}]}", &out));
    try std.testing.expectError(error.InvalidModelList, parseOpenAi(arena.allocator(), "{\"data\":[]} {}", &out));
    // A decoded non-ASCII ID is not one Rui can select.
    try std.testing.expectEqualStrings("", (try parseOpenAi(arena.allocator(), "{\"data\":[{\"id\":\"\\u00e9\"}]}", &out)).bytes);
    try std.testing.expectEqualStrings("a/b\n", (try parseOpenAi(arena.allocator(), "{\"data\":[{\"id\":\"a\\/b\",\"created\":1.5e3}]}", &out)).bytes);
}

test "a list past either bound is refused, not cut" {
    var out: IdBuffer = undefined;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var body: std.Io.Writer.Allocating = .init(arena.allocator());
    try body.writer.writeAll("{\"data\":[");
    for (0..max_live_models + 1) |index| try body.writer.print("{s}{{\"id\":\"m{d}\"}}", .{ if (index == 0) "" else ",", index });
    try body.writer.writeAll("]}");
    try std.testing.expectError(error.ModelListTooLarge, parseOpenAi(arena.allocator(), body.written(), &out));

    // Exactly the byte bound fits: 64 IDs of 256 bytes are 16 KiB.
    body.clearRetainingCapacity();
    try body.writer.writeAll("{\"data\":[");
    for (0..64) |index| try body.writer.print("{s}{{\"id\":\"{d:0>256}\"}}", .{ if (index == 0) "" else ",", index });
    try body.writer.writeAll("]}");
    const ids = try parseOpenAi(arena.allocator(), body.written(), &out);
    try std.testing.expectEqual(@as(usize, 64 * 257), ids.bytes.len);
    const more = try std.mem.concat(arena.allocator(), u8, &.{ body.written()[0 .. body.written().len - 2], ",{\"id\":\"x\"}]}" });
    try std.testing.expectError(error.ModelListTooLarge, parseOpenAi(arena.allocator(), more, &out));
}

test "a reply lists each provider's models and whether the catalog knows them" {
    var bytes: [max_providers_bytes]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try writeProviders(&out, &.{
        .{ .provider = .codex, .list = .catalog },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6-luna\nmy\"model\n" } } },
    });
    const listed_models = comptime blk: {
        var text: []const u8 = "";
        for (catalog.openai_ids, 0..) |id, index| text = text ++ (if (index == 0) "" else ",") ++ "{\"id\":\"" ++ id ++ "\",\"known\":true}";
        break :blk text;
    };
    try std.testing.expectEqualStrings(
        "[{\"provider\":\"codex\",\"source\":\"catalog\",\"models\":[" ++ listed_models ++ "]}," ++
            "{\"provider\":\"openai\",\"source\":\"live\",\"models\":[{\"id\":\"gpt-6-luna\",\"known\":true},{\"id\":\"my\\\"model\",\"known\":false}]}]",
        out.buffered(),
    );
}

test "the reply bound holds the largest lists" {
    const id: [max_live_id_bytes / max_live_models]u8 = @splat('"');
    var ids: IdBuffer = undefined;
    var len: usize = 0;
    for (0..max_live_models) |_| {
        @memcpy(ids[len..][0..id.len], &id);
        ids[len + id.len] = '\n';
        len += id.len + 1;
    }
    var bytes: [max_providers_bytes]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var entries: [provider_count]Entry = undefined;
    for (&entries, std.enums.values(provider_name.Provider)) |*entry, provider|
        entry.* = .{ .provider = provider, .list = .{ .live = .{ .bytes = ids[0..len] } } };
    try writeProviders(&out, &entries);
    entries[0] = .{ .provider = .codex, .list = .catalog_fallback };
    out = std.Io.Writer.fixed(&bytes);
    try writeProviders(&out, &entries);
}
