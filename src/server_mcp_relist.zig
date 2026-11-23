const std = @import("std");
const hs = @import("host_settings.zig");
const relist = @import("mcp/relist.zig");
const offered = @import("mcp/offered.zig");
const Listing = @import("mcp/Listing.zig");
const tools = @import("tools.zig");
const stderr = @import("stderr.zig");
const store_module = @import("store.zig");
const server_mcp_settings = @import("server_mcp_settings.zig");
const tool_name = @import("tool_name.zig");

/// The one owner of MCP tool lists. Startup and the execution loop both ask it;
/// nothing else lists a server. Each server has at most one list in flight, and a
/// complete list is published in one Store step.
pub const Refusal = union(enum) {
    collision: struct { name: [tool_name.max_bytes]u8 = undefined, name_len: usize = 0, first: []const u8, second: []const u8 },
    too_many,

    fn named(listed_name: []const u8, first: []const u8, second: []const u8) Refusal {
        var refusal: Refusal = .{ .collision = .{ .first = first, .second = second } };
        const length = @min(listed_name.len, tool_name.max_bytes);
        @memcpy(refusal.collision.name[0..length], listed_name[0..length]);
        refusal.collision.name_len = length;
        return refusal;
    }

    pub fn tool(self: *const Refusal) []const u8 {
        return self.collision.name[0..self.collision.name_len];
    }
};

pub const Relist = struct {
    allocator: std.mem.Allocator,
    servers: []const server_mcp_settings.Server,
    slots: [hs.max_mcp_servers]relist.Slot = @splat(.{}),
    asks: [hs.max_mcp_servers]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0)),
    pending: [hs.max_mcp_servers]?*offered.Pending = @splat(null),
    /// While startup runs, landed lists wait here so all first attempts publish in one merge.
    held: ?*[hs.max_mcp_servers]bool = null,
    /// Why the latest list was refused, kept for startup's report.
    refusal: ?Refusal = null,
    /// The arena holding the tool set this owner published. Null while the current set is startup's.
    current: ?std.heap.ArenaAllocator = null,

    /// `servers` must outlive the owner.
    pub fn init(allocator: std.mem.Allocator, servers: []const server_mcp_settings.Server) Relist {
        return .{ .allocator = allocator, .servers = servers };
    }

    pub fn deinit(self: *Relist) void {
        for (&self.pending) |*slot_pending| {
            if (slot_pending.*) |pending| pending.finish();
            slot_pending.* = null;
        }
        if (self.current) |*arena| arena.deinit();
        self.current = null;
    }

    /// Records a request to list `index`; any thread may call it. Returns the ask's generation.
    pub fn ask(self: *Relist, index: usize) u64 {
        return self.asks[index].fetchAdd(1, .acq_rel) + 1;
    }

    /// True while any server has a list in flight.
    pub fn listing(self: *const Relist) bool {
        for (self.pending) |pending| if (pending != null) return true;
        return false;
    }

    /// The earliest awake-clock millisecond the owner needs service again, or null.
    pub fn wakeAt(self: *const Relist) ?u64 {
        var earliest: ?u64 = null;
        for (&self.slots) |*slot| {
            const at = slot.wakeAt() orelse continue;
            earliest = if (earliest) |current| @min(current, at) else at;
        }
        return earliest;
    }

    /// Startup: asks every server and drives the same `service` step until every first
    /// attempt has ended, holding the lists that land, then publishes them with the saved
    /// tools of every other configured server in one merge (dropping servers no longer
    /// configured). A server that did not list keeps its saved tools and is retried by
    /// backoff once the Host serves. A refused merge refuses the start: the configuration
    /// is wrong now.
    pub fn startup(self: *Relist, io: std.Io, store: *store_module.Store, saved: ?*const tools.HostToolSet, stop: ?std.posix.fd_t) !void {
        var held: [hs.max_mcp_servers]bool = @splat(false);
        self.held = &held;
        defer self.held = null;
        for (0..self.servers.len) |index| _ = self.ask(index);
        while (true) {
            var failure: ?anyerror = null;
            _ = self.service(store, offered.nowMs(io), &failure);
            if (failure) |err| return err;
            if (self.firstAttemptsEnded()) break;
            var fds: [hs.max_mcp_servers + 1]std.posix.pollfd = undefined;
            var polled: usize = 0;
            for (self.pending[0..self.servers.len], held[0..self.servers.len]) |slot_pending, waiting| if (slot_pending) |pending| if (!waiting) {
                fds[polled] = .{ .fd = pending.fd(), .events = pending.events(), .revents = 0 };
                polled += 1;
            };
            fds[polled] = .{ .fd = stop orelse -1, .events = std.posix.POLL.IN, .revents = 0 };
            _ = std.posix.poll(fds[0 .. polled + 1], 100) catch {};
            if (fds[polled].revents != 0) return error.Stopped;
        }
        var fresh: [hs.max_mcp_servers]?[]const Listing.Entry = @splat(null);
        for (0..self.servers.len) |index| if (held[index]) {
            fresh[index] = self.pending[index].?.listed();
        };
        const outcome = try self.publish(store, saved, fresh[0..self.servers.len]);
        const now_ms = offered.nowMs(io);
        for (0..self.servers.len) |index| if (held[index]) self.settle(index, outcome, now_ms);
        var refused = outcome == .collision;
        for (self.slots[0..self.servers.len]) |slot| refused = refused or slot.last == .collision;
        if (refused) return switch (self.refusal.?) {
            .collision => error.ToolNameCollision,
            .too_many => error.TooManyTools,
        };
    }

    fn firstAttemptsEnded(self: *const Relist) bool {
        for (self.slots[0..self.servers.len], 0..) |slot, index| if (slot.finished == 0 and !self.held.?[index]) return false;
        return true;
    }

    /// Test driver: services at a fixed `now_ms` until no list is in flight and every
    /// due list has run. Returns the first publish failure.
    pub fn settleForTesting(self: *Relist, io: std.Io, store: *store_module.Store, now_ms: u64) !?anyerror {
        if (!@import("builtin").is_test) @compileError("test-only driver");
        const poll = @import("test_poll");
        const Drive = struct {
            owner: *Relist,
            store: *store_module.Store,
            now_ms: u64,
            failure: ?anyerror = null,
            fn settled(drive: *@This()) bool {
                _ = drive.owner.service(drive.store, drive.now_ms, &drive.failure);
                if (drive.failure != null) return true;
                if (drive.owner.listing()) return false;
                for (drive.owner.slots[0..drive.owner.servers.len]) |*slot| if (slot.due(drive.now_ms)) return false;
                return true;
            }
        };
        var drive: Drive = .{ .owner = self, .store = store, .now_ms = now_ms };
        try poll.waitUntil(io, poll.after(io, .fromSeconds(30)), &drive, Drive.settled);
        return drive.failure;
    }

    /// Drives every server's list once against `store` at `now_ms`. Returns true when
    /// anything progressed. A failed publish is written to `failure` and stops the pass.
    pub fn service(self: *Relist, store: *store_module.Store, now_ms: u64, failure: *?anyerror) bool {
        var progress = false;
        for (0..self.servers.len) |index| {
            const want = self.asks[index].load(.acquire);
            while (self.slots[index].asked < want) {
                _ = self.slots[index].want();
                progress = true;
            }
        }
        for (0..self.servers.len) |index| {
            if (self.held) |held| if (held[index]) continue;
            const slot = &self.slots[index];
            if (self.pending[index]) |pending| switch (pending.advance()) {
                .waiting => if (pending.expired(now_ms)) {
                    self.diagnoseFailure(index);
                    self.settle(index, .failed, now_ms);
                    progress = true;
                },
                .listed => {
                    progress = true;
                    if (self.held) |held| {
                        held[index] = true;
                        continue;
                    }
                    var fresh: [hs.max_mcp_servers]?[]const Listing.Entry = @splat(null);
                    fresh[index] = pending.listed();
                    const outcome = self.publish(store, store.hostTools().host_tool_set, fresh[0..self.servers.len]) catch |err| {
                        failure.* = err;
                        self.settle(index, .failed, now_ms);
                        return progress;
                    };
                    self.settle(index, outcome, now_ms);
                },
                .failed => {
                    self.diagnoseFailure(index);
                    self.settle(index, .failed, now_ms);
                    progress = true;
                },
                .collision => |name| {
                    const server = self.servers[index].name.slice();
                    stderr.diagnostic("rui: MCP server {s} lists tool {s} twice; keeping its saved tools\n", .{ server, name });
                    self.refusal = .named(name, server, server);
                    self.settle(index, .collision, now_ms);
                    progress = true;
                },
            };
            if (self.pending[index] == null and slot.due(now_ms)) {
                slot.begin();
                progress = true;
                self.pending[index] = offered.Pending.start(self.allocator, &self.servers[index], now_ms);
                if (self.pending[index] == null) {
                    self.diagnoseFailure(index);
                    slot.end(.failed, now_ms);
                }
            }
        }
        return progress;
    }

    fn settle(self: *Relist, index: usize, outcome: relist.Outcome, now_ms: u64) void {
        self.pending[index].?.finish();
        self.pending[index] = null;
        self.slots[index].end(outcome, now_ms);
    }

    fn diagnoseFailure(self: *const Relist, index: usize) void {
        stderr.diagnostic("rui: MCP server {s} did not list its tools; keeping its saved tools\n", .{self.servers[index].name.slice()});
    }

    /// Merges one complete list into the current set and swaps it into the Store.
    /// The previous set's arena is freed only after the Store has taken the new one.
    /// `fresh` holds, per configured server, its complete new list or null; `base`
    /// supplies the tools of every server whose entry is null.
    fn publish(self: *Relist, store: *store_module.Store, base: ?*const tools.HostToolSet, fresh: []const ?[]const Listing.Entry) !relist.Outcome {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const memory = arena.allocator();
        const sources = try memory.alloc(offered.Source, self.servers.len);
        for (self.servers, sources, 0..) |*server, *source, at| source.* = .{
            .server = server.name.slice(),
            .listed = fresh[at],
        };
        var collision: offered.Collision = .{};
        const set = offered.merge(memory, base, sources, &collision) catch |err| switch (err) {
            error.ToolNameCollision => {
                stderr.diagnostic("rui: MCP tool {s} is offered by {s} and by {s}; keeping the previous tools\n", .{ collision.name, collision.first, collision.second });
                self.refusal = .named(collision.name, collision.first, collision.second);
                arena.deinit();
                return .collision;
            },
            error.TooManyTools => {
                stderr.diagnostic("rui: MCP servers list more tools than a Host offers; keeping the previous tools\n", .{});
                self.refusal = .too_many;
                arena.deinit();
                return .collision;
            },
            else => |other| return other,
        };
        const owned = try memory.create(tools.HostToolSet);
        owned.* = set;
        try store.saveHostToolSet(owned);
        if (self.current) |*previous| previous.deinit();
        self.current = arena;
        return .listed;
    }
};

test "re-list folds asks made during a list into one more list" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    const first = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"alpha\",\"inputSchema\":{\"type\":\"object\"}}]}}");
    const second = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"beta\",\"inputSchema\":{\"type\":\"object\"}}]}}");
    var script: Script = .{ .reply = first, .more = &.{second} };
    try script.start();
    defer script.stop();
    var url: [128]u8 = undefined;
    var server: server_mcp_settings.Server = .{};
    try server.name.set("docs");
    @memcpy(server.bearer_token.bytes[0..6], "secret");
    server.bearer_token.len = 6;
    try server.url.set(try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/mcp", .{script.port}));
    const servers = [_]server_mcp_settings.Server{server};
    var owner = Relist.init(std.testing.allocator, &servers);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module_testing.testingStoreToolSet(&storage, &tmp, std.testing.io, null);
    defer storage.close() catch unreachable;

    // Two asks before the first list begins, then one more while it is in flight.
    _ = owner.ask(0);
    _ = owner.ask(0);
    var failure: ?anyerror = null;
    _ = owner.service(&storage, 0, &failure);
    _ = owner.ask(0);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(std.testing.io, &storage, 0));
    try std.testing.expectEqual(@as(u64, 3), owner.slots[0].finished);
    try std.testing.expectEqual(@as(?anyerror, null), failure);
    try std.testing.expectEqual(@as(usize, 2), script.requests.load(.acquire));
    try std.testing.expect(storage.hostTools().host_tool_set.find("beta") != null);
    try std.testing.expect(storage.hostTools().host_tool_set.find("alpha") == null);
}
