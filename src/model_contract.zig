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

pub const default_catalog_digest: binding.ToolCatalog = .{ .bytes = .{
    0xd1, 0x4f, 0x19, 0x76, 0x0f, 0x81, 0x1b, 0x54,
    0x1e, 0x35, 0xda, 0x8f, 0x11, 0x97, 0xe7, 0xf3,
    0xc4, 0x5b, 0xc3, 0x5e, 0xfd, 0xe1, 0xc8, 0x85,
    0xe4, 0x05, 0x9e, 0x8d, 0x2f, 0xdd, 0x44, 0x83,
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
    if (default_catalog.len == 0 or default_catalog.len > max_tool_count) {
        return error.InvalidToolCatalog;
    }
    for (default_catalog, 0..) |definition, index| {
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
        for (default_catalog[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.key, definition.key)) return error.DuplicateToolKey;
            if (std.mem.eql(u8, earlier.provider_tool_name, definition.provider_tool_name)) {
                return error.AmbiguousProviderToolName;
            }
        }
    }
    if (!binding.eql(binding.ToolCatalog, builtinCatalogDigest(), default_catalog_digest)) {
        return error.InvalidToolCatalogDigest;
    }
}

pub fn keyForProviderName(name: []const u8) ![]const u8 {
    if (name.len == 0 or name.len > max_provider_tool_name_size or !utf8Valid(name)) {
        return error.UnknownProviderToolName;
    }
    for (default_catalog) |definition| {
        if (std.mem.eql(u8, definition.provider_tool_name, name)) {
            return definition.key;
        }
    }
    return error.UnknownProviderToolName;
}

fn builtinCatalogDigest() binding.ToolCatalog {
    var hasher = binding.Hasher(binding.ToolCatalog).init();
    var count: [2]u8 = undefined;
    std.mem.writeInt(u16, &count, @intCast(default_catalog.len), .little);
    hasher.update(&count);
    for (default_catalog) |definition| {
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

/// Exact tool-argument bytes admitted under StrictToolJsonV1. The slice points
/// into the immutable capture or caller-owned storage; admission never rewrites
/// whitespace, object order, string escapes, or number spelling.
pub const StrictToolJson = struct {
    value: []const u8,
    proof: StrictToolJsonEvidence,

    pub fn bytes(self: StrictToolJson) []const u8 {
        return self.value;
    }

    pub fn evidence(self: StrictToolJson) StrictToolJsonEvidence {
        return self.proof;
    }
};

pub const StrictToolJsonEvidence = extern struct {
    digest: [32]u8 = @splat(0),
    length: u32 = 0,

    pub fn empty(self: StrictToolJsonEvidence) bool {
        return self.length == 0 and std.mem.allEqual(u8, &self.digest, 0);
    }

    pub fn validForLength(self: StrictToolJsonEvidence, length: u32) bool {
        return length != 0 and self.length == length;
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

pub const BashArguments = struct {
    json: StrictToolJson,
    command: []const u8,
    timeout_ms: u32,
};

pub const PatchArguments = struct {
    json: StrictToolJson,
    patch: []const u8,
};

pub const AdmittedToolArguments = union(enum) {
    bash: BashArguments,
    apply_patch: PatchArguments,
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
    return .{ .value = bytes, .proof = strictToolJsonEvidence(bytes) };
}

pub fn strictToolJsonEvidence(bytes: []const u8) StrictToolJsonEvidence {
    return .{
        .digest = binding.hash(binding.StrictToolJsonV1, bytes).bytes,
        .length = @intCast(bytes.len),
    };
}

/// Reopen already-admitted exact bytes without parsing them again.
pub fn strictToolJsonFromEvidence(
    bytes: []const u8,
    evidence_value: StrictToolJsonEvidence,
) !StrictToolJson {
    if (bytes.len == 0 or bytes.len > max_tool_arguments_envelope_size or
        bytes.len != evidence_value.length or
        !binding.eql(
            binding.StrictToolJsonV1,
            .{ .bytes = strictToolJsonEvidence(bytes).digest },
            .{ .bytes = evidence_value.digest },
        ))
    {
        return error.InvalidStrictToolJsonEvidence;
    }
    return .{ .value = bytes, .proof = evidence_value };
}

/// Apply the Operation-bound closed V1 tool schema to a strict JSON value.
pub fn admitToolArguments(
    scratch: *StrictToolJsonScratch,
    key: []const u8,
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
        .proof = strictToolJsonEvidence(bytes),
    };
    if (std.mem.eql(u8, key, bash_key)) {
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidToolArguments,
        };
        if (object.count() != 2) return error.InvalidToolArguments;
        const command = switch (object.get("command") orelse return error.InvalidToolArguments) {
            .string => |value| value,
            else => return error.InvalidToolArguments,
        };
        const timeout_ms = try jsonU32(
            object.get("timeout_ms") orelse return error.InvalidToolArguments,
        );
        validateBashCommand(command) catch return error.InvalidToolArguments;
        if (timeout_ms < 100 or timeout_ms > 120_000) return error.InvalidToolArguments;
        return .{ .bash = .{ .json = json, .command = command, .timeout_ms = timeout_ms } };
    }
    if (std.mem.eql(u8, key, apply_patch_key)) {
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidToolArguments,
        };
        if (object.count() != 1) return error.InvalidToolArguments;
        const patch = switch (object.get("patch") orelse return error.InvalidToolArguments) {
            .string => |value| value,
            else => return error.InvalidToolArguments,
        };
        validatePatchInput(patch) catch return error.InvalidToolArguments;
        return .{ .apply_patch = .{ .json = json, .patch = patch } };
    }
    return error.UnknownModelTool;
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
    try std.testing.expectEqualSlices(u8, &default_catalog_digest.bytes, &builtinCatalogDigest().bytes);
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
    const first = try admitToolArguments(&scratch, bash_key, first_bytes);
    const second = try admitToolArguments(&scratch, bash_key, second_bytes);
    try std.testing.expectEqualStrings(first_bytes, first.bash.json.bytes());
    try std.testing.expectEqualStrings(second_bytes, second.bash.json.bytes());
    try std.testing.expect(!std.mem.eql(
        u8,
        &first.bash.json.evidence().digest,
        &second.bash.json.evidence().digest,
    ));
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
        admitToolArguments(&scratch, bash_key, "{\"command\":1,\"timeout_ms\":1000}"),
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

test "StrictToolJsonV1 evidence distinguishes absence from an all-zero digest" {
    const absent: StrictToolJsonEvidence = .{};
    const zero_digest_value: StrictToolJsonEvidence = .{
        .digest = @splat(0),
        .length = 2,
    };
    try std.testing.expect(absent.empty());
    try std.testing.expect(!zero_digest_value.empty());
    try std.testing.expect(zero_digest_value.validForLength(2));
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
