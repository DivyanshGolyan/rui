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
pub const max_connection_bytes = @import("connection.zig").max_name_bytes;
const max_model_bytes = @import("model_capability.zig").max_model_bytes;
const max_label_bytes = @import("tool_presentation.zig").max_label_bytes;
const max_tool_names_bytes = tool_name.max_names_bytes;
const max_tool_list_name_bytes = tool_name.max_list_name_bytes;
const max_tools = tool_name.max_tools;
const validToolName = tool_name.valid;
pub const max_preset_name_bytes = 64;

pub fn Commands(comptime Custody: type) type {
    return struct {
        pub const ContentField = ContentFieldOf(Custody);
        pub const Configuration = ConfigurationOf(Custody);
        pub const ConfigureCommand = ConfigureCommandOf(Custody);
        pub const MessageCommand = MessageCommandOf(Custody);
    };
}

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
        file: ?Custody.File = null,
        borrowed: ?[*]const u8 = null,
        scratch_budget: ?Custody.Budget = null,
        charged: u64 = 0,
        length: u64 = 0,
        digest: [32]u8 = @splat(0),
        capture: u8 = 0,

        pub fn borrowedBytes(self: *const ContentField) ?[]const u8 {
            const bytes = self.borrowed orelse return null;
            return bytes[0..@intCast(self.length)];
        }

        pub fn hasFile(self: *const ContentField) bool {
            return self.file != null;
        }

        pub fn removeTemporaryContent(self: *ContentField, io: Custody.Io) !void {
            Custody.release(self.file, self.scratch_budget, self.charged, io);
            self.charged = 0;
            self.file = null;
            self.borrowed = null;
            self.state = .omitted;
        }
    };
}

pub const ToolsField = struct {
    state: FieldState = .omitted,
    count: u8 = 0,
    names: Bounded(max_tool_names_bytes) = .{},

    pub fn iterator(self: *const ToolsField) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, self.names.slice(), ' ');
    }

    pub fn eql(self: *const ToolsField, other: *const ToolsField) bool {
        return self.state == other.state and self.count == other.count and self.names.eql(other.names.slice());
    }

    pub fn contains(self: *const ToolsField, name: []const u8) bool {
        var names = self.iterator();
        while (names.next()) |held| if (std.mem.eql(u8, held, name)) return true;
        return false;
    }

    pub fn of(names: []const []const u8) error{ InvalidToolName, InvalidJsonShape }!ToolsField {
        var out: ToolsField = .{ .state = .value };
        for (names) |name| try out.append(name);
        return out;
    }

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

    pub fn append(self: *ToolsField, name: []const u8) error{ InvalidToolName, InvalidJsonShape }!void {
        if (!validToolName(name)) return error.InvalidToolName;
        if (self.count == max_tools) return error.InvalidJsonShape;
        const held = self.names.slice();
        if (self.count != 0) {
            const last = held[if (std.mem.lastIndexOfScalar(u8, held, ' ')) |space| space + 1 else 0..];
            if (std.mem.order(u8, last, name) != .lt) return error.InvalidJsonShape;
        }
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

pub const Preferences = struct {
    reasoning_effort: OptionalBounded(16) = .{},
    permission_mode: OptionalBounded(16) = .{},
};

fn ConfigurationOf(comptime Custody: type) type {
    const ContentField = Commands(Custody).ContentField;
    return struct {
        const Configuration = @This();

        workspace: OptionalBounded(max_workspace_bytes) = .{},
        provider: OptionalBounded(max_connection_bytes) = .{},
        model: OptionalBounded(max_model_bytes) = .{},
        instructions: ContentField = .{},
        tools: ToolsField = .{},
        loaded_tools: ToolsField = .{},
        permission_mode: OptionalBounded(16) = .{},
        output_schema: ContentField = .{},
        compaction_trigger: OptionalBounded(20) = .{},
        output_reservation: OptionalBounded(20) = .{},
        reasoning_effort: OptionalBounded(16) = .{},
        label: OptionalBounded(max_label_bytes) = .{},
        // The declared app records as one JSON document in file custody, validated when the declaration is parsed.
        app_tools: ContentField = .{},
        parent: OptionalBounded(6) = .{},
        preferences: ?Preferences = null,

        comptime {
            const fields = @typeInfo(Configuration).@"struct";
            if (fields.field_names.len != session_settings.spec_entries.len + 1)
                @compileError("Session settings table must cover Configuration exactly");
            for (session_settings.spec_entries, fields.field_names[0..session_settings.spec_entries.len], fields.field_types[0..session_settings.spec_entries.len]) |entry, name, Field| {
                if (!std.mem.eql(u8, entry.field, name))
                    @compileError("Session settings table must follow Configuration field order: " ++ name);
                const Expected = switch (entry.kind) {
                    .text, .choice => |capacity| OptionalBounded(capacity),
                    .decimal_policy => OptionalBounded(20),
                    .content => ContentField,
                    .tools => ToolsField,
                    .app_tools => ContentField,
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
            self.app_tools.removeTemporaryContent(io) catch |err| {
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

fn configureDigest(session: []const u8, configuration: anytype, require_model: bool) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hash, "rui/core/configure/v1");
    hashField(&hash, session);
    inline for (session_settings.entries) |entry| {
        const name = entry.field;
        if (comptime entry.digest == .always) hashSetting(&hash, entry, &@field(configuration, name));
    }
    hash.update(&.{@intFromBool(require_model)});
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
    if (configuration.preferences) |preferences| {
        hashField(&hash, "rui/core/configure/preferences/v1");
        hashOptional(&hash, &preferences.reasoning_effort);
        hashOptional(&hash, &preferences.permission_mode);
    }
    return hash.finalResult();
}

fn hashSetting(hash: *std.crypto.hash.sha2.Sha256, comptime entry: session_settings.Entry, field: anytype) void {
    switch (entry.kind) {
        .content => hashContent(hash, field),
        .tools => hashTools(hash, field),
        .text, .choice, .decimal_policy => hashOptional(hash, field),
        .app_tools => hashContent(hash, field),
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
        text: ContentField = .{},
        configuration: ?Configuration = null,
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
            return self.inputDigest(null);
        }

        pub fn semanticDigestForInput(self: *const MessageCommand, reference: @import("input_parts.zig").Reference) [32]u8 {
            return self.inputDigest(reference);
        }

        fn inputDigest(self: *const MessageCommand, input: ?@import("input_parts.zig").Reference) [32]u8 {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hashField(&hash, "rui/core/message/v5");
            hashField(&hash, self.session.slice());
            if (input) |reference| {
                const identity = reference.identity();
                hashContentIdentity(&hash, .value, identity.length, &identity.digest);
            } else hashContent(&hash, &self.text);
            if (self.configuration) |*configuration| {
                hashField(&hash, "initial-configuration");
                hash.update(&configureDigest("", configuration, self.require_model));
            } else if (self.require_model) hashField(&hash, "require-model");
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

pub const SessionPinCommand = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},

    pinned: bool = true,

    pub fn semanticDigest(self: *const SessionPinCommand) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hash, "rui/core/session-pin/v1");
        hashField(&hash, self.session.slice());
        hash.update(&.{@intFromBool(self.pinned)});
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

pub const ActionBackgroundCommand = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    action_id: u64 = 0,

    pub fn semanticDigest(self: *const ActionBackgroundCommand) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hash, "rui/core/action-background/v1");
        hashField(&hash, self.session.slice());
        var value: [8]u8 = undefined;
        std.mem.writeInt(u64, &value, self.action_id, .big);
        hash.update(&value);
        return hash.finalResult();
    }
};

pub const ActionStopCommand = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    action_id: u64 = 0,

    pub fn semanticDigest(self: *const ActionStopCommand) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hash, "rui/core/action-stop/v1");
        hashField(&hash, self.session.slice());
        var value: [8]u8 = undefined;
        std.mem.writeInt(u64, &value, self.action_id, .big);
        hash.update(&value);
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
    hashContentIdentity(hash, field.state, field.length, &field.digest);
}

fn hashContentIdentity(hash: *std.crypto.hash.sha2.Sha256, state: FieldState, size: u64, digest: *const [32]u8) void {
    hash.update(&.{@backingInt(state)});
    if (state == .value) {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, size, .big);
        hash.update(&length);
        hash.update(digest);
    }
}

test "tool list equality compares semantic names rather than unused capacity" {
    var first = try ToolsField.of(&.{ "bash", "none" });
    var second = first;
    @memset(first.names.bytes[first.names.len..], 'a');
    @memset(second.names.bytes[second.names.len..], 'b');
    try std.testing.expect(first.eql(&second));
    second.count -= 1;
    try std.testing.expect(!first.eql(&second));
    second = first;
    second.state = .omitted;
    try std.testing.expect(!first.eql(&second));
    second = try .of(&.{ "bash", "lookup" });
    try std.testing.expect(!first.eql(&second));
}
