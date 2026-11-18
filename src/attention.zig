const std = @import("std");
const session_line = @import("session_line.zig");
const session_work = @import("session_work.zig");

pub const Attention = session_work.Attention;
pub const Kind = @FieldType(Attention, "kind");

fn attentionAfter(self: Attention, other: Attention) bool {
    return self.turn > other.turn or (self.turn == other.turn and self.step > other.step);
}

pub fn observe(seen: *?Attention, work: session_work.Work) ?Kind {
    const now = work.served_attention orelse return null;
    if (seen.*) |held| if (!attentionAfter(now, held)) return null;
    seen.* = now;
    return now.kind;
}

pub const max_name_bytes = 80;

pub const Status = enum {
    idle,
    working,
    done,
    blocked,
    failed,

    pub fn of(work: session_work.Work) Status {
        return statusFromServed(work.served_group.?, work.served_attention);
    }

    pub fn next(held: ?Status, was: ?Reading, now: Reading, opening: bool) ?Status {
        const changed = if (was) |before| before.status != now.status or now.after(before) else !opening;
        if (!changed) return if (was == null and (now.status == .working or now.status == .blocked)) now.status else held;
        if (held == null and now.status == .idle) return null;
        return now.status;
    }

    pub fn opened(held: ?Status) ?Status {
        const status = held orelse return null;
        return if (status == .done or status == .failed) .idle else status;
    }
};

fn statusFromServed(group: session_work.Group, served: ?Attention) Status {
    return switch (group) {
        .needs_you => .blocked,
        .working, .queued => .working,
        .done => if (served) |value| switch (value.kind) {
            .failed => .failed,
            .finished => .done,
            .approval => .idle,
        } else .idle,
    };
}

pub const Reading = struct {
    status: Status,
    attention: ?Attention,

    pub fn of(work: session_work.Work, acknowledged: ?Attention) Reading {
        const status: Status = .of(work);
        const now = work.served_attention;
        const seen = if (now) |reached| if (acknowledged) |opened| !attentionAfter(reached, opened) else false else false;
        return .{ .status = if (seen and (status == .done or status == .failed)) .idle else status, .attention = now };
    }

    pub fn after(self: Reading, before: Reading) bool {
        const now = self.attention orelse return false;
        const held = before.attention orelse return true;
        return attentionAfter(now, held);
    }
};

const status_root = "rui";
pub const max_status_bytes = 64 + status_root.len + 1 + max_id_segment + std.base64.standard.Encoder.calcSize(max_name_bytes * 3);
const max_id_segment = 32;

pub fn writeStatus(out: *std.Io.Writer, session: []const u8, name: []const u8, status: ?Status) !void {
    try out.print("\x1b]7501;state={s}:id=" ++ status_root ++ "/", .{if (status) |known| switch (known) {
        .failed => "error",
        else => @tagName(known),
    } else "clear"});
    for (session[0..@min(session.len, max_id_segment)]) |byte| try out.writeByte(switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '.', '+', '-' => byte,
        else => '_',
    });
    if (status) |known| {
        try out.writeAll(":app=rui");
        if (known == .blocked) try out.writeAll(":kind=permission");
        var text: [max_name_bytes * 3]u8 = undefined;
        const line = printable(&text, session_line.cut(max_name_bytes, name).slice());
        if (line.len != 0) {
            try out.writeAll(":msg=");
            try std.base64.standard.Encoder.encodeWriter(out, line);
        }
    }
    try out.writeAll("\x1b\\");
}

pub const clear_statuses = "\x1b]7501;state=clear:id=" ++ status_root ++ "\x1b\\";

fn printable(buffer: []u8, bytes: []const u8) []const u8 {
    var len: usize = 0;
    var at: usize = 0;
    while (at < bytes.len) {
        var scalar: []const u8 = "\u{fffd}";
        var step: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(bytes[at])) |needed| {
            if (at + needed <= bytes.len) if (std.unicode.utf8Decode(bytes[at..][0..needed])) |code| {
                step = needed;
                scalar = if (code < 0x20 or (code >= 0x7f and code <= 0x9f)) "" else bytes[at..][0..needed];
            } else |_| {};
        } else |_| {}
        at += step;
        @memcpy(buffer[len..][0..scalar.len], scalar);
        len += scalar.len;
    }
    return buffer[0..len];
}

const Work = session_work.Work;

fn fixture(work: Work) Work {
    var result = work;
    result.served_attention = session_work.attention(work);
    result.served_group = session_work.group(work);
    return result;
}

fn news(before: ?Work, next: Work) ?Kind {
    var seen: ?Attention = null;
    if (before) |read| _ = observe(&seen, fixture(read));
    return observe(&seen, fixture(next));
}

test "each finish, failure and approval is news once, and stopping or working is none" {
    const finished: Work = .{ .state = .{ .finished = .{ .since = 10 } }, .turn = 1 };
    try std.testing.expectEqual(Kind.finished, news(.{ .state = .{ .working = .{ .since = 5 } } }, finished).?);
    try std.testing.expectEqual(Kind.finished, news(null, finished).?);
    try std.testing.expectEqual(@as(?Kind, null), news(finished, finished));
    try std.testing.expectEqual(Kind.finished, news(finished, .{ .state = .{ .finished = .{ .since = 11 } }, .turn = 2 }).?);
    try std.testing.expectEqual(Kind.finished, news(finished, .{ .state = .{ .finished = .{ .since = 10 } }, .turn = 2 }).?);
    try std.testing.expectEqual(Kind.failed, news(.{ .state = .{ .failed = .{ .since = 10, .code = .{}, .resets_at = null } }, .turn = 1 }, .{ .state = .{ .failed = .{ .since = 10, .code = .{}, .resets_at = null } }, .turn = 2 }).?);
    try std.testing.expectEqual(Kind.approval, news(.{ .state = .{ .bash = .{ .since = 3, .call = 0, .description = null, .running = 1, .approvals = 0 } } }, .{ .state = .{ .approval = .{ .since = 4 } }, .first_action = 7 }).?);
    try std.testing.expectEqual(Kind.failed, news(finished, .{ .state = .{ .failed = .{ .since = 10, .code = .{}, .resets_at = null } }, .turn = 2 }).?);
    try std.testing.expectEqual(@as(?Kind, null), news(finished, .{ .state = .{ .stopped = .{ .since = 12, .cause = .stop } } }));
    try std.testing.expectEqual(@as(?Kind, null), news(.{ .state = .{ .approval = .{ .since = 3 } }, .first_action = 7 }, .{ .state = .{ .working = .{ .since = 4 } } }));
    const beside: Work = .{ .state = .{ .bash = .{ .since = 5, .call = 0, .description = null, .running = 1, .approvals = 1 } }, .first_action = 7 };
    try std.testing.expectEqual(Kind.approval, news(.{ .state = .{ .bash = .{ .since = 5, .call = 0, .description = null, .running = 1, .approvals = 0 } } }, beside).?);
    try std.testing.expectEqual(@as(?Kind, null), news(beside, .{ .state = .{ .approval = .{ .since = 6 } }, .first_action = 7 }));
    try std.testing.expectEqual(@as(?Kind, null), news(.{ .state = .{ .approval = .{ .since = 6 } }, .first_action = 7 }, beside));
    try std.testing.expectEqual(Kind.approval, news(.{ .state = .{ .approval = .{ .since = 6 } }, .first_action = 7 }, .{ .state = .{ .approval = .{ .since = 6 } }, .first_action = 8 }).?);
    try std.testing.expectEqual(Kind.approval, news(beside, .{ .state = .{ .approval = .{ .since = 9 } }, .first_action = 8 }).?);
    var seen: ?Attention = null;
    try std.testing.expectEqual(Kind.finished, observe(&seen, fixture(finished)).?);
    try std.testing.expectEqual(@as(?Kind, null), observe(&seen, fixture(.{ .state = .{ .working = .{ .since = 5 } }, .turn = 1 })));
    try std.testing.expectEqual(@as(?Kind, null), observe(&seen, fixture(finished)));
}

test "a delayed read of an earlier wait neither notifies nor makes the finish after it news again" {
    const waiting: Work = .{ .state = .{ .approval = .{ .since = 4 } }, .turn = 3, .first_action = 7 };
    const finished: Work = .{ .state = .{ .finished = .{ .since = 9 } }, .turn = 3 };
    var seen: ?Attention = null;
    try std.testing.expectEqual(Kind.approval, observe(&seen, fixture(waiting)).?);
    try std.testing.expectEqual(Kind.finished, observe(&seen, fixture(finished)).?);
    try std.testing.expectEqual(@as(?Kind, null), observe(&seen, fixture(waiting)));
    try std.testing.expectEqual(@as(?Kind, null), observe(&seen, fixture(finished)));
    try std.testing.expectEqual(@as(?Kind, null), observe(&seen, fixture(.{ .state = .{ .failed = .{ .since = 2, .code = .{}, .resets_at = null } }, .turn = 2 })));
    try std.testing.expectEqual(Kind.approval, observe(&seen, fixture(.{ .state = .{ .approval = .{ .since = 10 } }, .turn = 4, .first_action = 9 })).?);
}

test "of every work state, only a finish, a failure and an Action awaiting approval want the person" {
    for (std.enums.values(session_work.Kind)) |tag| {
        const state: session_work.WorkState = switch (tag) {
            .idle => .{ .idle = .{ .since = 1 } },
            .pending => .{ .pending = .{ .since = 1 } },
            .working => .{ .working = .{ .since = 1 } },
            .retrying => .{ .retrying = .{ .since = 1, .due_at_ms = 2, .cause = .{}, .attempt = 1 } },
            .bash => .{ .bash = .{ .since = 1, .call = 0, .description = null, .running = 1, .approvals = 1 } },
            .approval => .{ .approval = .{ .since = 1 } },
            .stopping => .{ .stopping = .{ .since = 1 } },
            .finished => .{ .finished = .{ .since = 1 } },
            .failed => .{ .failed = .{ .since = 1, .code = .{}, .resets_at = null } },
            .stopped => .{ .stopped = .{ .since = 1, .cause = .stop } },
        };
        const expected: ?Kind = switch (tag) {
            .approval, .bash => .approval,
            .failed => .failed,
            .finished => .finished,
            else => null,
        };
        const seen: Work = .{ .state = state, .turn = 1, .first_action = if (expected == .approval) 1 else null };
        try std.testing.expectEqual(expected, news(null, seen));
        try std.testing.expectEqual(@as(?Kind, null), news(seen, seen));
    }
    try std.testing.expectEqual(@as(?Kind, null), news(null, .{ .state = .{ .bash = .{ .since = 1, .call = 0, .description = null, .running = 1, .approvals = 0 } } }));
}

test "a Session's program status follows its work, and a record begins only with news" {
    const working: Reading = .of(fixture(.{ .state = .{ .working = .{ .since = 1 } }, .turn = 1 }), null);
    const finished: Reading = .of(fixture(.{ .state = .{ .finished = .{ .since = 2 } }, .turn = 1 }), null);
    const failed: Reading = .of(fixture(.{ .state = .{ .failed = .{ .since = 2, .code = .{}, .resets_at = null } }, .turn = 1 }), null);
    const waiting: Reading = .of(fixture(.{ .state = .{ .approval = .{ .since = 2 } }, .turn = 1, .first_action = 4 }), null);
    const beside: Reading = .of(fixture(.{ .state = .{ .bash = .{ .since = 2, .call = 0, .description = null, .running = 1, .approvals = 1 } }, .turn = 1, .first_action = 4 }), null);
    const stopped: Reading = .of(fixture(.{ .state = .{ .stopped = .{ .since = 3, .cause = .stop } }, .turn = 1 }), null);
    const idle: Reading = .of(fixture(.{ .state = .{ .idle = .{ .since = 1 } } }), null);
    const next_turn: Reading = .of(fixture(.{ .state = .{ .finished = .{ .since = 2 } }, .turn = 2 }), null);
    const next_wait: Reading = .of(fixture(.{ .state = .{ .approval = .{ .since = 2 } }, .turn = 1, .first_action = 5 }), null);
    try std.testing.expectEqual(Status.working, Status.next(null, null, working, true).?);
    try std.testing.expectEqual(Status.blocked, Status.next(null, null, waiting, true).?);
    try std.testing.expectEqual(Status.blocked, Status.next(null, null, beside, true).?);
    for ([_]Reading{ finished, failed, stopped, idle }) |reading| try std.testing.expectEqual(@as(?Status, null), Status.next(null, null, reading, true));
    try std.testing.expectEqual(@as(?Status, null), Status.next(null, finished, finished, false));
    try std.testing.expectEqual(Status.done, Status.next(null, null, finished, false).?);
    try std.testing.expectEqual(Status.failed, Status.next(null, null, failed, false).?);
    try std.testing.expectEqual(@as(?Status, null), Status.next(null, null, idle, false));
    try std.testing.expectEqual(Status.done, Status.next(.working, working, finished, false).?);
    try std.testing.expectEqual(Status.idle, Status.next(.working, working, stopped, false).?);
    try std.testing.expectEqual(Status.working, Status.next(null, finished, working, false).?);
    try std.testing.expectEqual(@as(?Status, null), Status.next(null, finished, idle, false));
    try std.testing.expectEqual(Status.idle, Status.next(.idle, finished, finished, false).?);
    try std.testing.expectEqual(Status.done, Status.next(.idle, finished, next_turn, false).?);
    try std.testing.expectEqual(Status.done, Status.next(null, finished, next_turn, false).?);
    try std.testing.expectEqual(Status.blocked, Status.next(.blocked, waiting, next_wait, false).?);
    const opened_on: Attention = .{ .kind = .finished, .turn = 1, .step = std.math.maxInt(u64) };
    const seen_finish: Reading = .of(fixture(.{ .state = .{ .finished = .{ .since = 2 } }, .turn = 1 }), opened_on);
    try std.testing.expectEqual(Status.idle, Status.next(.working, working, seen_finish, false).?);
    try std.testing.expectEqual(Status.idle, Status.next(.idle, seen_finish, seen_finish, false).?);
    try std.testing.expectEqual(Status.done, Status.next(.idle, seen_finish, .of(fixture(.{ .state = .{ .finished = .{ .since = 2 } }, .turn = 2 }), opened_on), false).?);
    try std.testing.expectEqual(Status.failed, Status.next(.idle, seen_finish, .of(fixture(.{ .state = .{ .failed = .{ .since = 2, .code = .{}, .resets_at = null } }, .turn = 2 }), opened_on), false).?);
    try std.testing.expectEqual(Status.idle, Status.opened(.done).?);
    try std.testing.expectEqual(Status.idle, Status.opened(.failed).?);
    try std.testing.expectEqual(Status.blocked, Status.opened(.blocked).?);
    try std.testing.expectEqual(@as(?Status, null), Status.opened(null));
}

test "a program status report is one sequence the terminal accepts, whatever the name" {
    var buffer: [max_status_bytes]u8 = undefined;
    const cases = .{
        .{ "k7m2qx", "Fix the build", Status.done, "\x1b]7501;state=done:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBidWlsZA==\x1b\\" },
        .{ "k7m2qx", "k7m2qx", Status.blocked, "\x1b]7501;state=blocked:id=rui/k7m2qx:app=rui:kind=permission:msg=azdtMnF4\x1b\\" },
        .{ "k7m2qx", "", Status.failed, "\x1b]7501;state=error:id=rui/k7m2qx:app=rui\x1b\\" },
        .{ "k7m2qx", "x", null, "\x1b]7501;state=clear:id=rui/k7m2qx\x1b\\" },
        .{ "a/b c", "a\x1b\\b\x07\xffc", Status.working, "\x1b]7501;state=working:id=rui/a_b_c:app=rui:msg=YVxi77+9Yw==\x1b\\" },
    };
    inline for (cases) |case| {
        var out = std.Io.Writer.fixed(&buffer);
        try writeStatus(&out, case[0], case[1], case[2]);
        try std.testing.expectEqualStrings(case[3], out.buffered());
    }
    const name: [256]u8 = @splat(0xff);
    const session: [64]u8 = @splat('k');
    var out = std.Io.Writer.fixed(&buffer);
    try writeStatus(&out, &session, &name, .blocked);
    const written = out.buffered();
    try std.testing.expect(written.len <= 4096);
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b]7501;state=blocked:id=rui/" ++ session[0..32] ++ ":"));
    try std.testing.expect(std.mem.endsWith(u8, written, "\x1b\\"));
    for (written[1 .. written.len - 2]) |byte| try std.testing.expect(byte >= 0x20 and byte < 0x7f);
}
