pub const Rejection = enum {
    invalid_session_reference,
    unknown_session,
    unsupported_permission_mode,
    unsupported_provider,
    invalid_model,
    model_capability_unavailable,
    invalid_output_schema,
    invalid_compaction_trigger,
    compact_at_too_large,
    invalid_output_reservation,
    unsupported_reasoning_effort,
    unknown_tool,
    mcp_server_unavailable,
    provider_tool_missing,
    loaded_tools_not_in_tools,
    loaded_tools_unreachable,
    invalid_label,
    missing_settings,
    settings_on_reload,
    unknown_preset,
    preset_on_update,
    parent_on_update,
    parent_provider_forbidden,
    parent_workspace_forbidden,
    tools_not_in_parent,
    permission_mode_wider_than_parent,

    invalid_workspace,
    workspace_is_immutable,
    provider_is_immutable,
    model_is_immutable,
    revision_exhausted,
    skills_unavailable,
    preferences_on_update,
    invalid_app_tools,
    app_tools_too_large,
    invalid_app_tool_name,
    duplicate_app_tool_name,
    app_tool_built_in_clash,
    invalid_app_tool_policy,
    app_tools_on_child,
    connection_unserved,
};

const std = @import("std");
const tool = @import("built_in_tool.zig");
const ToolsField = @import("command_input.zig").ToolsField;

/// A picker edit owns the names the person saw, through asynchronous capture.
/// Admission remains responsible for membership, reachability and availability.
pub const ToolEdit = struct {
    allowed: ToolsField = .{ .state = .value },
    loaded: ToolsField = .{ .state = .value },

    pub fn replaceBuiltIns(self: *ToolEdit, allowed: *const ToolsField, loaded: *const ToolsField, selected: tool.Selection) !void {
        var retained = loaded.iterator();
        while (retained.next()) |name| if (!allowed.contains(name)) return error.LoadedToolsNotAllowed;
        self.* = .{};
        var names = allowed.iterator();
        while (names.next()) |name| {
            if (std.meta.stringToEnum(tool.BuiltInTool, name) == null) try self.allowed.insert(name);
        }
        var builtins = selected.iterator();
        while (builtins.next()) |builtin| try self.allowed.insert(@tagName(builtin));
        var initial = loaded.iterator();
        while (initial.next()) |name| {
            if (std.meta.stringToEnum(tool.BuiltInTool, name)) |builtin| {
                if (!selected.contains(builtin)) continue;
            }
            try self.loaded.append(name);
        }
    }
};

test "tool picker replacement preserves arbitrary allowed and loaded intent across the built-in domain" {
    const initial: tool.Selection = .full;
    var allowed: ToolsField = try .of(&.{ "lookup", "none" });
    var builtins = initial.iterator();
    while (builtins.next()) |builtin| try allowed.insert(@tagName(builtin));
    const loaded = allowed;
    for (0..(@as(usize, 1) << std.enums.values(tool.BuiltInTool).len)) |bits| {
        var selected: tool.Selection = .empty;
        for (std.enums.values(tool.BuiltInTool), 0..) |builtin, index| {
            if (bits & (@as(usize, 1) << @intCast(index)) != 0) selected.insert(builtin);
        }
        var edited: ToolEdit = .{};
        try edited.replaceBuiltIns(&allowed, &loaded, selected);
        try std.testing.expect(edited.allowed.contains("lookup") and edited.allowed.contains("none"));
        try std.testing.expect(edited.loaded.contains("lookup") and edited.loaded.contains("none"));
        for (std.enums.values(tool.BuiltInTool)) |builtin| {
            try std.testing.expectEqual(selected.contains(builtin), edited.allowed.contains(@tagName(builtin)));
            try std.testing.expectEqual(selected.contains(builtin), edited.loaded.contains(@tagName(builtin)));
        }
        try std.testing.expectEqualStrings(edited.allowed.names.slice(), edited.loaded.names.slice());
    }
}

test "tool picker replacement retains explicit empty singleton none and unreachable intent for admission" {
    const cases = [_]struct { allowed: []const []const u8, loaded: []const []const u8, selected: tool.Selection, want_allowed: []const u8, want_loaded: []const u8 }{
        .{ .allowed = &.{}, .loaded = &.{}, .selected = .empty, .want_allowed = "", .want_loaded = "" },
        .{ .allowed = &.{ "bash", "none" }, .loaded = &.{ "bash", "none" }, .selected = .empty, .want_allowed = "none", .want_loaded = "none" },
        .{ .allowed = &.{ "bash", "find_tools", "lookup" }, .loaded = &.{ "find_tools", "lookup" }, .selected = .initOne(.find_tools), .want_allowed = "find_tools lookup", .want_loaded = "find_tools lookup" },
        .{ .allowed = &.{ "find_tools", "lookup" }, .loaded = &.{"lookup"}, .selected = .empty, .want_allowed = "lookup", .want_loaded = "lookup" },
        .{ .allowed = &.{ "bash", "find_tools", "lookup" }, .loaded = &.{ "bash", "find_tools" }, .selected = .initOne(.bash), .want_allowed = "bash lookup", .want_loaded = "bash" },
        .{ .allowed = &.{"bash"}, .loaded = &.{"bash"}, .selected = .initMany(&.{ .bash, .message_agent }), .want_allowed = "bash message_agent", .want_loaded = "bash" },
        .{ .allowed = &.{"bash"}, .loaded = &.{}, .selected = .initOne(.bash), .want_allowed = "bash", .want_loaded = "" },
    };
    for (cases) |case| {
        const allowed = try ToolsField.of(case.allowed);
        const loaded = try ToolsField.of(case.loaded);
        var edited: ToolEdit = .{};
        try edited.replaceBuiltIns(&allowed, &loaded, case.selected);
        try std.testing.expectEqualStrings(case.want_allowed, edited.allowed.names.slice());
        try std.testing.expectEqualStrings(case.want_loaded, edited.loaded.names.slice());
    }
}

test "tool picker refuses invalid initial loaded membership before selection can repair it" {
    const allowed = try ToolsField.of(&.{"bash"});
    for ([_][]const u8{ "lookup", "web_search" }) |invalid| {
        var loaded = try ToolsField.of(&.{"bash"});
        try loaded.insert(invalid);
        for ([_]tool.Selection{ .empty, .initOne(.bash), .full }) |selected| {
            var edited: ToolEdit = .{};
            try std.testing.expectError(error.LoadedToolsNotAllowed, edited.replaceBuiltIns(&allowed, &loaded, selected));
            try std.testing.expectEqual(@as(u8, 0), edited.allowed.count);
            try std.testing.expectEqual(@as(u8, 0), edited.loaded.count);
        }
    }
}

test "tool picker refuses a full allowed set rather than truncating MCP names" {
    var allowed: ToolsField = .{ .state = .value };
    for (0..@import("tool_name.zig").max_tools) |index| {
        var buffer: [16]u8 = undefined;
        try allowed.append(try std.fmt.bufPrint(&buffer, "mcp{d:0>3}", .{index}));
    }
    const loaded = allowed;
    var edited: ToolEdit = .{};
    try std.testing.expectError(error.InvalidJsonShape, edited.replaceBuiltIns(&allowed, &loaded, .initOne(.bash)));
    try std.testing.expectEqual(@import("tool_name.zig").max_tools, allowed.count);
    try std.testing.expectEqualStrings(allowed.names.slice(), loaded.names.slice());
}

test "tool picker adds allowed builtins without widening loaded intent" {
    const cases = [_]struct {
        allowed: []const []const u8,
        loaded: []const []const u8,
        selected: tool.Selection,
        want_allowed: []const u8,
    }{
        .{ .allowed = &.{"bash"}, .loaded = &.{"bash"}, .selected = .initMany(&.{ .bash, .web_search }), .want_allowed = "bash web_search" },
        .{ .allowed = &.{ "find_tools", "lookup" }, .loaded = &.{"find_tools"}, .selected = .initMany(&.{ .find_tools, .web_search }), .want_allowed = "find_tools lookup web_search" },
        .{ .allowed = &.{}, .loaded = &.{}, .selected = .initOne(.bash), .want_allowed = "bash" },
    };
    for (cases) |case| {
        const allowed = try ToolsField.of(case.allowed);
        const loaded = try ToolsField.of(case.loaded);
        var edited: ToolEdit = .{};
        try edited.replaceBuiltIns(&allowed, &loaded, case.selected);
        try std.testing.expectEqualStrings(case.want_allowed, edited.allowed.names.slice());
        // Admission decides reachability; the picker never loads newly allowed names.
        try std.testing.expect(edited.loaded.eql(&loaded));
    }
}
