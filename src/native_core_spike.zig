const std = @import("std");
const checkpoint = @import("checkpoint.zig");
const core_contract = @import("core_contract.zig");
const core_image = @import("core_image.zig");
const jsc = @import("jsc_runtime.zig");
const model_protocol = @import("model_protocol.zig");
const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("unistd.h");
});

const density_agents = 1000;

const WasmTransitions = struct {
    initialize: jsc.JSObjectRef,
    deliver: jsc.JSObjectRef,
    start_task: jsc.JSObjectRef,
    begin_model: jsc.JSObjectRef,
    accept: jsc.JSObjectRef,
    complete: jsc.JSObjectRef,
    interpret: jsc.JSObjectRef,
    commit_tool: jsc.JSObjectRef,
    commit_final: jsc.JSObjectRef,

    fn load(runtime: *const jsc.Runtime, allocator: std.mem.Allocator) !WasmTransitions {
        return .{
            .initialize = try runtime.function(allocator, "__onepage.instance.exports.initialize"),
            .deliver = try runtime.function(allocator, "__onepage.instance.exports.deliver"),
            .start_task = try runtime.function(allocator, "__onepage.instance.exports.startTask"),
            .begin_model = try runtime.function(allocator, "__onepage.instance.exports.beginModelOperation"),
            .accept = try runtime.function(allocator, "__onepage.instance.exports.acceptOperation"),
            .complete = try runtime.function(allocator, "__onepage.instance.exports.completeOperation"),
            .interpret = try runtime.function(allocator, "__onepage.instance.exports.interpretModelResponse"),
            .commit_tool = try runtime.function(allocator, "__onepage.instance.exports.commitToolResult"),
            .commit_final = try runtime.function(allocator, "__onepage.instance.exports.commitFinalAnswer"),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) {
        std.debug.print("usage: {s} <onepage-core.wasm>\n", .{args[0]});
        return error.InvalidArguments;
    }

    const rss_process = try residentBytes();
    const image = try allocator.create(core_image.Image);
    defer allocator.destroy(image);
    image.initialize(1);
    const rss_first_image = try residentBytes();

    const record = try allocator.alloc(u8, checkpoint.encoded_size);
    defer allocator.free(record);
    for (0..density_agents) |index| {
        const agent_id: u32 = @intCast(index + 1);
        image.initialize(agent_id);
        if (!image.payload.deliver(agent_id ^ 0x5a5a5a5a)) return error.NativeTransitionRejected;
        try checkpoint.encode(record, agent_id, 1, std.mem.asBytes(image));
        const restored = try checkpoint.decode(record, agent_id, 1);
        if (!std.mem.eql(u8, restored.page, std.mem.asBytes(image))) return error.NativeRestoreMismatch;
    }
    const rss_density = try residentBytes();

    var slots: [8]?*core_image.Image = .{image} ++ .{null} ** 7;
    defer for (slots[1..]) |slot| if (slot) |allocated| allocator.destroy(allocated);
    var slot_rss: [4]u64 = undefined;
    slot_rss[0] = rss_density;
    var initialized_slots: usize = 1;
    for ([_]usize{ 2, 4, 8 }, 1..) |target, result_index| {
        while (initialized_slots < target) : (initialized_slots += 1) {
            const slot = try allocator.create(core_image.Image);
            slot.initialize(@intCast(initialized_slots + 1));
            slots[initialized_slots] = slot;
        }
        slot_rss[result_index] = try residentBytes();
    }

    const wasm = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(1024 * 1024));
    defer allocator.free(wasm);
    try core_contract.verify(wasm);
    try differentialCheck(allocator, image, wasm);

    std.debug.print(
        "native Core image      {d} B exact\n" ++
            "native payload offset  {d} B\n" ++
            "native response offset {d} B\n" ++
            "logical agents         {d}\n" ++
            "checkpoint round trips pass\n" ++
            "native/Wasm trace      equivalent\n" ++
            "RSS process baseline   {d} B\n" ++
            "RSS first image        {d} B\n" ++
            "RSS after density      {d} B\n" ++
            "RSS images 1/2/4/8     {d} / {d} / {d} / {d} B\n",
        .{
            @sizeOf(core_image.Image),
            core_image.state_memory_offset,
            core_image.response_memory_offset,
            density_agents,
            rss_process,
            rss_first_image,
            rss_density,
            slot_rss[0],
            slot_rss[1],
            slot_rss[2],
            slot_rss[3],
        },
    );
}

fn differentialCheck(
    allocator: std.mem.Allocator,
    native: *core_image.Image,
    wasm: []const u8,
) !void {
    var runtime = try jsc.Runtime.open();
    defer runtime.close();
    try runtime.instantiate(allocator, wasm);
    const transitions = try WasmTransitions.load(&runtime, allocator);
    const wasm_memory = try runtime.memory(allocator);

    native.initialize(7);
    try runtime.callNumbers(transitions.initialize, &.{7});
    try expectSamePayload(native, wasm_memory);

    try expectBoth(native.payload.deliver(29), try runtime.callNumber(transitions.deliver, &.{29}));
    try expectSamePayload(native, wasm_memory);
    try expectBoth(native.payload.startTask(7), try runtime.callNumber(transitions.start_task, &.{7}));
    try expectBoth(native.payload.beginModelOperation(11, 2), try runtime.callNumber(transitions.begin_model, &.{ 11, 2 }));
    try expectBoth(native.payload.acceptOperation(11, 1), try runtime.callNumber(transitions.accept, &.{ 11, 1 }));
    try expectBoth(native.payload.completeOperation(11, 1, 17), try runtime.callNumber(transitions.complete, &.{ 11, 1, 17 }));

    var encoded_buffer: [model_protocol.max_response_size]u8 = undefined;
    const tool = try model_protocol.encodeTool(&encoded_buffer, .bash, "pwd");
    @memcpy(wasm_memory[core_image.response_memory_offset..][0..tool.len], tool);
    try expectBoth(
        native.payload.interpretResponse(tool, 17),
        try runtime.callNumber(transitions.interpret, &.{ core_image.response_memory_offset, @intCast(tool.len), 17 }),
    );
    try expectSamePayload(native, wasm_memory);
    try expectBoth(native.payload.commitToolResult(8, 9), try runtime.callNumber(transitions.commit_tool, &.{ 8, 9 }));
    try expectBoth(native.payload.beginModelOperation(12, 3), try runtime.callNumber(transitions.begin_model, &.{ 12, 3 }));
    try expectBoth(native.payload.acceptOperation(12, 2), try runtime.callNumber(transitions.accept, &.{ 12, 2 }));
    try expectBoth(native.payload.completeOperation(12, 2, 18), try runtime.callNumber(transitions.complete, &.{ 12, 2, 18 }));

    const final = try model_protocol.encodeText(&encoded_buffer, .complete, "ok");
    @memcpy(wasm_memory[core_image.response_memory_offset..][0..final.len], final);
    try expectBoth(
        native.payload.interpretResponse(final, 18),
        try runtime.callNumber(transitions.interpret, &.{ core_image.response_memory_offset, @intCast(final.len), 18 }),
    );
    try expectSamePayload(native, wasm_memory);
    try expectBoth(native.payload.commitFinalAnswer(10), try runtime.callNumber(transitions.commit_final, &.{10}));
    try expectSamePayload(native, wasm_memory);
}

fn expectBoth(native: bool, wasm: u32) !void {
    if (!native or wasm != 1) return error.DifferentialTransitionRejected;
}

fn expectSamePayload(native: *const core_image.Image, wasm_memory: []const u8) !void {
    const native_bytes = std.mem.asBytes(native)[core_image.state_memory_offset..];
    const wasm_bytes = wasm_memory[core_image.state_memory_offset..];
    if (!std.mem.eql(u8, native_bytes, wasm_bytes)) return error.DifferentialStateMismatch;
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
