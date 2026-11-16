const std = @import("std");
const marks = @import("marks.zig");
const session_work = @import("session_work.zig");
const session_line = @import("session_line.zig");
const failure_class = @import("failure_class.zig");
const TerminalText = @import("TerminalText.zig");

pub const WorkState = session_work.WorkState;
pub const Method = session_line.Method;

pub const Tone = enum { normal, quiet, attention };

pub const Script = enum { unicode, ascii };
pub const Glyphs = struct { dot: []const u8, ellipsis: []const u8 };
pub const glyphs = std.enums.EnumArray(Script, Glyphs).init(.{
    .unicode = .{ .dot = "·", .ellipsis = session_line.ellipsis },
    .ascii = .{ .dot = "-", .ellipsis = "." },
});

pub const Call = struct { operation: u64, ordinal: u64 };

pub const Line = struct {
    mark: []const u8,
    tone: Tone,
    words: []const u8,
    clock: Clock,
    call: ?Call = null,
};

pub const Clock = union(enum) {
    ellipsis,
    elapsed: u64,
    retry: struct { attempt: u64, seconds: u64 },
};

const Look = struct { mark: []const u8, tone: Tone = .normal, words: []const u8, clock: std.meta.Tag(Clock) };

const looks = std.enums.EnumArray(session_work.Kind, ?Look).init(.{
    .idle = null,
    .pending = .{ .mark = marks.marks.get(.queued).unicode, .words = "Queued", .clock = .elapsed },
    .working = .{ .mark = marks.marks.get(.active).unicode, .words = "Thinking", .clock = .elapsed },
    .retrying = .{ .mark = marks.marks.get(.active).unicode, .tone = .attention, .words = "Provider error", .clock = .retry },
    .bash = .{ .mark = marks.marks.get(.active).unicode, .words = "Running a command", .clock = .elapsed },
    .approval = .{ .mark = marks.marks.get(.needs_you).unicode, .tone = .attention, .words = "Needs approval", .clock = .elapsed },
    .stopping = .{ .mark = "", .tone = .quiet, .words = "Stopping", .clock = .ellipsis },
    .finished = null,
    .failed = null,
    .stopped = null,
});
const rate_limited = "Rate limited";
pub const max_words_bytes = max: {
    var bytes = @max(TerminalText.max_bytes_per_byte * session_work.max_description_bytes, rate_limited.len);
    for (looks.values) |look| if (look) |shown| {
        bytes = @max(bytes, shown.words.len);
    };
    break :max bytes;
};

pub const stopping: Line = line: {
    const look = looks.get(.stopping).?;
    break :line .{ .mark = look.mark, .tone = look.tone, .words = look.words, .clock = .ellipsis };
};

pub fn of(words: *[max_words_bytes]u8, state: *const WorkState, operation: ?u64, now_ms: u64) ?Line {
    if (state.* == .retrying and state.retrying.due_at_ms <= now_ms) return of(words, &state.asOf(now_ms), null, now_ms);
    if (state.* == .stopping) return stopping;
    const look = looks.get(state.*) orelse return null;
    return .{
        .mark = look.mark,
        .tone = look.tone,
        .words = switch (state.*) {
            .bash => |*bash| if (bash.description) |*text| escaped(words, text.slice()) else look.words,
            .retrying => |*retry| if (failure_class.rateLimited(retry.cause.slice())) rate_limited else look.words,
            else => look.words,
        },
        .clock = switch (state.*) {
            .retrying => |retry| .{ .retry = .{ .attempt = retry.attempt, .seconds = std.math.divCeil(u64, retry.due_at_ms - now_ms, ms_per_s) catch unreachable } },
            else => .{ .elapsed = now_ms / ms_per_s -| state.since() },
        },
        .call = if (state.* == .bash and operation != null and state.bash.call != null) .{ .operation = operation.?, .ordinal = state.bash.call.? } else null,
    };
}

fn escaped(buffer: *[max_words_bytes]u8, text: []const u8) []const u8 {
    std.debug.assert(text.len <= session_work.max_description_bytes);
    var out = std.Io.Writer.fixed(buffer);
    var line: TerminalText = .{ .mode = .label };
    line.feed(&out, text) catch unreachable;
    line.finish(&out) catch unreachable;
    return out.buffered();
}

const ms_per_s = 1000;
const s_per_min = 60;
const s_per_hour = 60 * s_per_min;

pub const max_dot_bytes = max: {
    var bytes = 0;
    for (glyphs.values) |set| bytes = @max(bytes, set.dot.len);
    break :max bytes;
};
const max_span_hours = 99_999;
const max_span_seconds = max_span_hours * s_per_hour + s_per_hour - 1;
const max_span_bytes = std.fmt.count("{d}h {d}m", .{ max_span_hours, 59 });
const max_retry_seconds = std.math.divCeil(u64, std.math.maxInt(u64), ms_per_s) catch unreachable;
pub const max_clock_bytes = " ".len + max_dot_bytes + @max(" ".len + max_span_bytes, std.fmt.count(" retry {d} in {d}s", .{ session_work.max_retried_attempt, max_retry_seconds }));

pub const Form = enum { conversation, row };

pub fn clockText(buffer: *[max_clock_bytes]u8, clock: Clock, form: Form, script: Script) []const u8 {
    const set = glyphs.get(script);
    return switch (clock) {
        .ellipsis => set.ellipsis,
        .elapsed => |seconds| if (form == .row) "" else elapsed: {
            var span: [max_span_bytes]u8 = undefined;
            break :elapsed std.fmt.bufPrint(buffer, " {s} {s}", .{ set.dot, spanText(&span, seconds) }) catch unreachable;
        },
        .retry => |retry| if (form == .row)
            std.fmt.bufPrint(buffer, " {s} retry in {d}s", .{ set.dot, retry.seconds }) catch unreachable
        else
            std.fmt.bufPrint(buffer, " {s} retry {d} in {d}s", .{ set.dot, retry.attempt, retry.seconds }) catch unreachable,
    };
}

fn spanText(buffer: *[max_span_bytes]u8, total: u64) []const u8 {
    const seconds = @min(total, max_span_seconds);
    if (seconds < s_per_min) return std.fmt.bufPrint(buffer, "{d}s", .{seconds}) catch unreachable;
    if (seconds < s_per_hour) return std.fmt.bufPrint(buffer, "{d}m {d}s", .{ seconds / s_per_min, seconds % s_per_min }) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d}h {d}m", .{ seconds / s_per_hour, seconds % s_per_hour / s_per_min }) catch unreachable;
}

pub const Fitted = struct {
    mark: []const u8,
    words: []const u8,
    cut: bool,
    clock: []const u8,
};

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
var test_words: [max_words_bytes]u8 = undefined;
const test_now_s = 1_792_937_000;

fn bounded(comptime capacity: usize, text: []const u8) @import("bounded.zig").Bounded(capacity) {
    return @import("bounded.zig").Bounded(capacity).from(text) catch unreachable;
}

fn conversation(state: WorkState, now_ms: u64) ![]const u8 {
    const S = struct {
        var bytes: [256]u8 = undefined;
    };
    const line = of(&test_words, &state, null, now_ms) orelse return "";
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
    const line = of(&test_words, &state, null, now_ms) orelse return "";
    var buffer: [max_clock_bytes]u8 = undefined;
    return std.fmt.bufPrint(&S.bytes, "{s}{s}", .{ line.words, clockText(&buffer, line.clock, .row, script) });
}

test "every work state has the approved words on both screens, and ended work has none" {
    const retry: WorkState = .{ .retrying = .{ .since = test_now_s - 4, .due_at_ms = test_now_ms + 17_200, .cause = bounded(session_work.max_code_bytes, "provider_temporary_http_429"), .attempt = 2 } };
    const cases = [_]struct { state: WorkState, conversation: []const u8, row: []const u8, ascii: []const u8, tone: Tone = .normal }{
        .{ .state = .{ .idle = .{ .since = 1 } }, .conversation = "", .row = "", .ascii = "" },
        .{ .state = .{ .pending = .{ .since = test_now_s - 3 } }, .conversation = "◌ Queued · 3s", .row = "Queued", .ascii = "Queued" },
        .{ .state = .{ .working = .{ .since = test_now_s - 12 } }, .conversation = "⠹ Thinking · 12s", .row = "Thinking", .ascii = "Thinking" },
        .{ .state = retry, .conversation = "⠹ Rate limited · retry 2 in 18s", .row = "Rate limited · retry in 18s", .ascii = "Rate limited - retry in 18s", .tone = .attention },
        .{ .state = .{ .retrying = .{ .since = test_now_s, .due_at_ms = test_now_ms + 1, .cause = bounded(session_work.max_code_bytes, "provider_temporary_http_503"), .attempt = 1 } }, .conversation = "⠹ Provider error · retry 1 in 1s", .row = "Provider error · retry in 1s", .ascii = "Provider error - retry in 1s", .tone = .attention },
        .{ .state = .{ .bash = .{ .since = test_now_s - 42, .call = 1, .description = bounded(session_work.max_description_bytes, "Run zig build test-store"), .running = 1, .approvals = 0 } }, .conversation = "⠹ Run zig build test-store · 42s", .row = "Run zig build test-store", .ascii = "Run zig build test-store" },
        .{ .state = .{ .bash = .{ .since = test_now_s - 72, .call = 0, .description = null, .running = 2, .approvals = 1 } }, .conversation = "⠹ Running a command · 1m 12s", .row = "Running a command", .ascii = "Running a command" },
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
        try std.testing.expectEqual(case.state.progress() != null, of(&test_words, &case.state, null, test_now_ms) != null);
        if (of(&test_words, &case.state, null, test_now_ms)) |line| try std.testing.expectEqual(case.tone, line.tone);
    }
    try std.testing.expect(seen.eql(.full));
    const host_stopping = of(&test_words, &.{ .stopping = .{ .since = 1 } }, 7, test_now_ms).?;
    try std.testing.expectEqualStrings(stopping.words, host_stopping.words);
    try std.testing.expectEqual(stopping.tone, host_stopping.tone);
    try std.testing.expectEqual(Clock.ellipsis, host_stopping.clock);
    try std.testing.expectEqualStrings("◌ Queued · 0s", try conversation(retry, retry.retrying.due_at_ms));
    try std.testing.expectEqualStrings("◌ Queued · 6s", try conversation(retry, retry.retrying.due_at_ms + 5_999));
    try std.testing.expectEqualStrings("⠹ Thinking · 0s", try conversation(.{ .working = .{ .since = test_now_s + 3 } }, test_now_ms));
}

test "a description's controls read escaped on both screens, as its call row shows them" {
    const state: WorkState = .{ .bash = .{ .since = test_now_s - 42, .call = 0, .description = bounded(session_work.max_description_bytes, "Run\t\x1b[2J\u{202e}tests"), .running = 1, .approvals = 0 } };
    try std.testing.expectEqualStrings("⠹ Run\\t\\x1b[2J\\u202etests · 42s", try conversation(state, test_now_ms));
    try std.testing.expectEqualStrings("Run\\t\\x1b[2J\\u202etests", try row(state, test_now_ms, .unicode));
    const widest: WorkState = .{ .bash = .{ .since = test_now_s, .call = 0, .description = bounded(session_work.max_description_bytes, &@as([session_work.max_description_bytes]u8, @splat(0x1b))), .running = 1, .approvals = 0 } };
    try std.testing.expectEqual(max_words_bytes, of(&test_words, &widest, null, test_now_ms).?.words.len);
}

test "a running Bash line names its call only beside the Work's Operation and the call's ordinal" {
    const bash: WorkState = .{ .bash = .{ .since = test_now_s, .call = 3, .description = null, .running = 2, .approvals = 0 } };
    try std.testing.expectEqual(@as(?Call, .{ .operation = 19, .ordinal = 3 }), of(&test_words, &bash, 19, test_now_ms).?.call);
    try std.testing.expectEqual(@as(?Call, null), of(&test_words, &bash, null, test_now_ms).?.call);
    const older: WorkState = .{ .bash = .{ .since = test_now_s, .call = null, .description = null, .running = 2, .approvals = 0 } };
    try std.testing.expectEqual(@as(?Call, null), of(&test_words, &older, 19, test_now_ms).?.call);
    try std.testing.expectEqual(@as(?Call, null), of(&test_words, &.{ .working = .{ .since = test_now_s } }, 19, test_now_ms).?.call);
}

test "a retry counts down whole seconds to its due time and never shows zero before it" {
    for ([_]struct { u64, u64 }{ .{ 1, 1 }, .{ 999, 1 }, .{ 1_000, 1 }, .{ 1_001, 2 }, .{ 17_200, 18 }, .{ 18_000, 18 } }) |case| {
        const state: WorkState = .{ .retrying = .{ .since = test_now_s - 1, .due_at_ms = test_now_ms + case[0], .cause = .{}, .attempt = 1 } };
        try std.testing.expectEqual(case[1], of(&test_words, &state, null, test_now_ms).?.clock.retry.seconds);
    }
}

test "a running span is seconds, then minutes and seconds, then hours and minutes up to its cap" {
    var buffer: [max_span_bytes]u8 = undefined;
    for ([_]struct { u64, []const u8 }{ .{ 0, "0s" }, .{ 59, "59s" }, .{ 60, "1m 0s" }, .{ 3599, "59m 59s" }, .{ 3600, "1h 0m" }, .{ 86_400 * 3 + 61, "72h 1m" }, .{ 99_999 * 3600 + 59 * 60, "99999h 59m" }, .{ 100_000 * 3600, "99999h 59m" }, .{ std.math.maxInt(u64), "99999h 59m" } }) |case| {
        try std.testing.expectEqualStrings(case[1], spanText(&buffer, case[0]));
    }
    var clock: [max_clock_bytes]u8 = undefined;
    const widest_retry = clockText(&clock, .{ .retry = .{ .attempt = session_work.max_retried_attempt, .seconds = max_retry_seconds } }, .conversation, .unicode).len;
    const widest_span = clockText(&clock, .{ .elapsed = std.math.maxInt(u64) }, .conversation, .unicode).len;
    try std.testing.expectEqual(max_clock_bytes, @max(widest_retry, widest_span));
}

test "a fitted line never takes more than its width and keeps the clock while words fit beside it" {
    var long: [session_work.max_description_bytes]u8 = undefined;
    for (0..long.len / 2) |at| @memcpy(long[at * 2 ..][0..2], "é");
    const descriptions = [_][]const u8{ "Run zig build test-store", &long, "a" };
    const clock = " · 42s";
    for (descriptions) |description| for ([_]Method{ .unicode, .wcwidth }) |method| for (0..240) |width| {
        const state: WorkState = .{ .bash = .{ .since = test_now_s - 42, .call = 0, .description = bounded(session_work.max_description_bytes, description), .running = 1, .approvals = 0 } };
        var buffer: [max_clock_bytes]u8 = undefined;
        const fitted = fit(&buffer, of(&test_words, &state, null, test_now_ms).?, width, method);
        const mark_cells: usize = 2;
        const clock_cells: usize = 6;
        const ellipsis_cells: usize = 1;
        const cells = (if (fitted.mark.len == 0) 0 else mark_cells) + session_line.cells(fitted.words, method) + (if (fitted.cut) ellipsis_cells else 0) + session_line.cells(fitted.clock, method);
        try std.testing.expect(cells <= width);
        try std.testing.expect(std.unicode.utf8ValidateSlice(fitted.words));
        try std.testing.expect(std.mem.startsWith(u8, description, fitted.words));
        if (mark_cells + session_line.cells(description, method) + clock_cells <= width) {
            try std.testing.expectEqualStrings(description, fitted.words);
            try std.testing.expectEqualStrings(clock, fitted.clock);
        } else {
            try std.testing.expect(fitted.words.len < description.len or fitted.clock.len == 0);
            if (fitted.words.len < description.len and width >= mark_cells + ellipsis_cells) try std.testing.expect(fitted.cut);
            if (width >= mark_cells + min_words_cells + ellipsis_cells + clock_cells) try std.testing.expectEqualStrings(clock, fitted.clock);
        }
    };
    var buffer: [max_clock_bytes]u8 = undefined;
    const stopped = fit(&buffer, stopping, 80, .unicode);
    try std.testing.expectEqualStrings("Stopping", stopped.words);
    try std.testing.expectEqualStrings("…", stopped.clock);
}
