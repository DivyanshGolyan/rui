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
/// survives canonical representation without increasing resident state.
pub const max_tool_arguments_envelope_size: usize =
    6 * max_patch_input_bytes + "{\"patch\":\"\"}".len;
pub const max_prompt_size: usize = 2048;
pub const max_input_text_size: usize = 4096;
pub const max_choice_count: usize = 8;
pub const max_choice_id_size: usize = 64;
pub const max_choice_label_size: usize = 256;
pub const max_json_depth: usize = 32;
pub const max_safe_integer: i64 = (1 << 53) - 1;

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
    "response=assistant_text|tool_call|input_request|provider_failure\n" ++
    "input_request.prompt_bytes=1..2048\n" ++
    "input_request.text_response_bytes=1..4096\n" ++
    "input_request.choice_count=1..8\n" ++
    "input_request.choice_id_bytes=1..64\n" ++
    "input_request.choice_label_bytes=1..256\n";

const bash_schema =
    "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"Required non-empty valid UTF-8 text with at most 2048 bytes.\",\"minLength\":1,\"maxLength\":2048},\"timeout_ms\":{\"type\":\"integer\",\"minimum\":100,\"maximum\":120000}},\"required\":[\"command\",\"timeout_ms\"],\"additionalProperties\":false}";
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

pub fn validateToolKey(key: []const u8) !void {
    if (key.len == 0 or key.len > max_tool_key_size) return error.InvalidToolKey;
    for (key) |byte| {
        if (!((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or
            byte == '_' or byte == '-' or byte == '.')) return error.InvalidToolKey;
    }
}

pub fn validateCatalog(catalog: []const ToolDefinition) !void {
    if (catalog.len == 0 or catalog.len > max_tool_count) return error.InvalidToolCatalog;
    for (catalog, 0..) |definition, index| {
        try validateToolKey(definition.key);
        if (definition.provider_tool_name.len == 0 or
            definition.provider_tool_name.len > max_provider_tool_name_size or
            definition.description.len == 0 or definition.description.len > max_description_size or
            definition.input_schema.len == 0 or definition.input_schema.len > max_schema_size or
            definition.result_contract.len == 0 or
            definition.result_contract.len > max_result_contract_size or
            !utf8Valid(definition.provider_tool_name) or !utf8Valid(definition.description) or
            !utf8Valid(definition.result_contract) or !validJson(definition.input_schema))
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

pub fn keyForProviderName(catalog: []const ToolDefinition, name: []const u8) ![]const u8 {
    try validateCatalog(catalog);
    if (name.len == 0 or name.len > max_provider_tool_name_size or !utf8Valid(name)) {
        return error.UnknownProviderToolName;
    }
    var match: ?[]const u8 = null;
    for (catalog) |definition| {
        if (std.mem.eql(u8, definition.provider_tool_name, name)) {
            if (match != null) return error.AmbiguousProviderToolName;
            match = definition.key;
        }
    }
    return match orelse error.UnknownProviderToolName;
}

pub fn catalogDigest(catalog: []const ToolDefinition) !binding.ToolCatalog {
    try validateCatalog(catalog);
    var hasher = binding.Hasher(binding.ToolCatalog).init();
    var count: [2]u8 = undefined;
    std.mem.writeInt(u16, &count, @intCast(catalog.len), .little);
    hasher.update(&count);
    for (catalog) |definition| {
        hashField(&hasher, definition.key);
        hashField(&hasher, definition.provider_tool_name);
        hashField(&hasher, definition.description);
        hashField(&hasher, definition.input_schema);
        hashField(&hasher, definition.result_contract);
    }
    return hasher.final();
}

fn hashField(hasher: *binding.Hasher(binding.ToolCatalog), bytes: []const u8) void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(bytes.len), .little);
    hasher.update(&length);
    hasher.update(bytes);
}

/// The only tool-argument representation accepted by model and Conversation
/// encoders. The slice points into storage owned by the caller of
/// `canonicalizeJson` or `canonicalJsonValue`.
pub const CanonicalJson = struct {
    value: []const u8,

    pub fn bytes(self: CanonicalJson) []const u8 {
        return self.value;
    }
};

pub fn canonicalizeJson(out: []u8, bytes: []const u8) !CanonicalJson {
    if (bytes.len == 0 or bytes.len > max_tool_arguments_envelope_size or !utf8Valid(bytes)) {
        return error.InvalidCanonicalJson;
    }
    var arena_bytes: [max_tool_arguments_envelope_size + 48 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, fixed.allocator(), bytes, .{
        .max_value_len = max_tool_arguments_envelope_size,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidCanonicalJson;
    defer parsed.deinit();
    normalizeJsonValue(&parsed.value, 0) catch return error.InvalidCanonicalJson;
    var writer = std.Io.Writer.fixed(out);
    std.json.Stringify.value(parsed.value, .{}, &writer) catch return error.JsonTooLarge;
    return .{ .value = writer.buffered() };
}

pub fn canonicalJsonValue(bytes: []const u8) !CanonicalJson {
    if (!canonicalJson(bytes)) return error.InvalidCanonicalJson;
    return .{ .value = bytes };
}

pub fn canonicalJson(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes.len > max_tool_arguments_envelope_size or !utf8Valid(bytes)) return false;
    var normalized_bytes: [max_tool_arguments_envelope_size]u8 = undefined;
    const normalized = canonicalizeJson(&normalized_bytes, bytes) catch return false;
    var hash_buffer: [4096]u8 = undefined;
    var hashing = std.Io.Writer.Hashing(CountingSha256).initHasher(.{}, &hash_buffer);
    hashing.writer.writeAll(normalized.bytes()) catch return false;
    hashing.writer.flush() catch return false;
    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &expected, .{});
    var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hashing.hasher.hash.final(&actual);
    return hashing.hasher.length == bytes.len and std.mem.eql(u8, &actual, &expected);
}

fn validJson(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes.len > max_schema_size or !utf8Valid(bytes)) return false;
    var arena_bytes: [max_schema_size + 8 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, fixed.allocator(), bytes, .{
        .max_value_len = max_schema_size,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return false;
    defer parsed.deinit();
    return true;
}

fn normalizeJsonValue(value: *std.json.Value, depth: usize) !void {
    if (depth > max_json_depth) return error.JsonTooDeep;
    switch (value.*) {
        .null, .bool, .string => {},
        .integer => |integer| {
            if (integer < -max_safe_integer or integer > max_safe_integer) {
                return error.UnsupportedJsonNumber;
            }
        },
        .float => |number| {
            if (!std.math.isFinite(number) or
                number < -@as(f64, @floatFromInt(max_safe_integer)) or
                number > @as(f64, @floatFromInt(max_safe_integer)))
            {
                return error.UnsupportedJsonNumber;
            }
            if (number == 0) {
                value.* = .{ .integer = 0 };
            } else if (@trunc(number) == number) {
                value.* = .{ .integer = @intFromFloat(number) };
            }
        },
        .number_string => return error.UnsupportedJsonNumber,
        .array => |*array| for (array.items) |*item| {
            try normalizeJsonValue(item, depth + 1);
        },
        .object => |*object| {
            for (object.values()) |*item| try normalizeJsonValue(item, depth + 1);
            const Sort = struct {
                keys: [][]const u8,

                pub fn lessThan(self: @This(), left: usize, right: usize) bool {
                    return std.mem.order(u8, self.keys[left], self.keys[right]) == .lt;
                }
            };
            object.sort(Sort{ .keys = object.keys() });
        },
    }
}

const CountingSha256 = struct {
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    length: usize = 0,

    pub fn update(self: *CountingSha256, bytes: []const u8) void {
        self.hash.update(bytes);
        self.length += bytes.len;
    }
};

pub fn encodeJson(out: []u8, value: anytype) ![]const u8 {
    var raw: [max_tool_arguments_envelope_size]u8 = undefined;
    var writer = std.Io.Writer.fixed(&raw);
    std.json.Stringify.value(value, .{}, &writer) catch return error.JsonTooLarge;
    return (try canonicalizeJson(out, writer.buffered())).bytes();
}

pub fn utf8Valid(bytes: []const u8) bool {
    return std.unicode.utf8ValidateSlice(bytes);
}

pub fn validateBashCommand(command: []const u8) !void {
    try validateUnicodeField(command, max_bash_command_bytes);
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
    const first = try catalogDigest(&default_catalog);
    const second = try catalogDigest(&default_catalog);
    try std.testing.expectEqualSlices(u8, &first.bytes, &second.bytes);
    try std.testing.expectEqualStrings(
        apply_patch_key,
        try keyForProviderName(&default_catalog, "apply_patch"),
    );
    try std.testing.expectError(
        error.UnknownProviderToolName,
        keyForProviderName(&default_catalog, "unknown"),
    );
}

test "duplicate and ambiguous catalog definitions fail closed" {
    const duplicate_keys = [_]ToolDefinition{ default_catalog[0], default_catalog[0] };
    try std.testing.expectError(error.DuplicateToolKey, validateCatalog(&duplicate_keys));
    var ambiguous = default_catalog;
    ambiguous[1].provider_tool_name = ambiguous[0].provider_tool_name;
    try std.testing.expectError(error.AmbiguousProviderToolName, validateCatalog(&ambiguous));
}

test "canonical JSON has one recursive object order" {
    try std.testing.expect(canonicalJson("{\"a\":1}"));
    try std.testing.expect(!canonicalJson("{ \"a\": 1 }"));
    try std.testing.expect(!canonicalJson("{\"a\":1"));
    var first: [128]u8 = undefined;
    var second: [128]u8 = undefined;
    const canonical_first = try canonicalizeJson(&first, "{\"z\":0,\"a\":{\"y\":2,\"x\":1}}");
    const canonical_second = try canonicalizeJson(&second, "{\"a\":{\"x\":1,\"y\":2},\"z\":0}");
    try std.testing.expectEqualStrings(canonical_first.bytes(), canonical_second.bytes());
    try std.testing.expectEqualStrings("{\"a\":{\"x\":1,\"y\":2},\"z\":0}", canonical_first.bytes());
}

test "canonical JSON rejects duplicate keys and normalizes strings and numbers" {
    var out: [128]u8 = undefined;
    try std.testing.expectError(
        error.InvalidCanonicalJson,
        canonicalizeJson(&out, "{\"a\":1,\"a\":2}"),
    );
    const canonical = try canonicalizeJson(
        &out,
        "{\"escaped\":\"\\u0061\\/b\",\"negative_zero\":-0.0,\"whole\":1e0,\"fraction\":1.50}",
    );
    try std.testing.expectEqualStrings(
        "{\"escaped\":\"a/b\",\"fraction\":1.5,\"negative_zero\":0,\"whole\":1}",
        canonical.bytes(),
    );
    try std.testing.expectError(
        error.InvalidCanonicalJson,
        canonicalizeJson(&out, "9007199254740992"),
    );
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
        "Required non-empty valid UTF-8 text with at most 2048 bytes.",
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
