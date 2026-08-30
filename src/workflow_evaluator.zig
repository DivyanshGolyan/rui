const std = @import("std");
const qjs = @import("quickjs_c.zig").c;
const protocol = @import("workflow_protocol.zig");

const Visible = struct {
    key: []const u8,
    tag: protocol.VisibleTag,
    payload: []const u8,
};

const Request = struct {
    key: []const u8,
    descriptor: []const u8,
    pending: bool,
};

const EntryBudget = struct {
    used: usize = 0,

    fn add(self: *EntryBudget, count: usize) !void {
        self.used = std.math.add(usize, self.used, count) catch
            return error.ExcessiveEntries;
        if (self.used > protocol.Limits.data_entries) return error.ExcessiveEntries;
    }
};

const Evaluation = struct {
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    arguments: []const u8,
    visible: [protocol.Limits.pending_jobs]Visible = undefined,
    visible_count: usize = 0,
    requests: [protocol.Limits.pending_jobs]Request = undefined,
    request_count: usize = 0,
    descriptor_scratch: []u8,
    object_prototype: qjs.JSValue,
    array_prototype: qjs.JSValue,
    object_class: qjs.JSClassID = 0,
    array_class: qjs.JSClassID = 0,
    job_request_invalid: bool = false,
    import_attempted: bool = false,
    resource_code: ?[]const u8 = null,
    unhandled_rejections: usize = 0,
    microtasks: usize = 0,
    deadline_ns: i128,
    cpu_deadline_ns: i128,

    fn parse(allocator: std.mem.Allocator, input: []const u8) !*Evaluation {
        if (input.len > protocol.Limits.input_frame_bytes) return error.ExcessiveBytes;
        var cursor = protocol.Cursor.init(input);
        try protocol.readHeader(&cursor, protocol.request_magic);

        const key_storage = try allocator.alloc([]const u8, protocol.Limits.data_entries);

        const source_bytes = try cursor.readString(protocol.Limits.source_bytes);
        const source = try allocator.allocSentinel(u8, source_bytes.len, 0);
        @memcpy(source, source_bytes);

        const arguments = try cursor.skipValueExact(protocol.Limits.arguments_bytes, key_storage);
        const visible_count = try cursor.readInt(u16);
        if (visible_count > protocol.Limits.pending_jobs) return error.ExcessiveEntries;

        const state = try allocator.create(Evaluation);
        state.* = .{
            .allocator = allocator,
            .source = source,
            .arguments = arguments,
            .descriptor_scratch = try allocator.alloc(u8, protocol.Limits.workflow_output_bytes),
            .object_prototype = undefined,
            .array_prototype = undefined,
            .deadline_ns = monotonicNanoseconds() +
                @as(i128, protocol.Limits.wall_milliseconds) * std.time.ns_per_ms,
            .cpu_deadline_ns = processCpuNanoseconds() +|
                @as(i128, protocol.Limits.cpu_milliseconds) * std.time.ns_per_ms,
        };

        var visible_output_bytes: usize = 0;
        for (0..visible_count) |_| {
            const key = try cursor.readString(512);
            if (key.len == 0) return error.InvalidTag;
            for (state.visible[0..state.visible_count]) |existing| {
                if (std.mem.eql(u8, existing.key, key)) return error.DuplicateKey;
            }
            const tag = std.enums.fromInt(protocol.VisibleTag, try cursor.readByte()) orelse
                return error.InvalidTag;
            const payload = switch (tag) {
                .output => output: {
                    const remaining = protocol.Limits.visible_output_bytes - visible_output_bytes;
                    const value = try cursor.skipValueExact(
                        remaining,
                        key_storage,
                    );
                    visible_output_bytes += value.len;
                    break :output value;
                },
                .failure => failure: {
                    const code = try cursor.readString(256);
                    if (!isJobFailureCode(code)) return error.InvalidTag;
                    break :failure code;
                },
            };
            state.visible[state.visible_count] = .{ .key = key, .tag = tag, .payload = payload };
            state.visible_count += 1;
        }
        try cursor.finish();
        return state;
    }

    fn visibleFor(self: *const Evaluation, key: []const u8) ?Visible {
        for (self.visible[0..self.visible_count]) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry;
        }
        return null;
    }

    fn existingRequest(self: *Evaluation, key: []const u8) ?*Request {
        for (self.requests[0..self.request_count]) |*request| {
            if (std.mem.eql(u8, request.key, key)) return request;
        }
        return null;
    }
};

pub fn evaluate(input: []const u8, output_storage: []u8, bridge_storage: []u8) []const u8 {
    var builder = protocol.Builder.init(output_storage);
    protocol.writeHeader(&builder, protocol.outcome_magic) catch return &.{};

    if (bridge_storage.len > protocol.Limits.bridge_arena_bytes) {
        return writeSimpleOutcome(&builder, .protocol_failed, "BridgeArenaInvalid");
    }
    var arena = std.heap.FixedBufferAllocator.init(bridge_storage);
    const allocator = arena.allocator();
    const state = Evaluation.parse(allocator, input) catch |err| {
        return switch (err) {
            error.OutOfMemory => writeSimpleOutcome(&builder, .resource_exceeded, "BridgeArena"),
            else => writeSimpleOutcome(&builder, .protocol_failed, @errorName(err)),
        };
    };
    return evaluateParsed(state, &builder);
}

fn evaluateParsed(state: *Evaluation, builder: *protocol.Builder) []const u8 {
    const runtime = qjs.JS_NewRuntime() orelse
        return writeSimpleOutcome(builder, .resource_exceeded, "EngineRuntime");
    defer qjs.JS_FreeRuntime(runtime);
    qjs.JS_SetMemoryLimit(runtime, protocol.Limits.engine_heap_bytes);
    qjs.JS_SetMaxStackSize(runtime, protocol.Limits.engine_stack_bytes);
    qjs.JS_SetCanBlock(runtime, false);
    qjs.JS_SetInterruptHandler(runtime, interruptHandler, state);
    qjs.JS_SetHostPromiseRejectionTracker(runtime, promiseRejectionTracker, state);
    qjs.JS_SetModuleLoaderFunc(runtime, rejectImport, null, state);

    const context = qjs.JS_NewContextRaw(runtime) orelse
        return writeSimpleOutcome(builder, .resource_exceeded, "EngineContext");
    defer qjs.JS_FreeContext(context);
    qjs.JS_SetContextOpaque(context, state);
    if (qjs.JS_AddIntrinsicBaseObjects(context) < 0 or
        qjs.JS_AddIntrinsicEval(context) < 0 or
        qjs.JS_AddIntrinsicPromise(context) < 0)
    {
        discardException(context);
        return writeSimpleOutcome(builder, .resource_exceeded, "RealmIntrinsics");
    }

    if (!captureAllowedPrototypes(context, state)) {
        return writeSimpleOutcome(builder, .resource_exceeded, "RealmSetup");
    }
    defer qjs.JS_FreeValue(context, state.object_prototype);
    defer qjs.JS_FreeValue(context, state.array_prototype);

    if (!hardenRealm(context)) {
        return writeSimpleOutcome(builder, .protocol_failed, "RealmHardeningFailed");
    }

    const compiled = qjs.JS_Eval(
        context,
        state.source.ptr,
        state.source.len,
        "onepage:workflow",
        qjs.JS_EVAL_TYPE_MODULE | qjs.JS_EVAL_FLAG_COMPILE_ONLY,
    );
    if (qjs.JS_IsException(compiled)) {
        discardException(context);
        if (state.import_attempted) return writeSimpleOutcome(builder, .protocol_failed, "ImportsDisabled");
        return writeSimpleOutcome(builder, .failed, "WorkflowDefinitionInvalid");
    }
    defer qjs.JS_FreeValue(context, compiled);
    if (!qjs.JS_IsModule(compiled)) {
        return writeSimpleOutcome(builder, .protocol_failed, "CompiledValueNotModule");
    }

    const module = qjs.onepage_quickjs_module(compiled);
    const module_result = qjs.JS_EvalFunction(context, qjs.JS_DupValue(context, compiled));
    if (qjs.JS_IsException(module_result)) {
        discardException(context);
        return classifyFailure(state, builder, "WorkflowDefinitionInvalid");
    }
    defer qjs.JS_FreeValue(context, module_result);
    if (!drainJobs(runtime, state)) return classifyFailure(state, builder, "ModuleEvaluationFailed");
    if (state.import_attempted) return writeSimpleOutcome(builder, .protocol_failed, "ImportsDisabled");

    if (qjs.JS_IsPromise(module_result)) {
        switch (qjs.JS_PromiseState(context, module_result)) {
            qjs.JS_PROMISE_REJECTED => {
                qjs.JS_PromiseMarkAsHandled(context, module_result);
                return writeSimpleOutcome(builder, .failed, "WorkflowDefinitionInvalid");
            },
            qjs.JS_PROMISE_PENDING => return writeSimpleOutcome(builder, .deadlocked, "ModulePending"),
            else => {},
        }
    }

    const namespace = qjs.JS_GetModuleNamespace(context, module);
    if (qjs.JS_IsException(namespace)) {
        discardException(context);
        return writeSimpleOutcome(builder, .failed, "WorkflowDefinitionInvalid");
    }
    defer qjs.JS_FreeValue(context, namespace);
    const workflow = qjs.JS_GetPropertyStr(context, namespace, "default");
    if (qjs.JS_IsException(workflow)) {
        discardException(context);
        return writeSimpleOutcome(builder, .failed, "WorkflowDefinitionInvalid");
    }
    defer qjs.JS_FreeValue(context, workflow);
    if (!qjs.JS_IsFunction(context, workflow) or !qjs.JS_IsAsyncFunction(workflow)) {
        return writeSimpleOutcome(builder, .failed, "WorkflowDefaultMustBeAsyncFunction");
    }

    const agent = qjs.JS_NewCFunction(context, agentCall, "agent", 1);
    if (qjs.JS_IsException(agent)) return writeSimpleOutcome(builder, .resource_exceeded, "AgentCapability");
    defer qjs.JS_FreeValue(context, agent);
    if (qjs.JS_FreezeObject(context, agent) < 0) {
        discardException(context);
        return writeSimpleOutcome(builder, .resource_exceeded, "AgentCapability");
    }
    const capability = qjs.JS_NewObjectProto(context, qjs.onepage_quickjs_null());
    if (qjs.JS_IsException(capability)) return writeSimpleOutcome(builder, .resource_exceeded, "AgentCapability");
    defer qjs.JS_FreeValue(context, capability);
    if (qjs.JS_SetPropertyStr(context, capability, "agent", qjs.JS_DupValue(context, agent)) < 0 or
        qjs.JS_FreezeObject(context, capability) < 0)
    {
        discardException(context);
        return writeSimpleOutcome(builder, .resource_exceeded, "AgentCapability");
    }

    var argument_cursor = protocol.Cursor.init(state.arguments);
    const arguments = decodeData(context, &argument_cursor, 0) catch |err| {
        discardException(context);
        return switch (err) {
            error.OutOfMemory => writeSimpleOutcome(
                builder,
                .resource_exceeded,
                "EngineMemoryOrStack",
            ),
            else => writeSimpleOutcome(builder, .protocol_failed, "ArgumentsInvalid"),
        };
    };
    defer qjs.JS_FreeValue(context, arguments);
    argument_cursor.finish() catch return writeSimpleOutcome(builder, .protocol_failed, "ArgumentsTrailingBytes");
    deepFreeze(context, arguments, 0) catch {
        discardException(context);
        return writeSimpleOutcome(builder, .resource_exceeded, "ArgumentsFreeze");
    };

    var call_arguments = [_]qjs.JSValue{ capability, arguments };
    const root = qjs.JS_Call(context, workflow, qjs.onepage_quickjs_undefined(), call_arguments.len, &call_arguments);
    if (qjs.JS_IsException(root)) {
        discardException(context);
        return classifyFailure(state, builder, "WorkflowCallFailed");
    }
    defer qjs.JS_FreeValue(context, root);
    if (!qjs.JS_IsPromise(root)) return writeSimpleOutcome(builder, .failed, "WorkflowDefaultMustReturnPromise");
    if (!drainJobs(runtime, state)) return classifyFailure(state, builder, "WorkflowJobFailed");
    if (state.import_attempted) return writeSimpleOutcome(builder, .protocol_failed, "ImportsDisabled");
    if (state.job_request_invalid) return classifyFailure(state, builder, "WorkflowFailed");

    if (qjs.JS_PromiseState(context, root) == qjs.JS_PROMISE_REJECTED) {
        qjs.JS_PromiseMarkAsHandled(context, root);
        if (state.resource_code) |code| return writeSimpleOutcome(builder, .resource_exceeded, code);
        const reason = qjs.JS_PromiseResult(context, root);
        defer qjs.JS_FreeValue(context, reason);
        if (isEngineResourceError(context, reason)) {
            return writeSimpleOutcome(builder, .resource_exceeded, "EngineMemoryOrStack");
        }
        return writeSimpleOutcome(builder, .failed, "WorkflowRejected");
    }
    if (state.unhandled_rejections != 0) return writeSimpleOutcome(builder, .failed, "UnhandledRejection");

    var pending_requests: usize = 0;
    for (state.requests[0..state.request_count]) |request| {
        if (request.pending) pending_requests += 1;
    }

    switch (qjs.JS_PromiseState(context, root)) {
        qjs.JS_PROMISE_FULFILLED => {
            if (pending_requests != 0) return writeBlocked(builder, state);
            const result = qjs.JS_PromiseResult(context, root);
            defer qjs.JS_FreeValue(context, result);
            builder.writeByte(@intFromEnum(protocol.OutcomeTag.completed)) catch return &.{};
            var output_budget = EntryBudget{};
            encodeData(context, state, builder, result, 0, &.{}, &output_budget) catch |err| {
                return switch (err) {
                    error.ExcessiveBytes => rewriteSimpleOutcome(
                        builder,
                        .resource_exceeded,
                        "WorkflowOutputBytes",
                    ),
                    error.OutOfMemory, error.EnumerationFailed, error.StringConversion => rewriteSimpleOutcome(
                        builder,
                        .resource_exceeded,
                        "EngineMemoryOrStack",
                    ),
                    else => rewriteSimpleOutcome(builder, .failed, "WorkflowOutputInvalid"),
                };
            };
            if (builder.index > protocol.Limits.workflow_output_bytes + 7) {
                return rewriteSimpleOutcome(builder, .resource_exceeded, "WorkflowOutputBytes");
            }
            return builder.written();
        },
        qjs.JS_PROMISE_REJECTED => unreachable,
        qjs.JS_PROMISE_PENDING => {
            if (pending_requests != 0) return writeBlocked(builder, state);
            return writeSimpleOutcome(builder, .deadlocked, "RootPendingWithoutJobs");
        },
        else => return writeSimpleOutcome(builder, .protocol_failed, "RootNotPromise"),
    }
}

fn classifyFailure(state: *const Evaluation, builder: *protocol.Builder, fallback: []const u8) []const u8 {
    if (state.resource_code) |code| return writeSimpleOutcome(builder, .resource_exceeded, code);
    if (state.job_request_invalid) return writeSimpleOutcome(builder, .failed, "JobRequestInvalid");
    return writeSimpleOutcome(builder, .failed, fallback);
}

fn writeBlocked(builder: *protocol.Builder, state: *const Evaluation) []const u8 {
    builder.writeByte(@intFromEnum(protocol.OutcomeTag.blocked)) catch return &.{};
    var count: u16 = 0;
    for (state.requests[0..state.request_count]) |request| if (request.pending) {
        count += 1;
    };
    builder.writeInt(u16, count) catch return &.{};
    for (state.requests[0..state.request_count]) |request| if (request.pending) {
        builder.writeLengthBytes(request.descriptor) catch
            return rewriteSimpleOutcome(builder, .resource_exceeded, "BlockedSetBytes");
    };
    return builder.written();
}

fn writeSimpleOutcome(builder: *protocol.Builder, tag: protocol.OutcomeTag, code: []const u8) []const u8 {
    builder.writeByte(@intFromEnum(tag)) catch return &.{};
    builder.writeString(code) catch return &.{};
    return builder.written();
}

fn rewriteSimpleOutcome(builder: *protocol.Builder, tag: protocol.OutcomeTag, code: []const u8) []const u8 {
    builder.index = 6;
    return writeSimpleOutcome(builder, tag, code);
}

fn captureAllowedPrototypes(context: *qjs.JSContext, state: *Evaluation) bool {
    const object = qjs.JS_NewObject(context);
    if (qjs.JS_IsException(object)) return false;
    defer qjs.JS_FreeValue(context, object);
    state.object_prototype = qjs.JS_GetPrototype(context, object);
    if (qjs.JS_IsException(state.object_prototype)) return false;
    state.object_class = qjs.JS_GetClassID(object);

    const array = qjs.JS_NewArray(context);
    if (qjs.JS_IsException(array)) return false;
    defer qjs.JS_FreeValue(context, array);
    state.array_prototype = qjs.JS_GetPrototype(context, array);
    state.array_class = qjs.JS_GetClassID(array);
    return !qjs.JS_IsException(state.array_prototype);
}

fn hardenRealm(context: *qjs.JSContext) bool {
    const bootstrap =
        \\(() => {
        \\  'use strict';
        \\  const functionValues = [
        \\    function(){},
        \\    async function(){},
        \\    function*(){},
        \\    async function*(){},
        \\  ];
        \\  for (const functionValue of functionValues) {
        \\    const prototype = Object.getPrototypeOf(functionValue);
        \\    Object.defineProperty(prototype, 'constructor', {
        \\      value: undefined,
        \\      writable: false,
        \\      enumerable: false,
        \\      configurable: false,
        \\    });
        \\    Object.freeze(prototype);
        \\  }
        \\  delete globalThis.eval;
        \\  delete globalThis.Function;
        \\  delete globalThis.queueMicrotask;
        \\  delete Math.random;
        \\  delete Promise.race;
        \\  delete Promise.any;
        \\  Object.freeze(Math);
        \\  Object.freeze(Promise);
        \\  Object.freeze(Promise.prototype);
        \\})();
    ;
    const result = qjs.JS_Eval(
        context,
        bootstrap,
        bootstrap.len,
        "onepage:bootstrap",
        qjs.JS_EVAL_TYPE_GLOBAL | qjs.JS_EVAL_FLAG_STRICT,
    );
    if (qjs.JS_IsException(result)) {
        discardException(context);
        return false;
    }
    qjs.JS_FreeValue(context, result);
    return true;
}

fn rejectImport(
    context: ?*qjs.JSContext,
    _: [*c]const u8,
    _: [*c]const u8,
    opaque_ptr: ?*anyopaque,
) callconv(.c) [*c]u8 {
    const state: *Evaluation = @ptrCast(@alignCast(opaque_ptr.?));
    state.import_attempted = true;
    _ = qjs.JS_ThrowReferenceError(context.?, "imports are disabled");
    return null;
}

fn interruptHandler(_: ?*qjs.JSRuntime, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    const state: *Evaluation = @ptrCast(@alignCast(opaque_ptr.?));
    if (processCpuNanoseconds() >= state.cpu_deadline_ns) {
        state.resource_code = "CpuTime";
        return 1;
    }
    if (monotonicNanoseconds() >= state.deadline_ns) {
        state.resource_code = "WallTime";
        return 1;
    }
    return 0;
}

fn promiseRejectionTracker(
    _: ?*qjs.JSContext,
    _: qjs.JSValueConst,
    _: qjs.JSValueConst,
    handled: bool,
    opaque_ptr: ?*anyopaque,
) callconv(.c) void {
    const state: *Evaluation = @ptrCast(@alignCast(opaque_ptr.?));
    if (handled) {
        state.unhandled_rejections -|= 1;
    } else {
        state.unhandled_rejections += 1;
    }
}

fn drainJobs(runtime: *qjs.JSRuntime, state: *Evaluation) bool {
    while (qjs.JS_IsJobPending(runtime)) {
        if (state.microtasks == protocol.Limits.microtasks) {
            state.resource_code = "Microtasks";
            return false;
        }
        state.microtasks += 1;
        var job_context: ?*qjs.JSContext = null;
        if (qjs.JS_ExecutePendingJob(runtime, &job_context) < 0) {
            if (job_context) |context| discardException(context);
            return false;
        }
    }
    return true;
}

fn agentCall(
    context: ?*qjs.JSContext,
    _: qjs.JSValueConst,
    argc: c_int,
    argv: [*c]qjs.JSValueConst,
) callconv(.c) qjs.JSValue {
    const ctx = context.?;
    const state: *Evaluation = @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx).?));
    if (argc != 1) return failAgent(ctx, state, "agent expects one descriptor");

    var builder = protocol.Builder.init(state.descriptor_scratch);
    const key = encodeAgentDescriptor(ctx, state, &builder, argv[0]) catch |err| {
        return switch (err) {
            error.ExcessiveBytes, error.ExcessiveDepth, error.ExcessiveEntries, error.OutOfMemory => resource: {
                state.resource_code = "AgentDescriptor";
                break :resource qjs.JS_ThrowRangeError(ctx, "agent descriptor resource limit exceeded");
            },
            else => failAgent(ctx, state, "invalid agent descriptor"),
        };
    };
    const descriptor = builder.written();

    if (state.existingRequest(key)) |existing| {
        if (!std.mem.eql(u8, existing.descriptor, descriptor)) {
            return failAgent(ctx, state, "job key has conflicting descriptor");
        }
        return promiseForVisible(ctx, state, key, existing.pending);
    }
    if (state.request_count == protocol.Limits.pending_jobs) {
        state.resource_code = "PendingJobs";
        return qjs.JS_ThrowRangeError(ctx, "pending job limit exceeded");
    }

    const stored = state.allocator.dupe(u8, descriptor) catch {
        state.resource_code = "BridgeArena";
        return qjs.JS_ThrowOutOfMemory(ctx);
    };
    var stored_cursor = protocol.Cursor.init(stored);
    const stored_key = descriptorKey(&stored_cursor) catch {
        return failAgent(ctx, state, "invalid canonical agent descriptor");
    };
    const pending = state.visibleFor(stored_key) == null;
    state.requests[state.request_count] = .{
        .key = stored_key,
        .descriptor = stored,
        .pending = pending,
    };
    state.request_count += 1;
    return promiseForVisible(ctx, state, stored_key, pending);
}

fn promiseForVisible(context: *qjs.JSContext, state: *Evaluation, key: []const u8, pending: bool) qjs.JSValue {
    if (pending) {
        var resolvers: [2]qjs.JSValue = undefined;
        const promise = qjs.JS_NewPromiseCapability(context, &resolvers);
        if (!qjs.JS_IsException(promise)) {
            qjs.JS_FreeValue(context, resolvers[0]);
            qjs.JS_FreeValue(context, resolvers[1]);
        }
        return promise;
    }
    const visible = state.visibleFor(key).?;
    return switch (visible.tag) {
        .output => output: {
            var cursor = protocol.Cursor.init(visible.payload);
            const value = decodeData(context, &cursor, 0) catch {
                state.resource_code = "EngineMemoryOrStack";
                return qjs.JS_ThrowOutOfMemory(context);
            };
            cursor.finish() catch {
                qjs.JS_FreeValue(context, value);
                state.resource_code = "EngineMemoryOrStack";
                return qjs.JS_ThrowOutOfMemory(context);
            };
            deepFreeze(context, value, 0) catch {
                qjs.JS_FreeValue(context, value);
                state.resource_code = "EngineMemoryOrStack";
                return qjs.JS_ThrowOutOfMemory(context);
            };
            defer qjs.JS_FreeValue(context, value);
            break :output qjs.JS_NewSettledPromise(context, false, value);
        },
        .failure => failure: {
            const value = makeJobError(context, key, visible.payload);
            if (qjs.JS_IsException(value)) return value;
            defer qjs.JS_FreeValue(context, value);
            break :failure qjs.JS_NewSettledPromise(context, true, value);
        },
    };
}

fn makeJobError(context: *qjs.JSContext, key: []const u8, code: []const u8) qjs.JSValue {
    const value = qjs.JS_NewObject(context);
    if (qjs.JS_IsException(value)) return value;
    if (!setStringProperty(context, value, "code", code) or
        !setStringProperty(context, value, "job_key", key) or
        !setStringProperty(context, value, "message", "job did not complete successfully") or
        qjs.JS_FreezeObject(context, value) < 0)
    {
        qjs.JS_FreeValue(context, value);
        return qjs.onepage_quickjs_exception();
    }
    return value;
}

fn setStringProperty(
    context: *qjs.JSContext,
    object: qjs.JSValueConst,
    name: [*:0]const u8,
    bytes: []const u8,
) bool {
    const value = qjs.JS_NewStringLen(context, bytes.ptr, bytes.len);
    if (qjs.JS_IsException(value)) return false;
    return qjs.JS_SetPropertyStr(context, object, name, value) >= 0;
}

fn failAgent(context: *qjs.JSContext, state: *Evaluation, message: [*:0]const u8) qjs.JSValue {
    state.job_request_invalid = true;
    return qjs.JS_ThrowTypeError(context, message);
}

const AgentFields = struct {
    key: qjs.JSValue,
    task: qjs.JSValue,
    input: qjs.JSValue,
    schema: qjs.JSValue,
    agent_profile: qjs.JSValue,
    key_present: bool = false,
    task_present: bool = false,
    input_present: bool = false,
    schema_present: bool = false,
    agent_profile_present: bool = false,

    fn deinit(self: *AgentFields, context: *qjs.JSContext) void {
        qjs.JS_FreeValue(context, self.key);
        qjs.JS_FreeValue(context, self.task);
        qjs.JS_FreeValue(context, self.input);
        qjs.JS_FreeValue(context, self.schema);
        qjs.JS_FreeValue(context, self.agent_profile);
    }
};

fn encodeAgentDescriptor(
    context: *qjs.JSContext,
    state: *Evaluation,
    builder: *protocol.Builder,
    value: qjs.JSValueConst,
) ![]const u8 {
    if (!isPlainObject(context, state, value)) return error.UnsupportedObject;
    var fields = AgentFields{
        .key = qjs.onepage_quickjs_undefined(),
        .task = qjs.onepage_quickjs_undefined(),
        .input = qjs.onepage_quickjs_undefined(),
        .schema = qjs.onepage_quickjs_undefined(),
        .agent_profile = qjs.onepage_quickjs_undefined(),
    };
    defer fields.deinit(context);

    var table: [*c]qjs.JSPropertyEnum = null;
    var count: u32 = 0;
    if (qjs.JS_GetOwnPropertyNames(
        context,
        &table,
        &count,
        value,
        qjs.JS_GPN_STRING_MASK | qjs.JS_GPN_SYMBOL_MASK,
    ) < 0) return error.EnumerationFailed;
    defer qjs.JS_FreePropertyEnum(context, table, count);
    if (count > 5) return error.UnknownField;

    for (table[0..count]) |entry| {
        const field = try atomField(context, entry.atom);
        var descriptor: qjs.JSPropertyDescriptor = undefined;
        const property_present = qjs.JS_GetOwnProperty(context, &descriptor, value, entry.atom);
        if (property_present < 0) return error.OutOfMemory;
        if (property_present != 1) return error.PropertyMissing;
        defer freeDescriptor(context, &descriptor);
        if (descriptor.flags & qjs.JS_PROP_GETSET != 0) return error.AccessorRejected;
        const destination: *qjs.JSValue, const present: *bool = switch (field) {
            .key => .{ &fields.key, &fields.key_present },
            .task => .{ &fields.task, &fields.task_present },
            .input => .{ &fields.input, &fields.input_present },
            .schema => .{ &fields.schema, &fields.schema_present },
            .agent_profile => .{ &fields.agent_profile, &fields.agent_profile_present },
        };
        if (present.*) return error.DuplicateField;
        present.* = true;
        destination.* = qjs.JS_DupValue(context, descriptor.value);
    }
    if (!fields.key_present or !fields.task_present or
        !qjs.JS_IsString(fields.key) or !qjs.JS_IsString(fields.task)) return error.MissingField;

    try builder.writeByte(@intFromEnum(protocol.DataTag.object));
    var field_count: u32 = 3;
    if (fields.input_present) field_count += 1;
    if (fields.schema_present) field_count += 1;
    var entry_budget = EntryBudget{};
    try entry_budget.add(field_count);
    try builder.writeInt(u32, field_count);

    try builder.writeString("key");
    const key_start = builder.index;
    try encodeData(context, state, builder, fields.key, 0, &.{}, &entry_budget);
    var key_cursor = protocol.Cursor.init(builder.bytes[key_start..builder.index]);
    if (try key_cursor.readByte() != @intFromEnum(protocol.DataTag.string)) return error.InvalidKey;
    const key = try key_cursor.readString(512);
    if (key.len == 0 or scalarCount(key) > 128) return error.InvalidKey;

    try builder.writeString("task");
    const task_start = builder.index;
    try encodeData(context, state, builder, fields.task, 0, &.{}, &entry_budget);
    var task_cursor = protocol.Cursor.init(builder.bytes[task_start..builder.index]);
    if (try task_cursor.readByte() != @intFromEnum(protocol.DataTag.string)) return error.InvalidTask;
    if ((try task_cursor.readString(32 * 1024)).len == 0) return error.InvalidTask;

    if (fields.input_present) {
        try builder.writeString("input");
        try encodeData(context, state, builder, fields.input, 0, &.{}, &entry_budget);
    }
    if (fields.schema_present) {
        try builder.writeString("schema");
        try encodeData(context, state, builder, fields.schema, 0, &.{}, &entry_budget);
    }
    try builder.writeString("agent_profile");
    if (!fields.agent_profile_present) {
        try builder.writeByte(@intFromEnum(protocol.DataTag.string));
        try builder.writeString("default");
    } else {
        if (!qjs.JS_IsString(fields.agent_profile)) return error.InvalidProfile;
        const profile_start = builder.index;
        try encodeData(
            context,
            state,
            builder,
            fields.agent_profile,
            0,
            &.{},
            &entry_budget,
        );
        var profile_cursor = protocol.Cursor.init(builder.bytes[profile_start..builder.index]);
        if (try profile_cursor.readByte() != @intFromEnum(protocol.DataTag.string) or
            !std.mem.eql(u8, try profile_cursor.readString(64), "default")) return error.InvalidProfile;
    }
    return key;
}

fn descriptorKey(cursor: *protocol.Cursor) ![]const u8 {
    if (try cursor.readByte() != @intFromEnum(protocol.DataTag.object)) return error.InvalidDescriptor;
    if (try cursor.readInt(u32) < 2) return error.InvalidDescriptor;
    if (!std.mem.eql(u8, try cursor.readString(32), "key")) return error.InvalidDescriptor;
    if (try cursor.readByte() != @intFromEnum(protocol.DataTag.string)) return error.InvalidDescriptor;
    return cursor.readString(512);
}

fn decodeData(
    context: *qjs.JSContext,
    cursor: *protocol.Cursor,
    depth: usize,
) !qjs.JSValue {
    if (depth > protocol.Limits.data_depth) return error.ExcessiveDepth;
    const tag = std.enums.fromInt(protocol.DataTag, try cursor.readByte()) orelse return error.InvalidTag;
    return switch (tag) {
        .null_value => qjs.onepage_quickjs_null(),
        .false_value => qjs.onepage_quickjs_false(),
        .true_value => qjs.onepage_quickjs_true(),
        .number => number: {
            var value: f64 = @bitCast(try cursor.readInt(u64));
            try protocol.validateNumber(value);
            if (value == 0) value = 0;
            break :number qjs.JS_NewFloat64(context, value);
        },
        .string => string: {
            const bytes = try cursor.readString(protocol.Limits.output_frame_bytes);
            const value = qjs.JS_NewStringLen(context, bytes.ptr, bytes.len);
            if (qjs.JS_IsException(value)) return error.OutOfMemory;
            break :string value;
        },
        .array => array: {
            const count = try cursor.readInt(u32);
            const result = qjs.JS_NewArray(context);
            if (qjs.JS_IsException(result)) return error.OutOfMemory;
            errdefer qjs.JS_FreeValue(context, result);
            for (0..count) |index| {
                const item = try decodeData(context, cursor, depth + 1);
                if (qjs.JS_SetPropertyUint32(context, result, @intCast(index), item) < 0) return error.OutOfMemory;
            }
            break :array result;
        },
        .object => object: {
            const count = try cursor.readInt(u32);
            const result = qjs.JS_NewObject(context);
            if (qjs.JS_IsException(result)) return error.OutOfMemory;
            errdefer qjs.JS_FreeValue(context, result);
            for (0..count) |_| {
                const key = try cursor.readString(protocol.Limits.output_frame_bytes);
                const item = try decodeData(context, cursor, depth + 1);
                const atom = qjs.JS_NewAtomLen(context, key.ptr, key.len);
                if (atom == qjs.JS_ATOM_NULL) {
                    qjs.JS_FreeValue(context, item);
                    return error.OutOfMemory;
                }
                defer qjs.JS_FreeAtom(context, atom);
                var existing: qjs.JSPropertyDescriptor = undefined;
                const present = qjs.JS_GetOwnProperty(context, &existing, result, atom);
                if (present < 0) {
                    qjs.JS_FreeValue(context, item);
                    return error.OutOfMemory;
                }
                if (present == 1) {
                    freeDescriptor(context, &existing);
                    qjs.JS_FreeValue(context, item);
                    return error.DuplicateKey;
                }
                if (qjs.JS_DefinePropertyValue(
                    context,
                    result,
                    atom,
                    item,
                    qjs.JS_PROP_C_W_E,
                ) < 0) return error.OutOfMemory;
            }
            break :object result;
        },
    };
}

fn encodeData(
    context: *qjs.JSContext,
    state: *Evaluation,
    builder: *protocol.Builder,
    value: qjs.JSValueConst,
    depth: usize,
    ancestors: []const qjs.JSValueConst,
    budget: *EntryBudget,
) anyerror!void {
    if (depth > protocol.Limits.data_depth) return error.ExcessiveDepth;
    if (qjs.JS_IsNull(value)) return builder.writeByte(@intFromEnum(protocol.DataTag.null_value));
    if (qjs.JS_IsBool(value)) {
        return builder.writeByte(if (qjs.JS_ToBool(context, value) == 1)
            @intFromEnum(protocol.DataTag.true_value)
        else
            @intFromEnum(protocol.DataTag.false_value));
    }
    if (qjs.JS_IsNumber(value)) {
        var number: f64 = undefined;
        if (qjs.JS_ToFloat64(context, &number, value) < 0) return error.InvalidNumber;
        try protocol.validateNumber(number);
        if (number == 0) number = 0;
        try builder.writeByte(@intFromEnum(protocol.DataTag.number));
        return builder.writeInt(u64, @bitCast(number));
    }
    if (qjs.JS_IsString(value)) return encodeString(context, builder, value);
    if (!qjs.JS_IsObject(value) or qjs.JS_IsProxy(value)) return error.UnsupportedValue;
    for (ancestors) |ancestor| if (qjs.JS_IsStrictEqual(context, ancestor, value)) return error.Cycle;
    var next_ancestors: [protocol.Limits.data_depth + 1]qjs.JSValueConst = undefined;
    @memcpy(next_ancestors[0..ancestors.len], ancestors);
    next_ancestors[ancestors.len] = value;
    const chain = next_ancestors[0 .. ancestors.len + 1];

    if (qjs.JS_IsArray(value)) {
        if (qjs.JS_GetClassID(value) != state.array_class) return error.UnsupportedClass;
        if (!hasExactPrototype(context, value, state.array_prototype)) return error.UnsupportedPrototype;
        return encodeArray(context, state, builder, value, depth, chain, budget);
    }
    if (!isPlainObject(context, state, value)) return error.UnsupportedPrototype;
    return encodeObject(context, state, builder, value, depth, chain, budget);
}

fn encodeString(context: *qjs.JSContext, builder: *protocol.Builder, value: qjs.JSValueConst) !void {
    try builder.writeByte(@intFromEnum(protocol.DataTag.string));
    return encodeStringPayload(context, builder, value);
}

fn encodeStringPayload(context: *qjs.JSContext, builder: *protocol.Builder, value: qjs.JSValueConst) !void {
    var length: usize = 0;
    const units = qjs.JS_ToCStringLenUTF16(context, &length, value) orelse return error.StringConversion;
    defer qjs.JS_FreeCStringUTF16(context, units);
    const length_index = builder.index;
    try builder.writeInt(u32, 0);
    const start = builder.index;
    var index: usize = 0;
    while (index < length) {
        const first = units[index];
        var codepoint: u21 = undefined;
        if (first >= 0xD800 and first <= 0xDBFF) {
            if (index + 1 == length) return error.LoneSurrogate;
            const second = units[index + 1];
            if (second < 0xDC00 or second > 0xDFFF) return error.LoneSurrogate;
            codepoint = @intCast(0x10000 + ((@as(u32, first) - 0xD800) << 10) + (@as(u32, second) - 0xDC00));
            index += 2;
        } else if (first >= 0xDC00 and first <= 0xDFFF) {
            return error.LoneSurrogate;
        } else {
            codepoint = @intCast(first);
            index += 1;
        }
        var encoded: [4]u8 = undefined;
        const encoded_length = try std.unicode.utf8Encode(codepoint, &encoded);
        try builder.writeBytes(encoded[0..encoded_length]);
    }
    const byte_length = builder.index - start;
    if (byte_length > std.math.maxInt(u32)) return error.ExcessiveBytes;
    std.mem.writeInt(u32, builder.bytes[length_index..][0..4], @intCast(byte_length), .little);
}

fn encodeArray(
    context: *qjs.JSContext,
    state: *Evaluation,
    builder: *protocol.Builder,
    value: qjs.JSValueConst,
    depth: usize,
    ancestors: []const qjs.JSValueConst,
    budget: *EntryBudget,
) anyerror!void {
    var length: i64 = 0;
    if (qjs.JS_GetLength(context, value, &length) < 0 or length < 0 or length > protocol.Limits.data_entries) {
        return error.ExcessiveEntries;
    }
    try budget.add(@intCast(length));
    var table: [*c]qjs.JSPropertyEnum = null;
    var count: u32 = 0;
    if (qjs.JS_GetOwnPropertyNames(context, &table, &count, value, qjs.JS_GPN_STRING_MASK | qjs.JS_GPN_SYMBOL_MASK) < 0) {
        return error.EnumerationFailed;
    }
    defer qjs.JS_FreePropertyEnum(context, table, count);
    if (count != @as(u32, @intCast(length)) + 1) return error.SparseOrExtendedArray;

    try builder.writeByte(@intFromEnum(protocol.DataTag.array));
    try builder.writeInt(u32, @intCast(length));
    for (0..@as(usize, @intCast(length))) |index| {
        const atom = qjs.JS_NewAtomUInt32(context, @intCast(index));
        if (atom == qjs.JS_ATOM_NULL) return error.OutOfMemory;
        defer qjs.JS_FreeAtom(context, atom);
        var descriptor: qjs.JSPropertyDescriptor = undefined;
        const present = qjs.JS_GetOwnProperty(context, &descriptor, value, atom);
        if (present < 0) return error.OutOfMemory;
        if (present != 1) return error.SparseArray;
        defer freeDescriptor(context, &descriptor);
        if (descriptor.flags & qjs.JS_PROP_GETSET != 0) return error.AccessorRejected;
        try encodeData(context, state, builder, descriptor.value, depth + 1, ancestors, budget);
    }
}

fn encodeObject(
    context: *qjs.JSContext,
    state: *Evaluation,
    builder: *protocol.Builder,
    value: qjs.JSValueConst,
    depth: usize,
    ancestors: []const qjs.JSValueConst,
    budget: *EntryBudget,
) anyerror!void {
    var table: [*c]qjs.JSPropertyEnum = null;
    var count: u32 = 0;
    if (qjs.JS_GetOwnPropertyNames(context, &table, &count, value, qjs.JS_GPN_STRING_MASK | qjs.JS_GPN_SYMBOL_MASK) < 0) {
        return error.EnumerationFailed;
    }
    defer qjs.JS_FreePropertyEnum(context, table, count);
    try budget.add(count);
    try canonicalizePropertyOrder(context, table[0..count]);
    try builder.writeByte(@intFromEnum(protocol.DataTag.object));
    try builder.writeInt(u32, count);
    for (table[0..count]) |entry| {
        const name_value = qjs.JS_AtomToValue(context, entry.atom);
        if (qjs.JS_IsException(name_value)) return error.StringConversion;
        defer qjs.JS_FreeValue(context, name_value);
        if (!qjs.JS_IsString(name_value)) return error.SymbolKey;
        try encodeStringPayload(context, builder, name_value);

        var descriptor: qjs.JSPropertyDescriptor = undefined;
        const present = qjs.JS_GetOwnProperty(context, &descriptor, value, entry.atom);
        if (present < 0) return error.OutOfMemory;
        if (present != 1) return error.PropertyMissing;
        defer freeDescriptor(context, &descriptor);
        if (descriptor.flags & qjs.JS_PROP_GETSET != 0) return error.AccessorRejected;
        try encodeData(context, state, builder, descriptor.value, depth + 1, ancestors, budget);
    }
}

fn canonicalizePropertyOrder(
    context: *qjs.JSContext,
    entries: []qjs.JSPropertyEnum,
) !void {
    if (entries.len < 2) return;

    var start = entries.len / 2;
    while (start != 0) {
        start -= 1;
        try siftPropertyHeap(context, entries, start, entries.len);
    }
    var end = entries.len;
    while (end > 1) {
        end -= 1;
        std.mem.swap(qjs.JSPropertyEnum, &entries[0], &entries[end]);
        try siftPropertyHeap(context, entries, 0, end);
    }
}

fn siftPropertyHeap(
    context: *qjs.JSContext,
    entries: []qjs.JSPropertyEnum,
    start: usize,
    end: usize,
) !void {
    var root = start;
    while (root * 2 + 1 < end) {
        var child = root * 2 + 1;
        if (child + 1 < end and
            try atomLessThan(context, entries[child].atom, entries[child + 1].atom))
        {
            child += 1;
        }
        if (!try atomLessThan(context, entries[root].atom, entries[child].atom)) return;
        std.mem.swap(qjs.JSPropertyEnum, &entries[root], &entries[child]);
        root = child;
    }
}

fn atomLessThan(context: *qjs.JSContext, lhs: qjs.JSAtom, rhs: qjs.JSAtom) !bool {
    const lhs_value = qjs.JS_AtomToValue(context, lhs);
    if (qjs.JS_IsException(lhs_value)) return error.StringConversion;
    defer qjs.JS_FreeValue(context, lhs_value);
    const rhs_value = qjs.JS_AtomToValue(context, rhs);
    if (qjs.JS_IsException(rhs_value)) return error.StringConversion;
    defer qjs.JS_FreeValue(context, rhs_value);
    if (!qjs.JS_IsString(lhs_value) or !qjs.JS_IsString(rhs_value)) return error.SymbolKey;

    var lhs_length: usize = 0;
    const lhs_units = qjs.JS_ToCStringLenUTF16(context, &lhs_length, lhs_value) orelse
        return error.StringConversion;
    defer qjs.JS_FreeCStringUTF16(context, lhs_units);
    var rhs_length: usize = 0;
    const rhs_units = qjs.JS_ToCStringLenUTF16(context, &rhs_length, rhs_value) orelse
        return error.StringConversion;
    defer qjs.JS_FreeCStringUTF16(context, rhs_units);

    const common_length = @min(lhs_length, rhs_length);
    for (0..common_length) |index| {
        if (lhs_units[index] != rhs_units[index]) return lhs_units[index] < rhs_units[index];
    }
    return lhs_length < rhs_length;
}

fn isPlainObject(context: *qjs.JSContext, state: *Evaluation, value: qjs.JSValueConst) bool {
    if (!qjs.JS_IsObject(value) or qjs.JS_IsProxy(value) or qjs.JS_IsArray(value)) return false;
    if (qjs.JS_GetClassID(value) != state.object_class) return false;
    const prototype = qjs.JS_GetPrototype(context, value);
    if (qjs.JS_IsException(prototype)) return false;
    defer qjs.JS_FreeValue(context, prototype);
    return qjs.JS_IsNull(prototype) or qjs.JS_IsStrictEqual(context, prototype, state.object_prototype);
}

fn hasExactPrototype(context: *qjs.JSContext, value: qjs.JSValueConst, expected: qjs.JSValueConst) bool {
    const prototype = qjs.JS_GetPrototype(context, value);
    if (qjs.JS_IsException(prototype)) return false;
    defer qjs.JS_FreeValue(context, prototype);
    return qjs.JS_IsStrictEqual(context, prototype, expected);
}

fn deepFreeze(context: *qjs.JSContext, value: qjs.JSValueConst, depth: usize) !void {
    if (depth > protocol.Limits.data_depth) return error.ExcessiveDepth;
    if (!qjs.JS_IsObject(value)) return;
    if (qjs.JS_IsProxy(value)) return error.Proxy;
    var table: [*c]qjs.JSPropertyEnum = null;
    var count: u32 = 0;
    if (qjs.JS_GetOwnPropertyNames(context, &table, &count, value, qjs.JS_GPN_STRING_MASK | qjs.JS_GPN_SYMBOL_MASK) < 0) return error.EnumerationFailed;
    defer qjs.JS_FreePropertyEnum(context, table, count);
    for (table[0..count]) |entry| {
        var descriptor: qjs.JSPropertyDescriptor = undefined;
        const present = qjs.JS_GetOwnProperty(context, &descriptor, value, entry.atom);
        if (present < 0) return error.OutOfMemory;
        if (present != 1) return error.PropertyMissing;
        defer freeDescriptor(context, &descriptor);
        if (descriptor.flags & qjs.JS_PROP_GETSET != 0) return error.AccessorRejected;
        try deepFreeze(context, descriptor.value, depth + 1);
    }
    if (qjs.JS_FreezeObject(context, value) < 0) return error.FreezeFailed;
}

const AgentField = enum { key, task, input, schema, agent_profile };

fn atomField(context: *qjs.JSContext, atom: qjs.JSAtom) !AgentField {
    const value = qjs.JS_AtomToValue(context, atom);
    if (qjs.JS_IsException(value)) return error.OutOfMemory;
    defer qjs.JS_FreeValue(context, value);
    if (!qjs.JS_IsString(value)) return error.SymbolKey;
    var length: usize = 0;
    const string = qjs.JS_ToCStringLenUTF16(context, &length, value) orelse return error.OutOfMemory;
    defer qjs.JS_FreeCStringUTF16(context, string);
    const names = .{
        .{ AgentField.key, "key" },
        .{ AgentField.task, "task" },
        .{ AgentField.input, "input" },
        .{ AgentField.schema, "schema" },
        .{ AgentField.agent_profile, "agent_profile" },
    };
    inline for (names) |candidate| {
        if (length == candidate[1].len) {
            var equal = true;
            for (0..length) |index| {
                if (string[index] != candidate[1][index]) equal = false;
            }
            if (equal) return candidate[0];
        }
    }
    return error.UnknownField;
}

fn freeDescriptor(context: *qjs.JSContext, descriptor: *qjs.JSPropertyDescriptor) void {
    qjs.JS_FreeValue(context, descriptor.value);
    qjs.JS_FreeValue(context, descriptor.getter);
    qjs.JS_FreeValue(context, descriptor.setter);
}

fn scalarCount(bytes: []const u8) usize {
    return std.unicode.utf8CountCodepoints(bytes) catch std.math.maxInt(usize);
}

fn isJobFailureCode(code: []const u8) bool {
    const allowed = [_][]const u8{
        "JobFailed",
        "JobCancelled",
        "JobIndeterminate",
        "JobOutputInvalid",
        "WorkflowDefinitionConflict",
        "ResourceExceeded",
    };
    for (allowed) |candidate| {
        if (std.mem.eql(u8, code, candidate)) return true;
    }
    return false;
}

fn discardException(context: *qjs.JSContext) void {
    const exception = qjs.JS_GetException(context);
    qjs.JS_FreeValue(context, exception);
}

fn isEngineResourceError(context: *qjs.JSContext, reason: qjs.JSValueConst) bool {
    if (!qjs.JS_IsError(reason)) return false;
    const message = qjs.JS_GetPropertyStr(context, reason, "message");
    if (qjs.JS_IsException(message)) {
        discardException(context);
        return false;
    }
    defer qjs.JS_FreeValue(context, message);
    if (!qjs.JS_IsString(message)) return false;
    var length: usize = 0;
    const bytes = qjs.JS_ToCStringLen(context, &length, message) orelse return false;
    defer qjs.JS_FreeCString(context, bytes);
    const slice = bytes[0..length];
    return std.mem.eql(u8, slice, "out of memory") or
        std.mem.eql(u8, slice, "Maximum call stack size exceeded");
}

fn monotonicNanoseconds() i128 {
    var time: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &time) != 0) return 0;
    return @as(i128, time.sec) * std.time.ns_per_s + time.nsec;
}

fn processCpuNanoseconds() i128 {
    var time: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.PROCESS_CPUTIME_ID, &time) != 0) {
        return std.math.maxInt(i128);
    }
    return @as(i128, time.sec) * std.time.ns_per_s + time.nsec;
}
