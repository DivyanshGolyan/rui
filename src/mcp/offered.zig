const std = @import("std");
const protocol = @import("../protocol.zig");
const tools = @import("../tools.zig");
const hs = @import("../host_settings.zig");
const Connection = @import("../server_mcp_settings.zig").Server;
const http1 = @import("../http1/request.zig");
const stderr = @import("../stderr.zig");
const Listing = @import("Listing.zig");
const post = @import("post.zig");
const pages = @import("../os/pages.zig");

pub const list_timeout_ms = 10_000;

const entries_per_server = tools.max_host_tool_records;
const arena_bytes = 4 * 1024 * 1024;
const answer_bytes = 512 * 1024;
const request_bytes = 8 * 1024;

pub const client: post.Client = .{ .name = "rui", .version = protocol.wire_version };

pub const Source = struct {
    server: []const u8,
    listed: ?[]const Listing.Entry,
};

pub const Collision = struct {
    name: []const u8 = "",
    first: []const u8 = "",
    second: []const u8 = "",
};

pub const built_in_source = "Rui";

pub const Error = error{ OutOfMemory, ToolNameCollision, TooManyTools, Stopped };

const Item = struct { record: tools.Record, source: []const u8 };

fn before(_: void, a: Item, b: Item) bool {
    return std.mem.order(u8, a.record.name, b.record.name) == .lt;
}

/// Copies the bytes of an MCP-owned record into `arena`. Built-ins are static and stay borrowed.
fn ownedRecord(arena: std.mem.Allocator, record: tools.Record) Error!tools.Record {
    return .{
        .name = try arena.dupe(u8, record.name),
        .description = try arena.dupe(u8, record.description),
        .input_schema = try arena.dupe(u8, record.input_schema),
        .owner = record.owner,
        .server = try arena.dupe(u8, record.server),
    };
}

/// Builds a tool set whose bytes all live in `arena`: the result borrows nothing from
/// `saved`, `sources` or the listed entries, so those may be freed as soon as this returns.
pub noinline fn merge(arena: std.mem.Allocator, saved: ?*const tools.HostToolSet, sources: []const Source, collision: *Collision) Error!tools.HostToolSet {
    var items: std.ArrayList(Item) = .empty;
    for (tools.built_in_tool_set.records) |record| try items.append(arena, .{ .record = record, .source = built_in_source });
    for (sources) |source| {
        if (source.listed) |entries| {
            for (entries) |entry| try items.append(arena, .{ .source = source.server, .record = try ownedRecord(arena, .{
                .name = entry.name,
                .description = entry.description orelse "",
                .input_schema = entry.input_schema,
                .owner = .mcp,
                .server = source.server,
            }) });
        } else if (saved) |tool_set| {
            for (tool_set.records) |record| {
                if (record.owner == .mcp and std.mem.eql(u8, record.server, source.server))
                    try items.append(arena, .{ .record = try ownedRecord(arena, record), .source = source.server });
            }
        }
    }
    if (items.items.len > tools.max_host_tool_records) return error.TooManyTools;
    for (1..items.items.len) |at| {
        var low = at;
        while (low > 0 and before({}, items.items[low], items.items[low - 1])) : (low -= 1)
            std.mem.swap(Item, &items.items[low], &items.items[low - 1]);
    }
    for (items.items[1..], 0..) |item, at| {
        const earlier = items.items[at];
        if (!std.mem.eql(u8, earlier.record.name, item.record.name)) continue;
        collision.* = .{ .name = item.record.name, .first = earlier.source, .second = item.source };
        return error.ToolNameCollision;
    }
    const records = try arena.alloc(tools.Record, items.items.len);
    const digests = try arena.alloc([32]u8, items.items.len);
    for (items.items, records, digests) |item, *record, *digest| {
        record.* = item.record;
        digest.* = tools.recordDigest(record);
    }
    const configured_servers = try arena.alloc([]const u8, sources.len);
    for (sources, configured_servers) |source, *name| name.* = try arena.dupe(u8, source.server);
    return .{ .records = records, .digests = digests, .configured_servers = configured_servers };
}

pub fn nowMs(io: std.Io) u64 {
    const nanoseconds = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    return @intCast(@divTrunc(nanoseconds, std.time.ns_per_ms));
}

/// One server's list in flight. It owns the room its Listing reads into and the
/// entries it fills; `finish` frees them, so a listed server's entries are valid
/// only until then. The cell is heap-allocated so the Listing's address is stable.
pub const Pending = struct {
    scratch: std.mem.Allocator,
    name: []const u8,
    entries: []Listing.Entry,
    room: []u8,
    listing: Listing,
    deadline_ms: u64,

    pub const Step = union(enum) { waiting, listed, failed, collision: []const u8 };

    /// Begins listing `server`. Null when the server cannot be listed at all (a bad URL or no room).
    /// `collision` in a later `advance` is valid until `finish`.
    pub fn start(scratch: std.mem.Allocator, server: *const Connection, now_ms: u64) ?*Pending {
        const target = http1.parseTarget(server.url.slice()) catch return null;
        const entries = scratch.alloc(Listing.Entry, entries_per_server) catch return null;
        const room = pages.mapZeroed(u8, arena_bytes + answer_bytes + request_bytes) catch {
            scratch.free(entries);
            return null;
        };
        const self = scratch.create(Pending) catch {
            pages.unmapZeroed(room);
            scratch.free(entries);
            return null;
        };
        self.* = .{
            .scratch = scratch,
            .name = server.name.slice(),
            .entries = entries,
            .room = room,
            .listing = undefined,
            .deadline_ms = now_ms +| list_timeout_ms,
        };
        self.listing.init(
            .{ .target = target, .bearer_token = server.bearer_token.slice() },
            client,
            .{
                .entries = entries,
                .arena = room[0..arena_bytes],
                .answer = room[arena_bytes..][0..answer_bytes],
                .request = room[arena_bytes + answer_bytes ..],
            },
        ) catch {
            pages.unmapZeroed(room);
            scratch.free(entries);
            scratch.destroy(self);
            return null;
        };
        return self;
    }

    /// Reads what the server has sent so far. Call again only after `.waiting`.
    pub fn advance(self: *Pending) Step {
        const outcome = self.listing.advance() catch |err| switch (err) {
            error.ToolNameCollision => return .{ .collision = self.listing.collision orelse "" },
            else => return .failed,
        };
        return switch (outcome) {
            .waiting => .waiting,
            .unavailable => .failed,
            .listed => {
                if (self.listing.leftOut() != 0) stderr.diagnostic("rui: MCP server {s}: {d} tool(s) left out for a bad definition\n", .{ self.name, self.listing.leftOut() });
                return .listed;
            },
        };
    }

    /// The tools of a listed server. Valid after `.listed` until `finish`.
    pub fn listed(self: *const Pending) []const Listing.Entry {
        return self.listing.entries();
    }

    pub fn fd(self: *const Pending) std.posix.fd_t {
        return self.listing.fd();
    }

    pub fn events(self: *const Pending) i16 {
        return self.listing.events();
    }

    pub fn expired(self: *const Pending, now_ms: u64) bool {
        return now_ms >= self.deadline_ms;
    }

    /// Frees the list and its entries. Merge the entries first.
    pub fn finish(self: *Pending) void {
        self.listing.deinit();
        pages.unmapZeroed(self.room);
        self.scratch.free(self.entries);
        self.scratch.destroy(self);
    }
};

fn listed(name: []const u8) Listing.Entry {
    return .{ .name = name, .description = "d", .input_schema = "{\"type\":\"object\"}" };
}

test "listed tools join the built-ins in name order" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var collision: Collision = .{};
    const found = [_]Listing.Entry{ listed("search"), listed("alpha") };
    const merged = try merge(memory.allocator(), null, &.{.{ .server = "docs", .listed = &found }}, &collision);
    try std.testing.expect(merged.valid());
    try std.testing.expectEqual(tools.built_in_tool_set.records.len + 2, merged.records.len);
    const at = merged.find("search").?;
    try std.testing.expectEqual(tools.Owner.mcp, merged.records[at].owner);
    try std.testing.expectEqualStrings("docs", merged.records[at].server);
    try std.testing.expect(merged.find("bash") != null);
}

test "an unlisted server keeps its saved tools and a listed one replaces them" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var collision: Collision = .{};
    const before_up = [_]Listing.Entry{listed("old_up")};
    const before_down = [_]Listing.Entry{listed("kept")};
    const saved = try merge(memory.allocator(), null, &.{
        .{ .server = "up", .listed = &before_up },
        .{ .server = "down", .listed = &before_down },
    }, &collision);
    const fresh = [_]Listing.Entry{listed("new_up")};
    const again = try merge(memory.allocator(), &saved, &.{
        .{ .server = "up", .listed = &fresh },
        .{ .server = "down", .listed = null },
    }, &collision);
    try std.testing.expect(again.find("new_up") != null);
    try std.testing.expect(again.find("old_up") == null);
    try std.testing.expectEqualStrings("down", again.records[again.find("kept").?].server);
}

test "a server removed from settings loses its saved tools" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var collision: Collision = .{};
    const found = [_]Listing.Entry{listed("gone")};
    const saved = try merge(memory.allocator(), null, &.{.{ .server = "old", .listed = &found }}, &collision);
    const again = try merge(memory.allocator(), &saved, &.{}, &collision);
    try std.testing.expectEqual(tools.built_in_tool_set.records.len, again.records.len);
}

test "a name two servers share fails the start and names both" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var collision: Collision = .{};
    const found = [_]Listing.Entry{listed("search")};
    try std.testing.expectError(error.ToolNameCollision, merge(memory.allocator(), null, &.{
        .{ .server = "a", .listed = &found },
        .{ .server = "b", .listed = &found },
    }, &collision));
    try std.testing.expectEqualStrings("search", collision.name);
    try std.testing.expectEqualStrings("a", collision.first);
    try std.testing.expectEqualStrings("b", collision.second);
}

test "a tool named like a built-in fails the start" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var collision: Collision = .{};
    const found = [_]Listing.Entry{listed("bash")};
    try std.testing.expectError(error.ToolNameCollision, merge(memory.allocator(), null, &.{.{ .server = "a", .listed = &found }}, &collision));
    try std.testing.expectEqualStrings(built_in_source, collision.first);
    try std.testing.expectEqualStrings("a", collision.second);
}

test "a saved tool of an unreachable server can collide with a fresh one" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var collision: Collision = .{};
    const found = [_]Listing.Entry{listed("search")};
    const saved = try merge(memory.allocator(), null, &.{.{ .server = "down", .listed = &found }}, &collision);
    try std.testing.expectError(error.ToolNameCollision, merge(memory.allocator(), &saved, &.{
        .{ .server = "down", .listed = null },
        .{ .server = "up", .listed = &found },
    }, &collision));
}

test "MCP missing tools distinguish empty servers from saved copies without guessing ownership" {
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    var collision: Collision = .{};
    const entries = [_]Listing.Entry{listed("kept")};
    const saved = try merge(memory.allocator(), null, &.{.{ .server = "notes", .listed = &entries }}, &collision);
    for ([_]struct { sources: []const Source, previous: ?*const tools.HostToolSet = null, unavailable: bool }{
        .{ .sources = &.{}, .unavailable = false },
        .{ .sources = &.{.{ .server = "notes", .listed = &entries }}, .unavailable = false },
        .{ .sources = &.{.{ .server = "notes", .listed = null }}, .unavailable = true },
        .{ .sources = &.{.{ .server = "notes", .listed = &.{} }}, .unavailable = true },
        .{ .sources = &.{.{ .server = "notes", .listed = null }}, .previous = &saved, .unavailable = false },
        .{ .sources = &.{ .{ .server = "notes", .listed = null }, .{ .server = "other", .listed = null } }, .previous = &saved, .unavailable = true },
    }) |case| {
        const host_tool_set = try merge(memory.allocator(), case.previous, case.sources, &collision);
        try std.testing.expectEqualStrings(if (case.unavailable) "mcp_server_unavailable" else "unknown_tool", @tagName(host_tool_set.resolve("lookup")));
        try std.testing.expect(host_tool_set.resolve("bash") == .found);
        if (case.previous != null) try std.testing.expect(host_tool_set.resolve("kept") == .found);
    }

    const host_tool_set = try merge(memory.allocator(), null, &.{ .{ .server = "notes", .listed = null }, .{ .server = "other", .listed = null } }, &collision);
    var buffer: [tools.HostToolSet.max_refusal_message_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try host_tool_set.writeMissingTool("lookup", &writer);
    try std.testing.expectEqualStrings("spec.tools: lookup is not a known tool; MCP servers notes, other are unavailable and may provide it", writer.buffered());
}

test "MCP missing tools maximum launch names fit the request and start_agent diagnostic" {
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    var collision: Collision = .{};
    var names: [hs.max_mcp_servers][hs.max_mcp_name_bytes]u8 = undefined;
    var sources: [names.len]Source = undefined;
    for (&names, &sources, 0..) |*name, *source, index| {
        @memset(name, @as(u8, 'a') + @as(u8, @intCast(index)));
        source.* = .{ .server = name, .listed = null };
    }
    const host_tool_set = try merge(memory.allocator(), null, &sources, &collision);
    const tool = @as([@import("../tool_name.zig").max_bytes]u8, @splat('z'));
    var buffer: [tools.HostToolSet.max_refusal_message_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try host_tool_set.writeMissingTool(&tool, &writer);
    try writer.writeAll(" (mcp_server_unavailable). Nothing was started.");
    for (names) |name| try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), &name) != null);
}

test "MCP merged tool set owns its bytes, so the saved set and the listed entries can be freed" {
    var saved_memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    var listed_memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    var merged_memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer merged_memory.deinit();
    var collision: Collision = .{};
    const old_up = [_]Listing.Entry{.{ .name = try listed_memory.allocator().dupe(u8, "old_up"), .description = "old", .input_schema = "{\"type\":\"object\"}" }};
    const kept = [_]Listing.Entry{.{ .name = try listed_memory.allocator().dupe(u8, "kept"), .description = "stays", .input_schema = "{\"type\":\"object\"}" }};
    const saved = try merge(saved_memory.allocator(), null, &.{
        .{ .server = "up", .listed = &old_up },
        .{ .server = "down", .listed = &kept },
    }, &collision);
    const fresh = [_]Listing.Entry{.{ .name = try listed_memory.allocator().dupe(u8, "new_up"), .description = "fresh", .input_schema = "{\"type\":\"object\"}" }};
    const merged = try merge(merged_memory.allocator(), &saved, &.{
        .{ .server = "up", .listed = &fresh },
        .{ .server = "down", .listed = null },
    }, &collision);
    saved_memory.deinit();
    listed_memory.deinit();
    try std.testing.expectEqual(tools.built_in_tool_set.records.len + 2, merged.records.len);
    const up_at = merged.find("new_up").?;
    try std.testing.expectEqualStrings("up", merged.records[up_at].server);
    try std.testing.expectEqualStrings("fresh", merged.records[up_at].description);
    const kept_at = merged.find("kept").?;
    try std.testing.expectEqualStrings("down", merged.records[kept_at].server);
    try std.testing.expectEqualStrings("stays", merged.records[kept_at].description);
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", merged.records[kept_at].input_schema);
    try std.testing.expectEqualStrings("down", merged.configured_servers[1]);
    try std.testing.expect(merged.valid());
}
