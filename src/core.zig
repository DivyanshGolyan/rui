const std = @import("std");
const model_protocol = @import("model_protocol.zig");

const magic: u32 = 0x4f4e4550;

const OperationState = enum(u32) {
    idle = 0,
    submitted = 1,
    accepted = 2,
    completed = 3,
};

const TaskPhase = enum(u32) {
    idle = 0,
    ready = 1,
    awaiting_model = 2,
    final_candidate = 3,
    awaiting_tool = 4,
    finished = 5,
    failed = 6,
};

const response_memory_offset: u32 = 8 * 1024;
const response_memory_end: u32 = response_memory_offset + model_protocol.max_response_size;

const State = extern struct {
    magic: u32,
    agent_id: u32,
    event_count: u64,
    accumulator: u64,
    last_event: u32,
    yielded: u32,
    operation_id: u64,
    operation_generation: u32,
    operation_state: OperationState,
    operation_result: u64,
    operation_sequence: u64,
    active_leaf_id: u64,
    final_entry_id: u64,
    response_ref: u64,
    task_phase: TaskPhase,
    response_disposition: u32,
    response_failure: u32,
    context_first: u32,
    context_count: u32,
    response_text_offset: u32,
    response_text_length: u32,
};

var state: State = .{
    .magic = magic,
    .agent_id = 0,
    .event_count = 0,
    .accumulator = 0,
    .last_event = 0,
    .yielded = 1,
    .operation_id = 0,
    .operation_generation = 0,
    .operation_state = .idle,
    .operation_result = 0,
    .operation_sequence = 0,
    .active_leaf_id = 0,
    .final_entry_id = 0,
    .response_ref = 0,
    .task_phase = .idle,
    .response_disposition = 0,
    .response_failure = 0,
    .context_first = 0,
    .context_count = 0,
    .response_text_offset = 0,
    .response_text_length = 0,
};

export fn initialize(agent_id: u32) void {
    state = .{
        .magic = magic,
        .agent_id = agent_id,
        .event_count = 0,
        .accumulator = agent_id,
        .last_event = 0,
        .yielded = 1,
        .operation_id = 0,
        .operation_generation = 0,
        .operation_state = .idle,
        .operation_result = 0,
        .operation_sequence = 0,
        .active_leaf_id = 0,
        .final_entry_id = 0,
        .response_ref = 0,
        .task_phase = .idle,
        .response_disposition = 0,
        .response_failure = 0,
        .context_first = 0,
        .context_count = 0,
        .response_text_offset = 0,
        .response_text_length = 0,
    };
}

export fn deliver(event: u32) u32 {
    if (state.magic != magic or state.yielded != 1) return 0;

    state.yielded = 0;
    state.event_count +%= 1;
    state.last_event = event;
    state.accumulator = (state.accumulator *% 16_777_619) ^ event;
    state.yielded = 1;
    return 1;
}

export fn agentId() u32 {
    return state.agent_id;
}

export fn eventCount() u64 {
    return state.event_count;
}

export fn accumulator() u64 {
    return state.accumulator;
}

export fn isQuiescent() u32 {
    return state.yielded;
}

export fn submitOperation(operation_id: u32, sequence: u32) u32 {
    if (state.magic != magic or state.yielded != 1 or operation_id == 0 or sequence == 0) return 0;
    if (state.operation_state != .idle and state.operation_state != .completed) return 0;
    if (state.operation_generation == std.math.maxInt(u32)) return 0;

    state.yielded = 0;
    state.operation_id = operation_id;
    state.operation_generation += 1;
    state.operation_state = .submitted;
    state.operation_result = 0;
    state.operation_sequence = sequence;
    state.yielded = 1;
    return 1;
}

export fn acceptOperation(operation_id: u32, operation_generation: u32) u32 {
    if (state.magic != magic or state.yielded != 1) return 0;
    if (state.operation_state != .submitted or
        state.operation_id != operation_id or
        state.operation_generation != operation_generation)
    {
        return 0;
    }

    state.yielded = 0;
    state.operation_state = .accepted;
    state.yielded = 1;
    return 1;
}

export fn completeOperation(operation_id: u32, operation_generation: u32, result: u32) u32 {
    if (state.magic != magic or state.yielded != 1) return 0;
    if (state.operation_state != .accepted or
        state.operation_id != operation_id or
        state.operation_generation != operation_generation)
    {
        return 0;
    }

    state.yielded = 0;
    state.operation_result = result;
    state.operation_state = .completed;
    state.yielded = 1;
    return 1;
}

export fn operationState() u32 {
    return @intFromEnum(state.operation_state);
}

export fn operationId() u64 {
    return state.operation_id;
}

export fn operationGeneration() u32 {
    return state.operation_generation;
}

export fn operationResult() u64 {
    return state.operation_result;
}

export fn startTask(active_leaf_id: u32) u32 {
    if (state.magic != magic or state.yielded != 1 or active_leaf_id == 0) return 0;
    if (state.task_phase != .idle or state.operation_state != .idle) return 0;
    state.yielded = 0;
    state.active_leaf_id = active_leaf_id;
    state.task_phase = .ready;
    state.yielded = 1;
    return 1;
}

export fn beginModelOperation(operation_id: u32, sequence: u32) u32 {
    if (state.task_phase != .ready or state.active_leaf_id > std.math.maxInt(u32)) return 0;
    if (submitOperation(operation_id, sequence) != 1) return 0;
    state.context_first = 1;
    state.context_count = @intCast(state.active_leaf_id);
    state.response_ref = 0;
    state.response_disposition = 0;
    state.response_failure = 0;
    state.response_text_offset = 0;
    state.response_text_length = 0;
    state.task_phase = .awaiting_model;
    return 1;
}

export fn interpretModelResponse(offset: u32, length: u32, response_ref: u32) u32 {
    if (state.magic != magic or state.yielded != 1 or response_ref == 0) return 0;
    if (state.task_phase != .awaiting_model or
        state.operation_state != .completed or
        state.operation_result != response_ref or
        offset < response_memory_offset or
        length == 0 or
        length > model_protocol.max_response_size or
        offset > response_memory_end - length)
    {
        return 0;
    }

    state.yielded = 0;
    const pointer: [*]const u8 = @ptrFromInt(offset);
    const parsed = model_protocol.parse(pointer[0..length]);
    state.response_ref = response_ref;
    state.response_disposition = @intFromEnum(parsed.disposition);
    state.response_failure = @intFromEnum(parsed.failure);
    state.response_text_offset = offset + parsed.text_offset;
    state.response_text_length = parsed.text_length;
    state.task_phase = switch (parsed.disposition) {
        .final_answer => .final_candidate,
        .tool_call => .awaiting_tool,
        .failure => .failed,
    };
    state.yielded = 1;
    return 1;
}

export fn commitFinalAnswer(entry_id: u32) u32 {
    if (state.magic != magic or state.yielded != 1 or entry_id == 0) return 0;
    if (state.task_phase != .final_candidate or entry_id != state.active_leaf_id + 1) return 0;
    state.yielded = 0;
    state.active_leaf_id = entry_id;
    state.final_entry_id = entry_id;
    state.task_phase = .finished;
    state.yielded = 1;
    return 1;
}

export fn contextFirst() u32 {
    return state.context_first;
}

export fn contextCount() u32 {
    return state.context_count;
}

export fn responseDisposition() u32 {
    return state.response_disposition;
}

export fn responseFailure() u32 {
    return state.response_failure;
}

export fn responseTextOffset() u32 {
    return state.response_text_offset;
}

export fn responseTextLength() u32 {
    return state.response_text_length;
}

export fn taskOutcome() u32 {
    return @intFromEnum(state.task_phase);
}

export fn finalEntryId() u64 {
    return state.final_entry_id;
}

comptime {
    std.debug.assert(@sizeOf(State) <= 128);
    std.debug.assert(@alignOf(State) <= 8);
}
