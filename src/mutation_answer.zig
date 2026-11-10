//! What a durable mutation's reply establishes: its answer, bound to the
//! request that produced it, or why the reply confirms nothing. Decisions over
//! a parsed reply; protocol_reply.zig bounds and parses the bytes.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const CommandKind = @import("cli_value.zig").CommandKind;
const session_id = @import("session_id.zig");
const wire_field = @import("wire_field.zig");
const JsonString = wire_field.JsonString;
const JsonEnum = wire_field.JsonEnum;
const OmittableJson = wire_field.OmittableJson;
const decimalId = wire_field.decimalId;

// The protocol's sizes; protocol_reply.zig asserts they match.
pub const max_code_bytes = 96;
pub const max_session_bytes = 128;

pub const PermissionDecision = enum { allow_once, deny };
pub const SkillsReloadStatus = enum { reloaded, unchanged };
pub const SessionStopCompletion = enum { pending, completed };
pub const SessionArchiveObservation = struct { archived: bool, completion: SessionStopCompletion };

// Why the Host refuses each mutation. The Store saves the code and the Host
// renders its tag name.
pub const SessionStopRejection = enum { invalid_session_reference, unknown_session };
pub const SessionArchiveRejection = enum { invalid_session_reference, unknown_session, archive_pending };
pub const ModelInterruptionRejection = enum {
    invalid_session_reference,
    invalid_target,
    unknown_session,
    unknown_operation,
    target_mismatch,
    operation_resolved,
};
pub const PermissionDecisionRejection = enum {
    invalid_session_reference,
    invalid_target,
    unknown_session,
    unknown_action,
    target_mismatch,
    action_not_pending,
};
pub const ContentReference = struct { bytes: u64, digest: [32]u8 };

/// The durable mutations. Tag names are the captured-record and
/// observation spelling; `rui request recover --kind` uses the hyphenated spelling.
pub const Target = union(CommandKind) {
    configure,
    message: struct { bytes: u64, digest: [32]u8, creates_session: bool = false },
    session_stop,
    session_archive: struct { archived: bool },
    model_interruption: struct { turn: u64, operation: u64 },
    permission_decision: struct { action: u64, decision: PermissionDecision },
};

pub const Answer = struct {
    /// Validated Host-owned input identity, including captured native skills.
    input: ?ContentReference = null,
    result: union(enum) {
        accepted: union(enum) {
            configure: struct { revision: u64, created: bool, skills: ?SkillsReloadStatus = null },
            message: struct { admission: u64 },
            session_stop: struct { turn: ?u64, admission_cutoff: u64, completion: SessionStopCompletion },
            session_archive: SessionArchiveObservation,
            model_interruption,
            permission_decision,
        },
        rejected: Bounded(max_code_bytes),
        conflict,
    },
    replayed: bool,
};

pub const InvocationDiagnostic = struct {
    type: Bounded(32),
    code: Bounded(max_code_bytes),
};

/// An answer error is unconfirmed, never rejection or noncommit.
pub const Error = error{ CanonicalStoreFailure, HostInvocationFailed, InvalidResponse, RequestBindingMismatch };

/// A mutation reply's fields, as the decoder parses them.
pub const Wire = struct {
    version: JsonString(8),
    type: JsonString(32),
    code: OmittableJson(JsonString(max_code_bytes)) = .{},
    answer: OmittableJson(struct {
        status: JsonString(16),
        replayed: bool,
        session: OmittableJson(JsonString(max_session_bytes)) = .{},
        code: OmittableJson(JsonString(max_code_bytes)) = .{},
        revision: OmittableJson(JsonString(20)) = .{},
        created: OmittableJson(bool) = .{},
        skills: OmittableJson(JsonEnum(SkillsReloadStatus)) = .{},
        admission: OmittableJson(JsonString(20)) = .{},
        action: OmittableJson(JsonString(20)) = .{},
        decision: OmittableJson(JsonString(16)) = .{},
        archived: OmittableJson(bool) = .{},
        selection: OmittableJson(struct { turn: ?JsonString(20), admission_cutoff: JsonString(20) }) = .{},
        target: OmittableJson(struct { session: JsonString(max_session_bytes), turn: JsonString(20), operation: JsonString(20) }) = .{},
    }) = .{},
    input: OmittableJson(struct { type: JsonString(8), bytes: JsonString(20), sha256: JsonString(64) }) = .{},
    queue: OmittableJson(struct { status: JsonString(16), admission: JsonString(20) }) = .{},
    execution: OmittableJson(struct { status: JsonString(16), reason: OmittableJson(JsonString(64)) = .{} }) = .{},
    completion: OmittableJson(struct { status: JsonString(16) }) = .{},
};

/// The answer `wire` gives to `target` on `session` with HTTP `status`, when
/// the Host speaks `current_version` of the wire. A
/// diagnostic reply sets `diagnostic`; an accepted creation sets
/// `resolved_session` to the Session the Host created. No workflow,
/// terminal, retry or certainty transition is made here.
pub fn decide(current_version: []const u8, wire: Wire, status: u16, session: []const u8, target: Target, diagnostic: *?InvocationDiagnostic, resolved_session: *Bounded(max_session_bytes)) Error!Answer {
    if (wire.code.value) |code| {
        if (wire.answer.value != null or wire.input.value != null or wire.queue.value != null or wire.execution.value != null or wire.completion.value != null) return error.InvalidResponse;
        const parsed = InvocationDiagnostic{ .type = wire.type.value, .code = code.value };
        try validateInvocationDiagnostic(current_version, status, wire.version.slice(), parsed);
        diagnostic.* = parsed;
        if (parsed.code.eql("canonical_store_failure")) return error.CanonicalStoreFailure;
        return error.HostInvocationFailed;
    }
    if (status != 200 and status != 409) return error.InvalidResponse;
    const expected_type = switch (target) {
        .configure => "configuration_reply",
        .message => "message_reply",
        .session_stop => "session_stop_reply",
        .session_archive => "session_archive_reply",
        .model_interruption => "model_interruption_reply",
        .permission_decision => "permission_decision_reply",
    };
    if (!wire.version.eql(current_version) or !wire.type.eql(expected_type) or wire.code.value != null) return error.InvalidResponse;
    const answer = wire.answer.value orelse return error.InvalidResponse;
    if (target == .model_interruption) {
        const echoed = answer.target.value orelse return error.InvalidResponse;
        if (answer.session.value != null or !echoed.session.eql(session) or try decimalId(echoed.turn, true) != target.model_interruption.turn or
            try decimalId(echoed.operation, true) != target.model_interruption.operation) return error.RequestBindingMismatch;
    } else {
        const echoed = answer.session.value orelse return error.InvalidResponse;
        if (answer.target.value != null) return error.RequestBindingMismatch;
        if (target == .configure and session.len == 0 and answer.status.eql("accepted")) {
            if (!session_id.valid(echoed.slice()) or answer.created.value != true) return error.RequestBindingMismatch;
            resolved_session.* = echoed.value;
        } else if (target == .message and target.message.creates_session and session.len == 0 and answer.status.eql("accepted")) {
            if (!session_id.valid(echoed.slice())) return error.RequestBindingMismatch;
            resolved_session.* = echoed.value;
        } else if (!echoed.eql(session)) return error.RequestBindingMismatch;
    }
    if (target == .permission_decision) {
        if (try decimalId(answer.action.value orelse return error.InvalidResponse, true) != target.permission_decision.action or
            !(answer.decision.value orelse return error.InvalidResponse).eql(@tagName(target.permission_decision.decision))) return error.RequestBindingMismatch;
    } else if (answer.action.value != null or answer.decision.value != null) return error.InvalidResponse;
    const accepted = answer.status.eql("accepted");
    const conflict = answer.status.eql("conflict");
    if ((!accepted and !conflict and !answer.status.eql("rejected")) or (status == 409) != conflict) return error.InvalidResponse;
    if (answer.skills.value != null and (!accepted or target != .configure or answer.created.value != false)) return error.InvalidResponse;
    if (accepted) {
        if (!session_id.valid(resolved_session.slice())) return error.InvalidResponse;
        if (answer.code.value != null) return error.InvalidResponse;
    } else {
        const code = answer.code.value orelse return error.InvalidResponse;
        if (code.slice().len == 0 or answer.revision.value != null or answer.created.value != null or answer.admission.value != null or answer.selection.value != null or answer.archived.value != null) return error.InvalidResponse;
        if (conflict and (!code.eql("idempotency_key_conflict") or answer.replayed)) return error.InvalidResponse;
    }
    var value: @FieldType(@FieldType(Answer, "result"), "accepted") = undefined;
    var confirmed_input: ?ContentReference = null;
    switch (target) {
        .configure => {
            const execution = wire.execution.value orelse return error.InvalidResponse;
            if (!execution.status.eql("unavailable") or !(execution.reason.value orelse return error.InvalidResponse).eql("direct_reply_does_not_wait_for_model_processing")) return error.InvalidResponse;
            if (accepted) value = .{ .configure = .{ .revision = try decimalId(answer.revision.value orelse return error.InvalidResponse, false), .created = answer.created.value orelse return error.InvalidResponse, .skills = if (answer.skills.value) |skills_value| skills_value.value else null } };
        },
        .message => |expected| {
            if (!(wire.execution.value orelse return error.InvalidResponse).status.eql("queued")) return error.InvalidResponse;
            if (conflict) {
                if (wire.input.value != null or wire.queue.value != null) return error.InvalidResponse;
            } else {
                const input = wire.input.value orelse return error.InvalidResponse;
                var digest: [32]u8 = undefined;
                if (!input.type.eql("text") or input.sha256.slice().len != 64) return error.InvalidResponse;
                _ = std.fmt.hexToBytes(&digest, input.sha256.slice()) catch return error.InvalidResponse;
                const input_bytes = try decimalId(input.bytes, true);
                confirmed_input = .{ .bytes = input_bytes, .digest = digest };
                if (input_bytes != expected.bytes or !std.mem.eql(u8, &digest, &expected.digest)) return error.RequestBindingMismatch;
                if (accepted) {
                    const admission = try decimalId(answer.admission.value orelse return error.InvalidResponse, false);
                    const queue = wire.queue.value orelse return error.InvalidResponse;
                    if (!queue.status.eql("queued") or try decimalId(queue.admission, false) != admission) return error.InvalidResponse;
                    value = .{ .message = .{ .admission = admission } };
                } else if (wire.queue.value != null) return error.InvalidResponse;
            }
        },
        .session_stop => {
            const completion = wire.completion.value orelse return error.InvalidResponse;
            if (accepted) {
                const selection = answer.selection.value orelse return error.InvalidResponse;
                value = .{ .session_stop = .{
                    .turn = if (selection.turn) |turn| try decimalId(turn, false) else null,
                    .admission_cutoff = try decimalId(selection.admission_cutoff, true),
                    .completion = std.meta.stringToEnum(@FieldType(@FieldType(@TypeOf(value), "session_stop"), "completion"), completion.status.slice()) orelse return error.InvalidResponse,
                } };
            } else if (!completion.status.eql("unavailable")) return error.InvalidResponse;
        },
        .session_archive => |expected| {
            const completion = wire.completion.value orelse return error.InvalidResponse;
            if (accepted) {
                const archived = answer.archived.value orelse return error.InvalidResponse;
                if (archived != expected.archived) return error.RequestBindingMismatch;
                value = .{ .session_archive = .{
                    .archived = archived,
                    .completion = std.meta.stringToEnum(SessionStopCompletion, completion.status.slice()) orelse return error.InvalidResponse,
                } };
            } else if (!completion.status.eql("unavailable")) return error.InvalidResponse;
        },
        .model_interruption => if (accepted) {
            value = .model_interruption;
        },
        .permission_decision => if (accepted) {
            value = .permission_decision;
        },
    }
    if ((target != .configure and (answer.revision.value != null or answer.created.value != null)) or
        (target != .message and (answer.admission.value != null or wire.input.value != null or wire.queue.value != null)) or
        (target != .configure and target != .message and wire.execution.value != null) or
        (target != .session_stop and answer.selection.value != null) or
        (target != .session_archive and answer.archived.value != null) or
        (target != .session_stop and target != .session_archive and wire.completion.value != null)) return error.InvalidResponse;
    return .{
        .input = confirmed_input,
        .replayed = answer.replayed,
        .result = if (accepted) .{ .accepted = value } else if (conflict) .conflict else .{ .rejected = answer.code.value.?.value },
    };
}

// Shared authority rule for operation replies and static read/error envelopes.
/// `version` is the reply's; `current_version` is the protocol's.
pub fn validateInvocationDiagnostic(current_version: []const u8, status: u16, version: []const u8, diagnostic: InvocationDiagnostic) error{InvalidResponse}!void {
    if (status == 200 or !std.mem.eql(u8, version, current_version) or diagnostic.type.len == 0 or diagnostic.code.len == 0) return error.InvalidResponse;
    if (diagnostic.code.eql("canonical_store_failure") and (status != 500 or !diagnostic.type.eql("invocation_error"))) return error.InvalidResponse;
}

/// Any version: the decisions compare against the one they are given. The
/// protocol's own lives in protocol.zig alone.
const current = "7";
const stale = "6";

const Decoded = struct { answer: Error!Answer, diagnostic: ?InvocationDiagnostic = null, session: Bounded(max_session_bytes) = .{} };

/// Parses `body` as protocol_reply.zig's decoder does, without its byte bound.
fn decodeForTest(status: u16, body: []const u8, session: []const u8, target: Target) Decoded {
    var storage: [16 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var result: Decoded = .{ .answer = error.InvalidResponse };
    result.session.set(session) catch unreachable;
    const wire = std.json.parseFromSliceLeaky(Wire, fixed.allocator(), body, .{ .ignore_unknown_fields = true }) catch return result;
    var resolved = result.session;
    result.answer = decide(current, wire, status, session, target, &result.diagnostic, &resolved);
    if (result.answer) |_| result.session = resolved else |_| {}
    return result;
}

test "a mutation answer binds its request and its queue" {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("a\nµ", &digest, .{});
    const target: Target = .{ .message = .{ .bytes = 4, .digest = digest } };
    const prefix = "{\"version\":\"" ++ current ++ "\",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2q\\u0078\",\"admission\":\"7\"}";
    var suffix_storage: [256]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&suffix_storage, ",\"input\":{{\"type\":\"text\",\"bytes\":\"4\",\"sha256\":\"{s}\"}},\"queue\":{{\"status\":\"queued\",\"admission\":\"7\"}},\"execution\":{{\"status\":\"queued\"}}}}", .{std.fmt.bytesToHex(digest, .lower)});
    var body: [1024]u8 = undefined;
    const valid = try std.fmt.bufPrint(&body, "{s}{s}", .{ prefix, suffix });
    try std.testing.expectEqual(@as(u64, 7), (try decodeForTest(200, valid, "k7m2qx", target).answer).result.accepted.message.admission);
    try std.testing.expectError(error.RequestBindingMismatch, decodeForTest(200, valid, "09azvw", target).answer);
    var changed = target;
    changed.message.bytes = 5;
    try std.testing.expectError(error.RequestBindingMismatch, decodeForTest(200, valid, "k7m2qx", changed).answer);
    changed = target;
    changed.message.digest[3] ^= 1;
    try std.testing.expectError(error.RequestBindingMismatch, decodeForTest(200, valid, "k7m2qx", changed).answer);
    try std.testing.expectError(error.InvalidResponse, decodeForTest(409, valid, "k7m2qx", target).answer);
    for ([_][]const u8{
        "{\"version\":" ++ current ++ ",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"admission\":\"7\"}",
        "{\"version\":\"" ++ current ++ "\",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"sta\\u0074us\":\"rejected\",\"replayed\":false,\"session\":\"k7m2qx\",\"admission\":\"7\"}",
        "{\"version\":\"" ++ current ++ "\",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"admission\":\"07\"}",
        "{\"version\":\"" ++ current ++ "\",\"type\":\"message_reply\",\"answer\":{\"status\":\"rejected\",\"replayed\":false,\"session\":\"k7m2qx\",\"code\":\"unknown_session\"}",
    }) |invalid_prefix| {
        const invalid = try std.fmt.bufPrint(&body, "{s}{s}", .{ invalid_prefix, suffix });
        try std.testing.expectError(error.InvalidResponse, decodeForTest(200, invalid, "k7m2qx", target).answer);
    }
    const conflicting_queue = try std.fmt.bufPrint(&body, "{s},\"input\":{{\"type\":\"text\",\"bytes\":\"4\",\"sha256\":\"{s}\"}},\"queue\":{{\"status\":\"queued\",\"admission\":\"8\"}},\"execution\":{{\"status\":\"queued\"}}}}", .{ prefix, std.fmt.bytesToHex(digest, .lower) });
    try std.testing.expectError(error.InvalidResponse, decodeForTest(200, conflicting_queue, "k7m2qx", target).answer);
}

test "skills reload reply facts apply only to accepted existing Configure mutations" {
    const input = ",\"input\":{\"type\":\"text\",\"bytes\":\"0\",\"sha256\":\"" ++ @as([64]u8, @splat('0')) ++ "\"}";
    const cases = [_]struct {
        target: Target,
        reply_type: []const u8,
        binding: []const u8 = ",\"session\":\"k7m2qx\"",
        accepted_fields: []const u8 = "",
        accepted_tail: []const u8 = "",
        rejected_tail: []const u8 = "",
        conflict_tail: []const u8 = "",
    }{
        .{
            .target = .configure,
            .reply_type = "configuration_reply",
            .accepted_fields = ",\"revision\":\"31\",\"created\":false",
            .accepted_tail = ",\"execution\":{\"status\":\"unavailable\",\"reason\":\"direct_reply_does_not_wait_for_model_processing\"}",
            .rejected_tail = ",\"execution\":{\"status\":\"unavailable\",\"reason\":\"direct_reply_does_not_wait_for_model_processing\"}",
            .conflict_tail = ",\"execution\":{\"status\":\"unavailable\",\"reason\":\"direct_reply_does_not_wait_for_model_processing\"}",
        },
        .{
            .target = .{ .message = .{ .bytes = 0, .digest = @splat(0) } },
            .reply_type = "message_reply",
            .accepted_fields = ",\"admission\":\"7\"",
            .accepted_tail = input ++ ",\"queue\":{\"status\":\"queued\",\"admission\":\"7\"},\"execution\":{\"status\":\"queued\"}",
            .rejected_tail = input ++ ",\"execution\":{\"status\":\"queued\"}",
            .conflict_tail = ",\"execution\":{\"status\":\"queued\"}",
        },
        .{
            .target = .session_stop,
            .reply_type = "session_stop_reply",
            .accepted_fields = ",\"selection\":{\"turn\":null,\"admission_cutoff\":\"0\"}",
            .accepted_tail = ",\"completion\":{\"status\":\"completed\"}",
            .rejected_tail = ",\"completion\":{\"status\":\"unavailable\"}",
            .conflict_tail = ",\"completion\":{\"status\":\"unavailable\"}",
        },
        .{
            .target = .{ .session_archive = .{ .archived = true } },
            .reply_type = "session_archive_reply",
            .accepted_fields = ",\"archived\":true",
            .accepted_tail = ",\"completion\":{\"status\":\"completed\"}",
            .rejected_tail = ",\"completion\":{\"status\":\"unavailable\"}",
            .conflict_tail = ",\"completion\":{\"status\":\"unavailable\"}",
        },
        .{
            .target = .{ .model_interruption = .{ .turn = 3, .operation = 4 } },
            .reply_type = "model_interruption_reply",
            .binding = ",\"target\":{\"session\":\"k7m2qx\",\"turn\":\"3\",\"operation\":\"4\"}",
        },
        .{
            .target = .{ .permission_decision = .{ .action = 9, .decision = .deny } },
            .reply_type = "permission_decision_reply",
            .binding = ",\"session\":\"k7m2qx\",\"action\":\"9\",\"decision\":\"deny\"",
        },
    };
    const reload_fields = [_]struct { bytes: []const u8, expected: ?SkillsReloadStatus }{
        .{ .bytes = "", .expected = null },
        .{ .bytes = ",\"skills\":\"reloaded\"", .expected = .reloaded },
        .{ .bytes = ",\"skills\":\"unchanged\"", .expected = .unchanged },
    };
    var buffer: [1024]u8 = undefined;
    for (cases) |case| {
        for ([_][]const u8{ "accepted", "rejected", "conflict" }) |status| {
            const accepted = std.mem.eql(u8, status, "accepted");
            const conflict = std.mem.eql(u8, status, "conflict");
            const fields = if (accepted) case.accepted_fields else if (conflict) ",\"code\":\"idempotency_key_conflict\"" else ",\"code\":\"unknown_session\"";
            const tail = if (accepted) case.accepted_tail else if (conflict) case.conflict_tail else case.rejected_tail;
            for (reload_fields) |reload| {
                const body = try std.fmt.bufPrint(&buffer, "{{\"version\":\"{s}\",\"type\":\"{s}\",\"answer\":{{\"status\":\"{s}\",\"replayed\":false{s}{s}{s}}}{s}}}", .{ current, case.reply_type, status, case.binding, fields, reload.bytes, tail });
                const reply = decodeForTest(if (conflict) 409 else 200, body, "k7m2qx", case.target);
                if (reload.expected != null and (!accepted or case.target != .configure)) {
                    try std.testing.expectError(error.InvalidResponse, reply.answer);
                } else {
                    const answer = try reply.answer;
                    try std.testing.expect(!answer.replayed);
                    try std.testing.expectEqualStrings(status, @tagName(answer.result));
                    if (accepted) {
                        try std.testing.expectEqualStrings(@tagName(case.target), @tagName(answer.result.accepted));
                        if (case.target == .configure) {
                            try std.testing.expectEqual(@as(u64, 31), answer.result.accepted.configure.revision);
                            try std.testing.expect(!answer.result.accepted.configure.created);
                            try std.testing.expectEqual(reload.expected, answer.result.accepted.configure.skills);
                        }
                    } else if (!conflict) try std.testing.expectEqualStrings("unknown_session", answer.result.rejected.slice());
                }
            }
        }
    }
    // Ordinary creation remains valid; a reload cannot also create a Session.
    for ([_][]const u8{ "false", "true" }) |created| {
        for (reload_fields) |reload| {
            const body = try std.fmt.bufPrint(&buffer, "{{\"version\":\"{s}\",\"type\":\"configuration_reply\",\"answer\":{{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"revision\":\"31\",\"created\":{s}{s}}}{s}}}", .{ current, created, reload.bytes, cases[0].accepted_tail });
            const creating = std.mem.eql(u8, created, "true");
            const reply = decodeForTest(200, body, if (creating) "" else "k7m2qx", .configure);
            if (creating and reload.expected != null) {
                try std.testing.expectError(error.InvalidResponse, reply.answer);
            } else {
                const answer = try reply.answer;
                try std.testing.expectEqual(creating, answer.result.accepted.configure.created);
                try std.testing.expectEqual(reload.expected, answer.result.accepted.configure.skills);
                try std.testing.expectEqualStrings("k7m2qx", reply.session.slice());
            }
        }
    }
    for ([_][]const u8{ "null", "7", "true", "\"invented\"", "[]", "\"reloaded\",\"skills\":\"unchanged\"" }) |invalid| {
        const body = try std.fmt.bufPrint(&buffer, "{{\"version\":\"{s}\",\"type\":\"configuration_reply\",\"answer\":{{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"revision\":\"31\",\"created\":false,\"skills\":{s}}}{s}}}", .{ current, invalid, cases[0].accepted_tail });
        try std.testing.expectError(error.InvalidResponse, decodeForTest(200, body, "k7m2qx", .configure).answer);
    }
}

test "mutation decoder preserves invalid-target domain rejection not false fatal certainty" {
    const body = "{\"version\":\"" ++ current ++ "\",\"type\":\"model_interruption_reply\",\"answer\":{\"status\":\"rejected\",\"replayed\":true,\"target\":{\"session\":\"s\",\"turn\":\"0\",\"operation\":\"18446744073709551615\"},\"code\":\"invalid_target\"}}";
    const target: Target = .{ .model_interruption = .{ .turn = 0, .operation = std.math.maxInt(u64) } };
    const answer = try decodeForTest(200, body, "s", target).answer;
    try std.testing.expectEqualStrings("invalid_target", answer.result.rejected.slice());
    try std.testing.expect(answer.replayed);
    for ([_][]const u8{
        "{\"version\":\"" ++ current ++ "\",\"type\":\"invocation_error\",\"code\":\"unavailable\"}",
        "{\"version\":\"" ++ current ++ "\",\"type\":\"message_reply\",\"answer\":{\"status\":\"infrastructure_failure\",\"code\":\"canonical_store_failure\"}}",
    }) |unknown| {
        const reply = decodeForTest(500, unknown, "s", target);
        try std.testing.expectError(if (std.mem.indexOf(u8, unknown, "unavailable") != null) error.HostInvocationFailed else error.InvalidResponse, reply.answer);
        if (std.mem.indexOf(u8, unknown, "unavailable") != null)
            try std.testing.expectEqualStrings("unavailable", reply.diagnostic.?.code.slice());
    }
}

test "session archive mutation reply binds intent and completion on accepted replies" {
    const head = "{\"version\":\"" ++ current ++ "\",\"type\":\"session_archive_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\"";
    const accepted = head ++ ",\"archived\":false},\"completion\":{\"status\":\"completed\"}}";
    const target: Target = .{ .session_archive = .{ .archived = false } };
    const answer = try decodeForTest(200, accepted, "k7m2qx", target).answer;
    try std.testing.expect(!answer.result.accepted.session_archive.archived);
    try std.testing.expectEqual(.completed, answer.result.accepted.session_archive.completion);
    try std.testing.expectError(error.RequestBindingMismatch, decodeForTest(200, accepted, "k7m2qx", .{ .session_archive = .{ .archived = true } }).answer);
    inline for (.{
        head ++ "},\"completion\":{\"status\":\"completed\"}}",
        head ++ ",\"archived\":null},\"completion\":{\"status\":\"completed\"}}",
        head ++ ",\"archived\":false},\"completion\":{\"status\":\"unavailable\"}}",
        head ++ ",\"archived\":false}}",
        head ++ ",\"archived\":false,\"selection\":{\"turn\":null,\"admission_cutoff\":\"0\"}},\"completion\":{\"status\":\"completed\"}}",
        head ++ ",\"archived\":false},\"completion\":{\"status\":\"completed\"},\"execution\":{\"status\":\"queued\"}}",
    }) |invalid| try std.testing.expectError(error.InvalidResponse, decodeForTest(200, invalid, "k7m2qx", target).answer);
    const rejected = "{\"version\":\"" ++ current ++ "\",\"type\":\"session_archive_reply\",\"answer\":{\"status\":\"rejected\",\"replayed\":true,\"session\":\"k7m2qx\",\"code\":\"archive_pending\"},\"completion\":{\"status\":\"unavailable\"}}";
    const refusal = try decodeForTest(200, rejected, "k7m2qx", target).answer;
    try std.testing.expect(refusal.replayed);
    try std.testing.expectEqualStrings("archive_pending", refusal.result.rejected.slice());
}

test "a diagnostic reply confirms nothing, and only an authoritative one names a Store failure" {
    for ([_][]const u8{
        "{\"version\":\"" ++ current ++ "\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"" ++ current ++ "\",\"type\":\"busy\",\"code\":\"capacity_exhausted\"}",
    }, [_]u16{ 500, 503 }) |valid, status| {
        const value = decodeForTest(status, valid, "s", .configure);
        try std.testing.expectError(if (status == 500) error.CanonicalStoreFailure else error.HostInvocationFailed, value.answer);
        try std.testing.expect(value.diagnostic != null);
    }
    const prefix = "{\"version\":\"" ++ current ++ "\",\"type\":\"invocation_error\",\"code\":\"busy\"";
    for ([_][]const u8{
        prefix ++ ",\"co\\u0064e\":\"other\"}",
        prefix ++ ",\"extra\":[}",
        prefix ++ "} trailing",
        prefix ++ ",\"answer\":{\"status\":\"accepted\",\"replayed\":false}}",
        "{\"version\":\"" ++ current ++ "\",\"type\":\"busy\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"" ++ current ++ "\",\"type\":\"invocation_error\",\"code\":[98]}",
    }) |invalid| {
        const value = decodeForTest(500, invalid, "s", .configure);
        try std.testing.expectError(error.InvalidResponse, value.answer);
        try std.testing.expect(value.diagnostic == null);
    }
    // A diagnostic needs the current version, and only an invocation
    // error with status 500 claims a canonical Store failure.
    for ([_][]const u8{
        "{\"version\":\"" ++ stale ++ "\",\"type\":\"invocation_error\",\"code\":\"busy\"}",
        "{\"version\":\"" ++ current ++ "\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
    }, [_]u16{ 503, 503 }) |invalid, status| {
        const value = decodeForTest(status, invalid, "s", .configure);
        try std.testing.expectError(error.InvalidResponse, value.answer);
        try std.testing.expect(value.diagnostic == null);
    }
}

test "a reply carrying another mutation's fields, or the wrong version, confirms nothing" {
    const archive = "{\"version\":\"" ++ current ++ "\",\"type\":\"session_archive_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"archived\":true}";
    const target: Target = .{ .session_archive = .{ .archived = true } };
    _ = try decodeForTest(200, archive ++ ",\"completion\":{\"status\":\"completed\"}}", "k7m2qx", target).answer;
    const stop = "{\"version\":\"" ++ current ++ "\",\"type\":\"session_stop_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"selection\":{\"turn\":null,\"admission_cutoff\":\"0\"}";
    _ = try decodeForTest(200, stop ++ "},\"completion\":{\"status\":\"pending\"}}", "k7m2qx", .session_stop).answer;
    for ([_][]const u8{
        stop ++ ",\"archived\":true},\"completion\":{\"status\":\"pending\"}}",
        "{\"version\":\"" ++ stale ++ archive["{\"version\":\"".len + current.len ..] ++ ",\"completion\":{\"status\":\"completed\"}}",
    }, [_]Target{ .session_stop, target }) |invalid, expected|
        try std.testing.expectError(error.InvalidResponse, decodeForTest(200, invalid, "k7m2qx", expected).answer);
    // An interruption binds the Turn and operation it names.
    const interruption: Target = .{ .model_interruption = .{ .turn = 3, .operation = 4 } };
    for ([_][]const u8{ "\"3\",\"operation\":\"4\"", "\"3\",\"operation\":\"5\"", "\"2\",\"operation\":\"4\"" }, 0..) |echoed, index| {
        var buffer: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&buffer, "{{\"version\":\"{s}\",\"type\":\"model_interruption_reply\",\"answer\":{{\"status\":\"accepted\",\"replayed\":false,\"target\":{{\"session\":\"k7m2qx\",\"turn\":{s}}}}}}}", .{ current, echoed });
        const answer = decodeForTest(200, body, "k7m2qx", interruption).answer;
        if (index == 0) _ = try answer else try std.testing.expectError(error.RequestBindingMismatch, answer);
    }
    // A conflict is never a replay.
    const conflict = "{\"version\":\"" ++ current ++ "\",\"type\":\"session_stop_reply\",\"answer\":{\"status\":\"conflict\",\"replayed\":";
    const tail = ",\"session\":\"k7m2qx\",\"code\":\"idempotency_key_conflict\"},\"completion\":{\"status\":\"unavailable\"}}";
    try std.testing.expect((try decodeForTest(409, conflict ++ "false" ++ tail, "k7m2qx", .session_stop).answer).result == .conflict);
    try std.testing.expectError(error.InvalidResponse, decodeForTest(409, conflict ++ "true" ++ tail, "k7m2qx", .session_stop).answer);
}
