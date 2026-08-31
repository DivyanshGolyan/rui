const std = @import("std");
const binding = @import("binding.zig");
const core_image = @import("core_image.zig");
const core_state = @import("core_state.zig");
const lifecycle = @import("lifecycle.zig");
const model_contract = @import("model_contract.zig");
const model_protocol = @import("model_protocol.zig");
const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("unistd.h");
});

const density_agents = 1000;
const trace_count = 32;

const SemanticView = struct {
    identity: core_image.Identity,
    operation: core_image.Operation,
    task: core_image.Task,
    response: core_image.Response,
    context: core_image.ModelContext,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 1) return error.InvalidArguments;

    const baseline_rss = try residentBytes();
    var host = try lifecycle.Host.init(allocator, 1);
    defer host.deinit();
    const pool = &host.slots;
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
        // must not replace the primary density or invariant failure.
        std.Io.Dir.cwd().deleteFile(init.io, density_path) catch {};
    }

    var state_bytes: [core_state.encoded_size]u8 = undefined;
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
        try density_file.writePositionalAll(
            init.io,
            &state_bytes,
            index * core_state.encoded_size,
        );
        try lease.release();
    }
    try density_file.sync(init.io);
    const durable_density_bytes = (try density_file.stat(init.io)).size;
    for (0..density_agents) |index| {
        const actual = try density_file.readPositionalAll(
            init.io,
            &state_bytes,
            index * core_state.encoded_size,
        );
        if (actual != core_state.encoded_size) return error.TruncatedDensityState;
        const agent_id: u64 = index + 1;
        const decoded = try core_state.decode(&state_bytes);
        if (decoded.agent_id != agent_id or decoded.agent_generation != 1) {
            return error.DensityIdentityMismatch;
        }
        var lease = try pool.borrow();
        var core = try core_image.Core.activate(lease.slot, &state_bytes);
        const identity = try core.identity();
        if (identity.agent_id != agent_id) return error.DensityIdentityMismatch;
        try core.suspendInto(&state_bytes);
        try lease.release();
    }
    const density_rss = try residentBytes();

    var invariant_lease = try pool.borrow();
    defer invariant_lease.release() catch unreachable;
    try randomizedStateMachineTraces(invariant_lease.slot);
    const resources = host.resourceLedger();

    std.debug.print(
        "Activation Slot exact       {d} B\n" ++
            "resident slots            1\n" ++
            "configured slot bytes     {d} B\n" ++
            "occupied slot bytes       {d} B\n" ++
            "slot-pool host overhead   {d} B\n",
        .{
            @sizeOf(core_image.ActivationSlot),
            pool.residentBytes(),
            pool.occupiedBytes(),
            pool.hostOverheadBytes(),
        },
    );
    std.debug.print(
        "semantic validation multiplier Host {d}\n" ++
            "semantic validation components response={d} B tool-definition={d} B validation-scratch={d} B\n" ++
            "semantic validation workspace {d} B\n" ++
            "semantic validation pool overhead {d} B\n" ++
            "semantic validation reservation {d} B\n" ++
            "semantic validation allocator allocations 0 (embedded Host reservation)\n" ++
            "semantic validation allocator-observed bytes not applicable\n" ++
            "semantic validation occupancy {d} ({d} B)\n" ++
            "semantic validation occupied high-water {d} ({d} B)\n" ++
            "semantic validation acquisitions={d} busy={d}\n",
        .{
            resources.semantic_validation.multiplier,
            resources.semantic_validation.response_bytes,
            resources.semantic_validation.tool_definition_bytes,
            resources.semantic_validation.validation_scratch_bytes,
            resources.semantic_validation.workspace_bytes,
            resources.semantic_validation.pool_overhead_bytes,
            resources.semantic_validation.reservation_bytes,
            resources.semantic_validation.occupied_count,
            resources.semantic_validation.occupied_bytes,
            resources.semantic_validation.occupied_high_water_count,
            resources.semantic_validation.occupied_high_water_bytes,
            resources.semantic_validation.acquisition_count,
            resources.semantic_validation.busy_count,
        },
    );
    std.debug.print(
        "shared patch workspace multiplier Host {d}\n" ++
            "shared patch workspace component patch={d} B\n" ++
            "shared patch workspace bytes {d} B\n" ++
            "shared patch workspace pool overhead {d} B\n" ++
            "shared patch workspace reservation {d} B\n" ++
            "shared patch workspace allocator allocations 0 (embedded Host reservation)\n" ++
            "shared patch workspace allocator-observed bytes not applicable\n" ++
            "shared patch workspace occupancy {d} ({d} B)\n" ++
            "shared patch workspace occupied high-water {d} ({d} B)\n" ++
            "shared patch workspace acquisitions={d} busy={d}\n",
        .{
            resources.patch_workspace.multiplier,
            resources.patch_workspace.patch_bytes,
            resources.patch_workspace.workspace_bytes,
            resources.patch_workspace.pool_overhead_bytes,
            resources.patch_workspace.reservation_bytes,
            resources.patch_workspace.occupied_count,
            resources.patch_workspace.occupied_bytes,
            resources.patch_workspace.occupied_high_water_count,
            resources.patch_workspace.occupied_high_water_bytes,
            resources.patch_workspace.acquisition_count,
            resources.patch_workspace.busy_count,
        },
    );
    std.debug.print(
        "logical sleeping agents   {d}\n" ++
            "Core State per agent       {d} B\n" ++
            "durable Core State per agent {d} B\n" ++
            "sleeping Core State bytes  {d} B\n" ++
            "native invariant corpus    {d} randomized traces: outcomes, rejection preservation, canonical restore\n" ++
            "RSS baseline               {d} B\n" ++
            "RSS with first slot        {d} B\n" ++
            "RSS after density cycle    {d} B\n",
        .{
            density_agents,
            core_state.encoded_size,
            core_state.encoded_size,
            durable_density_bytes,
            trace_count,
            baseline_rss,
            first_slot_rss,
            density_rss,
        },
    );
}

fn randomizedStateMachineTraces(slot: *core_image.ActivationSlot) !void {
    var random = std.Random.DefaultPrng.init(0x5354_4154_454d_4143);
    for (0..trace_count) |trace_index| {
        const poison: u8 = @intCast(trace_index + 1);
        const agent_id: u64 = trace_index + 1;
        var expected: core_state.State = .{
            .agent_id = agent_id,
            .agent_generation = 1,
            .accumulator = agent_id,
        };
        var core = try core_image.Core.initialize(
            slot,
            .{ .agent_id = agent_id, .generation = 1 },
        );
        try expectStateAndRestore(&core, expected, poison);

        const delivery_count = random.random().uintLessThan(u8, 5);
        for (0..delivery_count) |_| {
            const event = random.random().int(u32);
            try core.deliver(event);
            expected.event_count +%= 1;
            expected.last_event = event;
            expected.accumulator = (expected.accumulator *% 16_777_619) ^ event;
            try expectStateAndRestore(&core, expected, poison);
        }

        var before = try canonicalState(&core);
        try expectRejectedPreserves(
            &core,
            before,
            expected,
            error.InvalidConversationEntry,
            core.startTask(0),
            poison,
        );
        const active_leaf_id: u64 = random.random().intRangeAtMost(u32, 1, 100);
        try core.startTask(active_leaf_id);
        expected.active_leaf_id = active_leaf_id;
        expected.task_phase = .ready;
        try expectStateAndRestore(&core, expected, poison);

        before = try canonicalState(&core);
        try expectRejectedPreserves(
            &core,
            before,
            expected,
            error.InvalidOperationIdentity,
            discardOperation(core.beginModelOperation(0, 1)),
            poison,
        );

        const operation_id: u64 = 1000 + trace_index;
        const operation = try core.beginModelOperation(operation_id, 1);
        expected.operation_id = operation_id;
        expected.operation_generation = 1;
        expected.operation_phase = .submitted;
        expected.operation_sequence = 1;
        expected.context = .{ .offset = 1, .length = @intCast(active_leaf_id) };
        expected.task_phase = .awaiting_model;
        try expectOperation(operation, expected);
        try expectStateAndRestore(&core, expected, poison);

        before = try canonicalState(&core);
        try expectRejectedPreserves(
            &core,
            before,
            expected,
            error.StaleOperation,
            core.acceptOperation(.{
                .id = operation.id,
                .generation = operation.generation + 1,
            }),
            poison,
        );
        if (random.random().boolean()) {
            before = try canonicalState(&core);
            try expectRejectedPreserves(
                &core,
                before,
                expected,
                error.IllegalOperationTransition,
                discardResponse(core.applyModelResponse(.{
                    .id = operation.id,
                    .generation = operation.generation,
                }, undefined, 9, undefined)),
                poison,
            );
        }
        try core.acceptOperation(.{ .id = operation.id, .generation = operation.generation });
        expected.operation_phase = .accepted;
        try expectStateAndRestore(&core, expected, poison);

        before = try canonicalState(&core);
        try expectRejectedPreserves(
            &core,
            before,
            expected,
            error.IllegalOperationTransition,
            core.acceptOperation(.{ .id = operation.id, .generation = operation.generation }),
            poison,
        );
        before = try canonicalState(&core);
        try expectRejectedPreserves(
            &core,
            before,
            expected,
            error.InvalidResultReference,
            discardResponse(core.applyModelResponse(.{
                .id = operation.id,
                .generation = operation.generation,
            }, undefined, 0, undefined)),
            poison,
        );

        const response_ref: u64 = 2000 + trace_index;
        var response_buffer: [model_protocol.max_response_size]u8 = undefined;
        var validation: model_protocol.ValidationScratch = undefined;
        if (trace_index % 2 == 0) {
            const arguments = "{\"command\":\"true\",\"timeout_ms\":1000}";
            const response = try model_protocol.encodeTool(
                &response_buffer,
                model_contract.bash_key,
                arguments,
            );
            const response_digest = binding.hash(binding.Result, response);
            const admission = model_protocol.admit(&validation, response).admission;
            before = try canonicalState(&core);
            try expectRejectedPreserves(
                &core,
                before,
                expected,
                error.StaleOperation,
                discardResponse(core.applyModelResponse(.{
                    .id = operation.id,
                    .generation = operation.generation + 1,
                }, admission, response_ref + 1, response_digest)),
                poison,
            );
            const interpreted = try core.applyModelResponse(.{
                .id = operation.id,
                .generation = operation.generation,
            }, admission, response_ref, response_digest);
            expected.operation_result = response_ref;
            expected.operation_phase = .completed;
            expected.response_ref = response_ref;
            expected.response_disposition = .tool_call;
            expected.response_tool_key = .{
                .offset = model_protocol.header_size,
                .length = model_contract.bash_key.len,
            };
            expected.response_arguments = .{
                .offset = model_protocol.header_size + model_contract.bash_key.len,
                .length = arguments.len,
            };
            expected.response_arguments_digest = model_contract.strictToolJsonDigest(arguments);
            expected.task_phase = .awaiting_tool;
            try expectResponse(interpreted, expected);
            try expectStateAndRestore(&core, expected, poison);
            try core.commitToolResult(active_leaf_id + 1, active_leaf_id + 2);
            expected.active_leaf_id = active_leaf_id + 2;
            expected.task_phase = .ready;
            try expectStateAndRestore(&core, expected, poison);

            const second = try core.beginModelOperation(operation_id + 1000, 2);
            expected.operation_id = operation_id + 1000;
            expected.operation_generation = 2;
            expected.operation_phase = .submitted;
            expected.operation_result = 0;
            expected.operation_sequence = 2;
            expected.context = .{ .offset = 1, .length = @intCast(active_leaf_id + 2) };
            expected.response_ref = 0;
            expected.response_disposition = .failure;
            expected.response_failure = .none;
            expected.response_text = .{};
            expected.response_tool_key = .{};
            expected.response_arguments = .{};
            expected.response_arguments_digest = .{ .bytes = @splat(0) };
            expected.task_phase = .awaiting_model;
            try expectOperation(second, expected);
            try expectStateAndRestore(&core, expected, poison);
            try core.acceptOperation(.{ .id = second.id, .generation = second.generation });
            expected.operation_phase = .accepted;
            try expectStateAndRestore(&core, expected, poison);
            const final = try model_protocol.encodeText(&response_buffer, "ok");
            const final_digest = binding.hash(binding.Result, final);
            const interpreted_final = try core.applyModelResponse(
                .{ .id = second.id, .generation = second.generation },
                model_protocol.admit(&validation, final).admission,
                response_ref + 1000,
                final_digest,
            );
            expected.operation_result = response_ref + 1000;
            expected.operation_phase = .completed;
            expected.response_ref = response_ref + 1000;
            expected.response_disposition = .final_answer;
            expected.response_text = .{
                .offset = model_protocol.header_size,
                .length = 2,
            };
            expected.task_phase = .final_candidate;
            try expectResponse(interpreted_final, expected);
            try expectStateAndRestore(&core, expected, poison);
            try core.commitFinalAnswer(active_leaf_id + 3);
            expected.active_leaf_id = active_leaf_id + 3;
            expected.final_entry_id = active_leaf_id + 3;
            expected.task_phase = .finished;
        } else {
            const final = try model_protocol.encodeText(&response_buffer, "ok");
            const final_digest = binding.hash(binding.Result, final);
            const admission = model_protocol.admit(&validation, final).admission;
            before = try canonicalState(&core);
            try expectRejectedPreserves(
                &core,
                before,
                expected,
                error.StaleOperation,
                discardResponse(core.applyModelResponse(.{
                    .id = operation.id,
                    .generation = operation.generation + 1,
                }, admission, response_ref + 1, final_digest)),
                poison,
            );
            const interpreted = try core.applyModelResponse(.{
                .id = operation.id,
                .generation = operation.generation,
            }, admission, response_ref, final_digest);
            expected.operation_result = response_ref;
            expected.operation_phase = .completed;
            expected.response_ref = response_ref;
            expected.response_disposition = .final_answer;
            expected.response_text = .{
                .offset = model_protocol.header_size,
                .length = 2,
            };
            expected.task_phase = .final_candidate;
            try expectResponse(interpreted, expected);
            try expectStateAndRestore(&core, expected, poison);
            before = try canonicalState(&core);
            try expectRejectedPreserves(
                &core,
                before,
                expected,
                error.IllegalFinalAnswerTransition,
                core.commitFinalAnswer(active_leaf_id + 2),
                poison,
            );
            try core.commitFinalAnswer(active_leaf_id + 1);
            expected.active_leaf_id = active_leaf_id + 1;
            expected.final_entry_id = active_leaf_id + 1;
            expected.task_phase = .finished;
        }
        try expectStateAndRestore(&core, expected, poison);
        core.abandon();
    }
}

fn expectRejectedPreserves(
    core: *core_image.Core,
    before: [core_state.encoded_size]u8,
    expected_state: core_state.State,
    expected_error: anyerror,
    result: anyerror!void,
    poison: u8,
) !void {
    result catch |actual| {
        if (actual != expected_error) return error.UnexpectedNativeRejection;
        const after = try canonicalState(core);
        if (!std.mem.eql(u8, &before, &after)) return error.RejectionMutatedCoreState;
        try expectStateAndRestore(core, expected_state, poison);
        return;
    };
    return error.NativeTransitionUnexpectedlyAccepted;
}

fn expectStateAndRestore(
    core: *core_image.Core,
    expected: core_state.State,
    poison: u8,
) !void {
    const expected_view = semanticView(expected);
    if (!std.meta.eql(expected_view, try observe(core))) return error.UnexpectedNativeSemanticView;

    const first = try canonicalState(core);
    var expected_encoding: [core_state.encoded_size]u8 = undefined;
    try core_state.encode(&expected_encoding, expected);
    if (!std.mem.eql(u8, &expected_encoding, &first)) return error.UnexpectedNativeCoreState;

    const decoded = try core_state.decode(&first);
    var second: [core_state.encoded_size]u8 = undefined;
    try core_state.encode(&second, decoded);
    if (!std.mem.eql(u8, &first, &second)) return error.NondeterministicCoreState;

    var restored_slot: core_image.ActivationSlot = undefined;
    @memset(std.mem.asBytes(&restored_slot), poison);
    var restored = try core_image.Core.activate(&restored_slot, &first);
    const restored_view = try observe(&restored);
    if (!std.meta.eql(expected_view, restored_view)) return error.RestoredSemanticViewMismatch;
    try restored.suspendInto(&second);
    if (!std.mem.eql(u8, &first, &second)) return error.RestoredCoreStateMismatch;
    for (std.mem.asBytes(&restored_slot)) |byte| {
        if (byte != 0) return error.RestoredSlotNotScrubbed;
    }
}

fn expectOperation(actual: core_image.Operation, expected: core_state.State) !void {
    if (!std.meta.eql(actual, operationView(expected))) return error.UnexpectedNativeOperation;
}

fn expectResponse(actual: core_image.Response, expected: core_state.State) !void {
    if (!std.meta.eql(actual, responseView(expected))) return error.UnexpectedNativeResponse;
}

fn semanticView(state: core_state.State) SemanticView {
    return .{
        .identity = .{
            .agent_id = state.agent_id,
            .generation = state.agent_generation,
        },
        .operation = operationView(state),
        .task = .{
            .phase = state.task_phase,
            .active_leaf_id = state.active_leaf_id,
            .final_entry_id = state.final_entry_id,
        },
        .response = responseView(state),
        .context = .{
            .first_entry = state.context.offset,
            .entry_count = state.context.length,
        },
    };
}

fn operationView(state: core_state.State) core_image.Operation {
    return .{
        .id = state.operation_id,
        .generation = state.operation_generation,
        .phase = state.operation_phase,
        .result_ref = state.operation_result,
        .sequence = state.operation_sequence,
    };
}

fn responseView(state: core_state.State) core_image.Response {
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

fn canonicalState(core: *const core_image.Core) ![core_state.encoded_size]u8 {
    var encoded: [core_state.encoded_size]u8 = undefined;
    try core_state.encode(&encoded, core.state.*);
    return encoded;
}

fn observe(core: *const core_image.Core) !SemanticView {
    return .{
        .identity = try core.identity(),
        .operation = try core.operation(),
        .task = try core.task(),
        .response = try core.response(),
        .context = try core.modelContext(),
    };
}

fn discardResponse(result: anyerror!core_image.Response) !void {
    _ = try result;
}

fn discardOperation(result: anyerror!core_image.Operation) !void {
    _ = try result;
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
