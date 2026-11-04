//! The floor of a compaction that makes room (D217): when a compaction
//! request overflows, the next compaction leaves out the oldest drop units
//! until the rest fits a smaller target.
//!
//! A drop unit is a host Message after the Session's first, or a model
//! Operation with its tool results; it begins at the Message's position or
//! the Operation's admission position, and a floor drops every unit that
//! begins at or below it (`historical.HistoricalView.Floor`). Each level
//! aims at a quarter of the room the level before it did: level 1 at the
//! context window less the output reservation, at four bytes per token as
//! `turn_policy.comparedPressure` counts, so a catalog window larger than
//! the one served (D207) still recovers by level 3. A Message counts its
//! text's bytes and an Operation four bytes per output token plus its tool
//! results' bytes; what is always kept is not counted. The newest unit is
//! always kept: it is the work in hand.

const std = @import("std");
const model_capability = @import("../../model_capability.zig");
const protocol = @import("../../protocol.zig");
const rsql = @import("../rsql.zig");
const store_access = @import("../access.zig");
const store_schema = @import("../schema.zig");

pub const levels = 3;
const bytes_per_token = 4;

/// The bytes level `level` (1 to `levels`) aims a compaction request at.
pub fn target(window: u64, reservation: u64, level: u8) u64 {
    std.debug.assert(level >= 1 and level <= levels);
    const room = (window -| reservation) *| bytes_per_token;
    return room >> @intCast(2 * (level - 1));
}

/// The deeper floor a compaction goes to next, and its level.
pub const Choice = struct { floor: u64, level: u8 };

/// A deeper floor, with what `droppedEntries` counts from.
pub const Room = struct { choice: Choice, previous: u64, first_message: u64 };

/// The units walked newest first, and the floor each level reaches: just
/// below the oldest unit it keeps, the newer neighbour of the first unit
/// past the newest whose bytes, with every newer unit's, exceed that
/// level's target. No unit begins between them, so every entry at or below
/// the floor belongs to a dropped unit or is kept by kind.
pub const Walk = struct {
    targets: [levels]u64,
    floors: [levels]u64 = @splat(0),
    total: u64 = 0,
    units: u64 = 0,
    /// The begin the next page reads below.
    cursor: u64,
    page_rows: u64 = 0,

    pub fn init(window: u64, reservation: u64, boundary: u64) Walk {
        var targets: [levels]u64 = undefined;
        for (&targets, 1..) |*value, level| value.* = target(window, reservation, @intCast(level));
        return .{ .targets = targets, .cursor = boundary };
    }

    /// Takes the next older unit; false once level 1's floor is found,
    /// which every deeper level's precedes.
    pub fn take(walk: *Walk, begin: u64, size: u64) bool {
        std.debug.assert(begin < walk.cursor);
        const newer = walk.cursor;
        walk.cursor = begin;
        walk.total +|= size;
        walk.units += 1;
        if (walk.units == 1) return true;
        for (walk.targets, &walk.floors) |limit, *floor| {
            if (floor.* == 0 and walk.total > limit) floor.* = newer - 1;
        }
        return walk.floors[0] == 0;
    }

    pub fn done(walk: *const Walk) bool {
        return walk.floors[0] != 0;
    }

    /// The first level past `from` whose floor drops more than `previous`.
    pub fn deeper(walk: *const Walk, from: u8, previous: u64) ?Choice {
        var level = from + 1;
        while (level <= levels) : (level += 1) {
            const floor = walk.floors[level - 1];
            if (floor > previous) return .{ .floor = floor, .level = level };
        }
        return null;
    }

    pub fn visit(walk: *Walk, row: *const units.Row) bool {
        walk.page_rows += 1;
        return walk.take(row.start.get(), row.size);
    }
};

/// What the walk from compaction Operation ?1 starts from: its own floor
/// and level, its selected base's floor, the Session's first
/// user Message, and the model and reservation it was admitted with.
const floor_facts = rsql.Read(.{
    .sql = "SELECT current.admission_position,current.history_floor,current.history_level,base.history_floor AS base_floor," ++
        "coalesce((SELECT min(first.session_position) FROM conversation_entry first @index(conversation_entry_history) " ++
        "WHERE first.session_ref=current.session_ref AND first.entry_kind=1),0) AS first_message," ++
        "current.output_reservation,r.model FROM model_operation current " ++
        "JOIN session_revision r ON r.session_ref=current.session_ref AND r.revision=current.settings_revision " ++
        "LEFT JOIN model_operation base ON base.operation_id=(SELECT selected.operation_id " ++
        "FROM model_operation selected @index(model_operation_compaction_bases) WHERE selected.session_ref=current.session_ref AND selected.purpose=1 " ++
        "AND " ++ store_schema.resolutionIs("selected.resolution_code", .compacted) ++ " AND selected.admission_position<current.admission_position " ++
        "ORDER BY selected.admission_position DESC LIMIT 1) " ++
        "WHERE current.operation_id=?1 AND current.purpose=1",
    .Args = struct { operation: u64 },
    .Row = struct {
        admission_position: rsql.Positive,
        history_floor: ?rsql.Positive,
        history_level: ?u8,
        base_floor: ?rsql.Positive,
        first_message: u64,
        output_reservation: u64,
        model: protocol.Bounded(protocol.max_model_bytes),
    },
    .cardinality = .one,
});

const page_rows = 16;

/// The drop units of Operation ?1's Session that begin below ?2 and above
/// ?3, newest first: Messages but the first (?4), and the calls whose
/// output later requests send. A failed call holds nothing, and a
/// compaction's output is sent only while it is the base, which is kept.
const units = rsql.Read(.{
    .sql = "SELECT e.session_position AS start,content.byte_length AS size FROM model_operation current " ++
        "JOIN conversation_entry e @index(conversation_entry_history) ON e.session_ref=current.session_ref " ++
        "JOIN content ON content.content_id=e.content_id " ++
        "WHERE current.operation_id=?1 AND e.session_position<?2 AND e.session_position>?3 AND e.entry_kind=1 AND e.session_position!=?4 UNION ALL " ++
        "SELECT o.admission_position," ++ std.fmt.comptimePrint("coalesce(o.usage_output_tokens,0)*{d}", .{bytes_per_token}) ++ "+" ++
        "coalesce((SELECT sum(result.byte_length) FROM action_operation a JOIN content result ON result.content_id=a.resolution_content_id " ++
        "WHERE a.parent_operation_id=o.operation_id),0) FROM model_operation current " ++
        "JOIN model_operation o @index(model_operation_context_history) ON o.session_ref=current.session_ref " ++
        "WHERE current.operation_id=?1 AND o.admission_position<?2 AND o.admission_position>?3 AND " ++
        store_schema.oneOf("o.resolution_code", &store_schema.accepted_resolutions) ++ " AND o.purpose=0 " ++
        std.fmt.comptimePrint("ORDER BY 1 DESC LIMIT {d}", .{page_rows}),
    .Args = struct { operation: u64, below: u64, above: u64, first_message: u64 },
    .Row = struct { start: rsql.Positive, size: u64 },
    .cardinality = .each,
    .compound = true,
});

/// The floor and level the compaction after compaction Operation
/// `operation` overflowed goes to, or null when no level drops more: only
/// kept items remain, or level `levels` overflowed. Settlement asks it to
/// decide whether the Turn goes on, and admission again for the floor it
/// writes; nothing they read changes in between, so both get one answer.
/// Each page is a round; the walk stops at level 1's floor, so it reads
/// about as many units as fit that target, however long the history.
/// A failed step is `CorruptStore`.
pub fn deeperFloor(a: anytype, operation: u64) !?Room {
    var facts: floor_facts.Row = undefined;
    a.read(floor_facts, .{ .operation = operation }, &facts);
    try store_access.runAs(a, error.CorruptStore);
    const from: u8 = facts.history_level orelse 0;
    if (from >= levels) return null;
    const base_floor: u64 = if (facts.base_floor) |floor| floor.get() else 0;
    const previous: u64 = if (facts.history_floor) |floor| floor.get() else base_floor;
    var walk: Walk = .init(model_capability.contextWindow(facts.model.slice()), facts.output_reservation, facts.admission_position.get());
    while (!walk.done()) {
        walk.page_rows = 0;
        a.readEach(units, .{
            .operation = operation,
            .below = walk.cursor,
            .above = base_floor,
            .first_message = facts.first_message,
        }, page_rows, &walk);
        try store_access.runAs(a, error.CorruptStore);
        if (walk.page_rows < page_rows) break;
    }
    const choice = walk.deeper(from, previous) orelse return null;
    return .{ .choice = choice, .previous = previous, .first_message = facts.first_message };
}

/// The conversation entries of Operation ?1's Session above ?2 and at or
/// below ?3, but instructions and the first Message (?4): what a floor
/// drops beyond the one before it.
const dropped_entries = rsql.Read(.{
    .sql = "SELECT count(*) AS dropped FROM model_operation current " ++
        "JOIN conversation_entry e @index(conversation_entry_history) ON e.session_ref=current.session_ref " ++
        "WHERE current.operation_id=?1 AND e.session_position>?2 AND e.session_position<=?3 AND e.entry_kind!=2 AND e.session_position!=?4",
    .Args = struct { operation: u64, above: u64, floor: u64, first_message: u64 },
    .Row = struct { dropped: u64 },
    .cardinality = .one,
});

/// How many conversation entries `room`'s floor drops beyond the one
/// before it (D217's `dropped`): a range of the entry index as long as
/// what it drops, read once per compaction that makes room. A failed
/// step is `CorruptStore`.
pub fn droppedEntries(a: anytype, operation: u64, room: Room) !u64 {
    var row: dropped_entries.Row = undefined;
    a.read(dropped_entries, .{ .operation = operation, .above = room.previous, .floor = room.choice.floor, .first_message = room.first_message }, &row);
    try store_access.runAs(a, error.CorruptStore);
    return row.dropped;
}

test "each level aims at a quarter of the room the one before it did" {
    try std.testing.expectEqual(@as(u64, (128000 - 8000) * 4), target(128000, 8000, 1));
    try std.testing.expectEqual(@as(u64, (128000 - 8000)), target(128000, 8000, 2));
    try std.testing.expectEqual(@as(u64, (128000 - 8000) / 4), target(128000, 8000, 3));
    try std.testing.expectEqual(@as(u64, 0), target(100, 200, 1));
}

test "the walk keeps the newest unit and finds each level's floor below it" {
    // Targets 400, 100 and 25 bytes.
    var walk: Walk = .init(100, 0, 100);
    // The newest unit alone is past every target, and is kept.
    try std.testing.expect(walk.take(90, 500));
    try std.testing.expect(!walk.take(80, 0));
    try std.testing.expectEqual([levels]u64{ 89, 89, 89 }, walk.floors);
    // Running totals 10 (kept), 20, 30, 120 and 420.
    var spread: Walk = .init(100, 0, 100);
    for ([_]u64{ 10, 10, 10, 90, 300 }, 0..) |size, index| _ = spread.take(90 - 10 * index, size);
    try std.testing.expect(spread.done());
    try std.testing.expectEqual([levels]u64{ 59, 69, 79 }, spread.floors);
    try std.testing.expectEqual(Choice{ .floor = 59, .level = 1 }, spread.deeper(0, 0).?);
    try std.testing.expectEqual(Choice{ .floor = 69, .level = 2 }, spread.deeper(1, 59).?);
    // A level whose floor drops no more than the last is passed over.
    try std.testing.expectEqual(Choice{ .floor = 79, .level = 3 }, spread.deeper(0, 69).?);
    try std.testing.expectEqual(@as(?Choice, null), spread.deeper(3, 0));
    try std.testing.expectEqual(@as(?Choice, null), spread.deeper(0, 79));
}

test "a catalog window four times the served one recovers within the levels" {
    // ChatGPT sign-in (D207): the catalog says 1.05M tokens, the provider
    // serves 272k and code runs nearer three bytes per token than four, so
    // the provider refuses a request above 272k * 3 bytes. A long history
    // of 2 KiB units, newest first.
    const catalog: u64 = 1_050_000;
    const reservation: u64 = 8000;
    const served_bytes: u64 = 272_000 * 3;
    const unit: u64 = 2048;
    const count: u64 = 4000;
    var walk: Walk = .init(catalog, reservation, count + 1);
    var begin: u64 = count;
    while (begin > 0 and walk.take(begin, unit)) : (begin -= 1) {}
    // What a request at a floor sends: every unit that begins above it.
    const Kept = struct {
        fn bytes(floor: u64) u64 {
            return (count - floor) * unit;
        }
    };
    // The full request overflows, and so do levels 1 and 2, which aim at
    // the catalog's room and a quarter of it.
    try std.testing.expect(count * unit > served_bytes);
    var previous: u64 = 0;
    var from: u8 = 0;
    var requests: u64 = 1;
    const recovered = while (walk.deeper(from, previous)) |choice| {
        requests += 1;
        if (Kept.bytes(choice.floor) <= served_bytes) break choice;
        previous = choice.floor;
        from = choice.level;
    } else null;
    try std.testing.expectEqual(@as(u8, 3), recovered.?.level);
    try std.testing.expect(requests <= 1 + levels);
}
