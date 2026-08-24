const std = @import("std");
const checkpoint = @import("checkpoint.zig");
const wasm_inspect = @import("wasm_inspect.zig");
const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("unistd.h");
});

const page_size = checkpoint.page_size;
const density_agents = 1000;
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

    fn callTwoNumbers(self: *const Runtime, function_ref: JSObjectRef, first: u32, second: u32) !void {
        const arguments = [_]JSValueRef{
            self.api.JSValueMakeNumber(self.context, @floatFromInt(first)),
            self.api.JSValueMakeNumber(self.context, @floatFromInt(second)),
        };
        var exception: JSValueRef = null;
        _ = self.api.JSObjectCallAsFunction(
            self.context,
            function_ref,
            null,
            arguments.len,
            &arguments,
            &exception,
        );
        if (exception != null) return error.JavaScriptCallFailed;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) {
        std.debug.print("usage: {s} <onepage-core.wasm>\n", .{args[0]});
        return error.InvalidArguments;
    }

    const wasm = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(wasm);
    const report = try wasm_inspect.inspect(wasm);
    if (report.imports != 0 or
        report.memories != 1 or
        report.memory_min_pages != 1 or
        report.memory_max_pages == null or
        report.memory_max_pages.? != 1 or
        report.memory_exports != 1 or
        report.tables != 1 or
        report.table_ref_type != 0x70 or
        report.table_min != 1 or
        report.table_max == null or
        report.table_max.? != 1 or
        report.table_exports != 0 or
        report.table_reads != 0 or
        report.table_writes != 0 or
        report.indirect_calls != 0 or
        report.globals != 1 or
        report.mutable_globals != 1 or
        report.first_global_type != 0x7f or
        report.first_global_i32_init != 4 * 1024 or
        report.global_exports != 0 or
        report.global_reads != 0 or
        report.global_writes != 0 or
        report.memory_grows != 0 or
        report.function_exports != 6 or
        report.exports != 7 or
        report.data_section_bytes != 0)
    {
        return error.OnePageContractViolated;
    }
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
