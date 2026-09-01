const std = @import("std");
const evaluator = @import("workflow_evaluator.zig");
const protocol = @import("workflow_protocol.zig");

const VisibleFixture = struct {
    key: []const u8,
    tag: protocol.VisibleTag,
    payload: []const u8,
};

fn request(
    source: []const u8,
    arguments: []const u8,
    visible: []const VisibleFixture,
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

fn nullValue(storage: []u8) ![]const u8 {
    var builder = protocol.Builder.init(storage);
    try builder.writeByte(@intFromEnum(protocol.DataTag.null_value));
    return builder.written();
}

fn stringValue(value: []const u8, storage: []u8) ![]const u8 {
    var builder = protocol.Builder.init(storage);
    try builder.writeByte(@intFromEnum(protocol.DataTag.string));
    try builder.writeString(value);
    return builder.written();
}

fn evaluateRequest(input: []const u8, output: []u8, bridge: []u8) !protocol.Cursor {
    const result = evaluator.evaluate(input, output, bridge);
    var cursor = protocol.Cursor.init(result);
    try protocol.readHeader(&cursor, protocol.outcome_magic);
    return cursor;
}

fn evaluateSource(source: []const u8, output: []u8, bridge: []u8) !protocol.Cursor {
    var input: [protocol.Limits.source_bytes + 64]u8 = undefined;
    var arguments: [1]u8 = undefined;
    return evaluateRequest(
        try request(source, try nullValue(&arguments), &.{}, &input),
        output,
        bridge,
    );
}

fn expectSimpleOutcome(source: []const u8, expected: protocol.OutcomeTag, expected_code: []const u8) !void {
    const bridge = try std.testing.allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    defer std.testing.allocator.free(bridge);
    const output = try std.testing.allocator.alloc(u8, protocol.Limits.output_frame_bytes);
    defer std.testing.allocator.free(output);
    var cursor = try evaluateSource(source, output, bridge);
    const actual = try cursor.readByte();
    if (actual != @intFromEnum(expected)) {
        std.debug.print("unexpected outcome for source: {s}\n", .{source});
        return error.UnexpectedOutcome;
    }
    try std.testing.expectEqualStrings(expected_code, try cursor.readString(protocol.Limits.diagnostic_bytes));
    try cursor.finish();
}

test "standard async default export completes with strict data" {
    const bridge = try std.testing.allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    defer std.testing.allocator.free(bridge);
    const output = try std.testing.allocator.alloc(u8, protocol.Limits.output_frame_bytes);
    defer std.testing.allocator.free(output);
    var cursor = try evaluateSource(
        "export default async function workflow({ agent }, args) { void agent; void args; return { ok: true }; }",
        output,
        bridge,
    );
    try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.completed), try cursor.readByte());
    try std.testing.expectEqual(@intFromEnum(protocol.DataTag.object), try cursor.readByte());
    try std.testing.expectEqual(1, try cursor.readInt(u32));
    try std.testing.expectEqualStrings("ok", try cursor.readString(16));
    try std.testing.expectEqual(@intFromEnum(protocol.DataTag.true_value), try cursor.readByte());
    try cursor.finish();
}

test "allowlisted realm keeps deterministic joins and removes ambient authority" {
    const source =
        \\export default async function workflow({ agent }, args) {
        \\  const ambient = [
        \\    typeof eval, typeof Function, typeof (() => {}).constructor,
        \\    typeof (async () => {}).constructor, typeof (function*(){}).constructor,
        \\    typeof (async function*(){}).constructor, typeof ({}).constructor.constructor,
        \\    typeof Math.random, typeof globalThis.process, typeof globalThis.env,
        \\    typeof globalThis.std, typeof globalThis.os, typeof globalThis.Date,
        \\    typeof globalThis.performance, typeof globalThis.fetch,
        \\    typeof globalThis.WebSocket, typeof globalThis.crypto,
        \\    typeof globalThis.setTimeout, typeof globalThis.setInterval,
        \\    typeof globalThis.queueMicrotask, typeof globalThis.require,
        \\  ];
        \\  if (typeof Promise.race !== 'undefined' || typeof Promise.any !== 'undefined') throw new Error('timing join');
        \\  if (!Object.isFrozen(agent) || !Object.isFrozen(args)) throw new Error('mutable capability');
        \\  const all = await Promise.all([Promise.resolve(1), Promise.resolve(2)]);
        \\  const settled = await Promise.allSettled([Promise.resolve(1)]);
        \\  if (all[1] !== 2 || settled[0].status !== 'fulfilled') throw new Error('join failed');
        \\  return ambient;
        \\}
    ;
    const bridge = try std.testing.allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    defer std.testing.allocator.free(bridge);
    const output = try std.testing.allocator.alloc(u8, protocol.Limits.output_frame_bytes);
    defer std.testing.allocator.free(output);
    var cursor = try evaluateSource(source, output, bridge);
    try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.completed), try cursor.readByte());
    try std.testing.expectEqual(@intFromEnum(protocol.DataTag.array), try cursor.readByte());
    const count = try cursor.readInt(u32);
    try std.testing.expectEqual(21, count);
    for (0..count) |index| {
        try std.testing.expectEqual(@intFromEnum(protocol.DataTag.string), try cursor.readByte());
        const value = try cursor.readString(32);
        if (!std.mem.eql(u8, value, "undefined")) {
            std.debug.print("ambient capability index {d}: {s}\n", .{ index, value });
            return error.AmbientCapabilityPresent;
        }
    }
    try cursor.finish();
}

test "static and caught dynamic imports are protocol failures" {
    try expectSimpleOutcome(
        "import value from 'elsewhere'; export default async function workflow() { return value; }",
        .protocol_failed,
        "ImportsDisabled",
    );
    try expectSimpleOutcome(
        "export default async function workflow() { try { await import('elsewhere'); } catch {} return null; }",
        .protocol_failed,
        "ImportsDisabled",
    );
}

test "only the standard async default-export module form is accepted" {
    try expectSimpleOutcome(
        "async function workflow() { return null; }",
        .failed,
        "WorkflowDefaultMustBeAsyncFunction",
    );
    try expectSimpleOutcome(
        "export default function workflow() { return Promise.resolve(null); }",
        .failed,
        "WorkflowDefaultMustBeAsyncFunction",
    );
    try expectSimpleOutcome(
        "export default async function workflow( {",
        .failed,
        "WorkflowDefinitionInvalid",
    );
}

test "root terminal states remain distinct" {
    try expectSimpleOutcome(
        "export default async function workflow() { throw new Error('no'); }",
        .failed,
        "WorkflowRejected",
    );
    try expectSimpleOutcome(
        "export default async function workflow() { await new Promise(() => {}); return null; }",
        .deadlocked,
        "RootPendingWithoutMicrotasks",
    );
    try expectSimpleOutcome(
        "export default async function workflow() { Promise.reject(new Error('detached')); return null; }",
        .failed,
        "UnhandledRejection",
    );
}

test "unresolved Agent Calls block even after detached root fulfillment" {
    const sources = [_][]const u8{
        "export default async function workflow({ agent }) { return await agent({ key: 'a', task: 'work' }); }",
        "export default async function workflow({ agent }) { agent({ key: 'a', task: 'work' }); return 1; }",
    };
    for (sources) |source| {
        const bridge = try std.testing.allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
        defer std.testing.allocator.free(bridge);
        const output = try std.testing.allocator.alloc(u8, protocol.Limits.output_frame_bytes);
        defer std.testing.allocator.free(output);
        var cursor = try evaluateSource(source, output, bridge);
        try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.blocked), try cursor.readByte());
        try std.testing.expectEqual(1, try cursor.readInt(u16));
        var descriptor = protocol.Cursor.init(try cursor.readLengthBytes(protocol.Limits.workflow_output_bytes));
        _ = try descriptor.skipValue(protocol.Limits.workflow_output_bytes);
        try descriptor.finish();
        try cursor.finish();
    }
}

test "visible Agent Call output settles agent" {
    var output_value_storage: [64]u8 = undefined;
    const output_value = try stringValue("done", &output_value_storage);
    var argument_storage: [1]u8 = undefined;
    var input_storage: [protocol.Limits.source_bytes + 256]u8 = undefined;
    const input = try request(
        "export default async function workflow({ agent }) { return await agent({ key: 'a', task: 'work' }); }",
        try nullValue(&argument_storage),
        &.{.{ .key = "a", .tag = .output, .payload = output_value }},
        &input_storage,
    );
    const bridge = try std.testing.allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    defer std.testing.allocator.free(bridge);
    const output = try std.testing.allocator.alloc(u8, protocol.Limits.output_frame_bytes);
    defer std.testing.allocator.free(output);
    var cursor = try evaluateRequest(input, output, bridge);
    try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.completed), try cursor.readByte());
    try std.testing.expectEqual(@intFromEnum(protocol.DataTag.string), try cursor.readByte());
    try std.testing.expectEqualStrings("done", try cursor.readString(16));
    try cursor.finish();
}

test "arguments and visible outputs are immutable deep data" {
    var data_storage: [128]u8 = undefined;
    var data = protocol.Builder.init(&data_storage);
    try data.writeByte(@intFromEnum(protocol.DataTag.object));
    try data.writeInt(u32, 1);
    try data.writeString("nested");
    try data.writeByte(@intFromEnum(protocol.DataTag.array));
    try data.writeInt(u32, 1);
    try data.writeByte(@intFromEnum(protocol.DataTag.number));
    try data.writeInt(u64, @bitCast(@as(f64, 1)));

    var input_storage: [protocol.Limits.source_bytes + 512]u8 = undefined;
    const input = try request(
        "export default async function workflow({ agent }, args) { const output = await agent({ key: 'a', task: 'work' }); return Object.isFrozen(args) && Object.isFrozen(args.nested) && Object.isFrozen(output) && Object.isFrozen(output.nested); }",
        data.written(),
        &.{.{ .key = "a", .tag = .output, .payload = data.written() }},
        &input_storage,
    );
    const bridge = try std.testing.allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    defer std.testing.allocator.free(bridge);
    const output = try std.testing.allocator.alloc(u8, protocol.Limits.output_frame_bytes);
    defer std.testing.allocator.free(output);
    var cursor = try evaluateRequest(input, output, bridge);
    try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.completed), try cursor.readByte());
    try std.testing.expectEqual(@intFromEnum(protocol.DataTag.true_value), try cursor.readByte());
    try cursor.finish();
}

test "protocol object keys define own data properties" {
    var data_storage: [128]u8 = undefined;
    var data = protocol.Builder.init(&data_storage);
    try data.writeByte(@intFromEnum(protocol.DataTag.object));
    try data.writeInt(u32, 1);
    try data.writeString("__proto__");
    try data.writeByte(@intFromEnum(protocol.DataTag.object));
    try data.writeInt(u32, 1);
    try data.writeString("safe");
    try data.writeByte(@intFromEnum(protocol.DataTag.true_value));

    var input_storage: [protocol.Limits.source_bytes + 256]u8 = undefined;
    const input = try request(
        "export default async function workflow(_, args) { return Object.prototype.hasOwnProperty.call(args, '__proto__') && Object.getPrototypeOf(args) === Object.prototype && args.__proto__.safe; }",
        data.written(),
        &.{},
        &input_storage,
    );
    const bridge = try std.testing.allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    defer std.testing.allocator.free(bridge);
    const output = try std.testing.allocator.alloc(u8, protocol.Limits.output_frame_bytes);
    defer std.testing.allocator.free(output);
    var cursor = try evaluateRequest(input, output, bridge);
    try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.completed), try cursor.readByte());
    try std.testing.expectEqual(@intFromEnum(protocol.DataTag.true_value), try cursor.readByte());
    try cursor.finish();
}

test "unreferenced visible output is validated before evaluation" {
    var invalid_storage: [64]u8 = undefined;
    var invalid = protocol.Builder.init(&invalid_storage);
    try invalid.writeByte(@intFromEnum(protocol.DataTag.object));
    try invalid.writeInt(u32, 2);
    try invalid.writeString("same");
    try invalid.writeByte(@intFromEnum(protocol.DataTag.null_value));
    try invalid.writeString("same");
    try invalid.writeByte(@intFromEnum(protocol.DataTag.true_value));

    var argument_storage: [1]u8 = undefined;
    var input_storage: [protocol.Limits.source_bytes + 256]u8 = undefined;
    const input = try request(
        "export default async function workflow() { return null; }",
        try nullValue(&argument_storage),
        &.{.{ .key = "unused", .tag = .output, .payload = invalid.written() }},
        &input_storage,
    );
    const bridge = try std.testing.allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    defer std.testing.allocator.free(bridge);
    var output: [256]u8 = undefined;
    var cursor = try evaluateRequest(input, &output, bridge);
    try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.protocol_failed), try cursor.readByte());
    try std.testing.expectEqualStrings("DuplicateKey", try cursor.readString(64));
    try cursor.finish();
}

test "arguments are structurally validated before evaluation" {
    var invalid_storage: [64]u8 = undefined;
    var invalid = protocol.Builder.init(&invalid_storage);
    try invalid.writeByte(@intFromEnum(protocol.DataTag.object));
    try invalid.writeInt(u32, 2);
    try invalid.writeString("same");
    try invalid.writeByte(@intFromEnum(protocol.DataTag.null_value));
    try invalid.writeString("same");
    try invalid.writeByte(@intFromEnum(protocol.DataTag.true_value));

    var input_storage: [protocol.Limits.source_bytes + 256]u8 = undefined;
    const input = try request(
        "export default async function workflow() { return null; }",
        invalid.written(),
        &.{},
        &input_storage,
    );
    const bridge = try std.testing.allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    defer std.testing.allocator.free(bridge);
    var output: [256]u8 = undefined;
    var cursor = try evaluateRequest(input, &output, bridge);
    try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.protocol_failed), try cursor.readByte());
    try std.testing.expectEqualStrings("DuplicateKey", try cursor.readString(64));
    try cursor.finish();
}

test "visible Turn Outputs share one aggregate byte budget" {
    const payload_bytes = protocol.Limits.visible_output_bytes / 2 + 1;
    const text = try std.testing.allocator.alloc(u8, payload_bytes);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    const first_storage = try std.testing.allocator.alloc(u8, payload_bytes + 5);
    defer std.testing.allocator.free(first_storage);
    const second_storage = try std.testing.allocator.alloc(u8, payload_bytes + 5);
    defer std.testing.allocator.free(second_storage);
    const first = try stringValue(text, first_storage);
    const second = try stringValue(text, second_storage);
    var argument_storage: [1]u8 = undefined;
    const input_storage = try std.testing.allocator.alloc(u8, protocol.Limits.input_frame_bytes);
    defer std.testing.allocator.free(input_storage);
    const input = try request(
        "export default async function workflow() { return null; }",
        try nullValue(&argument_storage),
        &.{
            .{ .key = "first", .tag = .output, .payload = first },
            .{ .key = "second", .tag = .output, .payload = second },
        },
        input_storage,
    );
    const bridge = try std.testing.allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    defer std.testing.allocator.free(bridge);
    var output: [256]u8 = undefined;
    var cursor = try evaluateRequest(input, &output, bridge);
    try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.protocol_failed), try cursor.readByte());
    try std.testing.expectEqualStrings("ExcessiveBytes", try cursor.readString(64));
    try cursor.finish();
}

test "strict output bridge rejects unsupported JavaScript values" {
    const expressions = [_][]const u8{
        "undefined",
        "NaN",
        "Infinity",
        "9007199254740992",
        "Object.create({})",
        "Object.defineProperty({}, 'x', { get() { return 1; }, enumerable: true })",
        "(() => { const x = {}; x.self = x; return x; })()",
        "[,,,]",
        "(() => { const x = [1]; x.extra = 2; return x; })()",
        "'\\uD800'",
        "Symbol('x')",
        "() => null",
        "1n",
        "({ promise: Promise.resolve(null) })",
        "typeof Proxy === 'undefined' ? (() => null) : new Proxy({}, {})",
    };
    for (expressions) |expression| {
        var source_storage: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(
            &source_storage,
            "export default async function workflow() {{ return {s}; }}",
            .{expression},
        );
        try expectSimpleOutcome(source, .failed, "WorkflowOutputInvalid");
    }
}

test "valid surrogate pairs and negative zero cross canonically" {
    const bridge = try std.testing.allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    defer std.testing.allocator.free(bridge);
    const output = try std.testing.allocator.alloc(u8, protocol.Limits.output_frame_bytes);
    defer std.testing.allocator.free(output);
    var cursor = try evaluateSource(
        "export default async function workflow() { return { text: '\\uD83D\\uDE80', number: -0 }; }",
        output,
        bridge,
    );
    try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.completed), try cursor.readByte());
    try std.testing.expectEqual(@intFromEnum(protocol.DataTag.object), try cursor.readByte());
    try std.testing.expectEqual(2, try cursor.readInt(u32));
    try std.testing.expectEqualStrings("number", try cursor.readString(16));
    try std.testing.expectEqual(@intFromEnum(protocol.DataTag.number), try cursor.readByte());
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 0.0))), try cursor.readInt(u64));
    try std.testing.expectEqualStrings("text", try cursor.readString(16));
    try std.testing.expectEqual(@intFromEnum(protocol.DataTag.string), try cursor.readByte());
    try std.testing.expectEqualStrings("🚀", try cursor.readString(16));
    try cursor.finish();
}

test "object output and nested Turn descriptor keys are canonical" {
    const bridge = try std.testing.allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    defer std.testing.allocator.free(bridge);
    const output = try std.testing.allocator.alloc(u8, protocol.Limits.output_frame_bytes);
    defer std.testing.allocator.free(output);
    var canonical_output = try evaluateSource(
        "export default async function workflow() { return { zebra: 1, alpha: { delta: 2, beta: 3 } }; }",
        output,
        bridge,
    );
    try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.completed), try canonical_output.readByte());
    try std.testing.expectEqual(@intFromEnum(protocol.DataTag.object), try canonical_output.readByte());
    try std.testing.expectEqual(2, try canonical_output.readInt(u32));
    try std.testing.expectEqualStrings("alpha", try canonical_output.readString(16));
    try std.testing.expectEqual(@intFromEnum(protocol.DataTag.object), try canonical_output.readByte());
    try std.testing.expectEqual(2, try canonical_output.readInt(u32));
    try std.testing.expectEqualStrings("beta", try canonical_output.readString(16));
    _ = try canonical_output.skipValue(16);
    try std.testing.expectEqualStrings("delta", try canonical_output.readString(16));
    _ = try canonical_output.skipValue(16);
    try std.testing.expectEqualStrings("zebra", try canonical_output.readString(16));
    _ = try canonical_output.skipValue(16);
    try canonical_output.finish();

    var canonical_descriptor = try evaluateSource(
        "export default async function workflow({ agent }) { agent({ key: 'same', task: 'work', input: { zebra: 1, alpha: { delta: 2, beta: 3 } }, schema: { type: 'object', properties: { zebra: { type: 'number' }, alpha: { type: 'number' } }, required: ['alpha'], additionalProperties: false } }); agent({ key: 'same', task: 'work', input: { alpha: { beta: 3, delta: 2 }, zebra: 1 }, schema: { additionalProperties: false, required: ['alpha'], properties: { alpha: { type: 'number' }, zebra: { type: 'number' } }, type: 'object' } }); await new Promise(() => {}); }",
        output,
        bridge,
    );
    try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.blocked), try canonical_descriptor.readByte());
    try std.testing.expectEqual(1, try canonical_descriptor.readInt(u16));
    _ = try canonical_descriptor.readLengthBytes(protocol.Limits.workflow_output_bytes);
    try canonical_descriptor.finish();
}

test "depth, width, bytes, and microtask limits are independently classified" {
    try expectSimpleOutcome(
        "export default async function workflow() { let value = null; for (let i = 0; i < 33; i++) value = [value]; return value; }",
        .failed,
        "WorkflowOutputInvalid",
    );
    try expectSimpleOutcome(
        "export default async function workflow() { return Array(4097).fill(null); }",
        .failed,
        "WorkflowOutputInvalid",
    );
    try expectSimpleOutcome(
        "export default async function workflow() { return Array.from({ length: 2049 }, () => [null]); }",
        .failed,
        "WorkflowOutputInvalid",
    );
    try expectSimpleOutcome(
        "export default async function workflow() { return 'x'.repeat(70000); }",
        .resource_exceeded,
        "WorkflowOutputBytes",
    );
    try expectSimpleOutcome(
        "export default async function workflow() { const loop = () => Promise.resolve().then(loop); loop(); await new Promise(() => {}); }",
        .resource_exceeded,
        "Microtasks",
    );
}

test "engine exceptions cannot forge host-observed resource outcomes" {
    try expectSimpleOutcome(
        "export default async function workflow() { const values = []; while (true) values.push('x'.repeat(100000)); }",
        .failed,
        "WorkflowRejected",
    );
    try expectSimpleOutcome(
        "export default async function workflow() { function recurse() { return recurse(); } return recurse(); }",
        .failed,
        "WorkflowRejected",
    );
    try expectSimpleOutcome(
        "export default async function workflow() { throw new Error('out of memory'); }",
        .failed,
        "WorkflowRejected",
    );
    try expectSimpleOutcome(
        "export default async function workflow() { throw new Error('Maximum call stack size exceeded'); }",
        .failed,
        "WorkflowRejected",
    );
    try expectSimpleOutcome(
        "throw new Error('out of memory'); export default async function workflow() { return null; }",
        .failed,
        "WorkflowDefinitionInvalid",
    );
    try expectSimpleOutcome(
        "const values = []; while (true) values.push('x'.repeat(100000)); export default async function workflow() { return null; }",
        .failed,
        "WorkflowDefinitionInvalid",
    );
    try expectSimpleOutcome(
        "function recurse() { return recurse(); } recurse(); export default async function workflow() { return null; }",
        .failed,
        "WorkflowDefinitionInvalid",
    );
    try expectSimpleOutcome(
        "while (true) {} export default async function workflow() { return null; }",
        .resource_exceeded,
        "CpuTime",
    );
}

test "host-observed pending-Agent-Call bound is a resource outcome" {
    try expectSimpleOutcome(
        "export default async function workflow({ agent }) { for (let i = 0; i < 257; i++) agent({ key: String(i), task: 'work' }); await new Promise(() => {}); }",
        .resource_exceeded,
        "PendingAgentCalls",
    );
    try expectSimpleOutcome(
        "export default async function workflow() { while (true) {} }",
        .resource_exceeded,
        "CpuTime",
    );
    try expectSimpleOutcome(
        "export default async function workflow({ agent }) { try { agent({ key: 'a', task: 'work', input: Array.from({ length: 2047 }, () => [null]) }); } catch {} return null; }",
        .resource_exceeded,
        "AgentDescriptor",
    );
    try expectSimpleOutcome(
        "export default async function workflow({ agent }) { for (let i = 0; i < 257; i++) { try { agent({ key: String(i), task: 'work' }); } catch {} } return null; }",
        .resource_exceeded,
        "PendingAgentCalls",
    );
}

test "visible stable failures reject with one frozen TurnError" {
    var argument_storage: [1]u8 = undefined;
    var input_storage: [protocol.Limits.source_bytes + 256]u8 = undefined;
    const input = try request(
        "export default async function workflow({ agent }) { const settled = await Promise.allSettled([agent({ key: 'a', task: 'work' })]); const error = settled[0].reason; return { status: settled[0].status, frozen: Object.isFrozen(error), code: error.code, key: error.agent_call_key }; }",
        try nullValue(&argument_storage),
        &.{.{ .key = "a", .tag = .failure, .payload = "TurnFailed" }},
        &input_storage,
    );
    const bridge = try std.testing.allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    defer std.testing.allocator.free(bridge);
    const output = try std.testing.allocator.alloc(u8, protocol.Limits.output_frame_bytes);
    defer std.testing.allocator.free(output);
    var cursor = try evaluateRequest(input, output, bridge);
    try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.completed), try cursor.readByte());
    _ = try cursor.skipValue(protocol.Limits.workflow_output_bytes);
    try cursor.finish();
}

test "agent bridge validates before publishing any request" {
    try expectSimpleOutcome(
        "export default async function workflow({ agent }) { const descriptor = Object.defineProperty({}, 'key', { get() { return 'a'; }, enumerable: true }); descriptor.task = 'work'; await agent(descriptor); return null; }",
        .failed,
        "TurnRequestInvalid",
    );
    try expectSimpleOutcome(
        "export default async function workflow({ agent }) { agent({ key: 'a', task: 'one' }); agent({ key: 'a', task: 'two' }); return null; }",
        .failed,
        "TurnRequestInvalid",
    );
    try expectSimpleOutcome(
        "export default async function workflow({ agent }) { await agent({ key: 'a', task: 'work', input: undefined }); return null; }",
        .failed,
        "TurnRequestInvalid",
    );
    try expectSimpleOutcome(
        "export default async function workflow({ agent }) { await agent({ key: 'a', task: 'work', execution_profile: undefined }); return null; }",
        .failed,
        "TurnRequestInvalid",
    );
    try expectSimpleOutcome(
        "export default async function workflow({ agent }) { await agent({ key: 'a', task: 'work', input: Array.from({ length: 2047 }, () => [null]) }); return null; }",
        .resource_exceeded,
        "AgentDescriptor",
    );
}

test "fixed bridge allocation failure is typed and publishes no partial output" {
    var input_storage: [256]u8 = undefined;
    var argument_storage: [1]u8 = undefined;
    const input = try request(
        "export default async function workflow() { return null; }",
        try nullValue(&argument_storage),
        &.{},
        &input_storage,
    );
    var output: [256]u8 = undefined;
    var tiny_bridge: [64]u8 = undefined;
    var cursor = try evaluateRequest(input, &output, &tiny_bridge);
    try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.resource_exceeded), try cursor.readByte());
    try std.testing.expectEqualStrings("BridgeArena", try cursor.readString(64));
    try cursor.finish();

    try expectSimpleOutcome(
        "export default async function workflow({ agent }) { const input = 'x'.repeat(20000); for (let i = 0; i < 256; i++) agent({ key: String(i), task: 'work', input }); return null; }",
        .resource_exceeded,
        "BridgeArena",
    );
}

test "repeated construction and teardown retains no evaluator state" {
    const bridge = try std.testing.allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    defer std.testing.allocator.free(bridge);
    const output = try std.testing.allocator.alloc(u8, protocol.Limits.output_frame_bytes);
    defer std.testing.allocator.free(output);
    for (0..64) |_| {
        var cursor = try evaluateSource(
            "export default async function workflow() { return 1; }",
            output,
            bridge,
        );
        try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.completed), try cursor.readByte());
    }
}

test "private protocol rejects an empty frame without entering QuickJS" {
    var output: [256]u8 = undefined;
    var bridge: [1024]u8 = undefined;
    const result = evaluator.evaluate(&.{}, &output, &bridge);
    var cursor = protocol.Cursor.init(result);
    try protocol.readHeader(&cursor, protocol.outcome_magic);
    try std.testing.expectEqual(@intFromEnum(protocol.OutcomeTag.protocol_failed), try cursor.readByte());
    try std.testing.expectEqualStrings("Truncated", try cursor.readString(64));
    try cursor.finish();
}
