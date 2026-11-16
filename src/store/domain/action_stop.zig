const std = @import("std");
const action = @import("action.zig");
const control = @import("../../action_control.zig");
const content = @import("content.zig");
const transition = @import("../transition.zig");
const store = @import("../Store.zig");
const rsql = @import("../rsql.zig");

const target = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position,a.parent_operation_id,op.turn_id,a.attempt_ordinal,a.acceptance_position," ++
        "EXISTS(SELECT 1 FROM action_stop stop WHERE stop.target_action_id=a.action_id) AS selected " ++
        "FROM action_operation a JOIN model_operation op ON op.operation_id=a.parent_operation_id " ++
        "JOIN session s ON s.session_ref=a.session_ref WHERE a.action_id=?1",
    .Args = struct { action_id: u64 },
    .Row = struct {
        session: rsql.SessionHead,
        parent_operation_id: rsql.Positive,
        turn_id: rsql.Positive,
        attempt_ordinal: u64,
        acceptance_position: ?rsql.Positive,
        selected: bool,
    },
    .cardinality = .optional,
});

const save = rsql.Write(.{
    .sql = "INSERT INTO action_stop(source_action_id,target_action_id) VALUES(?1,?2)",
    .Args = struct { source: u64, target: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.ActionSelectionChanged } },
});

const stopped_text = @import("../../tool_record.zig").Runner.bash.beforeAdmissionStopText();
const stopped_content: content.Import = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk .ofBytes(stopped_text, false);
};

pub const Outcome = union(enum) { selected, pending, final: u64, not_found, invalid_target };

pub const Stop = struct {
    pub const rounds = transition.rounds(.{ .facts = .{.always}, .content = .{.branch} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    pub const Input = struct { source: action.ActionAttemptBinding, target: u64 };
    pub const Result = Outcome;
    pub const Ordinary = store.Ordinary.action_attempt;
    pub const Guards = error{ActionSelectionChanged};
    pub const Declined = error{};

    input: Input,
    source: action.core_facts.Result = null,
    target: target.Result = null,
    content: content.Import = stopped_content,
    result: Result = undefined,

    pub fn step(t: *Stop, r: *transition.Round(Stop), ran: ?rounds.At) !transition.Next(Stop) {
        const binding = t.input.source;
        const at = ran orelse {
            r.read(action.core_facts, action.CoreNames.of().args(.{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id }), &t.source);
            if (t.input.target > 0 and t.input.target <= std.math.maxInt(i64)) r.read(target, .{ .action_id = t.input.target }, &t.target);
            return .{ .round = .facts };
        };
        const source = t.source orelse return error.StaleActionAttemptBinding;
        if (source.stopped or source.tool != .stop_action) return error.StaleActionAttemptBinding;
        if (t.input.target == binding.action_id) return .{ .done = .invalid_target };
        const found = t.target orelse return .{ .done = .not_found };
        if (!std.mem.eql(u8, &source.session.ref, &found.session.ref)) return .{ .done = .not_found };
        if (at == .content) {
            const id = try content.importBytes(r, &t.content, stopped_text);
            try action.queueResolution(r, .{ .action_id = t.input.target, .parent_operation_id = found.parent_operation_id.get(), .turn_id = found.turn_id.get() }, found.session, .cancelled, id);
            if (r.faults().before_commit) return error.InjectedCommitFailure;
            return .commit;
        }
        const choice = control.chooseStop(.{ .final_position = if (found.acceptance_position) |p| p.get() else null, .stop_selected = found.selected });
        if (choice == .final) return .{ .done = .{ .final = choice.final } };
        r.write(save, .{ .source = binding.action_id, .target = t.input.target });
        t.result = if (choice == .pending) .pending else .selected;
        if (found.attempt_ordinal == 0) {
            content.lookup(r, &t.content);
            return .{ .round = .content };
        }
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    pub fn committed(t: *const Stop) Result {
        return t.result;
    }
};
