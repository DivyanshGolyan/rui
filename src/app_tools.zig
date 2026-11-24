//! The app tools a lane root declares: one JSON array document, validated in this one place.
//! Every Store and Host path that accepts `appTools` calls `parse`; no other path reads the document.
const std = @import("std");
const tool_name = @import("tool_name.zig");
const tool_record = @import("tool_record.zig");
const tool_presentation = @import("tool_presentation.zig");
const shape = @import("mcp/shape.zig");

/// Declared records per lane root. The Store's round budget for one configure is sized to this.
pub const max_records = 16;
/// The largest document `parse` accepts; a larger one is refused by name before it is read.
pub const max_document_bytes = 64 * 1024;
/// Bytes the parse may use for the document copy, the JSON tree and the saved text of one declaration.
pub const arena_bytes = 512 * 1024;

pub const Refusal = enum {
    invalid_app_tools,
    app_tools_too_large,
    invalid_app_tool_name,
    duplicate_app_tool_name,
    app_tool_built_in_clash,
    invalid_app_tool_policy,
};

/// A declaration that passed every check. Its slices point into the arena `parse` was given.
pub const Declaration = struct {
    /// Sorted by name, which `tool_record.HostToolSet` requires for `find` and `valid`.
    records: []tool_record.Record,
    digests: [][32]u8,

    pub fn toolSet(declaration: *const Declaration) tool_record.HostToolSet {
        return .{ .records = declaration.records, .digests = declaration.digests };
    }
};

pub const Parsed = union(enum) { declared: Declaration, refused: Refusal };

const member_names = [_][]const u8{ "name", "description", "input_schema", "replay", "restart_limit", "wait_ms" };

/// Validates `bytes` as a declaration. `arena` owns every slice the result points to and must outlive it.
/// An arena that runs out is a refusal by size, never a partial declaration.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) Parsed {
    if (bytes.len > max_document_bytes) return .{ .refused = .app_tools_too_large };
    return parseInArena(arena, bytes) catch |err| switch (err) {
        error.OutOfMemory => .{ .refused = .app_tools_too_large },
        error.InvalidAppTools => .{ .refused = .invalid_app_tools },
        error.InvalidAppToolName => .{ .refused = .invalid_app_tool_name },
        error.DuplicateAppToolName => .{ .refused = .duplicate_app_tool_name },
        error.AppToolBuiltInClash => .{ .refused = .app_tool_built_in_clash },
        error.InvalidAppToolPolicy => .{ .refused = .invalid_app_tool_policy },
    };
}

const ParseError = error{ OutOfMemory, InvalidAppTools, InvalidAppToolName, DuplicateAppToolName, AppToolBuiltInClash, InvalidAppToolPolicy };

fn parseInArena(arena: std.mem.Allocator, bytes: []const u8) ParseError!Parsed {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .allocate = .alloc_if_needed }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAppTools,
    };
    if (value != .array or value.array.items.len > max_records) return error.InvalidAppTools;
    const records = try arena.alloc(tool_record.Record, value.array.items.len);
    for (value.array.items, records) |item, *record| record.* = try recordOf(arena, item);
    std.mem.sort(tool_record.Record, records, {}, byName);
    for (records, 0..) |record, index| {
        if (index != 0 and std.mem.eql(u8, records[index - 1].name, record.name)) return error.DuplicateAppToolName;
    }
    const digests = try arena.alloc([32]u8, records.len);
    for (records, digests) |*record, *digest| digest.* = tool_record.recordDigest(record);
    const declaration: Declaration = .{ .records = records, .digests = digests };
    std.debug.assert(declaration.toolSet().valid());
    return .{ .declared = declaration };
}

fn byName(_: void, a: tool_record.Record, b: tool_record.Record) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn recordOf(arena: std.mem.Allocator, item: std.json.Value) ParseError!tool_record.Record {
    if (item != .object) return error.InvalidAppTools;
    var members = item.object.iterator();
    while (members.next()) |member| {
        var known = false;
        for (member_names) |name| known = known or std.mem.eql(u8, member.key_ptr.*, name);
        if (!known) return error.InvalidAppTools;
    }
    const name = item.object.get("name") orelse return error.InvalidAppTools;
    if (name != .string) return error.InvalidAppTools;
    if (!tool_name.valid(name.string)) return error.InvalidAppToolName;
    if (tool_record.built_in_tool_set.find(name.string) != null) return error.AppToolBuiltInClash;
    const description = item.object.get("description") orelse return error.InvalidAppTools;
    if (description != .string or !tool_presentation.ToolPresentation.validDescription(description.string)) return error.InvalidAppTools;
    const schema = item.object.get("input_schema") orelse return error.InvalidAppTools;
    if (schema != .object) return error.InvalidAppTools;
    const schema_text = try std.json.Stringify.valueAlloc(arena, schema, .{});
    shape.check(schema_text) catch return error.InvalidAppTools;
    const policy: tool_record.AppPolicy = .{
        .replay = try replayOf(item.object.get("replay")),
        .restart_limit = try integerOf(u8, item.object.get("restart_limit"), tool_record.default_app_restart_limit),
        .wait_ms = try integerOf(u32, item.object.get("wait_ms"), tool_record.default_app_wait_ms),
    };
    if (!policy.valid()) return error.InvalidAppToolPolicy;
    return .{
        .name = name.string,
        .description = description.string,
        .input_schema = schema_text,
        .owner = .app,
        .app = policy,
    };
}

fn replayOf(value: ?std.json.Value) ParseError!tool_record.Replay {
    const found = value orelse return .unsafe;
    if (found != .string) return error.InvalidAppToolPolicy;
    return std.meta.stringToEnum(tool_record.Replay, found.string) orelse error.InvalidAppToolPolicy;
}

fn integerOf(comptime Int: type, value: ?std.json.Value, default: Int) ParseError!Int {
    const found = value orelse return default;
    if (found != .integer) return error.InvalidAppToolPolicy;
    return std.math.cast(Int, found.integer) orelse error.InvalidAppToolPolicy;
}

// SH-121: the declaration validator accepts one well-formed list of records and names the refusal of every other
// document, over the whole domain of names, policies, sizes and counts.
test "SH-121 app tools validate one declaration with named refusals over its domain" {
    const arena_memory = try std.testing.allocator.alloc(u8, arena_bytes);
    defer std.testing.allocator.free(arena_memory);
    const ok = "{\"name\":\"lookup\",\"description\":\"Look up a thing\",\"input_schema\":{\"type\":\"object\"}}";
    const cases = [_]struct { document: []const u8, want: ?Refusal }{
        .{ .document = "[]", .want = null },
        .{ .document = "[" ++ ok ++ "]", .want = null },
        .{ .document = "[{\"name\":\"a\",\"description\":\"d\",\"input_schema\":{\"type\":\"object\"},\"replay\":\"safe\",\"restart_limit\":5,\"wait_ms\":2000}]", .want = null },
        .{ .document = "[{\"name\":\"has.dot\",\"description\":\"d\",\"input_schema\":{}}]", .want = .invalid_app_tool_name },
        .{ .document = "[" ++ ok ++ "," ++ ok ++ "]", .want = .duplicate_app_tool_name },
        .{ .document = "[{\"name\":\"bash\",\"description\":\"d\",\"input_schema\":{}}]", .want = .app_tool_built_in_clash },
        .{ .document = "[{\"name\":\"a\",\"description\":\"d\",\"input_schema\":{},\"wait_ms\":0}]", .want = .invalid_app_tool_policy },
        .{ .document = "[{\"name\":\"a\",\"description\":\"d\",\"input_schema\":{},\"restart_limit\":17}]", .want = .invalid_app_tool_policy },
        .{ .document = "[{\"name\":\"a\",\"description\":\"d\",\"input_schema\":{},\"replay\":\"maybe\"}]", .want = .invalid_app_tool_policy },
        .{ .document = "[{\"name\":\"a\",\"description\":\"\",\"input_schema\":{}}]", .want = .invalid_app_tools },
        .{ .document = "[{\"name\":\"a\",\"description\":\"d\",\"input_schema\":[]}]", .want = .invalid_app_tools },
        .{ .document = "[{\"name\":\"a\",\"description\":\"d\",\"input_schema\":{},\"extra\":1}]", .want = .invalid_app_tools },
        .{ .document = "[{\"description\":\"d\",\"input_schema\":{}}]", .want = .invalid_app_tools },
        .{ .document = "{}", .want = .invalid_app_tools },
        .{ .document = "[", .want = .invalid_app_tools },
    };
    for (cases) |case| {
        var fixed: std.heap.FixedBufferAllocator = .init(arena_memory);
        const parsed = parse(fixed.allocator(), case.document);
        switch (parsed) {
            .declared => |declaration| {
                try std.testing.expect(case.want == null);
                try std.testing.expect(declaration.toolSet().valid());
            },
            .refused => |refusal| try std.testing.expectEqual(case.want.?, refusal),
        }
    }
    // The policy keeps its stated safe values; an unsafe call keeps restart_limit 0 (AppPolicy.canonical).
    var fixed: std.heap.FixedBufferAllocator = .init(arena_memory);
    const safe = parse(fixed.allocator(), cases[2].document).declared;
    try std.testing.expectEqual(tool_record.Replay.safe, safe.records[0].app.replay);
    try std.testing.expectEqual(@as(u8, 5), safe.records[0].app.restart_limit);
    try std.testing.expectEqual(@as(u32, 2000), safe.records[0].app.wait_ms);
    var defaults: std.heap.FixedBufferAllocator = .init(arena_memory);
    const unsafe = parse(defaults.allocator(), "[" ++ ok ++ "]").declared;
    try std.testing.expectEqual(tool_record.Replay.unsafe, unsafe.records[0].app.replay);
    try std.testing.expectEqual(@as(u8, 0), unsafe.records[0].app.canonical().restart_limit);
    // Size: a document over the cap is refused before it is read, and an arena too small is refused by size.
    const too_long = try std.testing.allocator.alloc(u8, max_document_bytes + 1);
    defer std.testing.allocator.free(too_long);
    @memset(too_long, ' ');
    var small_memory: [64]u8 = undefined;
    var small: std.heap.FixedBufferAllocator = .init(&small_memory);
    try std.testing.expectEqual(Refusal.app_tools_too_large, parse(fixed.allocator(), too_long).refused);
    try std.testing.expectEqual(Refusal.app_tools_too_large, parse(small.allocator(), "[" ++ ok ++ "]").refused);
}
