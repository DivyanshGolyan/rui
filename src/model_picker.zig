const std = @import("std");
const catalog = @import("model_catalog.zig");
const product_defaults = @import("product_defaults.zig");
const model_capability = @import("model_capability.zig");
const model_list = @import("model_list.zig");
const provider_name = @import("provider_name.zig");
const nextToken = model_list.nextToken;
const objectKey = model_list.objectKey;

pub const Provider = provider_name.Provider;
pub const Providers = std.enums.EnumSet(Provider);

pub const Entry = struct {
    id: []const u8,
    known: bool,
    catalogued: bool,
    providers: Providers,

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        if (a.known != b.known) return a.known;
        if (a.catalogued != b.catalogued) return a.catalogued;
        return std.mem.order(u8, a.id, b.id) == .lt;
    }

    fn idLessThan(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u8, a.id, b.id) == .lt;
    }
};

pub const Sources = std.enums.EnumArray(Provider, ?model_list.Source);

pub const Menu = struct {
    entries: []const Entry = &.{},
    ids: []u8 = &.{},
    sources: Sources = .initFill(null),
    others: usize = 0,
    widest: usize = 0,

    pub fn deinit(self: *Menu, gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
        gpa.free(self.ids);
        self.* = .{};
    }

    pub fn find(self: *const Menu, id: []const u8) ?usize {
        for (self.entries, 0..) |entry, at| if (std.mem.eql(u8, entry.id, id)) return at;
        return null;
    }

    pub fn loading(self: *const Menu) bool {
        for (self.sources.values) |source| if (source == .pending) return true;
        return false;
    }

    pub fn shown(self: *const Menu, default: ?[]const u8) Shown {
        return .{ .menu = self, .lead = if (default) |id| self.find(id) else null };
    }
};

pub const Shown = struct {
    menu: *const Menu,
    lead: ?usize,

    pub fn entry(self: Shown, at_row: usize) Entry {
        const lead = self.lead orelse return self.menu.entries[at_row];
        if (at_row == 0) return self.menu.entries[lead];
        return self.menu.entries[if (at_row <= lead) at_row - 1 else at_row];
    }

    pub fn row(self: Shown, at: usize) usize {
        const lead = self.lead orelse return at;
        return if (at == lead) 0 else if (at < lead) at + 1 else at;
    }

    pub fn others(self: Shown) usize {
        const lead = self.lead orelse return self.menu.others;
        return self.menu.others + @intFromBool(lead >= self.menu.others);
    }
};

pub const ReasoningEffort = model_capability.ReasoningEffort;

pub const Defaults = struct {
    model: ?[]const u8 = null,
    provider: ?Provider = null,
    effort: ?ReasoningEffort = null,
};

pub const Row = struct {
    effort: ?ReasoningEffort,
    provider: Provider,
    current: bool,
};

pub const Query = struct {
    words: []const u8,
    effort: ?ReasoningEffort = null,
    provider: ?Provider = null,

    pub fn parse(words: []const u8) Query {
        var query: Query = .{ .words = words };
        var each = std.mem.tokenizeScalar(u8, words, ' ');
        while (each.next()) |word| {
            for (std.enums.values(ReasoningEffort)) |effort| {
                if (std.ascii.eqlIgnoreCase(@tagName(effort), word)) query.effort = effort;
            }
            for (std.enums.values(Provider)) |provider| {
                for (signInWords(provider)) |name| {
                    if (std.ascii.eqlIgnoreCase(name, word)) query.provider = provider;
                }
            }
        }
        return query;
    }

    pub fn row(self: Query, entry: Entry, defaults: Defaults) ?Row {
        if (!catalog.canChat(entry.id)) return null;
        return self.match(entry, defaults);
    }

    fn match(self: Query, entry: Entry, defaults: Defaults) ?Row {
        var efforts: catalog.Efforts = .empty;
        for (std.enums.values(ReasoningEffort)) |effort| {
            if (model_capability.supportsReasoningEffort(catalog.shipped, entry.id, effort)) efforts.insert(effort);
        }
        var each = std.mem.tokenizeScalar(u8, self.words, ' ');
        while (each.next()) |word| {
            if (std.ascii.findIgnoreCase(entry.id, word) != null) continue;
            if (beginsOne(word, efforts, entry.providers)) continue;
            return null;
        }
        const product_provider = comptime std.meta.stringToEnum(Provider, product_defaults.provider).?;
        const provider = for ([_]?Provider{ self.provider, defaults.provider, product_provider }) |wanted| {
            if (wanted) |one| if (entry.providers.contains(one)) break one;
        } else for (std.enums.values(Provider)) |one| {
            if (entry.providers.contains(one)) break one;
        } else unreachable;
        return .{
            .effort = self.effort orelse defaults.effort,
            .provider = provider,
            .current = if (defaults.model) |model| std.mem.eql(u8, model, entry.id) else false,
        };
    }

    fn beginsOne(word: []const u8, efforts: catalog.Efforts, providers: Providers) bool {
        var efforts_offered = efforts.iterator();
        while (efforts_offered.next()) |effort| if (std.ascii.startsWithIgnoreCase(@tagName(effort), word)) return true;
        var providers_offered = providers.iterator();
        while (providers_offered.next()) |provider| {
            for ([_]?Provider{ provider, provider.sameAccount() }) |one| {
                const named = one orelse continue;
                for (signInWords(named)) |name| if (std.ascii.startsWithIgnoreCase(name, word)) return true;
            }
        }
        return false;
    }
};

fn signInWords(provider: Provider) [2][]const u8 {
    const label = provider.signIn();
    const first = label[0 .. std.mem.indexOfScalar(u8, label, ' ') orelse label.len];
    return .{ first, if (provider.sameAccount() != null) @tagName(provider) else first };
}

pub fn read(gpa: std.mem.Allocator, providers: []const u8) error{ OutOfMemory, InvalidModelList }!Menu {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const temporary = scratch.allocator();
    var scanner: std.json.Scanner = .initCompleteInput(temporary, providers);
    var menu: Menu = .{};
    const offered = try temporary.alloc(Entry, std.mem.count(u8, providers, "\"id\":"));
    var count: usize = 0;
    if (try nextToken(&scanner, temporary) != .array_begin) return error.InvalidModelList;
    while (true) {
        switch (try nextToken(&scanner, temporary)) {
            .array_end => break,
            .object_begin => {},
            else => return error.InvalidModelList,
        }
        var provider: ?Provider = null;
        var source: ?model_list.Source = null;
        var models: ?[2]usize = null;
        while (try objectKey(&scanner, temporary)) |key| {
            if (std.mem.eql(u8, key, "provider")) {
                provider = std.meta.stringToEnum(Provider, try string(&scanner, temporary)) orelse return error.InvalidModelList;
            } else if (std.mem.eql(u8, key, "source")) {
                source = std.meta.stringToEnum(model_list.Source, try string(&scanner, temporary)) orelse return error.InvalidModelList;
            } else if (std.mem.eql(u8, key, "models")) {
                const start = count;
                if (try nextToken(&scanner, temporary) != .array_begin) return error.InvalidModelList;
                while (true) {
                    switch (try nextToken(&scanner, temporary)) {
                        .array_end => break,
                        .object_begin => {},
                        else => return error.InvalidModelList,
                    }
                    var id: ?[]const u8 = null;
                    var known: ?bool = null;
                    while (try objectKey(&scanner, temporary)) |member| {
                        if (std.mem.eql(u8, member, "id")) {
                            id = try string(&scanner, temporary);
                        } else if (std.mem.eql(u8, member, "known")) {
                            known = switch (try nextToken(&scanner, temporary)) {
                                .true => true,
                                .false => false,
                                else => return error.InvalidModelList,
                            };
                        } else return error.InvalidModelList;
                    }
                    const model = id orelse return error.InvalidModelList;
                    if (!model_capability.validModelSyntax(model)) return error.InvalidModelList;
                    if (count == offered.len) return error.InvalidModelList;
                    offered[count] = .{ .id = model, .known = known orelse return error.InvalidModelList, .catalogued = model_capability.supportsModel(catalog.shipped, model), .providers = .empty };
                    count += 1;
                }
                models = .{ start, count };
            } else return error.InvalidModelList;
        }
        const served = provider orelse return error.InvalidModelList;
        const span = models orelse return error.InvalidModelList;
        if (menu.sources.get(served) != null) return error.InvalidModelList;
        menu.sources.set(served, source orelse return error.InvalidModelList);
        for (offered[span[0]..span[1]]) |*entry| entry.providers = .initOne(served);
    }
    if (try nextToken(&scanner, temporary) != .end_of_document) return error.InvalidModelList;
    std.mem.sort(Entry, offered[0..count], {}, Entry.idLessThan);
    var len: usize = 0;
    var id_bytes: usize = 0;
    for (offered[0..count]) |entry| {
        if (len != 0 and std.mem.eql(u8, offered[len - 1].id, entry.id)) {
            offered[len - 1].providers.setUnion(entry.providers);
            offered[len - 1].known = offered[len - 1].known or entry.known;
            continue;
        }
        offered[len] = entry;
        id_bytes += entry.id.len;
        len += 1;
    }
    std.mem.sort(Entry, offered[0..len], {}, Entry.lessThan);
    const entries = try gpa.alloc(Entry, len);
    errdefer gpa.free(entries);
    menu.ids = try gpa.alloc(u8, id_bytes);
    var at: usize = 0;
    menu.others = len;
    for (offered[0..len], entries, 0..) |entry, *kept, place| {
        @memcpy(menu.ids[at..][0..entry.id.len], entry.id);
        kept.* = entry;
        kept.id = menu.ids[at..][0..entry.id.len];
        at += entry.id.len;
        menu.widest = @max(menu.widest, entry.id.len);
        if (!entry.known and menu.others == len) menu.others = place;
    }
    menu.entries = entries;
    return menu;
}

fn string(scanner: *std.json.Scanner, scratch: std.mem.Allocator) error{ OutOfMemory, InvalidModelList }![]const u8 {
    return switch (try nextToken(scanner, scratch)) {
        .string, .allocated_string => |text| text,
        else => error.InvalidModelList,
    };
}

pub fn testMenu(lists: []const model_list.Entry) !Menu {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try model_list.writeProviders(&bytes.writer, catalog.shipped, lists);
    return read(std.testing.allocator, bytes.written());
}

fn expectOrder(shown: Shown, ids: []const []const u8) !void {
    try std.testing.expectEqual(ids.len, shown.menu.entries.len);
    for (ids, 0..) |id, row| {
        try std.testing.expectEqualStrings(id, shown.entry(row).id);
        try std.testing.expectEqual(row, shown.row(shown.menu.find(id).?));
    }
}

test "the default leads, known models follow in catalog order, then the others by name, each once with every sign-in that offers it" {
    var menu = try testMenu(&.{
        .{ .provider = .codex, .list = .catalog },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = "zz-unlisted\ngpt-6-luna\naa-unlisted\ngpt-5.5\n" } } },
    });
    defer menu.deinit(std.testing.allocator);
    var expected: [catalog.openai_ids.len + 2][]const u8 = undefined;
    expected[0] = "gpt-6-sol";
    var at: usize = 1;
    for (catalog.openai_ids) |id| if (!std.mem.eql(u8, id, "gpt-6-sol")) {
        expected[at] = id;
        at += 1;
    };
    expected[at..][0..2].* = .{ "aa-unlisted", "zz-unlisted" };
    try expectOrder(menu.shown("gpt-6-sol"), &expected);
    for (menu.entries) |entry| {
        const both = std.mem.eql(u8, entry.id, "gpt-6-luna") or std.mem.eql(u8, entry.id, "gpt-5.5");
        const live_only = std.mem.eql(u8, entry.id, "aa-unlisted") or std.mem.eql(u8, entry.id, "zz-unlisted");
        try std.testing.expectEqual(!live_only, entry.providers.contains(.codex));
        try std.testing.expectEqual(both or live_only, entry.providers.contains(.openai));
        try std.testing.expectEqual(!live_only, entry.known);
    }
    try std.testing.expectEqual(catalog.openai_ids.len, menu.shown("gpt-6-sol").others());
    var widest: usize = "zz-unlisted".len;
    for (catalog.openai_ids) |id| widest = @max(widest, id.len);
    try std.testing.expectEqual(widest, menu.widest);
    try std.testing.expectEqual(@as(?model_list.Source, .live), menu.sources.get(.openai));
    try std.testing.expect(!menu.loading());
    expected[0] = "gpt-5.5";
    at = 1;
    for (catalog.openai_ids) |id| if (!std.mem.eql(u8, id, "gpt-5.5")) {
        expected[at] = id;
        at += 1;
    };
    try expectOrder(menu.shown("gpt-5.5"), &expected);
    const unlisted_first = menu.shown("zz-unlisted");
    try std.testing.expectEqualStrings("zz-unlisted", unlisted_first.entry(0).id);
    try std.testing.expectEqual(catalog.openai_ids.len + 1, unlisted_first.others());
    try std.testing.expectEqualStrings("aa-unlisted", unlisted_first.entry(unlisted_first.others()).id);
    for ([_]?[]const u8{ null, "o9" }) |absent| {
        const plain = menu.shown(absent);
        try std.testing.expectEqualStrings(catalog.openai_ids[0], plain.entry(0).id);
        try std.testing.expectEqualStrings("zz-unlisted", plain.entry(menu.entries.len - 1).id);
    }
}

test "the Host's word decides which models are known; Rui's catalog only orders them" {
    var menu = try read(std.testing.allocator, "[{\"provider\":\"openai\",\"source\":\"live\",\"models\":[" ++
        "{\"id\":\"o9\",\"known\":false},{\"id\":\"gpt-6-luna\",\"known\":false},{\"id\":\"zz-next\",\"known\":true},{\"id\":\"gpt-5.5\",\"known\":true}]}]");
    defer menu.deinit(std.testing.allocator);
    try expectOrder(menu.shown(null), &.{ "gpt-5.5", "zz-next", "gpt-6-luna", "o9" });
    try std.testing.expectEqual(@as(usize, 2), menu.others);
    try std.testing.expect(menu.entries[1].known and !menu.entries[2].known);
}

test "a sign-in the Host does not serve has no source, and a pending list asks again" {
    var menu = try testMenu(&.{.{ .provider = .openai, .list = .pending }});
    defer menu.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?model_list.Source, null), menu.sources.get(.codex));
    try std.testing.expect(menu.loading());
    try std.testing.expectEqualStrings(catalog.openai_ids[0], menu.entries[0].id);
    try std.testing.expect(menu.find("gpt-6.1-sol") != null);
    try std.testing.expectEqual(menu.entries.len, menu.others);
    var nothing = try testMenu(&.{});
    defer nothing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), nothing.entries.len);
}

test "a reply Rui cannot read is refused whole" {
    for ([_][]const u8{
        "",
        "{}",
        "[{\"provider\":\"codex\",\"source\":\"table\",\"models\":[]}]",
        "[{\"provider\":\"openai\",\"source\":\"table_fallback\",\"models\":[]}]",
        "[{\"provider\":\"claude\",\"source\":\"catalog\",\"models\":[]}]",
        "[{\"provider\":\"openai\",\"source\":\"live\",\"models\":[{\"id\":\"a b\",\"known\":false}]}]",
        "[{\"provider\":\"openai\",\"source\":\"live\",\"models\":[{\"id\":\"gpt-6-luna\"}]}]",
        "[{\"provider\":\"openai\",\"source\":\"live\"}]",
        "[{\"provider\":\"openai\",\"source\":\"live\",\"models\":[]},{\"provider\":\"openai\",\"source\":\"catalog\",\"models\":[]}]",
        "[] []",
    }) |reply| try std.testing.expectError(error.InvalidModelList, read(std.testing.allocator, reply));
}

fn pickerMenu() !Menu {
    return testMenu(&.{
        .{ .provider = .codex, .list = .catalog },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-terra\ngpt-6.1-sol\ngpt-6.1-sol-2026-10-14\nft:custom\n" ++
            "@cf/deepseek-ai/deepseek-v4-flash-0731\nazure/gpt-5-pro\nopenai/gpt-4.1\nalibaba/qwen-max\nauto/mistralai/mistral-medium-3.5\n" } } },
    });
}

fn entryOf(menu: *const Menu, id: []const u8) Entry {
    return menu.entries[menu.find(id).?];
}

fn plainRow(menu: *const Menu, id: []const u8, defaults: Defaults) Row {
    return Query.parse("").row(entryOf(menu, id), defaults).?;
}

test "a row previews only typed or saved effort and keeps provider selection" {
    var menu = try pickerMenu();
    defer menu.deinit(std.testing.allocator);
    const Case = struct { id: []const u8, effort: ?ReasoningEffort, provider: Provider };
    const saved: Defaults = .{ .model = "gpt-6.1-sol", .provider = .openai, .effort = .none };
    for ([_]Case{
        .{ .id = "gpt-6.1-terra", .effort = .none, .provider = .openai },
        .{ .id = "gpt-6.1-sol", .effort = .none, .provider = .openai },
        .{ .id = "gpt-6-astra", .effort = .none, .provider = .codex },
        .{ .id = "gpt-5.5-pro", .effort = .none, .provider = .codex },
        .{ .id = "ft:custom", .effort = .none, .provider = .openai },
        .{ .id = "azure/gpt-5-pro", .effort = .none, .provider = .openai },
        .{ .id = "openai/gpt-4.1", .effort = .none, .provider = .openai },
    }) |case| {
        const row = plainRow(&menu, case.id, saved);
        try std.testing.expectEqual(case.effort, row.effort);
        try std.testing.expectEqual(case.provider, row.provider);
    }
    for ([_]Case{
        .{ .id = "gpt-6.1-sol", .effort = null, .provider = .codex },
        .{ .id = "gpt-5.5-pro", .effort = null, .provider = .codex },
        .{ .id = "ft:custom", .effort = null, .provider = .openai },
        .{ .id = "azure/gpt-5-pro", .effort = null, .provider = .openai },
    }) |case| {
        const row = plainRow(&menu, case.id, .{});
        try std.testing.expectEqual(case.effort, row.effort);
        try std.testing.expectEqual(case.provider, row.provider);
    }
    try std.testing.expectEqual(@as(?ReasoningEffort, .high), plainRow(&menu, "gpt-5.5-pro", .{ .effort = .high }).effort);
    try std.testing.expectEqual(@as(?ReasoningEffort, .high), plainRow(&menu, "gpt-6.1-sol", .{ .effort = .high }).effort);
}

test "the ✓ marks the row of the model new Sessions use, whatever its sign-in" {
    var menu = try pickerMenu();
    defer menu.deinit(std.testing.allocator);
    var marked: usize = 0;
    for (menu.entries) |entry| {
        const row = Query.parse("").row(entry, .{ .model = "gpt-6.1-sol", .provider = .codex }) orelse continue;
        try std.testing.expectEqual(std.mem.eql(u8, entry.id, "gpt-6.1-sol"), row.current);
        marked += @intFromBool(row.current);
        try std.testing.expect(!Query.parse("").row(entry, .{ .provider = .codex, .effort = .high }).?.current);
    }
    try std.testing.expectEqual(@as(usize, 1), marked);
}

fn expectRows(menu: *const Menu, typed: []const u8, ids: []const []const u8) !void {
    const query = Query.parse(typed);
    var at: usize = 0;
    for (menu.entries) |entry| if (query.row(entry, .{}) != null) {
        try std.testing.expect(at < ids.len);
        try std.testing.expectEqualStrings(ids[at], entry.id);
        at += 1;
    };
    try std.testing.expectEqual(ids.len, at);
}

test "/model terra low api leaves one row, set to low on the API key, whatever was saved" {
    var menu = try pickerMenu();
    defer menu.deinit(std.testing.allocator);
    const saved: Defaults = .{ .model = "gpt-6.1-sol", .provider = .codex, .effort = .high };
    for ([_][]const u8{ "terra low api", "api low terra", "  TERRA  Low API ", "terra high low api codex api" }) |typed| {
        try expectRows(&menu, typed, &.{"gpt-6.1-terra"});
        const row = Query.parse(typed).row(entryOf(&menu, "gpt-6.1-terra"), saved).?;
        try std.testing.expectEqual(@as(?ReasoningEffort, .low), row.effort);
        try std.testing.expectEqual(Provider.openai, row.provider);
        try std.testing.expect(!row.current);
    }
    try expectRows(&menu, "terra low", &.{ "gpt-5.6-terra", "gpt-6.1-terra" });
    try expectRows(&menu, "terra codex", &.{ "gpt-5.6-terra", "gpt-6.1-terra" });
    const codex = Query.parse("terra codex").row(entryOf(&menu, "gpt-6.1-terra"), .{ .provider = .openai, .effort = .medium }).?;
    try std.testing.expectEqual(Provider.codex, codex.provider);
    try std.testing.expectEqual(@as(?ReasoningEffort, .medium), codex.effort);
}

test "a word narrows to the rows whose ID holds it or that offer the effort or sign-in it begins" {
    var menu = try pickerMenu();
    defer menu.deinit(std.testing.allocator);
    for ([_][]const u8{ "6.1-terra l", "6.1-terra lo", "6.1-terra ap", "6.1-terra AP" }) |typed| {
        try expectRows(&menu, typed, &.{"gpt-6.1-terra"});
        const row = Query.parse(typed).row(entryOf(&menu, "gpt-6.1-terra"), .{ .provider = .codex, .effort = .high }).?;
        try std.testing.expectEqual(@as(?ReasoningEffort, .high), row.effort);
        try std.testing.expectEqual(Provider.codex, row.provider);
    }
    try expectRows(&menu, "6.1-sol none", &.{"gpt-6.1-sol-2026-10-14"});
    try expectRows(&menu, "astra api", &.{});
    try expectRows(&menu, "6.1-terra q", &.{});
    try expectRows(&menu, "qwen max", &.{"alibaba/qwen-max"});
    try std.testing.expectEqual(@as(?ReasoningEffort, .max), Query.parse("qwen max").row(entryOf(&menu, "alibaba/qwen-max"), .{ .effort = .low }).?.effort);
    try expectRows(&menu, "mistral medium", &.{"auto/mistralai/mistral-medium-3.5"});
    const mistral = entryOf(&menu, "auto/mistralai/mistral-medium-3.5");
    try std.testing.expectEqual(@as(?ReasoningEffort, .medium), Query.parse("mistral medium").row(mistral, .{ .effort = .high }).?.effort);
    try std.testing.expectEqual(@as(?ReasoningEffort, .medium), Query.parse("mistral medium").row(mistral, .{ .effort = .xhigh }).?.effort);
    var all: usize = 0;
    for (menu.entries) |entry| all += @intFromBool(Query.parse(" ").row(entry, .{}) != null);
    var chat_count: usize = 0;
    for (menu.entries) |entry| if (catalog.canChat(entry.id)) {
        chat_count += 1;
    };
    try std.testing.expectEqual(chat_count, all);
}

test "model picker domain admits chat and unknown live IDs but not catalog-proven non-chat families" {
    var menu = try testMenu(&.{.{ .provider = .openai, .list = .{ .live = .{
        .bytes = "gpt-6.1-sol\ngpt-4.1\nfuture-chat\ngpt-imagery-next\n" ++
            "gpt-image-2\ngpt-image-1-mini\ntext-embedding-3-large\ngpt-realtime-2.1\n" ++
            "openai/whisper-1\ngpt-image-next\ntext-embedding-next\ngpt-realtime-next\n",
    } } }});
    defer menu.deinit(std.testing.allocator);
    try expectRows(&menu, "", &.{ "gpt-4.1", "gpt-6.1-sol", "future-chat", "gpt-imagery-next" });
    try std.testing.expect(!entryOf(&menu, "future-chat").known);

    const facts = @import("model_catalog_snapshot.zig");
    var body: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer body.deinit();
    for (catalog.shipped) |entry| try body.writer.print("{s}\n", .{entry.id});
    var whole = try testMenu(&.{.{ .provider = .openai, .list = .{ .live = .{ .bytes = body.written() } } }});
    defer whole.deinit(std.testing.allocator);
    var offered_chat: usize = 0;
    for (whole.entries) |entry| {
        try std.testing.expect(entry.known);
        offered_chat += @intFromBool(Query.parse("").row(entry, .{}) != null);
    }
    try std.testing.expectEqual(catalog.shipped.len - facts.non_chat_ids.len, offered_chat);
    for (facts.non_chat_ids) |id| try std.testing.expect(Query.parse("").row(entryOf(&whole, id), .{}) == null);
}
