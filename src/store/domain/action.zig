const std = @import("std");
pub const Capacity = @import("../../execution.zig").DispatchCapacity;
const attempt = @import("../../attempt.zig");
const turn_ending = @import("../../turn_ending.zig");
const tool_proposal = @import("../../tool_proposal.zig");
const workspace_path = @import("../../workspace_path.zig");
const outcome_code = @import("../../outcome_code.zig");
const content_string = @import("../../content_string.zig");
const tool_name = @import("../../tool_name.zig");
const idempotency_key = @import("../../idempotency_key.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const session_id = @import("../../session_id.zig");
const tool_defs = @import("../../tool_record.zig");
const store_core = @import("../Store.zig");
const sourced_input = @import("sourced_input.zig");
const rsql = @import("../rsql.zig");
const content_domain = @import("content.zig");
const reads_domain = @import("reads.zig");
const sqlite = @import("../sqlite.zig");
const store_access = @import("../access.zig");
const transition = @import("../transition.zig");
const turn_domain = @import("turn.zig");
const forward_domain = @import("forward.zig");
const ContentReference = content_domain.ContentReference;
const Faults = store_core.Faults;

fn handleSql(comptime projection: []const u8, comptime extra: []const u8) []const u8 {
    return "SELECT " ++ projection ++ " FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "JOIN session s ON s.session_ref=action.session_ref WHERE action.sender_handle=?1 AND action.attempt_ordinal=1 " ++ extra ++ " LIMIT 1";
}

pub const live_by_handle = rsql.Read(.{
    .sql = handleSql("action.action_id,s.session_ref,s.workspace_key,s.next_position,action.background_position IS NOT NULL AS background,action.resolution_code IS NOT NULL AS resolved," ++ actionStoppedSql("action", "operation") ++ " AS stopped", ""),
    .Args = struct { handle: []const u8 },
    .Row = struct { action_id: rsql.Positive, session: rsql.SessionHead, background: bool, resolved: bool, stopped: bool },
    .cardinality = .optional,
});

pub const peer_by_handle = rsql.Read(.{
    .sql = handleSql("s.session_ref,s.workspace_key,s.next_position", "AND action.resolution_code IS NULL AND NOT " ++ actionStoppedSql("action", "operation")),
    .Args = struct { handle: []const u8 },
    .Row = struct { session: rsql.SessionHead },
    .cardinality = .optional,
});

pub fn liveByHandle(a: anytype, handle: []const u8, result: anytype) void {
    if (@TypeOf(result) == *peer_by_handle.Result) {
        a.read(peer_by_handle, .{ .handle = handle }, result);
    } else {
        a.read(live_by_handle, .{ .handle = handle }, result);
    }
}

const action_attempted_sql = std.fmt.comptimePrint("attempt_ordinal={d}", .{attempt.action_attempt_ordinal});

fn callNameSql(comptime test_sql: []const u8) []const u8 {
    return "EXISTS(SELECT 1 FROM model_tool_call tool_call JOIN content call_name ON call_name.content_id=tool_call.name_content_id " ++
        "WHERE tool_call.operation_id=action.parent_operation_id AND tool_call.call_ordinal=action.call_ordinal AND call_name.digest" ++ test_sql ++ ")";
}

pub fn coreCallSql(comptime first: u8) []const u8 {
    comptime {
        var sql: []const u8 = " IN(";
        for (std.enums.values(CoreTool), 0..) |_, i| {
            sql = sql ++ (if (i == 0) "" else ",") ++ std.fmt.comptimePrint("?{d}", .{first + i});
        }
        return callNameSql(sql ++ ")");
    }
}

fn coreCaseSql(comptime first: u8) []const u8 {
    comptime {
        var sql: []const u8 = "CASE";
        for (std.enums.values(CoreTool), 0..) |tool, i| {
            sql = sql ++ if (i + 1 == core_count)
                " ELSE '" ++ @tagName(tool) ++ "'"
            else
                " WHEN " ++ callNameSql(std.fmt.comptimePrint("=?{d}", .{first + i})) ++ " THEN '" ++ @tagName(tool) ++ "'";
        }
        return sql ++ " END AS tool ";
    }
}

const core_count = std.enums.values(CoreTool).len;

pub const CoreNames = struct {
    digests: [core_count][32]u8,

    pub fn of() CoreNames {
        var names: CoreNames = undefined;
        inline for (std.enums.values(CoreTool), &names.digests) |tool, *digest| {
            digest.* = content_string.digest(@tagName(tool));
        }
        return names;
    }

    pub fn Args(comptime Prefix: type) type {
        const prefix = @typeInfo(Prefix).@"struct";
        var fields: [prefix.field_names.len + core_count][]const u8 = undefined;
        var types: [fields.len]type = undefined;
        @memcpy(fields[0..prefix.field_names.len], prefix.field_names);
        @memcpy(types[0..prefix.field_types.len], prefix.field_types);
        for (std.enums.values(CoreTool), prefix.field_names.len..) |tool, i| {
            fields[i] = @tagName(tool) ++ "_name";
            types[i] = [32]u8;
        }
        return @Struct(.auto, null, &fields, &types, &@splat(.{}));
    }

    pub fn args(self: CoreNames, prefix: anytype) Args(@TypeOf(prefix)) {
        var out: Args(@TypeOf(prefix)) = undefined;
        inline for (@typeInfo(@TypeOf(prefix)).@"struct".field_names) |name| {
            @field(out, name) = @field(prefix, name);
        }
        inline for (std.enums.values(CoreTool), self.digests) |tool, digest| {
            @field(out, @tagName(tool) ++ "_name") = digest;
        }
        return out;
    }
};

pub fn mcpCallSql(comptime action_alias: []const u8, comptime operation_alias: []const u8) []const u8 {
    return "EXISTS(" ++ mcpCallSelectSql(action_alias, operation_alias, "1") ++ ")";
}

pub fn mcpServerSql(comptime action_alias: []const u8, comptime operation_alias: []const u8) []const u8 {
    return "(" ++ mcpCallSelectSql(action_alias, operation_alias, "tool.server") ++ ")";
}

pub fn mcpServerForNameSql(comptime operation_alias: []const u8, comptime name_content: []const u8) []const u8 {
    return "(" ++ mcpToolSelectSql(operation_alias, name_content, "tool.server") ++ ")";
}

fn mcpOfferJoinsSql(comptime operation_alias: []const u8) []const u8 {
    return "JOIN tool_set_member member ON member.tool_set_id=" ++ operation_alias ++ ".tool_set_id " ++
        "JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id ";
}

const mcp_name_sql = "AND @bytes(tool.name)=@payload(name) AND " ++ tool_defs.sql.runnerTest("tool.owner", "tool.name", .mcp);

fn mcpToolSelectSql(comptime operation_alias: []const u8, comptime name_content: []const u8, comptime selected: []const u8) []const u8 {
    return "SELECT " ++ selected ++ " FROM content name " ++ mcpOfferJoinsSql(operation_alias) ++
        "WHERE name.content_id=" ++ name_content ++ " " ++ mcp_name_sql;
}

fn mcpCallSelectSql(comptime action_alias: []const u8, comptime operation_alias: []const u8, comptime selected: []const u8) []const u8 {
    return "SELECT " ++ selected ++ " FROM model_tool_call tool_call " ++
        "JOIN content name ON name.content_id=tool_call.name_content_id " ++ mcpOfferJoinsSql(operation_alias) ++
        "WHERE tool_call.operation_id=" ++ action_alias ++ ".parent_operation_id AND tool_call.call_ordinal=" ++ action_alias ++ ".call_ordinal " ++ mcp_name_sql;
}

fn builtinCallSql(comptime runner: tool_defs.Runner) []const u8 {
    return "EXISTS(" ++ offeredCallSelectSql("action", "operation", "1") ++ " AND " ++ tool_defs.sql.runnerTest("tool.owner", "tool.name", runner) ++ ")";
}

/// The call's offered tool record, selecting `selected` over it. Its derived runner is `tool_defs.sql`.
fn offeredCallSelectSql(comptime action: []const u8, comptime operation: []const u8, comptime selected: []const u8) []const u8 {
    return "SELECT " ++ selected ++ " FROM model_tool_call tool_call " ++
        "JOIN content name ON name.content_id=tool_call.name_content_id " ++ mcpOfferJoinsSql(operation) ++
        "WHERE tool_call.operation_id=" ++ action ++ ".parent_operation_id AND tool_call.call_ordinal=" ++ action ++ ".call_ordinal " ++
        "AND @bytes(tool.name)=@payload(name)";
}

fn nonBashCallSql(comptime first: u8) []const u8 {
    return "(" ++ coreCallSql(first) ++ " OR EXISTS(" ++ offeredCallSelectSql("action", "operation", "1") ++ " AND " ++ tool_defs.sql.notDefaultTest("tool.owner", "tool.name") ++ "))";
}

pub fn actionStopKeysSql(comptime action: []const u8, comptime operation: []const u8) []const u8 {
    return "SELECT source_stop.command_key FROM session_stop source_stop WHERE " ++ sessionStopPredicate(action, operation);
}

fn selectedStopSql(comptime action: []const u8, comptime operation: []const u8) []const u8 {
    return "(source_stop.action_cutoff>=" ++ action ++ ".action_id OR source_stop.selected_turn_id=" ++ operation ++ ".turn_id)";
}

fn sessionStopPredicate(comptime action: []const u8, comptime operation: []const u8) []const u8 {
    return "source_stop.session_ref=" ++ action ++ ".session_ref AND " ++ selectedStopSql(action, operation);
}

pub fn stoppedSql(comptime session: []const u8, comptime selected: []const u8) []const u8 {
    return "(EXISTS(SELECT 1 FROM session_stop source_stop WHERE source_stop.session_ref=" ++ session ++ " AND " ++ selected ++
        ") OR EXISTS(SELECT 1 FROM session_stop_owed owed WHERE owed.child_ref=" ++ session ++ " AND owed.settled=0))";
}

fn messageDeclinesApprovalWithIndexSql(comptime action: []const u8, comptime index: []const u8) []const u8 {
    return "EXISTS(SELECT 1 FROM message_admission m" ++ index ++ " WHERE m.session_ref=" ++ action ++ ".session_ref AND " ++ sourced_input.messageSql("m") ++ " AND m.admission_position>" ++ action ++ ".approval_position)";
}

pub fn messageDeclinesApprovalSql(comptime action: []const u8) []const u8 {
    return messageDeclinesApprovalWithIndexSql(action, "");
}

test "automatic Message denial keeps its original selection predicate" {
    const actual = comptime messageDeclinesApprovalSql("action");
    try std.testing.expectEqualStrings(
        "EXISTS(SELECT 1 FROM message_admission m WHERE m.session_ref=action.session_ref AND m.source_kind IN (1,2) AND m.admission_position>action.approval_position)",
        actual,
    );
}

/// External decisions cannot be made after a Message has superseded the approval.
pub fn externalDecisionEligibleSql(comptime action: []const u8, comptime turn: []const u8) []const u8 {
    return action ++ ".authorized=0 AND " ++ action ++ ".resolution_code IS NULL AND (" ++ turn ++ ".outcome_code IS NULL OR " ++ action ++ ".background_position IS NOT NULL) AND NOT " ++
        messageDeclinesApprovalWithIndexSql(action, " @index(message_admission_position)");
}

pub fn actionStoppedSql(comptime action: []const u8, comptime operation: []const u8) []const u8 {
    return "(" ++ stoppedSql(action ++ ".session_ref", selectedStopSql(action, operation)) ++ " OR EXISTS(SELECT 1 FROM action_stop direct_stop WHERE direct_stop.target_action_id=" ++ action ++ ".action_id))";
}

pub fn stopCompletedSql(comptime stop: []const u8, comptime turn: []const u8, comptime end: []const u8) []const u8 {
    return "(" ++ stop ++ ".selected_turn_id IS NULL OR (" ++ turn ++ ".outcome_position IS NOT NULL AND (" ++ end ++ " IS NULL OR " ++ turn ++ ".outcome_position<=" ++ end ++ "))) AND NOT EXISTS(SELECT 1 FROM action_operation selected_action WHERE selected_action.session_ref=" ++ stop ++ ".session_ref AND selected_action.action_id<=" ++ stop ++ ".action_cutoff AND (selected_action.acceptance_position IS NULL OR (" ++ end ++ " IS NOT NULL AND selected_action.acceptance_position>" ++ end ++ ")))";
}

const capacity_sql = "(?1=1 AND (action.background_position IS NULL OR ?2=1))";

pub fn unresolvedSql(comptime action: []const u8) []const u8 {
    return action ++ ".resolution_code IS NULL";
}

pub fn eligibleSql(comptime action: []const u8, comptime operation: []const u8, comptime turn: []const u8) []const u8 {
    return unresolvedSql(action) ++ " AND (" ++ turn ++ ".outcome_code IS NULL OR " ++ action ++ ".background_position IS NOT NULL) AND NOT " ++
        actionStoppedSql(action, operation);
}

fn bashReadySql(comptime first: u8) []const u8 {
    return "action.authorized=1 AND action.attempt_ordinal=0 AND " ++ eligibleSql("action", "operation", "active") ++ " AND NOT " ++ nonBashCallSql(first);
}

const next_action_attempt = rsql.Read(.{
    .sql = "SELECT action.action_id,action.parent_operation_id,operation.turn_id,action.bash_timeout_override_ms,s.session_ref,s.workspace_key,s.next_position,action.background_position IS NOT NULL AS background " ++
        "FROM action_operation action @index(action_operation_executable) JOIN model_operation operation " ++
        "ON operation.operation_id=action.parent_operation_id JOIN turn active ON active.turn_id=operation.turn_id " ++
        "JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE " ++ bashReadySql(3) ++ " AND " ++ capacity_sql ++ " " ++
        "ORDER BY action.action_id LIMIT 1",
    .Args = CoreNames.Args(struct { foreground: bool, background: bool }),
    .Row = struct { action_id: rsql.Positive, parent_operation_id: rsql.Positive, turn_id: rsql.Positive, bash_timeout_override_ms: ?rsql.Positive, session: rsql.SessionHead, background: bool },
    .cardinality = .optional,
});
pub const next_action_attempt_sql = next_action_attempt.sql;

const next_core_action = rsql.Read(.{
    .compound = true,
    .sql = "SELECT action.action_id,action.parent_operation_id,operation.turn_id,s.session_ref AS session,action.background_position IS NOT NULL AS background,0 AS auto_deny," ++ coreCaseSql(3) ++
        "FROM action_operation action @index(action_operation_executable) JOIN model_operation operation " ++
        "ON operation.operation_id=action.parent_operation_id JOIN turn active ON active.turn_id=operation.turn_id " ++
        "JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.authorized=1 AND action.resolution_code IS NULL AND action.attempt_ordinal=0 " ++
        "AND (active.outcome_code IS NULL OR action.background_position IS NOT NULL) AND NOT " ++ actionStoppedSql("action", "operation") ++ " AND " ++ coreCallSql(3) ++ " " ++
        "AND NOT EXISTS(SELECT 1 FROM action_stop waiting JOIN action_operation target ON target.action_id=waiting.target_action_id WHERE waiting.source_action_id=action.action_id AND target.resolution_code IS NULL) " ++
        "UNION ALL SELECT action.action_id,action.parent_operation_id,operation.turn_id,s.session_ref AS session,action.background_position IS NOT NULL AS background,1 AS auto_deny,'read_action' AS tool " ++
        "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "JOIN turn active ON active.turn_id=operation.turn_id JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.authorized=0 AND action.resolution_code IS NULL AND action.approval_position IS NOT NULL " ++
        "AND ((active.outcome_code IS NULL AND active.operation_id=operation.operation_id) OR action.background_position IS NOT NULL) AND NOT " ++ actionStoppedSql("action", "operation") ++ " " ++
        "AND " ++ messageDeclinesApprovalSql("action") ++ " " ++
        "UNION ALL SELECT action.action_id,action.parent_operation_id,operation.turn_id,s.session_ref AS session,action.background_position IS NOT NULL AS background,0 AS auto_deny,'read_image' AS tool " ++
        "FROM action_operation action @index(action_operation_executable) JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "JOIN turn active ON active.turn_id=operation.turn_id JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE " ++ image_ready_sql ++ " AND " ++ capacity_sql ++ " " ++
        "ORDER BY auto_deny DESC,action_id LIMIT 1",
    .Args = CoreNames.Args(struct { foreground: bool, background: bool }),
    .Row = struct { action_id: rsql.Positive, parent_operation_id: rsql.Positive, turn_id: rsql.Positive, session: Bounded(session_id.max_reference_bytes), background: bool, auto_deny: bool, tool: SelectionTool },
    .cardinality = .optional,
});

pub const CoreTool = tool_defs.CoreTool;

const SelectionTool = blk: {
    const core_names = @typeInfo(CoreTool).@"enum".field_names;
    const names = core_names ++ &[_][]const u8{"read_image"};
    var values: [names.len]u8 = undefined;
    for (&values, 0..) |*value, i| value.* = @intCast(i);
    break :blk @Enum(u8, .exhaustive, names, &values);
};

pub const CoreActionInput = struct {
    binding: ActionAttemptBinding,
    tool: CoreTool,
    session: Bounded(session_id.max_reference_bytes),
    arguments: ContentReference,
};

pub const OwedStop = struct {
    session: Bounded(session_id.bytes),
    key: Bounded(idempotency_key.max_bytes),
};

pub const OwedEnding = struct {
    turn_id: u64,
    child: Bounded(session_id.bytes),
    parent: Bounded(session_id.bytes),
    ending: turn_ending.TurnEnding,
    answer: ?ContentReference,
    quiet: bool,
};

pub const CoreWork = union(enum) {
    stop: OwedStop,
    ending: OwedEnding,
    forward: u64,
    auto_deny: struct { action_id: u64, session: Bounded(session_id.max_reference_bytes) },
    action: CoreActionInput,
    mcp: ReadyAction,
    read_image: ReadyAction,
};

pub const ending_stop_sql = "EXISTS(SELECT 1 FROM session_stop st WHERE st.selected_turn_id=e.source_id) AS stopped," ++
    "(e.suppress_message=1 OR EXISTS(SELECT 1 FROM session_stop st WHERE st.selected_turn_id=e.source_id AND st.parent_caused=1)) AS quiet";

const owed_ending = rsql.Read(.{
    .sql = "SELECT e.source_id AS turn_id,t.session_ref,child.parent_ref,t.outcome_code,t.outcome_content_id,c.byte_length,c.digest," ++ ending_stop_sql ++ " " ++
        "FROM session_forward e @index(session_forward_message) JOIN turn t ON t.turn_id=e.source_id JOIN session child ON child.session_ref=t.session_ref " ++
        "LEFT JOIN content c ON c.content_id=t.outcome_content_id " ++
        "WHERE e.message_delivered=0 ORDER BY e.source_id LIMIT 1",
    .Args = struct {},
    .Row = struct {
        turn_id: rsql.Positive,
        session_ref: Bounded(session_id.bytes),
        parent_ref: ?Bounded(session_id.bytes),
        outcome_code: Bounded(outcome_code.max_bytes),
        outcome_content_id: ?rsql.Positive,
        byte_length: ?u64,
        digest: ?[32]u8,
        stopped: bool,
        quiet: bool,
    },
    .cardinality = .optional,
});

const owed_stop = rsql.Read(.{
    .sql = "SELECT child_ref,cause_ref,cause_position FROM session_stop_owed WHERE settled=0 ORDER BY child_ref LIMIT 1",
    .Args = struct {},
    .Row = struct { child_ref: Bounded(session_id.bytes), cause_ref: Bounded(session_id.bytes), cause_position: u64 },
    .cardinality = .optional,
});

pub fn owedStopKey(buffer: []u8, child: []const u8, cause: []const u8, position: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "rui.core/stop/{s}/{s}/{d}", .{ child, cause, position });
}

const CoreSelection = struct {
    stop: owed_stop.Result = undefined,
    ending: owed_ending.Result = undefined,
    forward: forward_domain.next.Result = undefined,
    action: next_core_action.Result = undefined,
    mcp: next_mcp_action.Result = null,

    fn queue(selection: *CoreSelection, a: anytype, capacity: Capacity) void {
        const names: CoreNames = .of();
        a.read(owed_stop, .{}, &selection.stop);
        if (capacity.includesMcp()) a.read(next_mcp_action, .{ .foreground = capacity.hasCredit(), .background = capacity.hasCredit() }, &selection.mcp);
        a.read(owed_ending, .{}, &selection.ending);
        a.read(forward_domain.next, .{}, &selection.forward);
        a.read(next_core_action, names.args(.{ .foreground = capacity.hasCredit(), .background = capacity.hasCredit() }), &selection.action);
    }
};

fn queueNextActionAttempt(a: anytype, capacity: Capacity, next: *next_action_attempt.Result) void {
    const names: CoreNames = .of();
    a.read(next_action_attempt, names.args(.{ .foreground = capacity.hasCredit(), .background = capacity.hasCredit() }), next);
}

pub const WorkProbe = struct {
    selection: CoreSelection = .{},
    bash_action: next_action_attempt.Result = undefined,

    pub fn queue(probe: *WorkProbe, a: anytype, capacity: Capacity) void {
        probe.selection.queue(a, capacity);
        queueNextActionAttempt(a, capacity, &probe.bash_action);
    }

    pub fn core(probe: *const WorkProbe) bool {
        const found = &probe.selection;
        return found.stop != null or found.ending != null or found.forward != null or (found.action != null and found.action.?.tool != .read_image);
    }

    pub fn mcp(probe: *const WorkProbe) bool {
        return probe.selection.mcp != null or (probe.selection.action != null and probe.selection.action.?.tool == .read_image);
    }

    pub fn bash(probe: *const WorkProbe) bool {
        return probe.bash_action != null;
    }
};

pub fn nextCoreWork(a: anytype, capacity: Capacity) !?CoreWork {
    var selection: CoreSelection = .{};
    selection.queue(a, capacity);
    try a.run();
    const stop = selection.stop;
    const ending = selection.ending;
    const forward = selection.forward;
    const mcp = selection.mcp;
    const next = selection.action;
    if (stop) |owed| {
        var work: OwedStop = .{ .session = owed.child_ref, .key = .{} };
        var buffer: [idempotency_key.max_bytes]u8 = undefined;
        try work.key.set(try owedStopKey(&buffer, owed.child_ref.slice(), owed.cause_ref.slice(), owed.cause_position));
        return .{ .stop = work };
    }
    if (ending) |owed| {
        const outcome = try turn_domain.TurnOutcome.decode(owed.outcome_code.slice(), if (owed.outcome_content_id) |id| @intCast(id.get()) else null);
        return .{ .ending = .{
            .turn_id = owed.turn_id.get(),
            .child = owed.session_ref,
            .parent = owed.parent_ref orelse return error.CorruptStore,
            .ending = outcome.ending(owed.stopped),
            .answer = if (outcome == .completed) .{ .length = owed.byte_length orelse return error.CorruptStore, .digest = owed.digest orelse return error.CorruptStore } else null,
            .quiet = owed.quiet,
        } };
    }
    if (forward) |owed| return .{ .forward = owed.forward_id.get() };
    if (mcp) |call| {
        if (next == null or call.action_id.get() < next.?.action_id.get())
            return .{ .mcp = .{ .action_id = call.action_id.get(), .runner = .mcp, .background = call.background, .server = call.server } };
    }
    const found = next orelse return null;
    if (found.auto_deny) return .{ .auto_deny = .{ .action_id = found.action_id.get(), .session = found.session } };
    if (found.tool == .read_image) return .{ .read_image = .{ .action_id = found.action_id.get(), .runner = .read_image, .background = found.background } };
    return .{ .action = .{
        .binding = .{ .turn_id = found.turn_id.get(), .parent_operation_id = found.parent_operation_id.get(), .action_id = found.action_id.get() },
        .tool = std.meta.stringToEnum(CoreTool, @tagName(found.tool)) orelse unreachable,
        .session = found.session,
        .arguments = try actionContent(a, found.session.slice(), found.action_id.get(), .arguments),
    } };
}

const attempt_action = rsql.Write(.{
    .sql = "UPDATE action_operation SET " ++ action_attempted_sql ++ ",attempt_at=@now,attempt_timeout_ms=?2,sender_handle=?3 " ++
        "WHERE action_id=?1 AND session_ref=@session(?4) AND authorized=1 AND resolution_code IS NULL AND attempt_ordinal=0",
    .Args = struct { action_id: u64, timeout_ms: u64, sender_handle: []const u8, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.ActionSelectionChanged } },
});

pub const ActionAttemptBinding = attempt.ActionAttemptBinding;

pub const SupersedingControl = struct {
    command_key: Bounded(idempotency_key.max_bytes),
};

pub const ActionAttemptAdmission = struct {
    permit: ActionDispatchPermit,
};

pub const ActionResolutionCode = enum {
    cancelled,
    succeeded,
    failed,
    timed_out,
    indeterminate,
    storage_failed,
    spawn_failed,
    infrastructure_shutdown,
};

pub const max_action_resolution_code_bytes = sqlite.maxEnumTagBytes(ActionResolutionCode);

pub const ActionSettlement = struct {
    pub const Outcome = enum { effect, session_stop };

    outcome: Outcome,
    kept: bool,
};

pub const ActionDispatchPermit = attempt.ActionDispatchPermit;

pub const ActionExecutionInput = struct {
    binding: ActionAttemptBinding,
    session: Bounded(session_id.max_reference_bytes),
    sender_handle: Bounded(32),
    arguments: ContentReference,
    timeout_ms: u64,
    runner: union(enum) {
        bash: struct { workspace: Bounded(workspace_path.max_bytes) },
        read_image: struct { workspace: Bounded(workspace_path.max_bytes) },
        mcp: struct {
            bash_offered: bool,
            parent: ?Bounded(session_id.max_reference_bytes),
            root: Bounded(session_id.max_reference_bytes),
            name: Bounded(tool_name.max_bytes),
            remote_name: Bounded(tool_name.max_bytes),
            server: Bounded(tool_defs.max_server_bytes),
            input_schema: ContentReference,
        },
    },
};

pub const ActiveOperationFilter = struct {
    context: *const anyopaque,
    containsFn: *const fn (*const anyopaque, u64) bool,
    maximum_exclusions: usize,

    pub fn contains(self: ActiveOperationFilter, operation_id: u64) bool {
        return self.containsFn(self.context, operation_id);
    }

    pub fn empty() ActiveOperationFilter {
        return .{
            .context = &empty_active_context,
            .containsFn = containsNoActiveOperation,
            .maximum_exclusions = 0,
        };
    }
};

pub const empty_active_context: u8 = 0;

fn containsNoActiveOperation(_: *const anyopaque, _: u64) bool {
    return false;
}

const action_call_position = rsql.Read(.{
    .sql = "SELECT item.session_position AS position FROM action_operation action JOIN model_tool_call tool_call " ++
        "ON tool_call.operation_id=action.parent_operation_id AND tool_call.call_ordinal=action.call_ordinal " ++
        "LEFT JOIN model_output_item item ON item.operation_id=tool_call.operation_id AND item.item_ordinal=tool_call.item_ordinal " ++
        "WHERE action.action_id=?1 AND action.session_ref=?2",
    .Args = struct { action_id: u64, session: []const u8 },
    .Row = struct { position: rsql.Positive },
    .cardinality = .optional,
});

pub fn actionContent(a: anytype, session_ref: []const u8, action_id: u64, field: tool_proposal.Field) !ContentReference {
    var found: action_call_position.Result = undefined;
    a.read(action_call_position, .{ .action_id = action_id, .session = session_ref }, &found);
    try a.run();
    const position = (found orelse return error.ActionNotFound).position.get();
    const reference = (try reads_domain.proposal(a, session_ref, position)).fields[@backingInt(field)];
    return .{ .length = reference.length, .digest = reference.digest };
}

pub const AdmitNextAttempt = struct {
    pub const rounds = transition.rounds(.{ .candidate = .{.always} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = null;
    pub const Input = struct { io: std.Io, timeout_ms: u64, capacity: Capacity };
    pub const Result = ?ActionAttemptAdmission;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{ActionSelectionChanged};
    pub const Declined = error{};

    input: Input,
    next: next_action_attempt.Result = undefined,
    sender_handle: [32]u8 = undefined,

    pub fn step(t: *AdmitNextAttempt, r: *transition.Round(AdmitNextAttempt), ran: ?rounds.At) !transition.Next(AdmitNextAttempt) {
        if (ran == null) {
            queueNextActionAttempt(r, t.input.capacity, &t.next);
            return .{ .round = .candidate };
        }
        const found = t.next orelse return .{ .done = null };
        var random: [16]u8 = undefined;
        try std.Io.randomSecure(t.input.io, &random);
        t.sender_handle = std.fmt.bytesToHex(random, .lower);
        r.write(attempt_action, .{
            .action_id = found.action_id.get(),
            .timeout_ms = if (found.bash_timeout_override_ms) |override| override.get() else t.input.timeout_ms,
            .sender_handle = &t.sender_handle,
            .session = found.session,
        });
        if (r.faults().attempt_before_commit) return error.InjectedAttemptCommitFailure;
        return .commit;
    }

    pub fn committed(t: *const AdmitNextAttempt) Result {
        const found = t.next.?;
        return .{ .permit = .{ .binding = .{
            .turn_id = found.turn_id.get(),
            .parent_operation_id = found.parent_operation_id.get(),
            .action_id = found.action_id.get(),
        } } };
    }
};

fn localInput(comptime runner: tool_defs.Runner) type {
    return rsql.Read(.{
        .sql = "SELECT item.session_position AS position,revision.workspace,action.session_ref AS session,action.sender_handle," ++
            "action.attempt_timeout_ms AS timeout_ms," ++ builtinCallSql(runner) ++ " AS runner_matches FROM action_operation action " ++
            "JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
            "JOIN session_revision revision ON revision.session_ref=action.session_ref AND revision.revision=action.permission_revision " ++
            "JOIN model_tool_call tool_call ON tool_call.operation_id=action.parent_operation_id AND tool_call.call_ordinal=action.call_ordinal " ++
            "LEFT JOIN model_output_item item ON item.operation_id=tool_call.operation_id AND item.item_ordinal=tool_call.item_ordinal " ++
            "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND operation.turn_id=?3 AND action." ++ action_attempted_sql ++
            " AND action.authorized=1 AND action.resolution_code IS NULL",
        .Args = struct { action_id: u64, parent_operation_id: u64, turn_id: u64 },
        .Row = struct {
            position: ?rsql.Positive,
            workspace: *Bounded(workspace_path.max_bytes),
            session: *Bounded(session_id.max_reference_bytes),
            sender_handle: *Bounded(32),
            timeout_ms: rsql.Positive,
            runner_matches: bool,
        },
        .cardinality = .optional,
    });
}

pub fn readBashExecutionInput(a: anytype, binding: ActionAttemptBinding, out: *ActionExecutionInput) !void {
    return readLocalExecutionInput(a, .bash, binding, out);
}

pub fn readImageExecutionInput(a: anytype, binding: ActionAttemptBinding, out: *ActionExecutionInput) !void {
    return readLocalExecutionInput(a, .read_image, binding, out);
}

fn readLocalExecutionInput(a: anytype, comptime runner: tool_defs.Runner, binding: ActionAttemptBinding, out: *ActionExecutionInput) !void {
    const input = localInput(runner);
    out.binding = binding;
    out.runner = @unionInit(@FieldType(ActionExecutionInput, "runner"), @tagName(runner), .{ .workspace = .{ .len = 0 } });
    var row: input.Row = .{ .position = null, .workspace = &@field(out.runner, @tagName(runner)).workspace, .session = &out.session, .sender_handle = &out.sender_handle, .timeout_ms = undefined, .runner_matches = undefined };
    var found: store_access.Found = undefined;
    a.readInto(input, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id }, &row, &found);
    try a.run();
    if (!found.get()) return error.StaleActionAttemptBinding;
    const position = (row.position orelse return error.CorruptStore).get();
    // Corrupt proposal fields must fence the Store even when the runner no longer matches.
    const proposal = try reads_domain.proposal(a, out.session.slice(), position);
    if (!row.runner_matches) return error.StaleActionAttemptBinding;
    const reference = proposal.fields[@backingInt(tool_proposal.Field.arguments)];
    out.arguments = .{ .length = reference.length, .digest = reference.digest };
    out.timeout_ms = row.timeout_ms.get();
}

pub const core_facts = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position,action.background_position IS NOT NULL AS background," ++
        actionStoppedSql("action", "operation") ++ " AS stopped," ++ coreCaseSql(4) ++
        "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND operation.turn_id=?3 " ++
        "AND action.authorized=1 AND action.attempt_ordinal=0 AND action.resolution_code IS NULL AND " ++ coreCallSql(4),
    .Args = CoreNames.Args(struct { action_id: u64, parent_operation_id: u64, turn_id: u64 }),
    .Row = struct { session: rsql.SessionHead, background: bool, stopped: bool, tool: CoreTool },
    .cardinality = .optional,
});

const resolve_unattempted_action = rsql.Write(.{
    .sql = "UPDATE action_operation SET resolution_code=?2,resolution_content_id=?3,acceptance_position=?4,resolved_at=@now " ++
        "WHERE action_id=?1 AND parent_operation_id=?5 AND session_ref=@session(?6) AND attempt_ordinal=0 AND resolution_code IS NULL",
    .Args = struct { action_id: u64, code: ActionResolutionCode, content_id: u64, position: u64, parent_operation_id: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

pub fn queueResolution(a: anytype, binding: ActionAttemptBinding, session: rsql.SessionHead, code: ActionResolutionCode, content_id: u64) !void {
    a.write(resolve_unattempted_action, .{
        .action_id = binding.action_id,
        .code = code,
        .content_id = content_id,
        .position = try (try a.positions(session)).take(1),
        .parent_operation_id = binding.parent_operation_id,
        .session = session,
    });
    turn_domain.queueContinuation(a, binding.turn_id, session);
}

const attempt_session = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position FROM action_operation action JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action." ++ action_attempted_sql,
    .Args = struct { action_id: u64, parent_operation_id: u64 },
    .Row = struct { session: rsql.SessionHead },
    .cardinality = .optional,
});

const revoke_sender = rsql.Write(.{
    .sql = "UPDATE action_operation SET sender_handle=NULL WHERE action_id=?1 AND parent_operation_id=?2 AND session_ref=@session(?3) AND " ++ action_attempted_sql,
    .Args = struct { action_id: u64, parent_operation_id: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

pub const RevokeSender = struct {
    pub const rounds = transition.rounds(.{ .attempt = .{.always} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .single;
    pub const begin: ?rounds.At = .attempt;
    pub const Input = struct { binding: ActionAttemptBinding };
    pub const Result = void;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{};
    pub const Declined = error{};

    input: Input,
    found: attempt_session.Result = undefined,

    pub fn step(t: *RevokeSender, r: *transition.Round(RevokeSender), ran: ?rounds.At) !transition.Next(RevokeSender) {
        const binding = t.input.binding;
        if (ran == null) {
            r.read(attempt_session, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id }, &t.found);
            return .{ .round = .attempt };
        }
        const row = t.found orelse return .{ .done = {} };
        r.write(revoke_sender, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .session = row.session });
        return .commit;
    }

    pub fn committed(_: *const RevokeSender) Result {}
};

const superseding_stop = rsql.Read(.{
    .sql = "SELECT coalesce((SELECT command.command_key FROM core_command command WHERE command.command_key IN (" ++ actionStopKeysSql("action", "operation") ++ ") ORDER BY command.command_seq LIMIT 1),'rui.core/action-stop') AS command_key " ++
        "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action." ++ action_attempted_sql ++ " AND (EXISTS(" ++ actionStopKeysSql("action", "operation") ++ ") OR EXISTS(SELECT 1 FROM action_stop direct_stop WHERE direct_stop.target_action_id=action.action_id))",
    .Args = struct { action_id: u64, parent_operation_id: u64 },
    .Row = struct { command_key: Bounded(idempotency_key.max_bytes) },
    .cardinality = .optional,
});

pub fn actionSupersededByStop(a: anytype, binding: ActionAttemptBinding) !?SupersedingControl {
    var stop: superseding_stop.Result = undefined;
    a.read(superseding_stop, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id }, &stop);
    try a.run();
    const row = stop orelse return null;
    return .{ .command_key = row.command_key };
}

const dispatch_facts = rsql.Read(.{
    .sql = "SELECT operation.turn_id,coalesce((SELECT max(m.admission_id) FROM message_admission m WHERE m.session_ref=action.session_ref),0) AS message_cutoff," ++ actionStoppedSql("action", "operation") ++ " AS stopped " ++
        "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action." ++ action_attempted_sql ++ " AND action.resolution_code IS NULL",
    .Args = struct { action_id: u64, parent_operation_id: u64 },
    .Row = struct { turn_id: rsql.Positive, message_cutoff: u64, stopped: bool },
    .cardinality = .optional,
});

pub fn validateActionDispatch(a: anytype, binding: ActionAttemptBinding) !u64 {
    var facts: dispatch_facts.Result = undefined;
    a.read(dispatch_facts, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id }, &facts);
    try a.run();
    const found = facts orelse return error.StaleActionAttemptBinding;
    if (found.turn_id.get() != binding.turn_id) return error.StaleActionAttemptBinding;
    if (found.stopped) return error.SupersededByControl;
    return found.message_cutoff;
}

const message_after_launch = rsql.Read(.{
    .sql = "SELECT EXISTS(SELECT 1 FROM message_admission m WHERE m.session_ref=action.session_ref AND m.admission_id>?2 AND m.turn_id IS NULL AND " ++ sourced_input.messageSql("m") ++ ") AS present FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id JOIN turn active ON active.turn_id=operation.turn_id WHERE action.action_id=?1 AND action.background_position IS NULL AND action.resolution_code IS NULL AND active.outcome_code IS NULL AND NOT " ++ actionStoppedSql("action", "operation"),
    .Args = struct { action_id: u64, cutoff: u64 },
    .Row = struct { present: bool },
    .cardinality = .optional,
});

pub fn messageAfterLaunch(a: anytype, binding: ActionAttemptBinding, cutoff: u64) !bool {
    var result: message_after_launch.Result = undefined;
    a.read(message_after_launch, .{ .action_id = binding.action_id, .cutoff = cutoff }, &result);
    try a.run();
    return if (result) |row| row.present else false;
}

const settle_facts = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position,operation.turn_id,action.background_position IS NOT NULL AS background," ++
        attemptRunnerSql() ++ " AS runner," ++
        actionStoppedSql("action", "operation") ++ " AS stopped,EXISTS(SELECT 1 FROM action_stop direct_stop WHERE direct_stop.target_action_id=action.action_id) AS direct_stop " ++
        "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action." ++ action_attempted_sql ++ " AND action.resolution_code IS NULL",
    .Args = struct { action_id: u64, parent_operation_id: u64 },
    .Row = struct { session: rsql.SessionHead, turn_id: rsql.Positive, background: bool, runner: tool_defs.Runner, stopped: bool, direct_stop: bool },
    .cardinality = .optional,
});

const resolve_action = rsql.Write(.{
    .sql = "UPDATE action_operation SET resolution_code=?2,resolution_content_id=?3,acceptance_position=?4,sender_handle=NULL,resolved_at=@now " ++
        "WHERE action_id=?1 AND parent_operation_id=?5 AND session_ref=@session(?6) AND " ++ action_attempted_sql ++ " AND resolution_code IS NULL",
    .Args = struct { action_id: u64, code: ActionResolutionCode, content_id: u64, position: u64, parent_operation_id: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.StaleActionAttemptBinding } },
});

pub const SettleAttempt = struct {
    pub const rounds = transition.rounds(.{ .facts = .{.always}, .content = .{.always}, .parts = .{.paged} });
    pub const round_budget = 3;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    pub const Input = struct { binding: ActionAttemptBinding, code: ActionResolutionCode, result: []const u8, saving: *@import("content_parts.zig").Saving, io: std.Io };
    pub const Result = ActionSettlement;
    pub const Ordinary = store_core.Ordinary.action_attempt;
    pub const Guards = store_core.Ordinary.action_attempt;
    pub const Declined = error{};

    input: Input,
    final_input: sourced_input.Final = .{},
    facts: settle_facts.Result = undefined,
    code: ActionResolutionCode = undefined,
    completion: turn_domain.stopped_turn.Result = null,
    kept: bool = true,

    pub fn step(t: *SettleAttempt, r: *transition.Round(SettleAttempt), ran: ?rounds.At) !transition.Next(SettleAttempt) {
        const binding = t.input.binding;
        const at = ran orelse {
            t.input.saving.restart();
            r.read(settle_facts, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id }, &t.facts);
            return .{ .round = .facts };
        };
        const found = if (t.facts) |*row| row else return error.StaleActionAttemptBinding;
        switch (at) {
            .facts => {
                if (found.turn_id.get() != binding.turn_id) return error.StaleActionAttemptBinding;
                const stopped = found.direct_stop or (found.stopped and found.runner != .mcp);
                t.code = if (stopped) .cancelled else t.input.code;
                if (stopped) {
                    t.kept = false;
                    const text = if (found.direct_stop) "Action was stopped." else found.runner.stoppedText(t.input.code, t.input.result);
                    t.input.saving.* = try .init(.{ .text = .{ .slice = text } });
                }
                if (try t.input.saving.step(r, t.input.io, r.faults()) != .round) return error.ContentChanged;
                if (found.stopped) r.read(turn_domain.stopped_turn, .{ .turn_id = binding.turn_id, .resolving_action_id = binding.action_id }, &t.completion);
                return .{ .round = .content };
            },
            .content, .parts => {
                if (r.faults().content_import) return error.InjectedContentImportFailure;
                const content_id = switch (try t.input.saving.step(r, t.input.io, r.faults())) {
                    .round => return .{ .round = .parts },
                    .saved => |saved| saved.content_id,
                };
                const positions = try r.positions(found.session);
                r.write(resolve_action, .{
                    .action_id = binding.action_id,
                    .code = t.code,
                    .content_id = content_id,
                    .position = try positions.take(1),
                    .parent_operation_id = binding.parent_operation_id,
                    .session = found.session,
                });
                try t.final_input.admit(r, &found.session, binding.action_id, content_id, .{ .background = found.background, .stopped = found.stopped });
                try turn_domain.queueStopCompletion(r, t.completion, binding.turn_id);
                turn_domain.queueContinuation(r, binding.turn_id, found.session);
                if (r.faults().before_commit) return error.InjectedCommitFailure;
                return .commit;
            },
        }
    }

    pub fn committed(t: *const SettleAttempt) Result {
        return .{ .outcome = if (t.facts.?.stopped) .session_stop else .effect, .kept = t.kept };
    }
};

const uncertain_actions = rsql.Read(.{
    .sql = "SELECT action_id FROM action_operation @index(action_operation_unresolved_attempt) " ++
        "WHERE resolution_code IS NULL AND " ++ action_attempted_sql ++ " ORDER BY action_id",
    .Args = struct {},
    .Row = struct { action_id: rsql.Positive },
    .cardinality = .each,
});

const uncertain_facts = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position,operation.turn_id,action.background_position IS NOT NULL AS background," ++ attemptRunnerSql() ++ " AS runner," ++ actionStoppedSql("action", "operation") ++ " AS stopped,EXISTS(SELECT 1 FROM action_stop direct_stop WHERE direct_stop.target_action_id=action.action_id) AS direct_stop FROM action_operation action " ++
        "JOIN model_operation operation ON operation.operation_id=action.parent_operation_id JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.action_id=?1 AND action.resolution_code IS NULL AND action." ++ action_attempted_sql,
    .Args = struct { action_id: u64 },
    .Row = struct { session: rsql.SessionHead, turn_id: rsql.Positive, background: bool, runner: tool_defs.Runner, stopped: bool, direct_stop: bool },
    .cardinality = .optional,
});

const resolve_uncertain = rsql.Write(.{
    .sql = "UPDATE action_operation SET resolution_code=?5,resolution_content_id=?2,acceptance_position=?3,resolved_at=@now " ++
        "WHERE action_id=?1 AND session_ref=@session(?4) AND resolution_code IS NULL AND " ++ action_attempted_sql,
    .Args = struct { action_id: u64, content_id: u64, position: u64, session: rsql.SessionHead, code: ActionResolutionCode },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.ActionSelectionChanged } },
});

fn recoveryContent(runner: tool_defs.Runner) content_domain.Import {
    return switch (runner) {
        inline .bash, .mcp, .read_image => |kind| comptime blk: {
            @setEvalBranchQuota(1_000_000);
            break :blk .ofBytes(kind.indeterminateText(), false);
        },
        // App calls never reach recovery: their cut-off is the app_call owner (design U6).
        .core, .provider, .app => unreachable,
    };
}

/// Every runner, so the recovery switches over `Runner` decide each one. Core commands resolve their call in
/// the transaction that admits it, so they never reach recovery. A call matching no offered record runs as
/// Bash. Names are unique within a tool set (a clashing MCP name is prefixed or left out; see EXR-69),
/// so the subquery yields at most one row.
fn attemptRunnerSql() []const u8 {
    return "COALESCE((" ++ offeredCallSelectSql("action", "operation", tool_defs.sql.runnerOf("tool.owner", "tool.name")) ++ "),'" ++ @tagName(tool_defs.default_runner) ++ "')";
}

const UncertainChoice = struct {
    active: ActiveOperationFilter,
    chosen: ?u64 = null,

    pub fn visit(choice: *UncertainChoice, row: *const uncertain_actions.Row) bool {
        if (choice.active.contains(row.action_id.get())) return true;
        choice.chosen = row.action_id.get();
        return false;
    }
};

pub const RecoverUncertain = struct {
    pub const rounds = transition.rounds(.{ .scan = .{.always}, .facts = .{.always}, .completion = .{.always} });
    pub const round_budget = 4;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    pub const Input = struct { active: ActiveOperationFilter };
    pub const Result = bool;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{ActionSelectionChanged};
    pub const Declined = error{};

    input: Input,
    final_input: sourced_input.Final = .{},
    choice: UncertainChoice = undefined,
    facts: uncertain_facts.Result = undefined,
    content: content_domain.Import = undefined,
    completion: turn_domain.stopped_turn.Result = undefined,

    pub fn step(t: *RecoverUncertain, r: *transition.Round(RecoverUncertain), ran: ?rounds.At) !transition.Next(RecoverUncertain) {
        const at = ran orelse {
            t.choice = .{ .active = t.input.active };
            r.readEach(uncertain_actions, .{}, try std.math.add(u64, t.input.active.maximum_exclusions, 1), &t.choice);
            return .{ .round = .scan };
        };
        const action_id = t.choice.chosen orelse return .{ .done = false };
        switch (at) {
            .scan => {
                r.read(uncertain_facts, .{ .action_id = action_id }, &t.facts);
                return .{ .round = .facts };
            },
            .facts => {
                const found = t.facts orelse return error.ActionSelectionChanged;
                t.content = if (found.direct_stop) .ofBytes("Action was stopped.", false) else recoveryContent(found.runner);
                content_domain.lookup(r, &t.content);
                r.read(turn_domain.stopped_turn, .{ .turn_id = found.turn_id.get(), .resolving_action_id = action_id }, &t.completion);
                return .{ .round = .completion };
            },
            .completion => {
                const found = &t.facts.?;
                const turn_id = found.turn_id.get();
                const positions = try r.positions(found.session);
                const text = if (found.direct_stop) "Action was stopped." else found.runner.indeterminateText();
                const content_id = try content_domain.importBytes(r, &t.content, text);
                r.write(resolve_uncertain, .{ .action_id = action_id, .content_id = content_id, .position = try positions.take(1), .session = found.session, .code = if (found.direct_stop) .cancelled else .indeterminate });
                try t.final_input.admit(r, &found.session, action_id, content_id, .{ .background = found.background, .stopped = found.stopped });
                try turn_domain.queueStopCompletion(r, t.completion, turn_id);
                turn_domain.queueContinuation(r, turn_id, found.session);
                return .commit;
            },
        }
    }

    pub fn committed(_: *const RecoverUncertain) Result {
        return true;
    }
};

const mcp_ready_sql = "action.authorized=1 AND action.attempt_ordinal=0 AND " ++ eligibleSql("action", "operation", "active");

const mcp_facts_sql = "SELECT action.action_id,action.parent_operation_id,operation.turn_id,s.session_ref,s.workspace_key,s.next_position,action.background_position IS NOT NULL AS background,NULL AS timeout_override_ms " ++
    "FROM action_operation action @index(action_operation_executable) " ++
    "JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
    "JOIN turn active ON active.turn_id=operation.turn_id JOIN session s ON s.session_ref=action.session_ref " ++
    "WHERE " ++ mcp_ready_sql ++ " AND " ++ mcpCallSql("action", "operation");
const ReadyFacts = struct { action_id: rsql.Positive, parent_operation_id: rsql.Positive, turn_id: rsql.Positive, session: rsql.SessionHead, background: bool, timeout_override_ms: ?rsql.Positive };
const next_mcp_action = rsql.Read(.{
    .compound = true,
    .sql = "WITH mcp_operations(operation_id) AS (" ++
        "SELECT active.operation_id FROM turn active @index(turn_one_active_per_session) WHERE active.outcome_code IS NULL " ++
        "UNION SELECT background.parent_operation_id FROM action_operation background @index(action_operation_background_ready) " ++
        "WHERE ?2=1 AND background.background_position IS NOT NULL AND background.authorized=1 AND background.resolution_code IS NULL AND background.attempt_ordinal=0) " ++
        "SELECT action.action_id,tool.server,action.background_position IS NOT NULL AS background " ++
        "FROM mcp_operations candidate " ++
        "CROSS JOIN model_operation operation ON operation.operation_id=candidate.operation_id " ++
        "CROSS JOIN turn active ON active.turn_id=operation.turn_id " ++
        "CROSS JOIN tool_set_member member ON member.tool_set_id=operation.tool_set_id " ++
        "CROSS JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id AND " ++ tool_defs.sql.runnerTest("tool.owner", "tool.name", .mcp) ++ " " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=operation.operation_id " ++
        "CROSS JOIN content name ON name.content_id=tool_call.name_content_id AND @payload(name)=@bytes(tool.name) " ++
        "CROSS JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id AND action.call_ordinal=tool_call.call_ordinal " ++
        "JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE " ++ mcp_ready_sql ++ " AND " ++ capacity_sql ++ " ORDER BY action.action_id LIMIT 1",
    .Args = struct { foreground: bool, background: bool },
    .Row = struct { action_id: rsql.Positive, server: Bounded(tool_defs.max_server_bytes), background: bool },
    .cardinality = .optional,
});
pub const next_mcp_action_sql = next_mcp_action.sql;

const image_ready_sql = "action.authorized=1 AND action.attempt_ordinal=0 AND " ++ eligibleSql("action", "operation", "active") ++ " AND " ++ builtinCallSql(.read_image);
const image_facts_sql = "SELECT action.action_id,action.parent_operation_id,operation.turn_id,s.session_ref,s.workspace_key,s.next_position,action.background_position IS NOT NULL AS background,NULL AS timeout_override_ms " ++
    "FROM action_operation action @index(action_operation_executable) JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
    "JOIN turn active ON active.turn_id=operation.turn_id JOIN session s ON s.session_ref=action.session_ref " ++
    "WHERE " ++ image_ready_sql;
const next_image_action = rsql.Read(.{
    .sql = image_facts_sql ++ " AND " ++ capacity_sql ++ " ORDER BY action.action_id LIMIT 1",
    .Args = struct { foreground: bool, background: bool },
    .Row = ReadyFacts,
    .cardinality = .optional,
});
const image_facts = rsql.Read(.{
    .sql = image_facts_sql ++ " AND action.action_id=?1",
    .Args = struct { action_id: u64 },
    .Row = ReadyFacts,
    .cardinality = .optional,
});

fn queueNextImageAction(a: anytype, capacity: Capacity, next: *next_image_action.Result) void {
    a.read(next_image_action, .{ .foreground = capacity.hasCredit(), .background = capacity.hasCredit() }, next);
}

pub const ReadyAction = struct {
    action_id: u64,
    runner: tool_defs.Runner,
    background: bool = false,
    server: Bounded(tool_defs.max_server_bytes) = .{},
};
pub fn nextAction(a: anytype, comptime runner: tool_defs.Runner, capacity: Capacity) !?ReadyAction {
    if (runner == .bash) {
        var next: next_action_attempt.Result = undefined;
        queueNextActionAttempt(a, capacity, &next);
        try a.run();
        const found = next orelse return null;
        return .{ .action_id = found.action_id.get(), .runner = .bash, .background = found.background };
    }
    if (runner == .read_image) {
        var next: next_image_action.Result = undefined;
        queueNextImageAction(a, capacity, &next);
        try a.run();
        const found = next orelse return null;
        return .{ .action_id = found.action_id.get(), .runner = .read_image, .background = found.background };
    }
    if (runner != .mcp) @compileError("only Action runners can select Actions");
    var row: next_mcp_action.Result = undefined;
    if (!capacity.includesMcp()) return null;
    a.read(next_mcp_action, .{ .foreground = capacity.hasCredit(), .background = capacity.hasCredit() }, &row);
    try a.run();
    const found = row orelse return null;
    return .{ .action_id = found.action_id.get(), .runner = .mcp, .background = found.background, .server = found.server };
}
const mcp_facts = rsql.Read(.{
    .sql = mcp_facts_sql ++ " AND action.action_id=?1",
    .Args = struct { action_id: u64 },
    .Row = ReadyFacts,
    .cardinality = .optional,
});
const bash_facts = rsql.Read(.{
    .sql = "SELECT action.action_id,action.parent_operation_id,operation.turn_id,s.session_ref,s.workspace_key,s.next_position,action.background_position IS NOT NULL AS background,action.bash_timeout_override_ms AS timeout_override_ms " ++
        "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "JOIN turn active ON active.turn_id=operation.turn_id JOIN session s ON s.session_ref=action.session_ref " ++
        "WHERE action.action_id=?1 AND " ++ bashReadySql(2),
    .Args = CoreNames.Args(struct { action_id: u64 }),
    .Row = ReadyFacts,
    .cardinality = .optional,
});

fn queueReadyFacts(a: anytype, selected: ReadyAction, facts: *mcp_facts.Result) void {
    switch (selected.runner) {
        .bash => a.read(bash_facts, CoreNames.of().args(.{ .action_id = selected.action_id }), facts),
        .mcp => a.read(mcp_facts, .{ .action_id = selected.action_id }, facts),
        .read_image => a.read(image_facts, .{ .action_id = selected.action_id }, facts),
        .core, .provider, .app => unreachable,
    }
}

pub const ResolveSelected = struct {
    pub const rounds = transition.rounds(.{ .facts = .{.always} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    pub const Input = struct { selected: ReadyAction, code: ActionResolutionCode, text: []const u8 };
    pub const Result = void;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{};
    pub const Declined = error{};

    input: Input,
    final_input: sourced_input.Final = .{},
    facts: mcp_facts.Result = undefined,
    content: content_domain.Import = undefined,

    pub fn step(t: *ResolveSelected, r: *transition.Round(ResolveSelected), ran: ?rounds.At) !transition.Next(ResolveSelected) {
        if (ran == null) {
            t.content = .ofBytes(t.input.text, false);
            queueReadyFacts(r, t.input.selected, &t.facts);
            content_domain.lookup(r, &t.content);
            return .{ .round = .facts };
        }
        const found = if (t.facts) |*row| row else return .commit;
        if (r.faults().content_import) return error.InjectedContentImportFailure;
        const content_id = try content_domain.importBytes(r, &t.content, t.input.text);
        try queueResolution(r, .{ .action_id = t.input.selected.action_id, .parent_operation_id = found.parent_operation_id.get(), .turn_id = found.turn_id.get() }, found.session, t.input.code, content_id);
        try t.final_input.admit(r, &found.session, t.input.selected.action_id, content_id, .{ .background = found.background, .stopped = false });
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    pub fn committed(_: *const ResolveSelected) Result {}
};

pub const AdmitSelected = struct {
    pub const rounds = transition.rounds(.{ .facts = .{.always} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    pub const Input = struct { io: std.Io, selected: ReadyAction, timeout_ms: u64 };
    pub const Result = ?ActionAttemptAdmission;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{ActionSelectionChanged};
    pub const Declined = error{};

    input: Input,
    facts: mcp_facts.Result = undefined,
    sender: [32]u8 = undefined,

    pub fn step(t: *AdmitSelected, r: *transition.Round(AdmitSelected), ran: ?rounds.At) !transition.Next(AdmitSelected) {
        if (ran == null) {
            queueReadyFacts(r, t.input.selected, &t.facts);
            return .{ .round = .facts };
        }
        const found = t.facts orelse return .commit;
        if (found.background != t.input.selected.background) {
            t.facts = null;
            return .commit;
        }
        var random: [16]u8 = undefined;
        try std.Io.randomSecure(t.input.io, &random);
        t.sender = std.fmt.bytesToHex(random, .lower);
        r.write(attempt_action, .{ .action_id = t.input.selected.action_id, .sender_handle = &t.sender, .session = found.session, .timeout_ms = if (found.timeout_override_ms) |value| value.get() else t.input.timeout_ms });
        if (r.faults().attempt_before_commit) return error.InjectedAttemptCommitFailure;
        return .commit;
    }

    pub fn committed(t: *const AdmitSelected) Result {
        const found = t.facts orelse return null;
        return .{ .permit = .{ .binding = .{ .action_id = t.input.selected.action_id, .parent_operation_id = found.parent_operation_id.get(), .turn_id = found.turn_id.get() } } };
    }
};
const mcp_input = rsql.Read(.{
    .sql = "SELECT item.session_position AS position,action.session_ref AS session,action.sender_handle,@payload(name) AS name,tool.remote_name,tool.server,schema_content.digest,schema_content.byte_length AS length,action.attempt_timeout_ms AS timeout_ms," ++
        "EXISTS(SELECT 1 FROM tool_set_member bash_member JOIN tool_record bash_tool ON bash_tool.tool_record_id=bash_member.tool_record_id " ++
        "WHERE bash_member.tool_set_id=operation.tool_set_id AND bash_tool.name='bash') AS bash_offered FROM action_operation action " ++
        "JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
        "JOIN model_tool_call tool_call ON tool_call.operation_id=action.parent_operation_id AND tool_call.call_ordinal=action.call_ordinal " ++
        "JOIN content name ON name.content_id=tool_call.name_content_id " ++
        "JOIN tool_set_member member ON member.tool_set_id=operation.tool_set_id " ++
        "JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id AND @bytes(tool.name)=@payload(name) AND " ++ tool_defs.sql.runnerTest("tool.owner", "tool.name", .mcp) ++ " " ++
        "JOIN content schema_content ON schema_content.content_id=tool.input_schema_content_id " ++
        "LEFT JOIN model_output_item item ON item.operation_id=tool_call.operation_id AND item.item_ordinal=tool_call.item_ordinal " ++
        "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND operation.turn_id=?3 AND action." ++ action_attempted_sql ++
        " AND action.resolution_code IS NULL AND " ++ mcpCallSql("action", "operation"),
    .Args = struct { action_id: u64, parent_operation_id: u64, turn_id: u64 },
    .Row = struct { position: ?rsql.Positive, session: *Bounded(session_id.max_reference_bytes), sender_handle: *Bounded(32), name: *Bounded(tool_name.max_bytes), remote_name: *Bounded(tool_name.max_bytes), server: *Bounded(tool_defs.max_server_bytes), digest: [32]u8, length: u64, timeout_ms: rsql.Positive, bash_offered: bool },
    .cardinality = .optional,
});
test "MCP execution input uses each engine's tool-name content layout" {
    const mysql = comptime mcp_input.mysql.prepared();
    const name_bytes = "coalesce((SELECT bytes FROM content_chunk WHERE content_chunk.content_id=name.content_id AND content_chunk.chunk_index=0),X'')";
    try std.testing.expect(std.mem.indexOf(u8, mcp_input.sql, "name.payload AS name") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp_input.sql, "CAST(tool.name AS BLOB)=name.payload") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, mysql, "name.payload"));
    try std.testing.expect(std.mem.indexOf(u8, mysql, name_bytes ++ " AS name") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysql, "CAST(tool.name AS BINARY)=" ++ name_bytes) != null);
}

const session_parent = rsql.Read(.{
    .sql = "SELECT parent_ref AS parent FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { parent: ?Bounded(session_id.max_reference_bytes) },
    .cardinality = .optional,
});
pub fn readMcpExecutionInput(a: anytype, binding: ActionAttemptBinding, out: *ActionExecutionInput) !void {
    out.binding = binding;
    out.runner = .{ .mcp = .{ .bash_offered = false, .parent = null, .root = .{ .len = 0 }, .name = .{ .len = 0 }, .remote_name = .{ .len = 0 }, .server = .{ .len = 0 }, .input_schema = .{ .length = 0, .digest = @splat(0) } } };
    const specific = &out.runner.mcp;
    var row: mcp_input.Row = .{ .position = null, .session = &out.session, .sender_handle = &out.sender_handle, .name = &specific.name, .remote_name = &specific.remote_name, .server = &specific.server, .digest = undefined, .length = undefined, .timeout_ms = undefined, .bash_offered = undefined };
    var found: store_access.Found = undefined;
    a.readInto(mcp_input, .{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id }, &row, &found);
    try a.run();
    if (!found.get()) return error.StaleActionAttemptBinding;
    specific.input_schema = .{ .length = row.length, .digest = row.digest };
    specific.bash_offered = row.bash_offered;
    out.timeout_ms = row.timeout_ms.get();
    const position = (row.position orelse return error.CorruptStore).get();
    const reference = (try reads_domain.proposal(a, out.session.slice(), position)).fields[@backingInt(tool_proposal.Field.arguments)];
    out.arguments = .{ .length = reference.length, .digest = reference.digest };
    specific.root = out.session;
    specific.parent = null;
    var first = true;
    while (true) {
        var ancestry: session_parent.Result = undefined;
        a.read(session_parent, .{ .session = specific.root.slice() }, &ancestry);
        try a.run();
        const parent = (ancestry orelse return error.CorruptStore).parent;
        if (first) specific.parent = parent;
        first = false;
        specific.root = parent orelse break;
    }
}
