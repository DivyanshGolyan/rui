const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;

pub const max_url_bytes = 256;
pub const max_login_bytes = 39;

pub const Arguments = struct {
    url: Bounded(max_url_bytes),
    account: ?Bounded(max_login_bytes),
};

pub fn validLogin(s: []const u8) bool {
    if (s.len == 0 or s.len > max_login_bytes or !std.ascii.isAlphanumeric(s[0]) or !std.ascii.isAlphanumeric(s[s.len - 1])) return false;
    var previous_hyphen = false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
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

test "PRW-41 account validation rejects invalid logins" {
    for ([_][]const u8{ "", "-bad", "bad-", "_bad", "bad_", "a--b", "a/b" }) |login| try std.testing.expect(!validLogin(login));
    try std.testing.expect(validLogin("octocat"));
    try std.testing.expect(validLogin("alice_acme"));
}

test "PRW-59 arguments accept one pull request URL and an optional login and nothing else" {
    const url = "\"url\":\"https://github.com/org/repo/pull/42\"";
    const accepted = try parse(std.testing.allocator, "{" ++ url ++ "}");
    try std.testing.expect(accepted.account == null);
    const named = try parse(std.testing.allocator, "{" ++ url ++ ",\"account\":\"chosen\"}");
    try std.testing.expectEqualStrings("chosen", named.account.?.slice());
    for ([_][]const u8{
        "{}",
        "[]",
        "{\"account\":\"chosen\"}",
        "{" ++ url ++ ",\"account\":null}",
        "{" ++ url ++ ",\"account\":\"-bad\"}",
        "{" ++ url ++ ",\"account\":\"a\",\"account\":\"b\"}",
        "{" ++ url ++ ",\"other\":1}",
        "{\"url\":\"https://github.com.evil/org/repo/pull/42\"}",
    }) |bytes| try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, bytes));
}
