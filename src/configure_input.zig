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

    pub fn completeCreation(self: *ConfigureInput, provider: ?Provider, model: []const u8, can_read_images: bool, saved_effort: ?ReasoningEffort, saved_permission: ?PermissionMode, compaction: *[20]u8) void {
        self.reasoning_effort = creationEffort(model, self.reasoning_effort, saved_effort);
        if (!self.compaction_trigger.present or self.compaction_trigger.value == null) self.compaction_trigger = .{ .present = true, .value = compactionTrigger(provider.?, model, compaction) };
        if (self.tools == null) {
            const tool_defaults = product_defaults.creationTools(@import("model_catalog.zig").acceptsImages(model), can_read_images);
            self.tools = tool_defaults.allowed;
            if (self.loaded_tools == null) self.loaded_tools = tool_defaults.loaded;
        }
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
    input.completeCreation(.openai, "unlisted-model", true, null, null, &compaction);
    try std.testing.expectEqualStrings("115200", input.compaction_trigger.value.?);
    try std.testing.expectEqualStrings(product_defaults.reasoning_effort, input.reasoning_effort.value.?);
    try std.testing.expectEqualStrings(product_defaults.tools, input.tools.?);
    try std.testing.expectEqualStrings(product_defaults.loaded_tools, input.loaded_tools.?);
    try std.testing.expectEqualStrings(product_defaults.permission_mode, input.permission_mode.value);
    try std.testing.expect(!input.workspace.present and !input.output_reservation.present and !input.label.present);

    input = .{ .store = "", .session = .create };
    input.completeCreation(.openai, "gpt-6.1-sol", true, null, null, &compaction);
    try std.testing.expectEqualStrings("945000", input.compaction_trigger.value.?);
    input = .{ .store = "", .session = .create };
    input.completeCreation(.codex, "gpt-6.1-sol", true, null, null, &compaction);
    try std.testing.expectEqualStrings("244800", input.compaction_trigger.value.?);
    input = .{ .store = "", .session = .create };
    input.completeCreation(.openai, "openai/whisper-1", true, .high, null, &compaction);
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
        input.completeCreation(.openai, "gpt-6.1-sol", true, case.saved, null, &compaction);
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
    input.completeCreation(.openai, "gpt-6.1-sol", true, .max, null, &compaction);
    try std.testing.expectEqualStrings("", input.tools.?);
    try std.testing.expectEqualStrings("plan", input.permission_mode.value);
    try std.testing.expectEqualStrings("00042", input.compaction_trigger.value.?);
    try std.testing.expectEqualStrings("high", input.reasoning_effort.value.?);

    input.compaction_trigger = policy("default");
    try std.testing.expect(input.compaction_trigger.value == null);
    input.completeCreation(.openai, "gpt-6.1-sol", true, .max, null, &compaction);
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
            .model = .{ .present = true, .value = "gpt-6.1-sol" },
        };
        input.completeCreation(.openai, "gpt-6.1-sol", true, .high, .ask, &compaction);
        try std.testing.expectEqualStrings("k7m2qx", input.parent.value);
        try std.testing.expectEqualStrings("gpt-6.1-sol", input.model.value);
        try std.testing.expectEqualStrings(product_defaults.tools, input.tools.?);
        try std.testing.expectEqualStrings(product_defaults.loaded_tools, input.loaded_tools.?);
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
        input.completeCreation(.codex, "unlisted-model", true, null, .ask, &compaction);
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
        input.completeCreation(null, input.model.value, true, null, null, &compaction);
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

test "creation default completion preserves Overview omitted binding and require_model" {
    for ([_]bool{ false, true }) |bound| {
        var input: ConfigureInput = .{
            .store = "/store",
            .session = .create,
            .require_model = true,
            .workspace = .{ .present = true, .value = "/workspace" },
            .provider = if (bound) .{ .present = true, .value = "codex" } else .{},
            .model = if (bound) .{ .present = true, .value = "selected-model" } else .{},
        };
        var compaction: [20]u8 = undefined;
        input.completeCreation(.openai, "unlisted-model", true, .high, .ask, &compaction);
        try std.testing.expect(input.require_model);
        try std.testing.expectEqual(bound, input.provider.present);
        try std.testing.expectEqual(bound, input.model.present);
        if (bound) {
            try std.testing.expectEqualStrings("codex", input.provider.value);
            try std.testing.expectEqualStrings("selected-model", input.model.value);
        } else {
            try std.testing.expectEqualStrings("", input.provider.value);
            try std.testing.expectEqualStrings("", input.model.value);
        }
        try std.testing.expectEqualStrings("/workspace", input.workspace.value);
        try std.testing.expectEqualStrings(product_defaults.tools, input.tools.?);
        try std.testing.expectEqualStrings("ask", input.permission_mode.value);
        try std.testing.expectEqualStrings("high", input.reasoning_effort.value.?);
        try std.testing.expectEqualStrings("115200", input.compaction_trigger.value.?);
    }
}

test "fresh creation preserves explicitly restricted tool selections with or without an opener" {
    var compaction: [20]u8 = undefined;
    for ([_]bool{ false, true }) |can_read_images| {
        for ([_][]const u8{ "gpt-6.1-sol", "unlisted-model", "gpt-3.5-turbo" }) |model| {
            for ([_]struct { tools: []const u8, loaded: ?[]const u8 }{
                .{ .tools = "bash", .loaded = null },
                .{ .tools = "bash,find_tools", .loaded = "find_tools" },
                .{ .tools = "read_image", .loaded = null },
                .{ .tools = "read_image", .loaded = "read_image" },
                .{ .tools = "none", .loaded = null },
                .{ .tools = "none", .loaded = "none" },
            }) |case| {
                var input: ConfigureInput = .{ .store = "", .session = .create, .tools = case.tools, .loaded_tools = case.loaded };
                input.completeCreation(.codex, model, can_read_images, null, null, &compaction);
                try std.testing.expectEqualStrings(case.tools, input.tools.?);
                if (case.loaded) |loaded| {
                    try std.testing.expectEqualStrings(loaded, input.loaded_tools.?);
                } else try std.testing.expect(input.loaded_tools == null);
            }
        }
    }
}

test "fresh creation preserves explicitly loaded tools with default allowed tools and either opener capability" {
    var compaction: [20]u8 = undefined;
    for ([_]bool{ false, true }) |can_read_images| {
        for ([_][]const u8{ "find_tools", "read_image", "none" }) |loaded| {
            var input: ConfigureInput = .{ .store = "", .session = .create, .loaded_tools = loaded };
            input.completeCreation(.codex, "unlisted-model", can_read_images, null, null, &compaction);
            try std.testing.expectEqualStrings(product_defaults.creationTools(true, can_read_images).allowed, input.tools.?);
            try std.testing.expectEqualStrings(loaded, input.loaded_tools.?);
        }
    }
}

test "fresh Session image tool defaults require model support and an opener with or without a parent" {
    for ([_]bool{ false, true }) |parent| {
        for ([_]bool{ false, true }) |can_read_images| {
            for ([_]struct { model: []const u8, images: bool }{
                .{ .model = "gpt-6.1-sol", .images = true },
                .{ .model = "unlisted-model", .images = true },
                .{ .model = "gpt-3.5-turbo", .images = false },
            }) |case| {
                var input: ConfigureInput = .{
                    .store = "",
                    .session = .create,
                    .parent = if (parent) .{ .present = true, .value = "k7m2qx" } else .{},
                };
                var compaction: [20]u8 = undefined;
                input.completeCreation(.openai, case.model, can_read_images, null, null, &compaction);
                const images = case.images and can_read_images;
                try std.testing.expectEqual(images, std.mem.indexOf(u8, input.tools.?, "read_image") != null);
                try std.testing.expectEqual(images, std.mem.indexOf(u8, input.loaded_tools.?, "read_image") != null);
            }
        }
    }
}

test "model changes and policy resets preserve existing Session tool intent" {
    for ([_]?[]const u8{ null, "bash", "bash,read_image", "none" }) |tools| {
        for ([_]?[]const u8{ null, "bash", "bash,read_image", "none" }) |loaded| {
            var input: ConfigureInput = .{
                .store = "",
                .session = .{ .named = "k7m2qx" },
                .tools = tools,
                .loaded_tools = loaded,
                .model = .{ .present = true, .value = "gpt-3.5-turbo" },
                .compaction_trigger = policy("default"),
                .reasoning_effort = policy("default"),
            };
            var compaction: [20]u8 = undefined;
            input.completeReset(.openai, input.model.value, &compaction);
            try std.testing.expectEqual(tools, input.tools);
            try std.testing.expectEqual(loaded, input.loaded_tools);
        }
    }
}
