const std = @import("std");
const action = @import("action.zig");
const control = @import("../../action_control.zig");
const content = @import("content.zig");
const transition = @import("../transition.zig");
const store = @import("../Store.zig");
const command = @import("command.zig");
const command_input = @import("../../command_input.zig");
const session_id = @import("../../session_id.zig");
const Bounded = @import("../../bounded.zig").Bounded;
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
    .sql = "INSERT INTO action_stop(stop_key,source_action_id,source_command_key,target_action_id) VALUES(?1,?2,?3,?4)",
    .Args = struct { key: []const u8, model: ?u64, command: ?[]const u8, target: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.ActionSelectionChanged } },
});
const receiver = rsql.Read(.{
    .sql = "SELECT session_ref FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { session_ref: Bounded(session_id.max_reference_bytes) },
    .cardinality = .optional,
});
const save_request = rsql.Write(.{
    .sql = "INSERT INTO action_stop_command(command_key,action_id,resolution_position) VALUES(?1,?2,?3)",
    .Args = struct { key: []const u8, action: []const u8, resolution: ?u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});
const saved_request = rsql.Read(.{
    .sql = "SELECT action_id,resolution_position FROM action_stop_command WHERE command_key=?1",
    .Args = struct { key: []const u8 },
    .Row = struct { action_id: Bounded(20), resolution_position: ?rsql.Positive },
    .cardinality = .one,
});
pub const Observation = control.StopObservation;
fn observation(row: saved_request.Row) !Observation {
    return .{ .action_id = std.fmt.parseInt(u64, row.action_id.slice(), 10) catch return error.CorruptStore, .resolution = if (row.resolution_position) |p| p.get() else null };
}
pub fn readSaved(a: anytype, key: []const u8) !Observation {
    var row: saved_request.Row = undefined;
    a.read(saved_request, .{ .key = key }, &row);
    try a.run();
    return observation(row);
}
pub const Reply = control.StopReply;
pub const Source = union(enum) {
    model: struct { binding: action.ActionAttemptBinding, target: u64 },
    command: *const command_input.ActionStopCommand,
};

const stopped_text = @import("../../tool_record.zig").Runner.bash.beforeAdmissionStopText();
const stopped_content: content.Import = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk .ofBytes(stopped_text, false);
};

pub const Outcome = union(enum) { selected, pending, final: u64, not_found, invalid_target };

pub const Stop = struct {
    pub const rounds = transition.rounds(.{ .facts = .{.always}, .content = .{.branch}, .replay = .{.branch} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    pub const Scratch = struct { stop_key: [130]u8, action_text: [20]u8 };
    pub const Input = struct { source: Source, scratch: *Scratch };
    pub const Result = union(enum) { model: Outcome, command: Reply };
    pub const Ordinary = store.Ordinary.action_attempt;
    pub const Guards = error{ActionSelectionChanged};
    pub const Declined = error{};

    input: Input,
    source: action.core_facts.Result = null,
    target: target.Result = null,
    content: content.Import = stopped_content,
    result: Result = undefined,
    saved: command.saved_command.Result = undefined,
    receiver: receiver.Result = null,
    replay: saved_request.Result = undefined,
    digest: [32]u8 = undefined,
    answer: command.StoredAnswer = undefined,

    pub fn step(t: *Stop, r: *transition.Round(Stop), ran: ?rounds.At) !transition.Next(Stop) {
        const id = switch (t.input.source) {
            .model => |m| m.target,
            .command => |c| c.action_id,
        };
        const at = ran orelse {
            switch (t.input.source) {
                .model => |m| r.read(action.core_facts, action.CoreNames.of().args(.{ .action_id = m.binding.action_id, .parent_operation_id = m.binding.parent_operation_id, .turn_id = m.binding.turn_id }), &t.source),
                .command => |c| {
                    command.lookupCommand(r, c.key.slice(), &t.saved);
                    if (session_id.valid(c.session.slice())) r.read(receiver, .{ .session = c.session.slice() }, &t.receiver);
                },
            }
            if (id > 0 and id <= std.math.maxInt(i64)) r.read(target, .{ .action_id = id }, &t.target);
            return .{ .round = .facts };
        };
        switch (t.input.source) {
            .model => |m| {
                const source = t.source orelse return error.StaleActionAttemptBinding;
                if (source.stopped or source.tool != .stop_action) return error.StaleActionAttemptBinding;
                if (id == m.binding.action_id) return .{ .done = .{ .model = .invalid_target } };
                const found = t.target orelse return .{ .done = .{ .model = .not_found } };
                if (!std.mem.eql(u8, &source.session.ref, &found.session.ref)) return .{ .done = .{ .model = .not_found } };
            },
            .command => |c| if (at == .facts) {
                t.digest = c.semanticDigest();
                switch (try command.classify(control.Rejection, &t.saved, .action_stop, c.session.slice(), &t.digest)) {
                    .fresh => {},
                    .conflict => return .{ .done = .{ .command = .conflict } },
                    .accepted => {
                        r.read(saved_request, .{ .key = c.key.slice() }, &t.replay);
                        return .{ .round = .replay };
                    },
                    .rejected => |code| return .{ .done = .{ .command = .{ .rejected = .{ .replayed = true, .code = code } } } },
                }
                const refusal: ?control.Rejection = if (!session_id.valid(c.session.slice())) .invalid_session_reference else if (id == 0 or id > std.math.maxInt(i64)) .invalid_target else if (t.receiver == null) .unknown_session else if (t.target == null) .unknown_action else if (!std.mem.eql(u8, &t.target.?.session.ref, c.session.slice())) .target_mismatch else null;
                if (refusal) |code| return t.record(r, .{ .rejected = .{ .replayed = false, .code = code } });
            } else if (at == .replay) {
                const old = try observation(t.replay);
                return .{ .done = .{ .command = .{ .accepted = .{ .replayed = true, .action_id = old.action_id, .resolution = old.resolution } } } };
            },
        }
        const found = t.target.?;
        if (at == .content) {
            const content_id = try content.importBytes(r, &t.content, stopped_text);
            try action.queueResolution(r, .{ .action_id = id, .parent_operation_id = found.parent_operation_id.get(), .turn_id = found.turn_id.get() }, found.session, .cancelled, content_id, .call_line);
            if (r.faults().before_commit) return error.InjectedCommitFailure;
            return .commit;
        }
        const choice = control.chooseStop(.{ .final_position = if (found.acceptance_position) |p| p.get() else null, .stop_selected = found.selected });
        if (choice == .final) return switch (t.input.source) {
            .model => .{ .done = .{ .model = .{ .final = choice.final } } },
            .command => t.record(r, .{ .accepted = .{ .replayed = false, .action_id = id, .resolution = choice.final } }),
        };
        const key = switch (t.input.source) {
            .model => |m| try std.fmt.bufPrint(&t.input.scratch.stop_key, "a/{d}", .{m.binding.action_id}),
            .command => |c| try std.fmt.bufPrint(&t.input.scratch.stop_key, "c/{s}", .{c.key.slice()}),
        };
        // Each authority records its own selection; every reader uses this one table.
        switch (t.input.source) {
            .model => t.result = .{ .model = if (choice == .pending) .pending else .selected },
            .command => {
                _ = try t.record(r, .{ .accepted = .{ .replayed = false, .action_id = id, .resolution = null } });
            },
        }
        r.write(save, .{ .key = key, .model = if (t.input.source == .model) t.input.source.model.binding.action_id else null, .command = if (t.input.source == .command) t.input.source.command.key.slice() else null, .target = id });
        if (found.attempt_ordinal == 0) {
            content.lookup(r, &t.content);
            return .{ .round = .content };
        }
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    fn record(t: *Stop, r: *transition.Round(Stop), reply: Reply) !transition.Next(Stop) {
        const c = t.input.source.command;
        t.answer = .{ .accepted = reply == .accepted };
        if (reply == .rejected) try t.answer.code.set(@tagName(reply.rejected.code));
        try command.queueCommand(r, c.key.slice(), .action_stop, c.session.slice(), &t.digest, null, null, &t.answer);
        const text = try std.fmt.bufPrint(&t.input.scratch.action_text, "{d}", .{c.action_id});
        r.write(save_request, .{ .key = c.key.slice(), .action = text, .resolution = if (reply == .accepted) reply.accepted.resolution else null });
        t.result = .{ .command = reply };
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    pub fn committed(t: *const Stop) Result {
        return t.result;
    }
};
