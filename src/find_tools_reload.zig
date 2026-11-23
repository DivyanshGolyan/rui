//! The model's `find_tools` reload. A reload asks every configured MCP server to list again, waits for those
//! lists to land, and reports how the Host tool set changed since the ask. This file is the pure core: the
//! Host's shell asks the re-list owner, reads its status and passes the landed flags in. Records live in memory
//! on the Host, keyed by Action id, so a restarted Host forgets them (see `Decision.restarted`).

const std = @import("std");
const tool_record = @import("tool_record.zig");

const HostToolSet = tool_record.HostToolSet;

/// One offered tool as it stood when a reload asked: its offered name and its record digest.
pub const Seen = struct { name: []const u8, digest: [32]u8 };

/// What a reload remembers between its ask and its settlement. Everything lives in `arena`.
pub const Record = struct {
    arena: std.heap.ArenaAllocator,
    /// The generation each configured server was asked for, in configured order.
    generations: []const u64,
    before: []const Seen,
};

/// What the Host does with a reload Action this pass.
pub const Decision = enum {
    /// No MCP server is configured: the reload reports that and asks nothing.
    no_servers,
    /// Take the snapshot and ask every server, then wait.
    ask,
    /// The asked lists have not all landed.
    wait,
    /// Every asked list has landed: report the change.
    report,
    /// No record, and the Action predates this process: its lists are not known. Report the current state.
    restarted,
};

/// `landed` is null when no record exists; otherwise whether every asked list has landed.
pub fn decide(servers: usize, landed: ?bool, action_id: u64, watermark: u64) Decision {
    if (servers == 0) return .no_servers;
    if (landed) |done| return if (done) .report else .wait;
    return if (action_id <= watermark) .restarted else .ask;
}

/// Copies a set's names and digests into `arena`, the reload's view at ask time.
pub fn snapshot(arena: std.mem.Allocator, set: *const HostToolSet) ![]const Seen {
    const seen = try arena.alloc(Seen, set.records.len);
    for (set.records, set.digests, seen) |record, digest, *each| each.* = .{ .name = try arena.dupe(u8, record.name), .digest = digest };
    return seen;
}

fn seenIndex(seen: []const Seen, name: []const u8) ?usize {
    for (seen, 0..) |each, index| if (std.mem.eql(u8, each.name, name)) return index;
    return null;
}

const Change = enum { added, removed, changed };

/// Writes ` Label: a, b.` for one kind of change and returns how many names it wrote.
fn writeChange(out: *std.Io.Writer, comptime label: []const u8, comptime change: Change, before: []const Seen, after: *const HostToolSet) !usize {
    var count: usize = 0;
    switch (change) {
        .added => for (after.records) |record| {
            if (seenIndex(before, record.name) == null) try writeName(out, label, &count, record.name);
        },
        .changed => for (after.records, after.digests) |record, digest| {
            if (seenIndex(before, record.name)) |index| {
                if (!std.mem.eql(u8, &before[index].digest, &digest)) try writeName(out, label, &count, record.name);
            }
        },
        .removed => for (before) |each| {
            if (after.find(each.name) == null) try writeName(out, label, &count, each.name);
        },
    }
    if (count != 0) try out.writeAll(".");
    return count;
}

fn writeName(out: *std.Io.Writer, comptime label: []const u8, count: *usize, name: []const u8) !void {
    try out.writeAll(if (count.* == 0) " " ++ label ++ ": " else ", ");
    try out.writeAll(name);
    count.* += 1;
}

/// Writes the report of a reload that landed: the tools added, removed and changed between `before` and `after`,
/// by offered name, then each server that failed to list. `failed` names those servers.
pub fn report(out: *std.Io.Writer, before: []const Seen, after: *const HostToolSet, failed: []const []const u8) !void {
    try out.writeAll("Reloaded MCP tools.");
    const added = try writeChange(out, "Added", .added, before, after);
    const removed = try writeChange(out, "Removed", .removed, before, after);
    const changed = try writeChange(out, "Changed", .changed, before, after);
    if (added + removed + changed == 0) try out.writeAll(" No tools were added, removed or changed.");
    if (failed.len != 0) {
        try out.writeAll("\nThese MCP servers did not list their tools, so they keep their saved tools:");
        for (failed) |name| try out.print(" {s}", .{name});
        try out.writeAll(".");
    }
}

/// Writes the report of a reload whose Action predates this process: the lists it asked for are unknown.
pub fn restarted(out: *std.Io.Writer, after: *const HostToolSet) !void {
    var offered: usize = 0;
    for (after.records) |record| {
        if (record.owner == .mcp) offered += 1;
    }
    try out.print("Rui restarted before this reload finished, so it cannot tell which tools changed and reports no changes. It offers {d} MCP tool(s) now.", .{offered});
}

test "decide covers every reload state, with and without a record, before and after a restart" {
    const Case = struct { servers: usize, landed: ?bool, action_id: u64, watermark: u64, want: Decision };
    for ([_]Case{
        .{ .servers = 0, .landed = null, .action_id = 5, .watermark = 9, .want = .no_servers },
        .{ .servers = 0, .landed = false, .action_id = 5, .watermark = 9, .want = .no_servers },
        .{ .servers = 2, .landed = null, .action_id = 10, .watermark = 9, .want = .ask },
        .{ .servers = 2, .landed = null, .action_id = 9, .watermark = 9, .want = .restarted },
        .{ .servers = 2, .landed = null, .action_id = 3, .watermark = 9, .want = .restarted },
        .{ .servers = 2, .landed = false, .action_id = 3, .watermark = 9, .want = .wait },
        .{ .servers = 2, .landed = true, .action_id = 10, .watermark = 9, .want = .report },
    }) |case| {
        try std.testing.expectEqual(case.want, decide(case.servers, case.landed, case.action_id, case.watermark));
    }
}

test "a reload reports added, removed and changed tools by offered name, and failed servers" {
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const kept: [32]u8 = @splat(1);
    const edited: [32]u8 = @splat(2);
    const fresh: [32]u8 = @splat(3);
    const before = [_]Seen{
        .{ .name = "alpha", .digest = kept },
        .{ .name = "beta", .digest = kept },
        .{ .name = "gone", .digest = kept },
    };
    const records = [_]tool_record.Record{
        .{ .name = "alpha", .owner = .mcp, .server = "docs" },
        .{ .name = "beta", .owner = .mcp, .server = "docs" },
        .{ .name = "new", .owner = .mcp, .server = "docs" },
    };
    const digests = [_][32]u8{ kept, edited, fresh };
    const after: HostToolSet = .{ .records = &records, .digests = &digests };
    var out: std.Io.Writer.Allocating = .init(arena);
    try report(&out.writer, &before, &after, &.{"notes"});
    try std.testing.expectEqualStrings(
        "Reloaded MCP tools. Added: new. Removed: gone. Changed: beta.\nThese MCP servers did not list their tools, so they keep their saved tools: notes.",
        out.written(),
    );
}

test "a reload with no change says so, and a restarted reload reports only the tools offered now" {
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const digest: [32]u8 = @splat(7);
    const records = [_]tool_record.Record{.{ .name = "alpha", .owner = .mcp, .server = "docs" }};
    const digests = [_][32]u8{digest};
    const after: HostToolSet = .{ .records = &records, .digests = &digests };
    const before = try snapshot(arena, &after);
    var out: std.Io.Writer.Allocating = .init(arena);
    try report(&out.writer, before, &after, &.{});
    try std.testing.expectEqualStrings("Reloaded MCP tools. No tools were added, removed or changed.", out.written());
    var restart: std.Io.Writer.Allocating = .init(arena);
    try restarted(&restart.writer, &after);
    try std.testing.expectEqualStrings(
        "Rui restarted before this reload finished, so it cannot tell which tools changed and reports no changes. It offers 1 MCP tool(s) now.",
        restart.written(),
    );
}
