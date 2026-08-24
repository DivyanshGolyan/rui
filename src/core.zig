const std = @import("std");

const magic: u32 = 0x4f4e4550;

const State = extern struct {
    magic: u32,
    agent_id: u32,
    event_count: u64,
    accumulator: u64,
    last_event: u32,
    yielded: u32,
};

var state: State = .{
    .magic = magic,
    .agent_id = 0,
    .event_count = 0,
    .accumulator = 0,
    .last_event = 0,
    .yielded = 1,
};

export fn initialize(agent_id: u32) void {
    state = .{
        .magic = magic,
        .agent_id = agent_id,
        .event_count = 0,
        .accumulator = agent_id,
        .last_event = 0,
        .yielded = 1,
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

comptime {
    std.debug.assert(@sizeOf(State) == 32);
    std.debug.assert(@alignOf(State) <= 8);
}
