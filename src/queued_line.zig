const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const marks = @import("marks.zig");
const session_line = @import("session_line.zig");

pub const Method = session_line.Method;

pub const Line = Bounded(session_line.max_line_bytes);

pub const Shown = struct { admission: u64, line: Line };

pub const Waiting = struct { line: []const u8, count: u64 };

pub const waiting_mark = marks.marks.get(.queued).unicode;
pub const waiting_capacity = waiting_mark.len + std.fmt.count(" {d} ·", .{std.math.maxInt(u64)}) + 1 + session_line.max_line_bytes + session_line.ellipsis.len;

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
    try std.testing.expectEqualStrings("◌ also upda…", waitingRow(&buffer, "also update docs", 1, 12, .unicode));
    try std.testing.expectEqualStrings("◌ 12 · a…", waitingRow(&buffer, "also", 12, 9, .unicode));
    try std.testing.expectEqualStrings("◌ 日本…", waitingRow(&buffer, "日本語です", 1, 8, .unicode));
    try std.testing.expectEqualStrings("◌ 3 ·", waitingRow(&buffer, "also", 3, 5, .unicode));
    try std.testing.expectEqualStrings("◌", waitingRow(&buffer, "also", 1, 1, .unicode));
}
