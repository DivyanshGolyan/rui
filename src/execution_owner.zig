const std = @import("std");
const execution = @import("execution.zig");
const action_attempt = @import("action_attempt.zig");
const host_reply = @import("host_reply.zig");
const host_settings = @import("host_settings.zig");
const session_report = @import("session_report.zig");
const server_host = @import("server_host.zig");
const server_mcp_relist = @import("server_mcp_relist.zig");
const store_module = @import("store.zig");

const Lifecycle = server_host.Lifecycle;
const Probes = server_host.Probes;

/// Guards what the execution thread shares with other threads: the custody pool and the MCP re-list owner.
pub const Execution = struct {
    custody: execution.CustodyPool,
    relist: ?*server_mcp_relist.Relist,
    lifecycle: *Lifecycle,
    scratch_used: *const std.atomic.Value(u64),

    /// Fills `self` in place, because the Store's model timing reads `self.custody` from here until `deinit`. A null
    /// `store` leaves no timing wired, for a test whose Store is not open.
    pub fn init(
        self: *Execution,
        records: []execution.CustodyRecord,
        relist: ?*server_mcp_relist.Relist,
        lifecycle: *Lifecycle,
        scratch_used: *const std.atomic.Value(u64),
        store: ?*store_module.Store,
    ) void {
        self.* = .{
            .custody = execution.CustodyPool.initialize(records),
            .relist = relist,
            .lifecycle = lifecycle,
            .scratch_used = scratch_used,
        };
        if (store) |open| open.modelTimingSource().* = self.custody.timingSource();
    }

    pub fn deinit(self: *Execution, store: *store_module.Store) void {
        _ = self;
        store.modelTimingSource().* = .{};
    }

    pub fn facts(self: *const Execution) session_report.Execution {
        return .{
            .dispatch_fenced = !self.lifecycle.launchAllowed(),
            .custody_occupied = self.custody.held(),
            .scratch_used_bytes = self.scratch_used.load(.acquire),
        };
    }

    /// The one ask for MCP lists: asks the re-list owner for `only` or every configured server, wakes the
    /// dispatch loop when anything was asked, and returns how many were asked. `tools_reload` and `find_tools`
    /// reload both call it, so neither path asks or wakes on its own.
    pub fn askMcpLists(self: *Execution, only: ?[]const u8, out: *[host_settings.max_mcp_servers]server_mcp_relist.Relist.Asked) usize {
        const count: usize = if (self.relist) |owner| owner.askAll(only, out) else 0;
        if (count != 0) self.lifecycle.wakeDispatch();
        return count;
    }

    /// Every configured server's published list status, read without waiting for the owner.
    pub fn mcpStatuses(self: *const Execution, rows: *[host_settings.max_mcp_servers]host_reply.ToolServerStatus) usize {
        const owner = self.relist orelse return 0;
        var count: usize = 0;
        for (owner.servers, 0..) |*server, index| {
            rows[count] = .{ .server = server.name.slice(), .status = owner.status(index), .listen = owner.streamState(index) };
            count += 1;
        }
        return count;
    }

    pub fn attempts(self: *Execution, store: *store_module.Store, probes: *Probes) action_attempt.Parts {
        return .{ .store = store, .lifecycle = self.lifecycle, .probes = probes, .custody = &self.custody };
    }

    /// The custody records the pool holds: the most attempts that can be in flight at once.
    pub fn capacity(self: *const Execution) usize {
        return self.custody.records.len;
    }
};

test "EXR-98 facts count held custody, not an in-flight admission reservation, beside the fence and scratch in force" {
    var records: [2]execution.CustodyRecord = @splat(.{});
    var lifecycle = Lifecycle.init(std.testing.io, undefined, false, null);
    var scratch_used: std.atomic.Value(u64) = .init(0);
    var owner: Execution = undefined;
    owner.init(&records, null, &lifecycle, &scratch_used, null);
    const cleanup = owner.custody.reserve().?;
    var permit = store_module.DispatchPermit{ .binding = .{ .turn_id = 1, .operation_id = 1, .attempt_ordinal = 1 } };
    _ = try owner.custody.attach(cleanup, &permit);
    try owner.custody.detach(cleanup);
    const probe = owner.custody.reserve().?;
    try std.testing.expectEqual(@as(usize, 1), owner.facts().custody_occupied);
    try std.testing.expectEqual(@as(usize, 2), owner.custody.occupied());
    try std.testing.expect(owner.custody.reserve() == null);
    try owner.custody.releaseUnused(probe);
    try std.testing.expectEqual(@as(usize, 1), owner.facts().custody_occupied);
    try owner.custody.cleanupComplete(cleanup);
    try std.testing.expectEqual(@as(usize, 0), owner.facts().custody_occupied);
    try std.testing.expect(!owner.facts().dispatch_fenced);
    scratch_used.store(4096, .release);
    try std.testing.expectEqual(@as(u64, 4096), owner.facts().scratch_used_bytes);
    try std.testing.expectEqual(@as(usize, 2), owner.capacity());
}

test "EXR-99 an MCP list ask wakes dispatch only when it asked a server" {
    const server_mcp_settings = @import("server_mcp_settings.zig");
    var docs: server_mcp_settings.Server = .{};
    try docs.name.set("docs");
    var notes: server_mcp_settings.Server = .{};
    try notes.name.set("notes");
    const servers = [_]server_mcp_settings.Server{ docs, notes };
    var relist = server_mcp_relist.Relist.init(std.testing.allocator, &servers, 1);
    defer relist.deinit();
    var scratch_used: std.atomic.Value(u64) = .init(0);
    var asked: [host_settings.max_mcp_servers]server_mcp_relist.Relist.Asked = undefined;
    var rows: [host_settings.max_mcp_servers]host_reply.ToolServerStatus = undefined;
    const Row = struct { relist: bool, only: ?[]const u8, asked: usize };
    for ([_]Row{
        .{ .relist = false, .only = null, .asked = 0 },
        .{ .relist = true, .only = "missing", .asked = 0 },
        .{ .relist = true, .only = "docs", .asked = 1 },
        .{ .relist = true, .only = null, .asked = 2 },
    }) |row| {
        var lifecycle = Lifecycle.init(std.testing.io, undefined, false, null);
        var owner: Execution = undefined;
        owner.init(&.{}, if (row.relist) &relist else null, &lifecycle, &scratch_used, null);
        try std.testing.expectEqual(row.asked, owner.askMcpLists(row.only, &asked));
        try std.testing.expectEqual(row.asked != 0, lifecycle.dispatchWakeIsSet());
        try std.testing.expectEqual(@as(usize, if (row.relist) servers.len else 0), owner.mcpStatuses(&rows));
    }
}
