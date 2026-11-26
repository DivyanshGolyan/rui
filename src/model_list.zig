const std = @import("std");
const catalog = @import("model_catalog.zig");
const model_capability = @import("model_capability.zig");
const connection = @import("connection.zig");

pub const Source = enum {
    catalog,
    pending,
    catalog_fallback,
    live,
};

pub const max_live_models = 512;
pub const max_live_id_bytes = 16 * 1024;
pub const max_response_bytes = 512 * 1024;

pub const IdBuffer = [max_live_id_bytes + max_live_models]u8;

pub const Ids = struct {
    bytes: []const u8,

    pub fn iterator(self: Ids) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, self.bytes, '\n');
    }
};

pub const Kept = struct {
    out: *IdBuffer,
    len: usize = 0,
    count: usize = 0,

    pub fn keep(self: *Kept, id: []const u8) error{ModelListTooLarge}!void {
        if (!model_capability.validModelSyntax(id)) return;
        if (self.count + 1 > max_live_models or self.len - self.count + id.len > max_live_id_bytes) return error.ModelListTooLarge;
        @memcpy(self.out[self.len..][0..id.len], id);
        self.out[self.len + id.len] = '\n';
        self.len += id.len + 1;
        self.count += 1;
    }

    pub fn ids(self: *const Kept) Ids {
        return .{ .bytes = self.out[0..self.len] };
    }
};

pub fn parseOpenAi(scratch: std.mem.Allocator, body: []const u8, out: *IdBuffer) !Ids {
    var scanner: std.json.Scanner = .initCompleteInput(scratch, body);
    var kept: Kept = .{ .out = out };
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
            try kept.keep(id orelse return error.InvalidModelList);
        }
    }
    if (!data_seen or try nextToken(&scanner, scratch) != .end_of_document) return error.InvalidModelList;
    return kept.ids();
}

pub fn nextToken(scanner: *std.json.Scanner, scratch: std.mem.Allocator) !std.json.Token {
    return scanner.nextAlloc(scratch, .alloc_if_needed) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidModelList,
    };
}

pub fn objectKey(scanner: *std.json.Scanner, scratch: std.mem.Allocator) !?[]const u8 {
    return switch (try nextToken(scanner, scratch)) {
        .object_end => null,
        .string, .allocated_string => |key| key,
        else => error.InvalidModelList,
    };
}

const model_overhead = "{\"id\":\"\",\"known\":false},".len;
const provider_overhead = ",{\"connection\":\"\",\"source\":\"catalog_fallback\",\"models\":[]}".len + max_provider_name_bytes;
const max_provider_name_bytes = connection.max_name_bytes;
const provider_count = connection.max_served;

pub fn providersBytes(facts: []const catalog.Entry) usize {
    @setEvalBranchQuota(20000);
    var catalog_bytes: usize = 0;
    for (facts) |row| if (row.openai_listed) {
        catalog_bytes += model_overhead + 2 * row.id.len;
    };
    return "[]".len + provider_count * (provider_overhead + @max(catalog_bytes, max_live_models * model_overhead + 2 * max_live_id_bytes));
}

pub const max_providers_bytes = providersBytes(catalog.shipped);

pub const List = union(Source) {
    catalog,
    pending,
    catalog_fallback,
    live: Ids,
};

pub const Entry = struct {
    provider: connection.Name,
    list: List,
};

pub fn writeProviders(out: *std.Io.Writer, facts: []const catalog.Entry, entries: []const Entry) !void {
    try out.writeByte('[');
    for (entries, 0..) |entry, index| {
        if (index != 0) try out.writeByte(',');
        try out.print("{{\"connection\":\"{s}\",\"source\":\"{s}\",\"models\":[", .{ entry.provider.slice(), @tagName(entry.list) });
        var first = true;
        switch (entry.list) {
            .live => |live| {
                var ids = live.iterator();
                while (ids.next()) |id| try writeModel(out, facts, id, &first);
            },
            .catalog, .pending, .catalog_fallback => for (facts) |row| {
                if (row.openai_listed) try writeModel(out, facts, row.id, &first);
            },
        }
        try out.writeAll("]}");
    }
    try out.writeByte(']');
}

fn writeModel(out: *std.Io.Writer, facts: []const catalog.Entry, id: []const u8, first: *bool) !void {
    if (!first.*) try out.writeByte(',');
    first.* = false;
    try out.writeAll("{\"id\":");
    try std.json.Stringify.encodeJsonString(id, .{}, out);
    try out.print(",\"known\":{}}}", .{model_capability.supportsModel(facts, id)});
}

fn named(text: []const u8) connection.Name {
    return connection.Name.parse(text).?;
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
    try writeProviders(&out, catalog.shipped, &.{
        .{ .provider = named("codex"), .list = .catalog },
        .{ .provider = named("openai"), .list = .{ .live = .{ .bytes = "gpt-6-luna\nmy\"model\n" } } },
    });
    const listed_models = comptime blk: {
        var text: []const u8 = "";
        for (catalog.openai_ids, 0..) |id, index| text = text ++ (if (index == 0) "" else ",") ++ "{\"id\":\"" ++ id ++ "\",\"known\":true}";
        break :blk text;
    };
    try std.testing.expectEqualStrings(
        "[{\"connection\":\"codex\",\"source\":\"catalog\",\"models\":[" ++ listed_models ++ "]}," ++
            "{\"connection\":\"openai\",\"source\":\"live\",\"models\":[{\"id\":\"gpt-6-luna\",\"known\":true},{\"id\":\"my\\\"model\",\"known\":false}]}]",
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
    for (&entries) |*entry|
        entry.* = .{ .provider = named("codex"), .list = .{ .live = .{ .bytes = ids[0..len] } } };
    try writeProviders(&out, catalog.shipped, &entries);
    entries[0] = .{ .provider = named("codex"), .list = .catalog_fallback };
    out = std.Io.Writer.fixed(&bytes);
    try writeProviders(&out, catalog.shipped, &entries);
}

test "provider lists use selected facts without merging shipped rows or sorting live IDs" {
    const facts: []const catalog.Entry = &.{
        .{ .id = "a-saved", .context_window = null, .efforts = .{}, .openai_listed = true },
        .{ .id = "b-hidden", .context_window = null, .efforts = .{}, .openai_listed = false },
        .{ .id = "z-saved", .context_window = null, .efforts = .{}, .openai_listed = true },
    };
    var bytes: [providersBytes(facts)]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    for ([_]Source{ .catalog, .pending, .catalog_fallback }) |source| {
        out = std.Io.Writer.fixed(&bytes);
        const list: List = switch (source) {
            .catalog => .catalog,
            .pending => .pending,
            .catalog_fallback => .catalog_fallback,
            .live => unreachable,
        };
        try writeProviders(&out, facts, &.{.{ .provider = named("codex"), .list = list }});
        var expected: [256]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "[{{\"connection\":\"codex\",\"source\":\"{s}\",\"models\":[{{\"id\":\"a-saved\",\"known\":true}},{{\"id\":\"z-saved\",\"known\":true}}]}}]", .{@tagName(source)}), out.buffered());
        out = std.Io.Writer.fixed(&bytes);
        try writeProviders(&out, &.{}, &.{.{ .provider = named("codex"), .list = list }});
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "[{{\"connection\":\"codex\",\"source\":\"{s}\",\"models\":[]}}]", .{@tagName(source)}), out.buffered());
    }
    const entries: []const Entry = &.{.{ .provider = named("openai"), .list = .{ .live = .{ .bytes = "z-saved\nb-hidden\ngpt-6-luna\na-saved\n" } } }};
    out = std.Io.Writer.fixed(&bytes);
    try writeProviders(&out, facts, entries);
    try std.testing.expectEqualStrings(
        "[{\"connection\":\"openai\",\"source\":\"live\",\"models\":[{\"id\":\"z-saved\",\"known\":true},{\"id\":\"b-hidden\",\"known\":true},{\"id\":\"gpt-6-luna\",\"known\":false},{\"id\":\"a-saved\",\"known\":true}]}]",
        out.buffered(),
    );
}

test "the dynamic reply bound holds saved catalogs beyond the shipped bound" {
    const count = 1024;
    const allocator = std.testing.allocator;
    const ids = try allocator.alloc([catalog.max_model_bytes]u8, count);
    defer allocator.free(ids);
    const facts = try allocator.alloc(catalog.Entry, count);
    defer allocator.free(facts);
    for (facts, ids, 0..) |*row, *id, index| {
        @memset(id, '"');
        _ = try std.fmt.bufPrint(id[0..4], "{d:0>4}", .{index});
        row.* = .{ .id = id, .context_window = null, .efforts = .{}, .openai_listed = true };
    }
    const bound = providersBytes(facts);
    try std.testing.expect(bound > max_providers_bytes);
    const bytes = try allocator.alloc(u8, bound);
    defer allocator.free(bytes);
    var out = std.Io.Writer.fixed(bytes);
    var entries: [provider_count]Entry = undefined;
    for (&entries) |*entry|
        entry.* = .{ .provider = named("codex"), .list = .catalog_fallback };
    try writeProviders(&out, facts, &entries);
    try std.testing.expect(out.buffered().len > max_providers_bytes);
    try std.testing.expect(out.buffered().len <= bound);
}
