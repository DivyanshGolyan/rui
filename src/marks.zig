//! State marks shared by terminal surfaces; each tone names a role, not a style.
const std = @import("std");
const failure_class = @import("failure_class.zig");

pub const Mark = enum { needs_you, active, queued, waiting, finished, failed, stopped, newer };
pub const Tone = enum { ink, normal, quiet, attention, failure };

pub const marks = std.enums.EnumArray(Mark, struct { unicode: []const u8, ascii: []const u8, tone: Tone }).init(.{
    .needs_you = .{ .unicode = "?", .ascii = "?", .tone = .attention },
    .active = .{ .unicode = "⠹", .ascii = "*", .tone = .ink },
    .queued = .{ .unicode = "◌", .ascii = ":", .tone = .quiet },
    .waiting = .{ .unicode = "○", .ascii = "o", .tone = .quiet },
    .finished = .{ .unicode = "✓", .ascii = "+", .tone = .quiet },
    .failed = .{ .unicode = "×", .ascii = "x", .tone = .failure },
    .stopped = .{ .unicode = "■", .ascii = "#", .tone = .normal },
    .newer = .{ .unicode = "↓", .ascii = "v", .tone = .quiet },
});

pub const Cause = struct {
    words: []const u8,
    place: ?[]const u8 = null,
    /// Offered only when the latest ending can resend the person's Message.
    key: ?[]const u8 = null,
};

/// Plain words shared by chat and list surfaces, never a saved code or report.
/// Retry policy lives here: Settings destinations need repair first, policy and
/// overflow cannot be fixed by resending, and an interruption is not a failure.
/// Surfaces still decide whether this is the latest, currently actionable ending.
pub fn cause(code: []const u8) Cause {
    if (std.mem.eql(u8, code, "malformed_provider_output")) return .{ .words = "Model reply unreadable", .key = "ctrl+r retries" };
    return switch (failure_class.of(code)) {
        .policy => .{ .words = "Refused by the provider" },
        .quota => .{ .words = "Out of quota", .place = "Settings" },
        .plan => .{ .words = "Model not in plan", .place = "Settings" },
        .model => .{ .words = "Model not served", .key = "ctrl+r retries" },
        .sign_in => .{ .words = "Sign-in expired", .place = "Settings" },
        .api_key => .{ .words = "API key rejected", .place = "Settings" },
        .overflow => .{ .words = "Context full" },
        .unreachable_provider => .{ .words = "Provider unreachable", .key = "ctrl+r retries" },
        .retries_exhausted => .{ .words = "Retries ran out", .key = "ctrl+r retries" },
        .interrupted => .{ .words = "Stopped" },
        .refused => .{ .words = "Provider refused the request", .key = "ctrl+r retries" },
        .other => .{ .words = "Something went wrong", .key = "ctrl+r retries" },
    };
}

/// Frames for work under way. `active`'s still glyph is one of these frames.
pub const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

test "marks have distinct state meanings, nonempty scripts and printable ASCII" {
    const Case = struct { mark: Mark, unicode: []const u8, ascii: []const u8, tone: Tone };
    const cases = [_]Case{
        .{ .mark = .needs_you, .unicode = "?", .ascii = "?", .tone = .attention },
        .{ .mark = .active, .unicode = "⠹", .ascii = "*", .tone = .ink },
        .{ .mark = .queued, .unicode = "◌", .ascii = ":", .tone = .quiet },
        .{ .mark = .waiting, .unicode = "○", .ascii = "o", .tone = .quiet },
        .{ .mark = .finished, .unicode = "✓", .ascii = "+", .tone = .quiet },
        .{ .mark = .failed, .unicode = "×", .ascii = "x", .tone = .failure },
        .{ .mark = .stopped, .unicode = "■", .ascii = "#", .tone = .normal },
        .{ .mark = .newer, .unicode = "↓", .ascii = "v", .tone = .quiet },
    };
    var seen: std.enums.EnumSet(Mark) = .empty;
    for (cases) |case| {
        seen.insert(case.mark);
        const shown = marks.get(case.mark);
        try std.testing.expect(shown.unicode.len != 0 and shown.ascii.len != 0);
        try std.testing.expectEqual(@as(usize, 1), shown.ascii.len);
        try std.testing.expect(shown.ascii[0] >= 0x20 and shown.ascii[0] <= 0x7e);
        try std.testing.expectEqualStrings(case.unicode, shown.unicode);
        try std.testing.expectEqualStrings(case.ascii, shown.ascii);
        try std.testing.expectEqual(case.tone, shown.tone);
    }
    try std.testing.expect(seen.eql(.full));
    var still_frame = false;
    for (spinner) |frame| {
        if (std.mem.eql(u8, frame, marks.get(.active).unicode)) still_frame = true;
    }
    try std.testing.expectEqual(@as(usize, 10), spinner.len);
    try std.testing.expect(still_frame);
}

test "cause retry keys cover every failure class and leave repair and stop unkeyed" {
    const Case = struct { code: []const u8, key: ?[]const u8 };
    const cases = [_]Case{
        .{ .code = "malformed_provider_output", .key = "ctrl+r retries" },
        .{ .code = "provider_policy", .key = null },
        .{ .code = "provider_quota", .key = null },
        .{ .code = "provider_plan", .key = null },
        .{ .code = "provider_model_unavailable", .key = "ctrl+r retries" },
        .{ .code = "provider_http_401", .key = null },
        .{ .code = "provider_api_key_rejected", .key = null },
        .{ .code = "ResourceExceeded", .key = null },
        .{ .code = "provider_tls_verification_failed", .key = "ctrl+r retries" },
        .{ .code = "retry_exhausted", .key = "ctrl+r retries" },
        .{ .code = "cancelled", .key = null },
        .{ .code = "provider_http_400", .key = "ctrl+r retries" },
        .{ .code = "unknown", .key = "ctrl+r retries" },
    };
    var seen: std.enums.EnumSet(failure_class.Class) = .empty;
    for (cases) |case| {
        seen.insert(failure_class.of(case.code));
        const shown = cause(case.code);
        if (case.key) |key| {
            try std.testing.expectEqualStrings(key, shown.key orelse return error.MissingRetryKey);
        } else try std.testing.expectEqual(@as(?[]const u8, null), shown.key);
        if (shown.place != null) try std.testing.expect(shown.key == null);
    }
    try std.testing.expect(seen.eql(.full));
}
