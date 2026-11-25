const std = @import("std");
const failure_class = @import("failure_class.zig");
const connection = @import("connection.zig");
const provider_route = @import("provider_route.zig");
const turn_ending = @import("turn_ending.zig");

pub const Mark = enum { needs_you, active, queued, waiting, finished, sent, failed, stopped, newer, none };
pub const Tone = enum { ink, normal, quiet, attention, failure };

pub const marks = std.enums.EnumArray(Mark, struct { unicode: []const u8, ascii: []const u8, tone: Tone }).init(.{
    .needs_you = .{ .unicode = "●", .ascii = "?", .tone = .attention },
    .active = .{ .unicode = "◝", .ascii = "*", .tone = .ink },
    .queued = .{ .unicode = "◌", .ascii = ":", .tone = .quiet },
    .waiting = .{ .unicode = "○", .ascii = "o", .tone = .quiet },
    .finished = .{ .unicode = "✓", .ascii = "+", .tone = .quiet },
    .sent = .{ .unicode = "→", .ascii = ">", .tone = .quiet },
    .failed = .{ .unicode = "×", .ascii = "x", .tone = .failure },
    .stopped = .{ .unicode = "▪", .ascii = "#", .tone = .normal },
    .none = .{ .unicode = " ", .ascii = " ", .tone = .quiet },
    .newer = .{ .unicode = "↓", .ascii = "v", .tone = .quiet },
});

pub const Cause = struct {
    words: []const u8,
    place: ?[]const u8 = null,
    key: ?[]const u8 = null,
};

pub fn cause(code: []const u8, provider: ?connection.Name) Cause {
    if (std.mem.eql(u8, code, failure_class.ordered_input_not_supported)) return .{ .words = "This Host cannot send this input yet; no provider request was sent" };
    if (std.mem.eql(u8, code, failure_class.ordered_input_limit)) return .{ .words = "Input exceeds this Host's request limit; no provider request was sent" };
    if (std.mem.eql(u8, code, "malformed_provider_output")) return .{ .words = "The model's reply didn't come through", .key = "ctrl+r retries" };
    return switch (failure_class.of(code)) {
        .policy => .{ .words = "Refused by the provider" },
        .quota => .{ .words = "Out of quota", .place = (if (provider) |known| if (provider_route.builtInOf(known)) |built_in| built_in.usage() else null else null) orelse "Settings" },
        .plan => .{ .words = "Model not in plan", .place = "Settings" },
        .model => .{ .words = "Model not served", .key = "ctrl+r retries" },
        .sign_in => .{ .words = "Sign-in expired", .place = "Settings" },
        .api_key => .{ .words = "API key rejected", .place = "Settings" },
        .overflow => .{ .words = "Context full" },
        .unreachable_provider => .{ .words = "Provider unreachable", .key = "ctrl+r retries" },
        .retries_exhausted => .{ .words = "Retries ran out", .key = "ctrl+r retries" },
        .interrupted => .{ .words = turn_ending.TurnEnding.stopped.words().? },
        .refused => .{ .words = "Provider refused the request", .key = "ctrl+r retries" },
        .other => .{ .words = "That didn't work", .key = "ctrl+r retries" },
    };
}

pub const spinner = [_][]const u8{ "◜", "◝", "◞", "◟" };

test "MRK-1 status marks and spinner represent their states" {
    const Case = struct { mark: Mark, unicode: []const u8, ascii: []const u8, tone: Tone };
    const cases = [_]Case{
        .{ .mark = .needs_you, .unicode = "●", .ascii = "?", .tone = .attention },
        .{ .mark = .active, .unicode = "◝", .ascii = "*", .tone = .ink },
        .{ .mark = .queued, .unicode = "◌", .ascii = ":", .tone = .quiet },
        .{ .mark = .waiting, .unicode = "○", .ascii = "o", .tone = .quiet },
        .{ .mark = .finished, .unicode = "✓", .ascii = "+", .tone = .quiet },
        .{ .mark = .sent, .unicode = "→", .ascii = ">", .tone = .quiet },
        .{ .mark = .failed, .unicode = "×", .ascii = "x", .tone = .failure },
        .{ .mark = .stopped, .unicode = "▪", .ascii = "#", .tone = .normal },
        .{ .mark = .none, .unicode = " ", .ascii = " ", .tone = .quiet },
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
    const expected_frames = [_][]const u8{ "◜", "◝", "◞", "◟" };
    for (spinner, expected_frames) |frame, expected| {
        try std.testing.expectEqualStrings(expected, frame);
        if (std.mem.eql(u8, frame, marks.get(.active).unicode)) still_frame = true;
    }
    try std.testing.expectEqual(@as(usize, 4), spinner.len);
    try std.testing.expect(still_frame);
}

test "MRK-2 failure causes provide the appropriate explanation and advice" {
    const Case = struct { code: []const u8, provider: ?connection.Name = null, words: []const u8, key: ?[]const u8, place: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .code = "malformed_provider_output", .words = "The model's reply didn't come through", .key = "ctrl+r retries" },
        .{ .code = "provider_policy", .words = "Refused by the provider", .key = null },
        .{ .code = "provider_quota", .words = "Out of quota", .key = null, .place = "Settings" },
        .{ .code = "provider_quota", .words = "Out of quota", .provider = connection.Name.parse("codex"), .key = null, .place = "Settings" },
        .{ .code = "provider_quota", .words = "Out of quota", .provider = connection.Name.parse("openai"), .key = null, .place = "Settings" },
        .{ .code = "provider_quota", .words = "Out of quota", .provider = connection.Name.parse("chatgpt"), .key = null, .place = "Manage usage: https://chatgpt.com/settings/usage" },
        .{ .code = "provider_plan", .words = "Model not in plan", .key = null, .place = "Settings" },
        .{ .code = "provider_plan", .words = "Model not in plan", .provider = connection.Name.parse("chatgpt"), .key = null, .place = "Settings" },
        .{ .code = "provider_model_unavailable", .words = "Model not served", .key = "ctrl+r retries" },
        .{ .code = "provider_http_401", .words = "Sign-in expired", .key = null, .place = "Settings" },
        .{ .code = "provider_http_401", .words = "Sign-in expired", .provider = connection.Name.parse("chatgpt"), .key = null, .place = "Settings" },
        .{ .code = "provider_api_key_rejected", .words = "API key rejected", .key = null, .place = "Settings" },
        .{ .code = "ResourceExceeded", .words = "Context full", .key = null },
        .{ .code = "provider_tls_verification_failed", .words = "Provider unreachable", .key = "ctrl+r retries" },
        .{ .code = "retry_exhausted", .words = "Retries ran out", .key = "ctrl+r retries" },
        .{ .code = "cancelled", .words = "Stopped", .key = null },
        .{ .code = "provider_http_400", .words = "Provider refused the request", .key = "ctrl+r retries" },
        .{ .code = "unknown", .words = "That didn't work", .key = "ctrl+r retries" },
    };
    var seen: std.enums.EnumSet(failure_class.Class) = .empty;
    for (cases) |case| {
        seen.insert(failure_class.of(case.code));
        const shown = cause(case.code, case.provider);
        try std.testing.expectEqualStrings(case.words, shown.words);
        if (case.key) |key| {
            try std.testing.expectEqualStrings(key, shown.key orelse return error.MissingRetryKey);
        } else try std.testing.expectEqual(@as(?[]const u8, null), shown.key);
        if (case.place) |place| {
            try std.testing.expectEqualStrings(place, shown.place orelse return error.MissingPlace);
        } else try std.testing.expectEqual(@as(?[]const u8, null), shown.place);
        if (shown.place != null) try std.testing.expect(shown.key == null);
    }
    try std.testing.expect(seen.eql(.full));
    {
        const codes = [_][]const u8{ "malformed_provider_output", "provider_policy", "provider_quota", "provider_plan", "provider_model_unavailable", "provider_http_401", "provider_api_key_rejected", "ResourceExceeded", "provider_tls_verification_failed", "retry_exhausted", "cancelled", "provider_http_400", "unknown" };
        var provider_seen: std.enums.EnumSet(failure_class.Class) = .empty;
        for (codes) |code| {
            provider_seen.insert(failure_class.of(code));
            const unknown = cause(code, null);
            for (std.enums.values(@import("provider_name.zig").Provider)) |built_in| {
                const provider = connection.Name.parse(@tagName(built_in)).?;
                const shown = cause(code, provider);
                try std.testing.expectEqualStrings(unknown.words, shown.words);
                try std.testing.expectEqual(unknown.key, shown.key);
                const usage = if (failure_class.of(code) == .quota) built_in.usage() else null;
                try std.testing.expectEqualStrings(usage orelse unknown.place orelse "", shown.place orelse "");
            }
        }
        try std.testing.expect(provider_seen.eql(.full));
    }
    {
        const local = cause(failure_class.ordered_input_limit, null);
        try std.testing.expectEqualStrings("Input exceeds this Host's request limit; no provider request was sent", local.words);
        try std.testing.expect(local.key == null and local.place == null);
        const unsupported = cause(failure_class.ordered_input_not_supported, null);
        try std.testing.expectEqualStrings("This Host cannot send this input yet; no provider request was sent", unsupported.words);
        try std.testing.expect(unsupported.key == null and unsupported.place == null);
        try std.testing.expect(cause("provider_http_400", null).key != null);
    }
}
