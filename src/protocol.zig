const std = @import("std");
const model_capability = @import("model_capability.zig");
const named_scratch = @import("named_scratch.zig");
pub const ScratchBudget = @import("ScratchBudget.zig");

pub const wire_version = "1";
pub const max_key_bytes = 128;
pub const max_session_bytes = 128;
// SQLite's Unix VFS needs eight bytes beyond the database path for journals.
// The Store selector plus "/rui.sqlite3" and the journal suffix must stay
// within its compiled 512-byte pathname limit.
pub const max_store_bytes = 492;
pub const max_workspace_bytes = 4096;
pub const max_sender_handle_bytes = 32;
pub const max_model_bytes = model_capability.max_model_bytes;
// Resolution, rejection and failure codes.
pub const max_code_bytes = 96;
pub const max_tool_description_bytes = 100;
pub const Provider = enum { codex };
pub const ReasoningEffort = model_capability.ReasoningEffort;
// Like permission-mode selectors, retain bounded unsupported names so admission
// can save their rejection. This is an ingress bound, not a provider registry.
pub const max_provider_bytes = 16;
pub const max_header_bytes = 16 * 1024;
pub const content_window_bytes = 4096;
pub const public_conversation_page_items = 16;
pub const max_json_depth = 64;
pub const max_sqlite_content_bytes: u64 = 1024 * 1024 * 1024 - 4096;
pub const session_list_page_size: usize = 8;

pub const Bounded = @import("bounded.zig").Bounded;

pub const session_id_bytes = 6;
pub const session_alphabet = "0123456789abcdefghjkmnpqrstvwxyz";

pub fn validSessionId(value: []const u8) bool {
    if (value.len != session_id_bytes) return false;
    for (value) |byte| if (std.mem.indexOfScalar(u8, session_alphabet, byte) == null) return false;
    return true;
}

/// Exact peer address. The issuing Host authenticates the sender separately.
pub const Address = struct {
    store: Bounded(max_store_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},

    pub fn validate(self: Address) !void {
        const path = self.store.slice();
        if (path.len == 0 or path[0] != '/' or !validSessionId(self.session.slice()) or
            !std.unicode.utf8ValidateSlice(path)) return error.InvalidRuiAddress;
        for (path) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidRuiAddress;
        if (path.len > 1) {
            var components = std.mem.splitScalar(u8, path[1..], '/');
            while (components.next()) |component| if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidRuiAddress;
        }
    }
};

pub const FieldState = enum { omitted, value, explicit_null };

pub fn OptionalBounded(comptime capacity: usize) type {
    return struct {
        state: FieldState = .omitted,
        value: Bounded(capacity) = .{},
    };
}

pub const ContentField = struct {
    state: enum { omitted, value, explicit_null } = .omitted,
    // A parsed request owns an unlinked file descriptor. The Store imports
    // through this sealed custody; no pathname can be swapped after capture.
    file: ?std.Io.File = null,
    scratch_budget: ?ScratchBudget = null,
    charged: u64 = 0,
    length: u64 = 0,
    digest: [32]u8 = @splat(0),

    pub fn hasFile(self: *const ContentField) bool {
        return self.file != null;
    }
};

pub const ToolsField = struct {
    state: FieldState = .omitted,
    count: u1 = 0,
    values: [1]enum { bash } = undefined,
};

pub const Configuration = struct {
    workspace: OptionalBounded(max_workspace_bytes) = .{},
    provider: OptionalBounded(max_provider_bytes) = .{},
    model: OptionalBounded(max_model_bytes) = .{},
    instructions: ContentField = .{},
    tools: ToolsField = .{},
    permission_mode: OptionalBounded(16) = .{},
    output_schema: ContentField = .{},
    compaction_trigger: OptionalBounded(20) = .{},
    output_reservation: OptionalBounded(20) = .{},
    reasoning_effort: OptionalBounded(16) = .{},
};

pub const Kind = enum {
    host_info,
    host_stop,
    configure,
    message,
    session_stop,
    model_interruption,
    permission_decision,
    observe_command,
    read_result,
    read_action_call_id,
    read_action_arguments,
    inspect_session,
    list_sessions,
    conversation_page,
    conversation_content,
    proposal_page,
    proposal_field,
    activity_page,
    activity_content,
};

pub const ConfigureCommand = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    configuration: Configuration = .{},
    require_model: bool = false,

    pub fn removeTemporaryContent(self: *ConfigureCommand, io: std.Io) !void {
        var cleanup_error: ?anyerror = null;
        removeContent(&self.configuration.instructions, io) catch |err| {
            cleanup_error = err;
        };
        removeContent(&self.configuration.output_schema, io) catch |err| {
            cleanup_error = err;
        };
        if (cleanup_error) |err| return err;
    }

    pub fn semanticDigest(self: *const ConfigureCommand) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hash, "rui/core/configure/v1");
        hashField(&hash, self.session.slice());
        hashOptional(&hash, &self.configuration.workspace);
        hashOptional(&hash, &self.configuration.provider);
        hashOptional(&hash, &self.configuration.model);
        hashContent(&hash, &self.configuration.instructions);
        hash.update(&.{@backingInt(self.configuration.tools.state)});
        if (self.configuration.tools.state == .value) {
            hash.update(&.{self.configuration.tools.count});
            for (self.configuration.tools.values[0..self.configuration.tools.count]) |tool| {
                hashField(&hash, @tagName(tool));
            }
        }
        hashOptional(&hash, &self.configuration.permission_mode);
        hashContent(&hash, &self.configuration.output_schema);
        hashOptional(&hash, &self.configuration.compaction_trigger);
        hashOptional(&hash, &self.configuration.output_reservation);
        hashOptional(&hash, &self.configuration.reasoning_effort);
        hash.update(&.{@intFromBool(self.require_model)});
        return hash.finalResult();
    }
};

pub const MessageCommand = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    // The full sending address; null when a human or script sends.
    sender: ?Address = null,
    sender_handle: ?Bounded(max_sender_handle_bytes) = null,
    text: ContentField = .{},
    // Non-null means create a fresh Session and admit this first Message in
    // one transaction. The requested Session must then be empty. Initial
    // configuration cannot supply instruction or schema content values.
    configuration: ?Configuration = null,

    pub fn removeTemporaryContent(self: *MessageCommand, io: std.Io) !void {
        try removeContent(&self.text, io);
    }

    pub fn semanticDigest(self: *const MessageCommand) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hash, "rui/core/message/v3");
        hashField(&hash, self.session.slice());
        hash.update(&.{@intFromBool(self.sender != null)});
        if (self.sender) |sender| {
            hashField(&hash, sender.store.slice());
            hashField(&hash, sender.session.slice());
        }
        hash.update(&.{@intFromBool(self.sender_handle != null)});
        if (self.sender_handle) |handle| hashField(&hash, handle.slice());
        hashContent(&hash, &self.text);
        if (self.configuration) |configuration| {
            const creation = ConfigureCommand{ .configuration = configuration };
            hashField(&hash, "initial-configuration");
            hash.update(&creation.semanticDigest());
        }
        return hash.finalResult();
    }
};

pub const SessionStopCommand = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},

    pub fn semanticDigest(self: *const SessionStopCommand) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hash, "rui/core/session-stop/v1");
        hashField(&hash, self.session.slice());
        return hash.finalResult();
    }
};

pub const ModelInterruptionCommand = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    turn_id: u64 = 0,
    operation_id: u64 = 0,

    pub fn semanticDigest(self: *const ModelInterruptionCommand) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hash, "rui/core/model-interruption/v1");
        hashField(&hash, self.session.slice());
        var value: [8]u8 = undefined;
        std.mem.writeInt(u64, &value, self.turn_id, .big);
        hash.update(&value);
        std.mem.writeInt(u64, &value, self.operation_id, .big);
        hash.update(&value);
        return hash.finalResult();
    }
};

pub const PermissionDecision = enum { allow_once, deny };

// Reply and observation vocabulary. The Store produces these values and the
// Host renders their tag names, so each reply's JSON shape can bound them.
pub const ConfigurationRejection = enum {
    invalid_session_reference,
    unknown_session,
    unsupported_permission_mode,
    unsupported_provider,
    invalid_model,
    model_capability_unavailable,
    invalid_output_schema,
    invalid_compaction_trigger,
    invalid_output_reservation,
    unsupported_reasoning_effort,
    incomplete_initial_configuration,
    invalid_workspace,
    workspace_is_immutable,
    provider_is_immutable,
    model_is_immutable,
    revision_exhausted,
};
pub const MessageRejection = enum {
    invalid_session_reference,
    unknown_session,
    invalid_sender_handle,
    unsupported_permission_mode,
    unsupported_provider,
    invalid_model,
    model_capability_unavailable,
    invalid_output_schema,
    invalid_compaction_trigger,
    invalid_output_reservation,
    unsupported_reasoning_effort,
    incomplete_initial_configuration,
    invalid_workspace,
    workspace_is_immutable,
    provider_is_immutable,
    model_is_immutable,
    revision_exhausted,
};
pub const CommandKind = enum { configure, message, session_stop, model_interruption, permission_decision };
pub const CommandObservationStatus = enum { absent, accepted, rejected };
pub const SessionStopCompletion = enum { pending, completed };
pub const SessionStopRejection = enum { invalid_session_reference, unknown_session };
pub const ModelInterruptionRejection = enum {
    invalid_session_reference,
    invalid_target,
    unknown_session,
    unknown_operation,
    target_mismatch,
    operation_resolved,
};
pub const PermissionDecisionRejection = enum {
    invalid_session_reference,
    invalid_target,
    unknown_session,
    unknown_action,
    target_mismatch,
    action_not_pending,
};
pub const MessageProgressStatus = enum { runnable, in_flight, waiting_for_permission };
pub const ConversationItemKind = enum { user, assistant, tool_result };

pub const PermissionDecisionCommand = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    action_id: u64 = 0,
    decision: PermissionDecision = .deny,

    pub fn semanticDigest(self: *const PermissionDecisionCommand) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hash, "rui/core/permission-decision/v1");
        hashField(&hash, self.session.slice());
        var value: [8]u8 = undefined;
        std.mem.writeInt(u64, &value, self.action_id, .big);
        hash.update(&value);
        hashField(&hash, @tagName(self.decision));
        return hash.finalResult();
    }
};

pub const ReadActionArguments = struct {
    store: Bounded(max_store_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    action_id: u64 = 0,
};

pub const ObserveCommand = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
};

pub const ReadResult = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
};

pub const ReportProfile = enum { current, full };

pub const FailedResponsePart = enum { body, metadata };
pub const FailedResponseExport = struct {
    operation: u64,
    attempt: u64,
    part: FailedResponsePart,
};

pub const InspectSession = struct {
    store: Bounded(max_store_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    profile: ReportProfile = .current,
    failed_response: ?FailedResponseExport = null,
};

// Random per serving lifetime; not a PID, Store identity, or recovery token.
pub const InstanceId = [16]u8;

pub fn parseInstanceId(text: []const u8) !InstanceId {
    if (text.len != 32) return error.InvalidInstanceId;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return error.InvalidInstanceId;
    }
    var id: InstanceId = undefined;
    _ = try std.fmt.hexToBytes(&id, text);
    return id;
}

pub const HostInfo = struct {
    version: []const u8,
    type: []const u8,
    store: []const u8,
    instance: []const u8,
    active_capacity: []const u8,
    intake_capacity: []const u8 = "100",
    descriptor_limit: []const u8 = "unlimited",
    capabilities: struct {
        bash: bool,
        model: bool,
        managed_authentication: bool,
    },
};

pub const ListSessions = struct {
    store: Bounded(max_store_bytes) = .{},
    workspace: ?Bounded(max_workspace_bytes) = null,
    // Zero/zero begins a traversal. A continuation carries both values.
    after: u64 = 0,
    ceiling: u64 = 0,
};

// Positions are immutable within a Session. The zero end/cursor requests the
// first (newest) page; subsequent requests carry the returned fixed end.
pub const ConversationPage = struct {
    store: Bounded(max_store_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    end: u64 = 0,
    before_position: u64 = 0,
    before_ordinal: u64 = 0,
};

pub const ConversationContent = struct {
    store: Bounded(max_store_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    position: u64 = 0,
    ordinal: u64 = 0,
    start: u64 = 0,
    stream: bool = false,
};

pub const ProposalField = enum { item_id, name, call_id, arguments };
pub const ProposalRejection = enum { unknown_tool, invalid_arguments };
pub const proposal_page_items = 16;
pub const ProposalMetadata = struct {
    position: u64,
    operation: u64,
    turn: u64,
    call_ordinal: u64,
    action: ?u64,
    rejection: ?ProposalRejection,
    fields: [4]struct { length: u64, digest: [32]u8 }, // ProposalField order.
};
pub const ProposalPage = struct {
    store: Bounded(max_store_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    end: ?u64 = null, // Null captures; zero freezes an empty traversal.
    after: u64 = 0,

    pub fn validate(self: ProposalPage) !void {
        if (self.after > std.math.maxInt(i64)) return error.InvalidCursor;
        if (self.end) |end| {
            if (end > std.math.maxInt(i64) or self.after > end) return error.InvalidCursor;
        } else if (self.after != 0) return error.InvalidCursor;
    }
};
pub const ReadProposalField = struct {
    store: Bounded(max_store_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    position: u64 = 0,
    field: ProposalField = .item_id,
};

pub const ActivityPage = struct {
    store: Bounded(max_store_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    end: ?u64 = null,
    position: u64 = 0,
    // Null is a sequence boundary; a value identifies an actual public row.
    ordinal: ?u64 = null,
    direction: enum { forward, backward } = .forward,

    pub fn validate(self: ActivityPage) !void {
        if (self.position > std.math.maxInt(i64) or (self.ordinal != null and
            (self.position == 0 or self.ordinal.? > std.math.maxInt(i64)))) return error.InvalidCursor;
        if (self.end) |end| if (end > std.math.maxInt(i64) or self.position > end) return error.InvalidCursor;
    }
};
pub const ToolPresentation = struct {
    description: ?Bounded(max_tool_description_bytes),
    code: Code,
    publication_position: ?u64,
    pub const Code = enum { unresolved, pending_permission, succeeded, failed, timed_out, indeterminate, storage_failed, spawn_failed, cancelled, infrastructure_shutdown, denied, unknown_tool, invalid_arguments };

    /// Holes: description, code, publication position.
    pub const json_shape = .{ "{\"description\":", Hole{ .optional_string = max_tool_description_bytes }, ",\"code\":\"", Hole{ .tag = Code }, "\",\"publication_position\":", Hole.optional_id, "}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn writeJson(self: ToolPresentation, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, .{ if (self.description) |description| description.slice() else null, self.code, self.publication_position });
    }
};

/// A peer Session named on a Message, in the same Store.
pub const Peer = struct {
    session: Bounded(max_session_bytes),

    pub const json_shape = .{ "{\"session\":", Hole{ .string = max_session_bytes }, "}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn writeJson(self: Peer, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, .{self.session.slice()});
    }
};

pub const ActivityItem = struct {
    position: u64,
    ordinal: u64 = 0,
    value: Value,
    pub const Value = union(enum) { admission: Message, user: Message, assistant: Content, call: Call, tool_result: struct { content: Content, presentation: ToolPresentation }, outcome: Outcome, stop: Stop, sent: Sent, send_failed: SendFailed };
    pub const Content = struct {
        length: u64,
        digest: [32]u8,
        pub const json_shape = .{ "{\"bytes\":\"", Hole.decimal, "\",\"sha256\":\"", Hole{ .hex = 32 }, "\"}" };
        pub const max_json_bytes = shapeBytes(json_shape);
        pub fn writeJson(self: Content, out: *std.Io.Writer) !void {
            try writeShape(out, json_shape, .{ self.length, self.digest });
        }
    };
    // `admitted_at` is the Host wall-clock second the Message was admitted.
    // A null `sender` means a human or script sent the Message.
    pub const Message = struct { admission: u64, key: Bounded(max_key_bytes), turn: ?u64, state: enum { queued, applied, excluded }, content: Content, admitted_at: u64, sender: ?Peer = null };
    pub const Call = ProposalMetadata;
    pub const Outcome = struct { turn: u64, operation: u64, code: Bounded(max_code_bytes), content: ?Content };
    pub const Stop = struct { key: Bounded(max_key_bytes), turn: ?u64, cutoff: u64, completion: SessionStopCompletion };
    /// A Message this Session sent: admitted to `target`, or rejected there.
    pub const Sent = struct { admission: u64, target: Peer, content: Content, admitted_at: u64 };
    pub const SendFailed = struct { key: Bounded(max_key_bytes), target: Peer, code: Bounded(max_code_bytes) };

    /// Holes: position, ordinal; then the value's shape, then `tail`.
    pub fn head(comptime kind: std.meta.Tag(Value)) struct { []const u8, Hole, []const u8, Hole, []const u8 } {
        return .{ "{\"position\":\"", .decimal, "\",\"ordinal\":\"", .decimal, "\",\"value\":{\"" ++ @tagName(kind) ++ "\":" };
    }
    pub const tail = .{"}}"};
    /// Each value kind's JSON, named by its tag.
    pub const value_shapes = struct {
        /// Holes: admission, key, turn, state, admitted at, sender, content.
        const message = .{ "{\"admission\":\"", Hole.decimal, "\",\"key\":", Hole{ .string = max_key_bytes }, ",\"turn\":", Hole.optional_id, ",\"state\":\"", Hole{ .tag = @FieldType(Message, "state") }, "\",\"admitted_at\":\"", Hole.decimal, "\",\"sender\":", Hole{ .optional_json = Peer }, ",\"content\":", Hole{ .json = Content }, "}" };
        pub const admission = message;
        pub const user = message;
        /// Hole: content.
        pub const assistant = .{Hole{ .json = Content }};
        /// Holes: operation, turn, call ordinal, Action, rejection, the four field contents.
        pub const call = .{ "{\"operation\":\"", Hole.decimal, "\",\"turn\":\"", Hole.decimal, "\",\"call_ordinal\":\"", Hole.decimal, "\",\"action\":", Hole.optional_id, ",\"rejection\":", Hole{ .optional_tag = ProposalRejection }, ",\"fields\":[", Hole{ .json = Content }, ",", Hole{ .json = Content }, ",", Hole{ .json = Content }, ",", Hole{ .json = Content }, "]}" };
        /// Holes: content, presentation.
        pub const tool_result = .{ "{\"content\":", Hole{ .json = Content }, ",\"presentation\":", Hole{ .json = ToolPresentation }, "}" };
        /// Holes: turn, operation, code, content.
        pub const outcome = .{ "{\"turn\":\"", Hole.decimal, "\",\"operation\":\"", Hole.decimal, "\",\"code\":", Hole{ .string = max_code_bytes }, ",\"content\":", Hole{ .optional_json = Content }, "}" };
        /// Holes: key, turn, cutoff, completion.
        pub const stop = .{ "{\"key\":", Hole{ .string = max_key_bytes }, ",\"turn\":", Hole.optional_id, ",\"cutoff\":\"", Hole.decimal, "\",\"completion\":\"", Hole{ .tag = SessionStopCompletion }, "\"}" };
        /// Holes: admission, admitted at, target, content.
        pub const sent = .{ "{\"admission\":\"", Hole.decimal, "\",\"admitted_at\":\"", Hole.decimal, "\",\"target\":", Hole{ .json = Peer }, ",\"content\":", Hole{ .json = Content }, "}" };
        /// Holes: key, target, code.
        pub const send_failed = .{ "{\"key\":", Hole{ .string = max_key_bytes }, ",\"target\":", Hole{ .json = Peer }, ",\"code\":", Hole{ .string = max_code_bytes }, "}" };
    };
    pub const max_json_bytes = blk: {
        var bytes = 0;
        for (std.meta.tags(std.meta.Tag(Value))) |kind| bytes = @max(bytes, shapeBytes(head(kind)) + shapeBytes(@field(value_shapes, @tagName(kind))));
        break :blk bytes + shapeBytes(tail);
    };

    pub fn writeJson(self: *const ActivityItem, out: *std.Io.Writer) !void {
        switch (self.value) {
            inline else => |_, kind| try writeShape(out, head(kind), .{ self.position, self.ordinal }),
        }
        switch (self.value) {
            inline .admission, .user => |message, tag| try writeShape(out, @field(value_shapes, @tagName(tag)), .{
                message.admission,   message.key.slice(), message.turn,    message.state,
                message.admitted_at, message.sender,      message.content,
            }),
            .sent => |sent| try writeShape(out, value_shapes.sent, .{ sent.admission, sent.admitted_at, sent.target, sent.content }),
            .send_failed => |failed| try writeShape(out, value_shapes.send_failed, .{ failed.key.slice(), failed.target, failed.code.slice() }),
            .assistant => |content| try writeShape(out, value_shapes.assistant, .{content}),
            .tool_result => |result| try writeShape(out, value_shapes.tool_result, .{ result.content, result.presentation }),
            .call => |call| {
                comptime std.debug.assert(call.fields.len == 4);
                var fields: [4]Content = undefined;
                for (call.fields, &fields) |field, *content| content.* = .{ .length = field.length, .digest = field.digest };
                try writeShape(out, value_shapes.call, .{ call.operation, call.turn, call.call_ordinal, call.action, call.rejection, fields[0], fields[1], fields[2], fields[3] });
            },
            .outcome => |outcome| try writeShape(out, value_shapes.outcome, .{ outcome.turn, outcome.operation, outcome.code.slice(), outcome.content }),
            .stop => |stop| try writeShape(out, value_shapes.stop, .{ stop.key.slice(), stop.turn, stop.cutoff, stop.completion }),
        }
        try writeShape(out, tail, .{});
    }
};
pub const ReadActivityContent = struct { store: Bounded(max_store_bytes) = .{}, session: Bounded(max_session_bytes) = .{}, position: u64 = 0, ordinal: u64 = 0 };

pub const CallActivity = struct {
    pub const Entry = struct { operation: u64, ordinal: u64, presentation: ToolPresentation };
    entries: [3]Entry = undefined,
    count: usize = 0,
    total: u64 = 0,

    /// Hole: total.
    pub const head = .{ "{\"total\":\"", Hole.decimal, "\",\"entries\":[" };
    /// Holes: operation, ordinal, presentation.
    pub const entry_shape = .{ "{\"operation\":\"", Hole.decimal, "\",\"ordinal\":\"", Hole.decimal, "\",\"presentation\":", Hole{ .json = ToolPresentation }, "}" };
    pub const tail = .{"]}"};
    pub const max_json_bytes = shapeBytes(head) + jsonListBytes(@typeInfo(@FieldType(CallActivity, "entries")).array.len, shapeBytes(entry_shape)) + shapeBytes(tail);

    pub fn writeJson(self: *const CallActivity, out: *std.Io.Writer) !void {
        try writeShape(out, head, .{self.total});
        for (self.entries[0..self.count], 0..) |entry, index| {
            if (index != 0) try out.writeByte(',');
            try writeShape(out, entry_shape, .{ entry.operation, entry.ordinal, entry.presentation });
        }
        try writeShape(out, tail, .{});
    }
};

/// The Session's work as of its page's own Store read: what the live footer,
/// consent and first Action show with that page.
pub const PageWork = struct {
    pub const Status = enum { idle, runnable, in_flight, waiting_for_permission, completed, cancelled, failed };
    status: Status = .idle,
    turn: ?u64 = null,
    operation: ?u64 = null,
    first_action: ?u64 = null,
    revision: u64 = 0,
    workspace: Bounded(max_workspace_bytes) = .{},

    /// Holes follow field order.
    pub const json_shape = .{ "{\"status\":\"", Hole{ .tag = Status }, "\",\"turn\":", Hole.optional_id, ",\"operation\":", Hole.optional_id, ",\"first_action\":", Hole.optional_id, ",\"revision\":\"", Hole.decimal, "\",\"workspace\":", Hole{ .string = max_workspace_bytes }, "}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn writeJson(self: *const PageWork, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, .{ self.status, self.turn, self.operation, self.first_action, self.revision, self.workspace.slice() });
    }
};

pub const ActivityFacts = struct {
    end: u64,
    direction: @FieldType(ActivityPage, "direction") = .forward,
    items: [16]ActivityItem = undefined,
    count: usize = 0,
    more: bool = false,
    call_activity: CallActivity = .{},
    work: PageWork = .{},

    /// Holes: end, direction; then the items, then `tail`.
    pub const head = .{ "{\"version\":\"1\",\"type\":\"activity_page\",\"end\":\"", Hole.decimal, "\",\"direction\":\"", Hole{ .tag = @FieldType(ActivityPage, "direction") }, "\",\"items\":[" };
    /// Holes: more, call activity, work.
    pub const tail = .{ "],\"more\":", Hole.boolean, ",\"call_activity\":", Hole{ .json = CallActivity }, ",\"work\":", Hole{ .json = PageWork }, "}" };
    pub const max_json_bytes = shapeBytes(head) + jsonListBytes(@typeInfo(@FieldType(ActivityFacts, "items")).array.len, ActivityItem.max_json_bytes) + shapeBytes(tail);

    pub fn writeJson(self: *const ActivityFacts, out: *std.Io.Writer) !void {
        try writeShape(out, head, .{ self.end, self.direction });
        for (self.items[0..self.count], 0..) |*item, index| {
            if (index != 0) try out.writeByte(',');
            try item.writeJson(out);
        }
        try writeShape(out, tail, .{ self.more, &self.call_activity, &self.work });
    }
};

pub const Request = union(Kind) {
    host_info: struct { store: Bounded(max_store_bytes) = .{} },
    host_stop: struct { store: Bounded(max_store_bytes) = .{} },
    configure: ConfigureCommand,
    message: MessageCommand,
    session_stop: SessionStopCommand,
    model_interruption: ModelInterruptionCommand,
    permission_decision: PermissionDecisionCommand,
    observe_command: ObserveCommand,
    read_result: ReadResult,
    read_action_call_id: ReadActionArguments,
    read_action_arguments: ReadActionArguments,
    inspect_session: InspectSession,
    list_sessions: ListSessions,
    conversation_page: ConversationPage,
    conversation_content: ConversationContent,
    proposal_page: ProposalPage,
    proposal_field: ReadProposalField,
    activity_page: ActivityPage,
    activity_content: ReadActivityContent,

    pub fn removeTemporaryContent(self: *Request, io: std.Io) !void {
        switch (self.*) {
            .configure => |*command| try command.removeTemporaryContent(io),
            .message => |*command| try command.removeTemporaryContent(io),
            .host_info, .host_stop, .session_stop, .model_interruption, .permission_decision, .observe_command, .read_result, .read_action_call_id, .read_action_arguments, .inspect_session, .list_sessions, .conversation_page, .conversation_content, .proposal_page, .proposal_field, .activity_page, .activity_content => {},
        }
    }

    /// Borrows the active payload's Store bytes until this Request is replaced.
    pub fn store(self: *const Request) []const u8 {
        return switch (self.*) {
            inline else => |*request| request.store.slice(),
        };
    }
};

fn removeContent(content: *ContentField, io: std.Io) !void {
    if (content.file) |file| file.close(io);
    if (content.scratch_budget) |budget| budget.release(content.charged);
    content.charged = 0;
    content.file = null;
    content.state = .omitted;
}

fn hashField(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .big);
    hash.update(&length);
    hash.update(value);
}

fn hashOptional(hash: *std.crypto.hash.sha2.Sha256, field: anytype) void {
    hash.update(&.{@backingInt(field.state)});
    if (field.state == .value) hashField(hash, field.value.slice());
}

fn hashContent(hash: *std.crypto.hash.sha2.Sha256, field: *const ContentField) void {
    hash.update(&.{@backingInt(field.state)});
    if (field.state == .value) {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, field.length, .big);
        hash.update(&length);
        hash.update(&field.digest);
    }
}

pub fn contentHasher() std.crypto.hash.sha2.Sha256 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hash, "rui/content/v1");
    return hash;
}

pub fn contentDigest(value: []const u8) [32]u8 {
    var hash = contentHasher();
    hash.update(value);
    return hash.finalResult();
}

/// Injected failures of a request's content capture.
pub const ContentFaults = struct {
    acquire: bool = false,
    write: bool = false,
    seal: bool = false,
};

pub const ParseOptions = struct {
    io: std.Io,
    fd: std.posix.fd_t,
    content_length: u64,
    scratch_path: []const u8,
    request_number: u64,
    content_faults: ContentFaults = .{},
    retained_scratch: *?named_scratch.Owner,
    scratch_budget: ?ScratchBudget = null,
    expected_kind: ?Kind = null,
    deadline: ?i128 = null,
};

/// Resumable ingress owns captures until complete framing and validation.
/// Parser remains the sole wire grammar: only its content-read instruction
/// can open a capture. Replays see metadata, never descriptors or charges.
pub const Ingress = struct {
    allocator: std.mem.Allocator,
    options: ParseOptions,
    metadata: std.ArrayList(u8) = .empty,
    received: u64 = 0,
    lexical: enum { plain, string, escape } = .plain,
    expecting_content: bool = false,
    capture: ?ContentCapture = null,
    decoder: StringDecoder = .{},
    contents: [2]ContentField = .{ .{}, .{} },
    content_count: usize = 0,
    complete: bool = false,

    // Initial Message combines configuration scalars and sender identity.
    // Allow worst-case escaping of both and 128 short grammar tokens (keys,
    // states, tools and literals, each at most 32 bytes), plus punctuation
    // and one preserved whitespace separator at every lexical boundary.
    const metadata_limit = 2 * (6 * (max_store_bytes + max_key_bytes + max_session_bytes +
        max_workspace_bytes + max_provider_bytes + max_model_bytes + 16 + 128 * 32) + 128 * 8);

    pub fn init(allocator: std.mem.Allocator, options: ParseOptions) Ingress {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *Ingress) void {
        if (self.capture) |*capture| capture.deinit();
        self.capture = null;
        for (&self.contents) |*field| removeContent(field, self.options.io) catch unreachable;
        self.metadata.deinit(self.allocator);
        self.metadata = .empty;
    }

    pub fn feed(self: *Ingress, bytes: []const u8) !void {
        if (bytes.len > self.options.content_length - self.received) return error.TrailingInput;
        for (bytes) |byte| {
            if (self.complete) return error.TrailingInput;
            self.received += 1;
            if (self.expecting_content) {
                if (self.capture == null) {
                    switch (byte) {
                        ' ', '\t', '\r', '\n' => continue,
                        '"' => {},
                        else => return error.InvalidJsonShape,
                    }
                    self.capture = try ContentCapture.init(self.options, @intCast(self.content_count + 1));
                    self.decoder = .{};
                } else if (try self.decoder.feed(byte, &self.capture.?.sink)) {
                    self.contents[self.content_count] = try self.capture.?.seal();
                    self.content_count += 1;
                    self.capture.?.deinit();
                    self.capture = null;
                    self.expecting_content = false;
                    try self.append('"');
                    try self.append('"');
                    try self.preview();
                }
                continue;
            }
            var boundary = false;
            switch (self.lexical) {
                .plain => switch (byte) {
                    ' ', '\t', '\r', '\n' => {
                        // Do not join tokens (t rue) or erase trailing input.
                        if (self.metadata.items.len == 0 or self.metadata.items[self.metadata.items.len - 1] != ' ')
                            try self.append(' ');
                        continue;
                    },
                    '"' => self.lexical = .string,
                    '{', '}', '[', ']', ',', ':' => boundary = true,
                    else => {},
                },
                .string => switch (byte) {
                    '"' => {
                        self.lexical = .plain;
                        boundary = true;
                    },
                    '\\' => self.lexical = .escape,
                    else => {},
                },
                .escape => self.lexical = .string,
            }
            try self.append(byte);
            if (boundary) try self.preview();
        }
    }

    fn append(self: *Ingress, byte: u8) !void {
        if (self.metadata.items.len == metadata_limit) return error.ValueTooLong;
        try self.metadata.append(self.allocator, byte);
    }

    fn parse(self: *Ingress) !Request {
        var source = SocketBody.init(-1, 0);
        source.input = self.metadata.items;
        var parser = Parser{
            .source = &source,
            .options = self.options,
            .captured = self.contents[0..self.content_count],
        };
        const request = try parser.parse();
        std.debug.assert(parser.content_ordinal == self.content_count);
        return request;
    }

    fn preview(self: *Ingress) !void {
        _ = self.parse() catch |err| switch (err) {
            error.NeedInput => return,
            error.NeedContent => {
                std.debug.assert(self.content_count < self.contents.len);
                self.expecting_content = true;
                return;
            },
            else => return err,
        };
        self.complete = true;
        if (self.received != self.options.content_length) return error.TrailingInput;
    }

    pub fn finish(self: *Ingress) !Request {
        if (self.received != self.options.content_length) return error.UnexpectedEndOfBody;
        var request = self.parse() catch |err| switch (err) {
            error.NeedInput, error.NeedContent => return error.UnexpectedEndOfBody,
            else => return err,
        };
        // All fallible validation precedes this non-failing custody transfer.
        var index: usize = 0;
        switch (request) {
            .configure => |*command| {
                for ([_]*ContentField{ &command.configuration.instructions, &command.configuration.output_schema }) |field| {
                    if (field.state != .value) continue;
                    field.* = self.contents[index];
                    self.contents[index] = .{};
                    index += 1;
                }
            },
            .message => |*command| {
                command.text = self.contents[0];
                self.contents[0] = .{};
                index = 1;
            },
            else => {},
        }
        std.debug.assert(index == self.content_count);
        self.metadata.deinit(self.allocator);
        self.metadata = .empty;
        return request;
    }
};

pub fn parseRequest(allocator: std.mem.Allocator, options: ParseOptions) !Request {
    var ingress = Ingress.init(allocator, options);
    defer ingress.deinit();
    var buffer: [content_window_bytes]u8 = undefined;
    while (ingress.received < options.content_length) {
        try pollExchange(options.io, options.fd, std.posix.POLL.IN, options.deadline);
        const wanted: usize = @intCast(@min(options.content_length - ingress.received, buffer.len));
        const count = try std.posix.read(options.fd, buffer[0..wanted]);
        if (count == 0) return error.UnexpectedEndOfBody;
        try ingress.feed(buffer[0..count]);
    }
    return ingress.finish();
}

// Discovery uses one absolute budget. Ordinary ingress keeps its existing
// refill inactivity wait; progress cannot extend an absolute exchange.
pub fn pollExchange(io: std.Io, fd: std.posix.fd_t, events: i16, deadline: ?i128) !void {
    const end = deadline orelse {
        var descriptors = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        if (try std.posix.poll(&descriptors, 60_000) == 0) return error.TransferInactive;
        return;
    };
    while (true) {
        const remaining = end - std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        if (remaining <= 0) return error.ExchangeDeadlineExceeded;
        const milliseconds: c_int = @intCast(@min(60_000, @divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        var descriptors = [_]std.c.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        // Recompute after EINTR rather than retrying the original timeout.
        const result = std.c.poll(&descriptors, descriptors.len, milliseconds);
        switch (std.posix.errno(result)) {
            .SUCCESS => if (result > 0) {
                if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= end) return error.ExchangeDeadlineExceeded;
                return;
            },
            .INTR => {},
            else => return error.PollFailed,
        }
    }
}

const SocketBody = struct {
    fd: std.posix.fd_t,
    remaining: u64,
    io: std.Io = undefined,
    deadline: ?i128 = null,
    buffer: [content_window_bytes]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    input: ?[]const u8 = null,

    fn init(fd: std.posix.fd_t, length: u64) SocketBody {
        return .{ .fd = fd, .remaining = length };
    }

    fn readByte(self: *SocketBody) !u8 {
        if (self.input) |input| {
            if (self.start == input.len) return error.NeedInput;
            const byte = input[self.start];
            self.start += 1;
            return byte;
        }
        if (self.start == self.end) try self.refill();
        const byte = self.buffer[self.start];
        self.start += 1;
        return byte;
    }

    fn atEnd(self: *const SocketBody) bool {
        return if (self.input) |input| self.start == input.len else self.remaining == 0 and self.start == self.end;
    }

    fn refill(self: *SocketBody) !void {
        if (self.remaining == 0) return error.UnexpectedEndOfBody;
        try pollExchange(self.io, self.fd, std.posix.POLL.IN, self.deadline);
        const limit: usize = @intCast(@min(self.remaining, self.buffer.len));
        const count = try std.posix.read(self.fd, self.buffer[0..limit]);
        if (count == 0) return error.UnexpectedEndOfBody;
        self.remaining -= count;
        self.start = 0;
        self.end = count;
    }
};

const Parser = struct {
    source: *SocketBody,
    options: ParseOptions,
    content_ordinal: u8 = 0,
    captured: ?[]const ContentField = null,

    fn parse(self: *Parser) !Request {
        try self.expectByte('{');
        try self.expectKey("version");
        var version: Bounded(8) = .{};
        try self.readSmallString(&version);
        if (!version.eql(wire_version)) return error.WrongWireVersion;
        try self.expectByte(',');
        try self.expectKey("kind");
        var kind_text: Bounded(32) = .{};
        try self.readSmallString(&kind_text);
        const kind: Kind = if (kind_text.eql("host_info"))
            .host_info
        else if (kind_text.eql("host_stop"))
            .host_stop
        else if (kind_text.eql("configure"))
            .configure
        else if (kind_text.eql("message"))
            .message
        else if (kind_text.eql("session_stop"))
            .session_stop
        else if (kind_text.eql("model_interruption"))
            .model_interruption
        else if (kind_text.eql("permission_decision"))
            .permission_decision
        else if (kind_text.eql("observe_command"))
            .observe_command
        else if (kind_text.eql("read_result"))
            .read_result
        else if (kind_text.eql("read_action_call_id"))
            .read_action_call_id
        else if (kind_text.eql("read_action_arguments"))
            .read_action_arguments
        else if (kind_text.eql("inspect_session"))
            .inspect_session
        else if (kind_text.eql("list_sessions"))
            .list_sessions
        else if (kind_text.eql("conversation_page"))
            .conversation_page
        else if (kind_text.eql("conversation_content"))
            .conversation_content
        else if (kind_text.eql("proposal_page"))
            .proposal_page
        else if (kind_text.eql("proposal_field"))
            .proposal_field
        else if (kind_text.eql("activity_page"))
            .activity_page
        else if (kind_text.eql("activity_content"))
            .activity_content
        else
            return error.UnknownCommand;

        if (self.options.expected_kind) |expected| {
            if (kind != expected) return error.RouteKindMismatch;
        }
        try self.expectByte(',');
        try self.expectKey("store");
        var store: Bounded(max_store_bytes) = .{};
        try self.readSmallString(&store);

        var request: Request = switch (kind) {
            .host_info => .{ .host_info = .{ .store = store } },
            .host_stop => .{ .host_stop = .{ .store = store } },
            .configure => .{ .configure = try self.parseConfigure(store) },
            .message => .{ .message = try self.parseMessage(store) },
            .session_stop => .{ .session_stop = try self.parseSessionStop(store) },
            .model_interruption => .{ .model_interruption = try self.parseModelInterruption(store) },
            .permission_decision => .{ .permission_decision = try self.parsePermissionDecision(store) },
            .observe_command => .{ .observe_command = try self.parseObserve(store) },
            .read_result => .{ .read_result = try self.parseReadResult(store) },
            .read_action_call_id => .{ .read_action_call_id = try self.parseReadActionArguments(store) },
            .read_action_arguments => .{ .read_action_arguments = try self.parseReadActionArguments(store) },
            .inspect_session => .{ .inspect_session = try self.parseInspect(store) },
            .list_sessions => .{ .list_sessions = try self.parseListSessions(store) },
            .conversation_page => .{ .conversation_page = try self.parseConversationPage(store) },
            .conversation_content => .{ .conversation_content = try self.parseConversationContent(store) },
            .proposal_page => .{ .proposal_page = try self.parseProposalPage(store) },
            .proposal_field => .{ .proposal_field = try self.parseProposalField(store) },
            .activity_page => .{ .activity_page = try self.parseActivityPage(store) },
            .activity_content => .{ .activity_content = try self.parseActivityContent(store) },
        };
        errdefer request.removeTemporaryContent(self.options.io) catch unreachable;
        try self.expectByte('}');
        if (!self.source.atEnd()) {
            return error.TrailingInput;
        }
        return request;
    }

    fn parseConfigure(self: *Parser, store: Bounded(max_store_bytes)) !ConfigureCommand {
        var request = ConfigureCommand{ .store = store };
        errdefer request.removeTemporaryContent(self.options.io) catch unreachable;
        try self.expectByte(',');
        try self.expectKey("key");
        try self.readSmallString(&request.key);
        try self.expectByte(',');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        try self.expectByte(',');
        try self.expectKey("configuration");
        request.configuration = try self.parseConfiguration(true);
        if (try self.consumeIf(',')) {
            try self.expectKey("require_model");
            try self.skipWhitespace();
            const first = try self.source.readByte();
            const rest: []const u8 = switch (first) {
                't' => "rue",
                'f' => "alse",
                else => return error.InvalidJsonShape,
            };
            for (rest) |expected| if (try self.source.readByte() != expected) return error.InvalidJsonShape;
            request.require_model = first == 't';
        }
        return request;
    }

    fn parseConfiguration(self: *Parser, allow_content: bool) !Configuration {
        var request: ConfigureCommand = .{};
        errdefer request.removeTemporaryContent(self.options.io) catch unreachable;
        try self.expectByte('{');
        try self.expectKey("workspace");
        try self.readOptionalSmall(max_workspace_bytes, &request.configuration.workspace);
        try self.expectByte(',');
        try self.expectKey("provider");
        try self.readOptionalSmall(max_provider_bytes, &request.configuration.provider);
        try self.expectByte(',');
        try self.expectKey("model");
        try self.readOptionalSmall(max_model_bytes, &request.configuration.model);
        try self.expectByte(',');
        try self.expectKey("instructions");
        try self.readContent(&request.configuration.instructions, false, allow_content);
        try self.expectByte(',');
        try self.expectKey("tools");
        try self.readTools(&request.configuration.tools);
        try self.expectByte(',');
        try self.expectKey("permission_mode");
        try self.readOptionalSmall(16, &request.configuration.permission_mode);
        try self.expectByte(',');
        try self.expectKey("output_schema");
        try self.readContent(&request.configuration.output_schema, true, allow_content);
        var trigger_seen = false;
        var reservation_seen = false;
        var effort_seen = false;
        while (try self.consumeIf(',')) {
            var key: Bounded(32) = .{};
            try self.readSmallString(&key);
            try self.expectByte(':');
            if (key.eql("compaction_trigger") and !trigger_seen) {
                trigger_seen = true;
                try self.readOptionalPolicy(&request.configuration.compaction_trigger);
            } else if (key.eql("output_reservation") and !reservation_seen) {
                reservation_seen = true;
                try self.readOptionalPolicy(&request.configuration.output_reservation);
            } else if (key.eql("reasoning_effort") and !effort_seen) {
                effort_seen = true;
                try self.readOptionalSmallNullable(16, &request.configuration.reasoning_effort, true);
            } else return error.UnexpectedField;
        }
        try self.expectByte('}');
        return request.configuration;
    }

    fn parseMessage(self: *Parser, store: Bounded(max_store_bytes)) !MessageCommand {
        var request = MessageCommand{ .store = store };
        errdefer request.removeTemporaryContent(self.options.io) catch unreachable;
        try self.expectByte(',');
        try self.expectKey("key");
        try self.readSmallString(&request.key);
        try self.expectByte(',');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        try self.expectByte(',');
        try self.expectKey("sender");
        try self.skipWhitespace();
        if (try self.source.readByte() == 'n') {
            for ("ull") |expected| if (try self.source.readByte() != expected) return error.InvalidJsonShape;
        } else {
            self.source.start -= 1;
            request.sender = .{};
            try self.expectByte('{');
            try self.expectKey("store");
            try self.readSmallString(&request.sender.?.store);
            try self.expectByte(',');
            try self.expectKey("session");
            try self.readSmallString(&request.sender.?.session);
            try self.expectByte('}');
            try request.sender.?.validate();
        }
        try self.expectByte(',');
        try self.expectKey("sender_handle");
        try self.skipWhitespace();
        if (try self.source.readByte() == 'n') {
            for ("ull") |expected| if (try self.source.readByte() != expected) return error.InvalidJsonShape;
        } else {
            self.source.start -= 1;
            request.sender_handle = .{};
            try self.readSmallString(&request.sender_handle.?);
        }
        try self.expectByte(',');
        if (request.session.len == 0) {
            try self.expectKey("configuration");
            request.configuration = try self.parseConfiguration(false);
            try self.expectByte(',');
        }
        try self.expectKey("text");
        try self.readContent(&request.text, false, true);
        if (request.text.state != .value) return error.InvalidMessage;
        return request;
    }

    fn parseSessionStop(self: *Parser, store: Bounded(max_store_bytes)) !SessionStopCommand {
        var request = SessionStopCommand{ .store = store };
        try self.expectByte(',');
        try self.expectKey("key");
        try self.readSmallString(&request.key);
        try self.expectByte(',');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        return request;
    }

    fn parseModelInterruption(self: *Parser, store: Bounded(max_store_bytes)) !ModelInterruptionCommand {
        var request = ModelInterruptionCommand{ .store = store };
        try self.expectByte(',');
        try self.expectKey("key");
        try self.readSmallString(&request.key);
        try self.expectByte(',');
        try self.expectKey("target");
        try self.expectByte('{');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        try self.expectByte(',');
        try self.expectKey("turn");
        request.turn_id = try self.readCanonicalU64();
        try self.expectByte(',');
        try self.expectKey("operation");
        request.operation_id = try self.readCanonicalU64();
        try self.expectByte('}');
        return request;
    }

    fn parsePermissionDecision(self: *Parser, store: Bounded(max_store_bytes)) !PermissionDecisionCommand {
        var request = PermissionDecisionCommand{ .store = store };
        try self.expectByte(',');
        try self.expectKey("key");
        try self.readSmallString(&request.key);
        try self.expectByte(',');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        try self.expectByte(',');
        try self.expectKey("action");
        request.action_id = try self.readCanonicalU64();
        try self.expectByte(',');
        try self.expectKey("decision");
        var decision: Bounded(16) = .{};
        try self.readSmallString(&decision);
        request.decision = if (decision.eql("deny"))
            .deny
        else if (decision.eql("allow_once"))
            .allow_once
        else
            return error.UnsupportedPermissionDecision;
        return request;
    }

    fn parseReadActionArguments(self: *Parser, store: Bounded(max_store_bytes)) !ReadActionArguments {
        var request = ReadActionArguments{ .store = store };
        try self.expectByte(',');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        try self.expectByte(',');
        try self.expectKey("action");
        request.action_id = try self.readCanonicalU64();
        return request;
    }

    fn readCanonicalU64(self: *Parser) !u64 {
        try self.expectByte('"');
        var digits: [20]u8 = undefined;
        var used: usize = 0;
        while (true) {
            const byte = try self.source.readByte();
            if (byte == '"') break;
            if (byte < '0' or byte > '9' or used == digits.len) return error.InvalidIdentity;
            digits[used] = byte;
            used += 1;
        }
        if (used == 0 or (used > 1 and digits[0] == '0')) return error.InvalidIdentity;
        return std.fmt.parseInt(u64, digits[0..used], 10) catch error.InvalidIdentity;
    }

    fn parseObserve(self: *Parser, store: Bounded(max_store_bytes)) !ObserveCommand {
        var request = ObserveCommand{ .store = store };
        try self.expectByte(',');
        try self.expectKey("key");
        try self.readSmallString(&request.key);
        return request;
    }

    fn parseInspect(self: *Parser, store: Bounded(max_store_bytes)) !InspectSession {
        var request = InspectSession{ .store = store };
        try self.expectByte(',');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        if (try self.consumeIf(',')) {
            var key: Bounded(32) = .{};
            try self.readSmallString(&key);
            try self.expectByte(':');
            if (key.eql("profile")) {
                var profile: Bounded(16) = .{};
                try self.readSmallString(&profile);
                request.profile = if (profile.eql("full")) .full else return error.UnknownReportProfile;
            } else if (key.eql("failed_response")) {
                var part: Bounded(16) = .{};
                try self.readSmallString(&part);
                const selected = std.meta.stringToEnum(FailedResponsePart, part.slice()) orelse return error.InvalidTarget;
                try self.expectByte(',');
                try self.expectKey("operation");
                const operation = try self.readCanonicalU64();
                try self.expectByte(',');
                try self.expectKey("attempt");
                const ordinal = try self.readCanonicalU64();
                if (operation == 0 or operation > std.math.maxInt(i64) or ordinal == 0 or ordinal > std.math.maxInt(i64)) return error.InvalidTarget;
                request.failed_response = .{ .operation = operation, .attempt = ordinal, .part = selected };
            } else return error.UnexpectedKey;
        }
        return request;
    }

    fn parseListSessions(self: *Parser, store: Bounded(max_store_bytes)) !ListSessions {
        var request = ListSessions{ .store = store };
        try self.expectByte(',');
        try self.expectKey("workspace");
        if (!try self.consumeIf('n')) {
            var workspace: Bounded(max_workspace_bytes) = .{};
            try self.readSmallString(&workspace);
            request.workspace = workspace;
        } else {
            try self.expectByte('u');
            try self.expectByte('l');
            try self.expectByte('l');
        }
        try self.expectByte(',');
        try self.expectKey("after");
        request.after = try self.readCanonicalU64();
        try self.expectByte(',');
        try self.expectKey("ceiling");
        request.ceiling = try self.readCanonicalU64();
        if (request.after > std.math.maxInt(i64) or request.ceiling > std.math.maxInt(i64) or
            (request.after == 0 and request.ceiling != 0) or
            (request.after != 0 and request.after > request.ceiling)) return error.InvalidCursor;
        return request;
    }

    fn parseConversationPage(self: *Parser, store: Bounded(max_store_bytes)) !ConversationPage {
        var request = ConversationPage{ .store = store };
        try self.expectByte(',');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        try self.expectByte(',');
        try self.expectKey("end");
        request.end = try self.readCanonicalU64();
        try self.expectByte(',');
        try self.expectKey("before_position");
        request.before_position = try self.readCanonicalU64();
        try self.expectByte(',');
        try self.expectKey("before_ordinal");
        request.before_ordinal = try self.readCanonicalU64();
        if (request.end > std.math.maxInt(i64) or request.before_position > std.math.maxInt(i64) or
            request.before_ordinal > std.math.maxInt(i64) or
            (request.end == 0 and request.before_position != 0) or
            (request.before_position == 0 and request.before_ordinal != 0) or
            (request.end != 0 and request.before_position > request.end)) return error.InvalidCursor;
        return request;
    }

    fn parseConversationContent(self: *Parser, store: Bounded(max_store_bytes)) !ConversationContent {
        var request = ConversationContent{ .store = store };
        try self.expectByte(',');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        try self.expectByte(',');
        try self.expectKey("position");
        request.position = try self.readCanonicalU64();
        try self.expectByte(',');
        try self.expectKey("ordinal");
        request.ordinal = try self.readCanonicalU64();
        try self.expectByte(',');
        try self.expectKey("start");
        request.start = try self.readCanonicalU64();
        if (try self.consumeIf(',')) {
            try self.expectKey("stream");
            for ("true") |byte| try self.expectByte(byte);
            request.stream = true;
        }
        if (request.position == 0 or request.position > std.math.maxInt(i64) or
            request.ordinal > std.math.maxInt(i64) or (request.stream and request.start != 0)) return error.InvalidCursor;
        return request;
    }

    fn parseProposalPage(self: *Parser, store: Bounded(max_store_bytes)) !ProposalPage {
        var request = ProposalPage{ .store = store };
        try self.expectByte(',');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        try self.expectByte(',');
        try self.expectKey("end");
        if (try self.consumeIf('n')) {
            for ("ull") |byte| try self.expectByte(byte);
        } else request.end = try self.readCanonicalU64();
        try self.expectByte(',');
        try self.expectKey("after");
        request.after = try self.readCanonicalU64();
        try request.validate();
        return request;
    }

    fn parseActivityPage(self: *Parser, store: Bounded(max_store_bytes)) !ActivityPage {
        var request: ActivityPage = .{ .store = store };
        try self.expectByte(',');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        try self.expectByte(',');
        try self.expectKey("end");
        if (try self.consumeIf('n')) {
            for ("ull") |byte| try self.expectByte(byte);
        } else request.end = try self.readCanonicalU64();
        try self.expectByte(',');
        try self.expectKey("position");
        request.position = try self.readCanonicalU64();
        try self.expectByte(',');
        try self.expectKey("ordinal");
        if (try self.consumeIf('n')) {
            for ("ull") |byte| try self.expectByte(byte);
        } else request.ordinal = try self.readCanonicalU64();
        try self.expectByte(',');
        try self.expectKey("direction");
        var direction: Bounded(8) = .{};
        try self.readSmallString(&direction);
        request.direction = std.meta.stringToEnum(@FieldType(ActivityPage, "direction"), direction.slice()) orelse return error.InvalidCursor;
        try request.validate();
        return request;
    }

    fn parseActivityContent(self: *Parser, store: Bounded(max_store_bytes)) !ReadActivityContent {
        var request: ReadActivityContent = .{ .store = store };
        try self.expectByte(',');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        try self.expectByte(',');
        try self.expectKey("position");
        request.position = try self.readCanonicalU64();
        try self.expectByte(',');
        try self.expectKey("ordinal");
        request.ordinal = try self.readCanonicalU64();
        if (request.position == 0 or request.position > std.math.maxInt(i64) or request.ordinal > std.math.maxInt(i64)) return error.InvalidCursor;
        return request;
    }

    fn parseProposalField(self: *Parser, store: Bounded(max_store_bytes)) !ReadProposalField {
        var request = ReadProposalField{ .store = store };
        try self.expectByte(',');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        try self.expectByte(',');
        try self.expectKey("position");
        request.position = try self.readCanonicalU64();
        if (request.position == 0 or request.position > std.math.maxInt(i64)) return error.InvalidCursor;
        try self.expectByte(',');
        try self.expectKey("field");
        var field: Bounded(16) = .{};
        try self.readSmallString(&field);
        request.field = std.meta.stringToEnum(ProposalField, field.slice()) orelse return error.InvalidField;
        return request;
    }

    fn parseReadResult(self: *Parser, store: Bounded(max_store_bytes)) !ReadResult {
        var request = ReadResult{ .store = store };
        try self.expectByte(',');
        try self.expectKey("key");
        try self.readSmallString(&request.key);
        return request;
    }

    fn readOptionalPolicy(self: *Parser, field: *OptionalBounded(20)) !void {
        try self.readOptionalSmallNullable(20, field, true);
    }

    fn readOptionalSmall(self: *Parser, comptime capacity: usize, field: *OptionalBounded(capacity)) !void {
        try self.readOptionalSmallNullable(capacity, field, false);
    }

    fn readOptionalSmallNullable(self: *Parser, comptime capacity: usize, field: *OptionalBounded(capacity), allow_null: bool) !void {
        try self.expectByte('{');
        try self.expectKey("state");
        var state: Bounded(16) = .{};
        try self.readSmallString(&state);
        if (state.eql("omitted")) {
            field.state = .omitted;
        } else if (allow_null and state.eql("null")) {
            field.state = .explicit_null;
        } else if (state.eql("value")) {
            field.state = .value;
            try self.expectByte(',');
            try self.expectKey("value");
            try self.readSmallString(&field.value);
        } else return error.InvalidFieldState;
        try self.expectByte('}');
    }

    fn readContent(self: *Parser, field: *ContentField, allow_null: bool, allow_value: bool) !void {
        try self.expectByte('{');
        try self.expectKey("state");
        var state: Bounded(16) = .{};
        try self.readSmallString(&state);
        if (state.eql("omitted")) {
            field.state = .omitted;
        } else if (allow_null and state.eql("null")) {
            field.state = .explicit_null;
        } else if (state.eql("value")) {
            if (!allow_value) return error.InvalidFieldState;
            field.state = .value;
            try self.expectByte(',');
            try self.expectKey("value");
            try self.readContentString(field);
        } else return error.InvalidFieldState;
        try self.expectByte('}');
    }

    fn readTools(self: *Parser, tools: *ToolsField) !void {
        try self.expectByte('{');
        try self.expectKey("state");
        var state: Bounded(16) = .{};
        try self.readSmallString(&state);
        if (state.eql("omitted")) {
            tools.state = .omitted;
        } else if (state.eql("value")) {
            tools.state = .value;
            try self.expectByte(',');
            try self.expectKey("value");
            try self.expectByte('[');
            if (!try self.consumeIf(']')) {
                var value: Bounded(16) = .{};
                try self.readSmallString(&value);
                if (!value.eql("bash")) return error.UnknownTool;
                tools.values[0] = .bash;
                tools.count = 1;
                try self.expectByte(']');
            }
        } else return error.InvalidFieldState;
        try self.expectByte('}');
    }

    fn readSmallString(self: *Parser, destination: anytype) !void {
        var sink = SmallSink(@TypeOf(destination.*)){ .destination = destination };
        try self.readJsonString(&sink);
        if (!std.unicode.utf8ValidateSlice(destination.slice())) return error.InvalidUtf8;
    }

    fn readContentString(self: *Parser, field: *ContentField) !void {
        self.content_ordinal += 1;
        if (self.captured) |captured| {
            if (self.content_ordinal > captured.len) return error.NeedContent;
            try self.expectByte('"');
            if (try self.source.readByte() != '"') return error.InvalidJsonShape;
            const original = captured[self.content_ordinal - 1];
            // Speculative request disposal has no resource authority.
            field.length = original.length;
            field.digest = original.digest;
            return;
        }
        var capture = try ContentCapture.init(self.options, self.content_ordinal);
        defer capture.deinit();
        try self.readJsonString(&capture.sink);
        const state = field.state;
        field.* = try capture.seal();
        field.state = state;
    }

    fn readJsonString(self: *Parser, sink: anytype) !void {
        try self.expectByte('"');
        var decoder = StringDecoder{};
        while (!try decoder.feed(try self.source.readByte(), sink)) {}
    }

    fn expectKey(self: *Parser, key: []const u8) !void {
        try self.skipWhitespace();
        try self.expectByte('"');
        for (key) |expected| if (try self.source.readByte() != expected) return error.UnexpectedField;
        if (try self.source.readByte() != '"') return error.UnexpectedField;
        try self.expectByte(':');
    }

    fn expectByte(self: *Parser, expected: u8) !void {
        try self.skipWhitespace();
        if (try self.source.readByte() != expected) return error.InvalidJsonShape;
    }

    fn consumeIf(self: *Parser, expected: u8) !bool {
        try self.skipWhitespace();
        const byte = try self.source.readByte();
        if (byte == expected) return true;
        self.source.start -= 1;
        return false;
    }

    fn skipWhitespace(self: *Parser) !void {
        while (true) {
            const byte = try self.source.readByte();
            switch (byte) {
                ' ', '\t', '\r', '\n' => {},
                else => {
                    self.source.start -= 1;
                    return;
                },
            }
        }
    }
};

// Shared by the synchronous metadata grammar and suspended content ingestion.
// The opening quote belongs to the caller; feed consumes through the closing
// quote and never consumes subsequent syntax.
const StringDecoder = struct {
    state: enum { plain, escape, hex, surrogate_slash, surrogate_u } = .plain,
    digits: u3 = 0,
    value: u16 = 0,
    high_surrogate: ?u16 = null,

    fn feed(self: *StringDecoder, byte: u8, sink: anytype) !bool {
        switch (self.state) {
            .plain => switch (byte) {
                '"' => {
                    try sink.endString();
                    return true;
                },
                0...0x1f => return error.InvalidJsonString,
                '\\' => self.state = .escape,
                else => try sink.write(&.{byte}),
            },
            .escape => {
                self.state = .plain;
                switch (byte) {
                    '"', '\\', '/' => try sink.write(&.{byte}),
                    'b' => try sink.write("\x08"),
                    'f' => try sink.write("\x0c"),
                    'n' => try sink.write("\n"),
                    'r' => try sink.write("\r"),
                    't' => try sink.write("\t"),
                    'u' => {
                        self.state = .hex;
                        self.digits = 0;
                        self.value = 0;
                    },
                    else => return error.InvalidJsonEscape,
                }
            },
            .hex => {
                const digit: u16 = std.fmt.charToDigit(byte, 16) catch return error.InvalidUnicodeEscape;
                self.value = self.value * 16 + digit;
                self.digits += 1;
                if (self.digits != 4) return false;
                const codepoint: u21 = if (self.high_surrogate) |high| blk: {
                    if (self.value < 0xdc00 or self.value > 0xdfff) return error.InvalidUnicodeEscape;
                    self.high_surrogate = null;
                    break :blk @intCast(0x10000 + ((@as(u32, high) - 0xd800) << 10) + (@as(u32, self.value) - 0xdc00));
                } else blk: {
                    if (self.value >= 0xd800 and self.value <= 0xdbff) {
                        self.high_surrogate = self.value;
                        self.state = .surrogate_slash;
                        return false;
                    }
                    if (self.value >= 0xdc00 and self.value <= 0xdfff) return error.InvalidUnicodeEscape;
                    break :blk self.value;
                };
                var encoded: [4]u8 = undefined;
                const length = try std.unicode.utf8Encode(codepoint, &encoded);
                try sink.write(encoded[0..length]);
                self.state = .plain;
            },
            .surrogate_slash => {
                if (byte != '\\') return error.InvalidUnicodeEscape;
                self.state = .surrogate_u;
            },
            .surrogate_u => {
                if (byte != 'u') return error.InvalidUnicodeEscape;
                self.state = .hex;
                self.value = 0;
                self.digits = 0;
            },
        }
        return false;
    }
};

const ContentCapture = struct {
    options: ParseOptions,
    path: [max_store_bytes + "/scratch/request-".len + 20 + 1 + 3 + ".tmp".len]u8 = undefined,
    path_len: usize,
    sink: ContentSink,
    writer_open: bool = true,
    sealed: ?std.Io.File = null,
    transferred: bool = false,

    fn init(options: ParseOptions, ordinal: u8) !ContentCapture {
        if (options.content_faults.acquire) return error.InjectedContentAcquireFailure;
        var capture: ContentCapture = undefined;
        var name_buffer: [96]u8 = undefined;
        const name = try named_scratch.NumericName.request.format(&name_buffer, options.request_number, ordinal);
        const path = try std.fmt.bufPrint(&capture.path, "{s}/{s}", .{ options.scratch_path, name });
        const writer = try std.Io.Dir.createFileAbsolute(options.io, path, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        capture.options = options;
        capture.path_len = path.len;
        capture.sink = .{ .io = options.io, .file = writer, .scratch_budget = options.scratch_budget };
        capture.writer_open = true;
        capture.sealed = null;
        capture.transferred = false;
        return capture;
    }

    fn seal(self: *ContentCapture) !ContentField {
        if (self.options.content_faults.write) return error.InjectedContentWriteFailure;
        try self.sink.finish();
        self.sink.file.sync(self.options.io) catch return error.ContentSyncFailed;
        if (self.options.content_faults.seal) return error.InjectedContentSealFailure;
        self.sealed = try std.Io.Dir.openFileAbsolute(self.options.io, self.path[0..self.path_len], .{});
        self.sink.file.close(self.options.io);
        self.writer_open = false;
        try std.Io.Dir.deleteFileAbsolute(self.options.io, self.path[0..self.path_len]);
        self.transferred = true;
        return .{
            .state = .value,
            .file = self.sealed.?,
            .scratch_budget = self.sink.scratch_budget,
            .charged = self.sink.charged,
            .length = self.sink.length,
            .digest = self.sink.hash.finalResult(),
        };
    }

    fn deinit(self: *ContentCapture) void {
        if (self.transferred) return;
        const removed = if (std.Io.Dir.deleteFileAbsolute(self.options.io, self.path[0..self.path_len])) |_| true else |err| switch (err) {
            error.FileNotFound => true,
            else => false,
        };
        if (removed) {
            if (self.writer_open) self.sink.file.close(self.options.io);
            if (self.sealed) |file| file.close(self.options.io);
            if (self.sink.scratch_budget) |budget| budget.release(self.sink.charged);
        } else {
            const retained = self.options.retained_scratch;
            std.debug.assert(retained.* == null);
            retained.* = named_scratch.Owner.init(
                self.options.io,
                if (self.writer_open) self.sink.file else self.sealed.?,
                if (self.writer_open) self.sealed else null,
                std.fs.path.basename(self.path[0..self.path_len]),
                self.sink.scratch_budget,
                self.sink.charged,
                .native,
            );
        }
        self.transferred = true;
    }
};

fn SmallSink(comptime T: type) type {
    return struct {
        destination: *T,

        fn write(self: *@This(), bytes: []const u8) !void {
            if (self.destination.len + bytes.len > self.destination.bytes.len) return error.ValueTooLong;
            @memcpy(self.destination.bytes[self.destination.len..][0..bytes.len], bytes);
            self.destination.len += bytes.len;
        }

        fn endString(_: *@This()) !void {}
    };
}

const ContentSink = struct {
    scratch_budget: ?ScratchBudget = null,
    charged: u64 = 0,
    io: std.Io,
    file: std.Io.File,
    buffer: [content_window_bytes]u8 = undefined,
    used: usize = 0,
    length: u64 = 0,
    hash: std.crypto.hash.sha2.Sha256 = contentHasher(),
    utf8: Utf8State = .{},

    fn write(self: *ContentSink, bytes: []const u8) !void {
        const next_length = std.math.add(u64, self.length, bytes.len) catch return error.ContentTooLarge;
        if (next_length > max_sqlite_content_bytes) return error.ContentTooLarge;
        try self.utf8.feed(bytes);
        self.hash.update(bytes);
        self.length = next_length;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = @min(self.buffer.len - self.used, bytes.len - offset);
            @memcpy(self.buffer[self.used..][0..count], bytes[offset..][0..count]);
            self.used += count;
            offset += count;
            if (self.used == self.buffer.len) try self.flush();
        }
    }

    fn endString(self: *ContentSink) !void {
        if (!self.utf8.complete()) return error.InvalidUtf8;
    }

    fn finish(self: *ContentSink) !void {
        try self.flush();
    }

    fn flush(self: *ContentSink) !void {
        if (self.used == 0) return;
        if (self.scratch_budget) |budget| {
            if (!budget.allocate(self.used)) return error.ScratchCapacityExhausted;
            // A failed streaming write may have written a prefix. Retain the
            // complete submitted increment until this file is safely removed.
            self.charged += self.used;
        }
        try self.file.writeStreamingAll(self.io, self.buffer[0..self.used]);
        self.used = 0;
    }
};

pub const Utf8State = struct {
    bytes: [4]u8 = undefined,
    used: u3 = 0,
    expected: u3 = 0,

    pub fn feed(self: *Utf8State, input: []const u8) !void {
        for (input) |byte| {
            if (self.used == 0) {
                if (byte < 0x80) continue;
                self.expected = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidUtf8;
            }
            self.bytes[self.used] = byte;
            self.used += 1;
            if (self.used == self.expected) {
                _ = std.unicode.utf8Decode(self.bytes[0..self.expected]) catch return error.InvalidUtf8;
                self.used = 0;
                self.expected = 0;
            }
        }
    }

    pub fn complete(self: *const Utf8State) bool {
        return self.used == 0;
    }
};

pub fn maximumJsonStringBytes(input_bytes: usize) usize {
    return 2 + 6 * input_bytes;
}

/// A placeholder in a JSON shape: the argument type it renders and the most
/// bytes that argument can produce.
pub const Hole = union(enum) {
    /// A `bool`.
    boolean,
    /// A `u64` in decimal.
    decimal,
    /// A `?u64` as a quoted decimal or `null`, the spelling of an optional ID.
    optional_id,
    /// A value of this enum, as its bare tag name.
    tag: type,
    /// A `?E` for this enum `E`, as a JSON string of its tag name or `null`.
    optional_tag: type,
    /// At most this many bytes, as a JSON string.
    string: usize,
    /// A `?[]const u8` of at most this many bytes, as a JSON string or `null`.
    optional_string: usize,
    /// At most this many bytes, written unchanged.
    text: usize,
    /// A `[N]u8` of this length, as lowercase hex.
    hex: usize,
    /// A value of, or pointer to, this type, which has `max_json_bytes` and `writeJson`.
    json: type,
    /// A `?T` for this type `T`, as `T` would render it or `null`.
    optional_json: type,

    pub fn maxBytes(comptime hole: Hole) usize {
        return switch (hole) {
            .boolean => "false".len,
            .decimal => std.fmt.count("{d}", .{std.math.maxInt(u64)}),
            .optional_id => @max("null".len, 2 + (comptime Hole.maxBytes(.decimal))),
            .tag => |T| maxTagBytes(T),
            .optional_tag => |T| @max("null".len, 2 + maxTagBytes(T)),
            .string => |bytes| maximumJsonStringBytes(bytes),
            .optional_string => |bytes| @max("null".len, maximumJsonStringBytes(bytes)),
            .text => |bytes| bytes,
            .hex => |bytes| 2 * bytes,
            .json => |T| T.max_json_bytes,
            .optional_json => |T| @max("null".len, T.max_json_bytes),
        };
    }

    fn maxTagBytes(comptime T: type) usize {
        var bytes = 0;
        for (std.meta.tags(T)) |tag| bytes = @max(bytes, @tagName(tag).len);
        return bytes;
    }
};

/// A JSON shape is a tuple of literal JSON text and `Hole`s, in output order.
/// Its renderer writes it with `writeShape` and its bound is `shapeBytes`, so
/// a reply's text and its maximum size have one source.
pub fn shapeBytes(comptime shape: anytype) usize {
    comptime var bytes = 0;
    inline for (shape) |part| bytes += if (comptime isLiteral(part)) part.len else (comptime Hole.maxBytes(part));
    return bytes;
}

/// The largest of a tuple of shapes, for a reply with alternative variants.
pub fn maxShapeBytes(comptime shapes: anytype) usize {
    comptime var bytes = 0;
    inline for (shapes) |shape| bytes = @max(bytes, comptime shapeBytes(shape));
    return bytes;
}

/// Writes `shape` with one argument per hole, in order. A string or text
/// argument longer than its hole is a programmer error.
pub fn writeShape(out: *std.Io.Writer, comptime shape: anytype, args: anytype) !void {
    comptime var next = 0;
    inline for (shape) |part| {
        if (comptime isLiteral(part)) {
            try out.writeAll(part);
        } else {
            const argument = args[next];
            next += 1;
            switch (comptime @as(Hole, part)) {
                .boolean => try out.writeAll(if (@as(bool, argument)) "true" else "false"),
                .decimal => try out.print("{d}", .{@as(u64, argument)}),
                .optional_id => if (@as(?u64, argument)) |id| try out.print("\"{d}\"", .{id}) else try out.writeAll("null"),
                .tag => |T| try out.writeAll(@tagName(@as(T, argument))),
                .optional_tag => |T| if (@as(?T, argument)) |tag| try out.print("\"{s}\"", .{@tagName(tag)}) else try out.writeAll("null"),
                .string => |bytes| {
                    const value: []const u8 = argument;
                    std.debug.assert(value.len <= bytes);
                    try std.json.Stringify.encodeJsonString(value, .{}, out);
                },
                .optional_string => |bytes| if (@as(?[]const u8, argument)) |value| {
                    std.debug.assert(value.len <= bytes);
                    try std.json.Stringify.encodeJsonString(value, .{}, out);
                } else try out.writeAll("null"),
                .text => |bytes| {
                    const value: []const u8 = argument;
                    std.debug.assert(value.len <= bytes);
                    try out.writeAll(value);
                },
                .hex => |bytes| try out.writeAll(&std.fmt.bytesToHex(@as([bytes]u8, argument), .lower)),
                .json => |T| {
                    const value: *const T = if (@TypeOf(argument) == T) &argument else argument;
                    try value.writeJson(out);
                },
                .optional_json => |T| if (@as(?T, argument)) |value| try value.writeJson(out) else try out.writeAll("null"),
            }
        }
    }
    comptime if (next != args.len) @compileError("a JSON shape needs one argument per hole");
}

fn isLiteral(comptime part: anytype) bool {
    return @typeInfo(@TypeOf(part)) == .pointer;
}

// Request shapes. The client writes each request with `writeShape` and each
// bound is `shapeBytes` of the same shape. Store, key and Session holes take
// fully escaped strings because the Host accepts any JSON spelling of them.
const store_hole = Hole{ .string = max_store_bytes };
const key_hole = Hole{ .string = max_key_bytes };
const session_hole = Hole{ .string = max_session_bytes };

/// Holes: Store, key, Session.
pub const session_stop_request = .{ "{\"version\":\"1\",\"kind\":\"session_stop\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, "}" };
/// Holes: Store, key, Session, turn, operation.
pub const model_interruption_request = .{ "{\"version\":\"1\",\"kind\":\"model_interruption\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"target\":{\"session\":", session_hole, ",\"turn\":\"", Hole.decimal, "\",\"operation\":\"", Hole.decimal, "\"}}" };
/// Holes: Store, key, Session, Action, decision.
pub const permission_decision_request = .{ "{\"version\":\"1\",\"kind\":\"permission_decision\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, ",\"action\":\"", Hole.decimal, "\",\"decision\":\"", Hole{ .tag = PermissionDecision }, "\"}" };
/// Holes: Store, key.
pub const observe_command_request = .{ "{\"version\":\"1\",\"kind\":\"observe_command\",\"store\":", store_hole, ",\"key\":", key_hole, "}" };
/// Holes: Store.
pub const host_info_request = .{ "{\"version\":\"1\",\"kind\":\"host_info\",\"store\":", store_hole, "}" };
/// Holes: Store.
pub const host_stop_request = .{ "{\"version\":\"1\",\"kind\":\"host_stop\",\"store\":", store_hole, "}" };
/// Holes: Store, key.
pub const read_result_request = .{ "{\"version\":\"1\",\"kind\":\"read_result\",\"store\":", store_hole, ",\"key\":", key_hole, "}" };
pub const inspect_session_request = struct {
    /// Holes: Store, Session.
    pub const current = .{ "{\"version\":\"1\",\"kind\":\"inspect_session\",\"store\":", store_hole, ",\"session\":", session_hole, "}" };
    /// Holes: Store, Session.
    pub const full = .{ "{\"version\":\"1\",\"kind\":\"inspect_session\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"profile\":\"full\"}" };
    /// Holes: Store, Session, part, operation, attempt.
    pub const failed_response = .{ "{\"version\":\"1\",\"kind\":\"inspect_session\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"failed_response\":\"", Hole{ .tag = FailedResponsePart }, "\",\"operation\":\"", Hole.decimal, "\",\"attempt\":\"", Hole.decimal, "\"}" };
    pub const max_bytes = maxShapeBytes(.{ current, full, failed_response });
};
/// Holes: Store, workspace, after, ceiling.
pub const list_sessions_request = .{ "{\"version\":\"1\",\"kind\":\"list_sessions\",\"store\":", store_hole, ",\"workspace\":", Hole{ .optional_string = max_workspace_bytes }, ",\"after\":\"", Hole.decimal, "\",\"ceiling\":\"", Hole.decimal, "\"}" };
/// Holes: Store, Session, Action.
pub const read_action_arguments_request = .{ "{\"version\":\"1\",\"kind\":\"read_action_arguments\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"action\":\"", Hole.decimal, "\"}" };
/// Holes: Store, Session, Action.
pub const read_action_call_id_request = .{ "{\"version\":\"1\",\"kind\":\"read_action_call_id\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"action\":\"", Hole.decimal, "\"}" };
/// Holes: Store, Session, position, ordinal. The client always streams from
/// the start.
pub const conversation_content_request = .{ "{\"version\":\"1\",\"kind\":\"conversation_content\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"position\":\"", Hole.decimal, "\",\"ordinal\":\"", Hole.decimal, "\",\"start\":\"0\",\"stream\":true}" };
/// Holes: Store, Session, end, before position, before ordinal.
pub const conversation_page_request = .{ "{\"version\":\"1\",\"kind\":\"conversation_page\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"end\":\"", Hole.decimal, "\",\"before_position\":\"", Hole.decimal, "\",\"before_ordinal\":\"", Hole.decimal, "\"}" };
/// Holes: Store, Session, end, after.
pub const proposal_page_request = .{ "{\"version\":\"1\",\"kind\":\"proposal_page\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"end\":", Hole.optional_id, ",\"after\":\"", Hole.decimal, "\"}" };
/// Holes: Store, Session, position, field.
pub const proposal_field_request = .{ "{\"version\":\"1\",\"kind\":\"proposal_field\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"position\":\"", Hole.decimal, "\",\"field\":\"", Hole{ .tag = ProposalField }, "\"}" };
/// Holes: Store, Session, end, position, ordinal, direction.
pub const activity_page_request = .{ "{\"version\":\"1\",\"kind\":\"activity_page\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"end\":", Hole.optional_id, ",\"position\":\"", Hole.decimal, "\",\"ordinal\":", Hole.optional_id, ",\"direction\":\"", Hole{ .tag = @FieldType(ActivityPage, "direction") }, "\"}" };
/// Holes: Store, Session, position, ordinal.
pub const activity_content_request = .{ "{\"version\":\"1\",\"kind\":\"activity_content\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"position\":\"", Hole.decimal, "\",\"ordinal\":\"", Hole.decimal, "\"}" };
/// Configure and Message carry content of unbounded size, so only their
/// metadata has a shape. The variable parts are written between these.
pub const configure_request = struct {
    /// Holes: Store, key, Session. The configuration object follows.
    pub const head = .{ "{\"version\":\"1\",\"kind\":\"configure\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, ",\"configuration\":" };
    pub const tail = .{"}"};
    pub const require_model_tail = .{",\"require_model\":true}"};
};
pub const message_request = struct {
    /// Holes: Store, key, Session, sender handle.
    pub const head = .{ "{\"version\":\"1\",\"kind\":\"message\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, ",\"sender\":null,\"sender_handle\":", Hole{ .optional_string = max_sender_handle_bytes } };
    /// Holes: Store, key, Session, sender Store, sender Session, sender handle.
    pub const sender_head = .{ "{\"version\":\"1\",\"kind\":\"message\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, ",\"sender\":{\"store\":", store_hole, ",\"session\":", session_hole, "},\"sender_handle\":", Hole{ .optional_string = max_sender_handle_bytes } };
    /// The configuration object of a creating Message follows.
    pub const configuration = .{",\"configuration\":"};
    /// The text, as a JSON string, follows.
    pub const text = .{",\"text\":{\"state\":\"value\",\"value\":"};
    pub const tail = .{"}}"};
};

pub const max_session_stop_request_bytes = shapeBytes(session_stop_request);
pub const max_model_interruption_request_bytes = shapeBytes(model_interruption_request);
pub const max_permission_decision_request_bytes = shapeBytes(permission_decision_request);
pub const max_control_request_bytes = maxShapeBytes(.{ session_stop_request, model_interruption_request, permission_decision_request });
pub const max_observe_command_request_bytes = shapeBytes(observe_command_request);
pub const max_host_info_request_bytes = shapeBytes(host_info_request);
pub const max_host_stop_request_bytes = shapeBytes(host_stop_request);
pub const max_read_result_request_bytes = shapeBytes(read_result_request);
pub const max_inspect_session_request_bytes = inspect_session_request.max_bytes;
pub const max_list_sessions_request_bytes = shapeBytes(list_sessions_request);
pub const max_read_action_arguments_request_bytes = shapeBytes(read_action_arguments_request);
pub const max_read_action_call_id_request_bytes = shapeBytes(read_action_call_id_request);
pub const max_conversation_content_request_bytes = shapeBytes(conversation_content_request);
pub const max_conversation_page_request_bytes = shapeBytes(conversation_page_request);
pub const max_proposal_page_request_bytes = shapeBytes(proposal_page_request);
pub const max_proposal_field_request_bytes = shapeBytes(proposal_field_request);
pub const max_activity_page_request_bytes = shapeBytes(activity_page_request);
pub const max_activity_content_request_bytes = shapeBytes(activity_content_request);
/// Every request the client writes into a `RequestBuffer`. Control requests
/// are captured to a record file instead.
pub const max_client_request_bytes = @max(max_inspect_session_request_bytes, maxShapeBytes(.{
    observe_command_request,     host_info_request,            host_stop_request,
    read_result_request,         list_sessions_request,        read_action_arguments_request,
    read_action_call_id_request, conversation_content_request, conversation_page_request,
    proposal_page_request,       proposal_field_request,       activity_page_request,
    activity_content_request,
}));

/// Separated by commas, `count` JSON values of at most `item_bytes` each.
pub fn jsonListBytes(comptime count: usize, comptime item_bytes: usize) usize {
    return count * item_bytes + count -| 1;
}

/// A Message or answer's content reference in an observation. Holes: length, digest.
pub const content_reference_shape = .{ "{\"type\":\"text\",\"bytes\":\"", Hole.decimal, "\",\"sha256\":\"", Hole{ .hex = 32 }, "\"}" };

pub const proposal_page_reply = struct {
    /// Hole: the page end.
    pub const head = .{ "{\"version\":\"1\",\"type\":\"proposal_page\",\"end\":\"", Hole.decimal, "\",\"items\":[" };
    /// Holes: position, operation, turn, call ordinal, Action and rejection.
    pub const item_head = .{ "{\"position\":\"", Hole.decimal, "\",\"operation\":\"", Hole.decimal, "\",\"turn\":\"", Hole.decimal, "\",\"call_ordinal\":\"", Hole.decimal, "\",\"action\":", Hole.optional_id, ",\"rejection\":", Hole{ .optional_tag = ProposalRejection }, ",\"fields\":{" };
    /// One field's reference, in `ProposalField` order. Holes: length, digest.
    pub fn field(comptime name: ProposalField) struct { []const u8, Hole, []const u8, Hole, []const u8 } {
        const separator = if (name == std.meta.tags(ProposalField)[0]) "" else ",";
        return .{ separator ++ "\"" ++ @tagName(name) ++ "\":{\"bytes\":\"", .decimal, "\",\"sha256\":\"", .{ .hex = 32 }, "\"}" };
    }
    pub const item_end = .{"}}"};
    /// Hole: whether more items follow.
    pub const tail = .{ "],\"more\":", Hole.boolean, "}" };
};

pub const max_proposal_page_response_bytes = blk: {
    const page = proposal_page_reply;
    var item = shapeBytes(page.item_head) + shapeBytes(page.item_end);
    for (std.meta.tags(ProposalField)) |name| item += shapeBytes(page.field(name));
    break :blk shapeBytes(page.head) + jsonListBytes(proposal_page_items, item) + shapeBytes(page.tail);
};

pub const max_activity_page_response_bytes = ActivityFacts.max_json_bytes;

pub const configuration_reply = struct {
    const head = "{\"version\":\"1\",\"type\":\"configuration_reply\",\"answer\":{\"status\":";
    const execution = "},\"execution\":{\"status\":\"unavailable\",\"reason\":\"direct_reply_does_not_wait_for_model_processing\"}}";
    /// Holes: replayed, Session, revision, created.
    pub const accepted = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"revision\":\"", Hole.decimal, "\",\"created\":", Hole.boolean, execution };
    /// Holes: replayed, Session, code.
    pub const rejected = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"", Hole{ .tag = ConfigurationRejection }, "\"" ++ execution };
    /// Hole: Session.
    pub const conflict = .{ head ++ "\"conflict\",\"replayed\":false,\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"idempotency_key_conflict\"" ++ execution };
    pub const max_bytes = maxShapeBytes(.{ accepted, rejected, conflict });
};

pub const message_reply = struct {
    const head = "{\"version\":\"1\",\"type\":\"message_reply\",\"answer\":{\"status\":";
    const execution = ",\"execution\":{\"status\":\"queued\"}}";
    /// Holes: replayed, Session, admission, input length and digest, admission.
    pub const accepted = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"admission\":\"", Hole.decimal, "\"},\"input\":" } ++
        content_reference_shape ++ .{ ",\"queue\":{\"status\":\"queued\",\"admission\":\"", Hole.decimal, "\"}" ++ execution };
    /// Holes: replayed, Session, code, input length and digest.
    pub const rejected = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"", Hole{ .tag = MessageRejection }, "\"},\"input\":" } ++
        content_reference_shape ++ .{execution};
    /// Hole: Session.
    pub const conflict = .{ head ++ "\"conflict\",\"replayed\":false,\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"idempotency_key_conflict\"}" ++ execution };
    pub const max_bytes = maxShapeBytes(.{ accepted, rejected, conflict });
};

pub const session_stop_reply = struct {
    const head = "{\"version\":\"1\",\"type\":\"session_stop_reply\",\"answer\":{\"status\":";
    /// Holes: replayed, Session, selected Turn, admission cutoff, completion.
    pub const accepted = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"selection\":{\"turn\":", Hole.optional_id, ",\"admission_cutoff\":\"", Hole.decimal, "\"}},\"completion\":{\"status\":\"", Hole{ .tag = SessionStopCompletion }, "\"}}" };
    /// Holes: replayed, Session, code.
    pub const rejected = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"", Hole{ .tag = SessionStopRejection }, "\"},\"completion\":{\"status\":\"unavailable\"}}" };
    /// Hole: Session.
    pub const conflict = .{ head ++ "\"conflict\",\"replayed\":false,\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"idempotency_key_conflict\"},\"completion\":{\"status\":\"unavailable\"}}" };
    pub const max_bytes = maxShapeBytes(.{ accepted, rejected, conflict });
};

/// Holes: Session, Turn, Operation.
pub const model_interruption_target_shape = .{ "{\"session\":", Hole{ .string = max_session_bytes }, ",\"turn\":\"", Hole.decimal, "\",\"operation\":\"", Hole.decimal, "\"}" };

pub const model_interruption_reply = struct {
    const head = "{\"version\":\"1\",\"type\":\"model_interruption_reply\",\"answer\":{\"status\":";
    /// Holes: replayed, then the target's.
    pub const accepted = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean, ",\"target\":" } ++ model_interruption_target_shape ++ .{"}}"};
    /// Holes: replayed, the target's, code.
    pub const rejected = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean, ",\"target\":" } ++ model_interruption_target_shape ++ .{ ",\"code\":\"", Hole{ .tag = ModelInterruptionRejection }, "\"}}" };
    /// Holes: the target's.
    pub const conflict = .{head ++ "\"conflict\",\"replayed\":false,\"target\":"} ++ model_interruption_target_shape ++ .{",\"code\":\"idempotency_key_conflict\"}}"};
    pub const max_bytes = maxShapeBytes(.{ accepted, rejected, conflict });
};

pub const permission_decision_reply = struct {
    const head = "{\"version\":\"1\",\"type\":\"permission_decision_reply\",\"answer\":{\"status\":";
    const target = .{ ",\"session\":", Hole{ .string = max_session_bytes }, ",\"action\":\"", Hole.decimal, "\",\"decision\":\"", Hole{ .tag = PermissionDecision }, "\"" };
    /// Holes: replayed, Session, Action, decision.
    pub const accepted = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean } ++ target ++ .{"}}"};
    /// Holes: replayed, Session, Action, decision, code.
    pub const rejected = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean } ++ target ++ .{ ",\"code\":\"", Hole{ .tag = PermissionDecisionRejection }, "\"}}" };
    /// Holes: Session, Action, decision.
    pub const conflict = .{head ++ "\"conflict\",\"replayed\":false"} ++ target ++ .{",\"code\":\"idempotency_key_conflict\"}}"};
    pub const max_bytes = maxShapeBytes(.{ accepted, rejected, conflict });
};

/// One command's observation. A reply is `absent`, or `head`, then `code`
/// when the command has one, then its kind's parts, then `tail`.
pub const command_observation_reply = struct {
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":";
    /// Hole: key.
    pub const absent = .{ prefix, Hole{ .string = max_key_bytes }, ",\"observation\":{\"status\":\"absent\"}}" };
    /// Holes: key, status, target Session.
    pub fn head(comptime kind: CommandKind) struct { []const u8, Hole, []const u8, Hole, []const u8, Hole } {
        return .{ prefix, .{ .string = max_key_bytes }, ",\"observation\":{\"status\":\"", .{ .tag = CommandObservationStatus }, "\",\"kind\":\"" ++ @tagName(kind) ++ "\",\"target\":", .{ .string = max_session_bytes } };
    }
    /// Hole: code.
    pub const code = .{ ",\"code\":", Hole{ .string = max_code_bytes } };
    /// An accepted configuration. Holes: revision, created.
    pub const revision = .{ ",\"revision\":\"", Hole.decimal, "\",\"created\":", Hole.boolean };
    /// A Message's input reference. Holes: its length and digest.
    pub const input = .{",\"input\":"} ++ content_reference_shape;
    // Holes: the Attempt binding's Turn, Operation and Attempt.
    const binding = .{ ",\"processing\":{\"turn\":\"", Hole.decimal, "\",\"operation\":\"", Hole.decimal, "\",\"attempt\":\"", Hole.decimal, "\"}" };
    /// Queue states. Holes: admission, then the binding's, then the result's.
    pub const queued = .{ ",\"queue\":{\"status\":\"queued\",\"admission\":\"", Hole.decimal, "\"}" };
    pub const excluded = .{ ",\"queue\":{\"status\":\"excluded\",\"admission\":\"", Hole.decimal, "\"},\"result\":{\"status\":\"cancelled\",\"code\":", Hole{ .string = max_code_bytes }, "}" };
    pub const processing = .{ ",\"queue\":{\"status\":\"processing\",\"admission\":\"", Hole.decimal, "\"}" } ++ binding;
    pub const completed = .{ ",\"queue\":{\"status\":\"completed\",\"admission\":\"", Hole.decimal, "\"}" } ++ binding ++
        .{",\"result\":{\"status\":\"completed\",\"text\":"} ++ content_reference_shape ++ .{"}"};
    pub const cancelled = .{ ",\"queue\":{\"status\":\"cancelled\",\"admission\":\"", Hole.decimal, "\"}" } ++ binding ++
        .{ ",\"result\":{\"status\":\"cancelled\",\"code\":", Hole{ .string = max_code_bytes }, "}" };
    pub const failed = .{ ",\"queue\":{\"status\":\"failed\",\"admission\":\"", Hole.decimal, "\"}" } ++ binding ++
        .{ ",\"result\":{\"status\":\"failed\",\"code\":", Hole{ .string = max_code_bytes }, "}" };
    /// A queued Message's progress. Holes: status, Action.
    pub const progress = .{ ",\"progress\":{\"status\":\"", Hole{ .tag = MessageProgressStatus }, "\",\"action\":", Hole.optional_id, "}" };
    /// Holes: selected Turn, admission cutoff, completion.
    pub const session_stop = .{ ",\"selection\":{\"turn\":", Hole.optional_id, ",\"admission_cutoff\":\"", Hole.decimal, "\"},\"completion\":{\"status\":\"", Hole{ .tag = SessionStopCompletion }, "\"}" };
    /// Holes: the interruption target's.
    pub const model_interruption = .{",\"interruption_target\":"} ++ model_interruption_target_shape;
    /// Holes: Action, decision.
    pub const permission_decision = .{ ",\"permission_target\":{\"action\":\"", Hole.decimal, "\",\"decision\":\"", Hole{ .tag = PermissionDecision }, "\"}" };
    pub const tail = .{"}}"};

    /// The largest observation of this kind.
    pub fn maxBytes(comptime kind: CommandKind) usize {
        const body = switch (kind) {
            .configure => shapeBytes(revision),
            .message => shapeBytes(input) + maxShapeBytes(.{ queued, excluded, processing, completed, cancelled, failed }) + shapeBytes(progress),
            .session_stop => shapeBytes(session_stop),
            .model_interruption => shapeBytes(model_interruption),
            .permission_decision => shapeBytes(permission_decision),
        };
        return shapeBytes(head(kind)) + shapeBytes(code) + body + shapeBytes(tail);
    }

    pub const max_bytes = blk: {
        var bytes = shapeBytes(absent);
        for (std.meta.tags(CommandKind)) |kind| bytes = @max(bytes, maxBytes(kind));
        break :blk bytes;
    };
};

/// Holes: error type and code.
/// The `type` of an error reply: what kind of failure its code names.
pub const ErrorType = enum { invocation_error, observation_error, busy, unsupported, host_unavailable, result_unavailable, action_unavailable, conversation_unavailable, activity_unavailable, proposal_unavailable, failed_response_unavailable };
pub const error_reply = .{ "{\"version\":\"1\",\"type\":\"", Hole{ .tag = ErrorType }, "\",\"code\":", Hole{ .string = max_code_bytes }, "}" };
pub const max_control_error_response_bytes = shapeBytes(error_reply);

pub const max_control_response_bytes = @max(
    @max(@max(configuration_reply.max_bytes, message_reply.max_bytes), @max(session_stop_reply.max_bytes, model_interruption_reply.max_bytes)),
    @max(@max(permission_decision_reply.max_bytes, command_observation_reply.max_bytes), max_control_error_response_bytes),
);

/// Holes: Store, instance, Active and intake capacity, descriptor limit
/// (decimal or `unlimited`), model and managed authentication capabilities.
pub const host_info_reply = .{ "{\"version\":\"1\",\"type\":\"host_info\",\"store\":", Hole{ .string = max_store_bytes }, ",\"instance\":\"", Hole{ .hex = @typeInfo(InstanceId).array.len }, "\",\"active_capacity\":\"", Hole.decimal, "\",\"intake_capacity\":\"", Hole.decimal, "\",\"descriptor_limit\":\"", Hole{ .text = Hole.maxBytes(.decimal) }, "\",\"capabilities\":{\"bash\":true,\"model\":", Hole.boolean, ",\"managed_authentication\":", Hole.boolean, "}}" };
pub const max_host_info_response_bytes = shapeBytes(host_info_reply);
pub const host_stop_ack = "{\"version\":\"1\",\"type\":\"host_stop_reply\",\"status\":\"acknowledged\"}";
// Only bounded replies and errors use this resident buffer. Complete reports
// and result content use their independent streamed delivery paths.
pub const max_response_bytes = @max(@max(max_control_response_bytes, max_host_info_response_bytes), host_stop_ack.len);

pub const conversation_page_reply = struct {
    /// Hole: the page end.
    pub const head = .{ "{\"version\":\"1\",\"type\":\"conversation_page\",\"direction\":\"newest_first\",\"end\":\"", Hole.decimal, "\",\"items\":[" };
    /// Holes: position, ordinal, content length and digest.
    pub fn item(comptime kind: ConversationItemKind) struct { []const u8, Hole, []const u8, Hole, []const u8, Hole, []const u8, Hole, []const u8 } {
        return .{ "{\"position\":\"", .decimal, "\",\"ordinal\":\"", .decimal, "\",\"kind\":\"" ++ @tagName(kind) ++ "\",\"content\":{\"bytes\":\"", .decimal, "\",\"sha256\":\"", .{ .hex = 32 }, "\",\"display\":\"omitted\"}" };
    }
    /// A User item's admission. Holes: second, sending peer.
    pub const admission = .{ ",\"admitted_at\":\"", Hole.decimal, "\",\"sender\":", Hole{ .optional_json = Peer } };
    /// A Tool Result item's presentation. Hole: it.
    pub const presentation = .{ ",\"presentation\":", Hole{ .json = ToolPresentation } };
    pub const item_end = .{"}"};

    /// The largest item of this kind, with what only that kind carries.
    pub fn itemBytes(comptime kind: ConversationItemKind) usize {
        const extra = switch (kind) {
            .user => shapeBytes(admission),
            .tool_result => shapeBytes(presentation),
            .assistant => 0,
        };
        return shapeBytes(item(kind)) + extra + shapeBytes(item_end);
    }
    pub const last = .{"],\"more\":false}"};
    /// Holes: the last item's position and ordinal.
    pub const more = .{ "],\"more\":true,\"before_position\":\"", Hole.decimal, "\",\"before_ordinal\":\"", Hole.decimal, "\"}" };
};

pub const max_conversation_page_response_bytes = blk: {
    const page = conversation_page_reply;
    var item = 0;
    for (std.meta.tags(ConversationItemKind)) |kind| item = @max(item, page.itemBytes(kind));
    break :blk shapeBytes(page.head) + jsonListBytes(public_conversation_page_items, item) + maxShapeBytes(.{ page.last, page.more });
};

pub fn FixedJsonBuffer(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn append(self: *@This(), value: []const u8) !void {
            if (self.len + value.len > self.bytes.len) return error.BufferTooLarge;
            @memcpy(self.bytes[self.len..][0..value.len], value);
            self.len += value.len;
        }

        pub fn appendFmt(self: *@This(), comptime format: []const u8, args: anytype) !void {
            const value = std.fmt.bufPrint(self.bytes[self.len..], format, args) catch
                return error.BufferTooLarge;
            self.len += value.len;
        }

        pub fn appendShape(self: *@This(), comptime shape: anytype, args: anytype) !void {
            var writer = std.Io.Writer.fixed(self.bytes[self.len..]);
            defer self.len += writer.end;
            writeShape(&writer, shape, args) catch return error.BufferTooLarge;
        }

        pub fn appendJsonString(self: *@This(), value: []const u8) !void {
            var writer = std.Io.Writer.fixed(self.bytes[self.len..]);
            defer self.len += writer.end;
            std.json.Stringify.encodeJsonString(value, .{}, &writer) catch return error.BufferTooLarge;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const RequestBuffer = FixedJsonBuffer(max_client_request_bytes);
pub const ResponseBuffer = FixedJsonBuffer(max_response_bytes);

test "semantic digest distinguishes omission, null, and value" {
    var omitted = ConfigureCommand{};
    try omitted.session.set("s");
    var null_schema = omitted;
    null_schema.configuration.output_schema.state = .explicit_null;
    var value_schema = omitted;
    value_schema.configuration.output_schema.state = .value;
    value_schema.configuration.output_schema.digest = @splat(1);
    try std.testing.expect(!std.mem.eql(u8, &omitted.semanticDigest(), &null_schema.semanticDigest()));
    try std.testing.expect(!std.mem.eql(u8, &null_schema.semanticDigest(), &value_schema.semanticDigest()));
    var efforts: [4]ConfigureCommand = @splat(omitted);
    efforts[1].configuration.reasoning_effort.state = .explicit_null;
    efforts[2].configuration.reasoning_effort.state = .value;
    try efforts[2].configuration.reasoning_effort.value.set("none");
    efforts[3].configuration.reasoning_effort.state = .value;
    try efforts[3].configuration.reasoning_effort.value.set("high");
    for (efforts, 0..) |command, index| {
        for (efforts[0..index]) |previous|
            try std.testing.expect(!std.mem.eql(u8, &command.semanticDigest(), &previous.semanticDigest()));
    }
}

test "Request Store borrow remains in its active union payload" {
    var requests = [_]Request{
        .{ .configure = .{} },
        .{ .message = .{} },
        .{ .session_stop = .{} },
        .{ .model_interruption = .{} },
        .{ .observe_command = .{} },
        .{ .read_result = .{} },
        .{ .inspect_session = .{} },
    };
    for (&requests) |*request| switch (request.*) {
        inline else => |*payload| {
            try payload.store.set("x");
            const borrowed = request.store();
            try std.testing.expect(
                @intFromPtr(borrowed.ptr) == @intFromPtr(&payload.store.bytes[0]),
            );
            payload.store.bytes[0] = 'y';
            try std.testing.expectEqualStrings("y", borrowed);
        },
    };
}

test "captured content cleanup closes sealed custody" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "content", .{ .read = true });
    var content: ContentField = .{ .state = .value, .file = file };
    try removeContent(&content, std.testing.io);
    try std.testing.expect(!content.hasFile());
}

test "configuration content sealing peaks at four descriptors with its socket" {
    const Probe = struct {
        var live_files: usize = 0;
        var maximum_live_files: usize = 0;
        var directory_opens: usize = 0;

        fn createFile(
            userdata: ?*anyopaque,
            dir: std.Io.Dir,
            path: []const u8,
            options: std.Io.Dir.CreateFileOptions,
        ) std.Io.File.OpenError!std.Io.File {
            const file = try std.testing.io.vtable.dirCreateFile(userdata, dir, path, options);
            live_files += 1;
            maximum_live_files = @max(maximum_live_files, live_files);
            return file;
        }

        fn openFile(
            userdata: ?*anyopaque,
            dir: std.Io.Dir,
            path: []const u8,
            options: std.Io.Dir.OpenFileOptions,
        ) std.Io.File.OpenError!std.Io.File {
            const file = try std.testing.io.vtable.dirOpenFile(userdata, dir, path, options);
            live_files += 1;
            maximum_live_files = @max(maximum_live_files, live_files);
            return file;
        }

        fn closeFiles(userdata: ?*anyopaque, files: []const std.Io.File) void {
            std.debug.assert(live_files >= files.len);
            live_files -= files.len;
            std.testing.io.vtable.fileClose(userdata, files);
        }

        fn openDir(
            userdata: ?*anyopaque,
            dir: std.Io.Dir,
            path: []const u8,
            options: std.Io.Dir.OpenOptions,
        ) std.Io.Dir.OpenError!std.Io.Dir {
            directory_opens += 1;
            return std.testing.io.vtable.dirOpenDir(userdata, dir, path, options);
        }
    };
    Probe.live_files = 0;
    Probe.maximum_live_files = 0;
    Probe.directory_opens = 0;

    var vtable = std.testing.io.vtable.*;
    vtable.dirCreateFile = Probe.createFile;
    vtable.dirOpenFile = Probe.openFile;
    vtable.fileClose = Probe.closeFiles;
    vtable.dirOpenDir = Probe.openDir;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    var retained: ?named_scratch.Owner = null;
    const json = "\"instructions\"\"schema\"";
    var source = SocketBody.init(-1, 0);
    @memcpy(source.buffer[0..json.len], json);
    source.end = json.len;
    var parser = Parser{ .source = &source, .options = .{
        .io = io,
        .fd = -1,
        .content_length = json.len,
        .scratch_path = root[0..root_len],
        .request_number = 1,
        .retained_scratch = &retained,
    } };
    var instructions = ContentField{};
    errdefer removeContent(&instructions, io) catch unreachable;
    var output_schema = ContentField{};
    errdefer removeContent(&output_schema, io) catch unreachable;
    try parser.readContentString(&instructions);
    try parser.readContentString(&output_schema);
    try std.testing.expectEqual(@as(usize, 4), 1 + Probe.maximum_live_files);
    try std.testing.expectEqual(@as(usize, 0), Probe.directory_opens);
    try removeContent(&output_schema, io);
    try removeContent(&instructions, io);
    try std.testing.expectEqual(@as(usize, 0), Probe.live_files);
}

test "content sink enforces the decoded consumer boundary before retention" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "content", .{});
    defer file.close(std.testing.io);

    var escaped = ContentSink{ .io = std.testing.io, .file = file };
    escaped.length = max_sqlite_content_bytes - 1;
    try escaped.write("\n");
    try std.testing.expectEqual(max_sqlite_content_bytes, escaped.length);
    try std.testing.expectError(error.ContentTooLarge, escaped.write("x"));
    try escaped.finish();
    try std.testing.expectEqual(@as(u64, 1), try file.length(std.testing.io));

    var multibyte = ContentSink{ .io = std.testing.io, .file = file };
    multibyte.length = max_sqlite_content_bytes - 3;
    try multibyte.write("€");
    try std.testing.expectEqual(max_sqlite_content_bytes, multibyte.length);
    try std.testing.expectError(error.ContentTooLarge, multibyte.write("x"));
}
test "fixed JSON buffers preserve control bytes and enforce capacity" {
    var response: ResponseBuffer = .{};
    try response.appendJsonString("\x00\x1f\"\\\n\r\t\x08\x0c\xc3\xa9");
    try std.testing.expectEqualStrings("\"\\u0000\\u001f\\\"\\\\\\n\\r\\t\\b\\f\xc3\xa9\"", response.slice());
    response.len = response.bytes.len - 2;
    try response.appendJsonString("");
    try std.testing.expectEqual(response.bytes.len, response.len);
    try std.testing.expectError(error.BufferTooLarge, response.appendJsonString("x"));
}
test "ingress charges decoded growth and transfers file charge through cleanup" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root);
    var used = std.atomic.Value(u64).init(0);
    var retained: ?named_scratch.Owner = null;
    for ([_][]const u8{ "\"abc\"", "\"\\u0061\\u0062\\u0063\"" }, 0..) |json, ordinal| {
        var source = SocketBody.init(-1, 0);
        @memcpy(source.buffer[0..json.len], json);
        source.end = json.len;
        var parser = Parser{ .source = &source, .options = .{
            .io = io,
            .fd = -1,
            .content_length = 999999,
            .scratch_path = root[0..n],
            .request_number = ordinal,
            .retained_scratch = &retained,
            .scratch_budget = .{ .used = &used, .limit = 3 },
        } };
        var field = ContentField{};
        try parser.readContentString(&field);
        try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
        try std.testing.expectEqual(@as(u64, 3), field.length);
        try removeContent(&field, io);
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    }
    const file = try tmp.dir.createFile(io, "bounded", .{});
    defer file.close(io);
    var sink = ContentSink{ .io = io, .file = file, .scratch_budget = .{ .used = &used, .limit = 3 } };
    try sink.write("abcd");
    try std.testing.expectError(error.ScratchCapacityExhausted, sink.finish());
    try std.testing.expectEqual(@as(u64, 0), try file.length(io));
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "failed ingress unlink retains an actionable owner and only the affected charge" {
    const FailDelete = struct {
        fn delete(_: ?*anyopaque, _: std.Io.Dir, _: []const u8) std.Io.Dir.DeleteFileError!void {
            return error.AccessDenied;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root);
    var used = std.atomic.Value(u64).init(0);
    var vtable = io.vtable.*;
    vtable.dirDeleteFile = FailDelete.delete;
    const failing_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var retained: ?named_scratch.Owner = null;
    const json = "\"abc\"";
    var source = SocketBody.init(-1, 0);
    @memcpy(source.buffer[0..json.len], json);
    source.end = json.len;
    var parser = Parser{ .source = &source, .options = .{
        .io = failing_io,
        .fd = -1,
        .content_length = json.len,
        .scratch_path = root[0..n],
        .request_number = 1,
        .retained_scratch = &retained,
        .scratch_budget = .{ .used = &used, .limit = 8 },
    } };
    const good_file = try tmp.dir.createFile(io, "good", .{});
    try good_file.writeStreamingAll(io, "ok");
    try tmp.dir.deleteFile(io, "good");
    const budget = ScratchBudget{ .used = &used, .limit = 8 };
    try std.testing.expect(budget.charge(2));
    var good_field = ContentField{ .file = good_file, .scratch_budget = budget, .charged = 2 };
    var field = ContentField{};
    try std.testing.expectError(error.AccessDenied, parser.readContentString(&field));
    try std.testing.expect(!field.hasFile());
    try std.testing.expectEqual(@as(u64, 5), used.load(.acquire));
    try removeContent(&good_field, io);
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3), (try tmp.dir.statFile(io, "request-1-1.tmp", .{})).size);
    try std.testing.expect(retained != null);
    try std.testing.expectError(error.AccessDenied, retained.?.reclaim(root[0..n]));
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
    vtable.dirDeleteFile = io.vtable.dirDeleteFile;
    try std.testing.expectEqual(named_scratch.Reclamation.removed, try retained.?.reclaim(root[0..n]));
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "request-1-1.tmp", .{}));
}

test "ingress unknown write failure keeps submitted charge until close" {
    const FailWrite = struct {
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_write_streaming) return .{ .file_write_streaming = error.NoSpaceLeft };
            return std.testing.io.vtable.operate(userdata, operation);
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "failed", .{});
    var used = std.atomic.Value(u64).init(0);
    var vtable = io.vtable.*;
    vtable.operate = FailWrite.operate;
    const failing_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var sink = ContentSink{ .io = failing_io, .file = file, .scratch_budget = .{ .used = &used, .limit = 3 } };
    try sink.write("abc");
    try std.testing.expectError(error.NoSpaceLeft, sink.finish());
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
    try tmp.dir.deleteFile(io, "failed");
    var field = ContentField{ .file = file, .scratch_budget = sink.scratch_budget, .charged = sink.charged };
    try removeContent(&field, io);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "observation needs no scratch at a full budget" {
    const json = "{\"version\":\"1\",\"kind\":\"observe_command\",\"store\":\"store\",\"key\":\"key\"}";
    var source = SocketBody.init(-1, 0);
    @memcpy(source.buffer[0..json.len], json);
    source.end = json.len;
    var used = std.atomic.Value(u64).init(3);
    var retained: ?named_scratch.Owner = null;
    var parser = Parser{ .source = &source, .options = .{
        .io = std.testing.io,
        .fd = -1,
        .content_length = json.len,
        .scratch_path = "unused",
        .request_number = 0,
        .retained_scratch = &retained,
        .scratch_budget = .{ .used = &used, .limit = 3 },
    } };
    const request = try parser.parse();
    try std.testing.expect(request == .observe_command);
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
}

test "Conversation content stream wire requires start zero and literal true" {
    const cases = [_]struct { suffix: []const u8, stream: bool = false, failure: ?anyerror = null }{
        .{ .suffix = "\"0\"}" },
        .{ .suffix = "\"0\",\"stream\":true}", .stream = true },
        .{ .suffix = "\"1\",\"stream\":true}", .failure = error.InvalidCursor },
        .{ .suffix = "\"0\",\"stream\":false}", .failure = error.InvalidJsonShape },
        .{ .suffix = "\"0\",\"stream\":\"true\"}", .failure = error.InvalidJsonShape },
        .{ .suffix = "\"0\",\"stream\":true,\"stream\":true}", .failure = error.InvalidJsonShape },
    };
    for (cases) |case| {
        var buffer: [512]u8 = undefined;
        const json = try std.fmt.bufPrint(&buffer, "{{\"version\":\"1\",\"kind\":\"conversation_content\",\"store\":\"s\",\"session\":\"x\",\"position\":\"1\",\"ordinal\":\"0\",\"start\":{s}", .{case.suffix});
        var source = SocketBody.init(-1, 0);
        @memcpy(source.buffer[0..json.len], json);
        source.end = json.len;
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{ .io = std.testing.io, .fd = -1, .content_length = json.len, .scratch_path = "unused", .request_number = 0, .retained_scratch = &retained } };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parser.parse());
        } else {
            const request = (try parser.parse()).conversation_content;
            try std.testing.expectEqual(case.stream, request.stream);
        }
    }
}

test "conversation cursor parser rejects unfixed and malformed continuations" {
    const cases = [_]struct { body: []const u8, failure: ?anyerror = null }{
        .{ .body = "\"end\":\"0\",\"before_position\":\"0\",\"before_ordinal\":\"0\"" },
        .{ .body = "\"end\":\"25\",\"before_position\":\"0\",\"before_ordinal\":\"0\"" },
        .{ .body = "\"end\":\"25\",\"before_position\":\"10\",\"before_ordinal\":\"2\"" },
        .{ .body = "\"end\":\"0\",\"before_position\":\"10\",\"before_ordinal\":\"0\"", .failure = error.InvalidCursor },
        .{ .body = "\"end\":\"25\",\"before_position\":\"0\",\"before_ordinal\":\"1\"", .failure = error.InvalidCursor },
        .{ .body = "\"end\":\"25\",\"before_position\":\"26\",\"before_ordinal\":\"0\"", .failure = error.InvalidCursor },
        .{ .body = "\"end\":\"25\",\"before_position\":\"10\",\"before_ordinal\":\"18446744073709551615\"", .failure = error.InvalidCursor },
        .{ .body = "\"end\":\"18446744073709551615\",\"before_position\":\"10\",\"before_ordinal\":\"0\"", .failure = error.InvalidCursor },
        .{ .body = "\"end\":\"0\",\"before_position\":\"0\",\"before_ordinal\":\"1\"", .failure = error.InvalidCursor },
        .{ .body = "\"end\":\"025\",\"before_position\":\"10\",\"before_ordinal\":\"0\"", .failure = error.InvalidIdentity },
    };
    for (cases) |case| {
        var buffer: [512]u8 = undefined;
        const json = try std.fmt.bufPrint(&buffer, "{{\"version\":\"1\",\"kind\":\"conversation_page\",\"store\":\"s\",\"session\":\"x\",{s}}}", .{case.body});
        var source = SocketBody.init(-1, 0);
        @memcpy(source.buffer[0..json.len], json);
        source.end = json.len;
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{ .io = std.testing.io, .fd = -1, .content_length = json.len, .scratch_path = "unused", .request_number = 0, .retained_scratch = &retained } };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parser.parse());
        } else {
            const request = try parser.parse();
            try std.testing.expect(request == .conversation_page);
        }
    }
}

test "configuration token heuristics and effort parse sparsely and bind idempotency" {
    const cases = [_]struct { suffix: []const u8, trigger: ?[]const u8 = null, reservation: ?[]const u8 = null, failure: ?anyerror = null }{
        .{ .suffix = "" },
        .{ .suffix = ",\"compaction_trigger\":{\"state\":\"omitted\"},\"output_reservation\":{\"state\":\"omitted\"}" },
        .{ .suffix = ",\"compaction_trigger\":{\"state\":\"value\",\"value\":\"100000\"}", .trigger = "100000" },
        .{ .suffix = ",\"output_reservation\":{\"state\":\"value\",\"value\":\"16384\"}", .reservation = "16384" },
        // Numeric meaning belongs to atomic Store admission, not wire parsing.
        .{ .suffix = ",\"compaction_trigger\":{\"state\":\"value\",\"value\":\"0\"}", .trigger = "0" },
        .{ .suffix = ",\"output_reservation\":{\"state\":\"value\",\"value\":\"9223372036854775808\"}", .reservation = "9223372036854775808" },
        .{ .suffix = ",\"compaction_trigger\":{\"state\":\"null\"}" },
        .{ .suffix = ",\"output_reservation\":{\"state\":\"null\"}" },
        .{ .suffix = ",\"compaction_trigger\":{\"state\":\"value\",\"value\":100000}", .failure = error.InvalidJsonShape },
        .{ .suffix = ",\"compaction_trigger\":{\"state\":\"value\",\"value\":\"123456789012345678901\"}", .failure = error.ValueTooLong },
        .{ .suffix = ",\"context_capacity\":{\"state\":\"omitted\"}", .failure = error.UnexpectedField },
        .{ .suffix = ",\"output_reservation\":{\"state\":\"omitted\"},\"output_reservation\":{\"state\":\"omitted\"}", .failure = error.UnexpectedField },
        .{ .suffix = ",\"reasoning_effort\":{\"state\":\"value\",\"value\":\"high\"}" },
        .{ .suffix = ",\"reasoning_effort\":{\"state\":\"value\",\"value\":\"none\"}" },
        .{ .suffix = ",\"reasoning_effort\":{\"state\":\"null\"}" },
        .{ .suffix = ",\"reasoning_effort\":{\"state\":\"value\",\"value\":\"ultra\"}" },
        .{ .suffix = ",\"reasoning_effort\":{\"state\":\"null\"},\"reasoning_effort\":{\"state\":\"null\"}", .failure = error.UnexpectedField },
    };
    var omitted_digest: [32]u8 = undefined;
    for (cases, 0..) |case, index| {
        var buffer: [2048]u8 = undefined;
        const json = try std.fmt.bufPrint(&buffer, "{{\"version\":\"1\",\"kind\":\"configure\",\"store\":\"store\",\"key\":\"key\",\"session\":\"session\",\"configuration\":{{" ++
            "\"workspace\":{{\"state\":\"omitted\"}},\"provider\":{{\"state\":\"omitted\"}},\"model\":{{\"state\":\"omitted\"}}," ++
            "\"instructions\":{{\"state\":\"omitted\"}},\"tools\":{{\"state\":\"omitted\"}},\"permission_mode\":{{\"state\":\"omitted\"}},\"output_schema\":{{\"state\":\"omitted\"}}{s}}}}}", .{case.suffix});
        var source = SocketBody.init(-1, 0);
        @memcpy(source.buffer[0..json.len], json);
        source.end = json.len;
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{ .io = std.testing.io, .fd = -1, .content_length = json.len, .scratch_path = "unused", .request_number = 0, .retained_scratch = &retained } };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parser.parse());
            continue;
        }
        const command = (try parser.parse()).configure;
        if (case.trigger) |value| try std.testing.expectEqualStrings(value, command.configuration.compaction_trigger.value.slice());
        if (case.reservation) |value| try std.testing.expectEqualStrings(value, command.configuration.output_reservation.value.slice());
        if (std.mem.indexOf(u8, case.suffix, "\"state\":\"null\"") != null) {
            const state = if (std.mem.indexOf(u8, case.suffix, "compaction_trigger") != null)
                command.configuration.compaction_trigger.state
            else if (std.mem.indexOf(u8, case.suffix, "reasoning_effort") != null)
                command.configuration.reasoning_effort.state
            else
                command.configuration.output_reservation.state;
            try std.testing.expectEqual(FieldState.explicit_null, state);
        }
        const digest = command.semanticDigest();
        if (index == 0) omitted_digest = digest else if (index == 1) {
            try std.testing.expectEqualSlices(u8, &omitted_digest, &digest);
        } else try std.testing.expect(!std.mem.eql(u8, &omitted_digest, &digest));
    }
}

test "configuration provider envelope preserves exact spelling and omission" {
    const cases = [_]struct { field: []const u8, expected: ?[]const u8, suffix: []const u8 = "", failure: ?anyerror = null }{
        .{ .field = "{\"state\":\"omitted\"}", .expected = null },
        .{ .field = "{\"state\":\"value\",\"value\":\"codex\"}", .expected = "codex" },
        .{ .field = "{\"state\":\"value\",\"value\":\"c\\u006fdex\"}", .expected = "codex" },
        .{ .field = "{\"state\":\"value\",\"value\":\"codex\"}", .expected = "codex", .suffix = ",\"require_model\":true" },
        // Admission, not parsing, rejects bounded unsupported spellings.
        .{ .field = "{\"state\":\"value\",\"value\":\"Codex\"}", .expected = "Codex" },
        .{ .field = "{\"state\":\"value\",\"value\":\"other\"}", .expected = "other" },
        .{ .field = "{\"state\":\"value\",\"value\":\"anthropic\"}", .expected = "anthropic" },
        .{ .field = "{\"state\":\"value\",\"value\":\"12345678901234567\"}", .expected = null, .failure = error.ValueTooLong },
        .{ .field = "{\"state\":\"null\"}", .expected = null, .failure = error.InvalidFieldState },
    };
    var omitted_digest: [32]u8 = undefined;
    var codex_digest: [32]u8 = undefined;
    for (cases, 0..) |case, index| {
        var buffer: [1024]u8 = undefined;
        const json = try std.fmt.bufPrint(
            &buffer,
            "{{\"version\":\"1\",\"kind\":\"configure\",\"store\":\"store\",\"key\":\"key\",\"session\":\"session\",\"configuration\":{{" ++
                "\"workspace\":{{\"state\":\"omitted\"}},\"provider\":{s},\"model\":{{\"state\":\"omitted\"}}," ++
                "\"instructions\":{{\"state\":\"omitted\"}},\"tools\":{{\"state\":\"omitted\"}}," ++
                "\"permission_mode\":{{\"state\":\"omitted\"}},\"output_schema\":{{\"state\":\"omitted\"}}}}{s}}}",
            .{ case.field, case.suffix },
        );
        var source = SocketBody.init(-1, 0);
        @memcpy(source.buffer[0..json.len], json);
        source.end = json.len;
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{
            .io = std.testing.io,
            .fd = -1,
            .content_length = json.len,
            .scratch_path = "unused",
            .request_number = 0,
            .retained_scratch = &retained,
        } };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parser.parse());
            continue;
        }
        const request = try parser.parse();
        try std.testing.expectEqual(index == 3, request.configure.require_model);
        const field = request.configure.configuration.provider;
        if (case.expected) |value| {
            try std.testing.expectEqual(FieldState.value, field.state);
            try std.testing.expectEqualStrings(value, field.value.slice());
        } else try std.testing.expectEqual(FieldState.omitted, field.state);
        const digest = request.configure.semanticDigest();
        if (index == 0) omitted_digest = digest else if (index == 1) codex_digest = digest;
        if (index == 2) try std.testing.expectEqualSlices(u8, &codex_digest, &digest);
        if (index > 2) try std.testing.expect(!std.mem.eql(u8, &codex_digest, &digest));
    }
    try std.testing.expect(!std.mem.eql(u8, &omitted_digest, &codex_digest));
}

test "configuration tools accept only an empty catalog or Bash" {
    const cases = [_]struct { value: []const u8, count: u1 = 0, failure: ?anyerror = null }{
        .{ .value = "[]" },
        .{ .value = "[\"bash\"]", .count = 1 },
        .{ .value = "[\"edit\"]", .failure = error.UnknownTool },
        .{ .value = "[\"Bash\"]", .failure = error.UnknownTool },
        .{ .value = "[\"none\"]", .failure = error.UnknownTool },
        .{ .value = "[\"bash\",\"bash\"]", .failure = error.InvalidJsonShape },
        .{ .value = "[\"bash\",\"edit\"]", .failure = error.InvalidJsonShape },
    };
    for (cases) |case| {
        var buffer: [1024]u8 = undefined;
        const json = try std.fmt.bufPrint(&buffer, "{{\"version\":\"1\",\"kind\":\"configure\",\"store\":\"store\",\"key\":\"key\",\"session\":\"session\",\"configuration\":{{" ++
            "\"workspace\":{{\"state\":\"omitted\"}},\"provider\":{{\"state\":\"omitted\"}},\"model\":{{\"state\":\"omitted\"}}," ++
            "\"instructions\":{{\"state\":\"omitted\"}},\"tools\":{{\"state\":\"value\",\"value\":{s}}}," ++
            "\"permission_mode\":{{\"state\":\"omitted\"}},\"output_schema\":{{\"state\":\"omitted\"}}}}}}", .{case.value});
        var source = SocketBody.init(-1, 0);
        @memcpy(source.buffer[0..json.len], json);
        source.end = json.len;
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{
            .io = std.testing.io,
            .fd = -1,
            .content_length = json.len,
            .scratch_path = "unused",
            .request_number = 0,
            .retained_scratch = &retained,
        } };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parser.parse());
        } else {
            const request = try parser.parse();
            try std.testing.expectEqual(case.count, request.configure.configuration.tools.count);
            if (case.count == 1) try std.testing.expectEqual(.bash, request.configure.configuration.tools.values[0]);
        }
    }
}

test "Session inspection selects a closed report profile or exact failed response stream" {
    const cases = [_]struct { json: []const u8, expected: ?ReportProfile, failed_response: ?FailedResponseExport = null }{
        .{
            .json = "{\"version\":\"1\",\"kind\":\"inspect_session\",\"store\":\"store\",\"session\":\"session\"}",
            .expected = .current,
        },
        .{
            .json = "{\"version\":\"1\",\"kind\":\"inspect_session\",\"store\":\"store\",\"session\":\"session\",\"profile\":\"full\"}",
            .expected = .full,
        },
        .{
            .json = "{\"version\":\"1\",\"kind\":\"inspect_session\",\"store\":\"store\",\"session\":\"session\",\"profile\":\"current\"}",
            .expected = null,
        },
        .{
            .json = "{\"version\":\"1\",\"kind\":\"inspect_session\",\"store\":\"store\",\"session\":\"session\",\"failed_response\":\"body\",\"operation\":\"106\",\"attempt\":\"1\"}",
            .expected = .current,
            .failed_response = .{ .operation = 106, .attempt = 1, .part = .body },
        },
        .{
            .json = "{\"version\":\"1\",\"kind\":\"inspect_session\",\"store\":\"store\",\"session\":\"session\",\"failed_response\":\"metadata\",\"operation\":\"42\",\"attempt\":\"3\"}",
            .expected = .current,
            .failed_response = .{ .operation = 42, .attempt = 3, .part = .metadata },
        },
    };
    for (cases) |case| {
        var source = SocketBody.init(-1, 0);
        @memcpy(source.buffer[0..case.json.len], case.json);
        source.end = case.json.len;
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{
            .io = std.testing.io,
            .fd = -1,
            .content_length = case.json.len,
            .scratch_path = "unused",
            .request_number = 0,
            .retained_scratch = &retained,
        } };
        if (case.expected) |expected| {
            const request = try parser.parse();
            try std.testing.expectEqual(expected, request.inspect_session.profile);
            try std.testing.expectEqualDeep(case.failed_response, request.inspect_session.failed_response);
        } else {
            try std.testing.expectError(error.UnknownReportProfile, parser.parse());
        }
    }
}

test "Session listing wire distinguishes all, exact workspace, continuation and invalid cursor" {
    const cases = [_]struct { json: []const u8, workspace: ?[]const u8, after: u64, ceiling: u64, valid: bool }{
        .{ .json = "{\"version\":\"1\",\"kind\":\"list_sessions\",\"store\":\"s\",\"workspace\":null,\"after\":\"0\",\"ceiling\":\"0\"}", .workspace = null, .after = 0, .ceiling = 0, .valid = true },
        .{ .json = "{\"version\":\"1\",\"kind\":\"list_sessions\",\"store\":\"s\",\"workspace\":\"/a\\u0001b\",\"after\":\"8\",\"ceiling\":\"12\"}", .workspace = "/a\x01b", .after = 8, .ceiling = 12, .valid = true },
        .{ .json = "{\"version\":\"1\",\"kind\":\"list_sessions\",\"store\":\"s\",\"workspace\":null,\"after\":\"0\",\"ceiling\":\"12\"}", .workspace = null, .after = 0, .ceiling = 12, .valid = false },
        .{ .json = "{\"version\":\"1\",\"kind\":\"list_sessions\",\"store\":\"s\",\"workspace\":null,\"after\":\"13\",\"ceiling\":\"12\"}", .workspace = null, .after = 13, .ceiling = 12, .valid = false },
    };
    for (cases) |case| {
        var source = SocketBody.init(-1, 0);
        @memcpy(source.buffer[0..case.json.len], case.json);
        source.end = case.json.len;
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{
            .io = std.testing.io,
            .fd = -1,
            .content_length = case.json.len,
            .scratch_path = "unused",
            .request_number = 0,
            .retained_scratch = &retained,
        } };
        if (case.valid) {
            const request = (try parser.parse()).list_sessions;
            try std.testing.expectEqual(case.after, request.after);
            try std.testing.expectEqual(case.ceiling, request.ceiling);
            if (case.workspace) |workspace| try std.testing.expectEqualStrings(workspace, request.workspace.?.slice()) else try std.testing.expect(request.workspace == null);
        } else try std.testing.expectError(error.InvalidCursor, parser.parse());
    }
}

test "peer wire rejects old sender strings, malformed addresses and missing handles" {
    const prefix = "{\"version\":\"1\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"target\",\"sender\":";
    const cases = [_]struct { json: []const u8, failure: anyerror }{
        .{ .json = prefix ++ "\"peer\",\"sender_handle\":null", .failure = error.InvalidJsonShape },
        .{ .json = prefix ++ "{\"store\":\"/s\"},\"sender_handle\":null", .failure = error.InvalidJsonShape },
        .{ .json = prefix ++ "{\"store\":\"relative\",\"session\":\"peer\"},\"sender_handle\":null", .failure = error.InvalidRuiAddress },
        .{ .json = prefix ++ "null,\"text\":{}", .failure = error.UnexpectedField },
    };
    for (cases) |case| {
        var source = SocketBody.init(-1, 0);
        @memcpy(source.buffer[0..case.json.len], case.json);
        source.end = case.json.len;
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{ .io = std.testing.io, .fd = -1, .content_length = case.json.len, .scratch_path = "unused", .request_number = 0, .retained_scratch = &retained } };
        try std.testing.expectError(case.failure, parser.parse());
        try std.testing.expect(retained == null);
    }
}

test "incremental ingress streams fragmented content and transfers charged custody only at complete framing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    const prefix = "{\"version\":\"1\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"p\\u0000é\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"";
    const encoded = @as([8193]u8, @splat('x')) ++ "\\n\\ud83d\\ude42\\u0000é\\\"\\\\";
    const expected = @as([8193]u8, @splat('x')) ++ "\n🙂\x00é\"\\";
    const suffix = "\"}}";
    var used = std.atomic.Value(u64).init(0);
    var retained: ?named_scratch.Owner = null;
    var ingress = Ingress.init(std.testing.allocator, .{
        .io = io,
        .fd = -1,
        .content_length = prefix.len + encoded.len + suffix.len,
        .scratch_path = root[0..root_len],
        .request_number = 42,
        .retained_scratch = &retained,
        .scratch_budget = .{ .used = &used, .limit = expected.len },
        .expected_kind = .message,
    });
    defer ingress.deinit();
    for (prefix ++ encoded) |byte| try ingress.feed(&.{byte});
    try std.testing.expectEqual(@as(u64, 8192), used.load(.acquire));
    try std.testing.expectError(error.UnexpectedEndOfBody, ingress.finish());
    for (suffix) |byte| try ingress.feed(&.{byte});
    var request = try ingress.finish();
    defer request.removeTemporaryContent(io) catch unreachable;
    // Disposing the exchange's parser cannot refund or close admitted ingress.
    ingress.deinit();
    try std.testing.expectEqual(@as(u64, expected.len), used.load(.acquire));
    try std.testing.expectEqualStrings("p\x00é", request.message.session.slice());
    var actual: [expected.len]u8 = undefined;
    try std.testing.expectEqual(actual.len, try request.message.text.file.?.readPositionalAll(io, &actual, 0));
    try std.testing.expectEqualStrings(expected, &actual);
    var hash = contentHasher();
    hash.update(expected);
    try std.testing.expectEqualSlices(u8, &hash.finalResult(), &request.message.text.digest);
    try request.removeTemporaryContent(io);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expect(retained == null);
}

test "initial Message ingress retains text custody and rejects extra content before capture" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    const prefix = "{\"version\":\"1\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"\",\"sender\":null,\"sender_handle\":null,\"configuration\":{" ++
        "\"workspace\":{\"state\":\"omitted\"},\"provider\":{\"state\":\"omitted\"},\"model\":{\"state\":\"omitted\"},\"instructions\":";
    const between = ",\"tools\":{\"state\":\"omitted\"},\"permission_mode\":{\"state\":\"omitted\"},\"output_schema\":";
    const suffix = "},\"text\":{\"state\":\"value\",\"value\":\"assignment\\u0000雪\\n\\n\"}}";
    const omitted = "{\"state\":\"omitted\"}";
    const value = "{\"state\":\"value\",\"value\":\"rules\\n\"}";
    const json = prefix ++ omitted ++ between ++ omitted ++ suffix;
    const expected = "assignment\x00雪\n\n";
    var used = std.atomic.Value(u64).init(0);
    var retained: ?named_scratch.Owner = null;
    const options: ParseOptions = .{
        .io = io,
        .fd = -1,
        .content_length = json.len,
        .scratch_path = root[0..root_len],
        .request_number = 43,
        .retained_scratch = &retained,
        .scratch_budget = .{ .used = &used, .limit = expected.len },
        .expected_kind = .message,
    };
    var ingress = Ingress.init(std.testing.allocator, options);
    defer ingress.deinit();
    for (json) |byte| try ingress.feed(&.{byte});
    var request = try ingress.finish();
    defer request.removeTemporaryContent(io) catch unreachable;
    ingress.deinit();
    try std.testing.expectEqual(.omitted, request.message.configuration.?.instructions.state);
    try std.testing.expectEqual(.omitted, request.message.configuration.?.output_schema.state);
    try std.testing.expectEqual(@as(u64, expected.len), used.load(.acquire));
    var actual: [64]u8 = undefined;
    const count = try request.message.text.file.?.readPositionalAll(io, &actual, 0);
    try std.testing.expectEqualStrings(expected, actual[0..count]);
    var hash = contentHasher();
    hash.update(expected);
    try std.testing.expectEqualSlices(u8, &hash.finalResult(), &request.message.text.digest);
    try request.removeTemporaryContent(io);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expect(retained == null);
    inline for (.{ prefix ++ value ++ between ++ omitted ++ suffix, prefix ++ omitted ++ between ++ value ++ suffix }) |invalid| {
        var rejection_options = options;
        rejection_options.content_length = invalid.len;
        var rejected = Ingress.init(std.testing.allocator, rejection_options);
        defer rejected.deinit();
        try std.testing.expectError(error.InvalidFieldState, rejected.feed(invalid));
        try std.testing.expectEqual(@as(usize, 0), rejected.content_count);
        try std.testing.expect(rejected.capture == null);
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    }
}

test "incremental ingress preserves grammar and releases both captures after late failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    const configure = "{\"version\":\"1\",\"kind\":\"configure\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"configuration\":{" ++
        "\"workspace\":{\"state\":\"omitted\"},\"provider\":{\"state\":\"omitted\"},\"model\":{\"state\":\"omitted\"}," ++
        "\"instructions\":{\"state\":\"value\",\"value\":\"first\\n\"},\"tools\":{\"state\":\"omitted\"}," ++
        "\"permission_mode\":{\"state\":\"omitted\"},\"output_schema\":{\"state\":\"value\",\"value\":\"{}\"}}";
    const cases = [_]struct { bytes: []const u8, kind: Kind = .configure, failure: ?anyerror = null }{
        .{ .bytes = configure ++ "}" },
        .{ .bytes = configure ++ ",\"require_model\":true}" },
        .{ .bytes = configure ++ ",\"require_model\":t rue}", .failure = error.InvalidJsonShape },
        .{ .bytes = configure ++ "} ", .failure = error.TrailingInput },
        .{ .bytes = configure ++ ",\"extra\":true}", .failure = error.UnexpectedField },
        .{ .bytes = configure ++ "}", .kind = .session_stop, .failure = error.RouteKindMismatch },
        .{ .bytes = configure, .failure = error.UnexpectedEndOfBody },
    };
    var used = std.atomic.Value(u64).init(0);
    var retained: ?named_scratch.Owner = null;
    for (cases, 0..) |case, index| {
        // Every split of this small command must have the same grammar and
        // capture lifetime, including suspension between surrogate/quote bytes.
        for (0..case.bytes.len + 1) |split| {
            var ingress = Ingress.init(std.testing.allocator, .{
                .io = io,
                .fd = -1,
                .content_length = case.bytes.len,
                .scratch_path = root[0..root_len],
                .request_number = index,
                .retained_scratch = &retained,
                .scratch_budget = .{ .used = &used, .limit = 8 },
                .expected_kind = case.kind,
                // A mismatched kind must fail before file acquisition.
                .content_faults = .{ .acquire = case.kind != .configure },
            });
            const result: anyerror!Request = blk: {
                ingress.feed(case.bytes[0..split]) catch |err| break :blk err;
                ingress.feed(case.bytes[split..]) catch |err| break :blk err;
                break :blk ingress.finish();
            };
            if (case.failure) |failure| {
                try std.testing.expectError(failure, result);
            } else {
                var request = try result;
                try std.testing.expectEqual(@as(u64, 8), used.load(.acquire));
                try std.testing.expectEqual(index == 1, request.configure.require_model);
                const fields = [_]ContentField{ request.configure.configuration.instructions, request.configure.configuration.output_schema };
                const expected = [_][]const u8{ "first\n", "{}" };
                for (fields, expected) |field, bytes| {
                    var buffer: [8]u8 = undefined;
                    const count = try field.file.?.readPositionalAll(io, &buffer, 0);
                    try std.testing.expectEqualStrings(bytes, buffer[0..count]);
                }
                try request.removeTemporaryContent(io);
            }
            ingress.deinit();
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            try std.testing.expect(retained == null);
        }
    }
}
// hillclimb nonce eff2-a--1-1793308772
