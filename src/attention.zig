//! What a Session's work asks of its person, and the desktop notification
//! that tells them while the terminal is out of focus. The overview and the
//! conversation decide with `observe`, against one record per Session, and
//! write with `write`, so both notify alike and never twice.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const session_line = @import("session_line.zig");
const session_work = @import("session_work.zig");
const TerminalText = @import("TerminalText.zig");

/// Most urgent first: a listing that brings several names the first.
pub const Kind = enum { approval, failed, finished };

/// A state that wants the person, by what it is about: a finish or failure
/// by its Turn, so a later Turn's is news again even within the same second;
/// a wait by its earliest Action awaiting a decision, so one Action's wait is
/// one wait as its Bash ends and the approval state begins.
pub const Attention = union(Kind) {
    approval: ?u64,
    failed: ?u64,
    finished: ?u64,

    /// An Action waits for a decision in the approval state, and beside
    /// running Bash while `approvals` counts one. A stop is the person's own
    /// doing.
    pub fn of(work: session_work.Work) ?Attention {
        return switch (work.state) {
            .approval => .{ .approval = work.first_action },
            .bash => |bash| if (bash.approvals != 0) .{ .approval = work.first_action } else null,
            .failed => .{ .failed = work.turn },
            .finished => .{ .finished = work.turn },
            else => null,
        };
    }
};

/// Records a read of a Session's work in `seen`, the last state that wanted
/// the person any read showed, and returns the news: each state that wants
/// the person is news once, however many reads, by however many screens,
/// show it. Work under way, a stop, or a stale read between leaves `seen`,
/// so a finish read again after them is not news again.
pub fn observe(seen: *?Attention, work: session_work.Work) ?Kind {
    const now = Attention.of(work) orelse return null;
    if (seen.*) |held| if (std.meta.eql(held, now)) return null;
    seen.* = now;
    return now;
}

/// How a terminal shows a notification. OSC 9 (iTerm2, kitty, WezTerm,
/// Ghostty) and OSC 777 (foot) post a desktop notification; elsewhere a
/// bell, which most terminals and multiplexers turn into an urgency hint.
pub const Signal = enum { osc9, osc777, bell };

/// The signal for the terminal the environment names. tmux and screen drop
/// an OSC they do not know unless passthrough is configured, but pass a bell
/// on, so inside one Rui rings.
pub fn signal(term: []const u8, program: []const u8, multiplexed: bool) Signal {
    if (multiplexed or std.mem.startsWith(u8, term, "tmux") or std.mem.startsWith(u8, term, "screen")) return .bell;
    for ([_][]const u8{ "iTerm.app", "WezTerm", "ghostty" }) |name| if (std.mem.eql(u8, program, name)) return .osc9;
    for ([_][]const u8{ "xterm-kitty", "xterm-ghostty", "wezterm" }) |name| if (std.mem.eql(u8, term, name)) return .osc9;
    if (std.mem.startsWith(u8, term, "foot")) return .osc777;
    return .bell;
}

/// Longest name a notification carries, before escaping.
pub const max_name_bytes = 80;
/// Bytes `write` may need: an escaped name and the fixed words around it.
pub const max_bytes = max_name_bytes * TerminalText.max_bytes_per_byte + 96;

/// News waiting to be written: the most urgent Session's name and news, and
/// how many other Sessions brought news with it.
pub const Notice = struct {
    name: Bounded(max_name_bytes),
    kind: Kind,
    more: usize,

    pub fn of(name: []const u8, kind: Kind, more: usize) Notice {
        return .{ .name = session_line.cut(max_name_bytes, name), .kind = kind, .more = more };
    }

    /// Counts `other`'s news with this one's. The more urgent is named, the
    /// earlier among equals.
    pub fn join(self: *Notice, other: Notice) void {
        self.more +|= other.more +| 1;
        if (@backingInt(other.kind) < @backingInt(self.kind)) {
            self.name = other.name;
            self.kind = other.kind;
        }
    }
};

/// Writes one complete notification: `name`'s news, and how many other
/// Sessions brought news with it. The name's bytes pass through
/// TerminalText, so none ends the sequence early or controls the terminal.
pub fn write(out: *std.Io.Writer, how: Signal, name: []const u8, kind: Kind, more: usize) !void {
    switch (how) {
        .bell => return out.writeByte(0x07),
        .osc9 => try out.writeAll("\x1b]9;Rui: "),
        .osc777 => try out.writeAll("\x1b]777;notify;Rui;"),
    }
    var text: TerminalText = .{ .mode = .line };
    try text.feed(out, session_line.cut(max_name_bytes, name).slice());
    try text.finish(out);
    try out.writeAll(switch (kind) {
        .approval => " needs approval",
        .failed => " failed",
        .finished => " finished",
    });
    if (more != 0) try out.print(", and {d} more", .{more});
    try out.writeByte(0x07);
}

const Work = session_work.Work;

/// The news of `after` once a screen read `before`, null when no read had
/// shown the Session.
fn news(before: ?Work, after: Work) ?Kind {
    var seen: ?Attention = null;
    if (before) |read| _ = observe(&seen, read);
    return observe(&seen, after);
}

test "each finish, failure and approval is news once, and stopping or working is none" {
    const finished: Work = .{ .state = .{ .finished = .{ .since = 10 } }, .turn = 1 };
    try std.testing.expectEqual(Kind.finished, news(.{ .state = .{ .working = .{ .since = 5 } } }, finished).?);
    try std.testing.expectEqual(Kind.finished, news(null, finished).?);
    try std.testing.expectEqual(@as(?Kind, null), news(finished, finished));
    // A later Turn's finish is news again, even in the same second; so is a
    // new approval after Bash ran.
    try std.testing.expectEqual(Kind.finished, news(finished, .{ .state = .{ .finished = .{ .since = 11 } }, .turn = 2 }).?);
    try std.testing.expectEqual(Kind.finished, news(finished, .{ .state = .{ .finished = .{ .since = 10 } }, .turn = 2 }).?);
    try std.testing.expectEqual(Kind.failed, news(.{ .state = .{ .failed = .{ .since = 10, .code = .{}, .resets_at = null } }, .turn = 1 }, .{ .state = .{ .failed = .{ .since = 10, .code = .{}, .resets_at = null } }, .turn = 2 }).?);
    try std.testing.expectEqual(Kind.approval, news(.{ .state = .{ .bash = .{ .since = 3, .call = 0, .description = null, .running = 1, .approvals = 0 } } }, .{ .state = .{ .approval = .{ .since = 4 } }, .first_action = 7 }).?);
    try std.testing.expectEqual(Kind.failed, news(finished, .{ .state = .{ .failed = .{ .since = 10, .code = .{}, .resets_at = null } } }).?);
    try std.testing.expectEqual(@as(?Kind, null), news(finished, .{ .state = .{ .stopped = .{ .since = 12, .cause = .stop } } }));
    try std.testing.expectEqual(@as(?Kind, null), news(.{ .state = .{ .approval = .{ .since = 3 } }, .first_action = 7 }, .{ .state = .{ .working = .{ .since = 4 } } }));
    // An Action beside running Bash waits for approval; when the Bash ends
    // and the approval state begins, that is the same wait.
    const beside: Work = .{ .state = .{ .bash = .{ .since = 5, .call = 0, .description = null, .running = 1, .approvals = 1 } }, .first_action = 7 };
    try std.testing.expectEqual(Kind.approval, news(.{ .state = .{ .bash = .{ .since = 5, .call = 0, .description = null, .running = 1, .approvals = 0 } } }, beside).?);
    try std.testing.expectEqual(@as(?Kind, null), news(beside, .{ .state = .{ .approval = .{ .since = 6 } }, .first_action = 7 }));
    try std.testing.expectEqual(@as(?Kind, null), news(.{ .state = .{ .approval = .{ .since = 6 } }, .first_action = 7 }, beside));
    // Once that Action is decided, the next one waiting is a new wait, even
    // when no read saw the Session between them.
    try std.testing.expectEqual(Kind.approval, news(.{ .state = .{ .approval = .{ .since = 6 } }, .first_action = 7 }, .{ .state = .{ .approval = .{ .since = 6 } }, .first_action = 8 }).?);
    try std.testing.expectEqual(Kind.approval, news(beside, .{ .state = .{ .approval = .{ .since = 9 } }, .first_action = 8 }).?);
    // A stale read between two reads of one finish, as a slower screen's,
    // leaves it seen.
    var seen: ?Attention = null;
    try std.testing.expectEqual(Kind.finished, observe(&seen, finished).?);
    try std.testing.expectEqual(@as(?Kind, null), observe(&seen, .{ .state = .{ .working = .{ .since = 5 } }, .turn = 1 }));
    try std.testing.expectEqual(@as(?Kind, null), observe(&seen, finished));
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

test "the signal follows what the terminal supports, and a multiplexer gets a bell" {
    try std.testing.expectEqual(Signal.osc9, signal("xterm-256color", "iTerm.app", false));
    try std.testing.expectEqual(Signal.osc9, signal("xterm-256color", "WezTerm", false));
    try std.testing.expectEqual(Signal.osc9, signal("xterm-ghostty", "", false));
    try std.testing.expectEqual(Signal.osc9, signal("xterm-kitty", "", false));
    try std.testing.expectEqual(Signal.osc777, signal("foot-extra", "", false));
    try std.testing.expectEqual(Signal.bell, signal("xterm-kitty", "iTerm.app", true));
    try std.testing.expectEqual(Signal.bell, signal("tmux-256color", "", false));
    try std.testing.expectEqual(Signal.bell, signal("screen-256color", "iTerm.app", false));
    try std.testing.expectEqual(Signal.bell, signal("xterm-256color", "Apple_Terminal", false));
    try std.testing.expectEqual(Signal.bell, signal("", "", false));
}

test "a notification is one sequence a hostile name cannot end or extend" {
    var buffer: [max_bytes]u8 = undefined;
    const cases = .{
        .{ Signal.osc9, "Fix the build", Kind.finished, 0, "\x1b]9;Rui: Fix the build finished\x07" },
        .{ Signal.osc777, "k7m2qx", Kind.approval, 2, "\x1b]777;notify;Rui;k7m2qx needs approval, and 2 more\x07" },
        .{ Signal.osc9, "a\x07b\x1b\\c\u{9c}d", Kind.failed, 0, "\x1b]9;Rui: a\\x07b\\x1b\\\\c\\u009cd failed\x07" },
        .{ Signal.osc9, "two\nlines\t\"x\"", Kind.finished, 0, "\x1b]9;Rui: two\\nlines\\t\\\"x\\\" finished\x07" },
        .{ Signal.bell, "anything", Kind.finished, 3, "\x07" },
    };
    inline for (cases) |case| {
        var out = std.Io.Writer.fixed(&buffer);
        try write(&out, case[0], case[1], case[2], case[3]);
        try std.testing.expectEqualStrings(case[4], out.buffered());
    }
    // The longest name, every byte escaped, still fits and ends the sequence.
    const name: [256]u8 = @splat(0x1b);
    var out = std.Io.Writer.fixed(&buffer);
    try write(&out, .osc777, &name, .approval, std.math.maxInt(usize));
    const written = out.buffered();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "\x07"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "\x1b"));
}
