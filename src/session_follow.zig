const std = @import("std");
pub const Reference = [@import("session_id.zig").bytes]u8;
pub const Origin = enum { peer, assistant };
pub const Target = struct { reference: Reference, origin: Origin };
pub const Stage = enum { target, source };
pub const Ticket = struct { generation: u64, reference: Reference, stage: Stage };
pub const Missing = union(enum) { stale, restore: Reference, overview };
pub const Ready = enum { stale, opened, restored };

pub const Follow = struct {
    const Attempt = struct {
        generation: u64,
        source: Reference,
        target: Reference,
        previous_return_to: ?Reference,
        stage: Stage = .target,
    };

    return_to: ?Reference = null,
    pending: ?Target = null,
    generation: u64 = 0,
    attempt: ?Attempt = null,

    pub fn clear(self: *Follow) void {
        const generation = self.generation;
        self.* = .{ .generation = generation };
    }

    pub fn next(self: *Follow, from: Reference) !?Reference {
        if (self.pending) |target| {
            self.pending = null;
            self.attempt = null;
            if (target.origin == .assistant) {
                self.generation = try std.math.add(u64, self.generation, 1);
                self.attempt = .{ .generation = self.generation, .source = from, .target = target.reference, .previous_return_to = self.return_to };
            }
            self.return_to = from;
            return target.reference;
        }
        self.attempt = null;
        defer self.return_to = null;
        return self.return_to;
    }

    pub fn ticket(self: *const Follow, reference: Reference) ?Ticket {
        const attempt = self.attempt orelse return null;
        const expected = if (attempt.stage == .target) attempt.target else attempt.source;
        if (!std.mem.eql(u8, &expected, &reference)) return null;
        return .{ .generation = attempt.generation, .reference = reference, .stage = attempt.stage };
    }

    pub fn current(self: *const Follow, ticket_: Ticket) bool {
        const valid = self.ticket(ticket_.reference) orelse return false;
        return valid.generation == ticket_.generation and valid.stage == ticket_.stage;
    }

    pub fn missing(self: *Follow, ticket_: Ticket) Missing {
        if (!self.current(ticket_)) return .stale;
        const attempt = &self.attempt.?;
        if (attempt.stage == .source) {
            self.attempt = null;
            self.return_to = null;
            return .overview;
        }
        self.return_to = attempt.previous_return_to;
        attempt.stage = .source;
        return .{ .restore = attempt.source };
    }

    pub fn ready(self: *Follow, ticket_: Ticket) Ready {
        if (!self.current(ticket_)) return .stale;
        const stage = self.attempt.?.stage;
        self.attempt = null;
        return if (stage == .target) .opened else .restored;
    }
};

test "SUI-148 Session link opening settles only the exact follow attempt" {
    const source = "aaaaaa".*;
    const target = "bbbbbb".*;
    const previous = "cccccc".*;
    var follow: Follow = .{ .return_to = previous };
    follow.pending = .{ .reference = target, .origin = .assistant };
    try std.testing.expectEqual(@as(?Reference, target), try follow.next(source));
    const ticket_ = follow.ticket(target).?;
    try std.testing.expectEqual(Missing.stale, follow.missing(.{ .generation = ticket_.generation + 1, .reference = target, .stage = .target }));
    try std.testing.expectEqual(Missing.stale, follow.missing(.{ .generation = ticket_.generation, .reference = source, .stage = .source }));
    try std.testing.expectEqualDeep(Missing{ .restore = source }, follow.missing(ticket_));
    try std.testing.expectEqual(@as(?Reference, previous), follow.return_to);
    try std.testing.expectEqual(Ready.stale, follow.ready(ticket_));
    const returning = follow.ticket(source).?;
    try std.testing.expectEqual(Ready.restored, follow.ready(returning));
    try std.testing.expectEqual(Ready.stale, follow.ready(returning));
    try std.testing.expectEqual(@as(?Reference, previous), try follow.next(source));
    try std.testing.expectEqual(@as(?Reference, null), try follow.next(previous));

    follow.pending = .{ .reference = target, .origin = .assistant };
    _ = try follow.next(source);
    const missing_target = follow.ticket(target).?;
    try std.testing.expectEqualDeep(Missing{ .restore = source }, follow.missing(missing_target));
    try std.testing.expectEqual(Missing.overview, follow.missing(follow.ticket(source).?));
    try std.testing.expectEqual(Missing.stale, follow.missing(missing_target));

    follow.pending = .{ .reference = target, .origin = .assistant };
    _ = try follow.next(source);
    const first = follow.ticket(target).?;
    follow.pending = .{ .reference = target, .origin = .assistant };
    _ = try follow.next(source);
    try std.testing.expectEqual(Missing.stale, follow.missing(first));
    const second = follow.ticket(target).?;
    follow.clear();
    follow.pending = .{ .reference = target, .origin = .assistant };
    _ = try follow.next(source);
    try std.testing.expectEqual(Missing.stale, follow.missing(second));
    try std.testing.expectEqual(Ready.opened, follow.ready(follow.ticket(target).?));
    try std.testing.expectEqual(@as(?Reference, source), try follow.next(target));

    follow.pending = .{ .reference = target, .origin = .peer };
    _ = try follow.next(source);
    try std.testing.expectEqual(@as(?Ticket, null), follow.ticket(target));
    follow.pending = .{ .reference = previous, .origin = .peer };
    try std.testing.expectEqual(@as(?Reference, previous), try follow.next(target));
    try std.testing.expectEqual(@as(?Reference, target), try follow.next(previous));
    try std.testing.expectEqual(@as(?Reference, null), try follow.next(target));

    follow.pending = .{ .reference = source, .origin = .assistant };
    _ = try follow.next(source);
    const same_target = follow.ticket(source).?;
    try std.testing.expectEqualDeep(Missing{ .restore = source }, follow.missing(same_target));
    try std.testing.expectEqual(Missing.stale, follow.missing(same_target));
    try std.testing.expectEqual(Missing.overview, follow.missing(follow.ticket(source).?));
}

pub const ReadFailure = struct { status: u16, kind: []const u8, code: []const u8 };
pub const OpeningFailure = enum { missing, confirm_current, other };

pub fn openingFailure(err: anyerror, diagnostic: ?ReadFailure) OpeningFailure {
    if (err == error.SessionNotConfigured and diagnostic == null) return .missing;
    if (err != error.HostInvocationFailed) return .other;
    const failure = diagnostic orelse return .other;
    if (failure.status != 409) return .other;
    if (std.mem.eql(u8, failure.kind, "activity_unavailable") and std.mem.eql(u8, failure.code, "SessionNotFound")) return .missing;
    if ((std.mem.eql(u8, failure.kind, "activity_unavailable") or std.mem.eql(u8, failure.kind, "parts_unavailable")) and
        std.mem.eql(u8, failure.code, "ContentNotFound")) return .confirm_current;
    return .other;
}

test "SUI-149 opening failures distinguish missing targets from content and transport errors" {
    const cases = [_]struct { err: anyerror, diagnostic: ?ReadFailure, expected: OpeningFailure }{
        .{ .err = error.SessionNotConfigured, .diagnostic = null, .expected = .missing },
        .{ .err = error.SessionNotConfigured, .diagnostic = .{ .status = 503, .kind = "busy", .code = "host_busy" }, .expected = .other },
        .{ .err = error.HostInvocationFailed, .diagnostic = .{ .status = 409, .kind = "activity_unavailable", .code = "SessionNotFound" }, .expected = .missing },
        .{ .err = error.HostInvocationFailed, .diagnostic = .{ .status = 409, .kind = "activity_unavailable", .code = "ContentNotFound" }, .expected = .confirm_current },
        .{ .err = error.HostInvocationFailed, .diagnostic = .{ .status = 409, .kind = "parts_unavailable", .code = "ContentNotFound" }, .expected = .confirm_current },
        .{ .err = error.HostInvocationFailed, .diagnostic = .{ .status = 409, .kind = "activity_unavailable", .code = "InvalidCursor" }, .expected = .other },
        .{ .err = error.HostInvocationFailed, .diagnostic = .{ .status = 503, .kind = "activity_unavailable", .code = "SessionNotFound" }, .expected = .other },
        .{ .err = error.HostInvocationFailed, .diagnostic = .{ .status = 409, .kind = "parts_unavailable", .code = "SessionNotFound" }, .expected = .other },
        .{ .err = error.HostInvocationFailed, .diagnostic = null, .expected = .other },
        .{ .err = error.CanonicalStoreFailure, .diagnostic = .{ .status = 409, .kind = "activity_unavailable", .code = "SessionNotFound" }, .expected = .other },
        .{ .err = error.ConnectionResetByPeer, .diagnostic = null, .expected = .other },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, openingFailure(case.err, case.diagnostic));
}
