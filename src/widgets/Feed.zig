//! A keyed view over a caller-owned window. No text or layout storage is retained.
const std = @import("std");

/// Key is an integer, or a value with `pub fn order(Key, Key) std.math.Order`.
/// Entries have unique, strictly increasing keys. An empty line slice is a hidden keyed entry; visible logical lines
/// have positive wrapped-row counts at the current width.
/// Slices are borrowed only during calls. Work is O(total logical lines), with
/// constant scratch space, no allocations and no cached layout to invalidate.
pub fn Feed(comptime Key: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct { key: Key, lines: []const u32 };
        pub const Anchor = union(enum) {
            end,
            at: struct { key: Key, line: u32 = 0, row: u32 = 0 },
        };
        pub const Edges = struct { start: bool, end: bool };
        pub const Need = enum { none, above, below };
        pub const Visible = struct {
            /// entries.len when empty or height is zero; otherwise a valid index.
            first: usize,
            line: u32 = 0,
            row: u32 = 0,
            /// Following a short window puts blank rows above its first entry.
            pad: u32 = 0,
        };
        pub const Trim = struct { drop_front: usize = 0, drop_back: usize = 0 };
        pub const margin_screens = 3;
        pub const bank_screens = 4;

        anchor: Anchor = .end,
        /// Unspent scroll intent at an unknown loaded edge, negative above.
        /// Bounded to bank_screens * height on every scroll/load transition.
        banked_rows: i64 = 0,

        pub fn following(self: Self) bool {
            return self.anchor == .end;
        }

        pub fn follow(self: *Self) void {
            self.anchor = .end;
            self.banked_rows = 0;
        }

        /// An explicit anchor keeps its logical line and wrapped row on top,
        /// even if less than a screen remains below it. Clamp only coordinates
        /// that no longer exist. Reads never rewrite the stored anchor.
        pub fn visible(self: Self, entries: []const Entry, height: u32) Visible {
            if (height == 0) return .{ .first = entries.len };
            const layout = self.measure(entries, height);
            var view = locate(entries, layout.top);
            if (self.following()) view.pad = @intCast(height -| layout.total);
            return view;
        }

        /// Keep three screens on either side. If both margins are short, spend
        /// banked intent first, otherwise load the nearer edge (above wins ties).
        pub fn need(self: Self, entries: []const Entry, height: u32, edges: Edges) Need {
            if (height == 0) return .none;
            const layout = self.measure(entries, height);
            const above = layout.top;
            const below = layout.total -| (layout.top + height);
            const margin = margin_screens * @as(u64, height);
            const want_above = above < margin and !edges.start;
            const want_below = below < margin and !edges.end;
            if (self.banked_rows < 0 and want_above) return .above;
            if (self.banked_rows > 0 and want_below) return .below;
            if (want_above and (!want_below or above <= below)) return .above;
            return if (want_below) .below else .none;
        }

        /// Negative rows move up. Loaded-edge overscroll is banked only when
        /// that edge is not the true history edge. Reversing direction clears
        /// the bank. Zero moves and zero-height views leave state untouched.
        pub fn scroll(self: *Self, entries: []const Entry, height: u32, rows: i32, edges: Edges) void {
            if (height == 0 or rows == 0) return;
            const same_direction = (rows < 0) == (self.banked_rows < 0);
            const amount = @as(i64, rows) + if (same_direction) self.banked_rows else 0;
            self.move(entries, height, amount, edges);
        }

        /// Call after prepending entries. Without banked upward intent the
        /// keyed anchor already preserves the view and nothing is changed.
        pub fn prepend(self: *Self, entries: []const Entry, height: u32, edges: Edges) void {
            self.spend(entries, height, edges, .above);
        }

        /// Call after appending entries. Following still follows; an explicit
        /// anchor moves only to spend previously banked downward intent.
        pub fn append(self: *Self, entries: []const Entry, height: u32, edges: Edges) void {
            self.spend(entries, height, edges, .below);
        }

        /// Call with the new dimensions after replacing an entry in place.
        /// Only an anchor naming that key is clamped; following stays following.
        pub fn replace(self: *Self, entry: Entry) void {
            if (self.anchor == .at and order(self.anchor.at.key, entry.key) == .eq) {
                const point = clamp(entry.lines, self.anchor.at.line, self.anchor.at.row);
                self.anchor.at.line = point.line;
                self.anchor.at.row = point.row;
            }
        }

        /// Best-effort entry-count bound, computed by the caller from its byte
        /// budget. Drop whole entries from the farther side first (front wins
        /// ties), preserving the view and the same margins need() loads. If that
        /// region exceeds the bound, retain it rather than the bound. Apply both
        /// counts together; no anchor adjustment is needed. Zero height drops none.
        pub fn trim(self: Self, entries: []const Entry, height: u32, max_entries: usize) Trim {
            var result: Trim = .{};
            if (height == 0 or entries.len <= max_entries) return result;
            const layout = self.measure(entries, height);
            const margin = margin_screens * @as(u64, height);
            const keep_start = layout.top -| margin;
            const keep_end = @min(layout.total, layout.top + height + margin);
            var front: u64 = 0;
            var back = layout.total;
            var first_rows = entryRows(entries[0]);
            var last_rows = entryRows(entries[entries.len - 1]);
            while (entries.len - result.drop_front - result.drop_back > max_entries) {
                const can_front = front + first_rows <= keep_start;
                const can_back = back - last_rows >= keep_end;
                if (!can_front and !can_back) break;
                if (can_front and (!can_back or layout.top - front >= back -| (layout.top + height))) {
                    front += first_rows;
                    result.drop_front += 1;
                    first_rows = entryRows(entries[result.drop_front]);
                } else {
                    back -= last_rows;
                    result.drop_back += 1;
                    last_rows = entryRows(entries[entries.len - result.drop_back - 1]);
                }
            }
            return result;
        }

        fn spend(self: *Self, entries: []const Entry, height: u32, edges: Edges, side: Need) void {
            if (height == 0 or self.banked_rows == 0) return;
            if ((self.banked_rows < 0) != (side == .above)) return;
            self.move(entries, height, self.banked_rows, edges);
        }

        fn move(self: *Self, entries: []const Entry, height: u32, rows: i64, edges: Edges) void {
            const layout = self.measure(entries, height);
            const up = rows < 0;
            const amount: u64 = @intCast(if (up) -rows else rows);
            const bottom = layout.total -| height;
            const available = if (up) layout.top else bottom -| layout.top;
            const moved = @min(amount, available);
            const target = if (up) layout.top - moved else layout.top + moved;
            const true_edge = if (up) edges.start else edges.end;
            const extra: i64 = @intCast(if (true_edge) 0 else @min(amount - moved, bank_screens * @as(u64, height)));
            self.banked_rows = if (up) -extra else extra;
            if (layout.total == 0) return; // Hidden entries cannot become a visual anchor.
            if (!up and target >= bottom and edges.end) {
                self.follow();
            } else {
                const view = locate(entries, target);
                self.anchor = .{ .at = .{ .key = entries[view.first].key, .line = view.line, .row = view.row } };
            }
        }

        const Layout = struct { top: u64, total: u64 };
        const Point = struct { line: u32, row: u32 };

        fn clamp(lines: []const u32, line: u32, row: u32) Point {
            if (lines.len == 0) return .{ .line = 0, .row = 0 };
            std.debug.assert(lines.len <= std.math.maxInt(u32));
            const selected: u32 = @intCast(@min(line, lines.len - 1));
            std.debug.assert(lines[selected] > 0);
            return .{ .line = selected, .row = @min(row, lines[selected] - 1) };
        }

        fn entryRows(entry: Entry) u64 {
            var total: u64 = 0;
            for (entry.lines) |rows| {
                std.debug.assert(rows > 0);
                total += rows;
            }
            return total;
        }

        fn offset(entry: Entry, line: u32, row: u32) u64 {
            const point = clamp(entry.lines, line, row);
            var result: u64 = point.row;
            for (entry.lines[0..point.line]) |rows| result += rows;
            return result;
        }

        /// Ordinal proximity: first surviving successor, or last predecessor
        /// if none. Preserve/clamp logical coordinates, never silently use .end.
        fn measure(self: Self, entries: []const Entry, height: u32) Layout {
            var total: u64 = 0;
            var top: ?u64 = null;
            for (entries) |entry| {
                if (entry.lines.len != 0 and self.anchor == .at and top == null and order(entry.key, self.anchor.at.key) != .lt)
                    top = total + offset(entry, self.anchor.at.line, self.anchor.at.row);
                total += entryRows(entry);
            }
            if (self.following()) return .{ .top = total -| height, .total = total };
            if (total == 0) return .{ .top = 0, .total = 0 };
            var last_index = entries.len - 1;
            while (entries[last_index].lines.len == 0) last_index -= 1;
            const last = entries[last_index];
            return .{
                .top = top orelse (total - entryRows(last) + offset(last, self.anchor.at.line, self.anchor.at.row)),
                .total = total,
            };
        }

        fn locate(entries: []const Entry, position: u64) Visible {
            var row = position;
            for (entries, 0..) |entry, index| {
                for (entry.lines, 0..) |rows, line| {
                    if (row < rows) return .{ .first = index, .line = @intCast(line), .row = @intCast(row) };
                    row -= rows;
                }
            }
            return .{ .first = entries.len };
        }

        fn order(a: Key, b: Key) std.math.Order {
            return switch (@typeInfo(Key)) {
                .int => std.math.order(a, b),
                else => Key.order(a, b),
            };
        }
    };
}

test "Feed domain: layout, margins, scrolling, edits, resize and trimming" {
    const F = Feed(i32);
    const middle: F.Anchor = .{ .at = .{ .key = 20, .line = 1, .row = 1 } };
    const base: []const F.Entry = &.{ .{ .key = 20, .lines = &.{ 1, 4 } }, .{ .key = 30, .lines = &.{3} } };
    const prepended: []const F.Entry = &.{ .{ .key = 10, .lines = &.{4} }, .{ .key = 20, .lines = &.{ 1, 4 } }, .{ .key = 30, .lines = &.{3} } };
    const appended: []const F.Entry = &.{ .{ .key = 20, .lines = &.{ 1, 4 } }, .{ .key = 30, .lines = &.{3} }, .{ .key = 40, .lines = &.{6} } };
    const both: []const F.Entry = &.{ .{ .key = 10, .lines = &.{4} }, .{ .key = 20, .lines = &.{ 1, 4 } }, .{ .key = 30, .lines = &.{3} }, .{ .key = 40, .lines = &.{6} } };
    const removed: []const F.Entry = &.{ .{ .key = 10, .lines = &.{4} }, .{ .key = 30, .lines = &.{3} } };
    const long: []const F.Entry = &.{
        .{ .key = 1, .lines = &.{2} }, .{ .key = 2, .lines = &.{2} }, .{ .key = 3, .lines = &.{2} }, .{ .key = 4, .lines = &.{2} }, .{ .key = 5, .lines = &.{2} },
        .{ .key = 6, .lines = &.{2} }, .{ .key = 7, .lines = &.{2} }, .{ .key = 8, .lines = &.{2} }, .{ .key = 9, .lines = &.{2} }, .{ .key = 10, .lines = &.{2} },
    };
    const all: F.Edges = .{ .start = true, .end = true };
    const neither: F.Edges = .{ .start = false, .end = false };
    const Case = struct {
        name: []const u8,
        entries: []const F.Entry = base,
        anchor: F.Anchor = .end,
        height: u32 = 4,
        edges: F.Edges = all,
        move: i32 = 0,
        limit: usize = std.math.maxInt(usize),
        key: ?i32,
        line: u32 = 0,
        row: u32 = 0,
        pad: u32 = 0,
        following: bool = true,
        need: F.Need = .none,
        bank: i64 = 0,
        drops: F.Trim = .{},
    };
    const cases = [_]Case{
        .{ .name = "empty", .entries = &.{}, .key = null, .pad = 4 },
        .{ .name = "empty missing both edges", .entries = &.{}, .edges = neither, .key = null, .pad = 4, .need = .above },
        .{ .name = "empty missing newest", .entries = &.{}, .edges = .{ .start = true, .end = false }, .key = null, .pad = 4, .need = .below },
        .{ .name = "empty keeps keyed anchor", .entries = &.{}, .anchor = middle, .move = 50, .key = null, .following = false },
        .{ .name = "short bottom alignment", .height = 10, .key = 20, .pad = 2 },
        .{ .name = "exact screen", .height = 8, .key = 20 },
        .{ .name = "following before append", .key = 20, .line = 1, .row = 3 },
        .{ .name = "following after append", .entries = appended, .key = 40, .row = 2 },
        .{ .name = "anchored mid line", .anchor = middle, .key = 20, .line = 1, .row = 1, .following = false },
        .{ .name = "prepend preserves key line row", .entries = prepended, .anchor = middle, .key = 20, .line = 1, .row = 1, .following = false },
        .{ .name = "append preserves key line row", .entries = appended, .anchor = middle, .key = 20, .line = 1, .row = 1, .following = false },
        .{ .name = "both edits preserve key line row", .entries = both, .anchor = middle, .key = 20, .line = 1, .row = 1, .following = false },
        .{ .name = "up leaves follow", .move = -1, .key = 20, .line = 1, .row = 2, .following = false },
        .{ .name = "down resumes follow", .anchor = middle, .move = 2, .key = 20, .line = 1, .row = 3 },
        .{ .name = "exact unknown newest does not follow or bank", .anchor = middle, .move = 2, .edges = .{ .start = true, .end = false }, .key = 20, .line = 1, .row = 3, .following = false, .need = .below },
        .{ .name = "unknown newest stops without following", .anchor = middle, .move = 100, .edges = .{ .start = true, .end = false }, .key = 20, .line = 1, .row = 3, .following = false, .need = .below, .bank = 16 },
        .{ .name = "unknown oldest banks above", .move = -100, .edges = .{ .start = false, .end = true }, .key = 20, .following = false, .need = .above, .bank = -16 },
        .{ .name = "known oldest just stops", .move = -100, .key = 20, .following = false },
        .{ .name = "maximum up page", .move = std.math.minInt(i32), .key = 20, .following = false },
        .{ .name = "maximum down page", .anchor = middle, .move = std.math.maxInt(i32), .key = 20, .line = 1, .row = 3 },
        .{ .name = "both short nearer top", .anchor = .{ .at = .{ .key = 20, .line = 1 } }, .edges = neither, .key = 20, .line = 1, .following = false, .need = .above },
        .{ .name = "both short nearer bottom", .anchor = .{ .at = .{ .key = 20, .line = 1, .row = 2 } }, .edges = neither, .key = 20, .line = 1, .row = 2, .following = false, .need = .below },
        .{ .name = "both short tie", .anchor = middle, .edges = neither, .key = 20, .line = 1, .row = 1, .following = false, .need = .above },
        .{ .name = "one screen is not enough margin", .entries = long, .height = 2, .anchor = .{ .at = .{ .key = 2 } }, .edges = .{ .start = false, .end = true }, .key = 2, .following = false, .need = .above },
        .{ .name = "three screens is enough margin", .entries = long, .height = 2, .anchor = .{ .at = .{ .key = 4 } }, .edges = neither, .key = 4, .following = false },
        .{ .name = "below three screens requests newer", .entries = long, .height = 2, .anchor = .{ .at = .{ .key = 8 } }, .edges = .{ .start = true, .end = false }, .key = 8, .following = false, .need = .below },
        .{ .name = "trim far back", .entries = long, .height = 2, .anchor = .{ .at = .{ .key = 2 } }, .limit = 6, .key = 2, .following = false, .drops = .{ .drop_back = 4 } },
        .{ .name = "trim far front", .entries = long, .height = 2, .anchor = .{ .at = .{ .key = 9 } }, .limit = 6, .key = 9, .following = false, .drops = .{ .drop_front = 4 } },
        .{ .name = "trim follows newest", .entries = long, .height = 2, .limit = 6, .key = 10, .drops = .{ .drop_front = 4 } },
        .{ .name = "trim protects loading margins over bound", .entries = long, .height = 2, .anchor = .{ .at = .{ .key = 5 } }, .limit = 0, .key = 5, .following = false, .drops = .{ .drop_front = 1, .drop_back = 2 } },
        .{ .name = "trim keeps partial entries", .entries = both, .anchor = middle, .height = 1, .limit = 0, .key = 20, .line = 1, .row = 1, .following = false, .drops = .{ .drop_back = 1 } },
        .{ .name = "missing key uses successor", .entries = removed, .anchor = middle, .key = 30, .row = 1, .following = false },
        .{ .name = "missing before first", .anchor = .{ .at = .{ .key = 10, .row = 1 } }, .key = 20, .following = false },
        .{ .name = "missing after last", .anchor = .{ .at = .{ .key = 40, .line = 10, .row = 10 } }, .key = 30, .row = 2, .following = false },
        .{ .name = "taller view keeps anchored top", .anchor = middle, .height = 20, .key = 20, .line = 1, .row = 1, .following = false },
        .{ .name = "zero height is inert", .anchor = middle, .height = 0, .move = 50, .edges = neither, .limit = 0, .key = null, .following = false },
    };
    for (cases) |case| {
        errdefer std.debug.print("Feed case: {s}\n", .{case.name});
        var feed: F = .{ .anchor = case.anchor };
        feed.scroll(case.entries, case.height, case.move, case.edges);
        const anchor = feed.anchor;
        const view = feed.visible(case.entries, case.height);
        const key = if (view.first < case.entries.len) case.entries[view.first].key else null;
        try std.testing.expectEqual(case.key, key);
        try std.testing.expectEqual(case.line, view.line);
        try std.testing.expectEqual(case.row, view.row);
        try std.testing.expectEqual(case.pad, view.pad);
        try std.testing.expectEqual(case.following, feed.following());
        try std.testing.expectEqual(case.bank, feed.banked_rows);
        try std.testing.expectEqual(case.need, feed.need(case.entries, case.height, case.edges));
        const drops = feed.trim(case.entries, case.height, case.limit);
        try std.testing.expectEqualDeep(case.drops, drops);
        const retained = case.entries[drops.drop_front .. case.entries.len - drops.drop_back];
        const after = feed.visible(retained, case.height);
        const after_key = if (after.first < retained.len) retained[after.first].key else null;
        try std.testing.expectEqual(case.key, after_key);
        try std.testing.expectEqual(view.line, after.line);
        try std.testing.expectEqual(view.row, after.row);
        try std.testing.expectEqual(view.pad, after.pad);
        try std.testing.expectEqualDeep(anchor, feed.anchor);
        try std.testing.expectEqual(case.bank, feed.banked_rows);
    }
}

test "Feed resize preserves logical line within a long entry; replace clamps each anchor" {
    const F = Feed(u64);
    const wide: F.Entry = .{ .key = 20, .lines = &.{ 2, 3, 4, 2 } };
    const narrow: F.Entry = .{ .key = 20, .lines = &.{ 20, 30, 40, 20 } };
    const shorter: F.Entry = .{ .key = 20, .lines = &.{ 1, 1, 2 } };
    const tiny: F.Entry = .{ .key = 20, .lines = &.{1} };
    const anchored: F.Anchor = .{ .at = .{ .key = 20, .line = 2, .row = 3 } };
    var feed: F = .{ .anchor = anchored };
    try std.testing.expectEqualDeep(F.Visible{ .first = 0, .line = 2, .row = 3 }, feed.visible(&.{wide}, 4));
    try std.testing.expectEqualDeep(F.Visible{ .first = 0, .line = 2, .row = 3 }, feed.visible(&.{narrow}, 8));
    try std.testing.expectEqualDeep(F.Visible{ .first = 0, .line = 2, .row = 1 }, feed.visible(&.{shorter}, 4));
    try std.testing.expectEqualDeep(F.Visible{ .first = 0 }, feed.visible(&.{tiny}, 4));
    try std.testing.expectEqualDeep(anchored, feed.anchor); // Resize is a pure read.

    const Case = struct { anchor: F.Anchor, replacement: F.Entry, expected: F.Anchor };
    const other: F.Anchor = .{ .at = .{ .key = 10, .line = 3, .row = 7 } };
    const cases = [_]Case{
        .{ .anchor = .end, .replacement = tiny, .expected = .end },
        .{ .anchor = other, .replacement = tiny, .expected = other },
        .{ .anchor = anchored, .replacement = narrow, .expected = anchored },
        .{ .anchor = anchored, .replacement = shorter, .expected = .{ .at = .{ .key = 20, .line = 2, .row = 1 } } },
        .{ .anchor = anchored, .replacement = tiny, .expected = .{ .at = .{ .key = 20 } } },
    };
    for (cases) |case| {
        feed = .{ .anchor = case.anchor, .banked_rows = -3 };
        feed.replace(case.replacement);
        try std.testing.expectEqualDeep(case.expected, feed.anchor);
        try std.testing.expectEqual(@as(i64, -3), feed.banked_rows);
    }
    feed.follow();
    try std.testing.expect(feed.following());
    try std.testing.expectEqual(@as(i64, 0), feed.banked_rows);
    try std.testing.expectEqualDeep(F.Visible{ .first = 0, .line = 3, .row = 12 }, feed.visible(&.{narrow}, 8));
}

test "Feed banks bounded overscroll, spends loaded rows, and clears reversal and true edges" {
    const F = Feed(u64);
    const entries: []const F.Entry = &.{ .{ .key = 10, .lines = &.{3} }, .{ .key = 20, .lines = &.{5} }, .{ .key = 30, .lines = &.{5} }, .{ .key = 40, .lines = &.{10} } };
    const unknown: F.Edges = .{ .start = false, .end = false };
    const known: F.Edges = .{ .start = true, .end = true };
    var feed: F = .{};
    feed.scroll(entries[2..3], 4, -7, unknown); // Move one loaded row; bank six.
    try std.testing.expectEqualDeep(F.Anchor{ .at = .{ .key = 30 } }, feed.anchor);
    try std.testing.expectEqual(@as(i64, -6), feed.banked_rows);
    feed.append(entries[2..], 4, unknown); // The wrong side cannot spend the bank.
    try std.testing.expectEqual(@as(i64, -6), feed.banked_rows);
    feed.prepend(entries[1..3], 4, unknown); // Five rows arrive; one remains banked.
    try std.testing.expectEqualDeep(F.Anchor{ .at = .{ .key = 20 } }, feed.anchor);
    try std.testing.expectEqual(@as(i64, -1), feed.banked_rows);
    feed.prepend(entries[0..3], 4, unknown);
    try std.testing.expectEqualDeep(F.Anchor{ .at = .{ .key = 10, .row = 2 } }, feed.anchor);
    try std.testing.expectEqual(@as(i64, 0), feed.banked_rows);

    feed.scroll(entries, 4, std.math.minInt(i32), unknown);
    feed.scroll(entries, 4, -100, unknown); // Repeated keys cannot grow past four screens.
    try std.testing.expectEqual(@as(i64, -16), feed.banked_rows);
    feed.scroll(entries, 4, 2, unknown); // Opposite movement discards debt, not motion.
    try std.testing.expectEqual(@as(i64, 0), feed.banked_rows);
    try std.testing.expectEqualDeep(F.Anchor{ .at = .{ .key = 10, .row = 2 } }, feed.anchor);
    feed.scroll(entries, 4, -100, unknown);
    feed.prepend(entries, 4, known); // A read discovered the true start.
    try std.testing.expectEqual(@as(i64, 0), feed.banked_rows);
    try std.testing.expect(!feed.following());

    feed = .{};
    feed.scroll(entries[0..2], 4, 7, unknown);
    try std.testing.expect(!feed.following());
    try std.testing.expectEqual(@as(i64, 7), feed.banked_rows);
    feed.append(entries[0..3], 4, unknown);
    try std.testing.expectEqualDeep(F.Anchor{ .at = .{ .key = 30, .row = 1 } }, feed.anchor);
    try std.testing.expectEqual(@as(i64, 2), feed.banked_rows);
    feed.append(entries, 4, known);
    try std.testing.expectEqualDeep(F.Anchor{ .at = .{ .key = 30, .row = 3 } }, feed.anchor);
    try std.testing.expectEqual(@as(i64, 0), feed.banked_rows);
    feed.scroll(entries, 4, 100, unknown);
    try std.testing.expectEqual(@as(i64, 16), feed.banked_rows);
    feed.append(entries, 4, known);
    try std.testing.expect(feed.following());
    try std.testing.expectEqual(@as(i64, 0), feed.banked_rows);

    feed.scroll(entries, 4, 100, unknown);
    feed.scroll(entries, 4, -2, unknown);
    try std.testing.expectEqual(@as(i64, 0), feed.banked_rows);
    try std.testing.expectEqualDeep(F.Anchor{ .at = .{ .key = 40, .row = 4 } }, feed.anchor);

    // Even an empty window can retain bounded intent until a page arrives.
    feed = .{};
    feed.scroll(&.{}, 4, -7, unknown);
    try std.testing.expectEqual(@as(i64, -7), feed.banked_rows);
    feed.prepend(entries, 4, unknown);
    try std.testing.expectEqualDeep(F.Anchor{ .at = .{ .key = 30, .row = 4 } }, feed.anchor);
    try std.testing.expectEqual(@as(i64, 0), feed.banked_rows);

    // Without debt, explicit anchors survive both edits; following follows append.
    feed = .{ .anchor = .{ .at = .{ .key = 20, .row = 2 } } };
    const anchor = feed.anchor;
    feed.prepend(entries, 4, known);
    feed.append(entries, 4, known);
    try std.testing.expectEqualDeep(anchor, feed.anchor);
    feed.follow();
    feed.append(entries, 4, known);
    try std.testing.expectEqualDeep(F.Visible{ .first = 3, .row = 6 }, feed.visible(entries, 4));
}

test "Feed supports ordered compound keys and wide row totals" {
    const Key = struct {
        position: u64,
        ordinal: u32,
        pub fn order(a: @This(), b: @This()) std.math.Order {
            const primary = std.math.order(a.position, b.position);
            return if (primary == .eq) std.math.order(a.ordinal, b.ordinal) else primary;
        }
    };
    const F = Feed(Key);
    const entries: []const F.Entry = &.{
        .{ .key = .{ .position = 10, .ordinal = 0 }, .lines = &.{std.math.maxInt(u32)} },
        .{ .key = .{ .position = 10, .ordinal = 2 }, .lines = &.{ std.math.maxInt(u32), 10 } },
        .{ .key = .{ .position = 11, .ordinal = 0 }, .lines = &.{10} },
    };
    var feed: F = .{ .anchor = .{ .at = .{ .key = .{ .position = 10, .ordinal = 1 }, .row = 7 } } };
    try std.testing.expectEqualDeep(F.Visible{ .first = 1, .row = 7 }, feed.visible(entries, 4));
    feed.follow();
    try std.testing.expectEqualDeep(F.Visible{ .first = 2, .row = 6 }, feed.visible(entries, 4));
    feed.scroll(entries, 4, -30, .{ .start = false, .end = true });
    try std.testing.expectEqualDeep(F.Visible{ .first = 1, .row = std.math.maxInt(u32) - 14 }, feed.visible(entries, 4));
}

test "Feed hidden keyed entries have no height and never become scroll anchors" {
    const F = Feed(u64);
    const entries: []const F.Entry = &.{ .{ .key = 1, .lines = &.{} }, .{ .key = 2, .lines = &.{4} }, .{ .key = 3, .lines = &.{} } };
    var view: F = .{};
    try std.testing.expectEqual(@as(usize, 1), view.visible(entries, 2).first);
    view.scroll(entries, 2, -1, .{ .start = false, .end = true });
    try std.testing.expectEqual(@as(u64, 2), view.anchor.at.key);
    view.scroll(entries[0..1], 2, -8, .{ .start = false, .end = false });
    try std.testing.expectEqual(@as(i64, -8), view.banked_rows);
    try std.testing.expectEqual(@as(usize, 1), view.visible(entries[0..1], 2).first);
}
