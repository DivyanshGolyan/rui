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

pub const Core = struct {
    slot: *ActivationSlot,
    state: *State,
    change: CommitChange = .none,
    active: bool = true,

    pub const CommitChange = union(enum) {
        none,
        unsupported,
        task_started: u64,
        model_operation_submitted: Operation,
        model_operation_admitted: Operation,
        model_response_applied: struct {
            operation: OperationIdentity,
            response_ref: u64,
            result_digest: binding.Result,
            disposition: model_protocol.Disposition,
        },
        tool_result_committed: struct {
            call_entry_id: u64,
            result_entry_id: u64,
        },
        final_answer_committed: u64,
    };

    pub fn initialize(slot: *ActivationSlot, identity_value: Identity) !Core {
        if (identity_value.agent_id == 0) return error.InvalidAgentIdentity;
        if (identity_value.generation == 0) return error.InvalidAgentGeneration;
        scrub(slot);
        slot.state = .{
            .agent_id = identity_value.agent_id,
            .agent_generation = identity_value.generation,
            .accumulator = identity_value.agent_id,
        };
        return .{
            .slot = slot,
            .state = &slot.state,
        };
    }

    pub fn activate(slot: *ActivationSlot, encoded: []const u8) !Core {
        scrub(slot);
        const restored = try core_state.decode(encoded);
        slot.state = restored;
        return .{
            .slot = slot,
            .state = &slot.state,
        };
    }

    pub fn suspendInto(self: *Core, encoded: []u8) !void {
        try self.requireActive();
        try core_state.encode(encoded, self.state.*);
        scrub(self.slot);
        self.active = false;
    }

    pub fn abandon(self: *Core) void {
        if (!self.active) return;
        scrub(self.slot);
        self.active = false;
    }

    pub fn identity(self: *const Core) !Identity {
        try self.requireActive();
        return .{
            .agent_id = self.state.agent_id,
            .generation = self.state.agent_generation,
        };
    }

    pub fn pendingCommitChange(self: *const Core) !CommitChange {
        try self.requireActive();
        return self.change;
    }

    pub fn operation(self: *const Core) !Operation {
        try self.requireActive();
        const state = self.state.*;
        return .{
            .id = state.operation_id,
            .generation = state.operation_generation,
            .phase = state.operation_phase,
            .result_ref = state.operation_result,
            .sequence = state.operation_sequence,
        };
    }

    pub fn task(self: *const Core) !Task {
        try self.requireActive();
        const state = self.state.*;
        return .{
            .phase = state.task_phase,
            .active_leaf_id = state.active_leaf_id,
            .final_entry_id = state.final_entry_id,
        };
    }

    pub fn response(self: *const Core) !Response {
        try self.requireActive();
        const state = self.state.*;
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

    pub fn modelContext(self: *const Core) !ModelContext {
        try self.requireActive();
        return .{
            .first_entry = self.state.context.offset,
            .entry_count = self.state.context.length,
        };
    }

    pub fn deliver(self: *Core, event: u32) !void {
        try self.requireActive();
        self.change = .unsupported;
        self.state.event_count +%= 1;
        self.state.last_event = event;
        self.state.accumulator = (self.state.accumulator *% 16_777_619) ^ event;
    }

    pub fn startTask(self: *Core, active_leaf_id: u64) !void {
        try self.requireActive();
        if (active_leaf_id == 0) return error.InvalidConversationEntry;
        if (self.state.task_phase != .idle or
            self.state.operation_phase != .idle)
        {
            return error.IllegalTaskTransition;
        }
        self.state.active_leaf_id = active_leaf_id;
        self.state.task_phase = .ready;
        self.change = .{ .task_started = active_leaf_id };
    }

    pub fn submitOperation(self: *Core, operation_id: u64, sequence: u64) !Operation {
        try self.requireActive();
        if (operation_id == 0 or sequence == 0) return error.InvalidOperationIdentity;
        const phase = self.state.operation_phase;
        if (phase != .idle and phase != .completed) return error.OperationAlreadyActive;
        if (self.state.operation_generation == std.math.maxInt(u32)) {
            return error.OperationGenerationExhausted;
        }
        self.state.operation_id = operation_id;
        self.state.operation_generation += 1;
        self.state.operation_phase = .submitted;
        self.state.operation_result = 0;
        self.state.operation_sequence = sequence;
        const prepared = try self.operation();
        self.change = .{ .model_operation_submitted = prepared };
        return prepared;
    }

    pub fn beginModelOperation(
        self: *Core,
        operation_id: u64,
        sequence: u64,
    ) !Operation {
        try self.requireActive();
        const active_leaf_id = self.state.active_leaf_id;
        if (self.state.task_phase != .ready or active_leaf_id >= std.math.maxInt(u32)) {
            return error.IllegalModelTransition;
        }
        const prepared = try self.submitOperation(operation_id, sequence);
        self.state.context = .{ .offset = 1, .length = @intCast(active_leaf_id) };
        self.state.response_ref = 0;
        self.state.response_disposition = .failure;
        self.state.response_failure = .none;
        self.state.response_text = .{};
        self.state.response_tool_key = .{};
        self.state.response_arguments = .{};
        self.state.response_arguments_digest = .{ .bytes = @splat(0) };
        self.state.task_phase = .awaiting_model;
        return prepared;
    }

    pub fn acceptOperation(self: *Core, identity_value: OperationIdentity) !void {
        try self.requireOperation(identity_value, .submitted);
        const submitted = switch (self.change) {
            .model_operation_submitted => |value| value,
            else => return error.UntrackedCoreTransition,
        };
        if (submitted.id != identity_value.id or submitted.generation != identity_value.generation) {
            return error.UntrackedCoreTransition;
        }
        self.state.operation_phase = .accepted;
        self.change = .{ .model_operation_admitted = try self.operation() };
    }

    pub fn applyModelResponse(
        self: *Core,
        identity_value: OperationIdentity,
        admission: model_protocol.Admission,
        response_ref: u64,
        result_digest: binding.Result,
    ) !Response {
        try self.requireOperation(identity_value, .accepted);
        if (response_ref == 0) return error.InvalidResultReference;
        if (admission.byte_length > model_protocol.max_response_size) return error.ResponseCapacityExceeded;
        if (self.state.task_phase != .awaiting_model) return error.IllegalModelResponseTransition;
        const parsed = try admission.verify(result_digest);
        if (admission.byte_length == 0 and
            !(parsed.disposition == .failure and parsed.failure == .empty))
        {
            return error.EmptyModelResponse;
        }
        self.state.operation_result = response_ref;
        self.state.operation_phase = .completed;
        self.state.response_ref = response_ref;
        self.state.response_disposition = parsed.disposition;
        self.state.response_failure = parsed.failure;
        self.state.response_text = if (parsed.disposition == .final_answer) .{
            .offset = parsed.text_offset,
            .length = parsed.text_length,
        } else .{};
        self.state.response_tool_key = .{
            .offset = parsed.tool_key_offset,
            .length = parsed.tool_key_length,
        };
        self.state.response_arguments = .{
            .offset = parsed.arguments_offset,
            .length = parsed.arguments_length,
        };
        self.state.response_arguments_digest = parsed.arguments_digest;
        self.state.task_phase = switch (parsed.disposition) {
            .final_answer => .final_candidate,
            .tool_call => .awaiting_tool,
            // Issue #38 replaces this terminal boundary with the atomic
            // Conversation and durable Interaction Request transition.
            .input_request => .failed,
            .failure => .failed,
        };
        self.change = .{ .model_response_applied = .{
            .operation = identity_value,
            .response_ref = response_ref,
            .result_digest = result_digest,
            .disposition = parsed.disposition,
        } };
        return self.response();
    }

    pub fn commitFinalAnswer(self: *Core, entry_id: u64) !void {
        try self.requireActive();
        if (entry_id == 0 or self.state.active_leaf_id == std.math.maxInt(u64)) {
            return error.InvalidConversationEntry;
        }
        if (self.state.task_phase != .final_candidate or
            entry_id != self.state.active_leaf_id + 1)
        {
            return error.IllegalFinalAnswerTransition;
        }
        self.state.active_leaf_id = entry_id;
        self.state.final_entry_id = entry_id;
        self.state.task_phase = .finished;
        self.change = .{ .final_answer_committed = entry_id };
    }

    pub fn commitToolResult(self: *Core, call_entry_id: u64, result_entry_id: u64) !void {
        try self.requireActive();
        if (call_entry_id == 0 or result_entry_id == 0 or
            self.state.active_leaf_id == std.math.maxInt(u64) or
            call_entry_id == std.math.maxInt(u64))
        {
            return error.InvalidConversationEntry;
        }
        if (self.state.task_phase != .awaiting_tool or
            call_entry_id != self.state.active_leaf_id + 1 or
            result_entry_id != call_entry_id + 1)
        {
            return error.IllegalToolResultTransition;
        }
        self.state.active_leaf_id = result_entry_id;
        self.state.task_phase = .ready;
        self.change = .{ .tool_result_committed = .{
            .call_entry_id = call_entry_id,
            .result_entry_id = result_entry_id,
        } };
    }

    fn requireOperation(
        self: *const Core,
        identity_value: OperationIdentity,
        phase: OperationPhase,
    ) !void {
        try self.requireActive();
        if (identity_value.id == 0 or identity_value.generation == 0) {
            return error.InvalidOperationIdentity;
        }
        if (self.state.operation_id != identity_value.id or
            self.state.operation_generation != identity_value.generation)
        {
            return error.StaleOperation;
        }
        if (self.state.operation_phase != phase) return error.IllegalOperationTransition;
    }

    fn requireActive(self: *const Core) !void {
        if (!self.active) return error.InactiveCore;
    }
};

pub fn scrub(slot: *ActivationSlot) void {
    @memset(std.mem.asBytes(slot), 0);
}

comptime {
    @setEvalBranchQuota(100_000);
    std.debug.assert(@sizeOf(ActivationSlot) == slot_size);
    std.debug.assert(@alignOf(ActivationSlot) == slot_alignment);
    assertNoAllocatorParameter(Core.initialize);
    assertNoAllocatorParameter(Core.activate);
    assertNoAllocatorParameter(Core.deliver);
    assertNoAllocatorParameter(Core.startTask);
    assertNoAllocatorParameter(Core.submitOperation);
    assertNoAllocatorParameter(Core.beginModelOperation);
    assertNoAllocatorParameter(Core.acceptOperation);
    assertNoAllocatorParameter(Core.applyModelResponse);
    assertNoAllocatorParameter(Core.commitFinalAnswer);
    assertNoAllocatorParameter(Core.commitToolResult);
    assertNoAllocatorParameter(Core.suspendInto);
    assertNoAllocatorParameter(Core.abandon);
    assertNoAllocatorStorage(Core);
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

test "Activation Slot is exact and suspension encodes only Core State then scrubs every byte" {
    var slot: ActivationSlot = undefined;
    @memset(std.mem.asBytes(&slot), 0xa5);
    var core = try Core.initialize(&slot, .{ .agent_id = 42, .generation = 7 });
    try core.deliver(9);
    var encoded: [core_state.encoded_size]u8 = undefined;
    try core.suspendInto(&encoded);
    for (std.mem.asBytes(&slot)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    const state = try core_state.decode(&encoded);
    try std.testing.expectEqual(@as(u64, 42), state.agent_id);
    try std.testing.expectEqual(@as(u64, 1), state.event_count);
}

test "Core initialization rejects invalid identity and generation" {
    var slot: ActivationSlot = undefined;
    try std.testing.expectError(
        error.InvalidAgentIdentity,
        Core.initialize(&slot, .{ .agent_id = 0, .generation = 1 }),
    );
    try std.testing.expectError(
        error.InvalidAgentGeneration,
        Core.initialize(&slot, .{ .agent_id = 1, .generation = 0 }),
    );
}

test "poisoned slots restore to identical semantic outcomes and encodings" {
    var source: ActivationSlot = undefined;
    var core = try Core.initialize(&source, .{ .agent_id = 7, .generation = 1 });
    try core.startTask(1);
    var initial: [core_state.encoded_size]u8 = undefined;
    try core.suspendInto(&initial);

    var first_slot: ActivationSlot = undefined;
    var second_slot: ActivationSlot = undefined;
    @memset(std.mem.asBytes(&first_slot), 0x11);
    @memset(std.mem.asBytes(&second_slot), 0xee);
    var first = try Core.activate(&first_slot, &initial);
    var second = try Core.activate(&second_slot, &initial);
    _ = try first.beginModelOperation(10, 2);
    _ = try second.beginModelOperation(10, 2);
    var first_encoded: [core_state.encoded_size]u8 = undefined;
    var second_encoded: [core_state.encoded_size]u8 = undefined;
    try first.suspendInto(&first_encoded);
    try second.suspendInto(&second_encoded);
    try std.testing.expectEqualSlices(u8, &first_encoded, &second_encoded);
}

test "failed activation leaves no prior slot bytes reachable" {
    var slot: ActivationSlot = undefined;
    @memset(std.mem.asBytes(&slot), 0xa5);
    var corrupt: [core_state.encoded_size]u8 = @splat(0xff);
    try std.testing.expectError(error.InvalidCoreStateMagic, Core.activate(&slot, &corrupt));
    for (std.mem.asBytes(&slot)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "oversized admission preserves accepted operation state" {
    var slot: ActivationSlot = undefined;
    var core = try Core.initialize(&slot, .{ .agent_id = 7, .generation = 1 });
    try core.startTask(1);
    const operation_value = try core.beginModelOperation(10, 1);
    try std.testing.expectError(
        error.StaleOperation,
        core.acceptOperation(.{ .id = operation_value.id, .generation = operation_value.generation + 1 }),
    );
    try core.acceptOperation(.{ .id = operation_value.id, .generation = operation_value.generation });
    const before = try core.operation();
    var response_buffer: [model_protocol.max_response_size]u8 = undefined;
    var validation: model_protocol.ValidationScratch = undefined;
    const encoded = try model_protocol.encodeText(&response_buffer, "valid");
    const admitted = model_protocol.admit(&validation, encoded);
    var oversized = admitted.admission;
    oversized.byte_length = model_protocol.max_response_size + 1;
    try std.testing.expectError(
        error.ResponseCapacityExceeded,
        core.applyModelResponse(
            .{ .id = operation_value.id, .generation = operation_value.generation },
            oversized,
            99,
            binding.hash(binding.Result, encoded),
        ),
    );
    try std.testing.expectEqualDeep(before, try core.operation());

    try std.testing.expectError(
        error.InvalidModelResponseEvidence,
        core.applyModelResponse(
            .{ .id = operation_value.id, .generation = operation_value.generation },
            admitted.admission,
            99,
            binding.hash(binding.Result, "substituted"),
        ),
    );
    try std.testing.expectEqualDeep(before, try core.operation());
}

test "responses retain only validated metadata and durable content windows" {
    var slot: ActivationSlot = undefined;
    var core = try Core.initialize(&slot, .{ .agent_id = 7, .generation = 1 });
    defer core.abandon();
    try core.startTask(1);
    const operation = try core.beginModelOperation(2, 1);
    const identity: OperationIdentity = .{ .id = operation.id, .generation = operation.generation };
    try core.acceptOperation(identity);

    var value: [model_contract.max_patch_input_bytes]u8 = @splat(0x01);
    var arguments_buffer: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
    var validation: model_protocol.ValidationScratch = undefined;
    const arguments = try model_contract.encodeJson(&arguments_buffer, .{ .patch = &value });
    var response_buffer: [model_protocol.max_response_size]u8 = undefined;
    const response = try model_protocol.encodeTool(&response_buffer, model_contract.apply_patch_key, arguments);
    try std.testing.expect(response.len > model_protocol.max_resident_response_size);
    const parsed = try core.applyModelResponse(
        identity,
        model_protocol.admit(&validation, response).admission,
        3,
        binding.hash(binding.Result, response),
    );
    try std.testing.expectEqual(@as(u32, @intCast(arguments.len)), parsed.arguments.length);
    try std.testing.expectEqual(@as(u64, 3), parsed.content_ref);
}

test "complete slot lifecycle is compiler checked to expose no allocator seam" {
    var first_slot: ActivationSlot = undefined;
    var core = try Core.initialize(&first_slot, .{ .agent_id = 9, .generation = 1 });
    try core.startTask(1);
    const operation_value = try core.beginModelOperation(2, 1);
    try core.acceptOperation(.{ .id = operation_value.id, .generation = operation_value.generation });
    var response_bytes: [model_protocol.max_response_size]u8 = undefined;
    var validation: model_protocol.ValidationScratch = undefined;
    const response = try model_protocol.encodeText(&response_bytes, "done");
    _ = try core.applyModelResponse(
        .{ .id = operation_value.id, .generation = operation_value.generation },
        model_protocol.admit(&validation, response).admission,
        3,
        binding.hash(binding.Result, response),
    );
    var encoded: [core_state.encoded_size]u8 = undefined;
    try core.suspendInto(&encoded);

    var reused_slot: ActivationSlot = undefined;
    @memset(std.mem.asBytes(&reused_slot), 0xff);
    var restored = try Core.activate(&reused_slot, &encoded);
    try restored.commitFinalAnswer(2);
    try restored.suspendInto(&encoded);
}

test "generation exhaustion is a closed rejection" {
    var slot: ActivationSlot = undefined;
    var core = try Core.initialize(&slot, .{ .agent_id = 7, .generation = 1 });
    core.state.operation_generation = std.math.maxInt(u32);
    try std.testing.expectError(
        error.OperationGenerationExhausted,
        core.submitOperation(1, 1),
    );
    try std.testing.expectEqual(OperationPhase.idle, (try core.operation()).phase);
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

test "maximum context window is rejected before operation mutation" {
    var slot: ActivationSlot = undefined;
    var core = try Core.initialize(&slot, .{ .agent_id = 7, .generation = 1 });
    core.state.active_leaf_id = std.math.maxInt(u32);
    core.state.task_phase = .ready;
    const before = try core.operation();
    try std.testing.expectError(error.IllegalModelTransition, core.beginModelOperation(1, 1));
    try std.testing.expectEqualDeep(before, try core.operation());
}
const TraceView = struct {
    identity: Identity,
    operation: Operation,
    task: Task,
    response: Response,
    context: ModelContext,
};

const trace_count = 32;

fn randomizedStateMachineTraces(slot: *ActivationSlot) !void {
    var random = std.Random.DefaultPrng.init(0x5354_4154_454d_4143);
    for (0..trace_count) |trace_index| {
        const poison: u8 = @intCast(trace_index + 1);
        const agent_id: u64 = trace_index + 1;
        var expected: core_state.State = .{
            .agent_id = agent_id,
            .agent_generation = 1,
            .accumulator = agent_id,
        };
        var core = try Core.initialize(
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
    core: *Core,
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
    core: *Core,
    expected: core_state.State,
    poison: u8,
) !void {
    const expected_view = semanticView(expected);
    if (!std.meta.eql(expected_view, try observe(core))) return error.UnexpectedNativeTraceView;

    const first = try canonicalState(core);
    var expected_encoding: [core_state.encoded_size]u8 = undefined;
    try core_state.encode(&expected_encoding, expected);
    if (!std.mem.eql(u8, &expected_encoding, &first)) return error.UnexpectedNativeCoreState;

    const decoded = try core_state.decode(&first);
    var second: [core_state.encoded_size]u8 = undefined;
    try core_state.encode(&second, decoded);
    if (!std.mem.eql(u8, &first, &second)) return error.NondeterministicCoreState;

    var restored_slot: ActivationSlot = undefined;
    @memset(std.mem.asBytes(&restored_slot), poison);
    var restored = try Core.activate(&restored_slot, &first);
    const restored_view = try observe(&restored);
    if (!std.meta.eql(expected_view, restored_view)) return error.RestoredTraceViewMismatch;
    try restored.suspendInto(&second);
    if (!std.mem.eql(u8, &first, &second)) return error.RestoredCoreStateMismatch;
    for (std.mem.asBytes(&restored_slot)) |byte| {
        if (byte != 0) return error.RestoredSlotNotScrubbed;
    }
}

fn expectOperation(actual: Operation, expected: core_state.State) !void {
    if (!std.meta.eql(actual, operationView(expected))) return error.UnexpectedNativeOperation;
}

fn expectResponse(actual: Response, expected: core_state.State) !void {
    if (!std.meta.eql(actual, responseView(expected))) return error.UnexpectedNativeResponse;
}

fn semanticView(state: core_state.State) TraceView {
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

fn operationView(state: core_state.State) Operation {
    return .{
        .id = state.operation_id,
        .generation = state.operation_generation,
        .phase = state.operation_phase,
        .result_ref = state.operation_result,
        .sequence = state.operation_sequence,
    };
}

fn responseView(state: core_state.State) Response {
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

fn canonicalState(core: *const Core) ![core_state.encoded_size]u8 {
    var encoded: [core_state.encoded_size]u8 = undefined;
    try core_state.encode(&encoded, core.state.*);
    return encoded;
}

fn observe(core: *const Core) !TraceView {
    return .{
        .identity = try core.identity(),
        .operation = try core.operation(),
        .task = try core.task(),
        .response = try core.response(),
        .context = try core.modelContext(),
    };
}

fn discardResponse(result: anyerror!Response) !void {
    _ = try result;
}

fn discardOperation(result: anyerror!Operation) !void {
    _ = try result;
}

test "production Core passes 32 randomized poison and rejection traces" {
    var slot: ActivationSlot = undefined;
    try randomizedStateMachineTraces(&slot);
}
