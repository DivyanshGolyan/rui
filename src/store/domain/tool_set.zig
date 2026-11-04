//! Tool records and tool sets (D48, D49). A record is one tool as the model
//! is told about it, saved once by content; a set is an ordered list of
//! records, saved once by its digest. A Session's settings, and so every
//! revision and the Operations admitted under it, name the set they offer,
//! and a request renders the saved text, so a reworded built-in changes
//! only the sets saved after it.
const std = @import("std");
const tool_catalog = @import("../../tools.zig");
const rsql = @import("../rsql.zig");
const content_domain = @import("content.zig");

const Tool = tool_catalog.Tool;
const tool_count = std.enums.values(Tool).len;

const lookup_set = rsql.Read(.{
    .sql = "SELECT tool_set_id FROM tool_set WHERE digest=?1",
    .Args = struct { digest: [32]u8 },
    .Row = struct { tool_set_id: rsql.Positive },
    .cardinality = .optional,
});

const lookup_record = rsql.Read(.{
    .sql = "SELECT tool_record_id FROM tool_record WHERE name=?1 AND owner=?2 AND description_content_id=?3 AND input_schema_content_id=?4",
    .Args = struct { name: []const u8, owner: tool_catalog.Owner, description: u64, input_schema: u64 },
    .Row = struct { tool_record_id: rsql.Positive },
    .cardinality = .optional,
});

const insert_record = rsql.Write(.{
    .sql = "INSERT INTO tool_record(tool_record_id,name,owner,description_content_id,input_schema_content_id) VALUES(?1,?2,?3,?4,?5)",
    .Args = struct { id: u64, name: []const u8, owner: tool_catalog.Owner, description: u64, input_schema: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const insert_set = rsql.Write(.{
    .sql = "INSERT INTO tool_set(tool_set_id,digest,member_count) VALUES(?1,?2,?3)",
    .Args = struct { id: u64, digest: [32]u8, count: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const insert_member = rsql.Write(.{
    .sql = "INSERT INTO tool_set_member(tool_set_id,ordinal,tool_record_id) VALUES(?1,?2,?3)",
    .Args = struct { set: u64, ordinal: u64, record: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// A Rui SQL expression for the built-in tools the set `set_column` names,
/// as a tools_mask: each member's bit, and a bit past every tool's for a
/// member that is no built-in, which decoding refuses. It bridges readers
/// that still name tools by `Tool` until the wire names them.
pub fn maskSql(comptime set_column: []const u8) []const u8 {
    comptime {
        var cases: []const u8 = "";
        for (std.enums.values(Tool)) |tool| cases = cases ++ std.fmt.comptimePrint(" WHEN '{s}' THEN {d}", .{ @tagName(tool), tool_catalog.toolBit(tool) });
        return "(SELECT coalesce(sum(CASE tool.name" ++ cases ++ std.fmt.comptimePrint(" ELSE {d} END),0) ", .{@as(u16, tool_catalog.all_tools_mask) + 1}) ++
            "FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=" ++ set_column ++ ")";
    }
}

/// SQL for the mask of every built-in in any set of `session`'s revisions
/// up to `revision`, until the wire names tools.
pub fn everMaskSql(comptime session: []const u8, comptime revision: []const u8) []const u8 {
    comptime {
        var sum: []const u8 = "(0";
        for (std.enums.values(Tool)) |tool| sum = sum ++ std.fmt.comptimePrint(
            "+CASE WHEN EXISTS(SELECT 1 FROM session_revision ever JOIN tool_set_member ever_member ON ever_member.tool_set_id=ever.tool_set_id " ++
                "JOIN tool_record ever_tool ON ever_tool.tool_record_id=ever_member.tool_record_id " ++
                "WHERE ever.session_ref={s} AND ever.revision<={s} AND ever_tool.name='{s}') THEN {d} ELSE 0 END",
            .{ session, revision, @tagName(tool), tool_catalog.toolBit(tool) },
        );
        return sum ++ ")";
    }
}

/// The records of `set`, in `Tool` order.
pub const Members = struct {
    records: [tool_count]*const tool_catalog.Record = undefined,
    len: usize = 0,

    pub fn of(set: tool_catalog.ToolSet) Members {
        var out: Members = .{};
        for (std.enums.values(Tool)) |tool| if (set.contains(tool)) {
            out.records[out.len] = tool_catalog.record(tool);
            out.len += 1;
        };
        return out;
    }

    pub fn slice(self: *const Members) []const *const tool_catalog.Record {
        return self.records[0..self.len];
    }
};

/// What `ensure` reads and keeps across its rounds; the caller holds it.
pub const Ensure = struct {
    members: Members,
    digest: [32]u8,
    set: lookup_set.Result = null,
    pairs: [tool_count]content_domain.Pair = undefined,
    descriptions: [tool_count]content_domain.Import = undefined,
    schemas: [tool_count]content_domain.Import = undefined,
    existing: [tool_count]lookup_record.Result = undefined,
    content_ids: [tool_count][2]u64 = undefined,

    pub fn init(set: tool_catalog.ToolSet) Ensure {
        const members = Members.of(set);
        return .{ .members = members, .digest = tool_catalog.setDigest(members.slice()) };
    }
};

/// Queues the reads `finish` follows: the set by its digest, and each
/// member's two texts. A configure queues them in its own first round.
pub fn lookup(a: anytype, state: *Ensure) void {
    a.read(lookup_set, .{ .digest = state.digest }, &state.set);
    for (state.members.slice(), 0..) |record, index| {
        state.descriptions[index] = .ofBytes(record.description, false);
        state.schemas[index] = .ofBytes(record.input_schema, false);
        content_domain.lookupPair(a, &state.descriptions[index], &state.schemas[index], &state.pairs[index]);
    }
}

/// After `lookup`'s round: the id of the set `state` names, the saved one
/// or one queued now with whatever records and content it needs. A new set
/// runs one more round on `a`, a write Access, when some record may exist.
pub fn finish(a: anytype, state: *Ensure) !u64 {
    if (state.set) |row| return row.tool_set_id.get();
    const records = state.members.slice();

    // A record can exist only when both its texts already do.
    var known = false;
    for (records, 0..) |record, index| {
        content_domain.foundPair(&state.pairs[index], &state.descriptions[index], &state.schemas[index]);
        const both = state.descriptions[index].found != null and state.schemas[index].found != null;
        state.content_ids[index] = .{
            try content_domain.importBytes(a, &state.descriptions[index], record.description),
            try content_domain.importBytes(a, &state.schemas[index], record.input_schema),
        };
        state.existing[index] = null;
        if (both) {
            known = true;
            a.read(lookup_record, .{ .name = record.name, .owner = record.owner, .description = state.content_ids[index][0], .input_schema = state.content_ids[index][1] }, &state.existing[index]);
        }
    }
    if (known) try a.run();

    const set_id = try a.identity(.tool_set_id);
    a.write(insert_set, .{ .id = set_id, .digest = state.digest, .count = records.len });
    for (records, 0..) |record, index| {
        const record_id = if (state.existing[index]) |row| row.tool_record_id.get() else id: {
            const id = try a.identity(.tool_record_id);
            a.write(insert_record, .{ .id = id, .name = record.name, .owner = record.owner, .description = state.content_ids[index][0], .input_schema = state.content_ids[index][1] });
            break :id id;
        };
        a.write(insert_member, .{ .set = set_id, .ordinal = index, .record = record_id });
    }
    return set_id;
}
