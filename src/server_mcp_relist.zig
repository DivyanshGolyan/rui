const std = @import("std");
const hs = @import("host_settings.zig");
const relist = @import("mcp/relist.zig");
const offered = @import("mcp/offered.zig");
const Listing = @import("mcp/Listing.zig");
const tools = @import("tools.zig");
const stderr = @import("stderr.zig");
const store_module = @import("store.zig");
const server_mcp_settings = @import("server_mcp_settings.zig");

comptime {
    std.debug.assert(hs.max_mcp_servers <= tools.HostToolSet.max_servers);
}

/// The one owner of MCP tool lists. Startup and the execution loop both ask it;
/// nothing else lists a server. Each server has at most one list in flight, and a
/// complete list is published in one Store step. A list is never refused over its
/// tools' names or count: tools the merge cannot offer are left out and logged.
pub const Relist = struct {
    /// `status` packed into one atomic word: state (2 bits), last (2 bits), tools (28 bits).
    const Packed = packed struct(u64) { state: u2, last: u2, tools: u28, left_out: u32 };

    /// What `publishView` writes for one server. Intake threads read it lock-free.
    const View = struct {
        finished: std.atomic.Value(u64) = .init(0),
        status: std.atomic.Value(u64) = .init(0),
    };

    allocator: std.mem.Allocator,
    servers: []const server_mcp_settings.Server,
    slots: [hs.max_mcp_servers]relist.Slot = @splat(.{}),
    asks: [hs.max_mcp_servers]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0)),
    pending: [hs.max_mcp_servers]?*offered.Pending = @splat(null),
    views: [hs.max_mcp_servers]View = @splat(.{}),
    /// Tool records per server in the set last published. Only the execution thread writes it.
    tools: [hs.max_mcp_servers]u28 = @splat(0),
    /// Tools left out of the set last published, per server. Only the execution thread writes it.
    left_out: [hs.max_mcp_servers]u32 = @splat(0),
    /// While startup runs, landed lists wait here so all first attempts publish in one merge.
    held: ?*[hs.max_mcp_servers]bool = null,
    /// Configured server names with the settings' lifetime; every published set's
    /// `configured_servers` is this slice, so a missing-tool refusal can outlive the set.
    names: [hs.max_mcp_servers][]const u8 = undefined,
    /// The arena holding the tool set this owner published. Null while the current set is startup's.
    current: ?std.heap.ArenaAllocator = null,
    /// Each server's last complete list, which every publish merges, so a server's offered names follow the
    /// lists now in force rather than the set saved before. Only the execution thread touches it.
    kept: [hs.max_mcp_servers]Kept = @splat(.{}),

    /// One server's kept list: its entries and listing-level left-out count, copied into `arena`.
    const Kept = struct {
        arena: ?std.heap.ArenaAllocator = null,
        entries: []const Listing.Entry = &.{},
        left_out: u32 = 0,

        /// Copies a listed server's entries, which the listing frees when it finishes.
        fn copy(allocator: std.mem.Allocator, listed: []const Listing.Entry, left_out: u32) !Kept {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const memory = arena.allocator();
            const entries = try memory.alloc(Listing.Entry, listed.len);
            for (listed, entries) |entry, *each| each.* = .{
                .name = try memory.dupe(u8, entry.name),
                .description = if (entry.description) |text| try memory.dupe(u8, text) else null,
                .input_schema = try memory.dupe(u8, entry.input_schema),
            };
            return .{ .arena = arena, .entries = entries, .left_out = left_out };
        }

        fn deinit(self: *Kept) void {
            if (self.arena) |*arena| arena.deinit();
            self.* = .{};
        }
    };

    /// `servers` must outlive the owner.
    pub fn init(allocator: std.mem.Allocator, servers: []const server_mcp_settings.Server) Relist {
        return .{ .allocator = allocator, .servers = servers };
    }

    pub fn deinit(self: *Relist) void {
        for (&self.pending) |*slot_pending| {
            if (slot_pending.*) |pending| pending.finish();
            slot_pending.* = null;
        }
        for (&self.kept) |*each| each.deinit();
        if (self.current) |*arena| arena.deinit();
        self.current = null;
    }

    /// Records a request to list `index`; any thread may call it. Returns the ask's generation.
    pub fn ask(self: *Relist, index: usize) u64 {
        return self.asks[index].fetchAdd(1, .acq_rel) + 1;
    }

    /// Reads server `index`'s published status from any thread. `finished` is loaded first, so a
    /// reader that sees generation g also sees a status at least as new as the list that finished g.
    pub fn status(self: *const Relist, index: usize) relist.Status {
        const view = &self.views[index];
        const finished = view.finished.load(.acquire);
        const packed_status: Packed = @bitCast(view.status.load(.acquire));
        return .{ .state = @fromBackingInt(@intCast(packed_status.state)), .last = @fromBackingInt(@intCast(packed_status.last)), .finished = finished, .tools = packed_status.tools, .left_out = packed_status.left_out };
    }

    /// Publishes server `index`'s slot and tool count for intake reads. The execution thread calls it
    /// after every change to that slot. The status is stored before `finished`, which `status` relies on.
    fn publishView(self: *Relist, index: usize) void {
        const slot = &self.slots[index];
        const view = &self.views[index];
        const packed_status: Packed = .{ .state = @backingInt(slot.state), .last = @backingInt(slot.last), .tools = self.tools[index], .left_out = self.left_out[index] };
        view.status.store(@bitCast(packed_status), .release);
        view.finished.store(slot.finished, .release);
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
    /// backoff once the Host serves. Startup never refuses over tools: the merge leaves out what
    /// it cannot offer and logs it.
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
        try self.publish(store, saved, held[0..self.servers.len]);
        const now_ms = offered.nowMs(io);
        for (0..self.servers.len) |index| if (held[index]) self.settle(index, .listed, now_ms);
        for (0..self.servers.len) |index| self.publishView(index);
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
                    var landed: [hs.max_mcp_servers]bool = @splat(false);
                    landed[index] = true;
                    self.publish(store, store.hostTools().host_tool_set, landed[0..self.servers.len]) catch |err| {
                        failure.* = err;
                        self.settle(index, .failed, now_ms);
                        return progress;
                    };
                    self.settle(index, .listed, now_ms);
                },
                .failed => {
                    self.diagnoseFailure(index);
                    self.settle(index, .failed, now_ms);
                    progress = true;
                },
            };
            if (self.pending[index] == null and slot.due(now_ms)) {
                slot.begin();
                self.publishView(index);
                progress = true;
                self.pending[index] = offered.Pending.start(self.allocator, &self.servers[index], now_ms);
                if (self.pending[index] == null) {
                    self.diagnoseFailure(index);
                    slot.end(.failed, now_ms);
                    self.publishView(index);
                }
            }
        }
        return progress;
    }

    fn settle(self: *Relist, index: usize, outcome: relist.Outcome, now_ms: u64) void {
        self.pending[index].?.finish();
        self.pending[index] = null;
        self.slots[index].end(outcome, now_ms);
        self.publishView(index);
    }

    /// Counts the MCP records in `set` that server `name` owns.
    fn countOwned(set: *const tools.HostToolSet, name: []const u8) u28 {
        var count: usize = 0;
        for (set.records) |record| {
            if (record.owner == .mcp and std.mem.eql(u8, record.server, name)) count += 1;
        }
        return @intCast(count);
    }

    fn diagnoseFailure(self: *const Relist, index: usize) void {
        stderr.diagnostic("rui: MCP server {s} did not list its tools; keeping its saved tools\n", .{self.servers[index].name.slice()});
    }

    /// Merges the kept lists into a new set and swaps it into the Store. `landed` marks the servers whose
    /// pending list has just completed: each takes a copy of it as its kept list once the Store has the set.
    /// A server with no kept list keeps its tools from `base`. Every server's tool count and left-out count
    /// are recomputed from this merge, and each tool the merge leaves out is logged. The previous set's arena
    /// is freed only after the Store has taken the new one.
    fn publish(self: *Relist, store: *store_module.Store, base: ?*const tools.HostToolSet, landed: []const bool) !void {
        var next: [hs.max_mcp_servers]Kept = @splat(.{});
        errdefer for (&next) |*each| each.deinit();
        for (landed, 0..) |listed, index| if (listed) {
            const pending = self.pending[index].?;
            next[index] = try Kept.copy(self.allocator, pending.listed(), pending.leftOut());
        };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const memory = arena.allocator();
        const sources = try memory.alloc(offered.Source, self.servers.len);
        for (self.servers, sources, 0..) |*server, *source, index| {
            const kept = if (next[index].arena != null) &next[index] else &self.kept[index];
            source.* = .{
                .server = server.name.slice(),
                .listed = if (kept.arena != null) kept.entries else null,
                .listed_left_out = kept.left_out,
            };
        }
        var report: offered.Report = .{};
        const set = try offered.merge(memory, base, sources, &report);
        for (report.drops) |drop| stderr.diagnostic("rui: MCP server {s}: tool {s} left out: {s}\n", .{ self.servers[drop.source].name.slice(), drop.name, drop.reason.text() });
        const owned = try memory.create(tools.HostToolSet);
        owned.* = set;
        for (self.servers, self.names[0..self.servers.len]) |*server, *name| name.* = server.name.slice();
        owned.configured_servers = self.names[0..self.servers.len];
        try store.saveHostToolSet(owned);

        for (&next, &self.kept) |*copy, *kept| if (copy.arena != null) {
            kept.deinit();
            kept.* = copy.*;
            copy.* = .{};
        };
        for (self.servers, 0..) |*server, index| {
            self.tools[index] = countOwned(owned, server.name.slice());
            self.left_out[index] = sources[index].listed_left_out + report.droppedFrom(index);
            self.publishView(index);
        }
        if (self.current) |*previous| previous.deinit();
        self.current = arena;
    }
};

/// A listing reply for `names`, each with the object schema the merge needs.
fn listReply(comptime names: []const []const u8) []const u8 {
    const Script = @import("mcp/test_server.zig");
    const body = comptime blk: {
        var text: []const u8 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[";
        for (names, 0..) |name, index| {
            if (index != 0) text = text ++ ",";
            text = text ++ "{\"name\":\"" ++ name ++ "\",\"inputSchema\":{\"type\":\"object\"}}";
        }
        break :blk text ++ "]}}";
    };
    return Script.jsonReply(body);
}

test "a re-list of one server decides every server's names from the lists now in force" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    const io = std.testing.io;
    var docs_script: Script = .{ .reply = listReply(&.{"search"}) };
    try docs_script.start();
    defer docs_script.stop();
    var notes_script: Script = .{ .reply = listReply(&.{"keep"}), .more = &.{
        listReply(&.{ "search", "keep" }),
        listReply(&.{ "search", "keep", "docs__search" }),
        listReply(&.{"keep"}),
    } };
    try notes_script.start();
    defer notes_script.stop();
    var docs_url: [128]u8 = undefined;
    var notes_url: [128]u8 = undefined;
    var docs: server_mcp_settings.Server = .{};
    try docs.name.set("docs");
    @memcpy(docs.bearer_token.bytes[0..6], "secret");
    docs.bearer_token.len = 6;
    try docs.url.set(try std.fmt.bufPrint(&docs_url, "http://127.0.0.1:{d}/mcp", .{docs_script.port}));
    var notes: server_mcp_settings.Server = .{};
    try notes.name.set("notes");
    @memcpy(notes.bearer_token.bytes[0..6], "secret");
    notes.bearer_token.len = 6;
    try notes.url.set(try std.fmt.bufPrint(&notes_url, "http://127.0.0.1:{d}/mcp", .{notes_script.port}));
    const servers = [_]server_mcp_settings.Server{ docs, notes };
    var owner = Relist.init(std.testing.allocator, &servers);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module_testing.testingStoreToolSet(&storage, &tmp, io, null);
    defer storage.close() catch unreachable;

    // Startup: both lists land, so docs offers `search` plainly.
    _ = owner.ask(0);
    _ = owner.ask(1);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));
    try std.testing.expectEqualStrings("docs", storage.hostTools().host_tool_set.records[storage.hostTools().host_tool_set.find("search").?].server);

    // Notes lists `search` too: both are prefixed, and docs's status counts its offered tool.
    _ = owner.ask(1);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));
    var set = storage.hostTools().host_tool_set;
    try std.testing.expectEqual(@as(?usize, null), set.find("search"));
    try std.testing.expectEqualStrings("docs", set.records[set.find("docs__search").?].server);
    try std.testing.expectEqualStrings("notes", set.records[set.find("notes__search").?].server);
    try std.testing.expectEqual(1, owner.status(0).tools);
    try std.testing.expectEqual(0, owner.status(0).left_out);

    // Notes lists `docs__search` plainly as well: docs's `search` now clashes and is left out, which docs's status shows.
    _ = owner.ask(1);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));
    set = storage.hostTools().host_tool_set;
    try std.testing.expectEqual(0, owner.status(0).tools);
    try std.testing.expectEqual(1, owner.status(0).left_out);
    try std.testing.expectEqualStrings("notes", set.records[set.find("docs__search").?].server);

    // Notes stops listing `search`: docs's `search` comes back without docs listing again.
    _ = owner.ask(1);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));
    set = storage.hostTools().host_tool_set;
    try std.testing.expectEqualStrings("docs", set.records[set.find("search").?].server);
    try std.testing.expectEqual(@as(?usize, null), set.find("docs__search"));
    try std.testing.expectEqual(1, owner.status(0).tools);
    try std.testing.expectEqual(0, owner.status(0).left_out);
    try std.testing.expectEqual(@as(usize, 1), docs_script.requests.load(.acquire));
}

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

test "a list in flight keeps its generation: an ask made mid-list waits for the next list" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    const poll = @import("test_poll");
    const io = std.testing.io;
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
    try store_module_testing.testingStoreToolSet(&storage, &tmp, io, null);
    defer storage.close() catch unreachable;

    const Reach = struct {
        owner: *Relist,
        storage: *store_module.Store,
        target: u64,
        failure: ?anyerror = null,

        fn reached(drive: *@This()) bool {
            _ = drive.owner.service(drive.storage, 0, &drive.failure);
            return drive.failure != null or drive.owner.status(0).finished >= drive.target;
        }
    };

    // Generation 1 begins its list; generation 2 is asked while that list is in flight.
    try std.testing.expectEqual(@as(u64, 1), owner.ask(0));
    var begin_failure: ?anyerror = null;
    _ = owner.service(&storage, 0, &begin_failure);
    try std.testing.expect(owner.listing());
    try std.testing.expectEqual(@as(u64, 2), owner.ask(0));

    // The list in flight lands generation 1 alone. The next list begins at once for generation 2.
    var landing: Reach = .{ .owner = &owner, .storage = &storage, .target = 1 };
    try poll.waitUntil(io, poll.after(io, .fromSeconds(30)), &landing, Reach.reached);
    try std.testing.expectEqual(@as(?anyerror, null), landing.failure);
    try std.testing.expectEqual(@as(u64, 1), owner.status(0).finished);
    try std.testing.expect(owner.listing());

    // The next service lists again and reaches generation 2.
    var reaching: Reach = .{ .owner = &owner, .storage = &storage, .target = 2 };
    try poll.waitUntil(io, poll.after(io, .fromSeconds(30)), &reaching, Reach.reached);
    try std.testing.expectEqual(@as(?anyerror, null), reaching.failure);
    try std.testing.expectEqual(@as(u64, 2), owner.status(0).finished);
    try std.testing.expectEqual(@as(usize, 2), script.requests.load(.acquire));
    try std.testing.expect(storage.hostTools().host_tool_set.find("beta") != null);
}

test "published status follows each list and keeps its tool count through a failed list" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    const alpha = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"alpha\",\"inputSchema\":{\"type\":\"object\"}}]}}");
    const alpha_beta = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"alpha\",\"inputSchema\":{\"type\":\"object\"}},{\"name\":\"beta\",\"inputSchema\":{\"type\":\"object\"}}]}}");
    const down = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n";
    var script: Script = .{ .reply = alpha, .more = &.{ down, alpha_beta } };
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

    try std.testing.expectEqual(relist.Status{ .state = .idle, .last = .never, .finished = 0, .tools = 0, .left_out = 0 }, owner.status(0));

    // A list that lands: one tool, generation 1 finished, last listed.
    const first = owner.ask(0);
    try serviceUntilFinished(&owner, &storage, first);
    try std.testing.expectEqual(relist.Status{ .state = .idle, .last = .listed, .finished = 1, .tools = 1, .left_out = 0 }, owner.status(0));

    // A list that fails keeps the tool count it had and waits out its backoff.
    const second = owner.ask(0);
    try serviceUntilFinishedQuietly(&owner, &storage, second);
    try std.testing.expectEqual(relist.Status{ .state = .waiting, .last = .failed, .finished = 2, .tools = 1, .left_out = 0 }, owner.status(0));

    // The next list that lands sets the count to what it listed.
    const third = owner.ask(0);
    try serviceUntilFinished(&owner, &storage, third);
    try std.testing.expectEqual(relist.Status{ .state = .idle, .last = .listed, .finished = 3, .tools = 2, .left_out = 0 }, owner.status(0));
    try std.testing.expect(storage.hostTools().host_tool_set.find("beta") != null);
}

/// Drives a list that fails. Its diagnostic goes to a pipe, not the test output, and the test checks it was written.
fn serviceUntilFinishedQuietly(owner: *Relist, storage: *store_module.Store, generation: u64) !void {
    var pipe: [2]c_int = undefined;
    if (std.c.pipe(&pipe) != 0) return error.SystemResources;
    const saved = std.c.dup(2);
    if (saved < 0 or std.c.dup2(pipe[1], 2) < 0) return error.TestUnexpectedResult;
    const result = serviceUntilFinished(owner, storage, generation);
    _ = std.c.dup2(saved, 2);
    _ = std.c.close(saved);
    _ = std.c.close(pipe[1]);
    defer _ = std.c.close(pipe[0]);
    try result;
    var buffer: [256]u8 = undefined;
    const read = std.c.read(pipe[0], &buffer, buffer.len);
    try std.testing.expect(read > 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer[0..@intCast(read)], "did not list its tools") != null);
}

fn serviceUntilFinished(owner: *Relist, storage: *store_module.Store, generation: u64) !void {
    var failure: ?anyerror = null;
    var attempts: usize = 0;
    while (owner.status(0).finished < generation or owner.listing()) : (attempts += 1) {
        if (attempts == 1000) return error.ListDidNotFinish;
        if (owner.pending[0]) |pending| {
            var poll_fd = [_]std.c.pollfd{.{ .fd = pending.fd(), .events = pending.events(), .revents = 0 }};
            _ = std.c.poll(&poll_fd, 1, 100);
        }
        _ = owner.service(storage, 0, &failure);
    }
    try std.testing.expectEqual(@as(?anyerror, null), failure);
}
