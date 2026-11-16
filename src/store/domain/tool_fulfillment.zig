pub fn positionSql(comptime call: []const u8, comptime action: []const u8) []const u8 {
    return "coalesce(" ++ call ++ ".acceptance_position," ++ action ++ ".background_position," ++ action ++ ".acceptance_position)";
}

pub fn contentSql(comptime call: []const u8, comptime action: []const u8) []const u8 {
    return "coalesce(" ++ call ++ ".rejection_content_id," ++ action ++ ".background_content_id," ++ action ++ ".resolution_content_id)";
}

pub fn actionPositionSql(comptime action: []const u8) []const u8 {
    return "coalesce(" ++ action ++ ".background_position," ++ action ++ ".acceptance_position)";
}

pub fn actionCompleteSql(comptime action: []const u8) []const u8 {
    return "(" ++ action ++ ".background_position IS NOT NULL OR " ++ action ++ ".resolution_code IS NOT NULL)";
}

pub fn actionContentSql(comptime action: []const u8) []const u8 {
    return "coalesce(" ++ action ++ ".background_content_id," ++ action ++ ".resolution_content_id)";
}

pub fn timeSql(comptime action: []const u8, comptime operation: []const u8) []const u8 {
    return "coalesce(" ++ action ++ ".background_at," ++ action ++ ".resolved_at," ++ operation ++ ".resolved_at)";
}

pub fn codeSql(comptime call: []const u8, comptime action: []const u8) []const u8 {
    return "coalesce(" ++ call ++ ".rejection_code,CASE WHEN " ++ action ++ ".background_position IS NOT NULL THEN 'background' ELSE " ++ action ++ ".resolution_code END)";
}

/// A final shares the call group's publication only when it fulfilled that
/// call. A background receipt fulfilled it earlier; its final stays separate.
pub fn resolutionPublicationSql(comptime action: []const u8, comptime publication: []const u8) []const u8 {
    return "CASE WHEN " ++ action ++ ".acceptance_position=" ++ actionPositionSql(action) ++ " THEN " ++ publication ++ " END";
}
