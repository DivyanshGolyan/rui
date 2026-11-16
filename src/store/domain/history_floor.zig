const std = @import("std");
const output_item = @import("../../output_item.zig");
const model_capability = @import("../../model_capability.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const rsql = @import("../rsql.zig");
const tool_fulfillment = @import("tool_fulfillment.zig");
const store_schema = @import("../schema.zig");

pub const levels = 3;
const bytes_per_token = 4;

pub fn target(window: u64, reservation: u64, level: u8) u64 {
    std.debug.assert(level >= 1 and level <= levels);
    const room = (window -| reservation) *| bytes_per_token;
    return room >> @intCast(2 * (level - 1));
}

pub const Choice = struct { floor: u64, level: u8 };

pub const Room = struct { choice: Choice, previous: u64, first_message: u64 };

pub const Walk = struct {
    targets: [levels]u64,
    floors: [levels]u64 = @splat(0),
    total: u64 = 0,
    units: u64 = 0,
    cursor: u64,
    page_rows: u64 = 0,

    pub fn init(window: u64, reservation: u64, boundary: u64) Walk {
        var targets: [levels]u64 = undefined;
        for (&targets, 1..) |*value, level| value.* = target(window, reservation, @intCast(level));
        return .{ .targets = targets, .cursor = boundary };
    }

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

const floor_facts = rsql.Read(.{
    .sql = "SELECT current.admission_position,current.history_floor,current.history_level,base.history_floor AS base_floor,coalesce(base.admission_position,0) AS frontier," ++
        "coalesce((SELECT min(first.session_position) FROM conversation_entry first @index(conversation_entry_history) " ++
        "WHERE first.session_ref=current.session_ref AND first.entry_kind=1),0) AS first_message," ++
        "current.output_reservation,current.context_window,r.model,base_revision.model AS base_model FROM model_operation current " ++
        "JOIN session_revision r ON r.session_ref=current.session_ref AND r.revision=current.settings_revision " ++
        "LEFT JOIN model_operation base ON base.operation_id=(SELECT selected.operation_id " ++
        "FROM model_operation selected @index(model_operation_compaction_bases) WHERE selected.session_ref=current.session_ref AND selected.purpose=1 " ++
        "AND " ++ store_schema.resolutionIs("selected.resolution_code", .compacted) ++ " AND selected.admission_position<current.admission_position " ++
        "ORDER BY selected.admission_position DESC LIMIT 1) " ++
        "LEFT JOIN session_revision base_revision ON base_revision.session_ref=base.session_ref AND base_revision.revision=base.settings_revision " ++
        "WHERE current.operation_id=?1 AND current.purpose=1",
    .Args = struct { operation: u64 },
    .Row = struct {
        admission_position: rsql.Positive,
        history_floor: ?rsql.Positive,
        history_level: ?u8,
        base_floor: ?rsql.Positive,
        frontier: u64,
        first_message: u64,
        output_reservation: u64,
        context_window: u64,
        model: Bounded(model_capability.max_model_bytes),
        base_model: ?Bounded(model_capability.max_model_bytes),
    },
    .cardinality = .one,
});

const page_rows = 16;

pub fn firstMessageSkillSql(comptime e: []const u8, comptime first_message: []const u8) []const u8 {
    return "(" ++ e ++ ".entry_kind=4 AND EXISTS(SELECT 1 FROM conversation_entry owner WHERE owner.source_admission_id=" ++ e ++
        ".source_skill_admission_id AND owner.session_position=" ++ first_message ++ "))";
}

pub const item_bytes_sql = "coalesce((SELECT bag.byte_length FROM content bag WHERE bag.content_id=i.extras_content_id),0) + " ++
    "(SELECT coalesce(sum(coalesce(p.text_length,text.byte_length,0)+coalesce(bag.byte_length,0)),0) FROM model_output_part p " ++
    "LEFT JOIN content text ON text.content_id=p.text_content_id LEFT JOIN content bag ON bag.content_id=p.extras_content_id " ++
    "WHERE p.operation_id=i.operation_id AND p.item_ordinal=i.item_ordinal) + " ++
    "coalesce((SELECT name.byte_length+call_id.byte_length+arguments.byte_length FROM model_tool_call tool_call " ++
    "JOIN content name ON name.content_id=tool_call.name_content_id JOIN content call_id ON call_id.content_id=tool_call.call_id_content_id " ++
    "JOIN content arguments ON arguments.content_id=tool_call.arguments_content_id " ++
    "WHERE tool_call.operation_id=i.operation_id AND tool_call.item_ordinal=i.item_ordinal AND tool_call.session_ref=i.session_ref),0)";

const units = rsql.Read(.{
    .sql = "SELECT e.session_position AS start,content.byte_length+coalesce((SELECT sum(body.byte_length) FROM message_skill skill " ++
        "JOIN content body ON body.content_id=skill.content_id WHERE skill.admission_id=e.source_admission_id),0) AS size FROM model_operation current " ++
        "JOIN conversation_entry e @index(conversation_entry_history) ON e.session_ref=current.session_ref " ++
        "JOIN content ON content.content_id=e.content_id " ++
        "WHERE current.operation_id=?1 AND e.session_position<?2 AND e.session_position>?3 AND e.entry_kind=1 AND e.session_position!=?4 UNION ALL " ++
        "SELECT o.admission_position,(SELECT coalesce(sum(" ++ item_bytes_sql ++ "),0) FROM model_output_item i WHERE i.operation_id=o.operation_id)+" ++
        "coalesce((SELECT sum(result.byte_length) FROM action_operation a JOIN content result ON result.content_id=" ++ tool_fulfillment.actionContentSql("a") ++ " " ++
        "WHERE a.parent_operation_id=o.operation_id),0) FROM model_operation current " ++
        "JOIN model_operation o @index(model_operation_context_history) ON o.session_ref=current.session_ref " ++
        "WHERE current.operation_id=?1 AND o.admission_position<?2 AND o.admission_position>?3 AND o.admission_position>?5 AND " ++
        store_schema.oneOf("o.resolution_code", &store_schema.accepted_resolutions) ++ " AND o.purpose=0 " ++
        std.fmt.comptimePrint("ORDER BY 1 DESC LIMIT {d}", .{page_rows}),
    .Args = struct { operation: u64, below: u64, above: u64, first_message: u64, frontier: u64 },
    .Row = struct { start: rsql.Positive, size: u64 },
    .cardinality = .each,
    .compound = true,
});

const base_floor_read = rsql.Read(.{
    .sql = "SELECT base.history_floor,r.model FROM model_operation base @index(model_operation_compaction_bases) " ++
        "JOIN session_revision r ON r.session_ref=base.session_ref AND r.revision=base.settings_revision " ++
        "WHERE base.session_ref=?1 AND base.purpose=1 AND " ++
        store_schema.resolutionIs("base.resolution_code", .compacted) ++ " AND base.admission_position<?2 ORDER BY base.admission_position DESC LIMIT 1",
    .Args = struct { session: []const u8, boundary: u64 },
    .Row = struct { history_floor: ?rsql.Positive, model: Bounded(model_capability.max_model_bytes) },
    .cardinality = .optional,
});

pub const InheritedFloor = struct {
    found: base_floor_read.Result = undefined,

    pub fn queue(read: *InheritedFloor, a: anytype, session: []const u8, boundary: u64) void {
        a.read(base_floor_read, .{ .session = session, .boundary = boundary }, &read.found);
    }

    pub fn floor(read: *const InheritedFloor, model: []const u8) ?u64 {
        const row = read.found orelse return null;
        if (!output_item.Kind.compaction.replayableTo(row.model.slice(), model, .selected_base)) return null;
        return if (row.history_floor) |found| found.get() else null;
    }
};

pub const FloorSearch = struct {
    operation: u64,
    read: union { facts: floor_facts.Row, walk: Walk } = undefined,
    from: u8 = levels,
    paged: bool = false,
    base_floor: u64 = 0,
    previous: u64 = 0,
    first_message: u64 = 0,
    frontier: u64 = 0,

    pub fn start(search: *FloorSearch, a: anytype) void {
        search.read = .{ .facts = undefined };
        a.read(floor_facts, .{ .operation = search.operation }, &search.read.facts);
    }

    pub fn next(search: *FloorSearch, a: anytype) bool {
        if (!search.paged) {
            const facts = &search.read.facts;
            const from: u8 = facts.history_level orelse 0;
            if (from >= levels) return false;
            const compatible = if (facts.base_model) |*model| output_item.Kind.compaction.replayableTo(model.slice(), facts.model.slice(), .selected_base) else true;
            search.from = from;
            search.base_floor = if (compatible) (if (facts.base_floor) |floor| floor.get() else 0) else 0;
            search.previous = if (facts.history_floor) |floor| floor.get() else search.base_floor;
            search.first_message = facts.first_message;
            search.frontier = if (compatible) facts.frontier else 0;
            const walk: Walk = .init(facts.context_window, facts.output_reservation, facts.admission_position.get());
            search.read = .{ .walk = walk };
        } else if (search.read.walk.page_rows < page_rows) return false;
        const walk = &search.read.walk;
        if (walk.done()) return false;
        walk.page_rows = 0;
        a.readEach(units, .{
            .operation = search.operation,
            .below = walk.cursor,
            .above = search.base_floor,
            .first_message = search.first_message,
            .frontier = search.frontier,
        }, page_rows, walk);
        search.paged = true;
        return true;
    }

    pub fn room(search: *const FloorSearch) ?Room {
        if (search.from >= levels) return null;
        const choice = search.read.walk.deeper(search.from, search.previous) orelse return null;
        return .{ .choice = choice, .previous = search.previous, .first_message = search.first_message };
    }
};

const dropped_entries = rsql.Read(.{
    .sql = "SELECT count(*) AS dropped FROM model_operation current " ++
        "JOIN conversation_entry e @index(conversation_entry_history) ON e.session_ref=current.session_ref " ++
        "WHERE current.operation_id=?1 AND e.session_position>?2 AND e.session_position<=?3 AND e.entry_kind!=2 AND e.session_position!=?4 " ++
        "AND NOT " ++ firstMessageSkillSql("e", "?4"),
    .Args = struct { operation: u64, above: u64, floor: u64, first_message: u64 },
    .Row = struct { dropped: u64 },
    .cardinality = .one,
});

pub const DroppedEntries = struct {
    row: dropped_entries.Row = undefined,

    pub fn queue(read: *DroppedEntries, a: anytype, operation: u64, room: Room) void {
        a.read(dropped_entries, .{ .operation = operation, .above = room.previous, .floor = room.choice.floor, .first_message = room.first_message }, &read.row);
    }

    pub fn dropped(read: *const DroppedEntries) u64 {
        return read.row.dropped;
    }
};

test "each level aims at a quarter of the room the one before it did" {
    try std.testing.expectEqual(@as(u64, (128000 - 8000) * 4), target(128000, 8000, 1));
    try std.testing.expectEqual(@as(u64, (128000 - 8000)), target(128000, 8000, 2));
    try std.testing.expectEqual(@as(u64, (128000 - 8000) / 4), target(128000, 8000, 3));
    try std.testing.expectEqual(@as(u64, 0), target(100, 200, 1));
}

test "the walk keeps the newest unit and finds each level's floor below it" {
    var walk: Walk = .init(100, 0, 100);
    try std.testing.expect(walk.take(90, 500));
    try std.testing.expect(!walk.take(80, 0));
    try std.testing.expectEqual([levels]u64{ 89, 89, 89 }, walk.floors);
    var spread: Walk = .init(100, 0, 100);
    for ([_]u64{ 10, 10, 10, 90, 300 }, 0..) |size, index| _ = spread.take(90 - 10 * index, size);
    try std.testing.expect(spread.done());
    try std.testing.expectEqual([levels]u64{ 59, 69, 79 }, spread.floors);
    try std.testing.expectEqual(Choice{ .floor = 59, .level = 1 }, spread.deeper(0, 0).?);
    try std.testing.expectEqual(Choice{ .floor = 69, .level = 2 }, spread.deeper(1, 59).?);
    try std.testing.expectEqual(Choice{ .floor = 79, .level = 3 }, spread.deeper(0, 69).?);
    try std.testing.expectEqual(@as(?Choice, null), spread.deeper(3, 0));
    try std.testing.expectEqual(@as(?Choice, null), spread.deeper(0, 79));
}

test "a catalog window four times the served one recovers within the levels" {
    const catalog: u64 = 1_050_000;
    const reservation: u64 = 8000;
    const served_bytes: u64 = 272_000 * 3;
    const unit: u64 = 2048;
    const count: u64 = 4000;
    var walk: Walk = .init(catalog, reservation, count + 1);
    var begin: u64 = count;
    while (begin > 0 and walk.take(begin, unit)) : (begin -= 1) {}
    const Kept = struct {
        fn bytes(floor: u64) u64 {
            return (count - floor) * unit;
        }
    };
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
