//! The tools a Host offers at start: the built-ins and every `mcpServers`
//! entry's tools (M3a, D110). A server that cannot be listed keeps the
//! records the Host saved last, so a restart while a server is down does
//! not change what a Session can be configured with (D147). A name two
//! sources share refuses the start (D142).
//!
//! `merge` is a value transition over lists already read; `collect` is the
//! shell that lists each server, one at a time with a deadline, before the
//! Host serves anyone.
const std = @import("std");
const tools = @import("../tools.zig");
const launch_frame = @import("../launch_frame.zig");
const http1 = @import("../http1/request.zig");
const deadline = @import("../deadline.zig");
const stderr = @import("../stderr.zig");
const Listing = @import("Listing.zig");
const post = @import("post.zig");

/// How long one server has to list its tools.
pub const list_timeout_ms = 10_000;

/// Room for one server's listing, taken from the scratch allocator.
const entries_per_server = tools.max_catalog_records;
const arena_bytes = 4 * 1024 * 1024;
const answer_bytes = 512 * 1024;
const request_bytes = 8 * 1024;

pub const client: post.Client = .{ .name = "rui", .version = "0" };

/// One server's tools as listed, or null when it could not be.
pub const Source = struct {
    server: []const u8,
    listed: ?[]const Listing.Entry,
};

/// The two sources of a name they both offer. A built-in's source is
/// `built_in_source`.
pub const Collision = struct {
    name: []const u8 = "",
    first: []const u8 = "",
    second: []const u8 = "",
};

pub const built_in_source = "Rui";

pub const Error = error{ OutOfMemory, ToolNameCollision, TooManyTools };

const Item = struct { record: tools.Record, source: []const u8 };

fn before(_: void, a: Item, b: Item) bool {
    return std.mem.order(u8, a.record.name, b.record.name) == .lt;
}

/// The built-ins plus each source's tools, sorted by name. A listed source
/// contributes what it listed; an unlisted one, its records in `saved`.
/// Everything the result points to is `listed`'s, `saved`'s or `arena`'s.
pub fn merge(arena: std.mem.Allocator, saved: ?*const tools.Catalog, sources: []const Source, collision: *Collision) Error!tools.Catalog {
    var items: std.ArrayList(Item) = .empty;
    for (tools.built_in.records) |record| try items.append(arena, .{ .record = record, .source = built_in_source });
    for (sources) |source| {
        if (source.listed) |entries| {
            for (entries) |entry| try items.append(arena, .{ .source = source.server, .record = .{
                .name = entry.name,
                .description = entry.description orelse "",
                .input_schema = entry.input_schema,
                .owner = .mcp,
                .server = source.server,
            } });
        } else if (saved) |catalog| {
            for (catalog.records) |record| {
                if (record.owner == .mcp and std.mem.eql(u8, record.server, source.server))
                    try items.append(arena, .{ .record = record, .source = source.server });
            }
        }
    }
    if (items.items.len > tools.max_catalog_records) return error.TooManyTools;
    std.mem.sort(Item, items.items, {}, before);
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
    return .{ .records = records, .digests = digests };
}

pub const Fetched = union(enum) {
    listed: []const Listing.Entry,
    unreachable_,
    /// Two of the server's own tools share a name, or one has a schema that
    /// already names `rui_call_description`.
    collision: []const u8,
};

/// Lists one server's tools within `list_timeout_ms`, copying them into
/// `arena`. Anything but a complete listing leaves the server unreachable.
pub fn fetch(io: std.Io, arena: std.mem.Allocator, scratch: std.mem.Allocator, server: launch_frame.Frame.McpServer) Error!Fetched {
    const target = http1.parseTarget(server.url.slice()) catch return .unreachable_;
    const entries = try scratch.alloc(Listing.Entry, entries_per_server);
    defer scratch.free(entries);
    const room = try scratch.alloc(u8, arena_bytes + answer_bytes + request_bytes);
    defer scratch.free(room);
    const listing = try scratch.create(Listing);
    defer scratch.destroy(listing);
    listing.init(
        .{ .target = target, .bearer_token = server.bearer_token.slice() },
        client,
        .{
            .entries = entries,
            .arena = room[0..arena_bytes],
            .answer = room[arena_bytes..][0..answer_bytes],
            .request = room[arena_bytes + answer_bytes ..],
        },
    ) catch return .unreachable_;
    defer listing.deinit();
    const limit = deadline.after(std.Io.Clock.Timestamp.now(io, .awake), list_timeout_ms);
    while (true) {
        const outcome = listing.advance() catch |err| switch (err) {
            error.ToolNameCollision => return .{ .collision = try arena.dupe(u8, listing.collision orelse "") },
            else => return .unreachable_,
        };
        switch (outcome) {
            .listed => break,
            .unavailable => return .unreachable_,
            .waiting => {},
        }
        if (deadline.reached(std.Io.Clock.Timestamp.now(io, .awake), limit)) return .unreachable_;
        var fds = [_]std.posix.pollfd{.{ .fd = listing.fd(), .events = listing.events(), .revents = 0 }};
        _ = std.posix.poll(&fds, 100) catch return .unreachable_;
    }
    const copies = try arena.alloc(Listing.Entry, listing.entries().len);
    for (listing.entries(), copies) |entry, *copy| copy.* = .{
        .name = try arena.dupe(u8, entry.name),
        .description = if (entry.description) |text| try arena.dupe(u8, text) else null,
        .input_schema = try arena.dupe(u8, entry.input_schema),
        .read_only = entry.read_only,
    };
    if (listing.leftOut() != 0) stderr.diagnostic("rui: MCP server {s}: {d} tool(s) left out for a bad definition\n", .{ server.name.slice(), listing.leftOut() });
    return .{ .listed = copies };
}

/// Lists every server and merges the result with `saved`. On a collision
/// the error is `ToolNameCollision` and `collision` says between which.
pub fn collect(
    io: std.Io,
    arena: std.mem.Allocator,
    scratch: std.mem.Allocator,
    servers: []const launch_frame.Frame.McpServer,
    saved: ?*const tools.Catalog,
    collision: *Collision,
) Error!tools.Catalog {
    const sources = try arena.alloc(Source, servers.len);
    for (servers, sources) |server, *source| {
        const name = try arena.dupe(u8, server.name.slice());
        source.* = .{ .server = name, .listed = null };
        switch (try fetch(io, arena, scratch, server)) {
            .listed => |entries| source.listed = entries,
            .unreachable_ => stderr.diagnostic("rui: MCP server {s} did not list its tools; keeping its saved tools\n", .{name}),
            .collision => |tool| {
                collision.* = .{ .name = tool, .first = name, .second = name };
                return error.ToolNameCollision;
            },
        }
    }
    return merge(arena, saved, sources, collision);
}

fn listed(name: []const u8) Listing.Entry {
    return .{ .name = name, .description = "d", .input_schema = "{\"type\":\"object\"}", .read_only = false };
}

test "listed tools join the built-ins in name order" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var collision: Collision = .{};
    const found = [_]Listing.Entry{ listed("search"), listed("alpha") };
    const merged = try merge(memory.allocator(), null, &.{.{ .server = "docs", .listed = &found }}, &collision);
    try std.testing.expect(merged.valid());
    try std.testing.expectEqual(tools.built_in.records.len + 2, merged.records.len);
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

test "a server removed from the frame loses its saved tools" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var collision: Collision = .{};
    const found = [_]Listing.Entry{listed("gone")};
    const saved = try merge(memory.allocator(), null, &.{.{ .server = "old", .listed = &found }}, &collision);
    const again = try merge(memory.allocator(), &saved, &.{}, &collision);
    try std.testing.expectEqual(tools.built_in.records.len, again.records.len);
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
