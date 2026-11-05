//! Tool records and tool sets (D48, D49). A record is one tool as the model
//! is told about it, saved once by content; a set is an ordered list of
//! records, saved once by its digest. A Session's settings, and so every
//! revision and the Operations admitted under it, name the set they offer,
//! and a request renders the saved text, so a reworded built-in changes
//! only the sets saved after it.
const std = @import("std");
const protocol = @import("../../protocol.zig");
const tool_catalog = @import("../../tools.zig");
const rsql = @import("../rsql.zig");
const content_domain = @import("content.zig");

const Tool = tool_catalog.Tool;

const lookup_set = rsql.Read(.{
    .sql = "SELECT tool_set_id FROM tool_set WHERE digest=?1",
    .Args = struct { digest: [32]u8 },
    .Row = struct { tool_set_id: rsql.Positive },
    .cardinality = .optional,
});

const lookup_record = rsql.Read(.{
    .sql = "SELECT tool_record_id FROM tool_record WHERE name=?1 AND owner=?2 AND server=?3 AND description_content_id=?4 AND input_schema_content_id=?5",
    .Args = struct { name: []const u8, owner: tool_catalog.Owner, server: []const u8, description: u64, input_schema: u64 },
    .Row = struct { tool_record_id: rsql.Positive },
    .cardinality = .optional,
});

const insert_record = rsql.Write(.{
    .sql = "INSERT INTO tool_record(tool_record_id,name,owner,server,description_content_id,input_schema_content_id) VALUES(?1,?2,?3,?4,?5,?6)",
    .Args = struct { id: u64, name: []const u8, owner: tool_catalog.Owner, server: []const u8, description: u64, input_schema: u64 },
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
/// as a tools_mask: each built-in member's bit, and nothing for any other
/// member. Settlement runs only the built-ins, so it reads a set this way:
/// a call to another member, an MCP server's tool, is unknown until Rui
/// runs it. A catalog holds the built-ins unchanged, so no other member
/// shares a built-in's name.
pub fn maskSql(comptime set_column: []const u8) []const u8 {
    comptime {
        var cases: []const u8 = "";
        for (std.enums.values(Tool)) |tool| cases = cases ++ std.fmt.comptimePrint(" WHEN '{s}' THEN {d}", .{ @tagName(tool), tool_catalog.toolBit(tool) });
        return "(SELECT coalesce(sum(CASE tool.name" ++ cases ++ " ELSE 0 END),0) " ++
            "FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=" ++ set_column ++ ")";
    }
}

/// A Rui SQL expression for the names of the set `set_column`'s members,
/// joined by commas in no set order, since ordering them would sort; NULL
/// for an empty set. A name has no comma (`protocol.validToolName`), and
/// a Session's names, as configure bounds them, fit `max_names_bytes`.
pub fn namesSql(comptime set_column: []const u8) []const u8 {
    return "(SELECT @list(tool.name) FROM tool_set_member member " ++
        "JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=" ++ set_column ++ ")";
}

/// The longest `namesSql` text of a Session's set.
pub const max_names_bytes = protocol.max_tool_names_bytes;

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

/// A Session's member named `name` in the catalog set `catalog`, as
/// member `ordinal` of `set`. One row, or the catalog lacks it.
const insert_selected_member = rsql.Write(.{
    .sql = "INSERT INTO tool_set_member(tool_set_id,ordinal,tool_record_id) SELECT ?1,?2,member.tool_record_id " ++
        "FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=?3 AND tool.name=?4",
    .Args = struct { set: u64, ordinal: u64, catalog: u64, name: []const u8 },
    .expect = .{ .counted = .{ .otherwise = error.CorruptStore } },
});

/// The record with these name, owner and texts, as member `ordinal` of
/// `set`. One row, or the record was never saved.
const insert_catalog_member = rsql.Write(.{
    .sql = "INSERT INTO tool_set_member(tool_set_id,ordinal,tool_record_id) SELECT ?1,?2,tool.tool_record_id FROM tool_record tool " ++
        "JOIN content description ON description.content_id=tool.description_content_id " ++
        "JOIN content input_schema ON input_schema.content_id=tool.input_schema_content_id " ++
        "WHERE tool.name=?3 AND tool.owner=?4 AND tool.server=?5 AND description.digest=?6 AND description.byte_length=?7 AND description.private=0 " ++
        "AND input_schema.digest=?8 AND input_schema.byte_length=?9 AND input_schema.private=0",
    .Args = struct {
        set: u64,
        ordinal: u64,
        name: []const u8,
        owner: tool_catalog.Owner,
        server: []const u8,
        description: [32]u8,
        description_bytes: u64,
        input_schema: [32]u8,
        input_schema_bytes: u64,
    },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// The digest of `catalog`'s set: its records, in order.
pub fn catalogDigest(catalog: *const tool_catalog.Catalog) [32]u8 {
    var digest: tool_catalog.SetDigest = .init();
    for (catalog.digests) |*each| digest.add(each);
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
pub fn ensureRecords(a: anytype, records: []const tool_catalog.Record, reads: *RecordReads) !void {
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
            a.read(lookup_record, .{ .name = each.name, .owner = each.owner, .server = each.server, .description = content_ids[index][0], .input_schema = content_ids[index][1] }, &reads.existing[index]);
        }
    }
    if (known) try a.run();
    for (records, 0..) |*each, index| if (reads.existing[index] == null) {
        const id = try a.identity(.tool_record_id);
        a.write(insert_record, .{ .id = id, .name = each.name, .owner = each.owner, .server = each.server, .description = content_ids[index][0], .input_schema = content_ids[index][1] });
    };
}

/// The catalog's saved set, by its digest, and whether host_catalog
/// names it already.
const lookup_catalog = rsql.Read(.{
    .sql = "SELECT tool_set_id,EXISTS(SELECT 1 FROM host_catalog host WHERE host.tool_set_id=tool_set.tool_set_id) AS current FROM tool_set WHERE digest=?1",
    .Args = struct { digest: [32]u8 },
    .Row = struct { tool_set_id: rsql.Positive, current: bool },
    .cardinality = .optional,
});

/// host_catalog's one row, on the first save.
const start_host_catalog = rsql.Write(.{
    .sql = "INSERT INTO host_catalog(slot,tool_set_id) SELECT 1,?1 WHERE NOT EXISTS(SELECT 1 FROM host_catalog)",
    .Args = struct { set: u64 },
    .expect = .{ .at_most = 1 },
});

const update_host_catalog = rsql.Write(.{
    .sql = "UPDATE host_catalog SET tool_set_id=?1 WHERE slot=1",
    .Args = struct { set: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Queues reading the catalog's saved set, by `digest`.
pub fn lookupCatalog(a: anytype, digest: *const [32]u8, set: *lookup_catalog.Result) void {
    a.read(lookup_catalog, .{ .digest = digest.* }, set);
}

pub const CatalogSet = lookup_catalog.Result;

/// Queues making `set_id` the Host's catalog, the one the next start
/// reads back.
pub fn pointCatalog(a: anytype, set_id: u64) void {
    a.write(start_host_catalog, .{ .set = set_id });
    a.write(update_host_catalog, .{ .set = set_id });
}

/// The Host's catalog set and its record count; none before the first
/// catalog is saved.
const saved_catalog = rsql.Read(.{
    .sql = "SELECT host.tool_set_id,tool_set.member_count FROM host_catalog host JOIN tool_set ON tool_set.tool_set_id=host.tool_set_id",
    .Args = struct {},
    .Row = struct { tool_set_id: rsql.Positive, member_count: u64 },
    .cardinality = .optional,
});

pub const SavedCatalog = saved_catalog.Result;

/// One round: the Host's catalog set.
pub fn savedCatalogOf(a: anytype) !SavedCatalog {
    var set: SavedCatalog = null;
    a.read(saved_catalog, .{}, &set);
    try a.run();
    return set;
}

/// One round: the catalog set `set`'s records from `ordinal`, at most a
/// batch and `rows.len`, in order; how many it read.
pub fn catalogRecordsOf(a: anytype, set: u64, ordinal: usize, rows: []catalog_records.Row) !usize {
    var batch: RecordBatch = .{ .rows = rows };
    a.readEach(catalog_records, .{ .set = set, .ordinal = ordinal }, @min(rows.len, catalog_record_batch), &batch);
    try a.run();
    return batch.count;
}

const RecordBatch = struct {
    rows: []catalog_records.Row,
    count: usize = 0,

    pub fn visit(batch: *RecordBatch, row: *const catalog_records.Row) bool {
        batch.rows[batch.count] = row.*;
        batch.count += 1;
        return true;
    }
};

/// A catalog set's members from ordinal ?2 on: each record and where
/// its texts are.
pub const catalog_records = rsql.Read(.{
    .sql = "SELECT member.ordinal,tool.name,tool.owner,tool.server,description.content_id AS description_id,description.byte_length AS description_length," ++
        "description.digest AS description_digest,description.private AS description_private,input_schema.content_id AS schema_id," ++
        "input_schema.byte_length AS schema_length,input_schema.digest AS schema_digest,input_schema.private AS schema_private " ++
        "FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id " ++
        "JOIN content description ON description.content_id=tool.description_content_id " ++
        "JOIN content input_schema ON input_schema.content_id=tool.input_schema_content_id " ++
        std.fmt.comptimePrint("WHERE member.tool_set_id=?1 AND member.ordinal>=?2 ORDER BY member.ordinal LIMIT {d}", .{catalog_record_batch}),
    .Args = struct { set: u64, ordinal: u64 },
    .Row = struct {
        ordinal: u64,
        name: protocol.Bounded(tool_catalog.max_name_bytes),
        owner: tool_catalog.Owner,
        server: protocol.Bounded(tool_catalog.max_server_bytes),
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

/// How many records one round of `catalog_records` reads.
pub const catalog_record_batch = 16;

/// Queues saving `catalog`'s set, whose every record is saved, as `set_id`.
pub fn insertCatalog(a: anytype, catalog: *const tool_catalog.Catalog, digest: *const [32]u8, set_id: u64) void {
    a.write(insert_set, .{ .id = set_id, .digest = digest.*, .count = catalog.records.len });
    for (catalog.records, 0..) |*each, ordinal| a.write(insert_catalog_member, .{
        .set = set_id,
        .ordinal = ordinal,
        .name = each.name,
        .owner = each.owner,
        .server = each.server,
        .description = protocol.contentDigest(each.description),
        .description_bytes = each.description.len,
        .input_schema = protocol.contentDigest(each.input_schema),
        .input_schema_bytes = each.input_schema.len,
    });
}

/// The set a configure saves: the catalog's records `names` names, in
/// name order, and the digest it is saved under.
pub const Selection = struct {
    names: *const protocol.ToolsField,
    digest: [32]u8,
    set: lookup_set.Result = null,

    /// Null when the catalog lacks one of `names`.
    pub fn of(catalog: *const tool_catalog.Catalog, names: *const protocol.ToolsField) ?Selection {
        var digest: tool_catalog.SetDigest = .init();
        var each = names.iterator();
        while (each.next()) |name| digest.add(&catalog.digests[catalog.find(name) orelse return null]);
        return .{ .names = names, .digest = digest.final() };
    }
};

/// Queues the read `finishSelection` follows: the set by its digest.
pub fn lookupSelection(a: anytype, selection: *Selection) void {
    a.read(lookup_set, .{ .digest = selection.digest }, &selection.set);
}

/// After `lookupSelection`'s round: the id of the set `selection` names,
/// the saved one or one queued now from the catalog set `catalog_set`.
pub fn finishSelection(a: anytype, selection: *const Selection, catalog_set: u64) !u64 {
    if (selection.set) |row| return row.tool_set_id.get();
    const set_id = try a.identity(.tool_set_id);
    a.write(insert_set, .{ .id = set_id, .digest = selection.digest, .count = selection.names.count });
    var names = selection.names.iterator();
    var ordinal: u64 = 0;
    while (names.next()) |name| : (ordinal += 1) a.writeCount(insert_selected_member, .{ .set = set_id, .ordinal = ordinal, .catalog = catalog_set, .name = name }, 1);
    return set_id;
}
