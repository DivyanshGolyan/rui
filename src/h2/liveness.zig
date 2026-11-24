const std = @import("std");

const ns_per_s: u64 = 1_000_000_000;

pub const Liveness = struct {
    ping_after_quiet_ns: u64 = 45 * ns_per_s,
    ping_timeout_ns: u64 = 15 * ns_per_s,
    idle_close_ns: u64 = 118 * ns_per_s,

    pub fn action(config: Liveness, facts: Facts) Action {
        if (facts.streams == 0) {
            if (!facts.is_only_idle) return .close;
            const since = facts.idle_since_ns orelse return .none;
            return if (facts.now_ns -| since >= config.idle_close_ns) .close else .none;
        }
        if (pingOutstanding(facts)) |sent| {
            return if (facts.now_ns -| sent >= config.ping_timeout_ns) .dead else .none;
        }
        return if (facts.now_ns -| facts.last_inbound_ns >= config.ping_after_quiet_ns) .ping else .none;
    }

    pub fn deadline(config: Liveness, facts: Facts) ?u64 {
        if (facts.streams == 0) {
            if (!facts.is_only_idle) return facts.now_ns;
            const since = facts.idle_since_ns orelse return null;
            return since +| config.idle_close_ns;
        }
        if (pingOutstanding(facts)) |sent| return sent +| config.ping_timeout_ns;
        return facts.last_inbound_ns +| config.ping_after_quiet_ns;
    }
};

pub const Facts = struct {
    now_ns: u64,
    last_inbound_ns: u64,
    ping_sent_ns: ?u64,
    streams: u32,
    idle_since_ns: ?u64,
    is_only_idle: bool,
};

pub const Action = enum { none, ping, dead, close };

fn pingOutstanding(facts: Facts) ?u64 {
    const sent = facts.ping_sent_ns orelse return null;
    return if (facts.last_inbound_ns > sent) null else sent;
}

fn with(base: anytype, comptime field: []const u8, value: anytype) @TypeOf(base) {
    var facts = base;
    @field(facts, field) = value;
    return facts;
}

test "one PING per quiet connection, a missed PING is fatal, idle connections close" {
    const s = ns_per_s;
    const config: Liveness = .{};
    const busy: Facts = .{
        .now_ns = 100 * s,
        .last_inbound_ns = 100 * s,
        .ping_sent_ns = null,
        .streams = 3,
        .idle_since_ns = null,
        .is_only_idle = true,
    };
    const Row = struct { facts: Facts, action: Action, deadline: ?u64 };
    const rows = [_]Row{
        .{ .facts = busy, .action = .none, .deadline = 145 * s },
        .{ .facts = with(busy, "last_inbound_ns", 56 * s), .action = .none, .deadline = 101 * s },
        .{ .facts = with(busy, "last_inbound_ns", 55 * s), .action = .ping, .deadline = 100 * s },
        .{ .facts = with(with(busy, "last_inbound_ns", 50 * s), "ping_sent_ns", 95 * s), .action = .none, .deadline = 110 * s },
        .{ .facts = with(with(busy, "last_inbound_ns", 50 * s), "ping_sent_ns", 85 * s), .action = .dead, .deadline = 100 * s },
        .{ .facts = with(with(busy, "last_inbound_ns", 90 * s), "ping_sent_ns", 80 * s), .action = .none, .deadline = 135 * s },
        .{ .facts = with(with(with(busy, "last_inbound_ns", 90 * s), "ping_sent_ns", 80 * s), "now_ns", 135 * s), .action = .ping, .deadline = 135 * s },
        .{ .facts = with(with(busy, "streams", 0), "idle_since_ns", 0), .action = .none, .deadline = 118 * s },
        .{ .facts = with(with(busy, "streams", 0), "idle_since_ns", 100 * s), .action = .none, .deadline = 218 * s },
        .{ .facts = with(with(with(busy, "streams", 0), "idle_since_ns", 0), "now_ns", 118 * s), .action = .close, .deadline = 118 * s },
        .{ .facts = with(with(with(busy, "streams", 0), "idle_since_ns", 99 * s), "is_only_idle", false), .action = .close, .deadline = 100 * s },
    };
    for (rows) |row| {
        try std.testing.expectEqual(row.action, config.action(row.facts));
        try std.testing.expectEqual(row.deadline, config.deadline(row.facts));
    }
}
