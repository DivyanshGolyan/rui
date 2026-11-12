const std = @import("std");
const session_settings = @import("session_settings.zig");
const Bounded = @import("bounded.zig").Bounded;
const session_id = @import("session_id.zig");
const store_id = @import("store_id.zig");
const tool_name = @import("tool_name.zig");
const PermissionDecision = @import("mutation_answer.zig").PermissionDecision;
const max_store_bytes = @import("store_path.zig").max_bytes;
const max_key_bytes = @import("idempotency_key.zig").max_bytes;
const max_session_bytes = session_id.max_reference_bytes;
const validSessionId = session_id.valid;
const max_workspace_bytes = @import("workspace_path.zig").max_bytes;
pub const max_provider_bytes = 16;
const max_model_bytes = @import("model_capability.zig").max_model_bytes;
const max_label_bytes = @import("tool_presentation.zig").max_label_bytes;
const max_tool_names_bytes = tool_name.max_names_bytes;
const max_tool_list_name_bytes = tool_name.max_list_name_bytes;
const max_tools = tool_name.max_tools;
const validToolName = tool_name.valid;
pub const max_preset_name_bytes = 64;
pub const max_sender_handle_bytes = 32;

pub fn Commands(comptime Custody: type) type {
    return struct {
        pub const ContentField = ContentFieldOf(Custody);
        pub const Configuration = ConfigurationOf(Custody);
        pub const ConfigureCommand = ConfigureCommandOf(Custody);
        pub const MessageCommand = MessageCommandOf(Custody);
    };
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

fn ContentFieldOf(comptime Custody: type) type {
    return struct {
        const ContentField = @This();

        state: FieldState = .omitted,
        // A parsed request owns an unlinked file descriptor. The Store imports
        // through this sealed custody; no pathname can be swapped after capture.
        file: ?Custody.File = null,
        /// D113: bounded start_agent content borrows its call arena through commit;
        /// `length` counts it. Wire content still uses sealed file custody; this
        /// pointer is never saved. A bare pointer keeps ContentField, which the
        /// configure path copies, no larger than one word.
        borrowed: ?[*]const u8 = null,
        scratch_budget: ?Custody.Budget = null,
        charged: u64 = 0,
        length: u64 = 0,
        digest: [32]u8 = @splat(0),
        /// While a request is parsed, which Ingress capture holds this value,
        /// counted from 1 in arrival order; 0 once it holds its own file.
        capture: u8 = 0,

        pub fn borrowedBytes(self: *const ContentField) ?[]const u8 {
            const bytes = self.borrowed orelse return null;
            return bytes[0..@intCast(self.length)];
        }

        pub fn hasFile(self: *const ContentField) bool {
            return self.file != null;
        }

        /// Releases the custody this value holds, and leaves it omitted.
        pub fn removeTemporaryContent(self: *ContentField, io: Custody.Io) !void {
            Custody.release(self.file, self.scratch_budget, self.charged, io);
            self.charged = 0;
            self.file = null;
            self.borrowed = null;
            self.state = .omitted;
        }
    };
}

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

    /// Adds one name in canonical order, refusing duplicates and bound overflow.
    pub fn insert(self: *ToolsField, name: []const u8) error{ InvalidToolName, InvalidJsonShape }!void {
        if (!validToolName(name)) return error.InvalidToolName;
        var names = self.iterator();
        var at: usize = 0;
        while (names.next()) |held| {
            switch (std.mem.order(u8, held, name)) {
                .eq => return error.InvalidJsonShape,
                .gt => break,
                .lt => at += held.len + 1,
            }
        }
        if (at >= self.names.len) return self.append(name);
        if (self.count == max_tools or self.names.len - (self.count -| 1) + name.len > max_tool_list_name_bytes)
            return error.InvalidJsonShape;
        const added = name.len + 1;
        std.mem.copyBackwards(u8, self.names.bytes[at + added ..][0 .. self.names.len - at], self.names.bytes[at..self.names.len]);
        @memcpy(self.names.bytes[at..][0..name.len], name);
        self.names.bytes[at + name.len] = ' ';
        self.names.len += added;
        self.count += 1;
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

fn ConfigurationOf(comptime Custody: type) type {
    const ContentField = Commands(Custody).ContentField;
    return struct {
        const Configuration = @This();

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
        /// Creation relation, never a revisioned setting.
        parent: OptionalBounded(6) = .{},

        comptime {
            const fields = @typeInfo(Configuration).@"struct";
            if (fields.field_names.len != session_settings.spec_entries.len)
                @compileError("Session settings table must cover Configuration exactly");
            for (session_settings.spec_entries, fields.field_names, fields.field_types) |entry, name, Field| {
                if (!std.mem.eql(u8, entry.field, name))
                    @compileError("Session settings table must follow Configuration field order: " ++ name);
                const Expected = switch (entry.kind) {
                    .text, .choice => |capacity| OptionalBounded(capacity),
                    .decimal_policy => OptionalBounded(20),
                    .content => ContentField,
                    .tools => ToolsField,
                };
                if (Field != Expected) @compileError("Session setting kind/type mismatch: " ++ name);
            }
        }

        pub fn removeTemporaryContent(self: *Configuration, io: Custody.Io) !void {
            var cleanup_error: ?anyerror = null;
            self.instructions.removeTemporaryContent(io) catch |err| {
                cleanup_error = err;
            };
            self.output_schema.removeTemporaryContent(io) catch |err| {
                cleanup_error = err;
            };
            if (cleanup_error) |err| return err;
        }
    };
}

fn ConfigureCommandOf(comptime Custody: type) type {
    const Configuration = Commands(Custody).Configuration;
    return struct {
        const ConfigureCommand = @This();

        store: Bounded(max_store_bytes) = .{},
        key: Bounded(max_key_bytes) = .{},
        session: Bounded(max_session_bytes) = .{},
        configuration: Configuration = .{},
        /// Host-memory creation seed; its resolution or refusal is supplied to the Store.
        preset: ?Bounded(max_preset_name_bytes) = null,
        require_model: bool = false,
        reload_skills: bool = false,

        pub fn removeTemporaryContent(self: *ConfigureCommand, io: Custody.Io) !void {
            return self.configuration.removeTemporaryContent(io);
        }

        pub fn semanticDigest(self: *const ConfigureCommand) [32]u8 {
            const base = configureDigest(self.session.slice(), &self.configuration, self.require_model);
            if (!self.reload_skills) return base;
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update("rui/core/reload-skills/v1");
            hash.update(&base);
            return hash.finalResult();
        }

        /// A preset refusal binds the unresolved request, including its name;
        /// unlike an accepted creation, it has no resolved spec to identify.
        pub fn presetRequestDigest(self: *const ConfigureCommand) [32]u8 {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hashField(&hash, "rui/core/configure-preset-request/v1");
            hash.update(&self.semanticDigest());
            hash.update(&.{@intFromBool(self.preset != null)});
            if (self.preset) |name| hashField(&hash, name.slice());
            return hash.finalResult();
        }
    };
}

/// The digest of a Configure command with these parts; a creating Message
/// binds its initial configuration through the same digest.
fn configureDigest(session: []const u8, configuration: anytype, require_model: bool) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hash, "rui/core/configure/v1");
    hashField(&hash, session);
    inline for (session_settings.entries) |entry| {
        const name = entry.field;
        if (comptime entry.digest == .always) hashSetting(&hash, entry, &@field(configuration, name));
    }
    hash.update(&.{@intFromBool(require_model)});
    // Omission retains the pre-loaded-tools digest, including creating
    // Messages: saved requests must still replay after a Store upgrade.
    inline for (session_settings.entries) |entry| {
        if (comptime entry.digest == .unless_omitted) {
            const name = entry.field;
            const field = &@field(configuration, name);
            if (field.state != .omitted) {
                hashField(&hash, "rui/core/configure/loaded-tools/v1");
                hashSetting(&hash, entry, field);
            }
        }
    }
    if (configuration.parent.state != .omitted) {
        hashField(&hash, "rui/core/configure/parent/v1");
        hashOptional(&hash, &configuration.parent);
    }
    return hash.finalResult();
}

fn hashSetting(hash: *std.crypto.hash.sha2.Sha256, comptime entry: session_settings.Entry, field: anytype) void {
    switch (entry.kind) {
        .content => hashContent(hash, field),
        .tools => hashTools(hash, field),
        .text, .choice, .decimal_policy => hashOptional(hash, field),
    }
}

fn MessageCommandOf(comptime Custody: type) type {
    const Configuration = Commands(Custody).Configuration;
    const ContentField = Commands(Custody).ContentField;
    return struct {
        const MessageCommand = @This();

        store: Bounded(max_store_bytes) = .{},
        key: Bounded(max_key_bytes) = .{},
        session: Bounded(max_session_bytes) = .{},
        // The full sending address; null when a human or script sends.
        sender: ?Address = null,
        sender_handle: ?Bounded(max_sender_handle_bytes) = null,
        text: ContentField = .{},
        // Non-null means create a fresh Session and admit this first Message in
        // one transaction. The requested Session must then be empty; its spec
        // carries the same instruction and schema custody as configure.
        configuration: ?Configuration = null,
        // A creating Message only: create nothing unless the Host has a model.
        require_model: bool = false,

        pub fn removeTemporaryContent(self: *MessageCommand, io: Custody.Io) !void {
            var failure: ?anyerror = null;
            self.text.removeTemporaryContent(io) catch |err| {
                failure = err;
            };
            if (self.configuration) |*configuration| configuration.removeTemporaryContent(io) catch |err| {
                if (failure == null) failure = err;
            };
            if (failure) |err| return err;
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
}

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

pub const SessionArchiveCommand = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},

    archived: bool = true,

    pub fn semanticDigest(self: *const SessionArchiveCommand) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hash, "rui/core/session-archive/v1");
        hashField(&hash, self.session.slice());
        hash.update(&.{@intFromBool(self.archived)});
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

fn hashContent(hash: *std.crypto.hash.sha2.Sha256, field: anytype) void {
    hash.update(&.{@backingInt(field.state)});
    if (field.state == .value) {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, field.length, .big);
        hash.update(&length);
        hash.update(&field.digest);
    }
}
