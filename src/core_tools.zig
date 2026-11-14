//! The core's own tools (D24): their record text and their argument
//! checks. A call to one runs as a core command, never as an Action
//! process; who runs a tool is derived from its name (D46).

const std = @import("std");
const protocol = @import("protocol.zig");
const wire_request = @import("wire_request.zig");
const utf8_validation = @import("utf8_validation.zig");

pub const Preset = @import("preset_value.zig").Preset;
pub const max_presets = @import("preset_value.zig").max_presets;
pub const max_preset_name_bytes = @import("preset_value.zig").max_preset_name_bytes;
pub const validPresetName = @import("preset_value.zig").validPresetName;

pub const message_agent_max_text_bytes = @import("tool_record.zig").message_agent_max_text_bytes;
pub const message_agent_description = @import("tool_record.zig").message_agent_description;
pub const message_agent_schema = @import("tool_record.zig").message_agent_schema;
pub const find_tools_description = @import("tool_record.zig").find_tools_description;
pub const find_tools_schema = @import("tool_record.zig").find_tools_schema;

pub const find_tools_max_word_bytes = 64;
/// Eight words of 64 bytes fit with room for JSON escapes and spacing; a
/// larger payload is refused before it is read or parsed.
pub const find_tools_max_argument_bytes = 4096;
pub const find_tools_too_long = std.fmt.comptimePrint("words must fit arguments of at most {d} bytes", .{find_tools_max_argument_bytes});

pub const FindTools = @import("find_tools_words.zig").FindTools;

/// Checked when the core call runs, not when its model output settles.
pub fn checkFindTools(arena: std.mem.Allocator, bytes: []const u8, out: *FindTools) error{OutOfMemory}!StartAgentCheck {
    if (bytes.len > find_tools_max_argument_bytes) return refused(find_tools_too_long);
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refused("words must be the only field of one well-formed JSON object"),
    };
    if (root != .object or root.object.count() != 1) return refused("words must be the only field of one JSON object");
    const words = root.object.get("words") orelse return refused("words is required");
    if (words != .string) return refused("words must be a string");
    out.* = .{};
    var pieces = std.mem.splitScalar(u8, words.string, ' ');
    while (pieces.next()) |piece| {
        if (piece.len == 0) continue;
        if (piece.len > find_tools_max_word_bytes) return refused("words must contain words of at most 64 bytes each");
        if (out.count == out.words.len) return refused("words must contain one to eight space-separated words");
        // The shared streaming Matcher folds the query, not this parser.
        out.words[out.count] = piece;
        out.count += 1;
    }
    if (out.count == 0) return refused("words must contain one to eight space-separated words");
    return .accepted;
}

/// Read arguments are deliberately small; content is read in bounded windows.
pub const read_transcript_max_argument_bytes = 4096;

pub const read_transcript_description = @import("tool_record.zig").read_transcript_description;
pub const read_transcript_schema = @import("tool_record.zig").read_transcript_schema;

pub const TranscriptAddress = struct { position: u64, ordinal: ?u64 = null };
pub const ReadTranscriptCheck = StartAgentCheck;

pub const ReadTranscript = struct {
    id: ?protocol.Bounded(protocol.session_id_bytes) = null,
    kinds: protocol.ActivityPage.Kinds = .full,
    before: ?TranscriptAddress = null,
    limit: u8 = protocol.ActivityPage.items,
    full: ?TranscriptAddress = null,
    query: ?protocol.Bounded(256) = null,
    offset: u64 = 0,
};

pub fn transcriptAddress(text: []const u8, require_ordinal: bool) ?TranscriptAddress {
    var parts = std.mem.splitScalar(u8, text, '.');
    const position = addressNumber(parts.next().?) orelse return null;
    if (position == 0) return null;
    const ordinal = if (parts.next()) |part| addressNumber(part) orelse return null else null;
    if (parts.next() != null or (require_ordinal and ordinal == null)) return null;
    return .{ .position = position, .ordinal = ordinal };
}

fn addressNumber(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    for (text) |byte| if (byte < '0' or byte > '9') return null;
    const value = std.fmt.parseInt(u64, text, 10) catch return null;
    return if (value <= std.math.maxInt(i64)) value else null;
}

pub fn checkReadTranscript(arena: std.mem.Allocator, bytes: []const u8, out: *ReadTranscript) error{OutOfMemory}!ReadTranscriptCheck {
    if (bytes.len > read_transcript_max_argument_bytes) return refused("the arguments take more than 4096 bytes");
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateField => return refused("a field appears more than once"),
        else => return refused("the arguments are not one well-formed JSON object"),
    };
    const top = switch (root) {
        .object => |object| object,
        else => return refused("the arguments are not one JSON object"),
    };
    if (unknownField(top, &.{ "id", "kinds", "before", "limit", "full", "offset", "query" })) |name| return refusedField(arena, name, "is not a read_transcript field");
    out.* = .{};
    if (top.get("id")) |value| {
        var id: protocol.Bounded(protocol.session_id_bytes) = .{};
        if (value != .string) return refused("id must be a Session ID");
        id.set(value.string) catch return refused("id must be a Session ID");
        if (!protocol.validSessionId(id.slice())) return refused("id must be a Session ID");
        out.id = id;
    }
    if (top.get("query")) |value| {
        if (value != .string or value.string.len == 0 or value.string.len > 256 or !std.unicode.utf8ValidateSlice(value.string)) return refused("query must be 1 to 256 bytes of UTF-8");
        out.query = .{};
        out.query.?.set(value.string) catch unreachable;
    }
    if (top.get("kinds")) |value| {
        if (value != .array or value.array.items.len == 0) return refused("kinds must be a nonempty array of feed kind names");
        out.kinds = .empty;
        for (value.array.items) |item| {
            if (item != .string) return refused("kinds must contain feed kind names");
            const kind = std.meta.stringToEnum(protocol.ActivityItem.Kind, item.string) orelse return refused("kinds contains an unknown feed kind name");
            out.kinds.insert(kind);
        }
    }
    if (top.get("before")) |value| {
        if (value != .string) return refused("before must be an entry address P or P.O");
        out.before = transcriptAddress(value.string, false) orelse return refused("before must be an entry address P or P.O");
    }
    if (top.get("limit")) |value| {
        if (value != .integer or value.integer < 1 or value.integer > protocol.ActivityPage.items) return refused("limit must be 1 to 16");
        out.limit = @intCast(value.integer);
    }
    if (top.get("full")) |value| {
        if (value != .string) return refused("full must be an entry address P.O");
        out.full = transcriptAddress(value.string, true) orelse return refused("full must be an entry address P.O");
        inline for (.{ "kinds", "before", "limit", "query" }) |name| if (top.get(name) != null) return refused(name ++ " must be absent with full");
    }
    if (top.get("offset")) |value| {
        if (out.full == null) return refused("offset is only accepted with full");
        if (value != .integer or value.integer < 0) return refused("offset must be a nonnegative integer");
        out.offset = @intCast(value.integer);
    }
    return .accepted;
}

/// The most bytes a `start_agent` call's arguments take: its task, at most
/// `message_agent_max_text_bytes` once decoded and six times that escaped
/// (`\u0001` for each byte), and its spec.
pub const start_agent_max_argument_bytes = 6 * message_agent_max_text_bytes + 16 * 1024;

pub const start_agent_description = @import("tool_record.zig").start_agent_description;
pub const start_agent_schema = @import("tool_record.zig").start_agent_schema;

/// A `start_agent` call's checked arguments: the task, whether the agent
/// is attached, and its spec as a creating Configuration without the
/// Workspace and provider, which come from the calling Session (D122, D221).
pub const StartAgent = struct {
    task: []const u8,
    instructions: ?[]const u8 = null,
    output_schema: ?[]const u8 = null,
    attached: bool,
    configuration: wire_request.Configuration,
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
    // Bound nesting before allocating the arguments DOM.
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
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .duplicate_field_behavior = .@"error", .parse_numbers = false }) catch |err| switch (err) {
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
    const checked = try parseAgentSpecFor(arena, spec, &out.configuration, true);
    if (checked == .rejected) return checked;
    out.task = task;
    out.attached = attached;
    out.instructions = out.configuration.instructions.borrowedBytes();
    out.output_schema = out.configuration.output_schema.borrowedBytes();
    return .accepted;
}

/// Applies creation admission to the shared protocol parser for launch presets
/// and creation seeds. Content borrows `arena` through Store admission.
pub fn parseAgentSpec(arena: std.mem.Allocator, spec: std.json.ObjectMap, configuration: *wire_request.Configuration) error{OutOfMemory}!StartAgentCheck {
    return parseAgentSpecFor(arena, spec, configuration, false);
}

fn parseAgentSpecFor(arena: std.mem.Allocator, spec: std.json.ObjectMap, configuration: *wire_request.Configuration, comptime inherits_parent: bool) error{OutOfMemory}!StartAgentCheck {
    if (spec.contains("parent")) return refused("spec.parent: parent is only valid on Session creation");
    // D221 applies after preset resolution too: no preset can change these.
    if (inherits_parent) {
        if (spec.contains("workspace")) return refused("spec.workspace: an agent always works in your Workspace");
        if (spec.contains("provider")) return refused("spec.provider: an agent always uses your provider");
    }
    if (try protocol.parseAgentSpec(wire_request.Custody, arena, spec, configuration)) |reason|
        return .{ .rejected = reason };
    if (protocol.missingCreatingSetting(configuration, inherits_parent)) |name|
        return .{ .rejected = try std.fmt.allocPrint(arena, "spec.{s} is required", .{name}) };
    // These are semantic admission checks, not a second spec grammar. The
    // Store still owns tool set availability and parent permission/tool narrowing.
    if (configuration.provider.state == .value and std.meta.stringToEnum(protocol.Provider, configuration.provider.value.slice()) == null)
        return refused("spec.provider must be a provider name");
    if (configuration.workspace.state == .value and configuration.workspace.value.len == 0)
        return refused("spec.workspace must be a Workspace path");
    if (configuration.model.value.len == 0) return refused("spec.model must be a model name");
    if (configuration.reasoning_effort.state == .value and std.meta.stringToEnum(protocol.ReasoningEffort, configuration.reasoning_effort.value.slice()) == null)
        return refused("spec.effort must be null, none, low, medium, high, xhigh or max");
    const tokens = std.fmt.parseInt(u64, configuration.compaction_trigger.value.slice(), 10) catch return refused("spec.compactAt must be a positive number of tokens");
    if (tokens == 0) return refused("spec.compactAt must be a positive number of tokens");
    if (!configuration.permission_mode.value.eql("ask") and !configuration.permission_mode.value.eql("bypass"))
        return refused("spec.permissionMode must be ask or bypass");
    if (configuration.label.state == .value and !protocol.validLabel(configuration.label.value.slice()))
        return refused("spec.label must be one nonblank line of UTF-8");

    return .accepted;
}

fn refused(comptime text: []const u8) StartAgentCheck {
    return .{ .rejected = text };
}

/// A bounded diagnostic, never a selector: keep a complete UTF-8 prefix.
pub fn diagnosticName(name: []const u8) []const u8 {
    return utf8_validation.validPrefix(name[0..@min(name.len, max_preset_name_bytes)]);
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

pub const MessageAgentArguments = @import("message_agent_arguments.zig").MessageAgentArguments;
pub const MessageAgentProblem = @import("message_agent_arguments.zig").MessageAgentProblem;
pub const MessageAgentCheck = @import("message_agent_arguments.zig").MessageAgentCheck;
pub const checkMessageAgent = @import("message_agent_arguments.zig").checkMessageAgent;

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

    pub fn writeAll(self: *TestText, piece: []const u8) !void {
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
        pub fn writeAll(_: *@This(), _: []const u8) !void {}
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

test "a start_agent call's arguments carry a task and a whole spec without a provider or Workspace" {
    const spec = "\"spec\":{\"model\":\"gpt-6.1-sol\",\"effort\":\"low\",\"compactAt\":100000,\"tools\":[\"start_agent\",\"bash\"],\"permissionMode\":\"ask\",\"label\":null}";
    const Case = struct { arguments: []const u8, refusal: ?[]const u8 = null };
    for ([_]Case{
        .{ .arguments = "{\"task\":\"read\",\"attached\":true," ++ spec ++ "}" },
        .{ .arguments = "{\"task\":\"\",\"attached\":true," ++ spec ++ "}", .refusal = "task must be nonempty UTF-8 text, at most 65536 bytes" },
        .{ .arguments = "{\"attached\":true," ++ spec ++ "}", .refusal = "task is required" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":1," ++ spec ++ "}", .refusal = "attached must be true or false" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true}", .refusal = "spec is required" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"m\",\"effort\":\"low\",\"compactAt\":1,\"tools\":[\"edit.file\"],\"permissionMode\":\"ask\",\"label\":null}}", .refusal = "spec.tools must be a list of distinct tool names" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"m\",\"effort\":\"low\",\"compactAt\":1,\"tools\":[\"bash\",\"bash\"],\"permissionMode\":\"ask\",\"label\":null}}", .refusal = "spec.tools must be a list of distinct tool names" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"m\",\"effort\":\"low\",\"compactAt\":0,\"tools\":[],\"permissionMode\":\"ask\",\"label\":null}}", .refusal = "spec.compactAt must be a positive number of tokens" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"m\",\"effort\":\"low\",\"compactAt\":1,\"tools\":[],\"permissionMode\":\"never\",\"label\":null}}", .refusal = "spec.permissionMode must be ask or bypass" },
        // D221: a child inherits both, so a spec naming either is refused.
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"workspace\":\"/\"}}", .refusal = "spec.workspace: an agent always works in your Workspace" },
        .{ .arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"provider\":\"codex\"}}", .refusal = "spec.provider: an agent always uses your provider" },
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
        .{ .extra = ",\"instructions\":\"\",\"outputSchema\":{}" },
        .{ .extra = ",\"outputSchema\":\"[]\"", .refusal = "spec.outputSchema" },
        .{ .extra = ",\"outputSchema\":\"false\"", .refusal = "spec.outputSchema" },
        .{ .extra = ",\"outputSchema\":\"not JSON\"", .refusal = "spec.outputSchema" },
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
            try std.testing.expectEqualStrings(start.instructions.?, start.configuration.instructions.borrowedBytes().?);
            try std.testing.expectEqual(start.instructions.?.len, start.configuration.instructions.length);
            try std.testing.expectEqual(protocol.contentDigest(start.instructions.?), start.configuration.instructions.digest);
            if (start.output_schema) |schema| {
                try std.testing.expectEqual(.value, start.configuration.output_schema.state);
                try std.testing.expectEqualStrings(schema, start.configuration.output_schema.borrowedBytes().?);
                try std.testing.expectEqual(protocol.contentDigest(schema), start.configuration.output_schema.digest);
            } else try std.testing.expectEqual(.explicit_null, start.configuration.output_schema.state);
            if (start.instructions.?.len != 0) {
                try std.testing.expectEqualStrings("Be helpful", start.instructions.?);
                try std.testing.expectEqualStrings("{\"type\":\"object\"}", start.output_schema.?);
            } else if (start.output_schema) |schema| try std.testing.expectEqualStrings("{}", schema);
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

test "read_transcript arguments defaults filters addresses and every refusal" {
    const Case = struct { bytes: []const u8, refusal: ?[]const u8 = null };
    for ([_]Case{
        .{ .bytes = "{}" },
        .{ .bytes = "{\"id\":\"k7m2qx\",\"kinds\":[\"assistant\",\"user\",\"assistant\"],\"before\":\"42.0\",\"limit\":1}" },
        .{ .bytes = "{\"before\":\"42\",\"limit\":16}" },
        .{ .bytes = "{\"full\":\"42.0\",\"offset\":16384}" },
        .{ .bytes = "[]", .refusal = "the arguments are not one JSON object" },
        .{ .bytes = "{", .refusal = "the arguments are not one well-formed JSON object" },
        .{ .bytes = "{} {}", .refusal = "the arguments are not one well-formed JSON object" },
        .{ .bytes = "{\"id\":\"k7m2qx\",\"id\":\"k7m2qx\"}", .refusal = "a field appears more than once" },
        .{ .bytes = "{\"query\":\"\"}", .refusal = "query must be 1 to 256 bytes of UTF-8" },
        .{ .bytes = "{\"query\":7}", .refusal = "query must be 1 to 256 bytes of UTF-8" },
        .{ .bytes = "{\"query\":\"word\",\"full\":\"42.0\"}", .refusal = "query must be absent with full" },
        .{ .bytes = "{\"id\":7}", .refusal = "id must be a Session ID" },
        .{ .bytes = "{\"id\":\"TOOLONG\"}", .refusal = "id must be a Session ID" },
        .{ .bytes = "{\"id\":\"K7M2QX\"}", .refusal = "id must be a Session ID" },
        .{ .bytes = "{\"id\":\"\"}", .refusal = "id must be a Session ID" },
        .{ .bytes = "{\"kinds\":[]}", .refusal = "kinds must be a nonempty array of feed kind names" },
        .{ .bytes = "{\"kinds\":\"user\"}", .refusal = "kinds must be a nonempty array of feed kind names" },
        .{ .bytes = "{\"kinds\":[7]}", .refusal = "kinds must contain feed kind names" },
        .{ .bytes = "{\"kinds\":[\"\"]}", .refusal = "kinds contains an unknown feed kind name" },
        .{ .bytes = "{\"kinds\":[\"User\"]}", .refusal = "kinds contains an unknown feed kind name" },
        .{ .bytes = "{\"before\":7}", .refusal = "before must be an entry address P or P.O" },
        .{ .bytes = "{\"before\":\"0\"}", .refusal = "before must be an entry address P or P.O" },
        .{ .bytes = "{\"before\":\"1.2.3\"}", .refusal = "before must be an entry address P or P.O" },
        .{ .bytes = "{\"before\":\"1.\"}", .refusal = "before must be an entry address P or P.O" },
        .{ .bytes = "{\"before\":\"+1\"}", .refusal = "before must be an entry address P or P.O" },
        .{ .bytes = "{\"before\":\"9223372036854775808\"}", .refusal = "before must be an entry address P or P.O" },
        .{ .bytes = "{\"before\":\"1.9223372036854775808\"}", .refusal = "before must be an entry address P or P.O" },
        .{ .bytes = "{\"limit\":0}", .refusal = "limit must be 1 to 16" },
        .{ .bytes = "{\"limit\":17}", .refusal = "limit must be 1 to 16" },
        .{ .bytes = "{\"limit\":1.5}", .refusal = "limit must be 1 to 16" },
        .{ .bytes = "{\"limit\":\"2\"}", .refusal = "limit must be 1 to 16" },
        .{ .bytes = "{\"full\":7}", .refusal = "full must be an entry address P.O" },
        .{ .bytes = "{\"full\":\"42\"}", .refusal = "full must be an entry address P.O" },
        .{ .bytes = "{\"full\":\"0.0\"}", .refusal = "full must be an entry address P.O" },
        .{ .bytes = "{\"full\":\"1.0\",\"limit\":16}", .refusal = "limit must be absent with full" },
        .{ .bytes = "{\"full\":\"1.0\",\"before\":\"2\"}", .refusal = "before must be absent with full" },
        .{ .bytes = "{\"full\":\"1.0\",\"kinds\":[\"user\"]}", .refusal = "kinds must be absent with full" },
        .{ .bytes = "{\"offset\":0}", .refusal = "offset is only accepted with full" },
        .{ .bytes = "{\"full\":\"1.0\",\"offset\":-1}", .refusal = "offset must be a nonnegative integer" },
        .{ .bytes = "{\"full\":\"1.0\",\"offset\":0.5}", .refusal = "offset must be a nonnegative integer" },
        .{ .bytes = "{\"full\":\"1.0\",\"offset\":null}", .refusal = "offset must be a nonnegative integer" },
    }) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var read: ReadTranscript = .{};
        const check = try checkReadTranscript(arena.allocator(), case.bytes, &read);
        errdefer std.debug.print("arguments: {s}\n", .{case.bytes});
        if (case.refusal) |expected| {
            try std.testing.expect(check == .rejected);
            try std.testing.expectEqualStrings(expected, check.rejected);
        } else {
            try std.testing.expect(check == .accepted);
            if (std.mem.eql(u8, case.bytes, "{}")) {
                try std.testing.expect(read.id == null and read.before == null and read.full == null);
                try std.testing.expectEqual(@as(u8, 16), read.limit);
                try std.testing.expectEqual(@as(u64, 0), read.offset);
                try std.testing.expect(read.kinds.eql(.full));
            } else if (read.full != null) {
                try std.testing.expectEqual(@as(u64, 42), read.full.?.position);
                try std.testing.expectEqual(@as(?u64, 0), read.full.?.ordinal);
                try std.testing.expectEqual(@as(u64, 16384), read.offset);
            } else if (read.id) |id| {
                try std.testing.expectEqualStrings("k7m2qx", id.slice());
                try std.testing.expect(read.kinds.eql(.initMany(&.{ .assistant, .user })));
                try std.testing.expectEqual(@as(u8, 1), read.limit);
                try std.testing.expectEqual(@as(?u64, 0), read.before.?.ordinal);
            } else try std.testing.expectEqual(@as(?u64, null), read.before.?.ordinal);
        }
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var read: ReadTranscript = .{};
    const oversized = try arena.allocator().alloc(u8, read_transcript_max_argument_bytes + 1);
    @memset(oversized, ' ');
    const check = try checkReadTranscript(arena.allocator(), oversized, &read);
    try std.testing.expectEqualStrings("the arguments take more than 4096 bytes", check.rejected);
    // Wire kind tags are the single vocabulary, including kinds introduced later.
    for (std.enums.values(protocol.ActivityItem.Kind)) |kind| {
        const bytes = try std.fmt.allocPrint(arena.allocator(), "{{\"kinds\":[\"{s}\"]}}", .{@tagName(kind)});
        try std.testing.expect(try checkReadTranscript(arena.allocator(), bytes, &read) == .accepted);
        try std.testing.expect(read.kinds.eql(.initOne(kind)));
    }
}

test "read_transcript query accepts UTF-8 byte bounds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var read: ReadTranscript = .{};
    for ([_]usize{ 1, 256, 257 }) |length| {
        const query = try arena.alloc(u8, length);
        @memset(query, 'a');
        const args = try std.fmt.allocPrint(arena, "{{\"query\":\"{s}\"}}", .{query});
        const check = try checkReadTranscript(arena, args, &read);
        if (length <= 256) {
            try std.testing.expect(check == .accepted);
            try std.testing.expectEqualStrings(query, read.query.?.slice());
        } else try std.testing.expect(check == .rejected);
    }
    const multibyte = try arena.alloc(u8, 256);
    for (0..128) |index| @memcpy(multibyte[index * 2 ..][0..2], "é");
    const args = try std.fmt.allocPrint(arena, "{{\"query\":\"{s}\"}}", .{multibyte});
    try std.testing.expect(try checkReadTranscript(arena, args, &read) == .accepted);
    try std.testing.expectEqualStrings(multibyte, read.query.?.slice());
    try std.testing.expect(try checkReadTranscript(arena, "{\"query\":\"\xff\"}", &read) == .rejected);
}

test "find_tools checks words at execution time" {
    const utf8_word: [64]u8 = @bitCast(@as([32][2]u8, @splat("é".*)));
    const Case = struct { bytes: []const u8, count: ?usize = null };
    for ([_]Case{
        .{ .bytes = "{\"words\":\"one\"}", .count = 1 },
        .{ .bytes = "{\"words\":\"  OnE   TWO  \"}", .count = 2 },
        .{ .bytes = "{\"words\":\"1 2 3 4 5 6 7 8\"}", .count = 8 },
        .{ .bytes = "{\"words\":\"one\\ttwo\"}", .count = 1 },
        .{ .bytes = "{\"words\":\"" ++ @as([64]u8, @splat('a')) ++ "\"}", .count = 1 },
        .{ .bytes = "{\"words\":\"" ++ @as([65]u8, @splat('a')) ++ "\"}" },
        .{ .bytes = "{\"words\":\"" ++ utf8_word ++ "\"}", .count = 1 },
        .{ .bytes = "{\"words\":\"" ++ utf8_word ++ "é" ++ "\"}" },
        .{ .bytes = "{\"words\":\"" ++ @as([64]u8, @splat('a')) ++ " " ++ @as([64]u8, @splat('b')) ++ "\"}", .count = 2 },
        .{ .bytes = "{\"words\":\"\"}" },
        .{ .bytes = "{\"words\":\"   \"}" },
        .{ .bytes = "{\"words\":\"1 2 3 4 5 6 7 8 9\"}" },
        .{ .bytes = "{}" },
        .{ .bytes = "[]" },
        .{ .bytes = "{" },
        .{ .bytes = "{\"words\":7}" },
        .{ .bytes = "{\"words\":null}" },
        .{ .bytes = "{\"words\":[]}" },
        .{ .bytes = "{\"words\":\"one\",\"extra\":true}" },
        .{ .bytes = "{\"words\":\"one\",\"words\":\"two\"}" },
        .{ .bytes = "{\"words\":\"one\"} {}" },
        .{ .bytes = "{\"words\":\"one" ++ @as([find_tools_max_argument_bytes]u8, @splat(' ')) ++ "\"}" },
    }) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var arguments: FindTools = .{};
        const check = try checkFindTools(arena.allocator(), case.bytes, &arguments);
        if (case.count) |count| {
            try std.testing.expect(check == .accepted);
            try std.testing.expectEqual(count, arguments.count);
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), case.bytes, .{});
            var pieces = std.mem.tokenizeScalar(u8, parsed.object.get("words").?.string, ' ');
            for (arguments.words[0..count]) |word| try std.testing.expectEqualStrings(pieces.next().?, word);
            try std.testing.expect(pieces.next() == null);
        } else {
            try std.testing.expect(check == .rejected);
            try std.testing.expect(std.mem.indexOf(u8, check.rejected, "words") != null);
        }
    }
}

test "presets resolve start_agent overrides including explicit null before checks" {
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const spec = (try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"model":"model-a","effort":"low","compactAt":1000,"tools":["bash"],"permissionMode":"ask","instructions":"Preset text","outputSchema":{"type":"object"},"label":"Preset label"}
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

test "start_agent presets cannot supply provider or workspace even with overrides" {
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const start = try arena.create(StartAgent);
    const configuration = try arena.create(wire_request.Configuration);
    for ([_][]const u8{ "provider", "workspace" }) |field| {
        const spec = (try std.json.parseFromSliceLeaky(std.json.Value, arena,
            \\{"model":"model-a","effort":"low","compactAt":1000,"tools":[],"permissionMode":"ask"}
        , .{})).object;
        var seeded = spec;
        try seeded.put(arena, field, .{ .string = if (std.mem.eql(u8, field, "provider")) "openai" else "/" });
        // Configure creation may use these fields, but start_agent inherits
        // them from its caller regardless of the source of the spec.
        try std.testing.expect(try parseAgentSpec(arena, seeded, configuration) == .accepted);
        const presets = [_]Preset{.{ .name = "review", .spec = seeded }};
        const null_override = try std.fmt.allocPrint(arena, ",\"spec\":{{\"{s}\":null}}", .{field});
        for ([_][]const u8{ "", ",\"spec\":{\"tools\":[]}", null_override }) |overrides| {
            const arguments = try std.fmt.allocPrint(arena, "{{\"task\":\"read\",\"attached\":true,\"preset\":\"review\"{s}}}", .{overrides});
            const result = try checkStartAgentWithPresets(arena, arguments, &presets, start);
            try std.testing.expect(result == .rejected);
            const diagnostic = try std.fmt.allocPrint(arena, "spec.{s}:", .{field});
            try std.testing.expect(std.mem.startsWith(u8, result.rejected, diagnostic));
        }
    }
}

pub const skill_description = @import("tool_record.zig").skill_description;
pub const skill_schema = @import("tool_record.zig").skill_schema;

pub const skill_max_argument_bytes = 4096;

pub fn checkSkill(arena: std.mem.Allocator, bytes: []const u8, out: *protocol.SkillRequest) error{OutOfMemory}!StartAgentCheck {
    if (bytes.len > skill_max_argument_bytes) return refused("the arguments take more than 4096 bytes");
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refused("the arguments are not one well-formed JSON object"),
    };
    if (root != .object) return refused("the arguments are not one JSON object");
    if (unknownField(root.object, &.{ "operation", "name" })) |name| return refusedField(arena, name, "is not a skill field");
    const operation = root.object.get("operation") orelse return refused("operation is required");
    if (operation != .string) return refused("operation must be invoke or reload");
    out.* = .{ .operation = std.meta.stringToEnum(@FieldType(protocol.SkillRequest, "operation"), operation.string) orelse return refused("operation must be invoke or reload") };
    if (root.object.get("name")) |name| {
        if (name != .string or name.string.len == 0) return refused("name must be a nonempty skill name");
        out.name = .{};
        out.name.?.set(name.string) catch return refused("name must be at most 64 UTF-8 bytes");
    }
    if ((out.operation == .invoke) != (out.name != null)) return refused("invoke requires name; reload accepts no name");
    return .accepted;
}

test "skills model arguments separate invoke and reload without authority fields" {
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    const allocator = memory.allocator();
    var out: protocol.SkillRequest = .{};
    try std.testing.expect(try checkSkill(allocator, "{\"operation\":\"invoke\",\"name\":\"demo\"}", &out) == .accepted);
    try std.testing.expectEqual(@as(@FieldType(protocol.SkillRequest, "operation"), .invoke), out.operation);
    try std.testing.expectEqualStrings("demo", out.name.?.slice());
    try std.testing.expect(try checkSkill(allocator, "{\"operation\":\"reload\"}", &out) == .accepted);
    try std.testing.expect(out.name == null);
    for ([_][]const u8{
        "{}",                                             "{\"operation\":\"invoke\"}",                      "{\"operation\":\"invoke\",\"name\":\"\"}",
        "{\"operation\":\"reload\",\"name\":\"demo\"}",   "{\"operation\":\"reload\",\"tools\":[\"bash\"]}", "{\"operation\":\"reload\",\"operation\":\"reload\"}",
        "{\"operation\":\"activate\",\"name\":\"demo\"}",
    }) |invalid| try std.testing.expect(try checkSkill(allocator, invalid, &out) == .rejected);
}

// The exact same spec text crosses the model-tool and native request doors.
// Independent expected names include both fields absent from the old tool schema.
test "start_agent and configure parse the same plain agent spec into the same Configuration" {
    const spec =
        \\{"model":"custom","effort":null,"compactAt":1000,"tools":["web_search","start_agent"],"loadedTools":["web_search"],"permissionMode":"ask","outputReservation":123,"label":"one spec","instructions":"Follow this","outputSchema":{"type":"object","description":"caf\u00e9\/","state":"value","value":{},"bytes":"0","sha256":"not a reference"}}
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const start = try allocator.create(StartAgent);
    const arguments = try std.fmt.allocPrint(allocator, "{{\"task\":\"read\",\"attached\":true,\"spec\":{s}}}", .{spec});
    try std.testing.expect(try checkStartAgent(allocator, arguments, start) == .accepted);
    try std.testing.expectEqualStrings("web_search", start.configuration.loaded_tools.names.slice());
    try std.testing.expectEqualStrings("123", start.configuration.output_reservation.value.slice());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    var retained: ?@import("named_scratch.zig").Owner = null;
    const body = try std.fmt.allocPrint(allocator, "{{\"version\":\"{s}\",\"kind\":\"configure\",\"store\":\"s\",\"key\":\"k\",\"session\":\"\",\"configuration\":{s}}}", .{ protocol.wire_version, spec });
    const ingress = try allocator.create(wire_request.Ingress);
    ingress.init(allocator, .{ .io = std.testing.io, .content_length = body.len, .scratch_path = root[0..root_len], .request_number = 1, .retained_scratch = &retained, .expected_kind = .configure });
    defer ingress.deinit();
    try ingress.feed(body);
    const request = try ingress.finish();
    defer request.removeTemporaryContent(std.testing.io) catch unreachable;
    const configuration = &request.configure.configuration;
    inline for (@import("session_settings.zig").entries) |entry| {
        const name = entry.field;
        const a = &@field(start.configuration, name);
        const b = &@field(configuration, name);
        try std.testing.expectEqual(a.state, b.state);
        if (a.state == .value) switch (entry.kind) {
            .text, .choice, .decimal_policy => try std.testing.expectEqualStrings(a.value.slice(), b.value.slice()),
            .tools => {
                try std.testing.expectEqual(a.count, b.count);
                try std.testing.expectEqualStrings(a.names.slice(), b.names.slice());
            },
            .content => {
                try std.testing.expectEqual(a.length, b.length);
                try std.testing.expectEqualSlices(u8, &a.digest, &b.digest);
                try std.testing.expect(b.hasFile());
                try std.testing.expect(a.borrowedBytes() != null);
            },
        };
    }
}

test "start_agent spec schema covers every noninherited Session setting" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), start_agent_schema, .{});
    const properties = schema.object.get("properties").?.object.get("spec").?.object.get("properties").?.object;
    try std.testing.expect(!properties.contains("workspace") and !properties.contains("provider"));
    try std.testing.expect(properties.contains("loadedTools") and properties.contains("outputReservation"));
    inline for (@import("session_settings.zig").entries) |entry| {
        if (comptime !std.mem.eql(u8, entry.field, "workspace") and !std.mem.eql(u8, entry.field, "provider"))
            try std.testing.expect(properties.contains(entry.spec));
    }
    try std.testing.expectEqual(@import("session_settings.zig").entries.len - 2, properties.count());
}
