//! The core's own tools (D24): their record text and their argument
//! checks. A call to one runs as a core command, never as an Action
//! process; who runs a tool is derived from its name (D46).

const std = @import("std");
const protocol = @import("protocol.zig");

/// Presets live in their launch frame, never in the Store. The spec's JSON
/// strings and objects are borrowed for the Host's life, not copied per slot.
pub const Preset = struct {
    name: []const u8,
    spec: std.json.ObjectMap,
};
pub const max_presets = 64;
pub const max_preset_name_bytes = protocol.max_preset_name_bytes;

pub fn validPresetName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_preset_name_bytes) return false;
    for (name) |byte| if (!(byte >= 'a' and byte <= 'z') and !std.ascii.isDigit(byte) and byte != '_' and byte != '-') return false;
    return true;
}

/// The most decoded bytes a `message_agent` text carries.
pub const message_agent_max_text_bytes = 64 * 1024;

// Prompt text: written here, and given no tests (D141).
pub const message_agent_description = "Send a Message to another Rui Session by its ID. It returns once the Message is delivered, before any answer. A reply, if the receiver sends one, arrives later as a Message that starts your next turn.";
pub const message_agent_schema = "{\"type\":\"object\",\"properties\":{" ++
    "\"id\":{\"type\":\"string\",\"description\":\"The receiving Session's six-character ID.\"}," ++
    std.fmt.comptimePrint("\"text\":{{\"type\":\"string\",\"description\":\"The Message: nonempty UTF-8, at most {d} bytes.\"}}", .{message_agent_max_text_bytes}) ++
    "},\"required\":[\"id\",\"text\"],\"additionalProperties\":false}";

/// The most bytes a `start_agent` call's arguments take: its task, at most
/// `message_agent_max_text_bytes` once decoded and six times that escaped
/// (`\u0001` for each byte), and its spec.
pub const start_agent_max_argument_bytes = 6 * message_agent_max_text_bytes + 16 * 1024;

// Prompt text: written here, and given no tests (D141).
pub const start_agent_description = "Start another Rui agent on a task. It creates the agent's Session, gives it the task as its first Message and returns the agent's ID at once, before any answer. " ++
    "An attached agent is your child: it inherits your Bash environment, and stops when you are stopped or run out of context. A standalone agent has its own lifetime. " ++
    "Give a spec, or a preset with optional spec overrides. The resolved spec may only narrow your tools and permission mode.";
pub const start_agent_schema = "{\"type\":\"object\",\"properties\":{" ++
    std.fmt.comptimePrint("\"task\":{{\"type\":\"string\",\"description\":\"The agent's first Message: nonempty UTF-8, at most {d} bytes.\"}},", .{message_agent_max_text_bytes}) ++
    "\"attached\":{\"type\":\"boolean\",\"description\":\"true starts your child, which stops with you; false starts a standalone agent.\"}," ++
    "\"preset\":{\"type\":\"string\"}," ++
    "\"spec\":{\"type\":\"object\",\"properties\":{" ++
    "\"provider\":{\"type\":\"string\"}," ++
    "\"workspace\":{\"type\":\"string\",\"description\":\"Required when Bash is enabled.\"}," ++
    "\"model\":{\"type\":\"string\"}," ++
    "\"effort\":{\"type\":[\"string\",\"null\"],\"enum\":[null,\"none\",\"low\",\"medium\",\"high\",\"xhigh\",\"max\"]}," ++
    "\"compactAt\":{\"type\":\"integer\",\"description\":\"Tokens of context at which the agent compacts.\"}," ++
    "\"tools\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Tool names, each one of yours.\"}," ++
    "\"permissionMode\":{\"type\":\"string\",\"enum\":[\"ask\",\"bypass\"]}," ++
    "\"instructions\":{\"type\":\"string\",\"description\":\"Optional agent instructions.\"}," ++
    "\"outputSchema\":{\"type\":[\"object\",\"null\"],\"description\":\"Optional JSON output schema.\"}," ++
    "\"label\":{\"type\":[\"string\",\"null\"],\"description\":\"A few words naming the agent's task.\"}" ++
    "},\"additionalProperties\":false}" ++
    "},\"required\":[\"task\",\"attached\"],\"anyOf\":[{\"required\":[\"preset\"]},{\"required\":[\"spec\"],\"properties\":{\"spec\":{\"required\":[\"model\",\"effort\",\"compactAt\",\"tools\",\"permissionMode\"]}}}],\"additionalProperties\":false}";

/// A `start_agent` call's checked arguments: the task, whether the agent
/// is attached, and its spec as a creating Configuration.
pub const StartAgent = struct {
    task: []const u8,
    instructions: ?[]const u8 = null,
    output_schema: ?[]const u8 = null,
    attached: bool,
    configuration: protocol.Configuration,
};

pub const StartAgentCheck = union(enum) {
    /// The call's `out` holds its checked arguments.
    accepted,
    /// Why the call's arguments were refused, naming the field (D140).
    rejected: []const u8,
};

/// Checks a `start_agent` call's decoded arguments. Parsed values live in
/// `arena`; `task` points into it.
/// An accepted call fills `out`, whose Configuration, kilobytes, is
/// written in place and never held in a frame.
pub fn checkStartAgent(arena: std.mem.Allocator, bytes: []const u8, out: *StartAgent) error{OutOfMemory}!StartAgentCheck {
    return checkStartAgentWithPresets(arena, bytes, &.{}, out);
}

/// Resolve a named seed and its explicit overrides, then check one whole spec.
pub fn checkStartAgentWithPresets(arena: std.mem.Allocator, bytes: []const u8, presets: []const Preset, out: *StartAgent) error{OutOfMemory}!StartAgentCheck {
    if (bytes.len > start_agent_max_argument_bytes) return refused(std.fmt.comptimePrint("the arguments take more than {d} bytes", .{start_agent_max_argument_bytes}));
    // Bound nesting before the DOM and recursive outputSchema serialization.
    var scanner = std.json.Scanner.initCompleteInput(arena, bytes);
    defer scanner.deinit();
    try scanner.ensureTotalStackCapacity(protocol.max_json_depth);
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return refused("the arguments are not one well-formed JSON object"),
        };
        if (scanner.stackHeight() > protocol.max_json_depth)
            return refused("the arguments exceed the maximum JSON nesting depth");
        if (token == .end_of_document) break;
    }
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateField => return refused("a field appears more than once"),
        else => return refused("the arguments are not one well-formed JSON object"),
    };
    const top = switch (root) {
        .object => |object| object,
        else => return refused("the arguments are not one JSON object"),
    };
    if (unknownField(top, &.{ "task", "attached", "spec", "preset" })) |name| return refusedField(arena, name, "is not a start_agent field");
    const task = switch (top.get("task") orelse return refused("task is required")) {
        .string => |text| text,
        else => return refused("task must be a string"),
    };
    if (task.len == 0 or task.len > message_agent_max_text_bytes or !std.unicode.utf8ValidateSlice(task))
        return refused(std.fmt.comptimePrint("task must be nonempty UTF-8 text, at most {d} bytes", .{message_agent_max_text_bytes}));
    const attached = switch (top.get("attached") orelse return refused("attached is required")) {
        .bool => |value| value,
        else => return refused("attached must be true or false"),
    };
    var spec: std.json.ObjectMap = .empty;
    if (top.get("preset")) |value| {
        const name = switch (value) {
            .string => |text| text,
            else => return refused("preset must be a preset name"),
        };
        const preset = for (presets) |*entry| {
            if (std.mem.eql(u8, name, entry.name)) break entry;
        } else return refusedField(arena, name, "is an unknown preset (preset)");
        var fields = preset.spec.iterator();
        while (fields.next()) |entry| try spec.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    } else if (!top.contains("spec")) return refused("spec is required");
    if (top.get("spec")) |value| {
        const overrides = switch (value) {
            .object => |object| object,
            else => return refused("spec must be an object"),
        };
        var fields = overrides.iterator();
        while (fields.next()) |entry| try spec.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }
    const checked = try parseAgentSpec(arena, spec, &out.configuration);
    if (checked == .rejected) return checked;
    out.task = task;
    out.attached = attached;
    out.instructions = out.configuration.instructions.borrowed_bytes;
    out.output_schema = out.configuration.output_schema.borrowed_bytes;
    return .accepted;
}

/// The single agent-spec parser for start_agent, launch presets and creation
/// seeds. It writes in place; content borrows `arena` through Store admission.
pub fn parseAgentSpec(arena: std.mem.Allocator, spec: std.json.ObjectMap, configuration: *protocol.Configuration) error{OutOfMemory}!StartAgentCheck {
    // D113/D133: provider defaults at the Host; workspace is required for Bash.
    if (unknownField(spec, &.{ "model", "effort", "compactAt", "tools", "permissionMode", "label", "instructions", "outputSchema", "provider", "workspace" })) |name|
        return refusedField(arena, name, "is not a spec field");
    configuration.* = .{};
    if (spec.contains("provider")) {
        if (!stringField(spec, "provider", &configuration.provider)) return refused("spec.provider must be a provider name");
        if (std.meta.stringToEnum(protocol.Provider, configuration.provider.value.slice()) == null)
            return refused("spec.provider must be a provider name");
    }
    if (spec.contains("workspace") and !stringField(spec, "workspace", &configuration.workspace))
        return refused("spec.workspace must be a Workspace path");
    if (!stringField(spec, "model", &configuration.model)) return refused("spec.model must be a model name");
    switch (spec.get("effort") orelse return refused("spec.effort is required")) {
        .null => configuration.reasoning_effort.state = .explicit_null,
        .string => {
            if (!stringField(spec, "effort", &configuration.reasoning_effort))
                return refused("spec.effort must be null, none, low, medium, high, xhigh or max");
            if (std.meta.stringToEnum(protocol.ReasoningEffort, configuration.reasoning_effort.value.slice()) == null)
                return refused("spec.effort must be null, none, low, medium, high, xhigh or max");
        },
        else => return refused("spec.effort must be null, none, low, medium, high, xhigh or max"),
    }
    const tokens: u64 = switch (spec.get("compactAt") orelse return refused("spec.compactAt is required")) {
        .integer => |value| if (value > 0) @intCast(value) else return refused("spec.compactAt must be a positive number of tokens"),
        .number_string => |value| std.fmt.parseInt(u64, value, 10) catch return refused("spec.compactAt must be a positive number of tokens"),
        else => return refused("spec.compactAt must be a positive number of tokens"),
    };
    if (tokens == 0) return refused("spec.compactAt must be a positive number of tokens");
    configuration.compaction_trigger.state = .value;
    configuration.compaction_trigger.value.set(std.fmt.allocPrint(arena, "{d}", .{tokens}) catch return error.OutOfMemory) catch unreachable;
    var unknown: []const u8 = "";
    toolsField(arena, spec.get("tools") orelse return refused("spec.tools is required"), &unknown, &configuration.tools) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return refused("spec.tools must be a list of distinct tool names"),
        error.UnknownTool => return refusedField(arena, unknown, "is not a Rui tool (spec.tools)"),
    };
    var selected_tools = configuration.tools.iterator();
    while (selected_tools.next()) |name| {
        if (std.mem.eql(u8, name, "bash") and configuration.workspace.state != .value)
            return refused("spec.workspace is required when spec.tools includes bash");
    }
    if (!stringField(spec, "permissionMode", &configuration.permission_mode)) return refused("spec.permissionMode must be ask or bypass");
    if (!configuration.permission_mode.value.eql("ask") and !configuration.permission_mode.value.eql("bypass"))
        return refused("spec.permissionMode must be ask or bypass");
    switch (spec.get("label") orelse .null) {
        .null => if (spec.contains("label")) {
            configuration.label.state = .explicit_null;
        },
        .string => |label| {
            configuration.label.state = .value;
            configuration.label.value.set(label) catch return refused(std.fmt.comptimePrint("spec.label takes at most {d} bytes", .{protocol.max_label_bytes}));
            if (!protocol.validLabel(label)) return refused("spec.label must be one nonblank line of UTF-8");
        },
        else => return refused("spec.label must be a string or null"),
    }
    const instructions = switch (spec.get("instructions") orelse .null) {
        .null => if (spec.contains("instructions")) return refused("spec.instructions must be a string") else null,
        .string => |text| if (std.unicode.utf8ValidateSlice(text)) text else return refused("spec.instructions must be UTF-8 text"),
        else => return refused("spec.instructions must be a string"),
    };
    const output_schema = switch (spec.get("outputSchema") orelse .null) {
        .null => value: {
            if (spec.contains("outputSchema")) configuration.output_schema.state = .explicit_null;
            break :value null;
        },
        .object => |object| std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = object }, .{}) catch return error.OutOfMemory,
        else => return refused("spec.outputSchema must be a JSON object or null"),
    };
    if (instructions) |bytes_value| configuration.instructions = .{
        .state = .value,
        .borrowed_bytes = bytes_value,
        .length = bytes_value.len,
        .digest = protocol.contentDigest(bytes_value),
    };
    if (output_schema) |bytes_value| configuration.output_schema = .{
        .state = .value,
        .borrowed_bytes = bytes_value,
        .length = bytes_value.len,
        .digest = protocol.contentDigest(bytes_value),
    };
    return .accepted;
}

fn refused(comptime text: []const u8) StartAgentCheck {
    return .{ .rejected = text };
}

/// A bounded diagnostic, never a selector: keep a complete UTF-8 prefix.
pub fn diagnosticName(name: []const u8) []const u8 {
    var length = @min(name.len, max_preset_name_bytes);
    while (!std.unicode.utf8ValidateSlice(name[0..length])) length -= 1;
    return name[0..length];
}

fn refusedField(arena: std.mem.Allocator, name: []const u8, comptime what: []const u8) error{OutOfMemory}!StartAgentCheck {
    const shown = diagnosticName(name);
    return .{ .rejected = try std.fmt.allocPrint(arena, "{s} " ++ what, .{shown}) };
}

fn unknownField(object: std.json.ObjectMap, comptime known: []const []const u8) ?[]const u8 {
    var keys = object.iterator();
    next: while (keys.next()) |entry| {
        inline for (known) |name| if (std.mem.eql(u8, entry.key_ptr.*, name)) continue :next;
        return entry.key_ptr.*;
    }
    return null;
}

/// Fill a nonempty bounded string field in place: a Workspace is over 1 KiB.
fn stringField(object: std.json.ObjectMap, comptime name: []const u8, field: anytype) bool {
    const text = switch (object.get(name) orelse return false) {
        .string => |value| value,
        else => return false,
    };
    if (text.len == 0) return false;
    field.value.set(text) catch return false;
    field.state = .value;
    return true;
}

/// The tool list `value` names, sorted; `unknown` is set to a name no
/// built-in tool has.
fn toolsField(arena: std.mem.Allocator, value: std.json.Value, unknown: *[]const u8, tools: *protocol.ToolsField) error{ OutOfMemory, Refused, UnknownTool }!void {
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.Refused,
    };
    const names = try arena.alloc([]const u8, items.len);
    for (items, names) |item, *name| {
        name.* = switch (item) {
            .string => |text| text,
            else => return error.Refused,
        };
        if (protocol.builtInTool(name.*) == null) {
            unknown.* = name.*;
            return error.UnknownTool;
        }
    }
    std.sort.insertion([]const u8, names, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    tools.* = .{ .state = .value };
    for (names) |name| tools.append(name) catch return error.Refused;
}

/// A `message_agent` call's checked arguments, without its text.
pub const MessageAgentArguments = struct {
    id: protocol.Bounded(protocol.session_id_bytes) = .{},
    text_bytes: u64 = 0,
};

/// Why a `message_agent` call's arguments were rejected. Its text goes back
/// to the model as the call's result.
pub const MessageAgentProblem = enum {
    malformed_json,
    unknown_field,
    duplicate_field,
    missing_id,
    missing_text,
    id_invalid,
    text_invalid,

    pub fn text(self: MessageAgentProblem) []const u8 {
        return switch (self) {
            .malformed_json => "the arguments are not one well-formed JSON object",
            .unknown_field => "only id and text are accepted",
            .duplicate_field => "a field appears more than once",
            .missing_id => "id is required",
            .missing_text => "text is required",
            .id_invalid => "id must be a Session's six-character ID",
            .text_invalid => std.fmt.comptimePrint("text must be a nonempty string of UTF-8 text, at most {d} bytes", .{message_agent_max_text_bytes}),
        };
    }
};

pub const MessageAgentCheck = union(enum) {
    accepted: MessageAgentArguments,
    rejected: MessageAgentProblem,
};

/// Checks a `message_agent` call's decoded arguments from `source` (with
/// `peek` and `take`, as Bash's parser reads them) and writes the text's
/// decoded bytes to `text` (with `writeAll`) as they are read. The writer
/// sees text from arguments that may yet be rejected, so a caller keeps it
/// only on `.accepted`.
pub fn checkMessageAgent(source: anytype, text: anytype) !MessageAgentCheck {
    return checkObject(source, text) catch |err| switch (err) {
        error.Malformed => .{ .rejected = .malformed_json },
        else => |e| e,
    };
}

fn checkObject(source: anytype, text: anytype) !MessageAgentCheck {
    // A flat object needs one level of the scanner's stack, which grows
    // its list by more than one byte at a time.
    var stack: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&stack);
    var reader: Reader(@TypeOf(source)) = .{ .source = source, .scanner = .initStreaming(fixed.allocator()) };
    if (try reader.next() != .object_begin) return error.Malformed;
    const Field = enum { id, text };
    var seen: std.EnumSet(Field) = .empty;
    var out: MessageAgentArguments = .{ .id = .{ .len = 0 } };
    while (true) {
        var token = try reader.next();
        if (token == .object_end) break;
        // The key, piece by piece; one longer than every field's is unknown.
        var key: protocol.Bounded(8) = .{ .len = 0 };
        var key_fits = true;
        while (true) {
            const piece = stringPiece(&token) orelse return error.Malformed;
            if (key.len + piece.len > key.bytes.len) key_fits = false else {
                @memcpy(key.bytes[key.len..][0..piece.len], piece);
                key.len += piece.len;
            }
            if (token == .string) break;
            token = try reader.next();
        }
        const field = (if (key_fits) std.meta.stringToEnum(Field, key.slice()) else null) orelse return .{ .rejected = .unknown_field };
        if (seen.contains(field)) return .{ .rejected = .duplicate_field };
        seen.insert(field);
        var value = try reader.next();
        if (stringPiece(&value) == null) return .{ .rejected = switch (field) {
            .id => .id_invalid,
            .text => .text_invalid,
        } };
        var id_fits = true;
        while (true) {
            const piece = stringPiece(&value) orelse return error.Malformed;
            switch (field) {
                .id => if (out.id.len + piece.len > out.id.bytes.len) {
                    id_fits = false;
                } else {
                    @memcpy(out.id.bytes[out.id.len..][0..piece.len], piece);
                    out.id.len += piece.len;
                },
                .text => {
                    out.text_bytes += piece.len;
                    if (out.text_bytes > message_agent_max_text_bytes) return .{ .rejected = .text_invalid };
                    try text.writeAll(piece);
                },
            }
            if (value == .string) break;
            value = try reader.next();
        }
        switch (field) {
            .id => if (!id_fits or !protocol.validSessionId(out.id.slice())) return .{ .rejected = .id_invalid },
            .text => if (out.text_bytes == 0) return .{ .rejected = .text_invalid },
        }
    }
    if (try reader.next() != .end_of_document) return error.Malformed;
    if (!seen.contains(.id)) return .{ .rejected = .missing_id };
    if (!seen.contains(.text)) return .{ .rejected = .missing_text };
    return .{ .accepted = out };
}

/// The bytes a string token carries, or null for any other token.
fn stringPiece(token: *const std.json.Token) ?[]const u8 {
    return switch (token.*) {
        .partial_string, .string => |bytes| bytes,
        .partial_string_escaped_1 => |*bytes| bytes,
        .partial_string_escaped_2 => |*bytes| bytes,
        .partial_string_escaped_3 => |*bytes| bytes,
        .partial_string_escaped_4 => |*bytes| bytes,
        else => null,
    };
}

/// Feeds the scanner from `source` a chunk at a time. A token's bytes
/// point into `chunk`, which is refilled only once they are used.
fn Reader(comptime Source: type) type {
    return struct {
        source: Source,
        scanner: std.json.Scanner,
        /// Small: the source buffers its own reads, and this lives in the
        /// settlement scan's and the engine's frames.
        chunk: [256]u8 = undefined,
        ended: bool = false,

        fn next(self: *@This()) !std.json.Token {
            while (true) return self.scanner.next() catch |err| switch (err) {
                error.BufferUnderrun => {
                    try self.refill();
                    continue;
                },
                error.SyntaxError, error.UnexpectedEndOfInput, error.OutOfMemory => error.Malformed,
            };
        }

        fn refill(self: *@This()) !void {
            if (self.ended) return error.Malformed;
            var length: usize = 0;
            while (length < self.chunk.len) : (length += 1) {
                const byte = (self.source.peek() catch |err| return if (isDecodeError(err)) error.Malformed else err) orelse break;
                _ = byte;
                self.chunk[length] = self.source.take() catch |err| return if (isDecodeError(err)) error.Malformed else err;
            }
            if (length == 0) {
                self.ended = true;
                self.scanner.endInput();
            } else self.scanner.feedInput(self.chunk[0..length]);
        }
    };
}

fn isDecodeError(err: anyerror) bool {
    return switch (err) {
        error.InvalidDescriptorShape, error.InvalidUtf8 => true,
        else => false,
    };
}

/// A call's arguments already in memory, as the checks read them.
pub const SliceSource = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn peek(self: *SliceSource) !?u8 {
        return if (self.position == self.bytes.len) null else self.bytes[self.position];
    }

    pub fn take(self: *SliceSource) !u8 {
        const byte = (try self.peek()) orelse return error.ShortCanonicalRead;
        self.position += 1;
        return byte;
    }
};

const TestSource = SliceSource;

const TestText = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,

    fn writeAll(self: *TestText, piece: []const u8) !void {
        @memcpy(self.bytes[self.len..][0..piece.len], piece);
        self.len += piece.len;
    }
};

test "a message_agent call's arguments name a Session and carry nonempty text" {
    const Case = struct { arguments: []const u8, expected: union(enum) { accepted: []const u8, rejected: MessageAgentProblem } };
    for ([_]Case{
        .{ .arguments = "{\"id\":\"k7m2qx\",\"text\":\"report back\"}", .expected = .{ .accepted = "report back" } },
        .{ .arguments = " { \"text\" : \"a\\nb \\u00e9\\ud83d\\ude00\" , \"id\" : \"k7m2qx\" } ", .expected = .{ .accepted = "a\nb é😀" } },
        .{ .arguments = "{\"id\":\"k7m2qx\"}", .expected = .{ .rejected = .missing_text } },
        .{ .arguments = "{\"text\":\"hi\"}", .expected = .{ .rejected = .missing_id } },
        .{ .arguments = "{\"id\":\"k7m2qx\",\"text\":\"\"}", .expected = .{ .rejected = .text_invalid } },
        .{ .arguments = "{\"id\":\"k7m2qx\",\"text\":7}", .expected = .{ .rejected = .text_invalid } },
        .{ .arguments = "{\"id\":\"K7M2QX\",\"text\":\"hi\"}", .expected = .{ .rejected = .id_invalid } },
        .{ .arguments = "{\"id\":\"k7m2qxk7m2qx\",\"text\":\"hi\"}", .expected = .{ .rejected = .id_invalid } },
        .{ .arguments = "{\"id\":[\"k7m2qx\"],\"text\":\"hi\"}", .expected = .{ .rejected = .id_invalid } },
        .{ .arguments = "{\"id\":\"k7m2qx\",\"id\":\"k7m2qx\",\"text\":\"hi\"}", .expected = .{ .rejected = .duplicate_field } },
        .{ .arguments = "{\"id\":\"k7m2qx\",\"text\":\"hi\",\"note\":1}", .expected = .{ .rejected = .unknown_field } },
        .{ .arguments = "{\"identifier\":\"k7m2qx\"}", .expected = .{ .rejected = .unknown_field } },
        .{ .arguments = "{\"id\":\"k7m2qx\",\"text\":\"hi\"} {}", .expected = .{ .rejected = .malformed_json } },
        .{ .arguments = "{\"id\":\"k7m2qx\",\"text\":\"hi\"", .expected = .{ .rejected = .malformed_json } },
        .{ .arguments = "[]", .expected = .{ .rejected = .malformed_json } },
        .{ .arguments = "", .expected = .{ .rejected = .malformed_json } },
        .{ .arguments = "{\"id\":\"k7m2qx\",\"text\":\"\xff\"}", .expected = .{ .rejected = .malformed_json } },
    }) |case| {
        var source: TestSource = .{ .bytes = case.arguments };
        var text: TestText = .{};
        const check = try checkMessageAgent(&source, &text);
        switch (case.expected) {
            .accepted => |expected| {
                try std.testing.expectEqualStrings("k7m2qx", check.accepted.id.slice());
                try std.testing.expectEqualStrings(expected, text.bytes[0..text.len]);
                try std.testing.expectEqual(expected.len, check.accepted.text_bytes);
            },
            .rejected => |expected| try std.testing.expectEqual(MessageAgentCheck{ .rejected = expected }, check),
        }
    }
}

test "a message_agent text over its bound is rejected, across chunk boundaries" {
    const Discard = struct {
        fn writeAll(_: *@This(), _: []const u8) !void {}
    };
    var buffer: [message_agent_max_text_bytes + 64]u8 = undefined;
    for ([_]usize{ message_agent_max_text_bytes, message_agent_max_text_bytes + 1 }) |length| {
        const head = "{\"id\":\"k7m2qx\",\"text\":\"";
        @memcpy(buffer[0..head.len], head);
        @memset(buffer[head.len..][0..length], 'a');
        @memcpy(buffer[head.len + length ..][0..2], "\"}");
        var source: TestSource = .{ .bytes = buffer[0 .. head.len + length + 2] };
        var discard: Discard = .{};
        const check = try checkMessageAgent(&source, &discard);
        if (length == message_agent_max_text_bytes)
            try std.testing.expectEqual(@as(u64, length), check.accepted.text_bytes)
        else
            try std.testing.expectEqual(MessageAgentCheck{ .rejected = .text_invalid }, check);
    }
}

test "a start_agent call's arguments carry a task and a whole spec with an optional provider and Bash Workspace" {
    const spec = "\"spec\":{\"model\":\"gpt-6.1-sol\",\"effort\":\"low\",\"compactAt\":100000,\"tools\":[\"start_agent\",\"bash\"],\"workspace\":\"/\",\"provider\":\"codex\",\"permissionMode\":\"ask\",\"label\":null}";
    const Case = struct { arguments: []const u8, refusal: ?[]const u8 = null };
    for ([_]Case{
        .{ .arguments = "{\"task\":\"read\",\"attached\":true," ++ spec ++ "}" },
        .{ .arguments = "{\"task\":\"\",\"attached\":true," ++ spec ++ "}", .refusal = "task must be nonempty UTF-8 text, at most 65536 bytes" },
        .{ .arguments = "{\"attached\":true," ++ spec ++ "}", .refusal = "task is required" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":1," ++ spec ++ "}", .refusal = "attached must be true or false" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true}", .refusal = "spec is required" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"m\",\"effort\":\"low\",\"compactAt\":1,\"tools\":[\"edit\"],\"permissionMode\":\"ask\",\"label\":null}}", .refusal = "edit is not a Rui tool (spec.tools)" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"m\",\"effort\":\"low\",\"compactAt\":1,\"tools\":[\"bash\",\"bash\"],\"permissionMode\":\"ask\",\"label\":null}}", .refusal = "spec.tools must be a list of distinct tool names" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"m\",\"effort\":\"low\",\"compactAt\":0,\"tools\":[],\"permissionMode\":\"ask\",\"label\":null}}", .refusal = "spec.compactAt must be a positive number of tokens" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"m\",\"effort\":\"low\",\"compactAt\":1,\"tools\":[],\"permissionMode\":\"never\",\"label\":null}}", .refusal = "spec.permissionMode must be ask or bypass" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"m\",\"effort\":null,\"compactAt\":1,\"tools\":[\"bash\"],\"permissionMode\":\"ask\"}}", .refusal = "spec.workspace is required when spec.tools includes bash" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"note\":1," ++ spec ++ "}", .refusal = "note is not a start_agent field" },
        .{ .arguments = "{\"task\":\"read\",\"task\":\"again\",\"attached\":true," ++ spec ++ "}", .refusal = "a field appears more than once" },
        .{ .arguments = "[]", .refusal = "the arguments are not one JSON object" },
        .{ .arguments = "{", .refusal = "the arguments are not one well-formed JSON object" },
    }) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const start = try arena.allocator().create(StartAgent);
        const check = try checkStartAgent(arena.allocator(), case.arguments, start);
        if (case.refusal) |expected| {
            try std.testing.expectEqualStrings(expected, check.rejected);
        } else {
            try std.testing.expect(check == .accepted);
            try std.testing.expectEqualStrings("read", start.task);
            try std.testing.expect(start.attached);
            try std.testing.expectEqualStrings("gpt-6.1-sol", start.configuration.model.value.slice());
            try std.testing.expectEqualStrings("100000", start.configuration.compaction_trigger.value.slice());
            // Sorted, as the Store's tool list requires.
            try std.testing.expectEqualStrings("bash start_agent", start.configuration.tools.names.slice());
            try std.testing.expect(start.configuration.workspace.state == .value and start.configuration.provider.state == .value and start.configuration.label.state != .value);
        }
    }
}

test "a start_agent task at its bound is accepted however it is escaped, and one byte more is the task's refusal" {
    const spec = ",\"attached\":false,\"spec\":{\"model\":\"gpt-6.1-sol\",\"effort\":\"low\",\"compactAt\":100000,\"tools\":[],\"permissionMode\":\"ask\",\"label\":null}}";
    for ([_]usize{ message_agent_max_text_bytes, message_agent_max_text_bytes + 1 }) |length| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var arguments: std.ArrayList(u8) = .empty;
        try arguments.appendSlice(arena.allocator(), "{\"task\":\"");
        // Every byte takes the longest escape.
        for (0..length) |_| try arguments.appendSlice(arena.allocator(), "\\u0001");
        try arguments.appendSlice(arena.allocator(), "\"" ++ spec);
        try std.testing.expect(arguments.items.len <= start_agent_max_argument_bytes);
        const start = try arena.allocator().create(StartAgent);
        const check = try checkStartAgent(arena.allocator(), arguments.items, start);
        if (length == message_agent_max_text_bytes) {
            try std.testing.expect(check == .accepted);
            try std.testing.expectEqual(length, start.task.len);
            for (start.task) |byte| try std.testing.expectEqual(@as(u8, 1), byte);
        } else try std.testing.expectEqualStrings("task must be nonempty UTF-8 text, at most 65536 bytes", check.rejected);
    }
}

test "core_tools start_agent requires every required spec field and accepts null effort" {
    const fields = [_][]const u8{ "model", "effort", "compactAt", "tools", "permissionMode" };
    const values = [_][]const u8{ "\"custom\"", "null", "18446744073709551615", "[]", "\"ask\"" };
    for (0..fields.len + 1) |omitted| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var json: std.Io.Writer.Allocating = .init(allocator);
        try json.writer.writeAll("{\"task\":\"read\",\"attached\":true,\"spec\":{");
        var separator: []const u8 = "";
        for (fields, values, 0..) |field, value, index| {
            if (index == omitted) continue;
            try json.writer.print("{s}\"{s}\":{s}", .{ separator, field, value });
            separator = ",";
        }
        try json.writer.writeAll("}}");
        const start = try allocator.create(StartAgent);
        const result = try checkStartAgent(allocator, json.written(), start);
        if (omitted < fields.len) {
            try std.testing.expect(result == .rejected);
            try std.testing.expect(std.mem.indexOf(u8, result.rejected, fields[omitted]) != null);
        } else {
            try std.testing.expect(result == .accepted);
            try std.testing.expectEqual(.explicit_null, start.configuration.reasoning_effort.state);
            try std.testing.expectEqualStrings("18446744073709551615", start.configuration.compaction_trigger.value.slice());
        }
    }
}

test "core_tools start_agent optional instructions and output schema" {
    const base = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"custom\",\"effort\":null,\"compactAt\":1,\"tools\":[],\"permissionMode\":\"ask\"";
    const Case = struct { extra: []const u8, refusal: ?[]const u8 = null };
    for ([_]Case{
        .{ .extra = ",\"instructions\":\"Be helpful\",\"outputSchema\":{\"type\":\"object\"}" },
        .{ .extra = ",\"instructions\":\"\",\"outputSchema\":null" },
        .{ .extra = ",\"instructions\":null", .refusal = "spec.instructions" },
        .{ .extra = ",\"instructions\":123", .refusal = "spec.instructions" },
        .{ .extra = ",\"outputSchema\":[]", .refusal = "spec.outputSchema" },
        .{ .extra = ",\"outputSchema\":\"{}\"", .refusal = "spec.outputSchema" },
    }) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const start = try allocator.create(StartAgent);
        const bytes = try std.fmt.allocPrint(allocator, "{s}{s}}}}}", .{ base, case.extra });
        const result = try checkStartAgent(allocator, bytes, start);
        if (case.refusal) |field| {
            try std.testing.expect(result == .rejected);
            try std.testing.expect(std.mem.indexOf(u8, result.rejected, field) != null);
        } else {
            try std.testing.expect(result == .accepted);
            try std.testing.expect(start.instructions != null);
            try std.testing.expectEqual(.value, start.configuration.instructions.state);
            try std.testing.expectEqualStrings(start.instructions.?, start.configuration.instructions.borrowed_bytes.?);
            try std.testing.expectEqual(start.instructions.?.len, start.configuration.instructions.length);
            try std.testing.expectEqual(protocol.contentDigest(start.instructions.?), start.configuration.instructions.digest);
            if (start.output_schema) |schema| {
                try std.testing.expectEqual(.value, start.configuration.output_schema.state);
                try std.testing.expectEqualStrings(schema, start.configuration.output_schema.borrowed_bytes.?);
                try std.testing.expectEqual(protocol.contentDigest(schema), start.configuration.output_schema.digest);
            } else try std.testing.expectEqual(.explicit_null, start.configuration.output_schema.state);
            if (start.instructions.?.len != 0) {
                try std.testing.expectEqualStrings("Be helpful", start.instructions.?);
                try std.testing.expectEqualStrings("{\"type\":\"object\"}", start.output_schema.?);
            } else try std.testing.expect(start.output_schema == null);
        }
    }
}

test "core_tools start_agent bounds nested output schema before serialization" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var json: std.Io.Writer.Allocating = .init(allocator);
    try json.writer.writeAll("{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"custom\",\"effort\":null,\"compactAt\":1,\"tools\":[],\"permissionMode\":\"ask\",\"outputSchema\":");
    for (0..protocol.max_json_depth) |_| try json.writer.writeAll("{\"nested\":");
    try json.writer.writeAll("null");
    for (0..protocol.max_json_depth) |_| try json.writer.writeAll("}");
    try json.writer.writeAll("}}");
    const start = try allocator.create(StartAgent);
    const result = try checkStartAgent(allocator, json.written(), start);
    try std.testing.expectEqualStrings("the arguments exceed the maximum JSON nesting depth", result.rejected);
}

test "presets resolve start_agent overrides including explicit null before checks" {
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const spec = (try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"model":"model-a","effort":"low","compactAt":1000,"tools":["bash"],"workspace":"/","permissionMode":"ask","instructions":"Preset text","outputSchema":{"type":"object"},"label":"Preset label"}
    , .{})).object;
    const presets = [_]Preset{.{ .name = "review", .spec = spec }};
    const start = try arena.create(StartAgent);
    const checked = try checkStartAgentWithPresets(arena,
        \\{"task":"read","attached":true,"preset":"review","spec":{"model":"model-b","effort":null,"tools":[],"outputSchema":null,"label":null}}
    , &presets, start);
    try std.testing.expect(checked == .accepted);
    try std.testing.expectEqualStrings("model-b", start.configuration.model.value.slice());
    try std.testing.expectEqualStrings("1000", start.configuration.compaction_trigger.value.slice());
    try std.testing.expectEqualStrings("ask", start.configuration.permission_mode.value.slice());
    try std.testing.expectEqualStrings("Preset text", start.instructions.?);
    try std.testing.expectEqual(@as(u8, 0), start.configuration.tools.count);
    try std.testing.expectEqual(protocol.FieldState.explicit_null, start.configuration.reasoning_effort.state);
    try std.testing.expectEqual(protocol.FieldState.explicit_null, start.configuration.output_schema.state);
    try std.testing.expectEqual(protocol.FieldState.explicit_null, start.configuration.label.state);
    const inherited = try checkStartAgentWithPresets(arena,
        \\{"task":"read","attached":false,"preset":"review"}
    , &presets, start);
    try std.testing.expect(inherited == .accepted);
    try std.testing.expectEqualStrings("model-a", start.configuration.model.value.slice());
    try std.testing.expectEqual(@as(u8, 1), start.configuration.tools.count);
    for ([_]struct { arguments: []const u8, field: []const u8 }{
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"preset\":\"missing\"}", .field = "preset" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"preset\":123}", .field = "preset" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"preset\":\"review\",\"spec\":{\"model\":null}}", .field = "spec.model" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"preset\":\"review\",\"spec\":{\"workspace\":null}}", .field = "spec.workspace" },
    }) |case| {
        const refused_call = try checkStartAgentWithPresets(arena, case.arguments, &presets, start);
        try std.testing.expect(refused_call == .rejected);
        try std.testing.expect(std.mem.indexOf(u8, refused_call.rejected, case.field) != null);
    }
}
