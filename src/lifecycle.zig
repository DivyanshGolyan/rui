const std = @import("std");
const binding = @import("binding.zig");
const bash_tool = @import("bash_tool.zig");
const completion_inbox = @import("completion_inbox.zig");
const conversation = @import("conversation.zig");
const core_image = @import("core_image.zig");
const host_store = @import("host_store.zig");
const model_operation = @import("model_operation.zig");
const model_contract = @import("model_contract.zig");
const model_protocol = @import("model_protocol.zig");
const patch_tool = @import("patch_tool.zig");
const session_store = @import("session.zig");
const session_transition = @import("session_transition.zig");

const agent_generation: u32 = 1;

comptime {
    std.debug.assert(model_contract.max_patch_input_bytes == patch_tool.max_patch_size);
}

/// Process-owned bounded activation capacity. Construct this once at host
/// startup and pass it through every agent lifecycle entry point.
pub const Host = struct {
    const CreditCell = std.atomic.Value(bool);

    allocator: std.mem.Allocator,
    slots: core_image.RuntimeSlotPool,
    credits: []CreditCell,
    occupied_credits: std.atomic.Value(usize) = .init(0),
    credit_high_water: std.atomic.Value(usize) = .init(0),
    semantic_validation: SemanticValidationWorkspacePool = .{},
    patch_workspace: PatchWorkspacePool = .{},

    /// The fixed admission token held by one live Harness today. Issue #34
    /// transfers this same token to an admitted detached Attempt or closure;
    /// it never creates an additional Attempt budget.
    pub const ActiveCredit = struct {
        host: *Host,
        index: usize,
        active: bool = true,

        pub fn release(self: *ActiveCredit) void {
            if (!self.active) return;
            const was_occupied = self.host.credits[self.index].swap(false, .acq_rel);
            std.debug.assert(was_occupied);
            const previous = self.host.occupied_credits.fetchSub(1, .acq_rel);
            std.debug.assert(previous > 0);
            self.active = false;
        }
    };

    pub fn init(allocator: std.mem.Allocator, active_capacity: usize) !Host {
        if (active_capacity == 0) return error.InvalidActiveCapacity;
        var slots = try core_image.RuntimeSlotPool.init(allocator, active_capacity);
        errdefer slots.deinit(allocator);
        const credits = try allocator.alloc(CreditCell, active_capacity);
        for (credits) |*credit| credit.* = .init(false);
        return .{ .allocator = allocator, .slots = slots, .credits = credits };
    }

    pub fn deinit(self: *Host) void {
        std.debug.assert(self.occupied_credits.load(.acquire) == 0);
        for (self.credits) |credit| std.debug.assert(!credit.load(.acquire));
        self.allocator.free(self.credits);
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    /// Reserve one of the Host's startup-fixed Active Credits before a
    /// Harness can allocate or claim durable Session ownership.
    pub fn reserveActiveCredit(self: *Host) !ActiveCredit {
        for (self.credits, 0..) |*credit, index| {
            if (credit.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) continue;
            const occupied = self.occupied_credits.fetchAdd(1, .acq_rel) + 1;
            self.raiseCreditHighWater(occupied);
            return .{ .host = self, .index = index };
        }
        return error.ActiveCapacityExhausted;
    }

    pub fn resourceLedger(self: *const Host) HostResourceLedger {
        return .{
            .activation = .{
                .capacity = self.slots.capacity(),
                .slot_bytes = @sizeOf(core_image.ActivationSlot),
                .slot_reservation_bytes = self.slots.residentBytes(),
                .pool_overhead_bytes = self.slots.hostOverheadBytes(),
                .occupied_bytes = self.slots.occupiedBytes(),
                .occupied_high_water_bytes = self.slots.occupiedHighWaterBytes(),
            },
            .active_credits = .{
                .capacity = self.credits.len,
                .occupied = self.occupied_credits.load(.acquire),
                .occupied_high_water = self.credit_high_water.load(.acquire),
                .reservation_bytes = self.credits.len * @sizeOf(CreditCell),
            },
            .semantic_validation = self.semantic_validation.measurements(),
            .patch_workspace = self.patch_workspace.measurements(),
        };
    }

    fn raiseCreditHighWater(self: *Host, occupied: usize) void {
        var high_water = self.credit_high_water.load(.acquire);
        while (occupied > high_water) {
            high_water = self.credit_high_water.cmpxchgWeak(
                high_water,
                occupied,
                .acq_rel,
                .acquire,
            ) orelse return;
        }
    }
};

pub const ActivationResourceLedger = struct {
    capacity: usize,
    slot_bytes: usize,
    slot_reservation_bytes: usize,
    pool_overhead_bytes: usize,
    occupied_bytes: usize,
    occupied_high_water_bytes: usize,
};

pub const ActiveCreditResourceLedger = struct {
    capacity: usize,
    occupied: usize,
    occupied_high_water: usize,
    reservation_bytes: usize,
};

pub const SemanticValidationResourceLedger = struct {
    multiplier: usize,
    response_bytes: usize,
    tool_definition_bytes: usize,
    validation_scratch_bytes: usize,
    workspace_bytes: usize,
    pool_overhead_bytes: usize,
    reservation_bytes: usize,
    occupied_count: usize,
    occupied_bytes: usize,
    occupied_high_water_count: usize,
    occupied_high_water_bytes: usize,
    acquisition_count: u64,
    busy_count: u64,
};

pub const PatchWorkspaceResourceLedger = struct {
    multiplier: usize,
    patch_bytes: usize,
    workspace_bytes: usize,
    pool_overhead_bytes: usize,
    reservation_bytes: usize,
    occupied_count: usize,
    occupied_bytes: usize,
    occupied_high_water_count: usize,
    occupied_high_water_bytes: usize,
    acquisition_count: u64,
    busy_count: u64,
};

pub const HostResourceLedger = struct {
    activation: ActivationResourceLedger,
    active_credits: ActiveCreditResourceLedger,
    semantic_validation: SemanticValidationResourceLedger,
    patch_workspace: PatchWorkspaceResourceLedger,
};

const SemanticValidationWorkspace = struct {
    response: [model_protocol.max_response_size]u8 = undefined,
    tool_definition: model_operation.ToolDefinitionBuffer = .{},
    validation: model_protocol.ValidationScratch = .{},

    fn scrub(self: *SemanticValidationWorkspace) void {
        @memset(std.mem.asBytes(self), 0);
    }
};

const semantic_validation_workspace_size = @sizeOf(SemanticValidationWorkspace);

const SemanticValidationWorkspaceLease = struct {
    workspace: *SemanticValidationWorkspace,
    context: *anyopaque,
    generation: u64,
    release_fn: *const fn (*anyopaque, u64, *SemanticValidationWorkspace) error{StaleSemanticValidationLease}!void,
    borrowed: bool = true,

    fn release(self: *SemanticValidationWorkspaceLease) error{StaleSemanticValidationLease}!void {
        if (!self.borrowed) return;
        try self.release_fn(self.context, self.generation, self.workspace);
        self.borrowed = false;
    }
};

const SemanticValidationWorkspacePool = struct {
    const state_mask: u64 = 0b11;
    const state_free: u64 = 0;
    const state_occupied: u64 = 1;
    const state_releasing: u64 = 2;
    const generation_step: u64 = 4;

    workspace: SemanticValidationWorkspace = .{},
    state: std.atomic.Value(u64) = .init(0),
    acquisition_count: std.atomic.Value(u64) = .init(0),
    busy_count: std.atomic.Value(u64) = .init(0),

    fn borrow(self: *SemanticValidationWorkspacePool) !SemanticValidationWorkspaceLease {
        var state = self.state.load(.acquire);
        while (state & state_mask == state_free and state <= std.math.maxInt(u64) - generation_step) {
            const occupied_state = state + state_occupied;
            if (self.state.cmpxchgWeak(state, occupied_state, .acq_rel, .acquire)) |actual| {
                state = actual;
                continue;
            }
            self.workspace.scrub();
            incrementBoundedAtomic(&self.acquisition_count);
            return .{
                .workspace = &self.workspace,
                .context = self,
                .generation = occupied_state,
                .release_fn = releaseLease,
            };
        }
        incrementBoundedAtomic(&self.busy_count);
        return error.SemanticValidationWorkspaceBusy;
    }

    fn measurements(self: *const SemanticValidationWorkspacePool) SemanticValidationResourceLedger {
        const state = self.state.load(.acquire);
        const occupied_count: usize = @intFromBool(state & state_mask != state_free);
        const acquisition_count = self.acquisition_count.load(.acquire);
        const high_water_count: usize = @intFromBool(acquisition_count != 0);
        return .{
            .multiplier = 1,
            .response_bytes = @sizeOf(@TypeOf(self.workspace.response)),
            .tool_definition_bytes = @sizeOf(@TypeOf(self.workspace.tool_definition)),
            .validation_scratch_bytes = @sizeOf(@TypeOf(self.workspace.validation)),
            .workspace_bytes = @sizeOf(SemanticValidationWorkspace),
            .pool_overhead_bytes = @sizeOf(SemanticValidationWorkspacePool) - @sizeOf(SemanticValidationWorkspace),
            .reservation_bytes = @sizeOf(SemanticValidationWorkspacePool),
            .occupied_count = occupied_count,
            .occupied_bytes = occupied_count * @sizeOf(SemanticValidationWorkspace),
            .occupied_high_water_count = high_water_count,
            .occupied_high_water_bytes = high_water_count * @sizeOf(SemanticValidationWorkspace),
            .acquisition_count = acquisition_count,
            .busy_count = self.busy_count.load(.acquire),
        };
    }

    fn isOccupied(self: *const SemanticValidationWorkspacePool) bool {
        return self.state.load(.acquire) & state_mask != state_free;
    }

    fn releaseLease(
        context: *anyopaque,
        generation: u64,
        workspace: *SemanticValidationWorkspace,
    ) error{StaleSemanticValidationLease}!void {
        const self: *SemanticValidationWorkspacePool = @ptrCast(@alignCast(context));
        if (workspace != &self.workspace or generation & state_mask != state_occupied or
            self.state.cmpxchgStrong(
                generation,
                generation + state_releasing - state_occupied,
                .acq_rel,
                .acquire,
            ) != null)
        {
            return error.StaleSemanticValidationLease;
        }
        workspace.scrub();
        self.state.store(generation + generation_step - state_occupied, .release);
    }
};

/// One decoded admitted patch retained only while preparation or reconciliation
/// needs it. This fixed Host stage does not scale with Active Capacity, and no
/// activation keeps its own full patch across a subprocess wait.
const PatchWorkspace = struct {
    patch: [patch_tool.max_patch_size]u8 = undefined,

    fn scrub(self: *PatchWorkspace) void {
        @memset(&self.patch, 0);
    }
};

const PatchWorkspaceLease = struct {
    workspace: *PatchWorkspace,
    owner: *PatchWorkspacePool,
    generation: u64,
    borrowed: bool = true,

    fn release(self: *PatchWorkspaceLease) !void {
        if (!self.borrowed) return;
        try self.owner.releaseLease(self.generation, self.workspace);
        self.borrowed = false;
    }
};

const PatchWorkspacePool = struct {
    const state_mask: u64 = 0b11;
    const state_free: u64 = 0;
    const state_occupied: u64 = 1;
    const state_releasing: u64 = 2;
    const generation_step: u64 = 4;

    workspace: PatchWorkspace = .{},
    state: std.atomic.Value(u64) = .init(0),
    acquisition_count: std.atomic.Value(u64) = .init(0),
    busy_count: std.atomic.Value(u64) = .init(0),

    fn borrow(self: *PatchWorkspacePool) !PatchWorkspaceLease {
        var state = self.state.load(.acquire);
        while (state & state_mask == state_free and state <= std.math.maxInt(u64) - generation_step) {
            const occupied_state = state + state_occupied;
            if (self.state.cmpxchgWeak(state, occupied_state, .acq_rel, .acquire)) |actual| {
                state = actual;
                continue;
            }
            self.workspace.scrub();
            incrementBoundedAtomic(&self.acquisition_count);
            return .{
                .workspace = &self.workspace,
                .owner = self,
                .generation = occupied_state,
            };
        }
        incrementBoundedAtomic(&self.busy_count);
        return error.PatchWorkspaceBusy;
    }

    fn measurements(self: *const PatchWorkspacePool) PatchWorkspaceResourceLedger {
        const state = self.state.load(.acquire);
        const occupied_count: usize = @intFromBool(state & state_mask != state_free);
        const acquisition_count = self.acquisition_count.load(.acquire);
        const high_water_count: usize = @intFromBool(acquisition_count != 0);
        return .{
            .multiplier = 1,
            .patch_bytes = @sizeOf(@TypeOf(self.workspace.patch)),
            .workspace_bytes = @sizeOf(PatchWorkspace),
            .pool_overhead_bytes = @sizeOf(PatchWorkspacePool) - @sizeOf(PatchWorkspace),
            .reservation_bytes = @sizeOf(PatchWorkspacePool),
            .occupied_count = occupied_count,
            .occupied_bytes = occupied_count * @sizeOf(PatchWorkspace),
            .occupied_high_water_count = high_water_count,
            .occupied_high_water_bytes = high_water_count * @sizeOf(PatchWorkspace),
            .acquisition_count = acquisition_count,
            .busy_count = self.busy_count.load(.acquire),
        };
    }

    fn isOccupied(self: *const PatchWorkspacePool) bool {
        return self.state.load(.acquire) & state_mask != state_free;
    }

    fn releaseLease(
        self: *PatchWorkspacePool,
        generation: u64,
        workspace: *PatchWorkspace,
    ) error{StalePatchWorkspaceLease}!void {
        if (workspace != &self.workspace or generation & state_mask != state_occupied or
            self.state.cmpxchgStrong(
                generation,
                generation + state_releasing - state_occupied,
                .acq_rel,
                .acquire,
            ) != null)
        {
            return error.StalePatchWorkspaceLease;
        }
        workspace.scrub();
        self.state.store(generation + generation_step - state_occupied, .release);
    }
};

fn incrementBoundedAtomic(value: *std.atomic.Value(u64)) void {
    var current = value.load(.acquire);
    while (current != std.math.maxInt(u64)) {
        current = value.cmpxchgWeak(current, current + 1, .acq_rel, .acquire) orelse return;
    }
}

comptime {
    std.debug.assert(semantic_validation_workspace_size >=
        model_protocol.max_response_size + @sizeOf(model_protocol.ValidationScratch));
}

pub const PermissionMode = enum {
    ask,
    bypass,
};

pub const RuntimeConfig = struct {
    workspace_path: []const u8,
    fault: ?FaultHook = null,
    permission_mode: PermissionMode = .ask,
    bash_cancelled: ?*const std.atomic.Value(bool) = null,
    approval_required_hook: ?ApprovalRequiredHook = null,
    completion_hook: ?CompletionHook = null,
};

pub const ApprovalRequiredKind = enum { bash, apply_patch };

pub const ApprovalRequired = struct {
    kind: ApprovalRequiredKind,
    operation_id: u64,
    operation_generation: u32,
    descriptor_digest: binding.Descriptor,
    descriptor_ref: u64,
};

pub const ApprovalRequiredHook = struct {
    context: *anyopaque,
    required: *const fn (*anyopaque, ApprovalRequired) anyerror!void,
};

pub const CompletionHook = struct {
    context: *anyopaque,
    offered: *const fn (*anyopaque, completion_inbox.Envelope) anyerror!void,
};

pub const Control = enum { cancel, shutdown };

pub fn commitControl(session: *session_store.Session, control: Control) !void {
    _ = try session.commitControl(if (control == .cancel) .cancel else .shutdown);
}

pub fn restoredControl(session: *session_store.Session) !?Control {
    const state = try session.semanticView();
    const control = state.control orelse return null;
    return switch (control) {
        .cancellation => .cancel,
        .shutdown => .shutdown,
        else => error.InvalidControlFact,
    };
}

pub fn recoverSemanticWindow(
    host: *Host,
    session: *session_store.Session,
    frame_budget: u8,
) !session_store.RecoveryProgress {
    _ = host;
    return session.recoverSemanticWindow(frame_budget);
}

pub const FaultBoundary = enum {
    after_semantic_workspace_borrow,
    after_model_dispatch,
    after_completion_inbox,
    after_completion_persist,
    after_final_content,
    after_assistant_entry,
    after_bash_authorization,
    after_bash_execution,
    after_patch_authorization,
    after_patch_attempt,
    after_patch_mutation,
};

pub const FaultHook = struct {
    context: *anyopaque,
    reached: *const fn (*anyopaque, FaultBoundary) anyerror!void,
};

const OperationIds = struct {
    operation_id: u64,
    attempt_id: u64,
    request_ref: u64,
    response_ref: u32,
    final_ref: u64,
};

const ModelDispatch = struct {
    request_ref: u64,
    request_digest: binding.ModelDescriptor,
    response_ref: u64,
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
};

const ModelCompletion = struct {
    agent_id: u64,
    operation_id: u64,
    ownership_epoch: u64,
    result: u64,
    result_digest: binding.Result,
    attempt_id: u64,
    agent_generation: u32,
    operation_generation: u32,
    request_ref: u64,
    request_digest: binding.ModelDescriptor,
};

const ExecutableTool = enum { bash, apply_patch };

const AdmittedPatch = struct {
    patch_ref: u64,
};

fn admittedExecutableTool(
    session: *session_store.Session,
) !?ExecutableTool {
    const view = try session.semanticView();
    const model = view.model;
    if (model.operation_id > std.math.maxInt(u32)) return error.InvalidModelOperationIdentity;
    const action = (try session.currentAction()) orelse return null;
    const descriptor = action.operation;
    const source = descriptor.source_operation orelse return null;
    if (source.operation_id != model.operation_id or source.generation != model.generation) return null;
    return switch (descriptor.descriptor_digest) {
        .bash => .bash,
        .apply_patch => .apply_patch,
        .model => error.InvalidActionDescriptor,
    };
}

fn executableToolFromKey(key: []const u8) !ExecutableTool {
    if (std.mem.eql(u8, key, model_contract.bash_key)) return .bash;
    if (std.mem.eql(u8, key, model_contract.apply_patch_key)) return .apply_patch;
    return error.UnboundToolKey;
}

fn finalReference(response_ref: u64) u64 {
    return (@as(u64, 1) << 63) | response_ref;
}

fn agentContext(session: *const session_store.Session) session_transition.AgentContext {
    return .{
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .ownership_epoch = session.ownership_epoch,
    };
}

fn operationContext(
    session: *const session_store.Session,
    operation_id: u64,
    generation: u32,
) session_transition.OperationContext {
    return .{ .agent = agentContext(session), .operation_id = operation_id, .generation = generation };
}

fn operationHistory(
    session: *session_store.Session,
    operation_id: u64,
    generation: u32,
    expected_kind: binding.DescriptorKind,
) !session_store.OperationView {
    const view = try session.semanticView();
    const operation = view.operation(operationContext(session, operation_id, generation)) orelse
        return error.MissingOperationHistory;
    if (operation.kind() != expected_kind) return error.InvalidOperationHistory;
    return operation;
}

fn consequentialActionForModel(
    session: *session_store.Session,
    model_operation_id: u64,
    expected_kind: binding.DescriptorKind,
) !session_store.ActionView {
    return session.actionForModel(model_operation_id, expected_kind);
}

const ModelSlot = struct {
    session: *session_store.Session,
    scratch: *SemanticValidationWorkspace,
    workspace_path: []const u8,

    const Tool = union(enum) {
        none,
        generic,
        bash: struct {
            descriptor_ref: u64,
            call: session_store.BashCallMaterial,
        },
        apply_patch: AdmittedPatch,
    };

    const Admission = struct {
        response: model_protocol.Admission,
        tool: Tool = .none,
    };

    const DefinitionSelection = struct {
        session: *session_store.Session,
        request_ref: u64,
        buffer: *model_operation.ToolDefinitionBuffer,

        fn resolve(context: *anyopaque, key: []const u8) anyerror!?model_contract.ToolDefinition {
            const self: *DefinitionSelection = @ptrCast(@alignCast(context));
            return model_operation.readToolDefinition(
                self.session,
                self.request_ref,
                key,
                self.buffer,
            );
        }
    };

    fn admit(context: *anyopaque, completion: ModelCompletion) anyerror!Admission {
        const self: *ModelSlot = @ptrCast(@alignCast(context));
        try model_operation.verifyRequestDigest(
            self.session,
            completion.request_ref,
            completion.request_digest,
        );
        var response = try self.session.viewContent(completion.result);
        if (response.length() > model_protocol.max_response_size) return error.ResponseTooLarge;
        const length: usize = @intCast(response.length());
        const bytes = try readModelResponse(&response, self.scratch.response[0..length]);
        var selection: DefinitionSelection = .{
            .session = self.session,
            .request_ref = completion.request_ref,
            .buffer = &self.scratch.tool_definition,
        };
        var captured = model_protocol.admitCaptured(
            &self.scratch.validation,
            bytes,
            completion.result_digest,
            .{ .context = &selection, .resolve_fn = DefinitionSelection.resolve },
        ) catch |err| switch (err) {
            error.InvalidModelResponseEvidence => return error.CompletionResultDigestMismatch,
            else => return err,
        };
        var parsed = captured.admission.parsed_value;
        var tool: Tool = .none;
        if (parsed.disposition == .tool_call) {
            const admitted = captured.tool_arguments orelse
                return error.MissingAdmittedToolArguments;
            const key = bytes[parsed.tool_key_offset..][0..parsed.tool_key_length];
            const executable = admitExecutableArguments(key, admitted.parsed) catch |err| switch (err) {
                error.InvalidAdmittedBashArguments,
                error.InvalidAdmittedPatchArguments,
                => blk: {
                    try captured.rejectToolCall();
                    parsed = captured.admission.parsed_value;
                    break :blk null;
                },
            };
            if (parsed.disposition == .tool_call) {
                const call_ref = toolCallReference(completion);
                try storeToolCall(self.session, call_ref, key, admitted.json);
                tool = try self.admitTool(completion, executable);
            }
        }
        return .{ .response = captured.admission, .tool = tool };
    }

    fn admitTool(
        self: *ModelSlot,
        completion: ModelCompletion,
        executable: ?ExecutableArguments,
    ) !Tool {
        const arguments = executable orelse return .generic;
        return switch (arguments) {
            .bash => |bash| blk: {
                const descriptor_ref = (@as(u64, 1) << 62) | @as(u32, @truncate(completion.result));
                const descriptor: bash_tool.Descriptor = .{
                    .workspace_path = self.workspace_path,
                    .working_directory = self.workspace_path,
                    .call = .{ .command = bash.command, .timeout_ms = bash.timeout_ms },
                };
                var descriptor_buffer: [bash_tool.max_descriptor_size]u8 = undefined;
                const descriptor_bytes = try bash_tool.encodeDescriptor(&descriptor_buffer, descriptor);
                try self.session.storeContent(descriptor_ref, descriptor_bytes);
                break :blk .{ .bash = .{
                    .descriptor_ref = descriptor_ref,
                    .call = try session_store.BashCallMaterial.init(descriptor.call),
                } };
            },
            .apply_patch => |patch| blk: {
                const patch_ref = (@as(u64, 1) << 60) | @as(u32, @truncate(completion.result));
                try self.session.storeContent(patch_ref, patch);
                break :blk .{ .apply_patch = .{
                    .patch_ref = patch_ref,
                } };
            },
        };
    }
};

const PreparedTool = struct {
    call_ref: u64,
    action: ?session_store.ActionMaterial = null,
};

fn prepareToolAdmission(
    host: *Host,
    session: *session_store.Session,
    workspace_path: []const u8,
    completion: ModelCompletion,
    tool: ModelSlot.Tool,
) !PreparedTool {
    var prepared: PreparedTool = .{ .call_ref = toolCallReference(completion) };
    switch (tool) {
        .none => return error.MissingAdmittedTool,
        .generic => {},
        .bash => |bash| {
            prepared.action = .{ .bash = .{
                .descriptor_ref = bash.descriptor_ref,
                .call = bash.call,
            } };
        },
        .apply_patch => |patch| {
            var workspace = try host.patch_workspace.borrow();
            defer workspace.release() catch unreachable;
            const patch_bytes = try readAdmittedPatch(session, patch, &workspace.workspace.patch);
            std.debug.assert(!host.semantic_validation.isOccupied());
            const intent_ref = (@as(u64, 1) << 58) | @as(u32, @truncate(completion.result));
            const intent = try patch_tool.prepare(session.io, workspace_path, patch_bytes, .{
                .patch_ref = patch.patch_ref,
            });
            try storePatchIntent(session, intent_ref, intent);
            prepared.action = .{ .apply_patch = .{
                .intent_reference = intent_ref,
                .patch_reference = patch.patch_ref,
            } };
        },
    }
    return prepared;
}

fn toolCallReference(completion: ModelCompletion) u64 {
    return (@as(u64, 1) << 59) | @as(u32, @truncate(completion.result));
}

fn readAdmittedPatch(
    session: *session_store.Session,
    admitted: AdmittedPatch,
    out: *[patch_tool.max_patch_size]u8,
) ![]const u8 {
    var reader = try session.viewContent(admitted.patch_ref);
    if (reader.length() == 0 or reader.length() > out.len) {
        return error.InvalidAdmittedPatchContent;
    }
    const length: usize = @intCast(reader.length());
    var offset: usize = 0;
    while (offset < length) {
        const bytes = try reader.readWindow(offset, out[offset..length]);
        if (bytes.len == 0 or bytes.len > length - offset) return error.TruncatedAdmittedPatchContent;
        if (bytes.ptr != out[offset..].ptr) @memcpy(out[offset..][0..bytes.len], bytes);
        offset += bytes.len;
    }
    return out[0..length];
}

const AdmittedBashArguments = struct {
    command: []const u8,
    timeout_ms: u32,
};

const ExecutableArguments = union(ExecutableTool) {
    bash: AdmittedBashArguments,
    apply_patch: []const u8,
};

fn admitExecutableArguments(
    key: []const u8,
    value: std.json.Value,
) !?ExecutableArguments {
    const executable = executableToolFromKey(key) catch return null;
    return switch (executable) {
        .bash => .{ .bash = try admittedBashArguments(value) },
        .apply_patch => .{ .apply_patch = try admittedPatchArguments(value) },
    };
}

fn admittedBashArguments(value: std.json.Value) !AdmittedBashArguments {
    const object = switch (value) {
        .object => |item| item,
        else => return error.InvalidAdmittedBashArguments,
    };
    const command = switch (object.get("command") orelse return error.InvalidAdmittedBashArguments) {
        .string => |item| item,
        else => return error.InvalidAdmittedBashArguments,
    };
    const timeout = switch (object.get("timeout_ms") orelse return error.InvalidAdmittedBashArguments) {
        .integer => |item| std.math.cast(u32, item) orelse return error.InvalidAdmittedBashArguments,
        .float => |item| if (std.math.isFinite(item) and item >= 0 and
            item <= std.math.maxInt(u32) and @trunc(item) == item)
            @as(u32, @intFromFloat(item))
        else
            return error.InvalidAdmittedBashArguments,
        else => return error.InvalidAdmittedBashArguments,
    };
    model_contract.validateBashCommand(command) catch return error.InvalidAdmittedBashArguments;
    if (timeout < 100 or timeout > 120_000) return error.InvalidAdmittedBashArguments;
    return .{ .command = command, .timeout_ms = timeout };
}

fn admittedPatchArguments(value: std.json.Value) ![]const u8 {
    const object = switch (value) {
        .object => |item| item,
        else => return error.InvalidAdmittedPatchArguments,
    };
    const patch = switch (object.get("patch") orelse return error.InvalidAdmittedPatchArguments) {
        .string => |item| item,
        else => return error.InvalidAdmittedPatchArguments,
    };
    model_contract.validatePatchInput(patch) catch return error.InvalidAdmittedPatchArguments;
    return patch;
}

pub fn advanceCreated(
    host: *Host,
    session: *session_store.Session,
    config: RuntimeConfig,
    provider: ?model_operation.Provider,
) !u64 {
    const io = session.io;
    const token = session.ownerToken();
    var lease = try host.slots.borrow();
    defer lease.release() catch unreachable;
    _ = try session.startTask(lease.slot);
    try lease.release();
    _ = try performModelTurn(
        host,
        io,
        session,
        token,
        provider,
        1,
        config.completion_hook,
        config.fault,
    );
    return error.CompletionExpected;
}

fn performModelTurn(
    host: *Host,
    io: std.Io,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    provider: ?model_operation.Provider,
    model_sequence: u32,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !OperationIds {
    const next_provider = provider orelse return error.SessionOperationPending;
    const ids = try allocateOperationIds(io, session);
    var preview_lease = try host.slots.borrow();
    defer preview_lease.release() catch unreachable;
    const context = try session.previewModelContext(
        preview_lease.slot,
        ids.operation_id,
        model_sequence,
    );
    try preview_lease.release();
    const request_digest = try model_operation.buildRequest(
        session,
        ids.request_ref,
        context.first_entry,
        context.entry_count,
    );
    try model_operation.verifyRequestDigest(session, ids.request_ref, request_digest);
    var admission_lease = try host.slots.borrow();
    defer admission_lease.release() catch unreachable;
    const operation = try session.admitModelAttempt(admission_lease.slot, .{
        .operation_id = ids.operation_id,
        .sequence = model_sequence,
        .attempt_id = ids.attempt_id,
        .request_ref = ids.request_ref,
        .request_digest = request_digest,
    });
    try admission_lease.release();
    try dispatchModelAttempt(session, token, next_provider, .{
        .request_ref = ids.request_ref,
        .request_digest = request_digest,
        .response_ref = ids.response_ref,
        .operation_id = ids.operation_id,
        .operation_generation = operation.generation,
        .attempt_id = ids.attempt_id,
    }, completion_hook, fault);
    return error.CompletionExpected;
}

fn retryModelAttempt(
    host: *Host,
    io: std.Io,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    provider: ?model_operation.Provider,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !void {
    var view_lease = try host.slots.borrow();
    defer view_lease.release() catch unreachable;
    const continuation = try session.continuationView(view_lease.slot);
    try view_lease.release();
    const operation = continuation.operation;
    const history = try operationHistory(session, operation.id, operation.generation, .model);
    const descriptor = history.descriptor orelse return error.MissingModelDescriptor;
    if (history.attempt_count == session_transition.max_operation_attempts) {
        const attempt = history.attempts[history.attempt_count - 1].?;
        const result_ref = try model_operation.publishFailureResult(
            session,
            attempt.attempt_id,
        );
        const evidence = completion_inbox.bind(.{
            .kind = .model,
            .session_id = session.session_id,
            .ownership_epoch = attempt.operation.agent.ownership_epoch,
            .agent_id = session.agent_id,
            .agent_generation = agent_generation,
            .operation_id = operation.id,
            .operation_generation = operation.generation,
            .attempt_id = attempt.attempt_id,
            .result_ref = result_ref,
            .result_digest = try contentDigest(session, result_ref),
        });
        try session.publishCompletionEvidence(evidence);
        if (completion_hook) |hook| try hook.offered(hook.context, evidence);
        return error.CompletionOffered;
    }
    const next_provider = provider orelse return error.SessionOperationPending;
    const request_digest = switch (descriptor.descriptor_digest) {
        .model => |digest| digest,
        else => return error.InvalidModelDescriptor,
    };
    try model_operation.verifyRequestDigest(session, descriptor.descriptor_ref, request_digest);
    var attempt_id: u64 = 0;
    var response_ref: u32 = 0;
    for (0..8) |_| {
        io.random(std.mem.asBytes(&attempt_id));
        io.random(std.mem.asBytes(&response_ref));
        if (attempt_id != 0 and response_ref != 0 and !history.containsAttempt(attempt_id)) {
            break;
        }
    }
    if (attempt_id == 0 or response_ref == 0) return error.OperationIdentityAllocationExhausted;
    _ = try session.admitModelRetry(.{
        .operation_id = operation.id,
        .sequence = operation.sequence,
        .attempt_id = attempt_id,
        .request_ref = descriptor.descriptor_ref,
        .request_digest = request_digest,
        .possible_duplicate_attempts = history.attempt_count,
    });
    return dispatchModelAttempt(session, token, next_provider, .{
        .request_ref = descriptor.descriptor_ref,
        .request_digest = request_digest,
        .response_ref = response_ref,
        .operation_id = operation.id,
        .operation_generation = operation.generation,
        .attempt_id = attempt_id,
    }, completion_hook, fault);
}

fn dispatchModelAttempt(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    provider: model_operation.Provider,
    dispatch: ModelDispatch,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !void {
    try model_operation.verifyRequestDigest(session, dispatch.request_ref, dispatch.request_digest);
    var provider_io = try model_operation.ProviderIo.open(
        session,
        dispatch.request_ref,
        dispatch.response_ref,
    );
    defer provider_io.close();
    const outcome = try provider.dispatch(
        provider.context,
        try provider_io.request(),
        provider_io.candidateCapability(),
    );
    try provider_io.settle(outcome);
    try reach(fault, .after_model_dispatch);
    const evidence = completion_inbox.bind(.{
        .kind = .model,
        .session_id = session.session_id,
        .ownership_epoch = token.epoch,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = dispatch.operation_id,
        .operation_generation = dispatch.operation_generation,
        .attempt_id = dispatch.attempt_id,
        .result_ref = dispatch.response_ref,
        .result_digest = try contentDigest(session, dispatch.response_ref),
    });
    try session.publishCompletionEvidence(evidence);
    try reach(fault, .after_completion_inbox);
    if (completion_hook) |hook| try hook.offered(hook.context, evidence);
    return error.CompletionOffered;
}

fn executeBashCall(
    io: std.Io,
    allocator: std.mem.Allocator,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    ids: OperationIds,
    workspace_path: []const u8,
    permission_mode: PermissionMode,
    cancellation: ?*const std.atomic.Value(bool),
    approval_required_hook: ?ApprovalRequiredHook,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !void {
    const tool = try admittedExecutableTool(session) orelse
        return error.UnsupportedTool;
    if (tool != .bash) {
        return error.UnsupportedTool;
    }
    const action = try consequentialActionForModel(session, ids.operation_id, .bash);
    const identity = action.identity();
    if (permission_mode == .ask) switch (action.disposition) {
        .proposed, .approval_required => {
            const request = try session.requireApproval(
                identity.operation_id,
                identity.operation_generation,
            );
            if (approval_required_hook) |hook| try hook.required(hook.context, .{
                .kind = .bash,
                .operation_id = request.operation_id,
                .operation_generation = request.operation_generation,
                .descriptor_digest = request.descriptor_digest,
                .descriptor_ref = request.descriptor_ref,
            });
            return error.PermissionInputRequired;
        },
        .authorized => {},
        else => return error.InvalidBashAuthorization,
    } else switch (action.disposition) {
        .proposed => _ = try session.authorizeBypass(identity),
        .authorized => {},
        else => return error.InvalidBashAuthorization,
    }
    const admitted = action.operation;
    const descriptor_ref = admitted.descriptor_ref;
    var descriptor_buffer: [bash_tool.max_descriptor_size]u8 = undefined;
    const descriptor_bytes = try readBoundedContent(session, descriptor_ref, &descriptor_buffer);
    const admitted_descriptor = try bash_tool.decodeDescriptor(descriptor_bytes);
    const digest = switch (admitted.descriptor_digest) {
        .bash => |value| value,
        else => return error.InvalidBashDescriptor,
    };
    if (!binding.eql(binding.BashDescriptor, bash_tool.descriptorDigest(descriptor_bytes), digest) or
        !std.mem.eql(u8, admitted_descriptor.workspace_path, workspace_path))
    {
        return error.InvalidBashDescriptor;
    }
    const result_ref = (@as(u64, 1) << 61) | ids.response_ref;
    try reach(fault, .after_bash_authorization);

    const grant = try session.beginAuthorizedAction(identity);
    var execution = try bash_tool.executeDescriptor(
        allocator,
        io,
        admitted_descriptor,
        .{ .cancelled = cancellation },
    );
    try reach(fault, .after_bash_execution);
    defer execution.deinit();
    try storeBashResult(session, result_ref, execution);
    const result_digest = try contentDigest(session, result_ref);
    const evidence = completion_inbox.bind(.{
        .kind = .bash,
        .session_id = session.session_id,
        .ownership_epoch = token.epoch,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = grant.operation.operation_id,
        .operation_generation = grant.operation.generation,
        .attempt_id = grant.attempt_id,
        .result_ref = result_ref,
        .result_digest = result_digest,
    });
    try session.publishCompletionEvidence(evidence);
    if (completion_hook) |hook| try hook.offered(hook.context, evidence);
    return error.CompletionOffered;
}

fn requestPatchPermission(
    session: *session_store.Session,
    ids: OperationIds,
    permission_mode: PermissionMode,
    approval_required_hook: ?ApprovalRequiredHook,
    fault: ?FaultHook,
) !void {
    const action = try consequentialActionForModel(session, ids.operation_id, .apply_patch);
    const identity = action.identity();
    if (permission_mode == .ask) switch (action.disposition) {
        .proposed, .approval_required => {
            const request = try session.requireApproval(
                identity.operation_id,
                identity.operation_generation,
            );
            if (approval_required_hook) |hook| try hook.required(hook.context, .{
                .kind = .apply_patch,
                .operation_id = request.operation_id,
                .operation_generation = request.operation_generation,
                .descriptor_digest = request.descriptor_digest,
                .descriptor_ref = request.descriptor_ref,
            });
            return error.PermissionInputRequired;
        },
        .authorized => {},
        else => return error.InvalidPatchAuthorization,
    } else switch (action.disposition) {
        .proposed => _ = try session.authorizeBypass(identity),
        .authorized => {},
        else => return error.InvalidPatchAuthorization,
    }
    try reach(fault, .after_patch_authorization);
}

fn storePatchIntent(
    session: *session_store.Session,
    intent_ref: u64,
    intent: patch_tool.Intent,
) !void {
    var bytes: [patch_tool.max_intent_size]u8 = undefined;
    try session.storeContent(intent_ref, try patch_tool.encodeIntent(&bytes, intent));
}

fn storeBashResult(
    session: *session_store.Session,
    result_ref: u64,
    execution: bash_tool.Execution,
) !void {
    var header: [bash_tool.result_header_size]u8 = undefined;
    const header_bytes = try bash_tool.encodeResultHeader(&header, execution);
    var writer = try session.beginContent(result_ref);
    errdefer writer.abort();
    try writer.append(header_bytes);
    try writer.append(execution.stdout);
    try writer.append(execution.stderr);
    try writer.finish();
}

pub fn advanceRestored(
    host: *Host,
    allocator: std.mem.Allocator,
    session: *session_store.Session,
    config: RuntimeConfig,
    provider: ?model_operation.Provider,
) !u64 {
    const io = session.io;
    const token = session.ownerToken();
    switch (try reconcileRestored(host, session, config)) {
        .finished => |final_ref| return final_ref,
        .settled_needs_model => return error.SessionNeedsModel,
        .settled_needs_tool => return error.ToolCallDeferred,
        .retry_model => {
            try retryModelAttempt(
                host,
                io,
                session,
                token,
                provider,
                config.completion_hook,
                config.fault,
            );
            return error.CompletionExpected;
        },
        .dispatch_tool => {
            const observation = (try continuationView(host, session)).operation;
            const ids: OperationIds = .{
                .operation_id = @intCast(observation.id),
                .attempt_id = 0,
                .request_ref = 0,
                .response_ref = @truncate(observation.result_ref),
                .final_ref = finalReference(observation.result_ref),
            };
            const tool = try admittedExecutableTool(session) orelse
                return error.UnboundToolKey;
            switch (tool) {
                .bash => try executeBashCall(
                    io,
                    allocator,
                    session,
                    token,
                    ids,
                    config.workspace_path,
                    config.permission_mode,
                    config.bash_cancelled,
                    config.approval_required_hook,
                    config.completion_hook,
                    config.fault,
                ),
                .apply_patch => {
                    try requestPatchPermission(
                        session,
                        ids,
                        config.permission_mode,
                        config.approval_required_hook,
                        config.fault,
                    );
                    _ = try reconcilePatch(
                        host,
                        session,
                        config.workspace_path,
                        config.completion_hook,
                        config.fault,
                    );
                },
            }
            return error.CompletionExpected;
        },
        .dispatch_model => {
            if (try hasIndeterminateBash(session)) return error.BashPossiblyExecuted;
            _ = try performModelTurn(
                host,
                io,
                session,
                token,
                provider orelse return error.SessionNeedsModel,
                2,
                config.completion_hook,
                null,
            );
            return error.CompletionExpected;
        },
    }
}

const LocalRestored = union(enum) {
    finished: u64,
    settled_needs_model,
    settled_needs_tool,
    retry_model,
    dispatch_model,
    dispatch_tool,
};

/// Reconstructs and admits durable evidence without beginning a subsequent
/// external effect. Completion acceptance always ends at this structural seam.
fn reconcileRestored(
    host: *Host,
    session: *session_store.Session,
    config: RuntimeConfig,
) !LocalRestored {
    var continuation = try continuationView(host, session);
    var outcome = continuation.task.phase;
    var admitted_completion = false;
    if (outcome == .awaiting_model) {
        if (durableCompletion(session, continuation.operation)) |completion| {
            const admission = blk: {
                var scratch = try host.semantic_validation.borrow();
                defer scratch.release() catch unreachable;
                try reach(config.fault, .after_semantic_workspace_borrow);
                var model_slot: ModelSlot = .{
                    .session = session,
                    .scratch = scratch.workspace,
                    .workspace_path = config.workspace_path,
                };
                break :blk try ModelSlot.admit(&model_slot, completion);
            };
            const consequence: session_store.ModelCompletionConsequence = switch (admission.response.parsed_value.disposition) {
                .final_answer => blk: {
                    const final_ref = finalReference(completion.result);
                    var buffer: [model_protocol.max_assistant_text_size]u8 = undefined;
                    var response_reader = try session.viewContent(completion.result);
                    const parsed = admission.response.parsed_value;
                    const expected = try response_reader.readWindow(
                        parsed.text_offset,
                        buffer[0..parsed.text_length],
                    );
                    if (expected.len != parsed.text_length or expected.len == 0) {
                        return error.InvalidFinalAnswerRange;
                    }
                    try storeOrExpectContent(session, final_ref, expected);
                    try reach(config.fault, .after_final_content);
                    break :blk .{ .final_answer = .{ .content_ref = final_ref } };
                },
                .tool_call => blk: {
                    const prepared = try prepareToolAdmission(
                        host,
                        session,
                        config.workspace_path,
                        completion,
                        admission.tool,
                    );
                    break :blk .{ .tool_call = .{
                        .content_ref = prepared.call_ref,
                        .action = prepared.action,
                    } };
                },
                else => .terminal,
            };
            var admission_lease = try host.slots.borrow();
            defer admission_lease.release() catch unreachable;
            _ = try session.admitModelCompletion(admission_lease.slot, .{
                .operation_id = completion.operation_id,
                .operation_generation = completion.operation_generation,
                .attempt_id = completion.attempt_id,
                .evidence_epoch = completion.ownership_epoch,
                .response_ref = completion.result,
                .response_digest = completion.result_digest,
                .admission = admission.response,
                .consequence = consequence,
            });
            try admission_lease.release();
            admitted_completion = true;
        } else |err| switch (err) {
            error.SessionOperationPending => return .retry_model,
            else => return err,
        }
        continuation = try continuationView(host, session);
        outcome = continuation.task.phase;
    }
    if (outcome == .awaiting_tool) {
        switch (try reconcileToolCall(
            host,
            session,
            session.workspacePath(),
            config.completion_hook,
            config.fault,
        )) {
            .indeterminate => return error.BashPossiblyExecuted,
            .ready_completion => {
                outcome = .ready;
                admitted_completion = true;
            },
            .ready_local => outcome = .ready,
            .approval_required => return error.PatchApprovalRequired,
            .none => return if (admitted_completion) .settled_needs_tool else .dispatch_tool,
        }
    }
    if (outcome == .failed) {
        const response = continuation.response;
        if (response.disposition == .input_request) return error.InteractionRequestLayerRequired;
        return error.TerminalModelFailure;
    }
    if (outcome == .finished) {
        const entry_id = continuation.task.final_entry_id;
        if (entry_id != session.activeLeafId()) return error.FinalEntryMismatch;
        const entry = try session.readEntry(entry_id);
        if (entry.kind != .assistant_text) return error.InvalidFinalEntry;
        return .{ .finished = entry.content_ref };
    }
    if (outcome != .ready) return error.SessionNotReadyForModel;
    return if (admitted_completion) .settled_needs_model else .dispatch_model;
}

/// Performs only local reconstruction and durable evidence admission. It
/// returns before any causally subsequent Provider or Tool dispatch.
pub fn settleRestored(
    host: *Host,
    session: *session_store.Session,
    config: RuntimeConfig,
) !u64 {
    return localCompletionResult(try reconcileRestored(host, session, config));
}

fn continuationView(
    host: *Host,
    session: *session_store.Session,
) !session_store.ContinuationView {
    var lease = try host.slots.borrow();
    defer lease.release() catch unreachable;
    return session.continuationView(lease.slot);
}

pub fn resolvePermission(
    host: *Host,
    allocator: std.mem.Allocator,
    session: *session_store.Session,
    decision: ApprovalRequired,
    allow: bool,
    provider: ?model_operation.Provider,
    cancellation: ?*const std.atomic.Value(bool),
    completion_hook: ?CompletionHook,
) !u64 {
    const io = session.io;
    const token = session.ownerToken();
    const continuation = try continuationView(host, session);
    if (continuation.task.phase != .awaiting_tool) return error.PermissionNoLongerRequired;
    const tool = try admittedExecutableTool(session) orelse
        return error.PermissionNoLongerRequired;
    const observation = continuation.operation;
    const expected_kind: binding.DescriptorKind = switch (tool) {
        .bash => .bash,
        .apply_patch => .apply_patch,
    };
    const action = try consequentialActionForModel(session, observation.id, expected_kind);
    const resolved = try session.resolveApproval(.{
        .operation_id = decision.operation_id,
        .operation_generation = decision.operation_generation,
        .descriptor_digest = decision.descriptor_digest,
        .descriptor_ref = decision.descriptor_ref,
        .allowed = allow,
    });
    const identity = action.identity();
    const descriptor = resolved.operation;

    switch (tool) {
        .bash => {
            var descriptor_buffer: [bash_tool.max_descriptor_size]u8 = undefined;
            var reader = try session.viewContent(descriptor.descriptor_ref);
            if (reader.length() > descriptor_buffer.len) return error.InvalidBashCallRange;
            const descriptor_length: usize = @intCast(reader.length());
            const descriptor_bytes = try reader.readWindow(0, descriptor_buffer[0..descriptor_length]);
            if (descriptor_bytes.len != descriptor_length) return error.TruncatedBashDescriptor;
            const bash_descriptor = try bash_tool.decodeDescriptor(descriptor_bytes);
            const expected_bash_digest = switch (descriptor.descriptor_digest) {
                .bash => |value| value,
                else => return error.StalePermissionDecision,
            };
            if (!std.mem.eql(u8, bash_descriptor.workspace_path, session.workspacePath()) or
                !binding.eql(
                    binding.BashDescriptor,
                    bash_tool.descriptorDigest(descriptor_bytes),
                    expected_bash_digest,
                ))
            {
                return error.StalePermissionDecision;
            }
            const result_ref = (@as(u64, 1) << 61) | @as(u32, @truncate(observation.result_ref));
            var grant: ?session_store.ExecutionGrant = null;
            var execution: bash_tool.Execution = undefined;
            if (allow) {
                grant = try session.beginAuthorizedAction(identity);
                execution = try bash_tool.executeDescriptor(
                    allocator,
                    io,
                    bash_descriptor,
                    .{ .cancelled = cancellation },
                );
            } else {
                execution = .{
                    .allocator = allocator,
                    .status = .denied,
                    .stdout = try allocator.alloc(u8, 0),
                    .stderr = try allocator.alloc(u8, 0),
                };
            }
            defer execution.deinit();
            try storeBashResult(session, result_ref, execution);
            const result_digest = try contentDigest(session, result_ref);
            if (allow) {
                const admitted = grant.?;
                const evidence = completion_inbox.bind(.{
                    .kind = .bash,
                    .session_id = session.session_id,
                    .ownership_epoch = token.epoch,
                    .agent_id = session.agent_id,
                    .agent_generation = agent_generation,
                    .operation_id = admitted.operation.operation_id,
                    .operation_generation = admitted.operation.generation,
                    .attempt_id = admitted.attempt_id,
                    .result_ref = result_ref,
                    .result_digest = result_digest,
                });
                try session.publishCompletionEvidence(evidence);
                if (completion_hook) |hook| try hook.offered(hook.context, evidence);
                return error.CompletionOffered;
            }
            _ = try session.settleNoEffect(identity, .{
                .result_ref = result_ref,
                .result_digest = result_digest,
            });
            const result = ToolResult{
                .agent_id = session.agent_id,
                .agent_generation = agent_generation,
                .operation_id = identity.operation_id,
                .operation_generation = identity.operation_generation,
                .attempt_id = 0,
                .ownership_epoch = token.epoch,
                .result = result_ref,
            };
            try reconcileBashResult(
                host,
                session,
                result,
            );
        },
        .apply_patch => {},
    }
    const next_provider = provider orelse return error.SessionNeedsModel;
    return advanceRestored(
        host,
        allocator,
        session,
        .{
            .workspace_path = session.workspacePath(),
            .bash_cancelled = cancellation,
            .completion_hook = completion_hook,
        },
        next_provider,
    );
}

pub fn acceptCompletion(
    host: *Host,
    session: *session_store.Session,
    offered: completion_inbox.Envelope,
    config: RuntimeConfig,
) !u64 {
    try session.validateCompletionOffer(offered);
    return settleRestored(host, session, config);
}

fn localCompletionResult(result: LocalRestored) !u64 {
    return switch (result) {
        .finished => |final_ref| final_ref,
        .settled_needs_model => error.SessionNeedsModel,
        .settled_needs_tool => error.ToolCallDeferred,
        .retry_model, .dispatch_model => error.SessionNeedsModel,
        .dispatch_tool => error.ToolCallDeferred,
    };
}

const ToolRecovery = enum {
    none,
    ready_local,
    ready_completion,
    indeterminate,
    approval_required,
};

fn reconcileToolCall(
    host: *Host,
    session: *session_store.Session,
    workspace_path: []const u8,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !ToolRecovery {
    const tool = try admittedExecutableTool(session) orelse
        return error.UnboundToolKey;
    return switch (tool) {
        .bash => reconcileBash(host, session),
        .apply_patch => reconcilePatch(
            host,
            session,
            workspace_path,
            completion_hook,
            fault,
        ),
    };
}

fn reconcileBash(
    host: *Host,
    session: *session_store.Session,
) !ToolRecovery {
    const model_observation = (try continuationView(host, session)).operation;
    if ((try session.currentAction()) == null) return .none;
    const action = try consequentialActionForModel(session, model_observation.id, .bash);
    const identity = action.identity();
    const attempt = switch (action.disposition) {
        .proposed, .authorized => return .none,
        .approval_required => return .approval_required,
        .settled => |result| {
            try reconcileBashResult(host, session, toolResultFromRecord(result));
            if (result.class == .indeterminate) return .indeterminate;
            return switch (result.evidence) {
                .immediate => .ready_local,
                .durable => .ready_completion,
            };
        },
        .denied => {
            const response_ref: u32 = @truncate(model_observation.result_ref);
            const result_ref = (@as(u64, 1) << 61) | response_ref;
            var empty: [0]u8 = .{};
            const execution: bash_tool.Execution = .{
                .allocator = undefined,
                .status = .denied,
                .stdout = &empty,
                .stderr = &empty,
            };
            var encoded: [bash_tool.result_header_size]u8 = undefined;
            _ = try bash_tool.encodeResult(&encoded, execution);
            try storeOrExpectContent(session, result_ref, &encoded);
            const denied_digest = try contentDigest(session, result_ref);
            _ = try session.settleNoEffect(identity, .{
                .result_ref = result_ref,
                .result_digest = denied_digest,
            });
            try reconcileBashResult(
                host,
                session,
                .{
                    .agent_id = session.agent_id,
                    .agent_generation = agent_generation,
                    .operation_id = identity.operation_id,
                    .operation_generation = identity.operation_generation,
                    .attempt_id = 0,
                    .ownership_epoch = session.ownership_epoch,
                    .result = result_ref,
                },
            );
            return .ready_local;
        },
        .attempted => |observed| observed,
    };
    var evidence_agent = attempt.operation.agent;
    var result_ref: u64 = undefined;
    var result_digest: binding.Result = undefined;
    var status: bash_tool.Status = undefined;
    if (try session.pendingCompletionEvidence(attempt.operation, attempt.attempt_id)) |envelope| {
        if (!binding.eql(
            binding.Result,
            try contentDigest(session, envelope.result_ref),
            envelope.result_digest,
        )) {
            return error.CompletionResultDigestMismatch;
        }
        result_ref = envelope.result_ref;
        result_digest = envelope.result_digest;
        evidence_agent.ownership_epoch = envelope.ownership_epoch;
        status = try readBashStatus(session, envelope.result_ref);
    } else {
        const response_ref: u32 = @truncate(model_observation.result_ref);
        result_ref = (@as(u64, 1) << 61) | response_ref;
        var empty: [0]u8 = .{};
        const execution: bash_tool.Execution = .{
            .allocator = undefined,
            .status = .indeterminate,
            .stdout = &empty,
            .stderr = &empty,
        };
        var encoded: [bash_tool.result_header_size]u8 = undefined;
        _ = try bash_tool.encodeResult(&encoded, execution);
        try storeOrExpectContent(session, result_ref, &encoded);
        result_digest = try contentDigest(session, result_ref);
        status = .indeterminate;
        try session.publishCompletionEvidence(completion_inbox.bind(.{
            .kind = .bash,
            .session_id = session.session_id,
            .ownership_epoch = attempt.operation.agent.ownership_epoch,
            .agent_id = session.agent_id,
            .agent_generation = agent_generation,
            .operation_id = identity.operation_id,
            .operation_generation = identity.operation_generation,
            .attempt_id = attempt.attempt_id,
            .result_ref = result_ref,
            .result_digest = result_digest,
        }));
    }
    _ = try session.settleAttempt(attempt, .{
        .result_ref = result_ref,
        .result_digest = result_digest,
        .class = if (status == .indeterminate) .indeterminate else .ordinary,
        .ownership_epoch = evidence_agent.ownership_epoch,
    });
    try reconcileBashResult(
        host,
        session,
        .{
            .agent_id = session.agent_id,
            .agent_generation = agent_generation,
            .operation_id = identity.operation_id,
            .operation_generation = identity.operation_generation,
            .attempt_id = attempt.attempt_id,
            .ownership_epoch = evidence_agent.ownership_epoch,
            .result = result_ref,
        },
    );
    return if (status == .indeterminate) .indeterminate else .ready_completion;
}

fn readBashStatus(
    session: *session_store.Session,
    reference: u64,
) !bash_tool.Status {
    var reader = try session.viewContent(reference);
    if (reader.length() < bash_tool.result_header_size) return error.TruncatedBashResult;
    var header: [bash_tool.result_header_size]u8 = undefined;
    const bytes = try reader.readWindow(0, &header);
    if (bytes.len != header.len) return error.TruncatedBashResult;
    return (try bash_tool.decodeResultHeader(&header, reader.length())).status;
}

fn toolResultFromRecord(result: session_transition.ResultRecord) ToolResult {
    const attempt_id: u64 = switch (result.evidence) {
        .immediate => 0,
        .durable => |evidence| switch (evidence) {
            inline else => |value| value,
        },
    };
    return .{
        .agent_id = result.operation.agent.agent_id,
        .agent_generation = result.operation.agent.agent_generation,
        .operation_id = result.operation.operation_id,
        .operation_generation = result.operation.generation,
        .attempt_id = attempt_id,
        .ownership_epoch = result.operation.agent.ownership_epoch,
        .result = result.result_ref,
    };
}

fn reconcilePatch(
    host: *Host,
    session: *session_store.Session,
    workspace_path: []const u8,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !ToolRecovery {
    const operation_observation = (try continuationView(host, session)).operation;
    const model_operation_id = operation_observation.id;
    const response_ref: u32 = @truncate(operation_observation.result_ref);
    const result_ref = (@as(u64, 1) << 57) | response_ref;
    if ((try session.currentAction()) == null) return .none;
    const action = try consequentialActionForModel(session, model_operation_id, .apply_patch);
    const identity = action.identity();
    const validated = action.operation;
    const patch_descriptor = switch (validated.descriptor_digest) {
        .apply_patch => |value| value,
        else => return error.InvalidPatchHistory,
    };
    var intent_bytes: [patch_tool.max_intent_size]u8 = undefined;
    const intent = try readPatchIntent(session, validated.descriptor_ref, &intent_bytes);
    if (!binding.eql(binding.PatchIntent, intent.intent_digest, patch_descriptor) or
        !std.mem.eql(u8, intent.workspace_path, workspace_path))
    {
        return error.InvalidPatchHistory;
    }
    const patch_ref = intent.patch_ref;
    var attempt: ?session_store.AttemptObservation = null;
    var immediate_status: ?patch_tool.ResultStatus = null;
    switch (action.disposition) {
        .proposed => return .none,
        .approval_required => return .approval_required,
        .settled => |settled| {
            if (settled.result_ref != result_ref) return error.InvalidPatchHistory;
            try reconcileToolResult(
                host,
                session,
                (@as(u64, 1) << 59) | response_ref,
                .apply_patch,
                toolResultFromRecord(settled),
            );
            return switch (settled.evidence) {
                .immediate => .ready_local,
                .durable => .ready_completion,
            };
        },
        .denied => immediate_status = .denied,
        .attempted => |observed| attempt = observed,
        .authorized => {
            const ready = blk: {
                var workspace = try host.patch_workspace.borrow();
                defer workspace.release() catch unreachable;
                const patch = try readBoundedContent(session, patch_ref, &workspace.workspace.patch);
                break :blk try patch_tool.readyForAttempt(session.io, intent, patch);
            };
            if (!ready) {
                immediate_status = .stale;
            } else {
                // The first lease ended before this durable transition. Reconciliation
                // reopens the immutable patch under a new lease only if it needs bytes.
                attempt = (try session.beginAuthorizedAction(identity)).observation();
                try reach(fault, .after_patch_attempt);
            }
        },
    }

    var result_digest: binding.Result = undefined;
    var result_status: patch_tool.ResultStatus = undefined;
    var evidence_agent = if (attempt) |admitted| admitted.operation.agent else agentContext(session);
    if (immediate_status) |status| {
        result_status = status;
        var result_bytes: [patch_tool.result_size]u8 = undefined;
        try patch_tool.encodeResult(&result_bytes, .{
            .status = status,
            .intent_ref = validated.descriptor_ref,
            .intent_digest = patch_descriptor,
        });
        try storeOrExpectContent(session, result_ref, &result_bytes);
        result_digest = try contentDigest(session, result_ref);
    } else {
        const admitted = attempt orelse return error.InvalidPatchHistory;
        if (admitted.binding.descriptor_ref != validated.descriptor_ref or
            !binding.descriptorEql(admitted.binding.descriptor_digest, validated.descriptor_digest))
        {
            return error.InvalidPatchHistory;
        }
        if (try session.pendingCompletionEvidence(admitted.operation, admitted.attempt_id)) |envelope| {
            if (envelope.result_ref != result_ref or !binding.eql(
                binding.Result,
                try contentDigest(session, envelope.result_ref),
                envelope.result_digest,
            )) return error.CompletionResultDigestMismatch;
            result_digest = envelope.result_digest;
            evidence_agent.ownership_epoch = envelope.ownership_epoch;
            result_status = try readPatchResultStatus(
                session,
                envelope.result_ref,
                validated.descriptor_ref,
                patch_descriptor,
            );
        } else {
            const reconciliation = blk: {
                var workspace = try host.patch_workspace.borrow();
                defer workspace.release() catch unreachable;
                const patch = try readBoundedContent(session, patch_ref, &workspace.workspace.patch);
                break :blk try patch_tool.reconcile(session.io, intent, patch);
            };
            result_status = reconciliation.status;
            if (reconciliation.mutated) try reach(fault, .after_patch_mutation);
            var result_bytes: [patch_tool.result_size]u8 = undefined;
            try patch_tool.encodeResult(&result_bytes, .{
                .status = result_status,
                .intent_ref = validated.descriptor_ref,
                .intent_digest = patch_descriptor,
            });
            try storeOrExpectContent(session, result_ref, &result_bytes);
            result_digest = try contentDigest(session, result_ref);
            const envelope = completion_inbox.bind(.{
                .kind = .apply_patch,
                .session_id = session.session_id,
                .ownership_epoch = admitted.operation.agent.ownership_epoch,
                .agent_id = session.agent_id,
                .agent_generation = agent_generation,
                .operation_id = identity.operation_id,
                .operation_generation = identity.operation_generation,
                .attempt_id = admitted.attempt_id,
                .result_ref = result_ref,
                .result_digest = result_digest,
            });
            try session.publishCompletionEvidence(envelope);
            if (completion_hook) |hook| {
                try hook.offered(hook.context, envelope);
                return error.CompletionOffered;
            }
        }
    }
    if (attempt) |admitted| {
        _ = try session.settleAttempt(admitted, .{
            .result_ref = result_ref,
            .result_digest = result_digest,
            .class = if (result_status == .indeterminate) .indeterminate else .ordinary,
            .ownership_epoch = evidence_agent.ownership_epoch,
        });
    } else {
        _ = try session.settleNoEffect(identity, .{
            .result_ref = result_ref,
            .result_digest = result_digest,
        });
    }
    try reconcileToolResult(
        host,
        session,
        (@as(u64, 1) << 59) | response_ref,
        .apply_patch,
        .{
            .agent_id = session.agent_id,
            .agent_generation = agent_generation,
            .operation_id = identity.operation_id,
            .operation_generation = identity.operation_generation,
            .attempt_id = if (attempt) |admitted| admitted.attempt_id else 0,
            .ownership_epoch = evidence_agent.ownership_epoch,
            .result = result_ref,
        },
    );
    return if (attempt == null) .ready_local else .ready_completion;
}

const ToolResult = struct {
    agent_id: u64,
    agent_generation: u32,
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
    ownership_epoch: u64,
    result: u64,
};

fn readPatchIntent(
    session: *session_store.Session,
    intent_ref: u64,
    buffer: *[patch_tool.max_intent_size]u8,
) !patch_tool.Intent {
    return patch_tool.decodeIntent(try readBoundedContent(session, intent_ref, buffer));
}

fn readPatchResultStatus(
    session: *session_store.Session,
    result_ref: u64,
    intent_ref: u64,
    intent_digest: binding.PatchIntent,
) !patch_tool.ResultStatus {
    var bytes: [patch_tool.result_size]u8 = undefined;
    try readExactContent(session, result_ref, &bytes);
    const result = try patch_tool.decodeResult(&bytes);
    if (result.intent_ref != intent_ref or
        !binding.eql(binding.PatchIntent, result.intent_digest, intent_digest))
    {
        return error.InvalidPatchResult;
    }
    return result.status;
}

fn reconcileBashResult(
    host: *Host,
    session: *session_store.Session,
    result: ToolResult,
) !void {
    const response_ref: u32 = @truncate(result.result);
    if (result.result != ((@as(u64, 1) << 61) | response_ref)) return error.InvalidToolResultReference;
    const call_ref = (@as(u64, 1) << 59) | response_ref;
    try reconcileToolResult(host, session, call_ref, .bash, result);
}

fn reconcileToolResult(
    host: *Host,
    session: *session_store.Session,
    call_ref: u64,
    tool: ExecutableTool,
    result: ToolResult,
) !void {
    const visible_ref = (@as(u64, 1) << 55) | @as(u32, @truncate(result.result));
    const active = try session.readEntry(session.activeLeafId());
    var call_entry: session_store.ConversationEntry = undefined;
    var result_entry_id: u64 = undefined;
    if (active.kind == .tool_result and active.content_ref == visible_ref) {
        result_entry_id = active.entry_id;
        call_entry = try session.readEntry(active.parent_id);
    } else if (active.kind == .tool_call and active.content_ref == call_ref) {
        call_entry = active;
        try storeVisibleToolResult(session, tool, result.result, visible_ref, call_entry.entry_id);
        result_entry_id = call_entry.entry_id + 1;
    } else {
        return error.ToolConversationMismatch;
    }
    if (call_entry.kind != .tool_call or call_entry.content_ref != call_ref or
        result_entry_id != call_entry.entry_id + 1)
    {
        return error.ToolConversationMismatch;
    }
    var lease = try host.slots.borrow();
    defer lease.release() catch unreachable;
    try session.admitToolResult(lease.slot, .{
        .operation_id = result.operation_id,
        .operation_generation = result.operation_generation,
        .attempt_id = result.attempt_id,
        .result_ref = result.result,
        .result_digest = try contentDigest(session, result.result),
        .visible_ref = visible_ref,
    });
    try lease.release();
}

fn storeVisibleToolResult(
    session: *session_store.Session,
    tool: ExecutableTool,
    durable_ref: u64,
    visible_ref: u64,
    parent_id: u64,
) !void {
    var existing_length: ?u64 = null;
    var existing_digest: binding.Blob = undefined;
    var blob_writer: ?session_store.ContentWriter = null;
    var existing = session.viewContent(visible_ref) catch |err| switch (err) {
        error.FileNotFound => blk: {
            blob_writer = try session.beginContent(visible_ref);
            break :blk null;
        },
        else => return err,
    };
    if (existing) |*reader| {
        existing_length = reader.length();
        existing_digest = reader.digest();
    }
    defer if (blob_writer) |*writer| writer.abort();

    var target: VisibleResultTarget = .{
        .writer = if (blob_writer) |*writer| writer else null,
    };
    try emitVisibleToolResult(session, tool, durable_ref, parent_id, &target);
    if (blob_writer) |*writer| {
        try writer.finish();
        blob_writer = null;
    } else if (existing_length.? != target.length or
        !binding.eql(binding.Blob, existing_digest, target.hasher.final()))
    {
        return error.ContentMismatch;
    }
}

const VisibleResultTarget = struct {
    writer: ?*session_store.ContentWriter,
    hasher: binding.Hasher(binding.Blob) = .init(),
    length: u64 = 0,

    fn append(self: *VisibleResultTarget, bytes: []const u8) !void {
        if (self.length + bytes.len > conversation.result_header_size +
            conversation.max_result_content_size) return error.ToolResultTooLarge;
        if (self.writer) |writer| try writer.append(bytes);
        self.hasher.update(bytes);
        self.length += bytes.len;
    }
};

fn emitVisibleToolResult(
    session: *session_store.Session,
    tool: ExecutableTool,
    durable_ref: u64,
    parent_id: u64,
    target: *VisibleResultTarget,
) !void {
    switch (tool) {
        .bash => {
            var durable = try session.viewContent(durable_ref);
            var durable_header: [bash_tool.result_header_size]u8 = undefined;
            const header_bytes = try durable.readWindow(0, &durable_header);
            if (header_bytes.len != durable_header.len) return error.TruncatedContent;
            const result = try bash_tool.decodeResultHeader(&durable_header, durable.length());
            var prefix_buffer: [96]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&prefix_buffer, "status={s}\nexit_code={d}\nstdout_base64=", .{
                bashStatusName(result.status),
                result.exit_code,
            });
            const separator = "\nstderr_base64=";
            const content_length = prefix.len +
                std.base64.standard.Encoder.calcSize(result.stdout_length) + separator.len +
                std.base64.standard.Encoder.calcSize(result.stderr_length);
            var visible_header: [conversation.result_header_size]u8 = undefined;
            try target.append(try conversation.encodeToolResultHeader(
                &visible_header,
                parent_id,
                result.status != .success,
                content_length,
            ));
            try target.append(prefix);
            try appendBase64Windowed(
                &durable,
                bash_tool.result_header_size,
                result.stdout_length,
                target,
            );
            try target.append(separator);
            try appendBase64Windowed(
                &durable,
                bash_tool.result_header_size + @as(u64, result.stdout_length),
                result.stderr_length,
                target,
            );
        },
        .apply_patch => {
            var durable: [patch_tool.result_size]u8 = undefined;
            try readExactContent(session, durable_ref, &durable);
            const result = try patch_tool.decodeResult(&durable);
            var content_buffer: [64]u8 = undefined;
            const content = try std.fmt.bufPrint(&content_buffer, "status={s}", .{patchStatusName(result.status)});
            var visible_header: [conversation.result_header_size]u8 = undefined;
            try target.append(try conversation.encodeToolResultHeader(
                &visible_header,
                parent_id,
                result.status != .applied,
                content.len,
            ));
            try target.append(content);
        },
    }
}

fn appendBase64Windowed(
    reader: *session_store.ContentView,
    start: u64,
    length: u32,
    target: *VisibleResultTarget,
) !void {
    const input_window_size = 4095;
    var input: [input_window_size]u8 = undefined;
    var output: [std.base64.standard.Encoder.calcSize(input_window_size)]u8 = undefined;
    var consumed: u64 = 0;
    while (consumed < length) {
        const remaining = @as(u64, length) - consumed;
        const wanted: usize = @intCast(@min(remaining, input.len));
        const bytes = try reader.readWindow(start + consumed, input[0..wanted]);
        if (bytes.len != wanted) return error.TruncatedContent;
        try target.append(std.base64.standard.Encoder.encode(
            output[0..std.base64.standard.Encoder.calcSize(bytes.len)],
            bytes,
        ));
        consumed += bytes.len;
    }
}

fn bashStatusName(status: bash_tool.Status) []const u8 {
    return switch (status) {
        .success => "success",
        .nonzero_exit => "nonzero_exit",
        .timeout => "timeout",
        .cancelled => "cancelled",
        .missing_executable => "missing_executable",
        .truncated => "truncated",
        .denied => "denied",
        .indeterminate => "indeterminate",
        .spawn_error => "spawn_error",
    };
}

fn patchStatusName(status: patch_tool.ResultStatus) []const u8 {
    return switch (status) {
        .denied => "denied",
        .stale => "stale",
        .applied => "applied",
        .indeterminate => "indeterminate",
    };
}

fn durableCompletion(
    session: *session_store.Session,
    operation: session_store.Operation,
) !ModelCompletion {
    const operation_id = operation.id;
    const operation_generation = operation.generation;
    const history = try operationHistory(session, operation_id, operation_generation, .model);
    if (history.attempt_count == 0) return error.MissingAcceptedAttempt;
    if (history.result != null) return error.IncompleteModelAdmissionTransaction;
    var accepted: ?session_transition.AttemptRecord = null;
    var matched_envelope: ?session_store.CompletionEvidence = null;
    for (history.attemptSlice()) |maybe_attempt| {
        const attempt = maybe_attempt.?;
        if (try session.pendingCompletionEvidence(attempt.operation, attempt.attempt_id)) |envelope| {
            accepted = attempt;
            matched_envelope = envelope;
            break;
        }
    }
    const attempt = accepted orelse return error.SessionOperationPending;
    const envelope = matched_envelope.?;
    const descriptor = history.descriptor orelse return error.MissingModelDescriptor;
    const request_digest = switch (descriptor.descriptor_digest) {
        .model => |value| value,
        else => return error.InvalidModelDescriptor,
    };
    if (attempt.descriptor_ref != descriptor.descriptor_ref or
        !binding.descriptorEql(attempt.descriptor_digest, descriptor.descriptor_digest))
    {
        return error.InvalidModelDescriptor;
    }
    if (!binding.eql(
        binding.Result,
        try contentDigest(session, envelope.result_ref),
        envelope.result_digest,
    )) return error.CompletionResultDigestMismatch;
    if (envelope.result_ref == 0) return error.InvalidOperationHistory;
    return .{
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = operation_id,
        .operation_generation = operation_generation,
        .ownership_epoch = attempt.operation.agent.ownership_epoch,
        .attempt_id = attempt.attempt_id,
        .result = envelope.result_ref,
        .result_digest = envelope.result_digest,
        .request_ref = descriptor.descriptor_ref,
        .request_digest = request_digest,
    };
}

pub fn pendingApprovalRequired(session: *session_store.Session) !?ApprovalRequired {
    const action = (try session.currentAction()) orelse return null;
    const pending = switch (action.disposition) {
        .approval_required => |request| request,
        else => return null,
    };
    const kind: ApprovalRequiredKind = switch (std.meta.activeTag(action.operation.descriptor_digest)) {
        .bash => .bash,
        .apply_patch => .apply_patch,
        .model => return error.InvalidActionDescriptor,
    };
    return .{
        .kind = kind,
        .operation_id = pending.operation_id,
        .operation_generation = pending.operation_generation,
        .descriptor_digest = pending.descriptor_digest,
        .descriptor_ref = pending.descriptor_ref,
    };
}

fn resultAttemptId(result: session_transition.ResultRecord) u64 {
    return switch (result.evidence) {
        .immediate => 0,
        .durable => |evidence| switch (evidence) {
            inline else => |attempt_id| attempt_id,
        },
    };
}

fn hasIndeterminateBash(
    session: *session_store.Session,
) !bool {
    const view = try session.semanticView();
    if (view.consequential.kind() != .bash) return false;
    const result = view.consequential.result orelse return false;
    return result.class == .indeterminate;
}

fn reach(fault: ?FaultHook, boundary: FaultBoundary) !void {
    if (fault) |hook| try hook.reached(hook.context, boundary);
}

fn expectContent(reader: *session_store.ContentView, expected: []const u8) !void {
    if (reader.length() != expected.len) return error.FinalAnswerContentMismatch;
    var window: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < expected.len) {
        const actual = try reader.readWindow(offset, &window);
        if (actual.len == 0 or !std.mem.eql(u8, actual, expected[offset..][0..actual.len])) {
            return error.FinalAnswerContentMismatch;
        }
        offset += actual.len;
    }
}

fn readExactContent(
    session: *session_store.Session,
    reference: u64,
    out: []u8,
) !void {
    var reader = try session.viewContent(reference);
    if (reader.length() != out.len) return error.ContentLengthMismatch;
    const bytes = try reader.readWindow(0, out);
    if (bytes.len != out.len) return error.TruncatedContent;
}

fn readBoundedContent(
    session: *session_store.Session,
    reference: u64,
    out: []u8,
) ![]const u8 {
    var reader = try session.viewContent(reference);
    if (reader.length() == 0 or reader.length() > out.len) return error.ContentLengthMismatch;
    const bytes = try reader.readWindow(0, out[0..@intCast(reader.length())]);
    if (bytes.len != reader.length()) return error.TruncatedContent;
    return bytes;
}

fn readModelResponse(
    reader: *session_store.ContentView,
    out: []u8,
) ![]const u8 {
    if (reader.length() != out.len) return error.TruncatedModelResponse;
    var offset: usize = 0;
    while (offset < out.len) {
        const bytes = try reader.readWindow(offset, out[offset..][0..@min(4096, out.len - offset)]);
        if (bytes.len == 0) return error.TruncatedModelResponse;
        offset += bytes.len;
    }
    return out;
}

fn verifyModelResponse(reader: *session_store.ContentView, expected_digest: binding.Result) !void {
    var window: [4096]u8 = undefined;
    var hasher = binding.Hasher(binding.Result).init();
    var offset: u64 = 0;
    while (offset < reader.length()) {
        const wanted: usize = @intCast(@min(reader.length() - offset, window.len));
        const bytes = try reader.readWindow(offset, window[0..wanted]);
        if (bytes.len != wanted) return error.TruncatedModelResponse;
        hasher.update(bytes);
        offset += bytes.len;
    }
    if (!binding.eql(binding.Result, hasher.final(), expected_digest)) {
        return error.CompletionResultDigestMismatch;
    }
}

fn storeToolCall(
    session: *session_store.Session,
    reference: u64,
    key: []const u8,
    admitted_arguments: model_contract.StrictToolJson,
) !void {
    try model_contract.validateToolKey(key);
    const arguments = admitted_arguments.bytes();
    var header: [conversation.call_header_size]u8 = undefined;
    const header_bytes = try conversation.encodeToolCallHeader(
        &header,
        key.len,
        arguments.len,
        admitted_arguments.evidence(),
    );
    var hasher = binding.Hasher(binding.Blob).init();
    hasher.update(header_bytes);
    hasher.update(key);
    hasher.update(arguments);
    const expected_length = header_bytes.len + key.len + arguments.len;
    var existing = session.viewContent(reference) catch |err| switch (err) {
        error.FileNotFound => {
            var writer = try session.beginContent(reference);
            errdefer writer.abort();
            try writer.append(header_bytes);
            try writer.append(key);
            try writer.append(arguments);
            try writer.finish();
            return;
        },
        else => return err,
    };
    if (existing.length() != expected_length or
        !binding.eql(binding.Blob, existing.digest(), hasher.final()))
    {
        return error.ContentMismatch;
    }
}

fn storeOrExpectContent(
    session: *session_store.Session,
    reference: u64,
    bytes: []const u8,
) !void {
    var reader = session.viewContent(reference) catch |err| switch (err) {
        error.FileNotFound => {
            try session.storeContent(reference, bytes);
            return;
        },
        else => return err,
    };
    if (reader.length() != bytes.len) return error.ContentMismatch;
    var window: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const actual = try reader.readWindow(offset, &window);
        if (actual.len == 0 or !std.mem.eql(u8, actual, bytes[offset..][0..actual.len])) {
            return error.ContentMismatch;
        }
        offset += actual.len;
    }
}

fn contentDigest(
    session: *session_store.Session,
    reference: u64,
) !binding.Result {
    var reader = try session.viewContent(reference);
    var hasher = binding.Hasher(binding.Result).init();
    var window: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < reader.length()) {
        const bytes = try reader.readWindow(offset, &window);
        if (bytes.len == 0) return error.TruncatedContent;
        hasher.update(bytes);
        offset += bytes.len;
    }
    return hasher.final();
}

fn allocateOperationIds(io: std.Io, session: *session_store.Session) !OperationIds {
    const operation_id = try session.nextModelOperationId();
    for (0..8) |_| {
        var ids: OperationIds = undefined;
        io.random(std.mem.asBytes(&ids));
        ids.operation_id = operation_id;
        ids.final_ref = finalReference(ids.response_ref);
        if (ids.operation_id == 0 or ids.attempt_id == 0 or ids.request_ref == 0 or
            ids.response_ref == 0)
        {
            continue;
        }
        const values = [_]u64{
            ids.operation_id,
            ids.attempt_id,
            ids.request_ref,
            ids.response_ref,
            ids.final_ref,
            session.task_id,
        };
        var distinct = true;
        for (values, 0..) |value, index| {
            for (values[index + 1 ..]) |other| distinct = distinct and value != other;
        }
        if (distinct) return ids;
    }
    return error.OperationIdentityAllocationExhausted;
}

test "model dispatch releases continuation slot and keeps request content immutable" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "sessions", .default_dir);
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try repo.createDir(io, ".git", .default_dir);
    var git = try repo.openDir(io, ".git", .{});
    defer git.close(io);
    try git.createDir(io, "objects", .default_dir);
    try git.createDir(io, "refs", .default_dir);
    var config = try git.createFile(io, "config", .{});
    defer config.close(io);
    try config.writePositionalAll(io, "[core]\n\trepositoryformatversion = 0\n", 0);
    var head = try git.createFile(io, "HEAD", .{});
    defer head.close(io);
    try head.writePositionalAll(io, "ref: refs/heads/main\n", 0);

    var repo_path_buffer: [160]u8 = undefined;
    const repo_path = try std.fmt.bufPrint(
        &repo_path_buffer,
        ".zig-cache/tmp/{s}/repo",
        .{tmp.sub_path},
    );
    var database_path_buffer: [160]u8 = undefined;
    const database_path = try std.fmt.bufPrint(
        &database_path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var sessions = try tmp.dir.openDir(io, "sessions", .{});
    defer sessions.close(io);
    var storage = try host_store.StorageOwner.open(io, database_path, .{});
    defer storage.close();
    const scratch = try session_store.allocateTransientScratch(std.testing.allocator);
    defer session_store.destroyTransientScratch(std.testing.allocator, io, scratch);
    var session = try session_store.Session.create(sessions, scratch, &storage, io, .{
        .workspace_path = repo_path,
        .model = "fixture:bound",
        .task = "Check the request binding",
    });
    defer session.close();

    var host = try Host.init(std.testing.allocator, 1);
    defer host.deinit();
    const SlotProbeProvider = struct {
        host: *Host,
        observed_released_slot: bool = false,

        fn provider(self: *@This()) model_operation.Provider {
            return .{ .context = self, .dispatch = dispatch };
        }

        fn dispatch(
            context: *anyopaque,
            _: model_operation.RequestCursor,
            response: model_operation.CandidateWriter,
        ) anyerror!model_operation.DispatchOutcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            var lease = try self.host.slots.borrow();
            defer lease.release() catch unreachable;
            self.observed_released_slot = true;
            var bytes: [model_protocol.header_size + "done".len]u8 = undefined;
            try response.append(try model_protocol.encodeText(&bytes, "done"));
            return .candidate;
        }
    };
    var probe: SlotProbeProvider = .{ .host = &host };
    try std.testing.expectError(
        error.CompletionOffered,
        advanceCreated(
            &host,
            &session,
            .{ .workspace_path = repo_path },
            probe.provider(),
        ),
    );
    try std.testing.expect(probe.observed_released_slot);
    try std.testing.expectEqual(@as(usize, 0), host.resourceLedger().activation.occupied_bytes);
    try std.testing.expectError(
        error.IllegalModelTransition,
        performModelTurn(
            &host,
            io,
            &session,
            session.ownerToken(),
            probe.provider(),
            2,
            null,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), host.resourceLedger().activation.occupied_bytes);

    _ = try model_operation.buildRequest(&session, 1001, 1, 1);
    var request_blob = try session.viewContent(1001);
    const request_length: usize = @intCast(request_blob.length());
    var request: [32 * 1024]u8 = undefined;
    const original = try session.readContent(1001, 0, request[0..request_length]);
    request[model_operation.request_header_size] ^= 1;
    try std.testing.expectError(error.ContentAlreadyExists, session.storeContent(1001, original));
}

fn repeatedUtf8(
    allocator: std.mem.Allocator,
    codepoint_count: usize,
    codepoint: []const u8,
) ![]u8 {
    const bytes = try allocator.alloc(u8, codepoint_count * codepoint.len);
    for (0..codepoint_count) |index| {
        @memcpy(bytes[index * codepoint.len ..][0..codepoint.len], codepoint);
    }
    return bytes;
}

fn expectBashArgumentBoundary(
    envelope: []u8,
    command: []const u8,
    accepted: bool,
) !void {
    const encoded = try model_contract.encodeJson(envelope, .{
        .command = command,
        .timeout_ms = bash_tool.max_timeout_ms,
    });
    var scratch: model_contract.StrictToolJsonScratch = .{};
    if (accepted) {
        const admitted = try model_contract.admitToolArguments(
            &scratch,
            model_contract.default_catalog[0],
            encoded,
        );
        try std.testing.expect((try admitExecutableArguments(
            model_contract.bash_key,
            admitted.parsed,
        )) != null);
    } else {
        const admitted = model_contract.admitToolArguments(
            &scratch,
            model_contract.default_catalog[0],
            encoded,
        ) catch |err| switch (err) {
            error.InvalidToolArguments => return,
            else => return err,
        };
        try std.testing.expectError(
            error.InvalidAdmittedBashArguments,
            admitExecutableArguments(model_contract.bash_key, admitted.parsed),
        );
    }
}

fn expectPatchArgumentBoundary(
    envelope: []u8,
    patch: []const u8,
    accepted: bool,
) !void {
    const encoded = try model_contract.encodeJson(envelope, .{ .patch = patch });
    var scratch: model_contract.StrictToolJsonScratch = .{};
    if (accepted) {
        const admitted = try model_contract.admitToolArguments(
            &scratch,
            model_contract.default_catalog[1],
            encoded,
        );
        try std.testing.expect((try admitExecutableArguments(
            model_contract.apply_patch_key,
            admitted.parsed,
        )) != null);
    } else {
        const admitted = model_contract.admitToolArguments(
            &scratch,
            model_contract.default_catalog[1],
            encoded,
        ) catch |err| switch (err) {
            error.InvalidToolArguments => return,
            else => return err,
        };
        try std.testing.expectError(
            error.InvalidAdmittedPatchArguments,
            admitExecutableArguments(model_contract.apply_patch_key, admitted.parsed),
        );
    }
}

test "Host owns one semantic validation workspace independent of Activation Slot capacity" {
    var host = try Host.init(std.testing.allocator, 1);
    defer host.deinit();
    var host_four = try Host.init(std.testing.allocator, 4);
    defer host_four.deinit();
    try std.testing.expectEqual(@as(usize, 256_200), semantic_validation_workspace_size);
    try std.testing.expectEqual(@as(usize, 256_224), @sizeOf(SemanticValidationWorkspacePool));
    try std.testing.expectEqual(@as(usize, 16_384), @sizeOf(PatchWorkspace));
    try std.testing.expectEqual(@as(usize, 16_408), @sizeOf(PatchWorkspacePool));
    try std.testing.expectEqual(core_image.slot_size, @sizeOf(core_image.ActivationSlot));
    try std.testing.expectEqual(
        @sizeOf(SemanticValidationWorkspacePool),
        @sizeOf(@TypeOf(host.semantic_validation)),
    );
    try std.testing.expectEqual(
        @sizeOf(SemanticValidationWorkspacePool),
        @sizeOf(@TypeOf(host_four.semantic_validation)),
    );
    try std.testing.expectEqual(
        @sizeOf(PatchWorkspacePool),
        @sizeOf(@TypeOf(host.patch_workspace)),
    );
    try std.testing.expectEqual(@as(usize, 1), host.slots.capacity());
    try std.testing.expectEqual(@as(usize, 4), host_four.slots.capacity());
    try std.testing.expectEqual(4 * host.slots.residentBytes(), host_four.slots.residentBytes());
    var lease = try host.semantic_validation.borrow();
    @memset(std.mem.asBytes(lease.workspace), 0xa5);
    try std.testing.expectError(error.SemanticValidationWorkspaceBusy, host.semantic_validation.borrow());
    try lease.release();
    var reused = try host.semantic_validation.borrow();
    defer reused.release() catch unreachable;
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(reused.workspace), 0));
}

test "Host resource ledger measures each fixed scratch stage" {
    var host = try Host.init(std.testing.allocator, 1);
    defer host.deinit();
    const initial = host.resourceLedger();
    try std.testing.expectEqual(@as(usize, 1), initial.semantic_validation.multiplier);
    try std.testing.expectEqual(@as(usize, model_protocol.max_response_size), initial.semantic_validation.response_bytes);
    try std.testing.expectEqual(@sizeOf(model_operation.ToolDefinitionBuffer), initial.semantic_validation.tool_definition_bytes);
    try std.testing.expectEqual(@sizeOf(model_protocol.ValidationScratch), initial.semantic_validation.validation_scratch_bytes);
    try std.testing.expectEqual(@as(usize, 256_200), initial.semantic_validation.workspace_bytes);
    try std.testing.expectEqual(@as(usize, 24), initial.semantic_validation.pool_overhead_bytes);
    try std.testing.expectEqual(@as(usize, 256_224), initial.semantic_validation.reservation_bytes);
    try std.testing.expectEqual(@as(usize, 0), initial.semantic_validation.occupied_count);
    try std.testing.expectEqual(@as(usize, 0), initial.semantic_validation.occupied_high_water_count);
    try std.testing.expectEqual(@as(u64, 0), initial.semantic_validation.acquisition_count);
    try std.testing.expectEqual(@as(u64, 0), initial.semantic_validation.busy_count);
    try std.testing.expectEqual(@as(usize, 1), initial.patch_workspace.multiplier);
    try std.testing.expectEqual(@as(usize, patch_tool.max_patch_size), initial.patch_workspace.patch_bytes);
    try std.testing.expectEqual(@as(usize, 16_384), initial.patch_workspace.workspace_bytes);
    try std.testing.expectEqual(@as(usize, 24), initial.patch_workspace.pool_overhead_bytes);
    try std.testing.expectEqual(@as(usize, 16_408), initial.patch_workspace.reservation_bytes);

    var semantic = try host.semantic_validation.borrow();
    try std.testing.expectError(error.SemanticValidationWorkspaceBusy, host.semantic_validation.borrow());
    const semantic_occupied = host.resourceLedger().semantic_validation;
    try std.testing.expectEqual(@as(usize, 1), semantic_occupied.occupied_count);
    try std.testing.expectEqual(semantic_occupied.workspace_bytes, semantic_occupied.occupied_bytes);
    try std.testing.expectEqual(@as(usize, 1), semantic_occupied.occupied_high_water_count);
    try std.testing.expectEqual(semantic_occupied.workspace_bytes, semantic_occupied.occupied_high_water_bytes);
    try std.testing.expectEqual(@as(u64, 1), semantic_occupied.acquisition_count);
    try std.testing.expectEqual(@as(u64, 1), semantic_occupied.busy_count);
    try semantic.release();

    var patch = try host.patch_workspace.borrow();
    try std.testing.expectError(error.PatchWorkspaceBusy, host.patch_workspace.borrow());
    const patch_occupied = host.resourceLedger().patch_workspace;
    try std.testing.expectEqual(@as(usize, 1), patch_occupied.occupied_count);
    try std.testing.expectEqual(patch_occupied.workspace_bytes, patch_occupied.occupied_bytes);
    try std.testing.expectEqual(@as(usize, 1), patch_occupied.occupied_high_water_count);
    try std.testing.expectEqual(patch_occupied.workspace_bytes, patch_occupied.occupied_high_water_bytes);
    try std.testing.expectEqual(@as(u64, 1), patch_occupied.acquisition_count);
    try std.testing.expectEqual(@as(u64, 1), patch_occupied.busy_count);
    try patch.release();

    const released = host.resourceLedger();
    try std.testing.expectEqual(@as(usize, 0), released.semantic_validation.occupied_count);
    try std.testing.expectEqual(@as(usize, 0), released.semantic_validation.occupied_bytes);
    try std.testing.expectEqual(@as(usize, 1), released.semantic_validation.occupied_high_water_count);
    try std.testing.expectEqual(@as(usize, 0), released.patch_workspace.occupied_count);
    try std.testing.expectEqual(@as(usize, 0), released.patch_workspace.occupied_bytes);
    try std.testing.expectEqual(@as(usize, 1), released.patch_workspace.occupied_high_water_count);

    host.semantic_validation.busy_count.store(std.math.maxInt(u64), .release);
    var held = try host.semantic_validation.borrow();
    defer held.release() catch unreachable;
    try std.testing.expectError(error.SemanticValidationWorkspaceBusy, host.semantic_validation.borrow());
    try std.testing.expectEqual(std.math.maxInt(u64), host.resourceLedger().semantic_validation.busy_count);

    host.patch_workspace.state.store(std.math.maxInt(u64) - 3, .release);
    host.patch_workspace.acquisition_count.store(std.math.maxInt(u64), .release);
    try std.testing.expectError(error.PatchWorkspaceBusy, host.patch_workspace.borrow());
    const bounded = host.resourceLedger().patch_workspace;
    try std.testing.expectEqual(std.math.maxInt(u64), bounded.acquisition_count);
    try std.testing.expectEqual(@as(u64, 2), bounded.busy_count);
}

test "Active Credits admit the complete runtime-sized capacity" {
    var host = try Host.init(std.testing.allocator, 100);
    defer host.deinit();
    var credits: [100]Host.ActiveCredit = undefined;
    for (&credits) |*credit| credit.* = try host.reserveActiveCredit();
    try std.testing.expectError(error.ActiveCapacityExhausted, host.reserveActiveCredit());
    const full = host.resourceLedger().active_credits;
    try std.testing.expectEqual(@as(usize, 100), full.capacity);
    try std.testing.expectEqual(@as(usize, 100), full.occupied);
    try std.testing.expectEqual(@as(usize, 100), full.occupied_high_water);
    for (&credits) |*credit| credit.release();
    try std.testing.expectEqual(@as(usize, 0), host.resourceLedger().active_credits.occupied);
}

fn expectSingleConcurrentWorkspaceOwner(
    comptime Pool: type,
    pool: *Pool,
    comptime busy_error: anyerror,
) !void {
    const Worker = struct {
        fn run(
            worker_pool: *Pool,
            start: *const std.atomic.Value(bool),
            release: *const std.atomic.Value(bool),
            winners: *std.atomic.Value(usize),
            busy: *std.atomic.Value(usize),
            failed: *std.atomic.Value(bool),
        ) void {
            while (!start.load(.acquire)) std.atomic.spinLoopHint();
            if (worker_pool.borrow()) |lease_value| {
                var lease = lease_value;
                _ = winners.fetchAdd(1, .acq_rel);
                while (!release.load(.acquire)) std.atomic.spinLoopHint();
                lease.release() catch failed.store(true, .release);
            } else |err| {
                if (err == busy_error) {
                    _ = busy.fetchAdd(1, .acq_rel);
                } else {
                    failed.store(true, .release);
                }
            }
        }
    };

    var start: std.atomic.Value(bool) = .init(false);
    var release: std.atomic.Value(bool) = .init(false);
    var winners: std.atomic.Value(usize) = .init(0);
    var busy: std.atomic.Value(usize) = .init(0);
    var failed: std.atomic.Value(bool) = .init(false);
    var workers: [8]std.Thread = undefined;
    for (&workers) |*worker| {
        worker.* = try std.Thread.spawn(.{}, Worker.run, .{
            pool,
            &start,
            &release,
            &winners,
            &busy,
            &failed,
        });
    }
    start.store(true, .release);
    while (winners.load(.acquire) + busy.load(.acquire) != workers.len and
        !failed.load(.acquire))
    {
        std.atomic.spinLoopHint();
    }
    const one_winner = winners.load(.acquire) == 1;
    const all_others_busy = busy.load(.acquire) == workers.len - 1;
    const occupied = pool.measurements().occupied_count == 1;
    release.store(true, .release);
    for (workers) |worker| worker.join();

    try std.testing.expect(one_winner);
    try std.testing.expect(all_others_busy);
    try std.testing.expect(occupied);
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), pool.measurements().occupied_count);
    var reused = try pool.borrow();
    try reused.release();
}

test "semantic validation workspace admits one concurrent owner" {
    var host = try Host.init(std.testing.allocator, 8);
    defer host.deinit();
    try expectSingleConcurrentWorkspaceOwner(
        SemanticValidationWorkspacePool,
        &host.semantic_validation,
        error.SemanticValidationWorkspaceBusy,
    );
}

test "patch workspace admits one concurrent owner" {
    var host = try Host.init(std.testing.allocator, 8);
    defer host.deinit();
    try expectSingleConcurrentWorkspaceOwner(
        PatchWorkspacePool,
        &host.patch_workspace,
        error.PatchWorkspaceBusy,
    );
}

test "shared patch workspace contends fail-fast without retaining semantic validation" {
    var host = try Host.init(std.testing.allocator, 1);
    defer host.deinit();
    var patch = try host.patch_workspace.borrow();
    defer patch.release() catch unreachable;
    patch.workspace.patch[0] = 0xa5;

    var validation = try host.semantic_validation.borrow();
    try std.testing.expect(host.patch_workspace.isOccupied());
    try validation.release();
    try std.testing.expectEqual(@as(u8, 0xa5), patch.workspace.patch[0]);
    try std.testing.expectError(
        error.PatchWorkspaceBusy,
        host.patch_workspace.borrow(),
    );
    const contention = host.resourceLedger().patch_workspace;
    try std.testing.expectEqual(@as(u64, 1), contention.busy_count);
}

test "stale copied semantic validation lease cannot scrub a new borrower" {
    var host = try Host.init(std.testing.allocator, 1);
    defer host.deinit();
    var original = try host.semantic_validation.borrow();
    var stale = original;
    try original.release();

    var current = try host.semantic_validation.borrow();
    defer current.release() catch unreachable;
    current.workspace.response[0] = 0xa5;
    try std.testing.expectError(error.StaleSemanticValidationLease, stale.release());
    try std.testing.expectEqual(@as(u8, 0xa5), current.workspace.response[0]);
}

test "stale copied patch workspace lease cannot scrub a new borrower" {
    var host = try Host.init(std.testing.allocator, 1);
    defer host.deinit();
    var original = try host.patch_workspace.borrow();
    var stale = original;
    try original.release();

    var current = try host.patch_workspace.borrow();
    defer current.release() catch unreachable;
    current.workspace.patch[0] = 0xa5;
    try std.testing.expectError(error.StalePatchWorkspaceLease, stale.release());
    try std.testing.expectEqual(@as(u8, 0xa5), current.workspace.patch[0]);
}

test "Tool Catalog preserves byte-bounded Unicode admission" {
    const allocator = std.testing.allocator;
    const envelope = try allocator.alloc(u8, model_contract.max_tool_arguments_envelope_size);
    defer allocator.free(envelope);

    const bash_ascii_exact = try repeatedUtf8(allocator, model_contract.max_bash_command_bytes, "x");
    defer allocator.free(bash_ascii_exact);
    const bash_ascii_over = try repeatedUtf8(allocator, model_contract.max_bash_command_bytes + 1, "x");
    defer allocator.free(bash_ascii_over);
    const bash_unicode_exact = try repeatedUtf8(allocator, model_contract.max_bash_command_bytes / "é".len, "é");
    defer allocator.free(bash_unicode_exact);
    const bash_unicode_over = try repeatedUtf8(allocator, model_contract.max_bash_command_bytes / "é".len + 1, "é");
    defer allocator.free(bash_unicode_over);
    try expectBashArgumentBoundary(envelope, bash_ascii_exact, true);
    try expectBashArgumentBoundary(envelope, bash_ascii_over, false);
    try expectBashArgumentBoundary(envelope, bash_unicode_exact, true);
    try expectBashArgumentBoundary(envelope, bash_unicode_over, false);
    const escaped_bash = try repeatedUtf8(allocator, model_contract.max_bash_command_bytes, "\x01");
    defer allocator.free(escaped_bash);
    const encoded_escaped_bash = try model_contract.encodeJson(envelope, .{
        .command = escaped_bash,
        .timeout_ms = bash_tool.max_timeout_ms,
    });
    try std.testing.expect(encoded_escaped_bash.len <= model_contract.max_tool_arguments_envelope_size);
    try expectBashArgumentBoundary(envelope, escaped_bash, true);

    const patch_ascii_exact = try repeatedUtf8(allocator, model_contract.max_patch_input_bytes, "x");
    defer allocator.free(patch_ascii_exact);
    const patch_ascii_over = try repeatedUtf8(allocator, model_contract.max_patch_input_bytes + 1, "x");
    defer allocator.free(patch_ascii_over);
    const patch_unicode_exact = try repeatedUtf8(allocator, model_contract.max_patch_input_bytes / "é".len, "é");
    defer allocator.free(patch_unicode_exact);
    const patch_unicode_over = try repeatedUtf8(allocator, model_contract.max_patch_input_bytes / "é".len + 1, "é");
    defer allocator.free(patch_unicode_over);
    try expectPatchArgumentBoundary(envelope, patch_ascii_exact, true);
    try expectPatchArgumentBoundary(envelope, patch_ascii_over, false);
    try expectPatchArgumentBoundary(envelope, patch_unicode_exact, true);
    try expectPatchArgumentBoundary(envelope, patch_unicode_over, false);

    const escaped_patch = try repeatedUtf8(allocator, model_contract.max_patch_input_bytes, "\x01");
    defer allocator.free(escaped_patch);
    const encoded_patch = try model_contract.encodeJson(envelope, .{ .patch = escaped_patch });
    try std.testing.expectEqual(
        model_contract.max_tool_arguments_envelope_size,
        encoded_patch.len,
    );
    var decode_scratch: model_contract.StrictToolJsonScratch = .{};
    _ = try model_contract.admitToolArguments(
        &decode_scratch,
        model_contract.default_catalog[1],
        encoded_patch,
    );
    const response_buffer = try allocator.alloc(u8, model_protocol.max_response_size);
    defer allocator.free(response_buffer);
    const response = try model_protocol.encodeTool(
        response_buffer,
        model_contract.apply_patch_key,
        encoded_patch,
    );
    var validation: model_protocol.ValidationScratch = undefined;
    try std.testing.expectEqual(
        model_protocol.Disposition.tool_call,
        model_protocol.parse(&validation, response).disposition,
    );
}
