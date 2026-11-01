//! What a Session's work is doing now, in the words both screens use: the
//! conversation's last line ("• Waiting · 12s"), the clock on a running
//! call's own row (" · 42s"), and the word on the Session's overview row
//! ("Run the tests", beside the row's own age). Only work under way has a
//! line; an ended or idle Session has none. This core takes the work its
//! shell read and the shell's clock; it holds neither.
const std = @import("std");
const session_work = @import("session_work.zig");
const session_line = @import("session_line.zig");
const failure_class = @import("failure_class.zig");

pub const WorkState = session_work.WorkState;
pub const Method = session_line.Method;

/// How a line's words read. Its clock is always quiet.
pub const Tone = enum { normal, quiet, attention };

/// The two glyph sets a screen draws with.
pub const Script = enum { unicode, ascii };
pub const Glyphs = struct { dot: []const u8, ellipsis: []const u8 };
pub const glyphs = std.enums.EnumArray(Script, Glyphs).init(.{
    .unicode = .{ .dot = "·", .ellipsis = session_line.ellipsis },
    .ascii = .{ .dot = "-", .ellipsis = "." },
});

/// A Tool Call: its model Operation and its ordinal among that Operation's
/// calls, as call activity names it.
pub const Call = struct { operation: u64, ordinal: u64 };

pub const Line = struct {
    /// The conversation's glyph before the words; empty for none.
    mark: []const u8,
    tone: Tone,
    /// Borrows the state's description, when it names one.
    words: []const u8,
    clock: Clock,
    /// The running Bash call the line is about, when the caller named the
    /// Work's Operation.
    call: ?Call = null,
};

pub const Clock = union(enum) {
    /// Under way with no time to show: the words end in an ellipsis.
    ellipsis,
    /// Seconds in this state.
    elapsed: u64,
    /// The failed Attempt's ordinal, and whole seconds until the retry is
    /// due, rounded up.
    retry: struct { attempt: u64, seconds: u64 },
};

const Look = struct { mark: []const u8, tone: Tone = .normal, words: []const u8, clock: std.meta.Tag(Clock) };

/// The one wording table. `bash` says its call's description in place of
/// `words` when it has one, and `retrying` says a rate limit by its cause.
const looks = std.enums.EnumArray(session_work.Kind, ?Look).init(.{
    .idle = null,
    .pending = .{ .mark = "•", .words = "Starting", .clock = .elapsed },
    .working = .{ .mark = "•", .words = "Waiting", .clock = .elapsed },
    .retrying = .{ .mark = "!", .tone = .attention, .words = "Provider error", .clock = .retry },
    .bash = .{ .mark = "•", .words = "Running a command", .clock = .elapsed },
    .approval = .{ .mark = "?", .tone = .attention, .words = "Needs approval", .clock = .elapsed },
    .stopping = .{ .mark = "", .tone = .quiet, .words = "Stopping", .clock = .ellipsis },
    .finished = null,
    .failed = null,
    .stopped = null,
});
const rate_limited = "Rate limited";

/// The line of work being stopped: the Host's `stopping` state, and a stop
/// the person asked for before the Host reports it.
pub const stopping: Line = line: {
    const look = looks.get(.stopping).?;
    break :line .{ .mark = look.mark, .tone = look.tone, .words = look.words, .clock = .ellipsis };
};

/// The line for `state` at `now_ms`, or null when no work is under way.
/// `operation` is the Work's Operation, which names a running Bash call;
/// pass null when the screen places no calls. A retry that has fallen due
/// reads as the work it became (`asOf`).
pub fn of(state: *const WorkState, operation: ?u64, now_ms: u64) ?Line {
    if (state.* == .retrying and state.retrying.due_at_ms <= now_ms) return of(&state.asOf(now_ms), null, now_ms);
    if (state.* == .stopping) return stopping;
    const look = looks.get(state.*) orelse return null;
    return .{
        .mark = look.mark,
        .tone = look.tone,
        .words = switch (state.*) {
            .bash => |*bash| if (bash.description) |*text| text.slice() else look.words,
            .retrying => |*retry| if (failure_class.rateLimited(retry.cause.slice())) rate_limited else look.words,
            else => look.words,
        },
        .clock = switch (state.*) {
            .retrying => |retry| .{ .retry = .{ .attempt = retry.attempt, .seconds = std.math.divCeil(u64, retry.due_at_ms - now_ms, ms_per_s) catch unreachable } },
            else => .{ .elapsed = now_ms / ms_per_s -| state.since() },
        },
        .call = if (state.* == .bash) if (operation) |id| .{ .operation = id, .ordinal = state.bash.call } else null else null,
    };
}

const ms_per_s = 1000;
const s_per_min = 60;
const s_per_hour = 60 * s_per_min;

const max_dot_bytes = max: {
    var bytes = 0;
    for (glyphs.values) |set| bytes = @max(bytes, set.dot.len);
    break :max bytes;
};
/// Hours a running span shows at most; a longer one shows this many hours
/// and 59 minutes.
const max_span_hours = 99_999;
const max_span_seconds = max_span_hours * s_per_hour + s_per_hour - 1;
const max_span_bytes = std.fmt.count("{d}h {d}m", .{ max_span_hours, 59 });
/// The furthest a retry can be due: the whole range of Unix milliseconds.
const max_retry_seconds = std.math.divCeil(u64, std.math.maxInt(u64), ms_per_s) catch unreachable;
/// Bytes the longest clock text takes: an elapsed span's, or a retry's with
/// both numbers at their widest.
pub const max_clock_bytes = " ".len + max_dot_bytes + @max(" ".len + max_span_bytes, std.fmt.count(" retry {d} in {d}s", .{ session_work.max_retried_attempt, max_retry_seconds }));

/// Which screen the words are for. The conversation adds the elapsed time;
/// an overview row has its own age column, so it adds only a retry's
/// countdown.
pub const Form = enum { conversation, row };

/// The text after the words: " · 42s", " · retry 2 in 18s", "…", or
/// nothing.
pub fn clockText(buffer: *[max_clock_bytes]u8, clock: Clock, form: Form, script: Script) []const u8 {
    const set = glyphs.get(script);
    return switch (clock) {
        .ellipsis => set.ellipsis,
        .elapsed => |seconds| if (form == .row) "" else elapsed: {
            var span: [max_span_bytes]u8 = undefined;
            break :elapsed std.fmt.bufPrint(buffer, " {s} {s}", .{ set.dot, spanText(&span, seconds) }) catch unreachable;
        },
        .retry => |retry| std.fmt.bufPrint(buffer, " {s} retry {d} in {d}s", .{ set.dot, retry.attempt, retry.seconds }) catch unreachable,
    };
}

/// A running span: "42s", "1m 12s", "1h 5m".
fn spanText(buffer: *[max_span_bytes]u8, total: u64) []const u8 {
    const seconds = @min(total, max_span_seconds);
    if (seconds < s_per_min) return std.fmt.bufPrint(buffer, "{d}s", .{seconds}) catch unreachable;
    if (seconds < s_per_hour) return std.fmt.bufPrint(buffer, "{d}m {d}s", .{ seconds / s_per_min, seconds % s_per_min }) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d}h {d}m", .{ seconds / s_per_hour, seconds % s_per_hour / s_per_min }) catch unreachable;
}

/// The conversation's line within `width` cells, in the pieces its shell
/// styles apart. Words too long for the line are cut and end in an
/// ellipsis, keeping the clock; a line too narrow for the clock drops it.
pub const Fitted = struct {
    mark: []const u8,
    words: []const u8,
    /// An ellipsis follows the cut words.
    cut: bool,
    clock: []const u8,
};

/// The cells of words the clock leaves at least, or it is dropped.
const min_words_cells = 4;

pub fn fit(buffer: *[max_clock_bytes]u8, line: Line, width: usize, method: Method) Fitted {
    const mark_cells = session_line.cells(line.mark, method);
    const mark: []const u8 = if (line.mark.len != 0 and mark_cells < width) line.mark else "";
    const lead = if (mark.len == 0) 0 else mark_cells + 1;
    const words_cells = session_line.cells(line.words, method);
    const clock = clockText(buffer, line.clock, .conversation, .unicode);
    const clock_cells = session_line.cells(clock, method);
    if (lead + words_cells + clock_cells <= width) return .{ .mark = mark, .words = line.words, .cut = false, .clock = clock };
    const ellipsis_cells = session_line.cells(session_line.ellipsis, method);
    const kept_clock = if (lead + min_words_cells + ellipsis_cells + clock_cells <= width) clock else "";
    const room = width -| lead -| session_line.cells(kept_clock, method);
    if (words_cells <= room) return .{ .mark = mark, .words = line.words, .cut = false, .clock = kept_clock };
    const kept = session_line.fit(line.words, room -| ellipsis_cells, method);
    return .{ .mark = mark, .words = line.words[0..kept.len], .cut = room >= ellipsis_cells, .clock = kept_clock };
}

const test_now_ms = 1_792_937_000_000;
const test_now_s = 1_792_937_000;

fn bounded(comptime capacity: usize, text: []const u8) @import("bounded.zig").Bounded(capacity) {
    var value: @import("bounded.zig").Bounded(capacity) = .{};
    value.set(text) catch unreachable;
    return value;
}

fn conversation(state: WorkState, now_ms: u64) ![]const u8 {
    const S = struct {
        var bytes: [256]u8 = undefined;
    };
    const line = of(&state, null, now_ms) orelse return "";
    var buffer: [max_clock_bytes]u8 = undefined;
    var out = std.Io.Writer.fixed(&S.bytes);
    if (line.mark.len != 0) try out.print("{s} ", .{line.mark});
    try out.print("{s}{s}", .{ line.words, clockText(&buffer, line.clock, .conversation, .unicode) });
    return out.buffered();
}

fn row(state: WorkState, now_ms: u64, script: Script) ![]const u8 {
    const S = struct {
        var bytes: [256]u8 = undefined;
    };
    const line = of(&state, null, now_ms) orelse return "";
    var buffer: [max_clock_bytes]u8 = undefined;
    return std.fmt.bufPrint(&S.bytes, "{s}{s}", .{ line.words, clockText(&buffer, line.clock, .row, script) });
}

test "every work state has the approved words on both screens, and ended work has none" {
    const retry: WorkState = .{ .retrying = .{ .since = test_now_s - 4, .due_at_ms = test_now_ms + 17_200, .cause = bounded(session_work.max_code_bytes, "provider_temporary_http_429"), .attempt = 2 } };
    const cases = [_]struct { state: WorkState, conversation: []const u8, row: []const u8, ascii: []const u8, tone: Tone = .normal }{
        .{ .state = .{ .idle = .{ .since = 1 } }, .conversation = "", .row = "", .ascii = "" },
        .{ .state = .{ .pending = .{ .since = test_now_s - 3 } }, .conversation = "• Starting · 3s", .row = "Starting", .ascii = "Starting" },
        .{ .state = .{ .working = .{ .since = test_now_s - 12 } }, .conversation = "• Waiting · 12s", .row = "Waiting", .ascii = "Waiting" },
        .{ .state = retry, .conversation = "! Rate limited · retry 2 in 18s", .row = "Rate limited · retry 2 in 18s", .ascii = "Rate limited - retry 2 in 18s", .tone = .attention },
        .{ .state = .{ .retrying = .{ .since = test_now_s, .due_at_ms = test_now_ms + 1, .cause = bounded(session_work.max_code_bytes, "provider_temporary_http_503"), .attempt = 1 } }, .conversation = "! Provider error · retry 1 in 1s", .row = "Provider error · retry 1 in 1s", .ascii = "Provider error - retry 1 in 1s", .tone = .attention },
        .{ .state = .{ .bash = .{ .since = test_now_s - 42, .call = 1, .description = bounded(session_work.max_description_bytes, "Run zig build test-store"), .running = 1, .approvals = 0 } }, .conversation = "• Run zig build test-store · 42s", .row = "Run zig build test-store", .ascii = "Run zig build test-store" },
        .{ .state = .{ .bash = .{ .since = test_now_s - 72, .call = 0, .description = null, .running = 2, .approvals = 1 } }, .conversation = "• Running a command · 1m 12s", .row = "Running a command", .ascii = "Running a command" },
        .{ .state = .{ .approval = .{ .since = test_now_s - 3 * 3600 - 5 * 60 } }, .conversation = "? Needs approval · 3h 5m", .row = "Needs approval", .ascii = "Needs approval", .tone = .attention },
        .{ .state = .{ .stopping = .{ .since = test_now_s - 9 } }, .conversation = "Stopping…", .row = "Stopping…", .ascii = "Stopping.", .tone = .quiet },
        .{ .state = .{ .finished = .{ .since = 1 } }, .conversation = "", .row = "", .ascii = "" },
        .{ .state = .{ .failed = .{ .since = 1, .code = .{}, .resets_at = null } }, .conversation = "", .row = "", .ascii = "" },
        .{ .state = .{ .stopped = .{ .since = 1, .cause = .stop } }, .conversation = "", .row = "", .ascii = "" },
    };
    var seen: std.enums.EnumSet(session_work.Kind) = .empty;
    for (cases) |case| {
        seen.insert(case.state);
        try std.testing.expectEqualStrings(case.conversation, try conversation(case.state, test_now_ms));
        try std.testing.expectEqualStrings(case.row, try row(case.state, test_now_ms, .unicode));
        try std.testing.expectEqualStrings(case.ascii, try row(case.state, test_now_ms, .ascii));
        // A line exactly while work is under way.
        try std.testing.expectEqual(case.state.progress() != null, of(&case.state, null, test_now_ms) != null);
        if (of(&case.state, null, test_now_ms)) |line| try std.testing.expectEqual(case.tone, line.tone);
    }
    try std.testing.expect(seen.eql(.full));
    // A stop the person asked for reads as the Host's stopping state does.
    const host_stopping = of(&.{ .stopping = .{ .since = 1 } }, 7, test_now_ms).?;
    try std.testing.expectEqualStrings(stopping.words, host_stopping.words);
    try std.testing.expectEqual(stopping.tone, host_stopping.tone);
    try std.testing.expectEqual(Clock.ellipsis, host_stopping.clock);
    // A due retry says what it became: eligible work starting again.
    try std.testing.expectEqualStrings("• Starting · 0s", try conversation(retry, retry.retrying.due_at_ms));
    // Its time is from the due second: due 17.2 s ahead, read 23.199 s ahead.
    try std.testing.expectEqualStrings("• Starting · 6s", try conversation(retry, retry.retrying.due_at_ms + 5_999));
    // A clock behind the state's own second shows none elapsed.
    try std.testing.expectEqualStrings("• Waiting · 0s", try conversation(.{ .working = .{ .since = test_now_s + 3 } }, test_now_ms));
}

test "a running Bash line names its call only beside the Work's Operation" {
    const bash: WorkState = .{ .bash = .{ .since = test_now_s, .call = 3, .description = null, .running = 2, .approvals = 0 } };
    try std.testing.expectEqual(@as(?Call, .{ .operation = 19, .ordinal = 3 }), of(&bash, 19, test_now_ms).?.call);
    try std.testing.expectEqual(@as(?Call, null), of(&bash, null, test_now_ms).?.call);
    try std.testing.expectEqual(@as(?Call, null), of(&.{ .working = .{ .since = test_now_s } }, 19, test_now_ms).?.call);
}

test "a retry counts down whole seconds to its due time and never shows zero before it" {
    for ([_]struct { u64, u64 }{ .{ 1, 1 }, .{ 999, 1 }, .{ 1_000, 1 }, .{ 1_001, 2 }, .{ 17_200, 18 }, .{ 18_000, 18 } }) |case| {
        const state: WorkState = .{ .retrying = .{ .since = test_now_s - 1, .due_at_ms = test_now_ms + case[0], .cause = .{}, .attempt = 1 } };
        try std.testing.expectEqual(case[1], of(&state, null, test_now_ms).?.clock.retry.seconds);
    }
}

test "a running span is seconds, then minutes and seconds, then hours and minutes up to its cap" {
    var buffer: [max_span_bytes]u8 = undefined;
    for ([_]struct { u64, []const u8 }{ .{ 0, "0s" }, .{ 59, "59s" }, .{ 60, "1m 0s" }, .{ 3599, "59m 59s" }, .{ 3600, "1h 0m" }, .{ 86_400 * 3 + 61, "72h 1m" }, .{ 99_999 * 3600 + 59 * 60, "99999h 59m" }, .{ 100_000 * 3600, "99999h 59m" }, .{ std.math.maxInt(u64), "99999h 59m" } }) |case| {
        try std.testing.expectEqualStrings(case[1], spanText(&buffer, case[0]));
    }
    // The widest clocks fill their buffer exactly: Unicode's dot is the
    // wider.
    var clock: [max_clock_bytes]u8 = undefined;
    const widest_retry = clockText(&clock, .{ .retry = .{ .attempt = session_work.max_retried_attempt, .seconds = max_retry_seconds } }, .row, .unicode).len;
    const widest_span = clockText(&clock, .{ .elapsed = std.math.maxInt(u64) }, .conversation, .unicode).len;
    try std.testing.expectEqual(max_clock_bytes, @max(widest_retry, widest_span));
}

test "a fitted line never takes more than its width and keeps the clock while words fit beside it" {
    var long: [100]u8 = undefined;
    for (0..50) |at| @memcpy(long[at * 2 ..][0..2], "é");
    const descriptions = [_][]const u8{ "Run zig build test-store", &long, "a" };
    const clock = " · 42s";
    for (descriptions) |description| for ([_]Method{ .unicode, .wcwidth }) |method| for (0..120) |width| {
        const state: WorkState = .{ .bash = .{ .since = test_now_s - 42, .call = 0, .description = bounded(session_work.max_description_bytes, description), .running = 1, .approvals = 0 } };
        var buffer: [max_clock_bytes]u8 = undefined;
        const fitted = fit(&buffer, of(&state, null, test_now_ms).?, width, method);
        const mark_cells: usize = 2;
        const clock_cells: usize = 6;
        const ellipsis_cells: usize = 1;
        const cells = (if (fitted.mark.len == 0) 0 else mark_cells) + session_line.cells(fitted.words, method) + (if (fitted.cut) ellipsis_cells else 0) + session_line.cells(fitted.clock, method);
        try std.testing.expect(cells <= width);
        try std.testing.expect(std.unicode.utf8ValidateSlice(fitted.words));
        try std.testing.expect(std.mem.startsWith(u8, description, fitted.words));
        // Whole when it fits; cut words end in an ellipsis.
        if (mark_cells + session_line.cells(description, method) + clock_cells <= width) {
            try std.testing.expectEqualStrings(description, fitted.words);
            try std.testing.expectEqualStrings(clock, fitted.clock);
        } else {
            try std.testing.expect(fitted.words.len < description.len or fitted.clock.len == 0);
            if (fitted.words.len < description.len and width >= mark_cells + ellipsis_cells) try std.testing.expect(fitted.cut);
            if (width >= mark_cells + min_words_cells + ellipsis_cells + clock_cells) try std.testing.expectEqualStrings(clock, fitted.clock);
        }
    };
    // A stopping line keeps its ellipsis as its clock.
    var buffer: [max_clock_bytes]u8 = undefined;
    const stopped = fit(&buffer, stopping, 80, .unicode);
    try std.testing.expectEqualStrings("Stopping", stopped.words);
    try std.testing.expectEqualStrings("…", stopped.clock);
}
