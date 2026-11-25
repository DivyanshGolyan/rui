const std = @import("std");
const tools = @import("../../tool_record.zig");
const tool_name = @import("../../tool_name.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const rsql = @import("../rsql.zig");
const tool_set = @import("tool_set.zig");
const tool_offer = @This();

const projected = rsql.Read(.{
    .compound = true,
    .sql = "SELECT tool.name,tool.remote_name,tool.owner,tool.server,tool.replay,tool.restart_limit,tool.wait_ms,description.digest AS description,input_schema.digest AS input_schema," ++
        "description.content_id,description.byte_length,CASE WHEN intended.owner='mcp' THEN host.tool_set_id ELSE member.tool_set_id END AS source," ++
        "EXISTS(SELECT 1 FROM tool_set_member lm JOIN tool_record lt ON lt.tool_record_id=lm.tool_record_id WHERE lm.tool_set_id=?2 AND lt.name=tool.name) AS loaded " ++
        "FROM tool_set_member member JOIN tool_record intended ON intended.tool_record_id=member.tool_record_id " ++
        "JOIN host_tool_set host ON host.slot=1 " ++
        "JOIN tool_record tool ON tool.tool_record_id=CASE WHEN intended.owner='mcp' THEN " ++
        "(SELECT hm.tool_record_id FROM tool_set_member hm JOIN tool_record ht ON ht.tool_record_id=hm.tool_record_id WHERE hm.tool_set_id=host.tool_set_id AND ht.name=intended.name) " ++
        "ELSE intended.tool_record_id END " ++
        "JOIN content description ON description.content_id=tool.description_content_id JOIN content input_schema ON input_schema.content_id=tool.input_schema_content_id " ++
        "WHERE member.tool_set_id=?1 AND intended.owner<>'app' AND NOT " ++ tools.sql.retired("intended.owner", "intended.name") ++ " " ++
        // The lane's app tools (?3, its app set; 0 when the lane declares none), narrowed by the Session's own app names (?1) when it names any.
        "UNION ALL SELECT tool.name,tool.remote_name,tool.owner,tool.server,tool.replay,tool.restart_limit,tool.wait_ms,description.digest AS description,input_schema.digest AS input_schema," ++
        "description.content_id,description.byte_length,member.tool_set_id AS source,1 AS loaded " ++
        "FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id " ++
        "JOIN content description ON description.content_id=tool.description_content_id JOIN content input_schema ON input_schema.content_id=tool.input_schema_content_id " ++
        "WHERE member.tool_set_id=?3 AND tool.owner='app' AND (NOT EXISTS(" ++ appNamesSql("?1") ++ ") OR tool.name IN (" ++ appNamesSql("?1") ++ ")) AND NOT " ++ tool_set.hostShadowsSql("tool") ++ " ORDER BY name",
    .Args = struct { allowed: u64, loaded: u64, app: u64 },
    .Row = struct {
        name: Bounded(tools.max_name_bytes),
        remote_name: Bounded(tools.max_name_bytes),
        owner: tools.Owner,
        server: Bounded(tools.max_server_bytes),
        replay: Bounded(6),
        restart_limit: u64,
        wait_ms: u64,
        description: [32]u8,
        input_schema: [32]u8,
        content_id: rsql.Positive,
        byte_length: u64,
        source: rsql.Positive,
        loaded: bool,
    },
    .cardinality = .each,
});
pub const OfferedRecord = projected.Row;

/// `app` is the lane root's app tool set, or 0 when the lane declares none (no set id is 0).
pub fn project(a: anytype, allowed: u64, loaded: ?u64, app: u64, sink: anytype) void {
    a.readEach(projected, .{ .allowed = allowed, .loaded = loaded orelse allowed, .app = app }, tool_name.max_offered_tools + 1, sink);
}

const Projection = struct {
    members: [tool_name.max_offered_tools]tool_set.Member = undefined,
    count: usize = 0,
    invalid: bool = false,

    pub fn visit(self: *Projection, row: *const OfferedRecord) bool {
        if (!row.loaded) return true;
        if (self.count == self.members.len) {
            self.invalid = true;
            return false;
        }
        const app = tool_set.storedAppPolicy(row.owner, row.replay.slice(), row.restart_limit, row.wait_ms) catch {
            self.invalid = true;
            return false;
        };
        const identity: tools.RecordIdentity = .{
            .name = row.name.slice(),
            .remote_name = row.remote_name.slice(),
            .owner = row.owner,
            .server = row.server.slice(),
            .description = row.description,
            .input_schema = row.input_schema,
            .app = app,
        };
        self.members[self.count] = .{ .name = row.name, .source = row.source.get(), .digest = identity.digest() };
        self.count += 1;
        return true;
    }
};

/// Test seam (Store.readToolDigestsForTesting): the offer's projection and the saved selection of set `set`
/// in one read, with each digest computed by the same owners the Store's readers use. The set is its own lane:
/// its app members are the lane's app tools.
pub fn roundTripDigestsOf(a: anytype, set: u64, freeze: *Freeze, selection: *tool_set.SavedSelection) !void {
    freeze.project(a, set, set, set);
    selection.queue(a, set);
    try a.run();
}

/// The lane root's app set, read by a Session with alias `s`.
pub fn laneAppSetSql(comptime session_alias: []const u8) []const u8 {
    return "(SELECT lane.app_tool_set_id FROM session lane WHERE lane.session_ref=" ++ session_alias ++ ".app_lane)";
}

/// The app names a set names: the narrowing a Session's own tools intent puts on the lane's app tools.
fn appNamesSql(comptime set: []const u8) []const u8 {
    return "SELECT an_tool.name FROM tool_set_member an_member JOIN tool_record an_tool ON an_tool.tool_record_id=an_member.tool_record_id " ++
        "WHERE an_member.tool_set_id=" ++ set ++ " AND an_tool.owner='app'";
}

/// The app records a Session's frozen offer holds (its offered set), by record.
fn offeredAppSql(comptime offered: []const u8) []const u8 {
    return "SELECT o_member.tool_record_id FROM tool_set_member o_member JOIN tool_record o_tool ON o_tool.tool_record_id=o_member.tool_record_id " ++
        "WHERE o_member.tool_set_id=" ++ offered ++ " AND o_tool.owner='app'";
}

/// The app records the projection offers now: the lane's app set, narrowed by the Session's intent (`s.tool_set_id`).
fn expectedAppSql(comptime session_alias: []const u8) []const u8 {
    return "SELECT e_member.tool_record_id FROM tool_set_member e_member JOIN tool_record e_tool ON e_tool.tool_record_id=e_member.tool_record_id " ++
        "WHERE e_member.tool_set_id=" ++ laneAppSetSql(session_alias) ++ " AND e_tool.owner='app' AND (NOT EXISTS(" ++ appNamesSql(session_alias ++ ".tool_set_id") ++
        ") OR e_tool.name IN (" ++ appNamesSql(session_alias ++ ".tool_set_id") ++ ")) AND NOT " ++ tool_set.hostShadowsSql("e_tool");
}

/// Stale when the frozen offer holds a retired built-in, or its app records differ from the expected ones, in either direction. A lane with no
/// app set expects none, and a frozen offer with none matches, so a Host with no app tools is never stale for this.
pub const stale_sql = "EXISTS(SELECT 1 FROM tool_set_member rm JOIN tool_record rt ON rt.tool_record_id=rm.tool_record_id " ++
    "WHERE rm.tool_set_id=" ++ tool_set.offeredSetSql("s") ++ " AND " ++ tools.sql.retired("rt.owner", "rt.name") ++ ") OR " ++
    "EXISTS(SELECT 1 FROM tool_set_member tm JOIN tool_record tool ON tool.tool_record_id=tm.tool_record_id " ++
    "WHERE tm.tool_set_id=" ++ tool_set.offeredSetSql("s") ++ " AND tool.owner='mcp' AND tm.tool_record_id NOT IN " ++
    "(SELECT hm.tool_record_id FROM host_tool_set host JOIN tool_set_member hm ON hm.tool_set_id=host.tool_set_id WHERE host.slot=1)) OR " ++
    "EXISTS(" ++ offeredAppSql(tool_set.offeredSetSql("s")) ++ " AND o_member.tool_record_id NOT IN (" ++ expectedAppSql("s") ++ ")) OR " ++
    "EXISTS(" ++ expectedAppSql("s") ++ " AND e_member.tool_record_id NOT IN (" ++ offeredAppSql(tool_set.offeredSetSql("s")) ++ "))";

const session_offer_facts = rsql.Read(.{
    .sql = "SELECT s.tool_set_id,s.loaded_tool_set_id,coalesce(" ++ laneAppSetSql("s") ++ ",0) AS app_tool_set_id FROM session s WHERE s.session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { tool_set_id: u64, loaded_tool_set_id: ?u64 = null, app_tool_set_id: u64 = 0 },
    .cardinality = .one,
});

pub const Freeze = struct {
    projection: Projection = .{},
    interning: tool_set.Interning = .{},

    pub fn unchanged(allowed: u64, loaded: ?u64, stale: bool) ?u64 {
        return if (stale) null else loaded orelse allowed;
    }

    pub fn project(freeze: *Freeze, a: anytype, allowed: u64, loaded: ?u64, app: u64) void {
        freeze.* = .{};
        tool_offer.project(a, allowed, loaded, app, &freeze.projection);
    }

    pub fn intern(freeze: *Freeze, a: anytype) !void {
        if (freeze.projection.invalid) return error.CorruptStore;
        freeze.interning.queue(a, freeze.members());
    }

    pub fn set(freeze: *Freeze, a: anytype) !u64 {
        return freeze.interning.finish(a, freeze.members());
    }

    fn members(freeze: *const Freeze) []const tool_set.Member {
        return freeze.projection.members[0..freeze.projection.count];
    }
};
