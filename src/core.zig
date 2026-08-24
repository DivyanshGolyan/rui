const std = @import("std");

const magic: u32 = 0x4f4e4550;

const OperationState = enum(u32) {
    idle = 0,
    submitted = 1,
    accepted = 2,
    completed = 3,
};

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

comptime {
    std.debug.assert(@sizeOf(State) == 64);
    std.debug.assert(@alignOf(State) <= 8);
}
