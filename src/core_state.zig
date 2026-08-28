const std = @import("std");
const model_protocol = @import("model_protocol.zig");

pub const schema_version: u16 = 2;
pub const encoded_size: usize = 144;

const magic = "ONECORE\x00";
const checksum_offset = encoded_size - @sizeOf(u32);

pub const OperationPhase = enum(u8) {
    idle = 0,
    submitted = 1,
    accepted = 2,
    completed = 3,
};

pub const TaskPhase = enum(u8) {
    idle = 0,
    ready = 1,
    awaiting_model = 2,
    final_candidate = 3,
    awaiting_tool = 4,
    finished = 5,
    failed = 6,
};

pub const ContentWindow = extern struct {
    offset: u32 = 0,
    length: u32 = 0,
};

pub const State = extern struct {
    agent_id: u64,
    agent_generation: u32,
    event_count: u64 = 0,
    accumulator: u64,
    last_event: u32 = 0,
    operation_id: u64 = 0,
    operation_generation: u32 = 0,
    operation_phase: OperationPhase = .idle,
    operation_result: u64 = 0,
    operation_sequence: u64 = 0,
    active_leaf_id: u64 = 0,
    final_entry_id: u64 = 0,
    response_ref: u64 = 0,
    task_phase: TaskPhase = .idle,
    response_disposition: model_protocol.Disposition = .failure,
    response_failure: model_protocol.Failure = .none,
    context: ContentWindow = .{},
    response_text: ContentWindow = .{},
    response_tool_key: ContentWindow = .{},
    response_arguments: ContentWindow = .{},
};

comptime {
    for (std.meta.fields(State)) |field| {
        switch (@typeInfo(field.type)) {
            .pointer => @compileError("Core State cannot contain pointers"),
            .int => |integer| if (integer.bits == @bitSizeOf(usize)) {
                if (field.type == usize or field.type == isize) {
                    @compileError("Core State cannot contain target-width integers");
                }
            },
            else => {},
        }
    }
}

pub fn encode(out: []u8, state: State) !void {
    if (out.len != encoded_size) return error.InvalidCoreStateOutputLength;
    try validate(state);

    @memset(out, 0);
    @memcpy(out[0..magic.len], magic);
    write(u16, out, 8, schema_version);
    write(u16, out, 10, encoded_size);
    write(u64, out, 16, state.agent_id);
    write(u32, out, 24, state.agent_generation);
    write(u32, out, 28, state.last_event);
    write(u64, out, 32, state.event_count);
    write(u64, out, 40, state.accumulator);
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
    rewriteChecksum(out);
}

pub fn decode(input: []const u8) !State {
    if (input.len != encoded_size) return error.TruncatedCoreState;
    if (!std.mem.eql(u8, input[0..magic.len], magic)) return error.InvalidCoreStateMagic;
    if (read(u16, input, 8) != schema_version) return error.UnsupportedSchema;
    if (read(u16, input, 10) != encoded_size) return error.InvalidCoreStateLength;
    if (read(u32, input, 12) != 0) return error.UnsupportedCoreStateFlags;
    for (input[64..68]) |byte| if (byte != 0) return error.NonzeroCoreStateReservedByte;
    if (read(u32, input, checksum_offset) != std.hash.Crc32.hash(input[0..checksum_offset])) {
        return error.CoreStateChecksumMismatch;
    }

    const state: State = .{
        .agent_id = read(u64, input, 16),
        .agent_generation = read(u32, input, 24),
        .last_event = read(u32, input, 28),
        .event_count = read(u64, input, 32),
        .accumulator = read(u64, input, 40),
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
        .submitted, .accepted => {
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
        .idle => {
            if (state.active_leaf_id != 0 or state.final_entry_id != 0) {
                return error.InvalidTaskState;
            }
        },
        .ready => {
            if (state.active_leaf_id == 0 or state.final_entry_id != 0) {
                return error.InvalidTaskState;
            }
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
        .final_candidate, .awaiting_tool, .failed => {
            if (state.active_leaf_id == 0 or state.final_entry_id != 0 or
                state.operation_phase != .completed)
            {
                return error.InvalidTaskState;
            }
        },
        .finished => {
            if (state.active_leaf_id == 0 or state.final_entry_id != state.active_leaf_id or
                state.operation_phase != .completed)
            {
                return error.InvalidTaskState;
            }
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
            .final_candidate, .awaiting_tool, .finished, .failed => {
                return error.InvalidResponseState;
            },
        }
        return;
    }
    if (state.operation_phase != .completed or state.operation_result != state.response_ref) {
        return error.InvalidResponseState;
    }
    switch (state.task_phase) {
        .final_candidate, .finished => {
            if (state.response_disposition != .final_answer or
                state.response_failure != .none or state.response_text.length == 0 or
                state.response_tool_key.length != 0 or state.response_arguments.length != 0)
            {
                return error.InvalidResponseState;
            }
        },
        .awaiting_tool, .ready => {
            if (state.response_disposition != .tool_call or
                state.response_failure != .none or state.response_tool_key.length == 0 or
                state.response_arguments.length == 0 or state.response_text.length != 0)
            {
                return error.InvalidResponseState;
            }
        },
        .failed => {
            switch (state.response_disposition) {
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
            }
        },
        .idle, .awaiting_model => return error.InvalidResponseState,
    }
}

fn validateWindow(window: ContentWindow, limit: ?usize) !void {
    if ((window.offset == 0) != (window.length == 0)) return error.InvalidContentWindow;
    const end = std.math.add(u32, window.offset, window.length) catch
        return error.ContentWindowOverflow;
    if (limit) |maximum| if (end > maximum) return error.ContentWindowOutOfRange;
}

fn operationPhase(value: u8) !OperationPhase {
    return switch (value) {
        0 => .idle,
        1 => .submitted,
        2 => .accepted,
        3 => .completed,
        else => error.UnknownOperationPhase,
    };
}

fn taskPhase(value: u8) !TaskPhase {
    return switch (value) {
        0 => .idle,
        1 => .ready,
        2 => .awaiting_model,
        3 => .final_candidate,
        4 => .awaiting_tool,
        5 => .finished,
        6 => .failed,
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
        else => error.UnknownResponseFailure,
    };
}

fn writeWindow(out: []u8, offset: usize, window: ContentWindow) void {
    write(u32, out, offset, window.offset);
    write(u32, out, offset + 4, window.length);
}

fn readWindow(input: []const u8, offset: usize) ContentWindow {
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

test "canonical Core State vector round trips deterministically" {
    const state: State = .{
        .agent_id = 0x0102_0304_0506_0708,
        .agent_generation = 7,
        .event_count = 9,
        .accumulator = 0x1112_1314_1516_1718,
        .last_event = 19,
        .operation_id = 20,
        .operation_generation = 21,
        .operation_phase = .completed,
        .operation_result = 26,
        .operation_sequence = 23,
        .active_leaf_id = 24,
        .final_entry_id = 0,
        .response_ref = 26,
        .task_phase = .awaiting_tool,
        .response_disposition = .tool_call,
        .response_failure = .none,
        .context = .{ .offset = 1, .length = 24 },
        .response_text = .{},
        .response_tool_key = .{ .offset = 24, .length = 7 },
        .response_arguments = .{ .offset = 31, .length = 32 },
    };
    var first: [encoded_size]u8 = undefined;
    var second: [encoded_size]u8 = undefined;
    try encode(&first, state);
    const restored = try decode(&first);
    try encode(&second, restored);
    try std.testing.expectEqualSlices(u8, &first, &second);
    try std.testing.expectEqualDeep(state, restored);
}

test "Core State rejects unsupported schema enums truncation and checksum corruption" {
    var encoded: [encoded_size]u8 = undefined;
    try encode(&encoded, .{ .agent_id = 1, .agent_generation = 1, .accumulator = 1 });

    var changed = encoded;
    std.mem.writeInt(u16, changed[8..10], schema_version + 1, .little);
    try std.testing.expectError(error.UnsupportedSchema, decode(&changed));
    try std.testing.expectError(error.TruncatedCoreState, decode(encoded[0 .. encoded.len - 1]));

    changed = encoded;
    changed[60] = 0xff;
    rewriteChecksum(&changed);
    try std.testing.expectError(error.UnknownOperationPhase, decode(&changed));

    changed = encoded;
    changed[40] ^= 0x80;
    try std.testing.expectError(error.CoreStateChecksumMismatch, decode(&changed));
}

test "Core State rejects every unknown enum and overflowing bounded window" {
    var encoded: [encoded_size]u8 = undefined;
    try encode(&encoded, .{ .agent_id = 1, .agent_generation = 1, .accumulator = 1 });
    const cases = [_]struct { offset: usize, value: u8, expected: anyerror }{
        .{ .offset = 60, .value = 0xff, .expected = error.UnknownOperationPhase },
        .{ .offset = 61, .value = 7, .expected = error.UnknownTaskPhase },
        .{ .offset = 62, .value = 0xff, .expected = error.UnknownResponseDisposition },
        .{ .offset = 63, .value = 0xff, .expected = error.UnknownResponseFailure },
        .{ .offset = 64, .value = 0xff, .expected = error.NonzeroCoreStateReservedByte },
    };
    for (cases) |case| {
        var changed = encoded;
        changed[case.offset] = case.value;
        rewriteChecksum(&changed);
        try std.testing.expectError(case.expected, decode(&changed));
    }

    const invalid: State = .{
        .agent_id = 1,
        .agent_generation = 1,
        .accumulator = 1,
        .response_text = .{ .offset = std.math.maxInt(u32), .length = 2 },
    };
    try std.testing.expectError(error.ContentWindowOverflow, encode(&encoded, invalid));
}

test "Core State rejects impossible operation results after checksum validation" {
    var encoded: [encoded_size]u8 = undefined;
    try encode(&encoded, .{
        .agent_id = 1,
        .agent_generation = 1,
        .accumulator = 1,
        .operation_id = 2,
        .operation_generation = 1,
        .operation_phase = .completed,
        .operation_result = 3,
        .operation_sequence = 1,
        .active_leaf_id = 1,
        .task_phase = .awaiting_model,
        .context = .{ .offset = 1, .length = 1 },
    });

    write(u64, &encoded, 68, 0);
    rewriteChecksum(&encoded);
    try std.testing.expectError(error.InvalidOperationResult, decode(&encoded));

    encoded[60] = @intFromEnum(OperationPhase.accepted);
    write(u64, &encoded, 68, 3);
    rewriteChecksum(&encoded);
    try std.testing.expectError(error.InvalidOperationResult, decode(&encoded));
}

test "Core State rejects impossible task and response relationships" {
    const valid: State = .{
        .agent_id = 1,
        .agent_generation = 1,
        .accumulator = 1,
        .operation_id = 2,
        .operation_generation = 1,
        .operation_phase = .completed,
        .operation_result = 3,
        .operation_sequence = 1,
        .active_leaf_id = 2,
        .final_entry_id = 2,
        .response_ref = 3,
        .task_phase = .finished,
        .response_disposition = .final_answer,
        .response_text = .{ .offset = 16, .length = 1 },
    };
    var encoded: [encoded_size]u8 = undefined;
    try encode(&encoded, valid);

    write(u64, &encoded, 92, 1);
    rewriteChecksum(&encoded);
    try std.testing.expectError(error.InvalidTaskState, decode(&encoded));

    try encode(&encoded, valid);
    writeWindow(&encoded, 132, .{ .offset = 1, .length = 1 });
    rewriteChecksum(&encoded);
    try std.testing.expectError(error.InvalidResponseState, decode(&encoded));

    try encode(&encoded, valid);
    write(u64, &encoded, 100, 4);
    rewriteChecksum(&encoded);
    try std.testing.expectError(error.InvalidResponseState, decode(&encoded));

    try encode(&encoded, valid);
    write(u64, &encoded, 100, 0);
    writeWindow(&encoded, 116, .{});
    rewriteChecksum(&encoded);
    try std.testing.expectError(error.InvalidResponseState, decode(&encoded));

    encoded[62] = @intFromEnum(model_protocol.Disposition.failure);
    rewriteChecksum(&encoded);
    try std.testing.expectError(error.InvalidResponseState, decode(&encoded));

    try encode(&encoded, valid);
    write(u64, &encoded, 76, 0);
    rewriteChecksum(&encoded);
    try std.testing.expectError(error.InvalidOperationGeneration, decode(&encoded));
}
