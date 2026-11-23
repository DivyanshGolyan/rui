const std = @import("std");
const protocol = @import("protocol.zig");
const conversation_read = @import("conversation_read.zig");
const message_observation = @import("message_observation.zig");
const message_admission = @import("message_admission.zig");
const configuration_admission = @import("configuration_admission.zig");
const outcome_code = @import("outcome_code.zig");
const tool_presentation = @import("tool_presentation.zig");
const session_id = @import("session_id.zig");
const Bounded = @import("bounded.zig").Bounded;
const cli_value = @import("cli_value.zig");
const content_value = @import("content_value.zig");
const mutation_answer = @import("mutation_answer.zig");
const session_work = @import("session_work.zig");
const change_ring = @import("change_ring.zig");
const AttemptBinding = @import("attempt.zig").AttemptBinding;

pub const ContentReference = @import("input_parts.zig").ContentReference;

pub const CreationConfiguration = @import("creation_receipt.zig").Configuration;

pub const AcceptedConfiguration = struct {
    replayed: bool,
    revision: u64 = 0,
    created: bool = false,
    /// Borrowed from caller-supplied receipt storage; valid for its lifetime.
    configuration: ?*const CreationConfiguration = null,
    skills: ?mutation_answer.SkillsReloadStatus = null,
    session: Bounded(session_id.max_reference_bytes) = .{},
};

pub const RejectedConfiguration = struct {
    replayed: bool,
    code: configuration_admission.Rejection,
    message: ?@import("tool_record.zig").HostToolSet.MissingTool = null,
    /// Set exactly when `code` is `missing_settings`.
    missing: ?@import("required_settings.zig").Missing = null,
};

pub const ConfigureReply = union(enum) {
    accepted: AcceptedConfiguration,
    rejected: RejectedConfiguration,
    conflict,
    infrastructure_failure,
};

pub const AcceptedMessage = struct {
    replayed: bool,
    admission_id: u64,
    /// Borrowed from caller-supplied receipt storage; valid for its lifetime.
    configuration: ?*const CreationConfiguration = null,
    content: content_value.Value,
    session: Bounded(session_id.max_reference_bytes),
};

pub const RejectedMessage = struct {
    form: @import("input_parts.zig").Form = .bytes,
    replayed: bool,
    code: message_admission.Rejection,
    message: ?@import("tool_record.zig").HostToolSet.MissingTool = null,
    /// Set exactly when `code` is `missing_settings`.
    missing: ?@import("required_settings.zig").Missing = null,
    content: ContentReference,
};

pub const MessageReply = union(enum) {
    accepted: AcceptedMessage,
    rejected: RejectedMessage,
    conflict,
    infrastructure_failure,
};

pub const CommandObservation = struct {
    status: message_observation.CommandObservationStatus,
    target: Bounded(session_id.max_reference_bytes) = .{},
    code: Bounded(outcome_code.max_bytes) = .{},
    kind: union(cli_value.CommandKind) {
        configure: struct { revision: u64 = 0, created: bool = false },
        message: ?MessageObservation,
        session_stop: ?SessionStopObservation,
        session_archive: ?mutation_answer.SessionArchiveObservation,
        model_interruption: ModelInterruptionTarget,
        permission_decision: struct { action_id: u64, decision: mutation_answer.PermissionDecision },
        session_pin: ?mutation_answer.SessionPinObservation,
        action_background: @import("action_control.zig").Observation,
        action_stop: @import("action_control.zig").StopObservation,
    } = .{ .configure = .{} },

    pub fn requestState(self: *const CommandObservation) ?message_observation.MessageRequestState {
        if (self.kind != .message or self.status == .absent) return null;
        if (self.status == .rejected) return .rejected;
        const message = if (self.kind.message) |*value| value else return null;
        const queue = if (message.queue) |*value| value else return null;
        switch (queue.state) {
            .completed => return .completed,
            .failed => return .failed,
            .cancelled, .excluded => return .cancelled,
            else => {},
        }
        if (message.work) |*work| {
            if (work.state.progress() == .waiting_for_permission) return .waiting_for_permission;
        }
        return if (queue.state == .processing) .processing else .queued;
    }
};

pub const SessionStopSelection = struct {
    selected_turn_id: ?u64 = null,
    admission_cutoff: u64,
};

pub const SessionStopObservation = struct {
    selection: SessionStopSelection,
    completion: mutation_answer.SessionStopCompletion,
};

pub const ModelInterruptionTarget = struct {
    session: Bounded(session_id.max_reference_bytes),
    turn_id: u64,
    operation_id: u64,
};

pub const SessionStopReply = union(enum) {
    accepted: struct {
        replayed: bool,
        selection: SessionStopSelection,
        completion: mutation_answer.SessionStopCompletion,
        interrupted_operation_id: ?u64 = null,
    },
    rejected: struct { replayed: bool, code: mutation_answer.SessionStopRejection },
    conflict,
    infrastructure_failure,
};

pub const ModelInterruptionReply = union(enum) {
    accepted: struct { replayed: bool },
    rejected: struct { replayed: bool, code: mutation_answer.ModelInterruptionRejection },
    conflict,
    infrastructure_failure,
};

pub const SessionArchiveReply = union(enum) {
    accepted: struct {
        replayed: bool,
        archived: bool,
        completion: mutation_answer.SessionStopCompletion,
        interrupted_operation_id: ?u64 = null,
    },
    rejected: struct { replayed: bool, code: mutation_answer.SessionArchiveRejection },
    conflict,
    infrastructure_failure,
};

pub const SessionPinReply = union(enum) {
    accepted: struct { replayed: bool, pinned: bool },
    rejected: struct { replayed: bool, code: mutation_answer.SessionPinRejection },
    conflict,
    infrastructure_failure,
};

pub const PermissionDecisionReply = union(enum) {
    accepted: struct { replayed: bool },
    rejected: struct { replayed: bool, code: mutation_answer.PermissionDecisionRejection },
    conflict,
    infrastructure_failure,
};

pub const PublicConversationItem = struct {
    position: u64,
    ordinal: u64,
    kind: conversation_read.ConversationItemKind,
    content: content_value.Value,
    presentation: ?tool_presentation.ToolPresentation = null,
    admitted_at: ?u64 = null,
    sender: ?protocol.NamedPeer = null,
    source_action: ?u64 = null,
};

pub const PublicConversationPage = struct {
    pub const capacity = conversation_read.public_conversation_page_items;
    end: u64,
    items: [capacity]PublicConversationItem = undefined,
    count: usize = 0,
    more: bool = false,
};

pub const MessageObservation = struct {
    content: content_value.Value,
    queue: ?AcceptedMessageQueue = null,
    admitted_at: u64 = 0,
    work: ?session_work.Work = null,
    recovery: Recovery = .{},
};

pub const Recovery = struct {
    pub const capacity = message_observation.message_recovery_limit;
    calls: [capacity]UnknownOutcome = undefined,
    count: u8 = 0,
    more: bool = false,
};

pub const UnknownOutcome = message_observation.MessageUnknownOutcome;

pub const AcceptedMessageQueue = struct {
    admission_id: u64,
    state: State,

    pub const State = union(enum) {
        queued,
        excluded: struct { code: Bounded(outcome_code.max_bytes) },
        processing: AttemptBinding,
        completed: struct {
            binding: AttemptBinding,
            answer: ContentReference,
        },
        cancelled: struct {
            binding: AttemptBinding,
            code: Bounded(outcome_code.max_bytes),
        },
        failed: struct {
            binding: AttemptBinding,
            code: Bounded(outcome_code.max_bytes),
        },
    };
};

pub const Observed = union(enum) {
    not_modified: change_ring.SessionToken,
    full: struct {
        token: ?change_ring.SessionToken,
        observation: CommandObservation = undefined,
    },
};

const wire_field = @import("wire_field.zig");

/// Decodes a protocol shape into closed structs whose strings own their bytes.
/// The universe supplies field ownership at each object path; unrelated unknown
/// fields retain the command reply readers' forward-compatible skip behavior.
pub fn Decoder(comptime shape: anytype, comptime universe: anytype) type {
    return DecoderWithJson(shape, universe, struct {
        pub fn Type(comptime T: type) type {
            return T;
        }
    });
}

/// JsonTypes.Type(T) binds protocol writer-only JSON holes to existing readers.
/// Decimal and hexadecimal fields retain wire text for consumer validation.
pub fn DecoderWithJson(comptime shape: anytype, comptime universe: anytype, comptime JsonTypes: type) type {
    return DecoderWithPolicy(shape, universe, JsonTypes, struct {});
}

/// Policy preserves consumer-specific legacy behavior without duplicating shapes.
/// Optional hooks: ignored(path), Override(path), deferMissing(path),
/// foreign(path, name), and mergeDeferred(current, next).
pub fn DecoderWithPolicy(comptime shape: anytype, comptime universe: anytype, comptime JsonTypes: type, comptime Policy: type) type {
    const tree = comptime shapeTree(shape);
    return struct {
        pub const Value = NodeType(tree, 0, JsonTypes, Policy);

        pub const Partial = struct {
            value: Value,
            missing_fields: bool,
            deferred_error: ?anyerror,
            present: [tree.count]bool,

            /// Missing fields remain undefined. Check a path before reading it.
            pub fn has(self: *const @This(), comptime path: []const u8) bool {
                inline for (tree.nodes[0..tree.count], 0..) |node, index| {
                    if (comptime std.mem.eql(u8, node.path, path)) return self.present[index];
                }
                return false;
            }
        };

        pub fn parse(allocator: std.mem.Allocator, body: []const u8) !Value {
            const parsed = try parsePartial(allocator, body);
            if (parsed.missing_fields) return error.MissingField;
            if (parsed.deferred_error) |err| return err;
            return parsed.value;
        }

        /// Uses the same parser while leaving missing-member decisions to the
        /// consumer, so binding diagnostics can precede missing payload facts.
        pub fn parsePartial(allocator: std.mem.Allocator, body: []const u8) !Partial {
            var result: Partial = undefined;
            result.present = @splat(false);
            var state: ParseState = .{ .allow_missing = true, .present = &result.present };
            result.value = try parseBody(allocator, body, &state);
            result.missing_fields = state.missing_fields;
            result.deferred_error = state.deferred_error;
            return result;
        }

        fn parseBody(allocator: std.mem.Allocator, body: []const u8, state: *ParseState) !Value {
            var scanner = std.json.Scanner.initCompleteInput(allocator, body);
            defer scanner.deinit();
            try scanner.ensureTotalStackCapacity(body.len);
            const value = try parseNode(tree, 0, universe, JsonTypes, Policy, state, allocator, &scanner, .{
                .ignore_unknown_fields = true,
                .max_value_len = body.len,
                .allocate = .alloc_if_needed,
            });
            if (try scanner.next() != .end_of_document) return error.InvalidResponse;
            return value;
        }
    };
}

const ParseState = struct {
    deferred_error: ?anyerror = null,
    allow_missing: bool = false,
    missing_fields: bool = false,
    present: ?[]bool = null,
};

const ShapeNode = struct {
    kind: enum { object, string, boolean, null_value, hole },
    name: []const u8,
    path: []const u8,
    text: []const u8 = "",
    hole: protocol.Hole = .boolean,
    first_child: ?usize = null,
    next_sibling: ?usize = null,
};

fn shapeLiteral(comptime part: anytype) bool {
    return switch (@typeInfo(@TypeOf(part))) {
        .pointer => true,
        else => false,
    };
}

fn shapeText(comptime shape: anytype) []const u8 {
    comptime var text: []const u8 = "";
    inline for (shape) |part| {
        text = text ++ if (!shapeLiteral(part)) "\x00" else part;
    }
    return text;
}

fn shapeHoles(comptime shape: anytype) []const protocol.Hole {
    comptime var holes: []const protocol.Hole = &.{};
    inline for (shape) |part| {
        if (!shapeLiteral(part)) holes = holes ++ [_]protocol.Hole{part};
    }
    return holes;
}

fn ShapeTree(comptime capacity: usize) type {
    return struct {
        nodes: [capacity]ShapeNode = undefined,
        count: usize = 0,
        cursor: usize = 0,
        hole_index: usize = 0,

        fn add(self: *@This(), node: ShapeNode) usize {
            const index = self.count;
            self.nodes[index] = node;
            self.count += 1;
            return index;
        }

        fn expect(self: *@This(), comptime text: []const u8, byte: u8) void {
            if (self.cursor >= text.len or text[self.cursor] != byte)
                @compileError("invalid command reply shape");
            self.cursor += 1;
        }

        fn string(self: *@This(), comptime text: []const u8) []const u8 {
            self.expect(text, '"');
            const start = self.cursor;
            while (self.cursor < text.len and text[self.cursor] != '"') : (self.cursor += 1) {
                if (text[self.cursor] == '\\') @compileError("escaped command shape literal needs decoding");
            }
            const literal = text[start..self.cursor];
            self.expect(text, '"');
            return literal;
        }

        fn value(self: *@This(), comptime text: []const u8, comptime holes: []const protocol.Hole, name: []const u8, path: []const u8) usize {
            const index = self.add(.{ .kind = .object, .name = name, .path = path });
            switch (text[self.cursor]) {
                '{' => {
                    self.cursor += 1;
                    var previous: ?usize = null;
                    while (text[self.cursor] != '}') {
                        if (previous != null) self.expect(text, ',');
                        const child_name = self.string(text);
                        self.expect(text, ':');
                        const child_path = path ++ "." ++ child_name;
                        const child = self.value(text, holes, child_name, child_path);
                        if (previous) |p| self.nodes[p].next_sibling = child else self.nodes[index].first_child = child;
                        previous = child;
                    }
                    self.cursor += 1;
                },
                '"' => {
                    if (text[self.cursor + 1] == 0) {
                        self.cursor += 2;
                        self.nodes[index].kind = .hole;
                        self.nodes[index].hole = holes[self.hole_index];
                        self.hole_index += 1;
                        self.expect(text, '"');
                    } else {
                        self.nodes[index].kind = .string;
                        self.nodes[index].text = self.string(text);
                    }
                },
                0 => {
                    self.cursor += 1;
                    self.nodes[index].kind = .hole;
                    self.nodes[index].hole = holes[self.hole_index];
                    self.hole_index += 1;
                },
                't', 'f' => {
                    self.nodes[index].kind = .boolean;
                    const literal = if (text[self.cursor] == 't') "true" else "false";
                    self.nodes[index].text = literal;
                    for (literal) |byte| self.expect(text, byte);
                },
                'n' => {
                    self.nodes[index].kind = .null_value;
                    for ("null") |byte| self.expect(text, byte);
                },
                else => @compileError("unsupported command reply shape value"),
            }
            return index;
        }
    };
}

fn shapeNodeCapacity(comptime text: []const u8) usize {
    @setEvalBranchQuota(100_000);
    // There is one root, and each child consumes its own member colon.
    // Colons inside strings can only increase this bound.
    return 1 + std.mem.countScalar(u8, text, ':');
}

fn shapeTree(comptime shape: anytype) ShapeTree(shapeNodeCapacity(shapeText(shape))) {
    @setEvalBranchQuota(100_000);
    const text = shapeText(shape);
    var tree: ShapeTree(shapeNodeCapacity(text)) = .{};
    _ = tree.value(text, shapeHoles(shape), "", "");
    if (tree.cursor != text.len) @compileError("trailing command reply shape data");
    return tree;
}

fn tagLimit(comptime T: type) usize {
    comptime var limit: usize = 0;
    for (@typeInfo(T).@"enum".field_names) |name| limit = @max(limit, name.len);
    return limit;
}

fn HoleType(comptime hole: protocol.Hole, comptime name: []const u8, comptime JsonTypes: type) type {
    return switch (hole) {
        .boolean => bool,
        .decimal => wire_field.JsonString(20),
        .optional_id => ?wire_field.JsonString(20),
        .tag => |T| wire_field.JsonString(if (std.mem.eql(u8, name, "code")) protocol.max_code_bytes else tagLimit(T)),
        .optional_tag => |T| ?wire_field.JsonString(tagLimit(T)),
        .tag_set => |T| wire_field.JsonArray(wire_field.JsonString(tagLimit(T)), @typeInfo(T).@"enum".field_names.len),
        .string, .text => |limit| wire_field.JsonString(limit),
        .optional_string => |limit| ?wire_field.JsonString(limit),
        .hex => |bytes| wire_field.JsonString(2 * bytes),
        .json => |T| JsonTypes.Type(T),
        .optional_json => |T| ?JsonTypes.Type(T),
    };
}

fn children(comptime tree: anytype, comptime index: usize) []const usize {
    comptime var values: []const usize = &.{};
    comptime var next = tree.nodes[index].first_child;
    while (next) |child| {
        values = values ++ [_]usize{child};
        next = tree.nodes[child].next_sibling;
    }
    return values;
}

fn ignored(comptime Policy: type, comptime path: []const u8) bool {
    return @hasDecl(Policy, "ignored") and Policy.ignored(path);
}

fn deferMissing(comptime Policy: type, comptime path: []const u8) bool {
    return if (@hasDecl(Policy, "deferMissing")) Policy.deferMissing(path) else true;
}

fn nodeOverride(comptime Policy: type, comptime path: []const u8) ?type {
    return if (@hasDecl(Policy, "Override")) Policy.Override(path) else null;
}

fn NodeType(comptime tree: anytype, comptime index: usize, comptime JsonTypes: type, comptime Policy: type) type {
    const node = tree.nodes[index];
    if (ignored(Policy, node.path)) return ?void;
    if (nodeOverride(Policy, node.path)) |T| return T;
    return switch (node.kind) {
        .string => wire_field.JsonString(node.text.len),
        .boolean => bool,
        .null_value => ?void,
        .hole => HoleType(node.hole, node.name, JsonTypes),
        .object => blk: {
            const fields = children(tree, index);
            var names: [fields.len][]const u8 = undefined;
            var types: [fields.len]type = undefined;
            for (fields, 0..) |child, i| {
                names[i] = tree.nodes[child].name;
                types[i] = NodeType(tree, child, JsonTypes, Policy);
            }
            break :blk @Struct(.auto, null, &names, &types, &@splat(.{}));
        },
    };
}

fn knownNames(comptime universe: anytype, comptime path: []const u8) []const []const u8 {
    @setEvalBranchQuota(1_000_000);
    comptime var names: []const []const u8 = &.{};
    inline for (universe) |shape| {
        const tree = comptime shapeTree(shape);
        for (tree.nodes[0..tree.count], 0..) |node, index| {
            if (node.kind != .object or !std.mem.eql(u8, node.path, path)) continue;
            for (children(tree, index)) |child| {
                const name = tree.nodes[child].name;
                var found = false;
                for (names) |known| {
                    if (std.mem.eql(u8, known, name)) found = true;
                }
                if (!found) names = names ++ [_][]const u8{name};
            }
        }
    }
    return names;
}

fn recordDeferred(comptime Policy: type, state: *ParseState, next: anyerror) void {
    state.deferred_error = if (@hasDecl(Policy, "mergeDeferred"))
        Policy.mergeDeferred(state.deferred_error, next)
    else
        state.deferred_error orelse next;
}

fn parseForeign(comptime universe: anytype, comptime path: []const u8, comptime JsonTypes: type, comptime Policy: type, allocator: std.mem.Allocator, source: *std.json.Scanner, options: std.json.ParseOptions) anyerror!void {
    inline for (universe) |shape| {
        const tree = comptime shapeTree(shape);
        inline for (tree.nodes[0..tree.count], 0..) |node, index| {
            if (comptime std.mem.eql(u8, node.path, path)) {
                // Foreign syntax follows the same missing-field policy, using
                // its own tree without selected-shape presence indices.
                var state: ParseState = .{ .allow_missing = true };
                _ = try parseNode(tree, index, universe, JsonTypes, Policy, &state, allocator, source, options);
                if (state.deferred_error) |err| return err;
                return;
            }
        }
    }
    return error.UnknownField;
}

fn parseNode(comptime tree: anytype, comptime index: usize, comptime universe: anytype, comptime JsonTypes: type, comptime Policy: type, state: *ParseState, allocator: std.mem.Allocator, source: *std.json.Scanner, options: std.json.ParseOptions) anyerror!NodeType(tree, index, JsonTypes, Policy) {
    const node = tree.nodes[index];
    const T = NodeType(tree, index, JsonTypes, Policy);
    if (state.present) |present| present[index] = true;
    if (comptime ignored(Policy, node.path)) {
        try source.skipValue();
        return null;
    }
    if (comptime nodeOverride(Policy, node.path) != null)
        return std.json.innerParse(T, allocator, source, options);
    if (comptime node.kind == .null_value) {
        if (try source.next() != .null) return error.UnexpectedToken;
        return null;
    }
    if (comptime node.kind != .object) {
        const value = try std.json.innerParse(T, allocator, source, options);
        switch (comptime node.kind) {
            .string => if (!value.eql(node.text)) return error.InvalidResponse,
            .boolean => if (value != std.mem.eql(u8, node.text, "true")) return error.InvalidResponse,
            .hole => if (comptime node.hole == .tag and std.mem.eql(u8, node.name, "code")) {
                if (value.slice().len == 0) return error.InvalidResponse;
            },
            else => {},
        }
        return value;
    }
    if (try source.next() != .object_begin) return error.UnexpectedToken;
    const fields = comptime children(tree, index);
    const foreign_names = comptime blk: {
        var names: []const []const u8 = &.{};
        for (knownNames(universe, node.path)) |name| {
            if (!@hasField(T, name)) names = names ++ [_][]const u8{name};
        }
        break :blk names;
    };
    var seen: [fields.len]bool = @splat(false);
    var seen_foreign: [foreign_names.len]bool = @splat(false);
    var value: T = undefined;
    while (true) {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer if (token == .allocated_string) allocator.free(token.allocated_string);
        const name = switch (token) {
            .object_end => break,
            .string, .allocated_string => |text| text,
            else => return error.UnexpectedToken,
        };
        inline for (fields, 0..) |child, i| {
            if (std.mem.eql(u8, name, tree.nodes[child].name)) {
                if (seen[i] and !ignored(Policy, tree.nodes[child].path)) return error.DuplicateField;
                const field_name = comptime tree.nodes[child].name;
                @field(value, field_name) = try parseNode(tree, child, universe, JsonTypes, Policy, state, allocator, source, options);
                seen[i] = true;
                break;
            }
        } else {
            var consumed = false;
            inline for (foreign_names, 0..) |field, i| {
                if (std.mem.eql(u8, name, field)) {
                    if (comptime !ignored(Policy, node.path ++ "." ++ field)) {
                        if (seen_foreign[i]) return error.DuplicateField;
                        seen_foreign[i] = true;
                        if (comptime @hasDecl(Policy, "foreign")) {
                            Policy.foreign(node.path, name) catch |err| {
                                // A consumer may distinguish a valid foreign binding
                                // from invalid syntax. Its type still comes from the
                                // universe, rather than a second binding declaration.
                                if (err == error.UnknownField or err == error.InvalidResponse) return err;
                                try parseForeign(universe, node.path ++ "." ++ field, JsonTypes, Policy, allocator, source, options);
                                recordDeferred(Policy, state, err);
                                consumed = true;
                            };
                        } else return error.UnknownField;
                    }
                    break;
                }
            }
            if (!consumed) try source.skipValue();
        }
    }
    inline for (fields, 0..) |child, i| {
        const field_name = comptime tree.nodes[child].name;
        if (!seen[i]) {
            if (comptime ignored(Policy, tree.nodes[child].path)) {
                @field(value, field_name) = null;
            } else if (state.allow_missing and deferMissing(Policy, tree.nodes[child].path)) {
                state.missing_fields = true;
            } else return error.MissingField;
        }
    }
    return value;
}

test "shape decoder owns strings, validates constants, and skips unknown nested values" {
    const shape = .{ "{\"type\":\"example\",\"answer\":{\"status\":\"accepted\",\"id\":\"", protocol.Hole.decimal, "\",\"ok\":", protocol.Hole.boolean, ",\"name\":", protocol.Hole{ .optional_string = 8 }, "}}" };
    const D = Decoder(shape, .{shape});
    const value = try D.parse(std.testing.allocator, "{\"answer\":{\"id\":\"7\",\"name\":\"a\\u00b5\",\"extra\":{\"n\":[1,null,{}]},\"ok\":true,\"status\":\"accepted\"},\"type\":\"ex\\u0061mple\"}");
    try std.testing.expect(value.type.eql("example"));
    try std.testing.expect(value.answer.id.eql("7"));
    try std.testing.expect(value.answer.ok);
    try std.testing.expect(value.answer.name.?.eql("aµ"));
    for ([_][]const u8{
        "{\"type\":\"wrong\",\"answer\":{\"status\":\"accepted\",\"id\":\"7\",\"ok\":true,\"name\":null}}",
        "{\"type\":\"example\",\"answer\":{\"status\":\"accepted\",\"id\":\"7\",\"ok\":true}}",
        "{\"type\":\"example\",\"answer\":{\"status\":\"accepted\",\"id\":\"7\",\"ok\":true,\"name\":null,\"o\\u006b\":false}}",
        "{\"type\":\"example\",\"answer\":{\"status\":\"accepted\",\"id\":\"7\",\"ok\":true,\"name\":null}} {}",
    }) |body| try std.testing.expect(std.meta.isError(D.parse(std.testing.allocator, body)));
}

test "shape decoder refuses foreign fields by object path and preserves rejection codes" {
    const accepted = .{"{\"answer\":{\"status\":\"accepted\",\"created\":false},\"execution\":{\"status\":\"queued\"}}"};
    const rejected = .{ "{\"answer\":{\"status\":\"rejected\",\"code\":\"", protocol.Hole{ .tag = enum { known } }, "\"},\"completion\":{\"status\":\"unavailable\"}}" };
    const universe = .{ accepted, rejected };
    const A = Decoder(accepted, universe);
    const R = Decoder(rejected, universe);
    const value = try R.parse(std.testing.allocator, "{\"answer\":{\"status\":\"rejected\",\"code\":\"future_rejection\"},\"completion\":{\"status\":\"unavailable\"}}");
    try std.testing.expect(value.answer.code.eql("future_rejection"));
    for ([_][]const u8{
        "{\"answer\":{\"status\":\"accepted\",\"created\":false,\"code\":\"foreign\"},\"execution\":{\"status\":\"queued\"}}",
        "{\"answer\":{\"status\":\"accepted\",\"created\":false},\"execution\":{\"status\":\"queued\"},\"completion\":{}}",
        "{\"answer\":{\"status\":\"accepted\",\"created\":true},\"execution\":{\"status\":\"queued\"}}",
    }) |body| try std.testing.expect(std.meta.isError(A.parse(std.testing.allocator, body)));
    try std.testing.expectError(error.InvalidResponse, R.parse(std.testing.allocator, "{\"answer\":{\"status\":\"rejected\",\"code\":\"\"},\"completion\":{\"status\":\"unavailable\"}}"));
    _ = try A.parse(std.testing.allocator, "{\"answer\":{\"status\":\"accepted\",\"created\":false,\"extension\":{\"completion\":null}},\"execution\":{\"status\":\"queued\",\"created\":\"unrelated_path\"}}");
}

test "shape decoder reads the protocol configure reply shape" {
    const D = Decoder(protocol.configuration_reply.accepted, .{
        protocol.configuration_reply.accepted,
        protocol.configuration_reply.accepted_skills,
        protocol.configuration_reply.rejected,
        protocol.configuration_reply.conflict,
    });
    const body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"configuration_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"revision\":\"7\",\"created\":true},\"execution\":{\"status\":\"unavailable\",\"reason\":\"direct_reply_does_not_wait_for_model_processing\"}}";
    const value = try D.parse(std.testing.allocator, body);
    try std.testing.expect(value.answer.session.eql("k7m2qx"));
    try std.testing.expect(value.answer.revision.eql("7"));
    try std.testing.expect(value.answer.created and !value.answer.replayed);
}

test "shape decoder policy preserves ignored fields and delegates legacy objects" {
    const shape = .{ "{\"answer\":{\"status\":\"rejected\",\"message\":", protocol.Hole{ .optional_string = 8 }, "},\"execution\":{\"status\":\"queued\"}}" };
    const foreign_shape = .{"{\"answer\":{\"target\":{\"session\":\"foreign\"}}}"};
    const JsonTypes = struct {
        pub fn Type(comptime T: type) type {
            return T;
        }
    };
    const Policy = struct {
        pub fn ignored(comptime path: []const u8) bool {
            return std.mem.eql(u8, path, ".answer.message");
        }
        pub fn Override(comptime path: []const u8) ?type {
            if (std.mem.eql(u8, path, ".execution")) return struct {
                status: wire_field.JsonString(16),
                reason: wire_field.OmittableJson(wire_field.JsonString(64)) = .{},
            };
            return null;
        }
        pub fn foreign(comptime path: []const u8, name: []const u8) !void {
            if (std.mem.eql(u8, path, ".answer") and std.mem.eql(u8, name, "target")) return error.RequestBindingMismatch;
            return error.UnknownField;
        }
    };
    const D = DecoderWithPolicy(shape, .{ shape, foreign_shape }, JsonTypes, Policy);
    const missing = try D.parse(std.testing.allocator, "{\"answer\":{\"status\":\"rejected\"},\"execution\":{\"status\":\"queued\"}}");
    try std.testing.expect(missing.answer.message == null);
    const present = try D.parse(std.testing.allocator, "{\"answer\":{\"status\":\"rejected\",\"message\":[{},7]},\"execution\":{\"status\":\"queued\",\"reason\":\"legacy\"}}");
    try std.testing.expect(present.execution.reason.value.?.eql("legacy"));
    _ = try D.parse(std.testing.allocator, "{\"answer\":{\"status\":\"rejected\",\"message\":null,\"message\":7},\"execution\":{\"status\":\"queued\"}}");
    try std.testing.expect(std.meta.isError(D.parse(std.testing.allocator, "{\"answer\":{\"status\":\"rejected\"},\"execution\":{\"status\":\"queued\",\"reason\":null}}")));
    try std.testing.expectError(error.RequestBindingMismatch, D.parse(std.testing.allocator, "{\"answer\":{\"status\":\"rejected\",\"target\":{\"session\":\"foreign\"}},\"execution\":{\"status\":\"queued\"}}"));
    try std.testing.expectError(error.UnexpectedToken, D.parse(std.testing.allocator, "{\"answer\":{\"status\":\"rejected\",\"target\":null},\"execution\":{\"status\":\"queued\"}}"));
    try std.testing.expectError(error.MissingField, D.parse(std.testing.allocator, "{\"answer\":{\"target\":{\"session\":\"foreign\"}},\"execution\":{\"status\":\"queued\"}}"));
    try std.testing.expectError(error.InvalidResponse, D.parse(std.testing.allocator, "{\"answer\":{\"target\":{\"session\":\"foreign\"},\"status\":\"accepted\"},\"execution\":{\"status\":\"queued\"}}"));
    try std.testing.expectError(error.SyntaxError, D.parse(std.testing.allocator, "{\"answer\":{\"target\":{\"session\":\"foreign\"},\"status\":\"rejected\"},\"execution\":{\"status\":\"queued\"}} {}"));
    try std.testing.expectError(error.DuplicateField, D.parse(std.testing.allocator, "{\"answer\":{\"target\":{\"session\":\"foreign\"},\"target\":{\"session\":\"foreign\"},\"status\":\"rejected\"},\"execution\":{\"status\":\"queued\"}}"));
    const partial = try D.parsePartial(std.testing.allocator, "{\"answer\":{\"status\":\"rejected\",\"target\":{\"session\":\"foreign\"}}}");
    try std.testing.expect(partial.missing_fields and partial.has(".answer.status") and !partial.has(".execution"));
    try std.testing.expect(partial.deferred_error.? == error.RequestBindingMismatch);
    const WithoutMessage = DecoderWithPolicy(.{"{\"answer\":{\"status\":\"rejected\"},\"execution\":{\"status\":\"queued\"}}"}, .{shape}, JsonTypes, Policy);
    _ = try WithoutMessage.parse(std.testing.allocator, "{\"answer\":{\"status\":\"rejected\",\"message\":true},\"execution\":{\"status\":\"queued\"}}");
}

test "shape decoder partial parse distinguishes absent binding and payload fields" {
    const shape = .{"{\"answer\":{\"session\":\"expected\",\"replayed\":false},\"execution\":{\"status\":\"queued\"}}"};
    const D = Decoder(shape, .{shape});
    const partial = try D.parsePartial(std.testing.allocator, "{\"answer\":{\"session\":\"expected\",\"replayed\":false}}");
    try std.testing.expect(partial.missing_fields);
    try std.testing.expect(partial.has(".answer") and partial.has(".answer.session"));
    try std.testing.expect(!partial.has(".execution") and !partial.has(".execution.status"));
    try std.testing.expect(!partial.has(".unknown"));
    try std.testing.expect(partial.value.answer.session.eql("expected"));
    const nested = try D.parsePartial(std.testing.allocator, "{\"answer\":{},\"execution\":{\"status\":\"queued\"}}");
    try std.testing.expect(nested.has(".answer") and !nested.has(".answer.session"));
    try std.testing.expect(nested.missing_fields);
    try std.testing.expectError(error.MissingField, D.parse(std.testing.allocator, "{\"answer\":{\"session\":\"expected\",\"replayed\":false}}"));
    for ([_][]const u8{
        "{\"answer\":{\"session\":7,\"replayed\":false}}",
        "{\"answer\":{\"session\":\"wrong\",\"replayed\":false}}",
        "{\"answer\":{\"session\":\"expected\",\"replayed\":true}}",
        "{\"answer\":{\"session\":\"expected\",\"replayed\":false,\"session\":\"expected\"}}",
        "{\"answer\":{\"session\":\"expected\",\"replayed\":false}} {}",
    }) |body| try std.testing.expect(std.meta.isError(D.parsePartial(std.testing.allocator, body)));
    const complete = try D.parsePartial(std.testing.allocator, "{\"answer\":{\"session\":\"expected\",\"replayed\":false},\"execution\":{\"status\":\"queued\"}}");
    try std.testing.expect(!complete.missing_fields and complete.deferred_error == null);
}

test "shape decoder applies missing-field policy to selected and foreign syntax" {
    const answer = .{"{\"answer\":{\"status\":\"accepted\"}}"};
    const execution = .{"{\"execution\":{\"status\":\"queued\",\"reason\":\"optional\"}}"};
    const universe = .{ answer, execution };
    const JsonTypes = struct {
        pub fn Type(comptime T: type) type {
            return T;
        }
    };
    const Policy = struct {
        pub fn deferMissing(comptime path: []const u8) bool {
            return std.mem.eql(u8, path, ".execution.reason");
        }
        pub fn foreign(comptime _: []const u8, _: []const u8) !void {
            return error.ForeignAuthority;
        }
    };
    const E = DecoderWithPolicy(execution, universe, JsonTypes, Policy);
    const partial = try E.parsePartial(std.testing.allocator, "{\"execution\":{\"status\":\"queued\"}}");
    try std.testing.expect(partial.missing_fields and !partial.has(".execution.reason"));
    try std.testing.expectError(error.MissingField, E.parsePartial(std.testing.allocator, "{\"execution\":{\"reason\":\"optional\"}}"));
    try std.testing.expectError(error.MissingField, E.parse(std.testing.allocator, "{\"execution\":{\"status\":\"queued\"}}"));
    const A = DecoderWithPolicy(answer, universe, JsonTypes, Policy);
    const foreign = try A.parsePartial(std.testing.allocator, "{\"answer\":{\"status\":\"accepted\"},\"execution\":{\"status\":\"queued\"}}");
    try std.testing.expect(!foreign.missing_fields and foreign.has(".answer.status"));
    try std.testing.expect(foreign.deferred_error.? == error.ForeignAuthority);
    try std.testing.expectError(error.MissingField, A.parsePartial(std.testing.allocator, "{\"answer\":{\"status\":\"accepted\"},\"execution\":{\"reason\":\"optional\"}}"));
}

test "shape decoder policy merges deferred foreign errors independently of member order" {
    const shape = .{"{\"answer\":{\"status\":\"accepted\"}}"};
    const foreign_shape = .{"{\"answer\":{\"target\":{\"id\":\"7\"},\"other\":false}}"};
    const JsonTypes = struct {
        pub fn Type(comptime T: type) type {
            return T;
        }
    };
    const Policy = struct {
        pub fn foreign(comptime _: []const u8, name: []const u8) !void {
            return if (std.mem.eql(u8, name, "target")) error.RequestBindingMismatch else error.ForeignAuthority;
        }
        pub fn mergeDeferred(current: ?anyerror, next: anyerror) anyerror {
            if (next == error.RequestBindingMismatch) return next;
            return current orelse next;
        }
    };
    const D = DecoderWithPolicy(shape, .{ shape, foreign_shape }, JsonTypes, Policy);
    for ([_][]const u8{
        "{\"answer\":{\"other\":false,\"target\":{\"id\":\"7\"},\"status\":\"accepted\"}}",
        "{\"answer\":{\"target\":{\"id\":\"7\"},\"other\":false,\"status\":\"accepted\"}}",
    }) |body| {
        const parsed = try D.parsePartial(std.testing.allocator, body);
        try std.testing.expect(!parsed.missing_fields);
        try std.testing.expect(parsed.deferred_error.? == error.RequestBindingMismatch);
        try std.testing.expectError(error.RequestBindingMismatch, D.parse(std.testing.allocator, body));
    }
}
