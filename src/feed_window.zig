//! Rui's resident feed text. Feed owns the anchor; this owner owns text,
//! page-edge facts and the bounded set of opened tools.
const std = @import("std");
const vaxis = @import("vaxis");
const unicode = @import("terminal_unicode");
const viewport = @import("ConversationViewport.zig");
const View = @import("session_view.zig");

pub const Key = struct {
    position: u64,
    ordinal: u64 = 0,

    pub fn order(a: Key, b: Key) std.math.Order {
        const primary = std.math.order(a.position, b.position);
        return if (primary == .eq) std.math.order(a.ordinal, b.ordinal) else primary;
    }
};
/// Stable byte position within a retained row, independent of page seams.
pub const Point = struct { key: Key, offset: usize };
pub const MessageTarget = struct { offset: usize, target: View.Collapsed };
pub const tail_key: Key = .{ .position = std.math.maxInt(u64), .ordinal = std.math.maxInt(u64) };
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
    messages: []const MessageTarget = &.{},
};

/// One row's bound, applied twice for two reasons: the reader bounds the
/// bytes it renders (session_reads.RowCapture, which keeps the Ctrl-O target),
/// and the window bounds the prepared text, which display escaping can grow.
pub const row_capacity = 32 * 1024;
pub const entry_capacity = 512;
// Text, styles, one u32 per byte for newline-only text and the entry, layout
// and target tables together fit the old styled Document's footprint. Two
// full rows fit, and 512 one-line entries cover more than three 140x40
// screens, so neither a large row nor many tiny ones makes loading and
// eviction ping-pong.
pub const byte_capacity = 65 * 1024;
/// The tool rows the person opened, by key. A row renders with its output
/// while its key is here, so it stays open across trimming and reloading.
/// Holds at most 64 and never forgets one: a full set refuses another
/// opening, so the set and the rows' text cannot disagree. Closing releases
/// a slot.
pub const Opened = struct {
    pub const capacity = 64;
    keys: [capacity]Key = undefined,
    count: usize = 0,

    pub fn has(self: *const Opened, key: Key) bool {
        for (self.keys[0..self.count]) |item| if (item.order(key) == .eq) return true;
        return false;
    }

    pub fn full(self: *const Opened) bool {
        return self.count == capacity;
    }

    /// The caller asks `full` before opening another row.
    pub fn set(self: *Opened, key: Key, open: bool) void {
        for (self.keys[0..self.count], 0..) |item, i| {
            if (item.order(key) != .eq) continue;
            if (!open) {
                std.mem.copyForwards(Key, self.keys[i..], self.keys[i + 1 .. self.count]);
                self.count -= 1;
            }
            return;
        }
        if (!open) return;
        std.debug.assert(!self.full());
        self.keys[self.count] = key;
        self.count += 1;
    }
};

pub const LatestEnding = @import("feed_reads.zig").Ending(Key);
/// Padding on a synthetic-only wrapped row has no resident text to select.
pub const RetryHit = union(enum) { link: Key, padding };
pub const Presentation = struct {
    latest_ending: ?LatestEnding = null,
    retry_actionable: bool = false,
};

// Only the short, shared ending line is decorated, not arbitrary Message text.
// This is frame-local presentation; no bytes/styles are written to Window.
const EndingLine = struct {
    key_start: usize = 0,
    key_end: usize = 0,
    document: viewport.Sized(512, true) = .{ .dirty = false, .sidenotes = true, .quotes = true },

    fn init(self: *EndingLine, window: *const Window, entry: Window.Stored, offset: usize, presentation: Presentation) bool {
        if (!presentation.retry_actionable) return false;
        const latest = presentation.latest_ending orelse return false;
        if (!latest.matches(entry.key)) return false;
        const key = latest.cause.key orelse return false;
        const end = window.document.lineEnd(offset);
        if (end + 1 != entry.offset + entry.length) return false;
        const suffix = " · ";
        const length = end - offset + suffix.len + key.len;
        // Ending words and key strings come from marks, never content bytes.
        std.debug.assert(length < self.document.bytes.len);
        const head = end - offset;
        self.key_start = head + suffix.len;
        self.key_end = length;
        @memcpy(self.document.bytes[0..head], window.document.bytes[offset..end]);
        @memcpy(self.document.styles[0..head], window.document.styles[offset..end]);
        @memcpy(self.document.bytes[head..][0..suffix.len], suffix);
        @memcpy(self.document.bytes[head + suffix.len ..][0..key.len], key);
        @memset(self.document.styles[head..length], 0);
        self.document.bytes[length] = '\n';
        self.document.styles[length] = 0;
        self.document.length = length + 1;
        self.document.width_method = window.document.width_method;
        return true;
    }

    /// Paint exactly the wrapped row drawWith paints, then ask that same
    /// document which byte owns the cell. Margins/indent and the ending's
    /// words are not part of the retry link.
    fn hit(self: *const EndingLine, row: u16, cells: []vaxis.Cell, col: usize) bool {
        if (col >= cells.len) return false;
        self.paint(row, cells);
        return self.linked(cells[col]);
    }

    fn paint(self: *const EndingLine, row: u16, cells: []vaxis.Cell) void {
        @memset(cells, .{});
        var screen: vaxis.Screen = .{ .width = @intCast(cells.len), .height = 1, .width_method = self.document.width_method, .buf = cells };
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.width, .height = 1, .screen = &screen };
        _ = self.document.draw(window, .{ .row = row }, true, false, .{}, .{});
    }

    fn linked(self: *const EndingLine, cell: vaxis.Cell) bool {
        const offset = self.document.cellOffset(cell) orelse return false;
        return offset >= self.key_start and offset < self.key_end;
    }
};

pub const Window = struct {
    const Document = viewport.Sized(byte_capacity, true);
    const Target = struct { point: Point, target: View.Collapsed };
    pub const Stored = struct {
        key: Key,
        offset: usize,
        length: usize,
        tight: bool,
        provisional: bool,
    };

    document: Document = .{ .dirty = false, .sidenotes = true, .quotes = true },
    entries: [entry_capacity]Stored = undefined,
    count: usize = 0,
    opened: Opened = .{},
    // Page cursors are facts, not aliases for rendered row keys: filtered or
    // empty pages can advance them without adding any rendered text.
    at_start: bool = false,
    at_end: bool = false,
    forward_partial: bool = false,
    low: ?Key = null,
    high: ?Key = null,
    // Borrowed layout output; rebuilt, never cached. Every stored entry has a
    // terminating newline, so there cannot be more logical lines than bytes.
    dimensions: [entry_capacity + 1]Feed.Entry = undefined,
    // Last measured activity Widget, never a stored/keyed conversation row.
    tail_rows: u32 = 0,
    tail_lines: [1]u32 = undefined,
    targets: [entry_capacity]Target = undefined,
    target_count: usize = 0,
    line_rows: [byte_capacity]u32 = undefined,

    pub const Error = error{WindowFull};

    pub fn edges(self: *const Window) Feed.Edges {
        return .{ .start = self.at_start, .end = self.at_end };
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
            self.forward_partial = false;
            self.high = if (self.count != 0) self.entries[self.count - 1].key else null;
        }
        var kept: usize = 0;
        for (self.targets[0..self.target_count]) |target| if (self.indexOf(target.point.key) != null) {
            self.targets[kept] = target;
            kept += 1;
        };
        self.target_count = kept;
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
        return self.heightsWith(layout, .{});
    }

    pub fn heightsWith(self: *Window, layout: viewport.Layout, presentation: Presentation) []const Feed.Entry {
        self.document.width_method = layout.method;
        var used: usize = 0;
        for (self.entries[0..self.count], 0..) |entry, i| {
            const start = used;
            var offset = entry.offset;
            const end = offset + entry.length;
            while (offset < end) {
                self.line_rows[used] = if (layout.width == 0) 1 else self.lineRows(entry, layout, offset, presentation);
                used += 1;
                offset = self.document.lineEnd(offset) + 1;
            }
            if (used > start) self.line_rows[used - 1] += self.gapAfter(i);
            self.dimensions[i] = .{ .key = entry.key, .lines = self.line_rows[start..used] };
        }
        return self.dimensions[0..self.count];
    }

    /// Includes the unkeyed Widget tail only for layout/scroll/read policy.
    /// The synthetic key is never persisted, targeted or counted as a row.
    pub fn layoutEntries(self: *Window, layout: viewport.Layout) []const Feed.Entry {
        return self.layoutEntriesWith(layout, .{});
    }

    pub fn layoutEntriesWith(self: *Window, layout: viewport.Layout, presentation: Presentation) []const Feed.Entry {
        _ = self.heightsWith(layout, presentation);
        if (self.tail_rows == 0) return self.dimensions[0..self.count];
        self.tail_lines[0] = self.tail_rows;
        self.dimensions[self.count] = .{ .key = tail_key, .lines = &self.tail_lines };
        return self.dimensions[0 .. self.count + 1];
    }

    pub fn lineRows(self: *const Window, entry: Stored, layout: viewport.Layout, offset: usize, presentation: Presentation) u16 {
        var ending: EndingLine = .{};
        return if (ending.init(self, entry, offset, presentation)) ending.document.lineRows(layout, 0) else self.document.lineRows(layout, offset);
    }

    pub fn pointAt(self: *const Window, offset: usize) ?Point {
        for (self.entries[0..self.count]) |entry| {
            if (offset >= entry.offset and offset < entry.offset + entry.length)
                return .{ .key = entry.key, .offset = offset - entry.offset };
        }
        if (self.count > 0 and offset == self.document.length) {
            const last = self.entries[self.count - 1];
            return .{ .key = last.key, .offset = last.length };
        }
        return null;
    }

    /// Edits may shorten a row; a surviving keyed endpoint clamps to its end.
    pub fn offsetOf(self: *const Window, point: Point) ?usize {
        const entry = self.entries[self.indexOf(point.key) orelse return null];
        return entry.offset + @min(point.offset, entry.length);
    }

    /// The tool row whose heading line holds this point.
    pub fn toolAt(self: *const Window, point: Point) ?Key {
        const offset = self.offsetOf(point) orelse return null;
        const entry = self.entries[self.indexOf(point.key).?];
        var line = offset;
        while (line > entry.offset and self.document.bytes[line - 1] != '\n') : (line -= 1) {}
        return if (self.document.toolHeading(line)) point.key else null;
    }

    pub fn messageAt(self: *const Window, point: Point) ?View.Collapsed {
        const offset = self.offsetOf(point) orelse return null;
        const entry = self.entries[self.indexOf(point.key).?];
        // Only summary rows are Message targets. A click elsewhere in the
        // entry must not open its last Message (stops can contain many).
        const end = self.document.lineEnd(offset);
        var line = offset;
        while (line > entry.offset and self.document.bytes[line - 1] != '\n') : (line -= 1) {}
        const mark = self.document.collapsed(line, end).last orelse return null;
        for (self.targets[0..self.target_count]) |target| {
            if (target.point.key.order(point.key) == .eq and entry.offset + target.point.offset == mark)
                return target.target;
        }
        return null;
    }

    /// A synthetic retry link uses EndingLine's own drawing/layout, never a
    /// resident-text offset. The caller lends one pane-width row of cells.
    pub fn retryAt(self: *const Window, position: viewport.Position, cells: []vaxis.Cell, col: usize, presentation: Presentation) ?RetryHit {
        if (cells.len == 0) return null;
        const point = self.pointAt(position.offset) orelse return null;
        const entry = self.entries[self.indexOf(point.key) orelse return null];
        var ending: EndingLine = .{};
        if (!ending.init(self, entry, position.offset, presentation)) return null;
        if (ending.hit(position.row, cells, col)) return .{ .link = entry.key };
        const layout: viewport.Layout = .{ .width = @intCast(cells.len), .method = self.document.width_method };
        return if (position.row >= self.document.lineRows(layout, position.offset)) .padding else null;
    }

    /// The painted retry suffix's columns, shared by hover and the click query.
    /// `cells` is one pane-width scratch row; no resident offsets are invented.
    pub fn retryColumns(self: *const Window, position: viewport.Position, cells: []vaxis.Cell, presentation: Presentation) ?struct { start: u16, end: u16 } {
        if (cells.len == 0) return null;
        const point = self.pointAt(position.offset) orelse return null;
        const entry = self.entries[self.indexOf(point.key) orelse return null];
        var ending: EndingLine = .{};
        if (!ending.init(self, entry, position.offset, presentation)) return null;
        ending.paint(position.row, cells);
        var start: ?u16 = null;
        var end: u16 = 0;
        for (cells, 0..) |cell, col| if (ending.linked(cell)) {
            if (start == null) start = @intCast(col);
            end = @intCast(col + 1);
        };
        return .{ .start = start orelse return null, .end = end };
    }

    /// Logical text row beneath the pointer, excluding adjacency gaps/tail.
    pub fn positionAt(self: *const Window, visible: Feed.Visible, row: u32, layout: viewport.Layout) ?viewport.Position {
        return self.positionAtWith(visible, row, layout, .{});
    }

    pub fn positionAtWith(self: *const Window, visible: Feed.Visible, row: u32, layout: viewport.Layout, presentation: Presentation) ?viewport.Position {
        if (row < visible.pad or visible.first >= self.count) return null;
        var wanted = row - visible.pad;
        for (self.entries[visible.first..self.count], visible.first..) |entry, i| {
            var offset = entry.offset;
            var line: u32 = 0;
            while (offset < entry.offset + entry.length) : (line += 1) {
                const next = self.document.lineEnd(offset) + 1;
                if (i != visible.first or line >= visible.line) {
                    const skip = if (i == visible.first and line == visible.line) visible.row else 0;
                    const rows = self.lineRows(entry, layout, offset, presentation) - skip;
                    if (wanted < rows) return .{ .offset = offset, .row = @intCast(wanted + skip) };
                    wanted -= rows;
                    if (next == entry.offset + entry.length and self.gapAfter(i) != 0) {
                        if (wanted == 0) return null;
                        wanted -= 1;
                    }
                }
                offset = next;
            }
        }
        return null;
    }

    /// Feed.Visible must have been obtained at this window's current width and
    /// width method. The supplied vaxis window is already the shell's feed pane.
    pub fn draw(self: *const Window, visible: Feed.Visible, window: vaxis.Window, colour: bool, plain: vaxis.Style, colours: viewport.Colours) void {
        self.drawWith(visible, window, colour, plain, colours, .{}, null) catch unreachable;
    }

    /// Arena retains decorated graphemes through rendering; null is valid only
    /// for undecorated drawing (the allocation-free draw wrapper).
    pub fn drawWith(self: *const Window, visible: Feed.Visible, window: vaxis.Window, colour: bool, plain: vaxis.Style, colours: viewport.Colours, presentation: Presentation, arena: ?std.mem.Allocator) !void {
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
                    var ending: EndingLine = .{};
                    const top: i17 = @intCast(row - @as(i32, @intCast(skip)));
                    const height = if (ending.init(self, entry, offset, presentation)) decorated: {
                        // Cells borrow graphemes through Surface.render, beyond
                        // this call. Exactly one decorated line per frame.
                        const held = try arena.?.create(EndingLine);
                        held.* = ending;
                        break :decorated held.document.printLine(window, top, 0, true, colour, plain, colours);
                    } else self.document.printLine(window, top, offset, true, colour, plain, colours);
                    row += @as(i32, height) - @as(i32, @intCast(skip));
                    if (next == end) row += self.gapAfter(i);
                }
                offset = next;
            }
        }
    }

    pub fn gapAfter(self: *const Window, index: usize) u1 {
        if (self.entries[index].length == 0) return 0;
        var next = index + 1;
        while (next < self.count and self.entries[next].length == 0) : (next += 1) {}
        return @intFromBool(next < self.count and !(self.entries[index].tight and self.entries[next].tight));
    }

    pub fn indexOf(self: *const Window, key: Key) ?usize {
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
        const marker = std.fmt.bufPrint(&result.marker, "{s}┄ {d} more line{s}\n", .{ if (head != 0 and bytes[head - 1] == '\n') "" else "\n", hidden, if (hidden == 1) "" else "s" }) catch unreachable;
        result.marker_length = marker.len;
        result.length = head + marker.len;
        return result;
    }

    fn entryPlan(entry: Entry) Plan {
        if (entry.provisional and entry.text.bytes.len == 0) return .{ .head = 0, .length = 0 };
        return plan(entry.text);
    }

    fn splice(self: *Window, first: usize, remove: usize, incoming: []const Entry) Error!void {
        const count = self.count - remove + incoming.len;
        if (count > entry_capacity) return error.WindowFull;
        const old_start = if (first < self.count) self.entries[first].offset else self.document.length;
        const old_end = if (first + remove < self.count) self.entries[first + remove].offset else self.document.length;
        var added: usize = 0;
        for (incoming, 0..) |entry, i| {
            if (i != 0) std.debug.assert(incoming[i - 1].key.order(entry.key) == .lt);
            added += entryPlan(entry).length;
        }
        if (incoming.len != 0) {
            if (first != 0) std.debug.assert(self.entries[first - 1].key.order(incoming[0].key) == .lt);
            if (first + remove < self.count) std.debug.assert(incoming[incoming.len - 1].key.order(self.entries[first + remove].key) == .lt);
        }
        const length = self.document.length - (old_end - old_start) + added;
        if (length > byte_capacity) return error.WindowFull;
        // Text and all its actionable targets share this capacity decision.
        // Reject before mutating, just as for byte/entry capacity; callers may
        // trim and retry the complete entry instead of orphaning its summaries.
        var targets_needed: usize = 0;
        for (self.targets[0..self.target_count]) |target| {
            const index = self.indexOf(target.point.key) orelse continue;
            if (index < first or index >= first + remove) targets_needed += 1;
        }
        for (incoming) |entry| {
            const p = entryPlan(entry);
            for (entry.messages) |target| {
                if (target.offset < p.head) targets_needed += 1;
            }
        }
        if (targets_needed > self.targets.len) return error.WindowFull;
        var kept_targets: usize = 0;
        for (self.targets[0..self.target_count]) |target| {
            const index = self.indexOf(target.point.key) orelse continue;
            if (index >= first and index < first + remove) continue;
            self.targets[kept_targets] = target;
            kept_targets += 1;
        }
        self.target_count = kept_targets;
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
            const p = entryPlan(entry);
            @memcpy(self.document.bytes[offset..][0..p.head], entry.text.bytes[0..p.head]);
            if (entry.text.styles.len != 0) @memcpy(self.document.styles[offset..][0..p.head], entry.text.styles[0..p.head]) else @memset(self.document.styles[offset..][0..p.head], 0);
            if (p.marker_length != 0) {
                @memcpy(self.document.bytes[offset + p.head ..][0..p.marker_length], p.marker[0..p.marker_length]);
                @memset(self.document.styles[offset + p.head ..][0..p.marker_length], 0);
            } else if (p.length > p.head) {
                self.document.bytes[offset + p.head] = '\n';
                self.document.styles[offset + p.head] = 0;
            }
            // End link runs at the seam, but preserve a code newline's band.
            if (p.length > 0) {
                const last = offset + p.length - 1;
                self.document.styles[last] = viewport.seamStyle(self.document.styles[last]);
            }
            self.entries[first + i] = .{ .key = entry.key, .offset = offset, .length = p.length, .tight = entry.tight, .provisional = entry.provisional };
            for (entry.messages) |target| {
                // Oversized rows are capped; targets in omitted text disappear
                // with their summaries. Capacity was checked before mutation.
                if (target.offset >= p.head) continue;
                self.targets[self.target_count] = .{ .point = .{ .key = entry.key, .offset = target.offset }, .target = target.target };
                self.target_count += 1;
            }
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
    try testing.expect(std.mem.endsWith(u8, head.bytes, "\n┄ 1 more line\n"));
}

test "feed_window open keys survive trimming either edge and reloading" {
    var window: Window = .{};
    try window.append(&.{ testEntry(10, "old tool"), testEntry(20, "middle"), testEntry(30, "new tool") });
    window.at_start = true;
    window.at_end = true;
    window.low = .{ .position = 10 };
    window.high = .{ .position = 30 };
    for ([_]u64{ 10, 30 }) |position| window.opened.set(.{ .position = position }, true);
    window.trim(1, 1);
    try testing.expect(!window.at_start and !window.at_end);
    try testing.expectEqualDeep(@as(?Key, .{ .position = 20 }), window.low);
    try testing.expectEqualDeep(@as(?Key, .{ .position = 20 }), window.high);
    try window.prepend(&.{testEntry(10, "opened old tool")});
    try window.append(&.{testEntry(30, "opened new tool")});
    for ([_]u64{ 10, 30 }) |position| try testing.expect(window.opened.has(.{ .position = position }));
    window.trim(3, 0);
    try window.append(&.{testEntry(10, "opened again")});
    try testing.expect(window.opened.has(.{ .position = 10 }));
    window.opened.set(.{ .position = 10 }, false);
    try testing.expect(!window.opened.has(.{ .position = 10 }));
    // Same position, different ordinal is a distinct tool.
    window.opened.set(.{ .position = 30, .ordinal = 1 }, true);
    window.opened.set(.{ .position = 30 }, false);
    try testing.expect(window.opened.has(.{ .position = 30, .ordinal = 1 }));
    // A full set says so and keeps every key; closing one makes room.
    var position: u64 = 100;
    while (!window.opened.full()) : (position += 1) window.opened.set(.{ .position = position }, true);
    try testing.expectEqual(Opened.capacity, window.opened.count);
    try testing.expect(window.opened.has(.{ .position = 30, .ordinal = 1 }));
    window.opened.set(.{ .position = 100 }, false);
    try testing.expect(!window.opened.full());
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

test "feed_window styled newline drawing parity for every splice" {
    const plain: vaxis.Style = .{ .bg = .{ .index = 19 } };
    const colours: viewport.Colours = .{ .band = .{ .rgb = .{ 28, 29, 35 } } };
    for ([_][]const u8{ "\x1b[40m\n\x1b[0m", "\x1b[40mcode\n\x1b[0m" }) |input| {
        var source: viewport.Sized(256, true) = .{};
        try source.append(input);
        try source.prepare();
        for (0..4) |operation| {
            var window: Window = .{};
            const entry: Entry = .{ .key = .{ .position = 10 }, .text = Text.fromDocument(&source) };
            switch (operation) {
                0 => try window.append(&.{entry}),
                1 => try window.prepend(&.{entry}),
                2 => {
                    try window.append(&.{testEntry(10, "old")});
                    try window.replace(entry.key, entry.text);
                },
                3 => {
                    var old = testEntry(10, "old");
                    old.provisional = true;
                    try window.append(&.{old});
                    try window.replaceFrom(entry.key, &.{entry});
                },
                else => unreachable,
            }
            _ = window.heights(.{ .width = 8, .method = .unicode });
            for ([_]bool{ false, true }) |colour| {
                var expected: TestScreen = .{};
                const target = expected.window(8, 3);
                target.fill(.{ .style = plain });
                _ = source.draw(target, .{}, true, colour, plain, colours);
                var actual: TestScreen = .{};
                window.draw(.{ .first = 0 }, actual.window(8, 3), colour, plain, colours);
                for (0..3) |row| for (0..8) |column| {
                    const a = actual.screen.readCell(@intCast(column), @intCast(row)).?;
                    const b = expected.screen.readCell(@intCast(column), @intCast(row)).?;
                    try testing.expectEqualStrings(b.char.grapheme, a.char.grapheme);
                    try testing.expectEqualDeep(b.style, a.style);
                };
            }
        }
    }
}

test "feed_window invisible provisional keys own replay without adding rows or adjacency gaps" {
    const window = try testing.allocator.create(Window);
    defer testing.allocator.destroy(window);
    window.* = .{};
    try window.append(&.{
        .{ .key = .{ .position = 10 }, .text = .{ .bytes = "a\n" }, .tight = true },
        .{ .key = .{ .position = 20 }, .text = .{ .bytes = "" }, .provisional = true },
        .{ .key = .{ .position = 30 }, .text = .{ .bytes = "" }, .provisional = true },
        .{ .key = .{ .position = 40 }, .text = .{ .bytes = "b\n" }, .tight = true, .provisional = true },
    });
    try testing.expectEqualDeep(@as(?Key, .{ .position = 20 }), window.firstProvisional());
    try testing.expectEqual(@as(u64, 2), totalRows(window.heights(test_layout)));
    try testing.expectEqual(@as(usize, 0), window.heights(test_layout)[1].lines.len);
    window.forward_partial = true;
    try window.replaceFrom(.{ .position = 20 }, &.{testEntry(20, "z")});
    try testing.expect(window.firstProvisional() == null);
    try testing.expectEqual(@as(u64, 3), totalRows(window.heights(test_layout)));
    window.trim(0, 1);
    try testing.expect(!window.forward_partial);
    try testing.expectEqual(@as(usize, 1), window.count);
}

test "feed_window target capacity admits whole entries atomically across trim reload and replacement" {
    const window = try testing.allocator.create(Window);
    defer testing.allocator.destroy(window);
    window.* = .{};
    var prepared: viewport.Sized(1024, true) = .{};
    var targets: [16]MessageTarget = undefined;
    const reference: View.Collapsed = .{ .source = .activity, .position = 1, .ordinal = 0, .content = .{ .length = 99, .digest = @splat(7) }, .row = false };
    for (&targets, 0..) |*target, index| {
        target.* = .{ .offset = index * "┄\n".len, .target = reference };
        try prepared.append(View.Mark.summary ++ "┄" ++ View.Mark.reset ++ "\n");
    }
    try prepared.prepare();
    for (0..32) |index| {
        for (&targets, 0..) |*target, ordinal| {
            target.target.position = 1000 + index * targets.len + ordinal;
            target.target.ordinal = ordinal;
        }
        try window.append(&.{.{ .key = .{ .position = index + 1 }, .text = Text.fromDocument(&prepared), .messages = &targets }});
    }
    try testing.expectEqual(@as(usize, 512), window.target_count);
    const length = window.document.length;
    const last = window.messageAt(.{ .key = .{ .position = 32 }, .offset = targets[15].offset }).?;
    try testing.expectEqual(@as(u64, 1511), last.position);
    const next: Entry = .{ .key = .{ .position = 33 }, .text = Text.fromDocument(&prepared), .messages = &targets, .provisional = true };
    try testing.expectError(error.WindowFull, window.append(&.{next}));
    try testing.expectError(error.WindowFull, window.prepend(&.{.{ .key = .{ .position = 0 }, .text = Text.fromDocument(&prepared), .messages = &targets }}));
    try testing.expectEqual(@as(usize, 32), window.count);
    try testing.expectEqual(length, window.document.length);
    try testing.expectEqual(@as(usize, 512), window.target_count);
    try testing.expectEqualDeep(last, window.messageAt(.{ .key = .{ .position = 32 }, .offset = targets[15].offset }).?);
    // Release exactly one entry's targets, then reload another complete entry.
    window.trim(1, 0);
    try testing.expect(window.messageAt(.{ .key = .{ .position = 1 }, .offset = 0 }) == null);
    try testing.expectEqual(@as(usize, 496), window.target_count);
    try window.append(&.{next});
    try testing.expectEqual(@as(usize, 512), window.target_count);
    // Failed suffix replacement also leaves the old text/targets provisional.
    const before_replacement = window.document.length;
    try testing.expectError(error.WindowFull, window.replaceFrom(next.key, &.{ next, .{ .key = .{ .position = 34 }, .text = Text.fromDocument(&prepared), .messages = &targets } }));
    try testing.expectEqual(before_replacement, window.document.length);
    try testing.expectEqualDeep(@as(?Key, next.key), window.firstProvisional());
    try testing.expectEqual(@as(usize, 512), window.target_count);
    // Replacing a provisional suffix reuses its old budget, not a second one.
    targets[0].target.position = 9000;
    try window.replaceFrom(next.key, &.{.{ .key = next.key, .text = Text.fromDocument(&prepared), .messages = &targets }});
    try testing.expectEqual(@as(usize, 512), window.target_count);
    try testing.expectEqual(@as(u64, 9000), window.messageAt(.{ .key = next.key, .offset = 0 }).?.position);
    window.trim(0, 1);
    try testing.expect(window.messageAt(.{ .key = next.key, .offset = 0 }) == null);
    try window.prepend(&.{.{ .key = .{ .position = 1 }, .text = Text.fromDocument(&prepared), .messages = &targets }});
    try testing.expectEqual(@as(usize, 512), window.target_count);
    try testing.expectEqual(@as(u64, 9000), window.messageAt(.{ .key = .{ .position = 1 }, .offset = 0 }).?.position);
}
