//! The core's own tools (D24): their record text and their argument
//! checks. A call to one runs as a core command, never as an Action
//! process; who runs a tool is derived from its name (D46).

const std = @import("std");
const protocol = @import("protocol.zig");

/// The most decoded bytes a `message_agent` text carries.
pub const message_agent_max_text_bytes = 64 * 1024;

// Prompt text: written here, and given no tests (D141).
pub const message_agent_description = "Send a Message to another Rui Session by its ID. It returns once the Message is delivered, before any answer. A reply, if the receiver sends one, arrives later as a Message that starts your next turn.";
pub const message_agent_schema = "{\"type\":\"object\",\"properties\":{" ++
    "\"id\":{\"type\":\"string\",\"description\":\"The receiving Session's six-character ID.\"}," ++
    std.fmt.comptimePrint("\"text\":{{\"type\":\"string\",\"description\":\"The Message: nonempty UTF-8, at most {d} bytes.\"}}", .{message_agent_max_text_bytes}) ++
    "},\"required\":[\"id\",\"text\"],\"additionalProperties\":false}";

/// The most bytes a `start_agent` call's arguments take: its task, at most
/// `message_agent_max_text_bytes`, and its spec.
pub const start_agent_max_argument_bytes = message_agent_max_text_bytes + 16 * 1024;

// Prompt text: written here, and given no tests (D141).
pub const start_agent_description = "Start another Rui agent on a task. It creates the agent's Session, gives it the task as its first Message and returns the agent's ID at once, before any answer. " ++
    "An attached agent is your child: it works in your Workspace with your provider and Bash environment, and stops when you are stopped. A standalone agent has its own lifetime. " ++
    "The spec may only narrow your own tools and permission mode.";
pub const start_agent_schema = "{\"type\":\"object\",\"properties\":{" ++
    std.fmt.comptimePrint("\"task\":{{\"type\":\"string\",\"description\":\"The agent's first Message: nonempty UTF-8, at most {d} bytes.\"}},", .{message_agent_max_text_bytes}) ++
    "\"attached\":{\"type\":\"boolean\",\"description\":\"true starts your child, which stops with you; false starts a standalone agent.\"}," ++
    "\"spec\":{\"type\":\"object\",\"properties\":{" ++
    "\"model\":{\"type\":\"string\"}," ++
    "\"effort\":{\"type\":\"string\",\"enum\":[\"none\",\"low\",\"medium\",\"high\",\"xhigh\",\"max\"]}," ++
    "\"compactAt\":{\"type\":\"integer\",\"description\":\"Tokens of context at which the agent compacts.\"}," ++
    "\"tools\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Tool names, each one of yours.\"}," ++
    "\"permissionMode\":{\"type\":\"string\",\"enum\":[\"ask\",\"bypass\"]}," ++
    "\"label\":{\"type\":[\"string\",\"null\"],\"description\":\"A few words naming the agent's task.\"}" ++
    "},\"required\":[\"model\",\"effort\",\"compactAt\",\"tools\",\"permissionMode\",\"label\"],\"additionalProperties\":false}" ++
    "},\"required\":[\"task\",\"attached\",\"spec\"],\"additionalProperties\":false}";

/// A `start_agent` call's checked arguments: the task, whether the agent
/// is attached, and its spec as a creating Configuration without the
/// Workspace and provider, which come from the calling Session (D122).
pub const StartAgent = struct {
    task: []const u8,
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
    if (bytes.len > start_agent_max_argument_bytes) return refused(std.fmt.comptimePrint("the arguments take more than {d} bytes", .{start_agent_max_argument_bytes}));
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateField => return refused("a field appears more than once"),
        else => return refused("the arguments are not one well-formed JSON object"),
    };
    const top = switch (root) {
        .object => |object| object,
        else => return refused("the arguments are not one JSON object"),
    };
    if (unknownField(top, &.{ "task", "attached", "spec" })) |name| return refusedField(arena, name, "is not a start_agent field");
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
    const spec = switch (top.get("spec") orelse return refused("spec is required")) {
        .object => |object| object,
        else => return refused("spec must be an object"),
    };
    // An agent works where its parent does, with its provider (D140).
    if (spec.get("workspace") != null) return refused("spec.workspace: an agent always works in your Workspace");
    if (spec.get("provider") != null) return refused("spec.provider: an agent always uses your provider");
    if (unknownField(spec, &.{ "model", "effort", "compactAt", "tools", "permissionMode", "label" })) |name|
        return refusedField(arena, name, "is not a spec field");
    out.configuration = .{};
    const configuration = &out.configuration;
    configuration.model = stringField(spec, "model", @TypeOf(configuration.model)) orelse return refused("spec.model must be a model name");
    configuration.reasoning_effort = stringField(spec, "effort", @TypeOf(configuration.reasoning_effort)) orelse
        return refused("spec.effort must be none, low, medium, high, xhigh or max");
    if (std.meta.stringToEnum(protocol.ReasoningEffort, configuration.reasoning_effort.value.slice()) == null)
        return refused("spec.effort must be none, low, medium, high, xhigh or max");
    switch (spec.get("compactAt") orelse return refused("spec.compactAt is required")) {
        .integer => |tokens| {
            if (tokens <= 0) return refused("spec.compactAt must be a positive number of tokens");
            configuration.compaction_trigger.state = .value;
            configuration.compaction_trigger.value.set(std.fmt.allocPrint(arena, "{d}", .{tokens}) catch return error.OutOfMemory) catch unreachable;
        },
        else => return refused("spec.compactAt must be a positive number of tokens"),
    }
    var unknown: []const u8 = "";
    configuration.tools = toolsField(arena, spec.get("tools") orelse return refused("spec.tools is required"), &unknown) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return refused("spec.tools must be a list of distinct tool names"),
        error.UnknownTool => return refusedField(arena, unknown, "is not a Rui tool (spec.tools)"),
    };
    configuration.permission_mode = stringField(spec, "permissionMode", @TypeOf(configuration.permission_mode)) orelse
        return refused("spec.permissionMode must be ask or bypass");
    if (!configuration.permission_mode.value.eql("ask") and !configuration.permission_mode.value.eql("bypass"))
        return refused("spec.permissionMode must be ask or bypass");
    switch (spec.get("label") orelse .null) {
        .null => {},
        .string => |label| {
            configuration.label.state = .value;
            configuration.label.value.set(label) catch return refused(std.fmt.comptimePrint("spec.label takes at most {d} bytes", .{protocol.max_label_bytes}));
        },
        else => return refused("spec.label must be a string or null"),
    }
    out.task = task;
    out.attached = attached;
    return .accepted;
}

fn refused(comptime text: []const u8) StartAgentCheck {
    return .{ .rejected = text };
}

fn refusedField(arena: std.mem.Allocator, name: []const u8, comptime what: []const u8) error{OutOfMemory}!StartAgentCheck {
    const shown = name[0..@min(name.len, 64)];
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

/// A nonempty string field as the Configuration field type `T`, or null
/// when it is absent, not a string, or too long.
fn stringField(object: std.json.ObjectMap, comptime name: []const u8, comptime T: type) ?T {
    const text = switch (object.get(name) orelse return null) {
        .string => |value| value,
        else => return null,
    };
    if (text.len == 0) return null;
    var field: T = .{ .state = .value };
    field.value.set(text) catch return null;
    return field;
}

/// The tool list `value` names, sorted; `unknown` is set to a name no
/// built-in tool has.
fn toolsField(arena: std.mem.Allocator, value: std.json.Value, unknown: *[]const u8) error{ OutOfMemory, Refused, UnknownTool }!protocol.ToolsField {
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
    var tools: protocol.ToolsField = .{ .state = .value };
    for (names) |name| tools.append(name) catch return error.Refused;
    return tools;
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

test "a start_agent call's arguments carry a task and a whole spec, never a Workspace or provider" {
    const spec = "\"spec\":{\"model\":\"gpt-6.1-sol\",\"effort\":\"low\",\"compactAt\":100000,\"tools\":[\"start_agent\",\"bash\"],\"permissionMode\":\"ask\",\"label\":null}";
    const Case = struct { arguments: []const u8, refusal: ?[]const u8 = null };
    for ([_]Case{
        .{ .arguments = "{\"task\":\"read\",\"attached\":true," ++ spec ++ "}" },
        .{ .arguments = "{\"task\":\"\",\"attached\":true," ++ spec ++ "}", .refusal = "task must be nonempty UTF-8 text, at most 65536 bytes" },
        .{ .arguments = "{\"attached\":true," ++ spec ++ "}", .refusal = "task is required" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":1," ++ spec ++ "}", .refusal = "attached must be true or false" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true}", .refusal = "spec is required" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"workspace\":\"/\"}}", .refusal = "spec.workspace: an agent always works in your Workspace" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"provider\":\"codex\"}}", .refusal = "spec.provider: an agent always uses your provider" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"m\",\"effort\":\"low\",\"compactAt\":1,\"tools\":[\"edit\"],\"permissionMode\":\"ask\",\"label\":null}}", .refusal = "edit is not a Rui tool (spec.tools)" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"m\",\"effort\":\"low\",\"compactAt\":1,\"tools\":[\"bash\",\"bash\"],\"permissionMode\":\"ask\",\"label\":null}}", .refusal = "spec.tools must be a list of distinct tool names" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"m\",\"effort\":\"low\",\"compactAt\":0,\"tools\":[],\"permissionMode\":\"ask\",\"label\":null}}", .refusal = "spec.compactAt must be a positive number of tokens" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"m\",\"effort\":\"low\",\"compactAt\":1,\"tools\":[],\"permissionMode\":\"never\",\"label\":null}}", .refusal = "spec.permissionMode must be ask or bypass" },
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
            try std.testing.expect(start.configuration.workspace.state != .value and start.configuration.provider.state != .value and start.configuration.label.state != .value);
        }
    }
}
