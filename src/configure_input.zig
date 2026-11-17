const std = @import("std");
const client_defaults = @import("client_defaults.zig");
const ReasoningEffort = @import("model_catalog.zig").ReasoningEffort;
const PermissionMode = @import("cli_value.zig").PermissionMode;

pub const OptionalText = struct {
    present: bool = false,
    value: []const u8 = "",
};

pub const OptionalPolicy = struct {
    present: bool = false,
    value: ?[]const u8 = null,
};

pub const OptionalFile = struct {
    state: enum { omitted, value, explicit_null } = .omitted,
    path: []const u8 = "",
};

/// Borrowed through capture; only CLI spelling interprets "none" as empty.
pub const ToolInput = union(enum) {
    cli: []const u8,
    names: []const []const u8,
};

pub const ConfigureInput = struct {
    store: []const u8,
    session: union(enum) {
        named: []const u8,
        create,
    },
    parent: OptionalText = .{},
    preset: OptionalText = .{},
    require_model: bool = false,
    reload_skills: bool = false,
    workspace: OptionalText = .{},
    provider: OptionalText = .{},
    model: OptionalText = .{},
    instructions: OptionalFile = .{},
    tools: ?ToolInput = null,
    loaded_tools: ?ToolInput = null,
    permission_mode: OptionalText = .{},
    output_schema: OptionalFile = .{},
    compaction_trigger: OptionalPolicy = .{},
    output_reservation: OptionalPolicy = .{},
    reasoning_effort: OptionalPolicy = .{},
    label: OptionalPolicy = .{},

    pub fn creationReads(self: ConfigureInput) struct { binding: bool, preferences: bool, saved_effort: bool } {
        const binding = !self.parent.present or !self.model.present;
        const binding_preferences = binding and (!self.provider.present or !self.model.present);
        const saved_effort = binding_preferences or (self.parent.present and !self.reasoning_effort.present);
        return .{ .binding = binding, .preferences = saved_effort or !self.permission_mode.present, .saved_effort = saved_effort };
    }

    /// Personal preferences remain explicit client choices until they move to the Host.
    /// An unsupported saved effort retains its former fallback: the wire cannot
    /// distinguish a preference from an explicit effort supplied by the caller.
    pub fn applySavedCreation(self: *ConfigureInput, model: []const u8, saved_effort: ?ReasoningEffort, saved_permission: ?PermissionMode) void {
        if (!self.reasoning_effort.present and saved_effort != null) {
            const effort = client_defaults.savedEffort(model, saved_effort.?);
            self.reasoning_effort = .{ .present = true, .value = if (effort) |value| @tagName(value) else null };
        }
        if (!self.permission_mode.present) if (saved_permission) |mode| {
            self.permission_mode = .{ .present = true, .value = @tagName(mode) };
        };
    }
};

pub fn policy(text: []const u8) OptionalPolicy {
    return .{ .present = true, .value = if (std.mem.eql(u8, text, "default")) null else text };
}

test "a policy argument resets with default and keeps any other spelling" {
    const reset = policy("default");
    try std.testing.expect(reset.present and reset.value == null);
    try std.testing.expectEqualStrings("00042", policy("00042").value.?);
    try std.testing.expectEqualStrings("Default", policy("Default").value.?);
}

test "fresh creation preserves every omitted explicit and reset setting combination" {
    // Independent oracle: an omitted member stays omitted, explicit empty tool
    // lists stay empty, and null policy resets stay null. Only saved choices fill.
    for (0..16) |mask| {
        for (0..3) |effort_state| {
            for (0..3) |compact_state| {
                for ([_]?ReasoningEffort{ null, .high }) |saved_effort| {
                    for ([_]?PermissionMode{ null, .ask, .bypass }) |saved_permission| {
                        const effort: OptionalPolicy = switch (effort_state) {
                            0 => .{},
                            1 => policy("max"),
                            else => policy("default"),
                        };
                        const compact: OptionalPolicy = switch (compact_state) {
                            0 => .{},
                            1 => policy("00042"),
                            else => policy("default"),
                        };
                        var input: ConfigureInput = .{
                            .store = "/store",
                            .session = .create,
                            .parent = if (mask & 8 != 0) .{ .present = true, .value = "k7m2qx" } else .{},
                            .tools = if (mask & 1 != 0) .{ .names = &.{} } else null,
                            .loaded_tools = if (mask & 2 != 0) .{ .names = &.{"none"} } else null,
                            .permission_mode = if (mask & 4 != 0) .{ .present = true, .value = "bypass" } else .{},
                            .reasoning_effort = effort,
                            .compaction_trigger = compact,
                        };
                        input.applySavedCreation("gpt-6.1-sol", saved_effort, saved_permission);
                        try std.testing.expectEqual(mask & 1 != 0, input.tools != null);
                        if (input.tools) |tools| try std.testing.expectEqual(@as(usize, 0), tools.names.len);
                        try std.testing.expectEqual(mask & 2 != 0, input.loaded_tools != null);
                        if (input.loaded_tools) |tools| try std.testing.expectEqualStrings("none", tools.names[0]);
                        try std.testing.expectEqual(mask & 4 != 0 or saved_permission != null, input.permission_mode.present);
                        if (input.permission_mode.present) try std.testing.expectEqualStrings(if (mask & 4 != 0) "bypass" else @tagName(saved_permission.?), input.permission_mode.value);
                        try std.testing.expectEqual(effort.present or saved_effort != null, input.reasoning_effort.present);
                        const expected_effort = if (effort.present) effort.value else if (saved_effort != null) @as(?[]const u8, "high") else null;
                        if (expected_effort) |value| try std.testing.expectEqualStrings(value, input.reasoning_effort.value.?) else try std.testing.expect(input.reasoning_effort.value == null);
                        try std.testing.expectEqualDeep(compact, input.compaction_trigger);
                        try std.testing.expect(!input.provider.present and !input.model.present and !input.workspace.present);
                        try std.testing.expectEqual(mask & 8 != 0, input.parent.present);
                    }
                }
            }
        }
    }
}

test "saved creation effort preserves supported and unsupported preference behavior" {
    const cases = [_]struct { model: []const u8, saved: ReasoningEffort, expected: ?[]const u8 }{
        .{ .model = "gpt-6.1-sol", .saved = .max, .expected = "max" },
        .{ .model = "gpt-5.5", .saved = .max, .expected = "low" },
        .{ .model = "azure/gpt-5-pro", .saved = .low, .expected = "high" },
        .{ .model = "openai/whisper-1", .saved = .high, .expected = null },
        .{ .model = "unlisted-model", .saved = .max, .expected = "max" },
    };
    for (cases) |case| {
        var input: ConfigureInput = .{ .store = "", .session = .create };
        input.applySavedCreation(case.model, case.saved, null);
        try std.testing.expect(input.reasoning_effort.present);
        if (case.expected) |value| try std.testing.expectEqualStrings(value, input.reasoning_effort.value.?) else try std.testing.expect(input.reasoning_effort.value == null);
    }
}

test "parent creation reads no binding or preferences when supplied choices suffice" {
    var input: ConfigureInput = .{
        .store = "/store",
        .session = .create,
        .parent = .{ .present = true, .value = "k7m2qx" },
        .model = .{ .present = true, .value = "unlisted-model" },
        .permission_mode = .{ .present = true, .value = "ask" },
        .reasoning_effort = policy("high"),
    };
    const reads = input.creationReads();
    try std.testing.expect(!reads.binding and !reads.preferences and !reads.saved_effort);
    input.reasoning_effort = .{};
    try std.testing.expect(!input.creationReads().binding and input.creationReads().preferences);
    input.reasoning_effort = policy("default");
    input.compaction_trigger = policy("default");
    try std.testing.expect(!input.creationReads().binding and !input.creationReads().preferences);
    input.model = .{};
    try std.testing.expect(input.creationReads().binding and input.creationReads().preferences);
}

test "saved creation preserves every CLI and semantic tool intent" {
    for ([_][]const u8{ "", "none", "bash", "find_tools" }) |allowed| {
        for ([_]?[]const u8{ null, "", "none", "find_tools" }) |loaded| {
            var input: ConfigureInput = .{ .store = "", .session = .create, .tools = .{ .cli = allowed }, .loaded_tools = if (loaded) |text| .{ .cli = text } else null };
            input.applySavedCreation("unlisted-model", null, null);
            try std.testing.expectEqualStrings(allowed, input.tools.?.cli);
            if (loaded) |text| try std.testing.expectEqualStrings(text, input.loaded_tools.?.cli) else try std.testing.expect(input.loaded_tools == null);
        }
    }
    for ([_][]const []const u8{ &.{}, &.{"none"}, &.{ "bash", "mcp/arbitrary" } }) |names| {
        var input: ConfigureInput = .{ .store = "", .session = .create, .tools = .{ .names = names }, .loaded_tools = .{ .names = names } };
        input.applySavedCreation("unlisted-model", null, null);
        try std.testing.expectEqualDeep(names, input.tools.?.names);
        try std.testing.expectEqualDeep(names, input.loaded_tools.?.names);
    }
    var loaded_only: ConfigureInput = .{ .store = "", .session = .create, .loaded_tools = .{ .cli = "find_tools" } };
    loaded_only.applySavedCreation("unlisted-model", null, null);
    try std.testing.expect(loaded_only.tools == null);
    try std.testing.expectEqualStrings("find_tools", loaded_only.loaded_tools.?.cli);
}
