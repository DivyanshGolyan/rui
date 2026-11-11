//! What a configure asks for: the settings a caller names, sparse, and the
//! client defaults a fresh Session or a reset setting takes in their place.
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
    /// A null value clears the Label.
    label: OptionalPolicy = .{},

    /// A fresh Session sends every setting its caller left to the client
    /// defaults concretely, for the provider and model it starts on. The
    /// saved effort applies only where the caller named no effort; "default"
    /// takes the model's own. Saved permissions apply only when not named.
    pub fn completeCreation(self: *ConfigureInput, provider: Provider, model: []const u8, saved_effort: ?ReasoningEffort, saved_permission: ?PermissionMode, compaction: *[20]u8) void {
        if (!self.reasoning_effort.present) self.reasoning_effort = startEffort(model, saved_effort);
        if (self.reasoning_effort.present and self.reasoning_effort.value == null) self.reasoning_effort = startEffort(model, null);
        if (!self.compaction_trigger.present or self.compaction_trigger.value == null) self.compaction_trigger = .{ .present = true, .value = compactionTrigger(provider, model, compaction) };
        if (self.tools == null) self.tools = product_defaults.tools;
        if (!self.permission_mode.present) self.permission_mode = .{ .present = true, .value = if (saved_permission) |mode| @tagName(mode) else product_defaults.permission_mode };
    }

    /// An update resets a named setting to the client default for the
    /// Session's provider and model; the others stay sparse.
    pub fn completeReset(self: *ConfigureInput, provider: Provider, model: []const u8, compaction: *[20]u8) void {
        if (self.compaction_trigger.present and self.compaction_trigger.value == null) self.compaction_trigger.value = compactionTrigger(provider, model, compaction);
        if (self.reasoning_effort.present and self.reasoning_effort.value == null) self.reasoning_effort = startEffort(model, null);
    }

    /// Whether `completeReset` needs the Session's current provider and model.
    pub fn resetsToDefault(self: ConfigureInput) bool {
        return (self.compaction_trigger.present and self.compaction_trigger.value == null) or
            (self.reasoning_effort.present and self.reasoning_effort.value == null);
    }
};

/// A policy setting as a caller spells it: "default" resets it.
pub fn policy(text: []const u8) OptionalPolicy {
    return .{ .present = true, .value = if (std.mem.eql(u8, text, "default")) null else text };
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
    // A model that takes no effort sends an explicit null, not an omission.
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
        // The saved effort is admitted against the model it starts on.
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
