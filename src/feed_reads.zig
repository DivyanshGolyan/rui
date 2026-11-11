//! The idle feed reader's policy, not its thread or storage. The shell passes
//! Feed.need(), edge cursors, the scan's own cursor/deadline and current time.
//! Asked-for inspections, Message pages and recall still precede this policy.
const std = @import("std");
const reading = @import("session_reading.zig");
const activity = @import("activity_read.zig");
const feed = @import("widgets/Feed.zig");

/// Only an applied opening or scan advances this deadline. A fill or permission
/// read must leave it alone: otherwise back-to-back fills could defer scans
/// forever even though nextRead gives due scans priority. Reuse today's 250 ms
/// interval and /status exception.
pub const scanDue = reading.scanDue;
pub const scan_interval_ns = reading.scan_interval_ns;

/// A scan-owned live fact, independent of resident rows. Cause strings borrow
/// the shared marks table (never a page or renderer buffer).
pub fn Ending(comptime Key: type) type {
    return struct {
        key: Key,
        cause: @import("marks.zig").Cause,

        pub fn matches(self: @This(), key: Key) bool {
            return std.meta.eql(self.key, key);
        }
    };
}

pub const Read = enum {
    opening,
    scan,
    fill_above,
    fill_below,
    permission,
};

/// Generic only in the cursor value: the frontend can use its window's Key
/// without this pure policy importing the window's text/layout owner. Cursor
/// equality includes every field (not just position: ordinals matter).
pub fn Policy(comptime Cursor: type) type {
    return struct {
        pub const State = struct {
            /// Until the opening lands, no scan, fill or permission starts.
            opening: bool,
            now_ns: i96,
            scan_due_ns: i96,
            need: feed.Feed(Cursor).Need = .none,
            at_end: bool,
            low: ?Cursor = null,
            high: ?Cursor = null,
            scan: Cycle = .{},
            window_provisional: ?Cursor = null,
            window_continuing: bool = false,
            /// A press holds the same read exclusion as an active drag.
            selection_held: bool = false,
            action_named: bool = false,
            choice_open: bool = false,
            submission: bool = false,
            fills: Fills = .{},

            /// The only projection of the current loading need to its edge.
            pub fn demand(self: State) ?Demand {
                return switch (self.need) {
                    .above => .{ .above = self.low },
                    .below => if (!self.at_end) .{ .below = self.high } else null,
                    .none => null,
                };
            }
        };

        pub const Demand = union(enum) { above: ?Cursor, below: ?Cursor };

        /// A failed request's identity, not a second owner of current edges.
        /// Time, live scans and selection release alone cannot retry it.
        pub const Fills = struct {
            blocked: ?Demand = null,

            pub fn failed(self: Fills, read: Read, page: Page) Fills {
                return .{ .blocked = switch (read) {
                    .fill_above => .{ .above = page.started_from },
                    .fill_below => .{ .below = page.started_from },
                    else => return self,
                } };
            }

            pub fn observe(self: Fills, state: State) Fills {
                return if (state.opening or !std.meta.eql(self.blocked, state.demand())) .{} else self;
            }

            pub fn scrolled(self: Fills, state: State, down: bool) Fills {
                const current = self.observe(state);
                const blocked = current.blocked orelse return current;
                const toward = switch (blocked) {
                    .above => !down,
                    .below => down,
                };
                return if (toward) .{} else current;
            }

            pub fn allows(self: Fills, state: State) bool {
                return self.blocked == null or !std.meta.eql(self.blocked, state.demand());
            }
        };

        /// One reader: opening and due live facts first, then approval,
        /// then eligible historical work. A broken edge cannot starve either.
        pub fn nextRead(state: State) ?Read {
            if (state.opening) return .opening;
            if (state.now_ns >= state.scan_due_ns) return .scan;
            if (state.action_named and !state.choice_open and !state.submission) return .permission;
            if (state.selection_held or !state.fills.allows(state)) return null;
            return if (state.demand()) |demand| switch (demand) {
                .above => .fill_above,
                .below => .fill_below,
            } else null;
        }

        pub const Page = struct {
            direction: enum { backward, forward },
            /// `visible` asks the renderer's filtered kinds; only `all` pages
            /// carry live facts. The shell translates this intent to kinds.
            kinds: enum { all, visible },
            limit: u8 = activity.ActivityPage.items,
            /// The original edge, used for stale checks and scan attachment.
            started_from: ?Cursor,
            from: ?Cursor,
            /// Initial high-water mark of the whole scan cycle, not its page.
            novelty_after: ?Cursor = null,
            /// Non-null means read INCLUSIVELY at this key, then replace that
            /// suffix with feed_window.replaceFrom, not append duplicates.
            /// Null means the ordinary exclusive continuation at `from`.
            replace_from: ?Cursor = null,
            /// Continuation appends the rest of an already-replaced suffix.
            /// replace_from still names its attachment boundary.
            continuing: bool = false,
        };

        /// A scan cycle owns pagination progress and its independent novelty
        /// origin. A frozen catch-up keeps that origin until its final page;
        /// fills and the resident window never advance this owner.
        pub const Cycle = struct {
            cursor: ?Cursor = null,
            catchup: ?struct { end: u64, novelty_after: ?Cursor } = null,

            pub fn page(self: Cycle, provisional: ?Cursor) Page {
                var result = forward(self.cursor, provisional, .all, self.catchup != null);
                if (self.catchup) |sweep| result.novelty_after = sweep.novelty_after;
                return result;
            }

            pub fn landed(self: Cycle, asked: Page, cursor: ?Cursor, end: ?u64) Cycle {
                if (asked.kinds != .all) return self;
                return .{ .cursor = cursor, .catchup = if (end) |frozen| .{ .end = frozen, .novelty_after = asked.novelty_after } else null };
            }
        };

        pub fn isNew(page: Page, key: Cursor) bool {
            return page.novelty_after == null or key.order(page.novelty_after.?) == .gt;
        }

        /// The scan owns its cursor; the window alone owns the replay boundary.
        /// Opening reads newest backward; permission keeps its existing read.
        /// Capture this plan when the read starts, not when it completes.
        pub fn request(read: Read, state: State) ?Page {
            return switch (read) {
                .opening => .{ .direction = .backward, .kinds = .all, .started_from = null, .from = null },
                .fill_above => .{ .direction = .backward, .kinds = .visible, .started_from = state.low, .from = state.low },
                .scan => state.scan.page(state.window_provisional),
                .fill_below => forward(state.high, state.window_provisional, .visible, state.window_continuing),
                .permission => null,
            };
        }

        fn forward(edge: ?Cursor, first_provisional: ?Cursor, kinds: @FieldType(Page, "kinds"), continuing: bool) Page {
            return .{
                .direction = .forward,
                .kinds = kinds,
                .started_from = edge,
                .from = if (continuing) edge else first_provisional orelse edge,
                .novelty_after = edge,
                .replace_from = first_provisional,
                .continuing = continuing,
            };
        }

        /// A forward result attaches only while both its original cursor and
        /// replacement boundary match the window. Null matches only null: an
        /// append cannot skip a provisional suffix that appeared during a read.
        pub fn forwardAttaches(started_from: ?Cursor, replace_from: ?Cursor, window_high: ?Cursor, window_provisional: ?Cursor) bool {
            return std.meta.eql(started_from, window_high) and std.meta.eql(replace_from, window_provisional);
        }

        /// Compare the low edge for fill_above; fill_below uses forward
        /// attachment against the high edge and first provisional key now.
        /// Drop stale fills; need() will reissue. Scans are never dropped: work,
        /// call_activity, queued and the scan cursor always land, even from an
        /// empty page or with the window scrolled away from the end, and
        /// applyScan decides what happens to their rows.
        /// Opening/permission retain their own lifecycle, not an edge check.
        pub fn applies(read: Read, started_from: ?Cursor, replace_from: ?Cursor, edge_now: ?Cursor, window_provisional: ?Cursor) bool {
            return switch (read) {
                .fill_above => std.meta.eql(started_from, edge_now),
                .fill_below => forwardAttaches(started_from, replace_from, edge_now, window_provisional),
                .opening, .scan, .permission => true,
            };
        }

        pub const Scan = struct {
            rows: union(enum) { append, count_only: usize },
        };

        /// `scan_start` is Page.started_from, NOT its provisional restart key.
        /// Re-evaluate against the window high at completion, so scrolling or
        /// trimming during an in-flight scan cannot splice disconnected rows.
        /// A replay boundary must still be the window's first provisional key;
        /// pass firstProvisional() at completion. When attached, Page.replace_from
        /// replaces rather than appends.
        /// `rows` counts newly rendered entries, excluding replayed entries;
        /// Activity positions and replayed provisional rows are not new count.
        pub fn applyScan(window_high: ?Cursor, scan_start: ?Cursor, replace_from: ?Cursor, window_provisional: ?Cursor, rows: usize) Scan {
            return .{ .rows = if (forwardAttaches(scan_start, replace_from, window_high, window_provisional)) .append else .{ .count_only = rows } };
        }
    };
}

pub const Jump = enum {
    /// The window still reaches the end; just set Feed's anchor to end.
    follow,
    /// Start a fresh opening and keep the old frame until it lands. Do not
    /// clear or follow the old window before replacing it with that opening.
    opening_keep_frame,
};

pub fn jumpToEnd(at_end: bool) Jump {
    return if (at_end) .follow else .opening_keep_frame;
}

test "feed_reads policy: opening, fair fills, stale edges, live scan, jump and provisional replay" {
    const Key = struct {
        position: u64,
        ordinal: u64 = 0,
        pub fn order(a: @This(), b: @This()) std.math.Order {
            const primary = std.math.order(a.position, b.position);
            return if (primary == .eq) std.math.order(a.ordinal, b.ordinal) else primary;
        }
    };
    const P = Policy(Key);
    const F = feed.Feed(Key);
    const low: Key = .{ .position = 10 };
    const high: Key = .{ .position = 30, .ordinal = 2 };
    const provisional: Key = .{ .position = 20, .ordinal = 1 };
    var state: P.State = .{ .opening = true, .now_ns = 0, .scan_due_ns = 0, .at_end = true, .action_named = true };

    // Opening alone can start, even when both a scan and page are wanted.
    for (std.enums.values(F.Need)) |need| {
        state.need = need;
        try std.testing.expectEqual(Read.opening, P.nextRead(state).?);
    }
    state.low = low;
    state.high = high;
    state.scan.cursor = .{ .position = 40 };
    state.window_provisional = provisional;
    const opening = P.request(.opening, state).?;
    try std.testing.expect(opening.direction == .backward and opening.kinds == .all);
    try std.testing.expect(opening.from == null and opening.replace_from == null);
    try std.testing.expectEqual(@as(u8, 16), opening.limit);

    // The first page is short and paints at once. Following fills above until
    // Feed's margin (or the known start) says none.
    state.opening = false;
    state.scan_due_ns = scanDue(0, false);
    var view: F = .{};
    const entries: []const F.Entry = &.{.{ .key = high, .lines = &.{2} }};
    state.need = view.need(entries, 10, .{ .start = false, .end = true });
    try std.testing.expectEqual(Read.permission, P.nextRead(state).?);
    state.action_named = false;
    try std.testing.expectEqual(Read.fill_above, P.nextRead(state).?);
    const above = P.request(.fill_above, state).?;
    try std.testing.expect(above.direction == .backward and above.kinds == .visible);
    try std.testing.expect(std.meta.eql(@as(?Key, low), above.from));
    try std.testing.expect(above.replace_from == null);
    state.need = view.need(entries, 10, .{ .start = true, .end = true });
    state.action_named = true;
    try std.testing.expectEqual(Read.permission, P.nextRead(state).?);
    state.action_named = false;
    try std.testing.expectEqual(@as(?Read, null), P.nextRead(state));

    // Twenty idle decisions under held PgUp: fills do NOT reset the deadline.
    // At 250, 500 and 750 ms the due scan wins; between them fills are eager.
    state.need = .above;
    var scans: usize = 0;
    for (0..20) |i| {
        state.now_ns = @as(i96, @intCast(i)) * 50_000_000;
        const expected: Read = if (i == 5 or i == 10 or i == 15) .scan else .fill_above;
        try std.testing.expectEqual(expected, P.nextRead(state).?);
        if (expected == .scan) {
            scans += 1;
            state.scan_due_ns = scanDue(state.now_ns, false);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), scans);
    state.now_ns = 0;
    state.need = .below;
    try std.testing.expectEqual(@as(?Read, null), P.nextRead(state));
    state.at_end = false;
    try std.testing.expectEqual(Read.fill_below, P.nextRead(state).?);
    state.now_ns = state.scan_due_ns;
    try std.testing.expectEqual(Read.scan, P.nextRead(state).?);

    // Both edges: trim, jump-to-end replacement, and suffix replacement make
    // fills stale. A scroll alone leaves the edge unchanged and still applies.
    for ([_]Read{ .fill_above, .fill_below }) |read| {
        try std.testing.expect(P.applies(read, high, null, high, null));
        const changed = [_]?Key{ low, null, .{ .position = 30, .ordinal = 3 } };
        for (changed) |edge| try std.testing.expect(!P.applies(read, high, null, edge, null));
        try std.testing.expect(P.applies(read, null, null, null, null));
        try std.testing.expect(!P.applies(read, null, null, high, null));
    }
    for ([_]Read{ .scan, .opening, .permission }) |read| try std.testing.expect(P.applies(read, high, null, low, null));
    for ([_]usize{ 0, 7 }) |rows| {
        const attached = P.applyScan(high, high, null, null, rows);
        try std.testing.expect(attached.rows == .append);
        const detached = P.applyScan(low, high, null, null, rows);
        try std.testing.expectEqual(rows, detached.rows.count_only);
        // Equal positions with different ordinals are disconnected too.
        const ordinal_changed = P.applyScan(.{ .position = 30, .ordinal = 1 }, high, null, null, rows);
        try std.testing.expectEqual(rows, ordinal_changed.rows.count_only);
    }
    try std.testing.expect(P.applyScan(null, null, null, null, 0).rows == .append);
    try std.testing.expectEqual(@as(usize, 7), P.applyScan(null, high, null, null, 7).rows.count_only);
    try std.testing.expectEqual(Jump.follow, jumpToEnd(true));
    try std.testing.expectEqual(Jump.opening_keep_frame, jumpToEnd(false));
    // A jump keeps the old frame; the shell marks opening until it lands.
    state.opening = jumpToEnd(false) == .opening_keep_frame;
    try std.testing.expectEqual(Read.opening, P.nextRead(state).?);

    const independent_scan = P.request(.scan, state).?;
    try std.testing.expect(std.meta.eql(state.scan.cursor, independent_scan.started_from));
    try std.testing.expect(std.meta.eql(state.window_provisional, independent_scan.from));
    try std.testing.expectEqual(@as(usize, 2), P.applyScan(state.high, independent_scan.started_from, independent_scan.replace_from, state.window_provisional, 2).rows.count_only);
    const independent_fill = P.request(.fill_below, state).?;
    try std.testing.expect(std.meta.eql(state.high, independent_fill.started_from));
    try std.testing.expect(std.meta.eql(state.window_provisional, independent_fill.from));

    // Both forward paths replay inclusively at the provisional key, retaining
    // the original edge for attachment/staleness. No provisional means append.
    for ([_]Read{ .scan, .fill_below }) |read| {
        state.scan.cursor = high;
        state.window_provisional = provisional;
        const page = P.request(read, state).?;
        try std.testing.expect(page.direction == .forward);
        try std.testing.expectEqual(read == .scan, page.kinds == .all);
        try std.testing.expect(std.meta.eql(@as(?Key, provisional), page.from));
        try std.testing.expect(std.meta.eql(@as(?Key, provisional), page.replace_from));
        try std.testing.expect(std.meta.eql(@as(?Key, high), page.started_from));
        try std.testing.expect(P.applyScan(high, page.started_from, page.replace_from, state.window_provisional, 2).rows == .append);
        state.window_provisional = null;
        const settled = P.request(read, state).?;
        try std.testing.expect(std.meta.eql(@as(?Key, high), settled.from));
        try std.testing.expect(settled.replace_from == null);
    }
    try std.testing.expect(P.request(.permission, state) == null);

    // Permission is exactly today's rule over every combination of its inputs.
    // With no fill and no due scan it is offered only when input is quiet.
    state = .{ .opening = false, .now_ns = 0, .scan_due_ns = 1, .at_end = true };
    for ([_]bool{ false, true }) |named| for ([_]bool{ false, true }) |choice| for ([_]bool{ false, true }) |submitted| {
        state.action_named = named;
        state.choice_open = choice;
        state.submission = submitted;
        try std.testing.expectEqual(named and !choice and !submitted, P.nextRead(state) == .permission);
    };
    try std.testing.expectEqual(@as(i96, 250_000_000), scanDue(0, false));
    try std.testing.expectEqual(@as(i96, 0), scanDue(10, true));
}

test "feed_reads forward attachment domain for scan and fill_below" {
    const P = Policy(u64);
    const cases = [_]struct { replace_from: ?u64 = 20, current: ?u64, high: u64, attach: bool }{
        // Replay boundary retained / evicted / changed, crossed with high
        // unchanged / changed. A front trim can evict 20 while high stays 30.
        .{ .current = 20, .high = 30, .attach = true },
        .{ .current = 20, .high = 31, .attach = false },
        .{ .current = null, .high = 30, .attach = false },
        .{ .current = null, .high = 31, .attach = false },
        .{ .current = 21, .high = 30, .attach = false },
        .{ .current = 21, .high = 31, .attach = false },
        // An exclusive continuation also needs the same (null) boundary.
        .{ .replace_from = null, .current = null, .high = 30, .attach = true },
        .{ .replace_from = null, .current = null, .high = 31, .attach = false },
        .{ .replace_from = null, .current = 20, .high = 30, .attach = false },
        .{ .replace_from = null, .current = 20, .high = 31, .attach = false },
    };
    for (cases, 0..) |case, index| {
        errdefer std.debug.print("forward attachment case {d}: {any}\n", .{ index, case });
        try std.testing.expectEqual(case.attach, P.forwardAttaches(30, case.replace_from, case.high, case.current));
        for ([_]Read{ .scan, .fill_below }) |read| {
            errdefer std.debug.print("forward read: {s}\n", .{@tagName(read)});
            const page = P.request(read, .{
                .opening = false,
                .now_ns = 0,
                .scan_due_ns = 0,
                .at_end = false,
                .high = 30,
                .scan = .{ .cursor = 30 },
                .window_provisional = case.replace_from,
            }).?;
            const applies = P.applies(read, page.started_from, page.replace_from, case.high, case.current);
            switch (read) {
                .scan => {
                    // Detached scans still deliver live facts and count rows.
                    try std.testing.expect(applies);
                    const result = P.applyScan(case.high, page.started_from, page.replace_from, case.current, 7);
                    try std.testing.expectEqual(case.attach, result.rows == .append);
                    if (!case.attach) try std.testing.expectEqual(@as(usize, 7), result.rows.count_only);
                },
                .fill_below => try std.testing.expectEqual(case.attach, applies),
                else => unreachable,
            }
        }
        // Backward fills depend only on the low edge, not replay state.
        try std.testing.expect(P.applies(.fill_above, 10, case.replace_from, 10, case.current));
        try std.testing.expect(!P.applies(.fill_above, 10, case.replace_from, 11, case.current));
    }
}

test "feed_reads continues a paginated provisional replay without restarting or replacing twice" {
    const P = Policy(u64);
    for ([_]Read{ .scan, .fill_below }) |read| {
        var state: P.State = .{ .opening = false, .now_ns = 0, .scan_due_ns = 1, .at_end = false, .high = 30, .scan = .{ .cursor = 30 }, .window_provisional = 10 };
        const first = P.request(read, state).?;
        try std.testing.expectEqual(@as(?u64, 10), first.from);
        try std.testing.expect(!first.continuing);
        state.window_continuing = true;
        state.scan.catchup = .{ .end = 40, .novelty_after = 30 };
        const next = P.request(read, state).?;
        try std.testing.expectEqual(@as(?u64, 30), next.from);
        try std.testing.expectEqual(@as(?u64, 10), next.replace_from);
        try std.testing.expect(next.continuing);
        try std.testing.expect(P.forwardAttaches(next.started_from, next.replace_from, state.high, state.window_provisional));
    }
}

test "feed_reads ending identity includes position and ordinal" {
    const Key = struct { position: u64, ordinal: u64 = 0 };
    const E = Ending(Key);
    const ending: E = .{ .key = .{ .position = 9, .ordinal = 2 }, .cause = @import("marks.zig").cause("provider_http_500") };
    for ([_]u64{ 8, 9, 10 }) |position| for ([_]u64{ 1, 2, 3 }) |ordinal| {
        try std.testing.expectEqual(position == 9 and ordinal == 2, ending.matches(.{ .position = position, .ordinal = ordinal }));
    };
}

test "feed_reads holds fills during selection without holding scans or permission" {
    const P = Policy(u64);
    for ([_]@FieldType(P.State, "need"){ .above, .below }) |need| {
        for ([_]bool{ false, true }) |at_end| {
            for ([_]bool{ false, true }) |held| {
                var state: P.State = .{ .opening = false, .now_ns = 0, .scan_due_ns = 1, .need = need, .at_end = at_end, .selection_held = held };
                const fill: ?Read = if (held or (need == .below and at_end)) null else if (need == .above) .fill_above else .fill_below;
                try std.testing.expectEqual(fill, P.nextRead(state));
                // Selection excludes only fills, not independent work reads.
                state.action_named = true;
                try std.testing.expectEqual(Read.permission, P.nextRead(state).?);
                state.now_ns = state.scan_due_ns;
                try std.testing.expectEqual(Read.scan, P.nextRead(state).?);
                state.opening = true;
                try std.testing.expectEqual(Read.opening, P.nextRead(state).?);
            }
        }
    }
}

test "feed_reads scan cycle keeps novelty independent of replay pagination" {
    const Key = struct {
        position: u64,
        ordinal: u64 = 0,
        pub fn order(a: @This(), b: @This()) std.math.Order {
            const primary = std.math.order(a.position, b.position);
            return if (primary == .eq) std.math.order(a.ordinal, b.ordinal) else primary;
        }
    };
    const P = Policy(Key);
    for ([_]?Key{ null, .{ .position = 20, .ordinal = 2 } }) |origin| {
        var cycle: P.Cycle = .{ .cursor = origin };
        const provisional: Key = .{ .position = 1 };
        for ([_]u64{ 8, 16, 24 }, 0..) |position, index| {
            const page = cycle.page(provisional);
            try std.testing.expectEqualDeep(origin, page.novelty_after);
            try std.testing.expectEqual(index != 0, page.continuing);
            for ([_]Key{ .{ .position = 20, .ordinal = 1 }, .{ .position = 20, .ordinal = 2 }, .{ .position = 20, .ordinal = 3 }, .{ .position = 21 } }) |key| {
                try std.testing.expectEqual(origin == null or key.order(origin.?) == .gt, P.isNew(page, key));
            }
            const unchanged = cycle.landed(.{ .direction = .backward, .kinds = .visible, .started_from = null, .from = null }, .{ .position = 99 }, null);
            try std.testing.expectEqualDeep(cycle, unchanged);
            cycle = cycle.landed(page, .{ .position = position }, if (index < 2) 24 else null);
        }
        try std.testing.expect(cycle.catchup == null);
        try std.testing.expectEqualDeep(@as(?Key, .{ .position = 24 }), cycle.page(provisional).novelty_after);
        // An opening is a fresh snapshot, not a continuation of prior replay.
        cycle = cycle.landed(.{ .direction = .backward, .kinds = .all, .started_from = null, .from = null }, .{ .position = 40 }, null);
        try std.testing.expectEqualDeep(@as(?Key, .{ .position = 40 }), cycle.page(provisional).novelty_after);
    }
}

test "feed_reads failed fills wait for edge intent without starving live scans or approval" {
    const Key = struct { position: u64, ordinal: u64 = 0 };
    const P = Policy(Key);
    for ([_]Read{ .fill_above, .fill_below }) |read| {
        const down = read == .fill_below;
        var state: P.State = .{ .opening = false, .now_ns = 0, .scan_due_ns = 1, .at_end = false, .low = .{ .position = 10 }, .high = .{ .position = 30 }, .need = if (down) .below else .above };
        const page = P.request(read, state).?;
        try std.testing.expectEqual(read, P.nextRead(state).?);
        state.fills = state.fills.failed(read, page).observe(state);
        for (0..3) |_| {
            state.fills = state.fills.observe(state);
            try std.testing.expect(P.nextRead(state) == null);
        }
        // A press, drag and release are not a new loading intent.
        for ([_]bool{ true, true, false }) |held| {
            state.selection_held = held;
            try std.testing.expect(P.nextRead(state) == null);
        }
        state.now_ns = 1;
        try std.testing.expectEqual(Read.scan, P.nextRead(state).?);
        state.now_ns = 0;
        state.action_named = true;
        try std.testing.expectEqual(Read.permission, P.nextRead(state).?);
        state.fills = state.fills.failed(.scan, page).failed(.permission, page).observe(state);
        state.action_named = false;
        try std.testing.expect(P.nextRead(state) == null);
        state.fills = state.fills.scrolled(state, !down);
        try std.testing.expect(P.nextRead(state) == null);
        state.fills = state.fills.scrolled(state, down);
        try std.testing.expectEqual(read, P.nextRead(state).?);
        // Even an unfailed, continuously needed edge yields to approval.
        state.action_named = true;
        try std.testing.expectEqual(Read.permission, P.nextRead(state).?);
        state.action_named = false;
        state.fills = state.fills.failed(read, page);
        state.need = .none;
        state.fills = state.fills.observe(state);
        state.need = if (down) .below else .above;
        try std.testing.expectEqual(read, P.nextRead(state).?);
        // A failure at an old ordinal cannot block a new edge at that position.
        if (down) state.high.?.ordinal = 1 else state.low.?.ordinal = 1;
        state.fills = state.fills.failed(read, page).observe(state);
        try std.testing.expectEqual(read, P.nextRead(state).?);
        state.fills = state.fills.failed(read, P.request(read, state).?);
        state.opening = true;
        state.fills = state.fills.observe(state);
        try std.testing.expect(state.fills.blocked == null);
        try std.testing.expectEqual(Read.opening, P.nextRead(state).?);
    }
}
