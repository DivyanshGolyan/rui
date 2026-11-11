//! State marks shared by terminal surfaces; each tone names a role, not a style.
const std = @import("std");

pub const Mark = enum { needs_you, active, queued, waiting, finished, failed, stopped };
pub const Tone = enum { ink, normal, quiet, attention, failure };

pub const marks = std.enums.EnumArray(Mark, struct { unicode: []const u8, ascii: []const u8, tone: Tone }).init(.{
    .needs_you = .{ .unicode = "?", .ascii = "?", .tone = .attention },
    .active = .{ .unicode = "⠹", .ascii = "*", .tone = .ink },
    .queued = .{ .unicode = "◌", .ascii = ":", .tone = .quiet },
    .waiting = .{ .unicode = "○", .ascii = "o", .tone = .quiet },
    .finished = .{ .unicode = "✓", .ascii = "+", .tone = .quiet },
    .failed = .{ .unicode = "×", .ascii = "x", .tone = .failure },
    .stopped = .{ .unicode = "■", .ascii = "#", .tone = .normal },
});

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
