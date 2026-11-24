const std = @import("std");
const model_capability = @import("model_capability.zig");
const protocol = @import("protocol.zig");
const connection = @import("connection.zig");
const provider_selection = @import("provider_selection.zig");
pub const Readinesses = provider_selection.Readinesses;
pub const max_file_bytes = 1024;

pub const Values = struct {
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    provider: protocol.Bounded(16) = .{},
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    notifications: bool = true,
    reasoning_effort: ?model_capability.ReasoningEffort = null,
    permission_mode: ?@import("cli_value.zig").PermissionMode = null,
};

pub fn validAbsoluteText(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path) or !std.unicode.utf8ValidateSlice(path)) return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

pub const Change = union(enum) { keep, set: []const u8 };

pub const Edit = struct {
    store: Change = .keep,
    provider: Change = .keep,
    model: union(enum) { keep, set: []const u8, clear } = .keep,
    notifications: ?bool = null,
    reasoning_effort: union(enum) { keep, set: model_capability.ReasoningEffort, clear } = .keep,
    permission_mode: union(enum) { keep, set: PermissionMode, clear } = .keep,
};

pub fn validate(values: *const Values) !void {
    if (values.store.len != 0 and !validAbsoluteText(values.store.slice())) return error.InvalidPreferenceStore;
    for (values.provider.slice()) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidPreferenceProvider;
    }
    if (values.model.len != 0 and !model_capability.validModelSyntax(values.model.slice())) return error.InvalidPreferenceModel;
    if (values.model.len != 0 and values.provider.len == 0) return error.PreferenceProviderRequired;
}

pub fn validateSaved(values: *const Values) !void {
    validate(values) catch |err| return switch (err) {
        error.InvalidPreferenceStore => error.SavedPreferenceStoreInvalid,
        error.InvalidPreferenceProvider => error.SavedPreferenceProviderInvalid,
        error.InvalidPreferenceModel => error.SavedPreferenceModelInvalid,
        error.PreferenceProviderRequired => error.SavedPreferenceProviderRequired,
    };
}

const effort_key = "reasoning_effort=";
const permission_key = "permission_mode=";
const PermissionMode = @import("cli_value.zig").PermissionMode;

pub fn decode(bytes: []const u8) !Values {
    if (bytes.len > max_file_bytes) return error.InvalidPreferences;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const version_line = lines.next() orelse "";
    const known = [_][]const u8{ "version=1", "version=2", "version=3", "version=4" };
    const number = for (known, 1..) |name, at| {
        if (std.mem.eql(u8, version_line, name)) break at;
    } else return error.UnsupportedPreferencesVersion;
    var result: Values = .{};
    const fields = .{ .{ "store=", &result.store }, .{ "connection=", &result.provider }, .{ "model=", &result.model } };
    inline for (fields) |field| {
        const line = lines.next() orelse return error.InvalidPreferences;
        if (!std.mem.startsWith(u8, line, field[0])) return error.InvalidPreferences;
        field[1].set(line[field[0].len..]) catch return error.InvalidPreferences;
    }
    if (number >= 2) {
        const line = lines.next() orelse return error.InvalidPreferences;
        result.notifications = if (std.mem.eql(u8, line, "notifications=on")) true else if (std.mem.eql(u8, line, "notifications=off")) false else return error.InvalidPreferences;
    }
    if (number >= 3) {
        const line = lines.next() orelse return error.InvalidPreferences;
        if (!std.mem.startsWith(u8, line, effort_key)) return error.InvalidPreferences;
        const text = line[effort_key.len..];
        if (number < 4 or text.len != 0) result.reasoning_effort = std.meta.stringToEnum(model_capability.ReasoningEffort, text) orelse return error.InvalidPreferences;
    }
    if (number >= 4) {
        const line = lines.next() orelse return error.InvalidPreferences;
        if (!std.mem.startsWith(u8, line, permission_key)) return error.InvalidPreferences;
        const text = line[permission_key.len..];
        if (text.len != 0) result.permission_mode = std.meta.stringToEnum(PermissionMode, text) orelse return error.InvalidPreferences;
    }
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidPreferences, "") or lines.next() != null)
        return error.InvalidPreferences;
    return result;
}

pub const Failure = struct {
    saved: bool = false,
    reason: ?[]const u8 = null,
};

pub fn failure(err: anyerror) Failure {
    return switch (err) {
        error.PreferenceDirectorySyncFailed => .{ .saved = true, .reason = "durability unconfirmed; inspect HOME/.config/rui/preferences before another update" },
        error.UnsupportedPreferenceProvider => .{ .reason = "the provider must be " ++ provider_names },
        error.PreferenceProviderRequired => .{ .reason = "a model needs a provider: " ++ provider_names },
        error.UnsupportedPreferenceModel, error.InvalidPreferenceModel => .{ .reason = "a model ID is 1–256 printable non-space ASCII bytes" },
        error.InvalidPreferenceStore, error.FileNotFound => .{ .reason = "the Store must be an existing private, canonicalizable absolute directory" },
        else => .{},
    };
}

const provider_names = blk: {
    var text: []const u8 = "";
    for (std.meta.fieldNames(protocol.Provider), 0..) |name, at| text = text ++ (if (at == 0) "" else " or ") ++ name;
    break :blk text;
};

pub fn otherWayIn(saved: []const u8, chosen: []const u8) bool {
    const provider = std.meta.stringToEnum(protocol.Provider, chosen) orelse return false;
    const other = provider.sameAccount() orelse return false;
    return std.mem.eql(u8, saved, @tagName(other));
}

pub fn validateEdit(edit: Edit) !void {
    if (edit.provider == .set and connection.Name.parse(edit.provider.set) == null) return error.UnsupportedPreferenceProvider;
    if (edit.model == .set and !model_capability.validModelSyntax(edit.model.set)) return error.InvalidPreferenceModel;
    if (edit.store == .set) {
        const value = edit.store.set;
        if (!std.fs.path.isAbsolute(value)) return error.InvalidPreferenceStore;
        for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidPreferenceStore;
    }
}

/// Whether the Host serves this name: a built-in or a key connection in the readiness list.
fn served(readiness: *const Readinesses, text: []const u8) bool {
    const name = connection.Name.parse(text) orelse return false;
    for (readiness.names()) |*one| if (one.eql(name)) return true;
    return false;
}

pub fn apply(saved: Values, edit: Edit, store: ?[]const u8, readiness: *const Readinesses) !Values {
    try validateEdit(edit);
    if (edit.provider == .set and !served(readiness, edit.provider.set)) return error.UnsupportedPreferenceProvider;
    var values = saved;
    if (edit.store == .set) {
        values.store.set(store.?) catch return error.InvalidPreferenceStore;
    }
    if (edit.provider == .set) {
        if (!saved.provider.eql(edit.provider.set) and !otherWayIn(saved.provider.slice(), edit.provider.set)) values.model = .{};
        values.provider.set(edit.provider.set) catch unreachable;
    }
    if (edit.notifications) |on| values.notifications = on;
    switch (edit.reasoning_effort) {
        .keep => {},
        .set => |effort| values.reasoning_effort = effort,
        .clear => values.reasoning_effort = null,
    }
    switch (edit.permission_mode) {
        .keep => {},
        .set => |mode| values.permission_mode = mode,
        .clear => values.permission_mode = null,
    }
    switch (edit.model) {
        .keep => {},
        .clear => values.model = .{},
        .set => |model| {
            const choice = provider_selection.resolve(model_capability.capabilities(readiness).slice(), null, model, if (values.provider.len != 0) values.provider.slice() else null, null) catch |err| switch (err) {
                error.UnsupportedSelectionProvider => return error.UnsupportedPreferenceProvider,
                error.UnsupportedSelectionModel => return error.UnsupportedPreferenceModel,
            };
            if (choice == .chooser) return error.PreferenceProviderRequired;
            values.provider.set(choice.selected.provider) catch unreachable;
            values.model.set(model) catch unreachable;
        },
    }
    return values;
}

pub fn encode(values: *const Values, buffer: *[max_file_bytes]u8) ![]const u8 {
    const fields = .{ values.store.slice(), values.provider.slice(), values.model.slice() };
    return std.fmt.bufPrint(buffer, "version=4\nstore={s}\nconnection={s}\nmodel={s}\nnotifications={s}\n" ++ effort_key ++ "{s}\n" ++ permission_key ++ "{s}\n", fields ++ .{
        if (values.notifications) "on" else "off",
        if (values.reasoning_effort) |effort| @tagName(effort) else "",
        if (values.permission_mode) |mode| @tagName(mode) else "",
    }) catch return error.InvalidPreferences;
}

test "CLI-22 a defaults file reads versions 1 through 4 and always writes version 4" {
    const literals = [_]struct { text: []const u8, encoded: []const u8 }{
        .{ .text = "version=1\nstore=\nconnection=codex\nmodel=gpt-6-luna\n", .encoded = "version=4\nstore=\nconnection=codex\nmodel=gpt-6-luna\nnotifications=on\nreasoning_effort=\npermission_mode=\n" },
        .{ .text = "version=2\nstore=\nconnection=codex\nmodel=gpt-6-luna\nnotifications=off\n", .encoded = "version=4\nstore=\nconnection=codex\nmodel=gpt-6-luna\nnotifications=off\nreasoning_effort=\npermission_mode=\n" },
        .{ .text = "version=3\nstore=\nconnection=codex\nmodel=gpt-6-luna\nnotifications=off\nreasoning_effort=high\n", .encoded = "version=4\nstore=\nconnection=codex\nmodel=gpt-6-luna\nnotifications=off\nreasoning_effort=high\npermission_mode=\n" },
        .{ .text = "version=4\nstore=\nconnection=codex\nmodel=gpt-6-luna\nnotifications=off\nreasoning_effort=high\npermission_mode=ask\n", .encoded = "version=4\nstore=\nconnection=codex\nmodel=gpt-6-luna\nnotifications=off\nreasoning_effort=high\npermission_mode=ask\n" },
    };
    for (literals) |case| {
        const values = try decode(case.text);
        var buffer: [max_file_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(case.encoded, try encode(&values, &buffer));
    }
    const refusals = [_][]const u8{
        "version=1\nstore=\nconnection=\n",                                                                    "version=1\nconnection=\nstore=\nmodel=\n",
        "version=1\nstore=\nconnection=\nmodel=",                                                              "version=1\nstore=\nconnection=\nmodel=\nextra\n",
        "version=2\nstore=\nconnection=\nmodel=\nnotifications=maybe\n",                                       "version=3\nstore=\nconnection=\nmodel=\nnotifications=on\nreasoning_effort=\n",
        "version=4\nstore=\nconnection=\nmodel=\nnotifications=on\nreasoning_effort=\npermission_mode=plan\n", "version=4\nstore=\nconnection=\nmodel=\nnotifications=on\nreasoning_effort=\npermission\n",
    };
    for (refusals) |text| try std.testing.expectError(error.InvalidPreferences, decode(text));
    try std.testing.expectError(error.UnsupportedPreferencesVersion, decode("version=9\n"));
    const oversized: [1025]u8 = @splat('x');
    try std.testing.expectError(error.InvalidPreferences, decode(&oversized));
    for ([_]bool{ false, true }) |notifications| {
        for ([_]?model_capability.ReasoningEffort{ null, .none, .low, .medium, .high, .xhigh, .max }) |effort| {
            for ([_]?PermissionMode{ null, .ask, .bypass }) |mode| {
                for ([_]bool{ false, true }) |with_store| for ([_]bool{ false, true }) |with_provider| for ([_]bool{ false, true }) |with_model| {
                    var values: Values = .{ .notifications = notifications, .reasoning_effort = effort, .permission_mode = mode };
                    if (with_store) try values.store.set("/tmp/store");
                    if (with_provider) try values.provider.set("codex");
                    if (with_model) try values.model.set("gpt-6-luna");
                    var bytes: [max_file_bytes]u8 = undefined;
                    try std.testing.expectEqualDeep(values, try decode(try encode(&values, &bytes)));
                };
            }
        }
    }
}

test "CLI-23 an edit changes only what it names" {
    const readiness: Readinesses = .initFill(.configured);
    var saved: Values = .{};
    try saved.provider.set("codex");
    try saved.model.set("gpt-6-luna");
    const cases = .{
        .{ Edit{}, "codex", "gpt-6-luna", true },
        .{ Edit{ .model = .clear }, "codex", "", true },
        .{ Edit{ .model = .{ .set = "new-model" } }, "codex", "new-model", true },
        .{ Edit{ .provider = .{ .set = "openai" } }, "openai", "", true },
        .{ Edit{ .notifications = false }, "codex", "gpt-6-luna", false },
    };
    inline for (cases) |case| {
        const actual = try apply(saved, case[0], null, &readiness);
        try std.testing.expectEqualStrings(case[1], actual.provider.slice());
        try std.testing.expectEqualStrings(case[2], actual.model.slice());
        try std.testing.expectEqual(case[3], actual.notifications);
    }
    // Exercise every independent edit field across empty, full and retired saved defaults.
    const stores = [_]Change{ .keep, .{ .set = "/new" } };
    const providers = [_]Change{ .keep, .{ .set = "codex" }, .{ .set = "openai" }, .{ .set = "chatgpt" } };
    const models: [3]@FieldType(Edit, "model") = .{ .keep, .clear, .{ .set = "new-model" } };
    const notifications = [_]?bool{ null, false, true };
    const efforts: [3]@FieldType(Edit, "reasoning_effort") = .{ .keep, .clear, .{ .set = .high } };
    const permissions: [3]@FieldType(Edit, "permission_mode") = .{ .keep, .clear, .{ .set = .bypass } };
    for ([_][]const u8{ "", "codex", "retired" }) |original_provider| {
        var before: Values = .{};
        if (original_provider.len != 0) {
            before.notifications = false;
            before.reasoning_effort = .low;
            before.permission_mode = .ask;
            try before.store.set("/old");
            try before.provider.set(original_provider);
            try before.model.set("old-model");
        }
        for ([_]provider_selection.Readiness{ .configured, .renewal_due, .missing, .refresh_required, .credential_error }) |state| {
            const states: Readinesses = .initFill(state);
            for (stores) |store| for (providers) |provider| for (models) |model| for (notifications) |notification| for (efforts) |effort| for (permissions) |permission| {
                const edit: Edit = .{ .store = store, .provider = provider, .model = model, .notifications = notification, .reasoning_effort = effort, .permission_mode = permission };
                const chosen = if (provider == .set) provider.set else original_provider;
                if (model == .set and chosen.len == 0) {
                    try std.testing.expectError(error.PreferenceProviderRequired, apply(before, edit, if (store == .set) "/new" else null, &states));
                    continue;
                }
                if (model == .set and std.mem.eql(u8, chosen, "retired")) {
                    try std.testing.expectError(error.UnsupportedPreferenceProvider, apply(before, edit, if (store == .set) "/new" else null, &states));
                    continue;
                }
                const result = try apply(before, edit, if (store == .set) "/new" else null, &states);
                try std.testing.expectEqualStrings(if (store == .set) "/new" else before.store.slice(), result.store.slice());
                try std.testing.expectEqualStrings(chosen, result.provider.slice());
                const kept_model = if (provider == .keep or std.mem.eql(u8, original_provider, chosen) or (std.mem.eql(u8, original_provider, "codex") and std.mem.eql(u8, chosen, "chatgpt"))) before.model.slice() else "";
                try std.testing.expectEqualStrings(switch (model) {
                    .keep => kept_model,
                    .clear => "",
                    .set => "new-model",
                }, result.model.slice());
                try std.testing.expectEqual(notification orelse before.notifications, result.notifications);
                try std.testing.expectEqual(switch (effort) {
                    .keep => before.reasoning_effort,
                    .clear => null,
                    .set => .high,
                }, result.reasoning_effort);
                try std.testing.expectEqual(switch (permission) {
                    .keep => before.permission_mode,
                    .clear => null,
                    .set => .bypass,
                }, result.permission_mode);
            };
        }
    }
    try std.testing.expectError(error.InvalidPreferenceModel, apply(saved, .{ .model = .{ .set = "two words" } }, null, &readiness));
    try std.testing.expectError(error.UnsupportedPreferenceProvider, apply(saved, .{ .provider = .{ .set = "retired" } }, null, &readiness));
}
