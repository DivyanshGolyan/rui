const std = @import("std");
const input = @import("command_input.zig");
const catalog = @import("model_catalog.zig");
const capability = @import("model_capability.zig");
const product = @import("product_defaults.zig");
const Provider = @import("provider_name.zig").Provider;

const Choice = input.OptionalBounded(16);
const Tokens = input.OptionalBounded(20);
const Model = input.OptionalBounded(capability.max_model_bytes);
const product_model: Model = blk: {
    var field: Model = .{ .state = .value };
    field.value.set(product.recommended_model) catch unreachable;
    break :blk field;
};

const product_tools = names(product.tools);
const product_loaded = names(product.loaded_tools);
const product_permission = choice(.value, product.permission_mode);

fn names(comptime text: []const u8) input.ToolsField {
    @setEvalBranchQuota(10000);
    var out: input.ToolsField = .{ .state = .value };
    var each = std.mem.splitScalar(u8, text, ',');
    while (each.next()) |name| out.insert(name) catch unreachable;
    return out;
}

/// Model selection precedes the Host catalog read; all returned fields borrow
/// the request or immutable product defaults.
pub fn creationModel(requested: *const Model) *const Model {
    return if (requested.state == .omitted) &product_model else requested;
}

/// These lists borrow the request or immutable product defaults.
pub fn creationTools(requested: *const input.ToolsField) *const input.ToolsField {
    return if (requested.state == .omitted) &product_tools else requested;
}

fn creationPermission(requested: *const Choice) *const Choice {
    return if (requested.state == .omitted) &product_permission else requested;
}

pub fn compactionTrigger(facts: []const catalog.Entry, provider: Provider, model: []const u8) u64 {
    const model_trigger = capability.contextWindow(facts, model) * product.compaction_trigger_percent / 100;
    const provider_trigger = for (product.provider_compaction_triggers) |entry| {
        if (std.mem.eql(u8, entry.provider, @tagName(provider))) break entry.tokens;
    } else model_trigger;
    return @min(provider_trigger, model_trigger);
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
        out.tools = creationTools(request.tools);
        if (request.tools.state == .omitted and request.loaded_tools.state == .omitted) out.loaded_tools = &product_loaded;
        out.permission_mode = creationPermission(request.permission_mode).*;
        if (request.permission_mode.state == .omitted) if (request.preferences.permission_mode) |saved| {
            if (std.meta.stringToEnum(@import("cli_value.zig").PermissionMode, saved)) |mode| {
                if (request.parent == null or request.parent.?.permission_mode != .ask or mode == .ask) {
                    out.permission_mode = choice(.value, saved);
                }
            }
        };
        if (request.parent) |parent| out.parent_refusal = checkParent(parent, request.tools, &out.permission_mode);
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
    var requested = creationTools(tools).iterator();
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

test "configuration defaults enumerate every omitted explicit and null combination with and without a parent" {
    const models = [_]struct { id: []const u8, effort: ?[]const u8, compact: [3][]const u8 }{
        .{ .id = "gpt-6.1-sol", .effort = "low", .compact = .{ "244800", "945000", "945000" } },
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

test "configuration defaults preserve update omissions and explicit values while resetting null policies" {
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
        try std.testing.expectEqualStrings(if (compact_state == .explicit_null) "244800" else "00042", resolved.compaction_trigger.value.slice());
    };
}

test "configuration defaults use only selected Host model facts and preserve every explicit effort" {
    const facts: []const catalog.Entry = &.{
        .{ .id = "gpt-6.1-sol", .context_window = 1000, .efforts = .init(.{ .high = true }), .openai_listed = true },
        .{ .id = "no-effort", .context_window = 2000, .efforts = .{}, .openai_listed = false },
        .{ .id = "no-window", .context_window = null, .efforts = .init(.{ .max = true }), .openai_listed = false },
    };
    try std.testing.expectEqual(@as(u64, 900), compactionTrigger(facts, .codex, "gpt-6.1-sol"));
    try std.testing.expectEqual(@as(u64, 1800), compactionTrigger(facts, .openai, "no-effort"));
    try std.testing.expectEqual(@as(u64, 115200), compactionTrigger(facts, .openai, "no-window"));
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

test "configuration defaults parent checks reject default widening and preserve explicit empty intent" {
    const parent: Parent = .{ .tools = "bash", .permission_mode = .ask };
    const omitted: input.ToolsField = .{};
    const empty = try input.ToolsField.of(&.{});
    const bash = try input.ToolsField.of(&.{"bash"});
    const ask = choice(.value, "ask");
    const inherited = choice(.omitted, "");
    try std.testing.expectEqualStrings("find_tools", checkParent(parent, &omitted, &ask).?.tools_not_in_parent);
    try std.testing.expect(checkParent(parent, &empty, &ask) == null);
    try std.testing.expect(checkParent(parent, &bash, &ask) == null);
    try std.testing.expect(checkParent(parent, &bash, &inherited).? == .permission_mode_wider_than_parent);
}

test "configuration defaults enumerate wire refusal for every null list and permission combination" {
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

test "configuration defaults select the recommended model only for creation omissions" {
    var model: Model = .{};
    try std.testing.expectEqual(input.FieldState.value, creationModel(&model).state);
    try std.testing.expectEqualStrings("gpt-6.1-sol", creationModel(&model).value.slice());
    for ([_]input.FieldState{ .value, .explicit_null }) |state| {
        model.state = state;
        try model.value.set("custom-model");
        try std.testing.expect(creationModel(&model) == &model);
        try std.testing.expectEqual(state, model.state);
    }
}

test "parent creation uses inherited provider for omitted compaction regardless of saved provider binding" {
    const bindings = [_]struct { saved_provider: Provider, saved_compact_at: u64 }{
        .{ .saved_provider = .openai, .saved_compact_at = 945000 },
        .{ .saved_provider = .codex, .saved_compact_at = 244800 },
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
            .tools = &omitted_tools,
            .loaded_tools = &omitted_tools,
            .permission_mode = &omitted_choice,
            .reasoning_effort = &omitted_choice,
            .compaction_trigger = &omitted_tokens,
        });
        try std.testing.expect(resolved.parent_refusal == null);
        try std.testing.expectEqualStrings("244800", resolved.compaction_trigger.value.slice());
    }
}

test "creation preferences obey explicit intent and admission over the model and parent domains" {
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
            const base: Request = .{ .creating = true, .parent = parent, .provider = provider, .model = model, .tools = &tools, .loaded_tools = &tools, .permission_mode = &mode, .reasoning_effort = &effort, .compaction_trigger = &compact };
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

test "creation preferences use the selected Host catalog rather than shipped facts" {
    const tools = try input.ToolsField.of(&.{});
    const omitted = choice(.omitted, "");
    const compact = tokenField(.omitted, "");
    var selected = catalog.shipped[0];
    selected.id = "custom-model";
    const request: Request = .{ .creating = true, .provider = .openai, .model = "custom-model", .tools = &tools, .loaded_tools = &tools, .permission_mode = &omitted, .reasoning_effort = &omitted, .compaction_trigger = &compact, .preferences = .{ .reasoning_effort = "max" } };
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
