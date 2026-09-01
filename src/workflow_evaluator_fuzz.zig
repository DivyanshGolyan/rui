const std = @import("std");
const evaluator = @import("workflow_evaluator.zig");
const protocol = @import("workflow_protocol.zig");

const Target = enum {
    protocol_decoder,
    js_value_encoder,
    result_decoder,
    workflow_capability,
};

const Harness = struct {
    first_output: []u8,
    second_output: []u8,
    bridge: []u8,

    fn init(allocator: std.mem.Allocator) !Harness {
        const first_output = try allocator.alloc(u8, protocol.Limits.output_frame_bytes);
        errdefer allocator.free(first_output);
        const second_output = try allocator.alloc(u8, protocol.Limits.output_frame_bytes);
        errdefer allocator.free(second_output);
        return .{
            .first_output = first_output,
            .second_output = second_output,
            .bridge = try allocator.alloc(u8, protocol.Limits.bridge_arena_bytes),
        };
    }

    fn deinit(self: Harness, allocator: std.mem.Allocator) void {
        allocator.free(self.bridge);
        allocator.free(self.second_output);
        allocator.free(self.first_output);
    }

    fn evaluateDeterministically(self: *Harness, input: []const u8) !void {
        const first = evaluator.evaluate(input, self.first_output, self.bridge);
        try validateOutcome(first);
        const second = evaluator.evaluate(input, self.second_output, self.bridge);
        try validateOutcome(second);
        if (!std.mem.eql(u8, first, second)) return error.NondeterministicOutcome;
    }
};

const Visible = struct {
    key: []const u8,
    tag: protocol.VisibleTag,
    payload: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const arguments = try init.minimal.args.toSlice(allocator);
    defer allocator.free(arguments);
    if (arguments.len != 2) return error.InvalidArguments;
    const target = std.meta.stringToEnum(Target, arguments[1]) orelse return error.InvalidTarget;

    var harness = try Harness.init(allocator);
    defer harness.deinit(allocator);
    switch (target) {
        .protocol_decoder => try fuzzProtocolDecoder(allocator, &harness),
        .js_value_encoder => try fuzzJsValueEncoder(&harness),
        .result_decoder => try fuzzResultDecoder(allocator, &harness),
        .workflow_capability => try fuzzWorkflowCapability(&harness),
    }
}

fn fuzzProtocolDecoder(allocator: std.mem.Allocator, harness: *Harness) !void {
    var value_storage: [128]u8 = undefined;
    var value = protocol.Builder.init(&value_storage);
    try value.writeByte(@intFromEnum(protocol.DataTag.object));
    try value.writeInt(u32, 2);
    try value.writeString("items");
    try value.writeByte(@intFromEnum(protocol.DataTag.array));
    try value.writeInt(u32, 3);
    try value.writeByte(@intFromEnum(protocol.DataTag.true_value));
    try value.writeByte(@intFromEnum(protocol.DataTag.number));
    try value.writeInt(u64, @bitCast(@as(f64, 42)));
    try value.writeByte(@intFromEnum(protocol.DataTag.string));
    try value.writeString("value");
    try value.writeString("nested");
    try value.writeByte(@intFromEnum(protocol.DataTag.object));
    try value.writeInt(u32, 1);
    try value.writeString("ok");
    try value.writeByte(@intFromEnum(protocol.DataTag.true_value));

    var request_storage: [2048]u8 = undefined;
    const base = try buildRequest(
        "export default async function workflow(_, args) { return args; }",
        value.written(),
        &.{.{ .key = "visible", .tag = .output, .payload = value.written() }},
        &request_storage,
    );
    const mutation = try allocator.alloc(u8, base.len + 16);
    defer allocator.free(mutation);
    var random = std.Random.DefaultPrng.init(0x5052_4f54_4f43_4f4c);
    for (0..512) |iteration| {
        const bytes = mutateFrame(base, mutation, random.random(), iteration);
        try harness.evaluateDeterministically(bytes);
    }
}

fn fuzzJsValueEncoder(harness: *Harness) !void {
    var random = std.Random.DefaultPrng.init(0x4a53_5641_4c55_4553);
    var source_storage: [4096]u8 = undefined;
    var request_storage: [8192]u8 = undefined;
    const null_value = [_]u8{@intFromEnum(protocol.DataTag.null_value)};
    const invalid = [_][]const u8{
        "undefined",
        "NaN",
        "Infinity",
        "Symbol('value')",
        "1n",
        "(() => null)",
        "Object.defineProperty({}, 'x', { get() { return 1; }, enumerable: true })",
        "(() => { const value = {}; value.self = value; return value; })()",
    };

    for (0..256) |iteration| {
        const expression = if (iteration % 5 == 0)
            invalid[random.random().uintLessThan(usize, invalid.len)]
        else expression: {
            const first = random.random().intRangeAtMost(i32, -10_000, 10_000);
            const second = random.random().intRangeAtMost(i32, -10_000, 10_000);
            const order = random.random().boolean();
            break :expression if (order)
                try std.fmt.bufPrint(
                    source_storage[2048..],
                    "{{ zebra: [{d}, {{ beta: {d}, alpha: true }}], alpha: 'value-{d}' }}",
                    .{ first, second, iteration },
                )
            else
                try std.fmt.bufPrint(
                    source_storage[2048..],
                    "{{ alpha: 'value-{d}', zebra: [{d}, {{ alpha: true, beta: {d} }}] }}",
                    .{ iteration, first, second },
                );
        };
        const source = try std.fmt.bufPrint(
            source_storage[0..2048],
            "export default async function workflow() {{ return {s}; }}",
            .{expression},
        );
        const input = try buildRequest(source, &null_value, &.{}, &request_storage);
        try harness.evaluateDeterministically(input);
    }
}

fn fuzzResultDecoder(allocator: std.mem.Allocator, harness: *Harness) !void {
    var result_storage: [256]u8 = undefined;
    var result = protocol.Builder.init(&result_storage);
    try result.writeByte(@intFromEnum(protocol.DataTag.object));
    try result.writeInt(u32, 2);
    try result.writeString("answer");
    try result.writeByte(@intFromEnum(protocol.DataTag.array));
    try result.writeInt(u32, 2);
    try result.writeByte(@intFromEnum(protocol.DataTag.string));
    try result.writeString("yes");
    try result.writeByte(@intFromEnum(protocol.DataTag.number));
    try result.writeInt(u64, @bitCast(@as(f64, 7)));
    try result.writeString("details");
    try result.writeByte(@intFromEnum(protocol.DataTag.object));
    try result.writeInt(u32, 1);
    try result.writeString("complete");
    try result.writeByte(@intFromEnum(protocol.DataTag.true_value));

    const mutation = try allocator.alloc(u8, result.written().len + 16);
    defer allocator.free(mutation);
    var random = std.Random.DefaultPrng.init(0x5245_5355_4c54_5354);
    var request_storage: [4096]u8 = undefined;
    const null_value = [_]u8{@intFromEnum(protocol.DataTag.null_value)};
    for (0..512) |iteration| {
        const payload = mutateFrame(result.written(), mutation, random.random(), iteration);
        const input = try buildRequest(
            "export default async function workflow({ agent }) { return await agent({ key: 'result', task: 'work' }); }",
            &null_value,
            &.{.{ .key = "result", .tag = .output, .payload = payload }},
            &request_storage,
        );
        try harness.evaluateDeterministically(input);
    }
}

fn fuzzWorkflowCapability(harness: *Harness) !void {
    var random = std.Random.DefaultPrng.init(0x574f_524b_464c_4f57);
    var source_storage: [16 * 1024]u8 = undefined;
    var request_storage: [20 * 1024]u8 = undefined;
    const null_value = [_]u8{@intFromEnum(protocol.DataTag.null_value)};
    const invalid_calls = [_][]const u8{
        "agent()",
        "agent({ key: '', task: 'work' })",
        "agent({ key: 'same', task: 'one' }); agent({ key: 'same', task: 'two' })",
        "agent(Object.defineProperty({ task: 'work' }, 'key', { get() { return 'a'; }, enumerable: true }))",
    };

    for (0..256) |iteration| {
        var used: usize = 0;
        used += (try std.fmt.bufPrint(
            source_storage[used..],
            "export default async function workflow({{ agent }}, args) {{ const calls = []; ",
            .{},
        )).len;
        if (iteration % 7 == 0) {
            const invalid = invalid_calls[random.random().uintLessThan(usize, invalid_calls.len)];
            used += (try std.fmt.bufPrint(source_storage[used..], "{s}; ", .{invalid})).len;
        } else {
            const call_count = random.random().intRangeAtMost(u8, 1, 4);
            for (0..call_count) |call_index| {
                const value = random.random().intRangeAtMost(i32, -1000, 1000);
                if (random.random().boolean()) {
                    used += (try std.fmt.bufPrint(
                        source_storage[used..],
                        "calls.push(agent({{ key: 'call-{d}', task: 'work', input: {{ value: {d}, index: {d} }} }})); ",
                        .{ call_index, value, call_index },
                    )).len;
                } else {
                    used += (try std.fmt.bufPrint(
                        source_storage[used..],
                        "calls.push(agent({{ task: 'work', key: 'call-{d}', input: {{ index: {d}, value: {d} }} }})); ",
                        .{ call_index, call_index, value },
                    )).len;
                }
            }
        }
        const endings = [_][]const u8{
            "return await Promise.all(calls); }",
            "return (await Promise.allSettled(calls)).length; }",
            "await Promise.all(calls); return args; }",
            "return args; }",
        };
        const ending = endings[random.random().uintLessThan(usize, endings.len)];
        if (ending.len > source_storage.len - used) return error.SourceBufferExceeded;
        @memcpy(source_storage[used..][0..ending.len], ending);
        used += ending.len;
        const input = try buildRequest(source_storage[0..used], &null_value, &.{}, &request_storage);
        try harness.evaluateDeterministically(input);
    }
}

fn mutateFrame(
    base: []const u8,
    storage: []u8,
    random: std.Random,
    iteration: usize,
) []const u8 {
    @memcpy(storage[0..base.len], base);
    if (iteration % 17 == 0) return storage[0..base.len];
    var length = base.len;
    switch (iteration % 5) {
        0 => length = random.uintLessThan(usize, length + 1),
        1 => {
            const start = random.uintLessThan(usize, length);
            const run = @min(random.intRangeAtMost(usize, 1, 8), length - start);
            for (storage[start .. start + run]) |*byte| byte.* ^= random.int(u8) | 1;
        },
        2 => {
            const start = random.uintLessThan(usize, length);
            const run = @min(random.intRangeAtMost(usize, 1, 8), length - start);
            for (start..length - run) |index| storage[index] = storage[index + run];
            length -= run;
        },
        3 => {
            const start = random.uintLessThan(usize, length + 1);
            const run = random.intRangeAtMost(usize, 1, 8);
            var index = length;
            while (index > start) {
                index -= 1;
                storage[index + run] = storage[index];
            }
            for (storage[start .. start + run]) |*byte| byte.* = random.int(u8);
            length += run;
        },
        4 => {
            if (length >= 4) {
                const start = random.uintLessThan(usize, length - 3);
                std.mem.writeInt(u32, storage[start..][0..4], random.int(u32), .little);
            }
        },
        else => unreachable,
    }
    return storage[0..length];
}

fn buildRequest(
    source: []const u8,
    arguments: []const u8,
    visible: []const Visible,
    storage: []u8,
) ![]const u8 {
    var builder = protocol.Builder.init(storage);
    try protocol.writeHeader(&builder, protocol.request_magic);
    try builder.writeString(source);
    try builder.writeBytes(arguments);
    try builder.writeInt(u16, @intCast(visible.len));
    for (visible) |entry| {
        try builder.writeString(entry.key);
        try builder.writeByte(@intFromEnum(entry.tag));
        switch (entry.tag) {
            .output => try builder.writeBytes(entry.payload),
            .failure => try builder.writeString(entry.payload),
        }
    }
    return builder.written();
}

fn validateOutcome(bytes: []const u8) !void {
    var cursor = protocol.Cursor.init(bytes);
    try protocol.readHeader(&cursor, protocol.outcome_magic);
    const tag = std.enums.fromInt(protocol.OutcomeTag, try cursor.readByte()) orelse
        return error.InvalidOutcomeTag;
    switch (tag) {
        .completed => _ = try cursor.skipValue(protocol.Limits.workflow_output_bytes),
        .blocked => {
            const count = try cursor.readInt(u16);
            if (count > protocol.Limits.pending_agent_calls) return error.ExcessiveBlockedTurns;
            for (0..count) |_| {
                const descriptor_bytes = try cursor.readLengthBytes(protocol.Limits.workflow_output_bytes);
                var descriptor = protocol.Cursor.init(descriptor_bytes);
                _ = try descriptor.skipValue(protocol.Limits.workflow_output_bytes);
                try descriptor.finish();
            }
        },
        .failed, .deadlocked, .resource_exceeded, .protocol_failed => _ = try cursor.readString(protocol.Limits.diagnostic_bytes),
    }
    try cursor.finish();
}
