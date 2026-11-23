const std = @import("std");
const hs = @import("host_settings.zig");
const relist = @import("mcp/relist.zig");
const offered = @import("mcp/offered.zig");
const Listing = @import("mcp/Listing.zig");
const tools = @import("tools.zig");
const stderr = @import("stderr.zig");
const store_module = @import("store.zig");
const server_mcp_settings = @import("server_mcp_settings.zig");

/// The one owner of MCP tool lists. Startup and the execution loop both ask it;
/// nothing else lists a server. Each server has at most one list in flight, and a
/// complete list is published in one Store step.
pub const Relist = struct {
    allocator: std.mem.Allocator,
    servers: []const server_mcp_settings.Server,
    slots: [hs.max_mcp_servers]relist.Slot = @splat(.{}),
    asks: [hs.max_mcp_servers]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0)),
    pending: [hs.max_mcp_servers]?*offered.Pending = @splat(null),
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

    /// Startup: every server begins its first list at once, the lists are driven together
    /// until each ends or `list_timeout_ms` passes, and one merge builds the startup set.
    /// Servers that did not list keep their saved tools and are retried by backoff.
    pub fn listAtStartup(
        self: *Relist,
        io: std.Io,
        arena: std.mem.Allocator,
        saved: ?*const tools.HostToolSet,
        stop: ?std.posix.fd_t,
        collision: *offered.Collision,
    ) offered.Error!tools.HostToolSet {
        const count = self.servers.len;
        const started = offered.nowMs(io);
        var open: [hs.max_mcp_servers]bool = @splat(false);
        var result: [hs.max_mcp_servers]relist.Outcome = @splat(.failed);
        defer for (self.pending[0..count]) |*slot_pending| {
            if (slot_pending.*) |pending| pending.finish();
            slot_pending.* = null;
        };
        for (0..count) |index| {
            _ = self.slots[index].want();
            self.slots[index].begin();
            self.pending[index] = offered.Pending.start(self.allocator, &self.servers[index], started);
            if (self.pending[index] == null) self.diagnoseFailure(index);
            open[index] = self.pending[index] != null;
        }
        var now = started;
        while (true) {
            var waiting: usize = 0;
            for (0..count) |index| {
                if (!open[index]) continue;
                switch (self.pending[index].?.advance()) {
                    .waiting => if (self.pending[index].?.expired(now)) {
                        open[index] = false;
                        self.diagnoseFailure(index);
                    } else {
                        waiting += 1;
                    },
                    .listed => {
                        open[index] = false;
                        result[index] = .listed;
                    },
                    .failed => {
                        open[index] = false;
                        self.diagnoseFailure(index);
                    },
                    .collision => |name| {
                        const owner = self.servers[index].name.slice();
                        collision.* = .{ .name = try arena.dupe(u8, name), .first = owner, .second = owner };
                        return error.ToolNameCollision;
                    },
                }
            }
            if (waiting == 0) break;
            var fds: [hs.max_mcp_servers + 1]std.posix.pollfd = undefined;
            var polled: usize = 0;
            for (0..count) |index| {
                if (!open[index]) continue;
                const pending = self.pending[index].?;
                fds[polled] = .{ .fd = pending.fd(), .events = pending.events(), .revents = 0 };
                polled += 1;
            }
            fds[polled] = .{ .fd = stop orelse -1, .events = std.posix.POLL.IN, .revents = 0 };
            _ = std.posix.poll(fds[0 .. polled + 1], 100) catch {
                for (0..count) |index| if (open[index]) {
                    open[index] = false;
                    self.diagnoseFailure(index);
                };
                break;
            };
            if (fds[polled].revents != 0) return error.Stopped;
            now = offered.nowMs(io);
        }
        var sources: [hs.max_mcp_servers]offered.Source = undefined;
        for (0..count) |index| {
            const pending = self.pending[index];
            sources[index] = .{
                .server = self.servers[index].name.slice(),
                .listed = if (result[index] == .listed) pending.?.listed() else null,
            };
            self.slots[index].end(result[index], now);
        }
        return offered.merge(arena, saved, sources[0..count], collision);
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
            const slot = &self.slots[index];
            if (self.pending[index]) |pending| switch (pending.advance()) {
                .waiting => if (pending.expired(now_ms)) {
                    self.diagnoseFailure(index);
                    self.settle(index, .failed, now_ms);
                    progress = true;
                },
                .listed => {
                    progress = true;
                    const outcome = self.publish(store, index, pending.listed()) catch |err| {
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
                    stderr.diagnostic("rui: MCP server {s} lists tool {s} twice; keeping its saved tools\n", .{ self.servers[index].name.slice(), name });
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
    fn publish(self: *Relist, store: *store_module.Store, index: usize, entries: []const Listing.Entry) !relist.Outcome {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const memory = arena.allocator();
        const sources = try memory.alloc(offered.Source, self.servers.len);
        for (self.servers, sources, 0..) |*server, *source, at| source.* = .{
            .server = server.name.slice(),
            .listed = if (at == index) entries else null,
        };
        var collision: offered.Collision = .{};
        const set = offered.merge(memory, store.hostTools().host_tool_set, sources, &collision) catch |err| switch (err) {
            error.ToolNameCollision => {
                stderr.diagnostic("rui: MCP tool {s} is offered by {s} and by {s}; keeping the previous tools\n", .{ collision.name, collision.first, collision.second });
                arena.deinit();
                return .collision;
            },
            error.TooManyTools => {
                stderr.diagnostic("rui: MCP servers list more tools than a Host offers; keeping the previous tools\n", .{});
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
    var attempts: usize = 0;
    while (owner.slots[0].finished != 3 or owner.listing()) : (attempts += 1) {
        if (attempts == 1000) return error.ListDidNotFinish;
        if (owner.pending[0]) |pending| {
            var poll_fd = [_]std.c.pollfd{.{ .fd = pending.fd(), .events = pending.events(), .revents = 0 }};
            _ = std.c.poll(&poll_fd, 1, 100);
        }
        _ = owner.service(&storage, 0, &failure);
    }
    try std.testing.expectEqual(@as(?anyerror, null), failure);
    try std.testing.expectEqual(@as(usize, 2), script.requests.load(.acquire));
    try std.testing.expect(storage.hostTools().host_tool_set.find("beta") != null);
    try std.testing.expect(storage.hostTools().host_tool_set.find("alpha") == null);
}
