const core_image = @import("core_image.zig");

fn payload() *core_image.Payload {
    return @ptrFromInt(core_image.state_memory_offset);
}

export fn abiVersion() u32 {
    return core_image.abi_version;
}

export fn abiFingerprintLow() u32 {
    return @truncate(core_image.abi_fingerprint);
}

export fn abiFingerprintHigh() u32 {
    return @truncate(core_image.abi_fingerprint >> 32);
}

export fn initialize(agent_id: u32) void {
    payload().initialize(agent_id);
}

export fn deliver(event: u32) u32 {
    return @intFromBool(payload().deliver(event));
}

export fn agentId() u32 {
    return payload().state.agent_id;
}

export fn eventCount() u64 {
    return payload().state.event_count;
}

export fn accumulator() u64 {
    return payload().state.accumulator;
}

export fn isQuiescent() u32 {
    return payload().state.yielded;
}

export fn submitOperation(operation_id: u32, sequence: u32) u32 {
    return @intFromBool(payload().submitOperation(operation_id, sequence));
}

export fn acceptOperation(operation_id: u32, operation_generation: u32) u32 {
    return @intFromBool(payload().acceptOperation(operation_id, operation_generation));
}

export fn completeOperation(operation_id: u32, operation_generation: u32, result: u32) u32 {
    return @intFromBool(payload().completeOperation(operation_id, operation_generation, result));
}

export fn operationState() u32 {
    return @intFromEnum(payload().state.operation_state);
}

export fn operationId() u64 {
    return payload().state.operation_id;
}

export fn operationGeneration() u32 {
    return payload().state.operation_generation;
}

export fn operationResult() u64 {
    return payload().state.operation_result;
}

export fn startTask(active_leaf_id: u32) u32 {
    return @intFromBool(payload().startTask(active_leaf_id));
}

export fn beginModelOperation(operation_id: u32, sequence: u32) u32 {
    return @intFromBool(payload().beginModelOperation(operation_id, sequence));
}

export fn interpretModelResponse(offset: u32, length: u32, response_ref: u32) u32 {
    return @intFromBool(payload().interpretStoredResponse(offset, length, response_ref));
}

export fn commitFinalAnswer(entry_id: u32) u32 {
    return @intFromBool(payload().commitFinalAnswer(entry_id));
}

export fn commitToolResult(call_entry_id: u32, result_entry_id: u32) u32 {
    return @intFromBool(payload().commitToolResult(call_entry_id, result_entry_id));
}

export fn contextFirst() u32 {
    return payload().state.context_first;
}

export fn contextCount() u32 {
    return payload().state.context_count;
}

export fn responseDisposition() u32 {
    return payload().state.response_disposition;
}

export fn responseFailure() u32 {
    return payload().state.response_failure;
}

export fn responseTextOffset() u32 {
    return payload().state.response_text_offset;
}

export fn responseTextLength() u32 {
    return payload().state.response_text_length;
}

export fn responseTool() u32 {
    return payload().state.response_tool;
}

export fn responseArgumentsOffset() u32 {
    return payload().state.response_arguments_offset;
}

export fn responseArgumentsLength() u32 {
    return payload().state.response_arguments_length;
}

export fn taskOutcome() u32 {
    return @intFromEnum(payload().state.task_phase);
}

export fn finalEntryId() u64 {
    return payload().state.final_entry_id;
}
