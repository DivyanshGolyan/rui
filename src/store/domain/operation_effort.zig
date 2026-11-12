//! An Operation owns its admitted effort, its prior admitted fallback and
//! whether its own request emitted a boundary. Refusal observes that frozen
//! request, never a later reconstruction from configuration revisions.

pub fn refusedSql(comptime operation: []const u8) []const u8 {
    return "EXISTS(SELECT 1 FROM session_change refusal WHERE refusal.session_ref=" ++ operation ++ ".session_ref AND refusal.revision=" ++ operation ++ ".effort_source_revision AND refusal.field='reasoning_effort_refused' AND refusal.refused_operation_id=" ++ operation ++ ".operation_id)";
}

pub fn effectiveSql(comptime operation: []const u8) []const u8 {
    return "CASE WHEN " ++ refusedSql(operation) ++ " THEN " ++ operation ++ ".previous_reasoning_effort ELSE " ++ operation ++ ".reasoning_effort END";
}

pub fn emittedSql(comptime operation: []const u8) []const u8 {
    return operation ++ ".effort_update=1 AND NOT " ++ refusedSql(operation);
}

/// A restoration of the same previously admitted value is not a new choice.
/// First/top-level requests have no emitted boundary. Both eligibility facts
/// were frozen by admission; neither a revision nor an error's wording proves it.
pub fn refusalEligibleSql(comptime operation: []const u8) []const u8 {
    return "(" ++ emittedSql(operation) ++ ") AND " ++ operation ++ ".effort_source_revision>1 AND NOT @same(" ++ operation ++ ".reasoning_effort," ++ operation ++ ".previous_reasoning_effort) AND NOT EXISTS(SELECT 1 FROM session_change source_refusal WHERE source_refusal.session_ref=" ++ operation ++ ".session_ref AND source_refusal.revision=" ++ operation ++ ".effort_source_revision AND source_refusal.field='reasoning_effort_refused')";
}

pub fn previousSql(comptime session: []const u8, comptime boundary: []const u8, comptime model: []const u8) []const u8 {
    return "(SELECT " ++ effectiveSql("prior_effort") ++ " FROM model_operation prior_effort @index(model_operation_admission) JOIN session_revision prior_model ON prior_model.session_ref=prior_effort.session_ref AND prior_model.revision=prior_effort.settings_revision WHERE prior_effort.session_ref=" ++ session ++ " AND prior_effort.admission_position<" ++ boundary ++ " AND prior_model.model=" ++ model ++ " ORDER BY prior_effort.admission_position DESC LIMIT 1)";
}

/// The source revision owns the nullable override. A refusal maps that exact
/// choice to its refusing Operation's frozen prior override (NULL is a value).
pub fn sourceOverrideSql(comptime session: []const u8, comptime source: []const u8) []const u8 {
    return "(SELECT CASE WHEN refusal.refused_operation_id IS NOT NULL THEN refused.previous_effort_override ELSE choice.reasoning_effort END FROM session_revision choice LEFT JOIN session_change refusal ON refusal.session_ref=choice.session_ref AND refusal.revision=choice.revision AND refusal.field='reasoning_effort_refused' LEFT JOIN model_operation refused ON refused.operation_id=refusal.refused_operation_id AND refused.session_ref=choice.session_ref WHERE choice.session_ref=" ++ session ++ " AND choice.revision=" ++ source ++ ")";
}

pub fn previousOverrideSql(comptime session: []const u8, comptime boundary: []const u8, comptime model: []const u8) []const u8 {
    return "(SELECT " ++ sourceOverrideSql("prior_effort.session_ref", "prior_effort.effort_source_revision") ++ " FROM model_operation prior_effort @index(model_operation_admission) JOIN session_revision prior_model ON prior_model.session_ref=prior_effort.session_ref AND prior_model.revision=prior_effort.settings_revision WHERE prior_effort.session_ref=" ++ session ++ " AND prior_effort.admission_position<" ++ boundary ++ " AND prior_model.model=" ++ model ++ " ORDER BY prior_effort.admission_position DESC LIMIT 1)";
}
