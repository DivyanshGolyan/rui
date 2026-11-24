const std = @import("std");
const operation_effort = @import("operation_effort.zig");
const session_settings = @import("../../session_settings.zig");
const command_reply = @import("../../command_reply.zig");
const command_input = @import("../../command_input.zig");
const configuration_defaults = @import("../../configuration_defaults.zig");
const configuration_admission = @import("../../configuration_admission.zig");
const workspace_path = @import("../../workspace_path.zig");
const provider_route = @import("../../provider_route.zig");
const required_settings = @import("../../required_settings.zig");
const tool_presentation = @import("../../tool_presentation.zig");
const tool_name = @import("../../tool_name.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const cli_value = @import("../../cli_value.zig");
const provider_name = @import("../../provider_name.zig");
const connection = @import("../../connection.zig");
const session_id = @import("../../session_id.zig");
const content_custody = @import("../../content_custody.zig");
const model_catalog = @import("../../model_catalog.zig");
const model_facts = @import("model_facts.zig");
const model_capability = @import("../../model_capability.zig");
const product_defaults = @import("../../product_defaults.zig");
const tool_defs = @import("../../tool_record.zig");
const store_core = @import("../Store.zig");
const command_domain = @import("command.zig");
const content_domain = @import("content.zig");
const model_settlement_domain = @import("model_settlement.zig");
const tool_set = @import("tool_set.zig");
const skills_domain = @import("skills.zig");
const rsql = @import("../rsql.zig");
const store_access = @import("../access.zig");
const Faults = store_core.Faults;
const StoredAnswer = command_domain.StoredAnswer;

pub const AcceptedConfiguration = command_reply.AcceptedConfiguration;

pub const RejectedConfiguration = command_reply.RejectedConfiguration;

pub const PresetDecision = struct {
    request_digest: [32]u8,
    rejection: ?Rejection = null,

    pub const Rejection = enum { unknown_preset, preset_on_update };
};

pub const ConfigureReply = command_reply.ConfigureReply;

fn requestedNames(requested: anytype) *const command_input.ToolsField {
    return if (@TypeOf(requested.tools) == *const command_input.ToolsField) requested.tools else &requested.tools;
}

fn toolsRejection(host_tool_set: *const tool_defs.HostToolSet, served: *const provider_route.Served, provider: connection.Name, tools: *const command_input.ToolsField) ?configuration_admission.Rejection {
    var names = tools.iterator();
    while (names.next()) |name| {
        const index = switch (host_tool_set.resolve(name)) {
            .found => |index| index,
            .unknown_tool => return .unknown_tool,
            .mcp_server_unavailable => return .mcp_server_unavailable,
        };
        if (host_tool_set.records[index].owner == .provider and !served.runsTool(provider.slice(), name)) return .provider_tool_missing;
    }
    return null;
}

pub fn missingToolMessage(host_tool_set: *const tool_defs.HostToolSet, code: anytype, tools: *const command_input.ToolsField) ?tool_defs.HostToolSet.MissingTool {
    switch (code) {
        .unknown_tool, .mcp_server_unavailable => {},
        else => return null,
    }
    var names = tools.iterator();
    while (names.next()) |name| {
        if (host_tool_set.resolve(name) != .found) return host_tool_set.missingTool(name);
    }
    return null;
}

fn permissionModeCode(mode: []const u8) u8 {
    return if (std.mem.eql(u8, mode, "ask")) 0 else 1;
}

pub fn permissionMode(code: u8) error{CorruptStore}!cli_value.PermissionMode {
    return switch (code) {
        0 => .ask,
        1 => .bypass,
        else => error.CorruptStore,
    };
}

pub fn checkLabel(label: []const u8) error{CorruptStore}!void {
    if (!tool_presentation.validLabel(label)) return error.CorruptStore;
}

pub const CurrentConfiguration = struct {
    workspace: Bounded(workspace_path.max_bytes) = .{},
    provider: connection.Name = undefined,
    /// The codec of the current revision's bags; a Session never changes codec, so every revision carries the same one.
    codec: provider_name.Codec = undefined,
    model: Bounded(model_capability.max_model_bytes) = .{},
    instructions_id: ?i64 = null,
    tool_set_id: u64 = 0,
    loaded_tool_set_id: ?u64 = null,
    permission_mode: u8 = 0,
    output_schema_id: ?i64 = null,
    revision: u64 = 0,
    next_position: u64 = 1,
    compaction_trigger: ?u64 = null,
    output_reservation: ?u64 = null,
    reasoning_effort: ?model_capability.ReasoningEffort = null,
    label: ?Bounded(tool_presentation.max_label_bytes) = null,
    created_at: u64 = 0,
    workspace_key: u64 = 0,
    parent_ref: ?Bounded(session_id.bytes) = null,
    previous_reasoning_effort: ?model_capability.ReasoningEffort = null,
};

pub const SessionFacts = struct {
    provider: connection.Name,
    model: Bounded(model_capability.max_model_bytes) = .{},
    permission_mode: u8,
    revision: u64,
    next_position: u64,
    compaction_trigger: ?u64 = null,
    output_reservation: ?u64 = null,
    reasoning_effort: ?model_capability.ReasoningEffort = null,
    created_at: u64,
};

pub const ConfigurationContentAction = enum(u2) {
    preserve,
    import_requested,
    default_empty,
    clear,
};

pub const OutputSchemaAction = enum(u2) {
    preserve,
    import_requested,
    clear,
};

pub const ConfigurationUpdatePlan = union(enum) {
    rejected: configuration_admission.Rejection,
    update: struct {
        instructions: ConfigurationContentAction,
        output_schema: OutputSchemaAction,
    },
};

fn configurationTokens(field: anytype, previous: ?u64, allow_zero: bool) !?u64 {
    if (field.state == .omitted) return previous;
    if (field.state == .explicit_null) return null;
    if (field.state != .value) return error.InvalidTokenHeuristic;
    const value = try tokenCount(field.value.slice(), allow_zero);
    if (value > std.math.maxInt(i64)) return error.InvalidTokenHeuristic;
    return value;
}

fn tokenCount(text: []const u8, allow_zero: bool) !u64 {
    const value = std.fmt.parseInt(u64, text, 10) catch return error.InvalidTokenHeuristic;
    if (!allow_zero and value == 0) return error.InvalidTokenHeuristic;
    for (text) |byte| if (byte < '0' or byte > '9') return error.InvalidTokenHeuristic;
    return value;
}

pub fn configurationBeforeWorkspace(
    selected_facts: []const model_catalog.Entry,
    host_tool_set: *const tool_defs.HostToolSet,
    served: *const provider_route.Served,
    current: ?*const CurrentConfiguration,
    requested: anytype,
    creation_provider: ?connection.Name,
) ?configuration_admission.Rejection {
    if (requested.compaction_trigger.state == .explicit_null) return .invalid_compaction_trigger;
    const compact_at = if (requested.compaction_trigger.state == .value)
        tokenCount(requested.compaction_trigger.value.slice(), false) catch return .invalid_compaction_trigger
    else if (current) |existing|
        existing.compaction_trigger
    else
        null;
    _ = configurationTokens(requested.output_reservation, null, true) catch return .invalid_output_reservation;
    const provider = if (requested.connection.state == .value)
        connection.Name.parse(requested.connection.value.slice()) orelse return .unknown_connection
    else
        null;
    if (current) |existing| {
        if (provider) |value| {
            if (!value.eql(existing.provider)) return .connection_is_immutable;
        }
    }
    if (requested.label.state == .value and !tool_presentation.validLabel(requested.label.value.slice())) return .invalid_label;
    if (requested.tools.state == .value) if (toolsRejection(host_tool_set, served, provider orelse (if (current) |existing| existing.provider else creation_provider.?), requestedNames(requested))) |rejection| return rejection;
    const model = if (requested.model.state == .value) requested.model.value.slice() else current.?.model.slice();
    if (compact_at) |tokens| if (model_catalog.find(selected_facts, model)) |known| {
        if (known.context_window) |window| if (tokens > window) return .compact_at_too_large;
    };
    if (compact_at) |tokens| if (tokens > std.math.maxInt(i64)) return .invalid_compaction_trigger;
    const retained_effort = if (current) |existing| effectiveReasoningEffort(existing) else null;
    const effort = switch (requested.reasoning_effort.state) {
        .omitted => retained_effort,
        .explicit_null => null,
        .value => std.meta.stringToEnum(model_capability.ReasoningEffort, requested.reasoning_effort.value.slice()) orelse
            return .unsupported_reasoning_effort,
    };
    if (requested.reasoning_effort.state == .explicit_null and retained_effort != null) return .unsupported_reasoning_effort;
    if (!model_capability.supportsReasoningEffort(selected_facts, model, effort)) return .unsupported_reasoning_effort;
    return null;
}

pub fn effectiveReasoningEffort(current: anytype) ?model_capability.ReasoningEffort {
    return current.reasoning_effort orelse current.previous_reasoning_effort;
}

pub fn effortChoiceRevisionSql(comptime revision: []const u8) []const u8 {
    return "(SELECT intent.effort_source_revision FROM session_revision intent WHERE intent.session_ref=" ++ revision ++ ".session_ref AND intent.revision=" ++ revision ++ ".revision)";
}

fn hasEffortRefusalSql(comptime revision: []const u8) []const u8 {
    return "EXISTS(SELECT 1 FROM session_change refusal WHERE refusal.session_ref=" ++ revision ++ ".session_ref AND refusal.field='reasoning_effort_refused' AND refusal.revision<=" ++ revision ++ ".revision)";
}

pub fn reasoningEffortOverrideSql(comptime revision: []const u8) []const u8 {
    return "CASE WHEN " ++ hasEffortRefusalSql(revision) ++ " THEN " ++ operation_effort.sourceOverrideSql(revision ++ ".session_ref", effortChoiceRevisionSql(revision)) ++ " ELSE " ++ revision ++ ".reasoning_effort END";
}

pub fn previousReasoningEffortSql(comptime revision: []const u8) []const u8 {
    return "CASE WHEN " ++ revision ++ ".reasoning_effort IS NULL OR " ++ hasEffortRefusalSql(revision) ++ " THEN (SELECT " ++ operation_effort.effectiveSql("legacy") ++ " FROM model_operation legacy @index(model_operation_admission) WHERE legacy.session_ref=" ++ revision ++ ".session_ref AND legacy.settings_revision<=" ++ revision ++ ".revision ORDER BY legacy.admission_position DESC LIMIT 1) END";
}

pub fn planConfigurationUpdate(
    current: ?*const CurrentConfiguration,
    requested: anytype,
    workspace_matches: ?bool,
    next: *CurrentConfiguration,
) ConfigurationUpdatePlan {
    const created = current == null;
    if (requested.workspace.state == .value) {
        const matches = workspace_matches orelse unreachable;
        if (current != null and !matches) return .{ .rejected = .workspace_is_immutable };
    } else {
        std.debug.assert(workspace_matches == null);
    }
    if (current) |existing| {
        if (existing.revision == std.math.maxInt(i64)) {
            return .{ .rejected = .revision_exhausted };
        }
    }

    if (requested.connection.state == .value) next.provider = connection.Name.parse(requested.connection.value.slice()).?;
    if (requested.model.state == .value) next.model = requested.model.value;
    if (requested.permission_mode.state == .value) {
        next.permission_mode = permissionModeCode(requested.permission_mode.value.slice());
    }
    next.revision = if (created) 1 else current.?.revision + 1;
    next.compaction_trigger = configurationTokens(requested.compaction_trigger, next.compaction_trigger, false) catch unreachable;
    next.output_reservation = configurationTokens(requested.output_reservation, next.output_reservation, true) catch unreachable;
    switch (requested.reasoning_effort.state) {
        .omitted => {},
        .explicit_null => next.reasoning_effort = null,
        .value => next.reasoning_effort = std.meta.stringToEnum(model_capability.ReasoningEffort, requested.reasoning_effort.value.slice()).?,
    }
    switch (requested.label.state) {
        .omitted => {},
        .explicit_null => next.label = null,
        .value => next.label = requested.label.value,
    }

    return .{ .update = .{
        .instructions = switch (requested.instructions.state) {
            .value => .import_requested,
            .omitted, .explicit_null => if (created) .default_empty else .preserve,
        },
        .output_schema = switch (requested.output_schema.state) {
            .value => .import_requested,
            .explicit_null => .clear,
            .omitted => if (created) .clear else .preserve,
        },
    } };
}

pub noinline fn configureDigest(
    command: *const content_custody.ConfigureCommand,
    preset: ?*const PresetDecision,
    saved: *const command_domain.saved_command.Result,
    digest: *[32]u8,
) void {
    if (preset) |decision| {
        const saved_preset_refusal = if (saved.*) |*row|
            !row.accepted and std.meta.stringToEnum(PresetDecision.Rejection, row.code.slice()) != null
        else
            false;
        if (decision.rejection != null or saved_preset_refusal) {
            digest.* = decision.request_digest;
            return;
        }
    }
    digest.* = command.semanticDigest();
}

pub const Applied = struct {
    session: Bounded(session_id.max_reference_bytes),
    head: rsql.SessionHead,
    revision: u64,
    /// The codec a Session's first revision pins (its provider's). Null for a later revision, which carries
    /// the codec of the revision before it in the insert.
    codec: ?provider_name.Codec = null,
    instructions_id: ?u64,
    output_schema_id: ?u64,
    instructions_updated: bool,
    changes: std.EnumSet(session_settings.SessionField) = .empty,
};

const Settings = struct {
    provider: connection.Name,
    model: Bounded(model_capability.max_model_bytes),
    instructions_id: ?i64,
    tool_set_id: u64,
    loaded_tool_set_id: ?u64,
    permission_mode: u8,
    output_schema_id: ?i64,
    compaction_trigger: ?u64,
    output_reservation: ?u64,
    reasoning_effort: ?model_capability.ReasoningEffort,
    label: ?Bounded(tool_presentation.max_label_bytes),

    fn of(current: *const CurrentConfiguration) Settings {
        return .{
            .provider = current.provider,
            .model = current.model,
            .instructions_id = current.instructions_id,
            .tool_set_id = current.tool_set_id,
            .loaded_tool_set_id = current.loaded_tool_set_id,
            .permission_mode = current.permission_mode,
            .output_schema_id = current.output_schema_id,
            .compaction_trigger = current.compaction_trigger,
            .output_reservation = current.output_reservation,
            .reasoning_effort = current.reasoning_effort,
            .label = current.label,
        };
    }

    fn changed(before: *const Settings, after: *const CurrentConfiguration) std.EnumSet(session_settings.SessionField) {
        var fields: std.EnumSet(session_settings.SessionField) = .empty;
        inline for (session_settings.entries) |entry| {
            if (comptime entry.changeable) {
                const name = comptime settingsField(entry);
                const old = @field(before, name);
                const next = @field(after, name);
                const same = switch (entry.kind) {
                    .text => if (entry.nullable)
                        (if (old) |value| (if (next) |other| value.eql(other.slice()) else false) else next == null)
                    else
                        old.eql(next.slice()),
                    .choice, .content, .tools, .decimal_policy => old == next,
                };
                fields.setPresent(@field(session_settings.SessionField, entry.field), !same);
            }
        }
        return fields;
    }
};

fn settingsField(comptime entry: session_settings.Entry) []const u8 {
    return switch (entry.kind) {
        .content => entry.field ++ "_id",
        else => entry.column,
    };
}

pub const creation_hint = rsql.Read(.{
    .sql = "SELECT EXISTS(SELECT 1 FROM core_command WHERE command_key=?1) AS replay,coalesce((SELECT workspace FROM session WHERE session_ref=?2),'/') AS workspace",
    .Args = struct { key: []const u8, parent: []const u8 },
    .Row = struct { replay: bool, workspace: *Bounded(workspace_path.max_bytes) },
    .cardinality = .optional,
});

const parent_settings = rsql.Read(.{
    .sql = "SELECT workspace,provider,coalesce(" ++ tool_set.namesSql("session.tool_set_id") ++ ",'') AS tools,permission_mode FROM session WHERE session_ref=?1 " ++
        "AND session.archive_seq IS NULL",
    .Args = struct { session: []const u8 },
    .Row = struct { workspace: *Bounded(workspace_path.max_bytes), provider: connection.Name, tools: *Bounded(tool_set.max_names_bytes), permission_mode: u8 },
    .cardinality = .optional,
});

pub const ParentFailure = struct {
    code: configuration_admission.Rejection,
    tool: ?[]const u8 = null,

    fn from(failure: configuration_defaults.ParentRefusal) ParentFailure {
        return switch (failure) {
            .tools_not_in_parent => |name| .{ .code = .tools_not_in_parent, .tool = name },
            .permission_mode_wider_than_parent => .{ .code = .permission_mode_wider_than_parent },
        };
    }

    pub fn text(failure: ParentFailure, buffer: []u8, comptime effect: []const u8) []const u8 {
        return switch (failure.code) {
            .tools_not_in_parent => std.fmt.bufPrint(buffer, "spec.tools: {s} is not one of your tools. Nothing was " ++ effect ++ ".", .{failure.tool.?}) catch unreachable,
            .permission_mode_wider_than_parent => "spec.permissionMode: you ask before running commands, so your agents ask too. Nothing was " ++ effect ++ ".",
            .parent_provider_forbidden => "spec.provider: an agent always uses your provider",
            .parent_workspace_forbidden => "spec.workspace: an agent always works in your Workspace",
            else => unreachable,
        };
    }
};

fn prepareParent(a: anytype, reference: []const u8, reads: *ConfigurationReads) void {
    reads.inherits_parent = true;
    reads.inherited = .{ .workspace = &reads.next.workspace, .provider = undefined, .tools = &reads.saved_tools.names, .permission_mode = undefined };
    a.readInto(parent_settings, .{ .session = reference }, &reads.inherited, &reads.parent_found);
}

fn preferences(configuration: *const content_custody.Configuration) configuration_defaults.Preferences {
    const saved = if (configuration.preferences) |*value| value else return .{};
    return .{
        .reasoning_effort = if (saved.reasoning_effort.state == .value) saved.reasoning_effort.value.slice() else null,
        .permission_mode = if (saved.permission_mode.state == .value) saved.permission_mode.value.slice() else null,
    };
}

pub fn inheritParent(host_tool_set: *const tool_defs.HostToolSet, served: *const provider_route.Served, configuration: *const content_custody.Configuration, reads: *ConfigurationReads) !?configuration_admission.Rejection {
    if (!reads.inherits_parent) return null;
    if (!reads.parent_found.get()) return .unknown_session;
    if (reads.parent_checked) return if (reads.parent_failure) |failure| failure.code else null;
    // start_agent checks parent authority before the ordinary validation round.
    // Do not cache authority against an image profile for an absent or invalid model.
    if (modelRejection(&configuration.model)) |code| return code;
    // A missing model is named with every other missing setting once validation reaches the check.
    if (configuration.model.state != .value) return null;
    const failure: ?ParentFailure = refusal: {
        if (configuration.workspace.state != .omitted) break :refusal .{ .code = .parent_workspace_forbidden };
        if (configuration.connection.state != .omitted) break :refusal .{ .code = .parent_provider_forbidden };
        // This early start_agent boundary needs only tool and permission
        // authority. The selected catalog is read later for model defaults.
        const resolved = configuration_defaults.resolve(&.{}, .{
            .creating = true,
            .parent = .{ .tools = reads.inherited.tools.slice(), .permission_mode = try permissionMode(reads.inherited.permission_mode) },
            .provider = reads.inherited.provider,
            .model = configuration.model.value.slice(),
            .can_read_images = @import("../../os/read_image_file.zig").available,
            .tools = &configuration.tools,
            .loaded_tools = &configuration.loaded_tools,
            .permission_mode = &configuration.permission_mode,
            .reasoning_effort = &configuration.reasoning_effort,
            .compaction_trigger = &configuration.compaction_trigger,
            .preferences = preferences(configuration),
        });
        if (toolsRejection(host_tool_set, served, reads.inherited.provider, resolved.tools)) |code| return code;
        if (resolved.parent_refusal) |failure| break :refusal ParentFailure.from(failure);
        break :refusal null;
    };
    reads.parent_checked = true;
    reads.parent_failure = failure;
    if (failure) |refused| return refused.code;
    reads.next.provider = reads.inherited.provider;
    reads.workspace_digest = store_core.workspaceDigest(reads.next.workspace.slice());
    reads.creator = configuration.parent.value.slice()[0..session_id.bytes].*;
    return null;
}

/// A borrowed admission view keeps content custody and tool lists at their owners.
const ConfigurationView = struct {
    workspace: *const @FieldType(content_custody.Configuration, "workspace"),
    provider: *const @FieldType(content_custody.Configuration, "provider"),
    model: *const @FieldType(content_custody.Configuration, "model"),
    instructions: *const @FieldType(content_custody.Configuration, "instructions"),
    tools: *const @FieldType(content_custody.Configuration, "tools"),
    loaded_tools: *const @FieldType(content_custody.Configuration, "loaded_tools"),
    permission_mode: *const @FieldType(content_custody.Configuration, "permission_mode"),
    output_schema: *const @FieldType(content_custody.Configuration, "output_schema"),
    compaction_trigger: *const @FieldType(content_custody.Configuration, "compaction_trigger"),
    output_reservation: *const @FieldType(content_custody.Configuration, "output_reservation"),
    reasoning_effort: *const @FieldType(content_custody.Configuration, "reasoning_effort"),
    label: *const @FieldType(content_custody.Configuration, "label"),
    parent: *const @FieldType(content_custody.Configuration, "parent"),

    fn init(self: *ConfigurationView, configuration: *const content_custody.Configuration) void {
        inline for (@typeInfo(ConfigurationView).@"struct".field_names) |field| @field(self, field) = &@field(configuration, field);
    }
};

pub const ConfigurationReads = struct {
    configuration: ConfigurationView = undefined,
    defaults: configuration_defaults.Resolved = undefined,
    saved_command: command_domain.saved_command.Result = undefined,
    command_digest: [32]u8 = undefined,
    command_answer: StoredAnswer = undefined,
    message: command_domain.MessageReads = undefined,
    next: CurrentConfiguration,
    validated: ValidatedConfiguration = undefined,
    step: union(enum) { validating: Validating, applying: ApplyState } = undefined,
    applied: Applied = undefined,
    found: store_access.Found = .missing,
    reference: [session_id.bytes]u8 = undefined,
    workspace_digest: [32]u8 = undefined,
    creation: creation_facts.Result = undefined,
    instructions: content_domain.Import = undefined,
    output_schema: content_domain.Import = undefined,
    empty: content_domain.Import = content_domain.empty_content,
    pair: ?content_domain.Pair = null,
    tools: ?tool_set.Selection = null,
    loaded_tools: ?tool_set.Selection = null,
    saved_tools: command_input.ToolsField = undefined,
    saved_loaded: command_input.ToolsField = undefined,
    creator: ?[session_id.bytes]u8 = null,
    inherits_parent: bool = false,
    attach_parent: bool = true,
    inherited: parent_settings.Row = undefined,
    parent_found: store_access.Found = .missing,
    parent_checked: bool = false,
    parent_failure: ?ParentFailure = null,
    /// Set with a `missing_settings` rejection: the settings the new Session lacks.
    missing: ?required_settings.Missing = null,

    fn instructionsValue(reads: *ConfigurationReads, configuration: *const content_custody.Configuration) *content_domain.Import {
        return if (configuration.instructions.state == .value) &reads.instructions else &reads.empty;
    }
};

const saved_session = rsql.Read(.{
    .sql = "SELECT workspace,provider,(SELECT r.codec FROM session_revision r WHERE r.session_ref=session.session_ref AND r.revision=session.revision) AS codec,model,instructions_content_id AS instructions_id,tool_set_id,loaded_tool_set_id,permission_mode," ++
        "output_schema_content_id AS output_schema_id,revision,next_position,compaction_trigger,output_reservation," ++
        reasoningEffortOverrideSql("session") ++ " AS reasoning_effort,label,created_at,workspace_key,parent_ref," ++ previousReasoningEffortSql("session") ++ " AS previous_reasoning_effort FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = CurrentConfiguration,
    .cardinality = .optional,
});

const creation_facts = rsql.Read(.{
    .sql = "SELECT (SELECT workspace_key FROM session WHERE workspace_digest=?1 AND workspace=?2 LIMIT 1) AS workspace_key," ++
        "EXISTS(SELECT 1 FROM session WHERE session_ref=?3) AS taken",
    .Args = struct { digest: [32]u8, workspace: []const u8, session: []const u8 },
    .Row = struct { workspace_key: ?rsql.Positive, taken: bool },
    .cardinality = .one,
});

const insert_session = rsql.Write(.{
    .sql = "INSERT INTO session(session_ref,workspace,model,instructions_content_id,tool_set_id,permission_mode,output_schema_content_id,revision,next_position," ++
        "provider,compaction_trigger,output_reservation,reasoning_effort,label,workspace_digest,created_at,created_seq,workspace_key,parent_ref,loaded_tool_set_id,creator_ref) " ++
        "VALUES(@session(?1),?2,?3,?4,?5,?6,?7,1,1,?8,?9,?10,?11,?12,?13,@now,?14,?15,?16,?17,?18)",
    .Args = struct {
        session: rsql.SessionHead,
        workspace: []const u8,
        model: []const u8,
        instructions_id: ?u64,
        tool_set_id: u64,
        permission_mode: u8,
        output_schema_id: ?u64,
        provider: connection.Name,
        compaction_trigger: ?u64,
        output_reservation: ?u64,
        reasoning_effort: ?model_capability.ReasoningEffort,
        label: ?[]const u8,
        digest: [32]u8,
        created_seq: u64,
        workspace_key: u64,
        parent: ?Bounded(session_id.bytes),
        loaded_tool_set_id: ?u64,
        creator: ?Bounded(session_id.bytes),
    },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

pub fn insertSession(a: anytype, head: rsql.SessionHead, next: *const CurrentConfiguration, workspace_digest: *const [32]u8, created_seq: u64, parent: ?*const [session_id.bytes]u8, creator: ?*const [session_id.bytes]u8) void {
    var parent_ref: ?Bounded(session_id.bytes) = null;
    if (parent) |reference| {
        parent_ref = .{};
        parent_ref.?.set(reference) catch unreachable;
    }
    a.write(insert_session, .{
        .session = head,
        .workspace = next.workspace.slice(),
        .model = next.model.slice(),
        .instructions_id = if (next.instructions_id) |id| @intCast(id) else null,
        .tool_set_id = next.tool_set_id,
        .permission_mode = next.permission_mode,
        .output_schema_id = if (next.output_schema_id) |id| @intCast(id) else null,
        .provider = next.provider,
        .compaction_trigger = next.compaction_trigger,
        .output_reservation = next.output_reservation,
        .reasoning_effort = next.reasoning_effort,
        .label = if (next.label) |*label| label.slice() else null,
        .digest = workspace_digest.*,
        .created_seq = created_seq,
        .workspace_key = head.workspace_key.get(),
        .parent = parent_ref,
        .loaded_tool_set_id = next.loaded_tool_set_id,
        .creator = if (creator) |reference| Bounded(session_id.bytes).from(reference) catch unreachable else null,
    });
}

const update_session = rsql.Write(.{
    .sql = "UPDATE session SET model=?2,instructions_content_id=?3,tool_set_id=?4,permission_mode=?5,output_schema_content_id=?6,revision=?7,provider=?8," ++
        "compaction_trigger=?9,output_reservation=?10,reasoning_effort=?11,label=?12,loaded_tool_set_id=?13 WHERE session_ref=@session(?1)",
    .Args = struct {
        session: rsql.SessionHead,
        model: []const u8,
        instructions_id: ?u64,
        tool_set_id: u64,
        permission_mode: u8,
        output_schema_id: ?u64,
        revision: u64,
        provider: connection.Name,
        compaction_trigger: ?u64,
        output_reservation: ?u64,
        reasoning_effort: ?model_capability.ReasoningEffort,
        label: ?[]const u8,
        loaded_tool_set_id: ?u64,
    },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.SessionUpdateFailed } },
});

pub const update_session_sql = update_session.sql;

const insert_revision = rsql.Write(.{
    .sql = "INSERT INTO session_revision(session_ref,revision,command_key,workspace,model,instructions_content_id,instructions_updated,tool_set_id,loaded_tool_set_id," ++
        "permission_mode,output_schema_content_id,provider,codec,codec_options,compaction_trigger,output_reservation,reasoning_effort,label,effort_source_revision) " ++
        "SELECT session_ref,revision,?2,workspace,model,instructions_content_id,?3,tool_set_id,loaded_tool_set_id,permission_mode,output_schema_content_id,provider," ++
        "CASE WHEN ?5 IS NULL THEN (SELECT prior.codec FROM session_revision prior WHERE prior.session_ref=session.session_ref AND prior.revision=session.revision-1) ELSE ?5 END," ++
        "CASE WHEN ?5 IS NULL THEN (SELECT prior.codec_options FROM session_revision prior WHERE prior.session_ref=session.session_ref AND prior.revision=session.revision-1) END," ++
        "compaction_trigger,output_reservation,reasoning_effort,label,CASE WHEN revision=1 OR ?4 THEN revision ELSE (SELECT prior.effort_source_revision FROM session_revision prior WHERE prior.session_ref=session.session_ref AND prior.revision=session.revision-1) END FROM session WHERE session_ref=@session(?1)",
    .Args = struct { session: rsql.SessionHead, command_key: []const u8, instructions_updated: bool, effort_choice: bool, codec: ?[]const u8 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

pub fn readSaved(a: anytype, session_ref: []const u8, current: *CurrentConfiguration, found: *store_access.Found) void {
    a.readInto(saved_session, .{ .session = session_ref }, current, found);
}

pub fn checkSaved(current: *const CurrentConfiguration) error{CorruptStore}!void {
    const instructions = current.instructions_id orelse return error.CorruptStore;
    if (instructions == 0 or current.output_schema_id == @as(?i64, 0) or current.revision == 0 or current.next_position == 0 or
        current.compaction_trigger == @as(?u64, 0) or current.created_at == 0 or current.workspace_key == 0 or current.tool_set_id == 0 or current.loaded_tool_set_id == @as(?u64, 0)) return error.CorruptStore;
    _ = try permissionMode(current.permission_mode);
    if (current.label) |*label| try checkLabel(label.slice());
}

fn newReference(io: std.Io, reference: *[session_id.bytes]u8) !void {
    try std.Io.randomSecure(io, reference);
    for (reference) |*byte| byte.* = session_id.alphabet[byte.* & 31];
}

pub noinline fn prepareConfiguration(a: anytype, host_tool_set: *const tool_defs.HostToolSet, session: []const u8, configuration: *const content_custody.Configuration, reads: *ConfigurationReads) void {
    const creating = session.len == 0;
    reads.configuration.init(configuration);
    if (!creating) readSaved(a, session, &reads.next, &reads.found);
    if (creating and configuration.parent.state == .value) prepareParent(a, configuration.parent.value.slice(), reads);
    if (creating or configuration.tools.state == .value) {
        reads.tools = .of(host_tool_set, if (creating) configuration_defaults.creationTools(&configuration.tools, configuration.model.value.slice(), @import("../../os/read_image_file.zig").available) else &configuration.tools);
        if (reads.tools) |*tools| tool_set.lookupSelection(a, tools);
    }
    const instructions: ?*content_domain.Import = if (configuration.instructions.state == .value) requested: {
        reads.instructions = content_domain.sealedIdentity(&configuration.instructions);
        break :requested &reads.instructions;
    } else if (creating) &reads.empty else null;
    const output_schema: ?*content_domain.Import = if (configuration.output_schema.state == .value) requested: {
        reads.output_schema = content_domain.sealedIdentity(&configuration.output_schema);
        break :requested &reads.output_schema;
    } else null;
    if (instructions != null and output_schema != null) {
        reads.pair = .{ .first = null, .second = null };
        content_domain.lookupPair(a, instructions.?, output_schema.?, &reads.pair.?);
    } else if (instructions orelse output_schema) |value| content_domain.lookup(a, value);
}

const selected_names = rsql.Read(.{
    .sql = "SELECT tool.name FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id " ++
        "WHERE member.tool_set_id=?1 ORDER BY tool.name",
    .Args = struct { set: u64 },
    .Row = struct { name: Bounded(tool_defs.max_name_bytes) },
    .cardinality = .each,
});

fn containsName(names: *const command_input.ToolsField, wanted: []const u8) bool {
    var each = names.iterator();
    while (each.next()) |name| if (std.mem.eql(u8, name, wanted)) return true;
    return false;
}

const NameSelection = struct {
    names: *command_input.ToolsField,
    filter: ?*const command_input.ToolsField = null,
    invalid: bool = false,

    pub fn visit(self: *NameSelection, row: *const selected_names.Row) bool {
        if (self.filter) |filter| if (!containsName(filter, row.name.slice())) return true;
        self.names.append(row.name.slice()) catch {
            self.invalid = true;
            return false;
        };
        return true;
    }
};

fn loadedToolsRejection(tools: *const command_input.ToolsField, loaded: *const command_input.ToolsField) ?configuration_admission.Rejection {
    var names = loaded.iterator();
    while (names.next()) |name| if (!containsName(tools, name)) return .loaded_tools_not_in_tools;
    if (loaded.count < tools.count and !containsName(loaded, "find_tools")) return .loaded_tools_unreachable;
    return null;
}

fn loadedTools(a: anytype, request: *const Request, reads: *ConfigurationReads) !Validation {
    const requested = &reads.configuration;
    const creating = request.session.len == 0;
    if (!creating and requested.tools.state != .value and requested.loaded_tools.state != .value) return finishValidation(request, reads);
    if (requested.loaded_tools.state != .value and (creating or reads.next.loaded_tool_set_id == null)) return finishValidation(request, reads);
    const v = &reads.step.validating;
    if (creating or requested.tools.state == .value) {
        v.tools = requestedNames(requested);
        return loadedNames(a, request, reads);
    }
    reads.saved_tools.state = .value;
    reads.saved_tools.count = 0;
    reads.saved_tools.names.len = 0;
    v.names = .{ .names = &reads.saved_tools };
    a.readEach(selected_names, .{ .set = reads.next.tool_set_id }, tool_name.max_tools + 1, &v.names);
    return .{ .round = .saved_tools };
}

fn loadedNames(a: anytype, request: *const Request, reads: *ConfigurationReads) !Validation {
    const v = &reads.step.validating;
    if (reads.configuration.loaded_tools.state == .value) {
        v.loaded = reads.configuration.loaded_tools;
        return selectLoaded(a, request, reads);
    }
    reads.saved_loaded.state = .value;
    reads.saved_loaded.count = 0;
    reads.saved_loaded.names.len = 0;
    v.names = .{ .names = &reads.saved_loaded, .filter = v.tools };
    a.readEach(selected_names, .{ .set = reads.next.loaded_tool_set_id.? }, tool_name.max_tools + 1, &v.names);
    return .{ .round = .saved_loaded };
}

fn selectLoaded(a: anytype, request: *const Request, reads: *ConfigurationReads) !Validation {
    const v = &reads.step.validating;
    if (loadedToolsRejection(v.tools, v.loaded)) |rejection| {
        if (rejection == .loaded_tools_unreachable and
            reads.configuration.tools.state == .value and
            reads.configuration.loaded_tools.state == .omitted)
        {
            // An unreachable implicit intersection falls back to all allowed tools.
            return finishValidation(request, reads);
        }
        return .{ .rejected = rejection };
    }
    if (v.loaded.count == v.tools.count) return finishValidation(request, reads);
    if (request.session.len == 0 or reads.configuration.tools.state == .value) {
        reads.loaded_tools = tool_set.Selection.of(request.tools.host_tool_set, v.loaded) orelse return error.CorruptStore;
        tool_set.lookupSelection(a, &reads.loaded_tools.?);
        return .{ .round = .loaded };
    }
    request.saved.* = .{ .names = v.loaded };
    request.saved.queue(a, reads.next.tool_set_id);
    return .{ .round = .loaded_source };
}

fn savedNames(reads: *const ConfigurationReads) error{CorruptStore}!void {
    if (reads.step.validating.names.invalid) return error.CorruptStore;
}

fn readCreation(a: anytype, reads: *ConfigurationReads) void {
    a.read(creation_facts, .{ .digest = reads.workspace_digest, .workspace = reads.next.workspace.slice(), .session = &reads.reference }, &reads.creation);
}

pub fn targetRejection(session: []const u8) ?configuration_admission.Rejection {
    return if (session.len != 0 and !session_id.valid(session)) .invalid_session_reference else null;
}

pub const ValidatedConfiguration = struct {
    content_actions: @FieldType(ConfigurationUpdatePlan, "update"),
    before: ?Settings,
};

pub const Request = struct {
    io: std.Io,
    tools: *const store_core.HostTools,
    served: *const provider_route.Served,
    session: []const u8,
    configuration: *const content_custody.Configuration,
    initial_skills: ?*const skills_domain.Initial,
    saved: *tool_set.SavedSelection,
};

pub const ValidationRound = enum { model, saved_tools, saved_loaded, loaded_source, loaded };

pub const Validation = union(enum) {
    round: ValidationRound,
    rejected: configuration_admission.Rejection,
    ready: *const ValidatedConfiguration,
};

const Validating = struct {
    model: model_facts.Model,
    creation_provider: ?connection.Name,
    workspace_matches: ?bool,
    tools: *const command_input.ToolsField,
    loaded: *const command_input.ToolsField,
    names: NameSelection,
};

pub fn validateStep(a: anytype, request: *const Request, reads: *ConfigurationReads, ran: ?ValidationRound) !Validation {
    const at = ran orelse return validateRequest(a, request, reads);
    switch (at) {
        .model => return validateModel(a, request, reads),
        .saved_tools => {
            try savedNames(reads);
            reads.step.validating.tools = &reads.saved_tools;
            return loadedNames(a, request, reads);
        },
        .saved_loaded => {
            try savedNames(reads);
            reads.step.validating.loaded = &reads.saved_loaded;
            return selectLoaded(a, request, reads);
        },
        .loaded_source => {
            reads.loaded_tools = try request.saved.selection();
            tool_set.lookupSelection(a, &reads.loaded_tools.?);
            return .{ .round = .loaded };
        },
        .loaded => return finishValidation(request, reads),
    }
}

fn modelRejection(model: *const command_input.OptionalBounded(model_capability.max_model_bytes)) ?configuration_admission.Rejection {
    return switch (model.state) {
        .omitted => null,
        .explicit_null => .invalid_model,
        .value => if (model.value.len == 0) .invalid_model else null,
    };
}

test "a null or empty model is invalid and an omitted one is left to the missing-settings check" {
    const Model = command_input.OptionalBounded(model_capability.max_model_bytes);
    var model: Model = .{};
    try std.testing.expectEqual(@as(?configuration_admission.Rejection, null), modelRejection(&model));
    model.state = .explicit_null;
    try std.testing.expectEqual(configuration_admission.Rejection.invalid_model, modelRejection(&model).?);
    model.state = .value;
    try std.testing.expectEqual(configuration_admission.Rejection.invalid_model, modelRejection(&model).?);
    try model.value.set("model-a");
    try std.testing.expectEqual(@as(?configuration_admission.Rejection, null), modelRejection(&model));
}

const CreationCheck = union(enum) {
    missing: required_settings.Missing,
    unknown_connection,
    unserved_connection,
    complete: struct { provider: connection.Name },
};

/// The one creation check: every path that creates a Session (configure, a creating Message,
/// start_agent) reaches it after the parent is read, so the reply names every missing setting.
fn creationCheck(configuration: *const ConfigurationView, reads: *const ConfigurationReads, served: *const provider_route.Served) CreationCheck {
    const explicit: ?connection.Name = if (configuration.connection.state == .value)
        connection.Name.parse(configuration.connection.value.slice()) orelse return .unknown_connection
    else
        null;
    // Naming a connection the Host does not serve is refused; a default or inherited provider is not.
    if (explicit) |name| if (served.of(name.slice()) == null) return .unserved_connection;
    const named: ?connection.Name = if (reads.inherits_parent) reads.inherited.provider else explicit;
    return switch (required_settings.check(.{
        .model = configuration.model.state == .value,
        .workspace = configuration.workspace.state == .value,
        .parent = reads.inherits_parent,
        .provider = named,
        .served = served,
    })) {
        .missing => |missing| .{ .missing = missing },
        .complete => |complete| .{ .complete = .{ .provider = complete.provider } },
    };
}

fn validateRequest(a: anytype, request: *const Request, reads: *ConfigurationReads) !Validation {
    const session = request.session;
    const configuration = &reads.configuration;
    const creating = session.len == 0;
    if (targetRejection(session)) |code| return .{ .rejected = code };
    if (!creating and request.configuration.preferences != null) return .{ .rejected = .preferences_on_update };
    if (configuration.permission_mode.state == .value and
        std.meta.stringToEnum(cli_value.PermissionMode, configuration.permission_mode.value.slice()) == null)
    {
        return .{ .rejected = .unsupported_permission_mode };
    }
    if (modelRejection(configuration.model)) |rejection| return .{ .rejected = rejection };
    if (configuration.output_schema.state == .value) {
        const valid = if (configuration.output_schema.borrowedBytes()) |bytes|
            try model_settlement_domain.validateJsonBytes(bytes)
        else
            try model_settlement_domain.validateJsonFile(request.io, configuration.output_schema.file orelse return error.MissingContentCustody);
        if (!valid) return .{ .rejected = .invalid_output_schema };
    }

    if (reads.pair) |*rows| content_domain.foundPair(rows, reads.instructionsValue(request.configuration), &reads.output_schema);
    const next = &reads.next;
    if (!creating and !reads.found.get()) {
        return .{ .rejected = .unknown_session };
    }
    if (reads.found.get()) try checkSaved(next);
    if (!creating and configuration.parent.state != .omitted) return .{ .rejected = .parent_on_update };
    if (creating) if (try inheritParent(request.tools.host_tool_set, request.served, request.configuration, reads)) |code| return .{ .rejected = code };
    const creation_provider: ?connection.Name = if (creating) switch (creationCheck(configuration, reads, request.served)) {
        .missing => |missing| {
            reads.missing = missing;
            return .{ .rejected = .missing_settings };
        },
        .unknown_connection => return .{ .rejected = .unknown_connection },
        .unserved_connection => return .{ .rejected = .connection_unserved },
        .complete => |complete| complete.provider,
    } else null;
    reads.step = .{ .validating = undefined };
    const v = &reads.step.validating;
    v.creation_provider = creation_provider;
    v.model = .{};
    v.model.read(a, if (configuration.model.state == .value) configuration.model.value.slice() else next.model.slice());
    return .{ .round = .model };
}

fn validateModel(a: anytype, request: *const Request, reads: *ConfigurationReads) !Validation {
    const io = request.io;
    const configuration = &reads.configuration;
    const creating = request.session.len == 0;
    const v = &reads.step.validating;
    const next = &reads.next;
    const current_configuration: ?*const CurrentConfiguration = if (reads.found.get()) next else null;
    if (configuration.compaction_trigger.state == .value) _ = tokenCount(configuration.compaction_trigger.value.slice(), false) catch return .{ .rejected = .invalid_compaction_trigger };
    _ = configurationTokens(configuration.output_reservation, null, true) catch return .{ .rejected = .invalid_output_reservation };
    const provider = if (configuration.connection.state == .value)
        connection.Name.parse(configuration.connection.value.slice()) orelse return .{ .rejected = .unknown_connection }
    else if (current_configuration) |existing| existing.provider else v.creation_provider.?;
    const model = if (configuration.model.state == .value) configuration.model.value.slice() else next.model.slice();
    reads.defaults = configuration_defaults.resolve(v.model.facts(), .{
        .creating = creating,
        .parent = if (reads.inherits_parent) .{ .tools = reads.inherited.tools.slice(), .permission_mode = try permissionMode(reads.inherited.permission_mode) } else null,
        .provider = provider,
        .model = model,
        .can_read_images = @import("../../os/read_image_file.zig").available,
        .tools = configuration.tools,
        .loaded_tools = configuration.loaded_tools,
        .permission_mode = configuration.permission_mode,
        .reasoning_effort = configuration.reasoning_effort,
        .compaction_trigger = configuration.compaction_trigger,
        .preferences = preferences(request.configuration),
    });
    if (reads.defaults.parent_refusal) |failure| {
        reads.parent_failure = ParentFailure.from(failure);
        return .{ .rejected = reads.parent_failure.?.code };
    }
    reads.configuration.tools = reads.defaults.tools;
    reads.configuration.loaded_tools = reads.defaults.loaded_tools;
    reads.configuration.permission_mode = &reads.defaults.permission_mode;
    reads.configuration.reasoning_effort = &reads.defaults.reasoning_effort;
    reads.configuration.compaction_trigger = &reads.defaults.compaction_trigger;
    if (configurationBeforeWorkspace(v.model.facts(), request.tools.host_tool_set, request.served, current_configuration, configuration, v.creation_provider)) |rejection| {
        return .{ .rejected = rejection };
    }

    if (v.creation_provider) |provider_value| {
        next.provider = provider_value;
        // A Host serving no provider still creates a Session on the product default. Its codec is that
        // provider's built-in codec, which the Session keeps until a served connection of its name runs it.
        next.codec = if (request.served.of(provider_value.slice())) |entry| entry.codec else (if (provider_route.builtInOf(provider_value)) |built_in| built_in.codec() else return .{ .rejected = .connection_unserved });
    }
    v.workspace_matches = if (creating and reads.inherits_parent) inherited: {
        validateWorkspace(io, next.workspace.slice(), &next.workspace) catch return .{ .rejected = .invalid_workspace };
        reads.workspace_digest = store_core.workspaceDigest(next.workspace.slice());
        break :inherited null;
    } else if (configuration.workspace.state == .value) matches: {
        if (reads.found.get()) {
            break :matches sameWorkspace(io, configuration.workspace.value.slice(), next.workspace.slice()) catch {
                return .{ .rejected = .invalid_workspace };
            };
        }
        validateWorkspace(io, configuration.workspace.value.slice(), &next.workspace) catch return .{ .rejected = .invalid_workspace };
        reads.workspace_digest = store_core.workspaceDigest(next.workspace.slice());
        break :matches true;
    } else null;

    return loadedTools(a, request, reads);
}

fn finishValidation(request: *const Request, reads: *ConfigurationReads) Validation {
    const configuration = &reads.configuration;
    const next = &reads.next;
    const created = !reads.found.get();
    const current_configuration: ?*const CurrentConfiguration = if (reads.found.get()) next else null;
    reads.validated.before = if (created) null else .of(next);
    const content_actions = switch (planConfigurationUpdate(
        current_configuration,
        configuration,
        reads.step.validating.workspace_matches,
        next,
    )) {
        .rejected => |rejection| return .{ .rejected = rejection },
        .update => |actions| actions,
    };

    if (request.session.len == 0) if (request.initial_skills) |captured| if (captured.* == .unavailable) return .{ .rejected = .skills_unavailable };

    reads.validated.content_actions = content_actions;
    return .{ .ready = &reads.validated };
}

pub const ApplyRound = enum { creation, catalog };

pub const Applying = union(enum) {
    round: ApplyRound,
    accepted: *const Applied,
};

const ApplyState = struct {
    created_seq: u64,
    catalog: skills_domain.Appending,
};

pub fn applyStep(a: anytype, request: *const Request, faults: Faults, reads: *ConfigurationReads, ran: ?ApplyRound) !Applying {
    const at = ran orelse return applyContent(a, request, faults, reads);
    switch (at) {
        .creation => {
            if (reads.creation.taken) return drawReference(a, request.io, reads);
            return insertCreated(a, request, reads);
        },
        .catalog => {
            try reads.step.applying.catalog.finish(a, faults);
            return .{ .accepted = &reads.applied };
        },
    }
}

fn applyContent(a: anytype, request: *const Request, faults: Faults, reads: *ConfigurationReads) !Applying {
    const io = request.io;
    const session = request.session;
    const configuration = &reads.configuration;
    const creating = session.len == 0;
    const created = !reads.found.get();
    const next = &reads.next;
    const content_actions = reads.validated.content_actions;
    reads.step = .{ .applying = undefined };
    const applied = &reads.applied;
    applied.instructions_id = null;
    switch (content_actions.instructions) {
        .preserve => {},
        .import_requested => {
            applied.instructions_id = try content_domain.importSealed(a, io, configuration.instructions, &reads.instructions, faults);
            next.instructions_id = @intCast(applied.instructions_id.?);
        },
        .default_empty => next.instructions_id = @intCast(try content_domain.importBytes(a, &reads.empty, "")),
        .clear => next.instructions_id = null,
    }
    applied.output_schema_id = null;
    switch (content_actions.output_schema) {
        .preserve => {},
        .import_requested => {
            applied.output_schema_id = try content_domain.importSealed(a, io, configuration.output_schema, &reads.output_schema, faults);
            next.output_schema_id = @intCast(applied.output_schema_id.?);
        },
        .clear => next.output_schema_id = null,
    }
    if (creating or configuration.tools.state == .value) {
        const tools = &(reads.tools orelse return error.CorruptStore);
        next.tool_set_id = try tool_set.finishSelection(a, tools, request.tools.set_id);
    }
    if (reads.loaded_tools) |*loaded| {
        next.loaded_tool_set_id = try tool_set.finishSelection(a, loaded, next.tool_set_id);
    } else if (creating or configuration.loaded_tools.state == .value or configuration.tools.state == .value) {
        next.loaded_tool_set_id = null;
    }
    if (created) {
        std.debug.assert(next.revision == 1);
        reads.step.applying.created_seq = try a.identity(.created_seq);
        return drawReference(a, io, reads);
    }
    const head: rsql.SessionHead = .{ .ref = session[0..session_id.bytes].*, .workspace_key = .of(next.workspace_key), .next_position = .of(next.next_position) };
    a.write(update_session, .{
        .session = head,
        .model = next.model.slice(),
        .instructions_id = if (next.instructions_id) |id| @intCast(id) else null,
        .tool_set_id = next.tool_set_id,
        .loaded_tool_set_id = next.loaded_tool_set_id,
        .permission_mode = next.permission_mode,
        .output_schema_id = if (next.output_schema_id) |id| @intCast(id) else null,
        .revision = next.revision,
        .provider = next.provider,
        .compaction_trigger = next.compaction_trigger,
        .output_reservation = next.output_reservation,
        .reasoning_effort = next.reasoning_effort,
        .label = if (next.label) |*label| label.slice() else null,
    });
    try accept(reads, head, session);
    return .{ .accepted = applied };
}

fn drawReference(a: anytype, io: std.Io, reads: *ConfigurationReads) !Applying {
    try newReference(io, &reads.reference);
    readCreation(a, reads);
    return .{ .round = .creation };
}

fn insertCreated(a: anytype, request: *const Request, reads: *ConfigurationReads) !Applying {
    const created_seq = reads.step.applying.created_seq;
    const head: rsql.SessionHead = .{
        .ref = reads.reference,
        .workspace_key = if (reads.creation.workspace_key) |key| key else .of(created_seq),
        .next_position = .of(1),
    };
    const creator = if (reads.creator) |*reference| reference else null;
    insertSession(a, head, &reads.next, &reads.workspace_digest, created_seq, if (reads.attach_parent) creator else null, creator);
    try accept(reads, head, &reads.reference);
    if (try skills_domain.Appending.initial(head, request.initial_skills)) |appending| {
        reads.step.applying.catalog = appending;
        reads.step.applying.catalog.queue(a);
        return .{ .round = .catalog };
    }
    return .{ .accepted = &reads.applied };
}

fn accept(reads: *ConfigurationReads, head: rsql.SessionHead, target: []const u8) !void {
    const applied = &reads.applied;
    const created = !reads.found.get();
    applied.session = .{};
    try applied.session.set(target);
    applied.head = head;
    applied.revision = reads.next.revision;
    // Interim: a Session pins the codec of its first revision (its provider then). A later revision
    // carries the codec of the revision before it, so a switch of codec is a later unit.
    applied.codec = if (created) reads.next.codec else null;
    applied.instructions_updated = created or reads.configuration.instructions.state == .value;
    applied.changes = if (reads.validated.before) |*saved| saved.changed(&reads.next) else .empty;
}

pub fn servesProviderOf(served: anytype, configuration: ?*const content_custody.Configuration, saved: ?connection.Name) bool {
    const provider = if (configuration != null and configuration.?.connection.state == .value)
        connection.Name.parse(configuration.?.connection.value.slice()) orelse return true
    else
        saved orelse (if (configuration != null) required_settings.resolveProvider(null, served) orelse return true else return true);
    return served.route(provider.slice()) != .unserved;
}

pub noinline fn queueConfiguredCommand(
    a: anytype,
    applied: *const Applied,
    key: []const u8,
    kind: cli_value.CommandKind,
    digest: *const [32]u8,
    primary_content_id: ?u64,
    secondary_content_id: ?u64,
    answer: *const StoredAnswer,
) !void {
    try command_domain.queueCommand(a, key, kind, applied.session.slice(), digest, primary_content_id, secondary_content_id, answer);
    a.write(insert_revision, .{ .session = applied.head, .command_key = key, .instructions_updated = applied.instructions_updated, .effort_choice = applied.changes.contains(.model) or applied.changes.contains(.reasoning_effort), .codec = if (applied.codec) |codec| @tagName(codec) else null });
    if (applied.changes.count() == 0) return;
    const position = try (try a.positions(applied.head)).take(1);
    var fields = applied.changes.iterator();
    var ordinal: u64 = 0;
    while (fields.next()) |field| : (ordinal += 1) a.write(insert_change, .{
        .session = applied.head,
        .position = position,
        .ordinal = ordinal,
        .revision = applied.revision,
        .field = @tagName(field),
    });
}

const insert_change = rsql.Write(.{
    .sql = "INSERT INTO session_change(session_ref,position,ordinal,revision,field,changed_at) VALUES(@session(?1),?2,?3,?4,?5,@now)",
    .Args = struct { session: rsql.SessionHead, position: u64, ordinal: u64, revision: u64, field: []const u8 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

noinline fn sameWorkspace(io: std.Io, supplied: []const u8, existing: []const u8) !bool {
    var canonical: Bounded(workspace_path.max_bytes) = .{ .len = 0 };
    try validateWorkspace(io, supplied, &canonical);
    return canonical.eql(existing);
}

fn validateWorkspace(io: std.Io, supplied: []const u8, destination: *Bounded(workspace_path.max_bytes)) !void {
    if (!std.fs.path.isAbsolute(supplied)) return error.WorkspaceMustBeAbsolute;
    if (std.mem.indexOfScalar(u8, supplied, 0) != null) return error.InvalidWorkspace;
    var directory = try std.Io.Dir.cwd().openDir(io, supplied, .{});
    defer directory.close(io);
    destination.len = 0;
    const length = try directory.realPath(io, &destination.bytes);
    if (!std.unicode.utf8ValidateSlice(destination.bytes[0..length])) return error.InvalidUtf8;
    destination.len = length;
}

fn columnMentions(sql: []const u8, column: []const u8) usize {
    var tokens = std.mem.tokenizeAny(u8, sql, " (),=\n\t");
    var count: usize = 0;
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, column)) count += 1;
    }
    return count;
}

test "Session settings cover every hand-written Store SQL and schema projection" {
    const schema = @import("../schema.zig");
    var buffer: [16 * 1024]u8 = undefined;
    var missing: std.Io.Writer = .fixed(&buffer);
    inline for (session_settings.entries) |entry| {
        inline for (.{ "session", "session_revision" }) |table_name| {
            var found = false;
            for (schema.tables) |table| {
                if (!std.mem.eql(u8, table.name, table_name)) continue;
                for (table.columns) |column| {
                    if (std.mem.eql(u8, column.name, entry.column)) found = true;
                }
            }
            if (!found) try missing.print("{s}: schema.{s}.{s}\n", .{ entry.field, table_name, entry.column });
        }
        inline for (.{
            .{ "saved_session", saved_session.sql, @as(usize, 1) },
            .{ "insert_session", insert_session.sql, @as(usize, 1) },
            .{ "insert_revision (INSERT and SELECT)", insert_revision.sql, @as(usize, 2) },
        }) |site| {
            if (columnMentions(site[1], entry.column) < site[2])
                try missing.print("{s}: {s}.{s}\n", .{ entry.field, site[0], entry.column });
        }
        if (comptime !std.mem.eql(u8, entry.field, "workspace")) {
            if (columnMentions(update_session.sql, entry.column) == 0)
                try missing.print("{s}: update_session.{s}\n", .{ entry.field, entry.column });
        }
        if (comptime !@hasField(CurrentConfiguration, settingsField(entry)))
            try missing.print("{s}: CurrentConfiguration.{s}\n", .{ entry.field, settingsField(entry) });
    }
    try std.testing.expectEqualStrings("", missing.buffered());
}

test "Session settings changed detects each mutable value without comparing bounded tails" {
    var current: CurrentConfiguration = .{ .provider = connection.Name.parse("openai").?, .tool_set_id = 1 };
    try current.model.set("gpt-5");
    current.label = .{};
    try current.label.?.set("label");
    const before = Settings.of(&current);
    inline for (.{
        session_settings.SessionField.model,
        session_settings.SessionField.instructions,
        session_settings.SessionField.tools,
        session_settings.SessionField.loaded_tools,
        session_settings.SessionField.permission_mode,
        session_settings.SessionField.output_schema,
        session_settings.SessionField.compaction_trigger,
        session_settings.SessionField.output_reservation,
        session_settings.SessionField.reasoning_effort,
        session_settings.SessionField.label,
    }) |field| {
        var next = current;
        switch (field) {
            .model => try next.model.set("gpt-5.5"),
            .instructions => next.instructions_id = 1,
            .tools => next.tool_set_id = 2,
            .loaded_tools => next.loaded_tool_set_id = 1,
            .permission_mode => next.permission_mode = 1,
            .output_schema => next.output_schema_id = 2,
            .compaction_trigger => next.compaction_trigger = 1000,
            .output_reservation => next.output_reservation = 10,
            .reasoning_effort => next.reasoning_effort = .high,
            .label => try next.label.?.set("renamed"),
            else => unreachable,
        }
        const changed = before.changed(&next);
        try std.testing.expectEqual(@as(usize, 1), changed.count());
        try std.testing.expect(changed.contains(field));
    }
    current.label.?.bytes[current.label.?.len] = 123;
    try std.testing.expectEqual(@as(usize, 0), before.changed(&current).count());
}
