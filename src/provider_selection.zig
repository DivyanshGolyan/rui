const std = @import("std");
const connection = @import("connection.zig");
const provider_route = @import("provider_route.zig");
const connection_names = @import("connection_names.zig");

pub const Readiness = enum {
    configured,
    renewal_due,
    missing,
    refresh_required,
    credential_error,

    pub fn usable(self: Readiness) bool {
        return self == .configured or self == .renewal_due;
    }
};

/// The readiness of each served name: the built-in providers first, in their fixed
/// order, then key connections in document order. A name that is not served reads as missing.
pub const Readinesses = struct {
    map: connection_names.NameArray(Readiness) = .{},

    pub fn initFill(state: Readiness) Readinesses {
        var result: Readinesses = .{};
        for (provider_route.built_in_names) |name| result.map.set(name, state) catch unreachable;
        return result;
    }

    pub fn get(self: *const Readinesses, name: connection.Name) Readiness {
        return self.map.get(name) orelse .missing;
    }

    /// Sets a name's readiness, adding the name if it is not yet served.
    pub fn set(self: *Readinesses, name: connection.Name, state: Readiness) void {
        self.map.set(name, state) catch unreachable;
    }

    /// The served names, in order.
    pub fn names(self: *const Readinesses) []const connection.Name {
        return self.map.names[0..self.map.len];
    }

    /// The readiness of each served name, in the same order as `names`.
    pub fn states(self: *const Readinesses) []const Readiness {
        return self.map.values[0..self.map.len];
    }
};

/// Whether an explicit name is one the client cannot judge from its local readiness (the built-ins and the
/// Store's saved connections). Such a name passes through to the Host, which is the authority on what it
/// serves and refuses an unserved name by name; the client never asks a live Host to pre-validate it.
pub fn passesThrough(explicit: ?[]const u8, known: *const Readinesses) bool {
    const name = explicit orelse return false;
    for (known.names()) |served| if (std.mem.eql(u8, served.slice(), name)) return false;
    return true;
}

pub const Capability = struct {
    name: []const u8,
    recommended_model: []const u8,
    admits_model: *const fn ([]const u8) bool,
    readiness: Readiness,
};

pub const Selection = union(enum) {
    chooser,
    selected: struct {
        provider: []const u8,
        model: []const u8,
        readiness: Readiness,
    },
};

/// The model a name runs, for every name known or not: the explicit model, else the saved model when the saved
/// connection is that name, else null. Nothing else decides the precedence.
pub fn modelFor(name: []const u8, explicit_model: ?[]const u8, saved_provider: ?[]const u8, saved_model: ?[]const u8) ?[]const u8 {
    return explicit_model orelse (if (saved_provider != null and std.mem.eql(u8, name, saved_provider.?)) saved_model else null);
}

/// A name this client does not know locally: its model comes from modelFor alone, and a name with none is refused
/// by name, because this client cannot know another connection's default model.
pub const Unknown = struct { provider: []const u8, model: []const u8 };

pub fn resolveUnknown(name: []const u8, explicit_model: ?[]const u8, saved_provider: ?[]const u8, saved_model: ?[]const u8) error{ConnectionModelRequired}!Unknown {
    const model = modelFor(name, explicit_model, saved_provider, saved_model) orelse return error.ConnectionModelRequired;
    return .{ .provider = name, .model = model };
}

pub fn resolve(capabilities: []const Capability, explicit_provider: ?[]const u8, explicit_model: ?[]const u8, saved_provider: ?[]const u8, saved_model: ?[]const u8) !Selection {
    var chosen = explicit_provider orelse saved_provider;
    if (chosen == null) {
        for (capabilities) |capability| {
            if (!capability.readiness.usable()) continue;
            if (chosen != null) return .chooser;
            chosen = capability.name;
        }
    }
    const name = chosen orelse return .chooser;
    for (capabilities) |capability| {
        if (!std.mem.eql(u8, name, capability.name)) continue;
        const model = modelFor(name, explicit_model, saved_provider, saved_model) orelse capability.recommended_model;
        if (!capability.admits_model(model)) return error.UnsupportedSelectionModel;
        return .{ .selected = .{
            .provider = capability.name,
            .model = model,
            .readiness = capability.readiness,
        } };
    }
    return error.UnsupportedSelectionProvider;
}

test "Codex selection accepts identifiers without claiming model qualification" {
    var readiness: Readinesses = .initFill(.configured);
    const capability = @import("model_capability.zig").capabilities(&readiness).slice()[0];
    try std.testing.expectEqualStrings("family=variant", (try resolve(&.{capability}, null, "family=variant", null, null)).selected.model);
    const maximum = @as([256]u8, @splat('x'));
    try std.testing.expectEqualStrings(&maximum, (try resolve(&.{capability}, null, &maximum, null, null)).selected.model);
    for ([_][]const u8{ "", "bad model", "bad\nmodel", "\x7f", "\xc3\xa9", &@as([257]u8, @splat('x')) }) |invalid|
        try std.testing.expectError(error.UnsupportedSelectionModel, resolve(&.{capability}, null, invalid, null, null));
}

test "CM-57 served-name selection resolves by name across counts, readiness and explicit, saved and default choices" {
    const model_capability = @import("model_capability.zig");
    const built_ins = provider_route.built_in_names.len;
    var name_text: [connection.max_served][16]u8 = undefined;
    for (0..connection.max_served - built_ins + 1) |count| {
        var served: [connection.max_served]connection.Name = undefined;
        for (0..count) |index| served[index] = connection.Name.parse(try std.fmt.bufPrint(&name_text[index], "conn-{d}", .{index})).?;
        for (std.enums.values(Readiness)) |state| for (0..count) |sole| {
            var readiness: Readinesses = .initFill(.missing);
            for (served[0..count]) |name| readiness.set(name, .missing);
            readiness.set(served[sole], state);
            try std.testing.expectEqual(built_ins + count, readiness.names().len);
            for (served[0..count], 0..) |name, index| try std.testing.expectEqualStrings(name.slice(), readiness.names()[built_ins + index].slice());
            try std.testing.expectEqual(Readiness.missing, readiness.get(connection.Name.parse("absent").?));
            var caps = model_capability.capabilities(&readiness);
            const list = caps.slice();
            try std.testing.expectEqual(built_ins + count, list.len);

            // Explicit by name selects that entry with its own readiness, whatever the readiness.
            const explicit = try resolve(list, served[sole].slice(), null, null, null);
            try std.testing.expectEqualStrings(served[sole].slice(), explicit.selected.provider);
            try std.testing.expectEqual(state, explicit.selected.readiness);
            // Saved by name takes the saved model; an explicit model overrides it.
            try std.testing.expectEqualStrings("saved-model", (try resolve(list, null, null, served[sole].slice(), "saved-model")).selected.model);
            try std.testing.expectEqualStrings("explicit-model", (try resolve(list, null, "explicit-model", served[sole].slice(), "saved-model")).selected.model);
            // A name that is not served is refused, and a stale saved name never falls back to a ready entry.
            try std.testing.expectError(error.UnsupportedSelectionProvider, resolve(list, "absent", null, null, null));
            try std.testing.expectError(error.UnsupportedSelectionProvider, resolve(list, null, null, "absent", null));
            // With no explicit or saved name, the sole usable entry is chosen, else the caller must choose.
            const default = try resolve(list, null, null, null, null);
            if (state.usable()) {
                try std.testing.expectEqualStrings(served[sole].slice(), default.selected.provider);
            } else {
                try std.testing.expectEqual(Selection.chooser, default);
            }
            // A second usable entry (a built-in configured) leaves the default to the caller.
            var pair = readiness;
            pair.set(built_ins_first(), .configured);
            var pair_caps = model_capability.capabilities(&pair);
            const pair_default = try resolve(pair_caps.slice(), null, null, null, null);
            if (state.usable()) {
                try std.testing.expectEqual(Selection.chooser, pair_default);
            } else {
                try std.testing.expectEqualStrings(built_ins_first().slice(), pair_default.selected.provider);
            }
        };
    }

    // The served set holds at most max_served names, and one more is refused.
    var full: Readinesses = .initFill(.missing);
    for (0..connection.max_served - built_ins) |index| full.set(connection.Name.parse(try std.fmt.bufPrint(&name_text[index], "conn-{d}", .{index})).?, .missing);
    try std.testing.expectEqual(connection.max_served, full.names().len);
    try std.testing.expectError(error.ServedFull, full.map.set(connection.Name.parse("extra").?, .missing));
}

fn built_ins_first() connection.Name {
    return provider_route.built_in_names[0];
}

test "CM-59 local served names resolve at their own readiness, and a name the client does not know passes through" {
    const model_capability = @import("model_capability.zig");
    const built_ins = provider_route.built_in_names;
    var text: [connection.max_served][16]u8 = undefined;
    var pool: [connection.max_served]connection.Name = undefined;
    for (&pool, 0..) |*name, index| {
        name.* = if (index < built_ins.len) built_ins[index] else connection.Name.parse(try std.fmt.bufPrint(&text[index], "conn-{d}", .{index})).?;
    }
    const unknown = connection.Name.parse("absent").?;
    // One name, the built-ins only, and the full served set, at every credential state.
    const counts = [_]usize{ 1, built_ins.len, connection.max_served };
    for (counts) |count| for (std.enums.values(Readiness)) |state| {
        var known: Readinesses = .{};
        for (pool[0..count]) |name| known.set(name, state);
        try std.testing.expectEqual(count, known.names().len);
        var caps = model_capability.capabilities(&known);
        for (pool[0..count]) |name| {
            // A known name is selected at its own readiness, never forced to configured.
            try std.testing.expect(!passesThrough(name.slice(), &known));
            try std.testing.expectEqual(state, (try resolve(caps.slice(), name.slice(), null, null, null)).selected.readiness);
        }
        // A name the client does not know passes through, and resolve refuses it by name rather than choosing it.
        try std.testing.expect(passesThrough(unknown.slice(), &known));
        try std.testing.expectError(error.UnsupportedSelectionProvider, resolve(caps.slice(), unknown.slice(), null, null, null));
        try std.testing.expect(!passesThrough(null, &known));
    };
}

test "CM-60 model precedence: a known or unknown name takes its explicit, saved-matching, saved-other or no model" {
    const model_capability = @import("model_capability.zig");
    const known = connection.Name.parse("alpha").?;
    var readiness: Readinesses = .initFill(.missing);
    readiness.set(known, .configured);
    var caps = model_capability.capabilities(&readiness);
    const Model = enum { explicit, saved_matching, saved_other, absent };
    for ([_][]const u8{ "alpha", "beta" }) |name| for (std.enums.values(Model)) |model_case| {
        const explicit: ?[]const u8 = if (model_case == .explicit) "explicit-model" else null;
        const saved_provider: ?[]const u8 = switch (model_case) {
            .saved_matching => name,
            .saved_other => "gamma",
            else => null,
        };
        const saved_model: ?[]const u8 = if (saved_provider != null) "saved-model" else null;
        if (std.mem.eql(u8, name, "alpha")) {
            // A known name supplies its recommended model when neither an explicit nor a matching saved model names one.
            const selection = try resolve(caps.slice(), name, explicit, saved_provider, saved_model);
            switch (model_case) {
                .explicit => try std.testing.expectEqualStrings("explicit-model", selection.selected.model),
                .saved_matching => try std.testing.expectEqualStrings("saved-model", selection.selected.model),
                .saved_other, .absent => try std.testing.expect(selection.selected.model.len != 0),
            }
        } else {
            // An unknown name supplies no model of its own: a name with neither is refused by name.
            switch (model_case) {
                .explicit => try std.testing.expectEqualStrings("explicit-model", (try resolveUnknown(name, explicit, saved_provider, saved_model)).model),
                .saved_matching => try std.testing.expectEqualStrings("saved-model", (try resolveUnknown(name, explicit, saved_provider, saved_model)).model),
                .saved_other, .absent => try std.testing.expectError(error.ConnectionModelRequired, resolveUnknown(name, explicit, saved_provider, saved_model)),
            }
        }
    };
}
