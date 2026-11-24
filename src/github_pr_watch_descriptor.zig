const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;

pub const max_url_bytes = 256;
pub const max_login_bytes = 39;

pub const Arguments = struct {
    url: Bounded(max_url_bytes),
    account: ?Bounded(max_login_bytes),
};

pub const DiscoveryFailure = enum { gh_unavailable, account_discovery_failed };

pub const Descriptor = union(enum) {
    watch: struct { url: Bounded(max_url_bytes), login: Bounded(max_login_bytes) },
    discover_accounts: Bounded(max_url_bytes),
    discovery_failed: struct { url: Bounded(max_url_bytes), reason: DiscoveryFailure },
};

/// Facts are captured before settlement and never contain credentials.
pub const AuthFacts = union(enum) {
    sole_login: Bounded(max_login_bytes),
    discovery_required,
    discovery_failed: DiscoveryFailure,
};

pub fn prepare(args: Arguments, facts: AuthFacts) Descriptor {
    if (args.account) |login| return .{ .watch = .{ .url = args.url, .login = login } };
    return switch (facts) {
        .sole_login => |login| .{ .watch = .{ .url = args.url, .login = login } },
        .discovery_required => .{ .discover_accounts = args.url },
        .discovery_failed => |reason| .{ .discovery_failed = .{ .url = args.url, .reason = reason } },
    };
}

pub fn validLogin(s: []const u8) bool {
    if (s.len == 0 or s.len > max_login_bytes or !std.ascii.isAlphanumeric(s[0]) or !std.ascii.isAlphanumeric(s[s.len - 1])) return false;
    var previous_hyphen = false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
        if (c == '-' and previous_hyphen) return false;
        previous_hyphen = c == '-';
    }
    return true;
}

/// Strict JSON shape: unknown, duplicate and non-string fields are rejected.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Arguments {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidArguments;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const object = parsed.value.object;
    if (object.count() < 1 or object.count() > 2) return error.InvalidArguments;
    const url_value = object.get("url") orelse return error.InvalidArguments;
    if (url_value != .string) return error.InvalidArguments;
    _ = @import("github_pr_watch.zig").parseUrl(url_value.string) catch return error.InvalidArguments;
    const account = if (object.get("account")) |value| blk: {
        if (value != .string or !validLogin(value.string)) return error.InvalidArguments;
        break :blk value.string;
    } else null;
    if (object.count() != @as(usize, 1) + @intFromBool(account != null)) return error.InvalidArguments;
    return .{
        .url = Bounded(max_url_bytes).from(url_value.string) catch unreachable,
        .account = if (account) |login| Bounded(max_login_bytes).from(login) catch unreachable else null,
    };
}

pub fn parseSource(source: anytype) !?Arguments {
    var bytes: [2048]u8 = undefined;
    var length: usize = 0;
    while (try source.peek() != null) {
        if (length == bytes.len) return null;
        bytes[length] = try source.take();
        length += 1;
    }
    var memory: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    return parse(fixed.allocator(), bytes[0..length]) catch null;
}

pub fn decodeDescriptor(allocator: std.mem.Allocator, bytes: []const u8) !Descriptor {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidDescriptor;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDescriptor;
    const object = parsed.value.object;
    const kind = object.get("kind") orelse return error.InvalidDescriptor;
    const url = object.get("url") orelse return error.InvalidDescriptor;
    if (kind != .string or url != .string) return error.InvalidDescriptor;
    _ = @import("github_pr_watch.zig").parseUrl(url.string) catch return error.InvalidDescriptor;
    const target = Bounded(max_url_bytes).from(url.string) catch return error.InvalidDescriptor;
    if (std.mem.eql(u8, kind.string, "discover_accounts")) {
        if (object.count() != 2) return error.InvalidDescriptor;
        return .{ .discover_accounts = target };
    }
    if (std.mem.eql(u8, kind.string, "discovery_failed")) {
        if (object.count() != 3) return error.InvalidDescriptor;
        const reason = object.get("reason") orelse return error.InvalidDescriptor;
        if (reason != .string) return error.InvalidDescriptor;
        const value = std.meta.stringToEnum(DiscoveryFailure, reason.string) orelse return error.InvalidDescriptor;
        return .{ .discovery_failed = .{ .url = target, .reason = value } };
    }
    if (!std.mem.eql(u8, kind.string, "watch") or object.count() != 3) return error.InvalidDescriptor;
    const login = object.get("login") orelse return error.InvalidDescriptor;
    if (login != .string or !validLogin(login.string)) return error.InvalidDescriptor;
    return .{ .watch = .{ .url = target, .login = Bounded(max_login_bytes).from(login.string) catch unreachable } };
}

pub fn encode(descriptor: *const Descriptor, buffer: []u8) ![]const u8 {
    return switch (descriptor.*) {
        .watch => |*watch| std.fmt.bufPrint(buffer, "{{\"kind\":\"watch\",\"url\":\"{s}\",\"login\":\"{s}\"}}", .{ watch.url.slice(), watch.login.slice() }),
        .discover_accounts => |*url| std.fmt.bufPrint(buffer, "{{\"kind\":\"discover_accounts\",\"url\":\"{s}\"}}", .{url.slice()}),
        .discovery_failed => |*failure| std.fmt.bufPrint(buffer, "{{\"kind\":\"discovery_failed\",\"url\":\"{s}\",\"reason\":\"{s}\"}}", .{ failure.url.slice(), @tagName(failure.reason) }),
    };
}

test "PRW-24 preflight failures remain bounded in the authorized descriptor" {
    const args = try parse(std.testing.allocator, "{\"url\":\"https://github.com/org/repo/pull/42\"}");
    var buffer: [512]u8 = undefined;
    for ([_]DiscoveryFailure{ .gh_unavailable, .account_discovery_failed }) |reason| {
        const prepared = prepare(args, .{ .discovery_failed = reason });
        const decoded = try decodeDescriptor(std.testing.allocator, try encode(&prepared, &buffer));
        try std.testing.expectEqual(reason, decoded.discovery_failed.reason);
        try std.testing.expectEqualStrings(args.url.slice(), decoded.discovery_failed.url.slice());
    }
    const explicit = try parse(std.testing.allocator, "{\"url\":\"https://github.com/org/repo/pull/42\",\"account\":\"chosen\"}");
    const bound = prepare(explicit, .{ .discovery_failed = .gh_unavailable });
    try std.testing.expectEqualStrings("chosen", bound.watch.login.slice());
}

test "PRW-41 account validation rejects invalid logins" {
    for ([_][]const u8{ "", "-bad", "bad-", "a--b", "a/b" }) |login| try std.testing.expect(!validLogin(login));
    try std.testing.expect(validLogin("octocat"));
}

test "PRW-42 preparation binds explicit and sole accounts and preserves discovery" {
    const args = try parse(std.testing.allocator, "{\"url\":\"https://github.com/org/repo/pull/42\"}");
    const login = try Bounded(max_login_bytes).from("octocat");
    var descriptor = prepare(args, .{ .sole_login = login });
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings("{\"kind\":\"watch\",\"url\":\"https://github.com/org/repo/pull/42\",\"login\":\"octocat\"}", try encode(&descriptor, &buffer));
    const decoded_watch = try decodeDescriptor(std.testing.allocator, try encode(&descriptor, &buffer));
    try std.testing.expectEqualStrings("octocat", decoded_watch.watch.login.slice());
    const explicit = try parse(std.testing.allocator, "{\"url\":\"https://github.com/org/repo/pull/42\",\"account\":\"chosen\"}");
    const bound = prepare(explicit, .{ .sole_login = login });
    try std.testing.expectEqualStrings("chosen", bound.watch.login.slice());
    descriptor = prepare(args, .discovery_required);
    try std.testing.expectEqualStrings("{\"kind\":\"discover_accounts\",\"url\":\"https://github.com/org/repo/pull/42\"}", try encode(&descriptor, &buffer));
    const decoded_discovery = try decodeDescriptor(std.testing.allocator, try encode(&descriptor, &buffer));
    try std.testing.expectEqualStrings(args.url.slice(), decoded_discovery.discover_accounts.slice());
    try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, "{\"url\":\"https://github.com/o/r/pull/1\",\"account\":\"a\",\"account\":\"b\"}"));
    try std.testing.expectError(error.InvalidDescriptor, decodeDescriptor(std.testing.allocator, "{\"kind\":\"watch\",\"url\":\"https://github.com/o/r/pull/1\"}"));
    try std.testing.expectError(error.InvalidDescriptor, decodeDescriptor(std.testing.allocator, "{\"kind\":\"discover_accounts\",\"url\":\"https://github.com/o/r/pull/1\",\"login\":\"a\"}"));
}
