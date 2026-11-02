//! The model picker's list: each model a served sign-in offers, once, with
//! the sign-ins that offer it. The saved default comes first, then the
//! models Rui's table knows in the table's order, then the others by name.
const std = @import("std");
const model_capability = @import("model_capability.zig");
const model_list = @import("model_list.zig");
const provider_name = @import("provider_name.zig");

pub const Provider = provider_name.Provider;
pub const Providers = std.enums.EnumSet(Provider);

pub const Entry = struct {
    id: []const u8,
    /// Rui's table knows its limits; otherwise it runs with default limits.
    known: bool,
    /// The served sign-ins whose list holds it; never empty.
    providers: Providers,
};

/// What the Host said of each sign-in's list; null for one it does not serve.
pub const Sources = std.enums.EnumArray(Provider, ?model_list.Source);

pub const Menu = struct {
    entries: []const Entry = &.{},
    sources: Sources = .initFill(null),

    /// Where "Other models" starts: the first entry the table does not know.
    pub fn others(self: *const Menu) usize {
        for (self.entries, 0..) |entry, at| if (!entry.known) return at;
        return self.entries.len;
    }

    pub fn find(self: *const Menu, id: []const u8) ?usize {
        for (self.entries, 0..) |entry, at| if (std.mem.eql(u8, entry.id, id)) return at;
        return null;
    }

    /// Some served list is still being fetched: ask again later.
    pub fn loading(self: *const Menu) bool {
        for (self.sources.values) |source| if (source == .pending) return true;
        return false;
    }
};

/// The menu of `lists`, in `arena`, which owns it and its IDs. `default` is
/// the saved default's model.
pub fn build(arena: std.mem.Allocator, lists: []const model_list.Provided, default: ?[]const u8) error{OutOfMemory}!Menu {
    var menu: Menu = .{};
    var count: usize = 0;
    for (lists) |list| count += list.models.len;
    const ranked = try arena.alloc(Ranked, count);
    var filled: usize = 0;
    for (lists) |list| {
        menu.sources.set(list.provider, list.source);
        for (list.models) |model| {
            ranked[filled] = .{ .rank = rankOf(model.id, default), .entry = .{ .id = model.id, .known = model.known, .providers = .initOne(list.provider) } };
            filled += 1;
        }
    }
    std.mem.sort(Ranked, ranked, {}, Ranked.lessThan);
    // One entry per ID, in place: equal IDs share a rank, so they are adjacent.
    const entries = try arena.alloc(Entry, count);
    var len: usize = 0;
    for (ranked) |item| {
        if (len != 0 and std.mem.eql(u8, entries[len - 1].id, item.entry.id)) {
            entries[len - 1].providers.setUnion(item.entry.providers);
            continue;
        }
        entries[len] = item.entry;
        entries[len].id = try arena.dupe(u8, item.entry.id);
        len += 1;
    }
    menu.entries = entries[0..len];
    return menu;
}

const Ranked = struct {
    /// 0 for the default, then the table's order; others share the last.
    rank: usize,
    entry: Entry,

    fn lessThan(_: void, a: Ranked, b: Ranked) bool {
        if (a.rank != b.rank) return a.rank < b.rank;
        return std.mem.order(u8, a.entry.id, b.entry.id) == .lt;
    }
};

fn rankOf(id: []const u8, default: ?[]const u8) usize {
    if (default) |model| if (std.mem.eql(u8, model, id)) return 0;
    for (model_capability.models, 1..) |row, rank| if (std.mem.eql(u8, row.id, id)) return rank;
    return model_capability.models.len + 1;
}

fn offered(comptime ids: []const []const u8) []const model_list.Offered {
    return comptime blk: {
        var models: [ids.len]model_list.Offered = undefined;
        for (ids, &models) |id, *model| model.* = .{ .id = id, .known = model_capability.supportsModel(id) };
        const final = models;
        break :blk &final;
    };
}

test "the default leads, known models follow in table order, then the others by name, each once with every sign-in that offers it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const table = comptime blk: {
        var ids: [model_capability.models.len][]const u8 = undefined;
        for (model_capability.models, &ids) |row, *id| id.* = row.id;
        const final = ids;
        break :blk offered(&final);
    };
    const lists = [_]model_list.Provided{
        .{ .provider = .codex, .source = .table, .models = table },
        .{ .provider = .openai, .source = .live, .models = offered(&.{ "whisper-1", "gpt-6-luna", "dall-e-3", "gpt-5.5" }) },
    };
    const menu = try build(arena.allocator(), &lists, "gpt-6-sol");
    var expected: [model_capability.models.len + 2][]const u8 = undefined;
    expected[0] = "gpt-6-sol";
    var at: usize = 1;
    for (model_capability.models) |row| if (!std.mem.eql(u8, row.id, "gpt-6-sol")) {
        expected[at] = row.id;
        at += 1;
    };
    expected[at..][0..2].* = .{ "dall-e-3", "whisper-1" };
    try std.testing.expectEqual(expected.len, menu.entries.len);
    for (expected, menu.entries) |id, entry| {
        try std.testing.expectEqualStrings(id, entry.id);
        const both = std.mem.eql(u8, id, "gpt-6-luna") or std.mem.eql(u8, id, "gpt-5.5");
        const live_only = std.mem.eql(u8, id, "dall-e-3") or std.mem.eql(u8, id, "whisper-1");
        try std.testing.expectEqual(!live_only, entry.providers.contains(.codex));
        try std.testing.expectEqual(both or live_only, entry.providers.contains(.openai));
        try std.testing.expectEqual(!live_only, entry.known);
    }
    try std.testing.expectEqual(model_capability.models.len, menu.others());
    try std.testing.expectEqual(@as(?model_list.Source, .live), menu.sources.get(.openai));
    try std.testing.expect(!menu.loading());
}

test "a sign-in the Host does not serve has no source, and a pending list asks again" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const lists = [_]model_list.Provided{.{ .provider = .openai, .source = .pending, .models = offered(&.{ "gpt-6-luna", "gpt-5.5" }) }};
    const menu = try build(arena.allocator(), &lists, null);
    try std.testing.expectEqual(@as(?model_list.Source, null), menu.sources.get(.codex));
    try std.testing.expect(menu.loading());
    try std.testing.expectEqualStrings("gpt-6-luna", menu.entries[0].id);
    try std.testing.expectEqual(@as(?usize, 1), menu.find("gpt-5.5"));
    try std.testing.expectEqual(menu.entries.len, menu.others());
    const nothing = try build(arena.allocator(), &.{}, "gpt-6-luna");
    try std.testing.expectEqual(@as(usize, 0), nothing.entries.len);
}
