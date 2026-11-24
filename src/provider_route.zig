const std = @import("std");
const connection = @import("connection.zig");
const provider_name = @import("provider_name.zig");
const Provider = provider_name.Provider;

pub const Route = enum { unserved, endpoint, chatgpt_device, key_file, chatgpt_plan };

/// The most connections one Host serves at once.
pub const max_served = 16;

/// One served connection: its name, how the Host reaches it, the wire codec
/// its Sessions speak, and whether it runs web_search.
pub const Entry = struct {
    name: connection.Name,
    route: Route,
    codec: provider_name.Codec,
    web_search: bool,
};

/// The Host's served set, keyed by connection name. It lists only served
/// names, so an absent name is unserved. `of` is the one lookup that answers
/// "who serves this Session".
pub const Served = struct {
    entries: [max_served]Entry = undefined,
    len: usize = 0,

    pub fn put(self: *Served, entry: Entry) error{ServedFull}!void {
        if (self.len == max_served) return error.ServedFull;
        self.entries[self.len] = entry;
        self.len += 1;
    }

    pub fn items(self: *const Served) []const Entry {
        return self.entries[0..self.len];
    }

    pub fn of(self: *const Served, name: []const u8) ?*const Entry {
        for (self.items()) |*entry| if (std.mem.eql(u8, entry.name.slice(), name)) return entry;
        return null;
    }

    pub fn servesModel(self: *const Served) bool {
        return self.len != 0;
    }

    /// The route a name is served at, `unserved` when the name is absent.
    pub fn route(self: *const Served, name: []const u8) Route {
        return if (self.of(name)) |entry| entry.route else .unserved;
    }

    /// The codec of the binding named `name`: a served name's entry, else an absent built-in name's own
    /// codec, else none. The one owner of whether a name is a binding a Session may be created on.
    pub fn codecOf(self: *const Served, name: []const u8) ?provider_name.Codec {
        if (self.of(name)) |entry| return entry.codec;
        const built_in = builtInOf(connection.Name.parse(name) orelse return null) orelse return null;
        return built_in.codec();
    }

    /// Whether the binding named `name` runs the tool. This is the one owner of tool capability: a served
    /// name answers from its entry, an absent built-in name from the built-in provider's facts, and any
    /// other absent name runs nothing. Serving decides reachability, not what the binding can run.
    pub fn runsTool(self: *const Served, name: []const u8, tool: []const u8) bool {
        if (self.of(name)) |entry| return entry.web_search and std.mem.eql(u8, tool, "web_search");
        const built_in = builtInOf(connection.Name.parse(name) orelse return false) orelse return false;
        return built_in.runsTool(tool);
    }
};

/// A built-in provider as a served entry, named by its enum tag.
pub fn builtIn(provider: Provider, route: Route) Entry {
    return .{
        .name = connection.Name.parse(@tagName(provider)).?,
        .route = route,
        .codec = provider.codec(),
        .web_search = provider.runsTool("web_search"),
    };
}

/// The built-in provider a name spells. Until the Host's provider enum gives
/// way to connection names (commits 3-6), the boundary that hands a Session's
/// provider to enum-typed code calls this; a name that is not built in has none.
pub fn builtInOf(name: connection.Name) ?Provider {
    return std.meta.stringToEnum(Provider, name.slice());
}

/// Every built-in provider served at one route, for test fixtures.
pub fn builtIns(route: Route) Served {
    var served: Served = .{};
    inline for (std.enums.values(Provider)) |provider| served.put(builtIn(provider, route)) catch unreachable;
    return served;
}

test "CM-49 served lookup finds exactly the listed names" {
    var served: Served = .{};
    try std.testing.expect(!served.servesModel());
    try std.testing.expectEqual(@as(?*const Entry, null), served.of("codex"));
    const codex = builtIn(.codex, .endpoint);
    try served.put(codex);
    try served.put(builtIn(.chatgpt, .chatgpt_plan));
    try std.testing.expect(served.servesModel());
    try std.testing.expectEqual(Route.endpoint, served.of("codex").?.route);
    try std.testing.expectEqual(Route.chatgpt_plan, served.of("chatgpt").?.route);
    // Absent, prefix, and case-variant names never match a listed name.
    for ([_][]const u8{ "openai", "cod", "codexx", "Codex", "CHATGPT", "", "chatgpt-" }) |name| {
        try std.testing.expectEqual(@as(?*const Entry, null), served.of(name));
    }
    // Exactly the listed names fill the set, and no more than max_served.
    var full: Served = .{};
    var buffer: [max_served + 1][8]u8 = undefined;
    for (0..max_served) |index| {
        const name = std.fmt.bufPrint(&buffer[index], "c{d}", .{index}) catch unreachable;
        var entry = codex;
        entry.name = connection.Name.parse(name).?;
        try full.put(entry);
    }
    try std.testing.expectEqual(@as(usize, max_served), full.items().len);
    try std.testing.expect(full.of("c15") != null);
    try std.testing.expect(full.of("c16") == null);
    try std.testing.expectError(error.ServedFull, full.put(codex));
    try std.testing.expect(full.of("codex") == null);
}

test "built-in entries carry each provider's codec and web_search" {
    const served = builtIns(.endpoint);
    try std.testing.expectEqual(@as(usize, 3), served.items().len);
    for (std.enums.values(Provider)) |provider| {
        const entry = served.of(@tagName(provider)).?;
        try std.testing.expectEqual(provider.codec(), entry.codec);
        try std.testing.expect(entry.web_search);
        try std.testing.expectEqual(Route.endpoint, entry.route);
    }
}
