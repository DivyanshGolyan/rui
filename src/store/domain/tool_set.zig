//! Tool records and tool sets (D48, D49). A record is one tool as the model
//! is told about it, saved once by content; a set is an ordered list of
//! records, saved once by its digest. A Session's settings, and so every
//! revision and the Operations admitted under it, name the set they offer,
//! and a request renders the saved text, so a reworded built-in changes
//! only the sets saved after it.
const std = @import("std");
const command_input = @import("../../command_input.zig");
const content_string = @import("../../content_string.zig");
const tool_name = @import("../../tool_name.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const tool_record = @import("../../tool_record.zig");
const rsql = @import("../rsql.zig");
const content_domain = @import("content.zig");

const lookup_set = rsql.Read(.{
    .sql = "SELECT tool_set_id FROM tool_set WHERE digest=?1",
    .Args = struct { digest: [32]u8 },
    .Row = struct { tool_set_id: rsql.Positive },
    .cardinality = .optional,
});

const lookup_record = rsql.Read(.{
    .sql = "SELECT tool_record_id FROM tool_record WHERE name=?1 AND owner=?2 AND server=?3 AND read_only=?4 AND description_content_id=?5 AND input_schema_content_id=?6",
    .Args = struct { name: []const u8, owner: tool_record.Owner, server: []const u8, read_only: bool, description: u64, input_schema: u64 },
    .Row = struct { tool_record_id: rsql.Positive },
    .cardinality = .optional,
});

const insert_record = rsql.Write(.{
    .sql = "INSERT INTO tool_record(tool_record_id,name,owner,server,read_only,description_content_id,input_schema_content_id) VALUES(?1,?2,?3,?4,?5,?6,?7)",
    .Args = struct { id: u64, name: []const u8, owner: tool_record.Owner, server: []const u8, read_only: bool, description: u64, input_schema: u64 },
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

/// SQL for loaded intent on a Session or configuration revision: its explicit
/// loaded set, otherwise all configured names. Frozen offers live on Operations.
pub fn offeredSetSql(comptime revision_alias: []const u8) []const u8 {
    return "coalesce(" ++ revision_alias ++ ".loaded_tool_set_id," ++ revision_alias ++ ".tool_set_id)";
}

/// A Rui SQL expression for the names of the set `set_column`'s members,
/// joined by commas in no set order, since ordering them would sort; NULL
/// for an empty set. A name has no comma (`tool_name.valid`), and
/// a Session's names, as configure bounds them, fit `max_names_bytes`.
pub fn namesSql(comptime set_column: []const u8) []const u8 {
    return "(SELECT @list(tool.name) FROM tool_set_member member " ++
        "JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=" ++ set_column ++ ")";
}

/// The longest `namesSql` text of a Session's set.
pub const max_names_bytes = tool_name.max_names_bytes;

/// A Session's member named `name` in the source set `source`, as
/// member `ordinal` of `set`. One row, or the source lacks it.
const insert_selected_member = rsql.Write(.{
    .sql = "INSERT INTO tool_set_member(tool_set_id,ordinal,tool_record_id) SELECT ?1,?2,member.tool_record_id " ++
        "FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=?3 AND tool.name=?4",
    .Args = struct { set: u64, ordinal: u64, source: u64, name: []const u8 },
    .expect = .{ .counted = .{ .otherwise = error.CorruptStore } },
});

/// The record with these name, owner and texts, as member `ordinal` of
/// `set`. One row, or the record was never saved.
const insert_tool_set_member = rsql.Write(.{
    .sql = "INSERT INTO tool_set_member(tool_set_id,ordinal,tool_record_id) SELECT ?1,?2,tool.tool_record_id FROM tool_record tool " ++
        "JOIN content description ON description.content_id=tool.description_content_id " ++
        "JOIN content input_schema ON input_schema.content_id=tool.input_schema_content_id " ++
        "WHERE tool.name=?3 AND tool.owner=?4 AND tool.server=?5 AND tool.read_only=?6 AND description.digest=?7 AND description.byte_length=?8 AND description.private=0 " ++
        "AND input_schema.digest=?9 AND input_schema.byte_length=?10 AND input_schema.private=0",
    .Args = struct {
        set: u64,
        ordinal: u64,
        name: []const u8,
        owner: tool_record.Owner,
        server: []const u8,
        read_only: bool,
        description: [32]u8,
        description_bytes: u64,
        input_schema: [32]u8,
        input_schema_bytes: u64,
    },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// The digest of `tool_set`'s set: its records, in order.
pub fn toolSetDigest(tool_set: *const tool_record.HostToolSet) [32]u8 {
    var digest: tool_record.SetDigest = .init();
    for (tool_set.digests) |*each| digest.add(each);
    return digest.final();
}

/// How many records one transaction of `ensureRecords` saves: each
/// imports at most its two texts, within an Access's `max_inserted`.
pub const records_per_transaction = 2;

/// What `ensureRecords` reads for one transaction's records.
pub const RecordReads = struct {
    pairs: [records_per_transaction]content_domain.Pair = undefined,
    descriptions: [records_per_transaction]content_domain.Import = undefined,
    schemas: [records_per_transaction]content_domain.Import = undefined,
    existing: [records_per_transaction]lookup_record.Result = undefined,
};

/// Saves each of `records` and its texts that no row holds yet, on `a`, a
/// write Access the caller commits. A record that exists is left as it is.
pub fn ensureRecords(a: anytype, records: []const tool_record.Record, reads: *RecordReads) !void {
    std.debug.assert(records.len <= records_per_transaction);
    for (records, 0..) |*each, index| {
        reads.descriptions[index] = .ofBytes(each.description, false);
        reads.schemas[index] = .ofBytes(each.input_schema, false);
        content_domain.lookupPair(a, &reads.descriptions[index], &reads.schemas[index], &reads.pairs[index]);
    }
    try a.run();
    // A record can exist only when both its texts already do.
    var content_ids: [records_per_transaction][2]u64 = undefined;
    var known = false;
    for (records, 0..) |*each, index| {
        content_domain.foundPair(&reads.pairs[index], &reads.descriptions[index], &reads.schemas[index]);
        const both = reads.descriptions[index].found != null and reads.schemas[index].found != null;
        content_ids[index] = .{
            try content_domain.importBytes(a, &reads.descriptions[index], each.description),
            try content_domain.importBytes(a, &reads.schemas[index], each.input_schema),
        };
        reads.existing[index] = null;
        if (both) {
            known = true;
            a.read(lookup_record, .{ .name = each.name, .owner = each.owner, .server = each.server, .read_only = each.read_only, .description = content_ids[index][0], .input_schema = content_ids[index][1] }, &reads.existing[index]);
        }
    }
    if (known) try a.run();
    for (records, 0..) |*each, index| if (reads.existing[index] == null) {
        const id = try a.identity(.tool_record_id);
        a.write(insert_record, .{ .id = id, .name = each.name, .owner = each.owner, .server = each.server, .read_only = each.read_only, .description = content_ids[index][0], .input_schema = content_ids[index][1] });
    };
}

/// The tool_set's saved set, by its digest, and whether host_tool_set
/// names it already.
const lookup_tool_set = rsql.Read(.{
    .sql = "SELECT tool_set_id,EXISTS(SELECT 1 FROM host_tool_set host WHERE host.tool_set_id=tool_set.tool_set_id) AS current FROM tool_set WHERE digest=?1",
    .Args = struct { digest: [32]u8 },
    .Row = struct { tool_set_id: rsql.Positive, current: bool },
    .cardinality = .optional,
});

/// host_tool_set's one row, on the first save.
const start_host_tool_set = rsql.Write(.{
    .sql = "INSERT INTO host_tool_set(slot,tool_set_id) SELECT 1,?1 WHERE NOT EXISTS(SELECT 1 FROM host_tool_set)",
    .Args = struct { set: u64 },
    .expect = .{ .at_most = 1 },
});

const update_host_tool_set = rsql.Write(.{
    .sql = "UPDATE host_tool_set SET tool_set_id=?1 WHERE slot=1",
    .Args = struct { set: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Queues reading the tool_set's saved set, by `digest`.
pub fn lookupHostToolSet(a: anytype, digest: *const [32]u8, set: *lookup_tool_set.Result) void {
    a.read(lookup_tool_set, .{ .digest = digest.* }, set);
}

pub const ToolSetLookup = lookup_tool_set.Result;

/// Queues making `set_id` the Host's tool_set, the one the next start
/// reads back.
pub fn pointHostToolSet(a: anytype, set_id: u64) void {
    a.write(start_host_tool_set, .{ .set = set_id });
    a.write(update_host_tool_set, .{ .set = set_id });
}

/// The Host's tool_set set and its record count; none before the first
/// tool_set is saved.
const saved_tool_set = rsql.Read(.{
    .sql = "SELECT host.tool_set_id,tool_set.member_count FROM host_tool_set host JOIN tool_set ON tool_set.tool_set_id=host.tool_set_id",
    .Args = struct {},
    .Row = struct { tool_set_id: rsql.Positive, member_count: u64 },
    .cardinality = .optional,
});

pub const SavedHostToolSet = saved_tool_set.Result;

/// One round: the Host's tool_set set.
pub fn savedHostToolSetOf(a: anytype) !SavedHostToolSet {
    var set: SavedHostToolSet = null;
    a.read(saved_tool_set, .{}, &set);
    try a.run();
    return set;
}

/// One round: the tool_set set `set`'s records from `ordinal`, at most a
/// batch and `rows.len`, in order; how many it read.
pub fn hostToolRecordsOf(a: anytype, set: u64, ordinal: usize, rows: []host_tool_records.Row) !usize {
    var batch: RecordBatch = .{ .rows = rows };
    a.readEach(host_tool_records, .{ .set = set, .ordinal = ordinal }, @min(rows.len, host_tool_record_batch), &batch);
    try a.run();
    return batch.count;
}

const RecordBatch = struct {
    rows: []host_tool_records.Row,
    count: usize = 0,

    pub fn visit(batch: *RecordBatch, row: *const host_tool_records.Row) bool {
        batch.rows[batch.count] = row.*;
        batch.count += 1;
        return true;
    }
};

/// A tool_set set's members from ordinal ?2 on: each record and where
/// its texts are.
pub const host_tool_records = rsql.Read(.{
    .sql = "SELECT member.ordinal,tool.name,tool.owner,tool.server,tool.read_only,description.content_id AS description_id,description.byte_length AS description_length," ++
        "description.digest AS description_digest,description.private AS description_private,input_schema.content_id AS schema_id," ++
        "input_schema.byte_length AS schema_length,input_schema.digest AS schema_digest,input_schema.private AS schema_private " ++
        "FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id " ++
        "JOIN content description ON description.content_id=tool.description_content_id " ++
        "JOIN content input_schema ON input_schema.content_id=tool.input_schema_content_id " ++
        std.fmt.comptimePrint("WHERE member.tool_set_id=?1 AND member.ordinal>=?2 ORDER BY member.ordinal LIMIT {d}", .{host_tool_record_batch}),
    .Args = struct { set: u64, ordinal: u64 },
    .Row = struct {
        ordinal: u64,
        name: Bounded(tool_record.max_name_bytes),
        owner: tool_record.Owner,
        server: Bounded(tool_record.max_server_bytes),
        read_only: bool,
        description_id: rsql.Positive,
        description_length: u64,
        description_digest: [32]u8,
        description_private: bool,
        schema_id: rsql.Positive,
        schema_length: u64,
        schema_digest: [32]u8,
        schema_private: bool,
    },
    .cardinality = .each,
});

/// How many records one round of `host_tool_records` reads.
pub const host_tool_record_batch = 16;

/// Queues saving `tool_set`'s set, whose every record is saved, as `set_id`.
pub fn insertHostToolSet(a: anytype, tool_set: *const tool_record.HostToolSet, digest: *const [32]u8, set_id: u64) void {
    a.write(insert_set, .{ .id = set_id, .digest = digest.*, .count = tool_set.records.len });
    for (tool_set.records, 0..) |*each, ordinal| a.write(insert_tool_set_member, .{
        .set = set_id,
        .ordinal = ordinal,
        .name = each.name,
        .owner = each.owner,
        .server = each.server,
        .read_only = each.read_only,
        .description = content_string.digest(each.description),
        .description_bytes = each.description.len,
        .input_schema = content_string.digest(each.input_schema),
        .input_schema_bytes = each.input_schema.len,
    });
}

/// The set a configure saves: the tool_set's records `names` names, in
/// name order, and the digest it is saved under.
pub const Selection = struct {
    names: *const command_input.ToolsField,
    digest: [32]u8,
    set: lookup_set.Result = null,

    /// Null when the tool_set lacks one of `names`.
    pub fn of(tool_set: *const tool_record.HostToolSet, names: *const command_input.ToolsField) ?Selection {
        var digest: tool_record.SetDigest = .init();
        var each = names.iterator();
        while (each.next()) |name| digest.add(&tool_set.digests[tool_set.find(name) orelse return null]);
        return .{ .names = names, .digest = digest.final() };
    }

    /// Selects from an already saved set, not today's tool_set. The digest
    /// and finishSelection's inserted members must use the same source.
    pub fn ofSaved(a: anytype, source_set: u64, names: *const command_input.ToolsField) !Selection {
        var selected: SavedSelection = .{ .names = names };
        a.readEach(selection_records, .{ .set = source_set }, tool_name.max_tools + 1, &selected);
        try a.run();
        if (selected.count != names.count) return error.CorruptStore;
        return .{ .names = names, .digest = selected.digest.final() };
    }
};

const selection_records = rsql.Read(.{
    .sql = "SELECT tool.name,tool.owner,tool.server,tool.read_only,description.digest AS description,input_schema.digest AS input_schema " ++
        "FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id " ++
        "JOIN content description ON description.content_id=tool.description_content_id " ++
        "JOIN content input_schema ON input_schema.content_id=tool.input_schema_content_id WHERE member.tool_set_id=?1 ORDER BY tool.name",
    .Args = struct { set: u64 },
    .Row = struct {
        name: Bounded(tool_record.max_name_bytes),
        owner: tool_record.Owner,
        server: Bounded(tool_record.max_server_bytes),
        read_only: bool,
        description: [32]u8,
        input_schema: [32]u8,
    },
    .cardinality = .each,
});

const SavedSelection = struct {
    names: *const command_input.ToolsField,
    digest: tool_record.SetDigest = .init(),
    count: usize = 0,

    pub fn visit(self: *SavedSelection, row: *const selection_records.Row) bool {
        var names = self.names.iterator();
        while (names.next()) |name| if (std.mem.eql(u8, name, row.name.slice())) {
            const identity: tool_record.RecordIdentity = .{
                .name = row.name.slice(),
                .owner = row.owner,
                .server = row.server.slice(),
                .read_only = row.read_only,
                .description = row.description,
                .input_schema = row.input_schema,
            };
            self.digest.add(&identity.digest());
            self.count += 1;
            break;
        };
        return true;
    }
};

/// Queues the read `finishSelection` follows: the set by its digest.
pub fn lookupSelection(a: anytype, selection: *Selection) void {
    a.read(lookup_set, .{ .digest = selection.digest }, &selection.set);
}

/// After `lookupSelection`'s round: the id of the set `selection` names,
/// the saved one or one queued now from the source set `source_set`.
pub fn finishSelection(a: anytype, selection: *const Selection, source_set: u64) !u64 {
    if (selection.set) |row| return row.tool_set_id.get();
    const set_id = try a.identity(.tool_set_id);
    a.write(insert_set, .{ .id = set_id, .digest = selection.digest, .count = selection.names.count });
    var names = selection.names.iterator();
    var ordinal: u64 = 0;
    while (names.next()) |name| : (ordinal += 1) a.writeCount(insert_selected_member, .{ .set = set_id, .ordinal = ordinal, .source = source_set, .name = name }, 1);
    return set_id;
}

/// An already saved record, named within its source set. Mixed-source sets
/// preserve frozen built-ins while selecting today's MCP records.
pub const Member = struct {
    name: Bounded(tool_record.max_name_bytes),
    source: u64,
    digest: [32]u8,
};

/// Intern a name-ordered effective offer. All members and their names must
/// outlive the Access's next round.
pub fn internMembers(a: anytype, members: []const Member) !u64 {
    var digest: tool_record.SetDigest = .init();
    var count: usize = 0;
    for (members) |*member| {
        digest.add(&member.digest);
        count += 1;
    }
    const value = digest.final();
    var saved: lookup_set.Result = null;
    a.read(lookup_set, .{ .digest = value }, &saved);
    try a.run();
    if (saved) |row| return row.tool_set_id.get();
    const id = try a.identity(.tool_set_id);
    a.write(insert_set, .{ .id = id, .digest = value, .count = count });
    var ordinal: u64 = 0;
    for (members) |*member| {
        a.writeCount(insert_selected_member, .{ .set = id, .ordinal = ordinal, .source = member.source, .name = member.name.slice() }, 1);
        ordinal += 1;
    }
    return id;
}
