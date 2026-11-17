const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const CommandKind = @import("cli_value.zig").CommandKind;
const session_id = @import("session_id.zig");
const wire_field = @import("wire_field.zig");
const decimalId = wire_field.decimalId;

pub const max_code_bytes = 96;
pub const max_session_bytes = 128;

pub const PermissionDecision = enum { allow_once, deny };
pub const SkillsReloadStatus = enum { reloaded, unchanged };
pub const SessionStopCompletion = enum { pending, completed };
pub const SessionPinObservation = struct { pinned: bool };
pub const SessionPinRejection = enum { invalid_session_reference, unknown_session, session_archiving, session_archived };
pub const SessionArchiveObservation = struct { archived: bool, completion: SessionStopCompletion };

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

pub const Target = union(CommandKind) {
    configure,
    message: struct { bytes: u64, digest: [32]u8, creates_session: bool = false },
    session_stop,
    session_archive: struct { archived: bool },
    model_interruption: struct { turn: u64, operation: u64 },
    permission_decision: struct { action: u64, decision: PermissionDecision },
    session_pin: struct { pinned: bool },
    action_background: u64,
    action_stop: u64,
};

pub const Answer = struct {
    input: ?ContentReference = null,
    result: union(enum) {
        accepted: union(enum) {
            configure: struct { revision: u64, created: bool, skills: ?SkillsReloadStatus = null, configuration: ?@import("creation_receipt.zig").Configuration = null },
            message: struct { admission: u64, configuration: ?@import("creation_receipt.zig").Configuration = null },
            session_stop: struct { turn: ?u64, admission_cutoff: u64, completion: SessionStopCompletion },
            session_archive: SessionArchiveObservation,
            session_pin: SessionPinObservation,
            model_interruption,
            permission_decision,
            action_background: @import("action_control.zig").Selection,
            action_stop: ?u64,
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

pub const Error = error{ CanonicalStoreFailure, HostInvocationFailed, InvalidResponse, RequestBindingMismatch };

pub fn decode(comptime protocol: type, comptime command_reply: type, allocator: std.mem.Allocator, body: []const u8, status: u16, session: []const u8, target: Target, diagnostic: *?InvocationDiagnostic, resolved_session: *Bounded(max_session_bytes)) Error!Answer {
    const command_spec = @import("command_spec.zig");
    @setEvalBranchQuota(200_000);
    const universe = comptime command_spec.mutationDecoderShapes(protocol).values;
    {
        // Invocation diagnostics carry no command authority. Keep their existing
        // permissive diagnostic vocabulary; the validator owns HTTP certainty.
        const e = protocol.error_reply;
        const shape = .{ e[0], protocol.Hole{ .string = 32 }, e[2], e[3], e[4] };
        if (command_reply.Decoder(shape, universe).parse(allocator, body)) |wire| {
            const parsed: InvocationDiagnostic = .{ .type = wire.type.value, .code = wire.code.value };
            try validateInvocationDiagnostic(protocol.wire_version, status, wire.version.slice(), parsed);
            diagnostic.* = parsed;
            return if (parsed.code.eql("canonical_store_failure")) error.CanonicalStoreFailure else error.HostInvocationFailed;
        } else |_| {}
    }
    if (status != 200 and status != 409) return error.InvalidResponse;
    switch (target) {
        inline else => |_, kind| {
            const Reply = command_spec.spec(kind).Reply(protocol);
            inline for (.{ "accepted_create", "accepted", "accepted_skills", "rejected", "conflict" }) |name| {
                if (comptime !@hasDecl(Reply, name)) continue;
                const accepted = comptime std.mem.startsWith(u8, name, "accepted");
                const conflict = comptime std.mem.eql(u8, name, "conflict");
                candidate: {
                    if ((status == 409) != conflict) break :candidate;
                    const Parser = command_reply.DecoderWithPolicy(@field(Reply, name), universe, struct {
                        pub fn Type(comptime T: type) type {
                            const receipt = @import("creation_receipt_wire.zig");
                            return if (T == receipt.NamesJson) receipt.Names else T;
                        }
                    }, DecodePolicy(kind));
                    const partial = Parser.parsePartial(allocator, body) catch |err| {
                        if (err == error.RequestBindingMismatch) return error.RequestBindingMismatch;
                        break :candidate;
                    };
                    if (comptime accepted and (kind == .configure or kind == .message)) {
                        const wants_creation = if (comptime kind == .configure) session.len == 0 else target.message.creates_session;
                        if (@hasField(@TypeOf(partial.value.answer), "configuration") != wants_creation) break :candidate;
                    }
                    // A shape for another outcome must not claim the request
                    // binding; only its own status can authorize that check.
                    if (partial.has(".answer.status") and !partial.value.answer.status.eql(if (accepted) "accepted" else if (conflict) "conflict" else "rejected")) break :candidate;
                    try bind(kind, accepted, partial, session, target, resolved_session);
                    if (partial.deferred_error) |err| {
                        if (err == error.RequestBindingMismatch) return error.RequestBindingMismatch;
                        break :candidate;
                    }
                    return decide(kind, accepted, conflict, partial, target);
                }
            }
        },
    }
    return error.InvalidResponse;
}

// These compatibility rules retain the base reader's semantic boundaries:
// refusal prose is diagnostic, and Message execution may carry a reason.
fn DecodePolicy(comptime kind: CommandKind) type {
    return struct {
        pub fn ignored(comptime path: []const u8) bool {
            return std.mem.eql(u8, path, ".answer.message");
        }
        pub fn deferMissing(comptime path: []const u8) bool {
            const depth = std.mem.count(u8, path, ".");
            return depth == 1 or (depth == 2 and std.mem.startsWith(u8, path, ".answer.")) or std.mem.eql(u8, path, ".execution.reason");
        }
        pub fn Override(comptime path: []const u8) ?type {
            if (std.mem.eql(u8, path, ".answer.configuration.provider")) return wire_field.JsonEnum(@import("provider_name.zig").Provider);
            if (std.mem.eql(u8, path, ".answer.configuration.reasoning_effort")) return ?wire_field.JsonEnum(@import("model_catalog.zig").ReasoningEffort);
            if (std.mem.eql(u8, path, ".answer.configuration.permission_mode")) return wire_field.JsonEnum(@import("cli_value.zig").PermissionMode);
            if (std.mem.eql(u8, path, ".answer.skills")) return wire_field.JsonEnum(SkillsReloadStatus);
            if (std.mem.eql(u8, path, ".answer.action_selection.kind")) return wire_field.JsonEnum(@FieldType(@import("action_control.zig").Selection, "kind"));
            if (std.mem.eql(u8, path, ".answer.replayed") or std.mem.eql(u8, path, ".answer.created")) return bool;
            if (std.mem.eql(u8, path, ".answer.code")) return wire_field.JsonString(max_code_bytes);
            if (std.mem.eql(u8, path, ".input.type")) return wire_field.JsonString(8);
            if (std.mem.eql(u8, path, ".execution.reason")) return wire_field.JsonString(64);
            inline for (.{ ".answer.status", ".queue.status", ".execution.status", ".completion.status" }) |field| {
                if (std.mem.eql(u8, path, field)) return wire_field.JsonString(16);
            }
            if (kind == .message and std.mem.eql(u8, path, ".execution")) return struct {
                status: wire_field.JsonString(16),
                reason: wire_field.OmittableJson(wire_field.JsonString(64)) = .{},
            };
            if (std.mem.eql(u8, path, ".answer.decision")) return wire_field.JsonString(16);
            return null;
        }
        pub fn mergeDeferred(previous: ?anyerror, next: anyerror) anyerror {
            if (next == error.RequestBindingMismatch or (previous != null and previous.? == error.RequestBindingMismatch)) return error.RequestBindingMismatch;
            return previous orelse next;
        }
        pub fn foreign(comptime path: []const u8, name: []const u8) anyerror!void {
            if (std.mem.eql(u8, path, ".answer") and
                (std.mem.eql(u8, name, "target") or (kind == .model_interruption and std.mem.eql(u8, name, "session")))) return error.RequestBindingMismatch;
            return error.ForeignAuthority;
        }
    };
}

fn bind(comptime kind: CommandKind, comptime accepted: bool, partial: anytype, session: []const u8, target: Target, resolved_session: *Bounded(max_session_bytes)) Error!void {
    inline for (.{ ".version", ".type", ".answer", ".answer.status", ".answer.replayed" }) |path| {
        if (!partial.has(path)) return error.InvalidResponse;
    }
    const answer = partial.value.answer;
    if (comptime kind == .model_interruption) {
        inline for (.{ ".answer.target", ".answer.target.session", ".answer.target.turn", ".answer.target.operation" }) |path| {
            if (!partial.has(path)) return error.InvalidResponse;
        }
        if (partial.deferred_error != null and partial.deferred_error.? == error.RequestBindingMismatch) return error.RequestBindingMismatch;
        const echoed = answer.target;
        if (!echoed.session.eql(session) or try decimalId(echoed.turn, true) != target.model_interruption.turn or
            try decimalId(echoed.operation, true) != target.model_interruption.operation) return error.RequestBindingMismatch;
    } else {
        if (!partial.has(".answer.session")) return error.InvalidResponse;
        if (partial.deferred_error != null and partial.deferred_error.? == error.RequestBindingMismatch) return error.RequestBindingMismatch;
        const echoed = answer.session;
        if (comptime kind == .configure and accepted) {
            if (session.len == 0 and answer.status.eql("accepted")) {
                if (!session_id.valid(echoed.slice()) or !partial.has(".answer.created") or !answer.created) return error.RequestBindingMismatch;
                resolved_session.* = echoed.value;
            } else if (!echoed.eql(session)) return error.RequestBindingMismatch;
        } else if (comptime kind == .message and accepted) {
            if (target.message.creates_session and session.len == 0 and answer.status.eql("accepted")) {
                if (!session_id.valid(echoed.slice())) return error.RequestBindingMismatch;
                resolved_session.* = echoed.value;
            } else if (!echoed.eql(session)) return error.RequestBindingMismatch;
        } else if (!echoed.eql(session)) return error.RequestBindingMismatch;
    }
    if (comptime kind == .permission_decision) {
        if (!partial.has(".answer.action") or !partial.has(".answer.decision")) return error.InvalidResponse;
        if (try decimalId(answer.action, true) != target.permission_decision.action or !answer.decision.eql(@tagName(target.permission_decision.decision))) return error.RequestBindingMismatch;
    } else if (comptime kind == .action_background or kind == .action_stop) {
        if (!partial.has(".answer.action")) return error.InvalidResponse;
        const expected_action = if (comptime kind == .action_background) target.action_background else target.action_stop;
        if (try decimalId(answer.action, true) != expected_action) return error.RequestBindingMismatch;
    }
    if (answer.status.eql("accepted") and !session_id.valid(resolved_session.slice())) return error.InvalidResponse;
}

fn require(partial: anytype, comptime path: []const u8) Error!void {
    if (!partial.has(path)) return error.InvalidResponse;
}

fn creationConfiguration(partial: anytype) Error!?@import("creation_receipt.zig").Configuration {
    const answer = partial.value.answer;
    return if (@hasField(@TypeOf(answer), "configuration")) config: {
        try require(partial, ".answer.configuration");
        const c = answer.configuration;
        if (!@import("model_catalog.zig").validModelSyntax(c.model.slice())) return error.InvalidResponse;
        break :config .{
            .provider = c.provider.value,
            .model = c.model.value,
            .reasoning_effort = if (c.reasoning_effort) |effort| effort.value else null,
            .workspace = c.workspace.value,
            .tools = c.tools.value,
            .loaded_tools = c.loaded_tools.value,
            .permission_mode = c.permission_mode.value,
            .compaction_trigger = if (c.compaction_trigger) |trigger| try decimalId(trigger, false) else null,
        };
    } else null;
}

fn decide(comptime kind: CommandKind, comptime accepted: bool, comptime conflict: bool, partial: anytype, target: Target) Error!Answer {
    const wire = partial.value;
    const answer = wire.answer;
    if (!accepted) {
        try require(partial, ".answer.code");
        if (answer.code.slice().len == 0) return error.InvalidResponse;
        if (conflict and (!answer.code.eql("idempotency_key_conflict") or answer.replayed)) return error.InvalidResponse;
    }
    if (comptime kind == .configure) {
        try require(partial, ".execution");
        try require(partial, ".execution.reason");
        if (!wire.execution.status.eql("unavailable") or !wire.execution.reason.eql("direct_reply_does_not_wait_for_model_processing")) return error.InvalidResponse;
    } else if (comptime kind == .message) {
        try require(partial, ".execution");
        if (!wire.execution.status.eql("queued")) return error.InvalidResponse;
    } else if (comptime kind == .session_stop or kind == .session_archive) {
        try require(partial, ".completion");
        if (!accepted and !wire.completion.status.eql("unavailable")) return error.InvalidResponse;
    }
    var confirmed_input: ?ContentReference = null;
    if (comptime kind == .message and !conflict) {
        try require(partial, ".input");
        const input = wire.input;
        var digest: [32]u8 = undefined;
        if (!input.type.eql("text") or input.sha256.slice().len != 64) return error.InvalidResponse;
        _ = std.fmt.hexToBytes(&digest, input.sha256.slice()) catch return error.InvalidResponse;
        const bytes = try decimalId(input.bytes, true);
        confirmed_input = .{ .bytes = bytes, .digest = digest };
        if (bytes != target.message.bytes or !std.mem.eql(u8, &digest, &target.message.digest)) return error.RequestBindingMismatch;
    }
    const value: @FieldType(@FieldType(Answer, "result"), "accepted") = if (!accepted) undefined else switch (kind) {
        .configure => blk: {
            try require(partial, ".answer.revision");
            try require(partial, ".answer.created");
            const skills = if (@hasField(@TypeOf(answer), "skills")) skills: {
                try require(partial, ".answer.skills");
                if (answer.created) return error.InvalidResponse;
                break :skills answer.skills.value;
            } else null;
            const configuration = try creationConfiguration(partial);
            if (answer.created != (configuration != null)) return error.InvalidResponse;
            break :blk .{ .configure = .{ .revision = try decimalId(answer.revision, false), .created = answer.created, .skills = skills, .configuration = configuration } };
        },
        .message => blk: {
            try require(partial, ".answer.admission");
            const admission = try decimalId(answer.admission, false);
            try require(partial, ".queue");
            if (!wire.queue.status.eql("queued") or try decimalId(wire.queue.admission, false) != admission) return error.InvalidResponse;
            const configuration = try creationConfiguration(partial);
            if (target.message.creates_session != (configuration != null)) return error.InvalidResponse;
            break :blk .{ .message = .{ .admission = admission, .configuration = configuration } };
        },
        .session_stop => blk: {
            try require(partial, ".answer.selection");
            break :blk .{ .session_stop = .{
                .turn = if (answer.selection.turn) |turn| try decimalId(turn, false) else null,
                .admission_cutoff = try decimalId(answer.selection.admission_cutoff, true),
                .completion = std.meta.stringToEnum(SessionStopCompletion, wire.completion.status.slice()) orelse return error.InvalidResponse,
            } };
        },
        .session_archive => blk: {
            try require(partial, ".answer.archived");
            if (answer.archived != target.session_archive.archived) return error.RequestBindingMismatch;
            break :blk .{ .session_archive = .{ .archived = answer.archived, .completion = std.meta.stringToEnum(SessionStopCompletion, wire.completion.status.slice()) orelse return error.InvalidResponse } };
        },
        .session_pin => blk: {
            try require(partial, ".answer.pinned");
            if (answer.pinned != target.session_pin.pinned) return error.RequestBindingMismatch;
            break :blk .{ .session_pin = .{ .pinned = answer.pinned } };
        },
        .model_interruption => .model_interruption,
        .permission_decision => .permission_decision,
        .action_stop => blk: {
            try require(partial, ".answer.resolution_position");
            break :blk .{ .action_stop = if (answer.resolution_position) |p| try decimalId(p, false) else null };
        },
        .action_background => blk: {
            try require(partial, ".answer.action_selection");
            break :blk .{ .action_background = .{ .kind = answer.action_selection.kind.value, .position = try decimalId(answer.action_selection.position, false) } };
        },
    };
    if (partial.missing_fields) return error.InvalidResponse;
    return .{
        .input = confirmed_input,
        .replayed = answer.replayed,
        .result = if (accepted) .{ .accepted = value } else if (conflict) .conflict else .{ .rejected = answer.code.value },
    };
}

pub fn validateInvocationDiagnostic(current_version: []const u8, status: u16, version: []const u8, diagnostic: InvocationDiagnostic) error{InvalidResponse}!void {
    if (status == 200 or !std.mem.eql(u8, version, current_version) or diagnostic.type.len == 0 or diagnostic.code.len == 0) return error.InvalidResponse;
    if (diagnostic.code.eql("canonical_store_failure") and (status != 500 or !diagnostic.type.eql("invocation_error"))) return error.InvalidResponse;
}

const stale = "6";

const Decoded = struct { answer: Error!Answer, diagnostic: ?InvocationDiagnostic = null, session: Bounded(max_session_bytes) = .{} };

fn decodeForTest(comptime protocol: type, comptime command_reply: type, status: u16, body: []const u8, session: []const u8, target: Target) Decoded {
    var storage: [16 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var result: Decoded = .{ .answer = error.InvalidResponse };
    result.session.set(session) catch unreachable;
    var resolved = result.session;
    result.answer = decode(protocol, command_reply, fixed.allocator(), body, status, session, target, &result.diagnostic, &resolved);
    if (result.answer) |_| result.session = resolved else |_| {}
    return result;
}

test "a mutation answer binds its request and its queue" {
    const current = @import("protocol.zig").wire_version;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("a\nµ", &digest, .{});
    const target: Target = .{ .message = .{ .bytes = 4, .digest = digest } };
    const prefix = "{\"version\":\"" ++ current ++ "\",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2q\\u0078\",\"admission\":\"7\"}";
    var suffix_storage: [256]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&suffix_storage, ",\"input\":{{\"type\":\"text\",\"bytes\":\"4\",\"sha256\":\"{s}\"}},\"queue\":{{\"status\":\"queued\",\"admission\":\"7\"}},\"execution\":{{\"status\":\"queued\"}}}}", .{std.fmt.bytesToHex(digest, .lower)});
    var body: [1024]u8 = undefined;
    const valid = try std.fmt.bufPrint(&body, "{s}{s}", .{ prefix, suffix });
    try std.testing.expectEqual(@as(u64, 7), (try decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, valid, "k7m2qx", target).answer).result.accepted.message.admission);
    try std.testing.expectError(error.RequestBindingMismatch, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, valid, "09azvw", target).answer);
    var changed = target;
    changed.message.bytes = 5;
    try std.testing.expectError(error.RequestBindingMismatch, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, valid, "k7m2qx", changed).answer);
    changed = target;
    changed.message.digest[3] ^= 1;
    try std.testing.expectError(error.RequestBindingMismatch, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, valid, "k7m2qx", changed).answer);
    try std.testing.expectError(error.InvalidResponse, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 409, valid, "k7m2qx", target).answer);
    for ([_][]const u8{
        "{\"version\":" ++ current ++ ",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"admission\":\"7\"}",
        "{\"version\":\"" ++ current ++ "\",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"sta\\u0074us\":\"rejected\",\"replayed\":false,\"session\":\"k7m2qx\",\"admission\":\"7\"}",
        "{\"version\":\"" ++ current ++ "\",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"admission\":\"07\"}",
        "{\"version\":\"" ++ current ++ "\",\"type\":\"message_reply\",\"answer\":{\"status\":\"rejected\",\"replayed\":false,\"session\":\"k7m2qx\",\"code\":\"unknown_session\"}",
    }) |invalid_prefix| {
        const invalid = try std.fmt.bufPrint(&body, "{s}{s}", .{ invalid_prefix, suffix });
        try std.testing.expectError(error.InvalidResponse, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, invalid, "k7m2qx", target).answer);
    }
    const conflicting_queue = try std.fmt.bufPrint(&body, "{s},\"input\":{{\"type\":\"text\",\"bytes\":\"4\",\"sha256\":\"{s}\"}},\"queue\":{{\"status\":\"queued\",\"admission\":\"8\"}},\"execution\":{{\"status\":\"queued\"}}}}", .{ prefix, std.fmt.bytesToHex(digest, .lower) });
    try std.testing.expectError(error.InvalidResponse, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, conflicting_queue, "k7m2qx", target).answer);
}

test "skills reload reply facts apply only to accepted existing Configure mutations" {
    const current = @import("protocol.zig").wire_version;
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
                const reply = decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), if (conflict) 409 else 200, body, "k7m2qx", case.target);
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
    for ([_][]const u8{ "false", "true" }) |created| {
        for (reload_fields) |reload| {
            const body = try std.fmt.bufPrint(&buffer, "{{\"version\":\"{s}\",\"type\":\"configuration_reply\",\"answer\":{{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"revision\":\"31\",\"created\":{s}{s}}}{s}}}", .{ current, created, reload.bytes, cases[0].accepted_tail });
            const creating = std.mem.eql(u8, created, "true");
            const reply = decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, body, if (creating) "" else "k7m2qx", .configure);
            if (creating) {
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
        try std.testing.expectError(error.InvalidResponse, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, body, "k7m2qx", .configure).answer);
    }
}

test "mutation decoder preserves invalid-target domain rejection not false fatal certainty" {
    const current = @import("protocol.zig").wire_version;
    const body = "{\"version\":\"" ++ current ++ "\",\"type\":\"model_interruption_reply\",\"answer\":{\"status\":\"rejected\",\"replayed\":true,\"target\":{\"session\":\"s\",\"turn\":\"0\",\"operation\":\"18446744073709551615\"},\"code\":\"invalid_target\"}}";
    const target: Target = .{ .model_interruption = .{ .turn = 0, .operation = std.math.maxInt(u64) } };
    const answer = try decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, body, "s", target).answer;
    try std.testing.expectEqualStrings("invalid_target", answer.result.rejected.slice());
    try std.testing.expect(answer.replayed);
    for ([_][]const u8{
        "{\"version\":\"" ++ current ++ "\",\"type\":\"invocation_error\",\"code\":\"unavailable\"}",
        "{\"version\":\"" ++ current ++ "\",\"type\":\"message_reply\",\"answer\":{\"status\":\"infrastructure_failure\",\"code\":\"canonical_store_failure\"}}",
    }) |unknown| {
        const reply = decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 500, unknown, "s", target);
        try std.testing.expectError(if (std.mem.indexOf(u8, unknown, "unavailable") != null) error.HostInvocationFailed else error.InvalidResponse, reply.answer);
        if (std.mem.indexOf(u8, unknown, "unavailable") != null)
            try std.testing.expectEqualStrings("unavailable", reply.diagnostic.?.code.slice());
    }
}

test "session archive mutation reply binds intent and completion on accepted replies" {
    const current = @import("protocol.zig").wire_version;
    const head = "{\"version\":\"" ++ current ++ "\",\"type\":\"session_archive_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\"";
    const accepted = head ++ ",\"archived\":false},\"completion\":{\"status\":\"completed\"}}";
    const target: Target = .{ .session_archive = .{ .archived = false } };
    const answer = try decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, accepted, "k7m2qx", target).answer;
    try std.testing.expect(!answer.result.accepted.session_archive.archived);
    try std.testing.expectEqual(.completed, answer.result.accepted.session_archive.completion);
    try std.testing.expectError(error.RequestBindingMismatch, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, accepted, "k7m2qx", .{ .session_archive = .{ .archived = true } }).answer);
    inline for (.{
        head ++ "},\"completion\":{\"status\":\"completed\"}}",
        head ++ ",\"archived\":null},\"completion\":{\"status\":\"completed\"}}",
        head ++ ",\"archived\":false},\"completion\":{\"status\":\"unavailable\"}}",
        head ++ ",\"archived\":false}}",
        head ++ ",\"archived\":false,\"selection\":{\"turn\":null,\"admission_cutoff\":\"0\"}},\"completion\":{\"status\":\"completed\"}}",
        head ++ ",\"archived\":false},\"completion\":{\"status\":\"completed\"},\"execution\":{\"status\":\"queued\"}}",
    }) |invalid| try std.testing.expectError(error.InvalidResponse, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, invalid, "k7m2qx", target).answer);
    const rejected = "{\"version\":\"" ++ current ++ "\",\"type\":\"session_archive_reply\",\"answer\":{\"status\":\"rejected\",\"replayed\":true,\"session\":\"k7m2qx\",\"code\":\"archive_pending\"},\"completion\":{\"status\":\"unavailable\"}}";
    const refusal = try decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, rejected, "k7m2qx", target).answer;
    try std.testing.expect(refusal.replayed);
    try std.testing.expectEqualStrings("archive_pending", refusal.result.rejected.slice());
}

test "a diagnostic reply confirms nothing, and only an authoritative one names a Store failure" {
    const current = @import("protocol.zig").wire_version;
    for ([_][]const u8{
        "{\"version\":\"" ++ current ++ "\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"" ++ current ++ "\",\"type\":\"busy\",\"code\":\"capacity_exhausted\"}",
    }, [_]u16{ 500, 503 }) |valid, status| {
        const value = decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), status, valid, "s", .configure);
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
        const value = decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 500, invalid, "s", .configure);
        try std.testing.expectError(error.InvalidResponse, value.answer);
        try std.testing.expect(value.diagnostic == null);
    }
    for ([_][]const u8{
        "{\"version\":\"" ++ stale ++ "\",\"type\":\"invocation_error\",\"code\":\"busy\"}",
        "{\"version\":\"" ++ current ++ "\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
    }, [_]u16{ 503, 503 }) |invalid, status| {
        const value = decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), status, invalid, "s", .configure);
        try std.testing.expectError(error.InvalidResponse, value.answer);
        try std.testing.expect(value.diagnostic == null);
    }
}

test "a reply carrying another mutation's fields, or the wrong version, confirms nothing" {
    const current = @import("protocol.zig").wire_version;
    const archive = "{\"version\":\"" ++ current ++ "\",\"type\":\"session_archive_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"archived\":true}";
    const target: Target = .{ .session_archive = .{ .archived = true } };
    _ = try decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, archive ++ ",\"completion\":{\"status\":\"completed\"}}", "k7m2qx", target).answer;
    const stop = "{\"version\":\"" ++ current ++ "\",\"type\":\"session_stop_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"selection\":{\"turn\":null,\"admission_cutoff\":\"0\"}";
    _ = try decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, stop ++ "},\"completion\":{\"status\":\"pending\"}}", "k7m2qx", .session_stop).answer;
    for ([_][]const u8{
        stop ++ ",\"archived\":true},\"completion\":{\"status\":\"pending\"}}",
        "{\"version\":\"" ++ stale ++ archive["{\"version\":\"".len + current.len ..] ++ ",\"completion\":{\"status\":\"completed\"}}",
    }, [_]Target{ .session_stop, target }) |invalid, expected|
        try std.testing.expectError(error.InvalidResponse, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, invalid, "k7m2qx", expected).answer);
    const interruption: Target = .{ .model_interruption = .{ .turn = 3, .operation = 4 } };
    for ([_][]const u8{ "\"3\",\"operation\":\"4\"", "\"3\",\"operation\":\"5\"", "\"2\",\"operation\":\"4\"" }, 0..) |echoed, index| {
        var buffer: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&buffer, "{{\"version\":\"{s}\",\"type\":\"model_interruption_reply\",\"answer\":{{\"status\":\"accepted\",\"replayed\":false,\"target\":{{\"session\":\"k7m2qx\",\"turn\":{s}}}}}}}", .{ current, echoed });
        const answer = decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, body, "k7m2qx", interruption).answer;
        if (index == 0) _ = try answer else try std.testing.expectError(error.RequestBindingMismatch, answer);
    }
    const conflict = "{\"version\":\"" ++ current ++ "\",\"type\":\"session_stop_reply\",\"answer\":{\"status\":\"conflict\",\"replayed\":";
    const tail = ",\"session\":\"k7m2qx\",\"code\":\"idempotency_key_conflict\"},\"completion\":{\"status\":\"unavailable\"}}";
    try std.testing.expect((try decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 409, conflict ++ "false" ++ tail, "k7m2qx", .session_stop).answer).result == .conflict);
    try std.testing.expectError(error.InvalidResponse, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 409, conflict ++ "true" ++ tail, "k7m2qx", .session_stop).answer);
}

test "Session pin replies bind desired value and reject unrelated mutation authority" {
    const current = @import("protocol.zig").wire_version;
    const version = current;
    const accepted = "{\"version\":\"" ++ version ++ "\",\"type\":\"session_pin_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":true,\"session\":\"k7m2qx\",\"pinned\":false}}";
    const target: Target = .{ .session_pin = .{ .pinned = false } };
    const answer = try decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, accepted, "k7m2qx", target).answer;
    try std.testing.expect(answer.replayed);
    try std.testing.expect(!answer.result.accepted.session_pin.pinned);
    try std.testing.expectError(error.RequestBindingMismatch, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, accepted, "k7m2qx", .{ .session_pin = .{ .pinned = true } }).answer);
    try std.testing.expectError(error.RequestBindingMismatch, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, accepted, "rhvzwc", target).answer);
    const stopped = "{\"version\":\"" ++ version ++ "\",\"type\":\"session_pin_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"pinned\":false},\"completion\":{\"status\":\"completed\"}}";
    try std.testing.expectError(error.InvalidResponse, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, stopped, "k7m2qx", target).answer);
}

test "Action promotion replies bind the target and immutable receipt or final selection" {
    const current = @import("protocol.zig").wire_version;
    inline for (.{ "background", "final" }) |kind| {
        const accepted = "{\"version\":\"" ++ current ++ "\",\"type\":\"action_background_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":true,\"session\":\"k7m2qx\",\"action\":\"42\",\"action_selection\":{\"kind\":\"" ++ kind ++ "\",\"position\":\"9007199254740993\"}}}";
        const answer = try decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, accepted, "k7m2qx", .{ .action_background = 42 }).answer;
        try std.testing.expect(answer.replayed);
        try std.testing.expectEqualStrings(kind, @tagName(answer.result.accepted.action_background.kind));
        try std.testing.expectEqual(@as(u64, 9007199254740993), answer.result.accepted.action_background.position);
        try std.testing.expectError(error.RequestBindingMismatch, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, accepted, "rhvzwc", .{ .action_background = 42 }).answer);
        try std.testing.expectError(error.RequestBindingMismatch, decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, accepted, "k7m2qx", .{ .action_background = 43 }).answer);
    }
}

test "mutation rejection preserves an empty original creation target" {
    const current = @import("protocol.zig").wire_version;
    const execution = ",\"execution\":{\"status\":\"unavailable\",\"reason\":\"direct_reply_does_not_wait_for_model_processing\"}}";
    const body = "{\"version\":\"" ++ current ++ "\",\"type\":\"configuration_reply\",\"answer\":{\"status\":\"rejected\",\"replayed\":true,\"session\":\"\",\"code\":\"invalid_configuration\"}" ++ execution;
    const answer = try decodeForTest(@import("protocol.zig"), @import("command_reply.zig"), 200, body, "", .configure).answer;
    try std.testing.expect(answer.replayed);
    try std.testing.expectEqualStrings("invalid_configuration", answer.result.rejected.slice());
}

test "creation replies bind bounded immutable settings to creating requests" {
    const protocol = @import("protocol.zig");
    const command_reply = @import("command_reply.zig");
    const config = ",\"configuration\":{\"provider\":\"codex\",\"model\":\"gpt-5.5\",\"reasoning_effort\":\"high\",\"workspace\":\"/workspace\",\"tools\":[\"bash\"],\"loaded_tools\":[\"bash\"],\"permission_mode\":\"ask\",\"compaction_trigger\":\"100\"}";
    const message_head = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":true,\"session\":\"k7m2qx\",\"admission\":\"7\"";
    const message_tail = "},\"input\":{\"type\":\"text\",\"bytes\":\"3\",\"sha256\":\"" ++ @as([64]u8, @splat('0')) ++ "\"},\"queue\":{\"status\":\"queued\",\"admission\":\"7\"},\"execution\":{\"status\":\"queued\"}}";
    const target: Target = .{ .message = .{ .bytes = 3, .digest = @splat(0), .creates_session = true } };
    const result = decodeForTest(protocol, command_reply, 200, message_head ++ config ++ message_tail, "", target);
    const receipt = (try result.answer).result.accepted.message.configuration.?;
    try std.testing.expectEqualStrings("gpt-5.5", receipt.model.slice());
    try std.testing.expectEqualStrings("bash", receipt.tools.slice());
    try std.testing.expectEqual(@as(?u64, 100), receipt.compaction_trigger);
    try std.testing.expectError(error.InvalidResponse, decodeForTest(protocol, command_reply, 200, message_head ++ message_tail, "", target).answer);
    const malformed = ",\"configuration\":{\"provider\":\"codex\",\"model\":\"bad model\",\"reasoning_effort\":null,\"workspace\":\"/workspace\",\"tools\":[],\"loaded_tools\":[],\"permission_mode\":\"ask\",\"compaction_trigger\":null}";
    try std.testing.expectError(error.InvalidResponse, decodeForTest(protocol, command_reply, 200, message_head ++ malformed ++ message_tail, "", target).answer);
    const send: Target = .{ .message = .{ .bytes = 3, .digest = @splat(0) } };
    try std.testing.expectError(error.InvalidResponse, decodeForTest(protocol, command_reply, 200, message_head ++ config ++ message_tail, "k7m2qx", send).answer);
    const configure = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"configuration_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"revision\":\"1\",\"created\":true" ++ config ++ "},\"execution\":{\"status\":\"unavailable\",\"reason\":\"direct_reply_does_not_wait_for_model_processing\"}}";
    const configured = decodeForTest(protocol, command_reply, 200, configure, "", .configure);
    try std.testing.expectEqualStrings("/workspace", (try configured.answer).result.accepted.configure.configuration.?.workspace.slice());
}
