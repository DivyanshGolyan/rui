//! Rui's resident feed text. Feed owns the anchor; this owner owns text,
//! page-edge facts and the bounded set of opened tools. No reader is wired yet.
const std = @import("std");
const vaxis = @import("vaxis");
const unicode = @import("terminal_unicode");
const viewport = @import("ConversationViewport.zig");

pub const Key = struct {
    position: u64,
    ordinal: u64 = 0,

    pub fn order(a: Key, b: Key) std.math.Order {
        const primary = std.math.order(a.position, b.position);
        return if (primary == .eq) std.math.order(a.ordinal, b.ordinal) else primary;
    }
};
pub const Feed = @import("widgets/Feed.zig").Feed(Key);

/// Borrowed, prepared Document representation, not SGR input. Empty styles
/// means plain text. A renderer uses Document.append/prepare, then fromDocument;
/// this window neither parses SGR nor implements text layout a second time.
pub const Text = struct {
    bytes: []const u8,
    styles: []const u8 = &.{},

    pub fn fromDocument(document: anytype) Text {
        std.debug.assert(!document.dirty);
        const bytes = document.text();
        return .{ .bytes = bytes, .styles = document.styles[0..bytes.len] };
    }
};
pub const Entry = struct {
    key: Key,
    text: Text,
    tight: bool = false,
    provisional: bool = false,
};

pub const row_capacity = 32 * 1024;
pub const entry_capacity = 512;
// Account for styles AND worst-case one u32 per byte of newline-only text,
// plus the entry and layout tables, within the old styled Document's footprint.
// 79 KiB of text is below the existing 256-KiB ceiling. At 80 columns with
// typical ~80-byte lines this holds >900 rows, and 512 one-line entries hold
// >three 140x40 screens even when every neighbour is tight. These independent
// caps prevent a large row or many tiny entries from causing load/evict ping-pong.
// No finite byte budget promises three screens at arbitrary terminal sizes.
pub const byte_capacity = 79 * 1024;
// Remember the latest 64 opened keys, including evicted entries; oldest-opened
// is forgotten when full. Lookup does not mutate order. Closing releases a slot.
pub const open_capacity = 64;

pub const Window = struct {
    const Document = viewport.Sized(byte_capacity, true);
    const Stored = struct {
        key: Key,
        offset: usize,
        length: usize,
        tight: bool,
        provisional: bool,
    };

    document: Document = .{ .dirty = false, .sidenotes = true, .quotes = true },
    entries: [entry_capacity]Stored = undefined,
    count: usize = 0,
    opened: [open_capacity]Key = undefined,
    opened_count: usize = 0,
    // Page cursors are facts, not aliases for rendered row keys: filtered or
    // empty pages can advance them without adding any rendered text.
    at_start: bool = false,
    at_end: bool = false,
    low: ?Key = null,
    high: ?Key = null,
    // Borrowed layout output; rebuilt, never cached. Every stored entry has a
    // terminating newline, so there cannot be more logical lines than bytes.
    dimensions: [entry_capacity]Feed.Entry = undefined,
    line_rows: [byte_capacity]u32 = undefined,

    pub const Error = error{WindowFull};

    pub fn edges(self: *const Window) Feed.Edges {
        return .{ .start = self.at_start, .end = self.at_end };
    }

    pub fn isOpen(self: *const Window, key: Key) bool {
        for (self.opened[0..self.opened_count]) |item| if (item.order(key) == .eq) return true;
        return false;
    }

    pub fn setOpen(self: *Window, key: Key, open: bool) void {
        for (self.opened[0..self.opened_count], 0..) |item, i| {
            if (item.order(key) != .eq) continue;
            if (!open) {
                std.mem.copyForwards(Key, self.opened[i..], self.opened[i + 1 .. self.opened_count]);
                self.opened_count -= 1;
            }
            return;
        }
        if (!open) return;
        if (self.opened_count == open_capacity) {
            std.mem.copyForwards(Key, &self.opened, self.opened[1..]);
            self.opened_count -= 1;
        }
        self.opened[self.opened_count] = key;
        self.opened_count += 1;
    }

    /// All edits copy their input. Input must not alias this window. Errors are
    /// atomic: callers can ask Feed.trim before retrying; edits never silently
    /// evict the anchored entry. Publish the page's edge facts after success.
    pub fn prepend(self: *Window, entries: []const Entry) Error!void {
        try self.splice(0, 0, entries);
    }

    pub fn append(self: *Window, entries: []const Entry) Error!void {
        try self.splice(self.count, 0, entries);
    }

    /// Keeps the row's flags. A caller notifies Feed.replace with the newly
    /// measured entry if the anchor's logical coordinates need clamping.
    pub fn replace(self: *Window, key: Key, new_text: Text) Error!void {
        const index = self.indexOf(key) orelse unreachable;
        const old = self.entries[index];
        try self.splice(index, 1, &.{.{ .key = key, .text = new_text, .tight = old.tight, .provisional = old.provisional }});
    }

    /// Forward reads restart at the first provisional row. The replacement may
    /// settle it, remove it, or introduce other keys in the suffix.
    pub fn replaceFrom(self: *Window, first: Key, entries: []const Entry) Error!void {
        const index = self.indexOf(first) orelse unreachable;
        std.debug.assert(self.entries[index].provisional);
        for (self.entries[0..index]) |entry| std.debug.assert(!entry.provisional);
        try self.splice(index, self.count - index, entries);
    }

    pub fn firstProvisional(self: *const Window) ?Key {
        for (self.entries[0..self.count]) |entry| if (entry.provisional) return entry.key;
        return null;
    }

    pub fn trim(self: *Window, drop_front: usize, drop_back: usize) void {
        std.debug.assert(drop_front + drop_back <= self.count);
        const end = self.count - drop_back;
        const start_byte = if (drop_front < self.count) self.entries[drop_front].offset else self.document.length;
        const end_byte = if (end < self.count) self.entries[end].offset else self.document.length;
        const length = end_byte - start_byte;
        std.mem.copyForwards(u8, &self.document.bytes, self.document.bytes[start_byte..end_byte]);
        std.mem.copyForwards(u8, &self.document.styles, self.document.styles[start_byte..end_byte]);
        std.mem.copyForwards(Stored, &self.entries, self.entries[drop_front..end]);
        self.count = end - drop_front;
        for (self.entries[0..self.count]) |*entry| entry.offset -= start_byte;
        self.document.length = length;
        if (drop_front != 0) {
            self.at_start = false;
            self.low = if (self.count != 0) self.entries[0].key else null;
        }
        if (drop_back != 0) {
            self.at_end = false;
            self.high = if (self.count != 0) self.entries[self.count - 1].key else null;
        }
        // Open keys deliberately survive both sides, including an empty window.
    }

    /// Text borrows the window and is invalidated by any edit, not by heights.
    pub fn text(self: *const Window, key: Key) Text {
        const entry = self.entries[self.indexOf(key) orelse unreachable];
        return .{ .bytes = self.document.bytes[entry.offset..][0..entry.length], .styles = self.document.styles[entry.offset..][0..entry.length] };
    }

    /// Borrowed until the next heights call or edit. Uses Document.printLine
    /// with commit=false, including its styles, hanging indents and links.
    /// A gap belongs to the predecessor's last logical line, not its text.
    pub fn heights(self: *Window, layout: viewport.Layout) []const Feed.Entry {
        self.document.width_method = layout.method;
        var used: usize = 0;
        for (self.entries[0..self.count], 0..) |entry, i| {
            const start = used;
            var offset = entry.offset;
            const end = offset + entry.length;
            while (offset < end) {
                self.line_rows[used] = if (layout.width == 0) 1 else self.document.lineRows(layout, offset);
                used += 1;
                offset = self.document.lineEnd(offset) + 1;
            }
            self.line_rows[used - 1] += self.gapAfter(i);
            self.dimensions[i] = .{ .key = entry.key, .lines = self.line_rows[start..used] };
        }
        return self.dimensions[0..self.count];
    }

    /// Feed.Visible must have been obtained at this window's current width and
    /// width method. The supplied vaxis window is already the shell's feed pane.
    pub fn draw(self: *const Window, visible: Feed.Visible, window: vaxis.Window, colour: bool, plain: vaxis.Style, colours: viewport.Colours) void {
        window.fill(.{ .style = plain });
        if (window.width == 0 or window.height == 0 or visible.first >= self.count) return;
        std.debug.assert(self.document.width_method == window.screen.width_method);
        var row: i32 = @intCast(visible.pad);
        for (self.entries[visible.first..self.count], visible.first..) |entry, i| {
            var offset = entry.offset;
            var line: u32 = 0;
            const end = offset + entry.length;
            while (offset < end) : (line += 1) {
                const next = self.document.lineEnd(offset) + 1;
                if (i != visible.first or line >= visible.line) {
                    const skip = if (i == visible.first and line == visible.line) visible.row else 0;
                    if (row >= window.height) return;
                    const height = self.document.printLine(window, @intCast(row - @as(i32, @intCast(skip))), offset, true, colour, plain, colours);
                    row += @as(i32, height) - @as(i32, @intCast(skip));
                    if (next == end) row += self.gapAfter(i);
                }
                offset = next;
            }
        }
    }

    fn gapAfter(self: *const Window, index: usize) u1 {
        return @intFromBool(index + 1 < self.count and !(self.entries[index].tight and self.entries[index + 1].tight));
    }

    fn indexOf(self: *const Window, key: Key) ?usize {
        for (self.entries[0..self.count], 0..) |entry, i| if (entry.key.order(key) == .eq) return i;
        return null;
    }

    // Reserve a newline for every entry: logical line boundaries and hidden
    // link-address runs cannot cross a seam. This is not the adjacency gap.
    const Plan = struct {
        head: usize,
        marker: [64]u8 = undefined,
        marker_length: usize = 0,
        length: usize,
    };

    fn plan(text_: Text) Plan {
        const bytes = text_.bytes;
        std.debug.assert(text_.styles.len == 0 or text_.styles.len == bytes.len);
        const newline = bytes.len == 0 or bytes[bytes.len - 1] != '\n';
        if (bytes.len + @intFromBool(newline) <= row_capacity)
            return .{ .head = bytes.len, .length = @max(1, bytes.len + @intFromBool(newline)) };
        const limit = row_capacity - 64;
        // Prefer complete logical lines. With a single enormous line retain
        // whole graphemes from its head instead; never split a UTF-8 scalar.
        const head = if (std.mem.lastIndexOfScalar(u8, bytes[0..limit], '\n')) |end| end + 1 else blk: {
            var clusters = unicode.graphemeIterator(bytes);
            var end: usize = 0;
            while (clusters.next()) |cluster| {
                if (cluster.start + cluster.len > limit) break;
                end = cluster.start + cluster.len;
            }
            break :blk end;
        };
        // A cut at a line boundary must not count its preceding line as hidden.
        const hidden_bytes = bytes[head..];
        const hidden = std.mem.count(u8, hidden_bytes, "\n") + @intFromBool(hidden_bytes.len != 0 and hidden_bytes[hidden_bytes.len - 1] != '\n');
        var result: Plan = .{ .head = head, .length = undefined };
        const marker = std.fmt.bufPrint(&result.marker, "{s}┄ {d} more lines\n", .{ if (head != 0 and bytes[head - 1] == '\n') "" else "\n", hidden }) catch unreachable;
        result.marker_length = marker.len;
        result.length = head + marker.len;
        return result;
    }

    fn splice(self: *Window, first: usize, remove: usize, incoming: []const Entry) Error!void {
        const count = self.count - remove + incoming.len;
        if (count > entry_capacity) return error.WindowFull;
        const old_start = if (first < self.count) self.entries[first].offset else self.document.length;
        const old_end = if (first + remove < self.count) self.entries[first + remove].offset else self.document.length;
        var added: usize = 0;
        for (incoming, 0..) |entry, i| {
            if (i != 0) std.debug.assert(incoming[i - 1].key.order(entry.key) == .lt);
            added += plan(entry.text).length;
        }
        if (incoming.len != 0) {
            if (first != 0) std.debug.assert(self.entries[first - 1].key.order(incoming[0].key) == .lt);
            if (first + remove < self.count) std.debug.assert(incoming[incoming.len - 1].key.order(self.entries[first + remove].key) == .lt);
        }
        const length = self.document.length - (old_end - old_start) + added;
        if (length > byte_capacity) return error.WindowFull;
        const new_end = old_start + added;
        const tail = self.document.length - old_end;
        if (new_end > old_end) {
            std.mem.copyBackwards(u8, self.document.bytes[new_end..][0..tail], self.document.bytes[old_end..][0..tail]);
            std.mem.copyBackwards(u8, self.document.styles[new_end..][0..tail], self.document.styles[old_end..][0..tail]);
        } else {
            std.mem.copyForwards(u8, self.document.bytes[new_end..][0..tail], self.document.bytes[old_end..][0..tail]);
            std.mem.copyForwards(u8, self.document.styles[new_end..][0..tail], self.document.styles[old_end..][0..tail]);
        }
        const rest = self.count - first - remove;
        if (incoming.len > remove) {
            std.mem.copyBackwards(Stored, self.entries[first + incoming.len ..][0..rest], self.entries[first + remove ..][0..rest]);
        } else {
            std.mem.copyForwards(Stored, self.entries[first + incoming.len ..][0..rest], self.entries[first + remove ..][0..rest]);
        }
        for (self.entries[first + incoming.len .. count]) |*entry| entry.offset = new_end + (entry.offset - old_end);
        var offset = old_start;
        for (incoming, 0..) |entry, i| {
            const p = plan(entry.text);
            @memcpy(self.document.bytes[offset..][0..p.head], entry.text.bytes[0..p.head]);
            if (entry.text.styles.len != 0) @memcpy(self.document.styles[offset..][0..p.head], entry.text.styles[0..p.head]) else @memset(self.document.styles[offset..][0..p.head], 0);
            if (p.marker_length != 0) {
                @memcpy(self.document.bytes[offset + p.head ..][0..p.marker_length], p.marker[0..p.marker_length]);
                @memset(self.document.styles[offset + p.head ..][0..p.marker_length], 0);
            } else if (p.length > p.head) {
                self.document.bytes[offset + p.head] = '\n';
                self.document.styles[offset + p.head] = 0;
            }
            // Always end link/style runs at an entry seam, even if the source
            // renderer included its own styled trailing newline.
            self.document.styles[offset + p.length - 1] = 0;
            self.entries[first + i] = .{ .key = entry.key, .offset = offset, .length = p.length, .tight = entry.tight, .provisional = entry.provisional };
            offset += p.length;
        }
        self.document.length = length;
        self.count = count;
    }
};

comptime {
    std.debug.assert(@sizeOf(Window) <= @sizeOf(viewport.Document));
}

const testing = std.testing;
const test_layout: viewport.Layout = .{ .width = 3, .method = .unicode };

fn testEntry(position: u64, bytes: []const u8) Entry {
    return .{ .key = .{ .position = position }, .text = .{ .bytes = bytes } };
}

fn expectAnchor(window: *Window, feed: *Feed, expected: Feed.Anchor, tail: u64) !void {
    const entries = window.heights(test_layout);
    const visible = feed.visible(entries, 1);
    try testing.expectEqualDeep(expected, feed.anchor);
    if (expected == .end) {
        try testing.expectEqual(tail, entries[visible.first].key.position);
        try testing.expectEqual(@as(u32, 1), visible.line);
        try testing.expectEqual(@as(u32, 1), visible.row);
    } else {
        try testing.expectEqualDeep(expected.at.key, entries[visible.first].key);
        try testing.expectEqual(expected.at.line, visible.line);
        try testing.expectEqual(expected.at.row, visible.row);
    }
}

test "feed_window edits preserve end and mid-entry Feed anchors" {
    const anchors: []const Feed.Anchor = &.{
        .end,
        .{ .at = .{ .key = .{ .position = 20 }, .line = 1, .row = 1 } },
        .{ .at = .{ .key = .{ .position = 30 }, .line = 1, .row = 1 } },
    };
    for (anchors) |anchor| {
        var window: Window = .{};
        var provisional = testEntry(30, "abcdef\n123456");
        provisional.provisional = true;
        try window.append(&.{ testEntry(20, "abcdef\n123456"), provisional });
        var feed: Feed = .{ .anchor = anchor };
        try expectAnchor(&window, &feed, anchor, 30);
        try window.prepend(&.{testEntry(10, "older")});
        feed.prepend(window.heights(test_layout), 1, window.edges());
        try expectAnchor(&window, &feed, anchor, 30);
        try window.append(&.{testEntry(40, "abcdef\n123456")});
        feed.append(window.heights(test_layout), 1, window.edges());
        try expectAnchor(&window, &feed, anchor, 40);
        for ([_]u64{ 20, 30 }) |key| {
            try window.replace(.{ .position = key }, .{ .bytes = "ghijkl\n789012" });
            const entries = window.heights(test_layout);
            feed.replace(entries[window.indexOf(.{ .position = key }).?]);
            try expectAnchor(&window, &feed, anchor, 40);
        }
        try testing.expectEqualDeep(@as(?Key, .{ .position = 30 }), window.firstProvisional());
        try window.replaceFrom(.{ .position = 30 }, &.{ testEntry(30, "settle\n789012"), testEntry(50, "abcdef\n123456") });
        feed.append(window.heights(test_layout), 1, window.edges());
        try expectAnchor(&window, &feed, anchor, 50);
        try testing.expectEqual(@as(?Key, null), window.firstProvisional());
        try testing.expectEqual(@as(usize, 4), window.count);
    }
}

test "feed_window replace clamps through Feed and suffix replacement can remove rows" {
    var window: Window = .{};
    var provisional = testEntry(30, "a\nb\nc");
    provisional.provisional = true;
    try window.append(&.{ testEntry(20, "a\nb\nc"), provisional, testEntry(40, "last") });
    var feed: Feed = .{ .anchor = .{ .at = .{ .key = .{ .position = 20 }, .line = 2, .row = 2 } } };
    try window.replace(.{ .position = 20 }, .{ .bytes = "x" });
    feed.replace(window.heights(test_layout)[0]);
    // One text row and the adjacency gap: logical line remains zero.
    try testing.expectEqualDeep(Feed.Anchor{ .at = .{ .key = .{ .position = 20 }, .row = 1 } }, feed.anchor);
    try window.replaceFrom(.{ .position = 30 }, &.{});
    try testing.expectEqual(@as(usize, 1), window.count);
    try testing.expectEqualSlices(u32, &.{1}, window.heights(test_layout)[0].lines);
    try testing.expectEqualStrings("x\n", window.text(.{ .position = 20 }).bytes);
}

test "feed_window caps oversized rows at their head and counts omitted lines" {
    var window: Window = .{};
    const many: [20000][2]u8 = @splat("a\n".*);
    try window.append(&.{testEntry(10, std.mem.asBytes(&many))});
    const capped = window.text(.{ .position = 10 });
    try testing.expect(capped.bytes.len <= row_capacity);
    try testing.expect(std.mem.startsWith(u8, capped.bytes, "a\na\n"));
    try testing.expect(std.mem.endsWith(u8, capped.bytes, "┄ 3648 more lines\n"));
    try testing.expectEqual(@as(usize, 16353), window.heights(test_layout)[0].lines.len);
    const wide: [20000][3]u8 = @splat("界".*);
    try window.replace(.{ .position = 10 }, .{ .bytes = std.mem.asBytes(&wide) });
    const head = window.text(.{ .position = 10 });
    try testing.expect(head.bytes.len <= row_capacity);
    try testing.expect(std.unicode.utf8ValidateSlice(head.bytes));
    try testing.expect(std.mem.startsWith(u8, head.bytes, "界界"));
    try testing.expect(std.mem.endsWith(u8, head.bytes, "\n┄ 1 more lines\n"));
}

test "feed_window open keys survive trimming either edge and reloading" {
    var window: Window = .{};
    try window.append(&.{ testEntry(10, "old tool"), testEntry(20, "middle"), testEntry(30, "new tool") });
    window.at_start = true;
    window.at_end = true;
    window.low = .{ .position = 10 };
    window.high = .{ .position = 30 };
    for ([_]u64{ 10, 30 }) |position| window.setOpen(.{ .position = position }, true);
    window.trim(1, 1);
    try testing.expect(!window.at_start and !window.at_end);
    try testing.expectEqualDeep(@as(?Key, .{ .position = 20 }), window.low);
    try testing.expectEqualDeep(@as(?Key, .{ .position = 20 }), window.high);
    try window.prepend(&.{testEntry(10, "opened old tool")});
    try window.append(&.{testEntry(30, "opened new tool")});
    for ([_]u64{ 10, 30 }) |position| try testing.expect(window.isOpen(.{ .position = position }));
    window.trim(3, 0);
    try window.append(&.{testEntry(10, "opened again")});
    try testing.expect(window.isOpen(.{ .position = 10 }));
    window.setOpen(.{ .position = 10 }, false);
    try testing.expect(!window.isOpen(.{ .position = 10 }));
    // Same position, different ordinal is a distinct tool.
    window.setOpen(.{ .position = 30, .ordinal = 1 }, true);
    window.setOpen(.{ .position = 30 }, false);
    try testing.expect(window.isOpen(.{ .position = 30, .ordinal = 1 }));
    for (0..open_capacity) |i| window.setOpen(.{ .position = 100 + i }, true);
    try testing.expectEqual(open_capacity, window.opened_count);
    try testing.expect(!window.isOpen(.{ .position = 30, .ordinal = 1 }));
    for (0..open_capacity) |i| try testing.expect(window.isOpen(.{ .position = 100 + i }));
}

fn totalRows(entries: []const Feed.Entry) u64 {
    var rows: u64 = 0;
    for (entries) |entry| for (entry.lines) |count| {
        rows += count;
    };
    return rows;
}

test "feed_window byte and entry bounds retain three typical screens without ping-pong" {
    const typical: viewport.Layout = .{ .width = 140, .method = .unicode };
    const screen_rows = 40;
    const line: [80]u8 = (@as([79]u8, @splat('x')) ++ "\n").*;
    // Reach each independent cap with a typical layout, never an oversized row.
    for ([_]usize{ 1, 26 }) |lines| {
        var window: Window = .{};
        const repeated: [26][80]u8 = @splat(line);
        const bytes = std.mem.asBytes(&repeated);
        var position: u64 = 1;
        while (true) : (position += 1) {
            var entry = testEntry(position, bytes[0 .. lines * line.len]);
            entry.tight = true;
            window.append(&.{entry}) catch |err| {
                try testing.expectEqual(error.WindowFull, err);
                break;
            };
        }
        try testing.expect(window.document.length <= viewport.capacity);
        try testing.expect(window.count <= entry_capacity);
        try testing.expect(totalRows(window.heights(typical)) >= 3 * screen_rows);
        try testing.expect(if (lines == 1) window.count == entry_capacity else window.document.length + lines * line.len > byte_capacity);
        // Bounds errors, including failed suffix replacement, leave text intact.
        const count = window.count;
        const length = window.document.length;
        try testing.expectError(error.WindowFull, window.prepend(&.{testEntry(0, bytes)}));
        try testing.expectEqual(count, window.count);
        try testing.expectEqual(length, window.document.length);
    }
    // Feed.trim protects its three-screen margins. After trimming, the loading
    // policy does not immediately ask to reload what it just evicted.
    var window: Window = .{};
    for (0..entry_capacity) |i| {
        var entry = testEntry(i, &line);
        entry.tight = true;
        try window.append(&.{entry});
    }
    const feed: Feed = .{ .anchor = .{ .at = .{ .key = .{ .position = 256 } } } };
    const before = feed.visible(window.heights(typical), screen_rows);
    const drops = feed.trim(window.heights(typical), screen_rows, 280);
    try testing.expect(drops.drop_front != 0 and drops.drop_back != 0);
    window.trim(drops.drop_front, drops.drop_back);
    const entries = window.heights(typical);
    const after = feed.visible(entries, screen_rows);
    try testing.expectEqual(@as(u64, 256), entries[after.first].key.position);
    try testing.expectEqual(before.line, after.line);
    try testing.expectEqual(before.row, after.row);
    try testing.expectEqual(Feed.Need.none, feed.need(entries, screen_rows, window.edges()));
    try testing.expectEqualDeep(Feed.Trim{}, feed.trim(entries, screen_rows, 280));
}

const TestScreen = struct {
    screen: vaxis.Screen = undefined,
    cells: [40 * 16]vaxis.Cell = undefined,

    fn window(self: *TestScreen, width: u16, height: u16) vaxis.Window {
        @memset(&self.cells, .{});
        self.screen = .{ .width = width, .height = height, .width_method = .unicode, .buf = self.cells[0 .. @as(usize, width) * height] };
        return .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &self.screen };
    }

    fn row(self: *const TestScreen, index: u16, storage: []u8) []const u8 {
        var used: usize = 0;
        var column: u16 = 0;
        while (column < self.screen.width) {
            const cell = self.screen.readCell(column, index).?;
            @memcpy(storage[used..][0..cell.char.grapheme.len], cell.char.grapheme);
            used += cell.char.grapheme.len;
            column += @max(1, cell.char.width);
        }
        return std.mem.trimEnd(u8, storage[0..used], " ");
    }
};

test "feed_window gaps derive from all tight loose adjacencies across prepend seam" {
    for ([_]bool{ false, true }) |a| for ([_]bool{ false, true }) |b| for ([_]bool{ false, true }) |c| {
        var window: Window = .{};
        var first = testEntry(10, "A");
        first.tight = a;
        var second = testEntry(20, "B");
        second.tight = b;
        var third = testEntry(30, "C");
        third.tight = c;
        try window.append(&.{ second, third });
        try window.prepend(&.{first});
        try testing.expectEqualStrings("B\n", window.text(second.key).bytes);
        const entries = window.heights(.{ .width = 8, .method = .unicode });
        const ab: u32 = @intFromBool(!(a and b));
        const bc: u32 = @intFromBool(!(b and c));
        try testing.expectEqualSlices(u32, &.{1 + ab}, entries[0].lines);
        try testing.expectEqualSlices(u32, &.{1 + bc}, entries[1].lines);
        var screen: TestScreen = .{};
        var buf: [64]u8 = undefined;
        window.draw(.{ .first = 0 }, screen.window(8, 8), true, .{}, .{});
        try testing.expectEqualStrings("A", screen.row(0, &buf));
        if (ab != 0) try testing.expectEqualStrings("", screen.row(1, &buf));
        try testing.expectEqualStrings("B", screen.row(@intCast(1 + ab), &buf));
        if (bc != 0) try testing.expectEqualStrings("", screen.row(@intCast(2 + ab), &buf));
        try testing.expectEqualStrings("C", screen.row(@intCast(2 + ab + bc), &buf));
        // A visible range may begin in the predecessor's gap, not its text.
        if (ab != 0) {
            window.draw(.{ .first = 0, .row = 1 }, screen.window(8, 3), true, .{}, .{});
            try testing.expectEqualStrings("", screen.row(0, &buf));
            try testing.expectEqualStrings("B", screen.row(1, &buf));
        }
    };
}

test "feed_window heights at two widths match drawing and keep Document colours and links" {
    const terminal = @import("TerminalText.zig");
    var rendered: viewport.Sized(256, true) = .{};
    try rendered.append("\x1b[1m\x1b[91mabcdefgh\x1b[0m\n" ++ terminal.link_open ++ "https://r.dev" ++ terminal.link_end ++ "xy" ++ terminal.link_close);
    try rendered.prepare();
    var window: Window = .{};
    try window.append(&.{ .{ .key = .{ .position = 10 }, .text = Text.fromDocument(&rendered) }, testEntry(20, "tail") });
    var screen: TestScreen = .{};
    var buffer: [64]u8 = undefined;
    for ([_]u16{ 4, 8 }) |width| {
        const entries = window.heights(.{ .width = width, .method = .unicode });
        const wraps: u32 = if (width == 4) 2 else 1;
        try testing.expectEqualSlices(u32, &.{ wraps, 2 }, entries[0].lines);
        try testing.expectEqualSlices(u32, &.{1}, entries[1].lines);
        const failure: vaxis.Color = .{ .index = 1 };
        window.draw(.{ .first = 0 }, screen.window(width, 8), true, .{}, .{ .failure = failure });
        try testing.expectEqualStrings(if (width == 4) "abcd" else "abcdefgh", screen.row(0, &buffer));
        const cell = screen.screen.readCell(0, 0).?;
        try testing.expect(cell.style.bold);
        try testing.expectEqualDeep(failure, cell.style.fg);
        try testing.expectEqualStrings("xy", screen.row(@intCast(wraps), &buffer));
        try testing.expectEqualStrings("https://r.dev", screen.screen.readCell(0, @intCast(wraps)).?.link.uri);
        try testing.expectEqualStrings("", screen.row(@intCast(wraps + 1), &buffer));
        try testing.expectEqualStrings("tail", screen.row(@intCast(wraps + 2), &buffer));
        // Mid-logical-line clipping uses exactly the same wrapper as measuring.
        if (width == 4) {
            window.draw(.{ .first = 0, .row = 1 }, screen.window(width, 2), true, .{}, .{});
            try testing.expectEqualStrings("efgh", screen.row(0, &buffer));
            try testing.expectEqualStrings("xy", screen.row(1, &buffer));
        }
        const feed: Feed = .{};
        const visible = feed.visible(entries, 8);
        window.draw(visible, screen.window(width, 8), true, .{}, .{});
        try testing.expectEqualStrings("tail", screen.row(7, &buffer));
    }
}

test "feed_window variable length splices move text and styles together atomically" {
    var window: Window = .{};
    var rendered: viewport.Sized(64, true) = .{};
    try rendered.append("\x1b[33mC\x1b[0m");
    try rendered.prepare();
    try window.append(&.{ testEntry(20, "b"), .{ .key = .{ .position = 30 }, .text = Text.fromDocument(&rendered), .tight = true, .provisional = true } });
    try window.prepend(&.{testEntry(10, "a")});
    for ([_][]const u8{ "long\nmany", "z", "", "again" }) |replacement| {
        try window.replace(.{ .position = 20 }, .{ .bytes = replacement });
        const moved = window.text(.{ .position = 30 });
        try testing.expectEqualStrings("C\n", moved.bytes);
        try testing.expectEqualDeep(viewport.CellStyle{ .foreground = .attention }, viewport.cellStyle(moved.styles[0], true));
        try testing.expect(window.entries[2].tight and window.entries[2].provisional);
    }
    const huge: [row_capacity]u8 = @splat('x');
    try testing.expectError(error.WindowFull, window.replaceFrom(.{ .position = 30 }, &.{ testEntry(30, &huge), testEntry(40, &huge), testEntry(50, &huge) }));
    try testing.expectEqual(@as(usize, 3), window.count);
    try testing.expectEqualDeep(@as(?Key, .{ .position = 30 }), window.firstProvisional());
    try testing.expectEqualStrings("a\n", window.text(.{ .position = 10 }).bytes);
    try testing.expectEqualStrings("again\n", window.text(.{ .position = 20 }).bytes);
    try testing.expectEqualStrings("C\n", window.text(.{ .position = 30 }).bytes);
    try window.replaceFrom(.{ .position = 30 }, &.{ testEntry(30, "settled"), testEntry(50, "e") });
    window.trim(1, 1);
    try testing.expectEqualStrings("again\n", window.text(.{ .position = 20 }).bytes);
    try testing.expectEqualStrings("settled\n", window.text(.{ .position = 30 }).bytes);
}

test "feed_window worst case newline scratch exact row cap empty edits and wide ordinals" {
    var window: Window = .{};
    try window.prepend(&.{});
    try window.append(&.{});
    window.trim(0, 0);
    try testing.expectEqual(@as(usize, 0), window.heights(test_layout).len);
    const blank: [row_capacity]u8 = @splat('\n');
    try window.append(&.{
        .{ .key = .{ .position = 5, .ordinal = 1 }, .text = .{ .bytes = &blank }, .tight = true },
        .{ .key = .{ .position = 5, .ordinal = std.math.maxInt(u64) - 1 }, .text = .{ .bytes = &blank }, .tight = true },
        .{ .key = .{ .position = 5, .ordinal = std.math.maxInt(u64) }, .text = .{ .bytes = blank[0 .. byte_capacity - 2 * row_capacity] }, .tight = true },
    });
    try testing.expectEqual(byte_capacity, window.document.length);
    const entries = window.heights(test_layout);
    try testing.expectEqual(@as(u64, byte_capacity), totalRows(entries));
    try testing.expectEqual(row_capacity, entries[0].lines.len);
    try testing.expectEqual(row_capacity, entries[1].lines.len);
    try testing.expectError(error.WindowFull, window.replace(.{ .position = 5, .ordinal = std.math.maxInt(u64) }, .{ .bytes = &blank }));
    try testing.expectEqual(byte_capacity, window.document.length);
    // Cursor facts can refer to filtered rows absent from the resident table.
    window.low = .{ .position = 1 };
    window.high = .{ .position = 9 };
    try window.append(&.{});
    try testing.expectEqualDeep(@as(?Key, .{ .position = 1 }), window.low);
    try testing.expectEqualDeep(@as(?Key, .{ .position = 9 }), window.high);
}

test "feed_window preserves every Document foreground slot through prepend replace and trim" {
    const cases = .{
        .{ "\x1b[33m", viewport.CellStyle{ .foreground = .attention } },
        .{ "\x1b[90m", viewport.CellStyle{ .foreground = .quiet } },
        .{ "\x1b[91m", viewport.CellStyle{ .foreground = .failure } },
        .{ "\x1b[94m", viewport.CellStyle{ .foreground = .user } },
    };
    inline for (cases) |case| {
        var rendered: viewport.Sized(64, true) = .{};
        try rendered.append(case[0] ++ "X\x1b[0m");
        try rendered.prepare();
        var window: Window = .{};
        try window.append(&.{.{ .key = .{ .position = 20 }, .text = Text.fromDocument(&rendered) }});
        try window.prepend(&.{testEntry(10, "before")});
        try window.replace(.{ .position = 10 }, .{ .bytes = "longer before" });
        window.trim(1, 0);
        const text = window.text(.{ .position = 20 });
        try testing.expectEqualDeep(case[1], viewport.cellStyle(text.styles[0], true));
    }
}
