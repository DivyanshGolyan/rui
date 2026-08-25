const std = @import("std");
const core_image = @import("core_image.zig");
const core_state = @import("core_state.zig");

const state_memory_offset = 8 * 1024;
const WasmWorkspace = extern struct {
    state: core_state.State,
    parser_scratch: [core_image.parser_scratch_size]u8,
    response_scratch: [core_image.response_scratch_size]u8,
    transition_scratch: [core_image.transition_scratch_size]u8,
};
const response_memory_offset = state_memory_offset +
    @offsetOf(WasmWorkspace, "response_scratch");
const encoded_state_output_offset = 48 * 1024;

fn workspace() *WasmWorkspace {
    return @ptrFromInt(state_memory_offset);
}

fn activeCore() core_image.Core {
    return core_image.Core.attach(&workspace().state, &workspace().response_scratch);
}

export fn coreStateVersion() u32 {
    return core_state.schema_version;
}

export fn coreStateSize() u32 {
    return core_state.encoded_size;
}

export fn encodeCoreState(offset: u32, capacity: u32) u32 {
    if (offset != encoded_state_output_offset or capacity != core_state.encoded_size) return 0;
    const out: [*]u8 = @ptrFromInt(offset);
    const bytes = out[0..capacity];
    core_state.encode(bytes, workspace().state) catch return 0;
    return 1;
}

export fn initialize(agent_id: u32) u32 {
    @memset(std.mem.asBytes(workspace()), 0);
    _ = core_image.Core.initializeAttached(
        &workspace().state,
        &workspace().response_scratch,
        .{ .agent_id = agent_id, .generation = 1 },
    ) catch |err| return core_image.rejectionCode(err);
    return 1;
}

export fn deliver(event: u32) u32 {
    var core = activeCore();
    core.deliver(event) catch |err| return core_image.rejectionCode(err);
    return 1;
}

export fn agentId() u32 {
    return @truncate(workspace().state.agent_id);
}

export fn eventCount() u64 {
    return workspace().state.event_count;
}

export fn accumulator() u64 {
    return workspace().state.accumulator;
}

export fn isQuiescent() u32 {
    return 1;
}

export fn submitOperation(operation_id: u32, sequence: u32) u32 {
    var core = activeCore();
    _ = core.submitOperation(operation_id, sequence) catch |err| return core_image.rejectionCode(err);
    return 1;
}

export fn acceptOperation(operation_id: u32, operation_generation: u32) u32 {
    var core = activeCore();
    core.acceptOperation(.{
        .id = operation_id,
        .generation = operation_generation,
    }) catch |err| return core_image.rejectionCode(err);
    return 1;
}

export fn completeOperation(
    operation_id: u32,
    operation_generation: u32,
    result: u32,
) u32 {
    var core = activeCore();
    core.completeOperation(
        .{ .id = operation_id, .generation = operation_generation },
        result,
    ) catch |err| return core_image.rejectionCode(err);
    return 1;
}

export fn operationState() u32 {
    return @intFromEnum(workspace().state.operation_phase);
}

export fn operationId() u64 {
    return workspace().state.operation_id;
}

export fn operationGeneration() u32 {
    return workspace().state.operation_generation;
}

export fn operationResult() u64 {
    return workspace().state.operation_result;
}

export fn startTask(active_leaf_id: u32) u32 {
    var core = activeCore();
    core.startTask(active_leaf_id) catch |err| return core_image.rejectionCode(err);
    return 1;
}

export fn beginModelOperation(operation_id: u32, sequence: u32) u32 {
    var core = activeCore();
    _ = core.beginModelOperation(operation_id, sequence) catch |err| return core_image.rejectionCode(err);
    return 1;
}

export fn interpretModelResponse(offset: u32, length: u32, response_ref: u32) u32 {
    if (offset != response_memory_offset) return core_image.rejectionCode(error.IllegalModelResponseTransition);
    if (length > core_image.response_scratch_size) {
        return core_image.rejectionCode(error.ResponseCapacityExceeded);
    }
    const bytes: [*]const u8 = @ptrFromInt(offset);
    var core = activeCore();
    _ = core.interpretModelResponse(bytes[0..length], response_ref) catch |err| return core_image.rejectionCode(err);
    return 1;
}

export fn commitFinalAnswer(entry_id: u32) u32 {
    var core = activeCore();
    core.commitFinalAnswer(entry_id) catch |err| return core_image.rejectionCode(err);
    return 1;
}

export fn commitToolResult(call_entry_id: u32, result_entry_id: u32) u32 {
    var core = activeCore();
    core.commitToolResult(call_entry_id, result_entry_id) catch |err| return core_image.rejectionCode(err);
    return 1;
}

export fn contextFirst() u32 {
    return workspace().state.context.offset;
}

export fn contextCount() u32 {
    return workspace().state.context.length;
}

export fn responseDisposition() u32 {
    return @intFromEnum(workspace().state.response_disposition);
}

export fn responseFailure() u32 {
    return @intFromEnum(workspace().state.response_failure);
}

export fn responseTextOffset() u32 {
    return workspace().state.response_text.offset;
}

export fn responseTextLength() u32 {
    return workspace().state.response_text.length;
}

export fn responseTool() u32 {
    return @intFromEnum(workspace().state.response_tool);
}

export fn responseArgumentsOffset() u32 {
    return workspace().state.response_arguments.offset;
}

export fn responseArgumentsLength() u32 {
    return workspace().state.response_arguments.length;
}

export fn taskOutcome() u32 {
    return @intFromEnum(workspace().state.task_phase);
}

export fn finalEntryId() u64 {
    return workspace().state.final_entry_id;
}

comptime {
    std.debug.assert(state_memory_offset + @sizeOf(WasmWorkspace) <= encoded_state_output_offset);
    std.debug.assert(encoded_state_output_offset + core_state.encoded_size <= 64 * 1024);
}
