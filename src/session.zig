const std = @import("std");
const bash_tool = @import("bash_tool.zig");
const binding = @import("binding.zig");
const conversation = @import("conversation.zig");
const model_contract = @import("model_contract.zig");
const completion_inbox = @import("completion_inbox.zig");
const core_image = @import("core_image.zig");
const host_store = @import("host_store.zig");
const model_protocol = @import("model_protocol.zig");
const patch_tool = @import("patch_tool.zig");
const session_transition = @import("session_transition.zig");

const continuation = struct {
    const schema_version: u16 = 6;
    const encoded_size = session_transition.continuation_size;
    const magic = "ONECORE\x00";
    const checksum_offset = encoded_size - @sizeOf(u32);

    const OperationPhase = enum(u8) {
        idle = 0,
        accepted = 1,
        completed = 2,
    };

    const TaskPhase = enum(u8) {
        idle = 0,
        ready = 1,
        awaiting_model = 2,
        awaiting_tool = 3,
        finished = 4,
        failed = 5,
    };

    const ContentWindow = extern struct {
        offset: u32 = 0,
        length: u32 = 0,
    };

    const State = extern struct {
        agent_id: u64,
        agent_generation: u32,
        operation_id: u64 = 0,
        operation_generation: u32 = 0,
        operation_phase: continuation.OperationPhase = .idle,
        operation_result: u64 = 0,
        operation_sequence: u64 = 0,
        active_leaf_id: u64 = 0,
        final_entry_id: u64 = 0,
        response_ref: u64 = 0,
        task_phase: continuation.TaskPhase = .idle,
        response_disposition: model_protocol.Disposition = .failure,
        response_failure: model_protocol.Failure = .none,
        context: continuation.ContentWindow = .{},
        response_text: continuation.ContentWindow = .{},
        response_tool_key: continuation.ContentWindow = .{},
        response_arguments: continuation.ContentWindow = .{},
        response_arguments_digest: binding.StrictToolJsonV1 = .{ .bytes = @splat(0) },
    };

    const Identity = struct {
        agent_id: u64,
        generation: u32,
    };

    const OperationIdentity = struct {
        id: u64,
        generation: u32,
    };

    const Operation = struct {
        id: u64,
        generation: u32,
        phase: continuation.OperationPhase,
        result_ref: u64,
        sequence: u64,
    };

    const ModelContext = struct {
        first_entry: u32,
        entry_count: u32,
    };

    const StrictToolJsonWindow = struct {
        offset: u32,
        length: u32,
        digest: binding.StrictToolJsonV1,

        fn contentWindow(self: @This()) continuation.ContentWindow {
            return .{ .offset = self.offset, .length = self.length };
        }
    };

    const Response = struct {
        content_ref: u64,
        disposition: model_protocol.Disposition,
        failure: model_protocol.Failure,
        text: continuation.ContentWindow,
        tool_key: continuation.ContentWindow,
        arguments: continuation.StrictToolJsonWindow,
    };

    const Task = struct {
        phase: continuation.TaskPhase,
        active_leaf_id: u64,
        final_entry_id: u64,
    };

    const CompletionConsequence = union(enum) {
        final_answer: u64,
        tool_call,
        terminal,
    };

    const ModelAttemptReduction = struct {
        state: State,
        operation: continuation.Operation,
        context: continuation.ModelContext,
    };

    const ModelCompletionReduction = struct {
        state: State,
        response: continuation.Response,
    };

    fn initialize(identity_value: Identity) !State {
        if (identity_value.agent_id == 0) return error.InvalidAgentIdentity;
        if (identity_value.generation == 0) return error.InvalidAgentGeneration;
        return .{
            .agent_id = identity_value.agent_id,
            .agent_generation = identity_value.generation,
        };
    }

    fn identity(state: State) Identity {
        return .{ .agent_id = state.agent_id, .generation = state.agent_generation };
    }

    fn operation(state: State) continuation.Operation {
        return .{
            .id = state.operation_id,
            .generation = state.operation_generation,
            .phase = state.operation_phase,
            .result_ref = state.operation_result,
            .sequence = state.operation_sequence,
        };
    }

    fn task(state: State) continuation.Task {
        return .{
            .phase = state.task_phase,
            .active_leaf_id = state.active_leaf_id,
            .final_entry_id = state.final_entry_id,
        };
    }

    fn response(state: State) continuation.Response {
        return .{
            .content_ref = state.response_ref,
            .disposition = state.response_disposition,
            .failure = state.response_failure,
            .text = state.response_text,
            .tool_key = state.response_tool_key,
            .arguments = .{
                .offset = state.response_arguments.offset,
                .length = state.response_arguments.length,
                .digest = state.response_arguments_digest,
            },
        };
    }

    fn modelContext(state: State) continuation.ModelContext {
        return .{ .first_entry = state.context.offset, .entry_count = state.context.length };
    }

    fn startTask(committed: State, active_leaf_id: u64) !State {
        if (active_leaf_id == 0) return error.InvalidConversationEntry;
        if (committed.task_phase != .idle or committed.operation_phase != .idle) {
            return error.IllegalTaskTransition;
        }
        var candidate = committed;
        candidate.active_leaf_id = active_leaf_id;
        candidate.task_phase = .ready;
        return candidate;
    }

    fn admitModelAttempt(
        committed: State,
        operation_id: u64,
        sequence: u64,
    ) !ModelAttemptReduction {
        if (operation_id == 0 or sequence == 0) return error.InvalidOperationIdentity;
        if (committed.task_phase != .ready or committed.active_leaf_id >= std.math.maxInt(u32)) {
            return error.IllegalModelTransition;
        }
        if (committed.operation_phase != .idle and committed.operation_phase != .completed) {
            return error.OperationAlreadyActive;
        }
        if (committed.operation_generation == std.math.maxInt(u32)) {
            return error.OperationGenerationExhausted;
        }
        var candidate = committed;
        candidate.operation_id = operation_id;
        candidate.operation_generation += 1;
        candidate.operation_phase = .accepted;
        candidate.operation_result = 0;
        candidate.operation_sequence = sequence;
        candidate.context = .{ .offset = 1, .length = @intCast(committed.active_leaf_id) };
        candidate.response_ref = 0;
        candidate.response_disposition = .failure;
        candidate.response_failure = .none;
        candidate.response_text = .{};
        candidate.response_tool_key = .{};
        candidate.response_arguments = .{};
        candidate.response_arguments_digest = .{ .bytes = @splat(0) };
        candidate.task_phase = .awaiting_model;
        return .{
            .state = candidate,
            .operation = operation(candidate),
            .context = modelContext(candidate),
        };
    }

    fn admitModelCompletion(
        committed: State,
        identity_value: OperationIdentity,
        admission: model_protocol.Admission,
        response_ref: u64,
        result_digest: binding.Result,
        consequence: CompletionConsequence,
    ) !ModelCompletionReduction {
        try requireOperation(committed, identity_value, .accepted);
        if (response_ref == 0) return error.InvalidResultReference;
        if (admission.byte_length > model_protocol.max_response_size) return error.ResponseCapacityExceeded;
        if (committed.task_phase != .awaiting_model) return error.IllegalModelResponseTransition;
        const parsed = try admission.verify(result_digest);
        if (admission.byte_length == 0 and
            !(parsed.disposition == .failure and parsed.failure == .empty))
        {
            return error.EmptyModelResponse;
        }
        switch (consequence) {
            .final_answer => |entry_id| {
                if (parsed.disposition != .final_answer) return error.InvalidCompletionConsequence;
                if (entry_id == 0 or committed.active_leaf_id == std.math.maxInt(u64) or
                    entry_id != committed.active_leaf_id + 1)
                {
                    return error.IllegalFinalAnswerTransition;
                }
            },
            .tool_call => if (parsed.disposition != .tool_call) return error.InvalidCompletionConsequence,
            .terminal => if (parsed.disposition == .final_answer or parsed.disposition == .tool_call) {
                return error.InvalidCompletionConsequence;
            },
        }
        var candidate = committed;
        candidate.operation_result = response_ref;
        candidate.operation_phase = .completed;
        candidate.response_ref = response_ref;
        candidate.response_disposition = parsed.disposition;
        candidate.response_failure = parsed.failure;
        candidate.response_text = if (parsed.disposition == .final_answer) .{
            .offset = parsed.text_offset,
            .length = parsed.text_length,
        } else .{};
        candidate.response_tool_key = .{
            .offset = parsed.tool_key_offset,
            .length = parsed.tool_key_length,
        };
        candidate.response_arguments = .{
            .offset = parsed.arguments_offset,
            .length = parsed.arguments_length,
        };
        candidate.response_arguments_digest = parsed.arguments_digest;
        candidate.task_phase = switch (consequence) {
            .final_answer => |entry_id| blk: {
                candidate.active_leaf_id = entry_id;
                candidate.final_entry_id = entry_id;
                break :blk .finished;
            },
            .tool_call => .awaiting_tool,
            .terminal => .failed,
        };
        return .{ .state = candidate, .response = response(candidate) };
    }

    fn admitToolResult(committed: State, call_entry_id: u64, result_entry_id: u64) !State {
        if (call_entry_id == 0 or result_entry_id == 0 or
            committed.active_leaf_id == std.math.maxInt(u64) or
            call_entry_id == std.math.maxInt(u64))
        {
            return error.InvalidConversationEntry;
        }
        if (committed.task_phase != .awaiting_tool or
            call_entry_id != committed.active_leaf_id + 1 or
            result_entry_id != call_entry_id + 1)
        {
            return error.IllegalToolResultTransition;
        }
        var candidate = committed;
        candidate.active_leaf_id = result_entry_id;
        candidate.task_phase = .ready;
        return candidate;
    }

    fn encode(out: []u8, state: State) !void {
        if (out.len != encoded_size) return error.InvalidCoreStateOutputLength;
        try validate(state);
        @memset(out, 0);
        @memcpy(out[0..magic.len], magic);
        write(u16, out, 8, schema_version);
        write(u16, out, 10, encoded_size);
        write(u64, out, 16, state.agent_id);
        write(u32, out, 24, state.agent_generation);
        write(u64, out, 48, state.operation_id);
        write(u32, out, 56, state.operation_generation);
        out[60] = @intFromEnum(state.operation_phase);
        out[61] = @intFromEnum(state.task_phase);
        out[62] = @intFromEnum(state.response_disposition);
        out[63] = @intFromEnum(state.response_failure);
        write(u64, out, 68, state.operation_result);
        write(u64, out, 76, state.operation_sequence);
        write(u64, out, 84, state.active_leaf_id);
        write(u64, out, 92, state.final_entry_id);
        write(u64, out, 100, state.response_ref);
        writeWindow(out, 108, state.context);
        writeWindow(out, 116, state.response_text);
        writeWindow(out, 124, state.response_arguments);
        writeWindow(out, 132, state.response_tool_key);
        @memcpy(out[140..172], &state.response_arguments_digest.bytes);
        rewriteChecksum(out);
    }

    fn decode(input: []const u8) !State {
        if (input.len != encoded_size) return error.TruncatedCoreState;
        if (!std.mem.eql(u8, input[0..magic.len], magic)) return error.InvalidCoreStateMagic;
        if (read(u16, input, 8) != schema_version) return error.UnsupportedSchema;
        if (read(u16, input, 10) != encoded_size) return error.InvalidCoreStateLength;
        if (read(u32, input, 12) != 0) return error.UnsupportedCoreStateFlags;
        for (input[28..48]) |byte| if (byte != 0) return error.NonzeroCoreStateReservedByte;
        for (input[64..68]) |byte| if (byte != 0) return error.NonzeroCoreStateReservedByte;
        if (read(u32, input, checksum_offset) != std.hash.Crc32.hash(input[0..checksum_offset])) {
            return error.CoreStateChecksumMismatch;
        }
        const state: State = .{
            .agent_id = read(u64, input, 16),
            .agent_generation = read(u32, input, 24),
            .operation_id = read(u64, input, 48),
            .operation_generation = read(u32, input, 56),
            .operation_phase = try operationPhase(input[60]),
            .task_phase = try taskPhase(input[61]),
            .response_disposition = try responseDisposition(input[62]),
            .response_failure = try responseFailure(input[63]),
            .operation_result = read(u64, input, 68),
            .operation_sequence = read(u64, input, 76),
            .active_leaf_id = read(u64, input, 84),
            .final_entry_id = read(u64, input, 92),
            .response_ref = read(u64, input, 100),
            .context = readWindow(input, 108),
            .response_text = readWindow(input, 116),
            .response_arguments = readWindow(input, 124),
            .response_tool_key = readWindow(input, 132),
            .response_arguments_digest = .{ .bytes = input[140..172].* },
        };
        try validate(state);
        return state;
    }

    fn validate(state: State) !void {
        if (state.agent_id == 0) return error.InvalidAgentIdentity;
        if (state.agent_generation == 0) return error.InvalidAgentGeneration;
        try validateOperation(state);
        try validateWindow(state.context, null);
        try validateWindow(state.response_text, model_protocol.max_response_size);
        try validateWindow(state.response_tool_key, model_protocol.max_response_size);
        try validateWindow(state.response_arguments, model_protocol.max_response_size);
        try validateTask(state);
        try validateResponse(state);
    }

    fn validateOperation(state: State) !void {
        switch (state.operation_phase) {
            .idle => {
                if (state.operation_id != 0) return error.InvalidOperationIdentity;
                if (state.operation_generation != 0 or state.operation_sequence != 0) {
                    return error.InvalidOperationGeneration;
                }
                if (state.operation_result != 0) return error.InvalidOperationResult;
            },
            .accepted => {
                if (state.operation_id == 0) return error.InvalidOperationIdentity;
                if (state.operation_generation == 0 or state.operation_sequence == 0) {
                    return error.InvalidOperationGeneration;
                }
                if (state.operation_result != 0) return error.InvalidOperationResult;
            },
            .completed => {
                if (state.operation_id == 0) return error.InvalidOperationIdentity;
                if (state.operation_generation == 0 or state.operation_sequence == 0) {
                    return error.InvalidOperationGeneration;
                }
                if (state.operation_result == 0) return error.InvalidOperationResult;
            },
        }
    }

    fn validateTask(state: State) !void {
        switch (state.task_phase) {
            .idle => if (state.active_leaf_id != 0 or state.final_entry_id != 0) {
                return error.InvalidTaskState;
            },
            .ready => if (state.active_leaf_id == 0 or state.final_entry_id != 0) {
                return error.InvalidTaskState;
            },
            .awaiting_model => {
                if (state.active_leaf_id == 0 or state.final_entry_id != 0 or
                    state.operation_phase == .idle)
                {
                    return error.InvalidTaskState;
                }
                if (state.active_leaf_id >= std.math.maxInt(u32) or
                    state.context.offset != 1 or state.context.length != state.active_leaf_id)
                {
                    return error.InvalidModelContext;
                }
            },
            .awaiting_tool, .failed => if (state.active_leaf_id == 0 or
                state.final_entry_id != 0 or state.operation_phase != .completed)
            {
                return error.InvalidTaskState;
            },
            .finished => if (state.active_leaf_id == 0 or
                state.final_entry_id != state.active_leaf_id or
                state.operation_phase != .completed)
            {
                return error.InvalidTaskState;
            },
        }
    }

    fn validateResponse(state: State) !void {
        if (state.response_ref == 0) {
            if (state.response_disposition != .failure or
                state.response_failure != .none or state.response_text.length != 0 or
                state.response_tool_key.length != 0 or state.response_arguments.length != 0)
            {
                return error.InvalidResponseState;
            }
            switch (state.task_phase) {
                .idle, .ready, .awaiting_model => {},
                .awaiting_tool, .finished, .failed => return error.InvalidResponseState,
            }
            return;
        }
        if (state.operation_phase != .completed or state.operation_result != state.response_ref) {
            return error.InvalidResponseState;
        }
        switch (state.task_phase) {
            .finished => if (state.response_disposition != .final_answer or
                state.response_failure != .none or state.response_text.length == 0 or
                state.response_tool_key.length != 0 or state.response_arguments.length != 0)
            {
                return error.InvalidResponseState;
            },
            .awaiting_tool, .ready => if (state.response_disposition != .tool_call or
                state.response_failure != .none or state.response_tool_key.length == 0 or
                state.response_arguments.length == 0 or state.response_text.length != 0)
            {
                return error.InvalidResponseState;
            },
            .failed => switch (state.response_disposition) {
                .input_request => if (state.response_failure != .none or
                    state.response_tool_key.length != 0 or state.response_text.length != 0 or
                    state.response_arguments.length != 0)
                {
                    return error.InvalidResponseState;
                },
                .failure => if (state.response_failure == .none or
                    state.response_tool_key.length != 0 or state.response_text.length != 0 or
                    state.response_arguments.length != 0)
                {
                    return error.InvalidResponseState;
                },
                else => return error.InvalidResponseState,
            },
            .idle, .awaiting_model => return error.InvalidResponseState,
        }
    }

    fn validateWindow(window: continuation.ContentWindow, limit: ?usize) !void {
        if ((window.offset == 0) != (window.length == 0)) return error.InvalidContentWindow;
        const end = std.math.add(u32, window.offset, window.length) catch
            return error.ContentWindowOverflow;
        if (limit) |maximum| if (end > maximum) return error.ContentWindowOutOfRange;
    }

    fn requireOperation(state: State, value: OperationIdentity, phase: continuation.OperationPhase) !void {
        if (value.id == 0 or value.generation == 0) return error.InvalidOperationIdentity;
        if (state.operation_id != value.id or state.operation_generation != value.generation) {
            return error.StaleOperation;
        }
        if (state.operation_phase != phase) return error.IllegalOperationTransition;
    }

    fn operationPhase(value: u8) !continuation.OperationPhase {
        return switch (value) {
            0 => .idle,
            1 => .accepted,
            2 => .completed,
            else => error.UnknownOperationPhase,
        };
    }

    fn taskPhase(value: u8) !continuation.TaskPhase {
        return switch (value) {
            0 => .idle,
            1 => .ready,
            2 => .awaiting_model,
            3 => .awaiting_tool,
            4 => .finished,
            5 => .failed,
            else => error.UnknownTaskPhase,
        };
    }

    fn responseDisposition(value: u8) !model_protocol.Disposition {
        return switch (value) {
            1 => .final_answer,
            2 => .tool_call,
            3 => .input_request,
            4 => .failure,
            else => error.UnknownResponseDisposition,
        };
    }

    fn responseFailure(value: u8) !model_protocol.Failure {
        return switch (value) {
            0 => .none,
            1 => .truncated,
            2 => .aborted,
            3 => .provider_error,
            4 => .malformed,
            5 => .empty,
            6 => .multiple_outputs,
            7 => .oversized,
            8 => .unknown_tool,
            9 => .missing_authentication,
            10 => .authentication_expired,
            11 => .model_unavailable,
            12 => .timeout,
            13 => .transport_not_started,
            14 => .transport_may_have_started,
            15 => .unsupported_provider_output,
            else => error.UnknownResponseFailure,
        };
    }

    fn writeWindow(out: []u8, offset: usize, window: continuation.ContentWindow) void {
        write(u32, out, offset, window.offset);
        write(u32, out, offset + 4, window.length);
    }

    fn readWindow(input: []const u8, offset: usize) continuation.ContentWindow {
        return .{ .offset = read(u32, input, offset), .length = read(u32, input, offset + 4) };
    }

    fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
        std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
    }

    fn read(comptime T: type, input: []const u8, offset: usize) T {
        return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
    }

    fn rewriteChecksum(out: []u8) void {
        write(u32, out, checksum_offset, std.hash.Crc32.hash(out[0..checksum_offset]));
    }

    comptime {
        std.debug.assert(@sizeOf(State) <= core_image.slot_size);
        for (std.meta.fields(State)) |field| {
            switch (@typeInfo(field.type)) {
                .pointer => @compileError("Continuation State cannot contain pointers"),
                .int => if (field.type == usize or field.type == isize) {
                    @compileError("Continuation State cannot contain target-width integers");
                },
                else => {},
            }
        }
    }
};

fn slotState(slot: *core_image.ActivationSlot) *continuation.State {
    return @ptrCast(@alignCast(&slot.storage));
}

pub const workspace_path_capacity = 1024;
pub const model_name_capacity = host_store.max_model_bytes;
/// One live Session may stage the three values in V1's largest same-transaction
/// first-import closure: patch bytes, Patch Intent, and Tool Call content.
/// A transaction may refer to more content that is already durable.
pub const max_pending_content = host_store.max_first_content_imports;
pub const max_transient_scratch_bytes = max_pending_content * host_store.max_content_bytes;

pub const Identities = host_store.SessionIdentity;

pub const Config = struct {
    workspace_path: []const u8,
    model: []const u8,
    task: []const u8,
};

pub const CreateConfig = struct {
    identities: Identities,
    workspace_path: []const u8,
    model: []const u8,
    task: []const u8,
};

pub const OwnerToken = host_store.OwnerToken;

pub const PatchContent = struct {
    intent_reference: u64,
    patch_reference: u64,
    patch_digest: binding.PatchDescriptor,
};

pub const ModelAttemptMaterial = struct {
    operation_id: u64,
    sequence: u64,
    attempt_id: u64,
    request_ref: u64,
    request_digest: binding.ModelDescriptor,
    possible_duplicate_attempts: u8 = 0,
};

pub const BashCallMaterial = struct {
    command: [bash_tool.max_command_size]u8 = @splat(0),
    command_length: u16,
    timeout_ms: u32,

    pub fn init(call: bash_tool.Call) !BashCallMaterial {
        if (call.command.len == 0 or call.command.len > bash_tool.max_command_size) {
            return error.InvalidBashCall;
        }
        var result: BashCallMaterial = .{
            .command_length = @intCast(call.command.len),
            .timeout_ms = call.timeout_ms,
        };
        @memcpy(result.command[0..call.command.len], call.command);
        return result;
    }

    pub fn commandSlice(self: *const BashCallMaterial) []const u8 {
        return self.command[0..self.command_length];
    }
};

pub const ActionMaterial = union(enum) {
    bash: struct {
        descriptor_ref: u64,
        call: BashCallMaterial,
    },
    apply_patch: PatchContent,
};

pub const ModelCompletionConsequence = union(enum) {
    final_answer: struct { content_ref: u64 },
    tool_call: struct {
        content_ref: u64,
        action: ?ActionMaterial = null,
    },
    terminal,
};

pub const ModelCompletionMaterial = struct {
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
    evidence_epoch: u64,
    response_ref: u64,
    response_digest: binding.Result,
    admission: model_protocol.Admission,
    consequence: ModelCompletionConsequence,
};

pub const ToolResultMaterial = struct {
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
    result_ref: u64,
    result_digest: binding.Result,
    visible_ref: u64,
};

comptime {
    std.debug.assert(4 <= session_transition.max_facts);
}

pub const Control = enum { cancel, shutdown };

pub const AuthorizationMaterial = struct {
    operation_id: u64,
    operation_generation: u32,
    permission_ref: u64,
    allowed: bool,
};

pub const ActionAttemptMaterial = struct {
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
};

pub const ActionResultEvidence = union(enum) {
    immediate,
    durable: struct {
        attempt_id: u64,
        ownership_epoch: u64,
    },
};

pub const ActionResultMaterial = struct {
    operation_id: u64,
    operation_generation: u32,
    result_ref: u64,
    result_digest: binding.Result,
    class: session_transition.ResultClass,
    evidence: ActionResultEvidence,
};

pub const EntryKind = session_transition.ConversationKind;

pub const ConversationEntry = struct {
    kind: EntryKind,
    session_id: u64,
    entry_id: u64,
    parent_id: u64,
    task_id: u64,
    content_ref: u64,
    sequence: u64,
};

pub const OperationPhase = continuation.OperationPhase;
pub const TaskPhase = continuation.TaskPhase;
pub const ContentWindow = continuation.ContentWindow;
pub const StrictToolJsonWindow = continuation.StrictToolJsonWindow;
pub const Operation = continuation.Operation;
pub const ModelContext = continuation.ModelContext;
pub const Response = continuation.Response;
pub const Task = continuation.Task;

pub const ContinuationView = struct {
    operation: Operation,
    task: Task,
    response: Response,
};

pub const ActionIdentity = struct {
    operation_id: u64,
    operation_generation: u32,
};

pub const ModelCompletionAdmission = struct {
    response: Response,
    action: ?ActionIdentity,
};

pub const ApprovalRequest = struct {
    operation_id: u64,
    operation_generation: u32,
    descriptor_digest: binding.Descriptor,
    descriptor_ref: u64,
};

const ApprovalRefs = struct {
    binding: u64,
    descriptor: u64,
};

pub const FailureObservation = struct {
    response_ref: u64,
    failure: model_protocol.Failure,
};

pub const OperationView = struct {
    const max_attempts = session_transition.max_operation_attempts;

    operation_id: u64 = 0,
    generation: u32 = 0,
    descriptor: ?session_transition.OperationRecord = null,
    attempts: [max_attempts]?session_transition.AttemptRecord = @splat(null),
    attempt_count: u8 = 0,
    approval_required: ?session_transition.ApprovalRequiredRecord = null,
    authorization: ?session_transition.AuthorizationRecord = null,
    result: ?session_transition.ResultRecord = null,
    terminal_result_sequence: ?u64 = null,

    fn accepts(self: OperationView, operation: session_transition.OperationContext) bool {
        return self.operation_id == operation.operation_id and self.generation == operation.generation;
    }

    fn appendAttempt(self: *OperationView, attempt: session_transition.AttemptRecord) !void {
        for (self.attempts[0..self.attempt_count]) |maybe_existing| {
            const existing = maybe_existing.?;
            if (existing.attempt_id != attempt.attempt_id) continue;
            if (!std.meta.eql(existing, attempt)) return error.ConflictingLedgerFacts;
            return;
        }
        const descriptor_kind = std.meta.activeTag(attempt.descriptor_digest);
        if ((descriptor_kind == .model and
            attempt.possible_duplicate_attempts != self.attempt_count) or
            (descriptor_kind != .model and attempt.possible_duplicate_attempts != 0))
        {
            return error.InvalidAttemptDuplicateAccounting;
        }
        if (self.attempt_count == max_attempts) return error.AttemptCapacityExceeded;
        self.attempts[self.attempt_count] = attempt;
        self.attempt_count += 1;
    }

    pub fn findAttempt(self: OperationView, attempt_id: u64) ?session_transition.AttemptRecord {
        for (self.attempts[0..self.attempt_count]) |maybe_attempt| {
            const attempt = maybe_attempt.?;
            if (attempt.attempt_id == attempt_id) return attempt;
        }
        return null;
    }

    pub fn attemptSlice(self: *const OperationView) []const ?session_transition.AttemptRecord {
        return self.attempts[0..self.attempt_count];
    }

    pub fn latestAttempt(self: *const OperationView) ?session_transition.AttemptRecord {
        if (self.attempt_count == 0) return null;
        return self.attempts[self.attempt_count - 1];
    }

    pub fn containsAttempt(self: *const OperationView, attempt_id: u64) bool {
        return self.findAttempt(attempt_id) != null;
    }

    pub fn kind(self: *const OperationView) ?binding.DescriptorKind {
        const descriptor = self.descriptor orelse return null;
        return std.meta.activeTag(descriptor.descriptor_digest);
    }
};

pub const SemanticView = struct {
    last_sequence: u64 = 0,
    last_core: ?[session_transition.continuation_size]u8 = null,
    maximum_operation_id: u64 = 0,
    model: OperationView = .{},
    consequential: OperationView = .{},
    control: ?session_transition.Fact = null,
    indeterminate: ?session_transition.ResultRecord = null,

    fn apply(self: *SemanticView, transaction: session_transition.Transaction) !void {
        if (transaction.sequence != self.last_sequence + 1) return error.NonmonotonicSequence;
        for (transaction.factSlice()) |fact| {
            switch (fact) {
                .operation_admitted => |record| {
                    if (record.operation.operation_id <= self.maximum_operation_id) {
                        return error.OperationIdentityCollision;
                    }
                    const descriptor_kind = std.meta.activeTag(record.descriptor_digest);
                    switch (descriptor_kind) {
                        .model => {
                            if (record.source_operation != null) return error.InvalidSourceOperation;
                            if (self.consequential.descriptor != null and
                                self.consequential.accepts(record.operation))
                            {
                                return error.OperationIdentityCollision;
                            }
                        },
                        .bash, .apply_patch => {
                            const source = record.source_operation orelse
                                return error.InvalidSourceOperation;
                            if (self.model.descriptor == null or
                                self.model.operation_id != source.operation_id or
                                self.model.generation != source.generation)
                            {
                                return error.InvalidSourceOperation;
                            }
                            if (self.model.accepts(record.operation)) {
                                return error.OperationIdentityCollision;
                            }
                        },
                    }
                    const history = historyForDescriptor(self, record.descriptor_digest);
                    if (!history.accepts(record.operation)) history.* = .{
                        .operation_id = record.operation.operation_id,
                        .generation = record.operation.generation,
                    };
                    history.descriptor = try uniqueValue(
                        session_transition.OperationRecord,
                        history.descriptor,
                        record,
                    );
                    self.maximum_operation_id = record.operation.operation_id;
                },
                .attempt_admitted => |record| {
                    const history = self.operationMut(record.operation) orelse
                        return error.InvalidOperationHistory;
                    const descriptor = history.descriptor orelse return error.InvalidOperationHistory;
                    if (record.descriptor_ref != descriptor.descriptor_ref or
                        !binding.descriptorEql(record.descriptor_digest, descriptor.descriptor_digest))
                    {
                        return error.AttemptDescriptorMismatch;
                    }
                    try history.appendAttempt(record);
                },
                .approval_required => |record| {
                    const history = self.operationMut(record.operation) orelse
                        return error.InvalidOperationHistory;
                    if (!history.accepts(record.operation)) return error.InvalidOperationHistory;
                    const descriptor = history.descriptor orelse return error.InvalidOperationHistory;
                    switch (descriptor.descriptor_digest) {
                        .model => return error.InvalidApprovalDescriptor,
                        .bash => if (record.binding_ref != 0 or
                            record.descriptor_ref != descriptor.descriptor_ref)
                        {
                            return error.ApprovalDescriptorMismatch;
                        },
                        .apply_patch => if (record.binding_ref != descriptor.descriptor_ref) {
                            return error.ApprovalDescriptorMismatch;
                        },
                    }
                    history.approval_required = try uniqueValue(
                        session_transition.ApprovalRequiredRecord,
                        history.approval_required,
                        record,
                    );
                },
                .authorization => |record| {
                    const history = self.operationMut(record.operation) orelse
                        return error.InvalidOperationHistory;
                    if (!history.accepts(record.operation)) return error.InvalidOperationHistory;
                    const descriptor = history.descriptor orelse return error.InvalidOperationHistory;
                    switch (descriptor.descriptor_digest) {
                        .model => return error.InvalidAuthorizationDescriptor,
                        .bash => if (record.permission_ref != 0) {
                            return error.AuthorizationDescriptorMismatch;
                        },
                        .apply_patch => if (record.permission_ref != descriptor.descriptor_ref) {
                            return error.AuthorizationDescriptorMismatch;
                        },
                    }
                    history.authorization = record;
                },
                .result => |record| {
                    const history = self.operationMut(record.operation) orelse
                        return error.InvalidOperationHistory;
                    const descriptor = history.descriptor orelse return error.InvalidOperationHistory;
                    const descriptor_kind = std.meta.activeTag(descriptor.descriptor_digest);
                    switch (record.evidence) {
                        .immediate => {},
                        .durable => |evidence| if (std.meta.activeTag(evidence) != descriptor_kind) {
                            return error.InvalidOperationResultKind;
                        },
                    }
                    if (!history.accepts(record.operation)) return error.InvalidOperationHistory;
                    const first_terminal = history.result == null;
                    history.result = try uniqueValue(
                        session_transition.ResultRecord,
                        history.result,
                        record,
                    );
                    if (first_terminal) {
                        history.terminal_result_sequence = transaction.sequence;
                    } else if (history.terminal_result_sequence == null) {
                        return error.MissingTerminalResultSequence;
                    }
                    if (descriptor_kind != .model and
                        record.class == .indeterminate)
                    {
                        self.indeterminate = record;
                    }
                },
                .result_applied => |record| {
                    const history = self.operationMut(record.operation) orelse
                        return error.InvalidOperationHistory;
                    const result = history.result orelse return error.InvalidOperationHistory;
                    if (result.result_ref != record.result_ref or
                        !binding.eql(binding.Result, result.result_digest, record.result_digest) or
                        resultAttemptId(result) != record.attempt_id)
                    {
                        return error.ResultApplicationMismatch;
                    }
                },
                .cancellation, .shutdown => self.control = fact,
                .task_admitted, .conversation_advanced, .outcome => {},
            }
        }
        if (transaction.core) |state| {
            _ = try continuation.decode(&state);
            self.last_core = state;
        }
        self.last_sequence = transaction.sequence;
    }

    pub fn operation(self: *const SemanticView, operation_context: session_transition.OperationContext) ?OperationView {
        if (self.model.accepts(operation_context)) return self.model;
        if (self.consequential.accepts(operation_context)) return self.consequential;
        return null;
    }

    fn operationMut(self: *SemanticView, operation_context: session_transition.OperationContext) ?*OperationView {
        if (self.model.accepts(operation_context)) return &self.model;
        if (self.consequential.accepts(operation_context)) return &self.consequential;
        return null;
    }

    pub fn openOperation(self: *const SemanticView) ?OperationView {
        if (self.consequential.descriptor != null and self.consequential.result == null) {
            return self.consequential;
        }
        if (self.model.descriptor != null and self.model.result == null) return self.model;
        return null;
    }
};

fn historyForDescriptor(index: *SemanticView, descriptor: binding.Descriptor) *OperationView {
    return switch (descriptor) {
        .model => &index.model,
        .bash, .apply_patch => &index.consequential,
    };
}

fn resultAttemptId(result: session_transition.ResultRecord) u64 {
    return switch (result.evidence) {
        .immediate => 0,
        .durable => |evidence| switch (evidence) {
            inline else => |attempt_id| attempt_id,
        },
    };
}

fn uniqueValue(comptime T: type, existing: ?T, candidate: T) !T {
    if (existing) |value| {
        if (!std.meta.eql(value, candidate)) return error.ConflictingLedgerFacts;
        return value;
    }
    return candidate;
}

pub const RecoveryProgress = struct {
    processed: u8,
    more: bool,
};

const InboxIndex = struct {
    const capacity = OperationView.max_attempts * 2;
    entries: [capacity]?completion_inbox.Envelope = @splat(null),
    ambiguous: [capacity]?AttemptKey = @splat(null),

    const AttemptKey = struct {
        kind: completion_inbox.EvidenceKind,
        operation_id: u64,
        operation_generation: u32,
        attempt_id: u64,

        fn fromEnvelope(envelope: completion_inbox.Envelope) AttemptKey {
            return .{
                .kind = envelope.kind,
                .operation_id = envelope.operation_id,
                .operation_generation = envelope.operation_generation,
                .attempt_id = envelope.attempt_id,
            };
        }

        fn matches(self: AttemptKey, envelope: completion_inbox.Envelope) bool {
            return self.kind == envelope.kind and self.operation_id == envelope.operation_id and
                self.operation_generation == envelope.operation_generation and
                self.attempt_id == envelope.attempt_id;
        }
    };

    const Disposition = union(enum) {
        irrelevant,
        duplicate,
        audit: u64,
        persist,
    };

    fn apply(
        self: *InboxIndex,
        semantic: *const SemanticView,
        envelope: completion_inbox.Envelope,
        session_id: u64,
        agent_id: u64,
        ownership_epoch: u64,
    ) !Disposition {
        if (envelope.session_id != session_id or envelope.agent_id != agent_id or
            envelope.agent_generation != 1 or envelope.ownership_epoch > ownership_epoch)
        {
            return .irrelevant;
        }
        const history = historyForIdentity(
            semantic,
            envelope.operation_id,
            envelope.operation_generation,
        ) orelse return .irrelevant;
        if (history.operation_id != envelope.operation_id or
            history.generation != envelope.operation_generation)
        {
            return .irrelevant;
        }
        const attempt = history.findAttempt(envelope.attempt_id) orelse return .irrelevant;
        if (envelope.ownership_epoch != attempt.operation.agent.ownership_epoch) {
            return error.CompletionAttemptEpochMismatch;
        }
        if (envelope.kind != (history.kind() orelse return error.MissingOperationDescriptor)) {
            return error.CompletionEvidenceKindMismatch;
        }
        if (history.result != null) return .{
            .audit = history.terminal_result_sequence orelse
                return error.MissingTerminalResultSequence,
        };
        var ambiguous_slot: ?*?AttemptKey = null;
        for (&self.ambiguous) |*slot| {
            const key = slot.* orelse {
                if (ambiguous_slot == null) ambiguous_slot = slot;
                continue;
            };
            if (!keyIsRelevant(semantic, key)) {
                if (ambiguous_slot == null) ambiguous_slot = slot;
                continue;
            }
            if (key.matches(envelope)) return .duplicate;
        }
        var available: ?*?completion_inbox.Envelope = null;
        for (&self.entries) |*slot| {
            const existing = slot.* orelse {
                if (available == null) available = slot;
                continue;
            };
            const existing_history = historyForIdentity(
                semantic,
                existing.operation_id,
                existing.operation_generation,
            ) orelse {
                if (available == null) available = slot;
                continue;
            };
            if (!attemptMatchesKind(existing_history, existing.attempt_id, existing.kind)) {
                if (available == null) available = slot;
                continue;
            }
            if (existing.operation_id == envelope.operation_id and
                existing.operation_generation == envelope.operation_generation and
                existing.attempt_id == envelope.attempt_id)
            {
                if (std.meta.eql(existing, envelope)) return .duplicate;
                slot.* = null;
                const destination = ambiguous_slot orelse
                    return error.InboxSemanticCapacityExceeded;
                destination.* = AttemptKey.fromEnvelope(envelope);
                return .persist;
            }
        }
        const slot = available orelse return error.InboxSemanticCapacityExceeded;
        slot.* = envelope;
        return .persist;
    }

    fn prune(self: *InboxIndex, semantic: *const SemanticView) void {
        for (&self.entries) |*slot| {
            const envelope = slot.* orelse continue;
            if (!envelopeIsPending(semantic, envelope)) slot.* = null;
        }
        for (&self.ambiguous) |*slot| {
            const key = slot.* orelse continue;
            if (!keyIsPending(semantic, key)) slot.* = null;
        }
    }

    fn historyForIdentity(
        semantic: *const SemanticView,
        operation_id: u64,
        operation_generation: u32,
    ) ?OperationView {
        if (semantic.model.operation_id == operation_id and
            semantic.model.generation == operation_generation) return semantic.model;
        if (semantic.consequential.operation_id == operation_id and
            semantic.consequential.generation == operation_generation) return semantic.consequential;
        return null;
    }

    fn keyIsRelevant(semantic: *const SemanticView, key: AttemptKey) bool {
        const history = historyForIdentity(
            semantic,
            key.operation_id,
            key.operation_generation,
        ) orelse return false;
        return attemptMatchesKind(history, key.attempt_id, key.kind);
    }

    fn envelopeIsPending(semantic: *const SemanticView, envelope: completion_inbox.Envelope) bool {
        const history = historyForIdentity(
            semantic,
            envelope.operation_id,
            envelope.operation_generation,
        ) orelse return false;
        return history.result == null and
            attemptMatchesKind(history, envelope.attempt_id, envelope.kind);
    }

    fn keyIsPending(semantic: *const SemanticView, key: AttemptKey) bool {
        const history = historyForIdentity(
            semantic,
            key.operation_id,
            key.operation_generation,
        ) orelse return false;
        return history.result == null and
            attemptMatchesKind(history, key.attempt_id, key.kind);
    }

    fn attemptMatchesKind(
        history: OperationView,
        attempt_id: u64,
        kind: completion_inbox.EvidenceKind,
    ) bool {
        if (!history.containsAttempt(attempt_id)) return false;
        return history.kind() == kind;
    }
};

const ResidentState = struct {
    semantic: SemanticView = .{},
    inbox: InboxIndex = .{},
    conversation_head_id: u64 = 0,
    conversation_head_kind: ?EntryKind = null,

    fn applyingLedger(
        self: ResidentState,
        transaction: session_transition.Transaction,
        agent_id: u64,
        ownership_epoch: u64,
    ) !ResidentState {
        var next = self;
        for (transaction.factSlice()) |fact| {
            const agent = fact.agent();
            if (agent.agent_id != agent_id or agent.agent_generation != 1 or
                agent.ownership_epoch > ownership_epoch)
            {
                return error.InvalidSessionFactIdentity;
            }
        }
        try next.semantic.apply(transaction);
        for (transaction.factSlice()) |fact| switch (fact) {
            .conversation_advanced => |advanced| {
                if (next.conversation_head_id == std.math.maxInt(u64)) {
                    return error.EntryIdentityExhausted;
                }
                if (advanced.entry_id != next.conversation_head_id + 1 or
                    advanced.parent_id != next.conversation_head_id)
                {
                    return error.ConversationLedgerGap;
                }
                if (next.conversation_head_kind == null) {
                    if (advanced.entry_id != 1 or advanced.parent_id != 0 or
                        advanced.kind != .user_text) return error.InvalidConversationGrammar;
                } else {
                    const parent_kind = next.conversation_head_kind.?;
                    if ((parent_kind == .tool_call) != (advanced.kind == .tool_result) or
                        (advanced.kind == .tool_call and parent_kind == .tool_call))
                    {
                        return error.InvalidConversationGrammar;
                    }
                }
                next.conversation_head_id = advanced.entry_id;
                next.conversation_head_kind = advanced.kind;
            },
            .task_admitted,
            .operation_admitted,
            .attempt_admitted,
            .authorization,
            .result,
            .outcome,
            .cancellation,
            .shutdown,
            .result_applied,
            .approval_required,
            => {},
        };
        next.inbox.prune(&next.semantic);
        return next;
    }

    fn applyingCompletion(
        self: ResidentState,
        envelope: completion_inbox.Envelope,
        session_id: u64,
        agent_id: u64,
        ownership_epoch: u64,
    ) !struct { state: ResidentState, disposition: InboxIndex.Disposition } {
        var next = self;
        const disposition = try next.inbox.apply(
            &next.semantic,
            envelope,
            session_id,
            agent_id,
            ownership_epoch,
        );
        return .{ .state = next, .disposition = disposition };
    }
};

const Recovery = union(enum) {
    ready,
    pending,
    ledger: struct {
        next_sequence: u64,
        ledger_head: u64,
        inbox_watermark: u64,
    },
    inbox: struct {
        after_id: u64,
        watermark: u64,
        ledger_head: u64,
    },
    historical: struct {
        completion: host_store.StoredCompletion,
        watermark: u64,
        ledger_head: u64,
        scan: host_store.CompletedAttemptScan,
    },
};

pub const AppendBoundary = enum {
    after_entry_sync,
};

pub const FaultHook = struct {
    context: *anyopaque,
    reached: *const fn (*anyopaque, AppendBoundary) anyerror!void,
};

pub const ContentWriter = struct {
    session: *Session,
    reference: u64,
    slot_index: usize,
    start_offset: u64,
    length_value: u64 = 0,
    hasher: binding.Hasher(binding.Blob) = .init(),
    open: bool = true,

    pub fn append(self: *ContentWriter, bytes: []const u8) !void {
        if (!self.open) return error.ContentWriterClosed;
        try self.session.ensureUsable();
        if (bytes.len == 0) return;
        if (self.length_value + bytes.len > host_store.max_content_bytes) {
            return error.ContentTooLarge;
        }
        const scratch = transientScratchState(self.session.scratch);
        const file = scratch.file orelse return error.TransientScratchUnavailable;
        if (self.start_offset + self.length_value + bytes.len > max_transient_scratch_bytes) {
            return error.TransientScratchCapacityExceeded;
        }
        try file.writePositionalAll(
            self.session.io,
            bytes,
            self.start_offset + self.length_value,
        );
        self.hasher.update(bytes);
        self.length_value += bytes.len;
    }

    pub fn finish(self: *ContentWriter) !void {
        if (!self.open) return error.ContentWriterClosed;
        try self.session.ensureUsable();
        if (self.length_value == 0) return error.EmptyContent;
        try self.session.installPendingContent(.{
            .reference = self.reference,
            .offset = self.start_offset,
            .length = self.length_value,
            .digest = self.hasher.final(),
        }, self.slot_index);
        const scratch = transientScratchState(self.session.scratch);
        scratch.writer_open = false;
        self.open = false;
    }

    pub fn abort(self: *ContentWriter) void {
        if (!self.open) return;
        const scratch = transientScratchState(self.session.scratch);
        scratch.writer_open = false;
        self.open = false;
    }
};

pub const ContentView = struct {
    source: union(enum) {
        durable: struct {
            storage: *host_store.StorageOwner,
            session_id: u64,
        },
        pending: struct {
            session: *Session,
            offset: u64,
        },
    },
    reference: u64,
    meta: host_store.ContentMetadata,

    pub fn length(self: *const ContentView) u64 {
        return self.meta.length;
    }

    pub fn digest(self: *const ContentView) binding.Blob {
        return self.meta.digest;
    }

    pub fn readWindow(self: *ContentView, offset: u64, out: []u8) ![]const u8 {
        if (offset > self.meta.length) return error.InvalidContentOffset;
        const wanted: usize = @intCast(@min(self.meta.length - offset, out.len));
        return switch (self.source) {
            .durable => |durable| durable.storage.readContentWindow(
                durable.session_id,
                self.reference,
                offset,
                out,
            ),
            .pending => |pending| blk: {
                try pending.session.ensureUsable();
                const file = transientScratchState(pending.session.scratch).file orelse
                    return error.TransientScratchUnavailable;
                const actual = try file.readPositionalAll(
                    pending.session.io,
                    out[0..wanted],
                    pending.offset + offset,
                );
                if (actual != wanted) return error.TruncatedContent;
                break :blk out[0..actual];
            },
        };
    }
};

const PendingContent = struct {
    reference: u64,
    offset: u64,
    length: u64,
    digest: binding.Blob,
};

/// Opaque borrowed capability for one live Harness's bounded, non-authoritative
/// capture scratch. Only the Harness that allocated it may destroy it; Session
/// receives a pointer and can neither copy nor free the file-owning state.
pub const TransientScratch = opaque {};

const TransientScratchState = struct {
    bound: bool = false,
    file: ?std.Io.File = null,
    writer_open: bool = false,
    pending: [max_pending_content]?PendingContent = @splat(null),
};

pub const transient_scratch_allocation_bytes = @sizeOf(TransientScratchState);

pub fn allocateTransientScratch(allocator: std.mem.Allocator) !*TransientScratch {
    const state = try allocator.create(TransientScratchState);
    state.* = .{};
    return @ptrCast(state);
}

/// Frees the Harness-local allocation. The owning Harness must first close its
/// Session; this function also defensively closes any scratch left by a failed
/// construction path.
pub fn destroyTransientScratch(
    allocator: std.mem.Allocator,
    io: std.Io,
    scratch: *TransientScratch,
) void {
    const state = transientScratchState(scratch);
    if (state.file) |file| file.close(io);
    state.* = .{};
    allocator.destroy(state);
}

/// Test-only fault injection: makes an in-flight writer's scratch backing
/// unavailable without exposing the file-owning state itself.
pub fn closeTransientScratchForTest(session: *Session) void {
    const scratch = transientScratchState(session.scratch);
    if (scratch.file) |file| file.close(session.io);
    scratch.file = null;
    scratch.writer_open = false;
}

fn transientScratchState(scratch: *TransientScratch) *TransientScratchState {
    return @ptrCast(@alignCast(scratch));
}

fn bindTransientScratch(scratch: *TransientScratch) !void {
    const state = transientScratchState(scratch);
    if (state.bound) return error.TransientScratchAlreadyBound;
    state.* = .{ .bound = true };
}

fn ensureTransientScratchBound(scratch: *TransientScratch) !void {
    if (!transientScratchState(scratch).bound) return error.TransientScratchUnavailable;
}

fn releaseTransientScratch(scratch: *TransientScratch, io: std.Io) void {
    const state = transientScratchState(scratch);
    if (!state.bound) return;
    if (state.file) |file| file.close(io);
    state.* = .{};
}

fn readExactConversationWindow(reader: *ContentView, offset: u64, out: []u8) !void {
    if ((try reader.readWindow(offset, out)).len != out.len) return error.InvalidConversationContent;
}

fn validateUtf8ConversationWindows(reader: *ContentView, start: u64, length: u64) !void {
    var window: [4096]u8 = undefined;
    var sequence: [4]u8 = undefined;
    var sequence_length: u3 = 0;
    var sequence_size: u3 = 0;
    var consumed: u64 = 0;
    while (consumed < length) {
        const wanted: usize = @intCast(@min(length - consumed, window.len));
        const bytes = try reader.readWindow(start + consumed, window[0..wanted]);
        if (bytes.len != wanted) return error.InvalidConversationContent;
        for (bytes) |byte| {
            if (sequence_length == 0) {
                const size = std.unicode.utf8ByteSequenceLength(byte) catch
                    return error.InvalidConversationContent;
                if (size == 1) continue;
                sequence[0] = byte;
                sequence_length = 1;
                sequence_size = @intCast(size);
            } else {
                sequence[sequence_length] = byte;
                sequence_length += 1;
                if (sequence_length == sequence_size) {
                    if (!std.unicode.utf8ValidateSlice(sequence[0..sequence_size])) {
                        return error.InvalidConversationContent;
                    }
                    sequence_length = 0;
                    sequence_size = 0;
                }
            }
        }
        consumed += bytes.len;
    }
    if (sequence_length != 0) return error.InvalidConversationContent;
}

pub const Session = struct {
    io: std.Io,
    scratch_root: std.Io.Dir,
    scratch: *TransientScratch,
    storage: *host_store.StorageOwner,
    session_id: u64,
    agent_id: u64,
    task_id: u64,
    ownership_epoch: u64,
    pending_conversation: ?ConversationEntry = null,
    resident: ResidentState = .{},
    recovery: Recovery = .ready,
    workspace_path: [workspace_path_capacity]u8 = undefined,
    workspace_path_length: u16,
    model_name: [model_name_capacity]u8 = undefined,
    model_name_length: u8,
    open: bool = true,
    failed: bool = false,

    pub fn create(
        root: std.Io.Dir,
        scratch: *TransientScratch,
        storage: *host_store.StorageOwner,
        io: std.Io,
        config: Config,
    ) !Session {
        for (0..8) |_| {
            var identities: Identities = undefined;
            io.random(std.mem.asBytes(&identities));
            identities.validate() catch continue;
            return createExact(root, scratch, storage, io, .{
                .identities = identities,
                .workspace_path = config.workspace_path,
                .model = config.model,
                .task = config.task,
            }) catch |err| switch (err) {
                error.HostStoreConstraint => continue,
                else => return err,
            };
        }
        return error.IdentityAllocationExhausted;
    }

    fn createExact(
        root: std.Io.Dir,
        scratch: *TransientScratch,
        storage: *host_store.StorageOwner,
        io: std.Io,
        config: CreateConfig,
    ) !Session {
        try config.identities.validate();
        if (config.workspace_path.len == 0 or config.workspace_path.len > workspace_path_capacity or
            config.model.len == 0 or config.model.len > model_name_capacity or
            !std.unicode.utf8ValidateSlice(config.model) or
            config.task.len == 0 or config.task.len > conversation.max_result_content_size or
            !std.unicode.utf8ValidateSlice(config.task))
        {
            return error.InvalidSessionMetadata;
        }
        try validateWorkspace(io, config.workspace_path);
        var canonical_workspace_buffer: [workspace_path_capacity]u8 = undefined;
        const canonical_workspace_length = try std.Io.Dir.cwd().realPathFile(
            io,
            config.workspace_path,
            &canonical_workspace_buffer,
        );
        if (canonical_workspace_length == 0 or canonical_workspace_length > workspace_path_capacity) {
            return error.InvalidSessionMetadata;
        }
        const canonical_workspace = canonical_workspace_buffer[0..canonical_workspace_length];

        const agent: session_transition.AgentContext = .{
            .agent_id = config.identities.agent_id,
            .agent_generation = 1,
            .ownership_epoch = 1,
        };
        var initial: session_transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
        initial.facts[0] = session_transition.conversationAdvanced(
            .{
                .agent = agent,
                .entry_id = 1,
                .parent_id = 0,
                .kind = .user_text,
                .content_ref = config.identities.task_id,
            },
        );

        try bindTransientScratch(scratch);
        errdefer releaseTransientScratch(scratch, io);
        var created: Session = .{
            .io = io,
            .scratch_root = root,
            .scratch = scratch,
            .storage = storage,
            .session_id = config.identities.session_id,
            .agent_id = config.identities.agent_id,
            .task_id = config.identities.task_id,
            .ownership_epoch = 1,
            .workspace_path_length = @intCast(canonical_workspace.len),
            .model_name_length = @intCast(config.model.len),
        };
        @memcpy(created.workspace_path[0..canonical_workspace.len], canonical_workspace);
        @memcpy(created.model_name[0..config.model.len], config.model);
        created.resident = try created.resident.applyingLedger(initial, created.agent_id, created.ownership_epoch);

        try storage.createSessionWithContent(.{
            .identities = .{
                .session_id = config.identities.session_id,
                .agent_id = config.identities.agent_id,
                .task_id = config.identities.task_id,
            },
            .workspace_path = canonical_workspace,
            .model = config.model,
        }, initial, .{
            .reference = config.identities.task_id,
            .length = config.task.len,
            .digest = binding.hash(binding.Blob, config.task),
            .source = .{ .bytes = config.task },
        });
        return created;
    }

    pub fn openExisting(
        root: std.Io.Dir,
        scratch: *TransientScratch,
        storage: *host_store.StorageOwner,
        io: std.Io,
        session_id: u64,
    ) !Session {
        if (session_id == 0) return error.InvalidIdentity;
        try bindTransientScratch(scratch);
        errdefer releaseTransientScratch(scratch, io);
        var stored = try storage.readSession(session_id);
        try validateWorkspace(io, stored.workspacePath());
        stored.ownership_epoch = try storage.claimSession(session_id);
        return fromStored(io, storage, root, scratch, stored, false);
    }

    fn fromStored(
        io: std.Io,
        storage: *host_store.StorageOwner,
        scratch_root: std.Io.Dir,
        scratch: *TransientScratch,
        stored: host_store.StoredSession,
        recovery_complete: bool,
    ) Session {
        std.debug.assert(stored.workspacePath().len <= workspace_path_capacity);
        var session: Session = .{
            .io = io,
            .scratch_root = scratch_root,
            .scratch = scratch,
            .storage = storage,
            .session_id = stored.identities.session_id,
            .agent_id = stored.identities.agent_id,
            .task_id = stored.identities.task_id,
            .ownership_epoch = stored.ownership_epoch,
            .workspace_path_length = stored.workspace_path_length,
            .model_name_length = stored.model_length,
            .recovery = if (recovery_complete) .ready else .pending,
        };
        @memcpy(session.workspace_path[0..stored.workspace_path_length], stored.workspacePath());
        @memcpy(session.model_name[0..stored.model_length], stored.modelName());
        return session;
    }

    pub fn ownerToken(self: *const Session) OwnerToken {
        return .{ .session_id = self.session_id, .epoch = self.ownership_epoch };
    }

    pub fn workspacePath(self: *const Session) []const u8 {
        return self.workspace_path[0..self.workspace_path_length];
    }

    pub fn modelName(self: *const Session) []const u8 {
        return self.model_name[0..self.model_name_length];
    }

    pub fn recoveryIsEmpty(self: *Session) !bool {
        try self.ensureUsable();
        if (try self.storage.sessionHead(self.session_id) != 0) return false;
        return try self.storage.completionHead(self.session_id) == 0;
    }

    pub fn activeLeafId(self: *const Session) u64 {
        return self.resident.conversation_head_id;
    }

    pub fn entryCount(self: *const Session) u64 {
        return self.resident.conversation_head_id;
    }

    pub fn nextModelOperationId(self: *Session) !u64 {
        _ = try self.semanticView();
        return self.nextOperationId();
    }

    fn nextOperationId(self: *const Session) !u64 {
        return std.math.add(u64, self.resident.semantic.maximum_operation_id, 1) catch
            error.OperationIdentityExhausted;
    }

    fn authorize(self: *Session, token: OwnerToken) !void {
        if (!self.open) return error.SessionClosed;
        if (self.failed) return error.SessionUnavailable;
        if (token.session_id != self.session_id or token.epoch != self.ownership_epoch) {
            return error.StaleOwner;
        }
    }

    fn ensureUsable(self: *Session) !void {
        try self.authorize(self.ownerToken());
        try ensureTransientScratchBound(self.scratch);
    }

    pub fn appendConversationForTest(
        self: *Session,
        kind: EntryKind,
        content_ref: u64,
        fault: ?FaultHook,
    ) !ConversationEntry {
        if (!@import("builtin").is_test) @compileError("test-only Conversation preparation");
        if (content_ref == 0) return error.InvalidContentReference;
        try self.ensureUsable();
        return self.appendAuthorized(kind, content_ref, fault) catch |err| {
            self.failed = true;
            return err;
        };
    }

    fn appendAuthorized(
        self: *Session,
        kind: EntryKind,
        content_ref: u64,
        fault: ?FaultHook,
    ) !ConversationEntry {
        const conversation_head = self.resident.conversation_head_id;
        if (conversation_head == std.math.maxInt(u64)) return error.EntryIdentityExhausted;

        const entry: ConversationEntry = .{
            .kind = kind,
            .session_id = self.session_id,
            .entry_id = conversation_head + 1,
            .parent_id = conversation_head,
            .task_id = self.task_id,
            .content_ref = content_ref,
            .sequence = conversation_head + 1,
        };
        if (self.pending_conversation) |pending| {
            if (!std.meta.eql(pending, entry)) return error.UncommittedConversationConflict;
            return pending;
        }
        self.pending_conversation = entry;
        if (fault) |hook| try hook.reached(hook.context, .after_entry_sync);
        return entry;
    }

    fn validatePreparedConversationEntry(
        self: *Session,
        fact: session_transition.Fact,
    ) !void {
        const advanced = fact.conversation_advanced;
        const conversation_head = self.resident.conversation_head_id;
        if (advanced.entry_id != conversation_head + 1) return error.ConversationLedgerGap;
        const entry = self.pending_conversation orelse return error.MissingPreparedConversationEntry;
        if (entry.entry_id != advanced.entry_id or entry.sequence != advanced.entry_id or
            entry.parent_id != advanced.parent_id or entry.kind != advanced.kind or
            entry.parent_id != conversation_head or entry.content_ref != advanced.content_ref or
            entry.session_id != self.session_id or entry.task_id != self.task_id)
        {
            return error.ConversationLedgerMismatch;
        }
        try self.validateConversationContent(entry.kind, entry.content_ref, entry.parent_id);
    }

    fn verifyConversationEntry(
        self: *Session,
        advanced: session_transition.ConversationRecord,
    ) !void {
        const entry = try self.loadEntry(advanced.entry_id);
        if (entry.entry_id != advanced.entry_id or entry.sequence != advanced.entry_id or
            entry.parent_id != advanced.parent_id or entry.kind != advanced.kind or
            entry.parent_id != self.resident.conversation_head_id or
            entry.content_ref != advanced.content_ref or
            entry.session_id != self.session_id or entry.task_id != self.task_id)
        {
            return error.ConversationLedgerMismatch;
        }
        try self.validateConversationContent(entry.kind, entry.content_ref, entry.parent_id);
    }

    fn validateConversationContent(
        self: *Session,
        kind: EntryKind,
        content_ref: u64,
        parent_id: u64,
    ) !void {
        var reader = try self.viewContent(content_ref);
        const maximum: usize = switch (kind) {
            .tool_call => conversation.call_header_size + model_contract.max_tool_key_size +
                model_contract.max_tool_arguments_envelope_size,
            .tool_result => conversation.result_header_size + conversation.max_result_content_size,
            .user_text, .assistant_text => conversation.max_result_content_size,
        };
        if (reader.length() == 0 or reader.length() > maximum) return error.InvalidConversationContent;
        switch (kind) {
            .tool_call => {
                var header_bytes: [conversation.call_header_size]u8 = undefined;
                try readExactConversationWindow(&reader, 0, &header_bytes);
                const header = conversation.decodeToolCallHeader(&header_bytes, reader.length()) catch
                    return error.InvalidConversationContent;
                var key: [model_contract.max_tool_key_size]u8 = undefined;
                try readExactConversationWindow(
                    &reader,
                    conversation.call_header_size,
                    key[0..header.key_length],
                );
                model_contract.validateToolKey(key[0..header.key_length]) catch
                    return error.InvalidConversationContent;
                var hasher = binding.Hasher(binding.StrictToolJsonV1).init();
                var arguments_offset: u64 = conversation.call_header_size + header.key_length;
                var remaining: u64 = header.arguments_length;
                var window: [4096]u8 = undefined;
                while (remaining != 0) {
                    const wanted: usize = @intCast(@min(remaining, window.len));
                    const bytes = try reader.readWindow(arguments_offset, window[0..wanted]);
                    if (bytes.len != wanted) return error.InvalidConversationContent;
                    hasher.update(bytes);
                    arguments_offset += bytes.len;
                    remaining -= bytes.len;
                }
                if (!binding.eql(
                    binding.StrictToolJsonV1,
                    hasher.final(),
                    header.arguments_digest,
                )) return error.InvalidConversationContent;
            },
            .tool_result => {
                var header_bytes: [conversation.result_header_size]u8 = undefined;
                try readExactConversationWindow(&reader, 0, &header_bytes);
                const result = conversation.decodeToolResultHeader(&header_bytes, reader.length()) catch
                    return error.InvalidConversationContent;
                if (result.parent_id != parent_id) return error.InvalidConversationParent;
                try validateUtf8ConversationWindows(
                    &reader,
                    conversation.result_header_size,
                    result.content_length,
                );
            },
            .user_text, .assistant_text => try validateUtf8ConversationWindows(&reader, 0, reader.length()),
        }
    }

    pub fn readEntry(self: *Session, sequence: u64) !ConversationEntry {
        if (!self.open) return error.SessionClosed;
        if (sequence == 0 or sequence > self.resident.conversation_head_id) {
            return error.InvalidEntrySequence;
        }
        return self.loadEntry(sequence);
    }

    fn loadEntry(self: *Session, sequence: u64) !ConversationEntry {
        const stored = try self.storage.readConversationEntry(self.session_id, sequence);
        const kind = std.enums.fromInt(EntryKind, stored.kind) orelse return error.UnsupportedConversationKind;
        return .{
            .kind = kind,
            .session_id = self.session_id,
            .entry_id = stored.entry_id,
            .parent_id = stored.parent_id,
            .task_id = self.task_id,
            .content_ref = stored.content_ref,
            .sequence = stored.entry_id,
        };
    }

    pub fn storeContent(
        self: *Session,
        reference: u64,
        bytes: []const u8,
    ) !void {
        try self.ensureUsable();
        var writer = try self.beginContent(reference);
        errdefer writer.abort();
        try writer.append(bytes);
        try writer.finish();
    }

    pub fn beginContent(
        self: *Session,
        reference: u64,
    ) !ContentWriter {
        try self.ensureUsable();
        const scratch = transientScratchState(self.scratch);
        if (reference == 0) return error.InvalidContentReference;
        if (scratch.writer_open) return error.ContentWriterAlreadyOpen;
        if (self.findPendingContent(reference) != null) return error.ContentAlreadyExists;
        if (self.storage.contentMetadata(self.session_id, reference)) |_| {
            return error.ContentAlreadyExists;
        } else |err| switch (err) {
            error.ContentNotFound => {},
            else => return err,
        }
        var slot_index: ?usize = null;
        for (scratch.pending, 0..) |slot, index| if (slot == null) {
            slot_index = index;
            break;
        };
        const slot = slot_index orelse return error.PendingContentCapacityExceeded;
        if (scratch.file == null) {
            scratch.file = try createTransientScratch(self.scratch_root, self.io);
        }
        scratch.writer_open = true;
        return .{
            .session = self,
            .reference = reference,
            .slot_index = slot,
            .start_offset = slot * host_store.max_content_bytes,
        };
    }

    pub fn readContent(
        self: *Session,
        reference: u64,
        offset: u64,
        out: []u8,
    ) ![]const u8 {
        var reader = try self.viewContent(reference);
        return reader.readWindow(offset, out);
    }

    pub fn viewContent(
        self: *Session,
        reference: u64,
    ) !ContentView {
        try self.ensureUsable();
        if (self.findPendingContent(reference)) |pending| return .{
            .source = .{ .pending = .{ .session = self, .offset = pending.offset } },
            .reference = reference,
            .meta = .{ .length = pending.length, .digest = pending.digest },
        };
        return self.viewDurableContent(reference);
    }

    /// Open committed immutable content without retaining this Session or its
    /// transient scratch. The returned value remains usable until Host Runtime
    /// shutdown, even when the originating Harness has been consumed.
    pub fn viewDurableContent(self: *Session, reference: u64) !ContentView {
        try self.ensureUsable();
        const meta = self.storage.contentMetadata(self.session_id, reference) catch |err| switch (err) {
            error.ContentNotFound => return error.FileNotFound,
            else => return err,
        };
        return .{
            .source = .{ .durable = .{ .storage = self.storage, .session_id = self.session_id } },
            .reference = reference,
            .meta = meta,
        };
    }

    const ContentClosure = union(enum) {
        facts_only,
        patch_intent: PatchContent,
    };

    const CompiledAction = struct {
        descriptor_ref: u64,
        descriptor_digest: binding.Descriptor,
        content_closure: ContentClosure,
    };

    pub fn startTask(self: *Session, slot: *core_image.ActivationSlot) !u64 {
        defer core_image.scrub(slot);
        const committed = try continuation.initialize(.{ .agent_id = self.agent_id, .generation = 1 });
        const candidate = try continuation.startTask(committed, self.activeLeafId());
        const facts = [_]session_transition.Fact{session_transition.taskAdmitted(
            self.agentContext(),
            self.task_id,
            self.task_id,
        )};
        return self.commitContinuation(slot, candidate, &facts, .facts_only);
    }

    pub fn previewModelContext(
        self: *Session,
        slot: *core_image.ActivationSlot,
        operation_id: u64,
        sequence: u64,
    ) !ModelContext {
        defer core_image.scrub(slot);
        if (operation_id == 0 or operation_id <= self.resident.semantic.maximum_operation_id) {
            return error.InvalidOperationIdentity;
        }
        const committed = try self.loadContinuation(slot);
        return (try continuation.admitModelAttempt(committed, operation_id, sequence)).context;
    }

    pub fn admitModelAttempt(
        self: *Session,
        slot: *core_image.ActivationSlot,
        material: ModelAttemptMaterial,
    ) !Operation {
        defer core_image.scrub(slot);
        if (material.operation_id == 0 or
            material.operation_id <= self.resident.semantic.maximum_operation_id)
        {
            return error.InvalidOperationIdentity;
        }
        const committed = try self.loadContinuation(slot);
        const reduced = try continuation.admitModelAttempt(
            committed,
            material.operation_id,
            material.sequence,
        );
        const operation_context = self.operationContext(
            reduced.operation.id,
            reduced.operation.generation,
        );
        const descriptor: binding.Descriptor = .{ .model = material.request_digest };
        const facts = [_]session_transition.Fact{
            session_transition.operationAdmitted(
                operation_context,
                null,
                material.request_ref,
                descriptor,
            ),
            session_transition.modelAttemptAdmitted(
                operation_context,
                material.attempt_id,
                material.request_ref,
                descriptor,
                material.possible_duplicate_attempts,
            ),
        };
        _ = try self.commitContinuation(slot, reduced.state, &facts, .facts_only);
        return reduced.operation;
    }

    pub fn admitModelRetry(self: *Session, material: ModelAttemptMaterial) !u64 {
        const model = self.resident.semantic.model;
        const descriptor = model.descriptor orelse return error.MissingModelDescriptor;
        if (model.operation_id != material.operation_id or
            descriptor.descriptor_ref != material.request_ref or
            descriptor.descriptor_digest != .model or
            !binding.eql(
                binding.ModelDescriptor,
                descriptor.descriptor_digest.model,
                material.request_digest,
            ) or model.attempt_count != material.possible_duplicate_attempts)
        {
            return error.InvalidModelAttempt;
        }
        return self.commitDerived(&.{session_transition.modelAttemptAdmitted(
            self.operationContext(material.operation_id, model.generation),
            material.attempt_id,
            material.request_ref,
            .{ .model = material.request_digest },
            material.possible_duplicate_attempts,
        )}, null, .facts_only);
    }

    pub fn admitModelCompletion(
        self: *Session,
        slot: *core_image.ActivationSlot,
        material: ModelCompletionMaterial,
    ) !ModelCompletionAdmission {
        defer core_image.scrub(slot);
        const committed = try self.loadContinuation(slot);
        const model_history = self.resident.semantic.model;
        const attempt = model_history.findAttempt(material.attempt_id) orelse
            return error.InvalidAttemptHistory;
        if (attempt.operation.operation_id != material.operation_id or
            attempt.operation.generation != material.operation_generation or
            attempt.descriptor_ref == 0)
        {
            return error.InvalidAttemptHistory;
        }
        _ = try self.requirePendingCompletion(.model, attempt.operation, material.attempt_id, .{
            .ownership_epoch = material.evidence_epoch,
            .result_ref = material.response_ref,
            .result_digest = material.response_digest,
        });

        var facts: [4]session_transition.Fact = undefined;
        const operation = self.operationContext(material.operation_id, material.operation_generation);
        var evidence_operation = operation;
        evidence_operation.agent.ownership_epoch = material.evidence_epoch;
        facts[0] = session_transition.result(.{
            .operation = evidence_operation,
            .result_ref = material.response_ref,
            .result_digest = material.response_digest,
            .class = .ordinary,
            .evidence = .{ .durable = .{ .model = material.attempt_id } },
        });
        facts[1] = session_transition.resultApplied(.{
            .operation = operation,
            .attempt_id = material.attempt_id,
            .result_ref = material.response_ref,
            .result_digest = material.response_digest,
        });

        var fact_count: usize = 2;
        var closure: ContentClosure = .facts_only;
        var action_identity: ?ActionIdentity = null;
        const next_entry_id = std.math.add(u64, self.activeLeafId(), 1) catch
            return error.EntryIdentityExhausted;
        const consequence: continuation.CompletionConsequence = switch (material.consequence) {
            .final_answer => .{ .final_answer = next_entry_id },
            .tool_call => .tool_call,
            .terminal => .terminal,
        };
        const reduced = try continuation.admitModelCompletion(
            committed,
            .{ .id = material.operation_id, .generation = material.operation_generation },
            material.admission,
            material.response_ref,
            material.response_digest,
            consequence,
        );
        try self.validateCompletionContent(reduced.response, material.consequence);
        switch (material.consequence) {
            .final_answer => |final| {
                const entry = try self.appendAuthorized(.assistant_text, final.content_ref, null);
                std.debug.assert(entry.entry_id == next_entry_id);
                facts[fact_count] = self.conversationFact(entry);
                fact_count += 1;
                facts[fact_count] = session_transition.outcome(
                    self.agentContext(),
                    self.task_id,
                    final.content_ref,
                );
                fact_count += 1;
            },
            .tool_call => |tool| {
                const action = if (tool.action) |action|
                    try self.compileAction(reduced.response, action)
                else
                    null;
                const entry = try self.appendAuthorized(.tool_call, tool.content_ref, null);
                std.debug.assert(entry.entry_id == next_entry_id);
                if (action) |compiled| {
                    const action_id = try self.nextOperationId();
                    facts[fact_count] = session_transition.operationAdmitted(
                        self.operationContext(action_id, 1),
                        .{
                            .operation_id = material.operation_id,
                            .generation = material.operation_generation,
                        },
                        compiled.descriptor_ref,
                        compiled.descriptor_digest,
                    );
                    fact_count += 1;
                    closure = compiled.content_closure;
                    action_identity = .{
                        .operation_id = action_id,
                        .operation_generation = 1,
                    };
                }
                facts[fact_count] = self.conversationFact(entry);
                fact_count += 1;
            },
            .terminal => {},
        }
        _ = try self.commitContinuation(slot, reduced.state, facts[0..fact_count], closure);
        return .{ .response = reduced.response, .action = action_identity };
    }

    pub fn admitToolResult(
        self: *Session,
        slot: *core_image.ActivationSlot,
        material: ToolResultMaterial,
    ) !void {
        defer core_image.scrub(slot);
        const committed = try self.loadContinuation(slot);
        const operation = self.operationContext(material.operation_id, material.operation_generation);
        const history = self.resident.semantic.operation(operation) orelse
            return error.InvalidOperationHistory;
        const result = history.result orelse return error.InvalidOperationHistory;
        if (result.result_ref != material.result_ref or
            !binding.eql(binding.Result, result.result_digest, material.result_digest) or
            resultAttemptId(result) != material.attempt_id)
        {
            return error.ResultApplicationMismatch;
        }
        if (material.attempt_id != 0) {
            const attempt = history.findAttempt(material.attempt_id) orelse
                return error.InvalidAttemptHistory;
            if (attempt.operation.operation_id != operation.operation_id or
                attempt.operation.generation != operation.generation or
                attempt.operation.agent.agent_id != operation.agent.agent_id or
                attempt.operation.agent.agent_generation != operation.agent.agent_generation)
            {
                return error.InvalidAttemptHistory;
            }
        }
        const call_entry = try self.readEntry(self.activeLeafId());
        const next_entry_id = std.math.add(u64, call_entry.entry_id, 1) catch
            return error.EntryIdentityExhausted;
        const candidate = try continuation.admitToolResult(
            committed,
            call_entry.entry_id,
            next_entry_id,
        );
        const entry = try self.appendAuthorized(.tool_result, material.visible_ref, null);
        std.debug.assert(entry.entry_id == next_entry_id);
        const facts = [_]session_transition.Fact{
            session_transition.resultApplied(.{
                .operation = operation,
                .attempt_id = material.attempt_id,
                .result_ref = material.result_ref,
                .result_digest = material.result_digest,
            }),
            self.conversationFact(entry),
        };
        _ = try self.commitContinuation(slot, candidate, &facts, .facts_only);
    }

    pub fn continuationView(
        self: *Session,
        slot: *core_image.ActivationSlot,
    ) !ContinuationView {
        defer core_image.scrub(slot);
        const state = try self.loadContinuation(slot);
        return .{
            .operation = continuation.operation(state),
            .task = continuation.task(state),
            .response = continuation.response(state),
        };
    }

    pub fn failureObservation(self: *Session) !FailureObservation {
        const view = try self.semanticView();
        const encoded = view.last_core orelse return error.MissingLedgerCoreState;
        const state = try continuation.decode(&encoded);
        return .{ .response_ref = state.response_ref, .failure = state.response_failure };
    }

    pub fn commitControl(self: *Session, control: Control) !u64 {
        const fact = switch (control) {
            .cancel => session_transition.cancellation(self.agentContext()),
            .shutdown => session_transition.shutdown(self.agentContext()),
        };
        return self.commitDerived(&.{fact}, null, .facts_only);
    }

    pub fn requestApproval(
        self: *Session,
        operation_id: u64,
        operation_generation: u32,
    ) !ApprovalRequest {
        const operation = try self.requireActionOperation(
            operation_id,
            operation_generation,
        );
        const descriptor = operation.descriptor orelse return error.MissingActionDescriptor;
        const refs: ApprovalRefs = switch (descriptor.descriptor_digest) {
            .model => return error.InvalidActionDescriptor,
            .bash => |digest| blk: {
                var bytes: [bash_tool.max_descriptor_size]u8 = undefined;
                const content = try self.readBoundedContent(descriptor.descriptor_ref, &bytes);
                _ = try bash_tool.decodeDescriptor(content);
                if (!binding.eql(binding.BashDescriptor, bash_tool.descriptorDigest(content), digest)) {
                    return error.InvalidApprovalBinding;
                }
                break :blk .{ .binding = @as(u64, 0), .descriptor = descriptor.descriptor_ref };
            },
            .apply_patch => |digest| blk: {
                var intent_bytes: [patch_tool.max_intent_size]u8 = undefined;
                const bytes = try self.readBoundedContent(descriptor.descriptor_ref, &intent_bytes);
                const intent = try patch_tool.decodeIntent(bytes);
                if (!binding.eql(binding.PatchIntent, intent.intent_digest, digest)) {
                    return error.InvalidApprovalBinding;
                }
                var patch_bytes: [patch_tool.max_patch_size]u8 = undefined;
                const patch = try self.readBoundedContent(intent.patch_ref, &patch_bytes);
                if (!binding.eql(binding.PatchDescriptor, patch_tool.patchDigest(patch), intent.patch_digest)) {
                    return error.InvalidApprovalBinding;
                }
                break :blk .{ .binding = descriptor.descriptor_ref, .descriptor = intent.patch_ref };
            },
        };
        const record: session_transition.ApprovalRequiredRecord = .{
            .operation = self.operationContext(operation_id, operation_generation),
            .binding_ref = refs.binding,
            .descriptor_ref = refs.descriptor,
        };
        _ = try self.commitDerived(&.{session_transition.approvalRequired(record)}, null, .facts_only);
        return .{
            .operation_id = operation_id,
            .operation_generation = operation_generation,
            .descriptor_digest = descriptor.descriptor_digest,
            .descriptor_ref = refs.descriptor,
        };
    }

    pub fn authorizeAction(self: *Session, material: AuthorizationMaterial) !u64 {
        const operation = try self.requireActionOperation(
            material.operation_id,
            material.operation_generation,
        );
        const descriptor = operation.descriptor orelse return error.MissingActionDescriptor;
        if (material.permission_ref != 0 and material.permission_ref != descriptor.descriptor_ref) {
            return error.InvalidAuthorizationBinding;
        }
        return self.commitDerived(&.{session_transition.authorization(.{
            .operation = self.operationContext(material.operation_id, material.operation_generation),
            .permission_ref = material.permission_ref,
            .allowed = material.allowed,
        })}, null, .facts_only);
    }

    pub fn admitActionAttempt(self: *Session, material: ActionAttemptMaterial) !u64 {
        const operation = try self.requireActionOperation(
            material.operation_id,
            material.operation_generation,
        );
        const descriptor = operation.descriptor orelse return error.MissingActionDescriptor;
        return self.commitDerived(&.{session_transition.consequentialAttemptAdmitted(
            self.operationContext(material.operation_id, material.operation_generation),
            material.attempt_id,
            descriptor.descriptor_ref,
            descriptor.descriptor_digest,
        )}, null, .facts_only);
    }

    pub fn admitActionResult(self: *Session, material: ActionResultMaterial) !u64 {
        const operation = try self.requireActionOperation(
            material.operation_id,
            material.operation_generation,
        );
        const kind = operation.kind() orelse return error.MissingActionDescriptor;
        if (kind == .model) return error.InvalidActionDescriptor;
        var evidence_operation = self.operationContext(
            material.operation_id,
            material.operation_generation,
        );
        const evidence: session_transition.ResultEvidence = switch (material.evidence) {
            .immediate => .{ .immediate = {} },
            .durable => |durable| blk: {
                const attempt = operation.findAttempt(durable.attempt_id) orelse
                    return error.InvalidAttemptHistory;
                if (attempt.operation.operation_id != evidence_operation.operation_id or
                    attempt.operation.generation != evidence_operation.generation or
                    attempt.operation.agent.agent_id != evidence_operation.agent.agent_id or
                    attempt.operation.agent.agent_generation != evidence_operation.agent.agent_generation)
                {
                    return error.InvalidAttemptHistory;
                }
                _ = try self.requirePendingCompletion(kind, attempt.operation, durable.attempt_id, .{
                    .ownership_epoch = durable.ownership_epoch,
                    .result_ref = material.result_ref,
                    .result_digest = material.result_digest,
                });
                evidence_operation.agent.ownership_epoch = durable.ownership_epoch;
                break :blk .{ .durable = switch (kind) {
                    .bash => .{ .bash = durable.attempt_id },
                    .apply_patch => .{ .apply_patch = durable.attempt_id },
                    .model => unreachable,
                } };
            },
        };
        return self.commitDerived(&.{session_transition.result(.{
            .operation = evidence_operation,
            .result_ref = material.result_ref,
            .result_digest = material.result_digest,
            .class = material.class,
            .evidence = evidence,
        })}, null, .facts_only);
    }

    fn requireActionOperation(
        self: *Session,
        operation_id: u64,
        generation: u32,
    ) !OperationView {
        const operation = self.resident.semantic.operation(
            self.operationContext(operation_id, generation),
        ) orelse return error.InvalidOperationHistory;
        if (operation.kind() == .model) return error.InvalidActionDescriptor;
        return operation;
    }

    fn loadContinuation(self: *Session, slot: *core_image.ActivationSlot) !continuation.State {
        const view = try self.semanticView();
        const encoded = view.last_core orelse return error.MissingLedgerCoreState;
        const state = try continuation.decode(&encoded);
        if (state.agent_id != self.agent_id or state.agent_generation != 1) {
            return error.CoreSessionIdentityMismatch;
        }
        slotState(slot).* = state;
        return state;
    }

    fn commitContinuation(
        self: *Session,
        slot: *core_image.ActivationSlot,
        candidate: continuation.State,
        facts: []const session_transition.Fact,
        closure: ContentClosure,
    ) !u64 {
        if (candidate.agent_id != self.agent_id or candidate.agent_generation != 1) {
            return error.CoreSessionIdentityMismatch;
        }
        slotState(slot).* = candidate;
        var encoded: [continuation.encoded_size]u8 = undefined;
        try continuation.encode(&encoded, slotState(slot).*);
        return self.commitDerived(facts, encoded, closure);
    }

    fn agentContext(self: *const Session) session_transition.AgentContext {
        return .{
            .agent_id = self.agent_id,
            .agent_generation = 1,
            .ownership_epoch = self.ownership_epoch,
        };
    }

    fn operationContext(
        self: *const Session,
        operation_id: u64,
        generation: u32,
    ) session_transition.OperationContext {
        return .{
            .agent = self.agentContext(),
            .operation_id = operation_id,
            .generation = generation,
        };
    }

    fn conversationFact(
        self: *const Session,
        entry: ConversationEntry,
    ) session_transition.Fact {
        return session_transition.conversationAdvanced(.{
            .agent = self.agentContext(),
            .entry_id = entry.entry_id,
            .parent_id = entry.parent_id,
            .kind = entry.kind,
            .content_ref = entry.content_ref,
        });
    }

    fn validateCompletionContent(
        self: *Session,
        response_value: Response,
        consequence: ModelCompletionConsequence,
    ) !void {
        switch (consequence) {
            .final_answer => |final| try self.requireContentEqualsWindow(
                response_value.content_ref,
                response_value.text,
                final.content_ref,
            ),
            .tool_call => |tool| {
                try self.requireToolCallMatchesResponse(response_value, tool.content_ref);
            },
            .terminal => {},
        }
    }

    fn compileAction(
        self: *Session,
        response_value: Response,
        material: ActionMaterial,
    ) !CompiledAction {
        return switch (material) {
            .bash => |bash| blk: {
                try self.requireResponseToolKey(response_value, model_contract.bash_key);
                var descriptor_bytes: [bash_tool.max_descriptor_size]u8 = undefined;
                const bytes = try self.readBoundedContent(bash.descriptor_ref, &descriptor_bytes);
                const descriptor = try bash_tool.decodeDescriptor(bytes);
                if (!std.mem.eql(u8, descriptor.workspace_path, self.workspacePath()) or
                    !std.mem.eql(u8, descriptor.working_directory, self.workspacePath()) or
                    descriptor.call.timeout_ms != bash.call.timeout_ms or
                    !std.mem.eql(u8, descriptor.call.command, bash.call.commandSlice()))
                {
                    return error.InvalidActionDescriptor;
                }
                break :blk .{
                    .descriptor_ref = bash.descriptor_ref,
                    .descriptor_digest = .{ .bash = bash_tool.descriptorDigest(bytes) },
                    .content_closure = .facts_only,
                };
            },
            .apply_patch => |patch| blk: {
                try self.requireResponseToolKey(response_value, model_contract.apply_patch_key);
                if (patch.intent_reference == 0 or patch.patch_reference == 0) {
                    return error.InvalidActionContentClosure;
                }
                var intent_bytes: [patch_tool.max_intent_size]u8 = undefined;
                const bytes = try self.readBoundedContent(patch.intent_reference, &intent_bytes);
                const intent = try patch_tool.decodeIntent(bytes);
                var patch_bytes: [patch_tool.max_patch_size]u8 = undefined;
                const patch_content = try self.readBoundedContent(patch.patch_reference, &patch_bytes);
                const patch_digest = patch_tool.patchDigest(patch_content);
                if (intent.patch_ref != patch.patch_reference or
                    !std.mem.eql(u8, intent.workspace_path, self.workspacePath()) or
                    !binding.eql(binding.PatchDescriptor, intent.patch_digest, patch.patch_digest) or
                    !binding.eql(binding.PatchDescriptor, patch.patch_digest, patch_digest))
                {
                    return error.InvalidActionDescriptor;
                }
                break :blk .{
                    .descriptor_ref = patch.intent_reference,
                    .descriptor_digest = .{ .apply_patch = intent.intent_digest },
                    .content_closure = .{ .patch_intent = patch },
                };
            },
        };
    }

    fn requireResponseToolKey(
        self: *Session,
        response_value: Response,
        expected: []const u8,
    ) !void {
        if (response_value.tool_key.length != expected.len or expected.len > model_contract.max_tool_key_size) {
            return error.InvalidActionDescriptor;
        }
        var source = try self.viewContent(response_value.content_ref);
        var key: [model_contract.max_tool_key_size]u8 = undefined;
        const actual = try source.readWindow(response_value.tool_key.offset, key[0..expected.len]);
        if (actual.len != expected.len or !std.mem.eql(u8, actual, expected)) {
            return error.InvalidActionDescriptor;
        }
    }

    fn readBoundedContent(self: *Session, reference: u64, out: []u8) ![]const u8 {
        var content = try self.viewContent(reference);
        if (content.length() == 0 or content.length() > out.len) return error.InvalidActionDescriptor;
        const length: usize = @intCast(content.length());
        var offset: usize = 0;
        while (offset < length) {
            const bytes = try content.readWindow(offset, out[offset..length]);
            if (bytes.len == 0 or bytes.len > length - offset) return error.InvalidActionDescriptor;
            if (bytes.ptr != out[offset..].ptr) @memcpy(out[offset..][0..bytes.len], bytes);
            offset += bytes.len;
        }
        return out[0..length];
    }

    fn requireContentEqualsWindow(
        self: *Session,
        source_ref: u64,
        window: ContentWindow,
        target_ref: u64,
    ) !void {
        var source = try self.viewContent(source_ref);
        var target = try self.viewContent(target_ref);
        if (target.length() != window.length) return error.ModelCompletionContentMismatch;
        var source_bytes: [4096]u8 = undefined;
        var target_bytes: [4096]u8 = undefined;
        var offset: u64 = 0;
        while (offset < window.length) {
            const wanted: usize = @intCast(@min(window.length - offset, source_bytes.len));
            const left = try source.readWindow(window.offset + offset, source_bytes[0..wanted]);
            const right = try target.readWindow(offset, target_bytes[0..wanted]);
            if (left.len != wanted or right.len != wanted or !std.mem.eql(u8, left, right)) {
                return error.ModelCompletionContentMismatch;
            }
            offset += wanted;
        }
    }

    fn requireToolCallMatchesResponse(
        self: *Session,
        response_value: Response,
        call_ref: u64,
    ) !void {
        var call = try self.viewContent(call_ref);
        var header_bytes: [conversation.call_header_size]u8 = undefined;
        const header_slice = try call.readWindow(0, &header_bytes);
        if (header_slice.len != header_bytes.len) return error.ModelCompletionContentMismatch;
        const header = conversation.decodeToolCallHeader(&header_bytes, call.length()) catch
            return error.ModelCompletionContentMismatch;
        if (header.key_length != response_value.tool_key.length or
            header.arguments_length != response_value.arguments.length or
            !binding.eql(
                binding.StrictToolJsonV1,
                header.arguments_digest,
                response_value.arguments.digest,
            ))
        {
            return error.ModelCompletionContentMismatch;
        }
        var source = try self.viewContent(response_value.content_ref);
        var left: [4096]u8 = undefined;
        var right: [4096]u8 = undefined;
        const comparisons = [_]struct { source: ContentWindow, call_offset: u64 }{
            .{ .source = response_value.tool_key, .call_offset = conversation.call_header_size },
            .{
                .source = response_value.arguments.contentWindow(),
                .call_offset = conversation.call_header_size + header.key_length,
            },
        };
        for (comparisons) |comparison| {
            var offset: u64 = 0;
            while (offset < comparison.source.length) {
                const wanted: usize = @intCast(@min(comparison.source.length - offset, left.len));
                const source_bytes = try source.readWindow(
                    comparison.source.offset + offset,
                    left[0..wanted],
                );
                const call_bytes = try call.readWindow(
                    comparison.call_offset + offset,
                    right[0..wanted],
                );
                if (source_bytes.len != wanted or call_bytes.len != wanted or
                    !std.mem.eql(u8, source_bytes, call_bytes))
                {
                    return error.ModelCompletionContentMismatch;
                }
                offset += wanted;
            }
        }
    }

    fn commitDerived(
        self: *Session,
        facts: []const session_transition.Fact,
        encoded_core: ?[continuation.encoded_size]u8,
        content_closure: ContentClosure,
    ) !u64 {
        try self.ensureUsable();
        if (self.recovery != .ready) return error.SessionRecoveryIncomplete;
        if (facts.len == 0 or facts.len > session_transition.max_facts) {
            return error.InvalidSemanticFactCount;
        }
        if (self.resident.semantic.last_sequence == std.math.maxInt(u64)) {
            return error.SessionSequenceExhausted;
        }
        for (facts) |fact| {
            if (fact.kind() == .conversation_advanced) {
                try self.validatePreparedConversationEntry(fact);
            }
            try self.validatePreparedContentReferences(fact);
        }

        var transaction: session_transition.Transaction = .{
            .sequence = self.resident.semantic.last_sequence + 1,
            .fact_count = @intCast(facts.len),
            .core = encoded_core,
        };
        @memcpy(transaction.facts[0..facts.len], facts);
        const next = try self.resident.applyingLedger(
            transaction,
            self.agent_id,
            self.ownership_epoch,
        );

        var imports: [max_pending_content]host_store.TransactionContentImport = undefined;
        var imported_references: [max_pending_content]u64 = undefined;
        const collected = try self.collectContentImports(
            transaction,
            content_closure,
            &imports,
            &imported_references,
        );
        const final_sequence = try self.storage.commitPrepared(
            self.ownerToken(),
            .{
                .transaction = transaction,
                .content = imports[0..collected.import_count],
            },
        );
        std.debug.assert(final_sequence == transaction.sequence);
        self.resident = next;
        self.releasePendingReferences(imported_references[0..collected.reference_count]);
        for (facts) |fact| switch (fact) {
            .conversation_advanced => self.pending_conversation = null,
            .task_admitted,
            .operation_admitted,
            .attempt_admitted,
            .authorization,
            .result,
            .outcome,
            .cancellation,
            .shutdown,
            .result_applied,
            .approval_required,
            => {},
        };
        return final_sequence;
    }

    /// Direct Fact injection exists only for malformed-ledger and recovery
    /// fixtures. Production semantics enter through the typed methods above.
    pub fn commitFactsForTest(
        self: *Session,
        facts: []const session_transition.Fact,
    ) !u64 {
        if (!@import("builtin").is_test) @compileError("test-only Session Fact injection");
        return self.commitDerived(facts, null, .facts_only);
    }

    fn validatePreparedContentReferences(
        self: *Session,
        fact: session_transition.Fact,
    ) !void {
        // validatePreparedConversationEntry opens the Conversation content,
        // verifies its SHA-256 envelope, and validates its semantics.
        if (fact == .conversation_advanced) return;
        const references = fact.contentReferences();
        for (references.slice()) |reference| {
            try self.validateContent(reference.reference);
        }
    }

    pub fn semanticView(self: *Session) !SemanticView {
        try self.ensureUsable();
        if (self.recovery != .ready) return error.SessionRecoveryIncomplete;
        return self.resident.semantic;
    }

    pub fn recoverSemanticWindow(
        self: *Session,
        frame_budget: u8,
    ) !RecoveryProgress {
        try self.ensureUsable();
        if (frame_budget == 0) return error.InvalidRecoveryQuantum;
        if (self.recovery == .ready) return .{ .processed = 0, .more = false };
        if (self.recovery == .pending) {
            self.resident = .{};
            self.recovery = .{ .ledger = .{
                .next_sequence = 1,
                .ledger_head = try self.storage.sessionHead(self.session_id),
                .inbox_watermark = try self.storage.completionHead(self.session_id),
            } };
        }
        var processed: u8 = 0;
        while (processed < frame_budget) {
            switch (self.recovery) {
                .ready => return .{ .processed = processed, .more = false },
                .pending => unreachable,
                .ledger => |cursor| {
                    if (cursor.next_sequence > cursor.ledger_head) {
                        self.recovery = .{ .inbox = .{
                            .after_id = 0,
                            .watermark = cursor.inbox_watermark,
                            .ledger_head = cursor.ledger_head,
                        } };
                        continue;
                    }
                    var stored: host_store.StoredTransition = undefined;
                    try self.storage.readTransition(
                        self.session_id,
                        cursor.next_sequence,
                        &stored,
                    );
                    const transaction = stored.transaction;
                    for (transaction.factSlice()) |fact| switch (fact) {
                        .conversation_advanced => |advanced| try self.verifyConversationEntry(advanced),
                        .task_admitted,
                        .operation_admitted,
                        .attempt_admitted,
                        .authorization,
                        .result,
                        .outcome,
                        .cancellation,
                        .shutdown,
                        .result_applied,
                        .approval_required,
                        => {},
                    };
                    self.resident = try self.resident.applyingLedger(
                        transaction,
                        self.agent_id,
                        self.ownership_epoch,
                    );
                    self.recovery = .{ .ledger = .{
                        .next_sequence = cursor.next_sequence + 1,
                        .ledger_head = cursor.ledger_head,
                        .inbox_watermark = cursor.inbox_watermark,
                    } };
                    processed += 1;
                },
                .inbox => |cursor| {
                    if (cursor.after_id >= cursor.watermark) {
                        self.recovery = .ready;
                        continue;
                    }
                    const stored = (try self.storage.readCompletionAfter(
                        self.session_id,
                        cursor.after_id,
                        cursor.watermark,
                    )) orelse {
                        self.recovery = .ready;
                        continue;
                    };
                    const prepared = try self.resident.applyingCompletion(
                        stored.envelope,
                        self.session_id,
                        self.agent_id,
                        self.ownership_epoch,
                    );
                    switch (prepared.disposition) {
                        .irrelevant => {
                            self.resident = prepared.state;
                            self.recovery = .{ .historical = .{
                                .completion = stored,
                                .watermark = cursor.watermark,
                                .ledger_head = cursor.ledger_head,
                                .scan = .{},
                            } };
                        },
                        .audit => |terminal_sequence| {
                            _ = try self.storage.publishCompletion(.{ .audited = .{
                                .envelope = stored.envelope,
                                .result = .existing,
                                .consumed_by_sequence = terminal_sequence,
                            } });
                            self.resident = prepared.state;
                            self.recovery = .{ .inbox = .{
                                .after_id = stored.inbox_id,
                                .watermark = cursor.watermark,
                                .ledger_head = cursor.ledger_head,
                            } };
                        },
                        .duplicate, .persist => {
                            self.resident = prepared.state;
                            self.recovery = .{ .inbox = .{
                                .after_id = stored.inbox_id,
                                .watermark = cursor.watermark,
                                .ledger_head = cursor.ledger_head,
                            } };
                        },
                    }
                    processed += 1;
                },
                .historical => |cursor| {
                    var scan = cursor.scan;
                    const scanned = try self.storage.scanCompletedAttemptWindow(
                        self.session_id,
                        cursor.completion.envelope.operation_id,
                        cursor.completion.envelope.operation_generation,
                        cursor.completion.envelope.attempt_id,
                        cursor.ledger_head,
                        frame_budget - processed,
                        &scan,
                    );
                    if (scanned == 0) return error.InvalidHistoricalScanProgress;
                    processed += scanned;
                    if (scan.done()) {
                        if (scan.result()) |completed| {
                            const terminal_sequence = try self.validateHistoricalCompletion(
                                cursor.completion.envelope,
                                completed,
                            );
                            _ = try self.storage.publishCompletion(.{ .audited = .{
                                .envelope = cursor.completion.envelope,
                                .result = .existing,
                                .consumed_by_sequence = terminal_sequence,
                            } });
                        }
                        self.recovery = .{ .inbox = .{
                            .after_id = cursor.completion.inbox_id,
                            .watermark = cursor.watermark,
                            .ledger_head = cursor.ledger_head,
                        } };
                    } else {
                        self.recovery = .{ .historical = .{
                            .completion = cursor.completion,
                            .watermark = cursor.watermark,
                            .ledger_head = cursor.ledger_head,
                            .scan = scan,
                        } };
                    }
                },
            }
        }
        switch (self.recovery) {
            .ledger => |cursor| if (cursor.next_sequence > cursor.ledger_head and
                cursor.inbox_watermark == 0)
            {
                self.recovery = .ready;
                return .{ .processed = processed, .more = false };
            },
            .inbox => |cursor| if (cursor.after_id >= cursor.watermark) {
                self.recovery = .ready;
                return .{ .processed = processed, .more = false };
            },
            .historical => {},
            .ready => return .{ .processed = processed, .more = false },
            .pending => unreachable,
        }
        return .{ .processed = processed, .more = true };
    }

    pub fn publishCompletionEvidence(
        self: *Session,
        envelope: completion_inbox.Envelope,
    ) !void {
        try self.ensureUsable();
        try completion_inbox.validate(envelope);
        if (envelope.session_id != self.session_id or envelope.agent_id != self.agent_id) {
            return error.CompletionIdentityMismatch;
        }
        if (envelope.ownership_epoch > self.ownership_epoch) return error.FutureCompletionEpoch;
        _ = try self.viewContent(envelope.result_ref);
        const prepared = try self.resident.applyingCompletion(
            envelope,
            self.session_id,
            self.agent_id,
            self.ownership_epoch,
        );
        switch (prepared.disposition) {
            .irrelevant => {
                const terminal_sequence = try self.historicalAuditSequence(envelope) orelse {
                    self.releasePendingReferences(&.{envelope.result_ref});
                    return;
                };
                _ = try self.publishStoredCompletion(envelope, terminal_sequence);
            },
            .duplicate => {
                self.releasePendingReferences(&.{envelope.result_ref});
                return;
            },
            .audit => |terminal_sequence| {
                _ = try self.publishStoredCompletion(envelope, terminal_sequence);
            },
            .persist => {
                _ = try self.publishStoredCompletion(envelope, null);
                self.resident = prepared.state;
            },
        }
        self.releasePendingReferences(&.{envelope.result_ref});
    }

    fn historicalAuditSequence(
        self: *Session,
        envelope: completion_inbox.Envelope,
    ) !?u64 {
        var scan: host_store.CompletedAttemptScan = .{};
        const ledger_head = try self.storage.sessionHead(self.session_id);
        while (!scan.done()) {
            const scanned = try self.storage.scanCompletedAttemptWindow(
                self.session_id,
                envelope.operation_id,
                envelope.operation_generation,
                envelope.attempt_id,
                ledger_head,
                std.math.maxInt(u8),
                &scan,
            );
            if (scanned == 0) return error.InvalidHistoricalScanProgress;
        }
        const completed = scan.result() orelse return null;
        return @as(?u64, try self.validateHistoricalCompletion(envelope, completed));
    }

    fn validateHistoricalCompletion(
        self: *Session,
        envelope: completion_inbox.Envelope,
        completed: host_store.CompletedAttempt,
    ) !u64 {
        _ = self;
        const attempt = completed.attempt;
        const operation = completed.operation;
        if (attempt.operation.agent.agent_id != envelope.agent_id or
            attempt.operation.agent.agent_generation != envelope.agent_generation)
        {
            return error.CompletionIdentityMismatch;
        }
        if (attempt.operation.agent.ownership_epoch != envelope.ownership_epoch) {
            return error.CompletionAttemptEpochMismatch;
        }
        if (!std.meta.eql(operation.operation, attempt.operation) or
            operation.descriptor_ref != attempt.descriptor_ref or
            !binding.descriptorEql(operation.descriptor_digest, attempt.descriptor_digest))
        {
            return error.AttemptDescriptorMismatch;
        }
        if (std.meta.activeTag(operation.descriptor_digest) != envelope.kind) {
            return error.CompletionEvidenceKindMismatch;
        }
        return completed.terminal_result_sequence;
    }

    /// Returns the one validated pending Completion for an admitted Attempt.
    /// The resident Inbox already binds identity, epoch, and kind to the
    /// Operation descriptor; callers do not reclassify raw envelopes.
    pub fn pendingCompletion(
        self: *Session,
        operation: session_transition.OperationContext,
        attempt_id: u64,
    ) !?completion_inbox.Envelope {
        try self.ensureUsable();
        if (self.recovery != .ready) return error.SessionRecoveryIncomplete;
        const history = self.resident.semantic.operation(operation) orelse
            return error.InvalidOperationHistory;
        const attempt = history.findAttempt(attempt_id) orelse return error.InvalidAttemptHistory;
        const descriptor = history.descriptor orelse return error.MissingOperationDescriptor;
        if (attempt.descriptor_ref != descriptor.descriptor_ref or
            !binding.descriptorEql(attempt.descriptor_digest, descriptor.descriptor_digest))
        {
            return error.AttemptDescriptorMismatch;
        }
        for (self.resident.inbox.ambiguous) |maybe_key| {
            const key = maybe_key orelse continue;
            if (key.operation_id == operation.operation_id and
                key.operation_generation == operation.generation and
                key.attempt_id == attempt_id)
            {
                return error.ConflictingCompletionEvidence;
            }
        }
        var match: ?completion_inbox.Envelope = null;
        for (self.resident.inbox.entries) |maybe_envelope| {
            const envelope = maybe_envelope orelse continue;
            if (envelope.operation_id != operation.operation_id or
                envelope.operation_generation != operation.generation or
                envelope.attempt_id != attempt_id)
            {
                continue;
            }
            if (match) |existing| {
                if (!std.meta.eql(existing, envelope)) return error.ConflictingCompletionEvidence;
            } else match = envelope;
        }
        return match;
    }

    const ExpectedCompletion = struct {
        ownership_epoch: u64,
        result_ref: u64,
        result_digest: binding.Result,
    };

    fn requirePendingCompletion(
        self: *Session,
        kind: binding.DescriptorKind,
        operation: session_transition.OperationContext,
        attempt_id: u64,
        expected: ExpectedCompletion,
    ) !completion_inbox.Envelope {
        const envelope = (try self.pendingCompletion(operation, attempt_id)) orelse
            return error.MissingCompletionEvidence;
        if (envelope.kind != kind or envelope.session_id != self.session_id or
            envelope.agent_id != self.agent_id or envelope.agent_generation != 1 or
            envelope.operation_id != operation.operation_id or
            envelope.operation_generation != operation.generation or
            envelope.attempt_id != attempt_id or
            envelope.ownership_epoch != expected.ownership_epoch or
            envelope.result_ref != expected.result_ref or
            !binding.eql(binding.Result, envelope.result_digest, expected.result_digest))
        {
            return error.CompletionEvidenceMismatch;
        }
        return envelope;
    }

    /// Diagnostic count of the bounded, already validated pending Inbox.
    pub fn pendingCompletionCount(self: *Session) !u32 {
        try self.ensureUsable();
        if (self.recovery != .ready) return error.SessionRecoveryIncomplete;
        var count: u32 = 0;
        for (self.resident.inbox.entries) |entry| {
            if (entry != null) count += 1;
        }
        return count;
    }

    pub fn close(self: *Session) void {
        if (!self.open) return;
        releaseTransientScratch(self.scratch, self.io);
        self.open = false;
    }

    /// Reports disk-backed provisional bytes owned by this live Session. The
    /// value is diagnostic only and confers no content or publication authority.
    pub fn transientScratchOccupancy(self: *Session) !u64 {
        try self.ensureUsable();
        const file = transientScratchState(self.scratch).file orelse return 0;
        return (try file.stat(self.io)).size;
    }

    fn publishStoredCompletion(
        self: *Session,
        envelope: completion_inbox.Envelope,
        consumed_by_sequence: ?u64,
    ) !u64 {
        const pending = self.findPendingContent(envelope.result_ref);
        const scratch = transientScratchState(self.scratch);
        const result: host_store.CompletionResult = if (pending) |content|
            .{ .first_import = contentImport(
                if (scratch.file) |*file| file else return error.TransientScratchUnavailable,
                content.*,
            ) }
        else
            .existing;
        const publication: host_store.CompletionPublication = if (consumed_by_sequence) |sequence|
            .{ .audited = .{
                .envelope = envelope,
                .result = result,
                .consumed_by_sequence = sequence,
            } }
        else
            .{ .pending = .{ .envelope = envelope, .result = result } };
        return self.storage.publishCompletion(publication);
    }

    fn installPendingContent(self: *Session, content: PendingContent, slot_index: usize) !void {
        if (self.findPendingContent(content.reference) != null) return error.ContentAlreadyExists;
        const slot = &transientScratchState(self.scratch).pending[slot_index];
        if (slot.* != null) return error.PendingContentCapacityExceeded;
        slot.* = content;
    }

    fn findPendingContent(self: *Session, reference: u64) ?*PendingContent {
        for (&transientScratchState(self.scratch).pending) |*slot| if (slot.*) |*content| {
            if (content.reference == reference) return content;
        };
        return null;
    }

    fn collectContentImports(
        self: *Session,
        transaction: session_transition.Transaction,
        content_closure: ContentClosure,
        imports: *[max_pending_content]host_store.TransactionContentImport,
        references: *[max_pending_content]u64,
    ) !struct { import_count: usize, reference_count: usize } {
        var import_count: usize = 0;
        var reference_count: usize = 0;
        const scratch = transientScratchState(self.scratch);
        const scratch_file = if (scratch.file) |*file| file else null;
        const patch_closure: ?PatchContent = switch (content_closure) {
            .facts_only => null,
            .patch_intent => |patch| patch,
        };
        if (patch_closure) |patch| {
            if (patch.intent_reference == 0 or patch.patch_reference == 0 or
                patch.intent_reference == patch.patch_reference or
                !transaction.referencesPatchIntent(patch.intent_reference) or
                transaction.referencesContent(patch.patch_reference))
            {
                return error.InvalidPatchContentReference;
            }
        }
        for (scratch.pending) |maybe_content| if (maybe_content) |content| {
            if (!transaction.referencesContent(content.reference)) continue;
            if (patch_closure) |patch| {
                if (content.reference == patch.intent_reference) continue;
            }
            imports[import_count] = .{ .transaction_fact = contentImport(
                scratch_file orelse return error.TransientScratchUnavailable,
                content,
            ) };
            references[reference_count] = content.reference;
            import_count += 1;
            reference_count += 1;
        };
        if (patch_closure) |patch| {
            const intent = self.findPendingContent(patch.intent_reference) orelse
                return error.MissingContentReference;
            const content = self.findPendingContent(patch.patch_reference) orelse
                return error.MissingContentReference;
            if (import_count == imports.len or reference_count + 2 > references.len) {
                return error.ExcessiveContentImports;
            }
            imports[import_count] = .{ .patch_intent = .{
                .intent = contentImport(
                    scratch_file orelse return error.TransientScratchUnavailable,
                    intent.*,
                ),
                .patch = contentImport(
                    scratch_file orelse return error.TransientScratchUnavailable,
                    content.*,
                ),
            } };
            references[reference_count] = patch.intent_reference;
            references[reference_count + 1] = patch.patch_reference;
            import_count += 1;
            reference_count += 2;
        }
        return .{ .import_count = import_count, .reference_count = reference_count };
    }

    fn releasePendingReferences(self: *Session, references: []const u64) void {
        const scratch = transientScratchState(self.scratch);
        for (references) |reference| for (&scratch.pending) |*slot| {
            if (slot.*) |content| if (content.reference == reference) {
                slot.* = null;
                break;
            };
        };
        for (scratch.pending) |slot| if (slot != null) return;
        if (scratch.file) |file| {
            file.setLength(self.io, 0) catch {
                // Scratch is non-authoritative, but a failed reset makes its
                // live offset state unsafe to reuse.
                self.failed = true;
                return;
            };
        }
    }

    fn validateContent(self: *Session, reference: u64) !void {
        if (reference == 0) return;
        _ = self.viewContent(reference) catch |err| switch (err) {
            error.FileNotFound => return error.MissingContentReference,
            else => return err,
        };
    }
};

pub fn formatId(session_id: u64, buffer: *[16]u8) ![]const u8 {
    if (session_id == 0) return error.InvalidIdentity;
    return std.fmt.bufPrint(buffer, "{x:0>16}", .{session_id});
}

fn sessionName(session_id: u64, buffer: *[16]u8) []const u8 {
    return formatId(session_id, buffer) catch unreachable;
}

fn contentImport(file: *const std.Io.File, content: PendingContent) host_store.ContentImport {
    return .{
        .reference = content.reference,
        .length = content.length,
        .digest = content.digest,
        .source = .{ .file = .{
            .handle = file,
            .offset = content.offset,
        } },
    };
}

fn createTransientScratch(root: std.Io.Dir, io: std.Io) !std.Io.File {
    for (0..8) |_| {
        var identity: [8]u8 = undefined;
        io.random(&identity);
        var name_buffer: [40]u8 = undefined;
        const name = try std.fmt.bufPrint(
            &name_buffer,
            ".onepage-transient-{x}",
            .{std.mem.readInt(u64, &identity, .little)},
        );
        const file = root.createFile(io, name, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        root.deleteFile(io, name) catch |err| {
            file.close(io);
            root.deleteFile(io, name) catch {
                // Best-effort cleanup after the initial unlink failure; the
                // original platform error remains the caller-visible result.
            };
            return err;
        };
        return file;
    }
    return error.TransientScratchIdentityExhausted;
}

fn validateWorkspace(io: std.Io, path: []const u8) !void {
    var workspace = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(io, path, .{}) catch return error.WorkspaceUnavailable
    else
        std.Io.Dir.cwd().openDir(io, path, .{}) catch return error.WorkspaceUnavailable;
    defer workspace.close(io);

    if (workspace.openDir(io, ".git", .{})) |git_dir_value| {
        var git_dir = git_dir_value;
        defer git_dir.close(io);
        try validateGitDir(git_dir, io, false);
        return;
    } else |_| {}

    var marker = workspace.openFile(io, ".git", .{}) catch return error.NotGitWorktree;
    defer marker.close(io);
    const stat = marker.stat(io) catch return error.NotGitWorktree;
    if (stat.size == 0 or stat.size > 1024) return error.NotGitWorktree;
    var marker_buffer: [1024]u8 = undefined;
    const length: usize = @intCast(stat.size);
    const actual = marker.readPositionalAll(io, marker_buffer[0..length], 0) catch
        return error.NotGitWorktree;
    if (actual != length) return error.NotGitWorktree;
    const value = std.mem.trim(u8, marker_buffer[0..length], " \t\r\n");
    const prefix = "gitdir: ";
    if (!std.mem.startsWith(u8, value, prefix) or value.len == prefix.len) {
        return error.NotGitWorktree;
    }
    const git_path = value[prefix.len..];
    var git_dir = if (std.fs.path.isAbsolute(git_path))
        std.Io.Dir.openDirAbsolute(io, git_path, .{}) catch return error.NotGitWorktree
    else
        workspace.openDir(io, git_path, .{}) catch return error.NotGitWorktree;
    defer git_dir.close(io);
    try validateGitDir(git_dir, io, true);
}

fn validateGitDir(git_dir: std.Io.Dir, io: std.Io, linked: bool) !void {
    var buffer: [1024]u8 = undefined;
    const head = readSmallFile(git_dir, io, "HEAD", &buffer) catch return error.NotGitWorktree;
    const symbolic = std.mem.startsWith(u8, head, "ref: refs/") and head.len > "ref: refs/".len;
    var detached = head.len == 40 or head.len == 64;
    for (head) |byte| detached = detached and std.ascii.isHex(byte);
    if (!symbolic and !detached) return error.NotGitWorktree;
    if (linked) {
        const common_path = readSmallFile(git_dir, io, "commondir", &buffer) catch
            return error.NotGitWorktree;
        var common = if (std.fs.path.isAbsolute(common_path))
            std.Io.Dir.openDirAbsolute(io, common_path, .{}) catch return error.NotGitWorktree
        else
            git_dir.openDir(io, common_path, .{}) catch return error.NotGitWorktree;
        defer common.close(io);
        try validateGitCommon(common, io);
        return;
    }
    try validateGitCommon(git_dir, io);
}

fn validateGitCommon(git_dir: std.Io.Dir, io: std.Io) !void {
    git_dir.access(io, "config", .{}) catch return error.NotGitWorktree;
    var objects = git_dir.openDir(io, "objects", .{}) catch return error.NotGitWorktree;
    objects.close(io);
    var refs = git_dir.openDir(io, "refs", .{}) catch return error.NotGitWorktree;
    refs.close(io);
}

fn readSmallFile(dir: std.Io.Dir, io: std.Io, path: []const u8, buffer: []u8) ![]const u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size == 0 or stat.size > buffer.len) return error.InvalidControlFile;
    const length: usize = @intCast(stat.size);
    const actual = try file.readPositionalAll(io, buffer[0..length], 0);
    if (actual != length) return error.TruncatedControlFile;
    return std.mem.trim(u8, buffer[0..length], " \t\r\n");
}

fn testConfig(workspace_path: []const u8, session_id: u64) CreateConfig {
    return .{
        .identities = .{
            .session_id = session_id,
            .agent_id = session_id + 1,
            .task_id = session_id + 2,
        },
        .workspace_path = workspace_path,
        .model = "fixture:repair",
        .task = "Fix the failing test",
    };
}

fn initTestGitWorktree(dir: std.Io.Dir, io: std.Io) !void {
    try dir.createDir(io, ".git", .default_dir);
    var git_dir = try dir.openDir(io, ".git", .{});
    defer git_dir.close(io);
    try git_dir.createDir(io, "objects", .default_dir);
    try git_dir.createDir(io, "refs", .default_dir);
    var config = try git_dir.createFile(io, "config", .{});
    defer config.close(io);
    try config.writePositionalAll(io, "[core]\n\trepositoryformatversion = 0\n", 0);
    var head = try git_dir.createFile(io, "HEAD", .{});
    defer head.close(io);
    try head.writePositionalAll(io, "ref: refs/heads/main\n", 0);
}

fn addTestGitPath(io: std.Io, workspace_path: []const u8, path: []const u8) !void {
    var environment = std.process.Environ.Map.init(std.heap.page_allocator);
    defer environment.deinit();
    try environment.put("PATH", "/usr/bin:/bin");
    try environment.put("LC_ALL", "C");
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    try environment.put("GIT_CONFIG_GLOBAL", "/dev/null");
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/git", "add", "--", path },
        .cwd = .{ .path = workspace_path },
        .environ_map = &environment,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.TestGitFailed,
        else => return error.TestGitFailed,
    }
}

test "Session creation rejects a non-UTF-8 model identity" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var config = testConfig(layout.workspacePath(), 15);
    config.model = "fixture:\xff";
    try std.testing.expectError(
        error.InvalidSessionMetadata,
        Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, config),
    );
}

test "Session creation enforces recoverable root task content" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);

    var exact_task: [conversation.max_result_content_size]u8 = @splat('x');
    var exact = testConfig(layout.workspacePath(), 20);
    exact.task = &exact_task;
    var created = try Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, exact);
    created.close();
    var restored = try Session.openExisting(layout.sessions, layout.scratch, &layout.storage, io, 20);
    defer restored.close();
    const recovered = try restored.recoverSemanticWindow(8);
    try std.testing.expect(!recovered.more);
    try std.testing.expectEqual(@as(u64, 1), restored.entryCount());

    var oversized_task: [conversation.max_result_content_size + 1]u8 = @splat('x');
    var oversized = testConfig(layout.workspacePath(), 30);
    oversized.task = &oversized_task;
    try std.testing.expectError(
        error.InvalidSessionMetadata,
        Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, oversized),
    );
    var name_buffer: [16]u8 = undefined;
    try std.testing.expectError(
        error.FileNotFound,
        layout.sessions.access(io, sessionName(30, &name_buffer), .{}),
    );

    var invalid_utf8 = testConfig(layout.workspacePath(), 40);
    invalid_utf8.task = "\xff";
    try std.testing.expectError(
        error.InvalidSessionMetadata,
        Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, invalid_utf8),
    );
    try std.testing.expectError(
        error.FileNotFound,
        layout.sessions.access(io, sessionName(40, &name_buffer), .{}),
    );
}

test "transient content disappears unless its reference commits" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(
        layout.sessions,
        layout.scratch,
        &layout.storage,
        io,
        testConfig(layout.workspacePath(), 25),
    );
    var staged = try created.beginContent(90);
    try staged.append("staged before ledger admission");
    try staged.finish();
    try std.testing.expectEqual(
        @as(u32, 0),
        try created.pendingCompletionCount(),
    );

    var interrupted = try created.beginContent(91);
    try interrupted.append("partial provisional bytes");
    closeTransientScratchForTest(&created);
    interrupted.open = false; // Simulate process loss before ProviderIo.close.
    created.close();

    var restored = try Session.openExisting(layout.sessions, layout.scratch, &layout.storage, io, 25);
    defer restored.close();
    var bytes: [64]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, restored.readContent(90, 0, &bytes));
    try std.testing.expectError(error.FileNotFound, restored.readContent(91, 0, &bytes));
}

test "failed transient append remains unpublished" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(
        layout.sessions,
        layout.scratch,
        &layout.storage,
        io,
        testConfig(layout.workspacePath(), 26),
    );
    defer created.close();

    var candidate = try created.beginContent(92);
    closeTransientScratchForTest(&created);
    _ = candidate.append("candidate bytes") catch {};
    candidate.open = false;
    var bytes: [1]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, created.readContent(92, 0, &bytes));
}

const TestLayout = struct {
    tmp: std.testing.TmpDir,
    storage: host_store.StorageOwner,
    scratch: *TransientScratch,
    sessions: std.Io.Dir,
    workspace: std.Io.Dir,
    workspace_path: [128]u8,
    workspace_path_len: u8,

    fn init(io: std.Io) !TestLayout {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(io, "sessions", .default_dir);
        try tmp.dir.createDir(io, "repo", .default_dir);
        var workspace = try tmp.dir.openDir(io, "repo", .{});
        errdefer workspace.close(io);
        try initTestGitWorktree(workspace, io);
        const sessions = try tmp.dir.openDir(io, "sessions", .{});
        var database_path: [128]u8 = undefined;
        const rendered_database_path = try std.fmt.bufPrint(
            &database_path,
            ".zig-cache/tmp/{s}/host.sqlite3",
            .{tmp.sub_path},
        );
        const storage = try host_store.StorageOwner.open(io, rendered_database_path, .{});
        const scratch = try allocateTransientScratch(std.testing.allocator);
        errdefer destroyTransientScratch(std.testing.allocator, io, scratch);
        var workspace_path: [128]u8 = undefined;
        const rendered = try std.fmt.bufPrint(
            &workspace_path,
            ".zig-cache/tmp/{s}/repo",
            .{tmp.sub_path},
        );
        return .{
            .tmp = tmp,
            .storage = storage,
            .scratch = scratch,
            .sessions = sessions,
            .workspace = workspace,
            .workspace_path = workspace_path,
            .workspace_path_len = @intCast(rendered.len),
        };
    }

    fn workspacePath(self: *const TestLayout) []const u8 {
        return self.workspace_path[0..self.workspace_path_len];
    }

    fn deinit(self: *TestLayout, io: std.Io) void {
        destroyTransientScratch(std.testing.allocator, io, self.scratch);
        self.storage.close();
        self.sessions.close(io);
        self.workspace.close(io);
        self.tmp.cleanup();
    }
};

fn testDescriptor(label: []const u8) binding.Descriptor {
    return .{ .model = binding.hash(binding.ModelDescriptor, label) };
}

fn admitTestModelSource(session: *Session, operation_id: u64) !void {
    const descriptor_bytes = "test model descriptor";
    const descriptor_ref = (@as(u64, 1) << 53) | operation_id;
    try session.storeContent(descriptor_ref, descriptor_bytes);
    _ = try session.commitFactsForTest(&.{session_transition.operationAdmitted(.{
        .agent = .{
            .agent_id = session.agent_id,
            .agent_generation = 1,
            .ownership_epoch = session.ownership_epoch,
        },
        .operation_id = operation_id,
        .generation = 1,
    }, null, descriptor_ref, .{
        .model = binding.hash(binding.ModelDescriptor, descriptor_bytes),
    })});
}

fn testResultDigest(label: []const u8) binding.Result {
    return binding.hash(binding.Result, label);
}

fn expectCanonicalContinuation(state: continuation.State) !void {
    var encoded: [continuation.encoded_size]u8 = undefined;
    try continuation.encode(&encoded, state);
    try std.testing.expectEqualDeep(state, try continuation.decode(&encoded));

    var slot: core_image.ActivationSlot = undefined;
    @memset(std.mem.asBytes(&slot), 0xa5);
    slotState(&slot).* = try continuation.decode(&encoded);
    try std.testing.expectEqualDeep(state, slotState(&slot).*);
    core_image.scrub(&slot);
    for (std.mem.asBytes(&slot)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

fn expectContinuationUnchanged(state: continuation.State, before: [continuation.encoded_size]u8) !void {
    var after: [continuation.encoded_size]u8 = undefined;
    try continuation.encode(&after, state);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "private continuation reducers cover deterministic accepted and rejected production traces" {
    var prng = std.Random.DefaultPrng.init(0x50_ba_5e);
    const random = prng.random();

    for (0..32) |trace| {
        const agent_id = random.intRangeAtMost(u64, 1, std.math.maxInt(u32));
        const initialized = try continuation.initialize(.{
            .agent_id = agent_id,
            .generation = 1,
        });
        const ready_a = try continuation.startTask(initialized, 1);
        const ready_b = try continuation.startTask(initialized, 1);
        try std.testing.expectEqualDeep(ready_a, ready_b);
        try std.testing.expectEqual(agent_id, ready_a.agent_id);
        try std.testing.expectEqual(@as(u64, 1), ready_a.active_leaf_id);
        try expectCanonicalContinuation(ready_a);

        const first_operation = random.intRangeAtMost(u64, 1, std.math.maxInt(u32));
        const attempt_a = try continuation.admitModelAttempt(ready_a, first_operation, 1);
        const attempt_b = try continuation.admitModelAttempt(ready_a, first_operation, 1);
        try std.testing.expectEqualDeep(attempt_a, attempt_b);
        try std.testing.expectEqual(agent_id, attempt_a.state.agent_id);
        try std.testing.expectEqual(@as(u64, 1), attempt_a.state.active_leaf_id);
        try expectCanonicalContinuation(attempt_a.state);

        switch (trace % 3) {
            0 => {
                var bytes: [model_protocol.max_response_size]u8 = undefined;
                const response = try model_protocol.encodeText(&bytes, "done");
                const digest = binding.hash(binding.Result, response);
                var scratch_a: model_protocol.ValidationScratch = undefined;
                var scratch_b: model_protocol.ValidationScratch = undefined;
                const completed_a = try continuation.admitModelCompletion(
                    attempt_a.state,
                    .{ .id = first_operation, .generation = 1 },
                    model_protocol.admit(&scratch_a, response).admission,
                    100 + trace,
                    digest,
                    .{ .final_answer = 2 },
                );
                const completed_b = try continuation.admitModelCompletion(
                    attempt_a.state,
                    .{ .id = first_operation, .generation = 1 },
                    model_protocol.admit(&scratch_b, response).admission,
                    100 + trace,
                    digest,
                    .{ .final_answer = 2 },
                );
                try std.testing.expectEqualDeep(completed_a, completed_b);
                try std.testing.expectEqual(agent_id, completed_a.state.agent_id);
                try std.testing.expectEqual(@as(u64, 2), completed_a.state.final_entry_id);
                try expectCanonicalContinuation(completed_a.state);
            },
            1 => {
                var arguments_buffer: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
                const arguments = try model_contract.encodeJson(&arguments_buffer, .{
                    .command = "true",
                    .timeout_ms = 1_000,
                });
                var bytes: [model_protocol.max_response_size]u8 = undefined;
                const response = try model_protocol.encodeTool(
                    &bytes,
                    model_contract.bash_key,
                    arguments,
                );
                const digest = binding.hash(binding.Result, response);
                var scratch_a: model_protocol.ValidationScratch = undefined;
                var scratch_b: model_protocol.ValidationScratch = undefined;
                const completed_a = try continuation.admitModelCompletion(
                    attempt_a.state,
                    .{ .id = first_operation, .generation = 1 },
                    model_protocol.admit(&scratch_a, response).admission,
                    200 + trace,
                    digest,
                    .tool_call,
                );
                const completed_b = try continuation.admitModelCompletion(
                    attempt_a.state,
                    .{ .id = first_operation, .generation = 1 },
                    model_protocol.admit(&scratch_b, response).admission,
                    200 + trace,
                    digest,
                    .tool_call,
                );
                try std.testing.expectEqualDeep(completed_a, completed_b);
                try expectCanonicalContinuation(completed_a.state);

                const resumed_a = try continuation.admitToolResult(completed_a.state, 2, 3);
                const resumed_b = try continuation.admitToolResult(completed_a.state, 2, 3);
                try std.testing.expectEqualDeep(resumed_a, resumed_b);
                try std.testing.expectEqual(agent_id, resumed_a.agent_id);
                try expectCanonicalContinuation(resumed_a);

                const second_operation = first_operation + std.math.maxInt(u32) + 1;
                const second_attempt = try continuation.admitModelAttempt(
                    resumed_a,
                    second_operation,
                    2,
                );
                try expectCanonicalContinuation(second_attempt.state);
                var final_bytes: [model_protocol.max_response_size]u8 = undefined;
                const final_response = try model_protocol.encodeText(&final_bytes, "finished");
                const final_digest = binding.hash(binding.Result, final_response);
                var final_scratch: model_protocol.ValidationScratch = undefined;
                const final = try continuation.admitModelCompletion(
                    second_attempt.state,
                    .{ .id = second_operation, .generation = 2 },
                    model_protocol.admit(&final_scratch, final_response).admission,
                    300 + trace,
                    final_digest,
                    .{ .final_answer = 4 },
                );
                try expectCanonicalContinuation(final.state);
            },
            else => {
                var bytes: [model_protocol.max_response_size]u8 = undefined;
                const response = try model_protocol.encodeFailure(&bytes, .provider_error);
                const digest = binding.hash(binding.Result, response);
                var scratch: model_protocol.ValidationScratch = undefined;
                const failed = try continuation.admitModelCompletion(
                    attempt_a.state,
                    .{ .id = first_operation, .generation = 1 },
                    model_protocol.admit(&scratch, response).admission,
                    400 + trace,
                    digest,
                    .terminal,
                );
                try std.testing.expectEqual(continuation.TaskPhase.failed, failed.state.task_phase);
                try expectCanonicalContinuation(failed.state);
            },
        }
    }

    const initialized = try continuation.initialize(.{ .agent_id = 1, .generation = 1 });
    var before: [continuation.encoded_size]u8 = undefined;
    try continuation.encode(&before, initialized);
    try std.testing.expectError(error.InvalidConversationEntry, continuation.startTask(initialized, 0));
    try expectContinuationUnchanged(initialized, before);
    try std.testing.expectError(error.IllegalModelTransition, continuation.admitModelAttempt(initialized, 1, 1));
    try expectContinuationUnchanged(initialized, before);

    const ready = try continuation.startTask(initialized, 1);
    const attempt = try continuation.admitModelAttempt(ready, 7, 1);
    try continuation.encode(&before, attempt.state);
    var final_bytes: [model_protocol.max_response_size]u8 = undefined;
    const final_response = try model_protocol.encodeText(&final_bytes, "done");
    const final_digest = binding.hash(binding.Result, final_response);
    var scratch: model_protocol.ValidationScratch = undefined;
    const admission = model_protocol.admit(&scratch, final_response).admission;
    try std.testing.expectError(
        error.StaleOperation,
        continuation.admitModelCompletion(
            attempt.state,
            .{ .id = 8, .generation = 1 },
            admission,
            9,
            final_digest,
            .{ .final_answer = 2 },
        ),
    );
    try expectContinuationUnchanged(attempt.state, before);
    try std.testing.expectError(
        error.InvalidModelResponseEvidence,
        continuation.admitModelCompletion(
            attempt.state,
            .{ .id = 7, .generation = 1 },
            admission,
            9,
            binding.hash(binding.Result, "substituted"),
            .{ .final_answer = 2 },
        ),
    );
    try expectContinuationUnchanged(attempt.state, before);
    try std.testing.expectError(
        error.InvalidCompletionConsequence,
        continuation.admitModelCompletion(
            attempt.state,
            .{ .id = 7, .generation = 1 },
            admission,
            9,
            final_digest,
            .tool_call,
        ),
    );
    try expectContinuationUnchanged(attempt.state, before);

    var arguments_buffer: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
    const arguments = try model_contract.encodeJson(&arguments_buffer, .{
        .command = "true",
        .timeout_ms = 1_000,
    });
    var tool_bytes: [model_protocol.max_response_size]u8 = undefined;
    const tool_response = try model_protocol.encodeTool(
        &tool_bytes,
        model_contract.bash_key,
        arguments,
    );
    var tool_scratch: model_protocol.ValidationScratch = undefined;
    const tool_completed = try continuation.admitModelCompletion(
        attempt.state,
        .{ .id = 7, .generation = 1 },
        model_protocol.admit(&tool_scratch, tool_response).admission,
        12,
        binding.hash(binding.Result, tool_response),
        .tool_call,
    );
    var exhausted = try continuation.admitToolResult(tool_completed.state, 2, 3);
    exhausted.operation_generation = std.math.maxInt(u32);
    try continuation.encode(&before, exhausted);
    try std.testing.expectError(
        error.OperationGenerationExhausted,
        continuation.admitModelAttempt(exhausted, 10, 2),
    );
    try expectContinuationUnchanged(exhausted, before);

    var out_of_range = ready;
    out_of_range.active_leaf_id = std.math.maxInt(u32);
    try continuation.encode(&before, out_of_range);
    try std.testing.expectError(
        error.IllegalModelTransition,
        continuation.admitModelAttempt(out_of_range, 11, 2),
    );
    try expectContinuationUnchanged(out_of_range, before);
}

fn testReboundEnvelope(envelope: completion_inbox.Envelope) completion_inbox.Envelope {
    return completion_inbox.bind(.{
        .kind = envelope.kind,
        .session_id = envelope.session_id,
        .ownership_epoch = envelope.ownership_epoch,
        .agent_id = envelope.agent_id,
        .agent_generation = envelope.agent_generation,
        .operation_id = envelope.operation_id,
        .operation_generation = envelope.operation_generation,
        .attempt_id = envelope.attempt_id,
        .result_ref = envelope.result_ref,
        .result_digest = envelope.result_digest,
    });
}

fn testEffectAttempt(
    kind: binding.DescriptorKind,
    operation: session_transition.OperationContext,
    attempt_id: u64,
    descriptor_ref: u64,
    descriptor: binding.Descriptor,
    possible_duplicate_attempts: u8,
) session_transition.Fact {
    return switch (kind) {
        .model => session_transition.modelAttemptAdmitted(
            operation,
            attempt_id,
            descriptor_ref,
            descriptor,
            possible_duplicate_attempts,
        ),
        .bash, .apply_patch => session_transition.consequentialAttemptAdmitted(
            operation,
            attempt_id,
            descriptor_ref,
            descriptor,
        ),
    };
}

fn testDurableEvidence(
    kind: binding.DescriptorKind,
    attempt_id: u64,
) session_transition.DurableResultEvidence {
    return switch (kind) {
        .model => .{ .model = attempt_id },
        .bash => .{ .bash = attempt_id },
        .apply_patch => .{ .apply_patch = attempt_id },
    };
}

test "create and exact resume preserve distinct identities and one owner" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);

    var created = try Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, testConfig(layout.workspacePath(), 10));
    const first_token = created.ownerToken();
    var id_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("000000000000000a", try formatId(created.session_id, &id_buffer));
    try std.testing.expectEqual(@as(u64, 1), first_token.epoch);
    try std.testing.expectEqual(@as(u64, 1), created.activeLeafId());
    try std.testing.expectEqual(@as(u64, 1), created.entryCount());

    const live_resident = created.resident;
    const restored_scratch = try allocateTransientScratch(std.testing.allocator);
    defer destroyTransientScratch(std.testing.allocator, io, restored_scratch);
    var restored = try Session.openExisting(layout.sessions, restored_scratch, &layout.storage, io, 10);
    defer restored.close();
    created.close();
    try std.testing.expectEqual(@as(u64, 2), restored.ownership_epoch);
    var expected_workspace: [workspace_path_capacity]u8 = undefined;
    const expected_workspace_length = try std.Io.Dir.cwd().realPathFile(
        io,
        layout.workspacePath(),
        &expected_workspace,
    );
    try std.testing.expectEqualStrings(
        expected_workspace[0..expected_workspace_length],
        restored.workspacePath(),
    );
    try std.testing.expectEqual(@as(u64, 10), restored.session_id);
    try std.testing.expectEqual(@as(u64, 12), restored.task_id);
    try std.testing.expectEqual(@as(u64, 0), restored.activeLeafId());
    try std.testing.expectEqual(@as(u64, 2), restored.ownership_epoch);
    try std.testing.expectError(error.StaleOwner, restored.authorize(first_token));
    try restored.authorize(restored.ownerToken());
    const recovered = try restored.recoverSemanticWindow(8);
    try std.testing.expect(!recovered.more);
    try std.testing.expectEqualDeep(live_resident, restored.resident);

    const root = try restored.readEntry(1);
    try std.testing.expectEqual(EntryKind.user_text, root.kind);
    try std.testing.expectEqual(@as(u64, 0), root.parent_id);
    try std.testing.expectEqual(restored.task_id, root.content_ref);
    var task_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Fix the failing test",
        try restored.readContent(root.content_ref, 0, &task_buffer),
    );
}

test "future ownership epochs never enter the durable Completion Inbox" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);

    var created = try Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, testConfig(layout.workspacePath(), 15));
    defer created.close();
    const token = created.ownerToken();
    try created.storeContent(99, "future result");
    try std.testing.expectError(error.FutureCompletionEpoch, created.publishCompletionEvidence(completion_inbox.bind(.{
        .kind = .model,
        .session_id = created.session_id,
        .ownership_epoch = token.epoch + 1,
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .operation_id = 100,
        .operation_generation = 1,
        .attempt_id = 101,
        .result_ref = 99,
        .result_digest = testResultDigest("102"),
    })));
    try std.testing.expectEqual(@as(u64, 0), try layout.storage.completionHead(created.session_id));

    try created.publishCompletionEvidence(completion_inbox.bind(.{
        .kind = .model,
        .session_id = created.session_id,
        .ownership_epoch = token.epoch,
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .operation_id = 100,
        .operation_generation = 1,
        .attempt_id = 101,
        .result_ref = 99,
        .result_digest = testResultDigest("102"),
    }));
    try std.testing.expectEqual(@as(u64, 0), try layout.storage.completionHead(created.session_id));
}

test "Completion evidence must match the admitted Attempt ownership epoch for every effect kind" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    const cases = [_]struct {
        kind: completion_inbox.EvidenceKind,
        operation_id: u64,
        descriptor: binding.Descriptor,
    }{
        .{
            .kind = .model,
            .operation_id = 100,
            .descriptor = .{ .model = binding.hash(binding.ModelDescriptor, "epoch-model") },
        },
        .{
            .kind = .bash,
            .operation_id = 101,
            .descriptor = .{ .bash = binding.hash(binding.BashDescriptor, "epoch-bash") },
        },
        .{
            .kind = .apply_patch,
            .operation_id = 102,
            .descriptor = .{ .apply_patch = binding.hash(binding.PatchIntent, "epoch-patch") },
        },
    };

    for (cases, 0..) |case, index| {
        const session_id: u64 = 20 + @as(u64, @intCast(index)) * 10;
        var created = try Session.createExact(
            layout.sessions,
            layout.scratch,
            &layout.storage,
            io,
            testConfig(layout.workspacePath(), session_id),
        );
        const attempt_epoch = created.ownership_epoch;
        const operation: session_transition.OperationContext = .{
            .agent = .{
                .agent_id = created.agent_id,
                .agent_generation = 1,
                .ownership_epoch = attempt_epoch,
            },
            .operation_id = case.operation_id,
            .generation = 1,
        };
        const descriptor_ref = 200 + index;
        const attempt_id = 210 + index;
        const first_result_ref = 220 + index;
        try created.storeContent(descriptor_ref, "epoch descriptor");
        try created.storeContent(first_result_ref, "first evidence");
        if (case.kind != .model) try admitTestModelSource(&created, 99);
        const admitted = if (case.kind == .model)
            session_transition.modelAttemptAdmitted(
                operation,
                attempt_id,
                descriptor_ref,
                case.descriptor,
                0,
            )
        else
            session_transition.consequentialAttemptAdmitted(
                operation,
                attempt_id,
                descriptor_ref,
                case.descriptor,
            );
        _ = try created.commitFactsForTest(&.{
            session_transition.operationAdmitted(
                operation,
                if (case.kind == .model) null else .{ .operation_id = 99, .generation = 1 },
                descriptor_ref,
                case.descriptor,
            ),
            admitted,
        });
        const first = completion_inbox.bind(.{
            .kind = case.kind,
            .session_id = created.session_id,
            .ownership_epoch = attempt_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = case.operation_id,
            .operation_generation = 1,
            .attempt_id = attempt_id,
            .result_ref = first_result_ref,
            .result_digest = testResultDigest("first epoch evidence"),
        });
        try created.publishCompletionEvidence(first);
        const first_inbox_id = try layout.storage.completionHead(created.session_id);
        if (first_inbox_id == 0) return error.CompletionNotPublished;
        created.close();

        var restored = (try Session.openExisting(
            layout.sessions,
            layout.scratch,
            &layout.storage,
            io,
            session_id,
        ));
        while ((try restored.recoverSemanticWindow(32)).more) {}
        const conflicting_result_ref = 230 + index;
        try restored.storeContent(conflicting_result_ref, "cross epoch evidence");
        const cross_epoch = completion_inbox.bind(.{
            .kind = case.kind,
            .session_id = restored.session_id,
            .ownership_epoch = restored.ownership_epoch,
            .agent_id = restored.agent_id,
            .agent_generation = 1,
            .operation_id = case.operation_id,
            .operation_generation = 1,
            .attempt_id = attempt_id,
            .result_ref = conflicting_result_ref,
            .result_digest = testResultDigest("cross epoch evidence"),
        });
        try std.testing.expectError(
            error.CompletionAttemptEpochMismatch,
            restored.publishCompletionEvidence(cross_epoch),
        );
        try std.testing.expectEqual(first_inbox_id, try layout.storage.completionHead(session_id));
        try std.testing.expectEqualDeep(
            first,
            (try layout.storage.readCompletion(session_id, first_inbox_id)).envelope,
        );
        restored.close();
    }
}

test "live Completion publication rejects Bash and Patch evidence kind swaps" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    const cases = [_]struct {
        descriptor: binding.Descriptor,
        result_evidence: session_transition.DurableResultEvidence,
        correct_kind: completion_inbox.EvidenceKind,
        wrong_kind: completion_inbox.EvidenceKind,
    }{
        .{
            .descriptor = .{ .bash = binding.hash(binding.BashDescriptor, "live-bash") },
            .result_evidence = .{ .bash = 320 },
            .correct_kind = .bash,
            .wrong_kind = .apply_patch,
        },
        .{
            .descriptor = .{ .apply_patch = binding.hash(binding.PatchIntent, "live-patch") },
            .result_evidence = .{ .apply_patch = 321 },
            .correct_kind = .apply_patch,
            .wrong_kind = .bash,
        },
    };

    for (cases, 0..) |case, index| {
        const session_id = 60 + @as(u64, @intCast(index)) * 10;
        var created = try Session.createExact(
            layout.sessions,
            layout.scratch,
            &layout.storage,
            io,
            testConfig(layout.workspacePath(), session_id),
        );
        defer created.close();
        const operation: session_transition.OperationContext = .{
            .agent = .{
                .agent_id = created.agent_id,
                .agent_generation = 1,
                .ownership_epoch = created.ownership_epoch,
            },
            .operation_id = 300 + index,
            .generation = 1,
        };
        const descriptor_ref = 310 + index;
        const attempt_id = 320 + index;
        const result_ref = 330 + index;
        try created.storeContent(descriptor_ref, "descriptor");
        try created.storeContent(result_ref, "wrong-kind result");
        try admitTestModelSource(&created, 299);
        _ = try created.commitFactsForTest(&.{
            session_transition.operationAdmitted(
                operation,
                .{ .operation_id = 299, .generation = 1 },
                descriptor_ref,
                case.descriptor,
            ),
            session_transition.consequentialAttemptAdmitted(
                operation,
                attempt_id,
                descriptor_ref,
                case.descriptor,
            ),
        });
        try created.publishCompletionEvidence(completion_inbox.bind(.{
            .kind = case.correct_kind,
            .session_id = created.session_id,
            .ownership_epoch = operation.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation.operation_id,
            .operation_generation = operation.generation,
            .attempt_id = attempt_id,
            .result_ref = result_ref,
            .result_digest = testResultDigest("wrong-kind result"),
        }));
        const correct_inbox_id = try layout.storage.completionHead(session_id);
        _ = try created.commitFactsForTest(&.{session_transition.result(.{
            .operation = operation,
            .result_ref = result_ref,
            .result_digest = testResultDigest("wrong-kind result"),
            .class = .ordinary,
            .evidence = .{ .durable = case.result_evidence },
        })});
        const wrong = completion_inbox.bind(.{
            .kind = case.wrong_kind,
            .session_id = created.session_id,
            .ownership_epoch = operation.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation.operation_id,
            .operation_generation = operation.generation,
            .attempt_id = attempt_id,
            .result_ref = result_ref,
            .result_digest = testResultDigest("wrong-kind result"),
        });
        try std.testing.expectError(
            error.CompletionEvidenceKindMismatch,
            created.publishCompletionEvidence(wrong),
        );
        try std.testing.expectEqual(@as(u64, 0), try layout.storage.completionHead(session_id));
        try std.testing.expectError(
            error.CompletionNotFound,
            layout.storage.readCompletion(session_id, correct_inbox_id + 1),
        );
    }
}

test "lost Completion notification recovery rejects Bash and Patch evidence kind swaps" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    const cases = [_]struct {
        descriptor: binding.Descriptor,
        result_evidence: session_transition.DurableResultEvidence,
        correct_kind: completion_inbox.EvidenceKind,
        wrong_kind: completion_inbox.EvidenceKind,
    }{
        .{
            .descriptor = .{ .bash = binding.hash(binding.BashDescriptor, "recovery-bash") },
            .result_evidence = .{ .bash = 420 },
            .correct_kind = .bash,
            .wrong_kind = .apply_patch,
        },
        .{
            .descriptor = .{ .apply_patch = binding.hash(binding.PatchIntent, "recovery-patch") },
            .result_evidence = .{ .apply_patch = 421 },
            .correct_kind = .apply_patch,
            .wrong_kind = .bash,
        },
    };

    for (cases, 0..) |case, index| {
        const session_id = 80 + @as(u64, @intCast(index)) * 10;
        var created = try Session.createExact(
            layout.sessions,
            layout.scratch,
            &layout.storage,
            io,
            testConfig(layout.workspacePath(), session_id),
        );
        const operation: session_transition.OperationContext = .{
            .agent = .{
                .agent_id = created.agent_id,
                .agent_generation = 1,
                .ownership_epoch = created.ownership_epoch,
            },
            .operation_id = 400 + index,
            .generation = 1,
        };
        const descriptor_ref = 410 + index;
        const attempt_id = 420 + index;
        const result_ref = 430 + index;
        try created.storeContent(descriptor_ref, "descriptor");
        try created.storeContent(result_ref, "lost wrong-kind result");
        try admitTestModelSource(&created, 399);
        _ = try created.commitFactsForTest(&.{
            session_transition.operationAdmitted(
                operation,
                .{ .operation_id = 399, .generation = 1 },
                descriptor_ref,
                case.descriptor,
            ),
            session_transition.consequentialAttemptAdmitted(
                operation,
                attempt_id,
                descriptor_ref,
                case.descriptor,
            ),
        });
        try created.publishCompletionEvidence(completion_inbox.bind(.{
            .kind = case.correct_kind,
            .session_id = created.session_id,
            .ownership_epoch = operation.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation.operation_id,
            .operation_generation = operation.generation,
            .attempt_id = attempt_id,
            .result_ref = result_ref,
            .result_digest = testResultDigest("lost wrong-kind result"),
        }));
        _ = try created.commitFactsForTest(&.{session_transition.result(.{
            .operation = operation,
            .result_ref = result_ref,
            .result_digest = testResultDigest("lost wrong-kind result"),
            .class = .ordinary,
            .evidence = .{ .durable = case.result_evidence },
        })});
        const wrong = completion_inbox.bind(.{
            .kind = case.wrong_kind,
            .session_id = created.session_id,
            .ownership_epoch = operation.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation.operation_id,
            .operation_generation = operation.generation,
            .attempt_id = attempt_id,
            .result_ref = result_ref,
            .result_digest = testResultDigest("lost wrong-kind result"),
        });
        const inbox_id = try layout.storage.publishCompletion(.{ .pending = .{
            .envelope = wrong,
            .result = .existing,
        } });
        created.close();

        var restored = (try Session.openExisting(
            layout.sessions,
            layout.scratch,
            &layout.storage,
            io,
            session_id,
        ));
        defer restored.close();
        try std.testing.expectError(
            error.CompletionEvidenceKindMismatch,
            restored.recoverSemanticWindow(32),
        );
        for (restored.resident.inbox.entries) |entry| try std.testing.expect(entry == null);
        const pending = try layout.storage.readCompletion(session_id, inbox_id);
        try std.testing.expect(pending.consumed_by_sequence == null);
        try std.testing.expectEqual(inbox_id, try layout.storage.completionHead(session_id));
    }
}

test "late evidence audits against the first terminal Result sequence" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, testConfig(layout.workspacePath(), 55));
    defer created.close();
    const operation: session_transition.OperationContext = .{
        .agent = .{
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .ownership_epoch = created.ownership_epoch,
        },
        .operation_id = 100,
        .generation = 1,
    };
    const descriptor = testDescriptor("terminal sequence descriptor");
    try created.storeContent(201, "descriptor");
    try created.storeContent(202, "winning result");
    _ = try created.commitFactsForTest(&.{
        session_transition.operationAdmitted(operation, null, 201, descriptor),
        session_transition.modelAttemptAdmitted(operation, 211, 201, descriptor, 0),
        session_transition.modelAttemptAdmitted(operation, 212, 201, descriptor, 1),
    });
    try created.publishCompletionEvidence(completion_inbox.bind(.{
        .kind = .model,
        .session_id = created.session_id,
        .ownership_epoch = operation.agent.ownership_epoch,
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .operation_id = operation.operation_id,
        .operation_generation = operation.generation,
        .attempt_id = 212,
        .result_ref = 202,
        .result_digest = testResultDigest("winning result"),
    }));
    try created.storeContent(203, "later outcome");
    const terminal_sequence = try created.commitFactsForTest(&.{session_transition.result(.{
        .operation = operation,
        .result_ref = 202,
        .result_digest = testResultDigest("winning result"),
        .class = .ordinary,
        .evidence = .{ .durable = .{ .model = 212 } },
    })});
    _ = try created.commitFactsForTest(&.{session_transition.outcome(
        operation.agent,
        301,
        203,
    )});

    try created.storeContent(204, "late result");
    try created.publishCompletionEvidence(completion_inbox.bind(.{
        .kind = .model,
        .session_id = created.session_id,
        .ownership_epoch = operation.agent.ownership_epoch,
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .operation_id = operation.operation_id,
        .operation_generation = operation.generation,
        .attempt_id = 211,
        .result_ref = 204,
        .result_digest = testResultDigest("late result"),
    }));
    const audited = try layout.storage.readCompletion(created.session_id, 2);
    try std.testing.expectEqual(terminal_sequence, audited.consumed_by_sequence.?);
}

test "late evidence for a prior Operation audits through durable history" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    const cases = [_]struct {
        kind: binding.DescriptorKind,
        descriptor_a: binding.Descriptor,
        descriptor_b: binding.Descriptor,
        wrong_kind: binding.DescriptorKind,
    }{
        .{
            .kind = .model,
            .descriptor_a = .{ .model = binding.hash(binding.ModelDescriptor, "prior-model-a") },
            .descriptor_b = .{ .model = binding.hash(binding.ModelDescriptor, "current-model-b") },
            .wrong_kind = .bash,
        },
        .{
            .kind = .bash,
            .descriptor_a = .{ .bash = binding.hash(binding.BashDescriptor, "prior-bash-a") },
            .descriptor_b = .{ .bash = binding.hash(binding.BashDescriptor, "current-bash-b") },
            .wrong_kind = .apply_patch,
        },
    };

    for (cases, 0..) |case, case_index| {
        const session_id = 110 + @as(u64, @intCast(case_index)) * 10;
        var created = try Session.createExact(
            layout.sessions,
            layout.scratch,
            &layout.storage,
            io,
            testConfig(layout.workspacePath(), session_id),
        );
        errdefer created.close();
        const operation_base: u64 = 500;
        const operation_a: session_transition.OperationContext = .{
            .agent = .{
                .agent_id = created.agent_id,
                .agent_generation = 1,
                .ownership_epoch = created.ownership_epoch,
            },
            .operation_id = operation_base + @as(u64, @intCast(case_index)) * 10,
            .generation = 1,
        };
        const operation_b: session_transition.OperationContext = .{
            .agent = operation_a.agent,
            .operation_id = operation_a.operation_id + 1,
            .generation = 1,
        };
        const descriptor_a_ref: u64 = 510 + @as(u64, @intCast(case_index)) * 20;
        const descriptor_b_ref = descriptor_a_ref + 1;
        const winner_attempt = descriptor_a_ref + 2;
        const live_attempt = descriptor_a_ref + 3;
        const recovery_attempt = descriptor_a_ref + 4;
        const wrong_epoch_attempt = descriptor_a_ref + 5;
        const wrong_kind_attempt = descriptor_a_ref + 6;
        const current_attempt = descriptor_a_ref + 7;
        const winner_result_ref = descriptor_a_ref + 8;
        const live_result_ref = descriptor_a_ref + 9;
        const recovery_result_ref = descriptor_a_ref + 10;
        const conflict_result_ref = descriptor_a_ref + 11;
        try created.storeContent(descriptor_a_ref, "prior descriptor");
        try created.storeContent(winner_result_ref, "winning result");
        if (case.kind != .model) try admitTestModelSource(&created, 499);

        var admission: [6]session_transition.Fact = undefined;
        admission[0] = session_transition.operationAdmitted(
            operation_a,
            if (case.kind == .model) null else .{ .operation_id = 499, .generation = 1 },
            descriptor_a_ref,
            case.descriptor_a,
        );
        const attempt_ids = [_]u64{
            winner_attempt,
            live_attempt,
            recovery_attempt,
            wrong_epoch_attempt,
            wrong_kind_attempt,
        };
        for (attempt_ids, 0..) |attempt_id, index| admission[index + 1] = testEffectAttempt(
            case.kind,
            operation_a,
            attempt_id,
            descriptor_a_ref,
            case.descriptor_a,
            @intCast(index),
        );
        _ = try created.commitFactsForTest(&admission);
        try created.publishCompletionEvidence(completion_inbox.bind(.{
            .kind = case.kind,
            .session_id = created.session_id,
            .ownership_epoch = operation_a.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation_a.operation_id,
            .operation_generation = operation_a.generation,
            .attempt_id = winner_attempt,
            .result_ref = winner_result_ref,
            .result_digest = testResultDigest("winning result"),
        }));
        const winner_inbox_id = try layout.storage.completionHead(session_id);
        const terminal_sequence = try created.commitFactsForTest(&.{session_transition.result(.{
            .operation = operation_a,
            .result_ref = winner_result_ref,
            .result_digest = testResultDigest("winning result"),
            .class = .ordinary,
            .evidence = .{ .durable = testDurableEvidence(case.kind, winner_attempt) },
        })});
        try created.storeContent(descriptor_b_ref, "current descriptor");
        _ = try created.commitFactsForTest(&.{
            session_transition.operationAdmitted(
                operation_b,
                if (case.kind == .model) null else .{ .operation_id = 499, .generation = 1 },
                descriptor_b_ref,
                case.descriptor_b,
            ),
            testEffectAttempt(
                case.kind,
                operation_b,
                current_attempt,
                descriptor_b_ref,
                case.descriptor_b,
                0,
            ),
        });
        const sequence_before_late = try layout.storage.sessionHead(session_id);
        const resident_before_late = created.resident;

        const live_late = completion_inbox.bind(.{
            .kind = case.kind,
            .session_id = created.session_id,
            .ownership_epoch = operation_a.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation_a.operation_id,
            .operation_generation = operation_a.generation,
            .attempt_id = live_attempt,
            .result_ref = live_result_ref,
            .result_digest = testResultDigest("live late result"),
        });
        try created.storeContent(live_result_ref, "live late result");
        try created.publishCompletionEvidence(live_late);
        const live_audit = try layout.storage.readCompletion(session_id, winner_inbox_id + 1);
        try std.testing.expectEqual(terminal_sequence, live_audit.consumed_by_sequence.?);
        try std.testing.expectEqualDeep(live_late, live_audit.envelope);

        const wrong_kind = completion_inbox.bind(.{
            .kind = case.wrong_kind,
            .session_id = created.session_id,
            .ownership_epoch = operation_a.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation_a.operation_id,
            .operation_generation = operation_a.generation,
            .attempt_id = wrong_kind_attempt,
            .result_ref = live_result_ref,
            .result_digest = testResultDigest("live late result"),
        });
        try std.testing.expectError(
            error.CompletionEvidenceKindMismatch,
            created.publishCompletionEvidence(wrong_kind),
        );
        const conflicting = completion_inbox.bind(.{
            .kind = case.kind,
            .session_id = created.session_id,
            .ownership_epoch = operation_a.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation_a.operation_id,
            .operation_generation = operation_a.generation,
            .attempt_id = live_attempt,
            .result_ref = conflict_result_ref,
            .result_digest = testResultDigest("conflicting late result"),
        });
        try created.storeContent(conflict_result_ref, "conflicting late result");
        try std.testing.expectError(
            error.ConflictingCompletionEvidence,
            created.publishCompletionEvidence(conflicting),
        );
        try std.testing.expectEqual(sequence_before_late, try layout.storage.sessionHead(session_id));
        try std.testing.expectEqualDeep(resident_before_late, created.resident);
        const current = try created.semanticView();
        const current_operation = if (case.kind == .model) current.model else current.consequential;
        try std.testing.expectEqual(operation_b.operation_id, current_operation.operation_id);
        try std.testing.expectEqual(current_attempt, current_operation.latestAttempt().?.attempt_id);

        const recovered_late = completion_inbox.bind(.{
            .kind = case.kind,
            .session_id = created.session_id,
            .ownership_epoch = operation_a.agent.ownership_epoch,
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .operation_id = operation_a.operation_id,
            .operation_generation = operation_a.generation,
            .attempt_id = recovery_attempt,
            .result_ref = recovery_result_ref,
            .result_digest = testResultDigest("recovered late result"),
        });
        try created.storeContent(recovery_result_ref, "recovered late result");
        const recovered_content = created.findPendingContent(recovery_result_ref) orelse {
            return error.MissingTestContent;
        };
        const recovered_inbox_id = try layout.storage.publishCompletion(.{ .pending = .{
            .envelope = recovered_late,
            .result = .{ .first_import = contentImport(
                &transientScratchState(created.scratch).file.?,
                recovered_content.*,
            ) },
        } });
        created.releasePendingReferences(&.{recovery_result_ref});
        try std.testing.expectEqual(winner_inbox_id + 2, recovered_inbox_id);
        created.close();

        var restored = (try Session.openExisting(
            layout.sessions,
            layout.scratch,
            &layout.storage,
            io,
            session_id,
        ));
        defer restored.close();
        const ledger_recovery = try restored.recoverSemanticWindow(
            @intCast(sequence_before_late),
        );
        try std.testing.expectEqual(@as(u8, @intCast(sequence_before_late)), ledger_recovery.processed);
        try std.testing.expect(ledger_recovery.more);
        const first_history_window = try restored.recoverSemanticWindow(2);
        try std.testing.expectEqual(@as(u8, 2), first_history_window.processed);
        try std.testing.expect(first_history_window.more);
        try std.testing.expectEqual(
            @as(?u64, null),
            (try layout.storage.readCompletion(session_id, recovered_inbox_id)).consumed_by_sequence,
        );
        while ((try restored.recoverSemanticWindow(32)).more) {}
        const recovered_audit = try layout.storage.readCompletion(session_id, recovered_inbox_id);
        try std.testing.expectEqual(terminal_sequence, recovered_audit.consumed_by_sequence.?);
        try std.testing.expectEqualDeep(recovered_late, recovered_audit.envelope);
        try std.testing.expectEqual(sequence_before_late, try layout.storage.sessionHead(session_id));
        const wrong_epoch = completion_inbox.bind(.{
            .kind = case.kind,
            .session_id = restored.session_id,
            .ownership_epoch = restored.ownership_epoch,
            .agent_id = restored.agent_id,
            .agent_generation = 1,
            .operation_id = operation_a.operation_id,
            .operation_generation = operation_a.generation,
            .attempt_id = wrong_epoch_attempt,
            .result_ref = live_result_ref,
            .result_digest = testResultDigest("live late result"),
        });
        try std.testing.expectError(
            error.CompletionAttemptEpochMismatch,
            restored.publishCompletionEvidence(wrong_epoch),
        );
        try std.testing.expectEqual(@as(u64, 0), try layout.storage.completionHead(session_id));
        const restored_current = try restored.semanticView();
        const restored_operation = if (case.kind == .model) restored_current.model else restored_current.consequential;
        try std.testing.expectEqual(operation_b.operation_id, restored_operation.operation_id);
        try std.testing.expectEqual(current_attempt, restored_operation.latestAttempt().?.attempt_id);
    }
}

test "fallible Inbox publication is prepared before durable Completion commit" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);

    var created = try Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, testConfig(layout.workspacePath(), 16));
    defer created.close();
    const token = created.ownerToken();
    const agent: session_transition.AgentContext = .{
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .ownership_epoch = token.epoch,
    };
    const operation: session_transition.OperationContext = .{
        .agent = agent,
        .operation_id = 100,
        .generation = 1,
    };
    var semantic: session_transition.Transaction = .{ .sequence = 2, .fact_count = 3 };
    semantic.facts[0] = session_transition.operationAdmitted(operation, null, 101, testDescriptor("102"));
    semantic.facts[1] = session_transition.modelAttemptAdmitted(operation, 103, 101, testDescriptor("102"), 0);
    semantic.facts[2] = session_transition.modelAttemptAdmitted(operation, 108, 101, testDescriptor("102"), 1);
    try created.resident.semantic.apply(semantic);

    const existing = completion_inbox.bind(.{
        .kind = .model,
        .session_id = created.session_id,
        .ownership_epoch = token.epoch,
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .operation_id = 100,
        .operation_generation = 1,
        .attempt_id = 103,
        .result_ref = 104,
        .result_digest = testResultDigest("105"),
    });
    _ = try created.resident.inbox.apply(
        &created.resident.semantic,
        existing,
        created.session_id,
        created.agent_id,
        token.epoch,
    );
    var other_attempt = existing;
    other_attempt.attempt_id = 108;
    for (&created.resident.inbox.ambiguous) |*slot| {
        slot.* = InboxIndex.AttemptKey.fromEnvelope(other_attempt);
    }

    var conflicting = existing;
    conflicting.result_ref = 106;
    conflicting.result_digest = testResultDigest("107");
    conflicting = testReboundEnvelope(conflicting);
    try created.storeContent(conflicting.result_ref, "conflicting result");
    try std.testing.expectError(
        error.InboxSemanticCapacityExceeded,
        created.publishCompletionEvidence(conflicting),
    );
    try std.testing.expectEqual(@as(u64, 0), try layout.storage.completionHead(created.session_id));
    try std.testing.expectEqualDeep(existing, created.resident.inbox.entries[0].?);
}

test "recovery advances only within the configured Session Ledger quantum" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, testConfig(layout.workspacePath(), 80));
    for (0..5) |index| {
        try created.storeContent(index + 1, "ledger fixture");
        _ = try created.commitFactsForTest(&.{session_transition.taskAdmitted(.{
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .ownership_epoch = created.ownership_epoch,
        }, index + 1, index + 1)});
    }
    created.close();

    var restored = (try Session.openExisting(
        layout.sessions,
        layout.scratch,
        &layout.storage,
        io,
        80,
    ));
    defer restored.close();
    const first = try restored.recoverSemanticWindow(2);
    try std.testing.expectEqual(@as(u8, 2), first.processed);
    try std.testing.expect(first.more);
    try std.testing.expectEqual(@as(u64, 2), restored.resident.semantic.last_sequence);
    const second = try restored.recoverSemanticWindow(2);
    try std.testing.expectEqual(@as(u8, 2), second.processed);
    try std.testing.expect(second.more);
    const last = try restored.recoverSemanticWindow(2);
    try std.testing.expectEqual(@as(u8, 2), last.processed);
    try std.testing.expect(!last.more);
    try std.testing.expectEqual(@as(u64, 6), restored.resident.semantic.last_sequence);
}

test "semantic commits reject missing immutable content references before advancing the Ledger" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, testConfig(layout.workspacePath(), 81));
    defer created.close();

    try std.testing.expectError(error.MissingContentReference, created.commitFactsForTest(
        &.{session_transition.operationAdmitted(.{
            .agent = .{
                .agent_id = created.agent_id,
                .agent_generation = 1,
                .ownership_epoch = created.ownership_epoch,
            },
            .operation_id = 100,
            .generation = 1,
        }, null, 999, testDescriptor("123"))},
    ));
    try std.testing.expectEqual(@as(u64, 1), created.resident.semantic.last_sequence);
    try std.testing.expectEqual(@as(u64, 1), try layout.storage.sessionHead(created.session_id));
}

test "typed final completion compiles one exact atomic semantic transaction" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(
        layout.sessions,
        layout.scratch,
        &layout.storage,
        io,
        testConfig(layout.workspacePath(), 811),
    );
    defer created.close();

    var slot: core_image.ActivationSlot = undefined;
    _ = try created.startTask(&slot);
    try created.storeContent(900, "request");
    const request_digest = binding.hash(binding.ModelDescriptor, "request");
    const operation = try created.admitModelAttempt(&slot, .{
        .operation_id = 100,
        .sequence = 1,
        .attempt_id = 101,
        .request_ref = 900,
        .request_digest = request_digest,
    });

    var response_bytes: [model_protocol.max_response_size]u8 = undefined;
    const response = try model_protocol.encodeText(&response_bytes, "done");
    try created.storeContent(901, response);
    try created.storeContent(902, "done");
    try created.storeContent(903, "substituted");
    const response_digest = binding.hash(binding.Result, response);
    try created.publishCompletionEvidence(completion_inbox.bind(.{
        .kind = .model,
        .session_id = created.session_id,
        .ownership_epoch = created.ownership_epoch,
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .operation_id = operation.id,
        .operation_generation = operation.generation,
        .attempt_id = 101,
        .result_ref = 901,
        .result_digest = response_digest,
    }));
    var validation: model_protocol.ValidationScratch = undefined;
    var substituted = ModelCompletionMaterial{
        .operation_id = operation.id,
        .operation_generation = operation.generation,
        .attempt_id = 101,
        .evidence_epoch = created.ownership_epoch,
        .response_ref = 901,
        .response_digest = response_digest,
        .admission = model_protocol.admit(&validation, response).admission,
        .consequence = .{ .final_answer = .{ .content_ref = 902 } },
    };
    substituted.evidence_epoch += 1;
    try std.testing.expectError(
        error.CompletionEvidenceMismatch,
        created.admitModelCompletion(&slot, substituted),
    );
    substituted.evidence_epoch = created.ownership_epoch;
    substituted.response_ref = 903;
    try std.testing.expectError(
        error.CompletionEvidenceMismatch,
        created.admitModelCompletion(&slot, substituted),
    );
    substituted.response_ref = 901;
    substituted.response_digest = binding.hash(binding.Result, "substituted");
    try std.testing.expectError(
        error.CompletionEvidenceMismatch,
        created.admitModelCompletion(&slot, substituted),
    );
    substituted.response_digest = response_digest;
    substituted.attempt_id = 102;
    try std.testing.expectError(
        error.InvalidAttemptHistory,
        created.admitModelCompletion(&slot, substituted),
    );
    try std.testing.expectError(
        error.ModelCompletionContentMismatch,
        created.admitModelCompletion(&slot, .{
            .operation_id = operation.id,
            .operation_generation = operation.generation,
            .attempt_id = 101,
            .evidence_epoch = created.ownership_epoch,
            .response_ref = 901,
            .response_digest = response_digest,
            .admission = model_protocol.admit(&validation, response).admission,
            .consequence = .{ .final_answer = .{ .content_ref = 903 } },
        }),
    );
    try std.testing.expectEqual(@as(u64, 3), try layout.storage.sessionHead(created.session_id));
    try std.testing.expectEqual(@as(?ConversationEntry, null), created.pending_conversation);
    _ = try created.admitModelCompletion(&slot, .{
        .operation_id = operation.id,
        .operation_generation = operation.generation,
        .attempt_id = 101,
        .evidence_epoch = created.ownership_epoch,
        .response_ref = 901,
        .response_digest = response_digest,
        .admission = model_protocol.admit(&validation, response).admission,
        .consequence = .{ .final_answer = .{ .content_ref = 902 } },
    });

    var stored: host_store.StoredTransition = undefined;
    try layout.storage.readTransition(created.session_id, 4, &stored);
    const committed = stored.transaction;
    try std.testing.expectEqual(@as(u8, 4), committed.fact_count);
    try std.testing.expectEqual(session_transition.Kind.result, committed.facts[0].kind());
    try std.testing.expectEqual(session_transition.Kind.result_applied, committed.facts[1].kind());
    try std.testing.expectEqual(session_transition.Kind.conversation_advanced, committed.facts[2].kind());
    try std.testing.expectEqual(session_transition.Kind.outcome, committed.facts[3].kind());
    try std.testing.expect(committed.core != null);
}

test "typed tool completion derives the Action and binds the exact Result" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(
        layout.sessions,
        layout.scratch,
        &layout.storage,
        io,
        testConfig(layout.workspacePath(), 812),
    );
    defer created.close();

    var slot: core_image.ActivationSlot = undefined;
    _ = try created.startTask(&slot);
    try created.storeContent(910, "request");
    const request_digest = binding.hash(binding.ModelDescriptor, "request");
    const model_operation = try created.admitModelAttempt(&slot, .{
        .operation_id = 110,
        .sequence = 1,
        .attempt_id = 111,
        .request_ref = 910,
        .request_digest = request_digest,
    });

    var arguments_buffer: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
    const arguments = try model_contract.encodeJson(&arguments_buffer, .{
        .command = "true",
        .timeout_ms = 1_000,
    });
    var response_buffer: [model_protocol.max_response_size]u8 = undefined;
    const response = try model_protocol.encodeTool(
        &response_buffer,
        model_contract.bash_key,
        arguments,
    );
    const response_digest = binding.hash(binding.Result, response);
    try created.storeContent(911, response);
    try created.publishCompletionEvidence(completion_inbox.bind(.{
        .kind = .model,
        .session_id = created.session_id,
        .ownership_epoch = created.ownership_epoch,
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .operation_id = model_operation.id,
        .operation_generation = model_operation.generation,
        .attempt_id = 111,
        .result_ref = 911,
        .result_digest = response_digest,
    }));

    var json_scratch: model_contract.StrictToolJsonScratch = .{};
    const admitted_arguments = try model_contract.validateStrictToolJson(&json_scratch, arguments);
    var call_buffer: [
        conversation.call_header_size + model_contract.max_tool_key_size +
            model_contract.max_tool_arguments_envelope_size
    ]u8 = undefined;
    const call = try conversation.encodeToolCall(&call_buffer, .{
        .key = model_contract.bash_key,
        .arguments = admitted_arguments,
    });
    try created.storeContent(912, call);

    var descriptor_buffer: [bash_tool.max_descriptor_size]u8 = undefined;
    const wrong_descriptor = try bash_tool.encodeDescriptor(&descriptor_buffer, .{
        .workspace_path = created.workspacePath(),
        .working_directory = created.workspacePath(),
        .call = .{ .command = "false", .timeout_ms = 1_000 },
    });
    try created.storeContent(913, wrong_descriptor);
    var validation: model_protocol.ValidationScratch = undefined;
    try std.testing.expectError(
        error.InvalidActionDescriptor,
        created.admitModelCompletion(&slot, .{
            .operation_id = model_operation.id,
            .operation_generation = model_operation.generation,
            .attempt_id = 111,
            .evidence_epoch = created.ownership_epoch,
            .response_ref = 911,
            .response_digest = response_digest,
            .admission = model_protocol.admit(&validation, response).admission,
            .consequence = .{ .tool_call = .{
                .content_ref = 912,
                .action = .{ .bash = .{
                    .descriptor_ref = 913,
                    .call = try BashCallMaterial.init(.{
                        .command = "true",
                        .timeout_ms = 1_000,
                    }),
                } },
            } },
        }),
    );
    try std.testing.expectEqual(@as(?ConversationEntry, null), created.pending_conversation);

    const descriptor = try bash_tool.encodeDescriptor(&descriptor_buffer, .{
        .workspace_path = created.workspacePath(),
        .working_directory = created.workspacePath(),
        .call = .{ .command = "true", .timeout_ms = 1_000 },
    });
    try created.storeContent(914, descriptor);
    const completion = try created.admitModelCompletion(&slot, .{
        .operation_id = model_operation.id,
        .operation_generation = model_operation.generation,
        .attempt_id = 111,
        .evidence_epoch = created.ownership_epoch,
        .response_ref = 911,
        .response_digest = response_digest,
        .admission = model_protocol.admit(&validation, response).admission,
        .consequence = .{ .tool_call = .{
            .content_ref = 912,
            .action = .{ .bash = .{
                .descriptor_ref = 914,
                .call = try BashCallMaterial.init(.{
                    .command = "true",
                    .timeout_ms = 1_000,
                }),
            } },
        } },
    });
    const action_id = completion.action.?.operation_id;

    try created.storeContent(915, "action result");
    const result_digest = binding.hash(binding.Result, "action result");
    _ = try created.admitActionAttempt(.{
        .operation_id = action_id,
        .operation_generation = 1,
        .attempt_id = 121,
    });
    try created.publishCompletionEvidence(completion_inbox.bind(.{
        .kind = .bash,
        .session_id = created.session_id,
        .ownership_epoch = created.ownership_epoch,
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .operation_id = action_id,
        .operation_generation = 1,
        .attempt_id = 121,
        .result_ref = 915,
        .result_digest = result_digest,
    }));
    var action_result = ActionResultMaterial{
        .operation_id = action_id,
        .operation_generation = 1,
        .result_ref = 915,
        .result_digest = result_digest,
        .class = .ordinary,
        .evidence = .{ .durable = .{
            .attempt_id = 121,
            .ownership_epoch = created.ownership_epoch,
        } },
    };
    action_result.evidence.durable.ownership_epoch += 1;
    try std.testing.expectError(
        error.CompletionEvidenceMismatch,
        created.admitActionResult(action_result),
    );
    action_result.evidence.durable.ownership_epoch = created.ownership_epoch;
    action_result.result_ref = 916;
    try std.testing.expectError(
        error.CompletionEvidenceMismatch,
        created.admitActionResult(action_result),
    );
    action_result.result_ref = 915;
    action_result.result_digest = binding.hash(binding.Result, "substituted");
    try std.testing.expectError(
        error.CompletionEvidenceMismatch,
        created.admitActionResult(action_result),
    );
    action_result.result_digest = result_digest;
    action_result.evidence.durable.attempt_id = 122;
    try std.testing.expectError(
        error.InvalidAttemptHistory,
        created.admitActionResult(action_result),
    );
    action_result.evidence.durable.attempt_id = 121;
    _ = try created.admitActionResult(.{
        .operation_id = action_id,
        .operation_generation = 1,
        .result_ref = 915,
        .result_digest = result_digest,
        .class = .ordinary,
        .evidence = .{ .durable = .{
            .attempt_id = 121,
            .ownership_epoch = created.ownership_epoch,
        } },
    });
    var visible_buffer: [conversation.result_header_size + "success".len]u8 = undefined;
    const visible = try conversation.encodeToolResult(&visible_buffer, .{
        .parent_id = 2,
        .is_error = false,
        .content = "success",
    });
    try created.storeContent(916, visible);
    try std.testing.expectError(
        error.ResultApplicationMismatch,
        created.admitToolResult(&slot, .{
            .operation_id = action_id,
            .operation_generation = 1,
            .attempt_id = 121,
            .result_ref = 915,
            .result_digest = binding.hash(binding.Result, "substituted"),
            .visible_ref = 916,
        }),
    );
    try std.testing.expectEqual(@as(?ConversationEntry, null), created.pending_conversation);
    try created.admitToolResult(&slot, .{
        .operation_id = action_id,
        .operation_generation = 1,
        .attempt_id = 121,
        .result_ref = 915,
        .result_digest = result_digest,
        .visible_ref = 916,
    });
}

const PatchApprovalCase = enum {
    exact,
    substituted_intent_digest,
    substituted_patch,
};

fn runPatchApprovalCase(
    layout: *TestLayout,
    session_id: u64,
    prepared: patch_tool.Intent,
    patch: []const u8,
    case: PatchApprovalCase,
) !void {
    var created = try Session.createExact(
        layout.sessions,
        layout.scratch,
        &layout.storage,
        std.testing.io,
        testConfig(layout.workspacePath(), session_id),
    );
    defer created.close();

    try admitTestModelSource(&created, 1);
    const patch_ref = 700 + session_id;
    const intent_ref = 800 + session_id;
    var intent = prepared;
    intent.patch_ref = patch_ref;
    intent.patch_digest = patch_tool.patchDigest(patch);
    const stored_patch = switch (case) {
        .exact, .substituted_intent_digest => patch,
        .substituted_patch => "different patch bytes",
    };
    intent.intent_digest = patch_tool.intentDigest(intent);
    var intent_buffer: [patch_tool.max_intent_size]u8 = undefined;
    const intent_bytes = try patch_tool.encodeIntent(&intent_buffer, intent);
    try created.storeContent(patch_ref, stored_patch);
    try created.storeContent(intent_ref, intent_bytes);

    const descriptor_digest: binding.Descriptor = .{ .apply_patch = switch (case) {
        .substituted_intent_digest => binding.hash(binding.PatchIntent, "substituted"),
        .exact, .substituted_patch => intent.intent_digest,
    } };
    _ = try created.commitFactsForTest(&.{session_transition.operationAdmitted(
        created.operationContext(2, 1),
        .{ .operation_id = 1, .generation = 1 },
        intent_ref,
        descriptor_digest,
    )});

    switch (case) {
        .exact => {
            const request = try created.requestApproval(2, 1);
            try std.testing.expectEqual(patch_ref, request.descriptor_ref);
            try std.testing.expect(binding.descriptorEql(descriptor_digest, request.descriptor_digest));
            const view = try created.semanticView();
            try std.testing.expectEqual(intent_ref, view.consequential.approval_required.?.binding_ref);
            try std.testing.expectEqual(patch_ref, view.consequential.approval_required.?.descriptor_ref);
        },
        .substituted_intent_digest, .substituted_patch => try std.testing.expectError(
            error.InvalidApprovalBinding,
            created.requestApproval(2, 1),
        ),
    }
}

test "Session derives patch approval from the exact admitted Intent and patch" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var file = try layout.workspace.createFile(io, "note.txt", .{});
    try file.writeStreamingAll(io, "old\n");
    file.close(io);
    try addTestGitPath(io, layout.workspacePath(), "note.txt");
    const patch =
        "diff --git a/note.txt b/note.txt\n" ++
        "index 3367afd..3e75765 100644\n" ++
        "--- a/note.txt\n" ++
        "+++ b/note.txt\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+new\n";
    var canonical_workspace: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const canonical_length = try std.Io.Dir.cwd().realPathFile(
        io,
        layout.workspacePath(),
        &canonical_workspace,
    );
    const prepared = try patch_tool.prepare(
        io,
        canonical_workspace[0..canonical_length],
        patch,
        .{ .patch_ref = 1 },
    );
    try runPatchApprovalCase(&layout, 820, prepared, patch, .substituted_intent_digest);
    try runPatchApprovalCase(&layout, 830, prepared, patch, .substituted_patch);
    try runPatchApprovalCase(&layout, 840, prepared, patch, .exact);
}

test "Semantic View validates Action source and opaque Operation identity" {
    const agent: session_transition.AgentContext = .{
        .agent_id = 7,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    const model: session_transition.OperationContext = .{
        .agent = agent,
        .operation_id = 41,
        .generation = 1,
    };
    var view: SemanticView = .{};
    var model_admission: session_transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
    model_admission.facts[0] = session_transition.operationAdmitted(
        model,
        .{ .operation_id = model.operation_id, .generation = model.generation },
        43,
        testDescriptor("model"),
    );
    try std.testing.expectError(error.InvalidSourceOperation, view.apply(model_admission));
    model_admission.facts[0] = session_transition.operationAdmitted(
        model,
        null,
        43,
        testDescriptor("model"),
    );
    try view.apply(model_admission);

    const action: session_transition.OperationContext = .{
        .agent = agent,
        .operation_id = 77,
        .generation = 1,
    };
    const action_descriptor: binding.Descriptor = .{
        .bash = binding.hash(binding.BashDescriptor, "bash descriptor"),
    };
    var action_admission: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    action_admission.facts[0] = session_transition.operationAdmitted(
        action,
        .{ .operation_id = model.operation_id, .generation = model.generation },
        79,
        action_descriptor,
    );
    var admitted = view;
    try admitted.apply(action_admission);
    try std.testing.expectEqual(binding.DescriptorKind.bash, admitted.consequential.kind().?);
    try std.testing.expectEqual(
        session_transition.OperationIdentity{ .operation_id = model.operation_id, .generation = model.generation },
        admitted.consequential.descriptor.?.source_operation.?,
    );
    try std.testing.expectEqual(action.operation_id, admitted.consequential.operation_id);

    action_admission.facts[0] = session_transition.operationAdmitted(
        action,
        .{ .operation_id = model.operation_id + 1, .generation = model.generation },
        79,
        action_descriptor,
    );
    try std.testing.expectError(error.InvalidSourceOperation, view.apply(action_admission));

    action_admission.facts[0] = session_transition.operationAdmitted(
        action,
        .{ .operation_id = model.operation_id, .generation = model.generation + 1 },
        79,
        action_descriptor,
    );
    try std.testing.expectError(error.InvalidSourceOperation, view.apply(action_admission));

    var reused_model = model_admission;
    reused_model.sequence = 2;
    reused_model.facts[0] = session_transition.operationAdmitted(
        .{ .agent = agent, .operation_id = model.operation_id, .generation = model.generation + 1 },
        null,
        43,
        testDescriptor("model"),
    );
    var replaced = view;
    try std.testing.expectError(error.OperationIdentityCollision, replaced.apply(reused_model));

    action_admission.sequence = 2;
    action_admission.facts[0] = session_transition.operationAdmitted(
        model,
        .{ .operation_id = model.operation_id, .generation = model.generation },
        79,
        action_descriptor,
    );
    try std.testing.expectError(error.OperationIdentityCollision, view.apply(action_admission));
}

test "child facts cannot reclassify an admitted Action descriptor" {
    const agent: session_transition.AgentContext = .{
        .agent_id = 9,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    const model: session_transition.OperationContext = .{
        .agent = agent,
        .operation_id = 51,
        .generation = 2,
    };
    const action: session_transition.OperationContext = .{
        .agent = agent,
        .operation_id = 52,
        .generation = 1,
    };
    const bash_descriptor: binding.Descriptor = .{
        .bash = binding.hash(binding.BashDescriptor, "bash"),
    };
    var view: SemanticView = .{};
    var admitted: session_transition.Transaction = .{ .sequence = 1, .fact_count = 2 };
    admitted.facts[0] = session_transition.operationAdmitted(model, null, 61, testDescriptor("model"));
    admitted.facts[1] = session_transition.operationAdmitted(
        action,
        .{ .operation_id = model.operation_id, .generation = model.generation },
        62,
        bash_descriptor,
    );
    try view.apply(admitted);

    var mismatched_attempt: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    mismatched_attempt.facts[0] = session_transition.consequentialAttemptAdmitted(
        action,
        63,
        62,
        .{ .apply_patch = binding.hash(binding.PatchIntent, "patch") },
    );
    try std.testing.expectError(error.AttemptDescriptorMismatch, view.apply(mismatched_attempt));

    var mismatched_authorization: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    mismatched_authorization.facts[0] = session_transition.authorization(.{
        .operation = action,
        .permission_ref = 62,
        .allowed = true,
    });
    try std.testing.expectError(
        error.AuthorizationDescriptorMismatch,
        view.apply(mismatched_authorization),
    );
}

test "irrelevant inbox records cannot displace admitted Attempt evidence" {
    const agent: session_transition.AgentContext = .{
        .agent_id = 1,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    const operation: session_transition.OperationContext = .{
        .agent = agent,
        .operation_id = 10,
        .generation = 1,
    };
    var semantic: SemanticView = .{};
    var admission: session_transition.Transaction = .{ .sequence = 1, .fact_count = 2 };
    admission.facts[0] = session_transition.operationAdmitted(operation, null, 11, testDescriptor("12"));
    admission.facts[1] = session_transition.modelAttemptAdmitted(
        operation,
        13,
        11,
        testDescriptor("12"),
        0,
    );
    try semantic.apply(admission);

    var inbox: InboxIndex = .{};
    const relevant = completion_inbox.bind(.{
        .kind = .model,
        .session_id = 1,
        .ownership_epoch = 1,
        .agent_id = 1,
        .agent_generation = 1,
        .operation_id = 10,
        .operation_generation = 1,
        .attempt_id = 13,
        .result_ref = 14,
        .result_digest = testResultDigest("15"),
    });
    var misrouted = relevant;
    misrouted.session_id = 99;
    misrouted.result_ref = 98;
    _ = try inbox.apply(&semantic, testReboundEnvelope(misrouted), 1, 1, 1);
    _ = try inbox.apply(&semantic, relevant, 1, 1, 1);
    for (0..16) |index| {
        var irrelevant = relevant;
        irrelevant.operation_id = 100 + index;
        irrelevant.attempt_id = 200 + index;
        _ = try inbox.apply(&semantic, testReboundEnvelope(irrelevant), 1, 1, 1);
    }
    var future = relevant;
    future.ownership_epoch = 2;
    future.result_ref = 99;
    _ = try inbox.apply(&semantic, testReboundEnvelope(future), 1, 1, 1);
    try std.testing.expectEqualDeep(relevant, inbox.entries[0].?);
}

test "late evidence for an earlier model Attempt survives a later admission" {
    const agent: session_transition.AgentContext = .{
        .agent_id = 1,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    const operation: session_transition.OperationContext = .{
        .agent = agent,
        .operation_id = 10,
        .generation = 1,
    };
    var semantic: SemanticView = .{};
    var first: session_transition.Transaction = .{ .sequence = 1, .fact_count = 2 };
    first.facts[0] = session_transition.operationAdmitted(operation, null, 11, testDescriptor("12"));
    first.facts[1] = session_transition.modelAttemptAdmitted(operation, 13, 11, testDescriptor("12"), 0);
    try semantic.apply(first);
    var retry: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    retry.facts[0] = session_transition.modelAttemptAdmitted(operation, 14, 11, testDescriptor("12"), 1);
    try semantic.apply(retry);

    var inbox: InboxIndex = .{};
    const late = completion_inbox.bind(.{
        .kind = .model,
        .session_id = 1,
        .ownership_epoch = 1,
        .agent_id = 1,
        .agent_generation = 1,
        .operation_id = 10,
        .operation_generation = 1,
        .attempt_id = 13,
        .result_ref = 15,
        .result_digest = testResultDigest("16"),
    });
    _ = try inbox.apply(&semantic, late, 1, 1, 1);
    try std.testing.expectEqual(@as(u8, 2), semantic.model.attempt_count);
    try std.testing.expectEqualDeep(late, inbox.entries[0].?);
}

test "conflicting Inbox evidence becomes non-authoritative ambiguity" {
    const agent: session_transition.AgentContext = .{
        .agent_id = 1,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    const operation: session_transition.OperationContext = .{
        .agent = agent,
        .operation_id = 10,
        .generation = 1,
    };
    var semantic: SemanticView = .{};
    var admission: session_transition.Transaction = .{ .sequence = 1, .fact_count = 2 };
    admission.facts[0] = session_transition.operationAdmitted(operation, null, 11, testDescriptor("12"));
    admission.facts[1] = session_transition.modelAttemptAdmitted(
        operation,
        13,
        11,
        testDescriptor("12"),
        0,
    );
    try semantic.apply(admission);
    var inbox: InboxIndex = .{};
    const first = completion_inbox.bind(.{
        .kind = .model,
        .session_id = 1,
        .ownership_epoch = 1,
        .agent_id = 1,
        .agent_generation = 1,
        .operation_id = 10,
        .operation_generation = 1,
        .attempt_id = 13,
        .result_ref = 14,
        .result_digest = testResultDigest("15"),
    });
    _ = try inbox.apply(&semantic, first, 1, 1, 1);
    var conflicting = first;
    conflicting.result_ref = 16;
    conflicting.result_digest = testResultDigest("17");
    _ = try inbox.apply(&semantic, testReboundEnvelope(conflicting), 1, 1, 1);
    try std.testing.expect(inbox.entries[0] == null);
    try std.testing.expect(inbox.ambiguous[0].?.matches(first));
}

test "failed recovered frame leaves the published semantic index unchanged" {
    const agent: session_transition.AgentContext = .{
        .agent_id = 1,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    const operation: session_transition.OperationContext = .{
        .agent = agent,
        .operation_id = 10,
        .generation = 1,
    };
    var index: SemanticView = .{};
    var admission: session_transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
    admission.facts[0] = session_transition.operationAdmitted(operation, null, 11, testDescriptor("12"));
    try index.apply(admission);

    var invalid: session_transition.Transaction = .{ .sequence = 2, .fact_count = 2 };
    invalid.facts[0] = session_transition.authorization(.{
        .operation = operation,
        .permission_ref = 11,
        .allowed = true,
    });
    invalid.facts[1] = session_transition.modelAttemptAdmitted(
        .{
            .agent = agent,
            .operation_id = 99,
            .generation = 1,
        },
        13,
        11,
        testDescriptor("12"),
        0,
    );
    var prepared = index;
    try std.testing.expectError(error.InvalidAuthorizationDescriptor, prepared.apply(invalid));
    try std.testing.expectEqual(@as(u64, 1), index.last_sequence);
    try std.testing.expect(index.model.authorization == null);
}

test "conversation advances only after its Ledger fact commits" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, testConfig(layout.workspacePath(), 20));
    defer created.close();
    try created.storeContent(900, "The test is fixed.");
    const assistant = try created.appendConversationForTest(.assistant_text, 900, null);

    try std.testing.expectEqual(@as(u64, 2), assistant.entry_id);
    try std.testing.expectEqual(@as(u64, 1), assistant.parent_id);
    try std.testing.expectEqual(@as(u64, 1), created.activeLeafId());
    try std.testing.expectError(error.InvalidEntrySequence, created.readEntry(2));
    _ = try created.commitFactsForTest(&.{session_transition.conversationAdvanced(.{
        .agent = .{
            .agent_id = created.agent_id,
            .agent_generation = 1,
            .ownership_epoch = created.ownership_epoch,
        },
        .entry_id = assistant.entry_id,
        .parent_id = assistant.parent_id,
        .kind = assistant.kind,
        .content_ref = assistant.content_ref,
    })});
    try std.testing.expectEqual(@as(u64, 2), created.activeLeafId());
    const stored = try created.readEntry(2);
    try std.testing.expectEqualDeep(assistant, stored);

    var response_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "The test is fixed.",
        try created.readContent(900, 0, &response_buffer),
    );
}

test "prepared Conversation content is validated at commit" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, testConfig(layout.workspacePath(), 35));
    defer created.close();
    try created.storeContent(900, &.{ 0xff, 0xfe });
    const assistant = try created.appendConversationForTest(.assistant_text, 900, null);

    try std.testing.expectError(
        error.InvalidConversationContent,
        created.commitFactsForTest(&.{session_transition.conversationAdvanced(.{
            .agent = .{
                .agent_id = created.agent_id,
                .agent_generation = 1,
                .ownership_epoch = created.ownership_epoch,
            },
            .entry_id = assistant.entry_id,
            .parent_id = assistant.parent_id,
            .kind = assistant.kind,
            .content_ref = assistant.content_ref,
        })}),
    );
    try std.testing.expectEqual(@as(u64, 1), created.activeLeafId());
}

test "conversation grammar rejects orphaned and unpaired tool entries during recovery" {
    const agent: session_transition.AgentContext = .{
        .agent_id = 1,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    var root: session_transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
    root.facts[0] = session_transition.conversationAdvanced(.{
        .agent = agent,
        .entry_id = 1,
        .parent_id = 0,
        .kind = .user_text,
        .content_ref = 10,
    });
    const resident = try (ResidentState{}).applyingLedger(root, 1, 1);

    var orphan: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    orphan.facts[0] = session_transition.conversationAdvanced(.{
        .agent = agent,
        .entry_id = 2,
        .parent_id = 1,
        .kind = .tool_result,
        .content_ref = 11,
    });
    try std.testing.expectError(error.InvalidConversationGrammar, resident.applyingLedger(orphan, 1, 1));

    var call: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    call.facts[0] = session_transition.conversationAdvanced(.{
        .agent = agent,
        .entry_id = 2,
        .parent_id = 1,
        .kind = .tool_call,
        .content_ref = 12,
    });
    const awaiting_result = try resident.applyingLedger(call, 1, 1);
    var non_result: session_transition.Transaction = .{ .sequence = 3, .fact_count = 1 };
    non_result.facts[0] = session_transition.conversationAdvanced(.{
        .agent = agent,
        .entry_id = 3,
        .parent_id = 2,
        .kind = .assistant_text,
        .content_ref = 13,
    });
    try std.testing.expectError(
        error.InvalidConversationGrammar,
        awaiting_result.applyingLedger(non_result, 1, 1),
    );
}

test "Conversation UTF-8 validation carries split sequences across bounded windows" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, testConfig(layout.workspacePath(), 25));
    defer created.close();
    var content: [4098]u8 = @splat('a');
    @memcpy(content[4095..], "€");
    try created.storeContent(990, &content);
    var valid = try created.viewContent(990);
    try validateUtf8ConversationWindows(&valid, 0, valid.length());

    content[4096] = 'x';
    try created.storeContent(991, &content);
    var invalid = try created.viewContent(991);
    try std.testing.expectError(
        error.InvalidConversationContent,
        validateUtf8ConversationWindows(&invalid, 0, invalid.length()),
    );
}

test "tool-call recovery trusts admitted exact-byte identity without reparsing JSON" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(
        layout.sessions,
        layout.scratch,
        &layout.storage,
        io,
        testConfig(layout.workspacePath(), 21),
    );
    defer created.close();

    const key = "fixture.inspect.v1";
    const admitted_arguments = "{ \"command\" : \"echo exact bytes\", \"timeout_ms\" : 1000 }";
    var call: [conversation.call_header_size + key.len + admitted_arguments.len]u8 = undefined;
    _ = try conversation.encodeToolCallHeader(
        &call,
        key.len,
        admitted_arguments.len,
        model_contract.strictToolJsonDigest(admitted_arguments),
    );
    @memcpy(call[conversation.call_header_size..][0..key.len], key);
    @memcpy(call[conversation.call_header_size + key.len ..], admitted_arguments);
    try created.storeContent(901, &call);
    try created.validateConversationContent(.tool_call, 901, 1);

    call[0] = 0;
    try created.storeContent(902, &call);
    try std.testing.expectError(
        error.InvalidConversationContent,
        created.validateConversationContent(.tool_call, 902, 1),
    );
}

const AppendCrash = struct {
    fn reached(_: *anyopaque, boundary: AppendBoundary) anyerror!void {
        if (boundary == .after_entry_sync) return error.InjectedCrash;
    }
};

test "resume leaves an uncommitted conversation record invisible" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var marker: u8 = 0;
    var created = try Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, testConfig(layout.workspacePath(), 30));
    try created.storeContent(901, "uncommitted assistant text");
    try std.testing.expectError(
        error.InjectedCrash,
        created.appendConversationForTest(.assistant_text, 901, .{
            .context = &marker,
            .reached = AppendCrash.reached,
        }),
    );
    try std.testing.expectEqual(@as(u64, 1), created.activeLeafId());
    try std.testing.expectError(error.SessionUnavailable, created.authorize(created.ownerToken()));
    created.close();

    var restored = try Session.openExisting(layout.sessions, layout.scratch, &layout.storage, io, 30);
    defer restored.close();
    try std.testing.expectEqual(@as(u64, 0), restored.activeLeafId());
    _ = try restored.recoverSemanticWindow(8);
    try std.testing.expectEqual(@as(u64, 1), restored.activeLeafId());
    try std.testing.expectEqual(@as(u64, 1), restored.entryCount());
    try std.testing.expectError(error.InvalidEntrySequence, restored.readEntry(2));
}

test "repeating task text creates a distinct session" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    const config: Config = .{
        .workspace_path = layout.workspacePath(),
        .model = "fixture:repair",
        .task = "Fix the failing test",
    };
    var first = try Session.create(layout.sessions, layout.scratch, &layout.storage, io, config);
    defer first.close();
    const second_scratch = try allocateTransientScratch(std.testing.allocator);
    defer destroyTransientScratch(std.testing.allocator, io, second_scratch);
    var second = try Session.create(layout.sessions, second_scratch, &layout.storage, io, config);
    defer second.close();

    try std.testing.expect(first.session_id != second.session_id);
    try std.testing.expect(first.agent_id != second.agent_id);
    try std.testing.expect(first.task_id != second.task_id);
}

test "creation rejects non Git workspaces and aliased identities" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "sessions", .default_dir);
    try tmp.dir.createDir(io, "plain", .default_dir);
    var sessions = try tmp.dir.openDir(io, "sessions", .{});
    defer sessions.close(io);
    var plain = try tmp.dir.openDir(io, "plain", .{});
    defer plain.close(io);
    var database_path_buffer: [128]u8 = undefined;
    const database_path = try std.fmt.bufPrint(
        &database_path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var storage = try host_store.StorageOwner.open(io, database_path, .{});
    defer storage.close();
    const scratch = try allocateTransientScratch(std.testing.allocator);
    defer destroyTransientScratch(std.testing.allocator, io, scratch);

    var plain_path_buffer: [128]u8 = undefined;
    const plain_path = try std.fmt.bufPrint(
        &plain_path_buffer,
        ".zig-cache/tmp/{s}/plain",
        .{tmp.sub_path},
    );
    try std.testing.expectError(
        error.NotGitWorktree,
        Session.createExact(sessions, scratch, &storage, io, testConfig(plain_path, 60)),
    );

    try initTestGitWorktree(plain, io);
    var invalid = testConfig(plain_path, 70);
    invalid.identities.agent_id = invalid.identities.session_id;
    try std.testing.expectError(
        error.InvalidIdentity,
        Session.createExact(sessions, scratch, &storage, io, invalid),
    );

    var oversized_bytes: [host_store.max_model_bytes + 1]u8 = undefined;
    @memset(&oversized_bytes, 'x');
    var oversized = testConfig(plain_path, 75);
    oversized.model = &oversized_bytes;
    try std.testing.expectError(
        error.InvalidSessionMetadata,
        Session.createExact(sessions, scratch, &storage, io, oversized),
    );
    var name_buffer: [16]u8 = undefined;
    try std.testing.expectError(
        error.FileNotFound,
        sessions.access(io, sessionName(75, &name_buffer), .{}),
    );
}

test "session metadata has no per-session manifest projection" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, testConfig(layout.workspacePath(), 80));
    created.close();

    var name_buffer: [16]u8 = undefined;
    try std.testing.expectError(
        error.FileNotFound,
        layout.sessions.access(io, sessionName(80, &name_buffer), .{}),
    );
    var restored = try Session.openExisting(layout.sessions, layout.scratch, &layout.storage, io, 80);
    defer restored.close();
    try std.testing.expectEqual(@as(u64, 2), restored.ownership_epoch);
}

test "transient scratch is an opaque pointer-stable borrowed capability" {
    const scratch = try allocateTransientScratch(std.testing.allocator);
    defer destroyTransientScratch(std.testing.allocator, std.testing.io, scratch);

    const borrowed = scratch;
    try bindTransientScratch(scratch);
    defer releaseTransientScratch(scratch, std.testing.io);
    try std.testing.expectEqual(scratch, borrowed);
    try std.testing.expectError(error.TransientScratchAlreadyBound, bindTransientScratch(borrowed));
    try ensureTransientScratchBound(borrowed);
}

test "pending content cap accepts the three-value patch admission closure" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(
        layout.sessions,
        layout.scratch,
        &layout.storage,
        io,
        testConfig(layout.workspacePath(), 83),
    );
    defer created.close();

    var facts: [max_pending_content]session_transition.Fact = undefined;
    const agent: session_transition.AgentContext = .{
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .ownership_epoch = created.ownership_epoch,
    };
    for (0..max_pending_content) |index| {
        const reference: u64 = 100 + index;
        var writer = try created.beginContent(reference);
        try writer.append("x");
        try writer.finish();
        facts[index] = session_transition.outcome(agent, index + 1, reference);
    }
    try std.testing.expectError(
        error.PendingContentCapacityExceeded,
        created.beginContent(100 + max_pending_content),
    );
    _ = try created.commitFactsForTest(&facts);
    try std.testing.expectEqual(@as(u64, 0), try created.transientScratchOccupancy());
    for (transientScratchState(created.scratch).pending) |pending| try std.testing.expect(pending == null);
}

test "committing one pending maximum value reuses only its scratch slot" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(
        layout.sessions,
        layout.scratch,
        &layout.storage,
        io,
        testConfig(layout.workspacePath(), 84),
    );
    defer created.close();

    const bytes_a = [_]u8{'A'} ** host_store.max_content_bytes;
    const bytes_b = [_]u8{'B'} ** host_store.max_content_bytes;
    const bytes_c = [_]u8{'C'} ** host_store.max_content_bytes;
    const bytes_d = [_]u8{'D'} ** host_store.max_content_bytes;
    const agent: session_transition.AgentContext = .{
        .agent_id = created.agent_id,
        .agent_generation = 1,
        .ownership_epoch = created.ownership_epoch,
    };

    try created.storeContent(200, &bytes_a);
    try created.storeContent(201, &bytes_b);
    try created.storeContent(202, &bytes_c);
    try std.testing.expectError(error.PendingContentCapacityExceeded, created.beginContent(203));

    const first = [_]session_transition.Fact{session_transition.outcome(agent, 1, 200)};
    _ = try created.commitFactsForTest(&first);

    var writer = try created.beginContent(203);
    try std.testing.expectEqual(@as(u64, 0), writer.start_offset);
    try writer.append(&bytes_d);
    try writer.finish();

    var retained: [1]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "B", try created.readContent(201, 0, &retained));
    try std.testing.expectEqualSlices(u8, "C", try created.readContent(202, 0, &retained));

    const rest = [_]session_transition.Fact{
        session_transition.outcome(agent, 2, 201),
        session_transition.outcome(agent, 3, 202),
        session_transition.outcome(agent, 4, 203),
    };
    _ = try created.commitFactsForTest(&rest);
    try std.testing.expectEqual(@as(u64, 0), try created.transientScratchOccupancy());
}

test "resume reserves pointer-stable scratch before claiming ownership" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(
        layout.sessions,
        layout.scratch,
        &layout.storage,
        io,
        testConfig(layout.workspacePath(), 82),
    );
    created.close();

    try bindTransientScratch(layout.scratch);
    defer releaseTransientScratch(layout.scratch, io);
    try std.testing.expectError(
        error.TransientScratchAlreadyBound,
        Session.openExisting(layout.sessions, layout.scratch, &layout.storage, io, 82),
    );
    const stored = try layout.storage.readSession(82);
    try std.testing.expectEqual(@as(u64, 1), stored.ownership_epoch);
}

test "resume rejects a missing recorded workspace before advancing ownership" {
    const io = std.testing.io;
    var layout = try TestLayout.init(io);
    defer layout.deinit(io);
    var created = try Session.createExact(layout.sessions, layout.scratch, &layout.storage, io, testConfig(layout.workspacePath(), 85));
    created.close();
    layout.workspace.close(io);
    try layout.tmp.dir.rename("repo", layout.tmp.dir, "moved", io);
    layout.workspace = try layout.tmp.dir.openDir(io, "moved", .{});

    try std.testing.expectError(
        error.WorkspaceUnavailable,
        Session.openExisting(layout.sessions, layout.scratch, &layout.storage, io, 85),
    );
    const stored = try layout.storage.readSession(85);
    try std.testing.expectEqual(@as(u64, 1), stored.ownership_epoch);
}
