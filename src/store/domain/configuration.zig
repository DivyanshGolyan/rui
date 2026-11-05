//! Session configuration: creating a Session, applying or rejecting a
//! configuration update, and reading a Session's saved settings.

const std = @import("std");
const protocol = @import("../../protocol.zig");
const model_capability = @import("../../model_capability.zig");
const product_defaults = @import("../../product_defaults.zig");
const tool_catalog = @import("../../tools.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const command_domain = @import("command.zig");
const content_domain = @import("content.zig");
const model_settlement_domain = @import("model_settlement.zig");
const tool_set = @import("tool_set.zig");
const sqlite = @import("../sqlite.zig");
const rsql = @import("../rsql.zig");
const store_access = @import("../access.zig");
const c = sqlite.c;
const Faults = store_core.Faults;
const StoredAnswer = command_domain.StoredAnswer;

pub const AcceptedConfiguration = struct {
    replayed: bool,
    revision: u64 = 0,
    created: bool = false,
    session: protocol.Bounded(protocol.max_session_bytes) = .{},
};

pub const RejectedConfiguration = struct {
    replayed: bool,
    code: protocol.ConfigurationRejection,
};

pub const ConfigureReply = union(enum) {
    accepted: AcceptedConfiguration,
    rejected: RejectedConfiguration,
    conflict,
    infrastructure_failure,
};

const Tool = tool_catalog.Tool;

/// Decodes a persisted tools_mask.
pub fn toolSet(mask: c_int) !tool_catalog.ToolSet {
    var set: tool_catalog.ToolSet = .empty;
    var remaining = std.math.cast(u8, mask) orelse return error.CorruptStore;
    inline for (comptime std.meta.tags(Tool)) |tool| {
        if (remaining & tool_catalog.toolBit(tool) != 0) set.insert(tool);
        remaining &= ~tool_catalog.toolBit(tool);
    }
    if (remaining != 0) return error.CorruptStore;
    return set;
}

/// The tool names a creation or a `tools` change saves: the requested
/// ones, or the defaults when a creation names none.
fn requestedNames(requested: *const protocol.Configuration) *const protocol.ToolsField {
    return if (requested.tools.state == .value) &requested.tools else &default_tools;
}

/// The built-in tools a creation or a `tools` change saves, or null when
/// one of them is no built-in: what an agent's spec may narrow.
pub fn requestedTools(requested: *const protocol.Configuration) ?tool_catalog.ToolSet {
    var set: tool_catalog.ToolSet = .empty;
    var names = requestedNames(requested).iterator();
    while (names.next()) |name| set.insert(tool_catalog.builtIn(name) orelse return null);
    return set;
}

/// The tools a created Session gets when configuration omits them.
pub const default_tools: protocol.ToolsField = blk: {
    var names: []const []const u8 = &.{};
    var each = std.mem.splitScalar(u8, product_defaults.tools, ',');
    while (each.next()) |name| {
        const index = tool_catalog.built_in.find(name) orelse @compileError("default tool " ++ name ++ " is no built-in");
        // A creation that names no tools gets these on any provider.
        if (tool_catalog.built_in.records[index].owner == .provider) for (std.enums.values(protocol.Provider)) |provider| {
            if (!provider.runsTool(name)) @compileError(@tagName(provider) ++ " does not run default tool " ++ name);
        };
        names = names ++ .{name};
    }
    break :blk protocol.ToolsField.of(names) catch unreachable;
};

/// Why `tools` cannot be saved for a Session of `provider`: a name the
/// Host's catalog lacks, or a tool some provider runs that `provider`
/// does not.
fn toolsRejection(catalog: *const tool_catalog.Catalog, provider: protocol.Provider, tools: *const protocol.ToolsField) ?protocol.ConfigurationRejection {
    var names = tools.iterator();
    while (names.next()) |name| {
        const index = catalog.find(name) orelse return .unknown_tool;
        if (catalog.records[index].owner == .provider and !provider.runsTool(name)) return .provider_tool_missing;
    }
    return null;
}

/// Persisted session.permission_mode for a validated mode name.
fn permissionModeCode(mode: []const u8) u8 {
    return if (std.mem.eql(u8, mode, "ask")) 0 else 1;
}

/// Decodes a persisted permission_mode: 0 asks, 1 bypasses, and any other
/// value is `CorruptStore`.
pub fn permissionMode(code: u8) error{CorruptStore}!protocol.PermissionMode {
    return switch (code) {
        0 => .ask,
        1 => .bypass,
        else => error.CorruptStore,
    };
}

/// Refuses a persisted label that `protocol.validLabel` does not accept.
pub fn checkLabel(label: []const u8) error{CorruptStore}!void {
    if (!protocol.validLabel(label)) return error.CorruptStore;
}

/// The default tools as a mask, for readers that still take one.
pub const default_tools_mask: u8 = blk: {
    var mask: u8 = 0;
    var names = default_tools.iterator();
    while (names.next()) |name| mask |= tool_catalog.toolBit(tool_catalog.builtIn(name).?);
    break :blk mask;
};

/// A Session's saved configuration. Its fields name, in order, the columns
/// `saved_session` reads, so a read decodes into it in place.
pub const CurrentConfiguration = struct {
    workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{},
    provider: protocol.Provider = undefined,
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    instructions_id: ?i64 = null,
    /// Read only: the tools of the set `tool_set_id` names, as a mask,
    /// until the wire names tools by name.
    tools_mask: u8 = default_tools_mask,
    /// The saved tool set; 0 until a creation saves its first.
    tool_set_id: u64 = 0,
    permission_mode: u8 = permissionModeCode(product_defaults.permission_mode),
    output_schema_id: ?i64 = null,
    revision: u64 = 0,
    next_position: u64 = 1,
    compaction_trigger: ?u64 = null,
    output_reservation: ?u64 = null,
    reasoning_effort: ?protocol.ReasoningEffort = null,
    label: ?protocol.Bounded(protocol.max_label_bytes) = null,
    /// Read only: the Store dates a Session when it inserts it.
    created_at: u64 = 0,
    /// Read only: the change ring's key for the Session's Workspace.
    workspace_key: u64 = 0,
};

/// The Session columns turn work, settlement and page cursors read, without
/// the 4 KB workspace a whole CurrentConfiguration carries.
pub const SessionFacts = struct {
    provider: protocol.Provider,
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    permission_mode: u8,
    revision: u64,
    next_position: u64,
    compaction_trigger: ?u64 = null,
    output_reservation: ?u64 = null,
    reasoning_effort: ?protocol.ReasoningEffort = null,
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
    rejected: protocol.ConfigurationRejection,
    update: struct {
        instructions: ConfigurationContentAction,
        output_schema: OutputSchemaAction,
    },
};

fn configurationTokens(field: @TypeOf(@as(protocol.Configuration, .{}).compaction_trigger), previous: ?u64, allow_zero: bool) !?u64 {
    if (field.state == .omitted) return previous;
    if (field.state == .explicit_null) return null;
    if (field.state != .value) return error.InvalidTokenHeuristic;
    const value = std.fmt.parseInt(u64, field.value.slice(), 10) catch return error.InvalidTokenHeuristic;
    if ((!allow_zero and value == 0) or value > std.math.maxInt(i64)) return error.InvalidTokenHeuristic;
    for (field.value.slice()) |byte| if (byte < '0' or byte > '9') return error.InvalidTokenHeuristic;
    return value;
}

pub fn configurationBeforeWorkspace(
    catalog: *const tool_catalog.Catalog,
    current: ?*const CurrentConfiguration,
    requested: *const protocol.Configuration,
) ?protocol.ConfigurationRejection {
    _ = configurationTokens(requested.compaction_trigger, null, false) catch return .invalid_compaction_trigger;
    _ = configurationTokens(requested.output_reservation, null, true) catch return .invalid_output_reservation;
    const provider = if (requested.provider.state == .value)
        std.meta.stringToEnum(protocol.Provider, requested.provider.value.slice()) orelse return .unsupported_provider
    else
        null;
    if (current == null and
        (requested.workspace.state != .value or provider == null or requested.model.state != .value))
    {
        return .incomplete_initial_configuration;
    }
    if (current) |existing| {
        if (provider) |value| {
            if (value != existing.provider) return .provider_is_immutable;
        }
        if (requested.model.state == .value and
            !existing.model.eql(requested.model.value.slice()))
        {
            return .model_is_immutable;
        }
    }
    if (requested.label.state == .value and !protocol.validLabel(requested.label.value.slice())) return .invalid_label;
    if (requested.tools.state == .value) if (toolsRejection(catalog, provider orelse current.?.provider, &requested.tools)) |rejection| return rejection;
    if (requested.reasoning_effort.state == .value) {
        const model = if (requested.model.state == .value) requested.model.value.slice() else current.?.model.slice();
        const effort = std.meta.stringToEnum(protocol.ReasoningEffort, requested.reasoning_effort.value.slice()) orelse
            return .unsupported_reasoning_effort;
        if (!model_capability.supportsReasoningEffort(model, effort)) return .unsupported_reasoning_effort;
    }
    return null;
}

/// The effort a new Operation freezes: the Session override, otherwise the
/// exact binding's catalog default, otherwise none.
pub fn effectiveReasoningEffort(current: anytype) ?protocol.ReasoningEffort {
    return current.reasoning_effort orelse model_capability.defaultReasoningEffort(current.model.slice());
}

/// `next` holds the current configuration's values, or the defaults when
/// there is none, and may be `current` itself: each field of `current` is
/// read before `next`'s same field is written. A requested workspace is
/// canonicalized by the caller, which answers `workspace_matches` (whether
/// it is the current Session's) and has already written a created
/// Session's into `next`.
pub fn planConfigurationUpdate(
    current: ?*const CurrentConfiguration,
    requested: *const protocol.Configuration,
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

    if (requested.provider.state == .value) next.provider = std.meta.stringToEnum(protocol.Provider, requested.provider.value.slice()).?;
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
        .value => next.reasoning_effort = std.meta.stringToEnum(protocol.ReasoningEffort, requested.reasoning_effort.value.slice()).?,
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
pub fn configure(a: anytype, io: std.Io, served: anytype, request: *const protocol.ConfigureCommand, faults: Faults) !ConfigureReply {
    // The captured creation intent has no ID. Save its original digest
    // alongside the allocated target so a lost reply never creates twice.
    const command = request;
    const creating = request.session.len == 0;
    const digest = request.semanticDigest();
    var saved: command_domain.saved_command.Result = undefined;
    command_domain.lookupCommand(a, command.key.slice(), &saved);
    const reads = a.store.configurationReads();
    reads.* = .{ .next = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } } };
    prepareConfiguration(a, command.session.slice(), &command.configuration, reads);
    try a.run();

    if (saved != null) try a.abandon(.{});
    switch (try command_domain.classify(protocol.ConfigurationRejection, &saved, .configure, command.session.slice(), &digest)) {
        .fresh => {},
        .conflict => return .conflict,
        .accepted => |existing| return .{ .accepted = .{
            .replayed = true,
            .revision = existing.revision,
            .created = existing.created,
            .session = existing.target,
        } },
        .rejected => |code| return .{ .rejected = .{ .replayed = true, .code = code } },
    }

    if (command.require_model and !servesProviderOf(served, &command.configuration, if (reads.found.get()) reads.next.provider else null)) {
        return saveConfigurationRejection(a, command, &digest, .model_capability_unavailable, faults);
    }
    const applied = switch (try applyConfiguration(a, io, command.session.slice(), &command.configuration, faults, reads)) {
        .rejected => |code| return saveConfigurationRejection(a, command, &digest, code, faults),
        .accepted => |value| value,
    };
    const answer: StoredAnswer = .{ .accepted = true, .revision = applied.revision, .created = creating };
    try queueConfiguredCommand(a, &applied, command.key.slice(), .configure, &digest, applied.instructions_id, applied.output_schema_id, &answer);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    return .{ .accepted = .{ .replayed = false, .revision = applied.revision, .created = creating, .session = applied.session } };
}

/// Settings `applyConfiguration` wrote to a Session, whose revision row
/// `queueConfiguredCommand` records with the command.
pub const Applied = struct {
    session: protocol.Bounded(protocol.max_session_bytes),
    head: rsql.SessionHead,
    revision: u64,
    instructions_id: ?u64,
    output_schema_id: ?u64,
    instructions_updated: bool,
    /// The settings this revision changed; empty for a creation.
    changes: std.EnumSet(protocol.SessionField) = .empty,
};

/// The settings a revision can change, as `next` holds them before and
/// after it applies (the Workspace never changes).
const Settings = struct {
    provider: protocol.Provider,
    model: protocol.Bounded(protocol.max_model_bytes),
    instructions_id: ?i64,
    tool_set_id: u64,
    permission_mode: u8,
    output_schema_id: ?i64,
    compaction_trigger: ?u64,
    output_reservation: ?u64,
    reasoning_effort: ?protocol.ReasoningEffort,
    label: ?protocol.Bounded(protocol.max_label_bytes),

    fn of(current: *const CurrentConfiguration) Settings {
        return .{
            .provider = current.provider,
            .model = current.model,
            .instructions_id = current.instructions_id,
            .tool_set_id = current.tool_set_id,
            .permission_mode = current.permission_mode,
            .output_schema_id = current.output_schema_id,
            .compaction_trigger = current.compaction_trigger,
            .output_reservation = current.output_reservation,
            .reasoning_effort = current.reasoning_effort,
            .label = current.label,
        };
    }

    /// Each field whose value differs, by its name in `SessionField`.
    fn changed(before: *const Settings, after: *const Settings) std.EnumSet(protocol.SessionField) {
        var fields: std.EnumSet(protocol.SessionField) = .empty;
        fields.setPresent(.provider, before.provider != after.provider);
        fields.setPresent(.model, !before.model.eql(after.model.slice()));
        fields.setPresent(.instructions, before.instructions_id != after.instructions_id);
        fields.setPresent(.tools, before.tool_set_id != after.tool_set_id);
        fields.setPresent(.permission_mode, before.permission_mode != after.permission_mode);
        fields.setPresent(.output_schema, before.output_schema_id != after.output_schema_id);
        fields.setPresent(.compaction_trigger, before.compaction_trigger != after.compaction_trigger);
        fields.setPresent(.output_reservation, before.output_reservation != after.output_reservation);
        fields.setPresent(.reasoning_effort, before.reasoning_effort != after.reasoning_effort);
        const same_label = if (before.label) |label| (if (after.label) |next| label.eql(next.slice()) else false) else after.label == null;
        fields.setPresent(.label, !same_label);
        return fields;
    }
};

pub const Application = union(enum) {
    accepted: Applied,
    rejected: protocol.ConfigurationRejection,
};

/// What `prepareConfiguration` reads in a round, and where the round
/// leaves it; its owner keeps it until the transaction ends. Declared with
/// a literal that names `next`'s big fields' lengths, so their bytes stay
/// unwritten.
pub const ConfigurationReads = struct {
    /// The Session's saved configuration, which the plan then updates in
    /// place: one 4.6 KB value, not a copy of it.
    next: CurrentConfiguration,
    /// Whether the Session exists: `.missing` for a creation, which reads none.
    found: store_access.Found = .missing,
    reference: [protocol.session_id_bytes]u8 = undefined,
    workspace_digest: [32]u8 = undefined,
    creation: creation_facts.Result = undefined,
    instructions: content_domain.Import = undefined,
    output_schema: content_domain.Import = undefined,
    empty: content_domain.Import = content_domain.empty_content,
    /// The rows `lookupPair` found, when round 1 needed two lookups.
    pair: ?content_domain.Pair = null,
    /// The tool set a creation or a `tools` change saves, when it does;
    /// null too when the catalog lacks a name, which the configure refuses.
    tools: ?tool_set.Selection = null,
    /// The Session a creation starts as the child of, when it has one.
    parent: ?[protocol.session_id_bytes]u8 = null,

    /// The value the instructions import through: the requested content,
    /// or the empty default a creation imports.
    fn instructionsValue(reads: *ConfigurationReads, configuration: *const protocol.Configuration) *content_domain.Import {
        return if (configuration.instructions.state == .value) &reads.instructions else &reads.empty;
    }
};

/// A Session's saved configuration, decoded into a CurrentConfiguration in
/// place; `checkSaved` holds it to its types.
const saved_session = rsql.Read(.{
    .sql = "SELECT workspace,provider,model,instructions_content_id AS instructions_id," ++ tool_set.maskSql("session.tool_set_id") ++ " AS tools_mask,tool_set_id,permission_mode," ++
        "output_schema_content_id AS output_schema_id,revision,next_position,compaction_trigger,output_reservation," ++
        "reasoning_effort,label,created_at,workspace_key FROM session WHERE session_ref=?1",
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
        "provider,compaction_trigger,output_reservation,reasoning_effort,label,codec,workspace_digest,created_at,created_seq,workspace_key,parent_ref) " ++
        "VALUES(@session(?1),?2,?3,?4,?5,?6,?7,1,1,?8,?9,?10,?11,?12,?13,?14,@now,?15,?16,?17)",
    .Args = struct {
        session: rsql.SessionHead,
        workspace: []const u8,
        model: []const u8,
        instructions_id: ?u64,
        tool_set_id: u64,
        permission_mode: u8,
        output_schema_id: ?u64,
        provider: protocol.Provider,
        compaction_trigger: ?u64,
        output_reservation: ?u64,
        reasoning_effort: ?protocol.ReasoningEffort,
        label: ?[]const u8,
        codec: []const u8,
        digest: [32]u8,
        created_seq: u64,
        workspace_key: u64,
        parent: ?protocol.Bounded(protocol.session_id_bytes),
    },
    // Its round read the reference free, under the single writer.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Queues inserting the created Session `head` with the settings `next`,
/// as the child of `parent` when one is named. `configure` calls it, and a
/// test drives it with references the schema refuses.
pub fn insertSession(a: anytype, head: rsql.SessionHead, next: *const CurrentConfiguration, workspace_digest: *const [32]u8, created_seq: u64, parent: ?*const [protocol.session_id_bytes]u8) void {
    var parent_ref: ?protocol.Bounded(protocol.session_id_bytes) = null;
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
    });
}

const update_session = rsql.Write(.{
    .sql = "UPDATE session SET model=?2,instructions_content_id=?3,tool_set_id=?4,permission_mode=?5,output_schema_content_id=?6,revision=?7,provider=?8," ++
        "compaction_trigger=?9,output_reservation=?10,reasoning_effort=?11,label=?12 WHERE session_ref=@session(?1)",
    .Args = struct {
        session: rsql.SessionHead,
        model: []const u8,
        instructions_id: ?u64,
        tool_set_id: u64,
        permission_mode: u8,
        output_schema_id: ?u64,
        revision: u64,
        provider: protocol.Provider,
        compaction_trigger: ?u64,
        output_reservation: ?u64,
        reasoning_effort: ?protocol.ReasoningEffort,
        label: ?[]const u8,
    },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.SessionUpdateFailed } },
});

/// The UPDATE a configure of an existing Session runs once it has touched
/// that Session, which a test faults.
pub const update_session_sql = update_session.sql;

/// The one writer of session_revision: it copies the Session row as
/// written under `command_key`, which an earlier write of the round saved.
const insert_revision = rsql.Write(.{
    .sql = "INSERT INTO session_revision(session_ref,revision,command_key,workspace,model,instructions_content_id,instructions_updated,tool_set_id," ++
        "permission_mode,output_schema_content_id,provider,compaction_trigger,output_reservation,reasoning_effort,label) " ++
        "SELECT session_ref,revision,?2,workspace,model,instructions_content_id,?3,tool_set_id,permission_mode,output_schema_content_id,provider," ++
        "compaction_trigger,output_reservation,reasoning_effort,label FROM session WHERE session_ref=@session(?1)",
    .Args = struct { session: rsql.SessionHead, command_key: []const u8, instructions_updated: bool },
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
        current.compaction_trigger == @as(?u64, 0) or current.created_at == 0 or current.workspace_key == 0 or current.tool_set_id == 0) return error.CorruptStore;
    _ = try toolSet(current.tools_mask);
    _ = try permissionMode(current.permission_mode);
    if (current.label) |*label| try checkLabel(label.slice());
}

/// A fresh Session reference: 32 symbols divide 256 exactly, so six
/// independent five-bit draws give 30 bits, without modulo bias or a weak
/// PRNG.
fn newReference(io: std.Io, reference: *[protocol.session_id_bytes]u8) !void {
    try std.Io.randomSecure(io, reference);
    for (reference) |*byte| byte.* = protocol.session_alphabet[byte.* & 31];
}

/// Queues what applying `configuration` to `session` reads (an empty
/// `session` creates one) into `reads`: one content lookup, or one pair of
/// them when both the instructions and an output schema need one and name
/// different rows. When they name one row, the schema shares the
/// instructions' value, so the first import's insert is the second's row.
pub fn prepareConfiguration(a: anytype, session: []const u8, configuration: *const protocol.Configuration, reads: *ConfigurationReads) void {
    const creating = session.len == 0;
    if (!creating) readSaved(a, session, &reads.next, &reads.found);
    if (creating or configuration.tools.state == .value) {
        reads.tools = .of(a.store.catalog().catalog, requestedNames(configuration));
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

fn readCreation(a: anytype, reads: *ConfigurationReads) void {
    a.read(creation_facts, .{ .digest = reads.workspace_digest, .workspace = reads.next.workspace.slice(), .session = &reads.reference }, &reads.creation);
}

/// After `prepareConfiguration`'s round: decides the configuration, and
/// queues its content and the Session's insert or update. Creation and its
/// first Message can share this owner without an intermediate commit. The
/// answer names the Session either way; the caller records an accepted
/// one with `queueConfiguredCommand`.
pub fn applyConfiguration(
    a: anytype,
    io: std.Io,
    session: []const u8,
    configuration: *const protocol.Configuration,
    faults: Faults,
    reads: *ConfigurationReads,
) !Application {
    const creating = session.len == 0;
    if (!creating and !protocol.validSessionId(session)) {
        return .{ .rejected = .invalid_session_reference };
    }
    if (configuration.permission_mode.state == .value and
        !configuration.permission_mode.value.eql("ask") and
        !configuration.permission_mode.value.eql("bypass"))
    {
        return .{ .rejected = .unsupported_permission_mode };
    }
    if (configuration.model.state == .value and configuration.model.value.len == 0) {
        return .{ .rejected = .invalid_model };
    }
    if (configuration.output_schema.state == .value and
        !try model_settlement_domain.validateJsonFile(io, configuration.output_schema.file orelse return error.MissingContentCustody))
    {
        return .{ .rejected = .invalid_output_schema };
    }

    if (reads.pair) |*rows| content_domain.foundPair(rows, reads.instructionsValue(configuration), &reads.output_schema);
    const next = &reads.next;
    if (!creating and !reads.found.get()) {
        return .{ .rejected = .unknown_session };
    }
    if (reads.found.get()) try checkSaved(next);
    const current_configuration: ?*const CurrentConfiguration = if (reads.found.get()) next else null;
    if (configurationBeforeWorkspace(a.store.catalog().catalog, current_configuration, configuration)) |rejection| {
        return .{ .rejected = rejection };
    }

    // An existing Session's Workspace is only compared, in sameWorkspace's
    // own frame; a created one's was canonicalized into `next`.
    const workspace_matches: ?bool = if (configuration.workspace.state == .value) matches: {
        if (reads.found.get()) {
            break :matches sameWorkspace(io, configuration.workspace.value.slice(), next.workspace.slice()) catch {
                return .{ .rejected = .invalid_workspace };
            };
        }
        validateWorkspace(io, configuration.workspace.value.slice(), &next.workspace) catch return .{ .rejected = .invalid_workspace };
        reads.workspace_digest = store_core.workspaceDigest(next.workspace.slice());
        break :matches true;
    } else null;

    const created = !reads.found.get();
    const before: ?Settings = if (created) null else .of(next);
    const content_actions = switch (planConfigurationUpdate(
        current_configuration,
        configuration,
        workspace_matches,
        next,
    )) {
        .rejected => |rejection| return .{ .rejected = rejection },
        .update => |actions| actions,
    };

    var command_instructions_id: ?u64 = null;
    switch (content_actions.instructions) {
        .preserve => {},
        .import_requested => {
            command_instructions_id = try content_domain.importSealed(a, io, &configuration.instructions, &reads.instructions, faults);
            next.instructions_id = @intCast(command_instructions_id.?);
        },
        .default_empty => next.instructions_id = @intCast(try content_domain.importBytes(a, &reads.empty, "")),
        .clear => next.instructions_id = null,
    }
    var command_output_schema_id: ?u64 = null;
    switch (content_actions.output_schema) {
        .preserve => {},
        .import_requested => {
            command_output_schema_id = try content_domain.importSealed(a, io, &configuration.output_schema, &reads.output_schema, faults);
            next.output_schema_id = @intCast(command_output_schema_id.?);
        },
        .clear => next.output_schema_id = null,
    }
    if (creating or configuration.tools.state == .value) {
        // configurationBeforeWorkspace refused a name the catalog lacks.
        const tools = &(reads.tools orelse return error.CorruptStore);
        next.tool_set_id = try tool_set.finishSelection(a, tools, a.store.catalog().set_id);
    }
    var target: protocol.Bounded(protocol.max_session_bytes) = .{};
    var head: rsql.SessionHead = undefined;
    if (created) {
        std.debug.assert(next.revision == 1);
        const created_seq = try a.identity(.created_seq);
        // Each drawn reference is checked free in a round of its own, after
        // the replay check, so a replay draws none; a taken one draws again.
        reads.creation.taken = true;
        while (reads.creation.taken) {
            try newReference(io, &reads.reference);
            readCreation(a, reads);
            try a.run();
        }
        head = .{
            .ref = reads.reference,
            .workspace_key = if (reads.creation.workspace_key) |key| key else .of(created_seq),
            .next_position = .of(1),
        };
        insertSession(a, head, next, &reads.workspace_digest, created_seq, if (reads.parent) |*parent| parent else null);
        try target.set(&reads.reference);
    } else {
        head = .{ .ref = session[0..protocol.session_id_bytes].*, .workspace_key = .of(next.workspace_key), .next_position = .of(next.next_position) };
        a.write(update_session, .{
            .session = head,
            .model = next.model.slice(),
            .instructions_id = if (next.instructions_id) |id| @intCast(id) else null,
            .tool_set_id = next.tool_set_id,
            .permission_mode = next.permission_mode,
            .output_schema_id = if (next.output_schema_id) |id| @intCast(id) else null,
            .revision = next.revision,
            .provider = next.provider,
            .compaction_trigger = next.compaction_trigger,
            .output_reservation = next.output_reservation,
            .reasoning_effort = next.reasoning_effort,
            .label = if (next.label) |*label| label.slice() else null,
        });
        try target.set(session);
    }
    return .{ .accepted = .{
        .session = target,
        .head = head,
        .revision = next.revision,
        .instructions_id = command_instructions_id,
        .output_schema_id = command_output_schema_id,
        .instructions_updated = created or configuration.instructions.state == .value,
        .changes = if (before) |*saved| saved.changed(&Settings.of(next)) else .empty,
    } };
}

fn saveConfigurationRejection(
    a: anytype,
    command: *const protocol.ConfigureCommand,
    digest: *const [32]u8,
    code: protocol.ConfigurationRejection,
    faults: Faults,
) !ConfigureReply {
    var answer = StoredAnswer{ .accepted = false };
    try answer.code.set(@tagName(code));
    try command_domain.queueCommand(a, command.key.slice(), .configure, command.session.slice(), digest, null, null, &answer);
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
    return .{ .rejected = .{ .replayed = false, .code = code } };
}

/// Whether the Host serves the provider of the Session `configuration`
/// sets or the Session already has (`saved`). An unknown provider or
/// Session counts as served, so its own rejection answers.
pub fn servesProviderOf(served: anytype, configuration: ?*const protocol.Configuration, saved: ?protocol.Provider) bool {
    const provider = if (configuration != null and configuration.?.provider.state == .value)
        std.meta.stringToEnum(protocol.Provider, configuration.?.provider.value.slice()) orelse return true
    else
        saved orelse return true;
    return protocol.routeOf(served, provider) != .unserved;
}

/// Queues saving the command that carries `applied`, then the Session's
/// revision row, which references it. Every argument outlives the round.
pub fn queueConfiguredCommand(
    a: anytype,
    applied: *const Applied,
    key: []const u8,
    kind: protocol.CommandKind,
    digest: *const [32]u8,
    primary_content_id: ?u64,
    secondary_content_id: ?u64,
    answer: *const StoredAnswer,
) !void {
    try command_domain.queueCommand(a, key, kind, applied.session.slice(), digest, primary_content_id, secondary_content_id, answer);
    a.write(insert_revision, .{ .session = applied.head, .command_key = key, .instructions_updated = applied.instructions_updated });
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
    var canonical: protocol.Bounded(protocol.max_workspace_bytes) = .{ .len = 0 };
    try validateWorkspace(io, supplied, &canonical);
    return canonical.eql(existing);
}

/// Canonicalizes `supplied` straight into `destination`'s own bytes, with
/// the UTF-8 check `Bounded.set` applies; no second path buffer.
fn validateWorkspace(io: std.Io, supplied: []const u8, destination: *protocol.Bounded(protocol.max_workspace_bytes)) !void {
    if (!std.fs.path.isAbsolute(supplied)) return error.WorkspaceMustBeAbsolute;
    if (std.mem.indexOfScalar(u8, supplied, 0) != null) return error.InvalidWorkspace;
    var directory = try std.Io.Dir.cwd().openDir(io, supplied, .{});
    defer directory.close(io);
    destination.len = 0;
    const length = try directory.realPath(io, &destination.bytes);
    if (!std.unicode.utf8ValidateSlice(destination.bytes[0..length])) return error.InvalidUtf8;
    destination.len = length;
}
