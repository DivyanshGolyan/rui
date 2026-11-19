// Measurement PR only, never merge: forces a recompile of every root.
const std = @import("std");
const Protocol = @This();
const session_settings = @import("session_settings.zig");
const cli_value = @import("cli_value.zig");
const command_spec = @import("command_spec.zig");
const built_in_tool = @import("built_in_tool.zig");
const model_capability = @import("model_capability.zig");
const model_list = @import("model_list.zig");
const provider_name = @import("provider_name.zig");
const command_input = @import("command_input.zig");
const mutation_answer = @import("mutation_answer.zig");
const turn_ending = @import("turn_ending.zig");
const tool_proposal = @import("tool_proposal.zig");
const message_admission = @import("message_admission.zig");
const configuration_admission = @import("configuration_admission.zig");
const workspace_path = @import("workspace_path.zig");
const store_path = @import("store_path.zig");
const provider_route = @import("provider_route.zig");
const outcome_code = @import("outcome_code.zig");
const content_string = @import("content_string.zig");
const tool_presentation = @import("tool_presentation.zig");
const tool_name = @import("tool_name.zig");
const idempotency_key = @import("idempotency_key.zig");
const message_observation = @import("message_observation.zig");
const conversation_read = @import("conversation_read.zig");
const session_list = @import("session_list.zig");
const activity_read = @import("activity_read.zig");
const activity_facts = @import("activity_facts.zig");

pub const wire_version = @import("wire_version.zig").wire_version;

pub const MessageRequestState = message_observation.MessageRequestState;

pub const message_recovery_limit = message_observation.message_recovery_limit;
pub const next_wire_version = std.fmt.comptimePrint("{d}", .{wire_number + 1});
pub const previous_wire_version = std.fmt.comptimePrint("{d}", .{wire_number - 1});
const wire_number = std.fmt.parseInt(u32, wire_version, 10) catch unreachable;
pub const max_key_bytes = idempotency_key.max_bytes;
pub const reserved_key_prefix = idempotency_key.reserved_prefix;
pub const max_session_bytes = session_id.max_reference_bytes;
pub const max_store_bytes = store_path.max_bytes;
pub const max_workspace_bytes = workspace_path.max_bytes;
const spec_content_count = count: {
    var total: usize = 0;
    for (session_settings.entries) |entry| {
        if (entry.kind == .content) total += 1;
    }
    break :count total;
};
pub const max_request_contents = 1 + spec_content_count;
pub const max_sender_handle_bytes = command_input.max_sender_handle_bytes;
pub const max_environment_bytes = 64 * 1024;
pub const max_model_bytes = model_capability.max_model_bytes;
pub const max_code_bytes = outcome_code.max_bytes;
pub const max_report_bytes = outcome_code.max_report_bytes;
pub const max_tool_description_bytes = tool_presentation.max_description_bytes;
pub const max_tool_name_bytes = tool_name.max_bytes;
pub const max_tools = tool_name.max_tools;
pub const max_tool_list_name_bytes = tool_name.max_list_name_bytes;
pub const max_preset_name_bytes = command_input.max_preset_name_bytes;
pub const max_label_bytes = tool_presentation.max_label_bytes;
pub const validLabel = tool_presentation.validLabel;
pub const Provider = provider_name.Provider;
pub const Route = provider_route.Route;
pub const Routes = provider_route.Routes;
pub const routesAll = provider_route.all;
pub const routeOf = provider_route.of;
pub const servesModel = provider_route.servesModel;

pub const Codec = provider_name.Codec;
pub const ReasoningEffort = model_capability.ReasoningEffort;
pub const max_provider_bytes = command_input.max_provider_bytes;
pub const max_header_bytes = 16 * 1024;
pub const content_window_bytes = conversation_read.content_window_bytes;
pub const public_conversation_page_items = conversation_read.public_conversation_page_items;
pub const max_json_depth = @import("json_limits.zig").max_depth;
pub const max_sqlite_content_bytes = content_string.max_bytes;
pub const session_list_page_size = session_list.session_list_page_size;

pub const Bounded = @import("bounded.zig").Bounded;

const session_id = @import("session_id.zig");
pub const session_id_bytes = session_id.bytes;
pub const session_alphabet = session_id.alphabet;
pub const validSessionId = session_id.valid;

pub const Address = command_input.Address;
pub const FieldState = command_input.FieldState;
pub const OptionalBounded = command_input.OptionalBounded;

pub fn Requests(comptime Custody: type) type {
    return struct {
        pub const ContentField = command_input.Commands(Custody).ContentField;
        pub const Configuration = command_input.Commands(Custody).Configuration;
        pub const ConfigureCommand = command_input.Commands(Custody).ConfigureCommand;
        pub const MessageCommand = command_input.Commands(Custody).MessageCommand;
        pub const Request = RequestOf(Custody);
        pub const Parser = ParserOf(Custody);
    };
}

pub const ToolsField = command_input.ToolsField;

pub const max_tool_names_bytes = tool_name.max_names_bytes;
pub const max_tool_names_json_bytes = tool_name.max_names_json_bytes;

pub const BuiltInTool = built_in_tool.BuiltInTool;
pub const ToolSelection = built_in_tool.Selection;

pub fn builtInTool(name: []const u8) ?BuiltInTool {
    return std.meta.stringToEnum(BuiltInTool, name);
}

comptime {
    const tools = std.enums.values(BuiltInTool);
    for (tools[1..], tools[0 .. tools.len - 1]) |tool, previous| {
        if (std.mem.order(u8, @tagName(previous), @tagName(tool)) != .lt) @compileError("built-in tools in name order");
    }
}
pub const validToolName = tool_name.valid;

pub const Kind = enum {
    host_info,
    host_stop,
    host_pause,
    configure,
    message,
    session_stop,
    session_archive,
    session_pin,
    model_interruption,
    permission_decision,
    action_background,
    action_stop,
    action_publish,
    observe_command,
    read_result,
    read_action,
    read_action_call_id,
    read_action_arguments,
    inspect_session,
    list_sessions,
    conversation_page,
    conversation_content,
    activity_page,
    activity_search,
    activity_content,
    public_parts,
    public_part_content,
    skill_suggestions,
    model_list,
};

pub const SkillsReloadStatus = mutation_answer.SkillsReloadStatus;

pub const SkillRequest = struct {
    operation: enum { invoke, reload } = .invoke,
    name: ?Bounded(64) = null,
};

pub const SessionStopCommand = command_input.SessionStopCommand;
pub const SessionArchiveCommand = command_input.SessionArchiveCommand;
pub const SessionPinCommand = command_input.SessionPinCommand;
pub const ModelInterruptionCommand = command_input.ModelInterruptionCommand;

pub const PermissionDecision = mutation_answer.PermissionDecision;

pub const ConfigurationRejection = configuration_admission.Rejection;
pub const MessageRejection = message_admission.Rejection;
pub const CommandKind = cli_value.CommandKind;
pub const CommandObservationStatus = message_observation.CommandObservationStatus;
pub const SessionStopCompletion = mutation_answer.SessionStopCompletion;
pub const SessionArchiveState = @import("session_archive.zig").State;
pub const SessionArchiveFilter = @import("session_archive.zig").Filter;
pub const SessionArchiveObservation = mutation_answer.SessionArchiveObservation;

pub const TurnEnding = turn_ending.TurnEnding;
pub const SessionStopRejection = mutation_answer.SessionStopRejection;
pub const SessionArchiveRejection = mutation_answer.SessionArchiveRejection;
pub const SessionPinRejection = mutation_answer.SessionPinRejection;
pub const ModelInterruptionRejection = mutation_answer.ModelInterruptionRejection;
pub const PermissionDecisionRejection = mutation_answer.PermissionDecisionRejection;
pub const MessageProgressStatus = WorkState.Progress;
pub const ConversationItemKind = conversation_read.ConversationItemKind;

pub const PermissionDecisionCommand = command_input.PermissionDecisionCommand;

pub const content_value = @import("content_value.zig");

/// The certified part list of a Session-scoped Message or Action owner.
pub const PublicParts = struct {
    store: Bounded(max_store_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    owner: content_value.Owner = .{ .message = 0 },
};

/// One part's exact bytes, framed as conversation content.
pub const PublicPartContent = struct {
    store: Bounded(max_store_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    owner: content_value.Owner = .{ .message = 0 },
    /// At most `input_parts.max_parts - 1`.
    part: u32 = 0,
    start: u64 = 0,
    /// Requires `start` 0, exactly as conversation content.
    stream: bool = false,
};

pub const ReadActionArguments = struct {
    store: Bounded(max_store_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    action_id: u64 = 0,
};

pub const ObserveCommand = struct {
    since: ?change_ring.SessionToken = null,
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
    since: ?change_ring.SessionToken = null,
    store: Bounded(max_store_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    profile: ReportProfile = .current,
    failed_response: ?FailedResponseExport = null,
};

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

pub const HostInfo = HostInfoWith(Routes);

pub fn HostInfoWith(comptime Providers: type) type {
    return struct {
        version: []const u8,
        type: []const u8,
        store: []const u8,
        instance: []const u8,
        active_capacity: []const u8,
        intake_capacity: []const u8 = "100",
        descriptor_limit: []const u8 = "unlimited",
        started_at: []const u8,
        custody_occupied: []const u8,
        paused: bool,
        innodb_doublewrite: ?[]const u8 = null,
        capabilities: struct {
            bash: bool,
            providers: Providers,
        },
    };
}

pub const ListSessions = session_list.ListSessions;

pub const ListDelta = session_list.ListDelta;

pub const ConversationPage = conversation_read.ConversationPage;
pub const ConversationContent = conversation_read.ConversationContent;

pub const ProposalField = tool_proposal.Field;
pub const ProposalFieldReference = activity_read.ProposalFieldReference;
pub const ProposalRejection = tool_proposal.Rejection;
pub const ProposalMetadata = activity_read.ProposalMetadata;

pub const ActivityPage = activity_read.ActivityPage;
pub const ActivitySearch = activity_read.ActivitySearch;

pub const ActivitySearchFacts = activity_facts.Search;

pub const ToolPresentation = tool_presentation.ToolPresentation;

pub const ToolPresentationJson = struct {
    value: ToolPresentation,

    pub const openapi_name = "ToolPresentation";
    pub const json_shape = .{ "{\"description\":", Hole{ .optional_string = max_tool_description_bytes }, ",\"code\":\"", Hole{ .tag = ToolPresentation.Code }, "\",\"publication_position\":", Hole.optional_id, "}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn writeJson(self: ToolPresentationJson, out: *std.Io.Writer) !void {
        const presentation = self.value;
        try writeShape(out, json_shape, .{ if (presentation.description) |description| description.slice() else null, presentation.code, presentation.publication_position });
    }
};

pub const Peer = struct {
    session: Bounded(max_session_bytes),

    pub const json_shape = .{ "{\"session\":", Hole{ .string = max_session_bytes }, "}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn writeJson(self: Peer, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, .{self.session.slice()});
    }
};

pub const NamedPeer = activity_facts.NamedPeer;

pub const NamedPeerJson = struct {
    value: NamedPeer,

    pub const openapi_name = "NamedPeer";
    pub const json_shape = .{ "{\"session\":", Hole{ .string = max_session_bytes }, ",\"label\":", Hole{ .optional_string = max_label_bytes }, "}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn optional(value: ?NamedPeer) ?NamedPeerJson {
        return if (value) |peer| .{ .value = peer } else null;
    }

    pub fn writeJson(self: *const NamedPeerJson, out: *std.Io.Writer) !void {
        const peer = &self.value;
        try writeShape(out, json_shape, .{ peer.session.slice(), if (peer.label.len == 0) null else peer.label.slice() });
    }
};

pub const SessionField = session_settings.SessionField;

pub const ActivityItem = activity_facts.Item;

pub const ReadActivityContent = activity_read.ReadActivityContent;
pub const ReadSkillSuggestions = struct {
    store: Bounded(max_store_bytes) = .{},
    session: ?Bounded(max_session_bytes) = null,
    workspace: ?Bounded(max_workspace_bytes) = null,
    prefix: Bounded(64) = .{},
};

pub const CallActivity = activity_facts.CallActivity;
pub const Queued = activity_facts.Queued;

pub const session_work = @import("session_work.zig");
pub const WorkState = session_work.WorkState;
pub const change_ring = @import("change_ring.zig");
pub const SinceToken = change_ring.Token;

comptime {
    std.debug.assert(session_work.max_code_bytes == max_code_bytes);
    std.debug.assert(session_work.max_description_bytes == max_tool_description_bytes);
}

pub const WorkStateJson = struct {
    state: WorkState,

    pub const plain_shape = .{ "{\"kind\":\"", Hole{ .tag = session_work.Kind }, "\",\"since\":\"", Hole.decimal, "\"}" };
    pub const compacting_shape = .{ "{\"kind\":\"working\",\"since\":\"", Hole.decimal, "\",\"compaction\":true}" };
    pub const retrying_shape = .{ "{\"kind\":\"retrying\",\"since\":\"", Hole.decimal, "\",\"due_at_ms\":\"", Hole.decimal, "\",\"cause\":", Hole{ .string = max_code_bytes }, ",\"attempt\":\"", Hole.decimal, "\"}" };
    pub const older_bash_shape = .{ "{\"kind\":\"bash\",\"since\":\"", Hole.decimal, "\",\"description\":", Hole{ .optional_string = session_work.max_description_bytes }, ",\"running\":\"", Hole.decimal, "\",\"approvals\":\"", Hole.decimal, "\"}" };
    pub const bash_shape = .{ "{\"kind\":\"bash\",\"since\":\"", Hole.decimal, "\",\"call\":\"", Hole.decimal, "\",\"description\":", Hole{ .optional_string = session_work.max_description_bytes }, ",\"running\":\"", Hole.decimal, "\",\"approvals\":\"", Hole.decimal, "\"}" };
    pub const failed_shape = .{ "{\"kind\":\"failed\",\"since\":\"", Hole.decimal, "\",\"code\":", Hole{ .string = max_code_bytes }, ",\"resets_at\":", Hole.optional_id, "}" };
    pub const stopped_shape = .{ "{\"kind\":\"stopped\",\"since\":\"", Hole.decimal, "\",\"cause\":\"", Hole{ .tag = session_work.StopCause }, "\"}" };
    pub const max_json_bytes = maxShapeBytes(.{ plain_shape, compacting_shape, retrying_shape, older_bash_shape, bash_shape, failed_shape, stopped_shape });

    pub fn writeJson(self: *const WorkStateJson, out: *std.Io.Writer) !void {
        switch (self.state) {
            .working => |value| if (value.compaction) try writeShape(out, compacting_shape, .{value.since}) else try writeShape(out, plain_shape, .{ session_work.Kind.working, value.since }),
            .retrying => |value| try writeShape(out, retrying_shape, .{ value.since, value.due_at_ms, value.cause.slice(), value.attempt }),
            .bash => |value| {
                const description = if (value.description) |text| text.slice() else null;
                if (value.call) |call| try writeShape(out, bash_shape, .{ value.since, call, description, value.running, value.approvals }) else try writeShape(out, older_bash_shape, .{ value.since, description, value.running, value.approvals });
            },
            .failed => |value| try writeShape(out, failed_shape, .{ value.since, value.code.slice(), value.resets_at }),
            .stopped => |value| try writeShape(out, stopped_shape, .{ value.since, value.cause }),
            inline .idle, .pending, .approval, .stopping, .finished => |value, kind| try writeShape(out, plain_shape, .{ kind, value.since }),
        }
    }
};

pub const WorkAttentionJson = struct {
    value: session_work.Attention,
    pub const json_shape = .{ "{\"kind\":\"", Hole{ .tag = @FieldType(session_work.Attention, "kind") }, "\",\"turn\":\"", Hole.decimal, "\",\"step\":\"", Hole.decimal, "\"}" };
    pub const max_json_bytes = shapeBytes(json_shape);
    pub fn writeJson(self: *const WorkAttentionJson, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, .{ self.value.kind, self.value.turn, self.value.step });
    }
};

pub const WorkInterruptJson = struct {
    turn: u64,
    operation: u64,
    pub const json_shape = .{ "{\"turn\":\"", Hole.decimal, "\",\"operation\":\"", Hole.decimal, "\"}" };
    pub const max_json_bytes = shapeBytes(json_shape);
    pub fn writeJson(self: *const WorkInterruptJson, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, .{ self.turn, self.operation });
    }
};

pub const WorkActionsJson = struct {
    value: session_work.Actions,
    pub const json_shape = .{ "{\"stop\":", Hole.boolean, ",\"interrupt\":", Hole{ .optional_json = WorkInterruptJson }, ",\"decide\":", Hole.optional_id, "}" };
    pub const max_json_bytes = shapeBytes(json_shape);
    pub fn writeJson(self: *const WorkActionsJson, out: *std.Io.Writer) !void {
        const target: ?WorkInterruptJson = if (self.value.interrupt) |v| .{ .turn = v.turn, .operation = v.operation } else null;
        try writeShape(out, json_shape, .{ self.value.stop, target, self.value.decide });
    }
};

pub const SessionWork = struct {
    state: WorkState = .{ .idle = .{ .since = 0 } },
    turn: ?u64 = null,
    operation: ?u64 = null,
    first_action: ?u64 = null,
    attention: ?session_work.Attention = null,
    group: session_work.Group = .done,
    actions: session_work.Actions = .{},

    pub const extra_fields = .{ ",\"attention\":", Hole{ .optional_json = WorkAttentionJson }, ",\"group\":\"", Hole{ .tag = session_work.Group }, "\",\"actions\":", Hole{ .json = WorkActionsJson } };
    pub const fields = .{ "\"state\":", Hole{ .json = WorkStateJson }, ",\"turn\":", Hole.optional_id, ",\"operation\":", Hole.optional_id, ",\"first_action\":", Hole.optional_id } ++ extra_fields;
    pub const json_shape = .{"{"} ++ fields ++ .{"}"};
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn fromCore(work: session_work.Work) SessionWork {
        return .{ .state = work.state, .turn = work.turn, .operation = work.operation, .first_action = work.first_action, .attention = if (work.served_group != null) work.served_attention else session_work.attention(work), .group = work.served_group orelse session_work.group(work), .actions = work.actions };
    }

    pub fn core(self: SessionWork) session_work.Work {
        return .{ .state = self.state, .turn = self.turn, .operation = self.operation, .first_action = self.first_action, .actions = self.actions, .served_attention = self.attention, .served_group = self.group };
    }

    pub fn extraArgs(self: *const SessionWork) struct { ?WorkAttentionJson, session_work.Group, WorkActionsJson } {
        return .{ if (self.attention) |value| .{ .value = value } else null, self.group, .{ .value = self.actions } };
    }

    pub fn args(self: *const SessionWork) struct { WorkStateJson, ?u64, ?u64, ?u64, ?WorkAttentionJson, session_work.Group, WorkActionsJson } {
        const extra = self.extraArgs();
        return .{ .{ .state = self.state }, self.turn, self.operation, self.first_action, extra[0], extra[1], extra[2] };
    }

    pub fn writeJson(self: *const SessionWork, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, self.args());
    }
};

pub const PageWork = activity_facts.PageWork;

pub const PeerFacts = struct {
    from_person_at: ?u64 = null,

    pub const json_shape = .{ "{\"from_person_at\":", Hole.optional_id, "}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn writeJson(self: *const PeerFacts, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, .{self.from_person_at});
    }
};

pub const FirstMessage = struct {
    position: u64,
    admission: u64,
    admitted_at: u64,
    sender: ?Peer,
    content: content_value.Value,

    pub const json_shape = .{ "{\"position\":\"", Hole.decimal, "\",\"admission\":\"", Hole.decimal, "\",\"admitted_at\":\"", Hole.decimal, "\",\"sender\":", Hole{ .optional_json = Peer }, ",\"content\":", Hole{ .json = ContentValueJson }, "}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub fn fromCore(first: session_list.FirstMessage) FirstMessage {
        return .{
            .position = first.position,
            .admission = first.admission,
            .admitted_at = first.admitted_at,
            .sender = if (first.sender) |sender| .{ .session = sender } else null,
            .content = first.content,
        };
    }

    pub fn writeJson(self: *const FirstMessage, out: *std.Io.Writer) !void {
        try writeShape(out, json_shape, .{ self.position, self.admission, self.admitted_at, self.sender, ContentValueJson{ .value = self.content } });
    }
};

pub const LastLine = struct {
    position: u64,
    text: ?Bounded(session_list.max_last_line_bytes),

    pub const json_shape = .{ "{\"position\":\"", Hole.decimal, "\",\"text\":", Hole{ .optional_string = session_list.max_last_line_bytes }, "}" };
    pub const max_json_bytes = shapeBytes(json_shape);

    pub const Fields = struct {
        position: u64,
        text: ?[]const u8,
        pub const json_shape = LastLine.json_shape;
        pub const max_json_bytes = LastLine.max_json_bytes;

        pub fn writeJson(self: *const Fields, out: *std.Io.Writer) !void {
            try writeShape(out, LastLine.json_shape, .{ self.position, self.text });
        }
    };

    pub fn fields(self: *const LastLine) Fields {
        return .{ .position = self.position, .text = if (self.text) |*text| text.slice() else null };
    }

    pub fn writeJson(self: *const LastLine, out: *std.Io.Writer) !void {
        try self.fields().writeJson(out);
    }
};

pub const PermissionMode = cli_value.PermissionMode;

pub const SessionRow = struct {
    read_version: change_ring.Token = .{ .instance = @splat(0), .generation = 0 },
    archive_state: SessionArchiveState = .active,
    pin_order: ?u64 = null,
    reference: Bounded(max_session_bytes) = .{},
    workspace: Bounded(max_workspace_bytes) = .{},
    provider: Provider = .codex,
    model: Bounded(max_model_bytes) = .{},
    tools: ToolsField = .{ .state = .value },
    permission_mode: PermissionMode = .ask,
    parent: ?Bounded(session_id_bytes) = null,
    creator: ?Bounded(session_id_bytes) = null,
    label: ?Bounded(max_label_bytes) = null,
    created_at: u64 = 0,
    revision: u64 = 0,
    end: u64 = 0,
    first_message: ?FirstMessage = null,
    last_line: ?LastLine = null,
    work: SessionWork = .{},
    peers: PeerFacts = .{},

    pub const json_shape = .{
        "{\"read_version\":\"",  Hole{ .text = change_ring.Token.max_bytes }, "\",\"archive_state\":\"", Hole{ .tag = SessionArchiveState },         "\",\"pin_order\":",  Hole.optional_id,                          ",\"reference\":",         Hole{ .string = max_session_bytes }, ",\"workspace\":", Hole{ .string = max_workspace_bytes },
        ",\"provider\":\"",      Hole{ .tag = Provider },                     "\",\"model\":",           Hole{ .string = max_model_bytes },          ",\"tools\":",        Hole{ .text = max_tool_names_json_bytes }, ",\"permission_mode\":\"", Hole{ .tag = PermissionMode },       "\",\"parent\":",  Hole{ .optional_string = session_id_bytes },
        ",\"creator\":",         Hole{ .optional_string = session_id_bytes }, ",\"label\":",             Hole{ .optional_string = max_label_bytes }, ",\"created_at\":\"", Hole.decimal,                              "\",\"revision\":\"",      Hole.decimal,                        "\",\"end\":\"",   Hole.decimal,
        "\",\"first_message\":", Hole{ .optional_json = FirstMessage },       ",\"last_line\":",         Hole{ .optional_json = LastLine.Fields },   ",\"work\":",         Hole{ .json = SessionWork },               ",\"peers\":",             Hole{ .json = PeerFacts },           "}",
    };
    pub const max_json_bytes = shapeBytes(json_shape);
    pub const budget_bytes = 36 * 1024;
    comptime {
        std.debug.assert(max_json_bytes <= budget_bytes);
    }

    pub const Fields = struct {
        read_version: change_ring.Token = .{ .instance = @splat(0), .generation = 0 },
        archive_state: SessionArchiveState = .active,
        pin_order: ?u64 = null,
        reference: []const u8,
        workspace: []const u8,
        provider: Provider,
        model: []const u8,
        tools: []const u8,
        permission_mode: PermissionMode,
        parent: ?[]const u8,
        creator: ?[]const u8 = null,
        label: ?[]const u8,
        created_at: u64,
        revision: u64,
        end: u64,
        first_message: ?FirstMessage,
        last_line: ?LastLine.Fields,
        work: *const SessionWork,
        peers: *const PeerFacts,

        pub const max_json_bytes = SessionRow.max_json_bytes;

        pub fn writeJson(f: *const Fields, out: *std.Io.Writer) !void {
            var token_buffer: [change_ring.Token.max_bytes]u8 = undefined;
            try writeShape(out, json_shape, .{
                f.read_version.format(&token_buffer), f.archive_state,   f.pin_order, f.reference, f.workspace, f.provider,   f.model,
                f.tools,                              f.permission_mode, f.parent,    f.creator,   f.label,     f.created_at, f.revision,
                f.end,                                f.first_message,   f.last_line, f.work,      f.peers,
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
            .read_version = self.read_version,
            .archive_state = self.archive_state,
            .pin_order = self.pin_order,
            .reference = self.reference.slice(),
            .workspace = self.workspace.slice(),
            .provider = self.provider,
            .model = self.model.slice(),
            .tools = tools_writer.buffered(),
            .permission_mode = self.permission_mode,
            .parent = if (self.parent) |*parent| parent.slice() else null,
            .creator = if (self.creator) |*creator| creator.slice() else null,
            .label = if (self.label) |*label| label.slice() else null,
            .created_at = self.created_at,
            .revision = self.revision,
            .end = self.end,
            .first_message = self.first_message,
            .last_line = if (self.last_line) |*last| last.fields() else null,
            .work = &self.work,
            .peers = &self.peers,
        };
        try fields.writeJson(out);
    }
};

pub const session_list_reply = struct {
    pub const head = .{"{\"version\":\"" ++ wire_version ++ "\",\"type\":\"session_list\",\"sessions\":["};
    const facts = .{ "],\"delta\":\"", Hole{ .tag = ListDelta }, "\",\"since\":\"", Hole{ .text = SinceToken.max_bytes }, "\",\"next\":" };
    pub const full_tail = facts ++ .{ "{\"after\":\"", Hole.decimal, "\",\"ceiling\":\"", Hole.decimal, "\"}}" };
    pub const changed_tail = facts ++ .{ "{\"through\":\"", Hole.decimal, "\",\"after_reference\":", Hole{ .string = session_id_bytes }, "}}" };
    pub const last_tail = facts ++ .{"null}"};
    pub const max_bytes = shapeBytes(head) + jsonListBytes(session_list_page_size, SessionRow.max_json_bytes) + maxShapeBytes(.{ full_tail, changed_tail, last_tail });
};

pub const ActivityFacts = activity_facts.Page;

fn RequestOf(comptime Custody: type) type {
    const ContentField = Requests(Custody).ContentField;
    const ConfigureCommand = Requests(Custody).ConfigureCommand;
    const MessageCommand = Requests(Custody).MessageCommand;
    return union(Kind) {
        const Request = @This();

        host_info: struct { store: Bounded(max_store_bytes) = .{} },
        host_stop: struct { store: Bounded(max_store_bytes) = .{} },
        host_pause: struct { store: Bounded(max_store_bytes) = .{}, paused: bool = false },
        configure: ConfigureCommand,
        message: MessageCommand,
        session_stop: SessionStopCommand,
        session_archive: SessionArchiveCommand,
        session_pin: SessionPinCommand,
        model_interruption: ModelInterruptionCommand,
        permission_decision: PermissionDecisionCommand,
        action_background: command_input.ActionBackgroundCommand,
        action_stop: command_input.ActionStopCommand,
        action_publish: struct { store: Bounded(max_store_bytes) = .{}, handle: Bounded(32) = .{}, key: Bounded(max_key_bytes) = .{}, text: ContentField = .{} },
        observe_command: ObserveCommand,
        read_result: ReadResult,
        read_action: @import("action_read.zig").Request,
        read_action_call_id: ReadActionArguments,
        read_action_arguments: ReadActionArguments,
        inspect_session: InspectSession,
        list_sessions: ListSessions,
        conversation_page: ConversationPage,
        conversation_content: ConversationContent,
        activity_page: ActivityPage,
        activity_search: ActivitySearch,
        activity_content: ReadActivityContent,
        public_parts: PublicParts,
        public_part_content: PublicPartContent,
        skill_suggestions: ReadSkillSuggestions,
        model_list: struct { store: Bounded(max_store_bytes) = .{} },

        pub fn removeTemporaryContent(self: *Request, io: Custody.Io) !void {
            switch (self.*) {
                .configure => |*command| try command.removeTemporaryContent(io),
                .message => |*command| try command.removeTemporaryContent(io),
                .action_publish => |*command| try command.text.removeTemporaryContent(io),
                .host_info, .host_stop, .host_pause, .session_stop, .session_archive, .session_pin, .model_interruption, .permission_decision, .action_background, .action_stop, .observe_command, .read_result, .read_action, .read_action_call_id, .read_action_arguments, .inspect_session, .list_sessions, .conversation_page, .conversation_content, .activity_page, .activity_search, .activity_content, .public_parts, .public_part_content, .skill_suggestions, .model_list => {},
            }
        }

        pub fn store(self: *const Request) []const u8 {
            return switch (self.*) {
                inline else => |*request| request.store.slice(),
            };
        }
    };
}

pub const contentHasher = content_string.hasher;
pub const contentDigest = content_string.digest;

pub const MetadataSource = struct {
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

fn ParserOf(comptime Custody: type) type {
    const ContentField = Requests(Custody).ContentField;
    const Configuration = Requests(Custody).Configuration;
    const ConfigureCommand = Requests(Custody).ConfigureCommand;
    const MessageCommand = Requests(Custody).MessageCommand;
    const Request = Requests(Custody).Request;
    return struct {
        const Parser = @This();

        source: *MetadataSource,
        expected_kind: ?Kind = null,
        content_ordinal: u8 = 0,
        part_ordinal: u32 = 0,
        part_started: u32 = 0,
        part_finished: u32 = 0,
        part_image: bool = false,
        part_format: ?@import("input_media.zig").Format = null,
        captured: []const ContentField = &.{},
        spec_field: Bounded(32) = .{},

        /// Members of every request object may come in any order, as JSON
        /// allows, so a client generated in any language can build one (D212).
        /// The first pass reads `version`, `kind` and `store` wherever they sit
        /// and counts content strings as they arrive; the second sets the
        /// command's arm in `out` and fills it in place, meeting the content
        /// strings in the same order.
        pub fn parse(self: *Parser, out: *Request) !void {
            const start = self.source.start;
            const header = try self.scanHeader();
            self.source.start = start;
            self.content_ordinal = 0;
            self.part_ordinal = 0;
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
                .session_archive => {
                    out.* = .{ .session_archive = .{ .store = store } };
                    try self.parseSessionArchive(&out.session_archive, &members);
                },
                .session_pin => {
                    out.* = .{ .session_pin = .{ .store = store } };
                    try self.parseSessionPin(&out.session_pin, &members);
                },
                .model_interruption => {
                    out.* = .{ .model_interruption = .{ .store = store } };
                    try self.parseModelInterruption(&out.model_interruption, &members);
                },
                .permission_decision => {
                    out.* = .{ .permission_decision = .{ .store = store } };
                    try self.parsePermissionDecision(&out.permission_decision, &members);
                },
                .action_background => {
                    out.* = .{ .action_background = .{ .store = store } };
                    try self.parseActionBackground(&out.action_background, &members);
                },
                .action_stop => {
                    out.* = .{ .action_stop = .{ .store = store } };
                    try self.parseActionStop(&out.action_stop, &members);
                },
                .action_publish => {
                    out.* = .{ .action_publish = .{ .store = store } };
                    try self.parseActionPublish(&out.action_publish, &members);
                },
                .read_action => {
                    out.* = .{ .read_action = .{ .store = store } };
                    try self.parseReadAction(&out.read_action, &members);
                },
                .observe_command => {
                    out.* = .{ .observe_command = .{ .store = store } };
                    try self.parseObserveCommand(&out.observe_command, &members);
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
                .activity_search => {
                    out.* = .{ .activity_search = .{ .store = store } };
                    try self.parseActivitySearch(&out.activity_search, &members);
                },
                .activity_page => {
                    out.* = .{ .activity_page = .{ .store = store } };
                    try self.parseActivityPage(&out.activity_page, &members);
                },
                .activity_content => {
                    out.* = .{ .activity_content = .{ .store = store } };
                    try self.parseActivityContent(&out.activity_content, &members);
                },
                .public_parts => {
                    out.* = .{ .public_parts = .{ .store = store } };
                    try self.parsePublicParts(&out.public_parts, &members);
                },
                .public_part_content => {
                    out.* = .{ .public_part_content = .{ .store = store } };
                    try self.parsePublicPartContent(&out.public_part_content, &members);
                },
                .skill_suggestions => {
                    out.* = .{ .skill_suggestions = .{ .store = store } };
                    const Field = enum { session, workspace, prefix };
                    var seen: std.enums.EnumSet(Field) = .empty;
                    while (try self.nextCommandField(Field, &members, &seen)) |field| switch (field) {
                        .session => {
                            out.skill_suggestions.session = .{};
                            try self.readSmallString(&out.skill_suggestions.session.?);
                        },
                        .workspace => {
                            out.skill_suggestions.workspace = .{};
                            try self.readSmallString(&out.skill_suggestions.workspace.?);
                        },
                        .prefix => try self.readSmallString(&out.skill_suggestions.prefix),
                    };
                    if (seen.contains(.session) == seen.contains(.workspace) or !seen.contains(.prefix)) return error.MissingField;
                    if (out.skill_suggestions.session) |session| if (!validSessionId(session.slice())) return error.InvalidSession;
                    if (out.skill_suggestions.workspace) |workspace| if (workspace.len == 0) return error.InvalidWorkspace;
                },
            }
            if (!self.source.atEnd()) {
                return error.TrailingInput;
            }
        }

        const Header = struct { kind: Kind, store: Bounded(max_store_bytes) };

        fn scanHeader(self: *Parser) !Header {
            const Field = enum { version, kind, store, text, value, parts, configuration };
            try self.expectByte('{');
            var members: Members = .{};
            var seen: std.enums.EnumSet(Field) = .empty;
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
                        if (self.expected_kind) |expected| {
                            if (named != expected) return error.RouteKindMismatch;
                        }
                        kind = named;
                    },
                    .store => try self.readSmallString(&store),
                    .text => {
                        if (kind) |named| if (named != .message) return error.UnexpectedField;
                        try self.scanContentEnvelope(true);
                    },
                    .value => {
                        if (self.expected_kind) |expected| if (expected != .action_publish) return error.UnexpectedField;
                        if (kind) |named| if (named != .action_publish) return error.UnexpectedField;
                        var counted: ContentField = .{};
                        try self.readContentString(&counted);
                    },
                    .parts => {
                        if (kind) |named| if (named != .message) return error.UnexpectedField;
                        try self.scanParts();
                    },
                    .configuration => {
                        if (kind) |named| if (named != .configure and named != .message) return error.UnexpectedField;
                        try self.scanConfiguration();
                    },
                }
            }
            if (!seen.contains(.version) or !seen.contains(.store)) return error.MissingField;
            const selected = kind orelse return error.MissingField;
            if (seen.contains(.value) and selected != .action_publish) return error.UnexpectedField;
            return .{ .kind = selected, .store = store };
        }

        fn scanParts(self: *Parser) !void {
            const Field = enum { type, mime, text, data };
            try self.expectByte('[');
            var count: u32 = 0;
            if (!try self.consumeIf(']')) while (true) {
                if (self.part_ordinal >= @import("input_parts.zig").max_parts) return error.TooManyInputParts;
                const ordinal = self.part_ordinal;
                self.part_ordinal += 1;
                count += 1;
                try self.expectByte('{');
                var members: Members = .{};
                var seen: std.enums.EnumSet(Field) = .empty;
                var kind: Bounded(8) = .{};
                var mime: Bounded(16) = .{};
                while (try self.nextField(Field, &members, &seen)) |field| switch (field) {
                    .type => try self.readSmallString(&kind),
                    .mime => try self.readSmallString(&mime),
                    .text, .data => {
                        self.part_image = field == .data;
                        if (ordinal >= self.part_started) return error.NeedPartStart;
                        try self.expectByte('"');
                        if (try self.source.readByte() != '"') return error.InvalidJsonShape;
                    },
                };
                if (!seen.contains(.type)) return error.MissingField;
                self.part_image = kind.eql("image");
                if (kind.eql("text")) {
                    if (!seen.contains(.text) or seen.contains(.data) or seen.contains(.mime)) return error.InvalidMessage;
                    self.part_format = null;
                } else if (self.part_image) {
                    if (!seen.contains(.data) or seen.contains(.text) or !seen.contains(.mime)) return error.InvalidMessage;
                    self.part_format = if (mime.eql("image/png")) .png else if (mime.eql("image/jpeg")) .jpeg else return error.UnsupportedImage;
                } else return error.InvalidMessage;
                if (ordinal >= self.part_finished) return error.NeedPartEnd;
                if (try self.consumeIf(']')) break;
                try self.expectByte(',');
            };
            if (count == 0) return error.InvalidMessage;
        }

        fn scanConfiguration(self: *Parser) !void {
            try self.expectByte('{');
            var members: Members = .{};
            var seen = std.enums.EnumSet(std.meta.FieldEnum(Configuration)).empty;
            var key: Bounded(32) = .{};
            while (try members.next(self, &key)) {
                const field = try specField(&key, &seen);
                switch (field) {
                    inline else => |tag| {
                        const entry = session_settings.spec_entries[@backingInt(tag)];
                        if (entry.kind == .content) {
                            self.skipWhitespace() catch |err| return if (err == error.NeedInput and self.content_ordinal >= self.captured.len) (if (entry.json_object) error.NeedSchema else error.NeedContent) else err;
                            if (!try self.readNull()) {
                                if (self.content_ordinal == max_request_contents) return error.UnexpectedField;
                                var counted: ContentField = .{};
                                if (entry.json_object) try self.readSchema(&counted) else try self.readContentString(&counted);
                            }
                        } else try self.skipValue();
                    },
                }
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
                if (self.content_ordinal == max_request_contents) return error.UnexpectedField;
                var counted: ContentField = .{};
                try self.readContentString(&counted);
            }
        }

        const Members = struct {
            started: bool = false,

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

        fn nextField(self: *Parser, comptime Field: type, members: *Members, seen: *std.enums.EnumSet(Field)) !?Field {
            var key: Bounded(32) = .{};
            if (!try members.next(self, &key)) return null;
            return try fieldOf(Field, &key, seen);
        }

        fn nextCommandField(self: *Parser, comptime Field: type, members: *Members, seen: *std.enums.EnumSet(Field)) !?Field {
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

        fn fieldOf(comptime Field: type, key: *const Bounded(32), seen: *std.enums.EnumSet(Field)) !Field {
            const field = std.meta.stringToEnum(Field, key.slice()) orelse return error.UnexpectedField;
            if (seen.contains(field)) return error.UnexpectedField;
            seen.insert(field);
            return field;
        }

        fn require(comptime Field: type, seen: std.enums.EnumSet(Field), required: []const Field) !void {
            for (required) |field| if (!seen.contains(field)) return error.MissingField;
        }

        fn parseHostPause(self: *Parser, out: *@FieldType(Request, "host_pause"), members: *Members) !void {
            const Field = enum { paused };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .paused => out.paused = try self.readBoolean(),
            };
            try require(Field, seen, &.{.paused});
        }

        fn readSessionToken(self: *Parser) !?change_ring.SessionToken {
            if (try self.readNull()) return null;
            var token: Bounded(change_ring.SessionToken.max_bytes) = .{};
            self.readSmallString(&token) catch return error.InvalidSince;
            return change_ring.SessionToken.parse(token.slice()) catch return error.InvalidSince;
        }

        fn parseObserveCommand(self: *Parser, out: *ObserveCommand, members: *Members) !void {
            const Field = enum { key, since };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .key => try self.readSmallString(&out.key),
                .since => out.since = try self.readSessionToken(),
            };
            try require(Field, seen, &.{.key});
        }

        fn parseKeyOnly(self: *Parser, key: *Bounded(max_key_bytes), members: *Members) !void {
            const Field = enum { key };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .key => try self.readSmallString(key),
            };
            try require(Field, seen, &.{.key});
        }

        fn parseConfigure(self: *Parser, out: *ConfigureCommand, members: *Members) !void {
            const Field = enum { key, session, configuration, preset, require_model, reload_skills };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .key => try self.readCommandKey(&out.key),
                .session => try self.readSmallString(&out.session),
                .configuration => try self.parseConfiguration(&out.configuration),
                .preset => {
                    out.preset = .{};
                    try self.readSmallString(&out.preset.?);
                },
                .require_model => out.require_model = try self.readBoolean(),
                .reload_skills => out.reload_skills = try self.readBoolean(),
            };
            try require(Field, seen, &.{ .key, .session, .configuration });
            if (out.session.len == 0 and out.preset == null) try validateCreatingConfiguration(&out.configuration);
        }

        fn specField(key: *const Bounded(32), seen: *std.enums.EnumSet(std.meta.FieldEnum(Configuration))) !std.meta.FieldEnum(Configuration) {
            inline for (session_settings.spec_entries, 0..) |entry, index| {
                if (key.eql(entry.spec)) {
                    const field: std.meta.FieldEnum(Configuration) = @fromBackingInt(@intCast(index));
                    if (seen.contains(field)) return error.UnexpectedField;
                    seen.insert(field);
                    return field;
                }
            }
            return error.UnexpectedField;
        }

        pub fn parseConfiguration(self: *Parser, out: *Configuration) !void {
            try self.expectByte('{');
            var members: Members = .{};
            var seen = std.enums.EnumSet(std.meta.FieldEnum(Configuration)).empty;
            while (try members.next(self, &self.spec_field)) {
                const field = try specField(&self.spec_field, &seen);
                switch (field) {
                    inline else => |tag| {
                        const entry = session_settings.spec_entries[@backingInt(tag)];
                        const name = entry.field;
                        const value = &@field(out, name);
                        if (try self.readNull()) {
                            if (!entry.nullable) return error.InvalidFieldState;
                            value.state = .explicit_null;
                            continue;
                        }
                        value.state = .value;
                        switch (entry.kind) {
                            .text, .choice => try self.readSmallString(&value.value),
                            .content => if (entry.json_object) try self.readSchema(value) else try self.readContentString(value),
                            .tools => try self.readToolList(value),
                            .decimal_policy => try self.readSpecDecimal(&value.value),
                        }
                    },
                }
            }
        }

        fn readSpecDecimal(self: *Parser, value: *Bounded(20)) !void {
            try self.skipWhitespace();
            value.len = 0;
            while (true) {
                const byte = try self.source.readByte();
                if (byte < '0' or byte > '9') {
                    self.source.start -= 1;
                    break;
                }
                if (value.len == value.bytes.len) return error.ValueTooLong;
                value.bytes[value.len] = byte;
                value.len += 1;
            }
            if (value.len == 0 or (value.len > 1 and value.bytes[0] == '0')) return error.InvalidJsonShape;
        }

        fn readToolList(self: *Parser, tools: *ToolsField) !void {
            try self.expectByte('[');
            tools.count = 0;
            tools.names.len = 0;
            if (!try self.consumeIf(']')) while (true) {
                var name: Bounded(max_tool_name_bytes) = .{};
                self.readSmallString(&name) catch |err| return if (err == error.ValueTooLong) error.InvalidToolName else err;
                try tools.insert(name.slice());
                if (try self.consumeIf(']')) break;
                try self.expectByte(',');
            };
        }

        fn validateCreatingConfiguration(configuration: *const Configuration) !void {
            if (missingCreatingSetting(configuration, configuration.parent.state == .value) != null) return error.MissingField;
        }

        fn parseMessage(self: *Parser, out: *MessageCommand, members: *Members) !void {
            const Field = enum { key, session, sender, sender_handle, configuration, text, parts, require_model };
            var seen: std.enums.EnumSet(Field) = .empty;
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
                    try self.parseConfiguration(&out.configuration.?);
                },
                .text => try self.readContent(&out.text, false, true),
                .parts => try self.scanParts(),
                .require_model => out.require_model = try self.readBoolean(),
            };
            try require(Field, seen, &.{ .key, .session, .sender, .sender_handle });
            if (seen.contains(.text) == seen.contains(.parts)) return error.InvalidMessage;
            if (out.session.len == 0 and out.configuration == null) return error.MissingField;
            if (out.session.len == 0) try validateCreatingConfiguration(&out.configuration.?);
            if (out.session.len != 0 and out.configuration != null) return error.UnexpectedField;
            if (seen.contains(.text) and out.text.state != .value) return error.InvalidMessage;
            if (seen.contains(.require_model) and out.configuration == null) return error.InvalidMessage;
        }

        fn parseAddress(self: *Parser, out: *Address) !void {
            const Field = enum { store, session };
            try self.expectByte('{');
            var members: Members = .{};
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextField(Field, &members, &seen)) |field| switch (field) {
                .store => try self.readSmallString(&out.store),
                .session => try self.readSmallString(&out.session),
            };
            try require(Field, seen, &.{ .store, .session });
        }

        fn parseSessionStop(self: *Parser, out: *SessionStopCommand, members: *Members) !void {
            const Field = enum { key, session };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .key => try self.readCommandKey(&out.key),
                .session => try self.readSmallString(&out.session),
            };
            try require(Field, seen, &.{ .key, .session });
        }

        fn parseSessionArchive(self: *Parser, out: *SessionArchiveCommand, members: *Members) !void {
            const Field = enum { key, session, archived };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .key => try self.readCommandKey(&out.key),
                .session => try self.readSmallString(&out.session),
                .archived => out.archived = try self.readBoolean(),
            };
            try require(Field, seen, &.{ .key, .session });
        }

        fn parseSessionPin(self: *Parser, out: *SessionPinCommand, members: *Members) !void {
            const Field = enum { key, session, pinned };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .key => try self.readCommandKey(&out.key),
                .session => try self.readSmallString(&out.session),
                .pinned => out.pinned = try self.readBoolean(),
            };
            try require(Field, seen, &.{ .key, .session, .pinned });
        }

        fn parseModelInterruption(self: *Parser, out: *ModelInterruptionCommand, members: *Members) !void {
            const Field = enum { key, target };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .key => try self.readCommandKey(&out.key),
                .target => {
                    const Target = enum { session, turn, operation };
                    try self.expectByte('{');
                    var target_members: Members = .{};
                    var target_seen: std.enums.EnumSet(Target) = .empty;
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
            var seen: std.enums.EnumSet(Field) = .empty;
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

        fn parseActionBackground(self: *Parser, out: *command_input.ActionBackgroundCommand, members: *Members) !void {
            const Field = enum { key, session, action };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .key => try self.readCommandKey(&out.key),
                .session => try self.readSmallString(&out.session),
                .action => out.action_id = try self.readCanonicalU64(),
            };
            try require(Field, seen, &.{ .key, .session, .action });
        }

        fn parseActionStop(self: *Parser, out: *command_input.ActionStopCommand, members: *Members) !void {
            const Field = enum { key, session, action };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .key => try self.readCommandKey(&out.key),
                .session => try self.readSmallString(&out.session),
                .action => out.action_id = try self.readCanonicalU64(),
            };
            try require(Field, seen, &.{ .key, .session, .action });
        }

        fn parseActionPublish(self: *Parser, out: anytype, members: *Members) !void {
            const Field = enum { handle, key, value };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .handle => try self.readSmallString(&out.handle),
                .key => try self.readSmallString(&out.key),
                .value => {
                    try self.readContentString(&out.text);
                    out.text.state = .value;
                },
            };
            try require(Field, seen, &.{ .handle, .key, .value });
            if (out.key.len == 0) return error.InvalidKey;
        }

        fn parsePublicParts(self: *Parser, out: *PublicParts, members: *Members) !void {
            const Field = enum { session, owner };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .session => try self.readSmallString(&out.session),
                .owner => out.owner = try self.readOwner(),
            };
            try require(Field, seen, &.{ .session, .owner });
        }

        fn parsePublicPartContent(self: *Parser, out: *PublicPartContent, members: *Members) !void {
            const Field = enum { session, owner, part, start, stream };
            var seen: std.enums.EnumSet(Field) = .empty;
            var part: u64 = 0;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .session => try self.readSmallString(&out.session),
                .owner => out.owner = try self.readOwner(),
                .part => part = try self.readCanonicalU64(),
                .start => out.start = try self.readCanonicalU64(),
                .stream => {
                    for ("true") |byte| try self.expectByte(byte);
                    out.stream = true;
                },
            };
            try require(Field, seen, &.{ .session, .owner, .part, .start });
            if (part >= @import("input_parts.zig").max_parts or (out.stream and out.start != 0)) return error.InvalidCursor;
            out.part = @intCast(part);
        }

        /// `{"message":"ID"}` or `{"action":"ID"}`: exactly one known owner kind and a positive id.
        fn readOwner(self: *Parser) !content_value.Owner {
            try self.expectByte('{');
            var members: Members = .{};
            var key: Bounded(32) = .{};
            if (!try members.next(self, &key)) return error.MissingField;
            const kind = std.meta.stringToEnum(content_value.Owner.Kind, key.slice()) orelse return error.InvalidTarget;
            const id = try self.readCanonicalU64();
            if (try members.next(self, &key)) return error.UnexpectedField;
            if (id == 0 or id > std.math.maxInt(i64)) return error.InvalidTarget;
            return .of(kind, id);
        }

        fn parseReadAction(self: *Parser, out: *@import("action_read.zig").Request, members: *Members) !void {
            const Field = enum { session, action, offset, after };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .session => try self.readSmallString(&out.session),
                .action => out.action_id = try self.readCanonicalU64(),
                .offset => out.offset = try self.readCanonicalU64(),
                .after => out.after = try self.readCanonicalU64(),
            };
            try require(Field, seen, &.{ .session, .action });
        }

        fn parseReadActionArguments(self: *Parser, out: *ReadActionArguments, members: *Members) !void {
            const Field = enum { session, action };
            var seen: std.enums.EnumSet(Field) = .empty;
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
            const Field = enum { session, profile, failed_response, operation, attempt, since };
            var seen: std.enums.EnumSet(Field) = .empty;
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
                .since => out.since = try self.readSessionToken(),
            };
            try require(Field, seen, &.{.session});
            if (seen.contains(.since) and (seen.contains(.profile) or seen.contains(.failed_response))) return error.UnexpectedField;
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
            const Field = enum { workspace, archive, after, ceiling, since, through, after_reference };
            var seen: std.enums.EnumSet(Field) = .empty;
            var through: u64 = 0;
            var reference: Bounded(session_id_bytes) = .{};
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .workspace => if (!try self.readNull()) {
                    out.workspace = .{ .len = 0 };
                    try self.readSmallString(&out.workspace.?);
                },
                .archive => {
                    var archive: Bounded(16) = .{};
                    try self.readSmallString(&archive);
                    out.archive = std.meta.stringToEnum(SessionArchiveFilter, archive.slice()) orelse return error.InvalidArchiveFilter;
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
            if (seen.contains(.through) or seen.contains(.after_reference)) {
                if (!seen.contains(.through) or !seen.contains(.after_reference) or out.since == null) return error.InvalidCursor;
                out.changed = .{ .through = through, .after_reference = reference.bytes[0..session_id_bytes].* };
            }
            try out.validate();
        }

        fn parseConversationPage(self: *Parser, out: *ConversationPage, members: *Members) !void {
            const Field = enum { session, end, before_position, before_ordinal };
            var seen: std.enums.EnumSet(Field) = .empty;
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
            var seen: std.enums.EnumSet(Field) = .empty;
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
            const Field = enum { session, end, position, ordinal, direction, kinds, limit, since };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .session => try self.readSmallString(&out.session),
                .since => out.since = try self.readSessionToken(),
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

        fn parseActivitySearch(self: *Parser, out: *ActivitySearch, members: *Members) !void {
            const Field = enum { session, query, before_position, before_ordinal, kinds, limit };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .session => try self.readSmallString(&out.session),
                .query => try self.readSmallString(&out.query),
                .before_position => if (!try self.readNull()) {
                    out.before_position = try self.readCanonicalU64();
                },
                .before_ordinal => if (!try self.readNull()) {
                    out.before_ordinal = try self.readCanonicalU64();
                },
                .kinds => {
                    try self.expectByte('[');
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
            try require(Field, seen, &.{ .session, .query });
            try out.validate();
        }

        fn parseActivityContent(self: *Parser, out: *ReadActivityContent, members: *Members) !void {
            const Field = enum { session, position, ordinal };
            var seen: std.enums.EnumSet(Field) = .empty;
            while (try self.nextCommandField(Field, members, &seen)) |field| switch (field) {
                .session => try self.readSmallString(&out.session),
                .position => out.position = try self.readCanonicalU64(),
                .ordinal => out.ordinal = try self.readCanonicalU64(),
            };
            try require(Field, seen, &.{ .session, .position, .ordinal });
            if (out.position == 0 or out.position > std.math.maxInt(i64) or out.ordinal > std.math.maxInt(i64)) return error.InvalidCursor;
        }

        const Envelope = enum { state, value };

        fn envelopeState(state: *const Bounded(16), seen: std.enums.EnumSet(Envelope), allow_null: bool) !FieldState {
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

        fn readContent(self: *Parser, field: *ContentField, allow_null: bool, allow_value: bool) !void {
            try self.expectByte('{');
            var members: Members = .{};
            var seen: std.enums.EnumSet(Envelope) = .empty;
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

        fn readNull(self: *Parser) !bool {
            if (!try self.consumeIf('n')) return false;
            for ("ull") |expected| if (try self.source.readByte() != expected) return error.InvalidJsonShape;
            return true;
        }

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
                    '0'...'9' => {
                        self.source.start -= 1;
                        var digits: Bounded(20) = .{};
                        try self.readSpecDecimal(&digits);
                    },
                    else => return error.InvalidJsonShape,
                }
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

        fn readCommandKey(self: *Parser, key: *Bounded(max_key_bytes)) !void {
            try self.readSmallString(key);
            if (std.mem.startsWith(u8, key.slice(), reserved_key_prefix)) return error.ReservedCommandKey;
        }

        fn readSmallString(self: *Parser, destination: anytype) !void {
            var sink = SmallSink(@TypeOf(destination.*)){ .destination = destination };
            try self.readJsonString(&sink);
            if (!std.unicode.utf8ValidateSlice(destination.slice())) return error.InvalidUtf8;
        }

        fn readSchema(self: *Parser, field: *ContentField) !void {
            self.content_ordinal += 1;
            if (self.content_ordinal > self.captured.len) return error.NeedSchema;
            try self.expectByte('[');
            try self.expectByte(']');
            const original = self.captured[self.content_ordinal - 1];
            field.length = original.length;
            field.digest = original.digest;
            field.capture = self.content_ordinal;
            field.borrowed = original.borrowed;
        }

        fn readContentString(self: *Parser, field: *ContentField) !void {
            self.content_ordinal += 1;
            if (self.content_ordinal > self.captured.len) return error.NeedContent;
            try self.expectByte('"');
            if (try self.source.readByte() != '"') return error.InvalidJsonShape;
            const original = self.captured[self.content_ordinal - 1];
            field.length = original.length;
            field.digest = original.digest;
            field.capture = self.content_ordinal;
            field.borrowed = original.borrowed;
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
}

pub fn missingCreatingSetting(configuration: anytype, inherits_parent: bool) ?[]const u8 {
    inline for (session_settings.entries) |entry| {
        const name = entry.field;
        const state = @field(configuration, name).state;
        switch (entry.create) {
            .optional => {},
            .must_value => if (state != .value) return entry.spec,
            .must_state => if (state == .omitted) return entry.spec,
        }
    }
    if (!inherits_parent) {
        var tools = configuration.tools.iterator();
        while (tools.next()) |tool| {
            if (std.mem.eql(u8, tool, "bash") and configuration.workspace.state != .value) return "workspace";
        }
    }
    return null;
}

pub fn parseAgentSpec(comptime Custody: type, arena: std.mem.Allocator, spec: std.json.ObjectMap, configuration: *Requests(Custody).Configuration) error{OutOfMemory}!?[]const u8 {
    const ContentField = Requests(Custody).ContentField;
    var captured: [spec_content_count]ContentField = @splat(.{});
    var content_count: usize = 0;
    var metadata: std.json.ObjectMap = .empty;
    var fields = spec.iterator();
    while (fields.next()) |field| {
        var value = field.value_ptr.*;
        inline for (session_settings.entries) |entry| {
            if (entry.kind == .content and std.mem.eql(u8, entry.spec, field.key_ptr.*)) {
                if (entry.json_object and value != .object and value != .null)
                    return try std.fmt.allocPrint(arena, "spec.{s} must be a JSON object or null", .{entry.spec});
                const content: ?[]const u8 = if (entry.json_object and value == .object)
                    try std.json.Stringify.valueAlloc(arena, value, .{})
                else if (!entry.json_object and value == .string)
                    value.string
                else
                    null;
                if (content) |bytes| {
                    if (!std.unicode.utf8ValidateSlice(bytes)) return try std.fmt.allocPrint(arena, "spec.{s} must be UTF-8 text", .{entry.spec});
                    captured[content_count] = .{ .state = .value, .borrowed = bytes.ptr, .length = bytes.len, .digest = contentDigest(bytes) };
                    content_count += 1;
                    value = if (entry.json_object) .{ .array = std.json.Array.init(arena) } else .{ .string = "" };
                }
            }
        }
        try metadata.put(arena, field.key_ptr.*, value);
    }
    const bytes = try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = metadata }, .{});
    var source: MetadataSource = .{ .input = bytes };
    var parser: Requests(Custody).Parser = .{ .source = &source, .captured = captured[0..content_count] };
    configuration.* = .{ .workspace = .{ .value = .{ .len = 0 } } };
    parser.parseConfiguration(configuration) catch |err| {
        if (parser.spec_field.eql("tools") or parser.spec_field.eql("loadedTools"))
            return try std.fmt.allocPrint(arena, "spec.{s} must be a list of distinct tool names", .{parser.spec_field.slice()});
        return try std.fmt.allocPrint(arena, "spec.{s}: invalid agent spec ({s})", .{ parser.spec_field.slice(), @errorName(err) });
    };
    std.debug.assert(source.atEnd());
    return null;
}

pub const Utf8State = @import("utf8_validation.zig").State;

pub const StringDecoder = struct {
    state: enum { plain, escape, hex, surrogate_slash, surrogate_u } = .plain,
    digits: u3 = 0,
    value: u16 = 0,
    high_surrogate: ?u16 = null,

    pub fn feed(self: *StringDecoder, byte: u8, sink: anytype) !bool {
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

pub fn maximumJsonStringBytes(input_bytes: usize) usize {
    return 2 + 6 * input_bytes;
}

pub const Hole = union(enum) {
    boolean,
    decimal,
    optional_id,
    tag: type,
    optional_tag: type,
    tag_set: type,
    string: usize,
    optional_string: usize,
    text: usize,
    hex: usize,
    json: type,
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

pub fn shapeBytes(comptime shape: anytype) usize {
    comptime var bytes = 0;
    inline for (shape) |part| bytes += if (comptime isLiteral(part)) part.len else (comptime Hole.maxBytes(part));
    return bytes;
}

pub fn maxShapeBytes(comptime shapes: anytype) usize {
    comptime var bytes = 0;
    inline for (shapes) |shape| bytes = @max(bytes, comptime shapeBytes(shape));
    return bytes;
}

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
                    for (std.meta.tags(T)) |tag| if (@as(std.enums.EnumSet(T), argument).contains(tag)) {
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

const store_hole = Hole{ .string = max_store_bytes };
const key_hole = Hole{ .string = max_key_bytes };
const session_hole = Hole{ .string = max_session_bytes };

pub const session_stop_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"session_stop\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, "}" };
pub const session_archive_request = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"session_archive\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole };
    pub const archived = .{ ",\"archived\":", Hole.boolean };
    pub const tail = .{"}"};
    pub const all = head ++ archived ++ tail;
};
pub const session_pin_request = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"session_pin\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole };
    pub const pinned = .{ ",\"pinned\":", Hole.boolean };
    pub const tail = .{"}"};
    pub const all = head ++ pinned ++ tail;
};
pub const model_interruption_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"model_interruption\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"target\":{\"session\":", session_hole, ",\"turn\":\"", Hole.decimal, "\",\"operation\":\"", Hole.decimal, "\"}}" };
pub const permission_decision_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"permission_decision\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, ",\"action\":\"", Hole.decimal, "\",\"decision\":\"", Hole{ .tag = PermissionDecision }, "\"}" };
pub const action_background_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"action_background\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, ",\"action\":\"", Hole.decimal, "\"}" };
pub const action_stop_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"action_stop\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, ",\"action\":\"", Hole.decimal, "\"}" };
pub const max_action_value_bytes = @import("action_value_limits.zig").max_value_bytes;
pub const action_publish_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"action_publish\",\"store\":", store_hole, ",\"handle\":", Hole{ .string = 32 }, ",\"key\":", key_hole, ",\"value\":", Hole{ .string = max_action_value_bytes }, "}" };
pub const action_publish_reply = .{ "{\"action_id\":\"", Hole.decimal, "\",\"ordinal\":\"", Hole.decimal, "\",\"admission_id\":", Hole.optional_id, ",\"replayed\":", Hole.boolean, "}" };
pub const observe_command_request = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"observe_command\",\"store\":", store_hole, ",\"key\":", key_hole };
    pub const since = .{ ",\"since\":", Hole{ .optional_string = change_ring.SessionToken.max_bytes } };
    pub const tail = .{"}"};
    pub const all = head ++ since ++ tail;
};
pub const host_info_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"host_info\",\"store\":", store_hole, "}" };
pub const skill_suggestions_session_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"skill_suggestions\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"prefix\":", Hole{ .string = 64 }, "}" };
pub const skill_suggestions_workspace_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"skill_suggestions\",\"store\":", store_hole, ",\"workspace\":", Hole{ .string = max_workspace_bytes }, ",\"prefix\":", Hole{ .string = 64 }, "}" };
pub const skill_suggestions_reply = struct {
    pub const entry = .{ "{\"name\":", Hole{ .string = 64 }, ",\"description\":", Hole{ .string = 4096 }, "}" };
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"skill_suggestions\",\"revision\":\"", Hole.decimal, "\",\"total\":\"", Hole.decimal, "\",\"entries\":[" };
    pub const tail = "]}";
    pub const max_bytes = shapeBytes(head) + jsonListBytes(24, shapeBytes(entry)) + tail.len;
};
pub const model_list_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"model_list\",\"store\":", store_hole, "}" };
pub const host_pause_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"host_pause\",\"store\":", store_hole, ",\"paused\":", Hole.boolean, "}" };
pub const host_stop_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"host_stop\",\"store\":", store_hole, "}" };
pub const read_result_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"read_result\",\"store\":", store_hole, ",\"key\":", key_hole, "}" };
pub const inspect_session_request = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"inspect_session\",\"store\":", store_hole, ",\"session\":", session_hole };
    pub const since = .{ ",\"since\":", Hole{ .optional_string = change_ring.SessionToken.max_bytes } };
    pub const profile = .{",\"profile\":\"full\""};
    pub const failed_response = .{ ",\"failed_response\":\"", Hole{ .tag = FailedResponsePart }, "\",\"operation\":\"", Hole.decimal, "\",\"attempt\":\"", Hole.decimal, "\"" };
    pub const tail = .{"}"};
    pub const max_bytes = maxShapeBytes(.{ head ++ since ++ tail, head ++ profile ++ tail, head ++ failed_response ++ tail });
};
pub const list_sessions_request = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"list_sessions\",\"store\":", store_hole, ",\"workspace\":", Hole{ .optional_string = max_workspace_bytes } };
    pub const archive = .{ ",\"archive\":\"", Hole{ .tag = SessionArchiveFilter }, "\"" };
    pub const cursor = .{ ",\"after\":\"", Hole.decimal, "\",\"ceiling\":\"", Hole.decimal, "\"" };
    pub const since = .{ ",\"since\":\"", Hole{ .text = SinceToken.max_bytes }, "\"" };
    pub const through = .{ ",\"through\":\"", Hole.decimal, "\"" };
    pub const after_reference = .{ ",\"after_reference\":", Hole{ .string = session_id_bytes } };
    pub const tail = .{"}"};
    pub const all = head ++ archive ++ cursor ++ since ++ through ++ after_reference ++ tail;
};
pub const read_action_request = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"read_action\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"action\":\"", Hole.decimal, "\"" };
    pub const offset = .{ ",\"offset\":\"", Hole.decimal, "\"" };
    pub const tail = .{"}"};
    pub const after = .{ ",\"after\":\"", Hole.decimal, "\"" };
    pub const all = head ++ offset ++ after ++ tail;
};

pub const read_action_arguments_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"read_action_arguments\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"action\":\"", Hole.decimal, "\"}" };
pub const read_action_call_id_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"read_action_call_id\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"action\":\"", Hole.decimal, "\"}" };
pub const conversation_content_request = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"conversation_content\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"position\":\"", Hole.decimal, "\",\"ordinal\":\"", Hole.decimal, "\",\"start\":\"0\"" };
    pub const stream = .{",\"stream\":true"};
    pub const tail = .{"}"};
    pub const all = head ++ stream ++ tail;
};
pub const conversation_page_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"conversation_page\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"end\":\"", Hole.decimal, "\",\"before_position\":\"", Hole.decimal, "\",\"before_ordinal\":\"", Hole.decimal, "\"}" };
pub const activity_search_request = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"activity_search\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"query\":", Hole{ .string = 256 } };
    pub const kinds = .{ ",\"kinds\":", Hole{ .tag_set = ActivityItem.Kind } };
    pub const before_position = .{ ",\"before_position\":", Hole.optional_id };
    pub const before_ordinal = .{ ",\"before_ordinal\":", Hole.optional_id };
    pub const limit = .{ ",\"limit\":\"", Hole.decimal, "\"" };
    pub const tail = .{"}"};
    pub const all = head ++ kinds ++ before_position ++ before_ordinal ++ limit ++ tail;
};
pub const max_activity_search_request_bytes = shapeBytes(activity_search_request.all);
pub const activity_page_request = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"activity_page\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"end\":", Hole.optional_id, ",\"position\":\"", Hole.decimal, "\",\"ordinal\":", Hole.optional_id, ",\"direction\":\"", Hole{ .tag = @FieldType(ActivityPage, "direction") }, "\",\"kinds\":", Hole{ .tag_set = ActivityItem.Kind }, ",\"limit\":\"", Hole.decimal, "\"" };
    pub const since = .{ ",\"since\":", Hole{ .optional_string = change_ring.SessionToken.max_bytes } };
    pub const tail = .{"}"};
    pub const all = head ++ since ++ tail;
};
/// The Message admission or Action that holds a parts value: `{"message":"ID"}` or `{"action":"ID"}`.
pub const OwnerJson = struct {
    owner: content_value.Owner,

    pub const openapi_name = "PartOwner";
    pub const message_shape = .{ "{\"message\":\"", Hole.decimal, "\"}" };
    pub const action_shape = .{ "{\"action\":\"", Hole.decimal, "\"}" };
    pub const openapi_shapes = .{ message_shape, action_shape };
    pub const max_json_bytes = maxShapeBytes(openapi_shapes);

    pub fn writeJson(self: *const OwnerJson, out: *std.Io.Writer) !void {
        switch (self.owner) {
            .message => |id| try writeShape(out, message_shape, .{id}),
            .action => |id| try writeShape(out, action_shape, .{id}),
        }
    }
};

/// One stored Content value: exact text bytes, or a parts manifest with the owner that addresses its parts.
pub const ContentValueJson = struct {
    value: content_value.Value,

    pub const openapi_name = "ContentValue";
    pub const text_shape = .{ "{\"type\":\"text\",\"bytes\":\"", Hole.decimal, "\",\"sha256\":\"", Hole{ .hex = 32 }, "\"}" };
    pub const parts_shape = .{ "{\"type\":\"parts\",\"bytes\":\"", Hole.decimal, "\",\"sha256\":\"", Hole{ .hex = 32 }, "\",\"owner\":", Hole{ .json = OwnerJson }, "}" };
    pub const openapi_shapes = .{ text_shape, parts_shape };
    pub const max_json_bytes = maxShapeBytes(openapi_shapes);

    /// Model text, which is never parts: an answer, an outcome, a call field.
    pub fn text(reference: content_value.Reference) ContentValueJson {
        return .{ .value = .{ .text = reference } };
    }

    pub fn optionalText(reference: ?content_value.Reference) ?ContentValueJson {
        return if (reference) |value| text(value) else null;
    }

    pub fn writeJson(self: *const ContentValueJson, out: *std.Io.Writer) !void {
        switch (self.value) {
            .text => |reference| try writeShape(out, text_shape, .{ reference.length, reference.digest }),
            .parts => |parts| try writeShape(out, parts_shape, .{ parts.identity.length, parts.identity.digest, OwnerJson{ .owner = parts.owner } }),
        }
    }
};

pub const public_parts_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"public_parts\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"owner\":", Hole{ .json = OwnerJson }, "}" };
pub const public_part_content_request = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"public_part_content\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"owner\":", Hole{ .json = OwnerJson }, ",\"part\":\"", Hole.decimal, "\",\"start\":\"", Hole.decimal, "\"" };
    pub const stream = .{",\"stream\":true"};
    pub const tail = .{"}"};
    pub const all = head ++ stream ++ tail;
};

/// The whole certified part list of one parts value, written into a report capture.
pub const public_parts_reply = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"public_parts\",\"session\":", session_hole, ",\"value\":", Hole{ .json = ContentValueJson }, ",\"parts\":[" };
    pub const text = .{ "{\"ordinal\":\"", Hole.decimal, "\",\"type\":\"text\",\"bytes\":\"", Hole.decimal, "\",\"sha256\":\"", Hole{ .hex = 32 }, "\"}" };
    pub const image = .{ "{\"ordinal\":\"", Hole.decimal, "\",\"type\":\"image\",\"mime\":", Hole{ .string = 10 }, ",\"width\":\"", Hole.decimal, "\",\"height\":\"", Hole.decimal, "\",\"name\":", Hole{ .optional_string = @import("input_parts.zig").max_name_bytes }, ",\"bytes\":\"", Hole.decimal, "\",\"sha256\":\"", Hole{ .hex = 32 }, "\"}" };
    pub const tail = .{"]}"};
    pub const max_part_bytes = maxShapeBytes(.{ text, image });
    /// The whole reply at its largest: every part an image with the longest name.
    pub const max_bytes = shapeBytes(head) + @import("input_parts.zig").max_parts * (max_part_bytes + 1) + shapeBytes(tail);

    /// The server's only writer of this reply: `head` once, then each `part`, then `finish`.
    pub fn Writer(comptime Capture: type) type {
        return struct {
            capture: *Capture,
            session: []const u8,
            parts: u32 = 0,

            pub fn head(self: *@This(), value: content_value.Value.Parts) !void {
                try appendCapture(self.capture, public_parts_reply.head, .{ self.session, ContentValueJson{ .value = .{ .parts = value } } });
            }

            pub fn part(self: *@This(), value: content_value.Part) !void {
                if (self.parts != 0) try self.capture.append(",");
                self.parts += 1;
                switch (value.kind) {
                    .text => try appendCapture(self.capture, text, .{ value.ordinal, value.reference.length, value.reference.digest }),
                    .image => |media| try appendCapture(self.capture, image, .{ value.ordinal, media.media.format.mime(), media.media.width, media.media.height, if (media.name) |*name| name.slice() else null, value.reference.length, value.reference.digest }),
                }
            }

            pub fn finish(self: *@This()) !void {
                try appendCapture(self.capture, tail, .{});
            }
        };
    }

    /// Renders one bounded shape on the stack, then hands the bytes to the capture.
    fn appendCapture(capture: anytype, comptime shape: anytype, args: anytype) !void {
        var buffer: [@max(shapeBytes(head), max_part_bytes, shapeBytes(tail))]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        writeShape(&out, shape, args) catch return error.ReplyShapeOverflow;
        try capture.append(out.buffered());
    }
};
pub const activity_content_request = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"activity_content\",\"store\":", store_hole, ",\"session\":", session_hole, ",\"position\":\"", Hole.decimal, "\",\"ordinal\":\"", Hole.decimal, "\"}" };
pub const configure_request = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"configure\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, ",\"configuration\":" };
    pub const reload_skills = .{",\"reload_skills\":true"};
    pub const require_model = .{",\"require_model\":true"};
    pub const preset = .{ ",\"preset\":", Hole{ .string = max_preset_name_bytes } };
    pub const tail = .{"}"};
    pub const max_metadata_bytes = shapeBytes(head ++ reload_skills ++ require_model ++ preset ++ tail);
};
pub const message_request = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"message\",\"store\":", store_hole, ",\"key\":", key_hole, ",\"session\":", session_hole, ",\"sender\":" };
    pub const sender = .{ "{\"store\":", store_hole, ",\"session\":", session_hole, "}" };
    pub const no_sender = .{"null"};
    pub const sender_handle = .{ ",\"sender_handle\":", Hole{ .optional_string = max_sender_handle_bytes } };
    pub const configuration = .{",\"configuration\":"};
    pub const text = .{",\"text\":{\"state\":\"value\",\"value\":"};
    pub const parts = .{",\"parts\":"};
    pub const text_tail = .{"}"};
    pub const require_model = .{",\"require_model\":true"};
    pub const tail = .{"}"};
};

pub const max_session_stop_request_bytes = command_spec.spec(.session_stop).Request.maxBytes(Protocol).?;
pub const max_session_archive_request_bytes = command_spec.spec(.session_archive).Request.maxBytes(Protocol).?;
pub const max_session_pin_request_bytes = command_spec.spec(.session_pin).Request.maxBytes(Protocol).?;
pub const max_model_interruption_request_bytes = command_spec.spec(.model_interruption).Request.maxBytes(Protocol).?;
pub const max_permission_decision_request_bytes = command_spec.spec(.permission_decision).Request.maxBytes(Protocol).?;
pub const max_action_background_request_bytes = command_spec.spec(.action_background).Request.maxBytes(Protocol).?;
pub const max_action_stop_request_bytes = command_spec.spec(.action_stop).Request.maxBytes(Protocol).?;
pub const max_control_request_bytes = blk: {
    var bytes: usize = 0;
    for (std.meta.tags(CommandKind)) |kind| {
        const facts = command_spec.spec(kind);
        if (facts.is_control) bytes = @max(bytes, facts.Request.maxBytes(Protocol).?);
    }
    break :blk bytes;
};
pub const max_observe_command_request_bytes = shapeBytes(observe_command_request.all);
pub const max_host_info_request_bytes = shapeBytes(host_info_request);
pub const max_host_stop_request_bytes = shapeBytes(host_stop_request);
pub const max_host_pause_request_bytes = shapeBytes(host_pause_request);
pub const max_model_list_request_bytes = shapeBytes(model_list_request);
pub const max_read_result_request_bytes = shapeBytes(read_result_request);
pub const max_inspect_session_request_bytes = inspect_session_request.max_bytes;
pub const max_list_sessions_request_bytes = shapeBytes(list_sessions_request.all);
pub const max_read_action_request_bytes = shapeBytes(read_action_request.all);
pub const max_read_action_arguments_request_bytes = shapeBytes(read_action_arguments_request);
pub const max_read_action_call_id_request_bytes = shapeBytes(read_action_call_id_request);
pub const max_conversation_content_request_bytes = shapeBytes(conversation_content_request.all);
pub const max_conversation_page_request_bytes = shapeBytes(conversation_page_request);
pub const max_activity_page_request_bytes = shapeBytes(activity_page_request.all);
pub const max_activity_content_request_bytes = shapeBytes(activity_content_request);
pub const max_client_request_bytes = @max(max_inspect_session_request_bytes, maxShapeBytes(.{
    observe_command_request.all,         host_info_request,             host_stop_request,
    host_pause_request,                  read_result_request,           list_sessions_request.all,
    read_action_request.all,             read_action_arguments_request, read_action_call_id_request,
    conversation_content_request.all,    conversation_page_request,     activity_search_request.all,
    activity_page_request.all,           activity_content_request,      skill_suggestions_session_request,
    skill_suggestions_workspace_request, model_list_request,            public_parts_request,
    public_part_content_request.all,
}));

pub fn jsonListBytes(comptime count: usize, comptime item_bytes: usize) usize {
    return count * item_bytes + count -| 1;
}

pub const content_reference_shape = .{ "{\"type\":\"text\",\"bytes\":\"", Hole.decimal, "\",\"sha256\":\"", Hole{ .hex = 32 }, "\"}" };
pub const parts_reference_shape = .{ "{\"type\":\"parts\",\"bytes\":\"", Hole.decimal, "\",\"sha256\":\"", Hole{ .hex = 32 }, "\"}" };

pub const configuration_reply = struct {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"" ++ command_spec.spec(.configure).reply_type ++ "\",\"answer\":{\"status\":";
    const execution = "},\"execution\":{\"status\":\"unavailable\",\"reason\":\"direct_reply_does_not_wait_for_model_processing\"}}";
    pub const accepted = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"revision\":\"", Hole.decimal, "\",\"created\":", Hole.boolean, execution };
    pub const accepted_skills = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"revision\":\"", Hole.decimal, "\",\"created\":false,\"skills\":\"", Hole{ .tag = SkillsReloadStatus }, "\"" ++ execution };
    pub const rejected = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"", Hole{ .tag = ConfigurationRejection }, "\",\"message\":", Hole{ .optional_string = @import("tool_record.zig").HostToolSet.max_refusal_message_bytes }, execution };
    pub const conflict = .{ head ++ "\"conflict\",\"replayed\":false,\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"idempotency_key_conflict\"" ++ execution };
    pub const max_bytes = maxShapeBytes(.{ accepted, accepted_skills, rejected, conflict });
};

pub const message_reply = struct {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"" ++ command_spec.spec(.message).reply_type ++ "\",\"answer\":{\"status\":";
    const execution = ",\"execution\":{\"status\":\"queued\"}}";
    pub const accepted = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"admission\":\"", Hole.decimal, "\"},\"input\":" } ++
        content_reference_shape ++ .{ ",\"queue\":{\"status\":\"queued\",\"admission\":\"", Hole.decimal, "\"}" ++ execution };
    pub const accepted_parts = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"admission\":\"", Hole.decimal, "\"},\"input\":" } ++
        parts_reference_shape ++ .{ ",\"queue\":{\"status\":\"queued\",\"admission\":\"", Hole.decimal, "\"}" ++ execution };
    pub const rejected = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"", Hole{ .tag = MessageRejection }, "\",\"message\":", Hole{ .optional_string = @import("tool_record.zig").HostToolSet.max_refusal_message_bytes }, "},\"input\":" } ++
        content_reference_shape ++ .{execution};
    pub const rejected_parts = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"", Hole{ .tag = MessageRejection }, "\",\"message\":", Hole{ .optional_string = @import("tool_record.zig").HostToolSet.max_refusal_message_bytes }, "},\"input\":" } ++
        parts_reference_shape ++ .{execution};
    pub const conflict = .{ head ++ "\"conflict\",\"replayed\":false,\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"idempotency_key_conflict\"}" ++ execution };
    pub const max_bytes = maxShapeBytes(.{ accepted, accepted_parts, rejected, rejected_parts, conflict });
};

pub const session_stop_reply = struct {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"" ++ command_spec.spec(.session_stop).reply_type ++ "\",\"answer\":{\"status\":";
    pub const accepted = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"selection\":{\"turn\":", Hole.optional_id, ",\"admission_cutoff\":\"", Hole.decimal, "\"}},\"completion\":{\"status\":\"", Hole{ .tag = SessionStopCompletion }, "\"}}" };
    pub const rejected = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"", Hole{ .tag = SessionStopRejection }, "\"},\"completion\":{\"status\":\"unavailable\"}}" };
    pub const conflict = .{ head ++ "\"conflict\",\"replayed\":false,\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"idempotency_key_conflict\"},\"completion\":{\"status\":\"unavailable\"}}" };
    pub const max_bytes = maxShapeBytes(.{ accepted, rejected, conflict });
};

pub const session_archive_reply = struct {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"" ++ command_spec.spec(.session_archive).reply_type ++ "\",\"answer\":{\"status\":";
    pub const accepted = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"archived\":", Hole.boolean, "},\"completion\":{\"status\":\"", Hole{ .tag = SessionStopCompletion }, "\"}}" };
    pub const rejected = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"", Hole{ .tag = SessionArchiveRejection }, "\"},\"completion\":{\"status\":\"unavailable\"}}" };
    pub const conflict = .{ head ++ "\"conflict\",\"replayed\":false,\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"idempotency_key_conflict\"},\"completion\":{\"status\":\"unavailable\"}}" };
    pub const max_bytes = maxShapeBytes(.{ accepted, rejected, conflict });
};

pub const session_pin_reply = struct {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"" ++ command_spec.spec(.session_pin).reply_type ++ "\",\"answer\":{\"status\":";
    pub const accepted = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"pinned\":", Hole.boolean, "}}" };
    pub const rejected = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean, ",\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"", Hole{ .tag = SessionPinRejection }, "\"}}" };
    pub const conflict = .{ head ++ "\"conflict\",\"replayed\":false,\"session\":", Hole{ .string = max_session_bytes }, ",\"code\":\"idempotency_key_conflict\"}}" };
    pub const max_bytes = maxShapeBytes(.{ accepted, rejected, conflict });
};

pub const model_interruption_target_shape = .{ "{\"session\":", Hole{ .string = max_session_bytes }, ",\"turn\":\"", Hole.decimal, "\",\"operation\":\"", Hole.decimal, "\"}" };

pub const model_interruption_reply = struct {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"" ++ command_spec.spec(.model_interruption).reply_type ++ "\",\"answer\":{\"status\":";
    pub const accepted = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean, ",\"target\":" } ++ model_interruption_target_shape ++ .{"}}"};
    pub const rejected = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean, ",\"target\":" } ++ model_interruption_target_shape ++ .{ ",\"code\":\"", Hole{ .tag = ModelInterruptionRejection }, "\"}}" };
    pub const conflict = .{head ++ "\"conflict\",\"replayed\":false,\"target\":"} ++ model_interruption_target_shape ++ .{",\"code\":\"idempotency_key_conflict\"}}"};
    pub const max_bytes = maxShapeBytes(.{ accepted, rejected, conflict });
};

pub const permission_decision_reply = struct {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"" ++ command_spec.spec(.permission_decision).reply_type ++ "\",\"answer\":{\"status\":";
    const target = .{ ",\"session\":", Hole{ .string = max_session_bytes }, ",\"action\":\"", Hole.decimal, "\",\"decision\":\"", Hole{ .tag = PermissionDecision }, "\"" };
    pub const accepted = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean } ++ target ++ .{"}}"};
    pub const rejected = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean } ++ target ++ .{ ",\"code\":\"", Hole{ .tag = PermissionDecisionRejection }, "\"}}" };
    pub const conflict = .{head ++ "\"conflict\",\"replayed\":false"} ++ target ++ .{",\"code\":\"idempotency_key_conflict\"}}"};
    pub const max_bytes = maxShapeBytes(.{ accepted, rejected, conflict });
};

pub const action_background_reply = struct {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"" ++ command_spec.spec(.action_background).reply_type ++ "\",\"answer\":{\"status\":";
    const target = .{ ",\"session\":", session_hole, ",\"action\":\"", Hole.decimal, "\"" };
    pub const selection = .{ ",\"action_selection\":{\"kind\":\"", Hole{ .tag = @FieldType(@import("action_control.zig").Selection, "kind") }, "\",\"position\":\"", Hole.decimal, "\"}" };
    pub const accepted = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean } ++ target ++ selection ++ .{"}}"};
    pub const rejected = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean } ++ target ++ .{ ",\"code\":\"", Hole{ .tag = @import("action_control.zig").Rejection }, "\"}}" };
    pub const conflict = .{head ++ "\"conflict\",\"replayed\":false"} ++ target ++ .{",\"code\":\"idempotency_key_conflict\"}}"};
    pub const max_bytes = maxShapeBytes(.{ accepted, rejected, conflict });
};

pub const action_stop_reply = struct {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"" ++ command_spec.spec(.action_stop).reply_type ++ "\",\"answer\":{\"status\":";
    const target = .{ ",\"session\":", session_hole, ",\"action\":\"", Hole.decimal, "\"" };
    pub const selection = .{ ",\"resolution_position\":", Hole.optional_id };
    pub const accepted = .{ head ++ "\"accepted\",\"replayed\":", Hole.boolean } ++ target ++ selection ++ .{"}}"};
    pub const rejected = .{ head ++ "\"rejected\",\"replayed\":", Hole.boolean } ++ target ++ .{ ",\"code\":\"", Hole{ .tag = @import("action_control.zig").Rejection }, "\"}}" };
    pub const conflict = .{head ++ "\"conflict\",\"replayed\":false"} ++ target ++ .{",\"code\":\"idempotency_key_conflict\"}}"};
    pub const max_bytes = maxShapeBytes(.{ accepted, rejected, conflict });
};

pub const action_read_reply = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"action_read\",\"session\":", session_hole, ",\"action\":\"", Hole.decimal, "\"," };
    pub const pending = .{ "\"state\":\"", Hole{ .tag = @import("action_read.zig").PendingState }, "\",\"final\":null" };
    pub const final = .{ "\"state\":\"resolved\",\"final\":{\"position\":\"", Hole.decimal, "\",\"code\":", Hole{ .string = max_code_bytes }, ",\"content\":", Hole{ .json = ContentValueJson }, ",\"window\":{\"offset\":\"", Hole.decimal, "\",\"next\":\"", Hole.decimal, "\",\"more\":", Hole.boolean, ",\"text\":", Hole{ .string = content_window_bytes }, "}}" };
    pub const parts = .{ "\"state\":\"resolved\",\"final\":{\"position\":\"", Hole.decimal, "\",\"code\":", Hole{ .string = max_code_bytes }, ",\"content\":", Hole{ .json = ContentValueJson }, ",\"window\":null}" };
    pub const item = .{ "{\"ordinal\":\"", Hole.decimal, "\",\"key\":", Hole{ .string = 128 }, ",\"text\":", Hole{ .string = @import("action_read.zig").page_bytes }, "}" };
    pub const values_head = ",\"values\":{\"items\":";
    pub const values_tail = .{ ",\"next\":\"", Hole.decimal, "\",\"more\":", Hole.boolean, "}}" };
    // The total text budget is shared by all items, rather than repeated per item.
    pub const max_bytes = maxShapeBytes(.{ head ++ pending, head ++ final, head ++ parts }) + values_head.len + 2 + jsonListBytes(@import("action_read.zig").page_items, shapeBytes(item) - 6 * @import("action_read.zig").page_bytes) + 6 * @import("action_read.zig").page_bytes + shapeBytes(values_tail);
};

pub const MessageUnknownOutcome = message_observation.MessageUnknownOutcome;

pub const MessageRecoveryJson = struct {
    calls: []const MessageUnknownOutcome,
    more: bool,

    pub const head = .{"{\"unknown_outcomes\":["};
    pub const item = .{ "{\"action\":\"", Hole.decimal, "\",\"operation\":\"", Hole.decimal, "\",\"call\":\"", Hole.decimal, "\",\"description\":", Hole{ .optional_string = max_tool_description_bytes }, ",\"at\":\"", Hole.decimal, "\"}" };
    pub const tail = .{ "],\"more\":", Hole.boolean, "}" };
    pub const max_json_bytes = shapeBytes(head) + message_recovery_limit * shapeBytes(item) + message_recovery_limit - 1 + shapeBytes(tail);

    pub fn writeJson(self: *const MessageRecoveryJson, out: *std.Io.Writer) !void {
        std.debug.assert(self.calls.len <= message_recovery_limit);
        try writeShape(out, head, .{});
        for (self.calls, 0..) |call, index| {
            if (index != 0) try out.writeAll(",");
            try writeShape(out, item, .{ call.action_id, call.operation_id, call.call, if (call.description) |text| text.slice() else null, call.at });
        }
        try writeShape(out, tail, .{self.more});
    }
};

pub const command_observation_reply = struct {
    const prefix = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"command_observation\",\"key\":";
    pub const absent = .{ prefix, Hole{ .string = max_key_bytes }, ",\"delta\":\"full\",\"since\":null,\"observation\":{\"status\":\"absent\"}}" };
    pub const not_modified = .{ prefix, Hole{ .string = max_key_bytes }, ",\"delta\":\"not_modified\",\"since\":", Hole{ .string = change_ring.SessionToken.max_bytes }, "}" };
    pub fn head(comptime kind: CommandKind) struct { []const u8, Hole, []const u8, Hole, []const u8, Hole, []const u8, Hole } {
        return .{ prefix, .{ .string = max_key_bytes }, ",\"delta\":\"full\",\"since\":", .{ .optional_string = change_ring.SessionToken.max_bytes }, ",\"observation\":{\"status\":\"", .{ .tag = CommandObservationStatus }, "\",\"kind\":\"" ++ @tagName(kind) ++ "\",\"target\":", .{ .string = max_session_bytes } };
    }
    pub const code = .{ ",\"code\":", Hole{ .string = max_code_bytes } };
    pub const revision = .{ ",\"revision\":\"", Hole.decimal, "\",\"created\":", Hole.boolean };
    pub const input = .{",\"input\":"} ++ content_reference_shape;
    pub const input_parts = .{",\"input\":"} ++ parts_reference_shape;
    pub const state = .{ ",\"state\":\"", Hole{ .tag = MessageRequestState }, "\"" };
    pub const queue = .{ ",\"queue\":{\"admission\":\"", Hole.decimal, "\",\"admitted_at\":\"", Hole.decimal, "\"}" };
    pub const binding = .{ ",\"binding\":{\"turn\":\"", Hole.decimal, "\",\"operation\":\"", Hole.decimal, "\",\"attempt\":\"", Hole.decimal, "\"}" };
    pub const completed = .{",\"result\":{\"status\":\"completed\",\"text\":"} ++ content_reference_shape ++ .{"}"};
    pub const cancelled = .{ ",\"result\":{\"status\":\"cancelled\",\"code\":", Hole{ .string = max_code_bytes }, "}" };
    pub const failed = .{ ",\"result\":{\"status\":\"failed\",\"code\":", Hole{ .string = max_code_bytes }, "}" };
    pub const work_base = .{ ",\"work\":{\"state\":", Hole{ .json = WorkStateJson }, ",\"first_action\":", Hole.optional_id };
    // The observation reservation adds the exact same bounded derived fields as every work reply.
    pub const work = work_base ++ SessionWork.extra_fields ++ .{"}"};
    pub const recovery = .{ ",\"recovery\":", Hole{ .json = MessageRecoveryJson } };

    const queued_state = .{",\"state\":\"queued\""};
    const processing_state = .{",\"state\":\"processing\""};
    const permission_state = .{",\"state\":\"waiting_for_permission\""};
    const rejected_state = .{",\"state\":\"rejected\""};
    const completed_state = .{",\"state\":\"completed\""};
    const failed_state = .{",\"state\":\"failed\""};
    const cancelled_state = .{",\"state\":\"cancelled\""};
    pub const permission_work = .{ ",\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"", Hole.decimal, "\"},\"first_action\":", Hole.optional_id } ++ SessionWork.extra_fields ++ .{"}"};
    pub const message_variants = .{
        rejected_state,
        rejected_state ++ input,
        rejected_state ++ input_parts,
        queued_state ++ input ++ queue ++ work,
        processing_state ++ input ++ queue ++ binding ++ work,
        processing_state ++ input ++ queue ++ binding ++ work ++ recovery,
        permission_state ++ input ++ queue ++ permission_work,
        permission_state ++ input ++ queue ++ binding ++ permission_work,
        permission_state ++ input ++ queue ++ binding ++ permission_work ++ recovery,
        cancelled_state ++ input ++ queue ++ cancelled,
        completed_state ++ input ++ queue ++ binding ++ completed,
        completed_state ++ input ++ queue ++ binding ++ completed ++ recovery,
        cancelled_state ++ input ++ queue ++ binding ++ cancelled,
        cancelled_state ++ input ++ queue ++ binding ++ cancelled ++ recovery,
        failed_state ++ input ++ queue ++ binding ++ failed,
        failed_state ++ input ++ queue ++ binding ++ failed ++ recovery,
    } ++ .{
        queued_state ++ input_parts ++ queue ++ work,
        processing_state ++ input_parts ++ queue ++ binding ++ work,
        processing_state ++ input_parts ++ queue ++ binding ++ work ++ recovery,
        permission_state ++ input_parts ++ queue ++ permission_work,
        permission_state ++ input_parts ++ queue ++ binding ++ permission_work,
        permission_state ++ input_parts ++ queue ++ binding ++ permission_work ++ recovery,
        cancelled_state ++ input_parts ++ queue ++ cancelled,
        completed_state ++ input_parts ++ queue ++ binding ++ completed,
        completed_state ++ input_parts ++ queue ++ binding ++ completed ++ recovery,
        cancelled_state ++ input_parts ++ queue ++ binding ++ cancelled,
        cancelled_state ++ input_parts ++ queue ++ binding ++ cancelled ++ recovery,
        failed_state ++ input_parts ++ queue ++ binding ++ failed,
        failed_state ++ input_parts ++ queue ++ binding ++ failed ++ recovery,
    };
    pub const session_stop = .{ ",\"selection\":{\"turn\":", Hole.optional_id, ",\"admission_cutoff\":\"", Hole.decimal, "\"},\"completion\":{\"status\":\"", Hole{ .tag = SessionStopCompletion }, "\"}" };
    pub const session_pin = .{ ",\"pinned\":", Hole.boolean };
    pub const session_archive = .{ ",\"archived\":", Hole.boolean, ",\"completion\":{\"status\":\"", Hole{ .tag = SessionStopCompletion }, "\"}" };
    pub const model_interruption = .{",\"interruption_target\":"} ++ model_interruption_target_shape;
    pub const permission_decision = .{ ",\"permission_target\":{\"action\":\"", Hole.decimal, "\",\"decision\":\"", Hole{ .tag = PermissionDecision }, "\"}" };
    pub const action_target = .{ ",\"action_target\":{\"action\":\"", Hole.decimal, "\"}" };
    pub const action_selection = action_background_reply.selection;
    pub const action_stop = action_stop_reply.selection;
    pub const tail = .{"}}"};

    pub fn maxBytes(comptime kind: CommandKind) usize {
        @setEvalBranchQuota(30_000);
        const body = maxShapeBytes(command_spec.spec(kind).Observation.shapes(Protocol).values);
        return shapeBytes(head(kind)) + shapeBytes(code) + body + shapeBytes(tail);
    }

    pub const max_bytes = blk: {
        var bytes: usize = @max(shapeBytes(absent), shapeBytes(not_modified));
        for (std.meta.tags(CommandKind)) |kind| bytes = @max(bytes, maxBytes(kind));
        break :blk bytes;
    };
};

pub const ErrorType = enum { invocation_error, observation_error, busy, unsupported, host_unavailable, result_unavailable, action_unavailable, conversation_unavailable, activity_unavailable, failed_response_unavailable, parts_unavailable };
pub const error_reply = .{ "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"", Hole{ .tag = ErrorType }, "\",\"code\":", Hole{ .string = max_code_bytes }, "}" };
pub const max_control_error_response_bytes = shapeBytes(error_reply);

pub const max_mutation_response_bytes = blk: {
    var bytes: usize = max_control_error_response_bytes;
    for (std.meta.tags(CommandKind)) |kind| bytes = @max(bytes, command_spec.spec(kind).Reply(Protocol).max_bytes);
    break :blk bytes;
};

pub const host_info_reply = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"host_info\",\"store\":", Hole{ .string = max_store_bytes }, ",\"instance\":\"", Hole{ .hex = @typeInfo(InstanceId).array.len }, "\",\"active_capacity\":\"", Hole.decimal, "\",\"intake_capacity\":\"", Hole.decimal, "\",\"descriptor_limit\":\"", Hole{ .text = Hole.maxBytes(.decimal) }, "\",\"started_at\":\"", Hole.decimal, "\",\"custody_occupied\":\"", Hole.decimal, "\",\"paused\":", Hole.boolean };
    pub const doublewrite = .{ ",\"innodb_doublewrite\":", Hole{ .string = 32 } };
    pub const tail = .{ ",\"capabilities\":{\"bash\":true,\"providers\":{\"codex\":\"", Hole{ .tag = Route }, "\",\"openai\":\"", Hole{ .tag = Route }, "\",\"chatgpt\":\"", Hole{ .tag = Route }, "\"}}}" };
    pub const max_bytes = shapeBytes(head) + shapeBytes(doublewrite) + shapeBytes(tail);
};
comptime {
    const names = @typeInfo(Provider).@"enum".field_names;
    if (names.len != 3 or !std.mem.eql(u8, names[0], "codex") or !std.mem.eql(u8, names[1], "openai") or !std.mem.eql(u8, names[2], "chatgpt"))
        @compileError("host_info_reply names one Route hole per provider, in Provider order");
}
pub const max_host_info_response_bytes: usize = host_info_reply.max_bytes;

pub const model_list_reply = struct {
    pub const head = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"model_list\",\"providers\":";
    pub const tail = "}";
    pub const max_bytes = maxBytes(@import("model_catalog.zig").shipped);

    pub fn maxBytes(facts: []const @import("model_catalog.zig").Entry) usize {
        return head.len + model_list.providersBytes(facts) + tail.len;
    }
};
pub const host_stop_ack = "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"host_stop_reply\",\"status\":\"acknowledged\"}";
pub const host_pause_reply = .{ "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"host_pause_reply\",\"paused\":", Hole.boolean, "}" };
pub const max_response_bytes = @max(@max(max_mutation_response_bytes, max_host_info_response_bytes), @max(host_stop_ack.len, shapeBytes(host_pause_reply)));

pub const conversation_page_reply = struct {
    pub const head = .{ "{\"version\":\"" ++ wire_version ++ "\",\"type\":\"conversation_page\",\"direction\":\"newest_first\",\"end\":\"", Hole.decimal, "\",\"items\":[" };
    pub fn item(comptime kind: ConversationItemKind) struct { []const u8, Hole, []const u8, Hole, []const u8, Hole } {
        comptime std.debug.assert(kind != .hosted_call);
        return .{ "{\"position\":\"", .decimal, "\",\"ordinal\":\"", .decimal, "\",\"kind\":\"" ++ @tagName(kind) ++ "\",\"content\":", .{ .json = ContentValueJson } };
    }
    pub const hosted_call = .{ "{\"position\":\"", Hole.decimal, "\",\"ordinal\":\"", Hole.decimal, "\",\"kind\":\"hosted_call\"" };
    pub const admission = .{ ",\"admitted_at\":\"", Hole.decimal, "\",\"sender\":", Hole{ .optional_json = NamedPeerJson }, ",\"source_action\":", Hole.optional_id };
    pub const presentation = .{ ",\"presentation\":", Hole{ .json = ToolPresentationJson } };
    pub const item_end = .{"}"};

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
    pub const more = .{ "],\"more\":true,\"before_position\":\"", Hole.decimal, "\",\"before_ordinal\":\"", Hole.decimal, "\"}" };
};

pub const max_conversation_page_response_bytes = blk: {
    const page = conversation_page_reply;
    var item = 0;
    for (std.meta.tags(ConversationItemKind)) |kind| item = @max(item, page.itemBytes(kind));
    break :blk shapeBytes(page.head) + jsonListBytes(public_conversation_page_items, item) + maxShapeBytes(.{ page.last, page.more });
};

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
pub const CommandObservationBuffer = FixedJsonBuffer(command_observation_reply.max_bytes);

const TestCustody = struct {
    pub const File = struct {};
    pub const Budget = struct {};
    pub const Io = void;
    pub fn release(_: ?File, _: ?Budget, _: u64, _: Io) void {}
};
const Tested = Requests(TestCustody);

fn parseForTest(parser: *Tested.Parser) !Tested.Request {
    var request: Tested.Request = undefined;
    try parser.parse(&request);
    return request;
}

test "semantic digest distinguishes omission, null, and value" {
    var omitted = Tested.ConfigureCommand{};
    try omitted.session.set("s");
    var null_schema = omitted;
    null_schema.configuration.output_schema.state = .explicit_null;
    var value_schema = omitted;
    value_schema.configuration.output_schema.state = .value;
    value_schema.configuration.output_schema.digest = @splat(1);
    try std.testing.expect(!std.mem.eql(u8, &omitted.semanticDigest(), &null_schema.semanticDigest()));
    try std.testing.expect(!std.mem.eql(u8, &null_schema.semanticDigest(), &value_schema.semanticDigest()));
    var efforts: [4]Tested.ConfigureCommand = @splat(omitted);
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
    var requests = [_]Tested.Request{
        .{ .configure = .{} },
        .{ .message = .{} },
        .{ .session_stop = .{} },
        .{ .session_archive = .{} },
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

test "fixed JSON buffers preserve control bytes and enforce capacity" {
    var response: ResponseBuffer = .{};
    try response.appendJsonString("\x00\x1f\"\\\n\r\t\x08\x0c\xc3\xa9");
    try std.testing.expectEqualStrings("\"\\u0000\\u001f\\\"\\\\\\n\\r\\t\\b\\f\xc3\xa9\"", response.slice());
    response.len = response.bytes.len - 2;
    try response.appendJsonString("");
    try std.testing.expectEqual(response.bytes.len, response.len);
    try std.testing.expectError(error.BufferTooLarge, response.appendJsonString("x"));
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
        var parser = Tested.Parser{ .source = &source };
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
        var parser = Tested.Parser{ .source = &source };
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
        var parser = Tested.Parser{ .source = &source };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parseForTest(&parser));
        } else {
            const request = try parseForTest(&parser);
            try std.testing.expect(request == .activity_page);
        }
    }
}

test "configuration token heuristics and effort parse sparsely and bind idempotency" {
    const longest_label: [max_label_bytes]u8 = @splat('x');
    const overlong_label: [max_label_bytes + 1]u8 = @splat('x');
    const cases = [_]struct { fields: []const u8, field: ?[]const u8 = null, value: ?[]const u8 = null, failure: ?anyerror = null }{
        .{ .fields = "" },
        .{ .fields = "\"compactAt\":100000", .field = "compaction_trigger", .value = "100000" },
        .{ .fields = "\"outputReservation\":16384", .field = "output_reservation", .value = "16384" },
        .{ .fields = "\"compactAt\":0", .field = "compaction_trigger", .value = "0" },
        .{ .fields = "\"outputReservation\":9223372036854775808", .field = "output_reservation", .value = "9223372036854775808" },
        .{ .fields = "\"compactAt\":null", .field = "compaction_trigger" },
        .{ .fields = "\"outputReservation\":null", .field = "output_reservation" },
        .{ .fields = "\"compactAt\":\"100000\"", .failure = error.InvalidJsonShape },
        .{ .fields = "\"compactAt\":123456789012345678901", .failure = error.ValueTooLong },
        .{ .fields = "\"compactAt\":01", .failure = error.InvalidJsonShape },
        .{ .fields = "\"compactAt\":1.5", .failure = error.InvalidJsonShape },
        .{ .fields = "\"compactAt\":1e3", .failure = error.InvalidJsonShape },
        .{ .fields = "\"context_capacity\":null", .failure = error.UnexpectedField },
        .{ .fields = "\"outputReservation\":null,\"outputReservation\":null", .failure = error.UnexpectedField },
        .{ .fields = "\"effort\":\"high\"", .field = "reasoning_effort", .value = "high" },
        .{ .fields = "\"effort\":\"none\"", .field = "reasoning_effort", .value = "none" },
        .{ .fields = "\"effort\":null", .field = "reasoning_effort" },
        .{ .fields = "\"effort\":\"ultra\"", .field = "reasoning_effort", .value = "ultra" },
        .{ .fields = "\"effort\":null,\"effort\":null", .failure = error.UnexpectedField },
        .{ .fields = "\"label\":\"Review PR 412\"", .field = "label", .value = "Review PR 412" },
        .{ .fields = "\"label\":null", .field = "label" },
        .{ .fields = "\"label\":\"" ++ longest_label ++ "\"", .field = "label", .value = &longest_label },
        .{ .fields = "\"label\":\"" ++ overlong_label ++ "\"", .failure = error.ValueTooLong },
        .{ .fields = "\"label\":null,\"label\":null", .failure = error.UnexpectedField },
    };
    var omitted_digest: [32]u8 = undefined;
    for (cases, 0..) |case, index| {
        var buffer: [2048]u8 = undefined;
        const json = try std.fmt.bufPrint(&buffer, "{{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"configure\",\"store\":\"store\",\"key\":\"key\",\"session\":\"session\",\"configuration\":{{{s}}}}}", .{case.fields});
        var source: MetadataSource = .{ .input = json };
        var parser = Tested.Parser{ .source = &source };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parseForTest(&parser));
            continue;
        }
        const command = (try parseForTest(&parser)).configure;
        inline for (.{ "compaction_trigger", "output_reservation", "reasoning_effort", "label" }) |name| {
            if (case.field != null and std.mem.eql(u8, case.field.?, name)) {
                const field = @field(command.configuration, name);
                if (case.value) |value| try std.testing.expectEqualStrings(value, field.value.slice()) else try std.testing.expectEqual(FieldState.explicit_null, field.state);
            }
        }
        const digest = command.semanticDigest();
        if (index == 0) omitted_digest = digest else try std.testing.expect(!std.mem.eql(u8, &omitted_digest, &digest));
    }
}

test "configuration provider value preserves exact spelling and omission" {
    const cases = [_]struct { field: []const u8, expected: ?[]const u8, suffix: []const u8 = "", failure: ?anyerror = null }{
        .{ .field = "", .expected = null },
        .{ .field = "\"codex\"", .expected = "codex" },
        .{ .field = "\"c\\u006fdex\"", .expected = "codex" },
        .{ .field = "\"codex\"", .expected = "codex", .suffix = ",\"require_model\":true" },
        .{ .field = "\"Codex\"", .expected = "Codex" },
        .{ .field = "\"other\"", .expected = "other" },
        .{ .field = "\"anthropic\"", .expected = "anthropic" },
        .{ .field = "\"12345678901234567\"", .expected = null, .failure = error.ValueTooLong },
        .{ .field = "null", .expected = null, .failure = error.InvalidFieldState },
    };
    var omitted_digest: [32]u8 = undefined;
    var codex_digest: [32]u8 = undefined;
    for (cases, 0..) |case, index| {
        var buffer: [1024]u8 = undefined;
        const json = try std.fmt.bufPrint(
            &buffer,
            "{{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"configure\",\"store\":\"store\",\"key\":\"key\",\"session\":\"session\",\"configuration\":{{{s}{s}}}{s}}}",
            .{ if (case.field.len == 0) "" else "\"provider\":", case.field, case.suffix },
        );
        var source: MetadataSource = .{ .input = json };
        var parser = Tested.Parser{ .source = &source };
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
        .{ .value = "[\"edit\"]", .names = "edit", .count = 1 },
        .{ .value = "[\"Bash\",\"bash\"]", .names = "Bash bash", .count = 2 },
        .{ .value = "[\"bash\",\"edit\"]", .names = "bash edit", .count = 2 },
        .{ .value = "[\"\"]", .failure = error.InvalidToolName },
        .{ .value = "[\"web search\"]", .failure = error.InvalidToolName },
        .{ .value = "[\"bash.v2\"]", .failure = error.InvalidToolName },
        .{ .value = "[\"" ++ @as([65]u8, @splat('x')) ++ "\"]", .failure = error.InvalidToolName },
        .{ .value = "[\"bash\",\"bash\"]", .failure = error.InvalidJsonShape },
        .{ .value = "[\"web_search\",\"bash\"]", .names = "bash web_search", .count = 2 },
        .{ .value = "[\"bash\",\"web_search\",\"bash\"]", .failure = error.InvalidJsonShape },
    };
    inline for (.{ "tools", "loaded_tools" }) |field_name| {
        for (cases) |case| {
            var buffer: [1024]u8 = undefined;
            const spec_name = if (comptime std.mem.eql(u8, field_name, "loaded_tools")) "loadedTools" else "tools";
            const json = try std.fmt.bufPrint(&buffer, "{{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"configure\",\"store\":\"store\",\"key\":\"key\",\"session\":\"session\",\"configuration\":{{\"" ++ spec_name ++ "\":{s}}}}}", .{case.value});
            var source: MetadataSource = .{ .input = json };
            var parser = Tested.Parser{ .source = &source };
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
        var parser = Tested.Parser{ .source = &source };
        if (case.expected) |expected| {
            const request = try parseForTest(&parser);
            try std.testing.expectEqual(expected, request.inspect_session.profile);
            try std.testing.expectEqual(case.failed_response, request.inspect_session.failed_response);
        } else {
            try std.testing.expectError(error.UnknownReportProfile, parseForTest(&parser));
        }
    }
}

test "Session listing wire distinguishes all, exact workspace, continuation, since and invalid cursor" {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"list_sessions\",\"store\":\"s\",\"workspace\":null,\"after\":\"0\",\"ceiling\":\"0\"";
    const since = ",\"since\":\"abababababababababababababababab.42\"";
    const Case = struct { json: []const u8, workspace: ?[]const u8 = null, archive: SessionArchiveFilter = .active, after: u64 = 0, ceiling: u64 = 0, since: ?u64 = null, through: ?u64 = null, failure: ?anyerror = null };
    const cases = [_]Case{
        .{ .json = head ++ "}" },
        .{ .json = head ++ ",\"archive\":\"active\"}" },
        .{ .json = head ++ ",\"archive\":\"archived\"}", .archive = .archived },
        .{ .json = head ++ ",\"archive\":\"all\"}", .archive = .all },
        .{ .json = head ++ ",\"archive\":\"archiving\"}", .failure = error.InvalidArchiveFilter },
        .{ .json = head ++ ",\"archive\":null}", .failure = error.InvalidJsonShape },

        .{ .json = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"list_sessions\",\"store\":\"s\",\"workspace\":\"/a\\u0001b\",\"after\":\"8\",\"ceiling\":\"12\"}", .workspace = "/a\x01b", .after = 8, .ceiling = 12 },
        .{ .json = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"list_sessions\",\"store\":\"s\",\"workspace\":null,\"after\":\"0\",\"ceiling\":\"12\"}", .failure = error.InvalidCursor },
        .{ .json = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"list_sessions\",\"store\":\"s\",\"workspace\":null,\"after\":\"13\",\"ceiling\":\"12\"}", .failure = error.InvalidCursor },
        .{ .json = head ++ since ++ "}", .since = 42 },
        .{ .json = head ++ since ++ ",\"through\":\"48\",\"after_reference\":\"k7m2qx\"}", .since = 42, .through = 48 },
        .{ .json = head ++ since ++ ",\"through\":\"42\",\"after_reference\":\"k7m2qx\"}", .since = 42, .through = 42 },
        .{ .json = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"list_sessions\",\"store\":\"s\",\"workspace\":null,\"after\":\"8\",\"ceiling\":\"12\"" ++ since ++ "}", .failure = error.InvalidCursor },
        .{ .json = head ++ since ++ ",\"through\":\"41\",\"after_reference\":\"k7m2qx\"}", .failure = error.InvalidCursor },
        .{ .json = head ++ since ++ ",\"through\":\"48\",\"after_reference\":\"k7m2qX\"}", .failure = error.InvalidCursor },
        .{ .json = head ++ since ++ ",\"through\":\"48\",\"after_reference\":\"k7m2q\"}", .failure = error.InvalidCursor },
        .{ .json = head ++ ",\"since\":\"ABABABABABABABABABABABABABABABAB.42\"}", .failure = error.InvalidCursor },
        .{ .json = head ++ ",\"since\":\"abababababababababababababababab.042\"}", .failure = error.InvalidCursor },
    };
    for (cases) |case| {
        var source: MetadataSource = .{ .input = case.json };
        var parser = Tested.Parser{ .source = &source };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parseForTest(&parser));
            continue;
        }
        const request = (try parseForTest(&parser)).list_sessions;
        try std.testing.expectEqual(case.archive, request.archive);
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
        var parser = Tested.Parser{ .source = &source };
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
        var parser = Tested.Parser{ .source = &source, .captured = &.{.{}} };
        if (case.valid) {
            const request = try parseForTest(&parser);
            try std.testing.expectEqualStrings(case.store, request.message.sender.?.store.slice());
            try std.testing.expectEqualStrings("k7m2qx", request.message.sender.?.session.slice());
        } else try std.testing.expectError(error.InvalidRuiAddress, parseForTest(&parser));
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
        var parser = Tested.Parser{ .source = &source };
        try std.testing.expectError(case.failure, parseForTest(&parser));
    }
}

test "omitted loaded tools preserve pre-T4a Configure and creating Message digests" {
    var configure: Tested.ConfigureCommand = .{};
    try std.testing.expectEqualStrings("e983bd4a7dce4a1ec777d065815928f654ac824dc57a57b397b8f78e7a4ede3a", &std.fmt.bytesToHex(configure.semanticDigest(), .lower));
    var message: Tested.MessageCommand = .{ .configuration = .{} };
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
        .last_line = .{ .position = 2, .text = "Done" },
        .work = &.{},
        .peers = &.{},
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try fields.writeJson(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"tools\":[\"bash\",\"offered_tool\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"last_line\":{\"position\":\"2\",\"text\":\"Done\"}") != null);
    try std.testing.expect(out.written().len <= SessionRow.max_json_bytes);
}

test "protocol creation requires five explicit settings independent of field order" {
    const fields = [_][]const u8{
        "\"model\":\"model\"",
        "\"compactAt\":1000",
        "\"tools\":[]",
        "\"permissionMode\":\"default\"",
        "\"effort\":null",
    };
    inline for (.{ "configure", "message" }) |kind| {
        for (0..fields.len + 1) |skip| {
            var buffer: [2048]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try writer.writeAll("{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"" ++ kind ++ "\",\"store\":\"s\",\"key\":\"k\",\"configuration\":{");
            var comma = false;
            for (fields, 0..) |field, index| {
                if (index == skip) continue;
                if (comma) try writer.writeByte(',');
                try writer.writeAll(field);
                comma = true;
            }
            try writer.writeAll("},\"session\":\"\"");
            if (comptime std.mem.eql(u8, kind, "message"))
                try writer.writeAll(",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"omitted\"}");
            try writer.writeByte('}');
            const json = writer.buffered();
            var source: MetadataSource = .{ .input = json };
            var parser = Tested.Parser{ .source = &source };
            if (skip < fields.len) {
                try std.testing.expectError(error.MissingField, parseForTest(&parser));
            } else if (comptime std.mem.eql(u8, kind, "message")) {
                try std.testing.expectError(error.InvalidMessage, parseForTest(&parser));
            } else {
                _ = try parseForTest(&parser);
            }
        }
    }
}

test "activity search wire validates query and paired backward cursor" {
    const cases = [_]struct { fields: []const u8, failure: ?anyerror = null }{
        .{ .fields = "\"query\":\"start_agent\"" },
        .{ .fields = "\"query\":\"雪\",\"before_position\":\"1\",\"before_ordinal\":\"0\",\"kinds\":[\"call\"],\"limit\":\"1\"" },
        .{ .fields = "\"query\":\"\"", .failure = error.InvalidCursor },
        .{ .fields = "\"query\":\"x\",\"before_position\":\"0\"", .failure = error.InvalidCursor },
        .{ .fields = "\"query\":\"x\",\"before_ordinal\":\"0\"", .failure = error.InvalidCursor },
        .{ .fields = "\"query\":\"x\",\"kinds\":[]", .failure = error.InvalidCursor },
        .{ .fields = "\"query\":\"x\",\"limit\":\"17\"", .failure = error.InvalidCursor },
        .{ .fields = "\"query\":\"x\",\"query\":\"y\"", .failure = error.UnexpectedField },
    };
    for (cases) |case| {
        var buffer: [1024]u8 = undefined;
        const json = try std.fmt.bufPrint(&buffer, "{{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"activity_search\",\"store\":\"s\",\"session\":\"x\",{s}}}", .{case.fields});
        var source: MetadataSource = .{ .input = json };
        var parser = Tested.Parser{ .source = &source };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parseForTest(&parser));
        } else {
            const request = try parseForTest(&parser);
            try std.testing.expect(request == .activity_search);
        }
    }
}

test "WIR-1 wire_object_grammar" {
    const v = "{\"version\":\"" ++ wire_version ++ "\",";
    const message = v ++ "\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"sender\":null,\"sender_handle\":null,";
    const inspect = v ++ "\"kind\":\"inspect_session\",\"store\":\"s\",\"session\":\"peer\",";
    const content = v ++ "\"kind\":\"activity_content\",\"store\":\"s\",\"session\":\"peer\",";
    const configure = v ++ "\"kind\":\"configure\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"configuration\":{";
    const since = "\"since\":\"abababababababababababababababab.42.k7m2qx\"";
    const value = "{\"state\":\"value\",\"value\":\"\"}";
    const i64_past = "\"9223372036854775808\"";
    const cases = [_]struct { json: []const u8, failure: ?anyerror = null, route: ?Kind = null }{
        .{ .json = "{\"version\":\"" ++ previous_wire_version ++ "\",\"kind\":\"host_info\",\"store\":\"s\"}", .failure = error.WrongWireVersion },
        .{ .json = "{\"version\":\"" ++ next_wire_version ++ "\",\"kind\":\"host_info\",\"store\":\"s\"}", .failure = error.WrongWireVersion },
        .{ .json = v ++ "\"kind\":\"host_info\",\"store\":\"s\"}" },
        .{ .json = v ++ "\"kind\":\"host_info\"}", .failure = error.MissingField },
        .{ .json = "{\"kind\":\"host_info\",\"store\":\"s\"}", .failure = error.MissingField },
        .{ .json = v ++ "\"store\":\"s\"}", .failure = error.MissingField },
        .{ .json = v ++ "\"kind\":\"host_info\",\"store\":\"s\"}", .failure = error.RouteKindMismatch, .route = .host_stop },
        .{ .json = v ++ "\"kind\":\"host_info\",\"store\":\"s\"}", .route = .host_info },
        .{ .json = "{\"text\":" ++ value ++ ",\"configuration\":{\"instructions\":\"\"" ++ ",\"outputSchema\":[]" ++ "}," ++ "\"version\":\"" ++ wire_version ++ "\",\"kind\":\"configure\",\"store\":\"s\"}", .failure = error.UnexpectedField },
        .{ .json = configure ++ "\"instructions\":\"\"" ++ ",\"outputSchema\":[]" ++ "}}" },
        .{ .json = configure ++ "\"instructions\":\"\"" ++ ",\"instructions\":\"\"" ++ "}}", .failure = error.UnexpectedField },
        .{ .json = message ++ "\"text\":" ++ value ++ "}" },
        .{ .json = message ++ "\"text\":" ++ value ++ ",\"configuration\":{}}", .failure = error.UnexpectedField },
        .{ .json = message ++ "\"text\":" ++ value ++ ",\"require_model\":true}", .failure = error.InvalidMessage },
        .{ .json = message ++ "\"skill\":\"review\"}", .failure = error.UnexpectedField },
        .{ .json = message ++ "\"sender_handle\":null}", .failure = error.UnexpectedField },
        .{ .json = inspect ++ since ++ "}" },
        .{ .json = inspect ++ since ++ ",\"profile\":\"full\"}", .failure = error.UnexpectedField },
        .{ .json = inspect ++ since ++ ",\"failed_response\":\"body\",\"operation\":\"1\",\"attempt\":\"1\"}", .failure = error.UnexpectedField },
        .{ .json = inspect ++ "\"failed_response\":\"body\",\"operation\":\"9223372036854775807\",\"attempt\":\"9223372036854775807\"}" },
        .{ .json = inspect ++ "\"failed_response\":\"body\",\"operation\":\"0\",\"attempt\":\"1\"}", .failure = error.InvalidTarget },
        .{ .json = inspect ++ "\"failed_response\":\"body\",\"operation\":\"1\",\"attempt\":\"0\"}", .failure = error.InvalidTarget },
        .{ .json = inspect ++ "\"failed_response\":\"body\",\"operation\":" ++ i64_past ++ ",\"attempt\":\"1\"}", .failure = error.InvalidTarget },
        .{ .json = inspect ++ "\"failed_response\":\"body\",\"operation\":\"1\",\"attempt\":" ++ i64_past ++ "}", .failure = error.InvalidTarget },
        .{ .json = inspect ++ "\"operation\":\"1\"}", .failure = error.UnexpectedField },
        .{ .json = inspect ++ "\"profile\":\"full\",\"failed_response\":\"body\",\"operation\":\"1\",\"attempt\":\"1\"}", .failure = error.UnexpectedField },
        .{ .json = content ++ "\"position\":\"1\",\"ordinal\":\"0\"}" },
        .{ .json = content ++ "\"position\":\"0\",\"ordinal\":\"0\"}", .failure = error.InvalidCursor },
        .{ .json = content ++ "\"position\":" ++ i64_past ++ ",\"ordinal\":\"0\"}", .failure = error.InvalidCursor },
        .{ .json = content ++ "\"position\":\"1\",\"ordinal\":" ++ i64_past ++ "}", .failure = error.InvalidCursor },
        .{ .json = configure ++ "\"model\":\"m\"}}" },
        .{ .json = configure ++ "\"model\":{\"state\":\"value\"}}}", .failure = error.InvalidJsonShape },
        .{ .json = configure ++ "\"model\":{\"state\":\"omitted\",\"value\":\"m\"}}}", .failure = error.InvalidJsonShape },
        .{ .json = configure ++ "\"model\":{\"value\":\"m\"}}}", .failure = error.InvalidJsonShape },
    };
    for (cases, 0..) |case, index| {
        errdefer std.debug.print("case {d}: {s}\n", .{ index, case.json });
        var source: MetadataSource = .{ .input = case.json };
        var parser: Tested.Parser = .{ .source = &source, .expected_kind = case.route, .captured = &.{ .{}, .{}, .{} } };
        if (case.failure) |failure| try std.testing.expectError(failure, parseForTest(&parser)) else _ = try parseForTest(&parser);
    }
    try publicPartSelectorGrammar();
}

test "presets allow partial creating configure in either field order" {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"configure\",\"store\":\"s\",\"key\":\"k\",\"session\":\"\",";
    for ([_][]const u8{
        head ++ "\"configuration\":{},\"preset\":\"review\"}",
        head ++ "\"preset\":\"review\",\"configuration\":{\"effort\":null}}",
        head ++ "\"preset\":\"review\",\"configuration\":{},\"require_model\":true}",
    }, 0..) |json, index| {
        var source: MetadataSource = .{ .input = json };
        var parser: Tested.Parser = .{ .source = &source };
        const request = try parseForTest(&parser);
        try std.testing.expectEqualStrings("review", request.configure.preset.?.slice());
        try std.testing.expectEqual(index == 2, request.configure.require_model);
        try std.testing.expectEqual(if (index == 1) FieldState.explicit_null else FieldState.omitted, request.configure.configuration.reasoning_effort.state);
    }
}

test "Session reader since is optional nullable and rejects invalid tokens" {
    const heads = [_][]const u8{
        "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"observe_command\",\"store\":\"s\",\"key\":\"k\"",
        "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"activity_page\",\"store\":\"s\",\"session\":\"k7m2qx\",\"end\":null,\"position\":\"0\",\"ordinal\":null,\"direction\":\"forward\",\"kinds\":[\"admission\"],\"limit\":\"16\"",
        "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"inspect_session\",\"store\":\"s\",\"session\":\"k7m2qx\"",
    };
    const cases = [_]struct { suffix: []const u8, generation: ?u64 = null, failure: ?anyerror = null }{
        .{ .suffix = "}" },
        .{ .suffix = ",\"since\":null}" },
        .{ .suffix = ",\"since\":\"abababababababababababababababab.42.k7m2qx\"}", .generation = 42 },
        .{ .suffix = ",\"since\":\"abababababababababababababababab.042.k7m2qx\"}", .failure = error.InvalidSince },
        .{ .suffix = ",\"since\":\"abababababababababababababababab.42\"}", .failure = error.InvalidSince },
        .{ .suffix = ",\"since\":17}", .failure = error.InvalidSince },
    };
    for (heads) |head| for (cases) |case| {
        var input: [512]u8 = undefined;
        const json = try std.fmt.bufPrint(&input, "{s}{s}", .{ head, case.suffix });
        var source: MetadataSource = .{ .input = json };
        var parser = Tested.Parser{ .source = &source };
        if (case.failure) |failure| {
            try std.testing.expectError(failure, parseForTest(&parser));
        } else {
            const parsed = try parseForTest(&parser);
            const since = switch (parsed) {
                .observe_command => |request| request.since,
                .activity_page => |request| request.since,
                .inspect_session => |request| request.since,
                else => unreachable,
            };
            if (case.generation) |generation| {
                try std.testing.expectEqual(generation, since.?.generation);
                try std.testing.expectEqualStrings("k7m2qx", &since.?.session);
            } else try std.testing.expect(since == null);
        }
    };
}

test "Command observation repeat shape is bounded independently of full replies" {
    var out: CommandObservationBuffer = .{};
    const token = "abababababababababababababababab.42.k7m2qx";
    try out.appendShape(command_observation_reply.not_modified, .{ "k", token });
    try std.testing.expectEqualStrings("{\"version\":\"" ++ wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"k\",\"delta\":\"not_modified\",\"since\":\"" ++ token ++ "\"}", out.slice());
    try std.testing.expect(shapeBytes(command_observation_reply.not_modified) < command_observation_reply.maxBytes(.message));
    try std.testing.expect(shapeBytes(command_observation_reply.absent) < command_observation_reply.maxBytes(.message));
}

test "session archive parses default intent and rejects malformed controls" {
    const prefix = "{\"version\":\"" ++ wire_version ++ "\",\"store\":\"s\",\"kind\":\"session_archive\",\"key\":\"k\",\"session\":\"k7m2qx\"";
    inline for (.{
        .{ "}", true },
        .{ ",\"archived\":true}", true },
        .{ ",\"archived\":false}", false },
    }) |case| {
        const bytes = prefix ++ case[0];
        var source: MetadataSource = .{ .input = bytes };
        var parser: Tested.Parser = .{ .source = &source };
        const request = try parseForTest(&parser);
        try std.testing.expectEqual(case[1], request.session_archive.archived);
        try std.testing.expectEqualStrings("k7m2qx", request.session_archive.session.slice());
    }
    inline for (.{
        .{ ",\"archived\":null}", error.InvalidJsonShape },
        .{ ",\"archived\":\"false\"}", error.InvalidJsonShape },
        .{ ",\"archived\":true,\"archived\":false}", error.UnexpectedField },
        .{ ",\"extra\":false}", error.UnexpectedField },
    }) |case| {
        const bytes = prefix ++ case[0];
        var source: MetadataSource = .{ .input = bytes };
        var parser: Tested.Parser = .{ .source = &source };
        try std.testing.expectError(case[1], parseForTest(&parser));
    }
}

test "session archive digest binds the domain session and intent not transport identity" {
    var command: SessionArchiveCommand = .{};
    try command.session.set("k7m2qx");
    const digest = command.semanticDigest();
    try command.key.set("another");
    try command.store.set("elsewhere");
    try std.testing.expectEqualSlices(u8, &digest, &command.semanticDigest());
    command.archived = false;
    try std.testing.expect(!std.mem.eql(u8, &digest, &command.semanticDigest()));
    command.archived = true;
    try command.session.set("p9q8rs");
    try std.testing.expect(!std.mem.eql(u8, &digest, &command.semanticDigest()));
    var stop: SessionStopCommand = .{};
    try stop.session.set("k7m2qx");
    try std.testing.expect(!std.mem.eql(u8, &digest, &stop.semanticDigest()));
}

test "skills native wire preserves explicit reload intent and has no skill request field" {
    const reload = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"configure\",\"store\":\"s\",\"key\":\"k\",\"session\":\"k7m2qx\",\"configuration\":{},\"reload_skills\":true}";
    var source: MetadataSource = .{ .input = reload };
    var parser: Tested.Parser = .{ .source = &source };
    const request = try parseForTest(&parser);
    try std.testing.expect(request.configure.reload_skills);
    const digest = request.configure.semanticDigest();
    var plain = request.configure;
    plain.reload_skills = false;
    try std.testing.expect(!std.mem.eql(u8, &digest, &plain.semanticDigest()));
    const message = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"k7m2qx\",\"sender\":null,\"sender_handle\":null,";
    for ([_][]const u8{ message ++ "\"skill\":\"demo\"}", message ++ "\"skills\":[\"demo\"]}" }) |removed| {
        source = .{ .input = removed };
        parser = .{ .source = &source };
        try std.testing.expectError(error.UnexpectedField, parseForTest(&parser));
    }
}

test "inline skills leave every existing canonical mutation digest unchanged" {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"store\":\"s\",\"key\":\"old\",";
    const Case = struct { body: []const u8, digest: []const u8 };
    const cases = [_]Case{
        .{ .body = head ++ "\"kind\":\"configure\",\"session\":\"k7m2qx\",\"configuration\":{}}", .digest = "db4015965f28197d8bfae4b13f61edb8b1047904643d764a7cc8ce10f9680e30" },
        .{ .body = head ++ "\"kind\":\"configure\",\"session\":\"k7m2qx\",\"configuration\":{},\"reload_skills\":true}", .digest = "14764e8bb9e20125961c2b950bac15e919dfc6653fe2cc7359b027faa0ee89b5" },
        .{ .body = head ++ "\"kind\":\"message\",\"session\":\"k7m2qx\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"\"}}", .digest = "e8cea677d75e3de98bcb68ccbbfcc6cda23fe42bd180da1c742f741f8c73975f" },
        .{ .body = head ++ "\"kind\":\"session_stop\",\"session\":\"k7m2qx\"}", .digest = "f8e8c1514a14cc72fe18bad111508cffa2b5b55812f6ba2deaed959740940d48" },
        .{ .body = head ++ "\"kind\":\"session_archive\",\"session\":\"k7m2qx\",\"archived\":true}", .digest = "ab777e65fc2476bbadf1d8eb793e2bf4d7d3bd49334bd79b4ca15a0f0c536d6b" },
        .{ .body = head ++ "\"kind\":\"session_archive\",\"session\":\"k7m2qx\",\"archived\":false}", .digest = "07e24427f9ec75478b887d3d2e5bd3a072bcc57a587c6d0826eb5bf0f6aa86df" },
        .{ .body = head ++ "\"kind\":\"model_interruption\",\"target\":{\"session\":\"k7m2qx\",\"turn\":\"7\",\"operation\":\"9\"}}", .digest = "0fd58dfc4f6ddff0f7f9da78e88e4fa50d596a623e161646c0c5082ba4350bf4" },
        .{ .body = head ++ "\"kind\":\"permission_decision\",\"session\":\"k7m2qx\",\"action\":\"11\",\"decision\":\"allow_once\"}", .digest = "58a41dbeb05f94c0a10bf02ec6dc5bf3b39a50dbfa4af591364f001c4008be79" },
    };
    for (cases) |case| {
        var source: MetadataSource = .{ .input = case.body };
        const captured: Tested.ContentField = .{ .state = .value, .length = 3, .digest = contentDigest("abc") };
        var parser: Tested.Parser = .{ .source = &source, .captured = &.{captured} };
        const request = try parseForTest(&parser);
        const digest = switch (request) {
            .configure => |*command| command.semanticDigest(),
            .message => |*command| command.semanticDigest(),
            .session_stop => |*command| command.semanticDigest(),
            .session_archive => |*command| command.semanticDigest(),
            .model_interruption => |*command| command.semanticDigest(),
            .permission_decision => |*command| command.semanticDigest(),
            else => unreachable,
        };
        try std.testing.expectEqualStrings(case.digest, &std.fmt.bytesToHex(digest, .lower));
    }
}

test "Session settings configure digest golden" {
    var command: Tested.ConfigureCommand = .{};
    try command.session.set("k7m2qx");
    try std.testing.expectEqualStrings("db4015965f28197d8bfae4b13f61edb8b1047904643d764a7cc8ce10f9680e30", &std.fmt.bytesToHex(command.semanticDigest(), .lower));
    command.require_model = true;
    const c = &command.configuration;
    c.workspace.state = .value;
    try c.workspace.value.set("/tmp/workspace");
    c.provider.state = .value;
    try c.provider.value.set("openai");
    c.model.state = .value;
    try c.model.value.set("gpt-5");
    c.instructions = .{ .state = .value, .length = 3, .digest = contentDigest("abc") };
    c.tools = try command_input.ToolsField.of(&.{ "bash", "find_tools" });
    c.loaded_tools = try command_input.ToolsField.of(&.{"bash"});
    c.permission_mode.state = .value;
    try c.permission_mode.value.set("ask");
    c.output_schema = .{ .state = .value, .length = 2, .digest = contentDigest("{}") };
    c.compaction_trigger.state = .value;
    try c.compaction_trigger.value.set("12345");
    c.output_reservation.state = .explicit_null;
    c.reasoning_effort.state = .value;
    try c.reasoning_effort.value.set("high");
    c.label.state = .value;
    try c.label.value.set("Golden Session");
    try std.testing.expectEqualStrings("46c2a9eafbd26d33d6584f2758bad73383b642adf2b6d1655dea294136399522", &std.fmt.bytesToHex(command.semanticDigest(), .lower));
}

test "Session settings preserve omitted and nullable wire states for every field" {
    inline for (.{
        .{ "workspace", "workspace", false },
        .{ "provider", "provider", false },
        .{ "model", "model", false },
        .{ "instructions", "instructions", false },
        .{ "tools", "tools", false },
        .{ "loaded_tools", "loadedTools", false },
        .{ "permission_mode", "permissionMode", false },
        .{ "output_schema", "outputSchema", true },
        .{ "compaction_trigger", "compactAt", true },
        .{ "output_reservation", "outputReservation", true },
        .{ "reasoning_effort", "effort", true },
        .{ "label", "label", true },
    }) |case| {
        inline for (.{ false, true }) |is_null| {
            const member = if (is_null) "\"" ++ case[1] ++ "\":null" else "";
            const json = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"configure\",\"store\":\"s\",\"key\":\"k\",\"session\":\"k7m2qx\",\"configuration\":{" ++ member ++ "}}";
            var source: MetadataSource = .{ .input = json };
            var parser: Tested.Parser = .{ .source = &source };
            if (is_null and !case[2]) {
                try std.testing.expectError(error.InvalidFieldState, parseForTest(&parser));
            } else {
                const request = try parseForTest(&parser);
                const name = case[0];
                try std.testing.expectEqual(if (is_null) FieldState.explicit_null else FieldState.omitted, @field(request.configure.configuration, name).state);
            }
        }
    }
}

test "parent spec relation parses creation without a workspace and rejects null or duplicate fields" {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"configure\",\"store\":\"s\",\"key\":\"k\",\"session\":\"\",\"configuration\":{";
    const required = "\"model\":\"model-a\",\"effort\":null,\"compactAt\":1000,\"tools\":[\"bash\"],\"permissionMode\":\"ask\"";
    inline for (.{ "\"parent\":\"k7m2qx\"," ++ required, required ++ ",\"parent\":\"k7m2qx\"" }) |members| {
        var source: MetadataSource = .{ .input = head ++ members ++ "}}" };
        var parser: Tested.Parser = .{ .source = &source };
        const request = try parseForTest(&parser);
        try std.testing.expectEqualStrings("k7m2qx", request.configure.configuration.parent.value.slice());
        try std.testing.expectEqual(FieldState.omitted, request.configure.configuration.workspace.state);
        try std.testing.expectEqual(FieldState.omitted, request.configure.configuration.provider.state);
    }
    inline for (.{
        .{ required, error.MissingField },
        .{ required ++ ",\"parent\":null", error.InvalidFieldState },
        .{ required ++ ",\"parent\":\"k7m2qx\",\"parent\":\"k7m2qx\"", error.UnexpectedField },
    }) |case| {
        var source: MetadataSource = .{ .input = head ++ case[0] ++ "}}" };
        var parser: Tested.Parser = .{ .source = &source };
        try std.testing.expectError(case[1], parseForTest(&parser));
    }
}

test "session pin parser requires an explicit desired value and binds semantic replay" {
    const prefix = "{\"version\":\"" ++ wire_version ++ "\",\"store\":\"s\",\"kind\":\"session_pin\",\"key\":\"k\",\"session\":\"k7m2qx\"";
    inline for (.{ .{ ",\"pinned\":true}", true }, .{ ",\"pinned\":false}", false } }) |case| {
        var source: MetadataSource = .{ .input = prefix ++ case[0] };
        var parser: Tested.Parser = .{ .source = &source };
        const request = try parseForTest(&parser);
        try std.testing.expectEqual(case[1], request.session_pin.pinned);
    }
    inline for (.{ "}", ",\"pinned\":null}", ",\"pinned\":\"false\"}", ",\"pinned\":true,\"pinned\":false}", ",\"archived\":true}" }) |tail| {
        var source: MetadataSource = .{ .input = prefix ++ tail };
        var parser: Tested.Parser = .{ .source = &source };
        if (parseForTest(&parser)) |_| return error.TestExpectedInvalidPin else |_| {}
    }
    var pin: SessionPinCommand = .{};
    try pin.session.set("k7m2qx");
    const digest = pin.semanticDigest();
    try pin.key.set("another");
    try pin.store.set("elsewhere");
    try std.testing.expectEqualSlices(u8, &digest, &pin.semanticDigest());
    pin.pinned = false;
    try std.testing.expect(!std.mem.eql(u8, &digest, &pin.semanticDigest()));
    pin.pinned = true;
    try pin.session.set("rhvzwc");
    try std.testing.expect(!std.mem.eql(u8, &digest, &pin.semanticDigest()));
    var archive: SessionArchiveCommand = .{};
    try archive.session.set("k7m2qx");
    try std.testing.expect(!std.mem.eql(u8, &digest, &archive.semanticDigest()));
}

test "Action read request preserves canonical identity and optional cursor" {
    // ARD-2
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"read_action\",\"store\":\"s\",\"session\":\"k7m2qx\",\"action\":\"42\"";
    inline for (.{ "}", ",\"offset\":\"0\"}", ",\"offset\":\"16383\"}" }, .{ 0, 0, 16383 }) |tail, offset| {
        var source: MetadataSource = .{ .input = head ++ tail };
        var parser = Tested.Parser{ .source = &source };
        const request = (try parseForTest(&parser)).read_action;
        try std.testing.expectEqual(@as(u64, 42), request.action_id);
        try std.testing.expectEqual(@as(u64, offset), request.offset);
        try std.testing.expectEqual(@as(u64, 0), request.after);
        try std.testing.expectEqualStrings("k7m2qx", request.session.slice());
    }
    {
        var source: MetadataSource = .{ .input = head ++ ",\"offset\":\"9\",\"after\":\"16\"}" };
        var parser = Tested.Parser{ .source = &source };
        const request = (try parseForTest(&parser)).read_action;
        try std.testing.expectEqual(@as(u64, 9), request.offset);
        try std.testing.expectEqual(@as(u64, 16), request.after);
    }
    {
        var source: MetadataSource = .{ .input = head ++ ",\"after\":\"18446744073709551615\",\"offset\":\"0\"}" };
        var parser = Tested.Parser{ .source = &source };
        const request = (try parseForTest(&parser)).read_action;
        try std.testing.expectEqual(std.math.maxInt(u64), request.after);
        try std.testing.expectEqual(@as(u64, 0), request.offset);
    }
    inline for (.{ ",\"after\":\"01\"}", ",\"after\":\"-1\"}", ",\"after\":\"18446744073709551616\"}" }) |tail| {
        var source: MetadataSource = .{ .input = head ++ tail };
        var parser = Tested.Parser{ .source = &source };
        try std.testing.expectError(error.InvalidIdentity, parseForTest(&parser));
    }
    inline for (.{ ",\"offset\":\"01\"}", ",\"offset\":\"-1\"}", ",\"offset\":\"18446744073709551616\"}" }) |tail| {
        var source: MetadataSource = .{ .input = head ++ tail };
        var parser = Tested.Parser{ .source = &source };
        try std.testing.expectError(error.InvalidIdentity, parseForTest(&parser));
    }
}

test "Action promotion parses one owned target and binds semantic replay" {
    const head = "{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"action_background\",\"store\":\"s\",\"key\":\"promote\",\"session\":\"k7m2qx\",\"action\":";
    var source: MetadataSource = .{ .input = head ++ "\"42\"}" };
    var parser = Tested.Parser{ .source = &source };
    var command = (try parseForTest(&parser)).action_background;
    try std.testing.expectEqual(@as(u64, 42), command.action_id);
    try std.testing.expectEqualStrings("k7m2qx", command.session.slice());
    const digest = command.semanticDigest();
    try command.key.set("another-key");
    try command.store.set("another-store");
    try std.testing.expectEqualSlices(u8, &digest, &command.semanticDigest());
    command.action_id = 43;
    try std.testing.expect(!std.mem.eql(u8, &digest, &command.semanticDigest()));
    command.action_id = 42;
    try command.session.set("rhvzwc");
    try std.testing.expect(!std.mem.eql(u8, &digest, &command.semanticDigest()));
    inline for (.{ "\"01\"}", "\"-1\"}", "\"18446744073709551616\"}" }) |tail| {
        var invalid: MetadataSource = .{ .input = head ++ tail };
        var invalid_parser = Tested.Parser{ .source = &invalid };
        try std.testing.expectError(error.InvalidIdentity, parseForTest(&invalid_parser));
    }
}

/// Owner, part, start and stream grammar of `public_parts` and `public_part_content`.
fn publicPartSelectorGrammar() !void {
    const Owner = content_value.Owner;
    const owners = [_]struct { json: []const u8, failure: ?anyerror = null, owner: Owner = .{ .message = 1 } }{
        .{ .json = "{\"message\":\"1\"}" },
        .{ .json = " { \"action\" : \"9223372036854775807\" } ", .owner = .{ .action = std.math.maxInt(i64) } },
        .{ .json = "{\"message\":\"0\"}", .failure = error.InvalidTarget },
        .{ .json = "{\"action\":\"9223372036854775808\"}", .failure = error.InvalidTarget },
        .{ .json = "{\"message\":\"01\"}", .failure = error.InvalidIdentity },
        .{ .json = "{\"message\":1}", .failure = error.InvalidJsonShape },
        .{ .json = "{\"turn\":\"1\"}", .failure = error.InvalidTarget },
        .{ .json = "{}", .failure = error.MissingField },
        .{ .json = "{\"message\":\"1\",\"action\":\"2\"}", .failure = error.UnexpectedField },
        .{ .json = "{\"message\":\"1\",\"message\":\"2\"}", .failure = error.UnexpectedField },
        .{ .json = "\"message\"", .failure = error.InvalidJsonShape },
        .{ .json = "null", .failure = error.InvalidJsonShape },
    };
    const Tail = struct { fields: []const u8, failure: ?anyerror = null, part: u32 = 0, start: u64 = 0, stream: bool = false };
    const tails = [_]Tail{
        .{ .fields = ",\"part\":\"0\",\"start\":\"0\"" },
        .{ .fields = ",\"start\":\"4096\",\"part\":\"1499\"", .part = 1499, .start = 4096 },
        .{ .fields = ",\"part\":\"2\",\"start\":\"0\",\"stream\":true", .part = 2, .stream = true },
        .{ .fields = ",\"part\":\"1500\",\"start\":\"0\"", .failure = error.InvalidCursor },
        .{ .fields = ",\"part\":\"2\",\"start\":\"1\",\"stream\":true", .failure = error.InvalidCursor },
        .{ .fields = ",\"part\":\"2\",\"start\":\"0\",\"stream\":false", .failure = error.InvalidJsonShape },
        .{ .fields = ",\"part\":\"00\",\"start\":\"0\"", .failure = error.InvalidIdentity },
        .{ .fields = ",\"part\":\"0\"", .failure = error.MissingField },
        .{ .fields = ",\"start\":\"0\"", .failure = error.MissingField },
        .{ .fields = ",\"part\":\"0\",\"start\":\"0\",\"part\":\"1\"", .failure = error.UnexpectedField },
        .{ .fields = ",\"part\":\"0\",\"start\":\"0\",\"ordinal\":\"0\"", .failure = error.UnexpectedField },
    };
    for (owners) |owner| {
        var buffer: [512]u8 = undefined;
        // The list takes exactly a session and an owner.
        for ([_][]const u8{ "", ",\"part\":\"0\"" }, 0..) |extra, index| {
            const json = try std.fmt.bufPrint(&buffer, "{{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"public_parts\",\"store\":\"s\",\"owner\":{s},\"session\":\"k7m2qx\"{s}}}", .{ owner.json, extra });
            var source: MetadataSource = .{ .input = json };
            var parser = Tested.Parser{ .source = &source };
            var failure_expected: ?anyerror = owner.failure;
            if (failure_expected == null and index == 1) failure_expected = error.UnexpectedField;
            if (failure_expected) |failure| {
                try std.testing.expectError(failure, parseForTest(&parser));
                continue;
            }
            const parsed = (try parseForTest(&parser)).public_parts;
            try std.testing.expect(std.meta.eql(owner.owner, parsed.owner));
            try std.testing.expectEqualStrings("k7m2qx", parsed.session.slice());
            var wrong_source: MetadataSource = .{ .input = json };
            var wrong_parser = Tested.Parser{ .source = &wrong_source, .expected_kind = .public_part_content };
            try std.testing.expectError(error.RouteKindMismatch, parseForTest(&wrong_parser));
        }
        for (tails) |tail| {
            const json = try std.fmt.bufPrint(&buffer, "{{\"version\":\"" ++ wire_version ++ "\",\"kind\":\"public_part_content\",\"store\":\"s\",\"session\":\"k7m2qx\",\"owner\":{s}{s}}}", .{ owner.json, tail.fields });
            var source: MetadataSource = .{ .input = json };
            var parser = Tested.Parser{ .source = &source };
            const failure_expected: ?anyerror = if (owner.failure != null) owner.failure else tail.failure;
            if (failure_expected) |failure| {
                try std.testing.expectError(failure, parseForTest(&parser));
                continue;
            }
            const parsed = (try parseForTest(&parser)).public_part_content;
            try std.testing.expect(std.meta.eql(owner.owner, parsed.owner));
            try std.testing.expectEqual(tail.part, parsed.part);
            try std.testing.expectEqual(tail.start, parsed.start);
            try std.testing.expectEqual(tail.stream, parsed.stream);
            var wrong_source: MetadataSource = .{ .input = json };
            var wrong_parser = Tested.Parser{ .source = &wrong_source, .expected_kind = .public_parts };
            try std.testing.expectError(error.RouteKindMismatch, parseForTest(&wrong_parser));
        }
    }
    // The request writers emit what the parser accepts.
    var body: RequestBuffer = .{};
    try body.appendShape(public_part_content_request.all, .{ "s", "k7m2qx", OwnerJson{ .owner = .{ .action = 42 } }, @as(u64, 7), @as(u64, 0) });
    var source: MetadataSource = .{ .input = body.slice() };
    var parser = Tested.Parser{ .source = &source };
    const written = (try parseForTest(&parser)).public_part_content;
    try std.testing.expect(std.meta.eql(Owner{ .action = 42 }, written.owner) and written.part == 7 and written.stream);
}
