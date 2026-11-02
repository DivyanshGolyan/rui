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

/// A state that wants the person, placed in the order its Session reached
/// it: by Turn, then within a Turn each wait by its earliest Action awaiting
/// a decision, and the Turn's finish or failure after every wait. Action ids
/// grow, and the earliest one awaiting moves only forward as decisions
/// land, so one Action's wait is one wait as its Bash ends and the approval
/// state begins, and a later Turn's finish is news again even within the
/// same second.
pub const Attention = struct {
    kind: Kind,
    turn: u64,
    step: u64,

    /// An Action waits for a decision in the approval state, and beside
    /// running Bash while `approvals` counts one. A stop is the person's own
    /// doing.
    pub fn of(work: session_work.Work) ?Attention {
        const turn = work.turn orelse 0;
        const wait: Attention = .{ .kind = .approval, .turn = turn, .step = work.first_action orelse 0 };
        return switch (work.state) {
            .approval => wait,
            .bash => |bash| if (bash.approvals != 0) wait else null,
            .failed => .{ .kind = .failed, .turn = turn, .step = std.math.maxInt(u64) },
            .finished => .{ .kind = .finished, .turn = turn, .step = std.math.maxInt(u64) },
            else => null,
        };
    }

    fn after(self: Attention, other: Attention) bool {
        return self.turn > other.turn or (self.turn == other.turn and self.step > other.step);
    }
};

/// Records a read of a Session's work in `seen`, the latest state that
/// wanted the person any read showed, and returns the news: each state that
/// wants the person is news once, however many reads, by however many
/// screens, show it. Work under way, a stop, or a stale read leaves `seen`:
/// a slower screen's read of an earlier wait, after a newer finish was seen,
/// is neither news nor able to make that finish news again.
pub fn observe(seen: *?Attention, work: session_work.Work) ?Kind {
    const now = Attention.of(work) orelse return null;
    if (seen.*) |held| if (!now.after(held)) return null;
    seen.* = now;
    return now.kind;
}

/// How a terminal shows a notification. OSC 9 (iTerm2, kitty, WezTerm,
/// Ghostty) and OSC 777 (foot) post a desktop notification; elsewhere a
/// bell, which most terminals and multiplexers turn into an urgency hint.
pub const Signal = enum { osc9, osc777, bell };

/// Rui runs inside tmux or screen: `inside` when the environment names one
/// (`TMUX`, `STY`), or when `term` does.
pub fn multiplexed(term: []const u8, inside: bool) bool {
    return inside or std.mem.startsWith(u8, term, "tmux") or std.mem.startsWith(u8, term, "screen");
}

/// The signal for the terminal the environment names. tmux and screen drop
/// an OSC they do not know unless passthrough is configured, but pass a bell
/// on, so inside one Rui rings.
pub fn signal(term: []const u8, program: []const u8, inside: bool) Signal {
    if (multiplexed(term, inside)) return .bell;
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

/// What a Session is doing, as a terminal that takes program status reports
/// (OSC 7501) shows it beside its other programs: one record per Session,
/// which the terminal presents as it chooses, focused or not.
pub const Status = enum {
    idle,
    working,
    /// Finished, with a result the person has not opened since.
    done,
    /// An Action waits for the person's decision.
    blocked,
    failed,

    /// A stop is the person's own doing, so the Session rests.
    pub fn of(work: session_work.Work) Status {
        return switch (work.state) {
            .idle, .stopped => .idle,
            .pending, .working, .retrying, .stopping => .working,
            .bash => |bash| if (bash.approvals != 0) .blocked else .working,
            .approval => .blocked,
            .finished => .done,
            .failed => .failed,
        };
    }

    /// The record a Session has once a listing reads it `now`, from the
    /// record it `held` and what the listing before read (`was`, null when
    /// none listed it). A record follows each change between listings; a
    /// later finish, failure or wait in the same status is one, whichever
    /// screen read it first. The listing the overview opens on changes
    /// nothing: it gives a record only to work under way or waiting. A
    /// Session at rest gets none until it does something.
    pub fn next(held: ?Status, was: ?Reading, now: Reading, opening: bool) ?Status {
        const changed = if (was) |before| before.status != now.status or now.after(before) else !opening;
        if (!changed) return if (was == null and (now.status == .working or now.status == .blocked)) now.status else held;
        if (held == null and now.status == .idle) return null;
        return now.status;
    }

    /// The record once the person opens the Session: an outcome is seen.
    pub fn opened(held: ?Status) ?Status {
        const status = held orelse return null;
        return if (status == .done or status == .failed) .idle else status;
    }
};

/// What one listing read of a Session's work: its status, and the state
/// that wanted the person, which tells a later finish, failure or wait in
/// the same status from the one read before.
pub const Reading = struct {
    status: Status,
    attention: ?Attention,

    /// An outcome at or before `acknowledged`, the latest state a
    /// conversation opened on, reads as rest: the person has seen it.
    pub fn of(work: session_work.Work, acknowledged: ?Attention) Reading {
        const status: Status = .of(work);
        const now: ?Attention = .of(work);
        const seen = if (now) |reached| if (acknowledged) |opened| !reached.after(opened) else false else false;
        return .{ .status = if (seen and (status == .done or status == .failed)) .idle else status, .attention = now };
    }

    fn after(self: Reading, before: Reading) bool {
        const now = self.attention orelse return false;
        const held = before.attention orelse return true;
        return now.after(held);
    }
};

/// Rui's records are this id's children, so clearing it clears Rui's own
/// and no other program's.
const status_root = "rui";
/// Bytes `writeStatus` may need: the fixed keys, the id, and the name with
/// every byte replaced, in base64.
pub const max_status_bytes = 64 + status_root.len + 1 + max_id_segment + std.base64.standard.Encoder.calcSize(max_name_bytes * 3);
const max_id_segment = 32;

/// Writes one complete OSC 7501 report of `session`'s record: `status`, or
/// a clear when null. The id keeps to the protocol's characters, so a
/// terminal never discards it, and the name travels in base64 without the
/// control characters a terminal would discard it for.
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

/// Clears every record Rui set.
pub const clear_statuses = "\x1b]7501;state=clear:id=" ++ status_root ++ "\x1b\\";

/// `bytes` as valid UTF-8 without control characters: an invalid byte
/// becomes U+FFFD, a control character is left out.
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
    try std.testing.expectEqual(Kind.failed, news(finished, .{ .state = .{ .failed = .{ .since = 10, .code = .{}, .resets_at = null } }, .turn = 2 }).?);
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

test "a delayed read of an earlier wait neither notifies nor makes the finish after it news again" {
    const waiting: Work = .{ .state = .{ .approval = .{ .since = 4 } }, .turn = 3, .first_action = 7 };
    const finished: Work = .{ .state = .{ .finished = .{ .since = 9 } }, .turn = 3 };
    var seen: ?Attention = null;
    // The overview's listing reads the wait; the conversation reads the
    // finish; the listing read before the finish applies late; the
    // conversation polls again.
    try std.testing.expectEqual(Kind.approval, observe(&seen, waiting).?);
    try std.testing.expectEqual(Kind.finished, observe(&seen, finished).?);
    try std.testing.expectEqual(@as(?Kind, null), observe(&seen, waiting));
    try std.testing.expectEqual(@as(?Kind, null), observe(&seen, finished));
    // An earlier Turn's outcome read late is old news too; the next Turn's
    // wait is new.
    try std.testing.expectEqual(@as(?Kind, null), observe(&seen, .{ .state = .{ .failed = .{ .since = 2, .code = .{}, .resets_at = null } }, .turn = 2 }));
    try std.testing.expectEqual(Kind.approval, observe(&seen, .{ .state = .{ .approval = .{ .since = 10 } }, .turn = 4, .first_action = 9 }).?);
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

test "a Session's program status follows its work, and a record begins only with news" {
    const working: Reading = .of(.{ .state = .{ .working = .{ .since = 1 } }, .turn = 1 }, null);
    const finished: Reading = .of(.{ .state = .{ .finished = .{ .since = 2 } }, .turn = 1 }, null);
    const failed: Reading = .of(.{ .state = .{ .failed = .{ .since = 2, .code = .{}, .resets_at = null } }, .turn = 1 }, null);
    const waiting: Reading = .of(.{ .state = .{ .approval = .{ .since = 2 } }, .turn = 1, .first_action = 4 }, null);
    const beside: Reading = .of(.{ .state = .{ .bash = .{ .since = 2, .call = 0, .description = null, .running = 1, .approvals = 1 } }, .turn = 1, .first_action = 4 }, null);
    const stopped: Reading = .of(.{ .state = .{ .stopped = .{ .since = 3, .cause = .stop } }, .turn = 1 }, null);
    const idle: Reading = .of(.{ .state = .{ .idle = .{ .since = 1 } } }, null);
    const next_turn: Reading = .of(.{ .state = .{ .finished = .{ .since = 2 } }, .turn = 2 }, null);
    const next_wait: Reading = .of(.{ .state = .{ .approval = .{ .since = 2 } }, .turn = 1, .first_action = 5 }, null);
    // What the overview opens on: work under way or waiting has a record,
    // an outcome or rest has none.
    try std.testing.expectEqual(Status.working, Status.next(null, null, working, true).?);
    try std.testing.expectEqual(Status.blocked, Status.next(null, null, waiting, true).?);
    try std.testing.expectEqual(Status.blocked, Status.next(null, null, beside, true).?);
    for ([_]Reading{ finished, failed, stopped, idle }) |reading| try std.testing.expectEqual(@as(?Status, null), Status.next(null, null, reading, true));
    // An outcome read again by a later listing is still no record.
    try std.testing.expectEqual(@as(?Status, null), Status.next(null, finished, finished, false));
    // A Session first listed later is news, unless it rests.
    try std.testing.expectEqual(Status.done, Status.next(null, null, finished, false).?);
    try std.testing.expectEqual(Status.failed, Status.next(null, null, failed, false).?);
    try std.testing.expectEqual(@as(?Status, null), Status.next(null, null, idle, false));
    // A record follows every change, back to rest after a stop, and a later
    // Turn's finish or a later wait in the same status, even one opened or
    // never recorded.
    try std.testing.expectEqual(Status.done, Status.next(.working, working, finished, false).?);
    try std.testing.expectEqual(Status.idle, Status.next(.working, working, stopped, false).?);
    try std.testing.expectEqual(Status.working, Status.next(null, finished, working, false).?);
    try std.testing.expectEqual(@as(?Status, null), Status.next(null, finished, idle, false));
    try std.testing.expectEqual(Status.idle, Status.next(.idle, finished, finished, false).?);
    try std.testing.expectEqual(Status.done, Status.next(.idle, finished, next_turn, false).?);
    try std.testing.expectEqual(Status.done, Status.next(null, finished, next_turn, false).?);
    try std.testing.expectEqual(Status.blocked, Status.next(.blocked, waiting, next_wait, false).?);
    // An outcome the conversation opened on, before any listing read it,
    // rests; a later Turn's outcome is news again.
    const opened_on: Attention = .{ .kind = .finished, .turn = 1, .step = std.math.maxInt(u64) };
    const seen_finish: Reading = .of(.{ .state = .{ .finished = .{ .since = 2 } }, .turn = 1 }, opened_on);
    try std.testing.expectEqual(Status.idle, Status.next(.working, working, seen_finish, false).?);
    try std.testing.expectEqual(Status.idle, Status.next(.idle, seen_finish, seen_finish, false).?);
    try std.testing.expectEqual(Status.done, Status.next(.idle, seen_finish, .of(.{ .state = .{ .finished = .{ .since = 2 } }, .turn = 2 }, opened_on), false).?);
    try std.testing.expectEqual(Status.failed, Status.next(.idle, seen_finish, .of(.{ .state = .{ .failed = .{ .since = 2, .code = .{}, .resets_at = null } }, .turn = 2 }, opened_on), false).?);
    // Opening the Session sees its outcome; work under way stays.
    try std.testing.expectEqual(Status.idle, Status.opened(.done).?);
    try std.testing.expectEqual(Status.idle, Status.opened(.failed).?);
    try std.testing.expectEqual(Status.blocked, Status.opened(.blocked).?);
    try std.testing.expectEqual(@as(?Status, null), Status.opened(null));
}

test "a program status report is one sequence the terminal accepts, whatever the name" {
    var buffer: [max_status_bytes]u8 = undefined;
    const cases = .{
        // base64("Fix the build") and base64("k7m2qx").
        .{ "k7m2qx", "Fix the build", Status.done, "\x1b]7501;state=done:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBidWlsZA==\x1b\\" },
        .{ "k7m2qx", "k7m2qx", Status.blocked, "\x1b]7501;state=blocked:id=rui/k7m2qx:app=rui:kind=permission:msg=azdtMnF4\x1b\\" },
        .{ "k7m2qx", "", Status.failed, "\x1b]7501;state=error:id=rui/k7m2qx:app=rui\x1b\\" },
        .{ "k7m2qx", "x", null, "\x1b]7501;state=clear:id=rui/k7m2qx\x1b\\" },
        // A control character is left out, an invalid byte replaced, and an
        // id byte outside the protocol's characters becomes `_`.
        .{ "a/b c", "a\x1b\\b\x07\xffc", Status.working, "\x1b]7501;state=working:id=rui/a_b_c:app=rui:msg=YVxi77+9Yw==\x1b\\" },
    };
    inline for (cases) |case| {
        var out = std.Io.Writer.fixed(&buffer);
        try writeStatus(&out, case[0], case[1], case[2]);
        try std.testing.expectEqualStrings(case[3], out.buffered());
    }
    // The longest name, every byte replaced, and the longest id still fit:
    // one sequence of the protocol's characters, under its 4096 bytes.
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
