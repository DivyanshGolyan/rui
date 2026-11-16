const std = @import("std");
const Faults = @This();

pub const Direction = enum(u1) { read, write };

pub const Rates = struct {
    short: u8 = 30,
    again: u8 = 15,
    cut: u8 = 20,
    cut_span: u32 = 64 * 1024,
};

pub const Decision = union(enum) {
    pass: usize,
    again,
    closed,
};

pub const Counts = struct { short: u32 = 0, again: u32 = 0, cut: u32 = 0, moved: u64 = 0 };

const max_connections = 256;

const Line = struct {
    seen: bool = false,
    moved: [2]u64 = .{ 0, 0 },
    cut: [2]?u64 = .{ null, null },
    again_run: [2]u8 = .{ 0, 0 },
};

prng: std.Random.DefaultPrng,
rates: Rates,
lines: [max_connections]Line = @splat(.{}),
counts: Counts = .{},

pub fn init(seed: u64, rates: Rates) Faults {
    return .{ .prng = .init(seed), .rates = rates };
}

pub fn admit(self: *Faults, serial: u64, direction: Direction, wanted: usize, tls: bool) Decision {
    std.debug.assert(wanted > 0);
    if (serial >= max_connections) return .{ .pass = wanted };
    const random = self.prng.random();
    const line = &self.lines[serial];
    if (!line.seen) {
        line.seen = true;
        if (random.uintLessThan(u8, 100) < self.rates.cut)
            line.cut[@intFromBool(random.boolean())] = random.uintLessThan(u64, self.rates.cut_span);
    }
    const d = @backingInt(direction);
    if (line.cut[d]) |cut| if (line.moved[d] >= cut) {
        self.counts.cut += 1;
        return .closed;
    };
    if (line.again_run[d] < 3 and random.uintLessThan(u8, 100) < self.rates.again) {
        line.again_run[d] += 1;
        self.counts.again += 1;
        return .again;
    }
    line.again_run[d] = 0;
    var allowed = wanted;
    if (wanted > 1 and !(tls and direction == .write) and random.uintLessThan(u8, 100) < self.rates.short) {
        allowed = random.intRangeAtMost(usize, 1, wanted - 1);
        self.counts.short += 1;
    }
    if (line.cut[d]) |cut| allowed = @min(allowed, cut - line.moved[d]);
    return .{ .pass = allowed };
}

pub fn moved(self: *Faults, serial: u64, direction: Direction, count: usize) void {
    self.counts.moved += count;
    if (serial >= max_connections) return;
    self.lines[serial].moved[@backingInt(direction)] += count;
}

test "a cut connection moves exactly its bytes, then reports closed" {
    var faults: Faults = .init(7, .{ .short = 0, .again = 0, .cut = 100, .cut_span = 10 });
    var total: [2]u64 = .{ 0, 0 };
    for ([_]Direction{ .read, .write }) |direction| {
        var steps: u32 = 0;
        while (steps < 100) : (steps += 1) switch (faults.admit(1, direction, 4, false)) {
            .pass => |count| {
                try std.testing.expect(count >= 1 and count <= 4);
                faults.moved(1, direction, count);
                total[@backingInt(direction)] += count;
            },
            .again => unreachable,
            .closed => break,
        };
    }
    const cut_direction: usize = if (faults.lines[1].cut[0] != null) 0 else 1;
    try std.testing.expectEqual(faults.lines[1].cut[cut_direction].?, total[cut_direction]);
    try std.testing.expectEqual(@as(u64, 400), total[1 - cut_direction]);
}

test "EAGAIN never comes more than three times in a row" {
    var faults: Faults = .init(1, .{ .short = 0, .again = 100, .cut = 0 });
    for (0..5) |_| {
        for (0..3) |_| try std.testing.expectEqual(Decision.again, faults.admit(1, .read, 8, false));
        try std.testing.expectEqual(Decision{ .pass = 8 }, faults.admit(1, .read, 8, false));
    }
}
