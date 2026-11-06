//! Presentation capabilities, never wire/content authority. Capture owns u64
//! prepared-file extents; retained Documents own bounded rebased extents.
const std = @import("std");
const prefix = @import("markdown_prefix.zig");
const rows = @import("table_row.zig");

pub const limit = 32;
pub const Data = union(enum) {
    /// Untrusted bytes: never pass through the trusted SGR/OSC decoder.
    literal_raw,
    table: rows.Columns,
    /// Already escaped/rendered prose, annotated from ORIGINAL raw syntax.
    quote: prefix.Quote,
};

pub fn Span(comptime Coordinate: type) type {
    return struct {
        start: Coordinate,
        end: Coordinate,
        header_end: Coordinate = 0,
        delimiter_end: Coordinate = 0,
        /// Proof of a complete admitted unit, not a min-clamped byte count.
        complete_end: Coordinate = 0,
        data: Data,
    };
}

pub fn Marks(comptime Coordinate: type) type {
    return struct {
        const Self = @This();
        items: [limit]Span(Coordinate) = undefined,
        count: u6 = 0,

        pub fn slice(self: *const Self) []const Span(Coordinate) {
            return self.items[0..self.count];
        }
        pub fn clear(self: *Self) void {
            self.count = 0;
        }
        pub fn reserve(self: *Self, span: Span(Coordinate)) bool {
            std.debug.assert(span.start <= span.end);
            if (self.count == limit) return false;
            var at: usize = self.count;
            while (at > 0 and self.items[at - 1].start > span.start) : (at -= 1) self.items[at] = self.items[at - 1];
            if (at != 0) std.debug.assert(self.items[at - 1].end <= span.start);
            if (at != self.count) std.debug.assert(span.end <= self.items[at + 1].start);
            self.items[at] = span;
            self.count += 1;
            return true;
        }

        /// Copy one source interval, preserving opaque provenance. Callers use
        /// this same edit rule for copies, rewrites, eviction and prepend.
        /// A clipped table header downgrades IN ITS SLOT. A clipped tail gets
        /// only an actual LF proof; a retained edge is never canonical EOF.
        pub fn copy(self: *Self, source: *const Self, bytes: []const u8, start: usize, end: usize, destination: usize) error{BlockCapacity}!void {
            std.debug.assert(start <= end and end <= bytes.len);
            for (source.slice()) |old| {
                const first = @max(@as(usize, old.start), start);
                const last = @min(@as(usize, old.end), end);
                if (first >= last) continue;
                // A quote whose original marker is gone has no decoration
                // authority. Its bytes remain trusted, escaped prose.
                if (old.data == .quote and first != old.start) continue;
                var value = old;
                const shifted = struct {
                    fn at(point: usize, from: usize, to: usize) Coordinate {
                        return @intCast(to + point - from);
                    }
                }.at;
                value.start = shifted(first, start, destination);
                value.end = shifted(last, start, destination);
                if (old.data == .table and (first != old.start or old.delimiter_end > last)) value.data = .literal_raw;
                if (value.data == .table) {
                    value.header_end = shifted(old.header_end, start, destination);
                    value.delimiter_end = shifted(old.delimiter_end, start, destination);
                    var complete = @as(usize, old.complete_end);
                    if (complete > last) {
                        complete = if (std.mem.lastIndexOfScalar(u8, bytes[first..last], '\n')) |line| first + line + 1 else first;
                    }
                    std.debug.assert(complete >= old.delimiter_end);
                    value.complete_end = shifted(complete, start, destination);
                } else {
                    value.header_end = 0;
                    value.delimiter_end = 0;
                    value.complete_end = 0;
                }
                if (!self.reserve(value)) return error.BlockCapacity;
            }
        }
    };
}

pub const Capture = Marks(u64);
pub const Retained = Marks(u32);

/// Synchronous borrowed values: the callback copies/consumes slices before
/// return. Rejection writes NOTHING; partial I/O is an error, never rejection.
/// Only assistant preparation and escaped UserBody paths receive a capability.
pub const Request = union(enum) {
    begin_table: struct { header: []const u8, delimiter: []const u8, columns: rows.Columns },
    table_row: []const u8,
    end_table,
    quote: ?prefix.Quote,
};
pub const Sink = struct {
    context: *anyopaque,
    event: *const fn (*anyopaque, Request) anyerror!bool,

    pub fn send(self: Sink, request: Request) anyerror!bool {
        return self.event(self.context, request);
    }
};

/// ONE prepared-payload cursor for live and saved-history ingestion. It owns
/// no file, bytes, rendering state or alternate pagination authority.
pub const Cursor = struct {
    marks: ?*const Capture = null,
    index: usize = 0,

    pub const Part = struct { end: u64, span: ?*const Span(u64) };
    pub fn part(self: *Cursor, offset: u64, end: u64) Part {
        std.debug.assert(offset <= end);
        const marks = self.marks orelse return .{ .end = end, .span = null };
        while (self.index < marks.count and marks.items[self.index].end <= offset) self.index += 1;
        if (self.index == marks.count) return .{ .end = end, .span = null };
        const span = &marks.items[self.index];
        if (offset < span.start) return .{ .end = @min(end, span.start), .span = null };
        return .{ .end = @min(end, span.end), .span = span };
    }
};

test "typed source extents preserve complete boundaries and downgrade header loss in one slot" {
    const raw = "h|x\n---|---\na|b\nlast|row";
    const delimiter_end = "h|x\n---|---\n".len;
    var marks: Retained = .{};
    const columns: rows.Columns = .{ .count = 2, .alignment = @splat(.left) };
    try std.testing.expect(marks.reserve(.{ .start = 0, .end = raw.len, .header_end = 4, .delimiter_end = delimiter_end, .complete_end = raw.len, .data = .{ .table = columns } }));
    var clipped: Retained = .{};
    try clipped.copy(&marks, raw, 0, raw.len - 2, 3);
    try std.testing.expectEqual(@as(u32, 3 + delimiter_end + "a|b\n".len), clipped.items[0].complete_end);
    clipped.clear();
    try clipped.copy(&marks, raw, 1, raw.len, 0);
    try std.testing.expectEqual(@as(u6, 1), clipped.count);
    try std.testing.expect(clipped.items[0].data == .literal_raw);
    try std.testing.expectEqual(@as(u32, raw.len - 1), clipped.items[0].end);
    clipped.clear();
    try clipped.copy(&marks, raw, 0, raw.len, 7);
    try std.testing.expectEqual(@as(u32, 7 + raw.len), clipped.items[0].complete_end);
}

test "prepared typed cursor preserves above 4GiB offsets and never reparses a cut as EOF" {
    const base: u64 = 1 << 34;
    var marks: Capture = .{};
    try std.testing.expect(marks.reserve(.{ .start = base + 3, .end = base + 13, .data = .literal_raw }));
    var cursor: Cursor = .{ .marks = &marks };
    const prose = cursor.part(base, base + 20);
    try std.testing.expectEqual(base + 3, prose.end);
    try std.testing.expect(prose.span == null);
    const raw = cursor.part(base + 3, base + 8);
    try std.testing.expectEqual(base + 8, raw.end);
    try std.testing.expect(raw.span.?.data == .literal_raw);
    try std.testing.expect(cursor.part(base + 8, base + 20).span == raw.span);
    try std.testing.expect(cursor.part(base + 13, base + 20).span == null);
    std.debug.print("typed block sizes retained={d} capture={d} span32={d} span64={d} bytes\n", .{ @sizeOf(Retained), @sizeOf(Capture), @sizeOf(Span(u32)), @sizeOf(Span(u64)) });
}
