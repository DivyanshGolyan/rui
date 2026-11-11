//! Display clusters and their cell widths. The viewport normalizes clusters it
//! cannot retain in a cell; a plain terminal draws the safe text as emitted.
const std = @import("std");
const gwidth = @import("terminal_width");
const unicode = @import("terminal_unicode");
pub const Method = gwidth.Method;
pub const terminal_method: Method = .wcwidth;

/// A viewport's negotiated method travels with its destination, never as an
/// independent renderer default. CLI reads have no width negotiation.
pub const Target = union(enum) { terminal, viewport: Method };

pub const widest_cluster = 8;
pub const longest_cluster = 64;

pub fn representable(cluster: []const u8, method: Method) bool {
    return represented(cluster, method) != null;
}

fn represented(cluster: []const u8, method: Method) ?Piece {
    if (std.mem.eql(u8, cluster, "\n") or std.mem.eql(u8, cluster, "\t")) return piece(cluster, method);
    if (cluster.len > longest_cluster) return null;
    const shown = piece(cluster, method);
    return if (shown.cells != 0 and shown.cells <= widest_cluster) shown else null;
}

pub const Piece = struct { bytes: []const u8, cells: u16 };

/// The exact pieces a viewport retains for one complete UTF-8 grapheme.
/// Oversized/invisible clusters escape scalar runs, with fixed scratch only.
/// A returned escape borrows this iterator until its next call.
pub const Cluster = struct {
    raw: []const u8,
    method: Method,
    at: usize = 0,
    scratch: [40]u8 = undefined,

    pub fn next(self: *Cluster) ?Piece {
        if (self.at == self.raw.len) return null;
        if (self.at == 0) if (represented(self.raw, self.method)) |shown| {
            self.at = self.raw.len;
            return shown;
        };
        var scalars = (std.unicode.Utf8View.init(self.raw[self.at..]) catch unreachable).iterator();
        const point = scalars.nextCodepoint().?;
        var count: usize = 1;
        self.at += scalars.i;
        while (scalars.nextCodepoint()) |next_point| {
            if (next_point != point) break;
            count += 1;
            self.at += std.unicode.utf8ByteSequenceLength(self.raw[self.at]) catch unreachable;
        }
        const shown = if (count == 1)
            std.fmt.bufPrint(&self.scratch, "\\u{{{x}}}", .{point}) catch unreachable
        else
            std.fmt.bufPrint(&self.scratch, "\\u{{{x}}}×{d}", .{ point, count }) catch unreachable;
        return piece(shown, self.method);
    }
};

fn piece(bytes: []const u8, method: Method) Piece {
    // Word wrapping draws ASCII whitespace separately from graphemes. In
    // particular a prepend character can join a following space during
    // normalization but is drawn as a word followed by that space.
    var cells: u16 = 0;
    var start: usize = 0;
    for (bytes, 0..) |byte, index| if (byte == ' ' or byte == '\t' or byte == '\n') {
        cells +|= gwidth.gwidth(bytes[start..index], method);
        cells +|= if (byte == '\n') @as(u16, 0) else if (byte == '\t') @as(u16, 8) else 1;
        start = index + 1;
    };
    cells +|= gwidth.gwidth(bytes[start..], method);
    return .{ .bytes = bytes, .cells = cells };
}

/// Measure the representation the destination actually draws. TerminalText
/// has already escaped terminal controls; only the viewport additionally
/// replaces unrepresentable clusters. No SGR or OSC address reaches here.
/// Like Vaxis widths, the result saturates at its maximum cell count; table
/// cells are bounded below that, and a code indent clamps to its window.
pub fn width(bytes: []const u8, target: Target) u16 {
    const method = switch (target) {
        .terminal => terminal_method,
        .viewport => |method| method,
    };
    var cells: u16 = 0;
    var clusters = unicode.graphemeIterator(bytes);
    while (clusters.next()) |value| {
        const raw = value.bytes(bytes);
        if (target == .terminal) {
            cells +|= piece(raw, method).cells;
        } else {
            var displayed: Cluster = .{ .raw = raw, .method = method };
            while (displayed.next()) |shown| cells +|= shown.cells;
        }
    }
    return cells;
}

test "display width counts viewport escapes but a terminal's emitted text" {
    for (std.enums.values(Method)) |method| {
        try std.testing.expectEqual(@as(u16, 8), width("\u{200b}", .{ .viewport = method }));
        try std.testing.expectEqual(@as(u16, 7), width("\u{301}", .{ .viewport = method }));
        try std.testing.expectEqual(@as(u16, 2), width("雪", .{ .viewport = method }));
        try std.testing.expectEqual(@as(u16, 1), width("e\u{301}", .{ .viewport = method }));
    }
    try std.testing.expectEqual(@as(u16, 0), width("\u{200b}", .terminal));
    try std.testing.expectEqual(@as(u16, 4), width("\\x1b", .terminal));
}

test "display width saturates for a retained line wider than any window" {
    const spaces: [70_000]u8 = @splat(' ');
    try std.testing.expectEqual(@as(u16, 65535), width(&spaces, .{ .viewport = .unicode }));
}
