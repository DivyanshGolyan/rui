//! A conversation's transcript as values: the read boundaries live output
//! keeps, the Messages it showed, and how a transcript of the output
//! retained from some front begins. `session_reads` reads the pages and
//! `SessionFrontend` records the offsets; this decides over what they found.
const std = @import("std");

/// How an Activity item carries a Message: another Session's or a person's
/// or script's Admission (`received` is one this Session received from
/// another), or the Message's row once applied (`user`).
pub const Kind = enum { admission, received, user };
pub const State = enum { queued, applied, excluded };

/// The newest Message a person or script sent that live output showed while
/// it waited (see View.Taking), by admission ID: just before the first of
/// some shown items and just after the last.
pub const DrawnSpan = struct { before: u64 = 0, after: u64 = 0 };

pub const Messages = struct {
    /// The newest Message shown as its Admission.
    shown: u64 = 0,
    /// The newest Message whose conversation row a read returned, or up to
    /// which a stop excluded every Message without one.
    answered: u64 = 0,

    /// Every shown Message has its conversation row before the next item, so
    /// no conversation item after it showed earlier in live output.
    pub fn settled(self: Messages) bool {
        return self.shown <= self.answered;
    }

    /// A read passed a Message's item, which live output showed if `shown`.
    pub fn observe(self: *Messages, kind: Kind, admission: u64, shown: bool) void {
        switch (kind) {
            .admission, .received => if (shown) {
                self.shown = @max(self.shown, admission);
            },
            .user => self.answered = @max(self.answered, admission),
        }
    }
};

/// Whether a range lists a Message's item.
///
/// A span of dropped echoes (`shown`, read at its newest echo's position)
/// lists each Message live output showed in it once. Live output shows another
/// Session's Message as its Admission. It shows a person's or script's at
/// its Admission when the Message showed while it waited (`DrawnSpan`),
/// otherwise as its row or labelled at the stop that excluded it, so it
/// judges each by the newest such Message before the span and after it:
/// - A row shows unless its Message showed while it waited, which it did
///   before the span only if no newer one had, and in the span only with
///   its Admission there too. Either way the row is listed exactly when its
///   Message is newer than the one before the span.
/// - An Admission whose row is in the span is listed there instead. One
///   still waiting at the span's end showed in it exactly when no newer
///   Message showed while it waited by then: any that did was taken next,
///   so this one had been taken before it. One a stop excluded is listed at
///   the stop's seam.
///
/// A seam lists each Message not applied at the range's end, except a
/// person's or script's still waiting: one that showed at its Admission has
/// its row before any later boundary (see `Messages`), and any other waits
/// above the input and shows live once taken. `from_person`: a person or
/// script sent it, not another Session.
pub fn lists(kind: Kind, state: State, admission: u64, from_person: bool, shown: ?DrawnSpan) bool {
    return switch (kind) {
        .received => shown != null or state != .applied,
        .admission => if (shown) |drawn| state == .queued and admission <= drawn.after else state == .excluded,
        .user => if (shown) |drawn| from_person and admission > drawn.before else false,
    };
}

/// The transcript's values for Messages of type `Message`, conversation
/// cursors of type `Cursor` (which names at least an `end`), and pages of at
/// most `page_items` items.
pub fn Of(comptime Message: type, comptime Cursor: type, comptime page_items: usize) type {
    return struct {
        /// Where a read's output may begin a transcript. `output` counts the
        /// read's staged bytes, styling included; live output keeps only
        /// text, so the UI records the live offset where writing reaches it,
        /// never this number.
        pub const Boundary = struct {
            output: u64,
            cursor: ?Cursor,
            /// Every Message admitted before this position that showed did so
            /// before the boundary; one admitted at or after it shows after
            /// it, if at all.
            admitted: u64,
        };

        /// One Message as a read's output shows it: live, another Session's
        /// Admission, or a person's or script's at its Admission or as its
        /// row; in the opening, its row or unapplied input. `output` and
        /// `end` are output offsets until the UI records live ones. The
        /// state is as of the read's end.
        pub const Echo = struct {
            output: u64,
            end: u64,
            position: u64,
            ordinal: u64,
            message: Message,
            drawn: DrawnSpan = .{},
        };

        /// The Messages one read shows, in order: a page holds at most one each.
        pub const Echoes = struct {
            items: [page_items]Echo = undefined,
            count: usize = 0,

            pub fn add(self: *Echoes, echo: Echo) void {
                self.items[self.count] = echo;
                self.count += 1;
            }

            pub fn slice(self: *const Echoes) []const Echo {
                return self.items[0..self.count];
            }
        };

        /// One step of a transcript's listing: a Message in full where older
        /// pages and the retained copy cannot show it. Each step reads one
        /// Message.
        pub const Listing = union(enum) {
            /// A shown Message whose output left the view, from its own item.
            echo: Echo,
            /// Messages at positions in `[lowest, before)` at `end`, newest
            /// first: every one live output showed in a span it dropped
            /// (`shown`), or those not applied at `end` (see `lists`). The
            /// next one is searched for backward from `position` and
            /// `ordinal`; position 0 searches back from the end itself.
            range: struct { end: u64, lowest: u64, shown: ?DrawnSpan, position: u64, ordinal: ?u64 = null },

            pub fn within(end: u64, lowest: u64, before: u64, shown: ?DrawnSpan) ?Listing {
                if (lowest >= before) return null;
                return .{ .range = .{ .end = end, .lowest = lowest, .shown = shown, .position = if (before > end) 0 else before } };
            }
        };

        /// The Messages live output shows after its newest mark, as live
        /// offsets. A mark prunes every echo before it: a transcript joined
        /// there reaches those through older pages or its listing. Opening
        /// echoes (one page) are never dropped; live ones beyond capacity
        /// are, keeping only their span.
        pub const Record = struct {
            pub const capacity = 64;
            opening: [page_items]Echo = undefined,
            opening_count: usize = 0,
            live: [capacity]Echo = undefined,
            live_count: usize = 0,
            /// Live echoes dropped beyond capacity: live echoes follow
            /// position order, so they are every item live output showed as
            /// a Message in `[low, high]` (see `lists`), and `drawn` is
            /// around them.
            dropped: ?struct { low: u64, high: u64, end: u64, drawn: DrawnSpan } = null,

            pub fn add(self: *Record, echo: Echo, opening: bool) void {
                if (opening) {
                    self.opening[self.opening_count] = echo;
                    self.opening_count += 1;
                    return;
                }
                if (self.live_count == self.live.len) {
                    const old = self.live[0];
                    self.dropped = if (self.dropped) |span| .{ .low = span.low, .high = old.position, .end = old.end, .drawn = .{ .before = span.drawn.before, .after = old.drawn.after } } else .{ .low = old.position, .high = old.position, .end = old.end, .drawn = old.drawn };
                    std.mem.copyForwards(Echo, self.live[0 .. self.live_count - 1], self.live[1..self.live_count]);
                    self.live_count -= 1;
                }
                self.live[self.live_count] = echo;
                self.live_count += 1;
            }

            pub fn prune(self: *Record, offset: u64) void {
                self.opening_count = keep(self.opening[0..self.opening_count], offset);
                self.live_count = keep(self.live[0..self.live_count], offset);
                if (self.dropped) |span| if (span.end <= offset) {
                    self.dropped = null;
                };
            }

            fn keep(echoes: []Echo, offset: u64) usize {
                var kept: usize = 0;
                for (echoes) |echo| if (echo.output >= offset) {
                    echoes[kept] = echo;
                    kept += 1;
                };
                return kept;
            }
        };

        /// How a transcript of live output retained from `front` begins:
        /// where its copy starts, then upward the listed Messages, the gap's
        /// label if any, the Messages listed at its seam, and older pages
        /// before `older`.
        pub const Plan = struct {
            start: u64,
            /// Shown Messages that left the view, oldest first; listed
            /// nearest the copy.
            echoes: [page_items + Record.capacity]Echo = undefined,
            echo_count: usize = 0,
            /// How many of `echoes`, the oldest, are the opening's: older
            /// than every live one, the dropped span's included.
            opening: usize = 0,
            dropped: ?Listing = null,
            gap: bool = false,
            unapplied: ?Listing = null,
            older: ?Cursor = null,

            /// The listed Message a transcript reads next, if any comes
            /// before older pages. Each is prepended, so newest first: live
            /// echoes, the dropped span, the opening's echoes, then after the
            /// gap's label the seam's.
            pub fn next(self: *const Plan) ?Listing {
                if (self.echo_count > self.opening) return .{ .echo = self.echoes[self.echo_count - 1] };
                if (self.dropped) |range| return range;
                if (self.echo_count != 0) return .{ .echo = self.echoes[self.echo_count - 1] };
                if (!self.gap) if (self.unapplied) |range| return range;
                return null;
            }

            /// Passes the step `next` returned once it shows; a range
            /// continues at `rest`, or is done when null.
            pub fn listed(self: *Plan, step: Listing, rest: ?Listing) void {
                switch (step) {
                    .echo => self.echo_count -= 1,
                    .range => if (self.dropped != null) {
                        self.dropped = rest;
                    } else {
                        self.unapplied = rest;
                    },
                }
            }
        };

        pub fn plan(marks: *const Marks, record: *const Record, front: u64, lowest: ?u64) Plan {
            const mark: ?Marks.Mark = switch (marks.start(front)) {
                .joined => |mark| return .{ .start = mark.offset, .unapplied = seam(mark, lowest), .older = mark.cursor },
                .gap => |before| before,
            };
            var result: Plan = .{ .start = front, .gap = true, .older = if (mark) |value| value.cursor else null };
            if (mark) |value| result.unapplied = seam(value, lowest);
            // Live echoes dropped beyond capacity may reach past the front:
            // start after the newest so none shows twice, and list them all.
            if (record.dropped) |span| {
                result.start = @max(result.start, span.end);
                // Read at the newest dropped echo's position: a Message
                // applied there has its row in the span (see `lists`).
                result.dropped = Listing.within(span.high, span.low, span.high + 1, span.drawn);
            }
            // An echo that the front cuts is listed whole, and the copy
            // starts after it.
            const echoes = [_][]const Echo{ record.opening[0..record.opening_count], record.live[0..record.live_count] };
            for (echoes) |kept| for (kept) |echo| if (echo.output < result.start and echo.end > result.start) {
                result.start = echo.end;
            };
            for (echoes, 0..) |kept, index| for (kept) |echo| if (echo.end <= result.start) {
                result.echoes[result.echo_count] = echo;
                result.echo_count += 1;
                if (index == 0) result.opening += 1;
            };
            return result;
        }

        /// Messages a transcript joined at `mark` lists there: admitted
        /// before its position and not applied at its end, so neither older
        /// pages nor the copy show them.
        fn seam(mark: Marks.Mark, lowest: ?u64) ?Listing {
            const cursor = mark.cursor orelse return null;
            return Listing.within(cursor.end, lowest orelse return null, mark.admitted, null);
        }

        /// A read's newest boundaries, oldest first. Any boundary at or
        /// after the view's front joins its transcript, so dropping the
        /// oldest loses nothing a newer one cannot replace.
        pub const Boundaries = struct {
            items: [Marks.capacity]Boundary = undefined,
            count: usize = 0,

            pub fn add(self: *Boundaries, boundary: Boundary) void {
                if (self.count == self.items.len) {
                    std.mem.copyForwards(Boundary, self.items[0 .. self.count - 1], self.items[1..self.count]);
                    self.count -= 1;
                }
                self.items[self.count] = boundary;
                self.count += 1;
            }

            pub fn slice(self: *const Boundaries) []const Boundary {
                return self.items[0..self.count];
            }
        };

        /// A later read also marks the end of its output, even when it shows
        /// nothing, if it reached its snapshot's end with every shown Message
        /// rowed. Reads continue from the previous one, so every item
        /// through `end` was read and has shown before `output` or never
        /// shows live; every later item, a result included, takes a fresh
        /// position after `end`. A Message whose row a read returned silently
        /// is then reachable through older pages. A page with more to read
        /// ends before its snapshot's end, and an unrowed shown Message would
        /// be in neither, so neither marks.
        pub fn readEnd(messages: Messages, more: bool, end: u64, output: u64) ?Boundary {
            if (more or !messages.settled()) return null;
            // End 0 asks the Host for its current end; nothing precedes
            // position 1.
            return .{ .output = output, .cursor = if (end == 0) null else .{ .end = end }, .admitted = end + 1 };
        }

        /// Read boundaries in live output, oldest first. A boundary pairs an
        /// absolute live offset with the canonical cursor for everything
        /// before it (null: the conversation's start). It is valid only if
        /// no conversation item at or after its cursor showed before its
        /// offset. Reads record only valid ones: the opening's start, and in
        /// a later read each shown item that follows every shown Message's
        /// conversation row, and its output's end (see `readEnd`). An
        /// incomplete read that shows nothing records none.
        pub const Marks = struct {
            pub const Mark = struct { offset: u64, cursor: ?Cursor, admitted: u64 };
            pub const capacity = 64;
            items: [capacity]Mark = undefined,
            count: usize = 0,

            /// Where a transcript of live output retained from some front
            /// begins.
            pub const Start = union(enum) {
                /// Output from the boundary's offset continues the older
                /// pages before its cursor exactly.
                joined: Mark,
                /// No boundary is retained. Output before the front left the
                /// view; older pages continue before the newest boundary that
                /// did, if any.
                gap: ?Mark,
            };

            pub fn record(self: *Marks, mark: Mark) void {
                // Equal offsets: nothing showed between the two reads, so the
                // later cursor is valid too and names at least as much before
                // the offset.
                if (self.count != 0 and self.items[self.count - 1].offset == mark.offset) {
                    self.items[self.count - 1] = mark;
                    return;
                }
                std.debug.assert(self.count == 0 or self.items[self.count - 1].offset < mark.offset);
                if (self.count == self.items.len) {
                    // Dropping the oldest boundary keeps the newest before
                    // any front until every retained one is after it.
                    std.mem.copyForwards(Mark, self.items[0 .. self.count - 1], self.items[1..self.count]);
                    self.count -= 1;
                }
                self.items[self.count] = mark;
                self.count += 1;
            }

            /// The first boundary retained from `front`; otherwise the newest
            /// before it.
            pub fn start(self: *const Marks, front: u64) Start {
                var before: ?Mark = null;
                for (self.items[0..self.count]) |mark| {
                    if (mark.offset >= front) return .{ .joined = mark };
                    before = mark;
                }
                return .{ .gap = before };
            }
        };
    };
}

/// Messages and cursors for tests: what a person's or script's Message
/// needs for `lists`, and a conversation cursor as the Host names one.
const TestMessage = struct { admission: u64, state: State = .queued, from_person: bool = true };
const TestCursor = struct { end: u64, before_position: u64 = 0, before_ordinal: u64 = 0 };
const T = Of(TestMessage, TestCursor, 16);

test "a range lists the Messages live output showed, never queued Messages still waiting above the input" {
    const Case = struct { kind: Kind, sender: bool, state: State, admission: u64, shown: ?DrawnSpan, listed: bool };
    // Live output showed Message 10 while it waited before the dropped
    // span, and Message 14 by its end.
    const span: DrawnSpan = .{ .before = 10, .after = 14 };
    for ([_]Case{
        // A dropped live span: what live output showed. Another Session's
        // Admission, a person's or script's row, and the Admission of one
        // that showed while it waited and still waits at the span's end.
        .{ .kind = .received, .sender = true, .state = .applied, .admission = 12, .shown = span, .listed = true },
        .{ .kind = .user, .sender = false, .state = .applied, .admission = 12, .shown = span, .listed = true },
        .{ .kind = .admission, .sender = false, .state = .queued, .admission = 14, .shown = span, .listed = true },
        // Not the row of one that showed while it waited before the span,
        // another Session's row, an Admission whose row the span lists,
        // one still waiting above the input, or one a stop excluded, which
        // shows at the stop.
        .{ .kind = .user, .sender = false, .state = .applied, .admission = 10, .shown = span, .listed = false },
        .{ .kind = .user, .sender = true, .state = .applied, .admission = 12, .shown = span, .listed = false },
        .{ .kind = .admission, .sender = false, .state = .applied, .admission = 12, .shown = span, .listed = false },
        .{ .kind = .admission, .sender = false, .state = .queued, .admission = 15, .shown = span, .listed = false },
        .{ .kind = .admission, .sender = false, .state = .excluded, .admission = 12, .shown = span, .listed = false },
        // A seam: each Message not applied at its end, except a person's
        // or script's still queued, which shows live once taken, at the
        // opening too.
        .{ .kind = .admission, .sender = false, .state = .queued, .admission = 10, .shown = null, .listed = false },
        .{ .kind = .admission, .sender = false, .state = .queued, .admission = 11, .shown = null, .listed = false },
        .{ .kind = .admission, .sender = false, .state = .excluded, .admission = 11, .shown = null, .listed = true },
        .{ .kind = .received, .sender = true, .state = .queued, .admission = 11, .shown = null, .listed = true },
        .{ .kind = .received, .sender = true, .state = .applied, .admission = 11, .shown = null, .listed = false },
        .{ .kind = .admission, .sender = false, .state = .applied, .admission = 9, .shown = null, .listed = false },
        .{ .kind = .user, .sender = false, .state = .applied, .admission = 11, .shown = null, .listed = false },
    }) |case| {
        try std.testing.expectEqual(case.listed, lists(case.kind, case.state, case.admission, !case.sender, case.shown));
    }
}

test "a read settles once every Message it showed has its row" {
    var messages: Messages = .{};
    messages.observe(.admission, 4, false);
    try std.testing.expect(messages.settled());
    messages.observe(.received, 4, true);
    try std.testing.expect(!messages.settled());
    messages.observe(.user, 3, false);
    try std.testing.expect(!messages.settled());
    messages.observe(.user, 4, false);
    try std.testing.expect(messages.settled());
    // An older showing or row never lowers what was seen.
    messages.observe(.admission, 2, true);
    messages.observe(.user, 1, false);
    try std.testing.expectEqual(Messages{ .shown = 4, .answered = 4 }, messages);
}

/// A live history for transcript tests: each Message item as of the newest
/// dropped echo's position, and the echoes live output recorded, in order.
const Shown = struct {
    const Item = struct { position: u64, kind: Kind, message: TestMessage };
    items: [160]Item = undefined,
    count: usize = 0,
    record: T.Record = .{},
    drawn: u64 = 0,
    output: u64 = 0,

    /// Appends an item at the next position; live output shows it as an
    /// echo when `shown`, moving the watermark to `drew` if it showed while
    /// it waited.
    fn add(self: *Shown, kind: Kind, message: TestMessage, shown: bool, drew: ?u64, opening: bool) void {
        const item: Item = .{ .position = self.count + 1, .kind = kind, .message = message };
        self.items[self.count] = item;
        self.count += 1;
        if (!shown) return;
        const before = self.drawn;
        if (drew) |admission| self.drawn = admission;
        self.record.add(.{ .output = self.output, .end = self.output + 1, .position = item.position, .ordinal = 0, .message = message, .drawn = .{ .before = before, .after = self.drawn } }, opening);
        self.output += 1;
    }

    /// How many times a transcript reaches each Message by admission ID:
    /// its kept echoes, and the dropped span listed as `session_reads` reads it.
    fn reached(self: *const Shown, counts: []u8) !void {
        @memset(counts, 0);
        for (self.record.opening[0..self.record.opening_count]) |echo| counts[echo.message.admission] += 1;
        for (self.record.live[0..self.record.live_count]) |echo| counts[echo.message.admission] += 1;
        const range = (T.plan(&T.Marks{}, &self.record, self.output, null).dropped orelse return error.NothingDropped).range;
        for (self.items[0..self.count]) |item| if (item.position >= range.lowest and item.position <= range.end) {
            if (lists(item.kind, item.message.state, item.message.admission, item.message.from_person, range.shown)) counts[item.message.admission] += 1;
        };
    }
};

test "a dropped span lists a Message taken from the queued row once, after a newer one showed while it waited" {
    // X waits behind work and leaves the queued row as its row R; another
    // Session's Messages keep live output from marking, so R falls into the
    // dropped span with X's Admission below it. Later Y shows at its
    // Admission while it waits. R is still X's only showing.
    var shown: Shown = .{};
    const x = 1;
    const y = 68;
    shown.add(.admission, .{ .admission = x, .state = .applied }, false, null, false);
    for (2..4) |admission| shown.add(.received, .{ .admission = admission, .from_person = false }, true, null, false);
    const row = shown.count + 1;
    shown.add(.user, .{ .admission = x, .state = .applied }, true, null, false);
    for (4..y) |admission| shown.add(.received, .{ .admission = admission, .from_person = false }, true, null, false);
    shown.add(.admission, .{ .admission = y }, true, y, false);
    const span = shown.record.dropped.?;
    try std.testing.expect(span.low > 1 and span.low < row and row <= span.high);
    var counts: [100]u8 = undefined;
    try shown.reached(&counts);
    for (1..y + 1) |admission| try std.testing.expectEqual(@as(u8, 1), counts[admission]);
}

test "Messages waiting at the opening reach a transcript once after their rows fall into the dropped span" {
    // The opening shows A at its Admission, since nothing holds the queue
    // and it is the oldest; B to the last wait in the queued row. Their
    // rows show live once taken, A's excepted, and more than a Record
    // holds fall into the dropped span; a later Message shows while it
    // waits.
    var shown: Shown = .{};
    const waiting = 70;
    for (1..waiting + 1) |admission| shown.add(.admission, .{ .admission = admission, .state = .applied }, admission == 1, if (admission == 1) 1 else null, true);
    for (1..waiting + 1) |admission| shown.add(.user, .{ .admission = admission, .state = .applied }, admission != 1, null, false);
    shown.add(.admission, .{ .admission = waiting + 1 }, true, waiting + 1, false);
    try std.testing.expect(shown.record.dropped != null);
    var counts: [100]u8 = undefined;
    try shown.reached(&counts);
    for (1..waiting + 2) |admission| try std.testing.expectEqual(@as(u8, 1), counts[admission]);
}

test "a transcript lists each recorded Message once, whole, before the copy that follows it" {
    const Make = struct {
        fn echo(position: u64, output: u64) T.Echo {
            // Each one moves the newest Message shown while it waited.
            return .{ .output = output, .end = output + 8, .position = position, .ordinal = 0, .message = .{ .admission = position }, .drawn = .{ .before = position, .after = position + 1 } };
        }
    };
    const opening: T.Marks.Mark = .{ .offset = 0, .cursor = .{ .end = 20 }, .admitted = 5 };
    var marks: T.Marks = .{};
    marks.record(opening);
    const Span = @typeInfo(@FieldType(T.Record, "dropped")).optional.child;
    var record: T.Record = .{};
    for (0..16) |index| record.add(Make.echo(5 + index, index * 4), true);
    // 64 live echoes fit; the 65th drops the oldest, keeping its span.
    for (0..64) |index| record.add(Make.echo(30 + index, 100 + 10 * index), false);
    try std.testing.expectEqual(@as(?Span, null), record.dropped);
    record.add(Make.echo(94, 740), false);
    try std.testing.expectEqual(@as(usize, 16), record.opening_count);
    try std.testing.expectEqual(@as(usize, 64), record.live_count);
    try std.testing.expectEqual(@as(?Span, .{ .low = 30, .high = 30, .end = 108, .drawn = .{ .before = 30, .after = 31 } }), record.dropped);
    // A second wrap widens the span to the next dropped echo, its end and
    // what showed by then.
    var wrapped = record;
    wrapped.add(Make.echo(95, 750), false);
    try std.testing.expectEqual(@as(?Span, .{ .low = 30, .high = 31, .end = 118, .drawn = .{ .before = 30, .after = 32 } }), wrapped.dropped);
    try std.testing.expectEqual(T.Listing.within(31, 30, 32, .{ .before = 30, .after = 32 }), T.plan(&marks, &wrapped, 105, 3).dropped);
    try std.testing.expectEqual(@as(u64, 118), T.plan(&marks, &wrapped, 105, 3).start);

    // The newest dropped echo ends after the front: the copy starts at its
    // end, so it shows only in the listing, and every opening echo is listed.
    // Live echoes wrapped while no later mark recorded: the opening mark
    // still names older pages and the seam.
    var result = T.plan(&marks, &record, 105, 3);
    try std.testing.expectEqual(@as(u64, 108), result.start);
    try std.testing.expect(result.gap);
    try std.testing.expectEqual(T.Listing.within(30, 30, 31, .{ .before = 30, .after = 31 }), result.dropped);
    try std.testing.expectEqual(T.Listing.within(20, 3, 5, null), result.unapplied);
    try std.testing.expectEqual(@as(u64, 20), result.older.?.end);
    try std.testing.expectEqual(@as(usize, 16), result.echo_count);
    // Before the front, it is listed as well; the copy starts at the front.
    result = T.plan(&marks, &record, 109, 3);
    try std.testing.expectEqual(@as(u64, 109), result.start);
    try std.testing.expect(result.dropped != null);
    // A front inside an echo lists that echo whole and starts after it.
    result = T.plan(&marks, &record, 112, 3);
    try std.testing.expectEqual(@as(u64, 118), result.start);
    try std.testing.expectEqual(@as(usize, 17), result.echo_count);
    try std.testing.expectEqual(@as(u64, 31), result.echoes[16].position);
    // Listed newest first: the live echo, the dropped span, then the opening's
    // older echoes; the gap's label precedes the seam.
    try std.testing.expectEqual(@as(u64, 31), result.next().?.echo.position);
    result.listed(result.next().?, null);
    try std.testing.expectEqual(T.Listing.within(30, 30, 31, .{ .before = 30, .after = 31 }), result.next());
    result.listed(result.next().?, null);
    for (0..16) |index| {
        try std.testing.expectEqual(@as(u64, 20 - index), result.next().?.echo.position);
        result.listed(result.next().?, null);
    }
    try std.testing.expectEqual(@as(?T.Listing, null), result.next());
    result.gap = false;
    try std.testing.expectEqual(T.Listing.within(20, 3, 5, null), result.next());
    result.listed(result.next().?, null);
    try std.testing.expectEqual(@as(?T.Listing, null), result.next());

    // A mark prunes echoes strictly before it; one starting at it stays.
    record.prune(107);
    try std.testing.expect(record.dropped != null);
    // The dropped span ends at 108: a mark there prunes it with its echoes.
    var at_end = record;
    at_end.prune(108);
    try std.testing.expectEqual(@as(?Span, null), at_end.dropped);
    record.prune(120);
    try std.testing.expectEqual(@as(?Span, null), record.dropped);
    try std.testing.expectEqual(@as(usize, 0), record.opening_count);
    try std.testing.expectEqual(@as(usize, 63), record.live_count);
    try std.testing.expectEqual(@as(u64, 120), record.live[0].output);
}

test "a range searches back from its end, or from the Message it must precede" {
    // Before the end: from that position; at or past it, from the end.
    try std.testing.expectEqual(@as(u64, 5), T.Listing.within(20, 3, 5, null).?.range.position);
    try std.testing.expectEqual(@as(u64, 0), T.Listing.within(20, 3, 21, null).?.range.position);
    try std.testing.expectEqual(@as(u64, 20), T.Listing.within(20, 3, 20, null).?.range.position);
    // Nothing lies below its lowest.
    try std.testing.expectEqual(@as(?T.Listing, null), T.Listing.within(20, 5, 5, null));
    // A mark without a cursor, or a read without a lowest, has no seam.
    var marks: T.Marks = .{};
    marks.record(.{ .offset = 0, .cursor = null, .admitted = 1 });
    try std.testing.expectEqual(@as(?T.Listing, null), T.plan(&marks, &T.Record{}, 0, 0).unapplied);
    marks.record(.{ .offset = 4, .cursor = .{ .end = 9 }, .admitted = 6 });
    try std.testing.expectEqual(@as(?T.Listing, null), T.plan(&marks, &T.Record{}, 4, null).unapplied);
    try std.testing.expectEqual(T.Listing.within(9, 2, 6, null), T.plan(&marks, &T.Record{}, 4, 2).unapplied);
}

test "the opening mark is retained through 64 marks and dropped by the 65th" {
    var marks: T.Marks = .{};
    marks.record(.{ .offset = 0, .cursor = null, .admitted = 1 });
    for (1..64) |index| marks.record(.{ .offset = index, .cursor = .{ .end = index }, .admitted = index + 1 });
    try std.testing.expectEqual(@as(u64, 0), marks.start(0).joined.offset);
    marks.record(.{ .offset = 64, .cursor = .{ .end = 64 }, .admitted = 65 });
    try std.testing.expectEqual(@as(u64, 1), marks.start(0).joined.offset);
}

test "a silent read marks its end only when complete and every shown Message is rowed" {
    const rowed: Messages = .{ .shown = 4, .answered = 4 };
    try std.testing.expectEqual(@as(?T.Boundary, .{ .output = 9, .cursor = .{ .end = 30 }, .admitted = 31 }), T.readEnd(rowed, false, 30, 9));
    try std.testing.expectEqual(@as(?T.Boundary, null), T.readEnd(rowed, true, 30, 9));
    try std.testing.expectEqual(@as(?T.Boundary, null), T.readEnd(.{ .shown = 5, .answered = 4 }, false, 30, 9));
    try std.testing.expectEqual(@as(?T.Boundary, .{ .output = 0, .cursor = null, .admitted = 1 }), T.readEnd(.{}, false, 0, 0));
}

test "a read keeps its newest boundaries beyond capacity" {
    var boundaries: T.Boundaries = .{};
    for (0..T.Marks.capacity + 2) |index| boundaries.add(.{ .output = index, .cursor = null, .admitted = index });
    try std.testing.expectEqual(@as(usize, T.Marks.capacity), boundaries.slice().len);
    try std.testing.expectEqual(@as(u64, 2), boundaries.slice()[0].output);
    try std.testing.expectEqual(@as(u64, T.Marks.capacity + 1), boundaries.slice()[T.Marks.capacity - 1].output);
}

test "a transcript joins at the first retained boundary or shows the gap after the newest evicted one" {
    var marks: T.Marks = .{};
    try std.testing.expectEqual(T.Marks.Start{ .gap = null }, marks.start(0));
    marks.record(.{ .offset = 0, .cursor = null, .admitted = 1 });
    marks.record(.{ .offset = 40, .cursor = .{ .end = 9, .before_position = 7 }, .admitted = 7 });
    try std.testing.expectEqual(T.Marks.Start{ .joined = .{ .offset = 0, .cursor = null, .admitted = 1 } }, marks.start(0));
    try std.testing.expectEqual(@as(u64, 7), marks.start(10).joined.cursor.?.before_position);
    // Exactly at a boundary's offset joins it.
    try std.testing.expectEqual(@as(u64, 40), marks.start(40).joined.offset);
    // Past every boundary, older pages continue before the newest one, not
    // the oldest and not none: rows between it and the front are the gap.
    try std.testing.expectEqual(@as(u64, 7), marks.start(41).gap.?.cursor.?.before_position);
    // An equal offset replaces the cursor rather than adding a boundary.
    marks.record(.{ .offset = 40, .cursor = .{ .end = 9, .before_position = 8 }, .admitted = 8 });
    try std.testing.expectEqual(@as(usize, 2), marks.count);
    try std.testing.expectEqual(@as(u64, 8), marks.start(10).joined.cursor.?.before_position);
    for (0..100) |index| marks.record(.{ .offset = 100 + index, .cursor = .{ .end = 200, .before_position = 100 + index }, .admitted = 100 + index });
    try std.testing.expectEqual(@as(usize, 64), marks.count);
    try std.testing.expectEqual(@as(u64, 136), marks.start(0).joined.offset);
    try std.testing.expectEqual(@as(u64, 199), marks.start(500).gap.?.cursor.?.before_position);
}
