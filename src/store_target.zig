const std = @import("std");
const session_id = @import("session_id.zig");
const store_id = @import("store_id.zig");

pub const Kind = enum { sqlite, mysql };

pub fn resolveKind(selector: []const u8, runtime_hint: ?[]const u8) Kind {
    return if (store_id.valid(selector) and runtime_hint != null) .mysql else .sqlite;
}

/// What an invocation's inputs say, as the shell read them. `saved` is null until the
/// shell has loaded the saved defaults, which `next` asks for only when it needs them.
pub const Sources = struct {
    explicit: ?[]const u8,
    env_store: ?[]const u8,
    env_address: ?[]const u8,
    env_handle: ?[]const u8,
    home: ?[]const u8,
    saved: ?SavedStore = null,
};

/// `path` borrows from the shell's buffer; the shell copies the saved Store there before asking again.
pub const SavedStore = union(enum) { none, path: []const u8, failed: anyerror };

pub const Source = enum { option, inherited, saved, home };

pub const Step = union(enum) {
    /// Effect: load the saved defaults under `home`, then ask again with `Sources.saved` set.
    load_saved,
    selected: struct {
        path: union(enum) { given: []const u8, home_default },
        source: Source,
        /// Inherited and saved Stores are never created by selection; the shell checks they exist.
        must_exist: bool,
    },
    /// `preferences` keeps the error the saved defaults failed with, so the shell names its class.
    refused: union(enum) { invalid_address, home_required, preferences: anyerror },
};

/// The one rule for which Store an invocation uses: the option; else the inherited
/// `RUI_STORE` with a valid `RUI_ADDRESS` and a nonempty `RUI_SENDER_HANDLE`; else the
/// saved default; else the HOME default.
pub fn next(sources: Sources) Step {
    if (sources.explicit) |path| return .{ .selected = .{ .path = .{ .given = path }, .source = .option, .must_exist = false } };
    if (sources.env_store) |path| {
        const address = sources.env_address orelse return .{ .refused = .invalid_address };
        const handle = sources.env_handle orelse return .{ .refused = .invalid_address };
        if (path.len == 0 or handle.len == 0 or !session_id.valid(address)) return .{ .refused = .invalid_address };
        return .{ .selected = .{ .path = .{ .given = path }, .source = .inherited, .must_exist = true } };
    }
    if (sources.env_address != null or sources.env_handle != null) return .{ .refused = .invalid_address };
    if (sources.home == null) return .{ .refused = .home_required };
    switch (sources.saved orelse return .load_saved) {
        .none => return .{ .selected = .{ .path = .home_default, .source = .home, .must_exist = false } },
        .path => |path| return .{ .selected = .{ .path = .{ .given = path }, .source = .saved, .must_exist = true } },
        .failed => |err| return .{ .refused = .{ .preferences = err } },
    }
}

test "Store target resolution retains path semantics without an explicit runtime hint" {
    for ([_][]const u8{ "/sqlite/store", "relative-store", "0123456789abcdef0123456789abcdeF", "", "0123456789abcdef0123456789abcdef" }) |selector| {
        try std.testing.expectEqual(.sqlite, resolveKind(selector, null));
    }
    for ([_][]const u8{ "/runtime", "relative", "" }) |hint| {
        try std.testing.expectEqual(.mysql, resolveKind("0123456789abcdef0123456789abcdef", hint));
        try std.testing.expectEqual(.sqlite, resolveKind("/sqlite/store", hint));
        try std.testing.expectEqual(.sqlite, resolveKind("0123456789abcdef0123456789abcdeF", hint));
    }
}

// CLI-25 an invocation selects one Store by a fixed order
// Expected values are typed from the base commit's selectedStore: the option first; then the
// inherited RUI_STORE, valid only with a valid RUI_ADDRESS and a nonempty RUI_SENDER_HANDLE and
// otherwise InvalidRuiAddress; then HOME's saved default, read only when the two above are absent;
// then HOME/.local/share/rui/store. A failed saved default keeps its own error.
fn sourcesWith(overrides: anytype) Sources {
    var sources: Sources = .{ .explicit = null, .env_store = null, .env_address = null, .env_handle = null, .home = null };
    inline for (@typeInfo(@TypeOf(overrides)).@"struct".field_names) |name| @field(sources, name) = @field(overrides, name);
    return sources;
}

fn expectSelected(expected_path: ?[]const u8, expected_source: Source, expected_exists: bool, actual: Step) !void {
    switch (actual) {
        .selected => |selected| {
            try std.testing.expectEqual(expected_source, selected.source);
            try std.testing.expectEqual(expected_exists, selected.must_exist);
            switch (selected.path) {
                .given => |text| try std.testing.expectEqualStrings(expected_path orelse return error.ExpectedHomeDefault, text),
                .home_default => if (expected_path != null) return error.ExpectedGivenPath,
            }
        },
        else => return error.ExpectedSelection,
    }
}

const Refusal = std.meta.Tag(@FieldType(Step, "refused"));

fn expectRefusal(expected: Refusal, actual: Step) !void {
    switch (actual) {
        .refused => |refused| try std.testing.expectEqual(expected, std.meta.activeTag(refused)),
        else => return error.ExpectedRefusal,
    }
}

fn expectLoadSaved(actual: Step) !void {
    if (std.meta.activeTag(actual) != .load_saved) return error.ExpectedLoadSaved;
}

/// The rule for one combination of inputs, stated per input and not computed by `next`.
fn checkRule(explicit: ?[]const u8, env_store: ?[]const u8, address: ?[]const u8, handle: ?[]const u8, home: ?[]const u8, saved: ?SavedStore) !void {
    const step = next(.{ .explicit = explicit, .env_store = env_store, .env_address = address, .env_handle = handle, .home = home, .saved = saved });
    if (explicit) |path| {
        try expectSelected(path, .option, false, step);
    } else if (env_store) |path| {
        const valid = path.len != 0 and address != null and std.mem.eql(u8, address.?, "k7m2qx") and handle != null and handle.?.len != 0;
        if (valid) {
            try expectSelected(path, .inherited, true, step);
        } else {
            try expectRefusal(.invalid_address, step);
        }
    } else if (address != null or handle != null) {
        try expectRefusal(.invalid_address, step);
    } else if (home == null) {
        try expectRefusal(.home_required, step);
    } else if (saved == null) {
        try expectLoadSaved(step);
    } else {
        switch (saved.?) {
            .none => try expectSelected(null, .home, false, step),
            .path => |path| try expectSelected(path, .saved, true, step),
            .failed => try expectRefusal(.preferences, step),
        }
    }
}

test "CLI-25 an invocation selects one Store by a fixed order" {
    // option, then inherited environment, then saved default, then HOME default
    try expectSelected("/opt/s", .option, false, next(sourcesWith(.{ .explicit = "/opt/s", .home = "/h" })));
    try expectSelected("/opt/s", .option, false, next(sourcesWith(.{ .explicit = "/opt/s", .env_store = "/inh", .env_address = "k7m2qx", .env_handle = "h", .home = "/h", .saved = SavedStore{ .path = "/saved" } })));
    try expectSelected("/opt/s", .option, false, next(sourcesWith(.{ .explicit = "/opt/s", .env_store = "/inh", .env_handle = "h" })));
    try expectSelected("", .option, false, next(sourcesWith(.{ .explicit = "", .home = "/h" })));
    try expectSelected("/inh", .inherited, true, next(sourcesWith(.{ .env_store = "/inh", .env_address = "k7m2qx", .env_handle = "h", .home = "/h" })));
    try expectSelected("/inh", .inherited, true, next(sourcesWith(.{ .env_store = "/inh", .env_address = "k7m2qx", .env_handle = "h" })));
    try expectSelected("/saved", .saved, true, next(sourcesWith(.{ .home = "/h", .saved = SavedStore{ .path = "/saved" } })));
    try expectSelected(null, .home, false, next(sourcesWith(.{ .home = "/h", .saved = SavedStore.none })));

    // The saved default is read only when neither the option nor the inherited environment answers.
    try expectLoadSaved(next(sourcesWith(.{ .home = "/h" })));
    try expectLoadSaved(next(sourcesWith(.{ .home = "/h", .env_address = null, .env_handle = null })));

    // A failed saved default refuses with its own error, not InvalidRuiAddress.
    try std.testing.expectEqual(error.AccessDenied, next(sourcesWith(.{ .home = "/h", .saved = SavedStore{ .failed = error.AccessDenied } })).refused.preferences);
    try std.testing.expectEqual(error.InvalidPreferences, next(sourcesWith(.{ .home = "/h", .saved = SavedStore{ .failed = error.InvalidPreferences } })).refused.preferences);
    // The option never reads the saved default, so its failure is not reached.
    try expectSelected("/opt/s", .option, false, next(sourcesWith(.{ .explicit = "/opt/s", .home = "/h", .saved = SavedStore{ .failed = error.AccessDenied } })));

    // A partial or invalid inherited set refuses, whatever the saved default holds.
    try expectRefusal(.invalid_address, next(sourcesWith(.{ .env_store = "/inh", .env_address = "k7m2qx", .env_handle = "", .home = "/h" })));
    try expectRefusal(.invalid_address, next(sourcesWith(.{ .env_store = "", .env_address = "k7m2qx", .env_handle = "h", .home = "/h" })));
    try expectRefusal(.invalid_address, next(sourcesWith(.{ .env_store = "/inh", .env_address = "K7M2QX", .env_handle = "h", .home = "/h" })));
    try expectRefusal(.invalid_address, next(sourcesWith(.{ .env_store = "/inh", .env_address = "v948e", .env_handle = "h", .home = "/h" })));
    try expectRefusal(.invalid_address, next(sourcesWith(.{ .env_store = "/inh", .env_handle = "h", .home = "/h", .saved = SavedStore{ .path = "/saved" } })));
    try expectRefusal(.invalid_address, next(sourcesWith(.{ .env_store = "/inh", .env_address = "k7m2qx", .home = "/h" })));
    try expectRefusal(.invalid_address, next(sourcesWith(.{ .env_address = "k7m2qx", .env_handle = "h", .home = "/h" })));
    try expectRefusal(.invalid_address, next(sourcesWith(.{ .env_handle = "h", .home = "/h" })));
    try expectRefusal(.invalid_address, next(sourcesWith(.{ .env_address = "k7m2qx", .home = "/h" })));
    try expectRefusal(.invalid_address, next(sourcesWith(.{ .env_address = "k7m2qx" })));
    // Inherited selection needs no HOME; no source at all needs HOME.
    try expectSelected("/inh", .inherited, true, next(sourcesWith(.{ .env_store = "/inh", .env_address = "k7m2qx", .env_handle = "h" })));
    try expectRefusal(.home_required, next(sourcesWith(.{})));

    // The product over every combination of present and absent inputs.
    const paths = [_]?[]const u8{ null, "/opt/s" };
    const env_stores = [_]?[]const u8{ null, "", "/inh" };
    const addresses = [_]?[]const u8{ null, "k7m2qx", "bad" };
    const handles = [_]?[]const u8{ null, "", "h" };
    const homes = [_]?[]const u8{ null, "/h" };
    const saved_states = [_]?SavedStore{ null, SavedStore.none, SavedStore{ .path = "/saved" }, SavedStore{ .failed = error.AccessDenied } };
    for (paths) |explicit| for (env_stores) |env_store| for (addresses) |address| for (handles) |handle| for (homes) |home| for (saved_states) |saved| {
        try checkRule(explicit, env_store, address, handle, home, saved);
    };
}
