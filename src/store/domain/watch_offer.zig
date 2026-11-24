const rsql = @import("../rsql.zig");
const model_settlement = @import("model_settlement.zig");
const AttemptBinding = @import("../../attempt.zig").AttemptBinding;

const offered = rsql.Read(.{
    .sql = "SELECT EXISTS(SELECT 1 FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=operation.tool_set_id AND tool.owner='rui' AND tool.name='watch_github_pr') AS offered FROM model_operation operation WHERE operation.operation_id=?1",
    .Args = struct { operation_id: u64 },
    .Row = struct { offered: bool },
    .cardinality = .optional,
});

pub fn watchOffered(a: anytype, binding: AttemptBinding) !bool {
    var standing: model_settlement.attempt_standing.Result = undefined;
    var result: offered.Result = undefined;
    model_settlement.queueAttemptKind(a, binding, &standing);
    a.read(offered, .{ .operation_id = binding.operation_id }, &result);
    try a.run();
    _ = try model_settlement.attemptKindOf(standing, binding);
    return (result orelse return error.StaleAttemptBinding).offered;
}
