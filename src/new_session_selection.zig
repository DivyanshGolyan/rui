const std = @import("std");
const provider_route = @import("provider_route.zig");
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

    /// Whether the command line names a provider or model, which makes a wide
    /// launch's binding explicit.
    pub fn namesBinding(self: Intent) bool {
        return self.provider != null or self.model != null;
    }
};

test "Intent.namesBinding is true when either provider or model is named" {
    const cases = [_]struct { intent: Intent, names: bool }{
        .{ .intent = .{}, .names = false },
        .{ .intent = .{ .provider = "codex" }, .names = true },
        .{ .intent = .{ .model = "gpt-6-luna" }, .names = true },
        .{ .intent = .{ .provider = "codex", .model = "gpt-6-luna" }, .names = true },
    };
    for (cases) |case| try std.testing.expectEqual(case.names, case.intent.namesBinding());
    try std.testing.expect(!(Intent{ .store = "/store" }).namesBinding());
}

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

    /// The binding when the caller does not prompt: `usable` names every served provider the caller may select.
    pub fn resolveUnprompted(self: *const Snapshot, usable: *const provider_selection.Readinesses) !Binding {
        if (self.intent.provider) |name| if (provider_selection.passesThrough(name, usable)) return self.resolveUnknown(name);
        const provider = self.intent.provider orelse if (self.defaults.provider.len == 0) @as([]const u8, product_defaults.provider) else null;
        return (try self.resolveWith(provider, usable)).?;
    }

    /// A name this client does not know locally goes to the Host unchanged, with the model the shared owner gives it.
    fn resolveUnknown(self: *const Snapshot, name: []const u8) !Binding {
        const unknown = try provider_selection.resolveUnknown(
            name,
            self.intent.model,
            if (self.defaults.provider.len == 0) null else self.defaults.provider.slice(),
            if (self.defaults.model.len == 0) null else self.defaults.model.slice(),
        );
        var binding: Binding = .{};
        try binding.provider.set(unknown.provider);
        try binding.model.set(unknown.model);
        return binding;
    }

    fn resolveWith(self: *const Snapshot, explicit_provider: ?[]const u8, readiness: *const provider_selection.Readinesses) !?Binding {
        const selection = try provider_selection.resolve(
            model_capability.capabilities(readiness).slice(),
            explicit_provider,
            self.intent.model,
            if (self.defaults.provider.len == 0) null else self.defaults.provider.slice(),
            if (self.defaults.model.len == 0) null else self.defaults.model.slice(),
        );
        if (selection == .chooser or !selection.selected.readiness.usable()) return null;
        var binding: Binding = .{};
        try binding.provider.set(selection.selected.provider);
        try binding.model.set(selection.selected.model);
        return binding;
    }
};

pub const Binding = struct {
    provider: protocol.Bounded(16) = .{},
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
};

fn codexOnly(state: provider_selection.Readiness) provider_selection.Readinesses {
    var readiness: provider_selection.Readinesses = .initFill(.missing);
    readiness.set(provider_route.nameOf(.codex), state);
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
    try std.testing.expectEqualStrings("gpt-6.1-sol", (try snapshot.resolve(&codexOnly(.configured))).?.model.slice());
    snapshot.defaults = .{};
    snapshot.intent = .{};
    const home = try snapshot.destination("/home/test", &fallback);
    try std.testing.expect(!home.saved);
    try std.testing.expectEqualStrings("/home/test/.local/share/rui/store", home.path);
    try std.testing.expectEqual(@as(?Binding, null), try snapshot.resolve(&codexOnly(.missing)));
    try std.testing.expectEqualStrings("gpt-6.1-sol", (try snapshot.resolve(&codexOnly(.renewal_due))).?.model.slice());
    snapshot.intent.model = "bad model";
    try std.testing.expectError(error.UnsupportedSelectionModel, snapshot.resolve(&codexOnly(.configured)));

    const long_raw_path = @as([std.Io.Dir.max_path_bytes + 1]u8, @splat('x'));
    snapshot.intent.store = &long_raw_path;
    try std.testing.expectEqualStrings(&long_raw_path, (try snapshot.destination("relative-home", &fallback)).path);
    snapshot.intent.store = null;
    try std.testing.expectError(error.InvalidHome, snapshot.destination("relative-home", &fallback));
}

test "CM-58 new Session binding takes a usable served name, and an unprompted caller takes its explicit, saved or product choice" {
    const connection = @import("connection.zig");
    const alpha = connection.Name.parse("alpha").?;
    for (std.enums.values(provider_selection.Readiness)) |state| {
        var readiness: provider_selection.Readinesses = .initFill(.missing);
        readiness.set(alpha, state);
        const explicit: Snapshot = .{ .intent = .{ .provider = "alpha" }, .defaults = .{} };
        const bound = try explicit.resolve(&readiness);
        if (state.usable()) try std.testing.expectEqualStrings("alpha", bound.?.provider.slice()) else try std.testing.expectEqual(@as(?Binding, null), bound);

        var saved: Snapshot = .{ .intent = .{}, .defaults = .{} };
        try saved.defaults.provider.set("alpha");
        try saved.defaults.model.set("saved-model");
        const saved_bound = try saved.resolve(&readiness);
        if (state.usable()) {
            try std.testing.expectEqualStrings("alpha", saved_bound.?.provider.slice());
            try std.testing.expectEqualStrings("saved-model", saved_bound.?.model.slice());
        } else try std.testing.expectEqual(@as(?Binding, null), saved_bound);
    }

    // Ready and unready built-ins: a saved unready provider binds nothing, and no saved provider with two ready asks.
    var both: provider_selection.Readinesses = .initFill(.configured);
    var none_saved: Snapshot = .{ .intent = .{}, .defaults = .{} };
    try std.testing.expectEqual(@as(?Binding, null), try none_saved.resolve(&both));
    try none_saved.defaults.provider.set("openai");
    try std.testing.expectEqualStrings("openai", (try none_saved.resolve(&both)).?.provider.slice());
    both.set(provider_route.nameOf(.openai), .missing);
    try std.testing.expectEqual(@as(?Binding, null), try none_saved.resolve(&both));

    // Unprompted: the caller's usable set decides; explicit, then saved, then the product provider.
    var usable: provider_selection.Readinesses = .initFill(.configured);
    usable.set(alpha, .configured);
    var snapshot: Snapshot = .{ .intent = .{ .provider = "alpha" }, .defaults = .{} };
    try std.testing.expectEqualStrings("alpha", (try snapshot.resolveUnprompted(&usable)).provider.slice());
    snapshot = .{ .intent = .{}, .defaults = .{} };
    try std.testing.expectEqualStrings(product_defaults.provider, (try snapshot.resolveUnprompted(&usable)).provider.slice());
    try snapshot.defaults.provider.set("alpha");
    try std.testing.expectEqualStrings("alpha", (try snapshot.resolveUnprompted(&usable)).provider.slice());
    try snapshot.defaults.provider.set("gone");
    try std.testing.expectError(error.UnsupportedSelectionProvider, snapshot.resolveUnprompted(&usable));
}
