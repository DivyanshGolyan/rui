const std = @import("std");
const Bounded = @import("../bounded.zig").Bounded;
const change_ring = @import("../change_ring.zig");
const session_list = @import("../session_list.zig");

/// The Session refs one page statement binds: a Session list page.
pub const page_size = session_list.session_list_page_size;

/// One Session ref bound by value into a page statement's IN list.
pub const RefSlot = Bounded(change_ring.id_bytes);

/// A page statement's `IN (?1,...,?8)` arguments: every slot by value, unused slots empty, so they match no Session.
pub const Args = struct { session0: RefSlot, session1: RefSlot, session2: RefSlot, session3: RefSlot, session4: RefSlot, session5: RefSlot, session6: RefSlot, session7: RefSlot };

comptime {
    if (@typeInfo(Args).@"struct".field_names.len != page_size) @compileError("a page statement binds one slot per Session of a page");
}

/// A page statement's source, refused at compile time unless it names each slot parameter exactly once. A shared
/// fragment that names `?1` itself (written for a one-Session read) would read every row's fact for the page's first
/// Session; a page statement correlates every fragment on its own row instead.
pub fn statement(comptime sql: []const u8) []const u8 {
    @setEvalBranchQuota(sql.len * page_size * 4 + 1000);
    inline for (1..page_size + 1) |n| {
        const name = std.fmt.comptimePrint("?{d}", .{n});
        var count: usize = 0;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, sql, at, name)) |found| : (at = found + name.len) {
            const next = found + name.len;
            if (next < sql.len and std.ascii.isDigit(sql[next])) continue;
            count += 1;
        }
        if (count != 1) @compileError(std.fmt.comptimePrint("a page statement names {s} {d} times; correlate shared fragments on the row's Session", .{ name, count }));
    }
    return sql;
}

/// Up to page_size Session refs as by-value statement slots; unused slots are empty.
pub fn refSlots(refs: []const change_ring.Id) error{CorruptStore}![page_size]RefSlot {
    var slots: PageSlots(error{CorruptStore}) = .{};
    try slots.bind(null, refs);
    return slots.refs;
}

/// The page-slot owner of one `.each` statement over a page's Session refs: it binds the refs, matches each row to the
/// slot of the ref it carries and settles the read. A row for a ref that was not asked for, or a second row for one, is
/// CorruptStore; so is a ref with no row (finish). A visitor keeps only its per-row action, on the slot slotOf names.
pub fn PageSlots(comptime Failure: type) type {
    return struct {
        const Self = @This();

        refs: [page_size]RefSlot = @splat(.{}),
        count: usize = 0,
        found: [page_size]bool = @splat(false),
        failure: ?Failure = null,

        /// Binds `refs` by value, so no ref bytes outlive this call; each item is a ref or has one at `field`.
        pub fn bind(self: *Self, comptime field: ?[]const u8, refs: anytype) error{CorruptStore}!void {
            std.debug.assert(refs.len <= page_size);
            self.* = .{ .count = refs.len };
            for (refs, self.refs[0..refs.len]) |*item, *slot| {
                const ref: []const u8 = if (field) |name| @field(item, name) else item;
                slot.* = RefSlot.from(ref) catch return error.CorruptStore;
            }
        }

        /// The statement's arguments, or null for an empty page, which queues nothing and adds no statement.
        pub fn args(self: *const Self) ?Args {
            if (self.count == 0) return null;
            var bound: Args = undefined;
            inline for (@typeInfo(Args).@"struct".field_names, 0..) |name, index| @field(bound, name) = self.refs[index];
            return bound;
        }

        /// The slot of the ref `ref` names, now found: refuses a ref not asked for and a second row for one.
        pub fn slotOf(self: *Self, ref: []const u8) error{CorruptStore}!usize {
            const index = for (self.refs[0..self.count], 0..) |*slot, index| {
                if (slot.eql(ref)) break index;
            } else return error.CorruptStore;
            if (self.found[index]) return error.CorruptStore;
            self.found[index] = true;
            return index;
        }

        /// A visitor's answer for one row: true to keep reading, or false with the row's refusal kept for finish.
        pub fn keep(self: *Self, outcome: Failure!void) bool {
            outcome catch |err| {
                self.failure = err;
                return false;
            };
            return true;
        }

        /// The read's outcome once its round ran: a refused row first, then a ref with no row.
        pub fn finish(self: *const Self) Failure!void {
            if (self.failure) |err| return err;
            for (self.found[0..self.count]) |found| if (!found) return error.CorruptStore;
        }
    };
}

const TestSlots = PageSlots(error{CorruptStore});

fn testRef(comptime n: u8) change_ring.Id {
    return @splat('a' + n);
}

fn testRefs(comptime count: usize) [count]change_ring.Id {
    var refs: [count]change_ring.Id = undefined;
    inline for (&refs, 0..) |*ref, n| ref.* = testRef(n);
    return refs;
}

/// Feeds the rows for `rows` as a statement would, through slotOf and keep, then settles.
fn testRead(slots: *TestSlots, rows: []const change_ring.Id) error{CorruptStore}!void {
    for (rows) |*row| if (!slots.keep(if (slots.slotOf(row)) |_| {} else |err| err)) break;
    return slots.finish();
}

test "SL-10: a page statement's rows match their own refs, one row per ref, for 0 to 8 refs in any order" {
    try expectMatchesOwnSlots();
    try expectRefusals();
    try expectEmptyPage();
}

fn expectMatchesOwnSlots() !void {
    inline for (.{ 1, 8 }) |count| {
        const refs = testRefs(count);
        var slots: TestSlots = .{};
        try slots.bind(null, &refs);
        const bound = slots.args().?;
        inline for (@typeInfo(Args).@"struct".field_names, 0..) |name, index| {
            const want: []const u8 = if (index < count) &refs[index] else "";
            try std.testing.expectEqualStrings(want, @field(bound, name).slice());
        }
        var index: usize = count;
        while (index > 0) {
            index -= 1;
            try std.testing.expectEqual(index, try slots.slotOf(&refs[index]));
        }
        try slots.finish();
    }
}

fn expectRefusals() !void {
    const refs = testRefs(3);
    var slots: TestSlots = .{};
    try slots.bind(null, &refs);
    try std.testing.expectError(error.CorruptStore, testRead(&slots, &.{ refs[1], testRef(5), refs[0], refs[2] }));
    try slots.bind(null, &refs);
    try std.testing.expectError(error.CorruptStore, testRead(&slots, &.{ refs[2], refs[0], refs[2], refs[1] }));
    try slots.bind(null, &refs);
    try std.testing.expectError(error.CorruptStore, testRead(&slots, &.{ refs[2], refs[0] }));
    // Binding again forgets the last page's rows and refusal.
    try slots.bind(null, &refs);
    try testRead(&slots, &.{ refs[2], refs[0], refs[1] });
}

fn expectEmptyPage() !void {
    var slots: TestSlots = .{};
    try slots.bind(null, &[_]change_ring.Id{});
    try std.testing.expect(slots.args() == null);
    try slots.finish();
    try std.testing.expectError(error.CorruptStore, testRead(&slots, &.{testRef(0)}));
}

test "page slots bind refs held at a field, and refuse a ref no slot can hold" {
    const Item = struct { session: []const u8 };
    var slots: TestSlots = .{};
    try slots.bind("session", &[_]Item{ .{ .session = "b" }, .{ .session = "a" } });
    try std.testing.expectEqual(@as(usize, 1), try slots.slotOf("a"));
    try std.testing.expectError(error.CorruptStore, slots.bind("session", &[_]Item{.{ .session = "too-long" }}));
}

test "page slots keep a per-row action's refusal for finish" {
    const Failure = error{ CorruptStore, ActionReadFailed };
    var slots: PageSlots(Failure) = .{};
    try slots.bind(null, &testRefs(1));
    try std.testing.expect(slots.keep({}));
    try std.testing.expect(!slots.keep(error.ActionReadFailed));
    _ = try slots.slotOf(&testRef(0));
    try std.testing.expectError(error.ActionReadFailed, slots.finish());
}
