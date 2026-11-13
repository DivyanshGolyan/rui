//! State marks shared by terminal surfaces; each tone names a role, not a style.
const std = @import("std");
const failure_class = @import("failure_class.zig");
const Provider = @import("provider_name.zig").Provider;

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
/// `provider` is the ending Session's, when the surface knows it: a quota
/// refusal sends the person where that provider raises its limit, and to
/// Settings otherwise. No other cause depends on it.
pub fn cause(code: []const u8, provider: ?Provider) Cause {
    if (std.mem.eql(u8, code, "malformed_provider_output")) return .{ .words = "Model reply unreadable", .key = "ctrl+r retries" };
    return switch (failure_class.of(code)) {
        .policy => .{ .words = "Refused by the provider" },
        .quota => .{ .words = "Out of quota", .place = (if (provider) |known| known.usage() else null) orelse "Settings" },
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

test "cause retry keys and places cover every failure class and leave repair and stop unkeyed" {
    const Case = struct { code: []const u8, provider: ?Provider = null, key: ?[]const u8, place: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .code = "malformed_provider_output", .key = "ctrl+r retries" },
        .{ .code = "provider_policy", .key = null },
        .{ .code = "provider_quota", .key = null, .place = "Settings" },
        .{ .code = "provider_quota", .provider = .codex, .key = null, .place = "Settings" },
        .{ .code = "provider_quota", .provider = .openai, .key = null, .place = "Settings" },
        .{ .code = "provider_quota", .provider = .chatgpt, .key = null, .place = "Manage usage: https://chatgpt.com/settings/usage" },
        .{ .code = "provider_plan", .key = null, .place = "Settings" },
        .{ .code = "provider_plan", .provider = .chatgpt, .key = null, .place = "Settings" },
        .{ .code = "provider_model_unavailable", .key = "ctrl+r retries" },
        .{ .code = "provider_http_401", .key = null, .place = "Settings" },
        .{ .code = "provider_http_401", .provider = .chatgpt, .key = null, .place = "Settings" },
        .{ .code = "provider_api_key_rejected", .key = null, .place = "Settings" },
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
        const shown = cause(case.code, case.provider);
        if (case.key) |key| {
            try std.testing.expectEqualStrings(key, shown.key orelse return error.MissingRetryKey);
        } else try std.testing.expectEqual(@as(?[]const u8, null), shown.key);
        if (case.place) |place| {
            try std.testing.expectEqualStrings(place, shown.place orelse return error.MissingPlace);
        } else try std.testing.expectEqual(@as(?[]const u8, null), shown.place);
        if (shown.place != null) try std.testing.expect(shown.key == null);
    }
    try std.testing.expect(seen.eql(.full));
}

test "a provider changes only a quota refusal's place, and only when it names one" {
    const codes = [_][]const u8{ "malformed_provider_output", "provider_policy", "provider_quota", "provider_plan", "provider_model_unavailable", "provider_http_401", "provider_api_key_rejected", "ResourceExceeded", "provider_tls_verification_failed", "retry_exhausted", "cancelled", "provider_http_400", "unknown" };
    var seen: std.enums.EnumSet(failure_class.Class) = .empty;
    for (codes) |code| {
        seen.insert(failure_class.of(code));
        const unknown = cause(code, null);
        for (std.enums.values(Provider)) |provider| {
            const shown = cause(code, provider);
            try std.testing.expectEqualStrings(unknown.words, shown.words);
            try std.testing.expectEqual(unknown.key, shown.key);
            const usage = if (failure_class.of(code) == .quota) provider.usage() else null;
            try std.testing.expectEqualStrings(usage orelse unknown.place orelse "", shown.place orelse "");
        }
    }
    try std.testing.expect(seen.eql(.full));
}
