const std = @import("std");
const binding = @import("binding.zig");
const bash_tool = @import("bash_tool.zig");
const completion_inbox = @import("completion_inbox.zig");
const conversation = @import("conversation.zig");
const core_image = @import("core_image.zig");
const core_state = @import("core_state.zig");
const host_store = @import("host_store.zig");
const model_operation = @import("model_operation.zig");
const model_contract = @import("model_contract.zig");
const model_protocol = @import("model_protocol.zig");
const patch_tool = @import("patch_tool.zig");
const session_store = @import("session.zig");
const session_transition = @import("session_transition.zig");

const agent_generation: u32 = 1;
const production_active_capacity: usize = 1;
const ProductionSlotPool = core_image.SlotPool(production_active_capacity);

comptime {
    std.debug.assert(model_contract.max_patch_input_bytes == patch_tool.max_patch_size);
}

/// Process-owned bounded activation capacity. Construct this once at host
/// startup and pass it through every agent lifecycle entry point.
fn HostWithCapacity(comptime active_capacity: usize) type {
    return struct {
        slots: core_image.SlotPool(active_capacity) = .{},
        semantic_validation: SemanticValidationWorkspacePool = .{},
        patch_workspace: PatchWorkspacePool = .{},

        pub fn resourceLedger(self: *const @This()) HostResourceLedger {
            return .{
                .semantic_validation = self.semantic_validation.measurements(),
                .patch_workspace = self.patch_workspace.measurements(),
            };
        }
    };
}

pub const Host = HostWithCapacity(production_active_capacity);

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
    queue_depth: usize,
    wait_time_ns: u64,
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
    queue_depth: usize,
    wait_time_ns: u64,
};

pub const HostResourceLedger = struct {
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
    workspace: SemanticValidationWorkspace = .{},
    occupied: bool = false,
    generation: u64 = 0,
    busy_count: u64 = 0,

    fn borrow(self: *SemanticValidationWorkspacePool) !SemanticValidationWorkspaceLease {
        if (self.occupied or self.generation == std.math.maxInt(u64)) {
            incrementBounded(&self.busy_count);
            return error.SemanticValidationWorkspaceBusy;
        }
        self.occupied = true;
        self.generation += 1;
        self.workspace.scrub();
        return .{
            .workspace = &self.workspace,
            .context = self,
            .generation = self.generation,
            .release_fn = releaseLease,
        };
    }

    fn measurements(self: *const SemanticValidationWorkspacePool) SemanticValidationResourceLedger {
        const occupied_count: usize = @intFromBool(self.occupied);
        const high_water_count: usize = @intFromBool(self.generation != 0);
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
            .acquisition_count = self.generation,
            .busy_count = self.busy_count,
            .queue_depth = 0,
            .wait_time_ns = 0,
        };
    }

    fn releaseLease(
        context: *anyopaque,
        generation: u64,
        workspace: *SemanticValidationWorkspace,
    ) error{StaleSemanticValidationLease}!void {
        const self: *SemanticValidationWorkspacePool = @ptrCast(@alignCast(context));
        if (!self.occupied or self.generation != generation or workspace != &self.workspace) {
            return error.StaleSemanticValidationLease;
        }
        workspace.scrub();
        self.occupied = false;
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
        if (!self.owner.occupied or self.owner.generation != self.generation or
            self.workspace != &self.owner.workspace)
        {
            return error.StalePatchWorkspaceLease;
        }
        self.workspace.scrub();
        self.owner.occupied = false;
        self.borrowed = false;
    }
};

const PatchWorkspacePool = struct {
    workspace: PatchWorkspace = .{},
    occupied: bool = false,
    generation: u64 = 0,
    busy_count: u64 = 0,

    fn borrow(self: *PatchWorkspacePool) !PatchWorkspaceLease {
        if (self.occupied or self.generation == std.math.maxInt(u64)) {
            incrementBounded(&self.busy_count);
            return error.PatchWorkspaceBusy;
        }
        self.occupied = true;
        self.generation += 1;
        self.workspace.scrub();
        return .{
            .workspace = &self.workspace,
            .owner = self,
            .generation = self.generation,
        };
    }

    fn measurements(self: *const PatchWorkspacePool) PatchWorkspaceResourceLedger {
        const occupied_count: usize = @intFromBool(self.occupied);
        const high_water_count: usize = @intFromBool(self.generation != 0);
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
            .acquisition_count = self.generation,
            .busy_count = self.busy_count,
            .queue_depth = 0,
            .wait_time_ns = 0,
        };
    }
};

fn incrementBounded(value: *u64) void {
    if (value.* != std.math.maxInt(u64)) value.* += 1;
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
    settle_only: bool = false,
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
    var state: ControlSearch = .{};
    _ = try session.inspectSemantic(&state, ControlSearch.applyFact);
    if (state.open_operation) return error.AcceptedOperationUnsettled;
    const agent = agentContext(session);
    const fact = if (control == .cancel)
        session_transition.cancellation(agent)
    else
        session_transition.shutdown(agent);
    _ = try session.commitSemantic(&.{fact}, null);
}

pub fn restoredControl(session: *session_store.Session) !?Control {
    var state: ControlSearch = .{};
    _ = try session.inspectSemantic(&state, ControlSearch.applyFact);
    return state.control;
}

pub fn recoverSemanticWindow(
    host: *Host,
    session: *session_store.Session,
    frame_budget: u8,
) !session_store.RecoveryProgress {
    var core = try Core.open(&host.slots);
    defer core.close();
    return session.recoverSemanticWindow(frame_budget);
}

const ControlSearch = struct {
    open_operation: bool = false,
    operation_id: u64 = 0,
    generation: u32 = 0,
    control: ?Control = null,

    fn applyFact(context: *anyopaque, fact: session_transition.Fact) anyerror!void {
        const self: *ControlSearch = @ptrCast(@alignCast(context));
        switch (fact) {
            .operation_accepted => |record| {
                self.open_operation = true;
                self.operation_id = record.operation.operation_id;
                self.generation = record.operation.generation;
            },
            .result => |record| if (self.open_operation and
                self.operation_id == record.operation.operation_id and
                self.generation == record.operation.generation)
            {
                self.open_operation = false;
            },
            .cancellation => self.control = .cancel,
            .shutdown => self.control = .shutdown,
            else => {},
        }
    }
};

pub const FaultBoundary = enum {
    after_model_dispatch,
    after_completion_inbox,
    after_completion_persist,
    after_final_blob,
    after_assistant_entry,
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
    operation_id: u32,
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
    patch_digest: binding.PatchDescriptor,
    patch_length: u32,
};

fn executableTool(session: *session_store.Session, core: *const core_image.Core) !ExecutableTool {
    const response = try core.response();
    var key_buffer: [model_contract.max_tool_key_size]u8 = undefined;
    const key = try readResponseWindow(session, core, response, response.tool_key, &key_buffer);
    return executableToolFromKey(key);
}

fn executableToolFromKey(key: []const u8) !ExecutableTool {
    if (std.mem.eql(u8, key, model_contract.bash_key)) return .bash;
    if (std.mem.eql(u8, key, model_contract.apply_patch_key)) return .apply_patch;
    return error.UnboundToolKey;
}

fn finalReference(response_ref: u64) u64 {
    return (@as(u64, 1) << 63) | response_ref;
}

const Core = struct {
    lease: core_image.SlotLease,
    slot: *core_image.ActivationSlot,
    reducer: core_image.Core = undefined,
    encoded_state: [core_state.encoded_size]u8 = undefined,
    active: bool = false,

    fn open(pool: *ProductionSlotPool) !Core {
        const lease = try pool.borrow();
        return .{ .lease = lease, .slot = lease.slot };
    }

    fn initialize(self: *Core, agent_id: u64) !void {
        self.reducer = try core_image.Core.initialize(self.slot, .{
            .agent_id = agent_id,
            .generation = agent_generation,
        });
        self.active = true;
    }

    fn activate(self: *Core) !void {
        self.reducer = try core_image.Core.activate(self.slot, &self.encoded_state);
        self.active = true;
    }

    fn suspendIntoState(self: *Core) !void {
        try self.reducer.suspendInto(&self.encoded_state);
        self.active = false;
    }

    fn close(self: *Core) void {
        if (self.active) self.reducer.abandon();
        self.lease.release() catch unreachable;
        self.active = false;
    }
};

fn commitCoreFacts(
    session: *session_store.Session,
    core: *Core,
    facts: []const session_transition.Fact,
    reactivate: bool,
) !void {
    try core.suspendIntoState();
    _ = try session.commitSemantic(facts, &core.encoded_state);
    if (reactivate) try core.activate();
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

fn restoreCoreFromLedger(
    session: *session_store.Session,
    core: *Core,
) !void {
    var replay_context: u8 = 0;
    const replay = try session.inspectSemantic(&replay_context, ignoreFact);
    core.encoded_state = replay.last_core orelse return error.MissingLedgerCoreState;
    try core.activate();
}

fn ignoreFact(_: *anyopaque, _: session_transition.Fact) anyerror!void {}

const ModelSlot = struct {
    session: *session_store.Session,
    scratch: *SemanticValidationWorkspace,
    workspace_path: []const u8,

    const PreparedFacts = struct {
        facts: [3]session_transition.Fact = undefined,
        fact_count: u8 = 0,
    };

    const Tool = union(enum) {
        none,
        generic,
        bash: struct {
            descriptor_ref: u64,
            descriptor_digest: binding.BashDescriptor,
        },
        apply_patch: AdmittedPatch,
    };

    const Admission = struct {
        response: model_protocol.Admission,
        tool: Tool = .none,
    };

    fn admit(context: *anyopaque, completion: ModelCompletion) anyerror!Admission {
        const self: *ModelSlot = @ptrCast(@alignCast(context));
        try model_operation.verifyRequestDigest(
            self.session,
            completion.request_ref,
            completion.request_digest,
        );
        var response = try self.session.openBlob(completion.result);
        defer response.close();
        if (response.length() > model_protocol.max_response_size) return error.ResponseTooLarge;
        const length: usize = @intCast(response.length());
        const bytes = try readAndVerifyModelResponse(
            &response,
            completion.result_digest,
            self.scratch.response[0..length],
        );
        const selected_key = model_protocol.toolKeyForCatalogLookup(bytes) catch null;
        const definition = try model_operation.readToolDefinition(
            self.session,
            completion.request_ref,
            selected_key orelse "",
            &self.scratch.tool_definition,
        );
        var validated = model_protocol.admitWithDefinition(&self.scratch.validation, bytes, definition);
        var parsed = try validated.verify(bytes);
        var tool: Tool = .none;
        if (parsed.disposition == .tool_call) {
            const admitted = (try validated.admittedToolArguments(bytes)) orelse
                return error.MissingAdmittedToolArguments;
            const key = bytes[parsed.tool_key_offset..][0..parsed.tool_key_length];
            const executable = admitExecutableArguments(key, admitted.parsed) catch |err| switch (err) {
                error.InvalidAdmittedBashArguments,
                error.InvalidAdmittedPatchArguments,
                => blk: {
                    validated = try validated.rejectToolCall(bytes);
                    parsed = try validated.verify(bytes);
                    break :blk null;
                },
            };
            if (parsed.disposition == .tool_call) {
                const call_ref = toolCallReference(completion);
                try storeToolCall(self.session, call_ref, key, admitted.json);
                tool = try self.admitTool(completion, executable);
            }
        }
        return .{ .response = try validated.admission(bytes), .tool = tool };
    }

    fn admitTool(
        self: *ModelSlot,
        completion: ModelCompletion,
        executable: ?ExecutableArguments,
    ) !Tool {
        const arguments = executable orelse return .generic;
        return switch (arguments) {
            .bash => |bash| blk: {
                const tool_operation_id = (@as(u64, 1) << 63) | completion.operation_id;
                const descriptor_ref = (@as(u64, 1) << 62) | @as(u32, @truncate(completion.result));
                const descriptor: bash_tool.Descriptor = .{
                    .operation_id = tool_operation_id,
                    .operation_generation = 1,
                    .workspace_path = self.workspace_path,
                    .working_directory = self.workspace_path,
                    .call = .{ .command = bash.command, .timeout_ms = bash.timeout_ms },
                };
                var descriptor_buffer: [bash_tool.max_descriptor_size]u8 = undefined;
                const descriptor_bytes = try bash_tool.encodeDescriptor(&descriptor_buffer, descriptor);
                const digest = bash_tool.descriptorDigest(descriptor_bytes);
                try self.session.storeBlob(descriptor_ref, descriptor_bytes);
                break :blk .{ .bash = .{
                    .descriptor_ref = descriptor_ref,
                    .descriptor_digest = digest,
                } };
            },
            .apply_patch => |patch| blk: {
                const patch_ref = (@as(u64, 1) << 60) | @as(u32, @truncate(completion.result));
                try self.session.storeBlob(patch_ref, patch);
                break :blk .{ .apply_patch = .{
                    .patch_ref = patch_ref,
                    .patch_digest = patch_tool.patchDigest(patch),
                    .patch_length = @intCast(patch.len),
                } };
            },
        };
    }
};

fn prepareToolAdmission(
    host: *Host,
    session: *session_store.Session,
    workspace_path: []const u8,
    completion: ModelCompletion,
    tool: ModelSlot.Tool,
) !ModelSlot.PreparedFacts {
    switch (tool) {
        .none => return .{},
        else => {},
    }
    var prepared: ModelSlot.PreparedFacts = .{};
    switch (tool) {
        .none => unreachable,
        .generic => {},
        .bash => |bash| {
            const operation = operationContext(
                session,
                (@as(u64, 1) << 63) | completion.operation_id,
                1,
            );
            prepared.facts[0] = session_transition.operationSubmitted(
                operation,
                bash.descriptor_ref,
                .{ .bash = bash.descriptor_digest },
                .consequential,
            );
            prepared.facts[1] = session_transition.operationAccepted(
                operation,
                bash.descriptor_ref,
                .{ .bash = bash.descriptor_digest },
                .consequential,
            );
            prepared.fact_count = 2;
        },
        .apply_patch => |patch| {
            var workspace = try host.patch_workspace.borrow();
            defer workspace.release() catch unreachable;
            const patch_bytes = try readAdmittedPatch(session, patch, &workspace.workspace.patch);
            std.debug.assert(!host.semantic_validation.occupied);
            const tool_operation_id = (@as(u64, 3) << 62) | completion.operation_id;
            const intent_ref = (@as(u64, 1) << 58) | @as(u32, @truncate(completion.result));
            const intent = try patch_tool.prepare(session.io, workspace_path, patch_bytes, .{
                .operation_id = tool_operation_id,
                .operation_generation = 1,
                .patch_ref = patch.patch_ref,
            });
            try storePatchIntent(session, intent_ref, intent);
            const operation = operationContext(session, tool_operation_id, 1);
            prepared.facts[0] = session_transition.operationSubmitted(
                operation,
                intent_ref,
                .{ .apply_patch = intent.intent_digest },
                .consequential,
            );
            prepared.facts[1] = session_transition.operationAccepted(
                operation,
                intent_ref,
                .{ .apply_patch = intent.intent_digest },
                .consequential,
            );
            prepared.fact_count = 2;
        },
    }
    const call_ref = toolCallReference(completion);
    const call_entry = try session.appendConversation(.tool_call, call_ref, null);
    const conversation_fact = session_transition.conversationAdvanced(.{
        .agent = agentContext(session),
        .entry_id = call_entry.entry_id,
        .parent_id = call_entry.parent_id,
        .kind = call_entry.kind,
        .content_ref = call_ref,
    });
    prepared.facts[prepared.fact_count] = conversation_fact;
    prepared.fact_count += 1;
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
    var reader = try session.openBlob(admitted.patch_ref);
    defer reader.close();
    if (reader.length() != admitted.patch_length or reader.length() > out.len) {
        return error.InvalidAdmittedPatchBlob;
    }
    const length: usize = @intCast(reader.length());
    var offset: usize = 0;
    while (offset < length) {
        const bytes = try reader.readWindow(offset, out[offset..length]);
        if (bytes.len == 0 or bytes.len > length - offset) return error.TruncatedAdmittedPatchBlob;
        if (bytes.ptr != out[offset..].ptr) @memcpy(out[offset..][0..bytes.len], bytes);
        offset += bytes.len;
    }
    const patch = out[0..length];
    if (!binding.eql(binding.PatchDescriptor, patch_tool.patchDigest(patch), admitted.patch_digest)) {
        return error.InvalidAdmittedPatchBlob;
    }
    return patch;
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
    var core = try Core.open(&host.slots);
    var core_open = true;
    defer if (core_open) core.close();
    const token = session.ownerToken();
    try core.initialize(session.agent_id);
    try core.reducer.startTask(session.activeLeafId());
    try commitCoreFacts(
        session,
        &core,
        &.{session_transition.taskAdmitted(
            agentContext(session),
            session.task_id,
            session.task_id,
        )},
        true,
    );
    _ = try performModelTurn(
        io,
        session,
        token,
        &core,
        &core_open,
        provider,
        1,
        config.completion_hook,
        config.fault,
    );
    return error.CompletionExpected;
}

fn performModelTurn(
    io: std.Io,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    core_open: *bool,
    provider: ?model_operation.Provider,
    model_sequence: u32,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !OperationIds {
    const next_provider = provider orelse return error.SessionOperationPending;
    const ids = try allocateOperationIds(io, session);
    const operation = try core.reducer.beginModelOperation(ids.operation_id, model_sequence);
    const context = try core.reducer.modelContext();
    const operation_generation = operation.generation;
    const request_digest = try model_operation.buildRequest(
        session,
        ids.request_ref,
        context.first_entry,
        context.entry_count,
    );
    try model_operation.verifyRequestDigest(session, ids.request_ref, request_digest);
    try core.reducer.acceptOperation(.{ .id = ids.operation_id, .generation = operation_generation });
    const operation_context = operationContext(session, ids.operation_id, operation_generation);
    const admission_facts = [_]session_transition.Fact{
        session_transition.operationSubmitted(
            operation_context,
            ids.request_ref,
            .{ .model = request_digest },
            .none,
        ),
        session_transition.operationAccepted(
            operation_context,
            ids.request_ref,
            .{ .model = request_digest },
            .none,
        ),
        session_transition.modelAttemptAdmitted(
            operation_context,
            ids.attempt_id,
            ids.request_ref,
            .{ .model = request_digest },
            0,
        ),
    };
    try commitCoreFacts(
        session,
        core,
        &admission_facts,
        false,
    );
    core.close();
    core_open.* = false;
    try dispatchModelAttempt(session, token, next_provider, .{
        .request_ref = ids.request_ref,
        .request_digest = request_digest,
        .response_ref = ids.response_ref,
        .operation_id = ids.operation_id,
        .operation_generation = operation_generation,
        .attempt_id = ids.attempt_id,
    }, completion_hook, fault);
    return error.CompletionExpected;
}

fn retryModelAttempt(
    io: std.Io,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    core_open: *bool,
    provider: ?model_operation.Provider,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !void {
    const operation = try core.reducer.operation();
    var history: FactSearch = .{
        .operation_id = operation.id,
        .generation = operation.generation,
        .recovery_class = .model,
    };
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    const descriptor = history.descriptor orelse return error.MissingModelDescriptor;
    if (history.attempt_count == FactSearch.max_attempts) {
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
            .result_digest = try blobDigest(session, result_ref),
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
    const attempt = session_transition.modelAttemptAdmitted(
        operationContext(session, operation.id, operation.generation),
        attempt_id,
        descriptor.descriptor_ref,
        descriptor.descriptor_digest,
        history.attempt_count,
    );
    try commitCoreFacts(
        session,
        core,
        &.{attempt},
        false,
    );
    core.close();
    core_open.* = false;
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
    var result_ref = dispatch.response_ref;
    var provider_failed = false;
    provider.dispatch(
        provider.context,
        try provider_io.request(),
        provider_io.responseCapability(),
    ) catch {
        result_ref = try provider_io.publishProviderFailure(
            session,
            dispatch.response_ref,
        );
        provider_failed = true;
    };
    if (!provider_failed) {
        try provider_io.ensureResponsePublished();
        try reach(fault, .after_model_dispatch);
    }
    const evidence = completion_inbox.bind(.{
        .kind = .model,
        .session_id = session.session_id,
        .ownership_epoch = token.epoch,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = dispatch.operation_id,
        .operation_generation = dispatch.operation_generation,
        .attempt_id = dispatch.attempt_id,
        .result_ref = result_ref,
        .result_digest = try blobDigest(session, result_ref),
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
    core: *Core,
    host: *Host,
    ids: OperationIds,
    core_open: *bool,
    workspace_path: []const u8,
    permission_mode: PermissionMode,
    cancellation: ?*const std.atomic.Value(bool),
    approval_required_hook: ?ApprovalRequiredHook,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !void {
    if (try executableTool(session, &core.reducer) != .bash) {
        return error.UnsupportedTool;
    }
    const tool_operation_id = (@as(u64, 1) << 63) | ids.operation_id;
    var history: FactSearch = .{
        .operation_id = tool_operation_id,
        .generation = 1,
        .recovery_class = .consequential,
    };
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    const admitted = history.descriptor orelse return error.MissingActionDescriptor;
    const descriptor_ref = admitted.descriptor_ref;
    var descriptor_buffer: [bash_tool.max_descriptor_size]u8 = undefined;
    const descriptor_bytes = try readBoundedBlob(session, descriptor_ref, &descriptor_buffer);
    const admitted_descriptor = try bash_tool.decodeDescriptor(descriptor_bytes);
    const digest = switch (admitted.descriptor_digest) {
        .bash => |value| value,
        else => return error.InvalidBashDescriptor,
    };
    if (!binding.eql(binding.BashDescriptor, bash_tool.descriptorDigest(descriptor_bytes), digest) or
        admitted_descriptor.operation_id != tool_operation_id or
        admitted_descriptor.operation_generation != 1 or
        !std.mem.eql(u8, admitted_descriptor.workspace_path, workspace_path))
    {
        return error.InvalidBashDescriptor;
    }
    const result_ref = (@as(u64, 1) << 61) | ids.response_ref;
    const operation_context = operationContext(session, tool_operation_id, 1);

    if (permission_mode == .ask) {
        const approval = session_transition.approvalRequired(.{
            .operation = operation_context,
            .binding_ref = 0,
            .descriptor_ref = descriptor_ref,
            .descriptor_digest = .{ .bash = digest },
        });
        try commitCoreFacts(session, core, &.{approval}, true);
        if (approval_required_hook) |hook| try hook.required(hook.context, .{
            .kind = .bash,
            .operation_id = tool_operation_id,
            .operation_generation = 1,
            .descriptor_digest = .{ .bash = digest },
            .descriptor_ref = descriptor_ref,
        });
        return error.PermissionInputRequired;
    }
    const authorization = session_transition.authorization(.{
        .operation = operation_context,
        .permission_ref = 0,
        .descriptor_digest = .{ .bash = digest },
        .allowed = true,
    });
    _ = try session.commitSemantic(&.{authorization}, null);

    var attempt_id: u64 = 0;
    while (attempt_id == 0) io.random(std.mem.asBytes(&attempt_id));
    const attempt = session_transition.consequentialAttemptAdmitted(
        operation_context,
        attempt_id,
        descriptor_ref,
        .{ .bash = digest },
    );
    try commitCoreFacts(
        session,
        core,
        &.{attempt},
        false,
    );
    core.close();
    core_open.* = false;
    var execution = try bash_tool.executeDescriptor(
        allocator,
        io,
        admitted_descriptor,
        .{ .cancelled = cancellation },
    );
    try reach(fault, .after_bash_execution);
    core.* = try Core.open(&host.slots);
    core_open.* = true;
    try restoreCoreFromLedger(session, core);
    defer execution.deinit();
    try storeBashResult(session, result_ref, execution);
    const result_digest = try blobDigest(session, result_ref);
    const evidence = completion_inbox.bind(.{
        .kind = .bash,
        .session_id = session.session_id,
        .ownership_epoch = token.epoch,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = tool_operation_id,
        .operation_generation = 1,
        .attempt_id = attempt_id,
        .result_ref = result_ref,
        .result_digest = result_digest,
    });
    try session.publishCompletionEvidence(evidence);
    if (completion_hook) |hook| try hook.offered(hook.context, evidence);
    return error.CompletionOffered;
}

fn requestPatchPermission(
    session: *session_store.Session,
    core: *Core,
    ids: OperationIds,
    permission_mode: PermissionMode,
    approval_required_hook: ?ApprovalRequiredHook,
    fault: ?FaultHook,
) !void {
    const tool_operation_id = (@as(u64, 3) << 62) | ids.operation_id;
    var history: FactSearch = .{
        .operation_id = tool_operation_id,
        .generation = 1,
        .recovery_class = .consequential,
    };
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    const admitted = history.descriptor orelse return error.MissingActionDescriptor;
    const intent_ref = admitted.descriptor_ref;
    var intent_buffer: [patch_tool.max_intent_size]u8 = undefined;
    const intent = try readPatchIntent(session, intent_ref, &intent_buffer);
    const digest = switch (admitted.descriptor_digest) {
        .apply_patch => |value| value,
        else => return error.InvalidPatchIntent,
    };
    if (intent.operation_id != tool_operation_id or intent.operation_generation != 1 or
        !binding.eql(binding.PatchIntent, intent.intent_digest, digest))
    {
        return error.InvalidPatchIntent;
    }
    const operation_context = operationContext(session, tool_operation_id, 1);

    if (permission_mode == .ask) {
        const approval = session_transition.approvalRequired(.{
            .operation = operation_context,
            .binding_ref = intent_ref,
            .descriptor_ref = intent.patch_ref,
            .descriptor_digest = .{ .apply_patch = intent.intent_digest },
        });
        try commitCoreFacts(
            session,
            core,
            &.{approval},
            true,
        );
        if (approval_required_hook) |hook| try hook.required(hook.context, .{
            .kind = .apply_patch,
            .operation_id = tool_operation_id,
            .operation_generation = 1,
            .descriptor_digest = .{ .apply_patch = intent.intent_digest },
            .descriptor_ref = intent.patch_ref,
        });
        return error.PermissionInputRequired;
    }
    const authorization = session_transition.authorization(.{
        .operation = operation_context,
        .permission_ref = intent_ref,
        .descriptor_digest = .{ .apply_patch = intent.intent_digest },
        .allowed = true,
    });
    _ = try session.commitSemantic(&.{authorization}, null);
    try reach(fault, .after_patch_authorization);
}

fn storePatchIntent(
    session: *session_store.Session,
    intent_ref: u64,
    intent: patch_tool.Intent,
) !void {
    var bytes: [patch_tool.max_intent_size]u8 = undefined;
    try session.storeBlob(intent_ref, try patch_tool.encodeIntent(&bytes, intent));
}

fn storeBashResult(
    session: *session_store.Session,
    result_ref: u64,
    execution: bash_tool.Execution,
) !void {
    var header: [bash_tool.result_header_size]u8 = undefined;
    const header_bytes = try bash_tool.encodeResultHeader(&header, execution);
    var writer = try session.beginBlob(result_ref);
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
    var core = try Core.open(&host.slots);
    var core_open = true;
    defer if (core_open) core.close();
    const token = session.ownerToken();
    try restoreCoreFromLedger(session, &core);
    var outcome = (try core.reducer.task()).phase;
    if (outcome == .awaiting_model) {
        if (durableCompletion(session, token, &core)) |completion| {
            const admission = blk: {
                var scratch = try host.semantic_validation.borrow();
                defer scratch.release() catch unreachable;
                var slot: ModelSlot = .{
                    .session = session,
                    .scratch = scratch.workspace,
                    .workspace_path = config.workspace_path,
                };
                break :blk try ModelSlot.admit(&slot, completion);
            };
            const prepared = try prepareToolAdmission(
                host,
                session,
                config.workspace_path,
                completion,
                admission.tool,
            );
            _ = try core.reducer.applyModelResponse(.{
                .id = completion.operation_id,
                .generation = completion.operation_generation,
            }, admission.response, completion.result, completion.result_digest);
            var evidence_agent = agentContext(session);
            evidence_agent.ownership_epoch = completion.ownership_epoch;
            const terminal = session_transition.result(.{
                .operation = .{
                    .agent = evidence_agent,
                    .operation_id = completion.operation_id,
                    .generation = completion.operation_generation,
                },
                .result_ref = completion.result,
                .result_digest = completion.result_digest,
                .class = .ordinary,
                .evidence = .{ .durable = .{ .model = completion.attempt_id } },
            });
            const applied = session_transition.resultApplied(.{
                .operation = operationContext(session, completion.operation_id, completion.operation_generation),
                .attempt_id = completion.attempt_id,
                .result_ref = completion.result,
                .result_digest = completion.result_digest,
                .recovery_class = .model,
            });
            var admission_facts: [5]session_transition.Fact = undefined;
            admission_facts[0] = terminal;
            admission_facts[1] = applied;
            @memcpy(admission_facts[2..][0..prepared.fact_count], prepared.facts[0..prepared.fact_count]);
            try commitCoreFacts(
                session,
                &core,
                admission_facts[0 .. 2 + prepared.fact_count],
                true,
            );
        } else |err| switch (err) {
            error.SessionOperationPending => try retryModelAttempt(
                io,
                session,
                token,
                &core,
                &core_open,
                provider,
                config.completion_hook,
                config.fault,
            ),
            else => return err,
        }
        outcome = (try core.reducer.task()).phase;
    }
    if (outcome == .final_candidate) {
        return finalizeCandidate(
            session,
            &core,
            null,
        );
    }
    if (outcome == .awaiting_tool) {
        switch (try reconcileToolCall(
            host,
            session,
            token,
            &core,
            session.workspacePath(),
            config.completion_hook,
            config.fault,
        )) {
            .indeterminate => return error.BashPossiblyExecuted,
            .ready => outcome = .ready,
            .approval_required => return error.PatchApprovalRequired,
            .none => {
                if (config.settle_only) return error.ToolCallDeferred;
                const observation = try core.reducer.operation();
                const ids: OperationIds = .{
                    .operation_id = @intCast(observation.id),
                    .attempt_id = 0,
                    .request_ref = 0,
                    .response_ref = @truncate(observation.result_ref),
                    .final_ref = finalReference(observation.result_ref),
                };
                switch (try executableTool(session, &core.reducer)) {
                    .bash => try executeBashCall(
                        io,
                        allocator,
                        session,
                        token,
                        &core,
                        host,
                        ids,
                        &core_open,
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
                            &core,
                            ids,
                            config.permission_mode,
                            config.approval_required_hook,
                            config.fault,
                        );
                        _ = try reconcilePatch(
                            host,
                            session,
                            token,
                            &core,
                            config.workspace_path,
                            config.completion_hook,
                            config.fault,
                        );
                    },
                }
                outcome = (try core.reducer.task()).phase;
            },
        }
    }
    if (outcome == .failed) {
        const response = try core.reducer.response();
        if (response.disposition == .input_request) return error.InteractionRequestLayerRequired;
        return modelFailure(@intFromEnum(response.failure));
    }
    if (outcome == .finished) {
        const entry_id = (try core.reducer.task()).final_entry_id;
        if (entry_id != session.activeLeafId()) return error.FinalEntryMismatch;
        const entry = try session.readEntry(entry_id);
        if (entry.kind != .assistant_text) return error.InvalidFinalEntry;
        return entry.content_ref;
    }
    if (outcome != .ready) return error.SessionNotReadyForModel;
    if (try hasIndeterminateBash(session)) return error.BashPossiblyExecuted;
    if (config.settle_only) return error.SessionNeedsModel;
    _ = try performModelTurn(
        io,
        session,
        token,
        &core,
        &core_open,
        provider orelse return error.SessionNeedsModel,
        2,
        config.completion_hook,
        null,
    );
    if ((try core.reducer.response()).disposition != .final_answer) {
        return error.ResumedModelDidNotFinish;
    }
    const final_ref = try finalizeCandidate(
        session,
        &core,
        null,
    );
    return final_ref;
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
    var core = try Core.open(&host.slots);
    var core_open = true;
    defer if (core_open) core.close();
    try restoreCoreFromLedger(session, &core);
    if ((try core.reducer.task()).phase != .awaiting_tool) return error.PermissionNoLongerRequired;
    const tool = try executableTool(session, &core.reducer);
    const observation = try core.reducer.operation();
    const expected_operation_id = switch (tool) {
        .bash => (@as(u64, 1) << 63) | observation.id,
        .apply_patch => (@as(u64, 3) << 62) | observation.id,
    };
    if (decision.operation_id != expected_operation_id or
        decision.operation_generation != 1)
    {
        return error.StalePermissionDecision;
    }
    var history: FactSearch = .{
        .operation_id = expected_operation_id,
        .generation = 1,
        .recovery_class = .consequential,
    };
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    const descriptor = history.descriptor orelse return error.MissingActionDescriptor;
    if (!binding.descriptorEql(descriptor.descriptor_digest, decision.descriptor_digest)) {
        return error.StalePermissionDecision;
    }
    if (history.result != null or history.attempt != null) return error.PermissionNoLongerRequired;
    const pending = history.approval_required orelse return error.ApprovalNotCommitted;
    if (pending.descriptor_ref != decision.descriptor_ref) return error.StalePermissionDecision;
    if (history.authorization != null or
        !binding.descriptorEql(pending.descriptor_digest, descriptor.descriptor_digest))
    {
        return error.PermissionNoLongerRequired;
    }

    switch (tool) {
        .bash => {
            const operation_context = operationContext(session, expected_operation_id, 1);
            var descriptor_buffer: [bash_tool.max_descriptor_size]u8 = undefined;
            var reader = try session.openBlob(descriptor.descriptor_ref);
            defer reader.close();
            if (reader.length() > descriptor_buffer.len) return error.InvalidBashCallRange;
            const descriptor_length: usize = @intCast(reader.length());
            const descriptor_bytes = try reader.readWindow(0, descriptor_buffer[0..descriptor_length]);
            if (descriptor_bytes.len != descriptor_length) return error.TruncatedBashDescriptor;
            const bash_descriptor = try bash_tool.decodeDescriptor(descriptor_bytes);
            const expected_bash_digest = switch (descriptor.descriptor_digest) {
                .bash => |value| value,
                else => return error.StalePermissionDecision,
            };
            if (bash_descriptor.operation_id != expected_operation_id or
                bash_descriptor.operation_generation != 1 or
                !std.mem.eql(u8, bash_descriptor.workspace_path, session.workspacePath()) or
                !binding.eql(
                    binding.BashDescriptor,
                    bash_tool.descriptorDigest(descriptor_bytes),
                    expected_bash_digest,
                ))
            {
                return error.StalePermissionDecision;
            }
            const authorization = session_transition.authorization(.{
                .operation = operation_context,
                .permission_ref = 0,
                .descriptor_digest = descriptor.descriptor_digest,
                .allowed = allow,
            });
            _ = try session.commitSemantic(&.{authorization}, null);
            const result_ref = (@as(u64, 1) << 61) | @as(u32, @truncate(observation.result_ref));
            var attempt_id: u64 = 0;
            var execution: bash_tool.Execution = undefined;
            if (allow) {
                while (attempt_id == 0) io.random(std.mem.asBytes(&attempt_id));
                const attempt = session_transition.consequentialAttemptAdmitted(
                    operation_context,
                    attempt_id,
                    descriptor.descriptor_ref,
                    descriptor.descriptor_digest,
                );
                try commitCoreFacts(session, &core, &.{attempt}, false);
                core.close();
                core_open = false;
                execution = try bash_tool.executeDescriptor(
                    allocator,
                    io,
                    bash_descriptor,
                    .{ .cancelled = cancellation },
                );
                core = try Core.open(&host.slots);
                core_open = true;
                try restoreCoreFromLedger(session, &core);
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
            const result_digest = try blobDigest(session, result_ref);
            if (allow) {
                const evidence = completion_inbox.bind(.{
                    .kind = .bash,
                    .session_id = session.session_id,
                    .ownership_epoch = token.epoch,
                    .agent_id = session.agent_id,
                    .agent_generation = agent_generation,
                    .operation_id = expected_operation_id,
                    .operation_generation = 1,
                    .attempt_id = attempt_id,
                    .result_ref = result_ref,
                    .result_digest = result_digest,
                });
                try session.publishCompletionEvidence(evidence);
                if (completion_hook) |hook| try hook.offered(hook.context, evidence);
                return error.CompletionOffered;
            }
            const terminal = session_transition.result(.{
                .operation = operation_context,
                .result_ref = result_ref,
                .result_digest = result_digest,
                .class = if (execution.status == .indeterminate) .indeterminate else .ordinary,
                .evidence = if (attempt_id == 0)
                    .{ .immediate = .consequential }
                else
                    .{ .durable = .{ .bash = attempt_id } },
            });
            _ = try session.commitSemantic(&.{terminal}, null);
            try reconcileBashResult(
                session,
                &core,
                toolResultFromRecord(terminal.result),
            );
        },
        .apply_patch => {
            var intent_bytes: [patch_tool.max_intent_size]u8 = undefined;
            const intent_slice = try readBoundedBlob(session, pending.binding_ref, &intent_bytes);
            const intent = try patch_tool.decodeIntent(intent_slice);
            const patch_descriptor = switch (descriptor.descriptor_digest) {
                .apply_patch => |value| value,
                else => return error.StalePermissionDecision,
            };
            if (descriptor.descriptor_ref != pending.binding_ref or
                intent.operation_id != expected_operation_id or
                intent.operation_generation != 1 or
                intent.patch_ref != pending.descriptor_ref or
                !binding.eql(binding.PatchIntent, intent.intent_digest, patch_descriptor))
            {
                return error.StalePermissionDecision;
            }
            const operation_context = operationContext(session, expected_operation_id, 1);
            const authorization = session_transition.authorization(.{
                .operation = operation_context,
                .permission_ref = pending.binding_ref,
                .descriptor_digest = descriptor.descriptor_digest,
                .allowed = allow,
            });
            _ = try session.commitSemantic(&.{authorization}, null);
        },
    }
    core.close();
    core_open = false;
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
    allocator: std.mem.Allocator,
    session: *session_store.Session,
    offered: completion_inbox.Envelope,
    config: RuntimeConfig,
    provider: ?model_operation.Provider,
) !u64 {
    const token = session.ownerToken();
    try completion_inbox.validate(offered);
    if (offered.session_id != session.session_id or offered.agent_id != session.agent_id or
        offered.agent_generation != agent_generation or
        offered.ownership_epoch > token.epoch)
    {
        return error.StaleCompletion;
    }
    var history: FactSearch = .{
        .operation_id = offered.operation_id,
        .generation = offered.operation_generation,
        .target_attempt_id = offered.attempt_id,
        .recovery_class = switch (offered.kind) {
            .model => .model,
            .bash, .apply_patch => .consequential,
        },
    };
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    const attempt = history.attempt orelse return error.StaleCompletion;
    if (attempt.attempt_id != offered.attempt_id) return error.StaleCompletion;
    if (offered.ownership_epoch != attempt.operation.agent.ownership_epoch) {
        return error.CompletionAttemptEpochMismatch;
    }
    if (offered.kind != std.meta.activeTag(attempt.descriptor_digest)) return error.StaleCompletion;
    if (history.result) |result| {
        if (resultAttemptId(result) != offered.attempt_id) {
            return advanceRestored(host, allocator, session, config, provider);
        }
        if (result.result_ref != offered.result_ref or
            !binding.eql(binding.Result, result.result_digest, offered.result_digest))
        {
            return error.ConflictingCompletionEvidence;
        }
        return advanceRestored(host, allocator, session, config, provider);
    }
    var inbox: InboxSearch = .{
        .session_id = offered.session_id,
        .agent_id = offered.agent_id,
        .operation_id = offered.operation_id,
        .operation_generation = offered.operation_generation,
        .attempt_id = offered.attempt_id,
        .maximum_epoch = token.epoch,
        .expected_epoch = attempt.operation.agent.ownership_epoch,
        .expected_kind = std.meta.activeTag(attempt.descriptor_digest),
    };
    _ = try session.scanCompletionEvidence(&inbox, InboxSearch.apply);
    const evidence = inbox.match orelse return error.CompletionEvidenceMissing;
    if (evidence.result_ref != offered.result_ref or
        !binding.eql(binding.Result, evidence.result_digest, offered.result_digest) or
        !binding.eql(binding.Completion, evidence.completion_digest, offered.completion_digest))
    {
        return error.ConflictingCompletionEvidence;
    }
    return advanceRestored(host, allocator, session, config, provider);
}

const ToolRecovery = enum { none, ready, indeterminate, approval_required };

fn reconcileToolCall(
    host: *Host,
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    workspace_path: []const u8,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !ToolRecovery {
    return switch (try executableTool(session, &core.reducer)) {
        .bash => reconcileBash(session, token, core),
        .apply_patch => reconcilePatch(
            host,
            session,
            token,
            core,
            workspace_path,
            completion_hook,
            fault,
        ),
    };
}

fn reconcileBash(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
) !ToolRecovery {
    const model_observation = try core.reducer.operation();
    const operation_id = (@as(u64, 1) << 63) | model_observation.id;
    var history: FactSearch = .{
        .operation_id = operation_id,
        .generation = 1,
        .recovery_class = .consequential,
    };
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    _ = history.descriptor orelse return .none;
    if (history.result) |result| {
        try reconcileBashResult(
            session,
            core,
            toolResultFromRecord(result),
        );
        return if (result.class == .indeterminate)
            .indeterminate
        else
            .ready;
    }
    const attempt = history.attempt orelse {
        if (history.authorization == null and history.approval_required != null) {
            return .approval_required;
        }
        const authorization = history.authorization orelse return .none;
        if (authorization.allowed) return .none;
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
        try storeOrExpectBlob(session, result_ref, &encoded);
        const denied = session_transition.result(.{
            .operation = operationContext(session, operation_id, 1),
            .result_ref = result_ref,
            .result_digest = try blobDigest(session, result_ref),
            .class = .ordinary,
            .evidence = .{ .immediate = .consequential },
        });
        _ = try session.commitSemantic(&.{denied}, null);
        try reconcileBashResult(
            session,
            core,
            toolResultFromRecord(denied.result),
        );
        return .ready;
    };
    var inbox: InboxSearch = .{
        .session_id = session.session_id,
        .agent_id = session.agent_id,
        .operation_id = operation_id,
        .operation_generation = 1,
        .attempt_id = attempt.attempt_id,
        .maximum_epoch = token.epoch,
        .expected_epoch = attempt.operation.agent.ownership_epoch,
        .expected_kind = .bash,
    };
    _ = try session.scanCompletionEvidence(&inbox, InboxSearch.apply);
    var evidence_agent = attempt.operation.agent;
    var result_ref: u64 = undefined;
    var result_digest: binding.Result = undefined;
    var status: bash_tool.Status = undefined;
    if (inbox.match) |envelope| {
        if (!binding.eql(
            binding.Result,
            try blobDigest(session, envelope.result_ref),
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
        try storeOrExpectBlob(session, result_ref, &encoded);
        result_digest = try blobDigest(session, result_ref);
        status = .indeterminate;
        try session.publishCompletionEvidence(completion_inbox.bind(.{
            .kind = .bash,
            .session_id = session.session_id,
            .ownership_epoch = attempt.operation.agent.ownership_epoch,
            .agent_id = session.agent_id,
            .agent_generation = agent_generation,
            .operation_id = operation_id,
            .operation_generation = 1,
            .attempt_id = attempt.attempt_id,
            .result_ref = result_ref,
            .result_digest = result_digest,
        }));
    }
    const result = session_transition.result(.{
        .operation = .{ .agent = evidence_agent, .operation_id = operation_id, .generation = 1 },
        .result_ref = result_ref,
        .result_digest = result_digest,
        .class = if (status == .indeterminate) .indeterminate else .ordinary,
        .evidence = .{ .durable = .{ .bash = attempt.attempt_id } },
    });
    _ = try session.commitSemantic(&.{result}, null);
    try reconcileBashResult(
        session,
        core,
        toolResultFromRecord(result.result),
    );
    return if (result.result.class == .indeterminate)
        .indeterminate
    else
        .ready;
}

fn readBashStatus(
    session: *session_store.Session,
    reference: u64,
) !bash_tool.Status {
    var reader = try session.openBlob(reference);
    defer reader.close();
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
    token: session_store.OwnerToken,
    core: *Core,
    workspace_path: []const u8,
    completion_hook: ?CompletionHook,
    fault: ?FaultHook,
) !ToolRecovery {
    const operation_observation = try core.reducer.operation();
    const model_operation_id = operation_observation.id;
    const response_ref: u32 = @truncate(operation_observation.result_ref);
    const operation_id = (@as(u64, 3) << 62) | model_operation_id;
    const result_ref = (@as(u64, 1) << 57) | response_ref;
    var history: FactSearch = .{
        .operation_id = operation_id,
        .generation = 1,
        .recovery_class = .consequential,
    };
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    const validated = history.descriptor orelse return .none;
    const patch_descriptor = switch (validated.descriptor_digest) {
        .apply_patch => |value| value,
        else => return error.InvalidPatchHistory,
    };
    var intent_bytes: [patch_tool.max_intent_size]u8 = undefined;
    const intent = try readPatchIntent(session, validated.descriptor_ref, &intent_bytes);
    if (intent.operation_id != operation_id or intent.operation_generation != 1 or
        !binding.eql(binding.PatchIntent, intent.intent_digest, patch_descriptor) or
        !std.mem.eql(u8, intent.workspace_path, workspace_path))
    {
        return error.InvalidPatchHistory;
    }
    const patch_ref = intent.patch_ref;
    if (history.result) |settled| {
        if (settled.result_ref != result_ref) {
            return error.InvalidPatchHistory;
        }
        try reconcileToolResult(
            session,
            core,
            (@as(u64, 1) << 59) | response_ref,
            .apply_patch,
            toolResultFromRecord(settled),
        );
        return .ready;
    }
    if (history.authorization == null and history.approval_required != null) {
        return .approval_required;
    }
    const authorization = history.authorization orelse return .none;
    if (!binding.descriptorEql(authorization.descriptor_digest, validated.descriptor_digest) or
        authorization.permission_ref != validated.descriptor_ref)
    {
        return error.InvalidPatchHistory;
    }
    var attempt = history.attempt;
    var immediate_status: ?patch_tool.ResultStatus = if (authorization.allowed) null else .denied;
    if (!authorization.allowed and attempt != null) return error.InvalidPatchHistory;
    if (authorization.allowed and attempt == null) {
        const ready = blk: {
            var workspace = try host.patch_workspace.borrow();
            defer workspace.release() catch unreachable;
            const patch = try readBoundedBlob(session, patch_ref, &workspace.workspace.patch);
            break :blk try patch_tool.readyForAttempt(session.io, intent, patch);
        };
        if (!ready) {
            immediate_status = .stale;
        } else {
            // The first lease ended before this durable transition. Reconciliation
            // reopens the immutable patch under a new lease only if it needs bytes.
            var attempt_id: u64 = 0;
            while (attempt_id == 0) session.io.random(std.mem.asBytes(&attempt_id));
            const admitted = session_transition.consequentialAttemptAdmitted(
                operationContext(session, operation_id, 1),
                attempt_id,
                validated.descriptor_ref,
                validated.descriptor_digest,
            );
            try commitCoreFacts(session, core, &.{admitted}, false);
            attempt = admitted.attempt_admitted;
            try reach(fault, .after_patch_attempt);
        }
    }

    var result_digest: binding.Result = undefined;
    var result_status: patch_tool.ResultStatus = undefined;
    var evidence_agent = if (attempt) |admitted| admitted.operation.agent else agentContext(session);
    var result_evidence: session_transition.ResultEvidence = .{ .immediate = .consequential };
    if (immediate_status) |status| {
        result_status = status;
        var result_bytes: [patch_tool.result_size]u8 = undefined;
        try patch_tool.encodeResult(&result_bytes, .{
            .status = status,
            .intent_ref = validated.descriptor_ref,
            .intent_digest = patch_descriptor,
        });
        try storeOrExpectBlob(session, result_ref, &result_bytes);
        result_digest = try blobDigest(session, result_ref);
    } else {
        const admitted = attempt orelse return error.InvalidPatchHistory;
        if (admitted.descriptor_ref != validated.descriptor_ref or
            !binding.descriptorEql(admitted.descriptor_digest, validated.descriptor_digest))
        {
            return error.InvalidPatchHistory;
        }
        result_evidence = .{ .durable = .{ .apply_patch = admitted.attempt_id } };
        var inbox: InboxSearch = .{
            .session_id = session.session_id,
            .agent_id = session.agent_id,
            .operation_id = operation_id,
            .operation_generation = 1,
            .attempt_id = admitted.attempt_id,
            .maximum_epoch = token.epoch,
            .expected_epoch = admitted.operation.agent.ownership_epoch,
            .expected_kind = .apply_patch,
        };
        _ = try session.scanCompletionEvidence(&inbox, InboxSearch.apply);
        if (inbox.match) |envelope| {
            if (envelope.result_ref != result_ref or !binding.eql(
                binding.Result,
                try blobDigest(session, envelope.result_ref),
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
                const patch = try readBoundedBlob(session, patch_ref, &workspace.workspace.patch);
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
            try storeOrExpectBlob(session, result_ref, &result_bytes);
            result_digest = try blobDigest(session, result_ref);
            const envelope = completion_inbox.bind(.{
                .kind = .apply_patch,
                .session_id = session.session_id,
                .ownership_epoch = admitted.operation.agent.ownership_epoch,
                .agent_id = session.agent_id,
                .agent_generation = agent_generation,
                .operation_id = operation_id,
                .operation_generation = 1,
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
    const terminal = session_transition.result(.{
        .operation = .{ .agent = evidence_agent, .operation_id = operation_id, .generation = 1 },
        .result_ref = result_ref,
        .result_digest = result_digest,
        .class = if (result_status == .indeterminate) .indeterminate else .ordinary,
        .evidence = result_evidence,
    });
    _ = try session.commitSemantic(&.{terminal}, null);
    try reconcileToolResult(
        session,
        core,
        (@as(u64, 1) << 59) | response_ref,
        .apply_patch,
        toolResultFromRecord(terminal.result),
    );
    return .ready;
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
    return patch_tool.decodeIntent(try readBoundedBlob(session, intent_ref, buffer));
}

fn readPatchResultStatus(
    session: *session_store.Session,
    result_ref: u64,
    intent_ref: u64,
    intent_digest: binding.PatchIntent,
) !patch_tool.ResultStatus {
    var bytes: [patch_tool.result_size]u8 = undefined;
    try readExactBlob(session, result_ref, &bytes);
    const result = try patch_tool.decodeResult(&bytes);
    if (result.intent_ref != intent_ref or
        !binding.eql(binding.PatchIntent, result.intent_digest, intent_digest))
    {
        return error.InvalidPatchResult;
    }
    return result.status;
}

fn reconcileBashResult(
    session: *session_store.Session,
    core: *Core,
    result: ToolResult,
) !void {
    const response_ref: u32 = @truncate(result.result);
    if (result.result != ((@as(u64, 1) << 61) | response_ref)) return error.InvalidToolResultReference;
    const call_ref = (@as(u64, 1) << 59) | response_ref;
    try reconcileToolResult(session, core, call_ref, .bash, result);
}

fn reconcileToolResult(
    session: *session_store.Session,
    core: *Core,
    call_ref: u64,
    tool: ExecutableTool,
    result: ToolResult,
) !void {
    const visible_ref = (@as(u64, 1) << 55) | @as(u32, @truncate(result.result));
    const active = try session.readEntry(session.activeLeafId());
    var call_entry: session_store.ConversationEntry = undefined;
    var result_entry: session_store.ConversationEntry = undefined;
    if (active.kind == .tool_result and active.content_ref == visible_ref) {
        result_entry = active;
        call_entry = try session.readEntry(active.parent_id);
    } else if (active.kind == .tool_call and active.content_ref == call_ref) {
        call_entry = active;
        try storeVisibleToolResult(session, tool, result.result, visible_ref, call_entry.entry_id);
        result_entry = try session.appendConversation(.tool_result, visible_ref, null);
    } else {
        return error.ToolConversationMismatch;
    }
    if (call_entry.kind != .tool_call or call_entry.content_ref != call_ref or
        result_entry.parent_id != call_entry.entry_id)
    {
        return error.ToolConversationMismatch;
    }
    try core.reducer.commitToolResult(call_entry.entry_id, result_entry.entry_id);
    const applied_facts = [_]session_transition.Fact{
        session_transition.resultApplied(.{
            .operation = operationContext(session, result.operation_id, result.operation_generation),
            .attempt_id = result.attempt_id,
            .result_ref = result.result,
            .result_digest = try blobDigest(session, result.result),
            .recovery_class = .consequential,
        }),
        session_transition.conversationAdvanced(.{
            .agent = agentContext(session),
            .entry_id = result_entry.entry_id,
            .parent_id = result_entry.parent_id,
            .kind = result_entry.kind,
            .content_ref = visible_ref,
        }),
    };
    try commitCoreFacts(
        session,
        core,
        &applied_facts,
        true,
    );
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
    var blob_writer: ?session_store.BlobWriter = null;
    var existing = session.openBlob(visible_ref) catch |err| switch (err) {
        error.FileNotFound => blk: {
            blob_writer = try session.beginBlob(visible_ref);
            break :blk null;
        },
        else => return err,
    };
    if (existing) |*reader| {
        existing_length = reader.length();
        existing_digest = reader.digest();
        reader.close();
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
        return error.BlobContentMismatch;
    }
}

const VisibleResultTarget = struct {
    writer: ?*session_store.BlobWriter,
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
            var durable = try session.openBlob(durable_ref);
            defer durable.close();
            var durable_header: [bash_tool.result_header_size]u8 = undefined;
            const header_bytes = try durable.readWindow(0, &durable_header);
            if (header_bytes.len != durable_header.len) return error.TruncatedBlob;
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
            try readExactBlob(session, durable_ref, &durable);
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
    reader: *session_store.BlobReader,
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
        if (bytes.len != wanted) return error.TruncatedBlob;
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
    token: session_store.OwnerToken,
    core: *Core,
) !ModelCompletion {
    const operation = try core.reducer.operation();
    const operation_id = operation.id;
    const operation_generation = operation.generation;
    var history: FactSearch = .{
        .operation_id = operation_id,
        .generation = operation_generation,
        .recovery_class = .model,
    };
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    if (history.attempt_count == 0) return error.MissingAcceptedAttempt;
    if (history.result != null) return error.IncompleteModelAdmissionTransaction;
    var accepted: ?session_transition.AttemptRecord = null;
    var matched_envelope: ?completion_inbox.Envelope = null;
    for (history.attemptSlice()) |maybe_attempt| {
        const attempt = maybe_attempt.?;
        var inbox: InboxSearch = .{
            .session_id = session.session_id,
            .agent_id = session.agent_id,
            .operation_id = operation_id,
            .operation_generation = operation_generation,
            .attempt_id = attempt.attempt_id,
            .maximum_epoch = token.epoch,
            .expected_epoch = attempt.operation.agent.ownership_epoch,
            .expected_kind = .model,
        };
        _ = try session.scanCompletionEvidence(&inbox, InboxSearch.apply);
        if (inbox.match) |envelope| {
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
        try blobDigest(session, envelope.result_ref),
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

const FactSearch = struct {
    const max_attempts = session_transition.max_operation_attempts;

    operation_id: u64,
    generation: u32,
    recovery_class: session_transition.RecoveryClass,
    descriptor: ?session_transition.OperationRecord = null,
    attempt: ?session_transition.AttemptRecord = null,
    attempts: [max_attempts]?session_transition.AttemptRecord = @splat(null),
    attempt_count: u8 = 0,
    target_attempt_id: u64 = 0,
    approval_required: ?session_transition.ApprovalRequiredRecord = null,
    authorization: ?session_transition.AuthorizationRecord = null,
    result: ?session_transition.ResultRecord = null,

    fn applyFact(context: *anyopaque, fact: session_transition.Fact) anyerror!void {
        const self: *FactSearch = @ptrCast(@alignCast(context));
        switch (fact) {
            .operation_submitted => |record| {
                if (!self.accepts(record.operation) or !self.acceptsClass(record.recovery_class)) return;
                self.descriptor = try uniqueRecord(
                    session_transition.OperationRecord,
                    self.descriptor,
                    record,
                );
            },
            .attempt_admitted => |record| {
                if (!self.accepts(record.operation) or record.recovery_class != self.recovery_class) return;
                var found = false;
                for (self.attempts[0..self.attempt_count]) |maybe_existing| {
                    const existing = maybe_existing.?;
                    if (existing.attempt_id != record.attempt_id) continue;
                    if (!std.meta.eql(existing, record)) return error.ConflictingLedgerFacts;
                    found = true;
                    break;
                }
                if (!found) {
                    if (self.attempt_count == max_attempts) return error.AttemptCapacityExceeded;
                    self.attempts[self.attempt_count] = record;
                    self.attempt_count += 1;
                }
                if (self.target_attempt_id == 0 or self.target_attempt_id == record.attempt_id) {
                    self.attempt = record;
                }
            },
            .approval_required => |record| {
                if (!self.accepts(record.operation)) return;
                self.approval_required = try uniqueRecord(
                    session_transition.ApprovalRequiredRecord,
                    self.approval_required,
                    record,
                );
            },
            .authorization => |record| {
                if (!self.accepts(record.operation)) return;
                self.authorization = try uniqueRecord(
                    session_transition.AuthorizationRecord,
                    self.authorization,
                    record,
                );
            },
            .result => |record| {
                if (!self.accepts(record.operation) or
                    !self.acceptsClass(resultRecoveryClass(record))) return;
                self.result = try uniqueRecord(
                    session_transition.ResultRecord,
                    self.result,
                    record,
                );
            },
            else => {},
        }
    }

    fn accepts(self: *const FactSearch, operation: session_transition.OperationContext) bool {
        return operation.operation_id == self.operation_id and operation.generation == self.generation;
    }

    fn acceptsClass(self: *const FactSearch, recovery_class: session_transition.RecoveryClass) bool {
        return recovery_class == .none or recovery_class == self.recovery_class;
    }

    fn attemptSlice(self: *const FactSearch) []const ?session_transition.AttemptRecord {
        return self.attempts[0..self.attempt_count];
    }

    fn containsAttempt(self: *const FactSearch, attempt_id: u64) bool {
        for (self.attemptSlice()) |maybe_attempt| {
            if (maybe_attempt.?.attempt_id == attempt_id) return true;
        }
        return false;
    }
};

pub fn pendingApprovalRequired(session: *session_store.Session) !?ApprovalRequired {
    var search: PendingApprovalSearch = .{};
    _ = try session.inspectSemantic(
        &search,
        PendingApprovalSearch.applyFact,
    );
    return search.approval;
}

const PendingApprovalSearch = struct {
    approval: ?ApprovalRequired = null,

    fn applyFact(context: *anyopaque, fact: session_transition.Fact) anyerror!void {
        const self: *PendingApprovalSearch = @ptrCast(@alignCast(context));
        switch (fact) {
            .approval_required => |record| {
                self.approval = .{
                    .kind = if ((record.operation.operation_id >> 62) == 3) .apply_patch else .bash,
                    .operation_id = record.operation.operation_id,
                    .operation_generation = record.operation.generation,
                    .descriptor_digest = record.descriptor_digest,
                    .descriptor_ref = record.descriptor_ref,
                };
            },
            .authorization => |record| if (self.approval) |approval| {
                if (approval.operation_id == record.operation.operation_id and
                    approval.operation_generation == record.operation.generation)
                {
                    self.approval = null;
                }
            },
            .attempt_admitted => |record| if (self.approval) |approval| {
                if (approval.operation_id == record.operation.operation_id and
                    approval.operation_generation == record.operation.generation)
                {
                    self.approval = null;
                }
            },
            .result => |record| if (self.approval) |approval| {
                if (approval.operation_id == record.operation.operation_id and
                    approval.operation_generation == record.operation.generation)
                {
                    self.approval = null;
                }
            },
            else => {},
        }
    }
};

const InboxSearch = struct {
    session_id: u64,
    agent_id: u64,
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
    maximum_epoch: u64,
    expected_epoch: u64,
    expected_kind: completion_inbox.EvidenceKind,
    match: ?completion_inbox.Envelope = null,

    fn apply(context: *anyopaque, envelope: completion_inbox.Envelope) anyerror!void {
        const self: *InboxSearch = @ptrCast(@alignCast(context));
        if (envelope.kind != self.expected_kind) return;
        if (envelope.session_id != self.session_id or envelope.agent_id != self.agent_id or
            envelope.operation_id != self.operation_id or
            envelope.operation_generation != self.operation_generation or
            envelope.attempt_id != self.attempt_id)
        {
            return;
        }
        if (envelope.ownership_epoch > self.maximum_epoch) return error.FutureCompletionEpoch;
        if (envelope.ownership_epoch != self.expected_epoch) {
            return error.CompletionAttemptEpochMismatch;
        }
        if (self.match) |existing| {
            if (!std.meta.eql(existing, envelope)) return error.ConflictingCompletionEvidence;
            return;
        }
        self.match = envelope;
    }
};

fn uniqueRecord(comptime T: type, existing: ?T, candidate: T) !T {
    if (existing) |value| {
        if (!std.meta.eql(value, candidate)) return error.ConflictingLedgerFacts;
        return value;
    }
    return candidate;
}

fn resultRecoveryClass(result: session_transition.ResultRecord) session_transition.RecoveryClass {
    return switch (result.evidence) {
        .immediate => |recovery_class| recovery_class,
        .durable => |evidence| switch (evidence) {
            .model => .model,
            .bash, .apply_patch => .consequential,
        },
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
    var found = false;
    _ = try session.inspectSemantic(&found, detectIndeterminate);
    return found;
}

fn detectIndeterminate(context: *anyopaque, fact: session_transition.Fact) anyerror!void {
    const found: *bool = @ptrCast(@alignCast(context));
    switch (fact) {
        .result => |result| if (result.class == .indeterminate) switch (result.evidence) {
            .durable => |evidence| switch (evidence) {
                .bash => found.* = true,
                else => {},
            },
            .immediate => {},
        },
        else => {},
    }
}

fn finalizeCandidate(
    session: *session_store.Session,
    core: *Core,
    fault: ?FaultHook,
) !u64 {
    const task = try core.reducer.task();
    const response = try core.reducer.response();
    if (task.phase != .final_candidate or response.disposition != .final_answer) {
        return error.FinalAnswerNotCandidate;
    }
    var final_buffer: [model_protocol.max_assistant_text_size]u8 = undefined;
    const expected = try readResponseWindow(session, &core.reducer, response, response.text, &final_buffer);
    if (expected.len == 0) {
        return error.InvalidFinalAnswerRange;
    }
    const response_ref = response.content_ref;
    if (response_ref == 0) return error.InvalidModelResponseReference;
    const final_ref = finalReference(response_ref);

    var final_blob = session.openBlob(final_ref) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try session.storeBlob(final_ref, expected);
            break :blk try session.openBlob(final_ref);
        },
        else => return err,
    };
    defer final_blob.close();
    try expectBlob(&final_blob, expected);
    try reach(fault, .after_final_blob);

    var entry = try session.readEntry(session.activeLeafId());
    if (entry.kind != .assistant_text or entry.content_ref != final_ref) {
        entry = try session.appendConversation(.assistant_text, final_ref, null);
    }
    try reach(fault, .after_assistant_entry);
    try core.reducer.commitFinalAnswer(entry.entry_id);
    const final_facts = [_]session_transition.Fact{
        session_transition.conversationAdvanced(.{
            .agent = agentContext(session),
            .entry_id = entry.entry_id,
            .parent_id = entry.parent_id,
            .kind = entry.kind,
            .content_ref = final_ref,
        }),
        session_transition.outcome(agentContext(session), session.task_id, final_ref),
    };
    try commitCoreFacts(
        session,
        core,
        &final_facts,
        true,
    );
    return final_ref;
}

fn reach(fault: ?FaultHook, boundary: FaultBoundary) !void {
    if (fault) |hook| try hook.reached(hook.context, boundary);
}

fn expectBlob(reader: *session_store.BlobReader, expected: []const u8) !void {
    if (reader.length() != expected.len) return error.FinalAnswerBlobMismatch;
    var window: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < expected.len) {
        const actual = try reader.readWindow(offset, &window);
        if (actual.len == 0 or !std.mem.eql(u8, actual, expected[offset..][0..actual.len])) {
            return error.FinalAnswerBlobMismatch;
        }
        offset += actual.len;
    }
}

fn readExactBlob(
    session: *session_store.Session,
    reference: u64,
    out: []u8,
) !void {
    var reader = try session.openBlob(reference);
    defer reader.close();
    if (reader.length() != out.len) return error.BlobLengthMismatch;
    const bytes = try reader.readWindow(0, out);
    if (bytes.len != out.len) return error.TruncatedBlob;
}

fn readBoundedBlob(
    session: *session_store.Session,
    reference: u64,
    out: []u8,
) ![]const u8 {
    var reader = try session.openBlob(reference);
    defer reader.close();
    if (reader.length() == 0 or reader.length() > out.len) return error.BlobLengthMismatch;
    const bytes = try reader.readWindow(0, out[0..@intCast(reader.length())]);
    if (bytes.len != reader.length()) return error.TruncatedBlob;
    return bytes;
}

fn readResponseWindow(
    session: *session_store.Session,
    core: *const core_image.Core,
    response: core_image.Response,
    window: core_image.ContentWindow,
    out: []u8,
) ![]const u8 {
    if (window.length == 0 or window.length > out.len) return error.InvalidModelResponseWindow;
    const operation = try core.operation();
    var history: FactSearch = .{
        .operation_id = operation.id,
        .generation = operation.generation,
        .recovery_class = .model,
    };
    _ = try session.inspectSemantic(&history, FactSearch.applyFact);
    const committed = history.result orelse return error.MissingModelResult;
    if (committed.result_ref != response.content_ref) return error.ModelResultReferenceMismatch;
    var reader = try session.openBlob(response.content_ref);
    defer reader.close();
    if (reader.length() == 0 or reader.length() > model_protocol.max_response_size) {
        return error.ResponseTooLarge;
    }
    try verifyModelResponse(&reader, committed.result_digest);
    const start: u64 = window.offset;
    const length: u64 = window.length;
    if (start > reader.length() or length > reader.length() - start) {
        return error.InvalidModelResponseWindow;
    }
    const bytes = try reader.readWindow(start, out[0..window.length]);
    if (bytes.len != window.length) return error.TruncatedModelResponse;
    return bytes;
}

fn readAdmittedResponseArguments(
    session: *session_store.Session,
    core: *const core_image.Core,
    response: core_image.Response,
    out: []u8,
) !model_contract.StrictToolJson {
    const bytes = try readResponseWindow(
        session,
        core,
        response,
        response.arguments.contentWindow(),
        out,
    );
    return model_contract.strictToolJsonFromEvidence(bytes, response.arguments.digest);
}

fn readAndVerifyModelResponse(
    reader: *session_store.BlobReader,
    expected_digest: binding.Result,
    out: []u8,
) ![]const u8 {
    if (reader.length() != out.len) return error.TruncatedModelResponse;
    var hasher = binding.Hasher(binding.Result).init();
    var offset: usize = 0;
    while (offset < out.len) {
        const bytes = try reader.readWindow(offset, out[offset..][0..@min(4096, out.len - offset)]);
        if (bytes.len == 0) return error.TruncatedModelResponse;
        hasher.update(bytes);
        offset += bytes.len;
    }
    if (!binding.eql(binding.Result, hasher.final(), expected_digest)) {
        return error.CompletionResultDigestMismatch;
    }
    return out;
}

fn verifyModelResponse(reader: *session_store.BlobReader, expected_digest: binding.Result) !void {
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

test "restored response metadata reads the exact durable content window" {
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
    var session = try session_store.Session.create(sessions, &storage, io, .{
        .workspace_path = repo_path,
        .model = "fixture:window",
        .task = "Recover the final answer window",
    });
    defer session.close();

    const response_ref: u64 = 2001;
    const answer = "the restored window comes from durable response bytes";
    var response_buffer: [model_protocol.max_response_size]u8 = undefined;
    var validation: model_protocol.ValidationScratch = undefined;
    const encoded_response = try model_protocol.encodeText(&response_buffer, answer);
    try session.storeBlob(response_ref, encoded_response);
    const descriptor_ref: u64 = 2000;
    const descriptor_bytes = "restored response test descriptor";
    try session.storeBlob(descriptor_ref, descriptor_bytes);
    const descriptor_digest: binding.Descriptor = .{
        .model = binding.hash(binding.ModelDescriptor, descriptor_bytes),
    };

    var initial_slot: core_image.ActivationSlot = undefined;
    var initial = try core_image.Core.initialize(&initial_slot, .{ .agent_id = session.agent_id, .generation = 1 });
    try initial.startTask(1);
    const operation = try initial.beginModelOperation(2, 1);
    const identity: core_image.OperationIdentity = .{
        .id = operation.id,
        .generation = operation.generation,
    };
    try initial.acceptOperation(identity);
    const ledger_operation = operationContext(&session, operation.id, operation.generation);
    const response_digest = binding.hash(binding.Result, encoded_response);
    _ = try session.commitSemantic(&.{
        session_transition.operationSubmitted(ledger_operation, descriptor_ref, descriptor_digest, .model),
        session_transition.modelAttemptAdmitted(ledger_operation, 9, descriptor_ref, descriptor_digest, 0),
    }, null);
    try session.publishCompletionEvidence(completion_inbox.bind(.{
        .kind = .model,
        .session_id = session.session_id,
        .ownership_epoch = session.ownership_epoch,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = operation.id,
        .operation_generation = operation.generation,
        .attempt_id = 9,
        .result_ref = response_ref,
        .result_digest = response_digest,
    }));
    _ = try session.commitSemantic(&.{session_transition.result(.{
        .operation = ledger_operation,
        .result_ref = response_ref,
        .result_digest = response_digest,
        .class = .ordinary,
        .evidence = .{ .durable = .{ .model = 9 } },
    })}, null);
    _ = try initial.applyModelResponse(
        identity,
        try (try model_protocol.validate(&validation, encoded_response)).admission(encoded_response),
        response_ref,
        response_digest,
    );
    var encoded_state: [core_state.encoded_size]u8 = undefined;
    try initial.suspendInto(&encoded_state);

    var restored_slot: core_image.ActivationSlot = undefined;
    var restored = try core_image.Core.activate(&restored_slot, &encoded_state);
    defer restored.abandon();
    const response = try restored.response();
    var answer_buffer: [model_protocol.max_assistant_text_size]u8 = undefined;
    try std.testing.expectEqualStrings(
        answer,
        try readResponseWindow(&session, &restored, response, response.text, &answer_buffer),
    );

    var blob_path: [64]u8 = undefined;
    const response_path = try std.fmt.bufPrint(&blob_path, "blobs/{x:0>16}.blob", .{response_ref});
    try session.dir.deleteFile(io, response_path);
    const substituted = try model_protocol.encodeText(&response_buffer, "substituted final answer");
    try session.storeBlob(response_ref, substituted);
    try std.testing.expectError(
        error.CompletionResultDigestMismatch,
        readResponseWindow(&session, &restored, response, response.text, &answer_buffer),
    );
}

test "restored tool arguments reject same-reference substitution and oversized blobs" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "sessions", .default_dir);
    var database_path_buffer: [160]u8 = undefined;
    const database_path = try std.fmt.bufPrint(
        &database_path_buffer,
        ".zig-cache/tmp/{s}/tool-window-test.sqlite3",
        .{tmp.sub_path},
    );
    var storage = try host_store.StorageOwner.open(io, database_path, .{});
    defer storage.close();
    var sessions = try tmp.dir.openDir(io, "sessions", .{});
    defer sessions.close(io);
    var session = try session_store.Session.create(sessions, &storage, io, .{
        .workspace_path = ".",
        .model = "fixture:window",
        .task = "Recover tool arguments",
    });
    defer session.close();

    const response_ref: u64 = 3001;
    const descriptor_ref: u64 = 3000;
    const descriptor_bytes = "tool window descriptor";
    try session.storeBlob(descriptor_ref, descriptor_bytes);
    var response_buffer: [model_protocol.max_response_size]u8 = undefined;
    var validation: model_protocol.ValidationScratch = undefined;
    const original = try model_protocol.encodeTool(
        &response_buffer,
        model_contract.bash_key,
        "{\"command\":\"true\",\"timeout_ms\":1000}",
    );
    try session.storeBlob(response_ref, original);

    var slot: core_image.ActivationSlot = undefined;
    var core = try core_image.Core.initialize(&slot, .{ .agent_id = session.agent_id, .generation = 1 });
    defer core.abandon();
    try core.startTask(1);
    const operation = try core.beginModelOperation(3, 1);
    const identity: core_image.OperationIdentity = .{ .id = operation.id, .generation = operation.generation };
    try core.acceptOperation(identity);
    const response_digest = binding.hash(binding.Result, original);
    _ = try core.applyModelResponse(
        identity,
        try (try model_protocol.validate(&validation, original)).admission(original),
        response_ref,
        response_digest,
    );
    const context = operationContext(&session, operation.id, operation.generation);
    const descriptor_digest: binding.Descriptor = .{ .model = binding.hash(binding.ModelDescriptor, descriptor_bytes) };
    _ = try session.commitSemantic(&.{
        session_transition.operationSubmitted(context, descriptor_ref, descriptor_digest, .model),
        session_transition.modelAttemptAdmitted(context, 10, descriptor_ref, descriptor_digest, 0),
    }, null);
    try session.publishCompletionEvidence(completion_inbox.bind(.{
        .kind = .model,
        .session_id = session.session_id,
        .ownership_epoch = session.ownership_epoch,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = operation.id,
        .operation_generation = operation.generation,
        .attempt_id = 10,
        .result_ref = response_ref,
        .result_digest = response_digest,
    }));
    _ = try session.commitSemantic(&.{session_transition.result(.{
        .operation = context,
        .result_ref = response_ref,
        .result_digest = response_digest,
        .class = .ordinary,
        .evidence = .{ .durable = .{ .model = 10 } },
    })}, null);
    const response = try core.response();
    var arguments_buffer: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"command\":\"true\",\"timeout_ms\":1000}",
        (try readAdmittedResponseArguments(&session, &core, response, &arguments_buffer)).bytes(),
    );

    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "blobs/{x:0>16}.blob", .{response_ref});
    try session.dir.deleteFile(io, path);
    const replacement = try model_protocol.encodeTool(
        &response_buffer,
        model_contract.bash_key,
        "{\"command\":\"false\",\"timeout_ms\":1000}",
    );
    try session.storeBlob(response_ref, replacement);
    try std.testing.expectError(
        error.CompletionResultDigestMismatch,
        readAdmittedResponseArguments(&session, &core, response, &arguments_buffer),
    );

    try session.dir.deleteFile(io, path);
    var oversized: [model_protocol.max_response_size + 1]u8 = @splat('x');
    try session.storeBlob(response_ref, &oversized);
    try std.testing.expectError(
        error.ResponseTooLarge,
        readAdmittedResponseArguments(&session, &core, response, &arguments_buffer),
    );
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

    var existing = session.openBlob(reference) catch |err| switch (err) {
        error.FileNotFound => {
            var writer = try session.beginBlob(reference);
            errdefer writer.abort();
            try writer.append(header_bytes);
            try writer.append(key);
            try writer.append(arguments);
            try writer.finish();
            return;
        },
        else => return err,
    };
    defer existing.close();
    if (existing.length() != expected_length or
        !binding.eql(binding.Blob, existing.digest(), hasher.final()))
    {
        return error.BlobContentMismatch;
    }
}

fn storeOrExpectBlob(
    session: *session_store.Session,
    reference: u64,
    bytes: []const u8,
) !void {
    var reader = session.openBlob(reference) catch |err| switch (err) {
        error.FileNotFound => {
            try session.storeBlob(reference, bytes);
            return;
        },
        else => return err,
    };
    defer reader.close();
    if (reader.length() != bytes.len) return error.BlobContentMismatch;
    var window: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const actual = try reader.readWindow(offset, &window);
        if (actual.len == 0 or !std.mem.eql(u8, actual, bytes[offset..][0..actual.len])) {
            return error.BlobContentMismatch;
        }
        offset += actual.len;
    }
}

fn blobDigest(
    session: *session_store.Session,
    reference: u64,
) !binding.Result {
    var reader = try session.openBlob(reference);
    defer reader.close();
    var hasher = binding.Hasher(binding.Result).init();
    var window: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < reader.length()) {
        const bytes = try reader.readWindow(offset, &window);
        if (bytes.len == 0) return error.TruncatedBlob;
        hasher.update(bytes);
        offset += bytes.len;
    }
    return hasher.final();
}

fn allocateOperationIds(io: std.Io, session: *const session_store.Session) !OperationIds {
    for (0..8) |_| {
        var ids: OperationIds = undefined;
        io.random(std.mem.asBytes(&ids));
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

fn modelFailure(value: u32) anyerror {
    return switch (value) {
        1 => error.ModelResponseTruncated,
        2 => error.ModelResponseAborted,
        3 => error.ModelProviderFailed,
        4 => error.MalformedModelResponse,
        5 => error.EmptyModelResponse,
        6 => error.MultipleModelOutputs,
        7 => error.ModelResponseOversized,
        8 => error.UnknownModelTool,
        else => error.UnknownModelFailure,
    };
}

test "generic tool and input dispositions cannot bypass the closed Action mapping" {
    var host: Host = .{};
    var core = try Core.open(&host.slots);
    defer core.close();
    try core.initialize(1);
    try core.reducer.startTask(1);
    const operation = try core.reducer.beginModelOperation(2, 1);
    try core.reducer.acceptOperation(.{ .id = operation.id, .generation = operation.generation });

    var response: [model_protocol.max_response_size]u8 = undefined;
    var validation: model_protocol.ValidationScratch = undefined;
    const fixture_definition: model_contract.ToolDefinition = .{
        .key = "fixture.inspect.v1",
        .provider_tool_name = "fixture_inspect",
        .description = "Inspect a fixture without execution authority.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":64}},\"required\":[\"query\"],\"additionalProperties\":false}",
        .result_contract = "Bounded fixture text.",
    };
    const fixture_catalog = [_]model_contract.ToolDefinition{fixture_definition};
    const arguments = " { \"query\" : \"status\" } ";
    const generic = try model_protocol.encodeTool(&response, fixture_definition.key, arguments);
    const validated = try model_protocol.validateWithCatalog(
        &validation,
        generic,
        &fixture_catalog,
    );
    _ = try core.reducer.applyModelResponse(
        .{ .id = operation.id, .generation = operation.generation },
        try validated.admission(generic),
        3,
        binding.hash(binding.Result, generic),
    );
    try std.testing.expectEqual(core_state.TaskPhase.awaiting_tool, (try core.reducer.task()).phase);
    const admitted = (try validated.admittedToolArguments(generic)).?;
    var call_bytes: [conversation.call_header_size + model_contract.max_tool_key_size + 128]u8 = undefined;
    const call = try conversation.encodeToolCall(&call_bytes, .{
        .key = fixture_definition.key,
        .arguments = admitted.json,
    });
    const decoded_call = try conversation.decodeToolCall(call);
    try std.testing.expectEqualStrings(fixture_definition.key, decoded_call.key);
    try std.testing.expectEqualStrings(arguments, decoded_call.arguments);
    try std.testing.expectError(error.UnboundToolKey, executableToolFromKey(decoded_call.key));

    core.close();
    core = try Core.open(&host.slots);
    try core.initialize(4);
    try core.reducer.startTask(1);
    const input_operation = try core.reducer.beginModelOperation(5, 1);
    try core.reducer.acceptOperation(.{ .id = input_operation.id, .generation = input_operation.generation });
    const input = try model_protocol.encodeInputText(&response, "Which migration should I use?");
    _ = try core.reducer.applyModelResponse(
        .{ .id = input_operation.id, .generation = input_operation.generation },
        try (try model_protocol.validate(&validation, input)).admission(input),
        6,
        binding.hash(binding.Result, input),
    );
    try std.testing.expectEqual(core_state.TaskPhase.failed, (try core.reducer.task()).phase);
    try std.testing.expectError(error.UnboundToolKey, executableToolFromKey(""));
}

test "model dispatch releases Core and rejects substituted request bytes" {
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
    var session = try session_store.Session.create(sessions, &storage, io, .{
        .workspace_path = repo_path,
        .model = "fixture:bound",
        .task = "Check the request binding",
    });
    defer session.close();

    var host: Host = .{};
    const SlotProbeProvider = struct {
        host: *Host,
        observed_released_slot: bool = false,

        fn provider(self: *@This()) model_operation.Provider {
            return .{ .context = self, .dispatch = dispatch };
        }

        fn dispatch(
            context: *anyopaque,
            _: model_operation.RequestCursor,
            response: model_operation.ResponseWriter,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            var lease = try self.host.slots.borrow();
            defer lease.release() catch unreachable;
            self.observed_released_slot = true;
            var bytes: [model_protocol.header_size + "done".len]u8 = undefined;
            try response.append(try model_protocol.encodeText(&bytes, "done"));
            try response.finish();
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

    const request_digest = try model_operation.buildRequest(&session, 1001, 1, 1);
    var request_blob = try session.openBlob(1001);
    const request_length: usize = @intCast(request_blob.length());
    request_blob.close();
    var request: [32 * 1024]u8 = undefined;
    const original = try session.readBlob(1001, 0, request[0..request_length]);
    request[model_operation.request_header_size] ^= 1;
    var blob_path: [32]u8 = undefined;
    const substituted_path = try std.fmt.bufPrint(&blob_path, "blobs/{x:0>16}.blob", .{@as(u64, 1001)});
    try session.dir.deleteFile(io, substituted_path);
    try session.storeBlob(1001, original);

    const CountingProvider = struct {
        calls: u32 = 0,

        fn provider(self: *@This()) model_operation.Provider {
            return .{ .context = self, .dispatch = dispatch };
        }

        fn dispatch(
            context: *anyopaque,
            _: model_operation.RequestCursor,
            _: model_operation.ResponseWriter,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
        }
    };
    var fixture: CountingProvider = .{};
    try std.testing.expectError(
        error.ModelRequestDigestMismatch,
        dispatchModelAttempt(
            &session,
            session.ownerToken(),
            fixture.provider(),
            .{
                .request_ref = 1001,
                .request_digest = request_digest,
                .response_ref = 1002,
                .operation_id = 1003,
                .operation_generation = 1,
                .attempt_id = 1004,
            },
            null,
            null,
        ),
    );
    try std.testing.expectEqual(@as(u32, 0), fixture.calls);
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
    var host: Host = .{};
    const HostFour = HostWithCapacity(4);
    try std.testing.expectEqual(@as(usize, 256_416), semantic_validation_workspace_size);
    try std.testing.expectEqual(@as(usize, 256_440), @sizeOf(SemanticValidationWorkspacePool));
    try std.testing.expectEqual(@as(usize, 16_384), @sizeOf(PatchWorkspace));
    try std.testing.expectEqual(@as(usize, 16_408), @sizeOf(PatchWorkspacePool));
    try std.testing.expectEqual(@as(usize, 281_224), @sizeOf(Host));
    try std.testing.expectEqual(@as(usize, 306_328), @sizeOf(HostFour));
    try std.testing.expectEqual(@as(usize, 8_360), @sizeOf(core_image.ActivationSlot));
    try std.testing.expectEqual(
        @sizeOf(SemanticValidationWorkspacePool),
        @sizeOf(@TypeOf(host.semantic_validation)),
    );
    try std.testing.expectEqual(
        @sizeOf(SemanticValidationWorkspacePool),
        @sizeOf(@TypeOf(@as(HostFour, .{}).semantic_validation)),
    );
    try std.testing.expectEqual(
        @sizeOf(PatchWorkspacePool),
        @sizeOf(@TypeOf(host.patch_workspace)),
    );
    try std.testing.expectEqual(
        @sizeOf(ProductionSlotPool),
        @offsetOf(Host, "semantic_validation"),
    );
    var lease = try host.semantic_validation.borrow();
    @memset(std.mem.asBytes(lease.workspace), 0xa5);
    try std.testing.expectError(error.SemanticValidationWorkspaceBusy, host.semantic_validation.borrow());
    try lease.release();
    var reused = try host.semantic_validation.borrow();
    defer reused.release() catch unreachable;
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(reused.workspace), 0));
}

test "Host resource ledger measures each fixed scratch stage" {
    var host: Host = .{};
    const initial = host.resourceLedger();
    try std.testing.expectEqual(@as(usize, 1), initial.semantic_validation.multiplier);
    try std.testing.expectEqual(@as(usize, model_protocol.max_response_size), initial.semantic_validation.response_bytes);
    try std.testing.expectEqual(@sizeOf(model_operation.ToolDefinitionBuffer), initial.semantic_validation.tool_definition_bytes);
    try std.testing.expectEqual(@sizeOf(model_protocol.ValidationScratch), initial.semantic_validation.validation_scratch_bytes);
    try std.testing.expectEqual(@as(usize, 256_416), initial.semantic_validation.workspace_bytes);
    try std.testing.expectEqual(@as(usize, 24), initial.semantic_validation.pool_overhead_bytes);
    try std.testing.expectEqual(@as(usize, 256_440), initial.semantic_validation.reservation_bytes);
    try std.testing.expectEqual(@as(usize, 0), initial.semantic_validation.occupied_count);
    try std.testing.expectEqual(@as(usize, 0), initial.semantic_validation.occupied_high_water_count);
    try std.testing.expectEqual(@as(u64, 0), initial.semantic_validation.acquisition_count);
    try std.testing.expectEqual(@as(u64, 0), initial.semantic_validation.busy_count);
    try std.testing.expectEqual(@as(usize, 0), initial.semantic_validation.queue_depth);
    try std.testing.expectEqual(@as(u64, 0), initial.semantic_validation.wait_time_ns);
    try std.testing.expectEqual(@as(usize, 1), initial.patch_workspace.multiplier);
    try std.testing.expectEqual(@as(usize, patch_tool.max_patch_size), initial.patch_workspace.patch_bytes);
    try std.testing.expectEqual(@as(usize, 16_384), initial.patch_workspace.workspace_bytes);
    try std.testing.expectEqual(@as(usize, 24), initial.patch_workspace.pool_overhead_bytes);
    try std.testing.expectEqual(@as(usize, 16_408), initial.patch_workspace.reservation_bytes);
    try std.testing.expectEqual(@as(usize, 0), initial.patch_workspace.queue_depth);
    try std.testing.expectEqual(@as(u64, 0), initial.patch_workspace.wait_time_ns);

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

    host.semantic_validation.busy_count = std.math.maxInt(u64);
    var held = try host.semantic_validation.borrow();
    defer held.release() catch unreachable;
    try std.testing.expectError(error.SemanticValidationWorkspaceBusy, host.semantic_validation.borrow());
    try std.testing.expectEqual(std.math.maxInt(u64), host.resourceLedger().semantic_validation.busy_count);

    host.patch_workspace.generation = std.math.maxInt(u64);
    try std.testing.expectError(error.PatchWorkspaceBusy, host.patch_workspace.borrow());
    const bounded = host.resourceLedger().patch_workspace;
    try std.testing.expectEqual(std.math.maxInt(u64), bounded.acquisition_count);
    try std.testing.expectEqual(@as(u64, 2), bounded.busy_count);
}

test "shared patch workspace contends fail-fast without retaining semantic validation" {
    var host: Host = .{};
    var patch = try host.patch_workspace.borrow();
    defer patch.release() catch unreachable;
    patch.workspace.patch[0] = 0xa5;

    var validation = try host.semantic_validation.borrow();
    try std.testing.expect(host.patch_workspace.occupied);
    try validation.release();
    try std.testing.expectEqual(@as(u8, 0xa5), patch.workspace.patch[0]);
    try std.testing.expectError(
        error.PatchWorkspaceBusy,
        host.patch_workspace.borrow(),
    );
    const contention = host.resourceLedger().patch_workspace;
    try std.testing.expectEqual(@as(u64, 1), contention.busy_count);
    try std.testing.expectEqual(@as(usize, 0), contention.queue_depth);
    try std.testing.expectEqual(@as(u64, 0), contention.wait_time_ns);
}

test "stale copied semantic validation lease cannot scrub a new borrower" {
    var host: Host = .{};
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
    var host: Host = .{};
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

test "Completion Inbox search never crosses evidence kinds" {
    var search: InboxSearch = .{
        .session_id = 1,
        .agent_id = 2,
        .operation_id = 3,
        .operation_generation = 1,
        .attempt_id = 4,
        .maximum_epoch = 5,
        .expected_epoch = 5,
        .expected_kind = .apply_patch,
    };
    const wrong = completion_inbox.bind(.{
        .kind = .bash,
        .session_id = 1,
        .ownership_epoch = 5,
        .agent_id = 2,
        .agent_generation = agent_generation,
        .operation_id = 3,
        .operation_generation = 1,
        .attempt_id = 4,
        .result_ref = 6,
        .result_digest = binding.hash(binding.Result, "result"),
    });
    try InboxSearch.apply(&search, wrong);
    try std.testing.expect(search.match == null);
}

test "Completion Inbox search binds evidence to the admitted Attempt epoch" {
    var search: InboxSearch = .{
        .session_id = 1,
        .agent_id = 2,
        .operation_id = 3,
        .operation_generation = 1,
        .attempt_id = 4,
        .maximum_epoch = 6,
        .expected_epoch = 5,
        .expected_kind = .model,
    };
    const rebound = completion_inbox.bind(.{
        .kind = .model,
        .session_id = 1,
        .ownership_epoch = 6,
        .agent_id = 2,
        .agent_generation = agent_generation,
        .operation_id = 3,
        .operation_generation = 1,
        .attempt_id = 4,
        .result_ref = 6,
        .result_digest = binding.hash(binding.Result, "result"),
    });
    try std.testing.expectError(
        error.CompletionAttemptEpochMismatch,
        InboxSearch.apply(&search, rebound),
    );
    try std.testing.expect(search.match == null);
}
