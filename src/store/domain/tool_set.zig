const std = @import("std");
const command_input = @import("../../command_input.zig");
const content_string = @import("../../content_string.zig");
const tool_name = @import("../../tool_name.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const tool_record = @import("../../tool_record.zig");
const rsql = @import("../rsql.zig");
const content_domain = @import("content.zig");
const store_core = @import("../Store.zig");
const transition = @import("../transition.zig");

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

pub fn offeredSetSql(comptime revision_alias: []const u8) []const u8 {
    return "coalesce(" ++ revision_alias ++ ".loaded_tool_set_id," ++ revision_alias ++ ".tool_set_id)";
}

pub fn namesSql(comptime set_column: []const u8) []const u8 {
    return "(SELECT @list(tool.name) FROM tool_set_member member " ++
        "JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=" ++ set_column ++ ")";
}

pub const max_names_bytes = tool_name.max_names_bytes;

const insert_selected_member = rsql.Write(.{
    .sql = "INSERT INTO tool_set_member(tool_set_id,ordinal,tool_record_id) SELECT ?1,?2,member.tool_record_id " ++
        "FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=?3 AND tool.name=?4",
    .Args = struct { set: u64, ordinal: u64, source: u64, name: []const u8 },
    .expect = .{ .counted = .{ .otherwise = error.CorruptStore } },
});

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

pub fn toolSetDigest(tool_set: *const tool_record.HostToolSet) [32]u8 {
    var digest: tool_record.SetDigest = .init();
    for (tool_set.digests) |*each| digest.add(each);
    return digest.final();
}

pub const records_per_transaction = 2;

pub const SavingRecords = struct {
    records: []const tool_record.Record,
    pairs: [records_per_transaction]content_domain.Pair = undefined,
    descriptions: [records_per_transaction]content_domain.Import = undefined,
    schemas: [records_per_transaction]content_domain.Import = undefined,
    content_ids: [records_per_transaction][2]u64 = undefined,
    existing: [records_per_transaction]lookup_record.Result = undefined,

    pub fn lookup(saving: *SavingRecords, a: anytype) void {
        std.debug.assert(saving.records.len <= records_per_transaction);
        for (saving.records, 0..) |*each, index| {
            saving.descriptions[index] = .ofBytes(each.description, false);
            saving.schemas[index] = .ofBytes(each.input_schema, false);
            content_domain.lookupPair(a, &saving.descriptions[index], &saving.schemas[index], &saving.pairs[index]);
        }
    }

    pub fn importTexts(saving: *SavingRecords, a: anytype) !bool {
        var known = false;
        for (saving.records, 0..) |*each, index| {
            content_domain.foundPair(&saving.pairs[index], &saving.descriptions[index], &saving.schemas[index]);
            const both = saving.descriptions[index].found != null and saving.schemas[index].found != null;
            const ids = &saving.content_ids[index];
            ids.* = .{
                try content_domain.importBytes(a, &saving.descriptions[index], each.description),
                try content_domain.importBytes(a, &saving.schemas[index], each.input_schema),
            };
            saving.existing[index] = null;
            if (both) {
                known = true;
                a.read(lookup_record, .{ .name = each.name, .owner = each.owner, .server = each.server, .read_only = each.read_only, .description = ids[0], .input_schema = ids[1] }, &saving.existing[index]);
            }
        }
        return known;
    }

    pub fn insert(saving: *SavingRecords, a: anytype) !void {
        for (saving.records, 0..) |*each, index| if (saving.existing[index] == null) {
            const ids = saving.content_ids[index];
            const id = try a.identity(.tool_record_id);
            a.write(insert_record, .{ .id = id, .name = each.name, .owner = each.owner, .server = each.server, .read_only = each.read_only, .description = ids[0], .input_schema = ids[1] });
        };
    }
};

pub const SaveHostToolSet = struct {
    pub const rounds = transition.rounds(.{ .set = .{.branch}, .texts = .{.branch}, .records = .{.branch} });
    pub const round_budget = 1;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .set;
    pub const Input = struct { offered: *const tool_record.HostToolSet, digest: *const [32]u8, start: ?usize };
    pub const Result = ?u64;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{};
    pub const Declined = error{};

    input: Input,
    set: lookup_tool_set.Result = null,
    saving: SavingRecords = undefined,
    set_id: ?u64 = null,

    pub fn step(t: *SaveHostToolSet, r: *transition.Round(SaveHostToolSet), ran: ?rounds.At) !transition.Next(SaveHostToolSet) {
        const offered = t.input.offered;
        const at = ran orelse {
            const start = t.input.start orelse {
                lookupHostToolSet(r, t.input.digest, &t.set);
                return .{ .round = .set };
            };
            if (start < offered.records.len) {
                t.saving = .{ .records = offered.records[start..@min(offered.records.len, start + records_per_transaction)] };
                t.saving.lookup(r);
                return .{ .round = .texts };
            }
            const set_id = try r.identity(.tool_set_id);
            insertHostToolSet(r, offered, t.input.digest, set_id);
            pointHostToolSet(r, set_id);
            t.set_id = set_id;
            return .commit;
        };
        switch (at) {
            .set => {
                const row = t.set orelse return .{ .done = null };
                if (row.current) return .{ .done = row.tool_set_id.get() };
                pointHostToolSet(r, row.tool_set_id.get());
                t.set_id = row.tool_set_id.get();
                return .commit;
            },
            .texts => if (try t.saving.importTexts(r)) return .{ .round = .records },
            .records => {},
        }
        try t.saving.insert(r);
        return .commit;
    }

    pub fn committed(t: *const SaveHostToolSet) Result {
        return t.set_id;
    }
};

const lookup_tool_set = rsql.Read(.{
    .sql = "SELECT tool_set_id,EXISTS(SELECT 1 FROM host_tool_set host WHERE host.tool_set_id=tool_set.tool_set_id) AS current FROM tool_set WHERE digest=?1",
    .Args = struct { digest: [32]u8 },
    .Row = struct { tool_set_id: rsql.Positive, current: bool },
    .cardinality = .optional,
});

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

pub fn lookupHostToolSet(a: anytype, digest: *const [32]u8, set: *lookup_tool_set.Result) void {
    a.read(lookup_tool_set, .{ .digest = digest.* }, set);
}

pub fn pointHostToolSet(a: anytype, set_id: u64) void {
    a.write(start_host_tool_set, .{ .set = set_id });
    a.write(update_host_tool_set, .{ .set = set_id });
}

const saved_tool_set = rsql.Read(.{
    .sql = "SELECT host.tool_set_id,tool_set.member_count FROM host_tool_set host JOIN tool_set ON tool_set.tool_set_id=host.tool_set_id",
    .Args = struct {},
    .Row = struct { tool_set_id: rsql.Positive, member_count: u64 },
    .cardinality = .optional,
});

pub const SavedHostToolSet = saved_tool_set.Result;

pub fn savedHostToolSetOf(a: anytype) !SavedHostToolSet {
    var set: SavedHostToolSet = null;
    a.read(saved_tool_set, .{}, &set);
    try a.run();
    return set;
}

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

pub const host_tool_record_batch = 16;

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

pub const Selection = struct {
    names: *const command_input.ToolsField,
    digest: [32]u8,
    set: lookup_set.Result = null,

    pub fn of(tool_set: *const tool_record.HostToolSet, names: *const command_input.ToolsField) ?Selection {
        var digest: tool_record.SetDigest = .init();
        var each = names.iterator();
        while (each.next()) |name| digest.add(&tool_set.digests[tool_set.find(name) orelse return null]);
        return .{ .names = names, .digest = digest.final() };
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

pub const SavedSelection = struct {
    names: *const command_input.ToolsField,
    digest: tool_record.SetDigest = .init(),
    count: usize = 0,

    pub fn queue(self: *SavedSelection, a: anytype, source_set: u64) void {
        a.readEach(selection_records, .{ .set = source_set }, tool_name.max_tools + 1, self);
    }

    pub fn selection(self: *SavedSelection) !Selection {
        if (self.count != self.names.count) return error.CorruptStore;
        return .{ .names = self.names, .digest = self.digest.final() };
    }

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

pub fn lookupSelection(a: anytype, selection: *Selection) void {
    a.read(lookup_set, .{ .digest = selection.digest }, &selection.set);
}

pub fn finishSelection(a: anytype, selection: *const Selection, source_set: u64) !u64 {
    if (selection.set) |row| return row.tool_set_id.get();
    const set_id = try a.identity(.tool_set_id);
    a.write(insert_set, .{ .id = set_id, .digest = selection.digest, .count = selection.names.count });
    var names = selection.names.iterator();
    var ordinal: u64 = 0;
    while (names.next()) |name| : (ordinal += 1) a.writeCount(insert_selected_member, .{ .set = set_id, .ordinal = ordinal, .source = source_set, .name = name }, 1);
    return set_id;
}

pub const Member = struct {
    name: Bounded(tool_record.max_name_bytes),
    source: u64,
    digest: [32]u8,
};

pub const Interning = struct {
    digest: [32]u8 = undefined,
    saved: lookup_set.Result = null,
    inserted: bool = false,

    pub fn queue(interning: *Interning, a: anytype, members: []const Member) void {
        var digest: tool_record.SetDigest = .init();
        for (members) |*member| digest.add(&member.digest);
        interning.digest = digest.final();
        a.read(lookup_set, .{ .digest = interning.digest }, &interning.saved);
    }

    pub fn finish(interning: *Interning, a: anytype, members: []const Member) !u64 {
        if (interning.saved) |row| return row.tool_set_id.get();
        const id = try a.identity(.tool_set_id);
        a.write(insert_set, .{ .id = id, .digest = interning.digest, .count = members.len });
        var ordinal: u64 = 0;
        for (members) |*member| {
            a.writeCount(insert_selected_member, .{ .set = id, .ordinal = ordinal, .source = member.source, .name = member.name.slice() }, 1);
            ordinal += 1;
        }
        interning.inserted = true;
        return id;
    }
};
