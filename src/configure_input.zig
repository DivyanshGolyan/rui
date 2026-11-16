const std = @import("std");
const client_defaults = @import("client_defaults.zig");
const product_defaults = @import("product_defaults.zig");
const ReasoningEffort = @import("model_catalog.zig").ReasoningEffort;
const PermissionMode = @import("cli_value.zig").PermissionMode;
const Provider = @import("provider_name.zig").Provider;

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

pub const ConfigureInput = struct {
    store: []const u8,
    session: union(enum) {
        named: []const u8,
        create,
    },
    parent: OptionalText = .{},
    require_model: bool = false,
    reload_skills: bool = false,
    workspace: OptionalText = .{},
    provider: OptionalText = .{},
    model: OptionalText = .{},
    instructions: OptionalFile = .{},
    tools: ?[]const u8 = null,
    loaded_tools: ?[]const u8 = null,
    permission_mode: OptionalText = .{},
    output_schema: OptionalFile = .{},
    compaction_trigger: OptionalPolicy = .{},
    output_reservation: OptionalPolicy = .{},
    reasoning_effort: OptionalPolicy = .{},
    label: OptionalPolicy = .{},

    pub fn creationReads(self: ConfigureInput) struct { binding: bool, preferences: bool, saved_effort: bool } {
        const binding = !self.parent.present or !self.model.present or !self.compaction_trigger.present or self.compaction_trigger.value == null;
        const binding_preferences = binding and (!self.provider.present or !self.model.present);
        const saved_effort = binding_preferences or (self.parent.present and !self.reasoning_effort.present);
        return .{ .binding = binding, .preferences = saved_effort or !self.permission_mode.present, .saved_effort = saved_effort };
    }

    pub fn completeCreation(self: *ConfigureInput, provider: ?Provider, model: []const u8, saved_effort: ?ReasoningEffort, saved_permission: ?PermissionMode, compaction: *[20]u8) void {
        self.model = .{ .present = true, .value = model };
        if (!self.parent.present) self.provider = .{ .present = true, .value = @tagName(provider.?) };
        self.reasoning_effort = creationEffort(model, self.reasoning_effort, saved_effort);
        if (!self.compaction_trigger.present or self.compaction_trigger.value == null) self.compaction_trigger = .{ .present = true, .value = compactionTrigger(provider.?, model, compaction) };
        if (self.tools == null) self.tools = product_defaults.tools;
        if (!self.permission_mode.present) self.permission_mode = .{ .present = true, .value = if (saved_permission) |mode| @tagName(mode) else product_defaults.permission_mode };
    }

    pub fn completeReset(self: *ConfigureInput, provider: Provider, model: []const u8, compaction: *[20]u8) void {
        if (self.compaction_trigger.present and self.compaction_trigger.value == null) self.compaction_trigger.value = compactionTrigger(provider, model, compaction);
        if (self.reasoning_effort.present and self.reasoning_effort.value == null) self.reasoning_effort = startEffort(model, null);
    }

    pub fn resetsToDefault(self: ConfigureInput) bool {
        return (self.compaction_trigger.present and self.compaction_trigger.value == null) or
            (self.reasoning_effort.present and self.reasoning_effort.value == null);
    }
};

pub fn policy(text: []const u8) OptionalPolicy {
    return .{ .present = true, .value = if (std.mem.eql(u8, text, "default")) null else text };
}

pub fn creationEffort(model: []const u8, held: OptionalPolicy, saved: ?ReasoningEffort) OptionalPolicy {
    if (!held.present) return startEffort(model, saved);
    if (held.value == null) return startEffort(model, null);
    return held;
}

fn startEffort(model: []const u8, saved: ?ReasoningEffort) OptionalPolicy {
    const effort = client_defaults.startEffort(model, saved);
    return .{ .present = true, .value = if (effort) |value| @tagName(value) else null };
}

fn compactionTrigger(provider: Provider, model: []const u8, buffer: *[20]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{client_defaults.compactionTrigger(provider, model)}) catch unreachable;
}

test "a policy argument resets with default and keeps any other spelling" {
    const reset = policy("default");
    try std.testing.expect(reset.present and reset.value == null);
    try std.testing.expectEqualStrings("00042", policy("00042").value.?);
    try std.testing.expectEqualStrings("Default", policy("Default").value.?);
}

test "a fresh Session sends concrete defaults where its caller named none" {
    var compaction: [20]u8 = undefined;
    var input: ConfigureInput = .{ .store = "", .session = .create };
    input.completeCreation(.openai, "unlisted-model", null, null, &compaction);
    try std.testing.expectEqualStrings("115200", input.compaction_trigger.value.?);
    try std.testing.expectEqualStrings(product_defaults.reasoning_effort, input.reasoning_effort.value.?);
    try std.testing.expectEqualStrings(product_defaults.tools, input.tools.?);
    try std.testing.expectEqualStrings(product_defaults.permission_mode, input.permission_mode.value);
    try std.testing.expect(!input.workspace.present and !input.output_reservation.present and !input.label.present);

    input = .{ .store = "", .session = .create };
    input.completeCreation(.openai, "gpt-6.1-sol", null, null, &compaction);
    try std.testing.expectEqualStrings("945000", input.compaction_trigger.value.?);
    input = .{ .store = "", .session = .create };
    input.completeCreation(.codex, "gpt-6.1-sol", null, null, &compaction);
    try std.testing.expectEqualStrings("244800", input.compaction_trigger.value.?);
    input = .{ .store = "", .session = .create };
    input.completeCreation(.openai, "openai/whisper-1", .high, null, &compaction);
    try std.testing.expect(input.reasoning_effort.present and input.reasoning_effort.value == null);
}

test "a fresh Session takes the saved effort only where its caller named none" {
    var compaction: [20]u8 = undefined;
    const cases = [_]struct { effort: OptionalPolicy, saved: ?ReasoningEffort, sent: []const u8 }{
        .{ .effort = .{}, .saved = .max, .sent = "max" },
        .{ .effort = .{}, .saved = null, .sent = product_defaults.reasoning_effort },
        .{ .effort = policy("default"), .saved = .max, .sent = product_defaults.reasoning_effort },
        .{ .effort = policy("high"), .saved = .max, .sent = "high" },
        .{ .effort = .{}, .saved = .none, .sent = product_defaults.reasoning_effort },
    };
    for (cases) |case| {
        var input: ConfigureInput = .{ .store = "", .session = .create, .reasoning_effort = case.effort };
        input.completeCreation(.openai, "gpt-6.1-sol", case.saved, null, &compaction);
        try std.testing.expectEqualStrings(case.sent, input.reasoning_effort.value.?);
    }
}

test "a fresh Session keeps every setting its caller named" {
    var compaction: [20]u8 = undefined;
    var input: ConfigureInput = .{
        .store = "",
        .session = .create,
        .tools = "",
        .permission_mode = .{ .present = true, .value = "plan" },
        .compaction_trigger = policy("00042"),
        .reasoning_effort = policy("high"),
    };
    input.completeCreation(.openai, "gpt-6.1-sol", .max, null, &compaction);
    try std.testing.expectEqualStrings("", input.tools.?);
    try std.testing.expectEqualStrings("plan", input.permission_mode.value);
    try std.testing.expectEqualStrings("00042", input.compaction_trigger.value.?);
    try std.testing.expectEqualStrings("high", input.reasoning_effort.value.?);

    input.compaction_trigger = policy("default");
    try std.testing.expect(input.compaction_trigger.value == null);
    input.completeCreation(.openai, "gpt-6.1-sol", .max, null, &compaction);
    try std.testing.expectEqualStrings("945000", input.compaction_trigger.value.?);
}

test "an update resets only the settings it names to default" {
    var compaction: [20]u8 = undefined;
    var sparse: ConfigureInput = .{ .store = "", .session = .{ .named = "s" }, .compaction_trigger = policy("7"), .reasoning_effort = policy("high") };
    try std.testing.expect(!sparse.resetsToDefault());
    sparse.completeReset(.openai, "gpt-6.1-sol", &compaction);
    try std.testing.expectEqualStrings("7", sparse.compaction_trigger.value.?);
    try std.testing.expectEqualStrings("high", sparse.reasoning_effort.value.?);
    try std.testing.expect(!(ConfigureInput{ .store = "", .session = .{ .named = "s" } }).resetsToDefault());

    var reset: ConfigureInput = .{ .store = "", .session = .{ .named = "s" }, .compaction_trigger = policy("default") };
    try std.testing.expect(reset.resetsToDefault());
    reset.completeReset(.codex, "gpt-6.1-sol", &compaction);
    try std.testing.expectEqualStrings("244800", reset.compaction_trigger.value.?);
    try std.testing.expect(!reset.reasoning_effort.present);

    reset = .{ .store = "", .session = .{ .named = "s" }, .reasoning_effort = policy("default") };
    try std.testing.expect(reset.resetsToDefault());
    reset.completeReset(.openai, "gpt-6-luna", &compaction);
    try std.testing.expectEqualStrings("low", reset.reasoning_effort.value.?);
    try std.testing.expect(!reset.compaction_trigger.present);
}

test "parent creation completes required defaults and preserves only explicit inherited-field overrides" {
    for ([_]bool{ false, true }) |overrides| {
        var compaction: [20]u8 = undefined;
        var input: ConfigureInput = .{
            .store = "",
            .session = .create,
            .parent = .{ .present = true, .value = "k7m2qx" },
            .provider = if (overrides) .{ .present = true, .value = "codex" } else .{},
            .workspace = if (overrides) .{ .present = true, .value = "/parent" } else .{},
        };
        input.completeCreation(.openai, "gpt-6.1-sol", .high, .ask, &compaction);
        try std.testing.expectEqualStrings("k7m2qx", input.parent.value);
        try std.testing.expectEqualStrings("gpt-6.1-sol", input.model.value);
        try std.testing.expectEqualStrings(product_defaults.tools, input.tools.?);
        try std.testing.expectEqualStrings("ask", input.permission_mode.value);
        try std.testing.expectEqualStrings("high", input.reasoning_effort.value.?);
        try std.testing.expectEqualStrings("945000", input.compaction_trigger.value.?);
        try std.testing.expectEqual(overrides, input.provider.present);
        try std.testing.expectEqual(overrides, input.workspace.present);
        if (overrides) {
            try std.testing.expectEqualStrings("codex", input.provider.value);
            try std.testing.expectEqualStrings("/parent", input.workspace.value);
        }
        input.tools = "";
        input.loaded_tools = "";
        input.permission_mode = .{ .present = true, .value = "bypass" };
        input.compaction_trigger = policy("42");
        input.completeCreation(.codex, "unlisted-model", null, .ask, &compaction);
        try std.testing.expectEqualStrings("", input.tools.?);
        try std.testing.expectEqualStrings("", input.loaded_tools.?);
        try std.testing.expectEqualStrings("bypass", input.permission_mode.value);
        try std.testing.expectEqualStrings("42", input.compaction_trigger.value.?);
    }
}

test "parent fully explicit creation needs neither binding nor preferences and preserves forbidden overrides" {
    for ([_]bool{ false, true }) |overrides| {
        var input: ConfigureInput = .{
            .store = "/store",
            .session = .create,
            .parent = .{ .present = true, .value = "k7m2qx" },
            .provider = if (overrides) .{ .present = true, .value = "codex" } else .{},
            .workspace = if (overrides) .{ .present = true, .value = "/parent" } else .{},
            .model = .{ .present = true, .value = "unlisted-model" },
            .tools = "bash",
            .permission_mode = .{ .present = true, .value = "ask" },
            .reasoning_effort = policy("high"),
            .compaction_trigger = policy("1000"),
        };
        const reads = input.creationReads();
        try std.testing.expect(!reads.binding and !reads.preferences and !reads.saved_effort);
        var compaction: [20]u8 = undefined;
        input.completeCreation(null, input.model.value, null, null, &compaction);
        try std.testing.expectEqualStrings("1000", input.compaction_trigger.value.?);
        try std.testing.expectEqualStrings("high", input.reasoning_effort.value.?);
        try std.testing.expectEqual(overrides, input.provider.present);
        try std.testing.expectEqual(overrides, input.workspace.present);
        if (overrides) {
            try std.testing.expectEqualStrings("codex", input.provider.value);
            try std.testing.expectEqualStrings("/parent", input.workspace.value);
        }
        input.reasoning_effort = .{};
        try std.testing.expect(!input.creationReads().binding and input.creationReads().preferences);
        input.reasoning_effort = policy("default");
        try std.testing.expect(!input.creationReads().preferences);
        input.compaction_trigger = policy("default");
        try std.testing.expect(input.creationReads().binding);
        input.compaction_trigger = policy("1000");
        input.model = .{};
        try std.testing.expect(input.creationReads().binding and input.creationReads().preferences);
    }
}
