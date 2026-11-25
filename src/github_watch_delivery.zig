const std = @import("std");
const watch = @import("github_pr_watch.zig");

/// Host-owned publication state. An in-flight value is immutable until the
/// Store reports whether its key committed; the latest observation can move
/// forward independently while that result is uncertain.
pub const Delivery = struct {
    latest: ?watch.Reduction = null,
    accepted: ?watch.Snapshot = null,
    frozen: ?Value = null,
    next_sequence: u64 = 1,
    skipped: bool = false,

    pub const Kind = enum { initial, transition, coalesced };
    pub const Value = struct {
        sequence: u64,
        snapshot: watch.Snapshot,
        changed: watch.Changes,
        coverage: watch.Coverage,
        kind: Kind,
    };

    pub fn observe(self: *Delivery, value: watch.Reduction) void {
        if (self.latest) |previous| {
            if (!sameState(previous.snapshot, value.snapshot) and self.hasUnpublished()) self.skipped = true;
        }
        self.latest = value;
    }

    /// A closed or merged observation belongs only in the terminal Resolution.
    pub fn candidate(self: *Delivery) ?Value {
        const latest = self.latest orelse return null;
        if (latest.snapshot.lifecycle == .closed or latest.snapshot.lifecycle == .merged) return null;
        if (self.frozen) |value| return value;
        if (!self.hasUnpublished()) return null;
        const changed = changes(self.accepted, latest.snapshot);
        const value: Value = .{
            .sequence = self.next_sequence,
            .snapshot = latest.snapshot,
            .changed = changed,
            .coverage = latest.coverage,
            .kind = if (self.accepted == null) .initial else if (self.skipped) .coalesced else .transition,
        };
        self.frozen = value;
        return value;
    }

    /// Only an accepted or replayed write advances the sequence. A definite
    /// refusal may be replaced by a newer aggregate with the same key.
    pub fn acceptedValue(self: *Delivery) void {
        const value = self.frozen orelse unreachable;
        self.accepted = value.snapshot;
        self.next_sequence += 1;
        self.frozen = null;
        self.skipped = if (self.latest) |latest| !sameState(latest.snapshot, value.snapshot) else false;
    }

    pub fn refusedValue(self: *Delivery) void {
        self.frozen = null;
    }

    fn hasUnpublished(self: *const Delivery) bool {
        const latest = self.latest orelse return false;
        const accepted = self.accepted orelse return true;
        return self.skipped or !sameState(accepted, latest.snapshot);
    }
};

fn sameState(a: watch.Snapshot, b: watch.Snapshot) bool {
    return std.mem.eql(u8, &a.head, &b.head) and a.lifecycle == b.lifecycle and a.checks == b.checks and a.reviews == b.reviews;
}

fn changes(previous: ?watch.Snapshot, current: watch.Snapshot) watch.Changes {
    const old = previous orelse return .{ .head = true, .lifecycle = true, .checks = true, .reviews = true };
    return .{
        .head = !std.mem.eql(u8, &old.head, &current.head),
        .lifecycle = old.lifecycle != current.lifecycle,
        .checks = old.checks != current.checks,
        .reviews = old.reviews != current.reviews,
    };
}

fn fixture(checks: watch.Checks, lifecycle: watch.Lifecycle) watch.Reduction {
    return .{ .snapshot = .{ .observed_at = 1, .head = @splat(1), .lifecycle = lifecycle, .checks = checks, .reviews = .none }, .changed = .{}, .coverage = .complete };
}

test "PRW-10 foreground retains latest baseline without spending a sequence" {
    var delivery: Delivery = .{};
    delivery.observe(fixture(.pending, .open));
    try std.testing.expectEqual(@as(u64, 1), delivery.candidate().?.sequence);
    delivery.refusedValue();
    delivery.observe(fixture(.passing, .open));
    const value = delivery.candidate().?;
    try std.testing.expectEqual(@as(u64, 1), value.sequence);
    try std.testing.expectEqual(Delivery.Kind.initial, value.kind);
    try std.testing.expectEqual(watch.Checks.passing, value.snapshot.checks);
    delivery.acceptedValue();
    try std.testing.expect(delivery.candidate() == null);
}

test "PRW-34 uncertain publication remains frozen while later changes coalesce" {
    var delivery: Delivery = .{};
    delivery.observe(fixture(.pending, .open));
    const first = delivery.candidate().?;
    delivery.observe(fixture(.passing, .open));
    try std.testing.expectEqualDeep(first, delivery.candidate().?);
    delivery.acceptedValue();
    const next = delivery.candidate().?;
    try std.testing.expectEqual(@as(u64, 2), next.sequence);
    try std.testing.expectEqual(Delivery.Kind.coalesced, next.kind);
    try std.testing.expect(next.changed.checks);
}

test "PRW-35 close is retained for settlement and never published" {
    var delivery: Delivery = .{};
    delivery.observe(fixture(.pending, .open));
    _ = delivery.candidate();
    delivery.acceptedValue();
    delivery.observe(fixture(.passing, .merged));
    try std.testing.expect(delivery.candidate() == null);
    try std.testing.expectEqual(watch.Lifecycle.merged, delivery.latest.?.snapshot.lifecycle);
}

test "PRW-36 closing suppresses a definitely refused earlier transition" {
    var delivery: Delivery = .{};
    delivery.observe(fixture(.pending, .open));
    _ = delivery.candidate();
    delivery.refusedValue();
    delivery.observe(fixture(.passing, .merged));
    try std.testing.expect(delivery.candidate() == null);
}

pub const Outcome = enum { closed, merged, cancelled, deadline_expired, auth_required, account_unavailable, account_discovery_failed, gh_unavailable, pr_inaccessible, revoked, network_failure, rate_limited, capacity_exceeded };

/// This output is constructed entirely from typed values; it contains no API
/// names, messages, response bodies, credential material, or arbitrary text.
pub fn encodeValue(value: Delivery.Value, buffer: []u8) ![]const u8 {
    const head = std.fmt.bytesToHex(value.snapshot.head, .lower);
    const changed = value.changed;
    return std.fmt.bufPrint(buffer, "{{\"sequence\":{d},\"snapshot\":{{\"observed_at\":{d},\"head_sha\":\"{s}\",\"lifecycle\":\"{s}\",\"checks\":\"{s}\",\"reviews\":\"{s}\"}},\"changed\":[{s}{s}{s}{s}],\"kind\":\"{s}\",\"coverage\":\"{s}\"}}", .{
        value.sequence,                       value.snapshot.observed_at,                                                             head,                                                                                               @tagName(value.snapshot.lifecycle),                                                                                      @tagName(value.snapshot.checks), @tagName(value.snapshot.reviews),
        if (changed.head) "\"head\"" else "", if (changed.lifecycle) if (changed.head) ",\"lifecycle\"" else "\"lifecycle\"" else "", if (changed.checks) if (changed.head or changed.lifecycle) ",\"checks\"" else "\"checks\"" else "", if (changed.reviews) if (changed.head or changed.lifecycle or changed.checks) ",\"reviews\"" else "\"reviews\"" else "", @tagName(value.kind),            @tagName(value.coverage),
    });
}

pub fn encodeEnd(self: *const Delivery, outcome: Outcome, retry_at: ?i64, buffer: []u8) ![]const u8 {
    const pending = self.hasUnpublished() and if (self.latest) |last|
        last.snapshot.lifecycle != .closed and last.snapshot.lifecycle != .merged
    else
        false;
    var retry_buffer: [32]u8 = undefined;
    const retry = if (retry_at) |when| try std.fmt.bufPrint(&retry_buffer, "{d}", .{when}) else "null";
    if (self.latest) |last| {
        const head = std.fmt.bytesToHex(last.snapshot.head, .lower);
        return std.fmt.bufPrint(buffer, "{{\"outcome\":\"{s}\",\"last_snapshot\":{{\"observed_at\":{d},\"head_sha\":\"{s}\",\"lifecycle\":\"{s}\",\"checks\":\"{s}\",\"reviews\":\"{s}\"}},\"delivery_coalesced\":{},\"retry_at\":{s}}}", .{ @tagName(outcome), last.snapshot.observed_at, head, @tagName(last.snapshot.lifecycle), @tagName(last.snapshot.checks), @tagName(last.snapshot.reviews), self.skipped or pending, retry });
    }
    return std.fmt.bufPrint(buffer, "{{\"outcome\":\"{s}\",\"last_snapshot\":null,\"delivery_coalesced\":{},\"retry_at\":{s}}}", .{ @tagName(outcome), self.skipped, retry });
}

test "PRW-37 terminal outcome includes the latest unpublished observation" {
    var delivery: Delivery = .{};
    delivery.observe(fixture(.pending, .open));
    _ = delivery.candidate();
    delivery.acceptedValue();
    delivery.observe(fixture(.passing, .open));
    _ = delivery.candidate();
    delivery.refusedValue();
    delivery.observe(fixture(.failing, .closed));
    var buffer: [1024]u8 = undefined;
    const encoded = try encodeEnd(&delivery, .closed, null, &buffer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("closed", parsed.value.object.get("outcome").?.string);
    const snapshot = parsed.value.object.get("last_snapshot").?.object;
    try std.testing.expectEqualStrings("failing", snapshot.get("checks").?.string);
    try std.testing.expect(parsed.value.object.get("delivery_coalesced").?.bool);
}

test "PRW-38 a terminal-only observation is not a dropped update" {
    var delivery: Delivery = .{};
    delivery.observe(fixture(.passing, .merged));
    var buffer: [1024]u8 = undefined;
    const encoded = try encodeEnd(&delivery, .merged, null, &buffer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("delivery_coalesced").?.bool);
}

test "PRW-39 changed dimensions encode as a set" {
    const names = [_][]const u8{ "head", "lifecycle", "checks", "reviews" };
    for (0..16) |mask| {
        var delivery: Delivery = .{};
        delivery.observe(fixture(.pending, .open));
        var value = delivery.candidate().?;
        value.changed = .{
            .head = mask & 1 != 0,
            .lifecycle = mask & 2 != 0,
            .checks = mask & 4 != 0,
            .reviews = mask & 8 != 0,
        };
        var buffer: [1024]u8 = undefined;
        const encoded = try encodeValue(value, &buffer);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
        defer parsed.deinit();
        const items = parsed.value.object.get("changed").?.array.items;
        var seen: [names.len]bool = @splat(false);
        for (items) |item| {
            try std.testing.expect(item == .string);
            const index = for (names, 0..) |name, i| {
                if (std.mem.eql(u8, item.string, name)) break i;
            } else return error.UnexpectedDimension;
            try std.testing.expect(!seen[index]);
            seen[index] = true;
        }
        for (seen, 0..) |present, i| {
            try std.testing.expectEqual(mask & (@as(usize, 1) << @intCast(i)) != 0, present);
        }
    }
}
