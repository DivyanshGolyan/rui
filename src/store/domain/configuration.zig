//! Session configuration: creating a Session, applying or rejecting a
//! configuration update, and reading a Session's saved settings.

const std = @import("std");
const operation_effort = @import("operation_effort.zig");
const session_settings = @import("../../session_settings.zig");
const command_reply = @import("../../command_reply.zig");
const command_input = @import("../../command_input.zig");
const session_field = @import("../../session_field.zig");
const configuration_admission = @import("../../configuration_admission.zig");
const workspace_path = @import("../../workspace_path.zig");
const provider_route = @import("../../provider_route.zig");
const tool_presentation = @import("../../tool_presentation.zig");
const tool_name = @import("../../tool_name.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const cli_value = @import("../../cli_value.zig");
const provider_name = @import("../../provider_name.zig");
const session_id = @import("../../session_id.zig");
const content_custody = @import("../../content_custody.zig");
const model_catalog = @import("../../model_catalog.zig");
const model_facts = @import("model_facts.zig");
const model_capability = @import("../../model_capability.zig");
const product_defaults = @import("../../product_defaults.zig");
const tool_defs = @import("../../tool_record.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
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

/// Host-only preset resolution, carried through the ordinary configure
/// transaction. The request digest is of the original, unresolved command.
pub const PresetDecision = struct {
    request_digest: [32]u8,
    rejection: ?Rejection = null,

    pub const Rejection = enum { unknown_preset, preset_on_update };
};

pub const ConfigureReply = command_reply.ConfigureReply;

/// D104: the spec alone selects tools; an empty list selects none.
fn requestedNames(requested: *const content_custody.Configuration) *const command_input.ToolsField {
    return &requested.tools;
}

fn requestsBash(requested: *const content_custody.Configuration) bool {
    var names = requested.tools.iterator();
    while (names.next()) |name| if (std.mem.eql(u8, name, "bash")) return true;
    return false;
}

/// D133: an omitted provider selects the Host's single served provider.
/// A Host serving several has no default (D221), so a creation must name
/// one. An idle Host keeps the product's, which its unserved check refuses.
fn defaultProvider(routes: provider_route.Routes) ?provider_name.Provider {
    var selected: ?provider_name.Provider = null;
    inline for (std.enums.values(provider_name.Provider)) |provider| {
        if (provider_route.of(routes, provider) != .unserved) {
            if (selected != null) return null;
            selected = provider;
        }
    }
    return selected orelse std.meta.stringToEnum(provider_name.Provider, product_defaults.provider).?;
}

/// Why `tools` cannot be saved for a Session of `provider`: a name the
/// Host tool set lacks, or a tool some provider runs that `provider`
/// does not.
fn toolsRejection(host_tool_set: *const tool_defs.HostToolSet, provider: provider_name.Provider, tools: *const command_input.ToolsField) ?configuration_admission.Rejection {
    var names = tools.iterator();
    while (names.next()) |name| {
        const index = switch (host_tool_set.resolve(name)) {
            .found => |index| index,
            .unknown_tool => return .unknown_tool,
            .mcp_server_unavailable => return .mcp_server_unavailable,
        };
        if (host_tool_set.records[index].owner == .provider and !provider.runsTool(name)) return .provider_tool_missing;
    }
    return null;
}

/// Rejection codes are durable; this advisory detail describes the current
/// Host's launch-only MCP configuration, also on replay. No Store read is needed.
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

/// Persisted session.permission_mode for a validated mode name.
fn permissionModeCode(mode: []const u8) u8 {
    return if (std.mem.eql(u8, mode, "ask")) 0 else 1;
}

/// Decodes a persisted permission_mode: 0 asks, 1 bypasses, and any other
/// value is `CorruptStore`.
pub fn permissionMode(code: u8) error{CorruptStore}!cli_value.PermissionMode {
    return switch (code) {
        0 => .ask,
        1 => .bypass,
        else => error.CorruptStore,
    };
}

/// Refuses a persisted label that `tool_presentation.validLabel` does not accept.
pub fn checkLabel(label: []const u8) error{CorruptStore}!void {
    if (!tool_presentation.validLabel(label)) return error.CorruptStore;
}

/// A Session's saved configuration. Its fields name, in order, the columns
/// `saved_session` reads, so a read decodes into it in place.
pub const CurrentConfiguration = struct {
    workspace: Bounded(workspace_path.max_bytes) = .{},
    provider: provider_name.Provider = undefined,
    model: Bounded(model_capability.max_model_bytes) = .{},
    instructions_id: ?i64 = null,
    /// Configured name intent; 0 until a creation saves its first.
    tool_set_id: u64 = 0,
    /// Loaded name intent. Null means every configured name.
    loaded_tool_set_id: ?u64 = null,
    permission_mode: u8 = 0,
    output_schema_id: ?i64 = null,
    revision: u64 = 0,
    next_position: u64 = 1,
    compaction_trigger: ?u64 = null,
    output_reservation: ?u64 = null,
    reasoning_effort: ?model_capability.ReasoningEffort = null,
    label: ?Bounded(tool_presentation.max_label_bytes) = null,
    /// Read only: the Store dates a Session when it inserts it.
    created_at: u64 = 0,
    /// Read only: the change ring's key for the Session's Workspace.
    workspace_key: u64 = 0,
    /// Read only: the creator of an attached agent; absent for other Sessions.
    parent_ref: ?Bounded(session_id.bytes) = null,
    /// Read only: the latest Operation's frozen effort, for pre-D111 null specs.
    previous_reasoning_effort: ?model_capability.ReasoningEffort = null,
};

/// The Session columns turn work, settlement and page cursors read, without
/// the 4 KB workspace a whole CurrentConfiguration carries.
pub const SessionFacts = struct {
    provider: provider_name.Provider,
    model: Bounded(model_capability.max_model_bytes) = .{},
    permission_mode: u8,
    revision: u64,
    next_position: u64,
    compaction_trigger: ?u64 = null,
    output_reservation: ?u64 = null,
    reasoning_effort: ?model_capability.ReasoningEffort = null,
    created_at: u64,
};

pub const RevisionContentField = enum(c_int) {
    instructions = 0,
    output_schema = 1,
};

pub const ConfigurationContentAction = enum(u2) {
    preserve,
    import_requested,
    default_empty,
    clear,
};

/// A created Session has no output schema by default, so the schema's
/// plan never imports empty content.
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

fn configurationTokens(field: @TypeOf(@as(content_custody.Configuration, .{}).compaction_trigger), previous: ?u64, allow_zero: bool) !?u64 {
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
    current: ?*const CurrentConfiguration,
    requested: *const content_custody.Configuration,
    default_provider: ?provider_name.Provider,
) ?configuration_admission.Rejection {
    if (requested.compaction_trigger.state == .explicit_null) return .invalid_compaction_trigger;
    const compact_at = if (requested.compaction_trigger.state == .value)
        tokenCount(requested.compaction_trigger.value.slice(), false) catch return .invalid_compaction_trigger
    else if (current) |existing|
        existing.compaction_trigger
    else
        null;
    _ = configurationTokens(requested.output_reservation, null, true) catch return .invalid_output_reservation;
    const provider = if (requested.provider.state == .value)
        std.meta.stringToEnum(provider_name.Provider, requested.provider.value.slice()) orelse return .unsupported_provider
    else
        null;
    // D104/D111/D113: callers of the domain must supply the same complete
    // creation spec that the wire parser requires.
    if (current == null and
        (requested.model.state != .value or requested.reasoning_effort.state == .omitted or
            requested.compaction_trigger.state != .value or requested.tools.state != .value or
            requested.permission_mode.state != .value or (requestsBash(requested) and requested.workspace.state != .value and requested.parent.state == .omitted) or
            (provider == null and default_provider == null)))
    {
        return .incomplete_initial_configuration;
    }
    if (current) |existing| {
        if (provider) |value| {
            if (value != existing.provider) return .provider_is_immutable;
        }
    }
    if (requested.label.state == .value and !tool_presentation.validLabel(requested.label.value.slice())) return .invalid_label;
    if (requested.tools.state == .value) if (toolsRejection(host_tool_set, provider orelse (if (current) |existing| existing.provider else default_provider.?), &requested.tools)) |rejection| return rejection;
    const model = if (requested.model.state == .value) requested.model.value.slice() else current.?.model.slice();
    // D166: an unlisted model has no known window to enforce.
    if (compact_at) |tokens| if (model_catalog.find(selected_facts, model)) |known| {
        if (known.context_window) |window| if (tokens > window) return .compact_at_too_large;
    };
    if (compact_at) |tokens| if (tokens > std.math.maxInt(i64)) return .invalid_compaction_trigger;
    // Resolve the settings once: omission retains the effective historical
    // effort, while a supplied value (including null) overrides it. Validate
    // that result even when only the model, or neither setting, was supplied.
    const retained_effort = if (current) |existing| effectiveReasoningEffort(existing) else null;
    const effort = switch (requested.reasoning_effort.state) {
        .omitted => retained_effort,
        .explicit_null => null,
        .value => std.meta.stringToEnum(model_capability.ReasoningEffort, requested.reasoning_effort.value.slice()) orelse
            return .unsupported_reasoning_effort,
    };
    // The codec cannot encode a boundary back to unspecified effort.
    if (requested.reasoning_effort.state == .explicit_null and retained_effort != null) return .unsupported_reasoning_effort;
    if (!model_capability.supportsReasoningEffort(selected_facts, model, effort)) return .unsupported_reasoning_effort;
    return null;
}

/// D111/D209: an explicit spec wins. A pre-D111 null spec carries forward
/// its last Operation's frozen effort, never a catalog or product default.
/// With no earlier concrete effort, null still means unspecified.
pub fn effectiveReasoningEffort(current: anytype) ?model_capability.ReasoningEffort {
    return current.reasoning_effort orelse current.previous_reasoning_effort;
}

/// Configure owns intent identity. The immutable revision freezes its source;
/// admission copies it, and later refusals cannot reinterpret older choices.
pub fn effortChoiceRevisionSql(comptime revision: []const u8) []const u8 {
    return "(SELECT intent.effort_source_revision FROM session_revision intent WHERE intent.session_ref=" ++ revision ++ ".session_ref AND intent.revision=" ++ revision ++ ".revision)";
}

fn hasEffortRefusalSql(comptime revision: []const u8) []const u8 {
    return "EXISTS(SELECT 1 FROM session_change refusal WHERE refusal.session_ref=" ++ revision ++ ".session_ref AND refusal.field='reasoning_effort_refused' AND refusal.revision<=" ++ revision ++ ".revision)";
}

/// A refused intent maps to the refusing Operation's own admitted fallback,
/// including null. Never search intervening, possibly unadmitted choices.
pub fn reasoningEffortOverrideSql(comptime revision: []const u8) []const u8 {
    // Before any refusal, snapshots already carry the nullable override.
    // Keep ordinary reports on their existing bounded-work path.
    return "CASE WHEN " ++ hasEffortRefusalSql(revision) ++ " THEN " ++ operation_effort.sourceOverrideSql(revision ++ ".session_ref", effortChoiceRevisionSql(revision)) ++ " ELSE " ++ revision ++ ".reasoning_effort END";
}

/// Legacy null specs carry the latest Operation's effective admitted value.
/// Its refusal is keyed to that Operation, not inferred from a later revision.
pub fn previousReasoningEffortSql(comptime revision: []const u8) []const u8 {
    return "CASE WHEN " ++ revision ++ ".reasoning_effort IS NULL OR " ++ hasEffortRefusalSql(revision) ++ " THEN (SELECT " ++ operation_effort.effectiveSql("legacy") ++ " FROM model_operation legacy @index(model_operation_admission) WHERE legacy.session_ref=" ++ revision ++ ".session_ref AND legacy.settings_revision<=" ++ revision ++ ".revision ORDER BY legacy.admission_position DESC LIMIT 1) END";
}

/// `next` holds the current configuration's values, or the defaults when
/// there is none, and may be `current` itself: each field of `current` is
/// read before `next`'s same field is written. A requested workspace is
/// canonicalized by the caller, which answers `workspace_matches` (whether
/// it is the current Session's) and has already written a created
/// Session's into `next`.
pub fn planConfigurationUpdate(
    current: ?*const CurrentConfiguration,
    requested: *const content_custody.Configuration,
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

    if (requested.provider.state == .value) next.provider = std.meta.stringToEnum(provider_name.Provider, requested.provider.value.slice()).?;
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

/// Round 1 reads the command's saved answer, the Session's saved
/// configuration and the content lookups its instructions and output
/// schema need. A creation then reads its Workspace's key and whether its
/// drawn reference is taken, which depends on the replay check: a replay
/// draws no reference and canonicalizes no Workspace. Each new sealed
/// import steps its insert in process before streaming into it, in the
/// write round (`importSealed`). The
/// decision is `applyConfiguration`; the write round saves the Session,
/// the command and its revision, then commits.
pub fn configure(a: anytype, io: std.Io, served: anytype, request: *const content_custody.ConfigureCommand, preset: ?*const PresetDecision, initial_skills: ?*const skills_domain.Initial, reload_capture: ?*const skills_domain.Capture, allocator: std.mem.Allocator, committed: ?Store.CreationCommitted, faults: Faults) !ConfigureReply {
    // The captured creation intent has no ID. Save its original digest
    // alongside the allocated target so a lost reply never creates twice.
    const command = request;
    const creating = request.session.len == 0;
    const reads = a.store.configurationReads();
    reads.* = .{ .next = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } } };
    const saved = &reads.saved_command;
    command_domain.lookupCommand(a, command.key.slice(), saved);
    prepareConfiguration(a, a.store.hostTools().host_tool_set, command.session.slice(), &command.configuration, reads);
    try a.run();

    configureDigest(command, preset, saved, &reads.command_digest);
    const digest = &reads.command_digest;
    if (saved.* != null) try a.abandon(.{});
    switch (try command_domain.classify(configuration_admission.Rejection, saved, .configure, command.session.slice(), digest)) {
        .fresh => {},
        .conflict => return .conflict,
        .accepted => |existing| return .{ .accepted = .{
            .replayed = true,
            .revision = existing.revision,
            .created = existing.created,
            .skills = if (command.reload_skills) (if (existing.code.eql("skills_reloaded")) .reloaded else if (existing.code.eql("skills_unchanged")) .unchanged else return error.CorruptStore) else null,
            .session = existing.target,
        } },
        .rejected => |code| return .{ .rejected = .{ .replayed = true, .code = code } },
    }

    if (preset) |decision| if (decision.rejection) |code| switch (code) {
        inline else => |tag| return saveConfigurationRejection(a, command, digest, @field(configuration_admission.Rejection, @tagName(tag)), faults),
    };
    if (command.require_model and !servesProviderOf(served, &command.configuration, if (reads.found.get()) reads.next.provider else if (reads.inherits_parent and reads.parent_found.get()) reads.inherited.provider else null)) {
        return saveConfigurationRejection(a, command, digest, .model_capability_unavailable, faults);
    }
    if (command.reload_skills) return reloadSkills(a, command, creating, reads, reload_capture, allocator, digest, faults);
    const applied = switch (try applyConfiguration(a, io, command.session.slice(), &command.configuration, initial_skills, faults, reads)) {
        .rejected => |code| return saveConfigurationRejection(a, command, digest, code, faults),
        .accepted => |value| value,
    };
    reads.command_answer = .{ .accepted = true, .revision = applied.revision, .created = creating };
    try queueConfiguredCommand(a, &applied, command.key.slice(), .configure, digest, applied.instructions_id, applied.output_schema_id, &reads.command_answer);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    if (creating) if (committed) |callback| store_core.created(a.store, callback, applied.session.slice());
    return .{ .accepted = .{ .replayed = false, .revision = applied.revision, .created = creating, .session = applied.session } };
}

// Native reload has its own atomic result/catalog settlement and scratch.
// Keep this rare branch off ordinary Configure's deeper content-import chain.
noinline fn reloadSkills(a: anytype, command: *const content_custody.ConfigureCommand, creating: bool, reads: *const ConfigurationReads, reload_capture: ?*const skills_domain.Capture, allocator: std.mem.Allocator, digest: *const [32]u8, faults: Faults) !ConfigureReply {
    if (targetRejection(command.session.slice())) |code| return saveConfigurationRejection(a, command, digest, code, faults);
    if (creating or !reads.found.get()) return saveConfigurationRejection(a, command, digest, .unknown_session, faults);
    var invalid = command.preset != null or command.require_model;
    inline for (@typeInfo(content_custody.Configuration).@"struct".field_names) |field| {
        if (@field(command.configuration, field).state != .omitted) invalid = true;
    }
    if (invalid) return saveConfigurationRejection(a, command, digest, .incomplete_initial_configuration, faults);
    const captured = reload_capture orelse return saveConfigurationRejection(a, command, digest, .skills_unavailable, faults);
    if (captured.* == .failed) return saveConfigurationRejectionWithFailure(a, command, digest, captured.failed.configurationRejection(), captured.failed, faults);
    if (captured.* != .reload) return saveConfigurationRejection(a, command, digest, .skills_unavailable, faults);
    var memory: std.heap.ArenaAllocator = .init(allocator);
    defer memory.deinit();
    const head: rsql.SessionHead = .{ .ref = command.session.slice()[0..session_id.bytes].*, .workspace_key = .of(reads.next.workspace_key), .next_position = .of(reads.next.next_position) };
    const result = try skills_domain.apply(a, memory.allocator(), head, captured, faults);
    var outcome: content_domain.Import = .ofBytes(result.bytes, false);
    content_domain.lookup(a, &outcome);
    try a.run();
    const outcome_id = try content_domain.importBytes(a, &outcome, result.bytes);
    const status = result.reload_status orelse return error.CorruptStore;
    var answer: StoredAnswer = .{ .accepted = true, .revision = reads.next.revision };
    try answer.code.set(if (status == .unchanged) "skills_unchanged" else "skills_reloaded");
    try command_domain.queueCommand(a, command.key.slice(), .configure, command.session.slice(), digest, outcome_id, null, &answer);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    return .{ .accepted = .{ .replayed = false, .revision = reads.next.revision, .created = false, .session = command.session, .skills = status } };
}

// A saved preset refusal keeps its original request identity, even when
// this Host can now resolve it. All other answers bind the resolved spec.
// noinline: preset resolution and hashing finish before applyConfiguration,
// keeping their scratch off the engine thread's deepest chain.
noinline fn configureDigest(
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

/// Settings `applyConfiguration` wrote to a Session, whose revision row
/// `queueConfiguredCommand` records with the command.
pub const Applied = struct {
    session: Bounded(session_id.max_reference_bytes),
    head: rsql.SessionHead,
    revision: u64,
    instructions_id: ?u64,
    output_schema_id: ?u64,
    instructions_updated: bool,
    /// The settings this revision changed; empty for a creation.
    changes: std.EnumSet(session_field.SessionField) = .empty,
};

/// The settings a revision can change, as `next` holds them before and
/// after it applies (the Workspace never changes).
const Settings = struct {
    provider: provider_name.Provider,
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

    /// Each field whose value differs, by its name in `SessionField`.
    fn changed(before: *const Settings, after: *const CurrentConfiguration) std.EnumSet(session_field.SessionField) {
        var fields: std.EnumSet(session_field.SessionField) = .empty;
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
                fields.setPresent(@field(session_field.SessionField, entry.field), !same);
            }
        }
        return fields;
    }
};

/// SQL names tools by set id; imported content uses a shorter id in reads.
fn settingsField(comptime entry: session_settings.Entry) []const u8 {
    return switch (entry.kind) {
        .content => entry.field ++ "_id",
        else => entry.column,
    };
}

pub const Application = union(enum) {
    accepted: Applied,
    rejected: configuration_admission.Rejection,
};

/// Skills discovery already asks whether this key exists. Fold its inherited
/// Workspace into that same read, rather than adding a parent preflight round.
pub const creation_hint = rsql.Read(.{
    .sql = "SELECT EXISTS(SELECT 1 FROM core_command WHERE command_key=?1) AS replay,coalesce((SELECT workspace FROM session WHERE session_ref=?2),'/') AS workspace",
    .Args = struct { key: []const u8, parent: []const u8 },
    .Row = struct { replay: bool, workspace: *Bounded(workspace_path.max_bytes) },
    .cardinality = .optional,
});

/// Parent inheritance has one admission owner for start_agent and native create.
/// Its ceiling is configured intent, not loaded intent or an Operation offer;
/// the ordinary configuration validation still checks Host tool set availability.
const parent_settings = rsql.Read(.{
    .sql = "SELECT workspace,provider,coalesce(" ++ tool_set.namesSql("session.tool_set_id") ++ ",'') AS tools,permission_mode FROM session WHERE session_ref=?1 " ++
        "AND NOT EXISTS(SELECT 1 FROM session_archive archived WHERE archived.session_ref=session.session_ref AND archived.command_key IS NOT NULL)",
    .Args = struct { session: []const u8 },
    .Row = struct { workspace: *Bounded(workspace_path.max_bytes), provider: provider_name.Provider, tools: *Bounded(tool_set.max_names_bytes), permission_mode: u8 },
    .cardinality = .optional,
});

pub const ParentFailure = struct {
    code: configuration_admission.Rejection,
    tool: ?[]const u8 = null,

    /// Same diagnostic at both doors; only the final effect differs.
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

/// Consumes the parent read from the existing first round, without a query or
/// a second path-sized configuration. Nothing is silently intersected.
pub fn inheritParent(host_tool_set: *const tool_defs.HostToolSet, configuration: *const content_custody.Configuration, reads: *ConfigurationReads) !?configuration_admission.Rejection {
    if (!reads.inherits_parent) return null;
    if (!reads.parent_found.get()) return .unknown_session;
    if (reads.parent_checked) return if (reads.parent_failure) |failure| failure.code else null;
    const failure: ?ParentFailure = refusal: {
        if (configuration.workspace.state != .omitted) break :refusal .{ .code = .parent_workspace_forbidden };
        if (configuration.provider.state != .omitted) break :refusal .{ .code = .parent_provider_forbidden };
        // Missing tool names keep the same refusal at both child doors,
        // before narrowing known tools against the parent's saved selection.
        if (toolsRejection(host_tool_set, reads.inherited.provider, &configuration.tools)) |code| return code;
        var requested = configuration.tools.iterator();
        while (requested.next()) |name| {
            var allowed = std.mem.splitScalar(u8, reads.inherited.tools.slice(), ',');
            while (allowed.next()) |member| {
                if (std.mem.eql(u8, name, member)) break;
            } else break :refusal .{ .code = .tools_not_in_parent, .tool = name };
        }
        if (try permissionMode(reads.inherited.permission_mode) == .ask and
            configuration.permission_mode.state == .value and !configuration.permission_mode.value.eql("ask"))
            break :refusal .{ .code = .permission_mode_wider_than_parent };
        break :refusal null;
    };
    reads.parent_checked = true;
    reads.parent_failure = failure;
    if (failure) |refused| return refused.code;
    reads.next.provider = reads.inherited.provider;
    reads.workspace_digest = store_core.workspaceDigest(reads.next.workspace.slice());
    if (reads.attach_parent) reads.parent = configuration.parent.value.slice()[0..session_id.bytes].*;
    return null;
}

/// What `prepareConfiguration` reads in a round, and where the round
/// leaves it; its owner keeps it until the transaction ends. Declared with
/// a literal that names `next`'s big fields' lengths, so their bytes stay
/// unwritten.
pub const ConfigurationReads = struct {
    /// Configure's saved command and answer live with its other reads until
    /// settlement; creating Messages leave these unused fields unwritten.
    saved_command: command_domain.saved_command.Result = undefined,
    command_digest: [32]u8 = undefined,
    command_answer: StoredAnswer = undefined,
    /// Creating Message reads share this owner's lifetime; Configure leaves
    /// the unused slot unwritten, and plain Messages use no creation scratch.
    message: command_domain.MessageReads = undefined,
    /// The Session's saved configuration, which the plan then updates in
    /// place: one 4.6 KB value, not a copy of it.
    next: CurrentConfiguration,
    /// The validation-only phase and application borrow this same plan until
    /// settlement; keep its saved Settings off the Host's import call chain.
    validated: ValidatedConfiguration = undefined,
    /// What validation, then application, keeps between its rounds
    /// (`validateStep`, `applyStep`): one storage, as validation ends
    /// before application starts.
    step: union { validating: Validating, applying: ApplyState } = undefined,
    /// What application answers.
    applied: Applied = undefined,
    /// Whether the Session exists: `.missing` for a creation, which reads none.
    found: store_access.Found = .missing,
    reference: [session_id.bytes]u8 = undefined,
    workspace_digest: [32]u8 = undefined,
    creation: creation_facts.Result = undefined,
    instructions: content_domain.Import = undefined,
    output_schema: content_domain.Import = undefined,
    empty: content_domain.Import = content_domain.empty_content,
    /// The rows `lookupPair` found, when round 1 needed two lookups.
    pair: ?content_domain.Pair = null,
    /// The tool set a creation or a `tools` change saves, when it does;
    /// null too when the Host tool set lacks a name, which the configure refuses.
    tools: ?tool_set.Selection = null,
    loaded_tools: ?tool_set.Selection = null,
    /// Saved names for narrowing an existing loaded subset. A child creation
    /// instead borrows saved_tools.names for its caller's configured names,
    /// consumed before applying its configuration; creations never read the
    /// saved tools here. Keep these in Store scratch, not a frame.
    saved_tools: command_input.ToolsField = undefined,
    saved_loaded: command_input.ToolsField = undefined,
    /// The Session a creation starts as the child of, when it has one.
    parent: ?[session_id.bytes]u8 = null,
    inherits_parent: bool = false,
    attach_parent: bool = true,
    inherited: parent_settings.Row = undefined,
    parent_found: store_access.Found = .missing,
    parent_checked: bool = false,
    parent_failure: ?ParentFailure = null,

    /// The value the instructions import through: the requested content,
    /// or the empty default a creation imports.
    fn instructionsValue(reads: *ConfigurationReads, configuration: *const content_custody.Configuration) *content_domain.Import {
        return if (configuration.instructions.state == .value) &reads.instructions else &reads.empty;
    }
};

/// A Session's saved configuration, decoded into a CurrentConfiguration in
/// place; `checkSaved` holds it to its types.
const saved_session = rsql.Read(.{
    .sql = "SELECT workspace,provider,model,instructions_content_id AS instructions_id,tool_set_id,loaded_tool_set_id,permission_mode," ++
        "output_schema_content_id AS output_schema_id,revision,next_position,compaction_trigger,output_reservation," ++
        reasoningEffortOverrideSql("session") ++ " AS reasoning_effort,label,created_at,workspace_key,parent_ref," ++ previousReasoningEffortSql("session") ++ " AS previous_reasoning_effort FROM session WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = CurrentConfiguration,
    .cardinality = .optional,
});

/// Where a new Session would go: the key of another Session's same
/// Workspace, when there is one, and whether its new reference is taken.
const creation_facts = rsql.Read(.{
    .sql = "SELECT (SELECT workspace_key FROM session WHERE workspace_digest=?1 AND workspace=?2 LIMIT 1) AS workspace_key," ++
        "EXISTS(SELECT 1 FROM session WHERE session_ref=?3) AS taken",
    .Args = struct { digest: [32]u8, workspace: []const u8, session: []const u8 },
    .Row = struct { workspace_key: ?rsql.Positive, taken: bool },
    .cardinality = .one,
});

/// A new Session starts at revision 1 and position 1. A Workspace's key is
/// the `created_seq` of its first Session.
const insert_session = rsql.Write(.{
    .sql = "INSERT INTO session(session_ref,workspace,model,instructions_content_id,tool_set_id,permission_mode,output_schema_content_id,revision,next_position," ++
        "provider,compaction_trigger,output_reservation,reasoning_effort,label,codec,workspace_digest,created_at,created_seq,workspace_key,parent_ref,loaded_tool_set_id) " ++
        "VALUES(@session(?1),?2,?3,?4,?5,?6,?7,1,1,?8,?9,?10,?11,?12,?13,?14,@now,?15,?16,?17,?18)",
    .Args = struct {
        session: rsql.SessionHead,
        workspace: []const u8,
        model: []const u8,
        instructions_id: ?u64,
        tool_set_id: u64,
        permission_mode: u8,
        output_schema_id: ?u64,
        provider: provider_name.Provider,
        compaction_trigger: ?u64,
        output_reservation: ?u64,
        reasoning_effort: ?model_capability.ReasoningEffort,
        label: ?[]const u8,
        codec: []const u8,
        digest: [32]u8,
        created_seq: u64,
        workspace_key: u64,
        parent: ?Bounded(session_id.bytes),
        loaded_tool_set_id: ?u64,
    },
    // Its round read the reference free, under the single writer.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Queues inserting the created Session `head` with the settings `next`,
/// as the child of `parent` when one is named. `configure` calls it, and a
/// test drives it with references the schema refuses.
pub fn insertSession(a: anytype, head: rsql.SessionHead, next: *const CurrentConfiguration, workspace_digest: *const [32]u8, created_seq: u64, parent: ?*const [session_id.bytes]u8) void {
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
        .codec = @tagName(next.provider.codec()),
        .digest = workspace_digest.*,
        .created_seq = created_seq,
        .workspace_key = head.workspace_key.get(),
        .parent = parent_ref,
        .loaded_tool_set_id = next.loaded_tool_set_id,
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
        provider: provider_name.Provider,
        compaction_trigger: ?u64,
        output_reservation: ?u64,
        reasoning_effort: ?model_capability.ReasoningEffort,
        label: ?[]const u8,
        loaded_tool_set_id: ?u64,
    },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.SessionUpdateFailed } },
});

/// The UPDATE a configure of an existing Session runs once it has touched
/// that Session, which a test faults.
pub const update_session_sql = update_session.sql;

/// The one writer of session_revision: it copies the Session row as
/// written under `command_key`, which an earlier write of the round saved.
const insert_revision = rsql.Write(.{
    .sql = "INSERT INTO session_revision(session_ref,revision,command_key,workspace,model,instructions_content_id,instructions_updated,tool_set_id,loaded_tool_set_id," ++
        "permission_mode,output_schema_content_id,provider,compaction_trigger,output_reservation,reasoning_effort,label,effort_source_revision) " ++
        "SELECT session_ref,revision,?2,workspace,model,instructions_content_id,?3,tool_set_id,loaded_tool_set_id,permission_mode,output_schema_content_id,provider," ++
        "compaction_trigger,output_reservation,reasoning_effort,label,CASE WHEN revision=1 OR ?4 THEN revision ELSE (SELECT prior.effort_source_revision FROM session_revision prior WHERE prior.session_ref=session.session_ref AND prior.revision=session.revision-1) END FROM session WHERE session_ref=@session(?1)",
    .Args = struct { session: rsql.SessionHead, command_key: []const u8, instructions_updated: bool, effort_choice: bool },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Queues reading `session_ref`'s saved configuration into `current` in
/// place; `found` says whether it exists. A missing one leaves `current`
/// as the caller declared it, which `configure` declares with
/// `CurrentConfiguration`'s field defaults: the settings a creation
/// starts from.
/// `checkSaved` follows the round.
pub fn readSaved(a: anytype, session_ref: []const u8, current: *CurrentConfiguration, found: *store_access.Found) void {
    a.readInto(saved_session, .{ .session = session_ref }, current, found);
}

/// Refuses a saved configuration that breaks what its columns may hold.
pub fn checkSaved(current: *const CurrentConfiguration) error{CorruptStore}!void {
    const instructions = current.instructions_id orelse return error.CorruptStore;
    if (instructions == 0 or current.output_schema_id == @as(?i64, 0) or current.revision == 0 or current.next_position == 0 or
        current.compaction_trigger == @as(?u64, 0) or current.created_at == 0 or current.workspace_key == 0 or current.tool_set_id == 0 or current.loaded_tool_set_id == @as(?u64, 0)) return error.CorruptStore;
    _ = try permissionMode(current.permission_mode);
    if (current.label) |*label| try checkLabel(label.slice());
}

/// A fresh Session reference: 32 symbols divide 256 exactly, so six
/// independent five-bit draws give 30 bits, without modulo bias or a weak
/// PRNG.
fn newReference(io: std.Io, reference: *[session_id.bytes]u8) !void {
    try std.Io.randomSecure(io, reference);
    for (reference) |*byte| byte.* = session_id.alphabet[byte.* & 31];
}

/// Queues what applying `configuration` to `session` reads (an empty
/// `session` creates one) into `reads`: one content lookup, or one pair of
/// them when both the instructions and an output schema need one and name
/// different rows. When they name one row, the schema shares the
/// instructions' value, so the first import's insert is the second's row.
/// noinline, as `queueConfiguredCommand`.
pub noinline fn prepareConfiguration(a: anytype, host_tool_set: *const tool_defs.HostToolSet, session: []const u8, configuration: *const content_custody.Configuration, reads: *ConfigurationReads) void {
    const creating = session.len == 0;
    if (!creating) readSaved(a, session, &reads.next, &reads.found);
    if (creating and configuration.parent.state == .value) prepareParent(a, configuration.parent.value.slice(), reads);
    if (creating or configuration.tools.state == .value) {
        reads.tools = .of(host_tool_set, requestedNames(configuration));
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

/// Sorted saved names, streamed into the configure's Store scratch. The
/// optional filter implements preserving a loaded subset across a tools change.
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

/// A strict loaded set must retain the built-in loader, so every configured
/// tool remains reachable. Membership always refers to the selected saved set.
fn loadedToolsRejection(tools: *const command_input.ToolsField, loaded: *const command_input.ToolsField) ?configuration_admission.Rejection {
    var names = loaded.iterator();
    while (names.next()) |name| if (!containsName(tools, name)) return .loaded_tools_not_in_tools;
    if (loaded.count < tools.count and !containsName(loaded, "find_tools")) return .loaded_tools_unreachable;
    return null;
}

/// Resolves the loaded set before importing content or changing the Session.
/// Omitted loaded_tools follows the entire tools set unless it was already a
/// strict subset; that subset is intersected with a newly requested tools set.
/// After `.model`: the saved configured names, when a request without
/// tools changes the loaded set, are read in `.saved_tools`.
fn loadedTools(a: anytype, request: *const Request, reads: *ConfigurationReads) !Validation {
    const requested = request.configuration;
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

/// Once the configured names are known: the saved loaded names an omitted
/// `loaded_tools` keeps, narrowed to them, are read in `.saved_loaded`.
fn loadedNames(a: anytype, request: *const Request, reads: *ConfigurationReads) !Validation {
    const v = &reads.step.validating;
    if (request.configuration.loaded_tools.state == .value) {
        v.loaded = &request.configuration.loaded_tools;
        return selectLoaded(a, request, reads);
    }
    reads.saved_loaded.state = .value;
    reads.saved_loaded.count = 0;
    reads.saved_loaded.names.len = 0;
    v.names = .{ .names = &reads.saved_loaded, .filter = v.tools };
    a.readEach(selected_names, .{ .set = reads.next.loaded_tool_set_id.? }, tool_name.max_tools + 1, &v.names);
    return .{ .round = .saved_loaded };
}

/// Once both name lists are known: a strict subset is selected from the
/// Host tool set, or from the saved set in `.loaded_source`, and looked
/// up in `.loaded`.
fn selectLoaded(a: anytype, request: *const Request, reads: *ConfigurationReads) !Validation {
    const v = &reads.step.validating;
    if (loadedToolsRejection(v.tools, v.loaded)) |rejection| return .{ .rejected = rejection };
    if (v.loaded.count == v.tools.count) return finishValidation(request, reads);
    if (request.session.len == 0 or request.configuration.tools.state == .value) {
        reads.loaded_tools = tool_set.Selection.of(request.tools.host_tool_set, v.loaded) orelse return error.CorruptStore;
        tool_set.lookupSelection(a, &reads.loaded_tools.?);
        return .{ .round = .loaded };
    }
    request.saved.* = .{ .names = v.loaded };
    request.saved.queue(a, reads.next.tool_set_id);
    return .{ .round = .loaded_source };
}

/// After a round that read saved names: refuses a list the Store could
/// not hold.
fn savedNames(reads: *const ConfigurationReads) error{CorruptStore}!void {
    if (reads.step.validating.names.invalid) return error.CorruptStore;
}

fn readCreation(a: anytype, reads: *ConfigurationReads) void {
    a.read(creation_facts, .{ .digest = reads.workspace_digest, .workspace = reads.next.workspace.slice(), .session = &reads.reference }, &reads.creation);
}

/// D133: only a spec with Bash needs a directory, and the parser and
/// configurationBeforeWorkspace refused one without it. The Workspace column
/// stays nonempty, so a spec without one saves the root. noinline: the
/// digest's hash state stays off applyConfiguration's frame, which sits on
/// the engine thread's deepest chain.
noinline fn saveUnusedWorkspace(configuration: *const content_custody.Configuration, next: *CurrentConfiguration, reads: *ConfigurationReads) void {
    std.debug.assert(!requestsBash(configuration));
    next.workspace.set("/") catch unreachable;
    reads.workspace_digest = store_core.workspaceDigest(next.workspace.slice());
}

// Both mutation branches validate after keyed replay and Configure's existing
// preset/capability precedence. Empty targets retain creation semantics;
// creating Messages share this check through applyConfiguration.
fn targetRejection(session: []const u8) ?configuration_admission.Rejection {
    return if (session.len != 0 and !session_id.valid(session)) .invalid_session_reference else null;
}

/// After `prepareConfiguration`'s round: decides the configuration, and
/// queues its content and the Session's insert or update. Creation and its
/// first Message can share this owner without an intermediate commit. The
/// answer names the Session either way; the caller records an accepted
/// one with `queueConfiguredCommand`.
pub const ValidatedConfiguration = struct {
    content_actions: @FieldType(ConfigurationUpdatePlan, "update"),
    before: ?Settings,
};
pub const ConfigurationValidation = union(enum) { ready: *const ValidatedConfiguration, rejected: configuration_admission.Rejection };

/// What applying a configuration reads besides the Store's rows: the
/// request, and the Host values its shell passes in. Each is the caller's,
/// which outlives the transaction.
pub const Request = struct {
    io: std.Io,
    tools: *const store_core.HostTools,
    served: provider_route.Routes,
    /// Empty for a creation.
    session: []const u8,
    configuration: *const content_custody.Configuration,
    initial_skills: ?*const skills_domain.Initial,
    /// The visitor of a `.loaded_source` round, the caller's, which
    /// outlives the round: its hash state is aligned beyond the Store's
    /// scratch, so `ConfigurationReads` cannot hold it.
    saved: *tool_set.SavedSelection,

    /// A request with `store`'s Host values, for a caller that holds it.
    pub fn of(store: *Store, io: std.Io, session: []const u8, configuration: *const content_custody.Configuration, initial_skills: ?*const skills_domain.Initial, saved: *tool_set.SavedSelection) Request {
        return .{ .io = io, .tools = store.hostTools(), .served = store.served, .session = session, .configuration = configuration, .initial_skills = initial_skills, .saved = saved };
    }
};

/// The rounds validating a configuration may ask for after
/// `prepareConfiguration`'s, in the order they run: the model's facts on
/// every path that gets that far, then, only when the loaded set changes,
/// the saved configured names, the saved loaded names, the saved set a
/// strict subset is selected from, and the lookup of that subset.
pub const ValidationRound = enum { model, saved_tools, saved_loaded, loaded_source, loaded };

/// What `validateStep` asks for next: a round, or its answer.
pub const Validation = union(enum) {
    round: ValidationRound,
    rejected: configuration_admission.Rejection,
    ready: *const ValidatedConfiguration,
};

/// What validation keeps between its rounds, in `ConfigurationReads`.
const Validating = struct {
    model: model_facts.Model,
    default_provider: ?provider_name.Provider,
    workspace_matches: ?bool,
    /// The configured and loaded names the loaded set is checked against:
    /// requested ones, or the saved ones read into `ConfigurationReads`.
    tools: *const command_input.ToolsField,
    loaded: *const command_input.ToolsField,
    /// The visitor of the round reading saved names.
    names: NameSelection,
};

/// Validates without queuing content, tool-set or Session writes, one
/// round at a time: `ran` is the round that just ran, null right after
/// `prepareConfiguration`'s. The plan it readies borrows the same
/// transaction's reads and is applied exactly once.
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

/// `validateStep` in rounds its caller runs. noinline: its request and
/// visitor stay off its caller's frame.
pub noinline fn validateConfiguration(
    a: anytype,
    io: std.Io,
    session: []const u8,
    configuration: *const content_custody.Configuration,
    initial_skills: ?*const skills_domain.Initial,
    reads: *ConfigurationReads,
) !ConfigurationValidation {
    var saved: tool_set.SavedSelection = undefined;
    const request: Request = .of(a.store, io, session, configuration, initial_skills, &saved);
    var ran: ?ValidationRound = null;
    while (true) switch (try validateStep(a, &request, reads, ran)) {
        .round => |at| {
            try a.run();
            ran = at;
        },
        .rejected => |code| return .{ .rejected = code },
        .ready => |plan| return .{ .ready = plan },
    };
}

/// What the request and round 1 decide, then the model's facts read.
fn validateRequest(a: anytype, request: *const Request, reads: *ConfigurationReads) !Validation {
    const session = request.session;
    const configuration = request.configuration;
    const creating = session.len == 0;
    if (targetRejection(session)) |code| return .{ .rejected = code };
    if (configuration.permission_mode.state == .value and
        std.meta.stringToEnum(cli_value.PermissionMode, configuration.permission_mode.value.slice()) == null)
    {
        return .{ .rejected = .unsupported_permission_mode };
    }
    if (configuration.model.state == .value and configuration.model.value.len == 0) {
        return .{ .rejected = .invalid_model };
    }
    if (configuration.output_schema.state == .value) {
        const valid = if (configuration.output_schema.borrowedBytes()) |bytes|
            try model_settlement_domain.validateJsonBytes(bytes)
        else
            try model_settlement_domain.validateJsonFile(request.io, configuration.output_schema.file orelse return error.MissingContentCustody);
        if (!valid) return .{ .rejected = .invalid_output_schema };
    }

    if (reads.pair) |*rows| content_domain.foundPair(rows, reads.instructionsValue(configuration), &reads.output_schema);
    const next = &reads.next;
    if (!creating and !reads.found.get()) {
        return .{ .rejected = .unknown_session };
    }
    if (reads.found.get()) try checkSaved(next);
    if (!creating and configuration.parent.state != .omitted) return .{ .rejected = .parent_on_update };
    if (creating) if (try inheritParent(request.tools.host_tool_set, configuration, reads)) |code| return .{ .rejected = code };
    reads.step = .{ .validating = undefined };
    const v = &reads.step.validating;
    v.default_provider = if (reads.inherits_parent) reads.next.provider else defaultProvider(request.served);
    v.model = .{};
    v.model.read(a, if (configuration.model.state == .value) configuration.model.value.slice() else next.model.slice());
    return .{ .round = .model };
}

/// After `.model`: the checks the model's facts decide, and the Workspace.
fn validateModel(a: anytype, request: *const Request, reads: *ConfigurationReads) !Validation {
    const io = request.io;
    const configuration = request.configuration;
    const creating = request.session.len == 0;
    const v = &reads.step.validating;
    const next = &reads.next;
    const current_configuration: ?*const CurrentConfiguration = if (reads.found.get()) next else null;
    if (configurationBeforeWorkspace(v.model.facts(), request.tools.host_tool_set, current_configuration, configuration, v.default_provider)) |rejection| {
        return .{ .rejected = rejection };
    }

    // A stated provider is saved by the update plan; configurationBeforeWorkspace
    // refused a creation with neither.
    if (creating) if (v.default_provider) |provider| {
        next.provider = provider;
    };
    // An existing Session's Workspace is only compared, in sameWorkspace's
    // own frame; a created one's was canonicalized into `next`.
    v.workspace_matches = if (creating and reads.inherits_parent) inherited: {
        validateWorkspace(io, next.workspace.slice(), &next.workspace) catch return .{ .rejected = .invalid_workspace };
        reads.workspace_digest = store_core.workspaceDigest(next.workspace.slice());
        break :inherited null;
    } else if (creating and configuration.workspace.state != .value) unused: {
        saveUnusedWorkspace(configuration, next, reads);
        break :unused null;
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

/// Once the loaded set is resolved: the update plan.
fn finishValidation(request: *const Request, reads: *ConfigurationReads) Validation {
    const configuration = request.configuration;
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

    // Preserve ordinary configuration refusals before considering a failed
    // discovery capture, but reject it before any content or Session writes.
    if (request.session.len == 0) if (request.initial_skills) |captured| if (captured.* == .unavailable) return .{ .rejected = .skills_unavailable };

    reads.validated.content_actions = content_actions;
    return .{ .ready = &reads.validated };
}

pub fn applyConfiguration(a: anytype, io: std.Io, session: []const u8, configuration: *const content_custody.Configuration, initial_skills: ?*const skills_domain.Initial, faults: Faults, reads: *ConfigurationReads) !Application {
    return switch (try validateConfiguration(a, io, session, configuration, initial_skills, reads)) {
        .rejected => |code| .{ .rejected = code },
        .ready => try applyValidatedConfiguration(a, io, session, configuration, initial_skills, faults, reads),
    };
}

/// The rounds applying a validated configuration may ask for, in order:
/// whether a created Session's drawn reference is free, once for each
/// draw, then the lookups its first skill catalog needs.
pub const ApplyRound = enum { creation, catalog };

/// What `applyStep` asks for next: a round, or the settings it applied.
pub const Applying = union(enum) {
    round: ApplyRound,
    accepted: *const Applied,
};

/// What application keeps between its rounds, in `ConfigurationReads`.
const ApplyState = struct {
    created_seq: u64,
    catalog: skills_domain.Appending,
};

/// Applies the plan `validateStep` readied, one round at a time: queues
/// its content and the Session's insert or update. `ran` is the round
/// that just ran, null for the first step. The answer, in
/// `ConfigurationReads`, names the Session; the caller records it with
/// `queueConfiguredCommand`. Creation and its first Message can share
/// this owner without an intermediate commit.
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

/// `applyStep` in rounds its caller runs, after `validateConfiguration`
/// readied `reads.validated`. noinline, as `validateConfiguration`.
pub noinline fn applyValidatedConfiguration(a: anytype, io: std.Io, session: []const u8, configuration: *const content_custody.Configuration, initial_skills: ?*const skills_domain.Initial, faults: Faults, reads: *ConfigurationReads) !Application {
    // Application reads no saved set.
    const request: Request = .of(a.store, io, session, configuration, initial_skills, undefined);
    var ran: ?ApplyRound = null;
    while (true) switch (try applyStep(a, &request, faults, reads, ran)) {
        .round => |at| {
            try a.run();
            ran = at;
        },
        .accepted => |applied| return .{ .accepted = applied.* },
    };
}

/// The content, the tool sets and an existing Session's update; a
/// creation draws its reference.
fn applyContent(a: anytype, request: *const Request, faults: Faults, reads: *ConfigurationReads) !Applying {
    const io = request.io;
    const session = request.session;
    const configuration = request.configuration;
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
            applied.instructions_id = try content_domain.importSealed(a, io, &configuration.instructions, &reads.instructions, faults);
            next.instructions_id = @intCast(applied.instructions_id.?);
        },
        .default_empty => next.instructions_id = @intCast(try content_domain.importBytes(a, &reads.empty, "")),
        .clear => next.instructions_id = null,
    }
    applied.output_schema_id = null;
    switch (content_actions.output_schema) {
        .preserve => {},
        .import_requested => {
            applied.output_schema_id = try content_domain.importSealed(a, io, &configuration.output_schema, &reads.output_schema, faults);
            next.output_schema_id = @intCast(applied.output_schema_id.?);
        },
        .clear => next.output_schema_id = null,
    }
    if (creating or configuration.tools.state == .value) {
        // configurationBeforeWorkspace refused a name the Host tool set lacks.
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
    try accept(request, reads, head, session);
    return .{ .accepted = applied };
}

/// Each drawn reference is checked free in a round of its own, after the
/// replay check, so a replay draws none; a taken one draws again.
fn drawReference(a: anytype, io: std.Io, reads: *ConfigurationReads) !Applying {
    try newReference(io, &reads.reference);
    readCreation(a, reads);
    return .{ .round = .creation };
}

/// Once a drawn reference is free: the Session's insert, then its first
/// skill catalog, when it starts with one.
fn insertCreated(a: anytype, request: *const Request, reads: *ConfigurationReads) !Applying {
    const created_seq = reads.step.applying.created_seq;
    const head: rsql.SessionHead = .{
        .ref = reads.reference,
        .workspace_key = if (reads.creation.workspace_key) |key| key else .of(created_seq),
        .next_position = .of(1),
    };
    insertSession(a, head, &reads.next, &reads.workspace_digest, created_seq, if (reads.parent) |*parent| parent else null);
    try accept(request, reads, head, &reads.reference);
    if (try skills_domain.Appending.initial(head, request.initial_skills)) |appending| {
        reads.step.applying.catalog = appending;
        reads.step.applying.catalog.queue(a);
        return .{ .round = .catalog };
    }
    return .{ .accepted = &reads.applied };
}

/// The answer: the Session `head` names, as `target`, with what changed.
fn accept(request: *const Request, reads: *ConfigurationReads, head: rsql.SessionHead, target: []const u8) !void {
    const applied = &reads.applied;
    const created = !reads.found.get();
    applied.session = .{};
    try applied.session.set(target);
    applied.head = head;
    applied.revision = reads.next.revision;
    applied.instructions_updated = created or request.configuration.instructions.state == .value;
    applied.changes = if (reads.validated.before) |*saved| saved.changed(&reads.next) else .empty;
}

fn saveConfigurationRejection(
    a: anytype,
    command: *const content_custody.ConfigureCommand,
    digest: *const [32]u8,
    code: configuration_admission.Rejection,
    faults: Faults,
) !ConfigureReply {
    return saveConfigurationRejectionWithFailure(a, command, digest, code, null, faults);
}

fn saveConfigurationRejectionWithFailure(
    a: anytype,
    command: *const content_custody.ConfigureCommand,
    digest: *const [32]u8,
    code: configuration_admission.Rejection,
    failure: ?skills_domain.Failure,
    faults: Faults,
) !ConfigureReply {
    var parent_buffer: [256]u8 = undefined;
    const parent_failure = a.store.configurationReads().parent_failure;
    const outcome_id = if (failure) |diagnostic| try skills_domain.importFailure(a, diagnostic.bytes, faults) else if (parent_failure) |diagnostic| try skills_domain.importFailure(a, diagnostic.text(&parent_buffer, "created"), faults) else null;
    var answer = StoredAnswer{ .accepted = false };
    try answer.code.set(@tagName(code));
    try command_domain.queueCommand(a, command.key.slice(), .configure, command.session.slice(), digest, outcome_id, null, &answer);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    return .{ .rejected = .{ .replayed = false, .code = code } };
}

/// Whether the Host serves the provider of the Session `configuration`
/// sets or the Session already has (`saved`). An unknown provider or
/// Session counts as served, so its own rejection answers.
pub fn servesProviderOf(served: anytype, configuration: ?*const content_custody.Configuration, saved: ?provider_name.Provider) bool {
    const provider = if (configuration != null and configuration.?.provider.state == .value)
        std.meta.stringToEnum(provider_name.Provider, configuration.?.provider.value.slice()) orelse return true
    else
        saved orelse (if (configuration != null) defaultProvider(served) orelse return true else return true);
    return provider_route.of(served, provider) != .unserved;
}

/// Queues saving the command that carries `applied`, then the Session's
/// revision row, which references it. Every argument outlives the round.
/// noinline: its locals stay off configure's frame on the engine's
/// deepest chain.
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
    a.write(insert_revision, .{ .session = applied.head, .command_key = key, .instructions_updated = applied.instructions_updated, .effort_choice = applied.changes.contains(.model) or applied.changes.contains(.reasoning_effort) });
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

/// One setting the revision just inserted changed (`session_change`).
const insert_change = rsql.Write(.{
    .sql = "INSERT INTO session_change(session_ref,position,ordinal,revision,field,changed_at) VALUES(@session(?1),?2,?3,?4,?5,@now)",
    .Args = struct { session: rsql.SessionHead, position: u64, ordinal: u64, revision: u64, field: []const u8 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Whether `supplied` canonicalizes to `existing`. Its canonical path
/// buffer lives in this call's frame only, never in the configure frame
/// that holds the whole next configuration.
noinline fn sameWorkspace(io: std.Io, supplied: []const u8, existing: []const u8) !bool {
    var canonical: Bounded(workspace_path.max_bytes) = .{ .len = 0 };
    try validateWorkspace(io, supplied, &canonical);
    return canonical.eql(existing);
}

/// Canonicalizes `supplied` straight into `destination`'s own bytes, with
/// the UTF-8 check `Bounded.set` applies; no second path buffer.
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

/// Match SQL identifiers, not substrings (tools must not hide loaded_tools).
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
        // Workspace never appears in UPDATE: admission keeps it immutable.
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
    var current: CurrentConfiguration = .{ .provider = .openai, .tool_set_id = 1 };
    try current.model.set("gpt-5");
    current.label = .{};
    try current.label.?.set("label");
    const before = Settings.of(&current);
    inline for (.{
        session_field.SessionField.model,
        session_field.SessionField.instructions,
        session_field.SessionField.tools,
        session_field.SessionField.loaded_tools,
        session_field.SessionField.permission_mode,
        session_field.SessionField.output_schema,
        session_field.SessionField.compaction_trigger,
        session_field.SessionField.output_reservation,
        session_field.SessionField.reasoning_effort,
        session_field.SessionField.label,
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
