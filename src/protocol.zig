const std = @import("std");
const cli_value = @import("cli_value.zig");
const built_in_tool = @import("built_in_tool.zig");
const model_capability = @import("model_capability.zig");
const model_list = @import("model_list.zig");
const provider_name = @import("provider_name.zig");
const named_scratch = @import("named_scratch.zig");
const store_id = @import("store_id.zig");
pub const ScratchBudget = @import("ScratchBudget.zig");

pub const wire_version = "8";
/// Versions a newer and an older Host speak, for tests that refuse them.
pub const next_wire_version = std.fmt.comptimePrint("{d}", .{wire_number + 1});
pub const previous_wire_version = std.fmt.comptimePrint("{d}", .{wire_number - 1});
const wire_number = std.fmt.parseInt(u32, wire_version, 10) catch unreachable;
pub const max_key_bytes = 128;
/// Command keys Rui gives its own commands: a core tool call's Message or
/// agent start, and the stop an attached child owes. A client command
/// with one is refused.
pub const reserved_key_prefix = "rui.core/";
pub const max_session_bytes = 128;
// SQLite's Unix VFS needs eight bytes beyond the database path for journals.
// The Store selector plus "/rui.sqlite3" and the journal suffix must stay
// within its compiled 512-byte pathname limit.
pub const max_store_bytes = 492;
pub const max_workspace_bytes = 4096;
/// Content strings one request carries at most: a configure command's
/// instructions and output schema.
const max_request_contents = 2;
pub const max_sender_handle_bytes = 32;
/// Most bytes of client environment entries one Message carries.
pub const max_environment_bytes = 64 * 1024;
pub const max_model_bytes = model_capability.max_model_bytes;
// Resolution, rejection and failure codes.
pub const max_code_bytes = 96;
/// A failed Turn outcome's report: the provider's code and message, each
/// at most 256 bytes plus a shortened mark, and their separator.
pub const max_report_bytes = 2 * 256 + ": ".len + 2 * "…".len;
pub const max_tool_description_bytes = 100;
/// A tool name: 1-64 bytes of [A-Za-z0-9_-] (OpenAI's function name limit).
pub const max_tool_name_bytes = 64;
/// The most names one `tools` list holds, and their bytes together (D214).
pub const max_tools = 128;
pub const max_tool_list_name_bytes = 4096;
/// A Session Label obeys the saved Bash description rule.
pub const max_label_bytes = max_tool_description_bytes;

/// Whether `bytes` is a Session Label: one non-blank line of UTF-8 within
/// `max_label_bytes`.
pub fn validLabel(bytes: []const u8) bool {
    comptime std.debug.assert(max_label_bytes == max_tool_description_bytes);
    return ToolPresentation.validDescription(bytes);
}
pub const Provider = provider_name.Provider;
/// How a Host serves a provider: not at all, at a development endpoint
/// that takes no credential, or at its own endpoint with its credential.
pub const Route = enum { unserved, endpoint, chatgpt_device, key_file };

/// Each provider's Route, as `host_info` reports it.
pub const Routes = std.enums.EnumFieldStruct(Provider, Route, null);

/// Every provider on `route`.
pub fn routesAll(route: Route) Routes {
    var routes: Routes = undefined;
    inline for (@typeInfo(Provider).@"enum".field_names) |name| @field(routes, name) = route;
    return routes;
}

pub fn routeOf(routes: Routes, provider: Provider) Route {
    return switch (provider) {
        inline else => |tag| @field(routes, @tagName(tag)),
    };
}

/// Whether a Host with these Routes makes model requests for any provider.
pub fn servesModel(routes: Routes) bool {
    inline for (@typeInfo(Provider).@"enum".field_names) |name| if (@field(routes, name) != .unserved) return true;
    return false;
}

pub const Codec = provider_name.Codec;
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
        if (!validSessionId(self.session.slice())) return error.InvalidRuiAddress;
        if (store_id.valid(path)) return;
        if (path.len == 0 or path[0] != '/' or
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
    state: FieldState = .omitted,
    // A parsed request owns an unlinked file descriptor. The Store imports
    // through this sealed custody; no pathname can be swapped after capture.
    file: ?std.Io.File = null,
    scratch_budget: ?ScratchBudget = null,
    charged: u64 = 0,
    length: u64 = 0,
    digest: [32]u8 = @splat(0),
    /// While a request is parsed, which Ingress capture holds this value,
    /// counted from 1 in arrival order; 0 once it holds its own file.
    capture: u8 = 0,

    pub fn hasFile(self: *const ContentField) bool {
        return self.file != null;
    }
};

/// A `tools` list: tool names, sorted by bytes with none repeated, so one
/// list has one spelling and one digest. The names are held one space
/// apart. The parser checks the Host offers each one.
pub const ToolsField = struct {
    state: FieldState = .omitted,
    count: u8 = 0,
    names: Bounded(max_tool_names_bytes) = .{},

    pub fn iterator(self: *const ToolsField) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, self.names.slice(), ' ');
    }

    /// A list of `names`, which must be sorted and valid.
    pub fn of(names: []const []const u8) error{ InvalidToolName, InvalidJsonShape }!ToolsField {
        var out: ToolsField = .{ .state = .value };
        for (names) |name| try out.append(name);
        return out;
    }

    /// Appends `name`, which must sort after every name already held. A
    /// name outside the grammar is `InvalidToolName`; one out of order,
    /// repeated, or past a limit is `InvalidJsonShape`.
    pub fn append(self: *ToolsField, name: []const u8) error{ InvalidToolName, InvalidJsonShape }!void {
        if (!validToolName(name)) return error.InvalidToolName;
        if (self.count == max_tools) return error.InvalidJsonShape;
        const held = self.names.slice();
        if (self.count != 0) {
            const last = held[if (std.mem.lastIndexOfScalar(u8, held, ' ')) |space| space + 1 else 0..];
            if (std.mem.order(u8, last, name) != .lt) return error.InvalidJsonShape;
        }
        // The limit counts name bytes only, not the separators.
        if (held.len - (self.count -| 1) + name.len > max_tool_list_name_bytes) return error.InvalidJsonShape;
        var at = held.len;
        if (self.count != 0) {
            self.names.bytes[at] = ' ';
            at += 1;
        }
        @memcpy(self.names.bytes[at..][0..name.len], name);
        self.names.len = at + name.len;
        self.count += 1;
    }
};

/// A `tools` list's names, one space apart.
pub const max_tool_names_bytes = max_tool_list_name_bytes + max_tools - 1;

/// A JSON list of validated tool names, including brackets, quotes and commas.
pub const max_tool_names_json_bytes = 2 + max_tool_list_name_bytes + 2 * max_tools + max_tools - 1;

pub const BuiltInTool = built_in_tool.BuiltInTool;
pub const ToolSelection = built_in_tool.Selection;

/// The built-in tool `name` names, or null.
pub fn builtInTool(name: []const u8) ?BuiltInTool {
    return std.meta.stringToEnum(BuiltInTool, name);
}

comptime {
    const tools = std.enums.values(BuiltInTool);
    for (tools[1..], tools[0 .. tools.len - 1]) |tool, previous| {
        if (std.mem.order(u8, @tagName(previous), @tagName(tool)) != .lt) @compileError("built-in tools in name order");
    }
}
/// Whether `name` is a tool name: 1-64 bytes of [A-Za-z0-9_-].
pub fn validToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_tool_name_bytes) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    return true;
}

pub const Configuration = struct {
    workspace: OptionalBounded(max_workspace_bytes) = .{},
    provider: OptionalBounded(max_provider_bytes) = .{},
    model: OptionalBounded(max_model_bytes) = .{},
    instructions: ContentField = .{},
    tools: ToolsField = .{},
    loaded_tools: ToolsField = .{},
    permission_mode: OptionalBounded(16) = .{},
    output_schema: ContentField = .{},
    compaction_trigger: OptionalBounded(20) = .{},
    output_reservation: OptionalBounded(20) = .{},
    reasoning_effort: OptionalBounded(16) = .{},
    /// Display text only: never model input, an address or a selector.
    label: OptionalBounded(max_label_bytes) = .{},

    pub fn removeTemporaryContent(self: *Configuration, io: std.Io) !void {
        var cleanup_error: ?anyerror = null;
        removeContent(&self.instructions, io) catch |err| {
            cleanup_error = err;
        };
        removeContent(&self.output_schema, io) catch |err| {
            cleanup_error = err;
        };
        if (cleanup_error) |err| return err;
    }
};

pub const Kind = enum {
    host_info,
    host_stop,
    host_pause,
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
    activity_page,
    activity_content,
    model_list,
};

pub const ConfigureCommand = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    configuration: Configuration = .{},
    require_model: bool = false,

    pub fn removeTemporaryContent(self: *ConfigureCommand, io: std.Io) !void {
        return self.configuration.removeTemporaryContent(io);
    }

    pub fn semanticDigest(self: *const ConfigureCommand) [32]u8 {
        return configureDigest(self.session.slice(), &self.configuration, self.require_model);
    }
};

/// The digest of a Configure command with these parts; a creating Message
/// binds its initial configuration through the same digest.
fn configureDigest(session: []const u8, configuration: *const Configuration, require_model: bool) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hash, "rui/core/configure/v1");
    hashField(&hash, session);
    hashOptional(&hash, &configuration.workspace);
    hashOptional(&hash, &configuration.provider);
    hashOptional(&hash, &configuration.model);
    hashContent(&hash, &configuration.instructions);
    hashTools(&hash, &configuration.tools);
    hashOptional(&hash, &configuration.permission_mode);
    hashContent(&hash, &configuration.output_schema);
    hashOptional(&hash, &configuration.compaction_trigger);
    hashOptional(&hash, &configuration.output_reservation);
    hashOptional(&hash, &configuration.reasoning_effort);
    hashOptional(&hash, &configuration.label);
    hash.update(&.{@intFromBool(require_model)});
    // Omission retains the pre-loaded-tools digest, including creating
    // Messages: saved requests must still replay after a Store upgrade.
    if (configuration.loaded_tools.state != .omitted) {
        hashField(&hash, "rui/core/configure/loaded-tools/v1");
        hashTools(&hash, &configuration.loaded_tools);
    }
    return hash.finalResult();
}

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
    // A creating Message only: create nothing unless the Host has a model.
    require_model: bool = false,

    pub fn removeTemporaryContent(self: *MessageCommand, io: std.Io) !void {
        try removeContent(&self.text, io);
    }

    pub fn semanticDigest(self: *const MessageCommand) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hash, "rui/core/message/v4");
        hashField(&hash, self.session.slice());
        hash.update(&.{@intFromBool(self.sender != null)});
        if (self.sender) |sender| {
            hashField(&hash, sender.store.slice());
            hashField(&hash, sender.session.slice());
        }
        hash.update(&.{@intFromBool(self.sender_handle != null)});
        if (self.sender_handle) |handle| hashField(&hash, handle.slice());
        hashContent(&hash, &self.text);
        if (self.configuration) |*configuration| {
            // The creation's own digest covers its capability condition.
            hashField(&hash, "initial-configuration");
            hash.update(&configureDigest("", configuration, self.require_model));
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
    unknown_tool,
    provider_tool_missing,
    loaded_tools_not_in_tools,
    loaded_tools_unreachable,
    invalid_label,
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
    unknown_tool,
    provider_tool_missing,
    loaded_tools_not_in_tools,
    loaded_tools_unreachable,
    invalid_label,
    incomplete_initial_configuration,
    invalid_workspace,
    workspace_is_immutable,
    provider_is_immutable,
    model_is_immutable,
    revision_exhausted,
};
pub const CommandKind = cli_value.CommandKind;
pub const CommandObservationStatus = enum { absent, accepted, rejected };
pub const SessionStopCompletion = enum { pending, completed };

/// How a Turn ended, as its `turn_ended` Activity row names it.
pub const TurnEnding = enum {
    /// The Turn's answer is its `final` assistant row.
    done,
    /// The conversation no longer fits the model's context, even after compaction.
    context_full,
    /// The provider answered with a refusal that resending will meet again.
    provider_refused,
    /// The provider could not be reached, or retries ran out.
    provider_unavailable,
    /// A Session stop ended it.
    stopped,
    /// A Model Interruption ended it.
    interrupted,
    /// Any other failure, which the row's `code` names.
    failed,
};
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
pub const MessageProgressStatus = WorkState.Progress;
/// A hosted call has no content: its presentation is the whole item.
pub const ConversationItemKind = enum { user, assistant, tool_result, hosted_call };

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

pub const ReportProfile = cli_value.ReportProfile;

pub const FailedResponsePart = cli_value.FailedResponsePart;
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
    /// Host Unix seconds, fixed before the execution thread starts.
    started_at: []const u8,
    /// Slots in use: held custody records, including detached cleanup. The
    /// value Current reports as `execution.custody_occupied`.
    custody_occupied: []const u8,
    /// Whether the Host holds every new Turn until resumed (D193).
    paused: bool,
    /// MySQL engine diagnostic (D200); absent on SQLite.
    innodb_doublewrite: ?[]const u8 = null,
    capabilities: struct {
        bash: bool,
        providers: Routes,
    },
};

pub const ListSessions = struct {
    store: Bounded(max_store_bytes) = .{},
    workspace: ?Bounded(max_workspace_bytes) = null,
    // Zero/zero begins a traversal. A continuation carries both values.
    after: u64 = 0,
    ceiling: u64 = 0,
    /// A token from an earlier reply: answer only what changed since it.
    since: ?SinceToken = null,
    /// A changed continuation: the first page's generation, and the last
    /// Session the previous page gave.
    changed: ?ChangedCursor = null,

    pub const ChangedCursor = struct { through: u64, after_reference: change_ring.Id };

    pub fn validate(self: *const ListSessions) error{InvalidCursor}!void {
        if (self.after > std.math.maxInt(i64) or self.ceiling > std.math.maxInt(i64) or
            (self.after == 0 and self.ceiling != 0) or
            (self.after != 0 and self.after > self.ceiling)) return error.InvalidCursor;
        // A full continuation needs no token; a changed one needs its own.
        if (self.since != null and self.after != 0) return error.InvalidCursor;
        if (self.changed) |changed| {
            const since = self.since orelse return error.InvalidCursor;
            if (changed.through < since.generation or !validSessionId(&changed.after_reference)) return error.InvalidCursor;
        }
    }
};

/// What a list reply answers relative to its request's `since`.
pub const ListDelta = enum { not_modified, changed, full };

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

pub const ProposalField = enum { name, call_id, arguments };
/// One certified call field: its decoded length and content digest.
pub const ProposalFieldReference = struct { length: u64, digest: [32]u8 };
pub const ProposalRejection = enum { unknown_tool, invalid_arguments };
pub const ProposalMetadata = struct {
    position: u64,
    operation: u64,
    turn: u64,
    call_ordinal: u64,
    action: ?u64,
    rejection: ?ProposalRejection,
    fields: [3]ProposalFieldReference, // ProposalField order.
};

pub const ActivityPage = struct {
    store: Bounded(max_store_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    end: ?u64 = null,
    position: u64 = 0,
    // Null is a sequence boundary; a value identifies an actual public row.
    ordinal: ?u64 = null,
    direction: enum { forward, backward } = .forward,
    /// The row kinds the page lists; the cursor may name a row of any kind.
    kinds: Kinds = .full,
    /// At most this many rows, from 1 to `items`.
    limit: u8 = items,

    pub const Kinds = std.EnumSet(ActivityItem.Kind);
    pub const items = @typeInfo(@FieldType(ActivityFacts, "items")).array.len;

    pub fn validate(self: ActivityPage) !void {
        if (self.position > std.math.maxInt(i64) or (self.ordinal != null and
            (self.position == 0 or self.ordinal.? > std.math.maxInt(i64)))) return error.InvalidCursor;
        if (self.end) |end| if (end > std.math.maxInt(i64) or self.position > end) return error.InvalidCursor;
        if (self.kinds.count() == 0 or self.limit == 0 or self.limit > items) return error.InvalidCursor;
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

    /// One non-blank line of UTF-8 within the description bound.
    pub fn validDescription(bytes: []const u8) bool {
        if (bytes.len == 0 or bytes.len > max_tool_description_bytes or !std.unicode.utf8ValidateSlice(bytes)) return false;
        var scalars = std.unicode.Utf8View.initUnchecked(bytes).iterator();
        var nonblank = false;
        while (scalars.nextCodepoint()) |scalar| {
            switch (scalar) {
                '\n', '\r', 0x85, 0x2028, 0x2029 => return false,
                ' ', '\t', 0xb, 0xc, 0xa0, 0x1680, 0x2000...0x200a, 0x202f, 0x205f, 0x3000 => {},
                else => nonblank = true,
            }
        }
        return nonblank;
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

/// A peer as a Message row names it: with its label as the Store holds it
/// when read, empty when the Session has none. Only rows a reader shows
/// carry it; listings keep the bare `Peer`.
pub const NamedPeer = struct {
    session: Bounded(max_session_bytes),
    label: Bounded(max_label_bytes) = .{},

    pub const json_shape = .{ "{\"session\":", Hole{ .string = max_session_bytes }, ",\"label\":", Hole{ .optional_string = max_label_bytes }, "}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn writeJson(self: NamedPeer, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, .{ self.session.slice(), if (self.label.len == 0) null else self.label.slice() });
    }

    /// What a reader calls it: its label, or its ID when it has none.
    pub fn name(self: *const NamedPeer) []const u8 {
        return if (self.label.len == 0) self.session.slice() else self.label.slice();
    }
};

/// A Session setting a revision can change, named on the wire as in a
/// configuration.
pub const SessionField = enum { provider, model, instructions, tools, loaded_tools, permission_mode, output_schema, compaction_trigger, output_reservation, reasoning_effort, label };

pub const ActivityItem = struct {
    position: u64,
    ordinal: u64 = 0,
    /// The Host Unix second the row's owning fact committed.
    at: u64,
    value: Value,
    /// `admission` is a Message a person or script sent; `received` one
    /// another Session sent, which always names it as `sender`.
    pub const Value = union(enum) { admission: Message, user: Message, assistant: Assistant, call: Call, tool_result: struct { content: Content, presentation: ToolPresentation }, hosted_call: ToolPresentation, turn_ended: TurnEnded, stop: Stop, sent: Sent, send_failed: SendFailed, received: Message, approval_requested: ApprovalRequested, session_changed: SessionChanged, compacted: Compacted };
    pub const Kind = std.meta.Tag(Value);
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
    pub const Message = struct { admission: u64, key: Bounded(max_key_bytes), turn: ?u64, state: enum { queued, applied, excluded }, content: Content, admitted_at: u64, sender: ?NamedPeer = null };
    pub const Call = ProposalMetadata;
    /// `final` marks the Turn's answer: the assistant row a `done` Turn
    /// ended with, once its `turn_ended` row is within the page's end.
    pub const Assistant = struct { content: Content, final: bool = false };
    /// `code` is the saved code the ending was judged from; `content` a
    /// done Turn's answer or a failed one's report.
    pub const TurnEnded = struct { turn: u64, operation: u64, ending: TurnEnding, code: Bounded(max_code_bytes), content: ?Content };
    pub const Stop = struct { key: Bounded(max_key_bytes), turn: ?u64, cutoff: u64, completion: SessionStopCompletion };
    /// A Message this Session sent: admitted to `target`, or rejected there.
    pub const Sent = struct { admission: u64, target: NamedPeer, content: Content, admitted_at: u64 };
    pub const SendFailed = struct { key: Bounded(max_key_bytes), target: NamedPeer, code: Bounded(max_code_bytes) };
    /// A call that waits on a person's decision because the Session asked
    /// for approval when it was made: `action` is the id a
    /// `permission_decision` names. The row follows its call at ordinal 1.
    pub const ApprovalRequested = struct { action: u64, operation: u64, call_ordinal: u64 };
    /// One setting a revision changed, at the position the revision was
    /// accepted; a revision's changes share it, one ordinal each.
    pub const SessionChanged = struct { revision: u64, field: SessionField };
    /// A compaction that succeeded, at its admission: `dropped` is how many
    /// conversation entries it left out to make room, zero for none (D217).
    pub const Compacted = struct { operation: u64, dropped: u64 };

    /// Holes: position, ordinal, at; then the value's shape, then `tail`.
    pub fn head(comptime kind: std.meta.Tag(Value)) struct { []const u8, Hole, []const u8, Hole, []const u8, Hole, []const u8 } {
        return .{ "{\"position\":\"", .decimal, "\",\"ordinal\":\"", .decimal, "\",\"at\":\"", .decimal, "\",\"value\":{\"" ++ @tagName(kind) ++ "\":" };
    }
    pub const tail = .{"}}"};
    /// Each value kind's JSON, named by its tag.
    pub const value_shapes = struct {
        /// Holes: admission, key, turn, state, admitted at, sender, content.
        const message = .{ "{\"admission\":\"", Hole.decimal, "\",\"key\":", Hole{ .string = max_key_bytes }, ",\"turn\":", Hole.optional_id, ",\"state\":\"", Hole{ .tag = @FieldType(Message, "state") }, "\",\"admitted_at\":\"", Hole.decimal, "\",\"sender\":", Hole{ .optional_json = NamedPeer }, ",\"content\":", Hole{ .json = Content }, "}" };
        pub const admission = message;
        pub const user = message;
        pub const received = message;
        /// Holes: content, final.
        pub const assistant = .{ "{\"content\":", Hole{ .json = Content }, ",\"final\":", Hole.boolean, "}" };
        /// Holes: operation, turn, call ordinal, Action, rejection, the three field contents.
        pub const call = .{ "{\"operation\":\"", Hole.decimal, "\",\"turn\":\"", Hole.decimal, "\",\"call_ordinal\":\"", Hole.decimal, "\",\"action\":", Hole.optional_id, ",\"rejection\":", Hole{ .optional_tag = ProposalRejection }, ",\"fields\":[", Hole{ .json = Content }, ",", Hole{ .json = Content }, ",", Hole{ .json = Content }, "]}" };
        /// Holes: content, presentation.
        pub const tool_result = .{ "{\"content\":", Hole{ .json = Content }, ",\"presentation\":", Hole{ .json = ToolPresentation }, "}" };
        /// A call the provider ran, shown by its line alone. Hole: presentation.
        pub const hosted_call = .{ "{\"presentation\":", Hole{ .json = ToolPresentation }, "}" };
        /// Holes: turn, operation, ending, code, content.
        pub const turn_ended = .{ "{\"turn\":\"", Hole.decimal, "\",\"operation\":\"", Hole.decimal, "\",\"ending\":\"", Hole{ .tag = TurnEnding }, "\",\"code\":", Hole{ .string = max_code_bytes }, ",\"content\":", Hole{ .optional_json = Content }, "}" };
        /// Holes: key, turn, cutoff, completion.
        pub const stop = .{ "{\"key\":", Hole{ .string = max_key_bytes }, ",\"turn\":", Hole.optional_id, ",\"cutoff\":\"", Hole.decimal, "\",\"completion\":\"", Hole{ .tag = SessionStopCompletion }, "\"}" };
        /// Holes: admission, admitted at, target, content.
        pub const sent = .{ "{\"admission\":\"", Hole.decimal, "\",\"admitted_at\":\"", Hole.decimal, "\",\"target\":", Hole{ .json = NamedPeer }, ",\"content\":", Hole{ .json = Content }, "}" };
        /// Holes: key, target, code.
        pub const send_failed = .{ "{\"key\":", Hole{ .string = max_key_bytes }, ",\"target\":", Hole{ .json = NamedPeer }, ",\"code\":", Hole{ .string = max_code_bytes }, "}" };
        /// Holes: action, operation, call ordinal.
        pub const approval_requested = .{ "{\"action\":\"", Hole.decimal, "\",\"operation\":\"", Hole.decimal, "\",\"call_ordinal\":\"", Hole.decimal, "\"}" };
        /// Holes: revision, field.
        pub const session_changed = .{ "{\"revision\":\"", Hole.decimal, "\",\"field\":\"", Hole{ .tag = SessionField }, "\"}" };
        /// Holes: operation, dropped.
        pub const compacted = .{ "{\"operation\":\"", Hole.decimal, "\",\"dropped\":\"", Hole.decimal, "\"}" };
    };
    pub const max_json_bytes = blk: {
        @setEvalBranchQuota(10_000);
        var bytes = 0;
        for (std.meta.tags(std.meta.Tag(Value))) |kind| bytes = @max(bytes, shapeBytes(head(kind)) + shapeBytes(@field(value_shapes, @tagName(kind))));
        break :blk bytes + shapeBytes(tail);
    };

    pub fn writeJson(self: *const ActivityItem, out: *std.Io.Writer) !void {
        switch (self.value) {
            inline else => |_, kind| try writeShape(out, head(kind), .{ self.position, self.ordinal, self.at }),
        }
        switch (self.value) {
            inline .admission, .user, .received => |message, tag| try writeShape(out, @field(value_shapes, @tagName(tag)), .{
                message.admission,   message.key.slice(), message.turn,    message.state,
                message.admitted_at, message.sender,      message.content,
            }),
            .sent => |sent| try writeShape(out, value_shapes.sent, .{ sent.admission, sent.admitted_at, sent.target, sent.content }),
            .send_failed => |failed| try writeShape(out, value_shapes.send_failed, .{ failed.key.slice(), failed.target, failed.code.slice() }),
            .approval_requested => |request| try writeShape(out, value_shapes.approval_requested, .{ request.action, request.operation, request.call_ordinal }),
            .session_changed => |change| try writeShape(out, value_shapes.session_changed, .{ change.revision, change.field }),
            .compacted => |compacted| try writeShape(out, value_shapes.compacted, .{ compacted.operation, compacted.dropped }),
            .assistant => |assistant| try writeShape(out, value_shapes.assistant, .{ assistant.content, assistant.final }),
            .tool_result => |result| try writeShape(out, value_shapes.tool_result, .{ result.content, result.presentation }),
            .hosted_call => |presentation| try writeShape(out, value_shapes.hosted_call, .{presentation}),
            .call => |call| {
                comptime std.debug.assert(call.fields.len == 3);
                var fields: [3]Content = undefined;
                for (call.fields, &fields) |field, *content| content.* = .{ .length = field.length, .digest = field.digest };
                try writeShape(out, value_shapes.call, .{ call.operation, call.turn, call.call_ordinal, call.action, call.rejection, fields[0], fields[1], fields[2] });
            },
            .turn_ended => |ended| try writeShape(out, value_shapes.turn_ended, .{ ended.turn, ended.operation, ended.ending, ended.code.slice(), ended.content }),
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

/// The Messages a person or script sent that a Session admitted and had not
/// taken at a page's boundary: not applied, and not excluded by a stop. A
/// stop and an input boundary both take an admission-order prefix, so they
/// are the newest such admissions. Zero when none waits.
pub const Queued = struct {
    count: u64 = 0,
    /// The oldest one's Admission position.
    oldest_position: u64 = 0,
    /// The newest one's admission ID and Admission position.
    newest_admission: u64 = 0,
    newest_position: u64 = 0,

    /// Holes: count, oldest position, newest admission, newest position.
    pub const shape = .{ "{\"count\":\"", Hole.decimal, "\",\"oldest_position\":\"", Hole.decimal, "\",\"newest_admission\":\"", Hole.decimal, "\",\"newest_position\":\"", Hole.decimal, "\"}" };
    pub const max_json_bytes = shapeBytes(shape);

    pub fn writeJson(self: *const Queued, out: *std.Io.Writer) !void {
        try writeShape(out, shape, .{ self.count, self.oldest_position, self.newest_admission, self.newest_position });
    }
};

pub const session_work = @import("session_work.zig");
pub const WorkState = session_work.WorkState;
pub const change_ring = @import("change_ring.zig");
/// A list reply's opaque change token.
pub const SinceToken = change_ring.Token;

comptime {
    std.debug.assert(session_work.max_code_bytes == max_code_bytes);
    std.debug.assert(session_work.max_description_bytes == max_tool_description_bytes);
}

/// The wire form of a `WorkState`: `kind` and `since`, then the kind's own
/// facts. Every reader writes it here, so they cannot drift apart.
pub const WorkStateJson = struct {
    state: WorkState,

    /// Holes: kind, since. The kinds that own no other fact.
    pub const plain_shape = .{ "{\"kind\":\"", Hole{ .tag = session_work.Kind }, "\",\"since\":\"", Hole.decimal, "\"}" };
    /// Holes: since, then the listed facts.
    pub const retrying_shape = .{ "{\"kind\":\"retrying\",\"since\":\"", Hole.decimal, "\",\"due_at_ms\":\"", Hole.decimal, "\",\"cause\":", Hole{ .string = max_code_bytes }, ",\"attempt\":\"", Hole.decimal, "\"}" };
    /// A running Host survives a Rui upgrade, so a reader still meets this
    /// form, from a Host that predates `call`.
    pub const older_bash_shape = .{ "{\"kind\":\"bash\",\"since\":\"", Hole.decimal, "\",\"description\":", Hole{ .optional_string = max_tool_description_bytes }, ",\"running\":\"", Hole.decimal, "\",\"approvals\":\"", Hole.decimal, "\"}" };
    pub const bash_shape = .{ "{\"kind\":\"bash\",\"since\":\"", Hole.decimal, "\",\"call\":\"", Hole.decimal, "\",\"description\":", Hole{ .optional_string = max_tool_description_bytes }, ",\"running\":\"", Hole.decimal, "\",\"approvals\":\"", Hole.decimal, "\"}" };
    pub const failed_shape = .{ "{\"kind\":\"failed\",\"since\":\"", Hole.decimal, "\",\"code\":", Hole{ .string = max_code_bytes }, ",\"resets_at\":", Hole.optional_id, "}" };
    pub const stopped_shape = .{ "{\"kind\":\"stopped\",\"since\":\"", Hole.decimal, "\",\"cause\":\"", Hole{ .tag = session_work.StopCause }, "\"}" };
    pub const max_json_bytes = maxShapeBytes(.{ plain_shape, retrying_shape, older_bash_shape, bash_shape, failed_shape, stopped_shape });

    pub fn writeJson(self: *const WorkStateJson, out: *std.Io.Writer) !void {
        switch (self.state) {
            .retrying => |value| try writeShape(out, retrying_shape, .{ value.since, value.due_at_ms, value.cause.slice(), value.attempt }),
            .bash => |value| {
                const description = if (value.description) |text| text.slice() else null;
                if (value.call) |call| try writeShape(out, bash_shape, .{ value.since, call, description, value.running, value.approvals }) else try writeShape(out, older_bash_shape, .{ value.since, description, value.running, value.approvals });
            },
            .failed => |value| try writeShape(out, failed_shape, .{ value.since, value.code.slice(), value.resets_at }),
            .stopped => |value| try writeShape(out, stopped_shape, .{ value.since, value.cause }),
            inline .idle, .pending, .working, .approval, .stopping, .finished => |value, kind| try writeShape(out, plain_shape, .{ kind, value.since }),
        }
    }
};

/// A Session's work, as list rows, activity pages and Current carry it: the
/// derived state, the latest Turn and Operation, and the earliest Action
/// awaiting permission.
pub const SessionWork = struct {
    state: WorkState = .{ .idle = .{ .since = 0 } },
    turn: ?u64 = null,
    operation: ?u64 = null,
    first_action: ?u64 = null,

    /// Holes: state, turn, operation, first action. Readers that add facts
    /// beside the work write these inside their own object.
    pub const fields = .{ "\"state\":", Hole{ .json = WorkStateJson }, ",\"turn\":", Hole.optional_id, ",\"operation\":", Hole.optional_id, ",\"first_action\":", Hole.optional_id };
    pub const json_shape = .{"{"} ++ fields ++ .{"}"};
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn fromCore(work: session_work.Work) SessionWork {
        return .{ .state = work.state, .turn = work.turn, .operation = work.operation, .first_action = work.first_action };
    }

    pub fn core(self: SessionWork) session_work.Work {
        return .{ .state = self.state, .turn = self.turn, .operation = self.operation, .first_action = self.first_action };
    }

    pub fn args(self: *const SessionWork) struct { WorkStateJson, ?u64, ?u64, ?u64 } {
        return .{ .{ .state = self.state }, self.turn, self.operation, self.first_action };
    }

    pub fn writeJson(self: *const SessionWork, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, self.args());
    }
};

/// The Session's work as of its page's own Store read: what the live footer,
/// consent and first Action show with that page, beside the revision and
/// Workspace a permission prompt shows.
pub const PageWork = struct {
    work: SessionWork = .{},
    revision: u64 = 0,
    workspace: Bounded(max_workspace_bytes) = .{},

    /// Holes: the work's fields, revision, Workspace.
    pub const json_shape = .{"{"} ++ SessionWork.fields ++ .{ ",\"revision\":\"", Hole.decimal, "\",\"workspace\":", Hole{ .string = max_workspace_bytes }, "}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn writeJson(self: *const PageWork, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, self.work.args() ++ .{ self.revision, self.workspace.slice() });
    }
};

/// Who reached this Session from outside its peers: when the latest Message
/// with no Session sender (a person or a script; Rui cannot tell them apart)
/// was admitted, or null if none was.
pub const PeerFacts = struct {
    from_person_at: ?u64 = null,

    pub const json_shape = .{ "{\"from_person_at\":", Hole.optional_id, "}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn writeJson(self: *const PeerFacts, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, .{self.from_person_at});
    }
};

/// The Session's first admitted Message, whatever happened to it. It never
/// changes once it exists.
pub const FirstMessage = struct {
    position: u64,
    admission: u64,
    admitted_at: u64,
    /// The Session that sent it, or null for a person or a script.
    sender: ?Peer,
    content: ActivityItem.Content,

    /// Holes: position, admission, admitted at, sender, content.
    pub const json_shape = .{ "{\"position\":\"", Hole.decimal, "\",\"admission\":\"", Hole.decimal, "\",\"admitted_at\":\"", Hole.decimal, "\",\"sender\":", Hole{ .optional_json = Peer }, ",\"content\":", Hole{ .json = ActivityItem.Content }, "}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn writeJson(self: *const FirstMessage, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, .{ self.position, self.admission, self.admitted_at, self.sender, self.content });
    }
};

pub const PermissionMode = cli_value.PermissionMode;

/// One `list-sessions` row. Every fact comes from the Store read that
/// produced its page.
pub const SessionRow = struct {
    reference: Bounded(max_session_bytes) = .{},
    workspace: Bounded(max_workspace_bytes) = .{},
    provider: Provider = .codex,
    model: Bounded(max_model_bytes) = .{},
    tools: ToolsField = .{ .state = .value },
    permission_mode: PermissionMode = .ask,
    parent: ?Bounded(session_id_bytes) = null,
    label: ?Bounded(max_label_bytes) = null,
    created_at: u64 = 0,
    revision: u64 = 0,
    /// The last activity position: a forward activity read from an earlier
    /// `end` shows what changed since.
    end: u64 = 0,
    first_message: ?FirstMessage = null,
    work: SessionWork = .{},
    peers: PeerFacts = .{},

    pub const json_shape = .{
        "{\"reference\":",    Hole{ .string = max_session_bytes },         ",\"workspace\":",         Hole{ .string = max_workspace_bytes },
        ",\"provider\":\"",   Hole{ .tag = Provider },                     "\",\"model\":",           Hole{ .string = max_model_bytes },
        ",\"tools\":",        Hole{ .text = max_tool_names_json_bytes },   ",\"permission_mode\":\"", Hole{ .tag = PermissionMode },
        "\",\"parent\":",     Hole{ .optional_string = session_id_bytes }, ",\"label\":",             Hole{ .optional_string = max_label_bytes },
        ",\"created_at\":\"", Hole.decimal,                                "\",\"revision\":\"",      Hole.decimal,
        "\",\"end\":\"",      Hole.decimal,                                "\",\"first_message\":",   Hole{ .optional_json = FirstMessage },
        ",\"work\":",         Hole{ .json = SessionWork },                 ",\"peers\":",             Hole{ .json = PeerFacts },
        "}",
    };
    pub const max_json_bytes = shapeBytes(json_shape);
    /// A row may never exceed this, whatever its fields hold: a new field that
    /// would grow every page's scratch charge past it fails the build.
    pub const budget_bytes = 36 * 1024;
    comptime {
        std.debug.assert(max_json_bytes <= budget_bytes);
    }

    /// A row's fields borrowed from wherever they are held, such as a Store
    /// read's row: the one place that orders them into `json_shape`.
    pub const Fields = struct {
        reference: []const u8,
        workspace: []const u8,
        provider: Provider,
        model: []const u8,
        /// Already-rendered JSON borrowed from the Store read.
        tools: []const u8,
        permission_mode: PermissionMode,
        parent: ?[]const u8,
        label: ?[]const u8,
        created_at: u64,
        revision: u64,
        end: u64,
        first_message: ?FirstMessage,
        work: *const SessionWork,
        peers: *const PeerFacts,

        pub const max_json_bytes = SessionRow.max_json_bytes;

        pub fn writeJson(f: *const Fields, out: *std.Io.Writer) !void {
            try writeShape(out, json_shape, .{
                f.reference,  f.workspace,       f.provider, f.model,
                f.tools,      f.permission_mode, f.parent,   f.label,
                f.created_at, f.revision,        f.end,      f.first_message,
                f.work,       f.peers,
            });
        }
    };

    pub fn writeJson(self: *const SessionRow, out: *std.Io.Writer) !void {
        var tools_buffer: [max_tool_names_json_bytes]u8 = undefined;
        var tools_writer = std.Io.Writer.fixed(&tools_buffer);
        try tools_writer.writeByte('[');
        var names = self.tools.iterator();
        var first = true;
        while (names.next()) |name| {
            if (!first) try tools_writer.writeByte(',');
            first = false;
            try tools_writer.print("\"{s}\"", .{name});
        }
        try tools_writer.writeByte(']');
        const fields: Fields = .{
            .reference = self.reference.slice(),
            .workspace = self.workspace.slice(),
            .provider = self.provider,
            .model = self.model.slice(),
            .tools = tools_writer.buffered(),
            .permission_mode = self.permission_mode,
            .parent = if (self.parent) |*parent| parent.slice() else null,
            .label = if (self.label) |*label| label.slice() else null,
            .created_at = self.created_at,
            .revision = self.revision,
            .end = self.end,
            .first_message = self.first_message,
            .work = &self.work,
            .peers = &self.peers,
        };
        try fields.writeJson(out);
    }
};

/// A `list-sessions` reply: up to eight rows, what they answer relative to
/// the request's `since`, the next token, then the continuation.
pub const session_list_reply = struct {
    pub const head = .{"{\"version\":\"" ++ wire_version ++ "\",\"type\":\"session_list\",\"sessions\":["};
    /// Holes: delta, token.
    const facts = .{ "],\"delta\":\"", Hole{ .tag = ListDelta }, "\",\"since\":\"", Hole{ .text = SinceToken.max_bytes }, "\",\"next\":" };
    /// Holes: delta, token, after, ceiling.
    pub const full_tail = facts ++ .{ "{\"after\":\"", Hole.decimal, "\",\"ceiling\":\"", Hole.decimal, "\"}}" };
    /// Holes: delta, token, through, after reference.
    pub const changed_tail = facts ++ .{ "{\"through\":\"", Hole.decimal, "\",\"after_reference\":", Hole{ .string = session_id_bytes }, "}}" };
    /// Holes: delta, token.
    pub const last_tail = facts ++ .{"null}"};
    pub const max_bytes = shapeBytes(head) + jsonListBytes(session_list_page_size, SessionRow.max_json_bytes) + maxShapeBytes(.{ full_tail, changed_tail, last_tail });
};

pub const ActivityFacts = struct {
    end: u64,
    direction: @FieldType(ActivityPage, "direction") = .forward,
    items: [16]ActivityItem = undefined,
    count: usize = 0,
    more: bool = false,
    call_activity: CallActivity = .{},
    /// At the same boundary as `call_activity`.
    queued: Queued = .{},
    work: PageWork = .{},

    /// Holes: end, direction; then the items, then `tail`.
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"activity_page\",\"end\":\"", Hole.decimal, "\",\"direction\":\"", Hole{ .tag = @FieldType(ActivityPage, "direction") }, "\",\"items\":[" };
    /// Holes: more, call activity, queued, work.
    pub const tail = .{ "],\"more\":", Hole.boolean, ",\"call_activity\":", Hole{ .json = CallActivity }, ",\"queued\":", Hole{ .json = Queued }, ",\"work\":", Hole{ .json = PageWork }, "}" };
    pub const max_json_bytes = shapeBytes(head) + jsonListBytes(@typeInfo(@FieldType(ActivityFacts, "items")).array.len, ActivityItem.max_json_bytes) + shapeBytes(tail);

    pub fn writeJson(self: *const ActivityFacts, out: *std.Io.Writer) !void {
        try writeShape(out, head, .{ self.end, self.direction });
        for (self.items[0..self.count], 0..) |*item, index| {
            if (index != 0) try out.writeByte(',');
            try item.writeJson(out);
        }
        try writeShape(out, tail, .{ self.more, &self.call_activity, &self.queued, &self.work });
    }
};

pub const Request = union(Kind) {
    host_info: struct { store: Bounded(max_store_bytes) = .{} },
    host_stop: struct { store: Bounded(max_store_bytes) = .{} },
    /// Sets whether the Host holds every new Turn (D193).
    host_pause: struct { store: Bounded(max_store_bytes) = .{}, paused: bool = false },
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
    activity_page: ActivityPage,
    activity_content: ReadActivityContent,
    model_list: struct { store: Bounded(max_store_bytes) = .{} },

    pub fn removeTemporaryContent(self: *Request, io: std.Io) !void {
        switch (self.*) {
            .configure => |*command| try command.removeTemporaryContent(io),
            .message => |*command| try command.removeTemporaryContent(io),
            .host_info, .host_stop, .host_pause, .session_stop, .model_interruption, .permission_decision, .observe_command, .read_result, .read_action_call_id, .read_action_arguments, .inspect_session, .list_sessions, .conversation_page, .conversation_content, .activity_page, .activity_content, .model_list => {},
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

fn hashTools(hash: *std.crypto.hash.sha2.Sha256, tools: *const ToolsField) void {
    hash.update(&.{@backingInt(tools.state)});
    if (tools.state == .value) {
        hash.update(&.{tools.count});
        var names = tools.iterator();
        while (names.next()) |name| hashField(hash, name);
    }
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
    content_length: u64,
    scratch_path: []const u8,
    request_number: u64,
    content_faults: ContentFaults = .{},
    retained_scratch: *?named_scratch.Owner,
    scratch_budget: ?ScratchBudget = null,
    expected_kind: ?Kind = null,
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
    /// Where the next byte goes: the metadata, the opening quote of a
    /// content string, or `capture`.
    content_state: enum { metadata, awaiting_quote, capturing } = .metadata,
    /// Live while `content_state` is `.capturing`.
    capture: ContentCapture = undefined,
    decoder: StringDecoder = .{},
    contents: [max_request_contents]ContentField = @splat(.{}),
    content_count: usize = 0,
    complete: bool = false,
    /// The one home of the parsed Request: preview and finish parse into it.
    /// After finish, the Ingress's owner borrows it until it releases the Ingress.
    request: Request = undefined,

    // Initial Message combines configuration scalars and sender identity.
    // Allow worst-case escaping of both, of a full `tools` list, and of 128
    // short grammar tokens (keys, states and literals, each at most 32
    // bytes), plus punctuation and one preserved whitespace separator at
    // every lexical boundary.
    const metadata_limit = 2 * (6 * (max_store_bytes + max_key_bytes + max_session_bytes +
        max_workspace_bytes + max_provider_bytes + max_model_bytes + 16 + 2 * max_tool_list_name_bytes + 128 * 32) + (128 + 2 * max_tools) * 8);

    /// Builds the Ingress in its home. `request` stays unwritten.
    pub fn init(self: *Ingress, allocator: std.mem.Allocator, options: ParseOptions) void {
        self.* = .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *Ingress) void {
        if (self.content_state == .capturing) self.capture.deinit();
        self.content_state = .metadata;
        for (&self.contents) |*field| removeContent(field, self.options.io) catch unreachable;
        self.metadata.deinit(self.allocator);
        self.metadata = .empty;
    }

    pub fn feed(self: *Ingress, bytes: []const u8) !void {
        if (bytes.len > self.options.content_length - self.received) return error.TrailingInput;
        for (bytes) |byte| {
            if (self.complete) return error.TrailingInput;
            self.received += 1;
            switch (self.content_state) {
                .metadata => {},
                .awaiting_quote => {
                    switch (byte) {
                        ' ', '\t', '\r', '\n' => continue,
                        '"' => {},
                        else => return error.InvalidJsonShape,
                    }
                    try self.capture.init(self.options, @intCast(self.content_count + 1));
                    self.content_state = .capturing;
                    self.decoder = .{};
                    continue;
                },
                .capturing => {
                    if (try self.decoder.feed(byte, &self.capture.sink)) {
                        self.contents[self.content_count] = try self.capture.seal();
                        self.content_count += 1;
                        self.capture.deinit();
                        self.content_state = .metadata;
                        try self.append('"');
                        try self.append('"');
                        try self.preview();
                    }
                    continue;
                },
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

    fn parse(self: *Ingress) !void {
        var source: MetadataSource = .{ .input = self.metadata.items };
        var parser = Parser{
            .source = &source,
            .options = self.options,
            .captured = self.contents[0..self.content_count],
        };
        try parser.parse(&self.request);
        std.debug.assert(parser.content_ordinal == self.content_count);
    }

    fn preview(self: *Ingress) !void {
        self.parse() catch |err| switch (err) {
            error.NeedInput => return,
            error.NeedContent => {
                std.debug.assert(self.content_count < self.contents.len);
                self.content_state = .awaiting_quote;
                return;
            },
            else => return err,
        };
        self.complete = true;
        if (self.received != self.options.content_length) return error.TrailingInput;
    }

    /// Parses the complete body into `request`, moves the captured content
    /// into it, and returns it.
    pub fn finish(self: *Ingress) !*Request {
        if (self.received != self.options.content_length) return error.UnexpectedEndOfBody;
        self.parse() catch |err| switch (err) {
            error.NeedInput, error.NeedContent => return error.UnexpectedEndOfBody,
            else => return err,
        };
        const request = &self.request;
        // All fallible validation precedes this non-failing custody transfer.
        // Each value takes the capture its string arrived in, whatever the
        // members' order.
        var moved: usize = 0;
        switch (request.*) {
            .configure => |*command| {
                for ([_]*ContentField{ &command.configuration.instructions, &command.configuration.output_schema }) |field| {
                    if (field.state != .value) continue;
                    self.take(field);
                    moved += 1;
                }
            },
            .message => |*command| {
                self.take(&command.text);
                moved = 1;
            },
            else => {},
        }
        std.debug.assert(moved == self.content_count);
        self.metadata.deinit(self.allocator);
        self.metadata = .empty;
        return request;
    }

    fn take(self: *Ingress, field: *ContentField) void {
        const index = field.capture - 1;
        field.* = self.contents[index];
        self.contents[index] = .{};
    }
};

// One absolute budget; progress cannot extend an absolute exchange.
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

/// The metadata an Ingress has received so far, the Parser's only input.
/// Content strings never reach it: the Ingress captures them.
const MetadataSource = struct {
    input: []const u8,
    start: usize = 0,

    fn readByte(self: *MetadataSource) !u8 {
        if (self.start == self.input.len) return error.NeedInput;
        const byte = self.input[self.start];
        self.start += 1;
        return byte;
    }

    fn atEnd(self: *const MetadataSource) bool {
        return self.start == self.input.len;
    }
};

const Parser = struct {
    source: *MetadataSource,
    options: ParseOptions,
    content_ordinal: u8 = 0,
    captured: []const ContentField = &.{},

    /// Members of every request object may come in any order, as JSON
    /// allows, so a client generated in any language can build one (D212).
    /// The first pass reads `version`, `kind` and `store` wherever they sit
    /// and counts content strings as they arrive; the second sets the
    /// command's arm in `out` and fills it in place, meeting the content
    /// strings in the same order.
    fn parse(self: *Parser, out: *Request) !void {
        const start = self.source.start;
        const header = try self.scanHeader();
        self.source.start = start;
        self.content_ordinal = 0;
        try self.expectByte('{');
        var members: Members = .{};
        const store = header.store;
        // Each arm is a literal written straight into `out`, then filled in
        // place: @unionInit would build a whole Request on the stack first.
        switch (header.kind) {
            .host_info => {
                out.* = .{ .host_info = .{ .store = store } };
                try self.endCommand(&members);
            },
            .host_stop => {
                out.* = .{ .host_stop = .{ .store = store } };
                try self.endCommand(&members);
            },
            .host_pause => {
                out.* = .{ .host_pause = .{ .store = store } };
                try self.parseHostPause(&out.host_pause, &members);
            },
            .model_list => {
                out.* = .{ .model_list = .{ .store = store } };
                try self.endCommand(&members);
            },
            .configure => {
                out.* = .{ .configure = .{ .store = store, .configuration = .{ .workspace = .{ .value = .{ .len = 0 } } } } };
                try self.parseConfigure(&out.configure, &members);
            },
            .message => {
                out.* = .{ .message = .{ .store = store } };
                try self.parseMessage(&out.message, &members);
            },
            .session_stop => {
                out.* = .{ .session_stop = .{ .store = store } };
                try self.parseSessionStop(&out.session_stop, &members);
            },
            .model_interruption => {
                out.* = .{ .model_interruption = .{ .store = store } };
                try self.parseModelInterruption(&out.model_interruption, &members);
            },
            .permission_decision => {
                out.* = .{ .permission_decision = .{ .store = store } };
                try self.parsePermissionDecision(&out.permission_decision, &members);
            },
            .observe_command => {
                out.* = .{ .observe_command = .{ .store = store } };
                try self.parseKeyOnly(&out.observe_command.key, &members);
            },
            .read_result => {
                out.* = .{ .read_result = .{ .store = store } };
                try self.parseKeyOnly(&out.read_result.key, &members);
            },
            .read_action_call_id => {
                out.* = .{ .read_action_call_id = .{ .store = store } };
                try self.parseReadActionArguments(&out.read_action_call_id, &members);
            },
            .read_action_arguments => {
                out.* = .{ .read_action_arguments = .{ .store = store } };
                try self.parseReadActionArguments(&out.read_action_arguments, &members);
            },
            .inspect_session => {
                out.* = .{ .inspect_session = .{ .store = store } };
                try self.parseInspect(&out.inspect_session, &members);
            },
            .list_sessions => {
                out.* = .{ .list_sessions = .{ .store = store } };
                try self.parseListSessions(&out.list_sessions, &members);
            },
            .conversation_page => {
                out.* = .{ .conversation_page = .{ .store = store } };
                try self.parseConversationPage(&out.conversation_page, &members);
            },
            .conversation_content => {
                out.* = .{ .conversation_content = .{ .store = store } };
                try self.parseConversationContent(&out.conversation_content, &members);
            },
            .activity_page => {
                out.* = .{ .activity_page = .{ .store = store } };
                try self.parseActivityPage(&out.activity_page, &members);
            },
            .activity_content => {
                out.* = .{ .activity_content = .{ .store = store } };
                try self.parseActivityContent(&out.activity_content, &members);
            },
        }
        errdefer out.removeTemporaryContent(self.options.io) catch unreachable;
        if (!self.source.atEnd()) {
            return error.TrailingInput;
        }
    }

    const Header = struct { kind: Kind, store: Bounded(max_store_bytes) };

    /// The first pass. It passes over every member but the header, except
    /// that it counts a content string where a Message's text or a
    /// configuration's instructions or output schema holds one, so the
    /// Ingress captures it whatever the order. Once `kind` is known, content
    /// the kind cannot carry fails before any capture.
    fn scanHeader(self: *Parser) !Header {
        const Field = enum { version, kind, store, text, configuration };
        try self.expectByte('{');
        var members: Members = .{};
        var seen: std.EnumSet(Field) = .empty;
        var kind: ?Kind = null;
        var store: Bounded(max_store_bytes) = .{};
        var key: Bounded(32) = .{};
        while (try members.next(self, &key)) {
            const field = std.meta.stringToEnum(Field, key.slice()) orelse {
                try self.skipValue();
                continue;
            };
            if (seen.contains(field)) return error.UnexpectedField;
            seen.insert(field);
            switch (field) {
                .version => {
                    var version: Bounded(8) = .{};
                    try self.readSmallString(&version);
                    if (!version.eql(wire_version)) return error.WrongWireVersion;
                },
                .kind => {
                    var text: Bounded(32) = .{};
                    try self.readSmallString(&text);
                    const named = std.meta.stringToEnum(Kind, text.slice()) orelse return error.UnknownCommand;
                    if (self.options.expected_kind) |expected| {
                        if (named != expected) return error.RouteKindMismatch;
                    }
                    kind = named;
                },
                .store => try self.readSmallString(&store),
                .text => {
                    if (kind) |named| if (named != .message) return error.UnexpectedField;
                    try self.scanContentEnvelope(true);
                },
                .configuration => {
                    if (kind) |named| if (named != .configure and named != .message) return error.UnexpectedField;
                    // Only a configure command's configuration carries content.
                    try self.scanConfiguration(if (kind) |named| named == .configure else true);
                },
            }
        }
        if (!seen.contains(.version) or !seen.contains(.store)) return error.MissingField;
        return .{ .kind = kind orelse return error.MissingField, .store = store };
    }

    fn scanConfiguration(self: *Parser, content: bool) !void {
        try self.expectByte('{');
        var members: Members = .{};
        var instructions = false;
        var output_schema = false;
        var key: Bounded(32) = .{};
        while (try members.next(self, &key)) {
            const seen = if (key.eql("instructions"))
                &instructions
            else if (key.eql("output_schema"))
                &output_schema
            else {
                try self.skipValue();
                continue;
            };
            if (seen.*) return error.UnexpectedField;
            seen.* = true;
            try self.scanContentEnvelope(content);
        }
    }

    fn scanContentEnvelope(self: *Parser, content: bool) !void {
        try self.expectByte('{');
        var members: Members = .{};
        var value = false;
        var key: Bounded(32) = .{};
        while (try members.next(self, &key)) {
            if (!key.eql("value")) {
                try self.skipValue();
                continue;
            }
            if (value) return error.UnexpectedField;
            if (!content) return error.InvalidFieldState;
            value = true;
            // A third content string has no capture to go to.
            if (self.content_ordinal == max_request_contents) return error.UnexpectedField;
            var counted: ContentField = .{};
            try self.readContentString(&counted);
        }
    }

    /// Walks one object's members after its opening brace.
    const Members = struct {
        started: bool = false,

        /// Reads the next member's key and colon, or the closing brace.
        fn next(self: *Members, parser: *Parser, key: *Bounded(32)) !bool {
            if (try parser.consumeIf('}')) return false;
            if (self.started) try parser.expectByte(',');
            self.started = true;
            key.* = .{};
            parser.readSmallString(key) catch |err| return switch (err) {
                error.ValueTooLong => error.UnexpectedField,
                else => err,
            };
            try parser.expectByte(':');
            return true;
        }
    };

    /// The next member of an object whose keys are `Field`'s names, each at
    /// most once, in any order.
    fn nextField(self: *Parser, comptime Field: type, members: *Members, seen: *std.EnumSet(Field)) !?Field {
        var key: Bounded(32) = .{};
        if (!try members.next(self, &key)) return null;
        return try fieldOf(Field, &key, seen);
    }

    /// The command's next member, passing over the header the first pass read.
    fn nextCommandField(self: *Parser, comptime Field: type, members: *Members, seen: *std.EnumSet(Field)) !?Field {
        var key: Bounded(32) = .{};
        while (try members.next(self, &key)) {
            if (isHeader(&key)) {
                try self.skipValue();
                continue;
            }
            return try fieldOf(Field, &key, seen);
        }
        return null;
    }

    /// Finishes a command that has no members beyond its header.
    fn endCommand(self: *Parser, members: *Members) !void {
        var key: Bounded(32) = .{};
        while (try members.next(self, &key)) {
            if (!isHeader(&key)) return error.UnexpectedField;
            try self.skipValue();
        }
    }

    fn isHeader(key: *const Bounded(32)) bool {
        return key.eql("version") or key.eql("kind") or key.eql("store");
    }

    fn fieldOf(comptime Field: type, key: *const Bounded(32), seen: *std.EnumSet(Field)) !Field {
        const field = std.meta.stringToEnum(Field, key.slice()) orelse return error.UnexpectedField;
        if (seen.contains(field)) return error.UnexpectedField;
        seen.insert(field);
        return field;
    }

    fn require(comptime Field: type, seen: std.EnumSet(Field), required: []const Field) !void {
        for (required) |field| if (!seen.contains(field)) return error.MissingField;
    }

    fn parseHostPause(self: *Parser, out: *@FieldType(Request, "host_pause"), members: *Members) !void {
        const Field = enum { paused };
        var seen: std.EnumSet(Field) = .empty;
        while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
            .paused => out.paused = try self.readBoolean(),
        };
        try require(Field, seen, &.{.paused});
    }

    fn parseKeyOnly(self: *Parser, key: *Bounded(max_key_bytes), members: *Members) !void {
        const Field = enum { key };
        var seen: std.EnumSet(Field) = .empty;
        while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
            .key => try self.readSmallString(key),
        };
        try require(Field, seen, &.{.key});
    }

    /// Each parser fills its command `out`, whose Store is already set.
    fn parseConfigure(self: *Parser, out: *ConfigureCommand, members: *Members) !void {
        errdefer out.removeTemporaryContent(self.options.io) catch unreachable;
        const Field = enum { key, session, configuration, require_model };
        var seen: std.EnumSet(Field) = .empty;
        while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
            .key => try self.readCommandKey(&out.key),
            .session => try self.readSmallString(&out.session),
            .configuration => try self.parseConfiguration(true, &out.configuration),
            .require_model => out.require_model = try self.readBoolean(),
        };
        try require(Field, seen, &.{ .key, .session, .configuration });
    }

    /// Fills `out`, which holds its defaults.
    fn parseConfiguration(self: *Parser, allow_content: bool, out: *Configuration) !void {
        errdefer out.removeTemporaryContent(self.options.io) catch unreachable;
        const Field = enum { workspace, provider, model, instructions, tools, loaded_tools, permission_mode, output_schema, compaction_trigger, output_reservation, reasoning_effort, label };
        try self.expectByte('{');
        var members: Members = .{};
        var seen: std.EnumSet(Field) = .empty;
        while (try self.nextField(Field, &members, &seen)) |field| switch (field) {
            .workspace => try self.readOptionalSmall(max_workspace_bytes, &out.workspace),
            .provider => try self.readOptionalSmall(max_provider_bytes, &out.provider),
            .model => try self.readOptionalSmall(max_model_bytes, &out.model),
            .instructions => try self.readContent(&out.instructions, false, allow_content),
            .tools => try self.readTools(&out.tools),
            .loaded_tools => try self.readTools(&out.loaded_tools),
            .permission_mode => try self.readOptionalSmall(16, &out.permission_mode),
            .output_schema => try self.readContent(&out.output_schema, true, allow_content),
            .compaction_trigger => try self.readOptionalPolicy(&out.compaction_trigger),
            .output_reservation => try self.readOptionalPolicy(&out.output_reservation),
            .reasoning_effort => try self.readOptionalSmallNullable(16, &out.reasoning_effort, true),
            .label => try self.readOptionalSmallNullable(max_label_bytes, &out.label, true),
        };
        try require(Field, seen, &.{ .workspace, .provider, .model, .instructions, .tools, .permission_mode, .output_schema });
    }

    fn parseMessage(self: *Parser, out: *MessageCommand, members: *Members) !void {
        errdefer out.removeTemporaryContent(self.options.io) catch unreachable;
        const Field = enum { key, session, sender, sender_handle, configuration, text, require_model };
        var seen: std.EnumSet(Field) = .empty;
        while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
            .key => try self.readCommandKey(&out.key),
            .session => try self.readSmallString(&out.session),
            .sender => if (!try self.readNull()) {
                out.sender = .{};
                try self.parseAddress(&out.sender.?);
                try out.sender.?.validate();
            },
            .sender_handle => if (!try self.readNull()) {
                out.sender_handle = .{};
                try self.readSmallString(&out.sender_handle.?);
            },
            .configuration => {
                out.configuration = .{ .workspace = .{ .value = .{ .len = 0 } } };
                try self.parseConfiguration(false, &out.configuration.?);
            },
            .text => try self.readContent(&out.text, false, true),
            .require_model => out.require_model = try self.readBoolean(),
        };
        try require(Field, seen, &.{ .key, .session, .sender, .sender_handle, .text });
        // Only a creating Message, one with no Session yet, carries a
        // configuration and a capability condition, and it must carry the
        // configuration.
        if (out.session.len == 0 and out.configuration == null) return error.MissingField;
        if (out.session.len != 0 and out.configuration != null) return error.UnexpectedField;
        if (out.text.state != .value) return error.InvalidMessage;
        if (seen.contains(.require_model) and out.configuration == null) return error.InvalidMessage;
    }

    fn parseAddress(self: *Parser, out: *Address) !void {
        const Field = enum { store, session };
        try self.expectByte('{');
        var members: Members = .{};
        var seen: std.EnumSet(Field) = .empty;
        while (try self.nextField(Field, &members, &seen)) |field| switch (field) {
            .store => try self.readSmallString(&out.store),
            .session => try self.readSmallString(&out.session),
        };
        try require(Field, seen, &.{ .store, .session });
    }

    fn parseSessionStop(self: *Parser, out: *SessionStopCommand, members: *Members) !void {
        const Field = enum { key, session };
        var seen: std.EnumSet(Field) = .empty;
        while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
            .key => try self.readCommandKey(&out.key),
            .session => try self.readSmallString(&out.session),
        };
        try require(Field, seen, &.{ .key, .session });
    }

    fn parseModelInterruption(self: *Parser, out: *ModelInterruptionCommand, members: *Members) !void {
        const Field = enum { key, target };
        var seen: std.EnumSet(Field) = .empty;
        while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
            .key => try self.readCommandKey(&out.key),
            .target => {
                const Target = enum { session, turn, operation };
                try self.expectByte('{');
                var target_members: Members = .{};
                var target_seen: std.EnumSet(Target) = .empty;
                while (try self.nextField(Target, &target_members, &target_seen)) |member| switch (member) {
                    .session => try self.readSmallString(&out.session),
                    .turn => out.turn_id = try self.readCanonicalU64(),
                    .operation => out.operation_id = try self.readCanonicalU64(),
                };
                try require(Target, target_seen, &.{ .session, .turn, .operation });
            },
        };
        try require(Field, seen, &.{ .key, .target });
    }

    fn parsePermissionDecision(self: *Parser, out: *PermissionDecisionCommand, members: *Members) !void {
        const Field = enum { key, session, action, decision };
        var seen: std.EnumSet(Field) = .empty;
        while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
            .key => try self.readCommandKey(&out.key),
            .session => try self.readSmallString(&out.session),
            .action => out.action_id = try self.readCanonicalU64(),
            .decision => {
                var decision: Bounded(16) = .{};
                try self.readSmallString(&decision);
                out.decision = if (decision.eql("deny"))
                    .deny
                else if (decision.eql("allow_once"))
                    .allow_once
                else
                    return error.UnsupportedPermissionDecision;
            },
        };
        try require(Field, seen, &.{ .key, .session, .action, .decision });
    }

    fn parseReadActionArguments(self: *Parser, out: *ReadActionArguments, members: *Members) !void {
        const Field = enum { session, action };
        var seen: std.EnumSet(Field) = .empty;
        while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
            .session => try self.readSmallString(&out.session),
            .action => out.action_id = try self.readCanonicalU64(),
        };
        try require(Field, seen, &.{ .session, .action });
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

    fn parseInspect(self: *Parser, out: *InspectSession, members: *Members) !void {
        const Field = enum { session, profile, failed_response, operation, attempt };
        var seen: std.EnumSet(Field) = .empty;
        var part: ?FailedResponsePart = null;
        var operation: u64 = 0;
        var attempt: u64 = 0;
        while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
            .session => try self.readSmallString(&out.session),
            .profile => {
                var profile: Bounded(16) = .{};
                try self.readSmallString(&profile);
                out.profile = if (profile.eql("full")) .full else return error.UnknownReportProfile;
            },
            .failed_response => {
                var text: Bounded(16) = .{};
                try self.readSmallString(&text);
                part = std.meta.stringToEnum(FailedResponsePart, text.slice()) orelse return error.InvalidTarget;
            },
            .operation => operation = try self.readCanonicalU64(),
            .attempt => attempt = try self.readCanonicalU64(),
        };
        try require(Field, seen, &.{.session});
        // A report profile or one failed response stream, never both; the
        // stream is named by its Operation and attempt.
        const selected = part orelse {
            if (seen.contains(.operation) or seen.contains(.attempt)) return error.UnexpectedField;
            return;
        };
        if (seen.contains(.profile)) return error.UnexpectedField;
        try require(Field, seen, &.{ .operation, .attempt });
        if (operation == 0 or operation > std.math.maxInt(i64) or attempt == 0 or attempt > std.math.maxInt(i64)) return error.InvalidTarget;
        out.failed_response = .{ .operation = operation, .attempt = attempt, .part = selected };
    }

    fn parseListSessions(self: *Parser, out: *ListSessions, members: *Members) !void {
        const Field = enum { workspace, after, ceiling, since, through, after_reference };
        var seen: std.EnumSet(Field) = .empty;
        var through: u64 = 0;
        var reference: Bounded(session_id_bytes) = .{};
        while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
            .workspace => if (!try self.readNull()) {
                out.workspace = .{ .len = 0 };
                try self.readSmallString(&out.workspace.?);
            },
            .after => out.after = try self.readCanonicalU64(),
            .ceiling => out.ceiling = try self.readCanonicalU64(),
            .since => {
                var token: Bounded(SinceToken.max_bytes) = .{};
                try self.readSmallString(&token);
                out.since = SinceToken.parse(token.slice()) catch return error.InvalidCursor;
            },
            .through => through = try self.readCanonicalU64(),
            .after_reference => {
                try self.readSmallString(&reference);
                if (reference.len != session_id_bytes) return error.InvalidCursor;
            },
        };
        try require(Field, seen, &.{ .workspace, .after, .ceiling });
        // A changed continuation names both its generation and its last
        // Session, and only follows a `since` token.
        if (seen.contains(.through) or seen.contains(.after_reference)) {
            if (!seen.contains(.through) or !seen.contains(.after_reference) or out.since == null) return error.InvalidCursor;
            out.changed = .{ .through = through, .after_reference = reference.bytes[0..session_id_bytes].* };
        }
        try out.validate();
    }

    fn parseConversationPage(self: *Parser, out: *ConversationPage, members: *Members) !void {
        const Field = enum { session, end, before_position, before_ordinal };
        var seen: std.EnumSet(Field) = .empty;
        while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
            .session => try self.readSmallString(&out.session),
            .end => out.end = try self.readCanonicalU64(),
            .before_position => out.before_position = try self.readCanonicalU64(),
            .before_ordinal => out.before_ordinal = try self.readCanonicalU64(),
        };
        try require(Field, seen, &.{ .session, .end, .before_position, .before_ordinal });
        if (out.end > std.math.maxInt(i64) or out.before_position > std.math.maxInt(i64) or
            out.before_ordinal > std.math.maxInt(i64) or
            (out.end == 0 and out.before_position != 0) or
            (out.before_position == 0 and out.before_ordinal != 0) or
            (out.end != 0 and out.before_position > out.end)) return error.InvalidCursor;
    }

    fn parseConversationContent(self: *Parser, out: *ConversationContent, members: *Members) !void {
        const Field = enum { session, position, ordinal, start, stream };
        var seen: std.EnumSet(Field) = .empty;
        while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
            .session => try self.readSmallString(&out.session),
            .position => out.position = try self.readCanonicalU64(),
            .ordinal => out.ordinal = try self.readCanonicalU64(),
            .start => out.start = try self.readCanonicalU64(),
            .stream => {
                for ("true") |byte| try self.expectByte(byte);
                out.stream = true;
            },
        };
        try require(Field, seen, &.{ .session, .position, .ordinal, .start });
        if (out.position == 0 or out.position > std.math.maxInt(i64) or
            out.ordinal > std.math.maxInt(i64) or (out.stream and out.start != 0)) return error.InvalidCursor;
    }

    fn parseActivityPage(self: *Parser, out: *ActivityPage, members: *Members) !void {
        const Field = enum { session, end, position, ordinal, direction, kinds, limit };
        var seen: std.EnumSet(Field) = .empty;
        while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
            .session => try self.readSmallString(&out.session),
            .end => if (!try self.readNull()) {
                out.end = try self.readCanonicalU64();
            },
            .position => out.position = try self.readCanonicalU64(),
            .ordinal => if (!try self.readNull()) {
                out.ordinal = try self.readCanonicalU64();
            },
            .direction => {
                var direction: Bounded(8) = .{};
                try self.readSmallString(&direction);
                out.direction = std.meta.stringToEnum(@FieldType(ActivityPage, "direction"), direction.slice()) orelse return error.InvalidCursor;
            },
            .kinds => {
                try self.expectByte('[');
                // Each kind at most once, in tag order, so one set has one spelling.
                out.kinds = .empty;
                var last: ?ActivityItem.Kind = null;
                if (!try self.consumeIf(']')) while (true) {
                    var name: Bounded(32) = .{};
                    try self.readSmallString(&name);
                    const kind = std.meta.stringToEnum(ActivityItem.Kind, name.slice()) orelse return error.InvalidCursor;
                    if (last) |previous| if (@backingInt(kind) <= @backingInt(previous)) return error.InvalidJsonShape;
                    out.kinds.insert(kind);
                    last = kind;
                    if (try self.consumeIf(']')) break;
                    try self.expectByte(',');
                };
            },
            .limit => out.limit = std.math.cast(u8, try self.readCanonicalU64()) orelse return error.InvalidCursor,
        };
        try require(Field, seen, &.{ .session, .end, .position, .ordinal, .direction, .kinds, .limit });
        try out.validate();
    }

    fn parseActivityContent(self: *Parser, out: *ReadActivityContent, members: *Members) !void {
        const Field = enum { session, position, ordinal };
        var seen: std.EnumSet(Field) = .empty;
        while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
            .session => try self.readSmallString(&out.session),
            .position => out.position = try self.readCanonicalU64(),
            .ordinal => out.ordinal = try self.readCanonicalU64(),
        };
        try require(Field, seen, &.{ .session, .position, .ordinal });
        if (out.position == 0 or out.position > std.math.maxInt(i64) or out.ordinal > std.math.maxInt(i64)) return error.InvalidCursor;
    }

    fn readOptionalPolicy(self: *Parser, field: *OptionalBounded(20)) !void {
        try self.readOptionalSmallNullable(20, field, true);
    }

    fn readOptionalSmall(self: *Parser, comptime capacity: usize, field: *OptionalBounded(capacity)) !void {
        try self.readOptionalSmallNullable(capacity, field, false);
    }

    /// The members of a `{"state":…,"value":…}` envelope.
    const Envelope = enum { state, value };

    /// An envelope's state, once its members are read: a value is present
    /// exactly when the state says so.
    fn envelopeState(state: *const Bounded(16), seen: std.EnumSet(Envelope), allow_null: bool) !FieldState {
        if (!seen.contains(.state)) return error.MissingField;
        const result: FieldState = if (state.eql("omitted"))
            .omitted
        else if (allow_null and state.eql("null"))
            .explicit_null
        else if (state.eql("value"))
            .value
        else
            return error.InvalidFieldState;
        if (seen.contains(.value) != (result == .value)) return error.InvalidFieldState;
        return result;
    }

    fn readOptionalSmallNullable(self: *Parser, comptime capacity: usize, field: *OptionalBounded(capacity), allow_null: bool) !void {
        try self.expectByte('{');
        var members: Members = .{};
        var seen: std.EnumSet(Envelope) = .empty;
        var state: Bounded(16) = .{};
        while (try self.nextField(Envelope, &members, &seen)) |member| switch (member) {
            .state => try self.readSmallString(&state),
            .value => try self.readSmallString(&field.value),
        };
        field.state = try envelopeState(&state, seen, allow_null);
    }

    fn readContent(self: *Parser, field: *ContentField, allow_null: bool, allow_value: bool) !void {
        try self.expectByte('{');
        var members: Members = .{};
        var seen: std.EnumSet(Envelope) = .empty;
        var state: Bounded(16) = .{};
        while (try self.nextField(Envelope, &members, &seen)) |member| switch (member) {
            .state => try self.readSmallString(&state),
            .value => {
                if (!allow_value) return error.InvalidFieldState;
                try self.readContentString(field);
            },
        };
        field.state = try envelopeState(&state, seen, allow_null);
    }

    fn readTools(self: *Parser, tools: *ToolsField) !void {
        try self.expectByte('{');
        var members: Members = .{};
        var seen: std.EnumSet(Envelope) = .empty;
        var state: Bounded(16) = .{};
        while (try self.nextField(Envelope, &members, &seen)) |member| switch (member) {
            .state => try self.readSmallString(&state),
            .value => {
                try self.expectByte('[');
                tools.* = .{};
                if (!try self.consumeIf(']')) while (true) {
                    var name: Bounded(max_tool_name_bytes) = .{};
                    self.readSmallString(&name) catch |err| return if (err == error.ValueTooLong) error.InvalidToolName else err;
                    if (!validToolName(name.slice())) return error.InvalidToolName;
                    // The Host offers the built-ins; MCP servers' tools join them later.
                    try tools.append(name.slice());
                    if (try self.consumeIf(']')) break;
                    try self.expectByte(',');
                };
            },
        };
        tools.state = try envelopeState(&state, seen, false);
    }

    /// Reads a literal null, or leaves the input where it was.
    fn readNull(self: *Parser) !bool {
        if (!try self.consumeIf('n')) return false;
        for ("ull") |expected| if (try self.source.readByte() != expected) return error.InvalidJsonShape;
        return true;
    }

    /// Passes over one value nested at most `max_skipped_depth` objects or
    /// arrays deep, without recursion.
    fn skipValue(self: *Parser) !void {
        const max_skipped_depth = 4;
        var closers: [max_skipped_depth]u8 = undefined;
        var depth: usize = 0;
        var discard: DiscardSink = .{};
        while (true) {
            try self.skipWhitespace();
            const first = try self.source.readByte();
            switch (first) {
                '"' => {
                    self.source.start -= 1;
                    try self.readJsonString(&discard);
                },
                't', 'f', 'n' => {
                    const rest: []const u8 = switch (first) {
                        't' => "rue",
                        'f' => "alse",
                        else => "ull",
                    };
                    for (rest) |expected| if (try self.source.readByte() != expected) return error.InvalidJsonShape;
                },
                '{', '[' => {
                    const closer: u8 = if (first == '{') '}' else ']';
                    if (!try self.consumeIf(closer)) {
                        if (depth == closers.len) return error.InvalidJsonShape;
                        closers[depth] = closer;
                        depth += 1;
                        if (closer == '}') try self.skipKey(&discard);
                        continue;
                    }
                },
                else => return error.InvalidJsonShape,
            }
            // A value ended: close each container it finished, then step to
            // the next element of the innermost open one.
            while (depth > 0) {
                if (try self.consumeIf(closers[depth - 1])) {
                    depth -= 1;
                    continue;
                }
                try self.expectByte(',');
                if (closers[depth - 1] == '}') try self.skipKey(&discard);
                break;
            }
            if (depth == 0) return;
        }
    }

    fn skipKey(self: *Parser, discard: *DiscardSink) !void {
        try self.readJsonString(discard);
        try self.expectByte(':');
    }

    /// A command's key. Keys under `reserved_key_prefix` are Rui's own
    /// commands', so a client command cannot take one first.
    fn readCommandKey(self: *Parser, key: *Bounded(max_key_bytes)) !void {
        try self.readSmallString(key);
        if (std.mem.startsWith(u8, key.slice(), reserved_key_prefix)) return error.ReservedCommandKey;
    }

    fn readSmallString(self: *Parser, destination: anytype) !void {
        var sink = SmallSink(@TypeOf(destination.*)){ .destination = destination };
        try self.readJsonString(&sink);
        if (!std.unicode.utf8ValidateSlice(destination.slice())) return error.InvalidUtf8;
    }

    /// Reads the empty placeholder the Ingress left for a captured string.
    fn readContentString(self: *Parser, field: *ContentField) !void {
        self.content_ordinal += 1;
        if (self.content_ordinal > self.captured.len) return error.NeedContent;
        try self.expectByte('"');
        if (try self.source.readByte() != '"') return error.InvalidJsonShape;
        const original = self.captured[self.content_ordinal - 1];
        // Speculative request disposal has no resource authority.
        field.length = original.length;
        field.digest = original.digest;
        field.capture = self.content_ordinal;
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

    fn readBoolean(self: *Parser) !bool {
        try self.skipWhitespace();
        const first = try self.source.readByte();
        const rest: []const u8 = switch (first) {
            't' => "rue",
            'f' => "alse",
            else => return error.InvalidJsonShape,
        };
        for (rest) |expected| if (try self.source.readByte() != expected) return error.InvalidJsonShape;
        return first == 't';
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

    /// Opens the scratch file and builds the capture in place. On error
    /// nothing is open and the capture is not live.
    fn init(self: *ContentCapture, options: ParseOptions, ordinal: u8) !void {
        if (options.content_faults.acquire) return error.InjectedContentAcquireFailure;
        var name_buffer: [96]u8 = undefined;
        const name = try named_scratch.NumericName.request.format(&name_buffer, options.request_number, ordinal);
        const path = try std.fmt.bufPrint(&self.path, "{s}/{s}", .{ options.scratch_path, name });
        const writer = try std.Io.Dir.createFileAbsolute(options.io, path, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        self.options = options;
        self.path_len = path.len;
        self.sink = .{ .io = options.io, .file = writer, .scratch_budget = options.scratch_budget };
        self.writer_open = true;
        self.sealed = null;
        self.transferred = false;
    }

    fn seal(self: *ContentCapture) !ContentField {
        if (self.options.content_faults.write) return error.InjectedContentWriteFailure;
        try self.sink.finish();
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

const DiscardSink = struct {
    fn write(_: *DiscardSink, _: []const u8) !void {}
    fn endString(_: *DiscardSink) !void {}
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
    /// A `std.EnumSet(E)`, as a JSON array of its tag names in tag order.
    tag_set: type,
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
            .tag_set => |T| blk: {
                var bytes = "[]".len + std.meta.tags(T).len - 1;
                for (std.meta.tags(T)) |tag| bytes += 2 + @tagName(tag).len;
                break :blk bytes;
            },
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
                .tag_set => |T| {
                    try out.writeByte('[');
                    var first = true;
                    for (std.meta.tags(T)) |tag| if (@as(std.EnumSet(T), argument).contains(tag)) {
                        if (!first) try out.writeByte(',');
                        first = false;
                        try out.print("\"{s}\"", .{@tagName(tag)});
                    };
                    try out.writeByte(']');
                },
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
pub const session_stop_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"session_stop\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, "}" };
/// Holes: Store, key, Session, turn, operation.
pub const model_interruption_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"model_interruption\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"target\":{\"session\":", session_hole, ",\"turn\":\"", Hole.decimal, "\",\"operation\":\"", Hole.decimal, "\"}}" };
/// Holes: Store, key, Session, Action, decision.
pub const permission_decision_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"permission_decision\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, ",\"action\":\"", Hole.decimal, "\",\"decision\":\"", Hole{ .tag = PermissionDecision }, "\"}" };
/// Holes: Store, key.
pub const observe_command_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"observe_command\",\"store\":", store_hole, ",\"key\":", key_hole, "}" };
/// Holes: Store.
pub const host_info_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"host_info\",\"store\":", store_hole, "}" };
/// Holes: Store.
pub const model_list_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"model_list\",\"store\":", store_hole, "}" };
/// Holes: Store, paused.
pub const host_pause_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"host_pause\",\"store\":", store_hole, ",\"paused\":", Hole.boolean, "}" };
/// Holes: Store.
pub const host_stop_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"host_stop\",\"store\":", store_hole, "}" };
/// Holes: Store, key.
pub const read_result_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"read_result\",\"store\":", store_hole, ",\"key\":", key_hole, "}" };
pub const inspect_session_request = struct {
    /// Holes: Store, Session.
    pub const current = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"inspect_session\",\"store\":", store_hole, ",\"session\":", session_hole, "}" };
    /// Holes: Store, Session.
    pub const full = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"inspect_session\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"profile\":\"full\"}" };
    /// Holes: Store, Session, part, operation, attempt.
    pub const failed_response = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"inspect_session\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"failed_response\":\"", Hole{ .tag = FailedResponsePart }, "\",\"operation\":\"", Hole.decimal, "\",\"attempt\":\"", Hole.decimal, "\"}" };
    pub const max_bytes = maxShapeBytes(.{ current, full, failed_response });
};
/// Holes: Store, Workspace, after, ceiling.
const list_sessions_head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"list_sessions\",\"store\":", store_hole, ",\"workspace\":", Hole{ .optional_string = max_workspace_bytes }, ",\"after\":\"", Hole.decimal, "\",\"ceiling\":\"", Hole.decimal, "\"" };
pub const list_sessions_request = list_sessions_head ++ .{"}"};
/// Hole: the token, after the head's.
pub const list_sessions_since_request = list_sessions_head ++ .{ ",\"since\":\"", Hole{ .text = SinceToken.max_bytes }, "\"}" };
/// Holes: the token, through, after reference, after the head's.
pub const list_sessions_changed_request = list_sessions_head ++ .{ ",\"since\":\"", Hole{ .text = SinceToken.max_bytes }, "\",\"through\":\"", Hole.decimal, "\",\"after_reference\":", Hole{ .string = session_id_bytes }, "}" };
/// Holes: Store, Session, Action.
pub const read_action_arguments_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"read_action_arguments\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"action\":\"", Hole.decimal, "\"}" };
/// Holes: Store, Session, Action.
pub const read_action_call_id_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"read_action_call_id\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"action\":\"", Hole.decimal, "\"}" };
/// Holes: Store, Session, position, ordinal. The client always streams from
/// the start.
pub const conversation_content_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"conversation_content\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"position\":\"", Hole.decimal, "\",\"ordinal\":\"", Hole.decimal, "\",\"start\":\"0\",\"stream\":true}" };
/// Holes: Store, Session, end, before position, before ordinal.
pub const conversation_page_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"conversation_page\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"end\":\"", Hole.decimal, "\",\"before_position\":\"", Hole.decimal, "\",\"before_ordinal\":\"", Hole.decimal, "\"}" };
/// Holes: Store, Session, end, position, ordinal, direction, kinds, limit.
pub const activity_page_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"activity_page\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"end\":", Hole.optional_id, ",\"position\":\"", Hole.decimal, "\",\"ordinal\":", Hole.optional_id, ",\"direction\":\"", Hole{ .tag = @FieldType(ActivityPage, "direction") }, "\",\"kinds\":", Hole{ .tag_set = ActivityItem.Kind }, ",\"limit\":\"", Hole.decimal, "\"}" };
/// Holes: Store, Session, position, ordinal.
pub const activity_content_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"activity_content\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"position\":\"", Hole.decimal, "\",\"ordinal\":\"", Hole.decimal, "\"}" };
/// Configure and Message carry content of unbounded size, so only their
/// metadata has a shape. The variable parts are written between these.
pub const configure_request = struct {
    /// Holes: Store, key, Session. The configuration object follows.
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"configure\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, ",\"configuration\":" };
    pub const tail = .{"}"};
    pub const require_model_tail = .{",\"require_model\":true}"};
};
pub const message_request = struct {
    /// Holes: Store, key, Session, sender handle.
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"message\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, ",\"sender\":null,\"sender_handle\":", Hole{ .optional_string = max_sender_handle_bytes } };
    /// Holes: Store, key, Session, sender Store, sender Session, sender handle.
    pub const sender_head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"message\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, ",\"sender\":{\"store\":", store_hole, ",\"session\":", session_hole, "},\"sender_handle\":", Hole{ .optional_string = max_sender_handle_bytes } };
    /// The configuration object of a creating Message follows.
    pub const configuration = .{",\"configuration\":"};
    /// The text, as a JSON string, follows.
    pub const text = .{",\"text\":{\"state\":\"value\",\"value\":"};
    pub const tail = .{"}}"};
    /// A creating Message's capability condition follows its text.
    pub const require_model_tail = .{"},\"require_model\":true}"};
};

pub const max_session_stop_request_bytes = shapeBytes(session_stop_request);
pub const max_model_interruption_request_bytes = shapeBytes(model_interruption_request);
pub const max_permission_decision_request_bytes = shapeBytes(permission_decision_request);
pub const max_control_request_bytes = maxShapeBytes(.{ session_stop_request, model_interruption_request, permission_decision_request });
pub const max_observe_command_request_bytes = shapeBytes(observe_command_request);
pub const max_host_info_request_bytes = shapeBytes(host_info_request);
pub const max_host_stop_request_bytes = shapeBytes(host_stop_request);
pub const max_host_pause_request_bytes = shapeBytes(host_pause_request);
pub const max_model_list_request_bytes = shapeBytes(model_list_request);
pub const max_read_result_request_bytes = shapeBytes(read_result_request);
pub const max_inspect_session_request_bytes = inspect_session_request.max_bytes;
pub const max_list_sessions_request_bytes = maxShapeBytes(.{ list_sessions_request, list_sessions_since_request, list_sessions_changed_request });
pub const max_read_action_arguments_request_bytes = shapeBytes(read_action_arguments_request);
pub const max_read_action_call_id_request_bytes = shapeBytes(read_action_call_id_request);
pub const max_conversation_content_request_bytes = shapeBytes(conversation_content_request);
pub const max_conversation_page_request_bytes = shapeBytes(conversation_page_request);
pub const max_activity_page_request_bytes = shapeBytes(activity_page_request);
pub const max_activity_content_request_bytes = shapeBytes(activity_content_request);
/// Every request the client writes into a `RequestBuffer`. Control requests
/// are captured to a record file instead.
pub const max_client_request_bytes = @max(max_inspect_session_request_bytes, maxShapeBytes(.{
    observe_command_request,       host_info_request,           host_stop_request,
    host_pause_request,            read_result_request,         list_sessions_changed_request,
    read_action_arguments_request, read_action_call_id_request, conversation_content_request,
    conversation_page_request,     activity_page_request,       activity_content_request,
    model_list_request,
}));

/// Separated by commas, `count` JSON values of at most `item_bytes` each.
pub fn jsonListBytes(comptime count: usize, comptime item_bytes: usize) usize {
    return count * item_bytes + count -| 1;
}

/// A Message or answer's content reference in an observation. Holes: length, digest.
pub const content_reference_shape = .{ "{\"type\":\"text\",\"bytes\":\"", Hole.decimal, "\",\"sha256\":\"", Hole{ .hex = 32 }, "\"}" };

pub const max_activity_page_response_bytes = ActivityFacts.max_json_bytes;

pub const configuration_reply = struct {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"configuration_reply\",\"answer\":{\"status\":";
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
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"message_reply\",\"answer\":{\"status\":";
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
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"session_stop_reply\",\"answer\":{\"status\":";
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
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"model_interruption_reply\",\"answer\":{\"status\":";
    /// Holes: replayed, then the target's.
    pub const accepted = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean, ",\"target\":" } ++ model_interruption_target_shape ++ .{"}}"};
    /// Holes: replayed, the target's, code.
    pub const rejected = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean, ",\"target\":" } ++ model_interruption_target_shape ++ .{ ",\"code\":\"", Hole{ .tag = ModelInterruptionRejection }, "\"}}" };
    /// Holes: the target's.
    pub const conflict = .{head ++ "\"conflict\",\"replayed\":false,\"target\":"} ++ model_interruption_target_shape ++ .{",\"code\":\"idempotency_key_conflict\"}}"};
    pub const max_bytes = maxShapeBytes(.{ accepted, rejected, conflict });
};

pub const permission_decision_reply = struct {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"permission_decision_reply\",\"answer\":{\"status\":";
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
    const prefix = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"command_observation\",\"key\":";
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
pub const ErrorType = enum { invocation_error, observation_error, busy, unsupported, host_unavailable, result_unavailable, action_unavailable, conversation_unavailable, activity_unavailable, failed_response_unavailable };
pub const error_reply = .{ "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"", Hole{ .tag = ErrorType }, "\",\"code\":", Hole{ .string = max_code_bytes }, "}" };
pub const max_control_error_response_bytes = shapeBytes(error_reply);

pub const max_control_response_bytes = @max(
    @max(@max(configuration_reply.max_bytes, message_reply.max_bytes), @max(session_stop_reply.max_bytes, model_interruption_reply.max_bytes)),
    @max(@max(permission_decision_reply.max_bytes, command_observation_reply.max_bytes), max_control_error_response_bytes),
);

/// Holes: Store, instance, Active and intake capacity, descriptor limit
/// (decimal or `unlimited`), start time, slots in use, whether new Turns
/// are paused, and each provider's Route.
pub const host_info_reply = .{ "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"host_info\",\"store\":", Hole{ .string = max_store_bytes }, ",\"instance\":\"", Hole{ .hex = @typeInfo(InstanceId).array.len }, "\",\"active_capacity\":\"", Hole.decimal, "\",\"intake_capacity\":\"", Hole.decimal, "\",\"descriptor_limit\":\"", Hole{ .text = Hole.maxBytes(.decimal) }, "\",\"started_at\":\"", Hole.decimal, "\",\"custody_occupied\":\"", Hole.decimal, "\",\"paused\":", Hole.boolean, ",\"capabilities\":{\"bash\":true,\"providers\":{\"codex\":\"", Hole{ .tag = Route }, "\",\"openai\":\"", Hole{ .tag = Route }, "\"}}}" };
pub const host_info_mysql_reply = .{ "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"host_info\",\"store\":", Hole{ .string = 32 }, ",\"instance\":\"", Hole{ .hex = @typeInfo(InstanceId).array.len }, "\",\"active_capacity\":\"", Hole.decimal, "\",\"intake_capacity\":\"", Hole.decimal, "\",\"descriptor_limit\":\"", Hole{ .text = Hole.maxBytes(.decimal) }, "\",\"started_at\":\"", Hole.decimal, "\",\"custody_occupied\":\"", Hole.decimal, "\",\"paused\":", Hole.boolean, ",\"innodb_doublewrite\":", Hole{ .string = 32 }, ",\"capabilities\":{\"bash\":true,\"providers\":{\"codex\":\"", Hole{ .tag = Route }, "\",\"openai\":\"", Hole{ .tag = Route }, "\"}}}" };
comptime {
    const names = @typeInfo(Provider).@"enum".field_names;
    if (names.len != 2 or !std.mem.eql(u8, names[0], "codex") or !std.mem.eql(u8, names[1], "openai"))
        @compileError("host_info_reply names one Route hole per provider, in Provider order");
}
pub const max_host_info_response_bytes: usize = @max(shapeBytes(host_info_reply), shapeBytes(host_info_mysql_reply));

/// Each served provider's models: `model_list.writeProviders` follows the
/// head, then the tail.
pub const model_list_reply = struct {
    pub const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"model_list\",\"providers\":";
    pub const tail = "}";
    pub const max_bytes = head.len + model_list.max_providers_bytes + tail.len;
};
pub const host_stop_ack = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"host_stop_reply\",\"status\":\"acknowledged\"}";
/// Hole: whether new Turns are now paused.
pub const host_pause_reply = .{ "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"host_pause_reply\",\"paused\":", Hole.boolean, "}" };
// Only bounded replies and errors use this resident buffer. Complete reports
// and result content use their independent streamed delivery paths.
pub const max_response_bytes = @max(@max(max_control_response_bytes, max_host_info_response_bytes), @max(host_stop_ack.len, shapeBytes(host_pause_reply)));

pub const conversation_page_reply = struct {
    /// Hole: the page end.
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"conversation_page\",\"direction\":\"newest_first\",\"end\":\"", Hole.decimal, "\",\"items\":[" };
    /// Holes: position, ordinal, content length and digest.
    pub fn item(comptime kind: ConversationItemKind) struct { []const u8, Hole, []const u8, Hole, []const u8, Hole, []const u8, Hole, []const u8 } {
        comptime std.debug.assert(kind != .hosted_call);
        return .{ "{\"position\":\"", .decimal, "\",\"ordinal\":\"", .decimal, "\",\"kind\":\"" ++ @tagName(kind) ++ "\",\"content\":{\"bytes\":\"", .decimal, "\",\"sha256\":\"", .{ .hex = 32 }, "\",\"display\":\"omitted\"}" };
    }
    /// A Hosted Call item, which has no content. Holes: position, ordinal.
    pub const hosted_call = .{ "{\"position\":\"", Hole.decimal, "\",\"ordinal\":\"", Hole.decimal, "\",\"kind\":\"hosted_call\"" };
    /// A User item's admission. Holes: second, sending peer.
    pub const admission = .{ ",\"admitted_at\":\"", Hole.decimal, "\",\"sender\":", Hole{ .optional_json = NamedPeer } };
    /// A Tool Result or Hosted Call item's presentation. Hole: it.
    pub const presentation = .{ ",\"presentation\":", Hole{ .json = ToolPresentation } };
    pub const item_end = .{"}"};

    /// The largest item of this kind, with what only that kind carries.
    pub fn itemBytes(comptime kind: ConversationItemKind) usize {
        const extra = switch (kind) {
            .user => shapeBytes(admission),
            .tool_result => shapeBytes(presentation),
            .assistant => 0,
            .hosted_call => return shapeBytes(hosted_call) + shapeBytes(presentation) + shapeBytes(item_end),
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

/// The one JSON rendering vocabulary, over any writer. A writer that runs out
/// of room is `BufferTooLarge`, so a renderer reads the same whether it writes
/// into a Host reply's heap body or a client's fixed buffer.
pub const JsonOut = struct {
    writer: *std.Io.Writer,

    pub fn append(self: JsonOut, value: []const u8) error{BufferTooLarge}!void {
        self.writer.writeAll(value) catch return error.BufferTooLarge;
    }

    pub fn appendFmt(self: JsonOut, comptime format: []const u8, args: anytype) error{BufferTooLarge}!void {
        self.writer.print(format, args) catch return error.BufferTooLarge;
    }

    pub fn appendShape(self: JsonOut, comptime shape: anytype, args: anytype) error{BufferTooLarge}!void {
        writeShape(self.writer, shape, args) catch return error.BufferTooLarge;
    }

    pub fn appendJsonString(self: JsonOut, value: []const u8) error{BufferTooLarge}!void {
        std.json.Stringify.encodeJsonString(value, .{}, self.writer) catch return error.BufferTooLarge;
    }
};

pub fn FixedJsonBuffer(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        /// Calls `renderer(out, args...)` over the unused bytes. A failed
        /// render keeps nothing it wrote.
        pub fn render(self: *@This(), comptime renderer: anytype, args: anytype) !void {
            var writer = std.Io.Writer.fixed(self.bytes[self.len..]);
            try @call(.auto, renderer, .{JsonOut{ .writer = &writer }} ++ args);
            self.len += writer.end;
        }

        pub fn append(self: *@This(), value: []const u8) error{BufferTooLarge}!void {
            return self.render(JsonOut.append, .{value});
        }

        pub fn appendFmt(self: *@This(), comptime format: []const u8, args: anytype) error{BufferTooLarge}!void {
            return self.render(JsonOut.appendFmt, .{ format, args });
        }

        pub fn appendShape(self: *@This(), comptime shape: anytype, args: anytype) error{BufferTooLarge}!void {
            return self.render(JsonOut.appendShape, .{ shape, args });
        }

        pub fn appendJsonString(self: *@This(), value: []const u8) error{BufferTooLarge}!void {
            return self.render(JsonOut.appendJsonString, .{value});
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const RequestBuffer = FixedJsonBuffer(max_client_request_bytes);
pub const ResponseBuffer = FixedJsonBuffer(max_response_bytes);

fn parseForTest(parser: *Parser) !Request {
    var request: Request = undefined;
    try parser.parse(&request);
    return request;
}

/// Captures one JSON string the way Ingress.feed does, into `field`.
fn captureForTest(field: *ContentField, options: ParseOptions, ordinal: u8, json: []const u8) !void {
    std.debug.assert(json[0] == '"');
    var capture: ContentCapture = undefined;
    try capture.init(options, ordinal);
    defer capture.deinit();
    var decoder: StringDecoder = .{};
    for (json[1..]) |byte| {
        if (try decoder.feed(byte, &capture.sink)) {
            field.* = try capture.seal();
            return;
        }
    }
    return error.UnexpectedEndOfBody;
}

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
    const options: ParseOptions = .{
        .io = io,
        .content_length = 22,
        .scratch_path = root[0..root_len],
        .request_number = 1,
        .retained_scratch = &retained,
    };
    var instructions = ContentField{};
    errdefer removeContent(&instructions, io) catch unreachable;
    var output_schema = ContentField{};
    errdefer removeContent(&output_schema, io) catch unreachable;
    try captureForTest(&instructions, options, 1, "\"instructions\"");
    try captureForTest(&output_schema, options, 2, "\"schema\"");
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
        var field = ContentField{};
        try captureForTest(&field, .{
            .io = io,
            .content_length = 999999,
            .scratch_path = root[0..n],
            .request_number = ordinal,
            .retained_scratch = &retained,
            .scratch_budget = .{ .used = &used, .limit = 3 },
        }, 1, json);
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
    const options: ParseOptions = .{
        .io = failing_io,
        .content_length = json.len,
        .scratch_path = root[0..n],
        .request_number = 1,
        .retained_scratch = &retained,
        .scratch_budget = .{ .used = &used, .limit = 8 },
    };
    const good_file = try tmp.dir.createFile(io, "good", .{});
    try good_file.writeStreamingAll(io, "ok");
    try tmp.dir.deleteFile(io, "good");
    const budget = ScratchBudget{ .used = &used, .limit = 8 };
    try std.testing.expect(budget.charge(2));
    var good_field = ContentField{ .file = good_file, .scratch_budget = budget, .charged = 2 };
    var field = ContentField{};
    try std.testing.expectError(error.AccessDenied, captureForTest(&field, options, 1, json));
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
    const json = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"observe_command\",\"store\":\"store\",\"key\":\"key\"}";
    var source: MetadataSource = .{ .input = json };
    var used = std.atomic.Value(u64).init(3);
    var retained: ?named_scratch.Owner = null;
    var parser = Parser{ .source = &source, .options = .{
        .io = std.testing.io,
        .content_length = json.len,
        .scratch_path = "unused",
        .request_number = 0,
        .retained_scratch = &retained,
        .scratch_budget = .{ .used = &used, .limit = 3 },
    } };
    const request = try parseForTest(&parser);
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
        .{ .suffix = "\"0\",\"stream\":true,\"stream\":true}", .failure = error.UnexpectedField },
    };
    for (cases) |case| {
        var buffer: [512]u8 = undefined;
        const json = try std.fmt.bufPrint(&buffer, "{{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"conversation_content\",\"store\":\"s\",\"session\":\"x\",\"position\":\"1\",\"ordinal\":\"0\",\"start\":{s}", .{case.suffix});
        var source: MetadataSource = .{ .input = json };
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{ .io = std.testing.io, .content_length = json.len, .scratch_path = "unused", .request_number = 0, .retained_scratch = &retained } };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parseForTest(&parser));
        } else {
            const request = (try parseForTest(&parser)).conversation_content;
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
        const json = try std.fmt.bufPrint(&buffer, "{{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"conversation_page\",\"store\":\"s\",\"session\":\"x\",{s}}}", .{case.body});
        var source: MetadataSource = .{ .input = json };
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{ .io = std.testing.io, .content_length = json.len, .scratch_path = "unused", .request_number = 0, .retained_scratch = &retained } };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parseForTest(&parser));
        } else {
            const request = try parseForTest(&parser);
            try std.testing.expect(request == .conversation_page);
        }
    }
}

test "an activity page names its kinds once each, in order, and a limit from 1 to 16" {
    const cases = [_]struct { body: []const u8, failure: ?anyerror = null }{
        .{ .body = "[\"admission\"],\"limit\":\"1\"" },
        .{ .body = "[\"admission\",\"received\"],\"limit\":\"16\"" },
        // The longest kind name.
        .{ .body = "[\"received\",\"approval_requested\"],\"limit\":\"1\"" },
        .{ .body = "[\"received\",\"admission\"],\"limit\":\"1\"", .failure = error.InvalidJsonShape },
        .{ .body = "[\"user\",\"user\"],\"limit\":\"1\"", .failure = error.InvalidJsonShape },
        .{ .body = "[\"unknown\"],\"limit\":\"1\"", .failure = error.InvalidCursor },
        .{ .body = "[],\"limit\":\"1\"", .failure = error.InvalidCursor },
        .{ .body = "[\"user\"],\"limit\":\"0\"", .failure = error.InvalidCursor },
        .{ .body = "[\"user\"],\"limit\":\"17\"", .failure = error.InvalidCursor },
        .{ .body = "[\"user\"],\"limit\":\"256\"", .failure = error.InvalidCursor },
    };
    for (cases) |case| {
        var buffer: [512]u8 = undefined;
        const json = try std.fmt.bufPrint(&buffer, "{{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"activity_page\",\"store\":\"s\",\"session\":\"x\",\"end\":null,\"position\":\"0\",\"ordinal\":null,\"direction\":\"forward\",\"kinds\":{s}}}", .{case.body});
        var source: MetadataSource = .{ .input = json };
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{ .io = std.testing.io, .content_length = json.len, .scratch_path = "unused", .request_number = 0, .retained_scratch = &retained } };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parseForTest(&parser));
        } else {
            const request = try parseForTest(&parser);
            try std.testing.expect(request == .activity_page);
        }
    }
}

test "a Label is one non-blank line of at most 100 bytes" {
    const longest: [max_label_bytes]u8 = @splat('x');
    const overlong: [max_label_bytes + 1]u8 = @splat('x');
    try std.testing.expect(validLabel("Review PR 412") and validLabel(&longest) and validLabel("Café"));
    for ([_][]const u8{ "", " \t", "one\ntwo", "one\u{2028}two", "\xff", &overlong }) |invalid|
        try std.testing.expect(!validLabel(invalid));
}

test "configuration token heuristics and effort parse sparsely and bind idempotency" {
    const longest_label: [max_label_bytes]u8 = @splat('x');
    const overlong_label: [max_label_bytes + 1]u8 = @splat('x');
    const cases = [_]struct { suffix: []const u8, trigger: ?[]const u8 = null, reservation: ?[]const u8 = null, label: ?[]const u8 = null, failure: ?anyerror = null }{
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
        .{ .suffix = ",\"label\":{\"state\":\"value\",\"value\":\"Review PR 412\"}", .label = "Review PR 412" },
        .{ .suffix = ",\"label\":{\"state\":\"null\"}" },
        .{ .suffix = ",\"label\":{\"state\":\"value\",\"value\":\"" ++ longest_label ++ "\"}", .label = &longest_label },
        .{ .suffix = ",\"label\":{\"state\":\"value\",\"value\":\"" ++ overlong_label ++ "\"}", .failure = error.ValueTooLong },
        .{ .suffix = ",\"label\":{\"state\":\"null\"},\"label\":{\"state\":\"null\"}", .failure = error.UnexpectedField },
    };
    var omitted_digest: [32]u8 = undefined;
    for (cases, 0..) |case, index| {
        var buffer: [2048]u8 = undefined;
        const json = try std.fmt.bufPrint(&buffer, "{{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"configure\",\"store\":\"store\",\"key\":\"key\",\"session\":\"session\",\"configuration\":{{" ++
            "\"workspace\":{{\"state\":\"omitted\"}},\"provider\":{{\"state\":\"omitted\"}},\"model\":{{\"state\":\"omitted\"}}," ++
            "\"instructions\":{{\"state\":\"omitted\"}},\"tools\":{{\"state\":\"omitted\"}},\"permission_mode\":{{\"state\":\"omitted\"}},\"output_schema\":{{\"state\":\"omitted\"}}{s}}}}}", .{case.suffix});
        var source: MetadataSource = .{ .input = json };
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{ .io = std.testing.io, .content_length = json.len, .scratch_path = "unused", .request_number = 0, .retained_scratch = &retained } };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parseForTest(&parser));
            continue;
        }
        const command = (try parseForTest(&parser)).configure;
        if (case.trigger) |value| try std.testing.expectEqualStrings(value, command.configuration.compaction_trigger.value.slice());
        if (case.reservation) |value| try std.testing.expectEqualStrings(value, command.configuration.output_reservation.value.slice());
        if (case.label) |value| try std.testing.expectEqualStrings(value, command.configuration.label.value.slice());
        if (std.mem.indexOf(u8, case.suffix, "\"state\":\"null\"") != null) {
            const state = if (std.mem.indexOf(u8, case.suffix, "compaction_trigger") != null)
                command.configuration.compaction_trigger.state
            else if (std.mem.indexOf(u8, case.suffix, "reasoning_effort") != null)
                command.configuration.reasoning_effort.state
            else if (std.mem.indexOf(u8, case.suffix, "label") != null)
                command.configuration.label.state
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
            "{{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"configure\",\"store\":\"store\",\"key\":\"key\",\"session\":\"session\",\"configuration\":{{" ++
                "\"workspace\":{{\"state\":\"omitted\"}},\"provider\":{s},\"model\":{{\"state\":\"omitted\"}}," ++
                "\"instructions\":{{\"state\":\"omitted\"}},\"tools\":{{\"state\":\"omitted\"}}," ++
                "\"permission_mode\":{{\"state\":\"omitted\"}},\"output_schema\":{{\"state\":\"omitted\"}}}}{s}}}",
            .{ case.field, case.suffix },
        );
        var source: MetadataSource = .{ .input = json };
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{
            .io = std.testing.io,
            .content_length = json.len,
            .scratch_path = "unused",
            .request_number = 0,
            .retained_scratch = &retained,
        } };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parseForTest(&parser));
            continue;
        }
        const request = try parseForTest(&parser);
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

test "configuration tools and loaded tools are tool names, sorted, each once" {
    const cases = [_]struct { value: []const u8, names: []const u8 = "", count: u8 = 0, failure: ?anyerror = null }{
        .{ .value = "[]" },
        .{ .value = "[\"bash\"]", .names = "bash", .count = 1 },
        .{ .value = "[\"web_search\"]", .names = "web_search", .count = 1 },
        .{ .value = "[\"bash\",\"web_search\"]", .names = "bash web_search", .count = 2 },
        .{ .value = "[\"b\\u0061sh\"]", .names = "bash", .count = 1 },
        // Whether the Host offers a name is configure's to say.
        .{ .value = "[\"edit\"]", .names = "edit", .count = 1 },
        .{ .value = "[\"Bash\",\"bash\"]", .names = "Bash bash", .count = 2 },
        .{ .value = "[\"bash\",\"edit\"]", .names = "bash edit", .count = 2 },
        .{ .value = "[\"\"]", .failure = error.InvalidToolName },
        .{ .value = "[\"web search\"]", .failure = error.InvalidToolName },
        .{ .value = "[\"bash.v2\"]", .failure = error.InvalidToolName },
        .{ .value = "[\"" ++ @as([65]u8, @splat('x')) ++ "\"]", .failure = error.InvalidToolName },
        .{ .value = "[\"bash\",\"bash\"]", .failure = error.InvalidJsonShape },
        .{ .value = "[\"web_search\",\"bash\"]", .failure = error.InvalidJsonShape },
        .{ .value = "[\"bash\",\"web_search\",\"bash\"]", .failure = error.InvalidJsonShape },
    };
    inline for (.{ "tools", "loaded_tools" }) |field_name| {
        for (cases) |case| {
            var buffer: [1024]u8 = undefined;
            const json = try std.fmt.bufPrint(&buffer, "{{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"configure\",\"store\":\"store\",\"key\":\"key\",\"session\":\"session\",\"configuration\":{{" ++
                "\"workspace\":{{\"state\":\"omitted\"}},\"provider\":{{\"state\":\"omitted\"}},\"model\":{{\"state\":\"omitted\"}}," ++
                "\"instructions\":{{\"state\":\"omitted\"}}," ++
                (if (comptime std.mem.eql(u8, field_name, "loaded_tools")) "\"tools\":{{\"state\":\"omitted\"}}," else "") ++
                "\"" ++ field_name ++ "\":{{\"state\":\"value\",\"value\":{s}}}," ++
                "\"permission_mode\":{{\"state\":\"omitted\"}},\"output_schema\":{{\"state\":\"omitted\"}}}}}}", .{case.value});
            var source: MetadataSource = .{ .input = json };
            var retained: ?named_scratch.Owner = null;
            var parser = Parser{ .source = &source, .options = .{
                .io = std.testing.io,
                .content_length = json.len,
                .scratch_path = "unused",
                .request_number = 0,
                .retained_scratch = &retained,
            } };
            if (case.failure) |failure| {
                try std.testing.expectError(failure, parseForTest(&parser));
            } else {
                const request = try parseForTest(&parser);
                try std.testing.expectEqual(case.count, @field(request.configure.configuration, field_name).count);
                try std.testing.expectEqualStrings(case.names, @field(request.configure.configuration, field_name).names.slice());
            }
        }
    }
}

test "a tools list holds at most 128 names and 4096 name bytes" {
    var names: [max_tools + 1][3]u8 = undefined;
    var many: ToolsField = .{ .state = .value };
    for (&names, 0..) |*name, index| {
        name.* = .{ 'a' + @as(u8, @intCast(index / 26 / 26)), 'a' + @as(u8, @intCast(index / 26 % 26)), 'a' + @as(u8, @intCast(index % 26)) };
        if (index < max_tools) try many.append(name) else try std.testing.expectError(error.InvalidJsonShape, many.append(name));
    }
    try std.testing.expectEqual(@as(u8, max_tools), many.count);

    // 64 names of 64 bytes fill the name bytes; the separators do not count.
    var long: ToolsField = .{ .state = .value };
    var name: [max_tool_name_bytes]u8 = @splat('a');
    for (0..max_tool_list_name_bytes / max_tool_name_bytes) |index| {
        name[name.len - 1] = 'A' + @as(u8, @intCast(index % 26));
        name[name.len - 2] = 'A' + @as(u8, @intCast(index / 26));
        try long.append(&name);
    }
    try std.testing.expectEqual(@as(usize, max_tool_list_name_bytes) + long.count - 1, long.names.len);
    try std.testing.expectError(error.InvalidJsonShape, long.append("z"));
    var iterator = long.iterator();
    var seen: usize = 0;
    while (iterator.next()) |each| : (seen += 1) try std.testing.expectEqual(max_tool_name_bytes, each.len);
    try std.testing.expectEqual(@as(usize, long.count), seen);
}

test "Session inspection selects a closed report profile or exact failed response stream" {
    const cases = [_]struct { json: []const u8, expected: ?ReportProfile, failed_response: ?FailedResponseExport = null }{
        .{
            .json = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"inspect_session\",\"store\":\"store\",\"session\":\"session\"}",
            .expected = .current,
        },
        .{
            .json = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"inspect_session\",\"store\":\"store\",\"session\":\"session\",\"profile\":\"full\"}",
            .expected = .full,
        },
        .{
            .json = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"inspect_session\",\"store\":\"store\",\"session\":\"session\",\"profile\":\"current\"}",
            .expected = null,
        },
        .{
            .json = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"inspect_session\",\"store\":\"store\",\"session\":\"session\",\"failed_response\":\"body\",\"operation\":\"106\",\"attempt\":\"1\"}",
            .expected = .current,
            .failed_response = .{ .operation = 106, .attempt = 1, .part = .body },
        },
        .{
            .json = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"inspect_session\",\"store\":\"store\",\"session\":\"session\",\"failed_response\":\"metadata\",\"operation\":\"42\",\"attempt\":\"3\"}",
            .expected = .current,
            .failed_response = .{ .operation = 42, .attempt = 3, .part = .metadata },
        },
    };
    for (cases) |case| {
        var source: MetadataSource = .{ .input = case.json };
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{
            .io = std.testing.io,
            .content_length = case.json.len,
            .scratch_path = "unused",
            .request_number = 0,
            .retained_scratch = &retained,
        } };
        if (case.expected) |expected| {
            const request = try parseForTest(&parser);
            try std.testing.expectEqual(expected, request.inspect_session.profile);
            try std.testing.expectEqualDeep(case.failed_response, request.inspect_session.failed_response);
        } else {
            try std.testing.expectError(error.UnknownReportProfile, parseForTest(&parser));
        }
    }
}

test "Session listing wire distinguishes all, exact workspace, continuation, since and invalid cursor" {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"list_sessions\",\"store\":\"s\",\"workspace\":null,\"after\":\"0\",\"ceiling\":\"0\"";
    const since = ",\"since\":\"abababababababababababababababab.42\"";
    const Case = struct { json: []const u8, workspace: ?[]const u8 = null, after: u64 = 0, ceiling: u64 = 0, since: ?u64 = null, through: ?u64 = null, failure: ?anyerror = null };
    const cases = [_]Case{
        .{ .json = head ++ "}" },
        .{ .json = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"list_sessions\",\"store\":\"s\",\"workspace\":\"/a\\u0001b\",\"after\":\"8\",\"ceiling\":\"12\"}", .workspace = "/a\x01b", .after = 8, .ceiling = 12 },
        .{ .json = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"list_sessions\",\"store\":\"s\",\"workspace\":null,\"after\":\"0\",\"ceiling\":\"12\"}", .failure = error.InvalidCursor },
        .{ .json = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"list_sessions\",\"store\":\"s\",\"workspace\":null,\"after\":\"13\",\"ceiling\":\"12\"}", .failure = error.InvalidCursor },
        // A token's first page, and a changed continuation through the
        // first page's generation after the last reference it gave.
        .{ .json = head ++ since ++ "}", .since = 42 },
        .{ .json = head ++ since ++ ",\"through\":\"48\",\"after_reference\":\"k7m2qx\"}", .since = 42, .through = 48 },
        .{ .json = head ++ since ++ ",\"through\":\"42\",\"after_reference\":\"k7m2qx\"}", .since = 42, .through = 42 },
        // A full continuation carries no token; a changed one never ends
        // before its token, and names a Session.
        .{ .json = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"list_sessions\",\"store\":\"s\",\"workspace\":null,\"after\":\"8\",\"ceiling\":\"12\"" ++ since ++ "}", .failure = error.InvalidCursor },
        .{ .json = head ++ since ++ ",\"through\":\"41\",\"after_reference\":\"k7m2qx\"}", .failure = error.InvalidCursor },
        .{ .json = head ++ since ++ ",\"through\":\"48\",\"after_reference\":\"k7m2qX\"}", .failure = error.InvalidCursor },
        .{ .json = head ++ since ++ ",\"through\":\"48\",\"after_reference\":\"k7m2q\"}", .failure = error.InvalidCursor },
        .{ .json = head ++ ",\"since\":\"ABABABABABABABABABABABABABABABAB.42\"}", .failure = error.InvalidCursor },
        .{ .json = head ++ ",\"since\":\"abababababababababababababababab.042\"}", .failure = error.InvalidCursor },
    };
    for (cases) |case| {
        var source: MetadataSource = .{ .input = case.json };
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{
            .io = std.testing.io,
            .content_length = case.json.len,
            .scratch_path = "unused",
            .request_number = 0,
            .retained_scratch = &retained,
        } };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parseForTest(&parser));
            continue;
        }
        const request = (try parseForTest(&parser)).list_sessions;
        try std.testing.expectEqual(case.after, request.after);
        try std.testing.expectEqual(case.ceiling, request.ceiling);
        if (case.workspace) |workspace| try std.testing.expectEqualStrings(workspace, request.workspace.?.slice()) else try std.testing.expect(request.workspace == null);
        try std.testing.expectEqual(case.since, if (request.since) |token| token.generation else null);
        if (request.since) |token| try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xab)), &token.instance);
        try std.testing.expectEqual(case.through, if (request.changed) |changed| changed.through else null);
        if (request.changed) |changed| try std.testing.expectEqualStrings("k7m2qx", &changed.after_reference);
    }
}

test "a client command cannot take a key Rui keeps for its own commands" {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"session_stop\",\"store\":\"s\",\"key\":";
    const cases = [_]struct { key: []const u8, failure: ?anyerror }{
        .{ .key = "\"rui.core/stop/abcdef/ghjkmn/3\"", .failure = error.ReservedCommandKey },
        .{ .key = "\"rui.core/message_agent/1\"", .failure = error.ReservedCommandKey },
        .{ .key = "\"rui.core\"", .failure = null },
        .{ .key = "\"my/rui.core/stop\"", .failure = null },
    };
    for (cases) |case| {
        var buffer: [256]u8 = undefined;
        const json = try std.fmt.bufPrint(&buffer, "{s}{s},\"session\":\"peer\"}}", .{ head, case.key });
        var source: MetadataSource = .{ .input = json };
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{ .io = std.testing.io, .content_length = json.len, .scratch_path = "unused", .request_number = 0, .retained_scratch = &retained } };
        if (case.failure) |failure| try std.testing.expectError(failure, parseForTest(&parser)) else _ = try parseForTest(&parser);
    }
}

test "protocol peer Store address wire parsing accepts opaque ids and preserves SQLite paths" {
    const prefix = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"target\",\"sender\":{\"store\":\"";
    const suffix = "\",\"session\":\"k7m2qx\"},\"sender_handle\":\"handle\",\"text\":{\"state\":\"value\",\"value\":\"\"}}";
    const cases = [_]struct { store: []const u8, valid: bool }{
        .{ .store = "0123456789abcdef0123456789abcdef", .valid = true },
        .{ .store = "/", .valid = true },
        .{ .store = "/store with spaces/é", .valid = true },
        .{ .store = "relative", .valid = false },
        .{ .store = "0123456789abcdef0123456789abcde", .valid = false },
        .{ .store = "0123456789abcdef0123456789abcdef0", .valid = false },
        .{ .store = "0123456789ABCDEF0123456789abcdef", .valid = false },
        .{ .store = "g123456789abcdef0123456789abcdef", .valid = false },
        .{ .store = "/store/", .valid = false },
        .{ .store = "/store//child", .valid = false },
        .{ .store = "/store/./child", .valid = false },
        .{ .store = "/store/../child", .valid = false },
        .{ .store = "/store\\n", .valid = false },
        .{ .store = "/store\\u007f", .valid = false },
    };
    for (cases) |case| {
        var buffer: [512]u8 = undefined;
        const json = try std.fmt.bufPrint(&buffer, "{s}{s}{s}", .{ prefix, case.store, suffix });
        var source: MetadataSource = .{ .input = json };
        var retained: ?named_scratch.Owner = null;
        // Ingress has replaced its captured content with an empty placeholder.
        var parser = Parser{ .source = &source, .captured = &.{.{}}, .options = .{ .io = std.testing.io, .content_length = json.len, .scratch_path = "unused", .request_number = 0, .retained_scratch = &retained } };
        if (case.valid) {
            const request = try parseForTest(&parser);
            try std.testing.expectEqualStrings(case.store, request.message.sender.?.store.slice());
            try std.testing.expectEqualStrings("k7m2qx", request.message.sender.?.session.slice());
        } else try std.testing.expectError(error.InvalidRuiAddress, parseForTest(&parser));
        try std.testing.expect(retained == null);
    }
}

test "peer wire rejects old sender strings, malformed addresses and missing handles" {
    const prefix = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"target\",\"sender\":";
    const text = ",\"text\":{\"state\":\"omitted\"}}";
    const cases = [_]struct { json: []const u8, failure: anyerror }{
        .{ .json = prefix ++ "\"peer\",\"sender_handle\":null" ++ text, .failure = error.InvalidJsonShape },
        .{ .json = prefix ++ "{\"store\":\"/s\"},\"sender_handle\":null" ++ text, .failure = error.MissingField },
        .{ .json = prefix ++ "{\"store\":\"relative\",\"session\":\"peer\"},\"sender_handle\":null" ++ text, .failure = error.InvalidRuiAddress },
        .{ .json = prefix ++ "null" ++ text, .failure = error.MissingField },
    };
    for (cases) |case| {
        var source: MetadataSource = .{ .input = case.json };
        var retained: ?named_scratch.Owner = null;
        var parser = Parser{ .source = &source, .options = .{ .io = std.testing.io, .content_length = case.json.len, .scratch_path = "unused", .request_number = 0, .retained_scratch = &retained } };
        try std.testing.expectError(case.failure, parseForTest(&parser));
        try std.testing.expect(retained == null);
    }
}

test "incremental ingress streams fragmented content and transfers charged custody only at complete framing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    const prefix = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"p\\u0000é\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"";
    const encoded = @as([8193]u8, @splat('x')) ++ "\\n\\ud83d\\ude42\\u0000é\\\"\\\\";
    const expected = @as([8193]u8, @splat('x')) ++ "\n🙂\x00é\"\\";
    const suffix = "\"}}";
    var used = std.atomic.Value(u64).init(0);
    var retained: ?named_scratch.Owner = null;
    var ingress: Ingress = undefined;
    ingress.init(std.testing.allocator, .{
        .io = io,
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
    const request = try ingress.finish();
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
    const prefix = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"\",\"sender\":null,\"sender_handle\":null,\"configuration\":{" ++
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
        .content_length = json.len,
        .scratch_path = root[0..root_len],
        .request_number = 43,
        .retained_scratch = &retained,
        .scratch_budget = .{ .used = &used, .limit = expected.len },
        .expected_kind = .message,
    };
    var ingress: Ingress = undefined;
    ingress.init(std.testing.allocator, options);
    defer ingress.deinit();
    for (json) |byte| try ingress.feed(&.{byte});
    const request = try ingress.finish();
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
        var rejected: Ingress = undefined;
        rejected.init(std.testing.allocator, rejection_options);
        defer rejected.deinit();
        try std.testing.expectError(error.InvalidFieldState, rejected.feed(invalid));
        try std.testing.expectEqual(@as(usize, 0), rejected.content_count);
        try std.testing.expect(rejected.content_state != .capturing);
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    }
}

test "only a creating Message carries require_model, and it binds the digest" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    const creating = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"\",\"sender\":null,\"sender_handle\":null,\"configuration\":{" ++
        "\"workspace\":{\"state\":\"omitted\"},\"provider\":{\"state\":\"omitted\"},\"model\":{\"state\":\"omitted\"},\"instructions\":{\"state\":\"omitted\"}," ++
        "\"tools\":{\"state\":\"omitted\"},\"permission_mode\":{\"state\":\"omitted\"},\"output_schema\":{\"state\":\"omitted\"}},\"text\":{\"state\":\"value\",\"value\":\"go\"}";
    const addressed = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"k7m2qx\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"go\"}";
    const cases = [_]struct { bytes: []const u8, require_model: bool = false, failure: ?anyerror = null }{
        .{ .bytes = creating ++ "}" },
        .{ .bytes = creating ++ ",\"require_model\":false}" },
        .{ .bytes = creating ++ ",\"require_model\":true}", .require_model = true },
        .{ .bytes = creating ++ ",\"require_model\":1}", .failure = error.InvalidJsonShape },
        .{ .bytes = creating ++ ",\"required_model\":true}", .failure = error.UnexpectedField },
        .{ .bytes = addressed ++ "}" },
        .{ .bytes = addressed ++ ",\"require_model\":true}", .failure = error.InvalidMessage },
        .{ .bytes = addressed ++ ",\"require_model\":false}", .failure = error.InvalidMessage },
    };
    var digests: [cases.len][32]u8 = undefined;
    for (cases, 0..) |case, index| {
        var used = std.atomic.Value(u64).init(0);
        var retained: ?named_scratch.Owner = null;
        var ingress: Ingress = undefined;
        ingress.init(std.testing.allocator, .{
            .io = io,
            .content_length = case.bytes.len,
            .scratch_path = root[0..root_len],
            .request_number = 44,
            .retained_scratch = &retained,
            .scratch_budget = .{ .used = &used, .limit = 16 },
            .expected_kind = .message,
        });
        defer ingress.deinit();
        if (case.failure) |failure| {
            const result = if (ingress.feed(case.bytes)) |_| ingress.finish() else |err| err;
            try std.testing.expectError(failure, result);
            continue;
        }
        try ingress.feed(case.bytes);
        const request = try ingress.finish();
        defer request.removeTemporaryContent(io) catch unreachable;
        try std.testing.expectEqual(case.require_model, request.message.require_model);
        digests[index] = request.message.semanticDigest();
    }
    // An explicit false is the omitted condition; true is a different intent.
    try std.testing.expectEqualSlices(u8, &digests[0], &digests[1]);
    try std.testing.expect(!std.mem.eql(u8, &digests[0], &digests[2]));
    try std.testing.expect(!std.mem.eql(u8, &digests[0], &digests[5]));
}

test "incremental ingress preserves grammar and releases both captures after late failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    const configure = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"configure\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"configuration\":{" ++
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
            var ingress: Ingress = undefined;
            ingress.init(std.testing.allocator, .{
                .io = io,
                .content_length = case.bytes.len,
                .scratch_path = root[0..root_len],
                .request_number = index,
                .retained_scratch = &retained,
                .scratch_budget = .{ .used = &used, .limit = 8 },
                .expected_kind = case.kind,
                // A mismatched kind must fail before file acquisition.
                .content_faults = .{ .acquire = case.kind != .configure },
            });
            const result: anyerror!*Request = blk: {
                ingress.feed(case.bytes[0..split]) catch |err| break :blk err;
                ingress.feed(case.bytes[split..]) catch |err| break :blk err;
                break :blk ingress.finish();
            };
            if (case.failure) |failure| {
                try std.testing.expectError(failure, result);
            } else {
                const request = try result;
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

test "a request's members may come in any order, and its content lands in its own field" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    // The output schema arrives before the instructions, values before
    // states, and the header last.
    const reordered = "{\"configuration\":{\"output_schema\":{\"value\":\"{}\",\"state\":\"value\"},\"label\":{\"value\":\"Map\",\"state\":\"value\"}," ++
        "\"tools\":{\"value\":[\"bash\"],\"state\":\"value\"},\"permission_mode\":{\"state\":\"omitted\"},\"instructions\":{\"value\":\"first\\n\",\"state\":\"value\"}," ++
        "\"model\":{\"state\":\"omitted\"},\"provider\":{\"state\":\"omitted\"},\"workspace\":{\"state\":\"omitted\"}}," ++
        "\"require_model\":true,\"session\":\"peer\",\"key\":\"k\",\"store\":\"s\",\"kind\":\"configure\",\"version\":\"" ++ wire_version ++ "\"}";
    const ordered = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"configure\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"configuration\":{" ++
        "\"workspace\":{\"state\":\"omitted\"},\"provider\":{\"state\":\"omitted\"},\"model\":{\"state\":\"omitted\"}," ++
        "\"instructions\":{\"state\":\"value\",\"value\":\"first\\n\"},\"tools\":{\"state\":\"value\",\"value\":[\"bash\"]}," ++
        "\"permission_mode\":{\"state\":\"omitted\"},\"output_schema\":{\"state\":\"value\",\"value\":\"{}\"},\"label\":{\"state\":\"value\",\"value\":\"Map\"}},\"require_model\":true}";
    var used = std.atomic.Value(u64).init(0);
    var retained: ?named_scratch.Owner = null;
    var digests: [2][32]u8 = undefined;
    for ([_][]const u8{ ordered, reordered }, 0..) |bytes, index| {
        // Every split suspends capture at a different byte.
        for (0..bytes.len + 1) |split| {
            var ingress: Ingress = undefined;
            ingress.init(std.testing.allocator, .{
                .io = io,
                .content_length = bytes.len,
                .scratch_path = root[0..root_len],
                .request_number = index,
                .retained_scratch = &retained,
                .scratch_budget = .{ .used = &used, .limit = 8 },
                .expected_kind = .configure,
            });
            defer ingress.deinit();
            try ingress.feed(bytes[0..split]);
            try ingress.feed(bytes[split..]);
            const request = try ingress.finish();
            defer request.removeTemporaryContent(io) catch unreachable;
            const configuration = request.configure.configuration;
            try std.testing.expect(request.configure.require_model);
            try std.testing.expectEqualStrings("Map", configuration.label.value.slice());
            try std.testing.expectEqual(@as(u2, 1), configuration.tools.count);
            const fields = [_]ContentField{ configuration.instructions, configuration.output_schema };
            for (fields, [_][]const u8{ "first\n", "{}" }) |field, expected| {
                var buffer: [8]u8 = undefined;
                const count = try field.file.?.readPositionalAll(io, &buffer, 0);
                try std.testing.expectEqualStrings(expected, buffer[0..count]);
            }
            digests[index] = request.configure.semanticDigest();
        }
    }
    try std.testing.expectEqualSlices(u8, &digests[0], &digests[1]);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "an order-free request still names each member once, carries every required one, and holds content only where its kind allows" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    const header = "\"version\":\"" ++ wire_version ++ "\",\"store\":\"s\"";
    const omitted = "{\"state\":\"omitted\"}";
    const value = "{\"value\":\"x\",\"state\":\"value\"}";
    const configuration = "{\"workspace\":" ++ omitted ++ ",\"provider\":" ++ omitted ++ ",\"model\":" ++ omitted ++ ",\"tools\":" ++ omitted ++
        ",\"permission_mode\":" ++ omitted;
    const cases = [_]struct { json: []const u8, failure: ?anyerror = null }{
        .{ .json = "{\"session\":\"x\",\"key\":\"k\",\"kind\":\"session_stop\"," ++ header ++ "}" },
        .{ .json = "{\"target\":{\"operation\":\"2\",\"turn\":\"1\",\"session\":\"x\"},\"key\":\"k\"," ++ header ++ ",\"kind\":\"model_interruption\"}" },
        .{ .json = "{\"text\":" ++ value ++ ",\"sender_handle\":null,\"sender\":{\"session\":\"k7m2qx\",\"store\":\"/s\"},\"session\":\"x\",\"key\":\"k\"," ++ header ++ ",\"kind\":\"message\"}" },
        .{ .json = "{\"attempt\":\"1\",\"operation\":\"2\",\"failed_response\":\"body\",\"session\":\"x\",\"kind\":\"inspect_session\"," ++ header ++ "}" },
        .{ .json = "{\"session\":\"x\",\"kind\":\"session_stop\"," ++ header ++ "}", .failure = error.MissingField },
        .{ .json = "{\"session\":\"x\",\"key\":\"k\"," ++ header ++ "}", .failure = error.MissingField },
        .{ .json = "{\"session\":\"x\",\"key\":\"k\",\"kind\":\"session_stop\",\"store\":\"s\"}", .failure = error.MissingField },
        .{ .json = "{\"session\":\"x\",\"key\":\"k\",\"kind\":\"session_stop\",\"kind\":\"session_stop\"," ++ header ++ "}", .failure = error.UnexpectedField },
        .{ .json = "{\"session\":\"x\",\"key\":\"k\",\"session\":\"y\",\"kind\":\"session_stop\"," ++ header ++ "}", .failure = error.UnexpectedField },
        .{ .json = "{\"session\":\"x\",\"key\":\"k\",\"kind\":\"session_stop\",\"extra\":[[[[[\"deep\"]]]]]," ++ header ++ "}", .failure = error.InvalidJsonShape },
        .{ .json = "{\"session\":\"x\",\"key\":\"k\",\"kind\":\"session_stop\",\"extra\":{\"a\":[1]}," ++ header ++ "}", .failure = error.InvalidJsonShape },
        .{ .json = "{\"session\":\"x\",\"key\":\"k\",\"kind\":\"session_stop\",\"extra\":{\"a\":[true,null]}," ++ header ++ "}", .failure = error.UnexpectedField },
        .{ .json = "{\"kind\":\"session_stop\",\"text\":" ++ value ++ ",\"session\":\"x\",\"key\":\"k\"," ++ header ++ "}", .failure = error.UnexpectedField },
        // A value with no state, or a state with no value.
        .{ .json = "{\"kind\":\"message\",\"text\":{\"value\":\"x\"},\"sender_handle\":null,\"sender\":null,\"session\":\"x\",\"key\":\"k\"," ++ header ++ "}", .failure = error.MissingField },
        .{ .json = "{\"kind\":\"message\",\"text\":{\"state\":\"value\"},\"sender_handle\":null,\"sender\":null,\"session\":\"x\",\"key\":\"k\"," ++ header ++ "}", .failure = error.InvalidFieldState },
        // A Message's configuration holds no content; once the kind is
        // known that fails before capture, otherwise after it.
        .{ .json = "{\"kind\":\"message\",\"configuration\":" ++ configuration ++ ",\"output_schema\":" ++ omitted ++ ",\"instructions\":" ++ value ++ "}," ++
            "\"text\":" ++ value ++ ",\"sender_handle\":null,\"sender\":null,\"session\":\"\",\"key\":\"k\"," ++ header ++ "}", .failure = error.InvalidFieldState },
        .{ .json = "{\"configuration\":" ++ configuration ++ ",\"output_schema\":" ++ omitted ++ ",\"instructions\":" ++ value ++ "}," ++
            "\"text\":" ++ value ++ ",\"sender_handle\":null,\"sender\":null,\"session\":\"\",\"key\":\"k\"," ++ header ++ ",\"kind\":\"message\"}", .failure = error.InvalidFieldState },
        // Three content strings before the kind: no capture is left.
        .{ .json = "{\"configuration\":" ++ configuration ++ ",\"output_schema\":" ++ value ++ ",\"instructions\":" ++ value ++ "}," ++
            "\"text\":" ++ value ++ ",\"key\":\"k\",\"session\":\"x\"," ++ header ++ ",\"kind\":\"configure\"}", .failure = error.UnexpectedField },
        .{ .json = "{\"configuration\":" ++ configuration ++ ",\"output_schema\":" ++ omitted ++ ",\"instructions\":" ++ omitted ++ "}," ++
            "\"text\":" ++ value ++ ",\"sender_handle\":null,\"sender\":null,\"session\":\"x\",\"key\":\"k\"," ++ header ++ ",\"kind\":\"message\"}", .failure = error.UnexpectedField },
    };
    var used = std.atomic.Value(u64).init(0);
    var retained: ?named_scratch.Owner = null;
    for (cases, 0..) |case, index| {
        var ingress: Ingress = undefined;
        ingress.init(std.testing.allocator, .{
            .io = io,
            .content_length = case.json.len,
            .scratch_path = root[0..root_len],
            .request_number = index,
            .retained_scratch = &retained,
            .scratch_budget = .{ .used = &used, .limit = 8 },
        });
        defer ingress.deinit();
        const result = if (ingress.feed(case.json)) |_| ingress.finish() else |err| err;
        if (case.failure) |failure| {
            try std.testing.expectError(failure, result);
            continue;
        }
        const request = try result;
        try request.removeTemporaryContent(io);
    }
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expect(retained == null);
}

test "omitted loaded tools preserve pre-T4a Configure and creating Message digests" {
    // Golden bytes of the pre-T4a hash stream, not recomputed by the
    // implementation under test. Keys are deliberately outside identity.
    var configure: ConfigureCommand = .{};
    try std.testing.expectEqualStrings("e983bd4a7dce4a1ec777d065815928f654ac824dc57a57b397b8f78e7a4ede3a", &std.fmt.bytesToHex(configure.semanticDigest(), .lower));
    var message: MessageCommand = .{ .configuration = .{} };
    message.text = .{ .state = .value, .length = 2, .digest = contentDigest("go") };
    try std.testing.expectEqualStrings("29da99db4ed9dcdf55128d1f956d9551106135b126ec23d2e97cc768618b8127", &std.fmt.bytesToHex(message.semanticDigest(), .lower));
    const previous = configure.semanticDigest();
    configure.configuration.loaded_tools = try .of(&.{});
    try std.testing.expect(!std.mem.eql(u8, &previous, &configure.semanticDigest()));
    const empty = configure.semanticDigest();
    configure.configuration.loaded_tools = try .of(&.{"bash"});
    try std.testing.expect(!std.mem.eql(u8, &empty, &configure.semanticDigest()));
}

test "SessionRow borrowed fields preserve offered tool names" {
    const fields: SessionRow.Fields = .{
        .reference = "peer",
        .workspace = "/w",
        .provider = .codex,
        .model = "model",
        .tools = "[\"bash\",\"offered_tool\"]",
        .permission_mode = .ask,
        .parent = null,
        .label = null,
        .created_at = 0,
        .revision = 0,
        .end = 0,
        .first_message = null,
        .work = &.{},
        .peers = &.{},
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try fields.writeJson(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"tools\":[\"bash\",\"offered_tool\"]") != null);
    try std.testing.expect(out.written().len <= SessionRow.max_json_bytes);
}
