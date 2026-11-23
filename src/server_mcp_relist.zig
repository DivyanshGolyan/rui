const std = @import("std");
const hs = @import("host_settings.zig");
const relist = @import("mcp/relist.zig");
const offered = @import("mcp/offered.zig");
const Listing = @import("mcp/Listing.zig");
const tools = @import("tools.zig");
const stderr = @import("stderr.zig");
const store_module = @import("store.zig");
const server_mcp_settings = @import("server_mcp_settings.zig");
const Listen = @import("server_mcp_listen.zig").Listen;
const listen_core = @import("mcp/listen.zig");

comptime {
    std.debug.assert(hs.max_mcp_servers <= tools.HostToolSet.max_servers);
}

/// The one owner of MCP tool lists. Startup and the execution loop both ask it;
/// nothing else lists a server. Each server has at most one list in flight, and a
/// complete list is published in one Store step. A list is never refused over its
/// tools' names or count: tools the merge cannot offer are left out and logged.
pub const Relist = struct {
    /// `status` packed into one atomic word: state (2 bits), last (2 bits), listen (2 bits), tools (26 bits).
    const Packed = packed struct(u64) { state: u2, last: u2, listen: u2, tools: u26, left_out: u32 };

    /// What `publishView` writes for one server. Intake threads read it lock-free.
    const View = struct {
        finished: std.atomic.Value(u64) = .init(0),
        status: std.atomic.Value(u64) = .init(0),
    };

    allocator: std.mem.Allocator,
    servers: []const server_mcp_settings.Server,
    /// Mixed into each list's jitter seed, so Hosts do not time their re-lists in step.
    seed: u64,
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
    /// Each server's `asks` generation the stream owner last saw, so a client ask reprobes a refusing stream once.
    /// Only the execution thread touches it.
    reprobed: [hs.max_mcp_servers]u64 = @splat(0),
    /// Each server's `subscriptions/listen` stream. Only the execution thread touches it.
    listen: Listen,

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
    pub fn init(allocator: std.mem.Allocator, servers: []const server_mcp_settings.Server, seed: u64) Relist {
        return .{ .allocator = allocator, .servers = servers, .seed = seed, .listen = Listen.init(allocator, servers, seed) };
    }

    pub fn deinit(self: *Relist) void {
        self.listen.deinit();
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

    /// One server's ask: its name and the generation it was given.
    pub const Asked = struct { server: []const u8, generation: u64 };

    /// Asks every configured server, or only the one named `only`, to list again. Writes each ask to `out` in
    /// configured order and returns how many were asked. Any thread may call it.
    pub fn askAll(self: *Relist, only: ?[]const u8, out: *[hs.max_mcp_servers]Asked) usize {
        var count: usize = 0;
        for (self.servers, 0..) |*server, index| {
            if (only) |name| if (!std.mem.eql(u8, name, server.name.slice())) continue;
            out[count] = .{ .server = server.name.slice(), .generation = self.ask(index) };
            count += 1;
        }
        return count;
    }

    /// Reads server `index`'s published status from any thread. `finished` is loaded first, so a
    /// reader that sees generation g also sees a status at least as new as the list that finished g.
    pub fn status(self: *const Relist, index: usize) relist.Status {
        const view = &self.views[index];
        const finished = view.finished.load(.acquire);
        const packed_status: Packed = @bitCast(view.status.load(.acquire));
        return .{ .state = @fromBackingInt(@intCast(packed_status.state)), .last = @fromBackingInt(@intCast(packed_status.last)), .finished = finished, .tools = packed_status.tools, .left_out = packed_status.left_out };
    }

    /// Reads server `index`'s `subscriptions/listen` state from any thread, from the same word as `status`.
    pub fn streamState(self: *const Relist, index: usize) listen_core.State {
        const packed_status: Packed = @bitCast(self.views[index].status.load(.acquire));
        return @fromBackingInt(@intCast(packed_status.listen));
    }

    /// Publishes server `index`'s slot and tool count for intake reads. The execution thread calls it
    /// after every change to that slot. The status is stored before `finished`, which `status` relies on.
    fn publishView(self: *Relist, index: usize) void {
        const slot = &self.slots[index];
        const view = &self.views[index];
        const packed_status: Packed = .{ .state = @backingInt(slot.state), .last = @backingInt(slot.last), .listen = @backingInt(self.listen.state(index)), .tools = @intCast(self.tools[index]), .left_out = self.left_out[index] };
        view.status.store(@bitCast(packed_status), .release);
        view.finished.store(slot.finished, .release);
    }

    /// True while any server has a list in flight.
    pub fn listing(self: *const Relist) bool {
        for (self.pending) |pending| if (pending != null) return true;
        return false;
    }

    /// The earliest awake-clock millisecond the owner needs service again, or null: a slot's, or a stream's reopen.
    pub fn wakeAt(self: *const Relist) ?u64 {
        var earliest: ?u64 = self.listen.wakeAt();
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
        for (0..self.servers.len) |index| if (held[index]) self.settleListed(index, now_ms);
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
                // A stream still opening has not yet been acknowledged or refused: settle once it has.
                for (drive.owner.listen.lines[0..drive.owner.servers.len]) |line| if (line.state == .opening) return false;
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
        // A client ask reprobes a stream that refused the subscription.
        for (0..self.servers.len) |index| {
            const want = self.asks[index].load(.acquire);
            if (want != self.reprobed[index]) {
                self.reprobed[index] = want;
                self.listen.reprobe(index);
            }
        }
        // Streams wait for startup's first attempts; then each acknowledgment and list change asks one re-list
        // through `ask`, the same generation counter a client ask uses.
        if (self.held == null) {
            var asked = self.listen.service(now_ms);
            while (asked.findFirstSet()) |index| {
                asked.unset(index);
                _ = self.ask(index);
            }
            for (0..self.servers.len) |index| self.publishView(index);
        }
        // The only caller of `Slot.want`: every ask, client or stream, reaches its slot here.
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
                    self.settleListed(index, now_ms);
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

    /// Settles a list that landed at `now_ms`: its ttl and this list's jitter seed set when it goes stale. Reads the
    /// ttl before `settle` frees the pending list.
    fn settleListed(self: *Relist, index: usize, now_ms: u64) void {
        // A server that refused its list may have recovered: its stream is probed again.
        if (self.slots[index].last == .failed) self.listen.reprobe(index);
        const pending = self.pending[index].?;
        const outcome: relist.Outcome = .{ .listed = .{
            .ttl_ms = pending.ttlMs(),
            .seed = relist.mix(self.seed, index, self.slots[index].started, now_ms),
        } };
        self.settle(index, outcome, now_ms);
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
    var owner = Relist.init(std.testing.allocator, &servers, 1);
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
    var owner = Relist.init(std.testing.allocator, &servers, 1);
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
    var owner = Relist.init(std.testing.allocator, &servers, 1);
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
    var owner = Relist.init(std.testing.allocator, &servers, 1);
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

fn oneServer(name: []const u8, port: u16) !server_mcp_settings.Server {
    var server: server_mcp_settings.Server = .{};
    try server.name.set(name);
    @memcpy(server.bearer_token.bytes[0..6], "secret");
    server.bearer_token.len = 6;
    var url: [128]u8 = undefined;
    try server.url.set(try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/mcp", .{port}));
    return server;
}

test "EXR-70 a list with a ttlMs re-lists once the clock passes its deadline, not before" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    const io = std.testing.io;
    const timed = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ttlMs\":120000,\"tools\":[{\"name\":\"search\",\"inputSchema\":{\"type\":\"object\"}}]}}");
    var script: Script = .{ .reply = timed, .more = &.{timed} };
    try script.start();
    defer script.stop();
    const servers = [_]server_mcp_settings.Server{try oneServer("docs", script.port)};
    var owner = Relist.init(std.testing.allocator, &servers, 1);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module_testing.testingStoreToolSet(&storage, &tmp, io, null);
    defer storage.close() catch unreachable;

    _ = owner.ask(0);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));
    try std.testing.expectEqual(@as(usize, 1), script.requests.load(.acquire));

    // The list is kept until its ttl plus at most a tenth of it (and at most 30 s) has passed.
    const deadline = owner.wakeAt().?;
    try std.testing.expect(deadline >= 120_000 and deadline <= 132_000);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, deadline - 1));
    try std.testing.expectEqual(@as(usize, 1), script.requests.load(.acquire));

    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, deadline));
    try std.testing.expectEqual(@as(usize, 2), script.requests.load(.acquire));
    try std.testing.expect(storage.hostTools().host_tool_set.find("search") != null);
}

test "EXR-70 a list without a ttlMs never re-lists by time" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    const io = std.testing.io;
    const untimed = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"keep\",\"inputSchema\":{\"type\":\"object\"}}]}}");
    var script: Script = .{ .reply = untimed };
    try script.start();
    defer script.stop();
    const servers = [_]server_mcp_settings.Server{try oneServer("notes", script.port)};
    var owner = Relist.init(std.testing.allocator, &servers, 1);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module_testing.testingStoreToolSet(&storage, &tmp, io, null);
    defer storage.close() catch unreachable;

    _ = owner.ask(0);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));
    try std.testing.expectEqual(@as(?u64, null), owner.wakeAt());
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 1), script.requests.load(.acquire));
}

test "EXR-70 startup sets the deadline of a list that lands before the Host serves" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    const io = std.testing.io;
    const timed = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ttlMs\":120000,\"tools\":[{\"name\":\"search\",\"inputSchema\":{\"type\":\"object\"}}]}}");
    var script: Script = .{ .reply = timed };
    try script.start();
    defer script.stop();
    const servers = [_]server_mcp_settings.Server{try oneServer("docs", script.port)};
    var owner = Relist.init(std.testing.allocator, &servers, 1);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module_testing.testingStoreToolSet(&storage, &tmp, io, null);
    defer storage.close() catch unreachable;

    try owner.startup(io, &storage, null, null);
    try std.testing.expectEqual(@as(usize, 1), script.requests.load(.acquire));
    try std.testing.expect(owner.wakeAt() != null);
    try std.testing.expect(storage.hostTools().host_tool_set.find("search") != null);
}

test "EXR-70 each ttl cycle of one list draws its own jitter" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    const io = std.testing.io;
    const timed = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ttlMs\":120000,\"tools\":[{\"name\":\"search\",\"inputSchema\":{\"type\":\"object\"}}]}}");
    var script: Script = .{ .reply = timed, .more = &.{ timed, timed } };
    try script.start();
    defer script.stop();
    const servers = [_]server_mcp_settings.Server{try oneServer("docs", script.port)};
    var owner = Relist.init(std.testing.allocator, &servers, 1);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module_testing.testingStoreToolSet(&storage, &tmp, io, null);
    defer storage.close() catch unreachable;

    // No ask folds into the re-lists, so every cycle shares one generation; only the landing time differs.
    _ = owner.ask(0);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));
    const first_deadline = owner.wakeAt().?;
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, first_deadline));
    const second_deadline = owner.wakeAt().?;
    try std.testing.expectEqual(@as(usize, 2), script.requests.load(.acquire));
    try std.testing.expect(second_deadline - first_deadline >= 120_000);
    try std.testing.expect(second_deadline - first_deadline - 120_000 != first_deadline - 120_000);
}

test "EXR-70 a publish that fails leaves the retry to backoff" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    const io = std.testing.io;
    const timed = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ttlMs\":120000,\"tools\":[{\"name\":\"search\",\"inputSchema\":{\"type\":\"object\"}}]}}");
    var script: Script = .{ .reply = timed, .more = &.{timed} };
    try script.start();
    defer script.stop();
    const servers = [_]server_mcp_settings.Server{try oneServer("docs", script.port)};
    var owner = Relist.init(std.testing.allocator, &servers, 1);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module_testing.testingStoreToolSet(&storage, &tmp, io, null);
    defer storage.close() catch unreachable;

    _ = owner.ask(0);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(io, &storage, 0));
    try std.testing.expect(owner.slots[0].stale_at_ms != null);

    // The deadline's re-list begins with the real allocator; the publish that follows its landing is made to fail.
    const deadline = owner.wakeAt().?;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var failure: ?anyerror = null;
    _ = owner.service(&storage, deadline, &failure);
    try std.testing.expect(owner.listing());
    owner.allocator = failing.allocator();
    var attempts: usize = 0;
    while (failure == null) : (attempts += 1) {
        if (attempts == 1000) return error.ListDidNotFinish;
        if (owner.pending[0]) |pending| {
            var poll_fd = [_]std.c.pollfd{.{ .fd = pending.fd(), .events = pending.events(), .revents = 0 }};
            _ = std.c.poll(&poll_fd, 1, 100);
        }
        _ = owner.service(&storage, deadline, &failure);
    }
    owner.allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), failure);

    // The failed publish clears the deadline; backoff owns the retry.
    try std.testing.expectEqual(@as(?u64, null), owner.slots[0].stale_at_ms);
    try std.testing.expectEqual(relist.State.waiting, owner.slots[0].state);
    try std.testing.expectEqual(owner.slots[0].retry_at_ms, owner.wakeAt().?);
}

/// What a listen test waits for: the server's requests answered, its stream's openings and state, and a tool it offers.
const ListenWant = struct {
    requests: usize,
    opens: ?u64 = null,
    state: ?listen_core.State = null,
    tool: ?[]const u8 = null,
};

/// Drives `owner` at `now_ms` until the server's list and stream reach `want` and no list is in flight or due.
fn listenUntil(owner: *Relist, storage: *store_module.Store, now_ms: u64, script: *const @import("mcp/test_server.zig"), listening: *const @import("mcp/test_server.zig").Listening, want: ListenWant) !void {
    const poll = @import("test_poll");
    const Drive = struct {
        owner: *Relist,
        storage: *store_module.Store,
        script: *const @import("mcp/test_server.zig"),
        listening: *const @import("mcp/test_server.zig").Listening,
        now_ms: u64,
        want: ListenWant,
        failure: ?anyerror = null,
        fn reached(drive: *@This()) bool {
            _ = drive.owner.service(drive.storage, drive.now_ms, &drive.failure);
            if (drive.failure != null) return true;
            if (drive.owner.listing()) return false;
            for (drive.owner.slots[0..drive.owner.servers.len]) |*slot| if (slot.due(drive.now_ms)) return false;
            if (drive.script.requests.load(.acquire) != drive.want.requests) return false;
            if (drive.want.opens) |opens| if (drive.listening.opens.load(.acquire) != opens) return false;
            if (drive.want.state) |state| if (drive.owner.listen.state(0) != state) return false;
            if (drive.want.tool) |tool| if (drive.storage.hostTools().host_tool_set.find(tool) == null) return false;
            return true;
        }
    };
    var drive: Drive = .{ .owner = owner, .storage = storage, .script = script, .listening = listening, .now_ms = now_ms, .want = want };
    try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(30)), &drive, Drive.reached);
    try std.testing.expectEqual(@as(?anyerror, null), drive.failure);
}

test "EXR-88 a pushed list_changed leads to exactly one re-list that lands" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    var listening: Script.Listening = .{};
    var script: Script = .{
        .reply = listReply(&.{"alpha"}),
        .more = &.{
            listReply(&.{"alpha"}), // the first acknowledgment asks one re-list
            listReply(&.{ "alpha", "beta" }), // the pushed notice
        },
        .listening = &listening,
    };
    try script.start();
    defer script.stop();
    const servers = [_]server_mcp_settings.Server{try oneServer("docs", script.port)};
    var owner = Relist.init(std.testing.allocator, &servers, 1);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module_testing.testingStoreToolSet(&storage, &tmp, std.testing.io, null);
    defer storage.close() catch unreachable;

    _ = owner.ask(0);
    try listenUntil(&owner, &storage, 0, &script, &listening, .{ .requests = 2, .opens = 1, .state = .open });

    listening.push("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n");
    try listenUntil(&owner, &storage, 0, &script, &listening, .{ .requests = 3, .tool = "beta" });
    try std.testing.expectEqual(owner.asks[0].load(.acquire), owner.status(0).finished);
    listening.finish();
}

test "EXR-89 a dropped listen stream reopens after its backoff, and its new acknowledgment asks one re-list" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    var listening: Script.Listening = .{};
    var script: Script = .{ .reply = listReply(&.{"alpha"}), .more = &.{ listReply(&.{"alpha"}), listReply(&.{"alpha"}) }, .listening = &listening };
    try script.start();
    defer script.stop();
    const servers = [_]server_mcp_settings.Server{try oneServer("docs", script.port)};
    var owner = Relist.init(std.testing.allocator, &servers, 1);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module_testing.testingStoreToolSet(&storage, &tmp, std.testing.io, null);
    defer storage.close() catch unreachable;

    _ = owner.ask(0);
    try listenUntil(&owner, &storage, 0, &script, &listening, .{ .requests = 2, .opens = 1, .state = .open });
    // A stream that is open holds no wake time of its own: the list has no ttl.
    try std.testing.expectEqual(@as(?u64, null), owner.wakeAt());

    listening.drop();
    try listenUntil(&owner, &storage, 0, &script, &listening, .{ .requests = 2, .state = .off });
    const reopen = owner.wakeAt().?;
    try std.testing.expect(reopen >= 1_000);

    // No reopen before the backoff runs out, and the owner waits until then.
    var early_failure: ?anyerror = null;
    _ = owner.service(&storage, reopen - 1, &early_failure);
    try std.testing.expectEqual(@as(u64, 1), listening.opens.load(.acquire));
    try std.testing.expectEqual(reopen, owner.wakeAt().?);

    try listenUntil(&owner, &storage, reopen, &script, &listening, .{ .requests = 3, .opens = 2, .state = .open });
    listening.finish();
}

test "EXR-90 a refusing listen stream is not reopened by time, and a client reload probes it again" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    const cases = [_]Script.Listening.Opening{ .{ .status = 405 }, .{ .acknowledge = .{ .tools = false } } };
    for (cases) |opening| {
        var listening: Script.Listening = .{ .opening = opening };
        var script: Script = .{ .reply = listReply(&.{"alpha"}), .more = &.{listReply(&.{"alpha"})}, .listening = &listening };
        try script.start();
        defer script.stop();
        const servers = [_]server_mcp_settings.Server{try oneServer("docs", script.port)};
        var owner = Relist.init(std.testing.allocator, &servers, 1);
        defer owner.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: store_module.Store = undefined;
        try store_module_testing.testingStoreToolSet(&storage, &tmp, std.testing.io, null);
        defer storage.close() catch unreachable;

        _ = owner.ask(0);
        try listenUntil(&owner, &storage, 0, &script, &listening, .{ .requests = 1, .state = .unsupported });
        try std.testing.expectEqual(@as(?u64, null), owner.wakeAt());
        var failure: ?anyerror = null;
        _ = owner.service(&storage, std.math.maxInt(u64), &failure);
        try std.testing.expectEqual(@as(u64, 1), owner.listen.lines[0].opens);

        // A client's reload asks the server again: its stream is probed once more, and refused again.
        _ = owner.ask(0);
        try listenUntil(&owner, &storage, 0, &script, &listening, .{ .requests = 2, .state = .unsupported });
        try std.testing.expectEqual(@as(u64, 2), owner.listen.lines[0].opens);
    }
}

test "EXR-91 a held listen stream is not a list in flight, and a dropped one wakes the owner at its reopen time" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    var listening: Script.Listening = .{};
    var script: Script = .{ .reply = listReply(&.{"alpha"}), .more = &.{listReply(&.{"alpha"})}, .listening = &listening };
    try script.start();
    defer script.stop();
    const servers = [_]server_mcp_settings.Server{try oneServer("docs", script.port)};
    var owner = Relist.init(std.testing.allocator, &servers, 1);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module_testing.testingStoreToolSet(&storage, &tmp, std.testing.io, null);
    defer storage.close() catch unreachable;

    _ = owner.ask(0);
    try listenUntil(&owner, &storage, 0, &script, &listening, .{ .requests = 2, .opens = 1, .state = .open });
    try std.testing.expect(!owner.listing());

    listening.drop();
    try listenUntil(&owner, &storage, 0, &script, &listening, .{ .requests = 2, .state = .off });
    try std.testing.expectEqual(owner.listen.lines[0].retry_at_ms, owner.wakeAt().?);
    listening.finish();
}

test "EXR-94 a client ask after a stream-driven re-list lists the server again, and its generation finishes" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    var listening: Script.Listening = .{};
    var script: Script = .{ .reply = listReply(&.{"alpha"}), .more = &.{ listReply(&.{"alpha"}), listReply(&.{ "alpha", "beta" }) }, .listening = &listening };
    try script.start();
    defer script.stop();
    const servers = [_]server_mcp_settings.Server{try oneServer("docs", script.port)};
    var owner = Relist.init(std.testing.allocator, &servers, 1);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module_testing.testingStoreToolSet(&storage, &tmp, std.testing.io, null);
    defer storage.close() catch unreachable;

    // The acknowledgment asks one re-list, which lands and leaves the server's list unchanged.
    _ = owner.ask(0);
    try listenUntil(&owner, &storage, 0, &script, &listening, .{ .requests = 2, .opens = 1, .state = .open });

    // The server's list now has `beta`. A client asks for a list, and that list lands with the new tool.
    const generation = owner.ask(0);
    try listenUntil(&owner, &storage, 0, &script, &listening, .{ .requests = 3, .tool = "beta" });
    try std.testing.expectEqual(generation, owner.status(0).finished);
    listening.finish();
}

test "EXR-90 a list that recovers probes a refusing stream again, once" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    var listening: Script.Listening = .{ .opening = .{ .status = 405 } };
    const failing = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    // The spare reply keeps the server accepting the subscribe that follows the recovered list.
    var script: Script = .{ .reply = failing, .more = &.{ listReply(&.{"alpha"}), listReply(&.{"alpha"}) }, .listening = &listening };
    try script.start();
    defer script.stop();
    const servers = [_]server_mcp_settings.Server{try oneServer("docs", script.port)};
    var owner = Relist.init(std.testing.allocator, &servers, 1);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module_testing.testingStoreToolSet(&storage, &tmp, std.testing.io, null);
    defer storage.close() catch unreachable;

    // The first list fails and the stream is refused: the server is unsupported and its list is backing off.
    _ = owner.ask(0);
    try listenUntil(&owner, &storage, 0, &script, &listening, .{ .requests = 1, .state = .unsupported });
    try std.testing.expect(owner.status(0).last == .failed);
    const opens_before = owner.listen.lines[0].opens;
    const retry_at = owner.slots[0].retry_at_ms;

    // The retry lands. Its landing probes the refusing stream once: one new subscribe, refused again.
    try listenUntil(&owner, &storage, retry_at, &script, &listening, .{ .requests = 2, .tool = "alpha", .state = .unsupported });
    try std.testing.expectEqual(opens_before + 1, owner.listen.lines[0].opens);
    try std.testing.expectEqual(@as(u64, 0), listening.opens.load(.acquire));
}

test "EXR-88 two notices that arrive while a list is in flight fold into one more list" {
    const Script = @import("mcp/test_server.zig");
    const store_module_testing = @import("store.zig").testing;
    var listening: Script.Listening = .{};
    var script: Script = .{
        .reply = listReply(&.{"alpha"}),
        .more = &.{
            listReply(&.{"alpha"}), // the first acknowledgment asks one re-list
            listReply(&.{"alpha"}), // the client ask's list, held until the test releases it
            listReply(&.{ "alpha", "beta", "gamma" }), // one list for the two notices
        },
        .listening = &listening,
        .gate_request = 3,
    };
    try script.start();
    defer script.stop();
    const servers = [_]server_mcp_settings.Server{try oneServer("docs", script.port)};
    var owner = Relist.init(std.testing.allocator, &servers, 1);
    defer owner.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try store_module_testing.testingStoreToolSet(&storage, &tmp, std.testing.io, null);
    defer storage.close() catch unreachable;

    _ = owner.ask(0);
    try listenUntil(&owner, &storage, 0, &script, &listening, .{ .requests = 2, .opens = 1, .state = .open });

    // A client ask starts a list that the server holds. Wait until the server has it in hand.
    const generation = owner.ask(0);
    const Wait = struct {
        owner: *Relist,
        storage: *store_module.Store,
        script: *const Script,
        requests: usize,
        asks_at_least: u64,
        failure: ?anyerror = null,
        fn reached(wait: *@This()) bool {
            _ = wait.owner.service(wait.storage, 0, &wait.failure);
            if (wait.failure != null) return true;
            return wait.script.requests.load(.acquire) == wait.requests and wait.owner.asks[0].load(.acquire) >= wait.asks_at_least;
        }
    };
    const poll = @import("test_poll");
    var held: Wait = .{ .owner = &owner, .storage = &storage, .script = &script, .requests = 3, .asks_at_least = 0 };
    try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(30)), &held, Wait.reached);
    try std.testing.expectEqual(@as(?anyerror, null), held.failure);

    // Two notices arrive while that list is in flight. Each one asks, one at a time so that each ask is seen;
    // neither starts a second list.
    const notice = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n";
    for (1..3) |count| {
        listening.push(notice);
        var noticed: Wait = .{ .owner = &owner, .storage = &storage, .script = &script, .requests = 3, .asks_at_least = generation + count };
        try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(30)), &noticed, Wait.reached);
        try std.testing.expectEqual(@as(?anyerror, null), noticed.failure);
    }
    try std.testing.expect(owner.listing());

    // Releasing the held list lands it, and the two notices fold into exactly one more list.
    try std.testing.expect(script.releaseGated(listReply(&.{"alpha"})));
    try listenUntil(&owner, &storage, 0, &script, &listening, .{ .requests = 4, .tool = "gamma" });
    try std.testing.expectEqual(owner.asks[0].load(.acquire), owner.status(0).finished);
    listening.finish();
}
