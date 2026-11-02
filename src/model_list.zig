//! Each served provider's model list: the IDs its account can use, and
//! whether Rui's table knows each one's facts. ChatGPT has no public list,
//! so its list is the table. The OpenAI API's is fetched once at Host start
//! (`GET BASE/models`) and kept; until it arrives, or when it fails, the
//! table stands in. A model the table does not list runs with default
//! limits (`product_defaults.unlisted_context_window`).
const std = @import("std");
const model_capability = @import("model_capability.zig");
const provider_name = @import("provider_name.zig");

/// Where a provider's list came from.
pub const Source = enum {
    /// Rui's table: the provider has no list, or its fetch failed.
    table,
    /// Rui's table while the fetch is still in flight; ask again later.
    pending,
    /// The provider's own list for this account.
    live,
};

/// The most model IDs a live list keeps, and the most bytes they take
/// together. A longer list falls back to the table rather than lose models
/// without saying so.
pub const max_live_models = 512;
pub const max_live_id_bytes = 16 * 1024;
/// The most bytes of a provider's `/models` answer Rui reads.
pub const max_response_bytes = 512 * 1024;

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
pub fn parseOpenAi(scratch: std.mem.Allocator, body: []const u8, out: *[max_live_id_bytes + max_live_models]u8) !Ids {
    const List = struct { data: []const struct { id: []const u8 } };
    const list = std.json.parseFromSliceLeaky(List, scratch, body, .{ .ignore_unknown_fields = true }) catch return error.InvalidModelList;
    var len: usize = 0;
    var count: usize = 0;
    for (list.data) |entry| {
        if (!model_capability.validModelSyntax(entry.id)) continue;
        count += 1;
        // `len` counts the newlines too: one per ID kept so far.
        if (count > max_live_models or len - (count - 1) + entry.id.len > max_live_id_bytes) return error.ModelListTooLarge;
        @memcpy(out[len..][0..entry.id.len], entry.id);
        out[len + entry.id.len] = '\n';
        len += entry.id.len + 1;
    }
    return .{ .bytes = out[0..len] };
}

/// Bytes one model entry adds to a reply beyond its ID's: an ID is printable
/// ASCII, so JSON escapes at most double it.
const model_overhead = "{\"id\":\"\",\"listed\":false},".len;
const provider_overhead = ",{\"provider\":\"\",\"source\":\"pending\",\"models\":[]}".len + max_provider_name_bytes;
const max_provider_name_bytes = blk: {
    var bytes = 0;
    for (std.meta.fieldNames(provider_name.Provider)) |name| bytes = @max(bytes, name.len);
    break :blk bytes;
};
const max_table_bytes = blk: {
    var bytes = 0;
    for (model_capability.models) |row| bytes += model_overhead + 2 * row.id.len;
    break :blk bytes;
};
const provider_count = std.meta.fieldNames(provider_name.Provider).len;

/// The most bytes `writeProviders` writes.
pub const max_providers_bytes = "[]".len + provider_count * (provider_overhead + @max(max_table_bytes, max_live_models * model_overhead + 2 * max_live_id_bytes));

/// One provider's list as the reply carries it.
pub const Entry = struct {
    provider: provider_name.Provider,
    source: Source,
    /// Read only when `source` is `.live`.
    ids: Ids = .{ .bytes = "" },
};

/// `[{"provider":...,"source":...,"models":[{"id":...,"listed":...},...]},...]`
pub fn writeProviders(out: *std.Io.Writer, entries: []const Entry) !void {
    try out.writeByte('[');
    for (entries, 0..) |entry, index| {
        if (index != 0) try out.writeByte(',');
        try out.print("{{\"provider\":\"{s}\",\"source\":\"{s}\",\"models\":[", .{ @tagName(entry.provider), @tagName(entry.source) });
        var first = true;
        if (entry.source == .live) {
            var ids = entry.ids.iterator();
            while (ids.next()) |id| try writeModel(out, id, &first);
        } else {
            for (model_capability.models) |row| try writeModel(out, row.id, &first);
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
    try out.print(",\"listed\":{}}}", .{model_capability.supportsModel(id)});
}

test "an OpenAI list keeps the provider's order and skips IDs Rui cannot select" {
    var out: [max_live_id_bytes + max_live_models]u8 = undefined;
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
}

test "a list past either bound is refused, not cut" {
    var out: [max_live_id_bytes + max_live_models]u8 = undefined;
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

test "a reply lists each provider's models and whether the table knows them" {
    var bytes: [max_providers_bytes]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try writeProviders(&out, &.{
        .{ .provider = .codex, .source = .table },
        .{ .provider = .openai, .source = .live, .ids = .{ .bytes = "gpt-6-luna\nmy\"model\n" } },
    });
    const table = comptime blk: {
        var text: []const u8 = "";
        for (model_capability.models, 0..) |row, index| text = text ++ (if (index == 0) "" else ",") ++ "{\"id\":\"" ++ row.id ++ "\",\"listed\":true}";
        break :blk text;
    };
    try std.testing.expectEqualStrings(
        "[{\"provider\":\"codex\",\"source\":\"table\",\"models\":[" ++ table ++ "]}," ++
            "{\"provider\":\"openai\",\"source\":\"live\",\"models\":[{\"id\":\"gpt-6-luna\",\"listed\":true},{\"id\":\"my\\\"model\",\"listed\":false}]}]",
        out.buffered(),
    );
}

test "the reply bound holds the largest lists" {
    const id: [max_live_id_bytes / max_live_models]u8 = @splat('"');
    var ids: [max_live_id_bytes + max_live_models]u8 = undefined;
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
        entry.* = .{ .provider = provider, .source = .live, .ids = .{ .bytes = ids[0..len] } };
    try writeProviders(&out, &entries);
    entries[0] = .{ .provider = .codex, .source = .pending };
    out = std.Io.Writer.fixed(&bytes);
    try writeProviders(&out, &entries);
}
