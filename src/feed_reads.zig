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
/// interval and /status exception until the old policy is removed at cut-over.
pub const scanDue = reading.scanDue;
pub const scan_interval_ns = reading.scan_interval_ns;

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
            scan_cursor: ?Cursor = null,
            window_provisional: ?Cursor = null,
            /// Scan replay survives eviction from the resident window.
            scan_provisional: ?Cursor = null,
            action_named: bool = false,
            choice_open: bool = false,
            submission: bool = false,
        };

        /// Opening paints immediately, then Feed.need requests the bottom-up
        /// fill above. Due scans always beat fills; all other fills run back to
        /// back. Thus held PgUp cannot starve live facts, without a fairness
        /// counter or another copy of the reader's state.
        pub fn nextRead(state: State) ?Read {
            if (state.opening) return .opening;
            if (state.now_ns >= state.scan_due_ns) return .scan;
            switch (state.need) {
                .above => return .fill_above,
                .below => if (!state.at_end) return .fill_below,
                .none => {},
            }
            // Same permission rule and priority (after page work) as before.
            if (state.action_named and !state.choice_open and !state.submission) return .permission;
            return null;
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
            /// Non-null means read INCLUSIVELY at this key, then replace that
            /// suffix with feed_window.replaceFrom, not append duplicates.
            /// Null means the ordinary exclusive continuation at `from`.
            replace_from: ?Cursor = null,
        };

        /// The scan owns its cursor and replay key, independent of the window.
        /// Opening reads newest backward; permission keeps its existing read.
        /// Capture this plan when the read starts, not when it completes.
        pub fn request(read: Read, state: State) ?Page {
            return switch (read) {
                .opening => .{ .direction = .backward, .kinds = .all, .started_from = null, .from = null },
                .fill_above => .{ .direction = .backward, .kinds = .visible, .started_from = state.low, .from = state.low },
                .scan => forward(state.scan_cursor, state.scan_provisional, .all),
                .fill_below => forward(state.high, state.window_provisional, .visible),
                .permission => null,
            };
        }

        fn forward(edge: ?Cursor, first_provisional: ?Cursor, kinds: @FieldType(Page, "kinds")) Page {
            return .{
                .direction = .forward,
                .kinds = kinds,
                .started_from = edge,
                .from = first_provisional orelse edge,
                .replace_from = first_provisional,
            };
        }

        /// Compare the low edge for fill_above, high for fill_below. A trim,
        /// jump or suffix replacement may change it while the reader runs.
        /// Drop stale fills; need() will reissue. Scans are never dropped: live
        /// facts always land, and applyScan decides what happens to their rows.
        /// Opening/permission retain their own lifecycle, not an edge check.
        pub fn applies(read: Read, started_from: ?Cursor, edge_now: ?Cursor) bool {
            return switch (read) {
                .fill_above, .fill_below => std.meta.eql(started_from, edge_now),
                .opening, .scan, .permission => true,
            };
        }

        pub const Scan = struct {
            /// Always refresh work, call_activity, queued and the scan cursor,
            /// even for empty pages or a window scrolled away from the end.
            live_facts: bool = true,
            rows: union(enum) { append, count_only: usize },
        };

        /// `scan_start` is Page.started_from, NOT its provisional restart key.
        /// Re-evaluate against the window high at completion, so scrolling or
        /// trimming during an in-flight scan cannot splice disconnected rows.
        /// When attached, Page.replace_from replaces rather than appends.
        /// `rows` counts newly rendered entries, excluding replayed entries;
        /// Activity positions and replayed provisional rows are not new count.
        pub fn applyScan(window_high: ?Cursor, scan_start: ?Cursor, rows: usize) Scan {
            return .{ .rows = if (std.meta.eql(window_high, scan_start)) .append else .{ .count_only = rows } };
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
    state.scan_cursor = .{ .position = 40 };
    state.window_provisional = provisional;
    state.scan_provisional = .{ .position = 35 };
    const opening = P.request(.opening, state).?;
    try std.testing.expect(opening.direction == .backward and opening.kinds == .all);
    try std.testing.expect(opening.from == null and opening.replace_from == null);
    try std.testing.expectEqual(@as(u8, 16), opening.limit);

    // The first page is short and paints at once. Following fills above until
    // Feed's margin (or the known start) says none, then permission may start.
    state.opening = false;
    state.scan_due_ns = scanDue(0, false);
    var view: F = .{};
    const entries: []const F.Entry = &.{.{ .key = high, .lines = &.{2} }};
    state.need = view.need(entries, 10, .{ .start = false, .end = true });
    try std.testing.expectEqual(Read.fill_above, P.nextRead(state).?);
    const above = P.request(.fill_above, state).?;
    try std.testing.expect(above.direction == .backward and above.kinds == .visible);
    try std.testing.expect(std.meta.eql(@as(?Key, low), above.from));
    try std.testing.expect(above.replace_from == null);
    state.need = view.need(entries, 10, .{ .start = true, .end = true });
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
        try std.testing.expect(P.applies(read, high, high));
        const changed = [_]?Key{ low, null, .{ .position = 30, .ordinal = 3 } };
        for (changed) |edge| try std.testing.expect(!P.applies(read, high, edge));
        try std.testing.expect(P.applies(read, null, null));
        try std.testing.expect(!P.applies(read, null, high));
    }
    for ([_]Read{ .scan, .opening, .permission }) |read| try std.testing.expect(P.applies(read, high, low));
    for ([_]usize{ 0, 7 }) |rows| {
        const attached = P.applyScan(high, high, rows);
        try std.testing.expect(attached.live_facts and attached.rows == .append);
        const detached = P.applyScan(low, high, rows);
        try std.testing.expect(detached.live_facts);
        try std.testing.expectEqual(rows, detached.rows.count_only);
        // Equal positions with different ordinals are disconnected too.
        const ordinal_changed = P.applyScan(.{ .position = 30, .ordinal = 1 }, high, rows);
        try std.testing.expectEqual(rows, ordinal_changed.rows.count_only);
    }
    try std.testing.expect(P.applyScan(null, null, 0).rows == .append);
    try std.testing.expectEqual(@as(usize, 7), P.applyScan(null, high, 7).rows.count_only);
    try std.testing.expectEqual(Jump.follow, jumpToEnd(true));
    try std.testing.expectEqual(Jump.opening_keep_frame, jumpToEnd(false));
    // A jump keeps the old frame; the shell marks opening until it lands.
    state.opening = jumpToEnd(false) == .opening_keep_frame;
    try std.testing.expectEqual(Read.opening, P.nextRead(state).?);

    const independent_scan = P.request(.scan, state).?;
    try std.testing.expect(std.meta.eql(state.scan_cursor, independent_scan.started_from));
    try std.testing.expect(std.meta.eql(state.scan_provisional, independent_scan.from));
    try std.testing.expectEqual(@as(usize, 2), P.applyScan(state.high, independent_scan.started_from, 2).rows.count_only);
    const independent_fill = P.request(.fill_below, state).?;
    try std.testing.expect(std.meta.eql(state.high, independent_fill.started_from));
    try std.testing.expect(std.meta.eql(state.window_provisional, independent_fill.from));

    // Both forward paths replay inclusively at the provisional key, retaining
    // the original edge for attachment/staleness. No provisional means append.
    for ([_]Read{ .scan, .fill_below }) |read| {
        state.scan_cursor = high;
        state.scan_provisional = provisional;
        state.window_provisional = provisional;
        const page = P.request(read, state).?;
        try std.testing.expect(page.direction == .forward);
        try std.testing.expectEqual(read == .scan, page.kinds == .all);
        try std.testing.expect(std.meta.eql(@as(?Key, provisional), page.from));
        try std.testing.expect(std.meta.eql(@as(?Key, provisional), page.replace_from));
        try std.testing.expect(std.meta.eql(@as(?Key, high), page.started_from));
        try std.testing.expect(P.applyScan(high, page.started_from, 2).rows == .append);
        state.scan_provisional = null;
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
        const old = reading.background(.{ .opening = false, .now_ns = 0, .scan_due_ns = 1, .older_remain = false, .older_failed = false, .at_top = false, .action_named = named, .choice_open = choice, .submission = submitted });
        try std.testing.expectEqual(old == .permission, P.nextRead(state) == .permission);
    };
    try std.testing.expectEqual(@as(i96, 250_000_000), scanDue(0, false));
    try std.testing.expectEqual(@as(i96, 0), scanDue(10, true));
}
