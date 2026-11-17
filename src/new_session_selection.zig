const std = @import("std");
const model_capability = @import("model_capability.zig");
const preferences = @import("preference_values.zig");
const product_defaults = @import("product_defaults.zig");
const protocol = @import("protocol.zig");
const provider_selection = @import("provider_selection.zig");

pub const Intent = struct {
    store: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,

    pub fn needsPreferences(self: Intent) bool {
        return self.store == null or self.provider == null or self.model == null;
    }
};

pub const Snapshot = struct {
    intent: Intent,
    defaults: preferences.Values,

    pub fn destination(self: *const Snapshot, home: []const u8, fallback: []u8) !struct { path: []const u8, saved: bool } {
        if (self.intent.store) |path| return .{ .path = path, .saved = false };
        if (self.defaults.store.len != 0) return .{ .path = self.defaults.store.slice(), .saved = true };
        return .{ .path = try preferences.defaultStore(home, fallback), .saved = false };
    }

    pub fn resolve(self: *const Snapshot, readiness: *const provider_selection.Readinesses) !?Binding {
        return self.resolveWith(self.intent.provider, readiness);
    }

    /// Creation carries a provider only when the caller or saved binding chose it.
    pub fn resolveCreation(self: *const Snapshot) !?Binding {
        if (self.intent.provider == null and self.defaults.provider.len == 0) return null;
        const usable: provider_selection.Readinesses = .initFill(.configured);
        return self.resolveWith(self.intent.provider, &usable);
    }

    pub fn resolveUnpromptedDisplay(self: *const Snapshot) !Binding {
        const provider = self.intent.provider orelse if (self.defaults.provider.len == 0) @as([]const u8, product_defaults.provider) else null;
        const usable: provider_selection.Readinesses = .initFill(.configured);
        return (try self.resolveWithMode(provider, &usable, true)).?;
    }

    pub fn resolveDisplay(self: *const Snapshot, readiness: *const provider_selection.Readinesses) !?Binding {
        return self.resolveWithMode(self.intent.provider, readiness, true);
    }

    fn resolveWith(self: *const Snapshot, explicit_provider: ?[]const u8, readiness: *const provider_selection.Readinesses) !?Binding {
        return self.resolveWithMode(explicit_provider, readiness, false);
    }

    fn resolveWithMode(self: *const Snapshot, explicit_provider: ?[]const u8, readiness: *const provider_selection.Readinesses, display: bool) !?Binding {
        const selection = try provider_selection.resolve(
            &model_capability.capabilities(readiness),
            explicit_provider,
            self.intent.model,
            if (self.defaults.provider.len == 0) null else self.defaults.provider.slice(),
            if (self.defaults.model.len == 0) null else self.defaults.model.slice(),
        );
        if (selection == .chooser or !selection.selected.readiness.usable()) return null;
        var binding: Binding = .{};
        try binding.provider.set(selection.selected.provider);
        const chosen_model = self.intent.model orelse if (self.defaults.provider.len != 0 and std.mem.eql(u8, selection.selected.provider, self.defaults.provider.slice()) and self.defaults.model.len != 0) self.defaults.model.slice() else null;
        if (chosen_model orelse if (display) selection.selected.model else null) |model| try binding.model.set(model);
        return binding;
    }
};

pub const Binding = struct {
    provider: protocol.Bounded(16) = .{},
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
};

fn codexOnly(state: provider_selection.Readiness) provider_selection.Readinesses {
    var readiness: provider_selection.Readinesses = .initFill(.missing);
    readiness.set(.codex, state);
    return readiness;
}

test "new Session preference dependency and refreshed choices with every explicit subset" {
    for (0..8) |mask| {
        const intent: Intent = .{
            .store = if (mask & 1 != 0) "/explicit" else null,
            .provider = if (mask & 2 != 0) "codex" else null,
            .model = if (mask & 4 != 0) "explicit-model" else null,
        };
        try std.testing.expectEqual(mask != 7, intent.needsPreferences());
        var defaults: preferences.Values = .{};
        try defaults.provider.set("codex");
        var fallback: [128]u8 = undefined;
        for ([_][2][]const u8{ .{ "/before", "before-model" }, .{ "/changed-after-choice", "after" } }) |values| {
            try defaults.store.set(values[0]);
            try defaults.model.set(values[1]);
            const snapshot: Snapshot = .{ .intent = intent, .defaults = if (intent.needsPreferences()) defaults else .{} };
            const destination = try snapshot.destination("/home/test", &fallback);
            try std.testing.expectEqualStrings(if (mask & 1 != 0) "/explicit" else values[0], destination.path);
            try std.testing.expectEqual(mask & 1 == 0, destination.saved);
            const binding = (try snapshot.resolve(&codexOnly(.configured))).?;
            try std.testing.expectEqualStrings("codex", binding.provider.slice());
            try std.testing.expectEqualStrings(if (mask & 4 != 0) "explicit-model" else values[1], binding.model.slice());
        }
    }
}

test "new Session refresh owns bindings and selects shorter and longer saved destinations" {
    for ([_][2][]const u8{
        .{ "/long-before-choice", "/s" },
        .{ "/s", "/a-much-longer-after-choice" },
    }) |paths| {
        var source: preferences.Values = .{};
        try source.store.set(paths[0]);
        try source.provider.set("codex");
        try source.model.set("before-choice-model");
        var snapshot: Snapshot = .{ .intent = .{}, .defaults = source };
        var fallback: [128]u8 = undefined;
        const before = try snapshot.destination("/home/test", &fallback);
        try std.testing.expect(before.saved);
        try std.testing.expectEqualStrings(paths[0], before.path);
        try std.testing.expectEqual(@as(?Binding, null), try snapshot.resolve(&codexOnly(.missing)));
        const retained = (try snapshot.resolve(&codexOnly(.configured))).?;

        try source.store.set(paths[1]);
        try source.model.set("after");
        try std.testing.expectEqualStrings(paths[0], (try snapshot.destination("/home/test", &fallback)).path);
        snapshot = .{ .intent = .{}, .defaults = source };
        const after = try snapshot.destination("/home/test", &fallback);
        try std.testing.expect(after.saved);
        try std.testing.expectEqualStrings(paths[1], after.path);
        const selected = (try snapshot.resolve(&codexOnly(.renewal_due))).?;
        try snapshot.defaults.model.set("overwritten-snapshot-model");
        try std.testing.expectEqualStrings("codex", selected.provider.slice());
        try std.testing.expectEqualStrings("after", selected.model.slice());
        try std.testing.expectEqualStrings("before-choice-model", retained.model.slice());
    }
}

test "new Session explicit choices bypass stale defaults without destination fallback" {
    var snapshot: Snapshot = .{ .intent = .{}, .defaults = .{} };
    try snapshot.defaults.store.set("/unavailable-saved-store");
    try snapshot.defaults.provider.set("removed");
    try snapshot.defaults.model.set("stale-model");
    var fallback: [128]u8 = undefined;
    const saved = try snapshot.destination("/home/test", &fallback);
    try std.testing.expect(saved.saved);
    try std.testing.expectEqualStrings("/unavailable-saved-store", saved.path);
    try std.testing.expectError(error.UnsupportedSelectionProvider, snapshot.resolve(&codexOnly(.configured)));
    snapshot.intent = .{ .store = "/explicit", .provider = "codex", .model = "explicit-model" };
    try std.testing.expect(!snapshot.intent.needsPreferences());
    const explicit = try snapshot.destination("/unused", &fallback);
    try std.testing.expect(!explicit.saved);
    try std.testing.expectEqualStrings("/explicit", explicit.path);
    for ([_]provider_selection.Readiness{ .missing, .refresh_required, .credential_error }) |state|
        try std.testing.expectEqual(@as(?Binding, null), try snapshot.resolve(&codexOnly(state)));
    try std.testing.expectEqualStrings("explicit-model", (try snapshot.resolve(&codexOnly(.renewal_due))).?.model.slice());
    snapshot.intent.model = null;
    try std.testing.expectEqualStrings("", (try snapshot.resolve(&codexOnly(.configured))).?.model.slice());
    snapshot.defaults = .{};
    snapshot.intent = .{};
    const home = try snapshot.destination("/home/test", &fallback);
    try std.testing.expect(!home.saved);
    try std.testing.expectEqualStrings("/home/test/.local/share/rui/store", home.path);
    try std.testing.expectEqual(@as(?Binding, null), try snapshot.resolve(&codexOnly(.missing)));
    try std.testing.expectEqualStrings("", (try snapshot.resolve(&codexOnly(.renewal_due))).?.model.slice());
    snapshot.intent.model = "bad model";
    try std.testing.expectError(error.UnsupportedSelectionModel, snapshot.resolve(&codexOnly(.configured)));

    const long_raw_path = @as([std.Io.Dir.max_path_bytes + 1]u8, @splat('x'));
    snapshot.intent.store = &long_raw_path;
    try std.testing.expectEqualStrings(&long_raw_path, (try snapshot.destination("relative-home", &fallback)).path);
    snapshot.intent.store = null;
    try std.testing.expectError(error.InvalidHome, snapshot.destination("relative-home", &fallback));
}

test "a saved provider picks among ready ones, and none saved with two ready asks" {
    var snapshot: Snapshot = .{ .intent = .{}, .defaults = .{} };
    const both: provider_selection.Readinesses = .initFill(.configured);
    try std.testing.expectEqual(@as(?Binding, null), try snapshot.resolve(&both));
    try snapshot.defaults.provider.set("openai");
    try std.testing.expectEqualStrings("openai", (try snapshot.resolve(&both)).?.provider.slice());
    var key_missing = both;
    key_missing.set(.openai, .missing);
    try std.testing.expectEqual(@as(?Binding, null), try snapshot.resolve(&key_missing));
}

test "creation only binds an explicit or saved provider" {
    var snapshot: Snapshot = .{ .intent = .{}, .defaults = .{} };
    try std.testing.expectEqual(@as(?Binding, null), try snapshot.resolveCreation());
    snapshot.intent.model = "explicit-model";
    try std.testing.expectEqual(@as(?Binding, null), try snapshot.resolveCreation());
    try snapshot.defaults.provider.set("openai");
    try snapshot.defaults.model.set("saved-model");
    var choice = (try snapshot.resolveCreation()).?;
    try std.testing.expectEqualStrings("openai", choice.provider.slice());
    try std.testing.expectEqualStrings("explicit-model", choice.model.slice());
    snapshot.intent.model = null;
    choice = (try snapshot.resolveCreation()).?;
    try std.testing.expectEqualStrings("saved-model", choice.model.slice());
    snapshot.intent.provider = "codex";
    choice = (try snapshot.resolveCreation()).?;
    try std.testing.expectEqualStrings("codex", choice.provider.slice());
    try std.testing.expectEqualStrings("", choice.model.slice());
    try std.testing.expectEqualStrings(product_defaults.provider, (try (Snapshot{ .intent = .{}, .defaults = .{} }).resolveUnpromptedDisplay()).provider.slice());
}
