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

test "CM-63 explicit launch intent: a named provider or model names the binding, and a store alone does not" {
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

test "CM-61 new Session store destination takes the explicit store, else the saved store, else the home default" {
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
        for ([_][]const u8{ "/before", "/changed-after-choice" }) |saved_store| {
            try defaults.store.set(saved_store);
            const snapshot: Snapshot = .{ .intent = intent, .defaults = if (intent.needsPreferences()) defaults else .{} };
            const destination = try snapshot.destination("/home/test", &fallback);
            try std.testing.expectEqualStrings(if (mask & 1 != 0) "/explicit" else saved_store, destination.path);
            try std.testing.expectEqual(mask & 1 == 0, destination.saved);
        }
    }

    // A snapshot keeps the saved store it was taken with, and a later snapshot takes the new one, shorter or longer.
    for ([_][2][]const u8{
        .{ "/long-before-choice", "/s" },
        .{ "/s", "/a-much-longer-after-choice" },
    }) |paths| {
        var source: preferences.Values = .{};
        try source.store.set(paths[0]);
        var snapshot: Snapshot = .{ .intent = .{}, .defaults = source };
        var fallback: [128]u8 = undefined;
        const before = try snapshot.destination("/home/test", &fallback);
        try std.testing.expect(before.saved);
        try std.testing.expectEqualStrings(paths[0], before.path);
        try source.store.set(paths[1]);
        try std.testing.expectEqualStrings(paths[0], (try snapshot.destination("/home/test", &fallback)).path);
        snapshot = .{ .intent = .{}, .defaults = source };
        const after = try snapshot.destination("/home/test", &fallback);
        try std.testing.expect(after.saved);
        try std.testing.expectEqualStrings(paths[1], after.path);
    }

    // An unavailable saved store is still the destination; an explicit store bypasses it; no store and no saved store take the home default.
    var snapshot: Snapshot = .{ .intent = .{}, .defaults = .{} };
    try snapshot.defaults.store.set("/unavailable-saved-store");
    var fallback: [128]u8 = undefined;
    const saved = try snapshot.destination("/home/test", &fallback);
    try std.testing.expect(saved.saved);
    try std.testing.expectEqualStrings("/unavailable-saved-store", saved.path);
    snapshot.intent = .{ .store = "/explicit", .provider = "codex", .model = "explicit-model" };
    try std.testing.expect(!snapshot.intent.needsPreferences());
    const explicit = try snapshot.destination("/unused", &fallback);
    try std.testing.expect(!explicit.saved);
    try std.testing.expectEqualStrings("/explicit", explicit.path);
    snapshot.defaults = .{};
    snapshot.intent = .{};
    const home = try snapshot.destination("/home/test", &fallback);
    try std.testing.expect(!home.saved);
    try std.testing.expectEqualStrings("/home/test/.local/share/rui/store", home.path);

    // A named store is used as given however long, and a relative home is refused when no store is named.
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

    // An explicit name bypasses a stale saved provider, and a binding taken earlier keeps its values when the saved defaults change.
    var stale: Snapshot = .{ .intent = .{ .provider = "alpha" }, .defaults = .{} };
    try stale.defaults.provider.set("gone");
    try std.testing.expectEqualStrings("alpha", (try stale.resolveUnprompted(&usable)).provider.slice());
    var retained_source: Snapshot = .{ .intent = .{}, .defaults = .{} };
    try retained_source.defaults.provider.set("alpha");
    try retained_source.defaults.model.set("before-choice-model");
    const retained = try retained_source.resolveUnprompted(&usable);
    try retained_source.defaults.model.set("after");
    try std.testing.expectEqualStrings("before-choice-model", retained.model.slice());
}

test "CM-60 model precedence: a known or unknown name takes its explicit, saved-matching, saved-other or no model, through resolveUnprompted" {
    const connection = @import("connection.zig");
    const known = connection.Name.parse("alpha").?;
    var usable: provider_selection.Readinesses = .initFill(.missing);
    usable.set(known, .configured);
    const Model = enum { explicit, saved_matching, saved_other, absent };
    // "alpha" is served and usable here; "beta" is a name this caller does not know, so it passes through to the Host.
    for ([_][]const u8{ "alpha", "beta" }) |name| for (std.enums.values(Model)) |model_case| {
        var snapshot: Snapshot = .{ .intent = .{ .provider = name }, .defaults = .{} };
        if (model_case == .explicit) snapshot.intent.model = "explicit-model";
        switch (model_case) {
            .saved_matching => {
                try snapshot.defaults.provider.set(name);
                try snapshot.defaults.model.set("saved-model");
            },
            .saved_other => {
                try snapshot.defaults.provider.set("gamma");
                try snapshot.defaults.model.set("saved-model");
            },
            .explicit, .absent => {},
        }
        if (std.mem.eql(u8, name, "alpha")) {
            // A known name takes its recommended model when neither an explicit nor a matching saved model names one.
            const binding = try snapshot.resolveUnprompted(&usable);
            try std.testing.expectEqualStrings(name, binding.provider.slice());
            switch (model_case) {
                .explicit => try std.testing.expectEqualStrings("explicit-model", binding.model.slice()),
                .saved_matching => try std.testing.expectEqualStrings("saved-model", binding.model.slice()),
                .saved_other, .absent => try std.testing.expect(binding.model.slice().len != 0),
            }
        } else switch (model_case) {
            // An unknown name takes only an explicit or matching saved model; with neither it is refused by name.
            .explicit => try std.testing.expectEqualStrings("explicit-model", (try snapshot.resolveUnprompted(&usable)).model.slice()),
            .saved_matching => try std.testing.expectEqualStrings("saved-model", (try snapshot.resolveUnprompted(&usable)).model.slice()),
            .saved_other, .absent => try std.testing.expectError(error.ConnectionModelRequired, snapshot.resolveUnprompted(&usable)),
        }
    };
}
