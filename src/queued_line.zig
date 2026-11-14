//! The dimmed row right above the input that shows the newest Message a
//! person or script sent that waits behind the work, and how many wait:
//! `◌ 3 · also check the history scratch cache`. The Host reports
//! them on each Activity page; live output shows each once it is taken: as
//! its conversation row once applied, or labelled at the stop that excluded
//! it. This core fits the row.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const marks = @import("marks.zig");
const session_line = @import("session_line.zig");

pub const Method = session_line.Method;

/// The newest queued Message's first line, terminal-safe.
pub const Line = Bounded(session_line.max_line_bytes);

/// A first line and the Message it was read from.
pub const Shown = struct { admission: u64, line: Line };

/// What the row shows: the newest Message's first line, and how many wait.
pub const Waiting = struct { line: []const u8, count: u64 };

/// The waiting mark the Session's activity tail and the overview share.
pub const waiting_mark = marks.marks.get(.queued).unicode;
pub const waiting_capacity = waiting_mark.len + std.fmt.count(" {d} ·", .{std.math.maxInt(u64)}) + 1 + session_line.max_line_bytes + session_line.ellipsis.len;

/// The activity tail's waiting row: `◌ also update docs …`, and with more
/// than one waiting, `◌ 3 · also update docs …`, the newest Message cut to
/// `width` cells. The mark says it waits its turn; there is no word.
pub fn waitingRow(buffer: *[waiting_capacity]u8, line: []const u8, count: u64, width: usize, method: Method) []const u8 {
    std.debug.assert(count != 0 and line.len <= session_line.max_line_bytes);
    var out = std.Io.Writer.fixed(buffer);
    out.writeAll(waiting_mark) catch unreachable;
    if (count > 1) out.print(" {d} ·", .{count}) catch unreachable;
    const head = session_line.cells(out.buffered(), method) + 1;
    if (head >= width) return out.buffered();
    out.writeByte(' ') catch unreachable;
    const room = width - head;
    if (session_line.cells(line, method) <= room) {
        out.writeAll(line) catch unreachable;
    } else {
        const kept = session_line.fit(line, room -| session_line.cells(session_line.ellipsis, method), method);
        out.writeAll(line[0..kept.len]) catch unreachable;
        out.writeAll(session_line.ellipsis) catch unreachable;
    }
    return out.buffered();
}

test "the waiting row marks the newest Message and counts the rest, cut to the row" {
    var buffer: [waiting_capacity]u8 = undefined;
    try std.testing.expectEqualStrings("◌ also update docs/using-rui.md", waitingRow(&buffer, "also update docs/using-rui.md", 1, 80, .unicode));
    try std.testing.expectEqualStrings("◌ 3 · also update docs/using-rui.md", waitingRow(&buffer, "also update docs/using-rui.md", 3, 80, .unicode));
    // Cut to 12 cells: "◌ " takes 2, the words 9, the ellipsis 1.
    try std.testing.expectEqualStrings("◌ also upda…", waitingRow(&buffer, "also update docs", 1, 12, .unicode));
    try std.testing.expectEqualStrings("◌ 12 · a…", waitingRow(&buffer, "also", 12, 9, .unicode));
    // Wide clusters are never split.
    try std.testing.expectEqualStrings("◌ 日本…", waitingRow(&buffer, "日本語です", 1, 8, .unicode));
    // Too narrow for any words: the mark and count alone.
    try std.testing.expectEqualStrings("◌ 3 ·", waitingRow(&buffer, "also", 3, 5, .unicode));
    try std.testing.expectEqualStrings("◌", waitingRow(&buffer, "also", 1, 1, .unicode));
}
