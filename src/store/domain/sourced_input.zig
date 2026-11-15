const std = @import("std");
const Bounded = @import("../../bounded.zig").Bounded;
const session_id = @import("../../session_id.zig");
const rsql = @import("../rsql.zig");

pub const Source = union(enum) {
    person: []const u8,
    peer: struct { key: []const u8, sender: rsql.SessionHead },
};

pub const Provenance = union(enum) {
    person,
    peer: Bounded(session_id.max_reference_bytes),
    tool_final: u64,
};

pub fn provenance(sender: ?Bounded(session_id.max_reference_bytes), final_action_id: ?u64) error{CorruptStore}!Provenance {
    if (final_action_id) |action_id| {
        if (sender != null or action_id == 0) return error.CorruptStore;
        return .{ .tool_final = action_id };
    }
    return if (sender) |value| .{ .peer = value } else .person;
}

pub fn columns(comptime alias: []const u8) []const u8 {
    return alias ++ ".content_id," ++ alias ++ ".sender_session_ref," ++ alias ++ ".final_action_id";
}

pub fn provenanceColumns(comptime alias: []const u8) []const u8 {
    return alias ++ ".sender_session_ref AS sender," ++ alias ++ ".final_action_id AS final_action_id";
}

pub fn personSql(comptime alias: []const u8) []const u8 {
    return alias ++ ".sender_session_ref IS NULL AND " ++ alias ++ ".final_action_id IS NULL";
}

/// A stop selects the source, not its causal Turn's continuing lifetime.
/// The Turn condition preserves selections saved before format 75.
pub fn actionStopKeysSql(comptime action: []const u8, comptime operation: []const u8) []const u8 {
    return "SELECT source_stop.command_key FROM session_stop source_stop WHERE " ++ sessionStopPredicate(action, operation) ++
        " UNION ALL SELECT source_control.command_key FROM action_control_command source_control WHERE " ++ controlStopPredicate(action);
}

fn sessionStopPredicate(comptime action: []const u8, comptime operation: []const u8) []const u8 {
    return "source_stop.session_ref=" ++ action ++ ".session_ref AND (source_stop.action_cutoff>=" ++ action ++ ".action_id OR source_stop.selected_turn_id=" ++ operation ++ ".turn_id)";
}

fn controlStopPredicate(comptime action: []const u8) []const u8 {
    return "source_control.selected_action_id=" ++ action ++ ".action_id AND source_control.selection='stop'";
}

pub fn actionStopPositionSql(comptime action: []const u8, comptime operation: []const u8) []const u8 {
    return "(SELECT min(coalesce(source_stop.position,source_control.selection_position)) FROM core_command source_command LEFT JOIN session_stop source_stop ON source_stop.command_key=source_command.command_key LEFT JOIN action_control_command source_control ON source_control.command_key=source_command.command_key WHERE source_command.command_key IN (" ++ actionStopKeysSql(action, operation) ++ "))";
}

pub fn actionStoppedSql(comptime action: []const u8, comptime operation: []const u8) []const u8 {
    return "(EXISTS(SELECT 1 FROM session_stop source_stop WHERE " ++ sessionStopPredicate(action, operation) ++
        ") OR EXISTS(SELECT 1 FROM action_control_command source_control WHERE " ++ controlStopPredicate(action) ++ "))";
}

/// Stop completion includes every selected Action, even after its causal Turn.
/// `end` is the reader's snapshot frontier; live control supplies SQL NULL.
pub fn stopCompletedSql(comptime stop: []const u8, comptime turn: []const u8, comptime end: []const u8) []const u8 {
    return "(" ++ stop ++ ".selected_turn_id IS NULL OR (" ++ turn ++ ".outcome_position IS NOT NULL AND (" ++ end ++ " IS NULL OR " ++ turn ++ ".outcome_position<=" ++ end ++ "))) AND NOT EXISTS(SELECT 1 FROM action_operation selected_action WHERE selected_action.session_ref=" ++ stop ++ ".session_ref AND selected_action.action_id<=" ++ stop ++ ".action_cutoff AND (selected_action.acceptance_position IS NULL OR (" ++ end ++ " IS NOT NULL AND selected_action.acceptance_position>" ++ end ++ ")))";
}

/// Both variants validate their authority through their original source.
/// A final never borrows the command entitlement of a person or peer.
pub fn consistentSql(comptime alias: []const u8) []const u8 {
    return "((" ++ alias ++ ".final_action_id IS NULL AND EXISTS(SELECT 1 FROM core_command input_command WHERE input_command.command_key=" ++ alias ++ ".command_key AND input_command.kind=2 AND input_command.accepted=1 AND input_command.target=" ++ alias ++ ".session_ref AND input_command.primary_content_id=" ++ alias ++ ".content_id)) OR (" ++ alias ++ ".final_action_id IS NOT NULL AND " ++ alias ++ ".command_key IS NULL AND EXISTS(SELECT 1 FROM action_operation input_action WHERE input_action.session_ref=" ++ alias ++ ".session_ref AND input_action.action_id=" ++ alias ++ ".final_action_id AND input_action.resolution_content_id=" ++ alias ++ ".content_id AND input_action.acceptance_position<" ++ alias ++ ".admission_position) AND NOT EXISTS(SELECT 1 FROM message_skill input_skill WHERE input_skill.admission_id=" ++ alias ++ ".admission_id)))";
}

fn Admission(comptime peer: bool) type {
    return rsql.Write(.{
        .sql = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,sender_session_ref,sender_position) " ++
            "VALUES(?1,@session(?2),?3,?4,?5,@now," ++ (if (peer) "@session(?6),?7)" else "NULL,NULL)"),
        .Args = if (peer) struct { admission_id: u64, session: rsql.SessionHead, key: []const u8, content_id: u64, position: u64, sender: rsql.SessionHead, sender_position: u64 } else struct { admission_id: u64, session: rsql.SessionHead, key: []const u8, content_id: u64, position: u64 },
        .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
    });
}
pub const admit_sql = Admission(false).sql;

pub fn queue(a: anytype, session: rsql.SessionHead, source: Source, content_id: u64) !u64 {
    const admission_id = try a.identity(.admission_id);
    const position = try (try a.positions(session)).take(1);
    switch (source) {
        .person => |key| a.write(Admission(false), .{ .admission_id = admission_id, .session = session, .key = key, .content_id = content_id, .position = position }),
        .peer => |peer| a.write(Admission(true), .{ .admission_id = admission_id, .session = session, .key = peer.key, .content_id = content_id, .position = position, .sender = peer.sender, .sender_position = try (try a.positions(peer.sender)).take(1) }),
    }
    return admission_id;
}

const admit_final = rsql.Write(.{
    .sql = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,final_action_id) " ++
        "SELECT ?1,@session(?2),NULL,action.resolution_content_id,?3,@now,action.action_id " ++
        "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id AND operation.session_ref=action.session_ref " ++
        "WHERE action.action_id=?4 AND action.session_ref=@session(?2) AND action.background_position IS NOT NULL " ++
        "AND action.resolution_content_id IS NOT NULL AND action.acceptance_position<?3 AND NOT " ++ actionStoppedSql("action", "operation") ++ " LIMIT 1",
    .Args = struct { admission_id: u64, session: rsql.SessionHead, position: u64, action_id: u64 },
    .expect = .{ .at_most = 1 },
});

/// Called immediately after the sole final write in the same transaction.
/// The source selection still suppresses late delivery after fresh user work.
/// No command, skill binding or payload copy is manufactured for a final.
pub fn queueFinal(a: anytype, session: rsql.SessionHead, action_id: u64, background: bool) !void {
    if (!background) return;
    a.write(admit_final, .{
        .admission_id = try a.identity(.admission_id),
        .session = session,
        .position = try (try a.positions(session)).take(1),
        .action_id = action_id,
    });
}

test "input provenance never attributes an Action final to a person or peer" {
    try std.testing.expectEqual(Provenance.person, try provenance(null, null));
    var peer: Bounded(session_id.max_reference_bytes) = .{};
    try peer.set("abcdef");
    try std.testing.expectEqualStrings(peer.slice(), (try provenance(peer, null)).peer.slice());
    try std.testing.expectEqual(@as(u64, 42), (try provenance(null, 42)).tool_final);
    try std.testing.expectError(error.CorruptStore, provenance(peer, 42));
    try std.testing.expectError(error.CorruptStore, provenance(null, 0));
}
