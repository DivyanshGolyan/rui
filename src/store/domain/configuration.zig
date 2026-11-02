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
const sqlite = @import("../sqlite.zig");
const c = sqlite.c;
const Faults = store_core.Faults;
const StoredAnswer = command_domain.StoredAnswer;

/// Whether the Host serves the provider `column` names, through the
/// `rui_served` function each opening registers over its own served set.
pub fn servedProviderSql(comptime column: []const u8) []const u8 {
    return "rui_served(" ++ column ++ ")";
}

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

/// Persisted session.permission_mode for a validated mode name.
fn permissionModeCode(mode: []const u8) u8 {
    return if (std.mem.eql(u8, mode, "ask")) 0 else 1;
}

/// A created Session's tools when configuration omits them.
const default_tools_mask: u8 = blk: {
    var mask: u8 = 0;
    var names = std.mem.splitScalar(u8, product_defaults.tools, ',');
    while (names.next()) |name| mask |= tool_catalog.toolBit(std.meta.stringToEnum(Tool, name).?);
    break :blk mask;
};

pub const CurrentConfiguration = struct {
    workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{},
    provider: protocol.Provider = undefined,
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    instructions_id: ?i64 = null,
    tools_mask: u8 = default_tools_mask,
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

pub const ConfigurationUpdatePlan = union(enum) {
    rejected: protocol.ConfigurationRejection,
    update: struct {
        instructions: ConfigurationContentAction,
        output_schema: ConfigurationContentAction,
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
    if (requested.tools.state == .value) {
        next.tools_mask = 0;
        for (requested.tools.values[0..requested.tools.count]) |tool| {
            next.tools_mask |= tool_catalog.toolBit(tool);
        }
    }
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

pub fn configureLocked(
    self: *Store,
    request: *const protocol.ConfigureCommand,
    faults: Faults,
) !ConfigureReply {
    try store_core.execute(self, "BEGIN IMMEDIATE");

    // The captured creation intent has no ID. Save its original digest
    // alongside the allocated target so a lost reply never creates twice.
    const command = request;
    const creating = request.session.len == 0;
    const digest = request.semanticDigest();
    switch (try command_domain.classifyReplay(self, protocol.ConfigurationRejection, .configure, command.key.slice(), command.session.slice(), &digest)) {
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

    if (command.require_model and !try servesProvider(self, &command.configuration, command.session.slice())) {
        return try saveConfigurationRejection(self, command, &digest, .model_capability_unavailable, faults);
    }
    const applied = switch (try applyConfiguration(self, command.key.slice(), command.session.slice(), &command.configuration, faults)) {
        .rejected => |code| return saveConfigurationRejection(self, command, &digest, code, faults),
        .accepted => |value| value,
    };
    try command_domain.insertCommand(
        self,
        command.key.slice(),
        .configure,
        applied.session.slice(),
        &digest,
        applied.instructions_id,
        applied.output_schema_id,
        .{ .accepted = true, .revision = applied.revision, .created = creating },
    );
    if (faults.before_commit) return error.InjectedCommitFailure;
    try store_core.execute(self, "COMMIT");
    return .{ .accepted = .{ .replayed = false, .revision = applied.revision, .created = creating, .session = applied.session } };
}

/// Applies settings within the caller's transaction. Creation and its
/// first Message can share this owner without an intermediate commit.
/// An empty `session` creates one; the answer names the Session either way.
pub fn applyConfiguration(
    self: *Store,
    key: []const u8,
    session: []const u8,
    configuration: *const protocol.Configuration,
    faults: Faults,
) !union(enum) {
    accepted: struct {
        session: protocol.Bounded(protocol.max_session_bytes),
        revision: u64,
        instructions_id: ?i64,
        output_schema_id: ?i64,
    },
    rejected: protocol.ConfigurationRejection,
} {
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
        !try model_settlement_domain.validateJsonFile(self.io, configuration.output_schema.file orelse return error.MissingContentCustody))
    {
        return .{ .rejected = .invalid_output_schema };
    }

    // The current configuration is read into `next`, which the plan
    // then updates in place: one 4.6 KB value, not a copy of it.
    var next: CurrentConfiguration = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } };
    const found = try readSession(self, session, &next);
    if (!creating and !found) {
        return .{ .rejected = .unknown_session };
    }
    const current_configuration: ?*const CurrentConfiguration = if (found) &next else null;
    if (configurationBeforeWorkspace(current_configuration, configuration)) |rejection| {
        return .{ .rejected = rejection };
    }

    // A created Session's canonical workspace lands in `next` itself;
    // an existing one's is only compared, in sameWorkspace's own frame.
    const workspace_matches: ?bool = if (configuration.workspace.state == .value) matches: {
        const supplied = configuration.workspace.value.slice();
        if (found) {
            break :matches sameWorkspace(self.io, supplied, next.workspace.slice()) catch {
                return .{ .rejected = .invalid_workspace };
            };
        }
        validateWorkspace(self.io, supplied, &next.workspace) catch {
            return .{ .rejected = .invalid_workspace };
        };
        break :matches true;
    } else null;

    const created = !found;
    const content_actions = switch (planConfigurationUpdate(
        current_configuration,
        configuration,
        workspace_matches,
        &next,
    )) {
        .rejected => |rejection| return .{ .rejected = rejection },
        .update => |actions| actions,
    };

    var command_instructions_id: ?i64 = null;
    switch (content_actions.instructions) {
        .preserve => {},
        .import_requested => {
            command_instructions_id = try content_domain.importContent(self, &configuration.instructions, faults);
            next.instructions_id = command_instructions_id;
        },
        .default_empty => next.instructions_id = try content_domain.importEmptyContent(self),
        .clear => next.instructions_id = null,
    }
    var command_output_schema_id: ?i64 = null;
    switch (content_actions.output_schema) {
        .preserve => {},
        .import_requested => {
            command_output_schema_id = try content_domain.importContent(self, &configuration.output_schema, faults);
            next.output_schema_id = command_output_schema_id;
        },
        .default_empty => next.output_schema_id = try content_domain.importEmptyContent(self),
        .clear => next.output_schema_id = null,
    }
    var target: protocol.Bounded(protocol.max_session_bytes) = .{};
    if (created) {
        while (true) {
            var random: [protocol.session_id_bytes]u8 = undefined;
            try std.Io.randomSecure(self.io, &random);
            // 32 symbols divide 256 exactly: six independent five-bit
            // draws give 30 bits, without modulo bias or a weak PRNG.
            for (&random) |*byte| byte.* = protocol.session_alphabet[byte.* & 31];
            try target.set(&random);
            if (try insertSession(self, target.slice(), &next)) break;
        }
    } else {
        try target.set(session);
        try updateSession(self, target.slice(), &next);
    }
    try insertRevision(
        self,
        target.slice(),
        key,
        &next,
        created or configuration.instructions.state == .value,
    );
    return .{ .accepted = .{
        .session = target,
        .revision = next.revision,
        .instructions_id = command_instructions_id,
        .output_schema_id = command_output_schema_id,
    } };
}

fn saveConfigurationRejection(
    self: *Store,
    command: *const protocol.ConfigureCommand,
    digest: *const [32]u8,
    code: protocol.ConfigurationRejection,
    faults: Faults,
) !ConfigureReply {
    var answer = StoredAnswer{ .accepted = false };
    try answer.code.set(@tagName(code));
    try command_domain.insertCommand(
        self,
        command.key.slice(),
        .configure,
        command.session.slice(),
        digest,
        null,
        null,
        answer,
    );
    if (faults.before_commit) return error.InjectedCommitFailure;
    try store_core.execute(self, "COMMIT");
    return .{ .rejected = .{ .replayed = false, .code = code } };
}

/// Whether the Host serves the provider of the Session `configuration`
/// sets or `session_ref` already has. An unknown provider or Session
/// counts as served, so its own rejection answers.
pub fn servesProvider(self: *Store, configuration: ?*const protocol.Configuration, session_ref: []const u8) !bool {
    var all_served = true;
    inline for (@typeInfo(protocol.Provider).@"enum".field_names) |name| all_served = all_served and @field(self.served, name) != .unserved;
    if (all_served) return true;
    const provider = if (configuration != null and configuration.?.provider.state == .value)
        std.meta.stringToEnum(protocol.Provider, configuration.?.provider.value.slice()) orelse return true
    else provider: {
        const statement = try store_core.cached(self, "SELECT provider FROM session WHERE session_ref=?1");
        defer sqlite.resetCached(statement);
        try sqlite.bindText(statement, 1, session_ref);
        switch (c.sqlite3_step(statement)) {
            c.SQLITE_DONE => return true,
            c.SQLITE_ROW => break :provider try sqlite.readProvider(statement, 0),
            else => return error.SessionReadFailed,
        }
    };
    return protocol.routeOf(self.served, provider) != .unserved;
}

/// Answers whether the Session exists and, when it does, writes every
/// field of `current`. A missing one leaves `current` as the caller
/// declared it: `.{}`, the defaults a creation starts from.
pub fn readSession(self: *Store, session_ref: []const u8, current: *CurrentConfiguration) !bool {
    const statement = try store_core.cached(self, "SELECT workspace,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id,revision,next_position,provider,compaction_trigger,output_reservation,reasoning_effort,label,created_at FROM session WHERE session_ref=?1");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    const step_result = c.sqlite3_step(statement);
    if (step_result == c.SQLITE_DONE) return false;
    if (step_result != c.SQLITE_ROW) return error.SessionReadFailed;
    try sqlite.readText(statement, 0, &current.workspace);
    try sqlite.readText(statement, 1, &current.model);
    current.instructions_id = (sqlite.readNullablePositiveI64(statement, 2) catch return error.CorruptStore) orelse
        return error.CorruptStore;
    current.tools_mask = try sqlite.readToolsMask(statement, 3);
    current.permission_mode = try sqlite.readPermissionMode(statement, 4);
    current.output_schema_id = sqlite.readNullablePositiveI64(statement, 5) catch return error.CorruptStore;
    current.revision = try sqlite.readPositiveU64(statement, 6);
    current.next_position = try sqlite.readPositiveU64(statement, 7);
    current.provider = try sqlite.readProvider(statement, 8);
    current.compaction_trigger = try sqlite.readNullableTokens(statement, 9, false);
    current.output_reservation = try sqlite.readNullableTokens(statement, 10, true);
    current.reasoning_effort = try sqlite.readNullableEffort(statement, 11);
    current.label = try sqlite.readNullableLabel(statement, 12);
    current.created_at = @intCast(try sqlite.readNullablePositiveI64(statement, 13) orelse return error.CorruptStore);
    return true;
}

/// The Session facts turn work binds to, without the workspace or label
/// a whole configuration carries, and optionally its workspace.
pub fn readSessionFacts(self: *Store, session_ref: []const u8, workspace: ?*protocol.Bounded(protocol.max_workspace_bytes)) !?SessionFacts {
    const statement = try store_core.cached(self, "SELECT model,permission_mode,revision,next_position,compaction_trigger,output_reservation,reasoning_effort,created_at,provider,workspace FROM session WHERE session_ref=?1");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    const step_result = c.sqlite3_step(statement);
    if (step_result == c.SQLITE_DONE) return null;
    if (step_result != c.SQLITE_ROW) return error.SessionReadFailed;
    var facts: SessionFacts = .{
        .permission_mode = try sqlite.readPermissionMode(statement, 1),
        .revision = try sqlite.readPositiveU64(statement, 2),
        .next_position = try sqlite.readPositiveU64(statement, 3),
        .compaction_trigger = try sqlite.readNullableTokens(statement, 4, false),
        .output_reservation = try sqlite.readNullableTokens(statement, 5, true),
        .reasoning_effort = try sqlite.readNullableEffort(statement, 6),
        .created_at = @intCast(try sqlite.readNullablePositiveI64(statement, 7) orelse return error.CorruptStore),
        .provider = try sqlite.readProvider(statement, 8),
    };
    try sqlite.readText(statement, 0, &facts.model);
    if (workspace) |destination| try sqlite.readText(statement, 9, destination);
    return facts;
}

pub fn insertSession(self: *Store, session_ref: []const u8, current: *const CurrentConfiguration) !bool {
    // created_seq is max+1 inside the creating transaction; a Workspace's
    // key is the created_seq of its first Session.
    const statement = try store_core.cached(self, "INSERT INTO session(session_ref,workspace,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id,revision,next_position,provider,compaction_trigger,output_reservation,reasoning_effort,label,codec,workspace_digest,created_at,created_seq,workspace_key) " ++
        "SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,unixepoch(),allocated.seq,coalesce((SELECT workspace_key FROM session WHERE workspace_digest=?16 AND workspace=?2 LIMIT 1),allocated.seq) " ++
        "FROM (SELECT coalesce(max(created_seq),0)+1 AS seq FROM session) allocated WHERE true ON CONFLICT(session_ref) DO NOTHING");
    defer sqlite.resetCached(statement);
    try bindSettings(statement, session_ref, current);
    try sqlite.bindU64(statement, 9, current.next_position);
    try sqlite.bindText(statement, 15, @tagName(current.provider.codec()));
    const digest = store_core.workspaceDigest(current.workspace.slice());
    try sqlite.bindBlob(statement, 16, &digest);
    try sqlite.expectDone(statement);
    if (c.sqlite3_changes(self.database) != 1) return false;
    try store_core.touch(self, session_ref);
    return true;
}

fn updateSession(self: *Store, session_ref: []const u8, current: *const CurrentConfiguration) !void {
    try store_core.touch(self, session_ref);
    const statement = try store_core.cached(self, "UPDATE session SET workspace=?2,model=?3,instructions_content_id=?4,tools_mask=?5,permission_mode=?6,output_schema_content_id=?7,revision=?8,provider=?10,compaction_trigger=?11,output_reservation=?12,reasoning_effort=?13,label=?14 WHERE session_ref=?1");
    defer sqlite.resetCached(statement);
    try bindSettings(statement, session_ref, current);
    try sqlite.expectDone(statement);
    if (c.sqlite3_changes(self.database) != 1) return error.SessionUpdateFailed;
}

fn insertRevision(
    self: *Store,
    session_ref: []const u8,
    command_key: []const u8,
    current: *const CurrentConfiguration,
    instructions_updated: bool,
) !void {
    const statement = try store_core.cached(self, "INSERT INTO session_revision(session_ref,revision,command_key,workspace,model,instructions_content_id,instructions_updated,tools_mask,permission_mode,output_schema_content_id,provider,compaction_trigger,output_reservation,reasoning_effort,label) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    try sqlite.bindU64(statement, 2, current.revision);
    try sqlite.bindText(statement, 3, command_key);
    try sqlite.bindText(statement, 4, current.workspace.slice());
    try sqlite.bindText(statement, 5, current.model.slice());
    try sqlite.bindNullableI64(statement, 6, current.instructions_id);
    try sqlite.bindI64(statement, 7, @as(i64, if (instructions_updated) 1 else 0));
    try sqlite.bindI64(statement, 8, current.tools_mask);
    try sqlite.bindI64(statement, 9, current.permission_mode);
    try sqlite.bindNullableI64(statement, 10, current.output_schema_id);
    try sqlite.bindText(statement, 11, @tagName(current.provider));
    try sqlite.bindNullableU64(statement, 12, current.compaction_trigger);
    try sqlite.bindNullableU64(statement, 13, current.output_reservation);
    try sqlite.bindNullableEffort(statement, 14, current.reasoning_effort);
    try sqlite.bindOptionalLabel(statement, 15, &current.label);
    try sqlite.expectDone(statement);
}

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

/// Binds every session column except `next_position` (?9), which only
/// `claimSessionPositions` advances.
fn bindSettings(statement: *c.sqlite3_stmt, session_ref: []const u8, current: *const CurrentConfiguration) !void {
    try sqlite.bindText(statement, 1, session_ref);
    try sqlite.bindText(statement, 2, current.workspace.slice());
    try sqlite.bindText(statement, 3, current.model.slice());
    try sqlite.bindNullableI64(statement, 4, current.instructions_id);
    try sqlite.bindI64(statement, 5, current.tools_mask);
    try sqlite.bindI64(statement, 6, current.permission_mode);
    try sqlite.bindNullableI64(statement, 7, current.output_schema_id);
    try sqlite.bindU64(statement, 8, current.revision);
    try sqlite.bindText(statement, 10, @tagName(current.provider));
    try sqlite.bindNullableU64(statement, 11, current.compaction_trigger);
    try sqlite.bindNullableU64(statement, 12, current.output_reservation);
    try sqlite.bindNullableEffort(statement, 13, current.reasoning_effort);
    try sqlite.bindOptionalLabel(statement, 14, &current.label);
}
