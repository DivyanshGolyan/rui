const std = @import("std");

pub const Root = enum { native, store };
pub const roots = std.enums.values(Root);

pub fn owner(name: []const u8) Root {
    return if (std.mem.startsWith(u8, name, "store.")) .store else .native;
}

pub const Timing = struct { name: []const u8, seconds: f64 };
pub const Shard = struct {
    index: usize,
    count: usize,

    pub fn parse(text: []const u8) !Shard {
        const slash = std.mem.indexOfScalar(u8, text, '/') orelse return error.InvalidUnitShard;
        const index = std.fmt.parseUnsigned(usize, text[0..slash], 10) catch return error.InvalidUnitShard;
        const count = std.fmt.parseUnsigned(usize, text[slash + 1 ..], 10) catch return error.InvalidUnitShard;
        if (count == 0 or index >= count) return error.InvalidUnitShard;
        return .{ .index = index, .count = count };
    }
};

const Weighted = struct { index: usize, name: []const u8, seconds: f64 };

pub fn exclusive(name: []const u8) bool {
    const prefix = "store.mysql_testing.test.";
    const tests = [_][]const u8{
        "store.mysql live admission refuses read_only",
        "store.mysql live admission refuses super_read_only",
        "store.mysql live admission refuses weak InnoDB commit flush",
        "store.mysql live admission refuses weak binlog sync",
        "store.mysql live admission refuses statement binlogging",
        "store.mysql live content chunks keep each batch within a small max_allowed_packet",
        "store.mysql live a reconnect onto a server admission refuses does not resume",
    };
    inline for (tests) |test_name| if (std.mem.eql(u8, name, prefix ++ test_name)) return true;
    return false;
}

fn fixedOwner(name: []const u8) bool {
    // Session tests still mutate one fixed schema. Dialect/migration schemas
    // and shadow PREPARE schemas have a namespace per process instead.
    return exclusive(name) or std.mem.startsWith(u8, name, "store.mysql_session_tests.");
}

fn stableShard(name: []const u8, count: usize) usize {
    // FNV-1a is explicit so missing-test placement survives toolchain upgrades.
    var hash: u64 = 14695981039346656037;
    for (name) |byte| hash = (hash ^ byte) *% 1099511628211;
    return @intCast(hash % count);
}

/// Caller owns the returned slice. Removed measurements do not schedule tests;
/// new tests keep hash placement and contribute the recorded median to loads.
pub fn assign(allocator: std.mem.Allocator, names: []const []const u8, times: []const Timing, count: usize) ![]usize {
    if (count == 0) return error.InvalidUnitShard;
    const result = try allocator.alloc(usize, names.len);
    errdefer allocator.free(result);
    const loads = try allocator.alloc(f64, count);
    defer allocator.free(loads);
    @memset(loads, 0);
    const durations = try allocator.alloc(f64, times.len);
    defer allocator.free(durations);
    for (times, durations) |entry, *duration| duration.* = entry.seconds;
    std.mem.sort(f64, durations, {}, struct {
        fn before(_: void, a: f64, b: f64) bool {
            return a < b;
        }
    }.before);
    const median = if (durations.len == 0) 1.0 else if (durations.len % 2 == 1)
        durations[durations.len / 2]
    else
        (durations[durations.len / 2 - 1] + durations[durations.len / 2]) / 2;
    const known = try allocator.alloc(Weighted, names.len);
    defer allocator.free(known);
    var known_count: usize = 0;
    for (names, 0..) |name, index| {
        var duration: ?f64 = null;
        for (times) |entry| if (std.mem.eql(u8, entry.name, name)) {
            duration = entry.seconds;
            break;
        };
        if (fixedOwner(name) or duration == null) {
            const shard = if (fixedOwner(name)) 0 else stableShard(name, count);
            result[index] = shard;
            loads[shard] += duration orelse median;
        } else {
            known[known_count] = .{ .index = index, .name = name, .seconds = duration.? };
            known_count += 1;
        }
    }
    std.mem.sort(Weighted, known[0..known_count], {}, struct {
        fn before(_: void, a: Weighted, b: Weighted) bool {
            if (a.seconds != b.seconds) return a.seconds > b.seconds;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.before);
    for (known[0..known_count]) |entry| {
        var shard: usize = 0;
        for (loads, 0..) |load, index| if (load < loads[shard]) {
            shard = index;
        };
        result[entry.index] = shard;
        loads[shard] += entry.seconds;
    }
    return result;
}

test "unit shard assignment covers every inventory exactly once for K 1 through 8" {
    const allocator = std.testing.allocator;
    const times = [_]Timing{
        .{ .name = "store.test.slow", .seconds = 100 },
        .{ .name = "store.test.middle", .seconds = 40 },
        .{ .name = "store.test.quick", .seconds = 2 },
        .{ .name = "store.test.removed", .seconds = 900 },
        .{ .name = "store.mysql_session_tests.test.schema", .seconds = 20 },
    };
    const names = [_][]const u8{
        "store.test.quick",                           "store.test.slow",        "store.test.middle",
        "store.test.new",                             "store.test.another new", "store.mysql_session_tests.test.schema",
        "store.mysql_session_tests.test.new session",
    };
    for (1..9) |count| {
        const placement = try assign(allocator, &names, &times, count);
        defer allocator.free(placement);
        const seen = try allocator.alloc(usize, names.len);
        defer allocator.free(seen);
        @memset(seen, 0);
        for (0..count) |shard| {
            for (placement, 0..) |selected, index| if (selected == shard) {
                seen[index] += 1;
            };
        }
        for (seen) |occurrences| try std.testing.expectEqual(@as(usize, 1), occurrences);
        try std.testing.expectEqual(@as(usize, 0), placement[5]);
        try std.testing.expectEqual(@as(usize, 0), placement[6]);
        try std.testing.expectEqual(stableShard(names[3], count), placement[3]);
        const again = try assign(allocator, &names, &times, count);
        defer allocator.free(again);
        try std.testing.expectEqualSlices(usize, placement, again);
    }
}

test "unit shard LPT balances known tests and validates selectors" {
    const names = [_][]const u8{ "a", "store.mysql_dialect_check.test.schema", "c", "d" };
    const times = [_]Timing{
        .{ .name = "a", .seconds = 8 }, .{ .name = "store.mysql_dialect_check.test.schema", .seconds = 7 },
        .{ .name = "c", .seconds = 6 }, .{ .name = "d", .seconds = 5 },
    };
    const placement = try assign(std.testing.allocator, &names, &times, 2);
    defer std.testing.allocator.free(placement);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 1, 0 }, placement);
    for ([_][]const u8{ "", "0", "0/0", "4/4", "1/2/3", "-1/4", "1/-4" }) |text|
        try std.testing.expectError(error.InvalidUnitShard, Shard.parse(text));
    try std.testing.expectEqual(Shard{ .index = 3, .count = 4 }, try Shard.parse("3/4"));
}
