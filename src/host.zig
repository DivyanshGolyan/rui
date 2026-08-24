const std = @import("std");
const checkpoint = @import("checkpoint.zig");
const core_contract = @import("core_contract.zig");
const operation_log = @import("operation_log.zig");
const wasm_inspect = @import("wasm_inspect.zig");
const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("unistd.h");
});

const page_size = checkpoint.page_size;
const density_agents = 1000;
const lifecycle_agents = 1000;
const lifecycle_generation = 1;
const lifecycle_journal_path = "snapshots/lifecycle.journal";
const interrupted_agent = 500;
const unaccepted_agent = lifecycle_agents + 1;
const framework_path = "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore";

const JSContext = opaque {};
const JSString = opaque {};
const JSValue = opaque {};
const JSObject = opaque {};

const JSContextRef = ?*JSContext;
const JSStringRef = ?*JSString;
const JSValueRef = ?*const JSValue;
const JSObjectRef = ?*JSObject;

const Api = struct {
    JSGlobalContextCreate: *const fn (?*anyopaque) callconv(.c) JSContextRef,
    JSGlobalContextRelease: *const fn (JSContextRef) callconv(.c) void,
    JSStringCreateWithUTF8CString: *const fn ([*:0]const u8) callconv(.c) JSStringRef,
    JSStringRelease: *const fn (JSStringRef) callconv(.c) void,
    JSEvaluateScript: *const fn (
        JSContextRef,
        JSStringRef,
        JSObjectRef,
        JSStringRef,
        c_int,
        *JSValueRef,
    ) callconv(.c) JSValueRef,
    JSValueToStringCopy: *const fn (JSContextRef, JSValueRef, *JSValueRef) callconv(.c) JSStringRef,
    JSStringGetMaximumUTF8CStringSize: *const fn (JSStringRef) callconv(.c) usize,
    JSStringGetUTF8CString: *const fn (JSStringRef, [*]u8, usize) callconv(.c) usize,
    JSValueToObject: *const fn (JSContextRef, JSValueRef, *JSValueRef) callconv(.c) JSObjectRef,
    JSValueMakeNumber: *const fn (JSContextRef, f64) callconv(.c) JSValueRef,
    JSObjectCallAsFunction: *const fn (
        JSContextRef,
        JSObjectRef,
        JSObjectRef,
        usize,
        [*]const JSValueRef,
        *JSValueRef,
    ) callconv(.c) JSValueRef,
    JSObjectGetTypedArrayBytesPtr: *const fn (JSContextRef, JSObjectRef, *JSValueRef) callconv(.c) ?*anyopaque,
    JSObjectGetTypedArrayByteLength: *const fn (JSContextRef, JSObjectRef, *JSValueRef) callconv(.c) usize,
};

const Runtime = struct {
    library: std.DynLib,
    api: Api,
    context: JSContextRef,

    fn open() !Runtime {
        var library = try std.DynLib.open(framework_path);
        errdefer library.close();

        var api: Api = undefined;
        inline for (@typeInfo(Api).@"struct".fields) |field| {
            @field(api, field.name) = library.lookup(field.type, field.name) orelse {
                std.debug.print("missing JavaScriptCore symbol: {s}\n", .{field.name});
                return error.MissingJavaScriptCoreSymbol;
            };
        }

        const context = api.JSGlobalContextCreate(null) orelse return error.ContextCreationFailed;
        return .{ .library = library, .api = api, .context = context };
    }

    fn close(self: *Runtime) void {
        self.api.JSGlobalContextRelease(self.context);
        self.library.close();
    }

    fn evaluate(self: *const Runtime, allocator: std.mem.Allocator, source: []const u8) !JSValueRef {
        const source_z = try allocator.dupeZ(u8, source);
        defer allocator.free(source_z);

        const source_ref = self.api.JSStringCreateWithUTF8CString(source_z.ptr);
        defer self.api.JSStringRelease(source_ref);

        var exception: JSValueRef = null;
        const value = self.api.JSEvaluateScript(
            self.context,
            source_ref,
            null,
            null,
            1,
            &exception,
        );
        if (exception != null) {
            const message = try self.valueString(allocator, exception);
            defer allocator.free(message);
            std.debug.print("JavaScriptCore exception: {s}\n", .{message});
            return error.JavaScriptException;
        }
        return value;
    }

    fn valueString(
        self: *const Runtime,
        allocator: std.mem.Allocator,
        value: JSValueRef,
    ) ![]u8 {
        var exception: JSValueRef = null;
        const string_ref = self.api.JSValueToStringCopy(self.context, value, &exception);
        if (exception != null or string_ref == null) return error.JavaScriptStringConversionFailed;
        defer self.api.JSStringRelease(string_ref);

        const capacity = self.api.JSStringGetMaximumUTF8CStringSize(string_ref);
        const buffer = try allocator.alloc(u8, capacity);
        errdefer allocator.free(buffer);

        const written = self.api.JSStringGetUTF8CString(string_ref, buffer.ptr, buffer.len);
        if (written == 0) return error.JavaScriptStringConversionFailed;
        return buffer[0 .. written - 1];
    }

    fn memory(self: *const Runtime, allocator: std.mem.Allocator) ![]u8 {
        const value = try self.evaluate(
            allocator,
            "new Uint8Array(__onepage.instance.exports.memory.buffer)",
        );
        var exception: JSValueRef = null;
        const object = self.api.JSValueToObject(self.context, value, &exception);
        if (exception != null or object == null) return error.MemoryBufferUnavailable;

        const length = self.api.JSObjectGetTypedArrayByteLength(self.context, object, &exception);
        if (exception != null or length != page_size) return error.InvalidMemoryLength;

        const raw = self.api.JSObjectGetTypedArrayBytesPtr(self.context, object, &exception);
        if (exception != null or raw == null) return error.MemoryBufferUnavailable;
        const bytes: [*]u8 = @ptrCast(raw.?);
        return bytes[0..length];
    }

    fn function(
        self: *const Runtime,
        allocator: std.mem.Allocator,
        source: []const u8,
    ) !JSObjectRef {
        const value = try self.evaluate(allocator, source);
        var exception: JSValueRef = null;
        const object = self.api.JSValueToObject(self.context, value, &exception);
        if (exception != null or object == null) return error.JavaScriptFunctionUnavailable;
        return object;
    }

    fn callNumbers(self: *const Runtime, function_ref: JSObjectRef, numbers: []const u32) !void {
        if (numbers.len > 3) return error.TooManyArguments;
        var arguments: [3]JSValueRef = undefined;
        for (numbers, 0..) |number, index| {
            arguments[index] = self.api.JSValueMakeNumber(self.context, @floatFromInt(number));
        }
        var exception: JSValueRef = null;
        _ = self.api.JSObjectCallAsFunction(
            self.context,
            function_ref,
            null,
            numbers.len,
            &arguments,
            &exception,
        );
        if (exception != null) return error.JavaScriptCallFailed;
    }

    fn callTwoNumbers(self: *const Runtime, function_ref: JSObjectRef, first: u32, second: u32) !void {
        try self.callNumbers(function_ref, &.{ first, second });
    }

    fn callThreeNumbers(
        self: *const Runtime,
        function_ref: JSObjectRef,
        first: u32,
        second: u32,
        third: u32,
    ) !void {
        try self.callNumbers(function_ref, &.{ first, second, third });
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2 or args.len > 3) {
        std.debug.print(
            "usage: {s} <onepage-core.wasm> " ++
                "[lifecycle-prepare|lifecycle-complete|lifecycle-recover]\n",
            .{args[0]},
        );
        return error.InvalidArguments;
    }

    const wasm = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(wasm);
    try core_contract.verify(wasm);
    const report = try wasm_inspect.inspect(wasm);
    const hex = try encodeHex(allocator, wasm);
    defer allocator.free(hex);
    const bootstrap = try std.mem.concat(allocator, u8, &.{
        "globalThis.__onepage = {}; const hex = '",
        hex,
        "'; const bytes = new Uint8Array(hex.length / 2); " ++
            "for (let i = 0; i < bytes.length; i++) " ++
            "bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16); " ++
            "__onepage.module = new WebAssembly.Module(bytes); 'ok';",
    });
    defer allocator.free(bootstrap);

    var runtime = try Runtime.open();
    defer runtime.close();
    const rss_context = try residentBytes();

    const bootstrap_result = try runtime.evaluate(allocator, bootstrap);
    const bootstrap_text = try runtime.valueString(allocator, bootstrap_result);
    defer allocator.free(bootstrap_text);
    if (!std.mem.eql(u8, bootstrap_text, "ok")) return error.BootstrapFailed;
    const rss_module = try residentBytes();

    _ = try runtime.evaluate(
        allocator,
        "__onepage.instances = [new WebAssembly.Instance(__onepage.module, {})]; " ++
            "__onepage.instance = __onepage.instances[0]",
    );

    if (args.len == 3) {
        if (std.mem.eql(u8, args[2], "lifecycle-prepare")) {
            try lifecyclePrepare(init.io, allocator, &runtime);
            return;
        }
        if (std.mem.eql(u8, args[2], "lifecycle-complete")) {
            try lifecycleComplete(init.io);
            return;
        }
        if (std.mem.eql(u8, args[2], "lifecycle-recover")) {
            try lifecycleRecover(init.io, allocator, &runtime);
            return;
        }
        return error.InvalidArguments;
    }

    _ = try runtime.evaluate(allocator, "__onepage.instance.exports.initialize(7)");
    _ = try runtime.evaluate(allocator, "__onepage.instance.exports.deliver(11)");
    _ = try runtime.evaluate(allocator, "__onepage.instance.exports.deliver(13)");

    const memory = try runtime.memory(allocator);
    const checkpoint_buffer = try allocator.alloc(u8, checkpoint.encoded_size);
    defer allocator.free(checkpoint_buffer);
    try checkpoint.encode(checkpoint_buffer, 7, 1, memory);
    std.Io.Dir.cwd().createDir(init.io, "snapshots", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = "snapshots/agent-7.page",
        .data = checkpoint_buffer,
    });

    @memset(memory, 0xa5);
    const snapshot = try checkpoint.decode(checkpoint_buffer, 7, 1);
    @memcpy(memory, snapshot.page);
    try expectString(&runtime, allocator, "__onepage.instance.exports.agentId()", "7");
    try expectString(&runtime, allocator, "__onepage.instance.exports.eventCount().toString()", "2");
    try expectString(&runtime, allocator, "__onepage.instance.exports.isQuiescent()", "1");

    @memset(memory, 0);
    _ = try runtime.evaluate(allocator, "__onepage.instance.exports.initialize(99)");
    if (std.mem.indexOfScalar(u8, memory, 0xa5) != null) return error.SlotScrubFailed;
    try expectString(&runtime, allocator, "__onepage.instance.exports.agentId()", "99");
    try expectString(&runtime, allocator, "__onepage.instance.exports.eventCount().toString()", "0");

    const rss_one_slot = try residentBytes();
    const run_agent = try runtime.function(
        allocator,
        "__onepage.runAgent = function(agentId, event) { " ++
            "__onepage.instance.exports.initialize(agentId); " ++
            "return __onepage.instance.exports.deliver(event); }; " ++
            "__onepage.runAgent",
    );
    const density_start = std.Io.Clock.Timestamp.now(init.io, .awake);
    var path_buffer: [64]u8 = undefined;
    for (0..density_agents) |index| {
        @memset(memory, 0);
        const agent_id: u32 = @intCast(index + 1);
        try runtime.callTwoNumbers(run_agent, agent_id, agent_id ^ 0x5a5a5a5a);
        try checkpoint.encode(checkpoint_buffer, agent_id, 1, memory);

        const path = try std.fmt.bufPrint(
            &path_buffer,
            "snapshots/density-{d:0>4}.page",
            .{agent_id},
        );
        try std.Io.Dir.cwd().writeFile(init.io, .{
            .sub_path = path,
            .data = checkpoint_buffer,
        });
    }
    const density_elapsed = density_start.untilNow(init.io).raw.toMilliseconds();
    const rss_density = try residentBytes();

    for ([_]u32{ 1, 500, 1000 }) |agent_id| {
        const path = try std.fmt.bufPrint(
            &path_buffer,
            "snapshots/density-{d:0>4}.page",
            .{agent_id},
        );
        const restored = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            path,
            allocator,
            .limited(checkpoint.encoded_size + 1),
        );
        defer allocator.free(restored);
        const restored_checkpoint = try checkpoint.decode(restored, agent_id, 1);
        @memcpy(memory, restored_checkpoint.page);
        const check_value = try runtime.evaluate(
            allocator,
            "__onepage.instance.exports.agentId().toString()",
        );
        const actual = try runtime.valueString(allocator, check_value);
        defer allocator.free(actual);
        var expected_buffer: [16]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "{d}", .{agent_id});
        if (!std.mem.eql(u8, actual, expected)) return error.DensityRestoreFailed;
    }

    var slot_rss: [4]u64 = undefined;
    const slot_counts = [_]u32{ 1, 2, 4, 8 };
    slot_rss[0] = rss_density;
    var current_slots: u32 = 1;
    for (slot_counts[1..], 1..) |target_slots, result_index| {
        while (current_slots < target_slots) : (current_slots += 1) {
            _ = try runtime.evaluate(
                allocator,
                "__onepage.instances.push(new WebAssembly.Instance(__onepage.module, {})); " ++
                    "__onepage.instance = __onepage.instances[__onepage.instances.length - 1]",
            );
            const slot_memory = try runtime.memory(allocator);
            @memset(slot_memory, 0);
            _ = try runtime.evaluate(allocator, "__onepage.instance.exports.initialize(1)");
        }
        slot_rss[result_index] = try residentBytes();
    }

    std.debug.print(
        "core linear memory    {d} B\n" ++
            "wasm growth           disabled by maximum=1 page\n" ++
            "imports               {d}\n" ++
            "table                 funcref min=1 max=1, unexported, unused\n" ++
            "mutable global        i32 init=4096, unexported, unused\n" ++
            "function exports      {d}\n" ++
            "data section          {d} B\n" ++
            "snapshot/restore      pass\n" ++
            "slot scrub            pass\n" ++
            "JavaScriptCore        system framework\n" ++
            "durable agents        {d}\n" ++
            "density elapsed       {d} ms\n" ++
            "page payload          {d} B\n" ++
            "checkpoint storage    {d} B\n" ++
            "RSS JSC context       {d} B\n" ++
            "RSS compiled module   {d} B\n" ++
            "RSS first slot        {d} B\n" ++
            "RSS after density     {d} B\n" ++
            "RSS slots 1/2/4/8     {d} / {d} / {d} / {d} B\n",
        .{
            memory.len,
            report.imports,
            report.function_exports,
            report.data_section_bytes,
            density_agents,
            density_elapsed,
            density_agents * page_size,
            density_agents * checkpoint.encoded_size,
            rss_context,
            rss_module,
            rss_one_slot,
            rss_density,
            slot_rss[0],
            slot_rss[1],
            slot_rss[2],
            slot_rss[3],
        },
    );
}

fn lifecyclePrepare(io: std.Io, allocator: std.mem.Allocator, runtime: *const Runtime) !void {
    try ensureLifecycleDirectory(io);
    var journal = try operation_log.Writer.create(io, lifecycle_journal_path);
    defer journal.close(io);

    const memory = try runtime.memory(allocator);
    const checkpoint_buffer = try allocator.alloc(u8, checkpoint.encoded_size);
    defer allocator.free(checkpoint_buffer);
    const submit = try runtime.function(
        allocator,
        "__onepage.lifecycleSubmit = function(agentId, operationId) { " ++
            "__onepage.instance.exports.initialize(agentId); " ++
            "if (__onepage.instance.exports.submitOperation(operationId, agentId) !== 1) " ++
            "throw new Error('submit failed'); " ++
            "}; __onepage.lifecycleSubmit",
    );
    const accept = try runtime.function(
        allocator,
        "__onepage.lifecycleAccept = function(operationId, operationGeneration) { " ++
            "if (__onepage.instance.exports.acceptOperation(operationId, operationGeneration) !== 1) " ++
            "throw new Error('accept failed'); " ++
            "}; __onepage.lifecycleAccept",
    );
    const bounds = try runtime.function(
        allocator,
        "__onepage.lifecycleBounds = function(unusedA, unusedB) { " ++
            "__onepage.instance.exports.initialize(9999); " ++
            "if (__onepage.instance.exports.submitOperation(1, 1) !== 1 || " ++
            "__onepage.instance.exports.submitOperation(2, 2) !== 0 || " ++
            "__onepage.instance.exports.acceptOperation(1, 2) !== 0 || " ++
            "__onepage.instance.exports.acceptOperation(1, 1) !== 1 || " ++
            "__onepage.instance.exports.completeOperation(1, 2, 3) !== 0 || " ++
            "__onepage.instance.exports.completeOperation(1, 1, 3) !== 1 || " ++
            "__onepage.instance.exports.submitOperation(1, 3) !== 1 || " ++
            "__onepage.instance.exports.acceptOperation(1, 2) !== 1 || " ++
            "__onepage.instance.exports.completeOperation(1, 1, 3) !== 0 || " ++
            "__onepage.instance.exports.completeOperation(1, 2, 4) !== 1 || " ++
            "__onepage.instance.exports.completeOperation(1, 2, 4) !== 0) " ++
            "throw new Error('operation bounds failed'); " ++
            "}; __onepage.lifecycleBounds",
    );
    try runtime.callTwoNumbers(bounds, 0, 0);

    const rss_first_slot = try residentBytes();
    var rss_after_first: u64 = 0;
    var rss_after_hundred: u64 = 0;
    var journal_sequence: u64 = 0;
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    var path_buffer: [80]u8 = undefined;

    for (0..lifecycle_agents) |index| {
        const agent_id: u32 = @intCast(index + 1);
        const operation_id = lifecycleOperationId(agent_id);
        @memset(memory, 0);
        try runtime.callTwoNumbers(submit, agent_id, operation_id);

        try writeLifecycleCheckpoint(
            io,
            checkpoint_buffer,
            memory,
            agent_id,
            &path_buffer,
        );

        journal_sequence += 1;
        try journal.appendDurable(io, .{
            .kind = .accepted,
            .agent_id = agent_id,
            .agent_generation = lifecycle_generation,
            .operation_id = operation_id,
            .operation_generation = 1,
            .sequence = journal_sequence,
            .result = 0,
        });

        if (agent_id != interrupted_agent) {
            try runtime.callTwoNumbers(accept, operation_id, 1);
            try writeLifecycleCheckpoint(
                io,
                checkpoint_buffer,
                memory,
                agent_id,
                &path_buffer,
            );
        }

        if (agent_id == 1) {
            journal_sequence += 1;
            try journal.appendDurable(io, .{
                .kind = .completed,
                .agent_id = agent_id,
                .agent_generation = lifecycle_generation,
                .operation_id = operation_id,
                .operation_generation = 1,
                .sequence = journal_sequence,
                .result = lifecycleResult(operation_id),
            });
        }

        if (agent_id == 1) rss_after_first = try residentBytes();
        if (agent_id == 100) rss_after_hundred = try residentBytes();
    }
    const rss_after_accepted = try residentBytes();

    @memset(memory, 0);
    const orphan_operation_id = lifecycleOperationId(unaccepted_agent);
    try runtime.callTwoNumbers(submit, unaccepted_agent, orphan_operation_id);
    try writeLifecycleCheckpoint(
        io,
        checkpoint_buffer,
        memory,
        unaccepted_agent,
        &path_buffer,
    );

    const elapsed = started.untilNow(io).raw.toMilliseconds();
    const rss_after_prepare = try residentBytes();

    std.debug.print(
        "lifecycle prepare\n" ++
            "durable agents        {d}\n" ++
            "resident slots        1\n" ++
            "accepted operations   {d}\n" ++
            "queued completions     1\n" ++
            "immediate queued       1\n" ++
            "deferred pending       {d}\n" ++
            "unaccepted preserved   {d}\n" ++
            "submitted at crash    {d}\n" ++
            "journal bytes         {d}\n" ++
            "elapsed               {d} ms\n" ++
            "RSS first slot        {d} B\n" ++
            "RSS agents 1/100/1000 {d} / {d} / {d} B\n" ++
            "RSS after prepare     {d} B\n",
        .{
            lifecycle_agents,
            lifecycle_agents,
            lifecycle_agents - 1,
            unaccepted_agent,
            interrupted_agent,
            journal.offset,
            elapsed,
            rss_first_slot,
            rss_after_first,
            rss_after_hundred,
            rss_after_accepted,
            rss_after_prepare,
        },
    );
}

fn lifecycleComplete(io: std.Io) !void {
    var journal = try operation_log.Writer.openAppend(io, lifecycle_journal_path);
    defer journal.close(io);
    const resumed_sequence = journal.last_sequence;
    const started = std.Io.Clock.Timestamp.now(io, .awake);

    for (0..lifecycle_agents) |index| {
        const agent_id: u32 = @intCast((index * 997) % lifecycle_agents + 1);
        if (agent_id == 1) continue;
        const operation_id = lifecycleOperationId(agent_id);
        try journal.appendDurable(io, .{
            .kind = .completed,
            .agent_id = agent_id,
            .agent_generation = lifecycle_generation,
            .operation_id = operation_id,
            .operation_generation = 1,
            .sequence = journal.last_sequence + 1,
            .result = lifecycleResult(operation_id),
        });
    }

    std.debug.print(
        "lifecycle complete\n" ++
            "fresh host process    yes\n" ++
            "resumed sequence      {d}\n" ++
            "deferred completed    {d}\n" ++
            "journal records       {d}\n" ++
            "journal bytes         {d}\n" ++
            "elapsed               {d} ms\n",
        .{
            resumed_sequence,
            lifecycle_agents - 1,
            journal.offset / operation_log.record_size,
            journal.offset,
            started.untilNow(io).raw.toMilliseconds(),
        },
    );
}

fn lifecycleRecover(io: std.Io, allocator: std.mem.Allocator, runtime: *const Runtime) !void {
    var journal = try operation_log.Reader.open(io, lifecycle_journal_path);
    defer journal.close(io);

    const memory = try runtime.memory(allocator);
    const checkpoint_buffer = try allocator.alloc(u8, checkpoint.encoded_size);
    defer allocator.free(checkpoint_buffer);
    const reconcile = try runtime.function(
        allocator,
        "__onepage.lifecycleReconcile = function(operationId, operationGeneration, result) { " ++
            "let state = __onepage.instance.exports.operationState(); " ++
            "if (state === 1 && " ++
            "__onepage.instance.exports.acceptOperation(operationId, operationGeneration) !== 1) " ++
            "throw new Error('reconcile accept failed'); " ++
            "state = __onepage.instance.exports.operationState(); " ++
            "if (state === 2 && __onepage.instance.exports.completeOperation(" ++
            "operationId, operationGeneration, result) !== 1) " ++
            "throw new Error('reconcile complete failed'); " ++
            "if (__onepage.instance.exports.operationState() !== 3 || " ++
            "__onepage.instance.exports.operationId() !== BigInt(operationId) || " ++
            "__onepage.instance.exports.operationGeneration() !== operationGeneration || " ++
            "__onepage.instance.exports.operationResult() !== BigInt(result)) " ++
            "throw new Error('reconcile result mismatch'); " ++
            "}; __onepage.lifecycleReconcile",
    );

    const rss_first_slot = try residentBytes();
    var accepted_count: usize = 0;
    var completed_count: usize = 0;
    var reconciled_submission = false;
    var replayed_completion = false;
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    var path_buffer: [80]u8 = undefined;

    while (try journal.next(io)) |record| {
        try validateLifecycleRecord(record);
        switch (record.kind) {
            .accepted => accepted_count += 1,
            .completed => {
                const completion_offset = journal.offset - operation_log.record_size;
                try verifyAcceptedPrefix(io, record, completion_offset);
                const agent_id: u32 = @intCast(record.agent_id);
                const operation_id: u32 = @intCast(record.operation_id);
                const operation_generation = record.operation_generation;
                const result: u32 = @intCast(record.result);
                try readLifecycleCheckpoint(
                    io,
                    checkpoint_buffer,
                    memory,
                    agent_id,
                    &path_buffer,
                );
                if (agent_id == interrupted_agent) {
                    const state_value = try runtime.evaluate(
                        allocator,
                        "__onepage.instance.exports.operationState()",
                    );
                    const state_text = try runtime.valueString(allocator, state_value);
                    defer allocator.free(state_text);
                    if (std.mem.eql(u8, state_text, "1")) {
                        reconciled_submission = true;
                    } else if (std.mem.eql(u8, state_text, "3")) {
                        replayed_completion = true;
                    } else {
                        return error.SubmittedCrashBoundaryNotRecoverable;
                    }
                }
                try runtime.callThreeNumbers(reconcile, operation_id, operation_generation, result);
                try writeLifecycleCheckpoint(
                    io,
                    checkpoint_buffer,
                    memory,
                    agent_id,
                    &path_buffer,
                );
                completed_count += 1;
            },
        }
    }

    if (accepted_count != lifecycle_agents or completed_count != lifecycle_agents) {
        return error.IncompleteLifecycleJournal;
    }
    if (!reconciled_submission and !replayed_completion) {
        return error.SubmittedCrashBoundaryNotExercised;
    }

    try readLifecycleCheckpoint(
        io,
        checkpoint_buffer,
        memory,
        unaccepted_agent,
        &path_buffer,
    );
    try expectString(runtime, allocator, "__onepage.instance.exports.operationState()", "1");
    if (try hasAcceptedRecord(
        io,
        unaccepted_agent,
        lifecycle_generation,
        lifecycleOperationId(unaccepted_agent),
        1,
        std.math.maxInt(u64),
    )) {
        return error.UnacceptedOperationWasPublished;
    }

    const elapsed = started.untilNow(io).raw.toMilliseconds();
    const rss_after_recovery = try residentBytes();
    std.debug.print(
        "lifecycle recover\n" ++
            "fresh host process    yes\n" ++
            "accepted recovered    {d}\n" ++
            "completions delivered {d}\n" ++
            "submitted reconciled  {d}\n" ++
            "completed replay      {s}\n" ++
            "unaccepted preserved  {d}\n" ++
            "lost operations       0\n" ++
            "resident index        0 B\n" ++
            "elapsed               {d} ms\n" ++
            "RSS first slot        {d} B\n" ++
            "RSS after recovery    {d} B\n",
        .{
            accepted_count,
            completed_count,
            interrupted_agent,
            if (replayed_completion) "yes" else "no",
            unaccepted_agent,
            elapsed,
            rss_first_slot,
            rss_after_recovery,
        },
    );
}

fn verifyAcceptedPrefix(
    io: std.Io,
    completion: operation_log.Record,
    completion_offset: u64,
) !void {
    if (!try hasAcceptedRecord(
        io,
        completion.agent_id,
        completion.agent_generation,
        completion.operation_id,
        completion.operation_generation,
        completion_offset,
    )) {
        return error.MissingAcceptedOperation;
    }
}

fn hasAcceptedRecord(
    io: std.Io,
    agent_id: u64,
    agent_generation: u64,
    operation_id: u64,
    operation_generation: u32,
    before_offset: u64,
) !bool {
    var scan = try operation_log.Reader.open(io, lifecycle_journal_path);
    defer scan.close(io);
    var accepted = false;
    while (scan.offset < before_offset) {
        const record = (try scan.next(io)) orelse break;
        if (record.agent_id != agent_id or
            record.agent_generation != agent_generation or
            record.operation_id != operation_id or
            record.operation_generation != operation_generation)
        {
            continue;
        }
        switch (record.kind) {
            .accepted => accepted = true,
            .completed => return error.DuplicateCompletion,
        }
    }
    return accepted;
}

fn validateLifecycleRecord(record: operation_log.Record) !void {
    if (record.agent_id == 0 or record.agent_id > lifecycle_agents) {
        return error.InvalidLifecycleAgent;
    }
    const agent_id: u32 = @intCast(record.agent_id);
    try operation_log.validateExpected(
        record,
        agent_id,
        lifecycle_generation,
        lifecycleOperationId(agent_id),
        1,
    );
    if (record.kind == .completed and record.result != lifecycleResult(@intCast(record.operation_id))) {
        return error.InvalidLifecycleResult;
    }
}

fn ensureLifecycleDirectory(io: std.Io) !void {
    std.Io.Dir.cwd().createDir(io, "snapshots", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.Io.Dir.cwd().createDir(io, "snapshots/lifecycle", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn writeLifecycleCheckpoint(
    io: std.Io,
    buffer: []u8,
    memory: []const u8,
    agent_id: u32,
    path_buffer: []u8,
) !void {
    try checkpoint.encode(buffer, agent_id, lifecycle_generation, memory);
    const path = try lifecyclePath(path_buffer, agent_id);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buffer });
}

fn readLifecycleCheckpoint(
    io: std.Io,
    buffer: []u8,
    memory: []u8,
    agent_id: u32,
    path_buffer: []u8,
) !void {
    const path = try lifecyclePath(path_buffer, agent_id);
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const bytes_read = try file.readPositionalAll(io, buffer, 0);
    if (bytes_read != checkpoint.encoded_size) return error.InvalidCheckpointLength;
    const restored = try checkpoint.decode(buffer, agent_id, lifecycle_generation);
    @memcpy(memory, restored.page);
}

fn lifecyclePath(buffer: []u8, agent_id: u32) ![]u8 {
    return std.fmt.bufPrint(buffer, "snapshots/lifecycle/agent-{d:0>4}.page", .{agent_id});
}

fn lifecycleOperationId(agent_id: u32) u32 {
    return 10_000 + agent_id;
}

fn lifecycleResult(operation_id: u32) u32 {
    return operation_id ^ 0xa5a5;
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

fn expectString(
    runtime: *const Runtime,
    allocator: std.mem.Allocator,
    source: []const u8,
    expected: []const u8,
) !void {
    const value = try runtime.evaluate(allocator, source);
    const actual = try runtime.valueString(allocator, value);
    defer allocator.free(actual);
    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print("expected {s}, got {s}\n", .{ expected, actual });
        return error.UnexpectedValue;
    }
}

fn encodeHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    const result = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        result[index * 2] = alphabet[byte >> 4];
        result[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return result;
}
