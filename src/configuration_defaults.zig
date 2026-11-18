const std = @import("std");
const input = @import("command_input.zig");
const catalog = @import("model_catalog.zig");
const capability = @import("model_capability.zig");
const product = @import("product_defaults.zig");
const Provider = @import("provider_name.zig").Provider;

const Choice = input.OptionalBounded(16);
const Tokens = input.OptionalBounded(20);
const ToolProfile = struct { allowed: input.ToolsField, loaded: input.ToolsField };
const image_profile: ToolProfile = .{ .allowed = names(product.creationTools(true, true).allowed), .loaded = names(product.creationTools(true, true).loaded) };
const text_profile: ToolProfile = .{ .allowed = names(product.creationTools(false, false).allowed), .loaded = names(product.creationTools(false, false).loaded) };
const product_permission = choice(.value, product.permission_mode);

fn names(comptime text: []const u8) input.ToolsField {
    @setEvalBranchQuota(10000);
    var out: input.ToolsField = .{ .state = .value };
    var each = std.mem.splitScalar(u8, text, ',');
    while (each.next()) |name| out.insert(name) catch unreachable;
    return out;
}

/// These lists borrow the request or immutable product defaults.
fn creationProfile(model: []const u8, can_read_images: bool) *const ToolProfile {
    return if (catalog.imageCapability(model) != .unsupported and can_read_images) &image_profile else &text_profile;
}

pub fn creationTools(requested: *const input.ToolsField, model: []const u8, can_read_images: bool) *const input.ToolsField {
    return if (requested.state == .omitted) &creationProfile(model, can_read_images).allowed else requested;
}

fn creationPermission(requested: *const Choice) *const Choice {
    return if (requested.state == .omitted) &product_permission else requested;
}

pub fn compactionTrigger(facts: []const catalog.Entry, provider: Provider, model: []const u8) u64 {
    const model_trigger = capability.contextWindow(facts, model) * product.compaction_trigger_percent / 100;
    const provider_trigger = for (product.provider_compaction_triggers) |entry| {
        if (std.mem.eql(u8, entry.provider, @tagName(provider))) break entry.tokens;
    } else model_trigger;
    const trigger = for (product.model_compaction_triggers) |entry| {
        if (std.mem.eql(u8, entry.provider, @tagName(provider)) and std.mem.eql(u8, entry.model, model)) break entry.tokens;
    } else provider_trigger;
    return @min(trigger, model_trigger);
}

pub fn startEffort(facts: []const catalog.Entry, model: []const u8) ?catalog.ReasoningEffort {
    const preferred = comptime std.meta.stringToEnum(catalog.ReasoningEffort, product.reasoning_effort).?;
    return capability.startEffort(facts, preferred, model) orelse blk: {
        const row = catalog.find(facts, model) orelse break :blk null;
        var efforts = row.efforts.iterator();
        break :blk efforts.next();
    };
}

pub const Request = struct {
    creating: bool,
    parent: ?Parent = null,
    provider: Provider,
    model: []const u8,
    can_read_images: bool,
    tools: *const input.ToolsField,
    loaded_tools: *const input.ToolsField,
    permission_mode: *const Choice,
    reasoning_effort: *const Choice,
    compaction_trigger: *const Tokens,
    preferences: Preferences = .{},
};

pub const Preferences = struct {
    reasoning_effort: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
};

pub const Resolved = struct {
    parent_refusal: ?ParentRefusal,
    tools: *const input.ToolsField,
    loaded_tools: *const input.ToolsField,
    permission_mode: Choice,
    reasoning_effort: Choice,
    compaction_trigger: Tokens,
};

/// Admission resolves omissions only for creation, and explicit policy resets
/// for both creation and updates. Explicit values retain their exact spelling.
pub fn resolve(facts: []const catalog.Entry, request: Request) Resolved {
    var out: Resolved = .{
        .parent_refusal = null,
        .tools = request.tools,
        .loaded_tools = request.loaded_tools,
        .permission_mode = request.permission_mode.*,
        .reasoning_effort = request.reasoning_effort.*,
        .compaction_trigger = request.compaction_trigger.*,
    };
    if (request.creating) {
        out.tools = creationTools(request.tools, request.model, request.can_read_images);
        if (request.tools.state == .omitted and request.loaded_tools.state == .omitted) {
            out.loaded_tools = &creationProfile(request.model, request.can_read_images).loaded;
        }
        out.permission_mode = creationPermission(request.permission_mode).*;
        if (request.permission_mode.state == .omitted) if (request.preferences.permission_mode) |saved| {
            if (std.meta.stringToEnum(@import("cli_value.zig").PermissionMode, saved)) |mode| {
                if (request.parent == null or request.parent.?.permission_mode != .ask or mode == .ask) {
                    out.permission_mode = choice(.value, saved);
                }
            }
        };
        if (request.parent) |parent| out.parent_refusal = checkParent(parent, out.tools, &out.permission_mode);
    }
    if (request.reasoning_effort.state == .explicit_null or (request.creating and request.reasoning_effort.state == .omitted)) {
        const saved_effort = if (request.creating and request.reasoning_effort.state == .omitted)
            if (request.preferences.reasoning_effort) |saved| std.meta.stringToEnum(catalog.ReasoningEffort, saved) else null
        else
            null;
        const effort_or_default = capability.startEffort(facts, saved_effort, request.model) orelse startEffort(facts, request.model);
        if (effort_or_default) |effort| {
            out.reasoning_effort.state = .value;
            out.reasoning_effort.value.set(@tagName(effort)) catch unreachable;
        } else {
            out.reasoning_effort.state = .explicit_null;
            out.reasoning_effort.value.len = 0;
        }
    }
    if (request.compaction_trigger.state == .explicit_null or (request.creating and request.compaction_trigger.state == .omitted)) {
        out.compaction_trigger.state = .value;
        const text = std.fmt.bufPrint(&out.compaction_trigger.value.bytes, "{d}", .{compactionTrigger(facts, request.provider, request.model)}) catch unreachable;
        out.compaction_trigger.value.len = text.len;
    }
    return out;
}

pub const Parent = struct {
    tools: []const u8,
    permission_mode: @import("cli_value.zig").PermissionMode,
};

pub const ParentRefusal = union(enum) {
    tools_not_in_parent: []const u8,
    permission_mode_wider_than_parent,
};

/// Parent authority is checked against the completed creation intent, including
/// the early start_agent check, before its result can be cached.
fn checkParent(parent: Parent, tools: *const input.ToolsField, permission: *const Choice) ?ParentRefusal {
    var requested = tools.iterator();
    while (requested.next()) |name| {
        var allowed = std.mem.splitScalar(u8, parent.tools, ',');
        while (allowed.next()) |member| {
            if (std.mem.eql(u8, name, member)) break;
        } else return .{ .tools_not_in_parent = name };
    }
    const mode = creationPermission(permission);
    if (parent.permission_mode == .ask and mode.state == .value and !mode.value.eql("ask")) return .permission_mode_wider_than_parent;
    return null;
}

// Golden values below come from 3ebdd8b's completeCreation/client_defaults,
// rather than the resolver or product defaults being tested.
const golden_tools = "bash find_tools message_agent read_action read_transcript skill start_agent stop_action web_search";
const golden_loaded = "bash find_tools skill web_search";

fn choice(state: input.FieldState, text: []const u8) Choice {
    var value: Choice = .{ .state = state };
    value.value.set(text) catch unreachable;
    return value;
}

fn tokenField(state: input.FieldState, text: []const u8) Tokens {
    var value: Tokens = .{ .state = state };
    value.value.set(text) catch unreachable;
    return value;
}

test "CM-39 default compaction trigger" {
    const cases = [_]struct { provider: Provider, model: []const u8, tokens: u64 }{
        .{ .provider = .codex, .model = "gpt-6.1-sol", .tokens = 450000 },
        .{ .provider = .codex, .model = "gpt-6.1-terra", .tokens = 450000 },
        .{ .provider = .codex, .model = "gpt-6.2-sol", .tokens = 450000 },
        .{ .provider = .codex, .model = "gpt-6.2-astra", .tokens = 244800 },
        .{ .provider = .codex, .model = "gpt-6-sol", .tokens = 244800 },
        .{ .provider = .codex, .model = "gpt-6.1-terra@eu", .tokens = 244800 },
        .{ .provider = .codex, .model = "openai/gpt-6.1-terra", .tokens = 244800 },
        .{ .provider = .codex, .model = "gpt-6.1-terra-extra", .tokens = 115200 },
        .{ .provider = .codex, .model = "gpt-5.3-codex-spark", .tokens = 115200 },
        .{ .provider = .codex, .model = "unlisted-model", .tokens = 115200 },
        .{ .provider = .openai, .model = "gpt-6.1-terra", .tokens = 945000 },
        .{ .provider = .openai, .model = "gpt-6.2-sol", .tokens = 945000 },
        .{ .provider = .openai, .model = "gpt-5.3-codex-spark", .tokens = 115200 },
        .{ .provider = .openai, .model = "unlisted-model", .tokens = 115200 },
    };
    for (cases) |case| try std.testing.expectEqual(case.tokens, compactionTrigger(catalog.shipped, case.provider, case.model));
    const narrow = [_]catalog.Entry{.{ .id = "gpt-6.1-sol", .context_window = 1000, .efforts = .empty, .openai_listed = true }};
    try std.testing.expectEqual(@as(u64, 900), compactionTrigger(&narrow, .codex, "gpt-6.1-sol"));
}

fn creationFieldCases() !void {
    const models = [_]struct { id: []const u8, effort: ?[]const u8, compact: [3][]const u8 }{
        .{ .id = "gpt-6.1-sol", .effort = "low", .compact = .{ "450000", "945000", "945000" } },
        .{ .id = "kimi-k2.6", .effort = null, .compact = .{ "235929", "235929", "235929" } },
        .{ .id = "unlisted-model", .effort = "low", .compact = .{ "115200", "115200", "115200" } },
    };
    const providers = [_]Provider{ .codex, .chatgpt, .openai };
    const states = [_]input.FieldState{ .omitted, .value, .explicit_null };
    var count: usize = 0;
    for (models) |model| for (providers, 0..) |provider, provider_index| for ([_]bool{ false, true }) |has_parent| {
        for (states) |tools_state| for (states) |loaded_state| for (states) |permission_state| for (states) |effort_state| for (states) |compact_state| {
            var tools = try input.ToolsField.of(&.{ "bash", "find_tools", "lookup" });
            tools.state = tools_state;
            var loaded = try input.ToolsField.of(&.{ "bash", "find_tools" });
            loaded.state = loaded_state;
            const permission = choice(permission_state, "ask");
            const effort = choice(effort_state, "high");
            const compact = tokenField(compact_state, "00042");
            const resolved = resolve(catalog.shipped, .{
                .creating = true,
                .parent = if (has_parent) .{ .tools = "bash,find_tools,lookup,message_agent,read_action,read_transcript,skill,start_agent,stop_action,web_search", .permission_mode = .ask } else null,
                .provider = provider,
                .model = model.id,
                .can_read_images = false,
                .tools = &tools,
                .loaded_tools = &loaded,
                .permission_mode = &permission,
                .reasoning_effort = &effort,
                .compaction_trigger = &compact,
            });
            if (tools_state == .omitted) {
                try std.testing.expectEqual(input.FieldState.value, resolved.tools.state);
                try std.testing.expectEqualStrings(golden_tools, resolved.tools.names.slice());
            } else try std.testing.expect(resolved.tools == &tools);
            if (tools_state == .omitted and loaded_state == .omitted) {
                try std.testing.expectEqual(input.FieldState.value, resolved.loaded_tools.state);
                try std.testing.expectEqualStrings(golden_loaded, resolved.loaded_tools.names.slice());
            } else try std.testing.expect(resolved.loaded_tools == &loaded);
            try std.testing.expectEqual(if (permission_state == .omitted) input.FieldState.value else permission_state, resolved.permission_mode.state);
            try std.testing.expectEqualStrings(if (permission_state == .omitted) "bypass" else "ask", resolved.permission_mode.value.slice());
            if (effort_state == .value) {
                try std.testing.expectEqual(input.FieldState.value, resolved.reasoning_effort.state);
                try std.testing.expectEqualStrings("high", resolved.reasoning_effort.value.slice());
            } else if (model.effort) |expected| {
                try std.testing.expectEqual(input.FieldState.value, resolved.reasoning_effort.state);
                try std.testing.expectEqualStrings(expected, resolved.reasoning_effort.value.slice());
            } else try std.testing.expectEqual(input.FieldState.explicit_null, resolved.reasoning_effort.state);
            try std.testing.expectEqual(input.FieldState.value, resolved.compaction_trigger.state);
            try std.testing.expectEqualStrings(if (compact_state == .value) "00042" else model.compact[provider_index], resolved.compaction_trigger.value.slice());
            if (has_parent) {
                const refusal = resolved.parent_refusal;
                if (permission_state == .omitted) try std.testing.expect(refusal.? == .permission_mode_wider_than_parent) else try std.testing.expect(refusal == null);
            }
            // The sparse input remains unchanged, including null/omitted intent.
            try std.testing.expectEqual(tools_state, tools.state);
            try std.testing.expectEqual(loaded_state, loaded.state);
            try std.testing.expectEqual(effort_state, effort.state);
            try std.testing.expectEqual(compact_state, compact.state);
            count += 1;
        };
    };
    try std.testing.expectEqual(@as(usize, 4374), count);
}

fn updateFieldCases() !void {
    const states = [_]input.FieldState{ .omitted, .value, .explicit_null };
    for (states) |tools_state| for (states) |loaded_state| for (states) |permission_state| for (states) |effort_state| for (states) |compact_state| {
        var tools = try input.ToolsField.of(&.{});
        tools.state = tools_state;
        var loaded = try input.ToolsField.of(&.{});
        loaded.state = loaded_state;
        const permission = choice(permission_state, "ask");
        const effort = choice(effort_state, "max");
        const compact = tokenField(compact_state, "00042");
        const resolved = resolve(catalog.shipped, .{
            .creating = false,
            .provider = .codex,
            .model = "gpt-6.1-sol",
            .can_read_images = false,
            .tools = &tools,
            .loaded_tools = &loaded,
            .permission_mode = &permission,
            .reasoning_effort = &effort,
            .compaction_trigger = &compact,
        });
        try std.testing.expect(resolved.tools == &tools and resolved.loaded_tools == &loaded);
        try std.testing.expectEqual(permission_state, resolved.permission_mode.state);
        try std.testing.expectEqualStrings("ask", resolved.permission_mode.value.slice());
        try std.testing.expectEqual(if (effort_state == .explicit_null) input.FieldState.value else effort_state, resolved.reasoning_effort.state);
        try std.testing.expectEqualStrings(if (effort_state == .explicit_null) "low" else "max", resolved.reasoning_effort.value.slice());
        try std.testing.expectEqual(if (compact_state == .explicit_null) input.FieldState.value else compact_state, resolved.compaction_trigger.state);
        try std.testing.expectEqualStrings(if (compact_state == .explicit_null) "450000" else "00042", resolved.compaction_trigger.value.slice());
    };
}

fn selectedModelCases() !void {
    const facts: []const catalog.Entry = &.{
        .{ .id = "gpt-6.1-sol", .context_window = 1000, .efforts = .init(.{ .high = true }), .openai_listed = true },
        .{ .id = "no-effort", .context_window = 2000, .efforts = .{}, .openai_listed = false },
        .{ .id = "no-window", .context_window = null, .efforts = .init(.{ .max = true }), .openai_listed = false },
    };
    try std.testing.expectEqual(catalog.ReasoningEffort.high, startEffort(facts, "gpt-6.1-sol").?);
    try std.testing.expect(startEffort(facts, "no-effort") == null);
    try std.testing.expectEqual(catalog.ReasoningEffort.max, startEffort(facts, "no-window").?);
    try std.testing.expectEqual(catalog.ReasoningEffort.low, startEffort(facts, "gpt-6-luna").?);
    const tools = try input.ToolsField.of(&.{});
    const permission = choice(.omitted, "");
    const compact = tokenField(.omitted, "");
    for (catalog.shipped) |row| {
        const selected = startEffort(catalog.shipped, row.id);
        if (selected) |effort| {
            try std.testing.expect(row.efforts.contains(effort));
            if (row.efforts.contains(.low)) try std.testing.expectEqual(catalog.ReasoningEffort.low, effort) else {
                var efforts = row.efforts.iterator();
                try std.testing.expectEqual(efforts.next().?, effort);
            }
        } else try std.testing.expectEqual(@as(usize, 0), row.efforts.count());
        for (std.enums.values(catalog.ReasoningEffort)) |effort| {
            const explicit = choice(.value, @tagName(effort));
            const resolved = resolve(catalog.shipped, .{
                .creating = true,
                .provider = .openai,
                .model = row.id,
                .can_read_images = false,
                .tools = &tools,
                .loaded_tools = &tools,
                .permission_mode = &permission,
                .reasoning_effort = &explicit,
                .compaction_trigger = &compact,
            });
            try std.testing.expectEqualStrings(@tagName(effort), resolved.reasoning_effort.value.slice());
        }
    }
}

test "ADM-29 configuration field wire grammar" {
    const protocol = @import("protocol.zig");
    const Custody = struct {
        pub const File = struct {};
        pub const Budget = struct {};
        pub const Io = void;
        pub fn release(_: ?File, _: ?Budget, _: u64, _: Io) void {}
    };
    const fields = [_][]const u8{ "tools", "loadedTools", "permissionMode", "effort", "compactAt" };
    const values = [_][]const u8{ "[\"bash\",\"find_tools\"]", "[\"bash\"]", "\"ask\"", "\"high\"", "42" };
    const states = [_]input.FieldState{ .omitted, .value, .explicit_null };
    var total: usize = 0;
    var invalid: usize = 0;
    for ([_][]const u8{ "gpt-6.1-sol", "kimi-k2.6", "unlisted-model" }) |model| for ([_]bool{ false, true }) |has_parent| {
        for (states) |tools| for (states) |loaded| for (states) |mode| for (states) |effort| for (states) |compact| {
            const combination = [_]input.FieldState{ tools, loaded, mode, effort, compact };
            var bytes: [512]u8 = undefined;
            var json = std.Io.Writer.fixed(&bytes);
            try json.print("{{\"model\":\"{s}\"", .{model});
            if (has_parent) try json.writeAll(",\"parent\":\"k7m2qx\"");
            for (combination, fields, values) |state, field, value| {
                if (state != .omitted) try json.print(",\"{s}\":{s}", .{ field, if (state == .explicit_null) "null" else value });
            }
            try json.writeAll("}");
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json.buffered(), .{});
            var configuration: protocol.Requests(Custody).Configuration = .{ .workspace = .{ .value = .{ .len = 0 } } };
            const refusal = try protocol.parseAgentSpec(Custody, arena.allocator(), parsed.object, &configuration);
            // Base wire grammar never admitted null tool lists or permission.
            const expected_field: ?[]const u8 = if (tools == .explicit_null) "spec.tools" else if (loaded == .explicit_null) "spec.loadedTools" else if (mode == .explicit_null) "spec.permissionMode" else null;
            if (expected_field) |field| {
                try std.testing.expect(refusal != null);
                try std.testing.expect(std.mem.startsWith(u8, refusal.?, field));
                invalid += 1;
            } else {
                try std.testing.expect(refusal == null);
                try std.testing.expectEqual(tools, configuration.tools.state);
                try std.testing.expectEqual(loaded, configuration.loaded_tools.state);
                try std.testing.expectEqual(mode, configuration.permission_mode.state);
                try std.testing.expectEqual(effort, configuration.reasoning_effort.state);
                try std.testing.expectEqual(compact, configuration.compaction_trigger.state);
            }
            total += 1;
        };
    };
    try std.testing.expectEqual(@as(usize, 1458), total);
    try std.testing.expectEqual(@as(usize, 1026), invalid);
}

test "parent creation uses inherited provider for omitted compaction regardless of saved provider binding" {
    const bindings = [_]struct { saved_provider: Provider, saved_compact_at: u64 }{
        .{ .saved_provider = .openai, .saved_compact_at = 945000 },
        .{ .saved_provider = .codex, .saved_compact_at = 450000 },
    };
    const omitted_tools: input.ToolsField = .{};
    const omitted_choice = choice(.omitted, "");
    const omitted_tokens = tokenField(.omitted, "");
    for (bindings) |binding| {
        try std.testing.expectEqual(binding.saved_compact_at, compactionTrigger(catalog.shipped, binding.saved_provider, "gpt-6.1-sol"));
        const resolved = resolve(catalog.shipped, .{
            .creating = true,
            .parent = .{ .tools = "bash,find_tools,message_agent,read_action,read_transcript,skill,start_agent,stop_action,web_search", .permission_mode = .bypass },
            .provider = .codex,
            .model = "gpt-6.1-sol",
            .can_read_images = false,
            .tools = &omitted_tools,
            .loaded_tools = &omitted_tools,
            .permission_mode = &omitted_choice,
            .reasoning_effort = &omitted_choice,
            .compaction_trigger = &omitted_tokens,
        });
        try std.testing.expect(resolved.parent_refusal == null);
        try std.testing.expectEqualStrings("450000", resolved.compaction_trigger.value.slice());
    }
}

fn preferenceCases() !void {
    const tools = try input.ToolsField.of(&.{});
    const compact = tokenField(.omitted, "");
    const states = [_]input.FieldState{ .omitted, .value, .explicit_null };
    const saved_modes = [_]?[]const u8{ null, "ask", "bypass", "invalid", "" };
    const saved_efforts = [_]?[]const u8{ null, "none", "low", "medium", "high", "xhigh", "max", "invalid", "" };
    const parents = [_]?Parent{ null, .{ .tools = "", .permission_mode = .ask }, .{ .tools = "", .permission_mode = .bypass } };
    try std.testing.expectEqual(std.enums.values(catalog.ReasoningEffort).len + 3, saved_efforts.len);
    try std.testing.expectEqual(std.enums.values(@import("cli_value.zig").PermissionMode).len + 3, saved_modes.len);
    for (0..catalog.shipped.len + 1) |index| {
        const row = if (index < catalog.shipped.len) &catalog.shipped[index] else null;
        const model = if (row) |r| r.id else "unlisted-model";
        for (std.enums.values(Provider)) |provider| for (parents) |parent| for (states) |mode_state| for (states) |effort_state| {
            const mode = choice(mode_state, "ask");
            const effort = choice(effort_state, "high");
            const base: Request = .{ .creating = true, .parent = parent, .provider = provider, .model = model, .can_read_images = false, .tools = &tools, .loaded_tools = &tools, .permission_mode = &mode, .reasoning_effort = &effort, .compaction_trigger = &compact };
            const fallback = resolve(catalog.shipped, base);
            for (saved_modes) |saved_mode| for (saved_efforts) |saved_effort| {
                var request = base;
                request.preferences = .{ .permission_mode = saved_mode, .reasoning_effort = saved_effort };
                const actual = resolve(catalog.shipped, request);
                var expected_mode = fallback.permission_mode;
                if (mode_state == .omitted) if (saved_mode) |saved| {
                    if (std.mem.eql(u8, saved, "ask") or (std.mem.eql(u8, saved, "bypass") and (parent == null or parent.?.permission_mode == .bypass))) expected_mode = choice(.value, saved);
                };
                try std.testing.expectEqual(expected_mode.state, actual.permission_mode.state);
                try std.testing.expectEqualStrings(expected_mode.value.slice(), actual.permission_mode.value.slice());
                const refused = parent != null and parent.?.permission_mode == .ask and expected_mode.state == .value and !expected_mode.value.eql("ask");
                try std.testing.expectEqual(refused, actual.parent_refusal != null);
                var expected_effort = fallback.reasoning_effort;
                if (effort_state == .omitted) if (saved_effort) |saved| {
                    if (std.meta.stringToEnum(catalog.ReasoningEffort, saved)) |parsed| {
                        if (row == null or row.?.efforts.contains(parsed)) expected_effort = choice(.value, saved);
                    }
                };
                try std.testing.expectEqual(expected_effort.state, actual.reasoning_effort.state);
                try std.testing.expectEqualStrings(expected_effort.value.slice(), actual.reasoning_effort.value.slice());
                request.creating = false;
                const update = resolve(catalog.shipped, request);
                request.preferences = .{};
                const update_without = resolve(catalog.shipped, request);
                try std.testing.expectEqual(update_without.permission_mode.state, update.permission_mode.state);
                try std.testing.expectEqualStrings(update_without.permission_mode.value.slice(), update.permission_mode.value.slice());
                try std.testing.expectEqual(update_without.reasoning_effort.state, update.reasoning_effort.state);
                try std.testing.expectEqualStrings(update_without.reasoning_effort.value.slice(), update.reasoning_effort.value.slice());
            };
        };
    }
}

fn selectedPreferenceCases() !void {
    const tools = try input.ToolsField.of(&.{});
    const omitted = choice(.omitted, "");
    const compact = tokenField(.omitted, "");
    var selected = catalog.shipped[0];
    selected.id = "custom-model";
    const request: Request = .{ .creating = true, .provider = .openai, .model = "custom-model", .can_read_images = false, .tools = &tools, .loaded_tools = &tools, .permission_mode = &omitted, .reasoning_effort = &omitted, .compaction_trigger = &compact, .preferences = .{ .reasoning_effort = "max" } };
    selected.efforts = .initMany(&.{ .low, .max });
    const accepted = resolve(&.{selected}, request);
    try std.testing.expectEqualStrings("max", accepted.reasoning_effort.value.slice());
    selected.efforts = .initOne(.low);
    const ignored = resolve(&.{selected}, request);
    try std.testing.expectEqualStrings("low", ignored.reasoning_effort.value.slice());
    selected.efforts = .empty;
    const no_effort = resolve(&.{selected}, request);
    try std.testing.expectEqual(input.FieldState.explicit_null, no_effort.reasoning_effort.state);
}

fn toolProfileCases() !void {
    const cases = [_]struct { model: []const u8, accepts_images: bool }{
        .{ .model = "gpt-3.5-turbo", .accepts_images = false },
        .{ .model = "gpt-3.5-turbo-0125", .accepts_images = false },
        .{ .model = "gpt-3.5-turbo-1106", .accepts_images = false },
        .{ .model = "gpt-3.5-turbo-instruct", .accepts_images = false },
        .{ .model = "gpt-6.1-sol", .accepts_images = true },
        .{ .model = "gpt-4.1", .accepts_images = true },
        .{ .model = "unlisted-model", .accepts_images = true },
        .{ .model = "gpt-3.5-turbo-next", .accepts_images = true },
    };
    const text_allowed = "bash find_tools message_agent read_action read_transcript skill start_agent stop_action web_search";
    const image_allowed = "bash find_tools message_agent read_action read_image read_transcript skill start_agent stop_action web_search";
    const text_loaded = "bash find_tools skill web_search";
    const image_loaded = "bash find_tools read_image skill web_search";
    const parent_text = "bash,find_tools,message_agent,read_action,read_transcript,skill,start_agent,stop_action,web_search";
    const parent_image = "bash,find_tools,message_agent,read_action,read_image,read_transcript,skill,start_agent,stop_action,web_search";
    const mode = choice(.value, "ask");
    const effort = choice(.omitted, "");
    const compact = tokenField(.omitted, "");
    for (cases) |case| for ([_]bool{ false, true }) |can_read| for ([_]bool{ false, true }) |parent_has_image| {
        for ([_]input.FieldState{ .omitted, .value, .explicit_null }) |tools_state| for ([_]input.FieldState{ .omitted, .value, .explicit_null }) |loaded_state| {
            var tools = try input.ToolsField.of(&.{"bash"});
            var loaded = try input.ToolsField.of(&.{"bash"});
            tools.state = tools_state;
            loaded.state = loaded_state;
            const image = case.accepts_images and can_read;
            var request: Request = .{
                .creating = true,
                .parent = .{ .tools = if (parent_has_image) parent_image else parent_text, .permission_mode = .ask },
                .provider = .codex,
                .model = case.model,
                .can_read_images = can_read,
                .tools = &tools,
                .loaded_tools = &loaded,
                .permission_mode = &mode,
                .reasoning_effort = &effort,
                .compaction_trigger = &compact,
            };
            const selected = creationTools(&tools, case.model, can_read);
            const result = resolve(catalog.shipped, request);
            try std.testing.expect(selected == result.tools);
            if (tools_state == .omitted) {
                try std.testing.expectEqualStrings(if (image) image_allowed else text_allowed, result.tools.names.slice());
            } else try std.testing.expect(result.tools == &tools);
            if (tools_state == .omitted and loaded_state == .omitted) {
                try std.testing.expectEqual(input.FieldState.value, result.loaded_tools.state);
                try std.testing.expectEqualStrings(if (image) image_loaded else text_loaded, result.loaded_tools.names.slice());
            } else try std.testing.expect(result.loaded_tools == &loaded);
            if (tools_state == .omitted and image and !parent_has_image) {
                try std.testing.expectEqualStrings("read_image", result.parent_refusal.?.tools_not_in_parent);
            } else try std.testing.expect(result.parent_refusal == null);
            request.creating = false;
            const update = resolve(catalog.shipped, request);
            try std.testing.expect(update.tools == &tools and update.loaded_tools == &loaded);
            try std.testing.expect(update.parent_refusal == null);
        };
    };
}

test "ADM-28 configuration default resolution" {
    try creationFieldCases();
    try updateFieldCases();
    try selectedModelCases();
    try preferenceCases();
    try selectedPreferenceCases();
    try toolProfileCases();
}
