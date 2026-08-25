const std = @import("std");
const checkpoint = @import("checkpoint.zig");
const core_contract = @import("core_contract.zig");
const core_image = @import("core_image.zig");
const core_state = @import("core_state.zig");
const jsc = @import("jsc_runtime.zig");
const model_protocol = @import("model_protocol.zig");
const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("unistd.h");
});

const density_agents = 1000;
const wasm_workspace_offset = 8 * 1024;
const wasm_response_offset = wasm_workspace_offset +
    @offsetOf(core_image.ActivationSlot, "response_scratch");
const wasm_encoded_state_offset = 48 * 1024;

const WasmTransitions = struct {
    initialize: jsc.JSObjectRef,
    deliver: jsc.JSObjectRef,
    start_task: jsc.JSObjectRef,
    begin_model: jsc.JSObjectRef,
    accept: jsc.JSObjectRef,
    complete: jsc.JSObjectRef,
    interpret: jsc.JSObjectRef,
    commit_tool: jsc.JSObjectRef,
    commit_final: jsc.JSObjectRef,
    encode_state: jsc.JSObjectRef,
    operation_state: jsc.JSObjectRef,
    operation_id: jsc.JSObjectRef,
    operation_generation: jsc.JSObjectRef,
    operation_result: jsc.JSObjectRef,
    context_first: jsc.JSObjectRef,
    context_count: jsc.JSObjectRef,
    response_disposition: jsc.JSObjectRef,
    response_failure: jsc.JSObjectRef,
    response_tool: jsc.JSObjectRef,
    response_text_offset: jsc.JSObjectRef,
    response_text_length: jsc.JSObjectRef,
    response_arguments_offset: jsc.JSObjectRef,
    response_arguments_length: jsc.JSObjectRef,
    task_outcome: jsc.JSObjectRef,
    final_entry_id: jsc.JSObjectRef,

    fn load(runtime: *const jsc.Runtime, allocator: std.mem.Allocator) !WasmTransitions {
        return .{
            .initialize = try runtime.function(allocator, "__onepage.instance.exports.initialize"),
            .deliver = try runtime.function(allocator, "__onepage.instance.exports.deliver"),
            .start_task = try runtime.function(allocator, "__onepage.instance.exports.startTask"),
            .begin_model = try runtime.function(allocator, "__onepage.instance.exports.beginModelOperation"),
            .accept = try runtime.function(allocator, "__onepage.instance.exports.acceptOperation"),
            .complete = try runtime.function(allocator, "__onepage.instance.exports.completeOperation"),
            .interpret = try runtime.function(allocator, "__onepage.instance.exports.interpretModelResponse"),
            .commit_tool = try runtime.function(allocator, "__onepage.instance.exports.commitToolResult"),
            .commit_final = try runtime.function(allocator, "__onepage.instance.exports.commitFinalAnswer"),
            .encode_state = try runtime.function(allocator, "__onepage.instance.exports.encodeCoreState"),
            .operation_state = try runtime.function(allocator, "__onepage.instance.exports.operationState"),
            .operation_id = try runtime.function(allocator, "__onepage.instance.exports.operationId"),
            .operation_generation = try runtime.function(allocator, "__onepage.instance.exports.operationGeneration"),
            .operation_result = try runtime.function(allocator, "__onepage.instance.exports.operationResult"),
            .context_first = try runtime.function(allocator, "__onepage.instance.exports.contextFirst"),
            .context_count = try runtime.function(allocator, "__onepage.instance.exports.contextCount"),
            .response_disposition = try runtime.function(allocator, "__onepage.instance.exports.responseDisposition"),
            .response_failure = try runtime.function(allocator, "__onepage.instance.exports.responseFailure"),
            .response_tool = try runtime.function(allocator, "__onepage.instance.exports.responseTool"),
            .response_text_offset = try runtime.function(allocator, "__onepage.instance.exports.responseTextOffset"),
            .response_text_length = try runtime.function(allocator, "__onepage.instance.exports.responseTextLength"),
            .response_arguments_offset = try runtime.function(allocator, "__onepage.instance.exports.responseArgumentsOffset"),
            .response_arguments_length = try runtime.function(allocator, "__onepage.instance.exports.responseArgumentsLength"),
            .task_outcome = try runtime.function(allocator, "__onepage.instance.exports.taskOutcome"),
            .final_entry_id = try runtime.function(allocator, "__onepage.instance.exports.finalEntryId"),
        };
    }
};

const SemanticIntent = struct {
    operation_phase: u32,
    operation_id: u64,
    operation_generation: u32,
    operation_result: u64,
    context_first: u32,
    context_count: u32,
    response_disposition: u32,
    response_failure: u32,
    response_tool: u32,
    response_text_offset: u32,
    response_text_length: u32,
    response_arguments_offset: u32,
    response_arguments_length: u32,
    task_phase: u32,
    final_entry_id: u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.InvalidArguments;

    const baseline_rss = try residentBytes();
    var pool: core_image.SlotPool(1) = .{};

    var random_name: [8]u8 = undefined;
    init.io.random(&random_name);
    var density_path_buffer: [96]u8 = undefined;
    const density_path = try std.fmt.bufPrint(
        &density_path_buffer,
        ".zig-cache/onepage-density-{x}.state",
        .{random_name},
    );
    var density_file = try std.Io.Dir.cwd().createFile(
        init.io,
        density_path,
        .{ .read = true, .truncate = true },
    );
    defer {
        density_file.close(init.io);
        // A randomized cache artifact after a failed measurement is harmless and
        // must not replace the primary density or conformance failure.
        std.Io.Dir.cwd().deleteFile(init.io, density_path) catch {};
    }

    var state_bytes: [core_state.encoded_size]u8 = undefined;
    var checkpoint_bytes: [checkpoint.encoded_size]u8 = undefined;
    var first_slot_rss: u64 = 0;
    for (0..density_agents) |index| {
        const agent_id: u64 = index + 1;
        var lease = try pool.borrow();
        var core = try core_image.Core.initialize(
            lease.slot,
            .{ .agent_id = agent_id, .generation = 1 },
        );
        if (index == 0) first_slot_rss = try residentBytes();
        try core.deliver(@truncate(agent_id ^ 0x5a5a_5a5a));
        try core.suspendInto(&state_bytes);
        try checkpoint.encode(&checkpoint_bytes, agent_id, 1, &state_bytes);
        try density_file.writePositionalAll(
            init.io,
            &checkpoint_bytes,
            index * checkpoint.encoded_size,
        );
        try lease.release();
    }
    try density_file.sync(init.io);
    const durable_density_bytes = (try density_file.stat(init.io)).size;
    for (0..density_agents) |index| {
        const actual = try density_file.readPositionalAll(
            init.io,
            &checkpoint_bytes,
            index * checkpoint.encoded_size,
        );
        if (actual != checkpoint.encoded_size) return error.TruncatedDensityCheckpoint;
        const agent_id: u64 = index + 1;
        const decoded = try checkpoint.decode(&checkpoint_bytes, agent_id, 1);
        var lease = try pool.borrow();
        var core = try core_image.Core.activate(lease.slot, decoded.state);
        const identity = try core.identity();
        if (identity.agent_id != agent_id) return error.DensityIdentityMismatch;
        try core.suspendInto(&state_bytes);
        try lease.release();
    }
    const density_rss = try residentBytes();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(wasm);
    try core_contract.verify(wasm);
    var conformance_lease = try pool.borrow();
    defer conformance_lease.release() catch unreachable;
    try differentialCheck(allocator, conformance_lease.slot, wasm);

    std.debug.print(
        "Activation Slot exact       {d} B\n" ++
            "resident slots            1\n" ++
            "configured slot bytes     {d} B\n" ++
            "occupied slot bytes       {d} B\n" ++
            "slot-pool host overhead   {d} B\n" ++
            "logical sleeping agents   {d}\n" ++
            "Core State per agent       {d} B\n" ++
            "State Checkpoint per agent {d} B\n" ++
            "sleeping checkpoint bytes  {d} B\n" ++
            "native/Wasm corpus         32 randomized traces: outcomes, intents, state parity\n" ++
            "RSS baseline               {d} B\n" ++
            "RSS with first slot        {d} B\n" ++
            "RSS after density cycle    {d} B\n",
        .{
            @sizeOf(core_image.ActivationSlot),
            pool.residentBytes(),
            pool.occupiedBytes(),
            pool.hostOverheadBytes(),
            density_agents,
            core_state.encoded_size,
            checkpoint.encoded_size,
            durable_density_bytes,
            baseline_rss,
            first_slot_rss,
            density_rss,
        },
    );
}

fn differentialCheck(
    allocator: std.mem.Allocator,
    slot: *core_image.ActivationSlot,
    wasm: []const u8,
) !void {
    var runtime = try jsc.Runtime.open();
    defer runtime.close();
    try runtime.instantiate(allocator, wasm);
    const transitions = try WasmTransitions.load(&runtime, allocator);
    const wasm_memory = try runtime.memory(allocator);

    const invalid_identity = try runtime.callNumber(transitions.initialize, &.{0});
    if (invalid_identity != core_image.rejectionCode(error.InvalidAgentIdentity)) {
        return error.WasmInvalidIdentityUnexpectedlyAccepted;
    }

    try randomizedStateMachineTraces(slot, &runtime, transitions, wasm_memory);

    var native = try core_image.Core.initialize(slot, .{ .agent_id = 7, .generation = 1 });
    try expectWasmAccepted(try runtime.callNumber(transitions.initialize, &.{7}));
    try expectSameState(&native, &runtime, transitions, wasm_memory);

    var random = std.Random.DefaultPrng.init(0x4f4e_4550_4147_4531);
    for (0..128) |_| {
        const event = random.random().int(u32);
        try expectAccepted(native.deliver(event), try runtime.callNumber(transitions.deliver, &.{event}));
        try expectSameState(&native, &runtime, transitions, wasm_memory);
    }
    try expectAccepted(native.startTask(7), try runtime.callNumber(transitions.start_task, &.{7}));
    const operation = try native.beginModelOperation(11, 2);
    try expectWasmAccepted(try runtime.callNumber(transitions.begin_model, &.{ 11, 2 }));

    try expectRejected(
        native.acceptOperation(.{ .id = 11, .generation = operation.generation + 1 }),
        try runtime.callNumber(transitions.accept, &.{ 11, operation.generation + 1 }),
    );
    try expectSameState(&native, &runtime, transitions, wasm_memory);
    try expectAccepted(
        native.acceptOperation(.{ .id = 11, .generation = operation.generation }),
        try runtime.callNumber(transitions.accept, &.{ 11, operation.generation }),
    );
    try expectAccepted(
        native.completeOperation(.{ .id = 11, .generation = operation.generation }, 17),
        try runtime.callNumber(transitions.complete, &.{ 11, operation.generation, 17 }),
    );

    var oversized: [model_protocol.max_response_size + 1]u8 = @splat(1);
    try expectRejected(
        discardResponse(native.interpretModelResponse(&oversized, 17)),
        try runtime.callNumber(transitions.interpret, &.{
            wasm_response_offset,
            model_protocol.max_response_size + 1,
            17,
        }),
    );
    try expectSameState(&native, &runtime, transitions, wasm_memory);

    var response_buffer: [model_protocol.max_response_size]u8 = undefined;
    const tool = try model_protocol.encodeTool(&response_buffer, .bash, "pwd");
    @memcpy(wasm_memory[wasm_response_offset..][0..tool.len], tool);
    _ = try native.interpretModelResponse(tool, 17);
    try expectWasmAccepted(try runtime.callNumber(transitions.interpret, &.{
        wasm_response_offset,
        @intCast(tool.len),
        17,
    }));
    try expectSameState(&native, &runtime, transitions, wasm_memory);
    try expectAccepted(
        native.commitToolResult(8, 9),
        try runtime.callNumber(transitions.commit_tool, &.{ 8, 9 }),
    );

    const second_operation = try native.beginModelOperation(12, 3);
    try expectWasmAccepted(try runtime.callNumber(transitions.begin_model, &.{ 12, 3 }));
    try expectAccepted(
        native.acceptOperation(.{ .id = 12, .generation = second_operation.generation }),
        try runtime.callNumber(transitions.accept, &.{ 12, second_operation.generation }),
    );
    try expectAccepted(
        native.completeOperation(.{ .id = 12, .generation = second_operation.generation }, 18),
        try runtime.callNumber(transitions.complete, &.{ 12, second_operation.generation, 18 }),
    );
    const final = try model_protocol.encodeText(&response_buffer, .complete, "ok");
    @memcpy(wasm_memory[wasm_response_offset..][0..final.len], final);
    _ = try native.interpretModelResponse(final, 18);
    try expectWasmAccepted(try runtime.callNumber(transitions.interpret, &.{
        wasm_response_offset,
        @intCast(final.len),
        18,
    }));
    try expectAccepted(
        native.commitFinalAnswer(10),
        try runtime.callNumber(transitions.commit_final, &.{10}),
    );
    try expectSameState(&native, &runtime, transitions, wasm_memory);
    native.abandon();
}

fn randomizedStateMachineTraces(
    slot: *core_image.ActivationSlot,
    runtime: *const jsc.Runtime,
    transitions: WasmTransitions,
    wasm_memory: []u8,
) !void {
    var random = std.Random.DefaultPrng.init(0x5354_4154_454d_4143);
    for (0..32) |trace_index| {
        const agent_id: u32 = @intCast(trace_index + 1);
        var native = try core_image.Core.initialize(
            slot,
            .{ .agent_id = agent_id, .generation = 1 },
        );
        try expectWasmAccepted(try runtime.callNumber(transitions.initialize, &.{agent_id}));
        try expectSameState(&native, runtime, transitions, wasm_memory);

        const delivery_count = random.random().uintLessThan(u8, 5);
        for (0..delivery_count) |_| {
            const event = random.random().int(u32);
            try expectAccepted(
                native.deliver(event),
                try runtime.callNumber(transitions.deliver, &.{event}),
            );
        }
        try expectSameState(&native, runtime, transitions, wasm_memory);

        try expectRejected(
            native.startTask(0),
            try runtime.callNumber(transitions.start_task, &.{0}),
        );
        const active_leaf_id: u32 = random.random().intRangeAtMost(u32, 1, 100);
        try expectAccepted(
            native.startTask(active_leaf_id),
            try runtime.callNumber(transitions.start_task, &.{active_leaf_id}),
        );
        try expectRejected(
            discardOperation(native.beginModelOperation(0, 1)),
            try runtime.callNumber(transitions.begin_model, &.{ 0, 1 }),
        );

        const operation_id: u32 = @intCast(1000 + trace_index);
        const operation = try native.beginModelOperation(operation_id, 1);
        try expectWasmAccepted(try runtime.callNumber(
            transitions.begin_model,
            &.{ operation_id, 1 },
        ));
        try expectSameState(&native, runtime, transitions, wasm_memory);

        try expectRejected(
            native.acceptOperation(.{
                .id = operation.id,
                .generation = operation.generation + 1,
            }),
            try runtime.callNumber(transitions.accept, &.{
                operation_id,
                operation.generation + 1,
            }),
        );
        if (random.random().boolean()) {
            try expectRejected(
                native.completeOperation(.{
                    .id = operation.id,
                    .generation = operation.generation,
                }, 9),
                try runtime.callNumber(transitions.complete, &.{
                    operation_id,
                    operation.generation,
                    9,
                }),
            );
        }
        try expectAccepted(
            native.acceptOperation(.{ .id = operation.id, .generation = operation.generation }),
            try runtime.callNumber(transitions.accept, &.{
                operation_id,
                operation.generation,
            }),
        );
        try expectRejected(
            native.acceptOperation(.{ .id = operation.id, .generation = operation.generation }),
            try runtime.callNumber(transitions.accept, &.{
                operation_id,
                operation.generation,
            }),
        );
        try expectRejected(
            native.completeOperation(.{
                .id = operation.id,
                .generation = operation.generation,
            }, 0),
            try runtime.callNumber(transitions.complete, &.{
                operation_id,
                operation.generation,
                0,
            }),
        );

        const response_ref: u32 = @intCast(2000 + trace_index);
        try expectAccepted(
            native.completeOperation(.{
                .id = operation.id,
                .generation = operation.generation,
            }, response_ref),
            try runtime.callNumber(transitions.complete, &.{
                operation_id,
                operation.generation,
                response_ref,
            }),
        );
        var response_buffer: [model_protocol.max_response_size]u8 = undefined;
        const texts = [_][]const u8{ "a", "bc", "xyz" };
        const text = texts[random.random().uintLessThan(usize, texts.len)];
        const response = try model_protocol.encodeText(&response_buffer, .complete, text);
        @memcpy(wasm_memory[wasm_response_offset..][0..response.len], response);
        try expectRejected(
            discardResponse(native.interpretModelResponse(response, response_ref + 1)),
            try runtime.callNumber(transitions.interpret, &.{
                wasm_response_offset,
                @intCast(response.len),
                response_ref + 1,
            }),
        );
        _ = try native.interpretModelResponse(response, response_ref);
        try expectWasmAccepted(try runtime.callNumber(transitions.interpret, &.{
            wasm_response_offset,
            @intCast(response.len),
            response_ref,
        }));
        try expectSameState(&native, runtime, transitions, wasm_memory);

        try expectRejected(
            native.commitFinalAnswer(@as(u64, active_leaf_id) + 2),
            try runtime.callNumber(transitions.commit_final, &.{active_leaf_id + 2}),
        );
        try expectAccepted(
            native.commitFinalAnswer(@as(u64, active_leaf_id) + 1),
            try runtime.callNumber(transitions.commit_final, &.{active_leaf_id + 1}),
        );
        try expectSameState(&native, runtime, transitions, wasm_memory);
        native.abandon();
    }
}

fn expectSameState(
    native: *core_image.Core,
    runtime: *const jsc.Runtime,
    transitions: WasmTransitions,
    wasm_memory: []const u8,
) !void {
    try expectSameIntent(native, runtime, transitions);
    var native_bytes: [core_state.encoded_size]u8 = undefined;
    try core_state.encode(&native_bytes, native.state.*);
    try expectWasmAccepted(try runtime.callNumber(transitions.encode_state, &.{
        wasm_encoded_state_offset,
        core_state.encoded_size,
    }));
    const wasm_bytes = wasm_memory[wasm_encoded_state_offset..][0..core_state.encoded_size];
    if (!std.mem.eql(u8, &native_bytes, wasm_bytes)) return error.DifferentialStateMismatch;
}

fn expectSameIntent(
    native: *core_image.Core,
    runtime: *const jsc.Runtime,
    transitions: WasmTransitions,
) !void {
    const operation = try native.operation();
    const context = try native.modelContext();
    const response = try native.response();
    const task = try native.task();
    const native_intent: SemanticIntent = .{
        .operation_phase = @intFromEnum(operation.phase),
        .operation_id = operation.id,
        .operation_generation = operation.generation,
        .operation_result = operation.result_ref,
        .context_first = context.first_entry,
        .context_count = context.entry_count,
        .response_disposition = @intFromEnum(response.disposition),
        .response_failure = @intFromEnum(response.failure),
        .response_tool = @intFromEnum(response.tool),
        .response_text_offset = response.text.offset,
        .response_text_length = response.text.length,
        .response_arguments_offset = response.arguments.offset,
        .response_arguments_length = response.arguments.length,
        .task_phase = @intFromEnum(task.phase),
        .final_entry_id = task.final_entry_id,
    };
    const wasm_intent: SemanticIntent = .{
        .operation_phase = try runtime.callNumber(transitions.operation_state, &.{}),
        .operation_id = try runtime.callNumber(transitions.operation_id, &.{}),
        .operation_generation = try runtime.callNumber(transitions.operation_generation, &.{}),
        .operation_result = try runtime.callNumber(transitions.operation_result, &.{}),
        .context_first = try runtime.callNumber(transitions.context_first, &.{}),
        .context_count = try runtime.callNumber(transitions.context_count, &.{}),
        .response_disposition = try runtime.callNumber(transitions.response_disposition, &.{}),
        .response_failure = try runtime.callNumber(transitions.response_failure, &.{}),
        .response_tool = try runtime.callNumber(transitions.response_tool, &.{}),
        .response_text_offset = try runtime.callNumber(transitions.response_text_offset, &.{}),
        .response_text_length = try runtime.callNumber(transitions.response_text_length, &.{}),
        .response_arguments_offset = try runtime.callNumber(
            transitions.response_arguments_offset,
            &.{},
        ),
        .response_arguments_length = try runtime.callNumber(
            transitions.response_arguments_length,
            &.{},
        ),
        .task_phase = try runtime.callNumber(transitions.task_outcome, &.{}),
        .final_entry_id = try runtime.callNumber(transitions.final_entry_id, &.{}),
    };
    if (!std.meta.eql(native_intent, wasm_intent)) return error.DifferentialIntentMismatch;
}

fn expectAccepted(native: anyerror!void, wasm: u32) !void {
    try native;
    try expectWasmAccepted(wasm);
}

fn discardResponse(result: anyerror!core_image.Response) !void {
    _ = try result;
}

fn discardOperation(result: anyerror!core_image.Operation) !void {
    _ = try result;
}

fn expectRejected(native: anyerror!void, wasm: u32) !void {
    if (native) |_| return error.NativeTransitionUnexpectedlyAccepted else |err| {
        if (core_image.rejectionCode(err) != wasm) return error.DifferentialRejectionMismatch;
    }
}

fn expectWasmAccepted(value: u32) !void {
    if (value != 1) return error.WasmTransitionRejected;
}

fn residentBytes() !u64 {
    var info: c.struct_proc_taskinfo = undefined;
    const actual = c.proc_pidinfo(
        c.getpid(),
        c.PROC_PIDTASKINFO,
        0,
        &info,
        @sizeOf(c.struct_proc_taskinfo),
    );
    if (actual != @sizeOf(c.struct_proc_taskinfo)) return error.ProcessInfoUnavailable;
    return info.pti_resident_size;
}
