const std = @import("std");
const control = @import("../../action_control.zig");
const command_input = @import("../../command_input.zig");
const action_receipt = @import("../../action_receipt.zig");
const session_id = @import("../../session_id.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const rsql = @import("../rsql.zig");
const transition = @import("../transition.zig");
const store_core = @import("../Store.zig");
const command_domain = @import("command.zig");
const action_domain = @import("action.zig");
const content_domain = @import("content.zig");
const turn_domain = @import("turn.zig");

const target = rsql.Read(.{
    .sql = "SELECT session_ref,workspace_key,next_position FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { session: rsql.SessionHead },
    .cardinality = .optional,
});
const facts = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position,action.parent_operation_id,operation.turn_id," ++
        "action.background_position,action.acceptance_position," ++
        action_domain.actionStopPositionSql("action", "operation") ++ " AS stop_position " ++
        "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id JOIN session s ON s.session_ref=action.session_ref WHERE action.action_id=?1",
    .Args = struct { action_id: u64 },
    .Row = struct {
        session: rsql.SessionHead,
        parent_operation_id: rsql.Positive,
        turn_id: rsql.Positive,
        background_position: ?rsql.Positive,
        acceptance_position: ?rsql.Positive,
        stop_position: ?rsql.Positive,

        fn selected(row: @This()) control.Facts {
            return .{
                .background = if (row.background_position) |position| position.get() else null,
                .final = if (row.acceptance_position) |position| position.get() else null,
                .stopped = if (row.stop_position) |position| position.get() else null,
            };
        }
    },
    .cardinality = .optional,
});
const save_selection = rsql.Write(.{
    .sql = "INSERT INTO action_control_command(command_key,action_id,selected_action_id,selection,selection_position) VALUES(?1,?2,?3,?4,?5)",
    .Args = struct { key: []const u8, action_id: []const u8, selected_action_id: ?u64, selection: ?@FieldType(control.Selection, "kind"), position: ?u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});
const accept_background = rsql.Write(.{
    .sql = "UPDATE action_operation SET background_content_id=?3,background_position=?4,background_at=@now WHERE action_id=?1 AND session_ref=@session(?2) AND background_position IS NULL AND resolution_code IS NULL",
    .Args = struct { action_id: u64, session: rsql.SessionHead, content_id: u64, position: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.ActionSelectionChanged } },
});
const saved_selection = rsql.Read(.{
    .sql = "SELECT action_id,selected_action_id,selection,selection_position FROM action_control_command WHERE command_key=?1",
    .Args = struct { key: []const u8 },
    .Row = struct { action_id: Bounded(20), selected_action_id: ?rsql.Positive, selection: ?@FieldType(control.Selection, "kind"), selection_position: ?rsql.Positive },
    .cardinality = .one,
});

pub const Observation = control.Observation;

fn observation(row: saved_selection.Row) error{CorruptStore}!Observation {
    const action_id = std.fmt.parseInt(u64, row.action_id.slice(), 10) catch return error.CorruptStore;
    const selected = if (row.selected_action_id) |selected| selection: {
        if (selected.get() != action_id) return error.CorruptStore;
        break :selection control.Selection{ .kind = row.selection orelse return error.CorruptStore, .position = (row.selection_position orelse return error.CorruptStore).get() };
    } else null;
    if (selected == null and (row.selection != null or row.selection_position != null)) return error.CorruptStore;
    return .{ .action_id = action_id, .selection = selected };
}

pub fn readSaved(a: anytype, key: []const u8) !Observation {
    var row: saved_selection.Row = undefined;
    a.read(saved_selection, .{ .key = key }, &row);
    try a.run();
    return observation(row);
}

pub const Control = struct {
    pub const rounds = transition.rounds(.{ .facts = .{.always}, .replay = .{.branch} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    pub const Scratch = struct { receipt: action_receipt.Bytes };
    pub const Input = struct { command: *const command_input.ActionBackgroundCommand, scratch: *Scratch };
    pub const Result = control.Reply;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{ActionSelectionChanged};
    pub const Declined = error{};

    input: Input,
    digest: [32]u8 = undefined,
    saved: command_domain.saved_command.Result = undefined,
    receiver: target.Result = null,
    action: facts.Result = null,
    replay: saved_selection.Result = undefined,
    content: content_domain.Import = undefined,
    text: []const u8 = &.{},
    action_text: [20]u8 = undefined,
    answer: command_domain.StoredAnswer = undefined,
    reply: Result = undefined,

    pub fn step(t: *Control, r: *transition.Round(Control), ran: ?rounds.At) !transition.Next(Control) {
        const request = t.input.command;
        const at = ran orelse {
            t.digest = request.semanticDigest();
            command_domain.lookupCommand(r, request.key.slice(), &t.saved);
            if (session_id.valid(request.session.slice())) r.read(target, .{ .session = request.session.slice() }, &t.receiver);
            if (validId(request.action_id)) {
                r.read(facts, .{ .action_id = request.action_id }, &t.action);
                t.text = action_receipt.format(request.action_id, &t.input.scratch.receipt);
                t.content = .ofBytes(t.text, false);
                content_domain.lookup(r, &t.content);
            }
            return .{ .round = .facts };
        };
        if (at == .replay) {
            const old = try observation(t.replay);
            return .{ .done = .{ .accepted = .{ .replayed = true, .action_id = old.action_id, .selection = old.selection orelse return error.CorruptStore } } };
        }
        switch (try command_domain.classify(control.Rejection, &t.saved, .action_background, request.session.slice(), &t.digest)) {
            .fresh => {},
            .conflict => return .{ .done = .conflict },
            .accepted => {
                r.read(saved_selection, .{ .key = request.key.slice() }, &t.replay);
                return .{ .round = .replay };
            },
            .rejected => |code| return .{ .done = .{ .rejected = .{ .replayed = true, .code = code } } },
        }
        const rejection: ?control.Rejection = if (!session_id.valid(request.session.slice())) .invalid_session_reference else if (!validId(request.action_id)) .invalid_target else if (t.receiver == null) .unknown_session else if (t.action == null) .unknown_action else if (!std.mem.eql(u8, &t.action.?.session.ref, request.session.slice())) .target_mismatch else null;
        if (rejection) |code| return t.refuse(r, code);
        const found = t.action.?;
        const choice = control.choose(found.selected());
        if (choice == .refused) return t.refuse(r, choice.refused);
        t.answer = .{ .accepted = true };
        try command_domain.queueCommand(r, request.key.slice(), .action_background, request.session.slice(), &t.digest, null, null, &t.answer);
        const selection: control.Selection = switch (choice) {
            .selected => |selected| selected,
            .background => selected: {
                if (r.faults().content_import) return error.InjectedContentImportFailure;
                const content_id = try content_domain.importBytes(r, &t.content, t.text);
                const position = try (try r.positions(found.session)).take(1);
                r.write(accept_background, .{ .action_id = request.action_id, .session = found.session, .content_id = content_id, .position = position });
                turn_domain.queueContinuation(r, found.turn_id.get(), found.session);
                break :selected .{ .kind = .background, .position = position };
            },
            .refused => unreachable,
        };
        t.save(r, selection);
        t.reply = .{ .accepted = .{ .replayed = false, .action_id = request.action_id, .selection = selection } };
        return t.finish(r);
    }

    fn save(t: *Control, r: *transition.Round(Control), selection: ?control.Selection) void {
        const request = t.input.command;
        const action_id = std.fmt.bufPrint(&t.action_text, "{d}", .{request.action_id}) catch unreachable;
        r.write(save_selection, .{ .key = request.key.slice(), .action_id = action_id, .selected_action_id = if (selection != null) request.action_id else null, .selection = if (selection) |selected| selected.kind else null, .position = if (selection) |selected| selected.position else null });
    }

    fn refuse(t: *Control, r: *transition.Round(Control), code: control.Rejection) !transition.Next(Control) {
        const request = t.input.command;
        t.answer = .{ .accepted = false };
        try t.answer.code.set(@tagName(code));
        try command_domain.queueCommand(r, request.key.slice(), .action_background, request.session.slice(), &t.digest, null, null, &t.answer);
        t.save(r, null);
        t.reply = .{ .rejected = .{ .replayed = false, .code = code } };
        return t.finish(r);
    }

    fn finish(_: *Control, r: *transition.Round(Control)) !transition.Next(Control) {
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    pub fn committed(t: *const Control) Result {
        return t.reply;
    }
};

fn validId(id: u64) bool {
    return id > 0 and id <= std.math.maxInt(i64);
}
