//! Name lookup for connection setups: getaddrinfo on a `job.Job` thread.
//! Internal.
//!
//! Bound: each origin keeps at most one lookup, shared by its setups and
//! kept across a setup that timed out, so at most `max_endpoints` lookup
//! threads run per Client even while the resolver stalls.
const std = @import("std");
const h2 = @import("h2.zig");
const Waker = @import("Waker.zig");
const job = @import("job.zig");
const Resolver = @This();

pub const Job = job.Job(Resolver);

/// Addresses tried per connection.
pub const max_addresses = 8;

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
pub fn start(waker: *Waker, host: []const u8, port: u16) ?*Job {
    std.debug.assert(host.len <= h2.max_host_bytes);
    var lookup: Resolver = .{ .port = port, .host = undefined, .count = 0, .addresses = undefined };
    @memcpy(lookup.host[0..host.len], host);
    lookup.host[host.len] = 0;
    return Job.start(waker, lookup);
}

/// A finished lookup that found `addresses`, in this order: a test's
/// stand-in for a name it cannot make resolve this way.
pub fn answered(waker: *Waker, addresses: []const Address) ?*Job {
    std.debug.assert(addresses.len <= max_addresses);
    var lookup: Resolver = .{ .port = 0, .host = @splat(0), .count = @intCast(addresses.len), .addresses = undefined };
    @memcpy(lookup.addresses[0..addresses.len], addresses);
    return Job.finished(waker, lookup);
}

/// The addresses found, in the order to try them; empty when the lookup
/// failed.
pub fn found(self: *const Resolver) []const Address {
    return self.addresses[0..self.count];
}

pub fn run(self: *Resolver) void {
    var port_text: [6]u8 = undefined;
    const service = std.fmt.bufPrintSentinel(&port_text, "{d}", .{self.port}, 0) catch unreachable;
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.c.AF.UNSPEC;
    hints.socktype = std.c.SOCK.STREAM;
    // Only families this host has an address in, so a host without IPv6
    // never waits on an IPv6 attempt.
    hints.flags = .{ .NUMERICSERV = true, .ADDRCONFIG = true };
    var list: ?*std.c.addrinfo = null;
    const status = std.c.getaddrinfo(@ptrCast(&self.host), service, &hints, &list);
    defer if (list) |head| std.c.freeaddrinfo(head);
    if (status != @as(std.c.EAI, @fromBackingInt(@intCast(0)))) return;
    // getaddrinfo's order (RFC 6724) within each family; the family of its
    // first answer leads.
    var families: [2]Family = .{ .{}, .{} };
    var next = list;
    while (next) |entry| : (next = entry.next) {
        const addr = entry.addr orelse continue;
        const address = Address.fromSockaddr(addr, entry.addrlen) orelse continue;
        const family = &families[@intFromBool(families[0].count > 0 and families[0].addresses[0].family != address.family)];
        if (family.count == max_addresses) continue;
        family.addresses[family.count] = address;
        family.count += 1;
    }
    self.count = @intCast(interleave(families[0].found(), families[1].found(), &self.addresses));
}

const Family = struct {
    addresses: [max_addresses]Address = undefined,
    count: u8 = 0,

    fn found(self: *const Family) []const Address {
        return self.addresses[0..self.count];
    }
};

/// Alternates the two families, `first` leading, so one family that does
/// not work costs at most every other attempt (RFC 8305 section 4).
/// Returns how many addresses `out` holds.
fn interleave(first: []const Address, second: []const Address, out: []Address) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (count < out.len and index < @max(first.len, second.len)) : (index += 1) {
        for ([_][]const Address{ first, second }) |family| {
            if (index >= family.len or count == out.len) continue;
            out[count] = family[index];
            count += 1;
        }
    }
    return count;
}

test "a lookup of an IP literal returns it, and a released lookup frees itself" {
    var waker = try Waker.init();
    defer waker.deinit();
    const lookup = start(&waker, "127.0.0.1", 443) orelse return error.SkipZigTest;
    var poll = [_]std.c.pollfd{.{ .fd = waker.read_fd, .events = std.c.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&poll, 1, 5000));
    const addresses = lookup.result().?.found();
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

test "families alternate, the first answer's family leading, and both fit" {
    var six: [max_addresses]Address = undefined;
    for (&six, 0..) |*address, index| address.* = Address.literal("::1", @intCast(index)).?;
    const four = [_]Address{ Address.literal("127.0.0.1", 100).?, Address.literal("127.0.0.1", 101).? };
    var out: [max_addresses]Address = undefined;
    const count = interleave(&six, &four, &out);
    try std.testing.expectEqual(@as(usize, max_addresses), count);
    const families = [_]c_uint{ std.c.AF.INET6, std.c.AF.INET, std.c.AF.INET6, std.c.AF.INET, std.c.AF.INET6, std.c.AF.INET6, std.c.AF.INET6, std.c.AF.INET6 };
    for (out, families) |address, family| try std.testing.expectEqual(family, address.family);
    // Within a family, getaddrinfo's order stays. The port sits at the same
    // offset in both sockaddr layouts.
    try std.testing.expectEqual(@as(u16, 1), std.mem.bigToNative(u16, out[2].storage.port));
    try std.testing.expectEqual(@as(u16, 101), std.mem.bigToNative(u16, out[3].storage.port));

    // IPv4 first when getaddrinfo answered IPv4 first; one family alone is unchanged.
    try std.testing.expectEqual(@as(usize, 4), interleave(&four, six[0..2], &out));
    try std.testing.expectEqual(@as(c_uint, std.c.AF.INET), out[0].family);
    try std.testing.expectEqual(@as(c_uint, std.c.AF.INET6), out[1].family);
    try std.testing.expectEqual(@as(usize, 2), interleave(&four, &.{}, &out));
}
