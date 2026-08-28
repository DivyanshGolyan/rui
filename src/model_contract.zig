const std = @import("std");
const binding = @import("binding.zig");

pub const max_tool_key_size: usize = 32;
pub const max_provider_tool_name_size: usize = 64;
pub const max_description_size: usize = 1024;
pub const max_schema_size: usize = 4096;
pub const max_result_contract_size: usize = 1024;
pub const max_tool_count: usize = 8;
pub const max_bash_command_bytes: usize = 2048;
pub const max_patch_input_bytes: usize = 16 * 1024;
/// One admitted patch byte can require a six-byte JSON Unicode escape. Keep
/// this transfer bound outside the Activation Slot so the full byte capacity
/// survives its worst-case escaped representation without increasing resident state.
pub const max_tool_arguments_envelope_size: usize =
    6 * max_patch_input_bytes + "{\"patch\":\"\"}".len;
pub const max_prompt_size: usize = 2048;
pub const max_input_text_size: usize = 4096;
pub const max_choice_count: usize = 8;
pub const max_choice_id_size: usize = 64;
pub const max_choice_label_size: usize = 256;
pub const max_json_depth: usize = 32;
pub const max_json_tokens: usize = 64;
pub const max_json_members: usize = 32;
pub const max_safe_integer: i64 = (1 << 53) - 1;
pub const strict_tool_json_v1: u16 = 1;

pub const bash_key = "bash.v1";
pub const apply_patch_key = "apply_patch.v1";

pub const InputShape = enum(u8) {
    text = 1,
    single_choice = 2,
};

pub const ToolDefinition = struct {
    key: []const u8,
    provider_tool_name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    result_contract: []const u8,
};

pub const default_instructions =
    "Complete the task using the offered tools when needed. Return one final answer when done.";

pub const model_contract_bytes =
    "onepage.model-contract.v1\n" ++
    "agent_profile=default\n" ++
    "tool_arguments.validation_profile=StrictToolJsonV1\n" ++
    "tool_arguments.identity=exact_bytes\n" ++
    "response=assistant_text|tool_call|input_request|provider_failure\n" ++
    "input_request.prompt_bytes=1..2048\n" ++
    "input_request.text_response_bytes=1..4096\n" ++
    "input_request.choice_count=1..8\n" ++
    "input_request.choice_id_bytes=1..64\n" ++
    "input_request.choice_label_bytes=1..256\n";

const bash_schema =
    "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"Required non-empty valid UTF-8 text without NUL bytes and with at most 2048 bytes.\",\"minLength\":1,\"maxLength\":2048},\"timeout_ms\":{\"type\":\"integer\",\"minimum\":100,\"maximum\":120000}},\"required\":[\"command\",\"timeout_ms\"],\"additionalProperties\":false}";
const patch_schema =
    "{\"type\":\"object\",\"properties\":{\"patch\":{\"type\":\"string\",\"description\":\"Required non-empty valid UTF-8 text with at most 16384 bytes.\",\"minLength\":1,\"maxLength\":16384}},\"required\":[\"patch\"],\"additionalProperties\":false}";

pub const default_catalog = [_]ToolDefinition{
    .{
        .key = bash_key,
        .provider_tool_name = "bash",
        .description = "Run one bounded Bash command in the Job Workspace.",
        .input_schema = bash_schema,
        .result_contract = "Bounded UTF-8 text containing status, exit code, and base64 stdout and stderr.",
    },
    .{
        .key = apply_patch_key,
        .provider_tool_name = "apply_patch",
        .description = "Apply one bounded patch to one regular file in the Job Workspace.",
        .input_schema = patch_schema,
        .result_contract = "Bounded UTF-8 text containing the patch disposition.",
    },
};

pub const default_catalog_digest: binding.ToolCatalog = .{ .bytes = .{
    0x06, 0xd9, 0xb7, 0x2a, 0xa3, 0x67, 0x80, 0x1e,
    0xda, 0xf1, 0x9d, 0xb5, 0x17, 0xa1, 0x86, 0xdc,
    0x40, 0xdd, 0x5f, 0x47, 0x69, 0x0d, 0xcc, 0x48,
    0x64, 0x5a, 0x1c, 0x1a, 0x93, 0xff, 0xbd, 0x12,
} };

pub fn validateToolKey(key: []const u8) !void {
    if (key.len == 0 or key.len > max_tool_key_size) return error.InvalidToolKey;
    for (key) |byte| {
        if (!((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or
            byte == '_' or byte == '-' or byte == '.')) return error.InvalidToolKey;
    }
}

/// Validate the one immutable built-in catalog once during Host startup.
pub fn validateBuiltinCatalog() !void {
    try validateCatalog(&default_catalog);
    if (!binding.eql(binding.ToolCatalog, catalogDigest(&default_catalog), default_catalog_digest)) {
        return error.InvalidToolCatalogDigest;
    }
}

pub fn validateCatalog(catalog: []const ToolDefinition) !void {
    if (catalog.len == 0 or catalog.len > max_tool_count) {
        return error.InvalidToolCatalog;
    }
    for (catalog, 0..) |definition, index| {
        try validateToolKey(definition.key);
        if (definition.provider_tool_name.len == 0 or
            definition.provider_tool_name.len > max_provider_tool_name_size or
            definition.description.len == 0 or definition.description.len > max_description_size or
            definition.input_schema.len == 0 or definition.input_schema.len > max_schema_size or
            definition.result_contract.len == 0 or
            definition.result_contract.len > max_result_contract_size or
            !utf8Valid(definition.provider_tool_name) or !utf8Valid(definition.description) or
            !utf8Valid(definition.result_contract) or !validInputSchema(definition.input_schema))
        {
            return error.InvalidToolCatalog;
        }
        for (catalog[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.key, definition.key)) return error.DuplicateToolKey;
            if (std.mem.eql(u8, earlier.provider_tool_name, definition.provider_tool_name)) {
                return error.AmbiguousProviderToolName;
            }
        }
    }
}

pub fn keyForProviderName(name: []const u8) ![]const u8 {
    return keyForProviderNameInCatalog(&default_catalog, name);
}

pub fn keyForProviderNameInCatalog(catalog: []const ToolDefinition, name: []const u8) ![]const u8 {
    if (name.len == 0 or name.len > max_provider_tool_name_size or !utf8Valid(name)) {
        return error.UnknownProviderToolName;
    }
    for (catalog) |definition| {
        if (std.mem.eql(u8, definition.provider_tool_name, name)) {
            return definition.key;
        }
    }
    return error.UnknownProviderToolName;
}

pub fn definitionForKey(catalog: []const ToolDefinition, key: []const u8) ?ToolDefinition {
    for (catalog) |definition| {
        if (std.mem.eql(u8, definition.key, key)) return definition;
    }
    return null;
}

pub fn catalogDigest(catalog: []const ToolDefinition) binding.ToolCatalog {
    var builder = CatalogDigestBuilder.init(catalog.len);
    for (catalog) |definition| builder.add(definition);
    return builder.final();
}

pub const CatalogDigestBuilder = struct {
    hasher: binding.Hasher(binding.ToolCatalog),

    pub fn init(count_value: usize) CatalogDigestBuilder {
        var hasher = binding.Hasher(binding.ToolCatalog).init();
        var count: [2]u8 = undefined;
        std.mem.writeInt(u16, &count, @intCast(count_value), .little);
        hasher.update(&count);
        return .{ .hasher = hasher };
    }

    pub fn add(self: *CatalogDigestBuilder, definition: ToolDefinition) void {
        self.addField(definition.key);
        self.addField(definition.provider_tool_name);
        self.addField(definition.description);
        self.addField(definition.input_schema);
        self.addField(definition.result_contract);
    }

    pub fn final(self: *CatalogDigestBuilder) binding.ToolCatalog {
        return self.hasher.final();
    }

    fn addField(self: *CatalogDigestBuilder, bytes: []const u8) void {
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(bytes.len), .little);
        self.hasher.update(&length);
        self.hasher.update(bytes);
    }
};

/// Exact tool-argument bytes admitted under StrictToolJsonV1. The slice points
/// into the immutable capture or caller-owned storage; admission never rewrites
/// whitespace, object order, string escapes, or number spelling.
pub const StrictToolJson = struct {
    value: []const u8,
    proof: binding.StrictToolJsonV1,

    pub fn bytes(self: StrictToolJson) []const u8 {
        return self.value;
    }

    pub fn evidence(self: StrictToolJson) binding.StrictToolJsonV1 {
        return self.proof;
    }
};

pub const strict_tool_json_arena_size = max_tool_arguments_envelope_size + 48 * 1024;
pub const StrictToolJsonArena = [strict_tool_json_arena_size]u8;

/// Reconstructible Host-owned scratch used only while admitting one captured
/// model output. It is not retained by providers, Sessions, Attempts, or tools.
pub const StrictToolJsonScratch = struct {
    scanner_stack: [4096]u8 align(@alignOf(usize)) = undefined,
    arena: StrictToolJsonArena = undefined,
};

pub const AdmittedToolArguments = struct {
    json: StrictToolJson,
    parsed: std.json.Value,
};

/// Validate exact bytes once under the generic StrictToolJsonV1 profile.
pub fn validateStrictToolJson(
    scratch: *StrictToolJsonScratch,
    bytes: []const u8,
) !StrictToolJson {
    try preflightStrictToolJson(scratch, bytes);
    var fixed = std.heap.FixedBufferAllocator.init(&scratch.arena);
    var parsed = std.json.parseFromSlice(std.json.Value, fixed.allocator(), bytes, .{
        .max_value_len = max_tool_arguments_envelope_size,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidStrictToolJson;
    defer parsed.deinit();
    var tokens: usize = 0;
    var members: usize = 0;
    countJsonStructure(parsed.value, 1, &tokens, &members) catch
        return error.InvalidStrictToolJson;
    return .{ .value = bytes, .proof = strictToolJsonDigest(bytes) };
}

pub fn strictToolJsonDigest(bytes: []const u8) binding.StrictToolJsonV1 {
    return binding.hash(binding.StrictToolJsonV1, bytes);
}

/// Reopen already-admitted exact bytes without parsing them again.
pub fn strictToolJsonFromEvidence(
    bytes: []const u8,
    digest: binding.StrictToolJsonV1,
) !StrictToolJson {
    if (bytes.len == 0 or bytes.len > max_tool_arguments_envelope_size or
        !binding.eql(binding.StrictToolJsonV1, strictToolJsonDigest(bytes), digest))
    {
        return error.InvalidStrictToolJsonEvidence;
    }
    return .{ .value = bytes, .proof = digest };
}

/// Apply the selected Operation-bound catalog schema to exact JSON bytes.
pub fn admitToolArguments(
    scratch: *StrictToolJsonScratch,
    definition: ToolDefinition,
    bytes: []const u8,
) !AdmittedToolArguments {
    try preflightStrictToolJson(scratch, bytes);
    var fixed = std.heap.FixedBufferAllocator.init(&scratch.arena);
    var parsed = std.json.parseFromSlice(std.json.Value, fixed.allocator(), bytes, .{
        .max_value_len = max_tool_arguments_envelope_size,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidToolArguments;
    defer parsed.deinit();
    var tokens: usize = 0;
    var members: usize = 0;
    countJsonStructure(parsed.value, 1, &tokens, &members) catch
        return error.InvalidStrictToolJson;
    const json: StrictToolJson = .{
        .value = bytes,
        .proof = strictToolJsonDigest(bytes),
    };
    var schema = std.json.parseFromSlice(std.json.Value, fixed.allocator(), definition.input_schema, .{
        .max_value_len = max_schema_size,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidToolSchema;
    defer schema.deinit();
    validateAgainstInputSchema(schema.value, parsed.value) catch return error.InvalidToolArguments;
    return .{ .json = json, .parsed = parsed.value };
}

fn validateAgainstInputSchema(schema_value: std.json.Value, maybe_arguments: ?std.json.Value) !void {
    const schema = switch (schema_value) {
        .object => |value| value,
        else => return error.InvalidToolSchema,
    };
    try requireOnlyFields(schema, &.{ "type", "properties", "required", "additionalProperties" });
    const root_type = switch (schema.get("type") orelse return error.InvalidToolSchema) {
        .string => |value| value,
        else => return error.InvalidToolSchema,
    };
    if (!std.mem.eql(u8, root_type, "object")) return error.InvalidToolSchema;
    const properties = switch (schema.get("properties") orelse return error.InvalidToolSchema) {
        .object => |value| value,
        else => return error.InvalidToolSchema,
    };
    if (properties.count() > max_json_members) return error.InvalidToolSchema;
    const required = switch (schema.get("required") orelse return error.InvalidToolSchema) {
        .array => |value| value,
        else => return error.InvalidToolSchema,
    };
    const additional = switch (schema.get("additionalProperties") orelse return error.InvalidToolSchema) {
        .bool => |value| value,
        else => return error.InvalidToolSchema,
    };
    if (additional or required.items.len > properties.count()) return error.InvalidToolSchema;
    const arguments = if (maybe_arguments) |argument_value| switch (argument_value) {
        .object => |value| value,
        else => return error.InvalidToolArguments,
    } else null;

    for (required.items, 0..) |item, index| {
        const name = switch (item) {
            .string => |value| value,
            else => return error.InvalidToolSchema,
        };
        if (properties.get(name) == null) return error.InvalidToolSchema;
        for (required.items[0..index]) |earlier| {
            const earlier_name = switch (earlier) {
                .string => |value| value,
                else => return error.InvalidToolSchema,
            };
            if (std.mem.eql(u8, earlier_name, name)) return error.InvalidToolSchema;
        }
        if (arguments) |values| {
            if (values.get(name) == null) return error.InvalidToolArguments;
        }
    }

    if (arguments) |values| {
        var argument_iterator = values.iterator();
        while (argument_iterator.next()) |entry| {
            if (properties.get(entry.key_ptr.*) == null) return error.InvalidToolArguments;
        }
    }
    var property_iterator = properties.iterator();
    while (property_iterator.next()) |entry| {
        try validatePropertySchema(
            entry.value_ptr.*,
            if (arguments) |values| values.get(entry.key_ptr.*) else null,
        );
    }
}

fn validatePropertySchema(schema_value: std.json.Value, maybe_value: ?std.json.Value) !void {
    const schema = switch (schema_value) {
        .object => |value| value,
        else => return error.InvalidToolSchema,
    };
    const type_name = switch (schema.get("type") orelse return error.InvalidToolSchema) {
        .string => |value| value,
        else => return error.InvalidToolSchema,
    };
    if (schema.get("description")) |description| switch (description) {
        .string => {},
        else => return error.InvalidToolSchema,
    };
    if (std.mem.eql(u8, type_name, "string")) {
        try requireOnlyFields(schema, &.{ "type", "description", "minLength", "maxLength" });
        const minimum = try schemaNatural(schema.get("minLength"), 0);
        const maximum = try schemaNatural(schema.get("maxLength"), max_tool_arguments_envelope_size);
        if (minimum > maximum) return error.InvalidToolSchema;
        if (maybe_value) |value| {
            const text = switch (value) {
                .string => |string| string,
                else => return error.InvalidToolArguments,
            };
            const length = std.unicode.utf8CountCodepoints(text) catch return error.InvalidToolArguments;
            if (length < minimum or length > maximum) return error.InvalidToolArguments;
        }
        return;
    }
    if (std.mem.eql(u8, type_name, "integer")) {
        try requireOnlyFields(schema, &.{ "type", "description", "minimum", "maximum" });
        const minimum = try schemaInteger(schema.get("minimum"), -max_safe_integer);
        const maximum = try schemaInteger(schema.get("maximum"), max_safe_integer);
        if (minimum > maximum) return error.InvalidToolSchema;
        if (maybe_value) |value| {
            const integer = try jsonInteger(value);
            if (integer < minimum or integer > maximum) return error.InvalidToolArguments;
        }
        return;
    }
    if (std.mem.eql(u8, type_name, "boolean")) {
        try requireOnlyFields(schema, &.{ "type", "description" });
        if (maybe_value) |value| switch (value) {
            .bool => {},
            else => return error.InvalidToolArguments,
        };
        return;
    }
    return error.InvalidToolSchema;
}

fn requireOnlyFields(object: std.json.ObjectMap, allowed: []const []const u8) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidToolSchema;
    }
}

fn schemaNatural(value: ?std.json.Value, default: usize) !usize {
    const actual = value orelse return default;
    return switch (actual) {
        .integer => |integer| std.math.cast(usize, integer) orelse error.InvalidToolSchema,
        else => error.InvalidToolSchema,
    };
}

fn schemaInteger(value: ?std.json.Value, default: i64) !i64 {
    const actual = value orelse return default;
    return switch (actual) {
        .integer => |integer| if (integer >= -max_safe_integer and integer <= max_safe_integer)
            integer
        else
            error.InvalidToolSchema,
        else => error.InvalidToolSchema,
    };
}

fn jsonInteger(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |integer| if (integer >= -max_safe_integer and integer <= max_safe_integer)
            integer
        else
            error.InvalidToolArguments,
        .float => |number| if (std.math.isFinite(number) and number >= -max_safe_integer and
            number <= max_safe_integer and @trunc(number) == number)
            @intFromFloat(number)
        else
            error.InvalidToolArguments,
        else => error.InvalidToolArguments,
    };
}

fn preflightStrictToolJson(scratch: *StrictToolJsonScratch, bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > max_tool_arguments_envelope_size or !utf8Valid(bytes)) {
        return error.InvalidStrictToolJson;
    }
    var fixed = std.heap.FixedBufferAllocator.init(&scratch.scanner_stack);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), bytes);
    defer scanner.deinit();
    scanner.ensureTotalStackCapacity(max_json_depth + 1) catch
        return error.InvalidStrictToolJson;
    while (true) {
        const token = scanner.next() catch return error.InvalidStrictToolJson;
        switch (token) {
            .object_begin, .array_begin => if (scanner.stackHeight() > max_json_depth) {
                return error.JsonTooDeep;
            },
            .end_of_document => return,
            else => {},
        }
    }
}

fn countJsonStructure(
    value: std.json.Value,
    depth: usize,
    tokens: *usize,
    members: *usize,
) !void {
    if (depth > max_json_depth) return error.JsonTooDeep;
    tokens.* += 1;
    if (tokens.* > max_json_tokens) return error.TooManyJsonTokens;
    switch (value) {
        .array => |array| for (array.items) |item| {
            try countJsonStructure(item, depth + 1, tokens, members);
        },
        .object => |object| {
            members.* += object.count();
            if (members.* > max_json_members) return error.TooManyJsonMembers;
            for (object.values()) |item| {
                try countJsonStructure(item, depth + 1, tokens, members);
            }
        },
        else => {},
    }
}

fn jsonU32(value: std.json.Value) !u32 {
    return switch (value) {
        .integer => |integer| std.math.cast(u32, integer) orelse error.InvalidToolArguments,
        .float => |number| if (std.math.isFinite(number) and number >= 0 and
            number <= std.math.maxInt(u32) and @trunc(number) == number)
            @intFromFloat(number)
        else
            error.InvalidToolArguments,
        else => error.InvalidToolArguments,
    };
}

fn validInputSchema(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes.len > max_schema_size or !utf8Valid(bytes)) return false;
    var arena_bytes: [max_schema_size + 8 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, fixed.allocator(), bytes, .{
        .max_value_len = max_schema_size,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return false;
    defer parsed.deinit();
    validateAgainstInputSchema(parsed.value, null) catch return false;
    return true;
}

pub fn encodeJson(
    out: []u8,
    value: anytype,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(out);
    std.json.Stringify.value(value, .{}, &writer) catch return error.JsonTooLarge;
    return writer.buffered();
}

pub fn utf8Valid(bytes: []const u8) bool {
    return std.unicode.utf8ValidateSlice(bytes);
}

pub fn validateBashCommand(command: []const u8) !void {
    try validateUnicodeField(command, max_bash_command_bytes);
    if (std.mem.indexOfScalar(u8, command, 0) != null) return error.InvalidToolText;
}

pub fn validatePatchInput(patch: []const u8) !void {
    try validateUnicodeField(patch, max_patch_input_bytes);
}

fn validateUnicodeField(bytes: []const u8, max_bytes: usize) !void {
    if (bytes.len == 0 or bytes.len > max_bytes or !utf8Valid(bytes)) {
        return error.InvalidToolText;
    }
}

test "the default catalog has a stable digest and deterministic name mapping" {
    try validateBuiltinCatalog();
    try std.testing.expectEqualSlices(u8, &default_catalog_digest.bytes, &catalogDigest(&default_catalog).bytes);
    try std.testing.expectEqualStrings(
        apply_patch_key,
        try keyForProviderName("apply_patch"),
    );
    try std.testing.expectError(
        error.UnknownProviderToolName,
        keyForProviderName("unknown"),
    );
}

test "StrictToolJsonV1 accepts noncanonical exact bytes and distinguishes identity" {
    var scratch: StrictToolJsonScratch = undefined;
    const first_bytes = " { \"timeout_ms\" : 1000, \"command\" : \"true\" } ";
    const second_bytes = "{\"command\":\"true\",\"timeout_ms\":1000}";
    const first = try admitToolArguments(&scratch, default_catalog[0], first_bytes);
    const second = try admitToolArguments(&scratch, default_catalog[0], second_bytes);
    try std.testing.expectEqualStrings(first_bytes, first.json.bytes());
    try std.testing.expectEqualStrings(second_bytes, second.json.bytes());
    try std.testing.expect(!std.mem.eql(
        u8,
        &first.json.evidence().bytes,
        &second.json.evidence().bytes,
    ));
}

test "StrictToolJsonV1 applies an arbitrary catalog definition without execution knowledge" {
    const definition: ToolDefinition = .{
        .key = "fixture.inspect.v1",
        .provider_tool_name = "fixture_inspect",
        .description = "Inspect one fixture value.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":6},\"fresh\":{\"type\":\"boolean\"}},\"required\":[\"query\"],\"additionalProperties\":false}",
        .result_contract = "Bounded fixture text.",
    };
    try validateCatalog(&.{definition});
    var scratch: StrictToolJsonScratch = undefined;
    const exact = " { \"fresh\" : true, \"query\" : \"status\" } ";
    const admitted = try admitToolArguments(&scratch, definition, exact);
    try std.testing.expectEqualStrings(exact, admitted.json.bytes());
    try std.testing.expectError(
        error.InvalidToolArguments,
        admitToolArguments(&scratch, definition, "{\"query\":1}"),
    );
    try std.testing.expectError(
        error.InvalidToolArguments,
        admitToolArguments(&scratch, definition, "{\"query\":\"status!\"}"),
    );
    try std.testing.expectError(
        error.InvalidToolArguments,
        admitToolArguments(&scratch, definition, "{\"query\":\"ok\",\"unknown\":true}"),
    );
}

test "Tool Catalog rejects schemas outside the admitted vocabulary" {
    const unsupported = [_][]const u8{
        "{\"type\":\"array\",\"items\":{\"type\":\"string\"}}",
        "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"array\"}},\"required\":[],\"additionalProperties\":false}",
        "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\",\"enum\":[\"a\"]}},\"required\":[],\"additionalProperties\":false}",
        "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\",\"description\":1}},\"required\":[],\"additionalProperties\":false}",
        "{\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":true}",
        "{\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false,\"$ref\":\"#\"}",
    };
    for (unsupported) |schema| {
        const definition: ToolDefinition = .{
            .key = "fixture.unsupported.v1",
            .provider_tool_name = "fixture_unsupported",
            .description = "Unsupported schema fixture.",
            .input_schema = schema,
            .result_contract = "Bounded fixture text.",
        };
        try std.testing.expectError(error.InvalidToolCatalog, validateCatalog(&.{definition}));
    }
}

test "StrictToolJsonV1 rejects malformed duplicate deep and many-member values" {
    var scratch: StrictToolJsonScratch = undefined;
    try std.testing.expectError(
        error.InvalidStrictToolJson,
        validateStrictToolJson(&scratch, "{\"a\":1"),
    );
    try std.testing.expectError(
        error.InvalidStrictToolJson,
        validateStrictToolJson(&scratch, "{\"a\":1,\"a\":2}"),
    );
    var deep: [2 * (max_json_depth + 1) + 1]u8 = undefined;
    @memset(deep[0 .. max_json_depth + 1], '[');
    deep[max_json_depth + 1] = '0';
    @memset(deep[max_json_depth + 2 ..], ']');
    try std.testing.expectError(error.JsonTooDeep, validateStrictToolJson(&scratch, &deep));
    var many: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&many);
    try writer.writeByte('{');
    for (0..max_json_members + 1) |index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("\"k{d}\":0", .{index});
    }
    try writer.writeByte('}');
    try std.testing.expectError(
        error.InvalidStrictToolJson,
        validateStrictToolJson(&scratch, writer.buffered()),
    );
    var many_tokens: [2 * max_json_tokens + 1]u8 = undefined;
    many_tokens[0] = '[';
    for (0..max_json_tokens) |index| {
        many_tokens[1 + 2 * index] = '0';
        many_tokens[2 + 2 * index] = if (index + 1 == max_json_tokens) ']' else ',';
    }
    try std.testing.expectError(
        error.InvalidStrictToolJson,
        validateStrictToolJson(&scratch, &many_tokens),
    );
    var oversized: [max_tool_arguments_envelope_size + 1]u8 = @splat(' ');
    try std.testing.expectError(
        error.InvalidStrictToolJson,
        validateStrictToolJson(&scratch, &oversized),
    );
    try std.testing.expectError(
        error.InvalidStrictToolJson,
        validateStrictToolJson(&scratch, "{\"value\":\"\xff\"}"),
    );
    try std.testing.expectError(
        error.InvalidToolArguments,
        admitToolArguments(&scratch, default_catalog[0], "{\"command\":1,\"timeout_ms\":1000}"),
    );
}

test "StrictToolJsonV1 evidence reopens exact admitted bytes without parsing" {
    var scratch: StrictToolJsonScratch = undefined;
    const admitted = try validateStrictToolJson(&scratch, "{ \"a\" : 1 }");
    try std.testing.expectEqualStrings(
        admitted.bytes(),
        (try strictToolJsonFromEvidence(admitted.bytes(), admitted.evidence())).bytes(),
    );
    try std.testing.expectError(
        error.InvalidStrictToolJsonEvidence,
        strictToolJsonFromEvidence("{\"a\":2}", admitted.evidence()),
    );
}

test "StrictToolJsonV1 identity has no empty digest sentinel" {
    const zero_digest: binding.StrictToolJsonV1 = .{ .bytes = @splat(0) };
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(@TypeOf(zero_digest)));
    try std.testing.expect(std.mem.allEqual(u8, &zero_digest.bytes, 0));
}

test "serialized catalog schemas state the exact UTF-8 byte contract" {
    const BashSchema = struct {
        properties: struct {
            command: struct {
                description: []const u8,
                minLength: usize,
                maxLength: usize,
            },
        },
    };
    const PatchSchema = struct {
        properties: struct {
            patch: struct {
                description: []const u8,
                minLength: usize,
                maxLength: usize,
            },
        },
    };
    var bash = try std.json.parseFromSlice(
        BashSchema,
        std.testing.allocator,
        default_catalog[0].input_schema,
        .{ .ignore_unknown_fields = true },
    );
    defer bash.deinit();
    try std.testing.expectEqual(@as(usize, 1), bash.value.properties.command.minLength);
    try std.testing.expectEqual(max_bash_command_bytes, bash.value.properties.command.maxLength);
    try std.testing.expectEqualStrings(
        "Required non-empty valid UTF-8 text without NUL bytes and with at most 2048 bytes.",
        bash.value.properties.command.description,
    );
    var patch = try std.json.parseFromSlice(
        PatchSchema,
        std.testing.allocator,
        default_catalog[1].input_schema,
        .{ .ignore_unknown_fields = true },
    );
    defer patch.deinit();
    try std.testing.expectEqual(@as(usize, 1), patch.value.properties.patch.minLength);
    try std.testing.expectEqual(max_patch_input_bytes, patch.value.properties.patch.maxLength);
    try std.testing.expectEqualStrings(
        "Required non-empty valid UTF-8 text with at most 16384 bytes.",
        patch.value.properties.patch.description,
    );
}

test "Bash command admission rejects NUL bytes" {
    try std.testing.expectError(error.InvalidToolText, validateBashCommand("true\x00"));
}
