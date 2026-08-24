const std = @import("std");
const checkpoint = @import("checkpoint.zig");
const durable_transition = @import("durable_transition.zig");
const harness = @import("harness.zig");
const jsc = @import("jsc_runtime.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");
const operation_log = @import("operation_log.zig");
const session_store = @import("session.zig");

const agent_generation: u32 = 1;
const response_memory_offset: u32 = 8 * 1024;

pub const NewConfig = struct {
    workspace_path: []const u8,
    model: []const u8,
    task: []const u8,
    fault: ?FaultHook = null,
};

pub const FaultBoundary = enum {
    after_completion_persist,
    after_final_blob,
    after_assistant_entry,
};

pub const FaultHook = struct {
    context: *anyopaque,
    reached: *const fn (*anyopaque, FaultBoundary) anyerror!void,
};

pub const Observer = struct {
    context: *anyopaque,
    session_created: *const fn (*anyopaque, u64) anyerror!void,
};

pub const Completed = struct {
    session: session_store.Session,
    final_ref: u64,

    pub fn close(self: *Completed) void {
        self.session.close();
    }
};

const OperationIds = struct {
    operation_id: u32,
    attempt_id: u64,
    request_ref: u64,
    response_ref: u32,
    final_ref: u64,
};

fn finalReference(response_ref: u32) u64 {
    return (@as(u64, 1) << 63) | response_ref;
}

const Core = struct {
    runtime: jsc.Runtime,
    allocator: std.mem.Allocator,
    initialize: jsc.JSObjectRef,
    deliver: jsc.JSObjectRef,
    agent_id: jsc.JSObjectRef,
    event_count: jsc.JSObjectRef,
    accumulator: jsc.JSObjectRef,
    is_quiescent: jsc.JSObjectRef,
    submit: jsc.JSObjectRef,
    start_task: jsc.JSObjectRef,
    begin_model: jsc.JSObjectRef,
    accept: jsc.JSObjectRef,
    complete: jsc.JSObjectRef,
    interpret: jsc.JSObjectRef,
    commit_final: jsc.JSObjectRef,
    operation_state: jsc.JSObjectRef,
    operation_id: jsc.JSObjectRef,
    operation_generation: jsc.JSObjectRef,
    operation_result: jsc.JSObjectRef,
    context_first: jsc.JSObjectRef,
    context_count: jsc.JSObjectRef,
    response_disposition: jsc.JSObjectRef,
    response_failure: jsc.JSObjectRef,
    response_text_offset: jsc.JSObjectRef,
    response_text_length: jsc.JSObjectRef,
    task_outcome: jsc.JSObjectRef,
    final_entry_id: jsc.JSObjectRef,

    fn open(allocator: std.mem.Allocator, wasm: []const u8) !Core {
        var runtime = try jsc.Runtime.open();
        errdefer runtime.close();
        try runtime.instantiate(allocator, wasm);
        var core: Core = .{
            .runtime = runtime,
            .allocator = allocator,
            .initialize = try runtime.function(allocator, "__onepage.instance.exports.initialize"),
            .deliver = try runtime.function(allocator, "__onepage.instance.exports.deliver"),
            .agent_id = try runtime.function(allocator, "__onepage.instance.exports.agentId"),
            .event_count = try runtime.function(allocator, "__onepage.instance.exports.eventCount"),
            .accumulator = try runtime.function(allocator, "__onepage.instance.exports.accumulator"),
            .is_quiescent = try runtime.function(allocator, "__onepage.instance.exports.isQuiescent"),
            .submit = try runtime.function(allocator, "__onepage.instance.exports.submitOperation"),
            .start_task = try runtime.function(allocator, "__onepage.instance.exports.startTask"),
            .begin_model = try runtime.function(allocator, "__onepage.instance.exports.beginModelOperation"),
            .accept = try runtime.function(allocator, "__onepage.instance.exports.acceptOperation"),
            .complete = try runtime.function(allocator, "__onepage.instance.exports.completeOperation"),
            .interpret = try runtime.function(allocator, "__onepage.instance.exports.interpretModelResponse"),
            .commit_final = try runtime.function(allocator, "__onepage.instance.exports.commitFinalAnswer"),
            .operation_state = try runtime.function(allocator, "__onepage.instance.exports.operationState"),
            .operation_id = try runtime.function(allocator, "__onepage.instance.exports.operationId"),
            .operation_generation = try runtime.function(allocator, "__onepage.instance.exports.operationGeneration"),
            .operation_result = try runtime.function(allocator, "__onepage.instance.exports.operationResult"),
            .context_first = try runtime.function(allocator, "__onepage.instance.exports.contextFirst"),
            .context_count = try runtime.function(allocator, "__onepage.instance.exports.contextCount"),
            .response_disposition = try runtime.function(allocator, "__onepage.instance.exports.responseDisposition"),
            .response_failure = try runtime.function(allocator, "__onepage.instance.exports.responseFailure"),
            .response_text_offset = try runtime.function(allocator, "__onepage.instance.exports.responseTextOffset"),
            .response_text_length = try runtime.function(allocator, "__onepage.instance.exports.responseTextLength"),
            .task_outcome = try runtime.function(allocator, "__onepage.instance.exports.taskOutcome"),
            .final_entry_id = try runtime.function(allocator, "__onepage.instance.exports.finalEntryId"),
        };
        try core.validateAbi();
        return core;
    }

    fn close(self: *Core) void {
        self.runtime.close();
    }

    fn call(self: *Core, function: jsc.JSObjectRef, arguments: []const u32) !void {
        if (try self.runtime.callNumber(function, arguments) != 1) return error.CoreTransitionRejected;
    }

    fn callVoid(self: *Core, function: jsc.JSObjectRef, arguments: []const u32) !void {
        try self.runtime.callNumbers(function, arguments);
    }

    fn value(self: *Core, function: jsc.JSObjectRef) !u32 {
        return self.runtime.callNumber(function, &.{});
    }

    fn validateAbi(self: *Core) !void {
        try self.callVoid(self.initialize, &.{7});
        if (try self.value(self.agent_id) != 7 or
            try self.value(self.event_count) != 0 or
            try self.value(self.accumulator) != 7 or
            try self.value(self.is_quiescent) != 1 or
            try self.value(self.operation_state) != 0 or
            try self.value(self.task_outcome) != 0)
        {
            return error.CoreAbiMismatch;
        }
        try self.call(self.deliver, &.{29});
        if (try self.value(self.event_count) != 1 or
            try self.value(self.accumulator) != ((7 * 16_777_619) ^ 29) or
            try self.value(self.is_quiescent) != 1)
        {
            return error.CoreAbiMismatch;
        }
        try self.call(self.submit, &.{ 3, 1 });
        if (try self.value(self.operation_id) != 3 or
            try self.value(self.operation_generation) != 1 or
            try self.value(self.operation_state) != 1)
        {
            return error.CoreAbiMismatch;
        }
        try self.call(self.accept, &.{ 3, 1 });
        try self.call(self.complete, &.{ 3, 1, 5 });
        if (try self.value(self.operation_result) != 5 or
            try self.value(self.operation_state) != 3)
        {
            return error.CoreAbiMismatch;
        }
        try self.callVoid(self.initialize, &.{7});
        try self.call(self.start_task, &.{7});
        try self.call(self.begin_model, &.{ 11, 2 });
        if (try self.value(self.operation_id) != 11 or
            try self.value(self.operation_generation) != 1 or
            try self.value(self.context_first) != 1 or
            try self.value(self.context_count) != 7 or
            try self.value(self.task_outcome) != 2)
        {
            return error.CoreAbiMismatch;
        }
        try self.call(self.accept, &.{ 11, 1 });
        try self.call(self.complete, &.{ 11, 1, 17 });
        var encoded_buffer: [model_protocol.header_size + model_protocol.item_header_size + 2]u8 = undefined;
        const encoded = try model_protocol.encodeText(&encoded_buffer, .complete, "ok");
        const memory = try self.runtime.memory(self.allocator);
        @memcpy(memory[response_memory_offset..][0..encoded.len], encoded);
        try self.call(self.interpret, &.{ response_memory_offset, @intCast(encoded.len), 17 });
        if (try self.value(self.response_disposition) != @intFromEnum(model_protocol.Disposition.final_answer) or
            try self.value(self.response_failure) != 0 or
            try self.value(self.response_text_offset) != response_memory_offset + model_protocol.header_size + model_protocol.item_header_size or
            try self.value(self.response_text_length) != 2 or
            try self.value(self.task_outcome) != 3)
        {
            return error.CoreAbiMismatch;
        }
        try self.call(self.commit_final, &.{8});
        if (try self.value(self.task_outcome) != 5 or try self.value(self.final_entry_id) != 8) {
            return error.CoreAbiMismatch;
        }
    }
};

const ModelSlot = struct {
    core: *Core,
    session: *session_store.Session,
    token: session_store.OwnerToken,

    fn inspect(
        context: *anyopaque,
        completion: harness.Completion,
    ) anyerror!durable_transition.SlotState {
        const self: *ModelSlot = @ptrCast(@alignCast(context));
        if (try self.core.value(self.core.operation_id) != completion.operation_id or
            try self.core.value(self.core.operation_generation) != completion.operation_generation)
        {
            return error.CoreOperationMismatch;
        }
        return switch (try self.core.value(self.core.operation_state)) {
            2 => .accepted,
            3 => blk: {
                if (try self.core.value(self.core.operation_result) != completion.result) {
                    return error.CoreResultMismatch;
                }
                break :blk .completed;
            },
            else => error.InvalidCoreOperationState,
        };
    }

    fn apply(context: *anyopaque, completion: harness.Completion) anyerror!void {
        const self: *ModelSlot = @ptrCast(@alignCast(context));
        try self.core.call(self.core.complete, &.{
            @intCast(completion.operation_id),
            completion.operation_generation,
            @intCast(completion.result),
        });
        var response = try self.session.openBlob(self.token, completion.result);
        defer response.close();
        if (response.length() > model_protocol.max_response_size) return error.ResponseTooLarge;
        const memory = try self.core.runtime.memory(self.core.allocator);
        const length: usize = @intCast(response.length());
        const bytes = try response.readWindow(
            0,
            memory[response_memory_offset .. response_memory_offset + length],
        );
        if (bytes.len != length) return error.TruncatedModelResponse;
        try self.core.call(self.core.interpret, &.{
            response_memory_offset,
            @intCast(length),
            @intCast(completion.result),
        });
    }

    fn interface(self: *ModelSlot) durable_transition.Slot {
        return .{ .context = self, .inspect = inspect, .apply = apply };
    }
};

const PersistFault = struct {
    hook: FaultHook,

    fn afterPersist(context: *anyopaque) anyerror!void {
        const self: *PersistFault = @ptrCast(@alignCast(context));
        try self.hook.reached(self.hook.context, .after_completion_persist);
    }
};

pub fn runNew(
    sessions: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    wasm: []const u8,
    config: NewConfig,
    provider: model_operation.Provider,
    observer: ?Observer,
) !Completed {
    // Resolve the complete product ABI before publishing a Session identity or
    // creating any durable state.
    var core = try Core.open(allocator, wasm);
    var core_open = true;
    defer if (core_open) core.close();
    var session = try session_store.Session.create(sessions, io, .{
        .workspace_path = config.workspace_path,
        .model = config.model,
        .task = config.task,
    });
    errdefer session.close();
    if (observer) |value| try value.session_created(value.context, session.session_id);
    const token = session.ownerToken();
    const ids = try allocateOperationIds(io, &session);

    try core.callVoid(core.initialize, &.{1});
    try core.call(core.start_task, &.{@intCast(session.active_leaf_id)});
    try core.call(core.begin_model, &.{ ids.operation_id, 1 });
    const first = try core.value(core.context_first);
    const count = try core.value(core.context_count);
    const descriptor = try model_operation.buildRequest(
        &session,
        token,
        ids.request_ref,
        first,
        count,
    );
    var journal = try session.openOperationJournal(token);
    defer journal.close(io);
    try journal.appendDurable(io, .{
        .kind = .accepted,
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = ids.operation_id,
        .operation_generation = 1,
        .attempt_id = ids.attempt_id,
        .ownership_epoch = token.epoch,
        .recovery_class = .billable_retry,
        .sequence = 1,
        .descriptor_digest = descriptor.digest,
        .result = 0,
    });
    try core.call(core.accept, &.{ ids.operation_id, 1 });

    const checkpoint_buffer = try allocator.alloc(u8, checkpoint.encoded_size);
    defer allocator.free(checkpoint_buffer);
    try session.publishCheckpoint(
        token,
        agent_generation,
        checkpoint_buffer,
        try core.runtime.memory(allocator),
    );
    core.close();
    core_open = false;

    var provider_io = try model_operation.ProviderIo.open(
        &session,
        token,
        descriptor.request_ref,
        ids.response_ref,
    );
    defer provider_io.close();
    try provider.dispatch(
        provider.context,
        provider_io.requestCapability(),
        provider_io.responseCapability(),
    );
    try provider_io.ensureResponsePublished();

    core = try Core.open(allocator, wasm);
    core_open = true;
    try session.restoreCheckpoint(
        token,
        agent_generation,
        checkpoint_buffer,
        try core.runtime.memory(allocator),
    );
    var slot: ModelSlot = .{ .core = &core, .session = &session, .token = token };
    var persist_fault: PersistFault = undefined;
    if (config.fault) |fault| persist_fault = .{ .hook = fault };
    var adapter: durable_transition.Adapter = .{
        .io = io,
        .dir = session.dir,
        .journal_path = "operations.log",
        .writer = &journal,
        .ownership_epoch = token.epoch,
        .slot = slot.interface(),
        .fault = if (config.fault != null) .{
            .context = &persist_fault,
            .after_persist = PersistFault.afterPersist,
        } else null,
    };
    var owner = try harness.Harness.open(.{
        .input_capacity = 1,
        .drive_quantum = 1,
        .transition = adapter.transition(),
        .owner_fence = session.fence(),
    });
    try expectQueued(owner.offer(.{ .completion = .{
        .agent_id = session.agent_id,
        .operation_id = ids.operation_id,
        .ownership_epoch = token.epoch,
        .result = ids.response_ref,
        .agent_generation = agent_generation,
        .operation_generation = 1,
    } }));
    _ = try owner.drive();

    const disposition = try core.value(core.response_disposition);
    if (disposition == @intFromEnum(model_protocol.Disposition.tool_call)) {
        return error.ToolCallDeferred;
    }
    if (disposition != @intFromEnum(model_protocol.Disposition.final_answer)) {
        return modelFailure(try core.value(core.response_failure));
    }
    const final_ref = try finalizeCandidate(
        &session,
        token,
        &core,
        checkpoint_buffer,
        config.fault,
    );
    return .{ .session = session, .final_ref = final_ref };
}

pub fn resumeSession(
    sessions: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    wasm: []const u8,
    session_id: u64,
) !Completed {
    // Reject an incompatible artifact without taking ownership or advancing the
    // durable Session epoch.
    var core = try Core.open(allocator, wasm);
    defer core.close();
    var manifest_buffer: [session_store.manifest_max_size]u8 = undefined;
    var restored = try session_store.Session.openExisting(
        sessions,
        io,
        session_id,
        &manifest_buffer,
    );
    errdefer restored.session.close();
    const token = restored.session.ownerToken();
    const checkpoint_buffer = try allocator.alloc(u8, checkpoint.encoded_size);
    defer allocator.free(checkpoint_buffer);
    try restored.session.restoreCheckpoint(
        token,
        agent_generation,
        checkpoint_buffer,
        try core.runtime.memory(allocator),
    );
    var outcome = try core.value(core.task_outcome);
    if (outcome == 2) {
        const completion = try durableCompletion(&restored.session, token, &core);
        var slot: ModelSlot = .{ .core = &core, .session = &restored.session, .token = token };
        try ModelSlot.apply(&slot, completion);
        outcome = try core.value(core.task_outcome);
    }
    if (outcome == 3) {
        const final_ref = try finalizeCandidate(
            &restored.session,
            token,
            &core,
            checkpoint_buffer,
            null,
        );
        return .{ .session = restored.session, .final_ref = final_ref };
    }
    if (outcome == 4) return error.ToolCallDeferred;
    if (outcome == 6) return modelFailure(try core.value(core.response_failure));
    if (outcome != 5) return error.SessionNotFinished;
    const entry_id = try core.value(core.final_entry_id);
    if (entry_id != restored.session.active_leaf_id) return error.FinalEntryMismatch;
    const entry = try restored.session.readEntry(entry_id);
    if (entry.kind != .assistant) return error.InvalidFinalEntry;
    return .{ .session = restored.session, .final_ref = entry.content_ref };
}

fn durableCompletion(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
) !harness.Completion {
    const operation_id = try core.value(core.operation_id);
    const operation_generation = try core.value(core.operation_generation);
    var reader = try session.openOperationReader(token);
    defer reader.close(session.io);
    var accepted: ?operation_log.Record = null;
    var completed: ?operation_log.Record = null;
    while (try reader.next(session.io)) |record| {
        if (record.agent_id != session.agent_id or
            record.agent_generation != agent_generation or
            record.operation_id != operation_id or
            record.operation_generation != operation_generation)
        {
            continue;
        }
        switch (record.kind) {
            .accepted => {
                if (accepted != null) return error.InvalidOperationHistory;
                accepted = record;
            },
            .completed => {
                if (completed != null) return error.InvalidOperationHistory;
                completed = record;
            },
        }
    }
    const intent = accepted orelse return error.MissingAcceptedAttempt;
    const result = completed orelse return error.SessionOperationPending;
    if (result.attempt_id != intent.attempt_id or
        result.ownership_epoch != intent.ownership_epoch or
        result.recovery_class != intent.recovery_class or
        result.descriptor_digest != intent.descriptor_digest or
        result.sequence <= intent.sequence or result.result == 0)
    {
        return error.InvalidOperationHistory;
    }
    return .{
        .agent_id = session.agent_id,
        .agent_generation = agent_generation,
        .operation_id = operation_id,
        .operation_generation = operation_generation,
        .ownership_epoch = intent.ownership_epoch,
        .result = result.result,
    };
}

fn finalizeCandidate(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    core: *Core,
    checkpoint_buffer: []u8,
    fault: ?FaultHook,
) !u64 {
    if (try core.value(core.task_outcome) != 3 or
        try core.value(core.response_disposition) != @intFromEnum(model_protocol.Disposition.final_answer))
    {
        return error.FinalAnswerNotCandidate;
    }
    const text_offset = try core.value(core.response_text_offset);
    const text_length = try core.value(core.response_text_length);
    const memory = try core.runtime.memory(core.allocator);
    if (text_length == 0 or text_offset > memory.len or text_length > memory.len - text_offset) {
        return error.InvalidFinalAnswerRange;
    }
    const expected = memory[text_offset..][0..text_length];
    const response_ref = try core.value(core.operation_result);
    if (response_ref == 0) return error.InvalidModelResponseReference;
    const final_ref = finalReference(response_ref);

    var final_blob = session.openBlob(token, final_ref) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try session.storeBlob(token, final_ref, expected);
            break :blk try session.openBlob(token, final_ref);
        },
        else => return err,
    };
    defer final_blob.close();
    try expectBlob(&final_blob, expected);
    try reach(fault, .after_final_blob);

    var entry = try session.readEntry(session.active_leaf_id);
    if (entry.kind != .assistant or entry.content_ref != final_ref) {
        entry = try session.appendConversation(token, .assistant, final_ref, null);
    }
    try reach(fault, .after_assistant_entry);
    try core.call(core.commit_final, &.{@intCast(entry.entry_id)});
    try session.publishCheckpoint(token, agent_generation, checkpoint_buffer, memory);
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

fn expectQueued(result: harness.OfferResult) !void {
    if (result != .queued) return error.CompletionAdmissionFailed;
}

fn modelFailure(value: u32) anyerror {
    return switch (value) {
        1 => error.ModelResponseTruncated,
        2 => error.ModelResponseAborted,
        3 => error.ModelProviderFailed,
        4 => error.MalformedModelResponse,
        5 => error.EmptyModelResponse,
        6 => error.MultipleModelTools,
        else => error.UnknownModelFailure,
    };
}
