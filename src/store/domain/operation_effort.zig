const replay_wire = @import("replay_wire.zig");

pub fn refusedSql(comptime operation: []const u8) []const u8 {
    return "EXISTS(SELECT 1 FROM session_change refusal WHERE refusal.session_ref=" ++ operation ++ ".session_ref AND refusal.revision=" ++ operation ++ ".effort_source_revision AND refusal.field='reasoning_effort_refused' AND refusal.refused_operation_id=" ++ operation ++ ".operation_id)";
}

pub fn effectiveSql(comptime operation: []const u8) []const u8 {
    return "CASE WHEN " ++ refusedSql(operation) ++ " THEN " ++ operation ++ ".previous_reasoning_effort ELSE " ++ operation ++ ".reasoning_effort END";
}

pub fn emittedSql(comptime operation: []const u8) []const u8 {
    return operation ++ ".effort_update=1 AND NOT " ++ refusedSql(operation);
}

pub fn refusalEligibleSql(comptime operation: []const u8) []const u8 {
    return "(" ++ emittedSql(operation) ++ ") AND " ++ operation ++ ".effort_source_revision>1 AND NOT @same(" ++ operation ++ ".reasoning_effort," ++ operation ++ ".previous_reasoning_effort) AND NOT EXISTS(SELECT 1 FROM session_change source_refusal WHERE source_refusal.session_ref=" ++ operation ++ ".session_ref AND source_refusal.revision=" ++ operation ++ ".effort_source_revision AND source_refusal.field='reasoning_effort_refused')";
}

fn priorSql(comptime projection: []const u8, comptime session: []const u8, comptime boundary: []const u8, comptime request: replay_wire.Side) []const u8 {
    return "(SELECT " ++ projection ++ " FROM model_operation prior_effort @index(model_operation_admission) JOIN session_revision prior_model ON prior_model.session_ref=prior_effort.session_ref AND prior_model.revision=prior_effort.settings_revision WHERE prior_effort.session_ref=" ++ session ++ " AND prior_effort.admission_position<" ++ boundary ++ " AND " ++ replay_wire.sameBindingSql(replay_wire.revisionSide("prior_model"), request) ++ " ORDER BY prior_effort.admission_position DESC LIMIT 1)";
}

pub fn previousSql(comptime session: []const u8, comptime boundary: []const u8, comptime request: replay_wire.Side) []const u8 {
    return priorSql(effectiveSql("prior_effort"), session, boundary, request);
}

pub fn sourceOverrideSql(comptime session: []const u8, comptime source: []const u8) []const u8 {
    return "(SELECT CASE WHEN refusal.refused_operation_id IS NOT NULL THEN refused.previous_effort_override ELSE choice.reasoning_effort END FROM session_revision choice LEFT JOIN session_change refusal ON refusal.session_ref=choice.session_ref AND refusal.revision=choice.revision AND refusal.field='reasoning_effort_refused' LEFT JOIN model_operation refused ON refused.operation_id=refusal.refused_operation_id AND refused.session_ref=choice.session_ref WHERE choice.session_ref=" ++ session ++ " AND choice.revision=" ++ source ++ ")";
}

pub fn previousOverrideSql(comptime session: []const u8, comptime boundary: []const u8, comptime request: replay_wire.Side) []const u8 {
    return priorSql(sourceOverrideSql("prior_effort.session_ref", "prior_effort.effort_source_revision"), session, boundary, request);
}
