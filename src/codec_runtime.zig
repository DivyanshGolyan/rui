//! Runs untrusted codec modules in WAMR's fast interpreter. The only file
//! that names WAMR: callers see `Module`, `Job` and `Function`.
//!
//! A module may import nothing, so a codec cannot reach a socket, a clock,
//! a file or the Store. Each job runs on a fresh instance, so no state
//! survives from one job to the next. A job's linear memory is capped, each
//! call runs under an instruction budget, and a trap ends the job with an
//! error instead of ending the Host.
//!
//! A job borrows its module and lives on the thread that began it: WAMR
//! records that thread's native stack bounds when the job begins.
const std = @import("std");
const c = @import("wamr");

/// The hard cap on a job's linear memory: 16 MiB.
pub const max_memory_pages = 256;

/// Everything WAMR allocates outside linear memory, across every module and
/// job: parsed code, tables, globals, interpreter stacks. A table declared
/// with a billion entries fails here instead of exhausting the Host.
pub const max_heap_bytes = 8 * 1024 * 1024;

/// Instructions one call may run. WAMR counts in a C int.
pub const Budget = u31;

pub const LoadError = error{
    RuntimeUnavailable,
    ModuleInvalid,
    ModuleHasImports,
    /// A start function, or an export WAMR calls while instantiating: either
    /// would run before any call sets a budget.
    ModuleRunsAtInstantiate,
    MemoryLimitExceeded,
};

pub const Module = struct {
    handle: c.wasm_module_t,
    /// The memory the module declares, in pages; zero without one.
    memory_pages: u32,
    jobs: u32 = 0,

    /// WAMR may rewrite `bytes` while loading. They are free to reuse or
    /// release once this returns: WAMR copies what the module keeps.
    pub fn load(bytes: []u8) LoadError!Module {
        if (bytes.len > std.math.maxInt(u32)) return error.ModuleInvalid;
        const layout = try scan(bytes);
        if (layout.has_start) return error.ModuleRunsAtInstantiate;
        if (layout.memory_pages > max_memory_pages) return error.MemoryLimitExceeded;
        var init: c.RuntimeInitArgs = std.mem.zeroes(c.RuntimeInitArgs);
        init.mem_alloc_type = c.Alloc_With_Allocator;
        init.mem_alloc_option.allocator = .{
            .malloc_func = @ptrCast(@constCast(&heap.malloc)),
            .realloc_func = @ptrCast(@constCast(&heap.realloc)),
            .free_func = @ptrCast(@constCast(&heap.free)),
            .user_data = null,
        };
        // Nested init counts references, so WAMR holds no state while no
        // module is loaded.
        if (!c.wasm_runtime_full_init(&init)) return error.RuntimeUnavailable;
        errdefer c.wasm_runtime_destroy();
        c.wasm_runtime_set_log_level(c.WASM_LOG_LEVEL_FATAL);
        var args: c.LoadArgs = std.mem.zeroes(c.LoadArgs);
        args.wasm_binary_freeable = true;
        // No error text: the refusal is the result, and nothing shows WAMR's
        // wording to anyone until user codecs name their refusals (U7).
        const handle = c.wasm_runtime_load_ex(bytes.ptr, @intCast(bytes.len), &args, null, 0) orelse
            return error.ModuleInvalid;
        errdefer c.wasm_runtime_unload(handle);
        if (c.wasm_runtime_get_import_count(handle) != 0) return error.ModuleHasImports;
        for (0..@intCast(c.wasm_runtime_get_export_count(handle))) |index| {
            var exported: c.wasm_export_t = undefined;
            c.wasm_runtime_get_export_type(handle, @intCast(index), &exported);
            const name = std.mem.span(exported.name);
            for (instantiation_exports) |runs| {
                if (std.mem.eql(u8, name, runs)) return error.ModuleRunsAtInstantiate;
            }
        }
        return .{ .handle = handle, .memory_pages = layout.memory_pages };
    }

    pub fn unload(self: *Module) void {
        std.debug.assert(self.jobs == 0);
        c.wasm_runtime_unload(self.handle);
        c.wasm_runtime_destroy();
        self.* = undefined;
    }
};

/// Exports this build of WAMR calls, unmetered, while instantiating, when
/// they take and return nothing. Refused by name whatever their kind.
const instantiation_exports = [_][]const u8{ "__post_instantiate", "__wasm_call_ctors" };

pub const Limits = struct {
    /// Linear memory the job may grow to. At least one page and the
    /// module's own declaration, at most `max_memory_pages`: WAMR reads
    /// zero as "the module's own maximum".
    memory_pages: u32,
    /// The interpreter's frame and operand stack.
    stack_bytes: u32 = 16 * 1024,
};

/// `InstantiateFailed` includes reaching `max_heap_bytes`.
pub const BeginError = error{ MemoryLimitExceeded, InstantiateFailed };

pub const CallError = error{ Trap, BudgetExhausted, StackExhausted };

/// An exported function taking `params` i32 values and returning one.
pub const Function = struct {
    handle: c.wasm_function_inst_t,
    params: Params,

    pub const Params = u3;
};

pub const Job = struct {
    module: *Module,
    instance: c.wasm_module_inst_t,
    exec_env: c.wasm_exec_env_t,
    thread: std.Thread.Id,

    pub fn begin(module: *Module, limits: Limits) BeginError!Job {
        std.debug.assert(limits.memory_pages >= 1 and limits.memory_pages <= max_memory_pages);
        if (module.memory_pages > limits.memory_pages) return error.MemoryLimitExceeded;
        var args: c.InstantiationArgs = .{
            .default_stack_size = limits.stack_bytes,
            .host_managed_heap_size = 0,
            .max_memory_pages = limits.memory_pages,
        };
        const instance = c.wasm_runtime_instantiate_ex(module.handle, &args, null, 0) orelse
            return error.InstantiateFailed;
        errdefer c.wasm_runtime_deinstantiate(instance);
        const exec_env = c.wasm_runtime_create_exec_env(instance, limits.stack_bytes) orelse
            return error.InstantiateFailed;
        module.jobs += 1;
        return .{ .module = module, .instance = instance, .exec_env = exec_env, .thread = std.Thread.getCurrentId() };
    }

    pub fn end(self: *Job) void {
        c.wasm_runtime_destroy_exec_env(self.exec_env);
        c.wasm_runtime_deinstantiate(self.instance);
        self.module.jobs -= 1;
        self.* = undefined;
    }

    /// Null when the module exports no such function, or one of another
    /// shape.
    pub fn function(self: *const Job, name: [:0]const u8, params: Function.Params) ?Function {
        const handle = c.wasm_runtime_lookup_function(self.instance, name.ptr) orelse return null;
        if (c.wasm_func_get_param_count(handle, self.instance) != params) return null;
        if (c.wasm_func_get_result_count(handle, self.instance) != 1) return null;
        var types: [std.math.maxInt(Function.Params)]c.wasm_valkind_t = undefined;
        c.wasm_func_get_param_types(handle, self.instance, &types);
        for (types[0..params]) |kind| if (kind != c.WASM_I32) return null;
        c.wasm_func_get_result_types(handle, self.instance, &types);
        if (types[0] != c.WASM_I32) return null;
        return .{ .handle = handle, .params = params };
    }

    /// Any error ends the job: the caller's next step is `end`.
    pub fn call(self: *Job, f: Function, args: []const u32, budget: Budget) CallError!u32 {
        std.debug.assert(args.len == f.params);
        std.debug.assert(self.thread == std.Thread.getCurrentId());
        var argv: [std.math.maxInt(Function.Params) + 1]u32 = undefined;
        @memcpy(argv[0..args.len], args);
        c.wasm_runtime_set_instruction_count_limit(self.exec_env, budget);
        if (c.wasm_runtime_call_wasm(self.exec_env, f.handle, f.params, &argv)) return argv[0];
        const exception = std.mem.span(c.wasm_runtime_get_exception(self.instance) orelse return error.Trap);
        if (std.mem.eql(u8, exception, "Exception: instruction limit exceeded")) return error.BudgetExhausted;
        for ([_][]const u8{
            "Exception: wasm operand stack overflow",
            "Exception: wasm auxiliary stack overflow",
            "Exception: native stack overflow",
        }) |overflow| if (std.mem.eql(u8, exception, overflow)) return error.StackExhausted;
        return error.Trap;
    }

    /// The job's linear memory. A call that grows memory may move it, so
    /// take a fresh slice after every call.
    pub fn memory(self: *const Job) []u8 {
        const default = c.wasm_runtime_get_default_memory(self.instance) orelse return &.{};
        const base: [*]u8 = @ptrCast(c.wasm_memory_get_base_address(default) orelse return &.{});
        // WAMR turns the memory of a module that never grows into one page
        // of the whole declared size.
        const pages: usize = c.wasm_memory_get_cur_page_count(default);
        return base[0 .. pages * c.wasm_memory_get_bytes_per_page(default)];
    }
};

/// WAMR's allocator: the C heap, counted against `max_heap_bytes`. Each
/// block carries its size ahead of the pointer WAMR sees.
const heap = struct {
    var used: std.atomic.Value(usize) = .init(0);
    const header = 16;

    fn malloc(size: c_uint) callconv(.c) ?*anyopaque {
        if (!reserve(size)) return null;
        const block: [*]u8 = @ptrCast(std.c.malloc(header + size) orelse {
            release(size);
            return null;
        });
        @as(*usize, @ptrCast(@alignCast(block))).* = size;
        return block + header;
    }

    fn realloc(pointer: ?*anyopaque, size: c_uint) callconv(.c) ?*anyopaque {
        const old = pointer orelse return malloc(size);
        const block = start(old);
        const previous = @as(*usize, @ptrCast(@alignCast(block))).*;
        if (size > previous and !reserve(size - previous)) return null;
        const moved: [*]u8 = @ptrCast(std.c.realloc(block, header + size) orelse {
            if (size > previous) release(size - previous);
            return null;
        });
        if (size < previous) release(previous - size);
        @as(*usize, @ptrCast(@alignCast(moved))).* = size;
        return moved + header;
    }

    fn free(pointer: ?*anyopaque) callconv(.c) void {
        const block = start(pointer orelse return);
        release(@as(*usize, @ptrCast(@alignCast(block))).*);
        std.c.free(block);
    }

    fn start(pointer: *anyopaque) [*]u8 {
        return @as([*]u8, @ptrCast(pointer)) - header;
    }

    fn reserve(size: usize) bool {
        var current = used.load(.monotonic);
        while (true) {
            if (size > max_heap_bytes - current) return false;
            current = used.cmpxchgWeak(current, current + size, .monotonic, .monotonic) orelse return true;
        }
    }

    fn release(size: usize) void {
        _ = used.fetchSub(size, .monotonic);
    }
};

const Layout = struct { has_start: bool = false, memory_pages: u32 = 0 };

/// Reads what WAMR's API does not expose: a start function, which would run
/// at instantiation outside any budget, and the declared memory.
fn scan(bytes: []const u8) error{ModuleInvalid}!Layout {
    var reader: Reader = .{ .bytes = bytes };
    if (!std.mem.eql(u8, try reader.take(8), "\x00asm\x01\x00\x00\x00")) return error.ModuleInvalid;
    var layout: Layout = .{};
    while (reader.offset < bytes.len) {
        const id = (try reader.take(1))[0];
        var section: Reader = .{ .bytes = try reader.take(try reader.leb()) };
        switch (id) {
            5 => {
                if (try section.leb() == 0) continue;
                _ = try section.take(1);
                layout.memory_pages = try section.leb();
            },
            8 => layout.has_start = true,
            else => {},
        }
    }
    return layout;
}

const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *Reader, len: usize) error{ModuleInvalid}![]const u8 {
        if (len > self.bytes.len - self.offset) return error.ModuleInvalid;
        defer self.offset += len;
        return self.bytes[self.offset..][0..len];
    }

    fn leb(self: *Reader) error{ModuleInvalid}!u32 {
        var value: u32 = 0;
        for (0..5) |index| {
            const byte = (try self.take(1))[0];
            value |= @as(u32, byte & 0x7f) << @intCast(index * 7);
            if (byte & 0x80 == 0) return value;
        }
        return error.ModuleInvalid;
    }
};

const fixture = @embedFile("codec_runtime_fixture");

fn loadFixture(buffer: []u8) !Module {
    @memcpy(buffer[0..fixture.len], fixture);
    return Module.load(buffer[0..fixture.len]);
}

fn beginFixture(module: *Module) !Job {
    return Job.begin(module, .{ .memory_pages = module.memory_pages });
}

const test_budget: Budget = 1_000_000;

test "a module that imports anything is refused" {
    var bytes = "\x00asm\x01\x00\x00\x00\x01\x04\x01\x60\x00\x00\x02\x07\x01\x01m\x01f\x00\x00".*;
    try std.testing.expectError(error.ModuleHasImports, Module.load(&bytes));
}

test "a module with a start function is refused before it can run unmetered" {
    var bytes = "\x00asm\x01\x00\x00\x00\x01\x04\x01\x60\x00\x00\x03\x02\x01\x00\x08\x01\x00\x0a\x04\x01\x02\x00\x0b".*;
    try std.testing.expectError(error.ModuleRunsAtInstantiate, Module.load(&bytes));
}

test "a module exporting what WAMR runs at instantiation is refused" {
    inline for (.{ "__post_instantiate", "__wasm_call_ctors" }) |name| {
        var bytes = endlessExport(name);
        try std.testing.expectError(error.ModuleRunsAtInstantiate, Module.load(&bytes));
    }
}

/// A module whose one function, exported as `name`, loops forever.
fn endlessExport(comptime name: []const u8) [35 + name.len]u8 {
    return ("\x00asm\x01\x00\x00\x00" ++ "\x01\x04\x01\x60\x00\x00" ++ "\x03\x02\x01\x00" ++
        "\x07" ++ [_]u8{ 4 + name.len, 1, name.len } ++ name ++ "\x00\x00" ++
        "\x0a\x09\x01\x07\x00\x03\x40\x0c\x00\x0b\x0b").*;
}

test "a module declaring more memory than the hard cap is refused at load" {
    var bytes = "\x00asm\x01\x00\x00\x00\x05\x04\x01\x00\xac\x02".*;
    try std.testing.expectError(error.MemoryLimitExceeded, Module.load(&bytes));
}

test "bytes that are not a module are refused" {
    var empty = "".*;
    try std.testing.expectError(error.ModuleInvalid, Module.load(&empty));
    var truncated = "\x00asm\x01\x00\x00\x00\x05\x09\x01".*;
    try std.testing.expectError(error.ModuleInvalid, Module.load(&truncated));
    var cut = fixture[0 .. fixture.len - 1].*;
    try std.testing.expectError(error.ModuleInvalid, Module.load(&cut));
}

test "a job below the module's own memory declaration is refused" {
    var buffer: [fixture.len]u8 = undefined;
    var module = try loadFixture(&buffer);
    defer module.unload();
    try std.testing.expect(module.memory_pages > 0);
    try std.testing.expectError(error.MemoryLimitExceeded, Job.begin(&module, .{ .memory_pages = module.memory_pages - 1 }));
}

test "each job starts from a fresh instance" {
    var buffer: [fixture.len]u8 = undefined;
    var module = try loadFixture(&buffer);
    defer module.unload();
    for (0..2) |_| {
        var job = try beginFixture(&module);
        defer job.end();
        const count = job.function("count", 0).?;
        try std.testing.expectEqual(1, try job.call(count, &.{}, test_budget));
        try std.testing.expectEqual(2, try job.call(count, &.{}, test_budget));
    }
}

test "the loaded bytes can be overwritten once the module is loaded" {
    var buffer: [fixture.len]u8 = undefined;
    var module = try loadFixture(&buffer);
    defer module.unload();
    @memset(&buffer, 0xaa);
    var job = try beginFixture(&module);
    defer job.end();
    const address = try job.call(job.function("greetingAddress", 0).?, &.{}, test_budget);
    const len = try job.call(job.function("greetingLength", 0).?, &.{}, test_budget);
    try std.testing.expectEqualStrings("codec data segment", job.memory()[address..][0..len]);
    try std.testing.expectEqual(5, try job.call(job.function("add", 2).?, &.{ 2, 3 }, test_budget));
    try std.testing.expectEqual(0x8000_0000, try job.call(job.function("add", 2).?, &.{ 0x7fff_ffff, 1 }, test_budget));
}

test "the host passes bytes through linear memory" {
    var buffer: [fixture.len]u8 = undefined;
    var module = try loadFixture(&buffer);
    defer module.unload();
    var job = try beginFixture(&module);
    defer job.end();
    const address = try job.call(job.function("scratchAddress", 0).?, &.{}, test_budget);
    @memcpy(job.memory()[address..][0..4], &[_]u8{ 1, 2, 3, 250 });
    try std.testing.expectEqual(256, try job.call(job.function("sum", 2).?, &.{ address, 4 }, test_budget));
}

test "functions of another shape are not found" {
    var buffer: [fixture.len]u8 = undefined;
    var module = try loadFixture(&buffer);
    defer module.unload();
    var job = try beginFixture(&module);
    defer job.end();
    try std.testing.expectEqual(null, job.function("add", 1));
    try std.testing.expectEqual(null, job.function("missing", 0));
    try std.testing.expect(job.function("add", 2) != null);
}

test "an endless loop stops at its budget and later jobs still run" {
    var buffer: [fixture.len]u8 = undefined;
    var module = try loadFixture(&buffer);
    defer module.unload();
    {
        var job = try beginFixture(&module);
        defer job.end();
        try std.testing.expectError(error.BudgetExhausted, job.call(job.function("forever", 0).?, &.{}, test_budget));
    }
    var job = try beginFixture(&module);
    defer job.end();
    try std.testing.expectEqual(1, try job.call(job.function("count", 0).?, &.{}, test_budget));
}

test "metering is exact and repeatable" {
    var buffer: [fixture.len]u8 = undefined;
    var module = try loadFixture(&buffer);
    defer module.unload();
    var low: Budget = 0;
    var high: Budget = test_budget;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (try spinWithin(&module, middle)) high = middle else low = middle + 1;
    }
    try std.testing.expect(low > 1000);
    for (0..3) |_| {
        try std.testing.expect(try spinWithin(&module, low));
        try std.testing.expect(!try spinWithin(&module, low - 1));
    }
}

fn spinWithin(module: *Module, budget: Budget) !bool {
    var job = try beginFixture(module);
    defer job.end();
    const result = job.call(job.function("spin", 1).?, &.{1000}, budget) catch |err| switch (err) {
        error.BudgetExhausted => return false,
        else => return err,
    };
    try std.testing.expectEqual(499500, result);
    return true;
}

test "traps end the job with an error" {
    var buffer: [fixture.len]u8 = undefined;
    var module = try loadFixture(&buffer);
    defer module.unload();
    inline for (.{ "fail", "outside" }) |name| {
        var job = try beginFixture(&module);
        defer job.end();
        try std.testing.expectError(error.Trap, job.call(job.function(name, 0).?, &.{}, test_budget));
    }
}

test "deep recursion exhausts the job's stack, not the Host's" {
    var buffer: [fixture.len]u8 = undefined;
    var module = try loadFixture(&buffer);
    defer module.unload();
    var job = try beginFixture(&module);
    defer job.end();
    const recurse = job.function("recurse", 1).?;
    try std.testing.expectEqual(10, try job.call(recurse, &.{10}, test_budget));
    try std.testing.expectError(error.StackExhausted, job.call(recurse, &.{1_000_000}, std.math.maxInt(Budget)));
}

test "memory grows up to the job's limit and no further" {
    var buffer: [fixture.len]u8 = undefined;
    var module = try loadFixture(&buffer);
    defer module.unload();
    var job = try Job.begin(&module, .{ .memory_pages = module.memory_pages + 2 });
    defer job.end();
    const grow = job.function("grow", 1).?;
    try std.testing.expectEqual(module.memory_pages, try job.call(grow, &.{2}, test_budget));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), try job.call(grow, &.{1}, test_budget));
    try std.testing.expectEqual((module.memory_pages + 2) * 64 * 1024, job.memory().len);
}

test "unloading the last module returns everything WAMR allocated" {
    var buffer: [fixture.len]u8 = undefined;
    try std.testing.expectEqual(0, heap.used.load(.monotonic));
    for (0..3) |_| {
        var module = try loadFixture(&buffer);
        defer module.unload();
        var job = try beginFixture(&module);
        defer job.end();
        _ = try job.call(job.function("count", 0).?, &.{}, test_budget);
        try std.testing.expect(heap.used.load(.monotonic) > 0);
    }
    try std.testing.expectEqual(0, heap.used.load(.monotonic));
}

test "a table too large for the heap cap fails to instantiate" {
    var bytes = "\x00asm\x01\x00\x00\x00\x04\x07\x01\x70\x00\xff\xff\xff\x01".*;
    var module = try Module.load(&bytes);
    defer module.unload();
    const before = heap.used.load(.monotonic);
    try std.testing.expectError(error.InstantiateFailed, Job.begin(&module, .{ .memory_pages = 1 }));
    try std.testing.expectEqual(before, heap.used.load(.monotonic));
}
