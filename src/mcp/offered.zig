const std = @import("std");
const protocol = @import("../protocol.zig");
const tools = @import("../tools.zig");
const hs = @import("../host_settings.zig");
const Connection = @import("../server_mcp_settings.zig").Server;
const http1 = @import("../http1/request.zig");
const Listing = @import("Listing.zig");
const post = @import("post.zig");
const pages = @import("../os/pages.zig");

pub const list_timeout_ms = 10_000;

const entries_per_server = tools.max_host_tool_records;
const prefix_separator = @import("../tool_record.zig").prefix_separator;
const tool_name = @import("../tool_name.zig");
const arena_bytes = 4 * 1024 * 1024;
const answer_bytes = 512 * 1024;
const request_bytes = 8 * 1024;

pub const client: post.Client = .{ .name = "rui", .version = protocol.wire_version };

pub const Source = struct {
    server: []const u8,
    /// The server's complete new list, or null when the server did not list (its saved tools stay).
    listed: ?[]const Listing.Entry,
    /// Tools Listing left out of `listed` for a bad definition or for capacity.
    listed_left_out: u32 = 0,
};

pub const built_in_source = "Rui";

pub const Error = error{OutOfMemory};

/// One tool the merge left out. `source` indexes `sources`; `name` is the name the server listed.
pub const Drop = struct {
    source: usize,
    name: []const u8,
    reason: Reason,

    pub const Reason = enum {
        listed_twice,
        too_long,
        clashes,
        over_limit,

        pub fn text(self: Reason) []const u8 {
            return switch (self) {
                .listed_twice => "listed twice by its server",
                .too_long => "name too long after prefix",
                .clashes => "name still clashes",
                .over_limit => std.fmt.comptimePrint("more than {d} tools offered in all", .{tools.max_host_tool_records}),
            };
        }
    };
};

/// What the merge left out, in arena memory. The Host logs each drop and counts it per server.
pub const Report = struct {
    drops: []const Drop = &.{},

    /// The tools of `source` that the merge left out.
    pub fn droppedFrom(self: *const Report, source: usize) u32 {
        var count: u32 = 0;
        for (self.drops) |drop| if (drop.source == source) {
            count += 1;
        };
        return count;
    }
};

const Item = struct {
    /// Null for a built-in, which always keeps its name.
    source: ?usize,
    server: []const u8,
    /// The name the server listed (a built-in's own name).
    remote: []const u8,
    /// The offered name, set once the naming rule has run.
    name: []const u8 = "",
    reason: ?Drop.Reason = null,
    record: tools.Record,
};

fn byRemote(_: void, a: Item, b: Item) bool {
    return std.mem.order(u8, a.remote, b.remote) == .lt;
}

fn byName(_: void, a: Item, b: Item) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Builds a tool set whose bytes all live in `arena`: the result borrows nothing from
/// `saved`, `sources` or the listed entries, so those may be freed as soon as this returns.
///
/// The offer is decided among the candidates only: built-ins, then each server's tools in `sources`
/// order, each server's in listed-name order. A name a server lists twice leaves both entries out. Above
/// the record limit the first candidates are kept and the rest are left out. Among the kept tools, a
/// built-in keeps its name; a listed name offered more than once is offered as `<server>__<listed name>`;
/// any other tool keeps its listed name. A prefixed name that is too long or still clashes leaves its tool
/// out. Every tool left out is in `report`, with its reason.
pub noinline fn merge(arena: std.mem.Allocator, saved: ?*const tools.HostToolSet, sources: []const Source, report: *Report) Error!tools.HostToolSet {
    var items: std.ArrayList(Item) = .empty;
    for (tools.built_in_tool_set.records) |record| try items.append(arena, .{ .source = null, .server = "", .remote = record.name, .name = record.name, .record = record });
    for (sources, 0..) |source, index| {
        if (source.listed) |entries| {
            for (entries) |entry| try items.append(arena, mcpItem(index, source.server, entry.name, .{
                .name = "",
                .description = entry.description orelse "",
                .input_schema = entry.input_schema,
                .owner = .mcp,
                .server = source.server,
            }));
        } else if (saved) |tool_set| {
            for (tool_set.records) |record| {
                if (record.owner == .mcp and std.mem.eql(u8, record.server, source.server))
                    try items.append(arena, mcpItem(index, source.server, record.remoteName(), record));
            }
        }
    }

    var drops: std.ArrayList(Drop) = .empty;
    var candidates: std.ArrayList(Item) = .empty;
    for (items.items) |item| if (item.source == null) try candidates.append(arena, item);
    for (sources, 0..) |_, index| {
        var own: std.ArrayList(Item) = .empty;
        for (items.items) |item| if (item.source == index) try own.append(arena, item);
        std.mem.sort(Item, own.items, {}, byRemote);
        for (own.items, 0..) |item, at| {
            const twice = (at > 0 and std.mem.eql(u8, own.items[at - 1].remote, item.remote)) or
                (at + 1 < own.items.len and std.mem.eql(u8, own.items[at + 1].remote, item.remote));
            if (twice) try drops.append(arena, .{ .source = index, .name = item.remote, .reason = .listed_twice }) else try candidates.append(arena, item);
        }
    }
    const kept = candidates.items[0..@min(candidates.items.len, tools.max_host_tool_records)];
    for (candidates.items[kept.len..]) |item| try drops.append(arena, .{ .source = item.source.?, .name = item.remote, .reason = .over_limit });

    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    for (kept) |item| {
        const found = try counts.getOrPut(arena, item.remote);
        found.value_ptr.* = if (found.found_existing) found.value_ptr.* + 1 else 1;
    }
    var plain: std.StringHashMapUnmanaged(void) = .empty;
    for (kept) |*item| {
        if (item.source == null or counts.get(item.remote).? == 1) {
            item.name = item.remote;
            try plain.put(arena, item.name, {});
            continue;
        }
        item.name = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ item.server, prefix_separator, item.remote });
        if (item.name.len > tool_name.max_bytes) item.reason = .too_long;
    }
    var prefixed: std.StringHashMapUnmanaged(u32) = .empty;
    for (kept) |item| if (item.source != null and counts.get(item.remote).? != 1 and item.reason == null) {
        const found = try prefixed.getOrPut(arena, item.name);
        found.value_ptr.* = if (found.found_existing) found.value_ptr.* + 1 else 1;
    };
    for (kept) |*item| {
        if (item.source == null or counts.get(item.remote).? == 1 or item.reason != null) continue;
        if (plain.contains(item.name) or prefixed.get(item.name).? > 1) item.reason = .clashes;
    }

    var selected: std.ArrayList(Item) = .empty;
    for (kept) |item| {
        if (item.reason) |reason| {
            try drops.append(arena, .{ .source = item.source.?, .name = item.remote, .reason = reason });
        } else {
            try selected.append(arena, item);
        }
    }
    report.* = .{ .drops = drops.items };

    std.mem.sort(Item, selected.items, {}, byName);
    const records = try arena.alloc(tools.Record, selected.items.len);
    const digests = try arena.alloc([32]u8, selected.items.len);
    for (selected.items, records, digests) |item, *record, *digest| {
        record.* = if (item.source == null) item.record else .{
            .name = try arena.dupe(u8, item.name),
            .remote_name = try arena.dupe(u8, item.remote),
            .description = try arena.dupe(u8, item.record.description),
            .input_schema = try arena.dupe(u8, item.record.input_schema),
            .owner = .mcp,
            .server = try arena.dupe(u8, item.server),
        };
        digest.* = tools.recordDigest(record);
    }
    const configured_servers = try arena.alloc([]const u8, sources.len);
    for (sources, configured_servers) |source, *name| name.* = try arena.dupe(u8, source.server);
    return .{ .records = records, .digests = digests, .configured_servers = configured_servers };
}

fn mcpItem(source: usize, server: []const u8, remote: []const u8, record: tools.Record) Item {
    return .{ .source = source, .server = server, .remote = remote, .record = record };
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
    entries: []Listing.Entry,
    room: []u8,
    listing: Listing,
    deadline_ms: u64,

    pub const Step = union(enum) { waiting, listed, failed };

    /// Begins listing `server`. Null when the server cannot be listed at all (a bad URL or no room).
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
            .entries = entries,
            .room = room,
            .listing = undefined,
            .deadline_ms = now_ms +| list_timeout_ms,
        };
        self.listing.init(
            .{ .target = target, .bearer_token = server.bearer_token.slice(), .label = server.name.slice() },
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
        const outcome = self.listing.advance() catch return .failed;
        return switch (outcome) {
            .waiting => .waiting,
            .unavailable => .failed,
            .listed => .listed,
        };
    }

    /// Tools the list left out before the merge: bad definitions and tools past the listing's capacity.
    pub fn leftOut(self: *const Pending) u32 {
        return @intCast(self.listing.leftOut());
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

fn offeredOwner(merged: *const tools.HostToolSet, name: []const u8) ?tools.Record {
    const at = merged.find(name) orelse return null;
    return merged.records[at];
}

test "listed tools join the built-ins in name order" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var report: Report = .{};
    const found = [_]Listing.Entry{ listed("search"), listed("alpha") };
    const merged = try merge(memory.allocator(), null, &.{.{ .server = "docs", .listed = &found }}, &report);
    try std.testing.expect(merged.valid());
    try std.testing.expectEqual(tools.built_in_tool_set.records.len + 2, merged.records.len);
    const at = merged.find("search").?;
    try std.testing.expectEqual(tools.Owner.mcp, merged.records[at].owner);
    try std.testing.expectEqualStrings("docs", merged.records[at].server);
    try std.testing.expectEqualStrings("search", merged.records[at].remote_name);
    try std.testing.expect(merged.find("bash") != null);
    try std.testing.expectEqual(@as(usize, 0), report.drops.len);
}

test "EXR-68 a clash with a built-in is offered under the server prefix, and the built-in keeps its name" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var report: Report = .{};
    const found = [_]Listing.Entry{listed("bash")};
    const merged = try merge(memory.allocator(), null, &.{.{ .server = "docs", .listed = &found }}, &report);
    try std.testing.expect(merged.valid());
    try std.testing.expectEqual(tools.Owner.rui, merged.records[merged.find("bash").?].owner);
    const prefixed = offeredOwner(&merged, "docs__bash").?;
    try std.testing.expectEqual(tools.Owner.mcp, prefixed.owner);
    try std.testing.expectEqualStrings("bash", prefixed.remote_name);
    try std.testing.expectEqual(@as(?usize, null), merged.find("bash__docs"));
    try std.testing.expectEqual(@as(usize, 0), report.drops.len);
}

test "EXR-68 two servers that list one name are both offered under their prefixes" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var report: Report = .{};
    const found = [_]Listing.Entry{listed("search")};
    const merged = try merge(memory.allocator(), null, &.{
        .{ .server = "a", .listed = &found },
        .{ .server = "b", .listed = &found },
    }, &report);
    try std.testing.expect(merged.valid());
    try std.testing.expectEqual(@as(?usize, null), merged.find("search"));
    try std.testing.expectEqualStrings("a", offeredOwner(&merged, "a__search").?.server);
    try std.testing.expectEqualStrings("search", offeredOwner(&merged, "a__search").?.remote_name);
    try std.testing.expectEqualStrings("b", offeredOwner(&merged, "b__search").?.server);
    try std.testing.expectEqual(@as(usize, 0), report.drops.len);
}

test "EXR-68 a prefixed name over the byte limit leaves its tool out with its reason" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var report: Report = .{};
    const long_a_bytes: [40]u8 = @splat('a');
    const long_b_bytes: [40]u8 = @splat('b');
    const raw_bytes: [30]u8 = @splat('t');
    const long_a: []const u8 = &long_a_bytes;
    const long_b: []const u8 = &long_b_bytes;
    const raw: []const u8 = &raw_bytes;
    const plain = [_]Listing.Entry{listed("keep")};
    const clash = [_]Listing.Entry{ listed(raw), listed("keep2") };
    const merged = try merge(memory.allocator(), null, &.{
        .{ .server = long_a, .listed = &clash },
        .{ .server = long_b, .listed = &.{listed(raw)} },
        .{ .server = "c", .listed = &plain },
    }, &report);
    try std.testing.expect(merged.valid());
    try std.testing.expectEqual(@as(?usize, null), merged.find(raw));
    try std.testing.expect(merged.find("keep2") != null);
    try std.testing.expectEqual(@as(usize, 2), report.drops.len);
    for (report.drops) |drop| {
        try std.testing.expectEqualStrings(raw, drop.name);
        try std.testing.expectEqual(Drop.Reason.too_long, drop.reason);
    }
    try std.testing.expectEqual(@as(u32, 1), report.droppedFrom(0));
    try std.testing.expectEqual(@as(u32, 1), report.droppedFrom(1));
    try std.testing.expectEqual(@as(u32, 0), report.droppedFrom(2));
}

test "EXR-68 a prefixed name that clashes leaves its tool out while the other tool keeps its name" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var report: Report = .{};
    const x = [_]Listing.Entry{listed("x")};
    const plain = [_]Listing.Entry{listed("a__x")};
    const merged = try merge(memory.allocator(), null, &.{
        .{ .server = "a", .listed = &x },
        .{ .server = "b", .listed = &x },
        .{ .server = "c", .listed = &plain },
    }, &report);
    try std.testing.expect(merged.valid());
    try std.testing.expectEqualStrings("c", offeredOwner(&merged, "a__x").?.server);
    try std.testing.expectEqualStrings("b", offeredOwner(&merged, "b__x").?.server);
    try std.testing.expectEqual(@as(usize, 1), report.drops.len);
    try std.testing.expectEqual(@as(usize, 0), report.drops[0].source);
    try std.testing.expectEqual(Drop.Reason.clashes, report.drops[0].reason);
}

test "a name a server lists twice is left out by both entries" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var report: Report = .{};
    const found = [_]Listing.Entry{ listed("twice"), listed("twice"), listed("once") };
    const merged = try merge(memory.allocator(), null, &.{.{ .server = "docs", .listed = &found }}, &report);
    try std.testing.expect(merged.valid());
    try std.testing.expectEqual(@as(?usize, null), merged.find("twice"));
    try std.testing.expect(merged.find("once") != null);
    try std.testing.expectEqual(@as(u32, 2), report.droppedFrom(0));
    for (report.drops) |drop| try std.testing.expectEqual(Drop.Reason.listed_twice, drop.reason);
}

test "EXR-68 the same tools in a different source order give the same offered names and servers" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const x = [_]Listing.Entry{ listed("x"), listed("bash") };
    const y = [_]Listing.Entry{ listed("x"), listed("y") };
    const z = [_]Listing.Entry{listed("a__x")};
    var report_one: Report = .{};
    var report_two: Report = .{};
    const one = try merge(memory.allocator(), null, &.{
        .{ .server = "a", .listed = &x },
        .{ .server = "b", .listed = &y },
        .{ .server = "c", .listed = &z },
    }, &report_one);
    const two = try merge(memory.allocator(), null, &.{
        .{ .server = "c", .listed = &z },
        .{ .server = "b", .listed = &y },
        .{ .server = "a", .listed = &x },
    }, &report_two);
    try std.testing.expectEqual(one.records.len, two.records.len);
    for (one.records, one.digests) |record, digest| {
        const at = two.find(record.name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(record.server, two.records[at].server);
        try std.testing.expectEqualStrings(record.remote_name, two.records[at].remote_name);
        try std.testing.expectEqualSlices(u8, &digest, &two.digests[at]);
    }
    try std.testing.expectEqual(report_one.drops.len, report_two.drops.len);
}

test "EXR-68 over the record limit the built-ins and then the servers in configuration order are kept" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const built_ins = tools.built_in_tool_set.records.len;
    const per_server = 600;
    const first = try memory.allocator().alloc(Listing.Entry, per_server);
    const second = try memory.allocator().alloc(Listing.Entry, per_server);
    for (first, second, 0..) |*one, *two, index| {
        one.* = listed(try std.fmt.allocPrint(memory.allocator(), "f{d:0>3}", .{index}));
        two.* = listed(try std.fmt.allocPrint(memory.allocator(), "s{d:0>3}", .{index}));
    }
    var report: Report = .{};
    const merged = try merge(memory.allocator(), null, &.{
        .{ .server = "first", .listed = first },
        .{ .server = "second", .listed = second },
    }, &report);
    try std.testing.expect(merged.valid());
    try std.testing.expectEqual(tools.max_host_tool_records, merged.records.len);
    const kept_second = tools.max_host_tool_records - built_ins - per_server;
    try std.testing.expect(merged.find("f599") != null);
    try std.testing.expect(merged.find(try std.fmt.allocPrint(memory.allocator(), "s{d:0>3}", .{kept_second - 1})) != null);
    try std.testing.expect(merged.find(try std.fmt.allocPrint(memory.allocator(), "s{d:0>3}", .{kept_second})) == null);
    try std.testing.expectEqual(@as(u32, 0), report.droppedFrom(0));
    try std.testing.expectEqual(@as(u32, per_server - kept_second), report.droppedFrom(1));
    for (report.drops) |drop| try std.testing.expectEqual(Drop.Reason.over_limit, drop.reason);
}

test "an unlisted server keeps its saved tools and a listed one replaces them" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var report: Report = .{};
    const before_up = [_]Listing.Entry{listed("old_up")};
    const before_down = [_]Listing.Entry{listed("kept")};
    const saved = try merge(memory.allocator(), null, &.{
        .{ .server = "up", .listed = &before_up },
        .{ .server = "down", .listed = &before_down },
    }, &report);
    const fresh = [_]Listing.Entry{listed("new_up")};
    const again = try merge(memory.allocator(), &saved, &.{
        .{ .server = "up", .listed = &fresh },
        .{ .server = "down", .listed = null },
    }, &report);
    try std.testing.expect(again.find("new_up") != null);
    try std.testing.expect(again.find("old_up") == null);
    try std.testing.expectEqualStrings("down", again.records[again.find("kept").?].server);
}

test "a server removed from settings loses its saved tools" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var report: Report = .{};
    const found = [_]Listing.Entry{listed("gone")};
    const saved = try merge(memory.allocator(), null, &.{.{ .server = "old", .listed = &found }}, &report);
    const again = try merge(memory.allocator(), &saved, &.{}, &report);
    try std.testing.expectEqual(tools.built_in_tool_set.records.len, again.records.len);
}

test "a saved tool of an unreachable server and a fresh one with its name are both prefixed" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    var report: Report = .{};
    const found = [_]Listing.Entry{listed("search")};
    const saved = try merge(memory.allocator(), null, &.{.{ .server = "down", .listed = &found }}, &report);
    const again = try merge(memory.allocator(), &saved, &.{
        .{ .server = "down", .listed = null },
        .{ .server = "up", .listed = &found },
    }, &report);
    try std.testing.expectEqual(@as(?usize, null), again.find("search"));
    try std.testing.expectEqualStrings("search", offeredOwner(&again, "down__search").?.remote_name);
    try std.testing.expectEqualStrings("search", offeredOwner(&again, "up__search").?.remote_name);
    try std.testing.expectEqual(@as(usize, 0), report.drops.len);
}

test "a tool dropped for the record limit does not make its clashing peer take a prefix" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const per_server = 600;
    const first = try memory.allocator().alloc(Listing.Entry, per_server + 1);
    const second = try memory.allocator().alloc(Listing.Entry, per_server + 1);
    for (first[0..per_server], second[0..per_server], 0..) |*one, *two, index| {
        one.* = listed(try std.fmt.allocPrint(memory.allocator(), "f{d:0>3}", .{index}));
        two.* = listed(try std.fmt.allocPrint(memory.allocator(), "s{d:0>3}", .{index}));
    }
    // `zzz` sorts last in each server, so the limit drops the second server's copy and keeps the first's.
    first[per_server] = listed("zzz");
    second[per_server] = listed("zzz");
    var report: Report = .{};
    const merged = try merge(memory.allocator(), null, &.{
        .{ .server = "first", .listed = first },
        .{ .server = "second", .listed = second },
    }, &report);
    try std.testing.expect(merged.valid());
    try std.testing.expectEqual(@as(usize, 0), report.droppedFrom(0));
    try std.testing.expect(report.droppedFrom(1) > 0);
    for (report.drops) |drop| try std.testing.expectEqual(Drop.Reason.over_limit, drop.reason);
    try std.testing.expectEqualStrings("first", merged.records[merged.find("zzz").?].server);
    try std.testing.expectEqual(@as(?usize, null), merged.find("first__zzz"));
}

test "MCP missing tools distinguish empty servers from saved copies without guessing ownership" {
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    var report: Report = .{};
    const entries = [_]Listing.Entry{listed("kept")};
    const saved = try merge(memory.allocator(), null, &.{.{ .server = "notes", .listed = &entries }}, &report);
    for ([_]struct { sources: []const Source, previous: ?*const tools.HostToolSet = null, unavailable: bool }{
        .{ .sources = &.{}, .unavailable = false },
        .{ .sources = &.{.{ .server = "notes", .listed = &entries }}, .unavailable = false },
        .{ .sources = &.{.{ .server = "notes", .listed = null }}, .unavailable = true },
        .{ .sources = &.{.{ .server = "notes", .listed = &.{} }}, .unavailable = true },
        .{ .sources = &.{.{ .server = "notes", .listed = null }}, .previous = &saved, .unavailable = false },
        .{ .sources = &.{ .{ .server = "notes", .listed = null }, .{ .server = "other", .listed = null } }, .previous = &saved, .unavailable = true },
    }) |case| {
        const host_tool_set = try merge(memory.allocator(), case.previous, case.sources, &report);
        try std.testing.expectEqualStrings(if (case.unavailable) "mcp_server_unavailable" else "unknown_tool", @tagName(host_tool_set.resolve("lookup")));
        try std.testing.expect(host_tool_set.resolve("bash") == .found);
        if (case.previous != null) try std.testing.expect(host_tool_set.resolve("kept") == .found);
    }

    const host_tool_set = try merge(memory.allocator(), null, &.{ .{ .server = "notes", .listed = null }, .{ .server = "other", .listed = null } }, &report);
    var buffer: [tools.HostToolSet.max_refusal_message_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try host_tool_set.writeMissingTool("lookup", &writer);
    try std.testing.expectEqualStrings("spec.tools: lookup is not a known tool; MCP servers notes, other are unavailable and may provide it", writer.buffered());
}

test "MCP missing tools maximum launch names fit the request and start_agent diagnostic" {
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    var report: Report = .{};
    var names: [hs.max_mcp_servers][hs.max_mcp_name_bytes]u8 = undefined;
    var sources: [names.len]Source = undefined;
    for (&names, &sources, 0..) |*name, *source, index| {
        @memset(name, @as(u8, 'a') + @as(u8, @intCast(index)));
        source.* = .{ .server = name, .listed = null };
    }
    const host_tool_set = try merge(memory.allocator(), null, &sources, &report);
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
    var report: Report = .{};
    const old_up = [_]Listing.Entry{.{ .name = try listed_memory.allocator().dupe(u8, "old_up"), .description = "old", .input_schema = "{\"type\":\"object\"}" }};
    const kept = [_]Listing.Entry{.{ .name = try listed_memory.allocator().dupe(u8, "kept"), .description = "stays", .input_schema = "{\"type\":\"object\"}" }};
    const saved = try merge(saved_memory.allocator(), null, &.{
        .{ .server = "up", .listed = &old_up },
        .{ .server = "down", .listed = &kept },
    }, &report);
    const fresh = [_]Listing.Entry{.{ .name = try listed_memory.allocator().dupe(u8, "new_up"), .description = "fresh", .input_schema = "{\"type\":\"object\"}" }};
    const merged = try merge(merged_memory.allocator(), &saved, &.{
        .{ .server = "up", .listed = &fresh },
        .{ .server = "down", .listed = null },
    }, &report);
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
