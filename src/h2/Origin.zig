const std = @import("std");
const h2 = @import("h2.zig");
const proxy = @import("proxy.zig");
const Resolver = @import("Resolver.zig");
const Waker = @import("os").Waker;
const Origin = @This();

pub const Target = struct { host: []const u8, port: u16, literal: ?Resolver.Address };

pub const Route = struct {
    settings_copy: []u8,
    host: []const u8,
    port: u16,
    literal: ?Resolver.Address,
    no_proxy: []const u8,
    credentials: ?[]u8,

    pub fn init(allocator: std.mem.Allocator, settings: h2.Proxy) h2.InitError!Route {
        const text = try allocator.alloc(u8, settings.url.len + settings.no_proxy.len);
        errdefer {
            std.crypto.secureZero(u8, text);
            allocator.free(text);
        }
        @memcpy(text[0..settings.url.len], settings.url);
        @memcpy(text[settings.url.len..], settings.no_proxy);
        const url = try proxy.splitUrl(text[0..settings.url.len]);
        const host, const port = h2.parseHostPort(url.authority, 80) catch return error.HttpsProxyInvalid;
        return .{
            .settings_copy = text,
            .host = host,
            .port = port,
            .literal = Resolver.Address.literal(host, port),
            .no_proxy = text[settings.url.len..],
            .credentials = if (url.user_info) |user_info| try proxy.basicCredentials(allocator, user_info) else null,
        };
    }

    pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        if (self.credentials) |credentials| {
            std.crypto.secureZero(u8, credentials);
            allocator.free(credentials);
        }
        std.crypto.secureZero(u8, self.settings_copy);
        allocator.free(self.settings_copy);
    }

    pub fn tunnels(self: *const Route, scheme: h2.Scheme, server_name: []const u8) bool {
        return scheme == .https and !proxy.isLoopback(server_name) and !proxy.bypasses(self.no_proxy, server_name);
    }
};

/// A DNS lookup shared by the connections of one origin, reference counted by users.
pub const SharedLookup = struct {
    job: ?*Resolver.Job = null,
    users: u32 = 0,

    pub fn acquire(self: *SharedLookup, waker: *Waker, target: Target) bool {
        if (self.job) |job| if (self.users == 0 and job.result() != null) {
            job.release();
            self.job = null;
        };
        if (self.job == null) self.job = Resolver.start(waker, target.host, target.port) orelse return false;
        self.users += 1;
        return true;
    }

    pub fn release(self: *SharedLookup) void {
        self.users -= 1;
        const job = self.job.?;
        if (self.users == 0 and job.result() != null) {
            job.release();
            self.job = null;
        }
    }

    pub fn result(self: *const SharedLookup) ?*const Resolver {
        return self.job.?.result();
    }

    pub fn deinit(self: *SharedLookup) void {
        if (self.job) |job| job.release();
    }
};

scheme: h2.Scheme,
host: []const u8,
server_name: []const u8,
authority: []const u8,
port: u16,
literal: ?Resolver.Address,
learned_max_streams: ?u32,
via: ?*const Route,
target: Target,
lookup: SharedLookup = .{},

pub fn init(url: h2.Url, via: ?*const Route) Origin {
    const literal = Resolver.Address.literal(url.host, url.port);
    var tunnel: ?*const Route = null;
    if (via) |route| {
        if (route.tunnels(url.scheme, url.server_name)) tunnel = route;
    }
    return .{
        .scheme = url.scheme,
        .host = url.host,
        .server_name = url.server_name,
        .authority = url.authority,
        .port = url.port,
        .literal = literal,
        .learned_max_streams = null,
        .via = tunnel,
        .target = if (tunnel) |route|
            .{ .host = route.host, .port = route.port, .literal = route.literal }
        else
            .{ .host = url.host, .port = url.port, .literal = literal },
    };
}

pub fn address(self: *const Origin, index: u8) ?Resolver.Address {
    if (self.target.literal) |literal| return if (index == 0) literal else null;
    const addresses = self.lookup.result().?.found();
    return if (index < addresses.len) addresses[index] else null;
}

fn awaitFinished(waker: *Waker, job: *Resolver.Job) !void {
    var poll = [_]std.c.pollfd{.{ .fd = waker.read_fd, .events = std.c.POLL.IN, .revents = 0 }};
    var rounds: u32 = 0;
    while (job.result() == null) : (rounds += 1) {
        if (rounds == 10_000) return error.TimedOut;
        _ = std.c.poll(&poll, 1, 5);
    }
}

fn pendingJob(waker: *Waker) *Resolver.Job {
    const job = std.heap.c_allocator.create(Resolver.Job) catch unreachable;
    job.* = .{ .mutex = .{}, .references = 1, .state = .running, .waker = waker, .work = undefined };
    return job;
}

test "connections of one origin share one lookup until the last releases a finished one" {
    var waker = try Waker.init();
    defer waker.deinit();
    const target: Target = .{ .host = "127.0.0.1", .port = 443, .literal = null };
    var lookup: SharedLookup = .{};
    defer lookup.deinit();

    try std.testing.expect(lookup.acquire(&waker, target));
    const started = lookup.job.?;
    try std.testing.expect(lookup.acquire(&waker, target));
    try std.testing.expectEqual(started, lookup.job.?);
    try std.testing.expectEqual(@as(u32, 2), lookup.users);
    try awaitFinished(&waker, started);

    lookup.release();
    try std.testing.expectEqual(started, lookup.job.?);
    try std.testing.expectEqual(@as(u32, 1), lookup.users);
    lookup.release();
    try std.testing.expectEqual(@as(?*Resolver.Job, null), lookup.job);
    try std.testing.expectEqual(@as(u32, 0), lookup.users);

    lookup.job = pendingJob(&waker);
    const unfinished = lookup.job.?;
    try std.testing.expect(lookup.acquire(&waker, target));
    try std.testing.expectEqual(unfinished, lookup.job.?);
    lookup.release();
    try std.testing.expectEqual(unfinished, lookup.job.?);
    try std.testing.expect(lookup.acquire(&waker, target));
    try std.testing.expectEqual(unfinished, lookup.job.?);
    lookup.release();

    const literal = Resolver.Address.literal("127.0.0.1", 443).?;
    lookup.job.?.release();
    lookup.job = Resolver.answered(&waker, &.{literal}) orelse return error.OutOfMemory;
    try std.testing.expect(lookup.acquire(&waker, target));
    const fresh = lookup.job.?;
    try std.testing.expectEqual(@as(u32, 1), lookup.users);
    try awaitFinished(&waker, fresh);
}
