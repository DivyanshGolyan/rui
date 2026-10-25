//! Name lookup for one connection setup: getaddrinfo on a short-lived
//! thread of its own. Internal.
//!
//! A lookup owns nothing but this job: no socket, no session, no stream.
//! The thread exists only while getaddrinfo runs, so an idle Client holds
//! no thread. The job is shared by two references, the owner's and the
//! thread's; whichever lets go last frees it. A finished lookup wakes the
//! owner's `wait`, unless the owner abandoned it first (the Client closed),
//! in which case the thread only frees the job.
//!
//! Bound: each origin keeps at most one lookup, shared by its setups and
//! kept across a setup that timed out, so at most `max_endpoints` threads
//! run per Client even while the resolver stalls. A thread may outlive
//! `Client.deinit` until getaddrinfo returns, which nothing can interrupt.
const std = @import("std");
const h2 = @import("h2.zig");
const Waker = @import("Waker.zig");
const Resolver = @This();

/// Addresses tried per connection, in getaddrinfo's order.
pub const max_addresses = 8;

mutex: std.c.pthread_mutex_t,
references: u8,
state: enum(u8) { running, done, abandoned },
waker: *Waker,
port: u16,
host: [h2.max_host_bytes + 1]u8,
count: u8,
addresses: [max_addresses]Address,

/// A socket address, IPv4 or IPv6.
pub const Address = struct {
    storage: std.c.sockaddr.in6,
    length: std.c.socklen_t,
    family: c_uint,

    /// The address an IP literal names, or null for a DNS name.
    pub fn literal(host: []const u8, port: u16) ?Address {
        if (std.Io.net.Ip4Address.parse(host, port)) |ip4| {
            var address: Address = .{ .storage = std.mem.zeroes(std.c.sockaddr.in6), .length = @sizeOf(std.c.sockaddr.in), .family = std.c.AF.INET };
            const v4: *std.c.sockaddr.in = @ptrCast(&address.storage);
            v4.family = std.c.AF.INET;
            v4.port = std.mem.nativeToBig(u16, port);
            v4.addr = @bitCast(ip4.bytes);
            if (@hasField(std.c.sockaddr.in, "len")) v4.len = @sizeOf(std.c.sockaddr.in);
            return address;
        } else |_| {}
        if (std.mem.indexOfScalar(u8, host, ':') == null) return null;
        const ip6 = std.Io.net.Ip6Address.parse(host, port) catch return null;
        var address: Address = .{ .storage = std.mem.zeroes(std.c.sockaddr.in6), .length = @sizeOf(std.c.sockaddr.in6), .family = std.c.AF.INET6 };
        address.storage.family = std.c.AF.INET6;
        address.storage.port = std.mem.nativeToBig(u16, port);
        address.storage.addr = ip6.bytes;
        if (@hasField(std.c.sockaddr.in6, "len")) address.storage.len = @sizeOf(std.c.sockaddr.in6);
        return address;
    }

    fn fromSockaddr(addr: *const std.c.sockaddr, length: std.c.socklen_t) ?Address {
        const family: c_uint = addr.family;
        if (family != std.c.AF.INET and family != std.c.AF.INET6) return null;
        if (length > @sizeOf(std.c.sockaddr.in6)) return null;
        var address: Address = .{ .storage = std.mem.zeroes(std.c.sockaddr.in6), .length = length, .family = family };
        @memcpy(std.mem.asBytes(&address.storage)[0..length], @as([*]const u8, @ptrCast(addr))[0..length]);
        return address;
    }
};

/// Starts a lookup of `host` and returns the owner's reference, or null
/// when no thread could be started.
pub fn start(waker: *Waker, host: []const u8, port: u16) ?*Resolver {
    std.debug.assert(host.len <= h2.max_host_bytes);
    // Freed by whichever thread lets go last, so not the Client's allocator.
    const self = std.heap.c_allocator.create(Resolver) catch return null;
    self.* = .{
        .mutex = .{},
        .references = 2,
        .state = .running,
        .waker = waker,
        .port = port,
        .host = undefined,
        .count = 0,
        .addresses = undefined,
    };
    @memcpy(self.host[0..host.len], host);
    self.host[host.len] = 0;
    // The libc default stack: glibc sizes it around static TLS, which a
    // fixed small size would not. Only the pages getaddrinfo touches count.
    var thread: std.c.pthread_t = undefined;
    if (std.c.pthread_create(&thread, null, run, self) != .SUCCESS) {
        std.heap.c_allocator.destroy(self);
        return null;
    }
    _ = std.c.pthread_detach(thread);
    return self;
}

/// Owner thread: the addresses once the lookup finished, empty when it
/// failed; null while it runs.
pub fn result(self: *Resolver) ?[]const Address {
    lock(self);
    defer unlock(self);
    return if (self.state == .done) self.addresses[0..self.count] else null;
}

/// Owner thread: lets go of the owner's reference. No wake follows.
pub fn release(self: *Resolver) void {
    lock(self);
    if (self.state == .running) self.state = .abandoned;
    self.references -= 1;
    const last = self.references == 0;
    unlock(self);
    if (last) std.heap.c_allocator.destroy(self);
}

fn run(argument: ?*anyopaque) callconv(.c) ?*anyopaque {
    const self: *Resolver = @ptrCast(@alignCast(argument.?));
    var port_text: [6]u8 = undefined;
    const service = std.fmt.bufPrintSentinel(&port_text, "{d}", .{self.port}, 0) catch unreachable;
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.c.AF.UNSPEC;
    hints.socktype = std.c.SOCK.STREAM;
    hints.flags = .{ .NUMERICSERV = true };
    var list: ?*std.c.addrinfo = null;
    const status = std.c.getaddrinfo(@ptrCast(&self.host), service, &hints, &list);
    defer if (list) |head| std.c.freeaddrinfo(head);

    lock(self);
    if (self.state == .running) {
        if (status == @as(std.c.EAI, @fromBackingInt(@intCast(0)))) {
            var next = list;
            while (next) |entry| : (next = entry.next) {
                if (self.count == max_addresses) break;
                const addr = entry.addr orelse continue;
                const address = Address.fromSockaddr(addr, entry.addrlen) orelse continue;
                self.addresses[self.count] = address;
                self.count += 1;
            }
        }
        self.state = .done;
        // Under the lock: the owner cannot have released, so its waker lives.
        self.waker.wake();
    }
    self.references -= 1;
    const last = self.references == 0;
    unlock(self);
    if (last) std.heap.c_allocator.destroy(self);
    return null;
}

fn lock(self: *Resolver) void {
    std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
}

fn unlock(self: *Resolver) void {
    std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);
}

test "a lookup of an IP literal returns it, and a released lookup frees itself" {
    var waker = try Waker.init();
    defer waker.deinit();
    const lookup = start(&waker, "127.0.0.1", 443) orelse return error.SkipZigTest;
    var poll = [_]std.c.pollfd{.{ .fd = waker.read_fd, .events = std.c.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&poll, 1, 5000));
    const addresses = lookup.result().?;
    try std.testing.expectEqual(@as(usize, 1), addresses.len);
    try std.testing.expectEqual(@as(c_uint, std.c.AF.INET), addresses[0].family);
    lookup.release();

    // Released while it may still run: the thread frees the job alone.
    const abandoned = start(&waker, "localhost", 443) orelse return error.SkipZigTest;
    abandoned.release();
}

test "literal addresses" {
    const v4 = Address.literal("127.0.0.1", 8443).?;
    try std.testing.expectEqual(@as(c_uint, std.c.AF.INET), v4.family);
    const v6 = Address.literal("::1", 8443).?;
    try std.testing.expectEqual(@as(c_uint, std.c.AF.INET6), v6.family);
    try std.testing.expectEqual(@as(u8, 1), v6.storage.addr[15]);
    try std.testing.expect(Address.literal("localhost", 443) == null);
    try std.testing.expect(Address.literal("api.openai.com", 443) == null);
}
