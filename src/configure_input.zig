const std = @import("std");
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
    profile: OptionalPolicy = .{},
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
    preferences: Preferences = .{},

    pub const Preferences = struct {
        reasoning_effort: ?ReasoningEffort = null,
        permission_mode: ?PermissionMode = null,
    };

    pub fn creationReads(self: ConfigureInput) struct { binding: bool, preferences: bool, saved_effort: bool } {
        const binding = !self.parent.present or !self.model.present;
        const binding_preferences = binding and (!self.provider.present or !self.model.present);
        const saved_effort = !self.reasoning_effort.present;
        return .{ .binding = binding, .preferences = binding_preferences or saved_effort or !self.permission_mode.present, .saved_effort = saved_effort };
    }

    /// Keep personal choices distinct from explicit settings for the Host.
    pub fn applySavedCreation(self: *ConfigureInput, saved_effort: ?ReasoningEffort, saved_permission: ?PermissionMode) void {
        self.preferences = .{ .reasoning_effort = saved_effort, .permission_mode = saved_permission };
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

fn expectPolicy(expected: OptionalPolicy, actual: OptionalPolicy) !void {
    try std.testing.expectEqual(expected.present, actual.present);
    try std.testing.expectEqual(expected.value != null, actual.value != null);
    if (expected.value) |value| try std.testing.expectEqualStrings(value, actual.value.?);
}

fn expectNames(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got);
}

fn checkCreationCombinations() !void {
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
                        input.applySavedCreation(saved_effort, saved_permission);
                        try std.testing.expectEqual(mask & 1 != 0, input.tools != null);
                        if (input.tools) |tools| try std.testing.expectEqual(@as(usize, 0), tools.names.len);
                        try std.testing.expectEqual(mask & 2 != 0, input.loaded_tools != null);
                        if (input.loaded_tools) |tools| try std.testing.expectEqualStrings("none", tools.names[0]);
                        try std.testing.expectEqual(mask & 4 != 0, input.permission_mode.present);
                        try expectPolicy(effort, input.reasoning_effort);
                        try std.testing.expectEqual(saved_effort, input.preferences.reasoning_effort);
                        try std.testing.expectEqual(saved_permission, input.preferences.permission_mode);
                        try expectPolicy(compact, input.compaction_trigger);
                        try std.testing.expect(!input.provider.present and !input.model.present and !input.workspace.present);
                        try std.testing.expectEqual(mask & 8 != 0, input.parent.present);
                    }
                }
            }
        }
    }
}

fn checkSavedEffort() !void {
    var input: ConfigureInput = .{ .store = "", .session = .create };
    input.applySavedCreation(.max, .ask);
    try std.testing.expectEqual(@as(?ReasoningEffort, .max), input.preferences.reasoning_effort);
    try std.testing.expectEqual(@as(?PermissionMode, .ask), input.preferences.permission_mode);
    try std.testing.expect(!input.reasoning_effort.present and !input.permission_mode.present);
}

fn checkCreationReads() !void {
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

fn checkToolIntent() !void {
    for ([_][]const u8{ "", "none", "bash", "find_tools" }) |allowed| {
        for ([_]?[]const u8{ null, "", "none", "find_tools" }) |loaded| {
            var input: ConfigureInput = .{ .store = "", .session = .create, .tools = .{ .cli = allowed }, .loaded_tools = if (loaded) |text| .{ .cli = text } else null };
            input.applySavedCreation(null, null);
            try std.testing.expectEqualStrings(allowed, input.tools.?.cli);
            if (loaded) |text| try std.testing.expectEqualStrings(text, input.loaded_tools.?.cli) else try std.testing.expect(input.loaded_tools == null);
        }
    }
    for ([_][]const []const u8{ &.{}, &.{"none"}, &.{ "bash", "mcp/arbitrary" } }) |names| {
        var input: ConfigureInput = .{ .store = "", .session = .create, .tools = .{ .names = names }, .loaded_tools = .{ .names = names } };
        input.applySavedCreation(null, null);
        try expectNames(names, input.tools.?.names);
        try expectNames(names, input.loaded_tools.?.names);
    }
    var loaded_only: ConfigureInput = .{ .store = "", .session = .create, .loaded_tools = .{ .cli = "find_tools" } };
    loaded_only.applySavedCreation(null, null);
    try std.testing.expect(loaded_only.tools == null);
    try std.testing.expectEqualStrings("find_tools", loaded_only.loaded_tools.?.cli);
}

fn checkImageToolIntent() !void {
    for ([_][]const []const u8{ &.{}, &.{"read_image"}, &.{ "bash", "read_image" } }) |allowed| {
        for ([_]?[]const []const u8{ null, &.{}, &.{"read_image"} }) |loaded| {
            var input: ConfigureInput = .{
                .store = "",
                .session = .create,
                .tools = .{ .names = allowed },
                .loaded_tools = if (loaded) |names| .{ .names = names } else null,
            };
            input.applySavedCreation(.max, .ask);
            try expectNames(allowed, input.tools.?.names);
            if (loaded) |names| try expectNames(names, input.loaded_tools.?.names) else try std.testing.expect(input.loaded_tools == null);
            try std.testing.expectEqual(@as(?ReasoningEffort, .max), input.preferences.reasoning_effort);
            try std.testing.expectEqual(@as(?PermissionMode, .ask), input.preferences.permission_mode);
        }
    }
}

test "CLI-29 saved creation intent" {
    try checkCreationCombinations();
    try checkSavedEffort();
    try checkCreationReads();
    try checkToolIntent();
    try checkImageToolIntent();
}
