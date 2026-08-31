const std = @import("std");
const binding = @import("binding.zig");
const core_state = @import("core_state.zig");
const model_contract = @import("model_contract.zig");
const model_protocol = @import("model_protocol.zig");

pub const slot_ceiling = 32 * 1024;
pub const slot_alignment = 8;

pub const State = core_state.State;
pub const ContentWindow = core_state.ContentWindow;
pub const OperationPhase = core_state.OperationPhase;
pub const TaskPhase = core_state.TaskPhase;

/// Caller-owned working storage for one Activation. None of its layout is durable.
pub const ActivationSlot = extern struct {
    state: State,
};

pub const slot_size = @sizeOf(ActivationSlot);

comptime {
    std.debug.assert(slot_size <= slot_ceiling);
}

pub const Identity = struct {
    agent_id: u64,
    generation: u32,
};

pub const OperationIdentity = struct {
    id: u64,
    generation: u32,
};

pub const Operation = struct {
    id: u64,
    generation: u32,
    phase: OperationPhase,
    result_ref: u64,
    sequence: u64,
};

pub const ModelContext = struct {
    first_entry: u32,
    entry_count: u32,
};

pub const Response = struct {
    content_ref: u64,
    disposition: model_protocol.Disposition,
    failure: model_protocol.Failure,
    text: ContentWindow,
    tool_key: ContentWindow,
    arguments: StrictToolJsonWindow,
};

pub const StrictToolJsonWindow = struct {
    offset: u32,
    length: u32,
    digest: binding.StrictToolJsonV1,

    pub fn contentWindow(self: StrictToolJsonWindow) ContentWindow {
        return .{ .offset = self.offset, .length = self.length };
    }
};

pub const Task = struct {
    phase: TaskPhase,
    active_leaf_id: u64,
    final_entry_id: u64,
};

pub const SlotLease = struct {
    slot: *ActivationSlot,
    context: *anyopaque,
    index: usize,
    generation: u64,
    release_fn: *const fn (*anyopaque, usize, u64, *ActivationSlot) error{StaleSlotLease}!void,
    borrowed: bool = true,

    pub fn release(self: *SlotLease) error{StaleSlotLease}!void {
        if (!self.borrowed) return;
        try self.release_fn(self.context, self.index, self.generation, self.slot);
        self.borrowed = false;
    }
};

/// Runtime-sized production Slot storage. One Host owns one fixed allocation
/// for its complete lifetime; Session population never changes its capacity.
pub const RuntimeSlotPool = struct {
    const state_mask: u64 = 0b11;
    const state_free: u64 = 0;
    const state_occupied: u64 = 1;
    const state_releasing: u64 = 2;
    const generation_step: u64 = 4;

    const Cell = struct {
        slot: ActivationSlot = undefined,
        /// Low two bits: free=0, occupied=1, releasing=2. Higher bits form a
        /// monotonically increasing generation that fences stale lease copies.
        state: std.atomic.Value(u64) = .init(0),
    };

    cells: []Cell,
    occupied_count: std.atomic.Value(usize) = .init(0),
    occupied_high_water: std.atomic.Value(usize) = .init(0),

    pub fn init(allocator: std.mem.Allocator, slot_capacity: usize) !RuntimeSlotPool {
        if (slot_capacity == 0) return error.InvalidActivationCapacity;
        const cells = try allocator.alloc(Cell, slot_capacity);
        for (cells) |*cell| cell.* = .{};
        return .{ .cells = cells };
    }

    pub fn deinit(self: *RuntimeSlotPool, allocator: std.mem.Allocator) void {
        std.debug.assert(self.occupied_count.load(.acquire) == 0);
        for (self.cells) |*cell| {
            std.debug.assert(cell.state.load(.acquire) & state_mask == state_free);
            scrub(&cell.slot);
        }
        allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn borrow(self: *RuntimeSlotPool) !SlotLease {
        for (self.cells, 0..) |*cell, index| {
            var state = cell.state.load(.acquire);
            while (state & state_mask == state_free) {
                if (state > std.math.maxInt(u64) - generation_step) break;
                const occupied_state = state + state_occupied;
                if (cell.state.cmpxchgWeak(state, occupied_state, .acq_rel, .acquire)) |actual| {
                    state = actual;
                    continue;
                }
                scrub(&cell.slot);
                const occupied = self.occupied_count.fetchAdd(1, .acq_rel) + 1;
                self.raiseHighWater(occupied);
                return .{
                    .slot = &cell.slot,
                    .context = self,
                    .index = index,
                    .generation = occupied_state,
                    .release_fn = releaseLease,
                };
            }
        }
        return error.ActivationCapacityExhausted;
    }

    pub fn capacity(self: *const RuntimeSlotPool) usize {
        return self.cells.len;
    }

    pub fn residentBytes(self: *const RuntimeSlotPool) usize {
        return self.cells.len * @sizeOf(ActivationSlot);
    }

    pub fn occupiedBytes(self: *const RuntimeSlotPool) usize {
        return self.occupied_count.load(.acquire) * @sizeOf(ActivationSlot);
    }

    pub fn occupiedHighWaterBytes(self: *const RuntimeSlotPool) usize {
        return self.occupied_high_water.load(.acquire) * @sizeOf(ActivationSlot);
    }

    pub fn hostOverheadBytes(self: *const RuntimeSlotPool) usize {
        return @sizeOf(RuntimeSlotPool) + self.cells.len * (@sizeOf(Cell) - @sizeOf(ActivationSlot));
    }

    fn raiseHighWater(self: *RuntimeSlotPool, occupied: usize) void {
        var high_water = self.occupied_high_water.load(.acquire);
        while (occupied > high_water) {
            high_water = self.occupied_high_water.cmpxchgWeak(
                high_water,
                occupied,
                .acq_rel,
                .acquire,
            ) orelse return;
        }
    }

    fn releaseLease(
        context: *anyopaque,
        index: usize,
        generation: u64,
        slot: *ActivationSlot,
    ) error{StaleSlotLease}!void {
        const self: *RuntimeSlotPool = @ptrCast(@alignCast(context));
        if (index >= self.cells.len) return error.StaleSlotLease;
        const cell = &self.cells[index];
        if (slot != &cell.slot or generation & state_mask != state_occupied or
            cell.state.cmpxchgStrong(
                generation,
                generation + state_releasing - state_occupied,
                .acq_rel,
                .acquire,
            ) != null)
        {
            return error.StaleSlotLease;
        }
        scrub(slot);
        const previous = self.occupied_count.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        cell.state.store(generation + generation_step - state_occupied, .release);
    }
};

pub fn initialize(identity_value: Identity) !State {
    if (identity_value.agent_id == 0) return error.InvalidAgentIdentity;
    if (identity_value.generation == 0) return error.InvalidAgentGeneration;
    return .{
        .agent_id = identity_value.agent_id,
        .agent_generation = identity_value.generation,
    };
}

pub fn identity(state: State) Identity {
    return .{ .agent_id = state.agent_id, .generation = state.agent_generation };
}

pub fn operation(state: State) Operation {
    return .{
        .id = state.operation_id,
        .generation = state.operation_generation,
        .phase = state.operation_phase,
        .result_ref = state.operation_result,
        .sequence = state.operation_sequence,
    };
}

pub fn task(state: State) Task {
    return .{
        .phase = state.task_phase,
        .active_leaf_id = state.active_leaf_id,
        .final_entry_id = state.final_entry_id,
    };
}

pub fn response(state: State) Response {
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

pub fn modelContext(state: State) ModelContext {
    return .{ .first_entry = state.context.offset, .entry_count = state.context.length };
}

pub fn startTask(committed: State, active_leaf_id: u64) !State {
    if (active_leaf_id == 0) return error.InvalidConversationEntry;
    if (committed.task_phase != .idle or committed.operation_phase != .idle) {
        return error.IllegalTaskTransition;
    }
    var candidate = committed;
    candidate.active_leaf_id = active_leaf_id;
    candidate.task_phase = .ready;
    return candidate;
}

pub const ModelAttemptReduction = struct {
    state: State,
    operation: Operation,
    context: ModelContext,
};

pub fn admitModelAttempt(
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

pub const CompletionConsequence = union(enum) {
    final_answer: u64,
    tool_call,
    terminal,
};

pub const ModelCompletionReduction = struct {
    state: State,
    response: Response,
};

pub fn admitModelCompletion(
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

pub fn admitToolResult(committed: State, call_entry_id: u64, result_entry_id: u64) !State {
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

fn requireOperation(state: State, identity_value: OperationIdentity, phase: OperationPhase) !void {
    if (identity_value.id == 0 or identity_value.generation == 0) {
        return error.InvalidOperationIdentity;
    }
    if (state.operation_id != identity_value.id or
        state.operation_generation != identity_value.generation)
    {
        return error.StaleOperation;
    }
    if (state.operation_phase != phase) return error.IllegalOperationTransition;
}

pub fn scrub(slot: *ActivationSlot) void {
    @memset(std.mem.asBytes(slot), 0);
}

comptime {
    @setEvalBranchQuota(100_000);
    std.debug.assert(@sizeOf(ActivationSlot) == slot_size);
    std.debug.assert(@alignOf(ActivationSlot) == slot_alignment);
    assertNoAllocatorParameter(initialize);
    assertNoAllocatorParameter(startTask);
    assertNoAllocatorParameter(admitModelAttempt);
    assertNoAllocatorParameter(admitModelCompletion);
    assertNoAllocatorParameter(admitToolResult);
    assertNoAllocatorStorage(State);
    assertNoAllocatorParameter(RuntimeSlotPool.borrow);
}

fn assertNoAllocatorParameter(comptime callable: anytype) void {
    const function_info = @typeInfo(@TypeOf(callable)).@"fn";
    for (function_info.params) |parameter| {
        if (parameter.type != null and containsAllocator(parameter.type.?)) {
            @compileError("Core slot lifecycle cannot expose an allocator seam");
        }
    }
}

fn assertNoAllocatorStorage(comptime T: type) void {
    if (containsAllocator(T)) {
        @compileError("Core cannot retain an allocator capability");
    }
}

fn containsAllocator(comptime T: type) bool {
    if (T == std.mem.Allocator) return true;
    return switch (@typeInfo(T)) {
        .pointer => |pointer| containsAllocator(pointer.child),
        .optional => |optional| containsAllocator(optional.child),
        .array => |array| containsAllocator(array.child),
        .vector => |vector| containsAllocator(vector.child),
        .error_union => |error_union| containsAllocator(error_union.payload),
        .@"struct", .@"union" => blk: {
            for (std.meta.fields(T)) |field| {
                if (containsAllocator(field.type)) break :blk true;
            }
            break :blk false;
        },
        .@"fn" => |function| blk: {
            for (function.params) |parameter| {
                if (parameter.type != null and containsAllocator(parameter.type.?)) break :blk true;
            }
            if (function.return_type) |return_type| {
                if (containsAllocator(return_type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn readyState(agent_id: u64, leaf_id: u64) !State {
    return startTask(try initialize(.{ .agent_id = agent_id, .generation = 1 }), leaf_id);
}

fn expectCanonical(state: State) !void {
    var first: [core_state.encoded_size]u8 = undefined;
    var second: [core_state.encoded_size]u8 = undefined;
    try core_state.encode(&first, state);
    const restored = try core_state.decode(&first);
    try core_state.encode(&second, restored);
    try std.testing.expectEqualSlices(u8, &first, &second);
    try std.testing.expectEqualDeep(state, restored);
}

test "pure continuation reducers reject invalid identity without mutation" {
    try std.testing.expectError(
        error.InvalidAgentIdentity,
        initialize(.{ .agent_id = 0, .generation = 1 }),
    );
    try std.testing.expectError(
        error.InvalidAgentGeneration,
        initialize(.{ .agent_id = 1, .generation = 0 }),
    );

    const ready = try readyState(7, 1);
    var before: [core_state.encoded_size]u8 = undefined;
    var after: [core_state.encoded_size]u8 = undefined;
    try core_state.encode(&before, ready);
    try std.testing.expectError(error.InvalidOperationIdentity, admitModelAttempt(ready, 0, 1));
    try core_state.encode(&after, ready);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "model attempt admission is atomic deterministic and canonical" {
    const ready = try readyState(7, 3);
    const first = try admitModelAttempt(ready, 10, 2);
    const second = try admitModelAttempt(ready, 10, 2);
    try std.testing.expectEqualDeep(first, second);
    try std.testing.expectEqual(OperationPhase.accepted, first.operation.phase);
    try std.testing.expectEqual(TaskPhase.awaiting_model, task(first.state).phase);
    try std.testing.expectEqual(@as(u32, 1), first.context.first_entry);
    try std.testing.expectEqual(@as(u32, 3), first.context.entry_count);
    try expectCanonical(first.state);
}

test "model completion binds exact evidence and consequence" {
    const attempt = try admitModelAttempt(try readyState(7, 1), 10, 1);
    var bytes: [model_protocol.max_response_size]u8 = undefined;
    var scratch: model_protocol.ValidationScratch = undefined;
    const encoded = try model_protocol.encodeText(&bytes, "done");
    const digest = binding.hash(binding.Result, encoded);
    const admission = model_protocol.admit(&scratch, encoded).admission;
    const first = try admitModelCompletion(
        attempt.state,
        .{ .id = 10, .generation = 1 },
        admission,
        20,
        digest,
        .{ .final_answer = 2 },
    );
    const second = try admitModelCompletion(
        attempt.state,
        .{ .id = 10, .generation = 1 },
        admission,
        20,
        digest,
        .{ .final_answer = 2 },
    );
    try std.testing.expectEqualDeep(first, second);
    try std.testing.expectEqual(TaskPhase.finished, task(first.state).phase);
    try std.testing.expectEqual(@as(u64, 2), task(first.state).final_entry_id);
    try expectCanonical(first.state);
    try std.testing.expectError(
        error.InvalidModelResponseEvidence,
        admitModelCompletion(
            attempt.state,
            .{ .id = 10, .generation = 1 },
            admission,
            20,
            binding.hash(binding.Result, "substituted"),
            .{ .final_answer = 2 },
        ),
    );
    try std.testing.expectError(
        error.InvalidCompletionConsequence,
        admitModelCompletion(
            attempt.state,
            .{ .id = 10, .generation = 1 },
            admission,
            20,
            digest,
            .tool_call,
        ),
    );
}

test "tool completion retains bounded windows and tool result resumes the task" {
    const attempt = try admitModelAttempt(try readyState(9, 1), 12, 1);
    var patch: [model_contract.max_patch_input_bytes]u8 = @splat('x');
    var arguments_buffer: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
    const arguments = try model_contract.encodeJson(&arguments_buffer, .{ .patch = &patch });
    var bytes: [model_protocol.max_response_size]u8 = undefined;
    const encoded = try model_protocol.encodeTool(
        &bytes,
        model_contract.apply_patch_key,
        arguments,
    );
    var scratch: model_protocol.ValidationScratch = undefined;
    const completed = try admitModelCompletion(
        attempt.state,
        .{ .id = 12, .generation = 1 },
        model_protocol.admit(&scratch, encoded).admission,
        30,
        binding.hash(binding.Result, encoded),
        .tool_call,
    );
    try std.testing.expectEqual(TaskPhase.awaiting_tool, task(completed.state).phase);
    try std.testing.expectEqual(@as(u32, @intCast(arguments.len)), completed.response.arguments.length);
    const resumed = try admitToolResult(completed.state, 2, 3);
    try std.testing.expectEqual(TaskPhase.ready, task(resumed).phase);
    try std.testing.expectEqual(@as(u64, 3), task(resumed).active_leaf_id);
    try expectCanonical(resumed);
    try std.testing.expectError(error.IllegalToolResultTransition, admitToolResult(resumed, 4, 5));
}

test "terminal model completion fails atomically" {
    const attempt = try admitModelAttempt(try readyState(11, 1), 13, 1);
    var bytes: [model_protocol.max_response_size]u8 = undefined;
    const encoded = try model_protocol.encodeFailure(&bytes, .provider_error);
    var scratch: model_protocol.ValidationScratch = undefined;
    const completed = try admitModelCompletion(
        attempt.state,
        .{ .id = 13, .generation = 1 },
        model_protocol.admit(&scratch, encoded).admission,
        31,
        binding.hash(binding.Result, encoded),
        .terminal,
    );
    try std.testing.expectEqual(TaskPhase.failed, task(completed.state).phase);
    try expectCanonical(completed.state);
}

test "all production reducers are deterministic across 32 traces" {
    for (0..32) |index| {
        const agent_id: u64 = index + 1;
        const ready = try readyState(agent_id, 1);
        const operation_id: u64 = index + 100;
        const first = try admitModelAttempt(ready, operation_id, 1);
        const second = try admitModelAttempt(ready, operation_id, 1);
        try std.testing.expectEqualDeep(first, second);
        try expectCanonical(first.state);
    }
}

test "scrub clears every Activation Slot byte" {
    var slot: ActivationSlot = undefined;
    @memset(std.mem.asBytes(&slot), 0xa5);
    scrub(&slot);
    for (std.mem.asBytes(&slot)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "runtime slot pool returns closed capacity and scrubs before reuse" {
    var pool = try RuntimeSlotPool.init(std.testing.allocator, 1);
    defer pool.deinit(std.testing.allocator);
    var lease = try pool.borrow();
    @memset(std.mem.asBytes(lease.slot), 0xa5);
    try std.testing.expectError(error.ActivationCapacityExhausted, pool.borrow());
    try lease.release();

    var reused = try pool.borrow();
    defer reused.release() catch unreachable;
    for (std.mem.asBytes(reused.slot)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqual(slot_size, pool.residentBytes());
}

test "the filler-free Activation Slot contains only decoded Core State" {
    try std.testing.expectEqual(@sizeOf(State), @sizeOf(ActivationSlot));
    try std.testing.expect(@sizeOf(ActivationSlot) <= slot_ceiling);
}

test "stale copied lease cannot release a newly borrowed slot" {
    var pool = try RuntimeSlotPool.init(std.testing.allocator, 1);
    defer pool.deinit(std.testing.allocator);
    var original = try pool.borrow();
    var stale_copy = original;
    try original.release();

    var current = try pool.borrow();
    defer current.release() catch unreachable;
    current.slot.state.agent_id = 99;
    try std.testing.expectError(error.StaleSlotLease, stale_copy.release());

    try std.testing.expectEqual(@as(u64, 99), current.slot.state.agent_id);
    try std.testing.expectError(error.ActivationCapacityExhausted, pool.borrow());
}

test "runtime Slot pool admits exactly its capacity under concurrent borrowing" {
    const Worker = struct {
        fn run(
            pool: *RuntimeSlotPool,
            active_mask: *std.atomic.Value(u64),
            ready: *std.atomic.Value(usize),
            release: *const std.atomic.Value(bool),
            failed: *std.atomic.Value(bool),
        ) void {
            var lease = pool.borrow() catch {
                failed.store(true, .release);
                return;
            };
            const bit = @as(u64, 1) << @intCast(lease.index);
            if (active_mask.fetchOr(bit, .acq_rel) & bit != 0) failed.store(true, .release);
            _ = ready.fetchAdd(1, .acq_rel);
            while (!release.load(.acquire)) std.atomic.spinLoopHint();
            _ = active_mask.fetchAnd(~bit, .acq_rel);
            lease.release() catch failed.store(true, .release);
        }
    };

    var pool = try RuntimeSlotPool.init(std.testing.allocator, 4);
    defer pool.deinit(std.testing.allocator);
    var active_mask: std.atomic.Value(u64) = .init(0);
    var ready: std.atomic.Value(usize) = .init(0);
    var release: std.atomic.Value(bool) = .init(false);
    var failed: std.atomic.Value(bool) = .init(false);
    var workers: [4]std.Thread = undefined;
    for (&workers) |*worker| {
        worker.* = try std.Thread.spawn(.{}, Worker.run, .{
            &pool,
            &active_mask,
            &ready,
            &release,
            &failed,
        });
    }
    while (ready.load(.acquire) != workers.len and !failed.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
    const all_workers_borrowed = !failed.load(.acquire) and ready.load(.acquire) == workers.len;
    const unique_slots = active_mask.load(.acquire) == 0b1111;
    const full_is_closed = if (pool.borrow()) |unexpected| block: {
        var lease = unexpected;
        lease.release() catch failed.store(true, .release);
        break :block false;
    } else |err| err == error.ActivationCapacityExhausted;
    const high_water_is_exact = pool.occupiedHighWaterBytes() == 4 * @sizeOf(ActivationSlot);
    release.store(true, .release);
    for (workers) |worker| worker.join();
    try std.testing.expect(all_workers_borrowed);
    try std.testing.expect(unique_slots);
    try std.testing.expect(full_is_closed);
    try std.testing.expect(high_water_is_exact);
}
