//! The dimmed row right above the input that shows the newest Message a
//! person or script sent that waits behind the work, and how many wait:
//! `› also check the history scratch cache          queued`. The Host reports
//! them on each Activity page; live output shows each once it is taken: as
//! its conversation row once applied, or labelled at the stop that excluded
//! it. This core fits the row.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const session_line = @import("session_line.zig");
const protocol = @import("protocol.zig");

pub const Method = session_line.Method;

/// The newest queued Message's first line, terminal-safe.
pub const Line = Bounded(session_line.max_line_bytes);

/// A first line and the Message it was read from.
pub const Shown = struct { admission: u64, line: Line };

/// Whether the row shows: some wait, the newest is not one the opening
/// showed queued, and the work holds them. A Session that holds nothing
/// takes a Message at once, so its row would only flash.
pub fn shows(queued: protocol.Queued, opened: u64, holds: bool) bool {
    return queued.count != 0 and queued.newest_admission > opened and holds;
}

/// What the row shows: the newest Message's first line, and how many wait.
pub const Waiting = struct { line: []const u8, count: u64 };

/// The row: the newest Message cut to fit, then how many wait, right-aligned
/// at `column`.
pub const Row = struct { text: []const u8, label: []const u8, column: usize };

const mark = "› ";
pub const text_capacity = mark.len + session_line.max_line_bytes + session_line.ellipsis.len;
pub const label_capacity = std.fmt.count("{d} queued", .{std.math.maxInt(u64)});

/// Fits the row to `width` cells. The label always shows, shortened to
/// `queued` when the count does not fit; the Message keeps one cell before
/// it and shows only when its mark and one more cell fit.
pub fn row(text: *[text_capacity]u8, label: *[label_capacity]u8, line: []const u8, count: u64, width: usize, method: Method) Row {
    std.debug.assert(count != 0 and line.len <= session_line.max_line_bytes);
    const counted = if (count == 1) "queued" else std.fmt.bufPrint(label, "{d} queued", .{count}) catch unreachable;
    const shown = if (session_line.cells(counted, method) <= width) counted else "queued";
    const label_cells = session_line.cells(shown, method);
    var out = std.Io.Writer.fixed(text);
    const room = width -| label_cells -| 1;
    if (room >= session_line.cells(mark, method) + 1) {
        out.writeAll(mark) catch unreachable;
        const left = room - session_line.cells(mark, method);
        if (session_line.cells(line, method) <= left) {
            out.writeAll(line) catch unreachable;
        } else {
            const kept = session_line.fit(line, left - session_line.cells(session_line.ellipsis, method), method);
            out.writeAll(line[0..kept.len]) catch unreachable;
            out.writeAll(session_line.ellipsis) catch unreachable;
        }
    }
    return .{ .text = out.buffered(), .label = shown, .column = width -| label_cells };
}

test "the queued row keeps its label and cuts the Message before it" {
    var text: [text_capacity]u8 = undefined;
    var label: [label_capacity]u8 = undefined;
    const Case = struct { line: []const u8, count: u64, width: usize, text: []const u8, label: []const u8 };
    for ([_]Case{
        .{ .line = "also check the history scratch cache", .count = 1, .width = 80, .text = "› also check the history scratch cache", .label = "queued" },
        .{ .line = "also check the history scratch cache", .count = 3, .width = 80, .text = "› also check the history scratch cache", .label = "3 queued" },
        // 30 columns: 8 for the label, one before it, 21 for the Message.
        .{ .line = "also check the history scratch cache", .count = 3, .width = 30, .text = "› also check the his…", .label = "3 queued" },
        .{ .line = "中文中文中文中文", .count = 1, .width = 16, .text = "› 中文中…", .label = "queued" },
        // Too narrow for the mark and a cell: the label alone.
        .{ .line = "anything", .count = 12, .width = 11, .text = "", .label = "12 queued" },
        .{ .line = "anything", .count = 12, .width = 8, .text = "", .label = "queued" },
        .{ .line = "", .count = 1, .width = 80, .text = "› ", .label = "queued" },
    }) |case| {
        const fitted = row(&text, &label, case.line, case.count, case.width, .unicode);
        try std.testing.expectEqualStrings(case.text, fitted.text);
        try std.testing.expectEqualStrings(case.label, fitted.label);
        try std.testing.expectEqual(case.width - session_line.cells(case.label, .unicode), fitted.column);
    }
    // At every width the Message, a gap and the label fit.
    for (8..120) |width| for ([_]u64{ 1, 9, 12345 }) |count| {
        const fitted = row(&text, &label, "a long Message with wide 中文 clusters and more words than fit", count, width, .unicode);
        const used = session_line.cells(fitted.text, .unicode);
        try std.testing.expect(used == 0 or used + 1 <= fitted.column);
        try std.testing.expectEqual(width, fitted.column + session_line.cells(fitted.label, .unicode));
    };
}
