const std = @import("std");
const model_protocol = @import("model_protocol.zig");

pub const page_size = 64 * 1024;
pub const wasm_stack_size = 4 * 1024;
pub const state_memory_offset = 8 * 1024;
pub const response_memory_offset = 12 * 1024;
pub const abi_version: u32 = 1;
pub const abi_fingerprint: u64 = 0x4f4e4550_0001_0001;

const magic: u32 = 0x4f4e4550;
const payload_size = page_size - state_memory_offset;
const response_offset_in_payload = response_memory_offset - state_memory_offset;

pub const OperationState = enum(u32) {
    idle = 0,
    submitted = 1,
    accepted = 2,
    completed = 3,
};

pub const TaskPhase = enum(u32) {
    idle = 0,
    ready = 1,
    awaiting_model = 2,
    final_candidate = 3,
    awaiting_tool = 4,
    finished = 5,
    failed = 6,
};

pub const State = extern struct {
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
    response_tool: u32,
    response_arguments_offset: u32,
    response_arguments_length: u32,
};

const prefix_padding_size = response_offset_in_payload - @sizeOf(State);
const reserved_size = payload_size - response_offset_in_payload - model_protocol.max_response_size;

pub const Payload = extern struct {
    state: State,
    prefix_padding: [prefix_padding_size]u8,
    response: [model_protocol.max_response_size]u8,
    reserved: [reserved_size]u8,

    pub fn initialize(self: *Payload, agent_id: u32) void {
        @memset(std.mem.asBytes(self), 0);
        self.state = initialState(agent_id);
    }

    pub fn deliver(self: *Payload, event: u32) bool {
        if (!self.validAndQuiescent()) return false;
        self.state.yielded = 0;
        self.state.event_count +%= 1;
        self.state.last_event = event;
        self.state.accumulator = (self.state.accumulator *% 16_777_619) ^ event;
        self.state.yielded = 1;
        return true;
    }

    pub fn submitOperation(self: *Payload, operation_id: u32, sequence: u32) bool {
        if (!self.validAndQuiescent() or operation_id == 0 or sequence == 0) return false;
        if (self.state.operation_state != .idle and self.state.operation_state != .completed) return false;
        if (self.state.operation_generation == std.math.maxInt(u32)) return false;

        self.state.yielded = 0;
        self.state.operation_id = operation_id;
        self.state.operation_generation += 1;
        self.state.operation_state = .submitted;
        self.state.operation_result = 0;
        self.state.operation_sequence = sequence;
        self.state.yielded = 1;
        return true;
    }

    pub fn acceptOperation(self: *Payload, operation_id: u32, operation_generation: u32) bool {
        if (!self.validAndQuiescent()) return false;
        if (self.state.operation_state != .submitted or
            self.state.operation_id != operation_id or
            self.state.operation_generation != operation_generation)
        {
            return false;
        }

        self.state.yielded = 0;
        self.state.operation_state = .accepted;
        self.state.yielded = 1;
        return true;
    }

    pub fn completeOperation(
        self: *Payload,
        operation_id: u32,
        operation_generation: u32,
        result: u32,
    ) bool {
        if (!self.validAndQuiescent()) return false;
        if (self.state.operation_state != .accepted or
            self.state.operation_id != operation_id or
            self.state.operation_generation != operation_generation)
        {
            return false;
        }

        self.state.yielded = 0;
        self.state.operation_result = result;
        self.state.operation_state = .completed;
        self.state.yielded = 1;
        return true;
    }

    pub fn startTask(self: *Payload, active_leaf_id: u32) bool {
        if (!self.validAndQuiescent() or active_leaf_id == 0) return false;
        if (self.state.task_phase != .idle or self.state.operation_state != .idle) return false;
        self.state.yielded = 0;
        self.state.active_leaf_id = active_leaf_id;
        self.state.task_phase = .ready;
        self.state.yielded = 1;
        return true;
    }

    pub fn beginModelOperation(self: *Payload, operation_id: u32, sequence: u32) bool {
        if (self.state.task_phase != .ready or self.state.active_leaf_id > std.math.maxInt(u32)) {
            return false;
        }
        if (!self.submitOperation(operation_id, sequence)) return false;
        self.state.context_first = 1;
        self.state.context_count = @intCast(self.state.active_leaf_id);
        self.state.response_ref = 0;
        self.state.response_disposition = 0;
        self.state.response_failure = 0;
        self.state.response_text_offset = 0;
        self.state.response_text_length = 0;
        self.state.response_tool = 0;
        self.state.response_arguments_offset = 0;
        self.state.response_arguments_length = 0;
        self.state.task_phase = .awaiting_model;
        return true;
    }

    pub fn interpretStoredResponse(
        self: *Payload,
        offset: u32,
        length: u32,
        response_ref: u32,
    ) bool {
        if (offset < response_memory_offset) return false;
        const relative = offset - response_memory_offset;
        if (relative > self.response.len or length > self.response.len - relative) return false;
        return self.interpretResponseAt(offset, self.response[relative..][0..length], response_ref);
    }

    pub fn interpretResponse(self: *Payload, bytes: []const u8, response_ref: u32) bool {
        if (bytes.len == 0 or bytes.len > self.response.len) return false;
        @memcpy(self.response[0..bytes.len], bytes);
        return self.interpretResponseAt(response_memory_offset, self.response[0..bytes.len], response_ref);
    }

    fn interpretResponseAt(
        self: *Payload,
        absolute_offset: u32,
        bytes: []const u8,
        response_ref: u32,
    ) bool {
        if (!self.validAndQuiescent() or response_ref == 0) return false;
        if (self.state.task_phase != .awaiting_model or
            self.state.operation_state != .completed or
            self.state.operation_result != response_ref or
            bytes.len == 0 or bytes.len > model_protocol.max_response_size)
        {
            return false;
        }

        self.state.yielded = 0;
        const parsed = model_protocol.parse(bytes);
        self.state.response_ref = response_ref;
        self.state.response_disposition = @intFromEnum(parsed.disposition);
        self.state.response_failure = @intFromEnum(parsed.failure);
        self.state.response_text_offset = absolute_offset + parsed.text_offset;
        self.state.response_text_length = parsed.text_length;
        self.state.response_tool = @intFromEnum(parsed.tool);
        self.state.response_arguments_offset = absolute_offset + parsed.arguments_offset;
        self.state.response_arguments_length = parsed.arguments_length;
        self.state.task_phase = switch (parsed.disposition) {
            .final_answer => .final_candidate,
            .tool_call => .awaiting_tool,
            .failure => .failed,
        };
        self.state.yielded = 1;
        return true;
    }

    pub fn commitFinalAnswer(self: *Payload, entry_id: u32) bool {
        if (!self.validAndQuiescent() or entry_id == 0) return false;
        if (self.state.task_phase != .final_candidate or entry_id != self.state.active_leaf_id + 1) {
            return false;
        }
        self.state.yielded = 0;
        self.state.active_leaf_id = entry_id;
        self.state.final_entry_id = entry_id;
        self.state.task_phase = .finished;
        self.state.yielded = 1;
        return true;
    }

    pub fn commitToolResult(self: *Payload, call_entry_id: u32, result_entry_id: u32) bool {
        if (!self.validAndQuiescent() or call_entry_id == 0 or result_entry_id == 0) return false;
        if (self.state.task_phase != .awaiting_tool or
            call_entry_id != self.state.active_leaf_id + 1 or
            result_entry_id != call_entry_id + 1)
        {
            return false;
        }
        self.state.yielded = 0;
        self.state.active_leaf_id = result_entry_id;
        self.state.task_phase = .ready;
        self.state.yielded = 1;
        return true;
    }

    fn validAndQuiescent(self: *const Payload) bool {
        return self.state.magic == magic and self.state.yielded == 1;
    }
};

pub const Image = extern struct {
    wasm_stack_static_or_native_reserve: [state_memory_offset]u8,
    payload: Payload,

    pub fn initialize(self: *Image, agent_id: u32) void {
        @memset(std.mem.asBytes(self), 0);
        self.payload.state = initialState(agent_id);
    }
};

fn initialState(agent_id: u32) State {
    return .{
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
        .response_tool = 0,
        .response_arguments_offset = 0,
        .response_arguments_length = 0,
    };
}

comptime {
    std.debug.assert(state_memory_offset >= wasm_stack_size);
    std.debug.assert(response_memory_offset >= state_memory_offset + @sizeOf(State));
    std.debug.assert(@sizeOf(State) <= 128);
    std.debug.assert(@alignOf(State) <= 8);
    std.debug.assert(@sizeOf(Payload) == payload_size);
    std.debug.assert(@sizeOf(Image) == page_size);
    std.debug.assert(@offsetOf(Image, "payload") == state_memory_offset);
    std.debug.assert(@offsetOf(Payload, "response") == response_offset_in_payload);
}

test "native image is exactly one page and snapshots without pointers" {
    var image: Image = undefined;
    image.initialize(42);
    try std.testing.expectEqual(page_size, @sizeOf(Image));
    try std.testing.expectEqual(@as(u32, 42), image.payload.state.agent_id);
    try std.testing.expect(image.payload.deliver(7));

    var restored: Image = undefined;
    @memcpy(std.mem.asBytes(&restored), std.mem.asBytes(&image));
    try std.testing.expectEqual(image.payload.state, restored.payload.state);
    try std.testing.expect(restored.payload.deliver(8));
}

test "model transition uses the same bounded response region" {
    var image: Image = undefined;
    image.initialize(7);
    try std.testing.expect(image.payload.startTask(1));
    try std.testing.expect(image.payload.beginModelOperation(11, 1));
    try std.testing.expect(image.payload.acceptOperation(11, 1));
    try std.testing.expect(image.payload.completeOperation(11, 1, 99));

    var encoded: [model_protocol.max_response_size]u8 = undefined;
    const response = try model_protocol.encodeText(&encoded, .complete, "done");
    try std.testing.expect(image.payload.interpretResponse(response, 99));
    try std.testing.expectEqual(TaskPhase.final_candidate, image.payload.state.task_phase);
    try std.testing.expectEqual(@as(u32, 4), image.payload.state.response_text_length);
}
