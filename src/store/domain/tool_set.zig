const std = @import("std");
const command_input = @import("../../command_input.zig");
const content_string = @import("../../content_string.zig");
const tool_name = @import("../../tool_name.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const tool_record = @import("../../tool_record.zig");
const app_tools = @import("../../tool_record.zig").app_tools;
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
    .sql = "SELECT tool_record_id FROM tool_record WHERE name=?1 AND remote_name=?2 AND owner=?3 AND server=?4 AND replay=?5 AND restart_limit=?6 AND wait_ms=?7 AND description_content_id=?8 AND input_schema_content_id=?9",
    .Args = struct { name: []const u8, remote: []const u8, owner: tool_record.Owner, server: []const u8, replay: []const u8, restart_limit: u64, wait_ms: u64, description: u64, input_schema: u64 },
    .Row = struct { tool_record_id: rsql.Positive },
    .cardinality = .optional,
});

const insert_record = rsql.Write(.{
    .sql = "INSERT INTO tool_record(tool_record_id,name,remote_name,owner,server,replay,restart_limit,wait_ms,description_content_id,input_schema_content_id) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
    .Args = struct { id: u64, name: []const u8, remote: []const u8, owner: tool_record.Owner, server: []const u8, replay: []const u8, restart_limit: u64, wait_ms: u64, description: u64, input_schema: u64 },
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

/// The names of the app-owned members of a set: the subset of `namesSql` that `Offered.apps` reads.
pub fn appNamesSql(comptime set_column: []const u8) []const u8 {
    return "(SELECT @list(tool.name) FROM tool_set_member member " ++
        "JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=" ++ set_column ++ " AND tool.owner='app')";
}

/// True when the Host set (its records, MCP ones included) has the name of the app record `alias`. The Host record
/// is the one a name resolves to (`HostToolSet.resolve` checks the Host first), so such an app record is never offered:
/// the offer and its stale check read this one rule; settlement reads the frozen offer's owners, never this rule.
pub fn hostShadowsSql(comptime alias: []const u8) []const u8 {
    return "EXISTS(SELECT 1 FROM host_tool_set host_s JOIN tool_set_member host_m ON host_m.tool_set_id=host_s.tool_set_id " ++
        "JOIN tool_record host_t ON host_t.tool_record_id=host_m.tool_record_id WHERE host_s.slot=1 AND host_t.name=" ++ alias ++ ".name)";
}

pub const max_names_bytes = tool_name.max_names_bytes;
pub const max_offered_names_bytes = tool_name.max_offered_names_bytes;
/// An app set's names, joined by commas: at most `app_tools.max_records` names of `tool_name.max_bytes` each.
pub const max_app_names_bytes = tool_name.max_app_names_bytes;

/// A selected name comes from the source set (?3), or from the lane's app set (?5) when the source does not name it as a
/// Host tool: a host record wins over an app record of the same name.
const insert_selected_member = rsql.Write(.{
    .sql = "INSERT INTO tool_set_member(tool_set_id,ordinal,tool_record_id) SELECT ?1,?2,member.tool_record_id " ++
        "FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id IN (?3,?5) AND tool.name=?4 " ++
        "AND (member.tool_set_id=?3 OR NOT EXISTS(SELECT 1 FROM tool_set_member host_member JOIN tool_record host_tool ON host_tool.tool_record_id=host_member.tool_record_id " ++
        "WHERE host_member.tool_set_id=?3 AND host_tool.name=?4))",
    .Args = struct { set: u64, ordinal: u64, source: u64, name: []const u8, app: u64 },
    .expect = .{ .counted = .{ .otherwise = error.CorruptStore } },
});

const insert_tool_set_member = rsql.Write(.{
    .sql = "INSERT INTO tool_set_member(tool_set_id,ordinal,tool_record_id) SELECT ?1,?2,tool.tool_record_id FROM tool_record tool " ++
        "JOIN content description ON description.content_id=tool.description_content_id " ++
        "JOIN content input_schema ON input_schema.content_id=tool.input_schema_content_id " ++
        "WHERE tool.name=?3 AND tool.owner=?4 AND tool.server=?5 AND description.digest=?6 AND description.byte_length=?7 AND description.private=0 " ++
        "AND input_schema.digest=?8 AND input_schema.byte_length=?9 AND input_schema.private=0 AND tool.remote_name=?10 AND tool.replay=?11 AND tool.restart_limit=?12 AND tool.wait_ms=?13",
    .Args = struct {
        set: u64,
        ordinal: u64,
        name: []const u8,
        owner: tool_record.Owner,
        server: []const u8,
        description: [32]u8,
        description_bytes: u64,
        input_schema: [32]u8,
        input_schema_bytes: u64,
        remote: []const u8,
        replay: []const u8,
        restart_limit: u64,
        wait_ms: u64,
    },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

pub fn toolSetDigest(tool_set: *const tool_record.HostToolSet) [32]u8 {
    var digest: tool_record.SetDigest = .init();
    for (tool_set.digests) |*each| digest.add(each);
    return digest.final();
}

pub const records_per_transaction = 2;

/// The texts and records rounds both tool-set owners run: a host set saves them two records a transaction,
/// an app set saves its whole declaration inside one configure transaction.
pub fn SavingRecordsOf(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        records: []const tool_record.Record,
        pairs: [capacity]content_domain.Pair = undefined,
        descriptions: [capacity]content_domain.Import = undefined,
        schemas: [capacity]content_domain.Import = undefined,
        content_ids: [capacity][2]u64 = undefined,
        existing: [capacity]lookup_record.Result = undefined,

        pub fn lookup(saving: *Self, a: anytype) void {
            std.debug.assert(saving.records.len <= capacity);
            for (saving.records, 0..) |*each, index| {
                saving.descriptions[index] = .ofBytes(each.description, false);
                saving.schemas[index] = .ofBytes(each.input_schema, false);
                content_domain.lookupPair(a, &saving.descriptions[index], &saving.schemas[index], &saving.pairs[index]);
            }
        }

        pub fn importTexts(saving: *Self, a: anytype) !bool {
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
                    const policy = storedPolicy(each);
                    a.read(lookup_record, .{ .name = each.name, .remote = each.storedRemoteName(), .owner = each.owner, .server = each.server, .replay = policy.replay, .restart_limit = policy.restart_limit, .wait_ms = policy.wait_ms, .description = ids[0], .input_schema = ids[1] }, &saving.existing[index]);
                }
            }
            return known;
        }

        pub fn insert(saving: *Self, a: anytype) !void {
            for (saving.records, 0..) |*each, index| if (saving.existing[index] == null) {
                const ids = saving.content_ids[index];
                const id = try a.identity(.tool_record_id);
                const policy = storedPolicy(each);
                a.write(insert_record, .{ .id = id, .name = each.name, .remote = each.storedRemoteName(), .owner = each.owner, .server = each.server, .replay = policy.replay, .restart_limit = policy.restart_limit, .wait_ms = policy.wait_ms, .description = ids[0], .input_schema = ids[1] });
            };
        }
    };
}

pub const SavingRecords = SavingRecordsOf(records_per_transaction);
pub const AppSaving = SavingRecordsOf(app_tools.max_records);

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
    .sql = "SELECT member.ordinal,tool.name,tool.remote_name,tool.owner,tool.server,tool.replay,tool.restart_limit,tool.wait_ms,description.content_id AS description_id,description.byte_length AS description_length," ++
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
        remote_name: Bounded(tool_record.max_name_bytes),
        owner: tool_record.Owner,
        server: Bounded(tool_record.max_server_bytes),
        replay: Bounded(6),
        restart_limit: u64,
        wait_ms: u64,
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
    for (tool_set.records, 0..) |*each, ordinal| {
        const policy = storedPolicy(each);
        a.write(insert_tool_set_member, .{
            .set = set_id,
            .ordinal = ordinal,
            .name = each.name,
            .owner = each.owner,
            .server = each.server,
            .description = content_string.digest(each.description),
            .description_bytes = each.description.len,
            .input_schema = content_string.digest(each.input_schema),
            .input_schema_bytes = each.input_schema.len,
            .remote = each.storedRemoteName(),
            .replay = policy.replay,
            .restart_limit = policy.restart_limit,
            .wait_ms = policy.wait_ms,
        });
    }
}

/// A configure's app declaration: the validated records, and the app tool set they intern as.
pub const AppSet = struct {
    declaration: ?app_tools.Declaration = null,
    phase: enum { idle, looking, saving, done } = .idle,
    digest: [32]u8 = undefined,
    set: lookup_tool_set.Result = null,
    saving: AppSaving = undefined,
    set_id: ?u64 = null,
};

/// The app tool set a configure saves: its records, then its set row, interned by digest. No Host points at
/// it; the Session's app_tool_set_id does. Returns the set's id.
pub fn insertAppToolSet(a: anytype, saving: *AppSaving, declaration: *const app_tools.Declaration, digest: *const [32]u8) !u64 {
    try saving.insert(a);
    const set_id = try a.identity(.tool_set_id);
    insertHostToolSet(a, &declaration.toolSet(), digest, set_id);
    return set_id;
}

/// The Store's form of a record's app policy: `replay` is '' for every non-app record, and an unsafe
/// policy keeps restart_limit 0 (`AppPolicy.canonical`), the form the Store's CHECKs accept.
pub const StoredPolicy = struct { replay: []const u8, restart_limit: u64, wait_ms: u64 };

pub fn storedPolicy(record: *const tool_record.Record) StoredPolicy {
    if (record.owner != .app) return .{ .replay = "", .restart_limit = 0, .wait_ms = 0 };
    const policy = record.app.canonical();
    return .{ .replay = @tagName(policy.replay), .restart_limit = policy.restart_limit, .wait_ms = policy.wait_ms };
}

/// The one reader of a stored app policy, the inverse of `storedPolicy`: null for the zero policy every
/// non-app owner keeps, and `CorruptStore` for a tag or number outside the Store's CHECKs.
pub fn storedAppPolicy(owner: tool_record.Owner, replay: []const u8, restart_limit: u64, wait_ms: u64) error{CorruptStore}!?tool_record.AppPolicy {
    if (owner != .app) return null;
    const policy: tool_record.AppPolicy = .{
        .replay = std.meta.stringToEnum(tool_record.Replay, replay) orelse return error.CorruptStore,
        .restart_limit = std.math.cast(u8, restart_limit) orelse return error.CorruptStore,
        .wait_ms = std.math.cast(u32, wait_ms) orelse return error.CorruptStore,
    };
    if (!policy.valid()) return error.CorruptStore;
    return policy;
}

pub const Selection = struct {
    names: *const command_input.ToolsField,
    digest: [32]u8,
    set: lookup_set.Result = null,
    /// The lane's app set the names of `owner = app` come from; 0 when none does.
    app_set: u64 = 0,

    /// Names resolve in one resolver: the Host set first, then the lane's app records (`app_set` is the lane's set).
    pub fn of(tool_set: *const tool_record.HostToolSet, names: *const command_input.ToolsField, app_set: u64) ?Selection {
        var digest: tool_record.SetDigest = .init();
        var each = names.iterator();
        while (each.next()) |name| switch (tool_set.resolve(name)) {
            .found => |index| digest.add(&tool_set.digests[index]),
            .app => |index| digest.add(&tool_set.app_digests[index]),
            .unknown_tool, .mcp_server_unavailable => return null,
        };
        return .{ .names = names, .digest = digest.final(), .app_set = app_set };
    }
};

const selection_records = rsql.Read(.{
    .sql = "SELECT tool.name,tool.remote_name,tool.owner,tool.server,tool.replay,tool.restart_limit,tool.wait_ms,description.digest AS description,input_schema.digest AS input_schema " ++
        "FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id " ++
        "JOIN content description ON description.content_id=tool.description_content_id " ++
        "JOIN content input_schema ON input_schema.content_id=tool.input_schema_content_id WHERE member.tool_set_id=?1 ORDER BY tool.name",
    .Args = struct { set: u64 },
    .Row = struct {
        name: Bounded(tool_record.max_name_bytes),
        remote_name: Bounded(tool_record.max_name_bytes),
        owner: tool_record.Owner,
        server: Bounded(tool_record.max_server_bytes),
        replay: Bounded(6),
        restart_limit: u64,
        wait_ms: u64,
        description: [32]u8,
        input_schema: [32]u8,
    },
    .cardinality = .each,
});

pub const SavedSelection = struct {
    names: *const command_input.ToolsField,
    digest: tool_record.SetDigest = .init(),
    count: usize = 0,
    invalid: bool = false,

    pub fn queue(self: *SavedSelection, a: anytype, source_set: u64) void {
        a.readEach(selection_records, .{ .set = source_set }, tool_name.max_tools + 1, self);
    }

    pub fn selection(self: *SavedSelection) !Selection {
        if (self.invalid or self.count != self.names.count) return error.CorruptStore;
        return .{ .names = self.names, .digest = self.digest.final() };
    }

    pub fn visit(self: *SavedSelection, row: *const selection_records.Row) bool {
        var names = self.names.iterator();
        while (names.next()) |name| if (std.mem.eql(u8, name, row.name.slice())) {
            const app = storedAppPolicy(row.owner, row.replay.slice(), row.restart_limit, row.wait_ms) catch {
                self.invalid = true;
                return false;
            };
            const identity: tool_record.RecordIdentity = .{
                .name = row.name.slice(),
                .remote_name = row.remote_name.slice(),
                .owner = row.owner,
                .server = row.server.slice(),
                .description = row.description,
                .input_schema = row.input_schema,
                .app = app,
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
    while (names.next()) |name| : (ordinal += 1) a.writeCount(insert_selected_member, .{ .set = set_id, .ordinal = ordinal, .source = source_set, .name = name, .app = selection.app_set }, 1);
    return set_id;
}

/// The lane root's declared app records, by name, read through the lane Session (`session.app_lane`'s row).
const lane_app_members = rsql.Read(.{
    .sql = "SELECT lane.app_tool_set_id AS set_id,tool.name,tool.remote_name,tool.owner,tool.server,tool.replay,tool.restart_limit,tool.wait_ms," ++
        "description.digest AS description,input_schema.digest AS input_schema " ++
        "FROM session lane JOIN tool_set_member member ON member.tool_set_id=lane.app_tool_set_id JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id " ++
        "JOIN content description ON description.content_id=tool.description_content_id JOIN content input_schema ON input_schema.content_id=tool.input_schema_content_id " ++
        "WHERE lane.session_ref=?1 AND tool.owner='app' ORDER BY tool.name",
    .Args = struct { lane: []const u8 },
    .Row = struct {
        set_id: u64,
        name: Bounded(tool_record.max_name_bytes),
        remote_name: Bounded(tool_record.max_name_bytes),
        owner: tool_record.Owner,
        server: Bounded(tool_record.max_server_bytes),
        replay: Bounded(6),
        restart_limit: u64,
        wait_ms: u64,
        description: [32]u8,
        input_schema: [32]u8,
    },
    .cardinality = .each,
});

/// A lane's app records as a Host-shaped view: each record's digest is the one the offer and a saved selection rebuild.
/// The app names a child's parent offers, into `out`, read from the lane's resolved view. Only app records the Host does
/// not shadow are offered (Host precedence, as `HostToolSet.resolve` decides), and a parent narrows to them only by
/// naming one of those app records: a parent name the Host resolves is not an app narrowing. The parent offers every
/// offered app name when it names none of them.
pub fn offeredAppNamesTo(view: *const tool_record.HostToolSet, parent_names: []const u8, out: *Bounded(max_app_names_bytes)) void {
    var narrowed = false;
    for (view.apps) |*app| {
        if (view.find(app.name) == null and listsName(parent_names, app.name)) narrowed = true;
    }
    var buffer: [max_app_names_bytes]u8 = undefined;
    var length: usize = 0;
    for (view.apps) |*app| {
        if (view.find(app.name) != null) continue;
        if (narrowed and !listsName(parent_names, app.name)) continue;
        if (length != 0) {
            buffer[length] = ',';
            length += 1;
        }
        @memcpy(buffer[length..][0..app.name.len], app.name);
        length += app.name.len;
    }
    out.* = .{};
    out.set(buffer[0..length]) catch unreachable;
}

pub const LaneApps = struct {
    set: u64 = 0,
    count: usize = 0,
    invalid: bool = false,
    names: [app_tools.max_records]Bounded(tool_record.max_name_bytes) = undefined,
    policies: [app_tools.max_records]tool_record.AppPolicy = undefined,
    digests: [app_tools.max_records][32]u8 = undefined,
    /// The records `view` hands out; their names point into `names`, so a view lives as long as this value.
    records: [app_tools.max_records]tool_record.Record = undefined,

    pub fn queue(self: *LaneApps, a: anytype, lane: []const u8) void {
        a.readEach(lane_app_members, .{ .lane = lane }, app_tools.max_records + 1, self);
    }

    pub fn visit(self: *LaneApps, row: *const lane_app_members.Row) bool {
        if (self.count == self.names.len) {
            self.invalid = true;
            return false;
        }
        const app = (storedAppPolicy(row.owner, row.replay.slice(), row.restart_limit, row.wait_ms) catch {
            self.invalid = true;
            return false;
        }) orelse {
            self.invalid = true;
            return false;
        };
        const identity: tool_record.RecordIdentity = .{
            .name = row.name.slice(),
            .remote_name = row.remote_name.slice(),
            .owner = row.owner,
            .server = row.server.slice(),
            .description = row.description,
            .input_schema = row.input_schema,
            .app = app,
        };
        self.set = row.set_id;
        self.names[self.count] = row.name;
        self.policies[self.count] = app;
        self.digests[self.count] = identity.digest();
        self.count += 1;
        return true;
    }

    pub fn check(self: *const LaneApps) error{CorruptStore}!void {
        if (self.invalid) return error.CorruptStore;
    }

    /// The Host set plus the lane's app records, sorted by name as the Host's own records are.
    pub fn view(self: *LaneApps, host: *const tool_record.HostToolSet) tool_record.HostToolSet {
        for (self.records[0..self.count], self.names[0..self.count], self.policies[0..self.count]) |*record, *name, policy| {
            record.* = .{ .name = name.slice(), .owner = .app, .app = policy };
        }
        return .{
            .records = host.records,
            .digests = host.digests,
            .configured_servers = host.configured_servers,
            .apps = self.records[0..self.count],
            .app_digests = self.digests[0..self.count],
        };
    }
};

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
            a.writeCount(insert_selected_member, .{ .set = id, .ordinal = ordinal, .source = member.source, .name = member.name.slice(), .app = 0 }, 1);
            ordinal += 1;
        }
        interning.inserted = true;
        return id;
    }
};

fn listsName(list: []const u8, name: []const u8) bool {
    var names = std.mem.splitScalar(u8, list, ',');
    while (names.next()) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}
