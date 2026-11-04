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
        "WHERE tool.name=?3 AND tool.owner=?4 AND description.digest=?5 AND description.byte_length=?6 AND description.private=0 " ++
        "AND input_schema.digest=?7 AND input_schema.byte_length=?8 AND input_schema.private=0",
    .Args = struct {
        set: u64,
        ordinal: u64,
        name: []const u8,
        owner: tool_catalog.Owner,
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
            a.read(lookup_record, .{ .name = each.name, .owner = each.owner, .description = content_ids[index][0], .input_schema = content_ids[index][1] }, &reads.existing[index]);
        }
    }
    if (known) try a.run();
    for (records, 0..) |*each, index| if (reads.existing[index] == null) {
        const id = try a.identity(.tool_record_id);
        a.write(insert_record, .{ .id = id, .name = each.name, .owner = each.owner, .description = content_ids[index][0], .input_schema = content_ids[index][1] });
    };
}

/// Queues reading the catalog's saved set, by `digest`.
pub fn lookupCatalog(a: anytype, digest: *const [32]u8, set: *lookup_set.Result) void {
    a.read(lookup_set, .{ .digest = digest.* }, set);
}

pub const CatalogSet = lookup_set.Result;

/// Queues saving `catalog`'s set, whose every record is saved, as `set_id`.
pub fn insertCatalog(a: anytype, catalog: *const tool_catalog.Catalog, digest: *const [32]u8, set_id: u64) void {
    a.write(insert_set, .{ .id = set_id, .digest = digest.*, .count = catalog.records.len });
    for (catalog.records, 0..) |*each, ordinal| a.write(insert_catalog_member, .{
        .set = set_id,
        .ordinal = ordinal,
        .name = each.name,
        .owner = each.owner,
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
