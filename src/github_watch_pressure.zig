const std = @import("std");
const transport = @import("github_transport.zig");
const watch = @import("github_pr_watch.zig");

/// One instance belongs to a Host. A burst covers an entire bounded poll;
/// exhaustion returns immediately and leaves scheduling to the watch runner.
pub const Budget = struct {
    io: std.Io,
    next_ns: std.atomic.Value(i64) = .init(0),
    interval: i64,
    const burst: i64 = 40;

    pub fn init(io: std.Io) Budget {
        return initEvery(io, std.time.ns_per_s);
    }

    /// A budget that refills one request every `interval` nanoseconds; a loopback fixture shortens it.
    pub fn initEvery(io: std.Io, interval: i64) Budget {
        const now: i64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
        return .{ .io = io, .next_ns = .init(now -| (burst - 1) * interval), .interval = interval };
    }
    pub fn acquireOpaque(context: *anyopaque) bool {
        const self: *Budget = @ptrCast(@alignCast(context));
        return self.acquire();
    }
    pub fn acquire(self: *Budget) bool {
        const now: i64 = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
        var next = self.next_ns.load(.monotonic);
        while (true) {
            const base = @max(next, now -| (burst - 1) * self.interval);
            if (base > now) return false;
            const updated = base +| self.interval;
            if (self.next_ns.cmpxchgWeak(next, updated, .monotonic, .monotonic)) |observed| {
                next = observed;
            } else return true;
        }
    }
};

const max_entries = 32;
const max_bytes = 4 * 1024 * 1024;
const max_entry = 512 * 1024;
const Entry = struct { key: [32]u8, response: transport.Response, bytes: usize };

/// Private per-watch cache. Bodies are bounded, never written to the Store and
/// wiped on eviction. No request credential or authorization header is kept.
pub const Cache = struct {
    entries: [max_entries]?Entry = @splat(null),
    bytes: usize = 0,
    cursor: usize = 0,

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (&self.entries) |*entry| if (entry.*) |*value| value.response.deinit(allocator);
        self.* = .{};
    }

    pub fn get(self: *const Cache, login: []const u8, endpoint: transport.Endpoint, head: ?watch.Digest) ?*const transport.Response {
        const key = makeKey(login, endpoint, head);
        for (&self.entries) |*entry| if (entry.*) |*value| {
            if (std.mem.eql(u8, &key, &value.key)) return &value.response;
        };
        return null;
    }

    fn evict(self: *Cache, allocator: std.mem.Allocator, index: usize) void {
        if (self.entries[index]) |*old| {
            self.bytes -= old.bytes;
            old.response.deinit(allocator);
            self.entries[index] = null;
        }
    }

    /// Retain only complete 200 responses with a bounded validator. Replacing
    /// the same key invalidates its old validator even if the new one is unusable.
    pub fn put(self: *Cache, allocator: std.mem.Allocator, login: []const u8, endpoint: transport.Endpoint, head: ?watch.Digest, response: *const transport.Response) !void {
        const key = makeKey(login, endpoint, head);
        for (&self.entries) |*entry| if (entry.*) |*value| {
            if (std.mem.eql(u8, &key, &value.key)) {
                self.bytes -= value.bytes;
                value.response.deinit(allocator);
                entry.* = null;
            }
        };
        const etag = response.etag orelse return;
        const link_len = if (response.link) |link| link.len else 0;
        if (response.status != 200 or etag.len == 0 or etag.len > 1024 or link_len > 8192) return;
        for (etag) |c| if (c < 32 or c == 127) {
            return;
        };
        const size = response.body.len + etag.len + link_len;
        if (size > max_entry) return;
        var copy = try clone(allocator, response);
        errdefer copy.deinit(allocator);
        while (self.bytes + size > max_bytes) {
            self.evict(allocator, self.cursor);
            self.cursor = (self.cursor + 1) % max_entries;
        }
        self.evict(allocator, self.cursor);
        self.entries[self.cursor] = .{ .key = key, .response = copy, .bytes = size };
        self.bytes += size;
        self.cursor = (self.cursor + 1) % max_entries;
    }
};

/// A 304 may be converted only from the matching retained 200; callers own
/// the returned copy and must dispose it like any transport response.
pub fn clone(allocator: std.mem.Allocator, response: *const transport.Response) !transport.Response {
    var result: transport.Response = .{ .status = 200, .body = try allocator.dupe(u8, response.body) };
    errdefer result.deinit(allocator);
    if (response.etag) |value| result.etag = try allocator.dupe(u8, value);
    if (response.link) |value| result.link = try allocator.dupe(u8, value);
    return result;
}

fn makeKey(login: []const u8, endpoint: transport.Endpoint, head: ?watch.Digest) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    hashPart(&h, login);
    const tag: u8 = @backingInt(std.meta.activeTag(endpoint));
    h.update(&.{tag});
    if (head) |value| {
        h.update(&.{1});
        h.update(&value);
    } else h.update(&.{0});
    switch (endpoint) {
        .identity => {},
        .pr => |pr| hashPr(&h, pr),
        .reviews => |v| {
            hashPr(&h, v.pr);
            h.update(&.{v.page});
        },
        .check_runs => |v| {
            hashPr(&h, v.pr);
            h.update(&v.head);
            h.update(&.{v.page});
        },
        .status => |v| {
            hashPr(&h, v.pr);
            h.update(&v.head);
            h.update(&.{v.page});
        },
    }
    return h.finalResult();
}
fn hashPart(h: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .little);
    h.update(&length);
    h.update(value);
}
fn hashPr(h: *std.crypto.hash.sha2.Sha256, pr: watch.PrKey) void {
    hashPart(h, pr.owner);
    hashPart(h, pr.repo);
    var number: [8]u8 = undefined;
    std.mem.writeInt(u64, &number, pr.number, .little);
    h.update(&number);
}

test "PRW-20 cache isolates account endpoint page and current head" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    const pr: watch.PrKey = .{ .owner = "org", .repo = "repo", .number = 7 };
    const a: watch.Digest = @splat(1);
    const b: watch.Digest = @splat(2);
    const endpoint: transport.Endpoint = .{ .reviews = .{ .pr = pr, .page = 1 } };
    const next: transport.Endpoint = .{ .reviews = .{ .pr = pr, .page = 2 } };
    var response: transport.Response = .{ .status = 200, .body = try allocator.dupe(u8, "private data"), .etag = try allocator.dupe(u8, "\"v1\""), .link = try allocator.dupe(u8, "link") };
    defer response.deinit(allocator);
    try cache.put(allocator, "alice", endpoint, a, &response);
    try std.testing.expect(cache.get("bob", endpoint, a) == null);
    try std.testing.expect(cache.get("alice", next, a) == null);
    try std.testing.expect(cache.get("alice", endpoint, b) == null);
    const retained = cache.get("alice", endpoint, a).?;
    var copy = try clone(allocator, retained);
    defer copy.deinit(allocator);
    try std.testing.expectEqualStrings("private data", copy.body);
    try std.testing.expectEqualStrings("link", copy.link.?);
    response.status = 200;
    allocator.free(response.etag.?);
    response.etag = null;
    try cache.put(allocator, "alice", endpoint, a, &response);
    try std.testing.expect(cache.get("alice", endpoint, a) == null);
}

test "PRW-45 cache bounds retained entries and bytes" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    const pr: watch.PrKey = .{ .owner = "org", .repo = "repo", .number = 7 };
    const body = try allocator.alloc(u8, 200 * 1024);
    @memset(body, 'x');
    var response: transport.Response = .{ .status = 200, .body = body, .etag = try allocator.dupe(u8, "tag") };
    defer response.deinit(allocator);
    for (0..50) |i| {
        const head: watch.Digest = @splat(@intCast(i));
        try cache.put(allocator, "alice", .{ .pr = pr }, head, &response);
    }
    try std.testing.expect(cache.bytes <= max_bytes);
    const oldest: watch.Digest = @splat(0);
    const newest: watch.Digest = @splat(49);
    try std.testing.expect(cache.get("alice", .{ .pr = pr }, oldest) == null);
    try std.testing.expect(cache.get("alice", .{ .pr = pr }, newest) != null);
}

test "PRW-46 budget exhausts without waiting" {
    var budget = Budget.init(std.testing.io);
    for (0..40) |_| try std.testing.expect(budget.acquire());
    try std.testing.expect(!budget.acquire());
}

test "PRW-47 cache evicts one entry when at capacity" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    const pr: watch.PrKey = .{ .owner = "org", .repo = "repo", .number = 7 };
    var response: transport.Response = .{ .status = 200, .body = try allocator.dupe(u8, "data"), .etag = try allocator.dupe(u8, "tag") };
    defer response.deinit(allocator);
    for (0..33) |i| {
        const head: watch.Digest = @splat(@intCast(i));
        try cache.put(allocator, "alice", .{ .pr = pr }, head, &response);
    }
    const oldest: watch.Digest = @splat(0);
    const second: watch.Digest = @splat(1);
    try std.testing.expect(cache.get("alice", .{ .pr = pr }, oldest) == null);
    try std.testing.expect(cache.get("alice", .{ .pr = pr }, second) != null);
}
